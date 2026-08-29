#!/usr/bin/env python3
"""Fail closed before one action covered by an immutable run authorization.

It never performs the external action. It validates the instantiated envelope,
binds the request to exact repository/time/attempt/artifact facts, then atomically
reserves the single-use grant in the local append-only ledger before returning.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import stat
from typing import Any
import urllib.parse
import uuid

import spec_kit_snapshot


ALLOWED_ACTIONS = {
    "git.commit", "git.push", "github.issue.create", "github.issue.update",
    "github.issue.comment", "github.project.update", "github.pr.create",
    "github.pr.update", "github.pr.comment", "github.evidence.publish",
    "github.checks.wait", "apple.testflight.upload",
    "apple.testflight.processing.wait", "apple.testflight.distribute_internal",
    "apple.testflight.readback",
}
FORBIDDEN_ACTIONS = {
    "git.force_push", "github.auto_merge", "github.ruleset_change",
    "apple.app_review_submit", "apple.production_release",
    "apple.signing_resource_mutation", "credential.scope_expansion",
    "environment.destructive_cleanup",
}
REPOSITORY_FIELDS = ("fingerprint", "canonical_root", "remote", "base_sha", "branch")
APPLE_FIELDS = (
    "account_guard_ref", "team_id", "app_id", "bundle_id", "platform",
    "version_policy", "build_policy", "artifact_policy",
)
LIMIT_MINIMUMS = {
    "max_implementation_attempts": 1, "max_review_cycles": 1,
    "max_transient_retries": 0, "active_wall_minutes": 1,
    "async_wait_minutes": 1,
}
TOP_LEVEL_FIELDS = {
    "schema_version", "run_id", "authorization_id", "decision", "actor", "issued_at",
    "expires_at", "delivery_target", "repository", "spec_kit",
    "acceptance_ids", "allowed_paths", "limits", "github", "apple",
    "action_grants", "forbidden_actions", "auto_merge", "app_review_submit",
    "credential_scope_expansion", "signing_resource_mutation",
    "destructive_cleanup",
}
REQUEST_FIELDS = {
    "run_id", "authorization_id", "authorization_hash", "delivery_target", "system",
    "action", "target", "grant_id", "idempotency_key", "repository",
    "spec_snapshot_sha256", "paths", "apple", "lease_id", "lease_owner",
    "lease_resource", "lease_resource_key",
    "operation", "operation_input", "constraint_sha256", "phase",
    "spec_checkpoint_sha256", "apple_observation_sha256",
}
HEX_SHA = re.compile(r"[0-9a-f]{40,64}")
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")
OPERATION_ALLOWLIST = {
    "git.commit": {"commit_reviewed_patch"},
    "git.push": {"push_reviewed_commit"},
    "github.issue.create": {"ensure_feature_issue"},
    "github.issue.update": {
        "transition_issue_ready",
        "transition_issue_in_progress",
        "transition_issue_in_review",
    },
    "github.issue.comment": {"publish_exact_issue_comment"},
    "github.project.update": {
        "transition_project_ready",
        "transition_project_in_progress",
        "transition_project_in_review",
    },
    "github.pr.create": {"create_pull_request"},
    "github.pr.update": {"update_exact_pull_request"},
    "github.pr.comment": {"publish_exact_pr_comment"},
    "github.evidence.publish": {
        "publish_pr_evidence",
        "publish_testflight_upload_evidence",
        "publish_testflight_distribution_evidence",
    },
    "github.checks.wait": {"wait_required_checks"},
    "apple.testflight.upload": {"upload_verified_archive"},
    "apple.testflight.processing.wait": {"wait_bounded_processing"},
    "apple.testflight.distribute_internal": {"distribute_named_internal_group"},
    "apple.testflight.readback": {
        "verify_uploaded_build",
        "verify_internal_distribution",
    },
}


def _exact_keys(value: Any, expected: set[str]) -> bool:
    return isinstance(value, dict) and set(value) == expected


def _full_sha256(value: Any) -> bool:
    return isinstance(value, str) and HEX_SHA256.fullmatch(value) is not None


def _safe_ref(value: Any) -> bool:
    """Conservative branch/ref validation without invoking Git."""
    if not isinstance(value, str) or not value or value.startswith(('/', '-')):
        return False
    if value.endswith(('/', '.lock')) or '..' in value or '@{' in value:
        return False
    return re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", value) is not None


def _operation_input_errors(
    envelope: dict[str, Any], action: Any, operation: Any, value: Any
) -> list[str]:
    """Reject descriptors that could hide a broader write than their operation name."""
    if not isinstance(value, dict):
        return [f"operation input must be an object: {operation}"]
    repository = envelope.get("repository") or {}
    limits = envelope.get("limits") or {}
    apple = envelope.get("apple") or {}
    errors: list[str] = []

    issue_states = {
        "transition_issue_ready": "Ready",
        "transition_issue_in_progress": "In Progress",
        "transition_issue_in_review": "In Review",
    }
    project_states = {
        "transition_project_ready": "Ready",
        "transition_project_in_progress": "In Progress",
        "transition_project_in_review": "In Review",
    }
    evidence_policies = {
        "publish_pr_evidence": "sanitized_pr_evidence",
        "publish_testflight_upload_evidence": "sanitized_testflight_upload_evidence",
        "publish_testflight_distribution_evidence": "sanitized_testflight_distribution_evidence",
    }

    if operation in issue_states:
        if value != {"state": issue_states[operation]}:
            errors.append(f"Issue transition descriptor drifted: {operation}")
    elif operation in project_states:
        if not _exact_keys(value, {"state", "field_id", "option_id"}):
            errors.append(f"Project transition descriptor has unsupported fields: {operation}")
        elif (
            value.get("state") != project_states[operation]
            or not isinstance(value.get("field_id"), str)
            or not value.get("field_id")
            or not isinstance(value.get("option_id"), str)
            or not value.get("option_id")
        ):
            errors.append(f"Project transition descriptor drifted: {operation}")
    elif operation == "commit_reviewed_patch":
        paths = value.get("paths")
        if (
            not _exact_keys(value, {"message_policy", "paths"})
            or value.get("message_policy") != "reviewed_patch"
            or not _nonempty_strings(paths)
            or any(not _path_allowed(path, envelope.get("allowed_paths", [])) for path in paths or [])
        ):
            errors.append("commit descriptor must bind reviewed_patch and exact authorized paths")
    elif operation == "push_reviewed_commit":
        if value != {"branch": repository.get("branch"), "force": False}:
            errors.append("push descriptor must bind the authorized branch with force false")
    elif operation == "ensure_feature_issue":
        if value != {"title_policy": "accepted_plan", "body_policy": "accepted_plan"}:
            errors.append("feature Issue descriptor must use the accepted-plan policy")
    elif operation == "create_pull_request":
        if (
            not _exact_keys(value, {"base_ref", "head", "body_policy", "draft"})
            or not _safe_ref(value.get("base_ref"))
            or value.get("head") != repository.get("branch")
            or value.get("base_ref") == value.get("head")
            or value.get("body_policy") != "evidence_backed_current_run"
            or value.get("draft") is not False
        ):
            errors.append("pull-request descriptor must bind a safe base, authorized head, evidence body, and draft false")
    elif operation in {"publish_exact_issue_comment", "publish_exact_pr_comment"}:
        if not _exact_keys(value, {"body_sha256"}) or not _full_sha256(value.get("body_sha256")):
            errors.append(f"exact comment descriptor must bind body_sha256: {operation}")
    elif operation == "update_exact_pull_request":
        if (
            not _exact_keys(value, {"title_sha256", "body_sha256"})
            or not _full_sha256(value.get("title_sha256"))
            or not _full_sha256(value.get("body_sha256"))
        ):
            errors.append("exact pull-request update must bind title and body SHA-256")
    elif operation in evidence_policies:
        if value != {"artifact_policy": evidence_policies[operation]}:
            errors.append(f"evidence publication descriptor drifted: {operation}")
    elif operation == "wait_required_checks":
        if value != {
            "policy": "all_required",
            "timeout_minutes": limits.get("async_wait_minutes"),
        }:
            errors.append("required-check wait must use all_required and the authorized async bound")
    elif operation == "upload_verified_archive":
        if value != {"artifact_policy": "fresh_archive_from_reviewed_pr_commit"}:
            errors.append("TestFlight upload descriptor drifted")
    elif operation == "wait_bounded_processing":
        if value != {
            "timeout_minutes": limits.get("async_wait_minutes"),
            "max_transient_retries": limits.get("max_transient_retries"),
        }:
            errors.append("processing wait descriptor exceeds or drifts from authorization bounds")
    elif operation == "verify_uploaded_build":
        if value != {"readback": "uploaded_build"}:
            errors.append("upload read-back descriptor drifted")
    elif operation == "distribute_named_internal_group":
        groups = apple.get("internal_group_ids") or []
        if not _exact_keys(value, {"group_id"}) or value.get("group_id") not in groups:
            errors.append("distribution descriptor is outside the named internal group")
    elif operation == "verify_internal_distribution":
        groups = apple.get("internal_group_ids") or []
        if (
            not _exact_keys(value, {"readback", "group_id"})
            or value.get("readback") != "internal_group_build"
            or value.get("group_id") not in groups
        ):
            errors.append("distribution read-back descriptor drifted")
    else:
        errors.append(f"operation input semantics are unavailable: {operation}")

    if operation not in OPERATION_ALLOWLIST.get(action, set()):
        errors.append(f"operation is not allowed for action {action}: {operation}")
    return errors


def _timestamp(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp has no timezone")
    return parsed


def _safe_relative_path(value: str) -> bool:
    path = Path(value)
    return bool(value) and not path.is_absolute() and ".." not in path.parts


def _path_allowed(path: str, allowed_paths: list[str]) -> bool:
    if not _safe_relative_path(path):
        return False
    for allowed in allowed_paths:
        prefix = allowed.rstrip("/")
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def authorization_hash(envelope: dict[str, Any]) -> str:
    encoded = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def sanitize_remote(remote: str) -> str:
    """Remove URL userinfo before hashing, comparing, or recording a remote."""
    if "://" not in remote:
        return remote
    parsed = urllib.parse.urlsplit(remote)
    hostname = parsed.hostname
    if hostname is None:
        return remote
    host = f"[{hostname}]" if ":" in hostname else hostname
    if parsed.port is not None:
        host = f"{host}:{parsed.port}"
    return urllib.parse.urlunsplit((parsed.scheme, host, parsed.path, "", ""))


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def repository_fingerprint(canonical_root: str, remote: str) -> str:
    material = f"{canonical_root}\0{sanitize_remote(remote)}".encode()
    return "sha256:" + hashlib.sha256(material).hexdigest()


def _github_slug(remote: str) -> str | None:
    for prefix in ("https://github.com/", "git@github.com:"):
        if remote.startswith(prefix):
            slug = remote[len(prefix):]
            if slug.endswith(".git"):
                slug = slug[:-4]
            if re.fullmatch(r"[^/]+/[^/]+", slug):
                return slug
    return None


def canonical_lease_resource_key(envelope: dict[str, Any], action: str) -> str:
    repository = envelope.get("repository") or {}
    github = envelope.get("github") or {}
    if action == "git.commit":
        return ":".join(
            (
                "source_checkout_writer",
                str(repository.get("fingerprint")),
                str(repository.get("canonical_root")),
            )
        )
    if action == "git.push" or action.startswith("github."):
        return ":".join(
            (
                "github_external_mutation",
                str(repository.get("fingerprint")),
                f"{github.get('owner')}/{github.get('repository')}",
            )
        )
    if action.startswith("apple."):
        apple = envelope.get("apple") or {}
        return ":".join(
            (
                "signing_or_app_store_connect",
                str(apple.get("account_guard_ref")),
                str(apple.get("app_id") or apple.get("bundle_id")),
            )
        )
    raise ValueError(f"cannot derive a resource key for action {action!r}")


def observe_repository(root: Path, expected_base_sha: str) -> dict[str, Any]:
    if root.is_symlink():
        raise ValueError("authoritative repository root cannot be a symlink")
    canonical = root.resolve(strict=True)

    def git(*arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(canonical), *arguments],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        return result.stdout.strip()

    def git_bytes(*arguments: str) -> bytes:
        result = subprocess.run(
            ["git", "-C", str(canonical), *arguments],
            check=True,
            capture_output=True,
            timeout=15,
        )
        return result.stdout

    top = Path(git("rev-parse", "--show-toplevel")).resolve(strict=True)
    if top != canonical:
        raise ValueError("authoritative root is not the exact Git top level")
    remote = sanitize_remote(git("remote", "get-url", "origin"))
    branch = git("branch", "--show-current")
    if not branch:
        raise ValueError("authoritative repository is in detached HEAD state")
    git("cat-file", "-e", f"{expected_base_sha}^{{commit}}")
    ancestor = subprocess.run(
        ["git", "-C", str(canonical), "merge-base", "--is-ancestor", expected_base_sha, "HEAD"],
        capture_output=True,
        timeout=15,
    )
    if ancestor.returncode != 0:
        raise ValueError("authorized base SHA is not an ancestor of current HEAD")
    canonical_string = str(canonical)
    staged_diff = git_bytes("diff", "--cached", "--binary")
    staged_paths = [
        item.decode("utf-8")
        for item in git_bytes("diff", "--cached", "--name-only", "-z").split(b"\0")
        if item
    ]
    outgoing_paths = [
        item.decode("utf-8")
        for item in git_bytes("diff", "--name-only", "-z", f"{expected_base_sha}..HEAD").split(b"\0")
        if item
    ]
    return {
        "fingerprint": repository_fingerprint(canonical_string, remote),
        "canonical_root": canonical_string,
        "remote": remote,
        "base_sha": expected_base_sha,
        "branch": branch,
        "head_sha": git("rev-parse", "HEAD"),
        "staged_paths": staged_paths,
        "staged_diff_sha256": hashlib.sha256(staged_diff).hexdigest(),
        "outgoing_paths": outgoing_paths,
    }


def validate_policy_overlay(envelope: dict[str, Any], overlay: Any) -> list[str]:
    errors: list[str] = []
    fields = {"schema_version", "decision", "github", "apple"}
    errors.extend(_object_shape(overlay, fields, fields, "private policy overlay"))
    if not isinstance(overlay, dict):
        return errors
    if overlay.get("schema_version") != "1.0.0" or overlay.get("decision") != "approved":
        errors.append("private policy overlay is not approved")
    github = overlay.get("github")
    if not isinstance(github, dict) or set(github) != {"owner"} or not github.get("owner"):
        errors.append("private policy overlay must bind one GitHub owner")
    elif github.get("owner") != envelope.get("github", {}).get("owner"):
        errors.append("GitHub owner differs from the private policy boundary")
    apple = envelope.get("apple")
    trusted_apple = overlay.get("apple")
    if apple is not None and (
        not isinstance(trusted_apple, dict)
        or set(trusted_apple) != {"account_guard_ref", "team_id"}
        or trusted_apple.get("account_guard_ref") != apple.get("account_guard_ref")
        or trusted_apple.get("team_id") != apple.get("team_id")
    ):
        errors.append("Apple account or team differs from the private policy boundary")
    return errors


def _object_shape(value: Any, required: set[str], allowed: set[str], label: str) -> list[str]:
    if not isinstance(value, dict):
        return [f"{label} must be an object"]
    errors: list[str] = []
    missing = required - set(value)
    extra = set(value) - allowed
    if missing:
        errors.append(f"{label} is missing fields: {', '.join(sorted(missing))}")
    if extra:
        errors.append(f"{label} has unsupported fields: {', '.join(sorted(extra))}")
    return errors


def _schema_type(value: Any, name: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }.get(name, False)


def _schema_errors(instance: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    """Validate the dependency-free JSON Schema subset used by this installed skill."""
    errors: list[str] = []
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(isinstance(name, str) and _schema_type(instance, name) for name in names):
            return [f"{path}: expected type {schema['type']!r}"]
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: must equal {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: must be one of {schema['enum']!r}")
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{path}: string is shorter than minLength")
        if schema.get("format") == "date-time":
            try:
                _timestamp(instance)
            except ValueError:
                errors.append(f"{path}: must be a timezone-aware date-time")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            errors.append(f"{path}: does not match the required pattern")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: is below the minimum")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: contains too few items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            errors.append(f"{path}: contains too many items")
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in instance}) != len(instance):
            errors.append(f"{path}: items must be unique")
        if isinstance(schema.get("items"), dict):
            for index, item in enumerate(instance):
                errors.extend(_schema_errors(item, schema["items"], f"{path}[{index}]"))
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        if schema.get("additionalProperties") is False:
            errors.extend(
                f"{path}: additional property {key!r} is forbidden"
                for key in instance if key not in properties
            )
        elif isinstance(schema.get("additionalProperties"), dict):
            for key in instance:
                if key not in properties:
                    errors.extend(_schema_errors(instance[key], schema["additionalProperties"], f"{path}.{key}"))
        for key, child in properties.items():
            if key in instance and isinstance(child, dict):
                errors.extend(_schema_errors(instance[key], child, f"{path}.{key}"))
    for child in schema.get("allOf", []):
        errors.extend(_schema_errors(instance, child, path))
    if "oneOf" in schema:
        matches = sum(not _schema_errors(instance, child, path) for child in schema["oneOf"])
        if matches != 1:
            errors.append(f"{path}: must match exactly one oneOf branch")
    if "not" in schema and not _schema_errors(instance, schema["not"], path):
        errors.append(f"{path}: matches a forbidden schema")
    if "if" in schema:
        branch = "then" if not _schema_errors(instance, schema["if"], path) else "else"
        if isinstance(schema.get(branch), dict):
            errors.extend(_schema_errors(instance, schema[branch], path))
    return errors


def _nonempty_strings(values: Any) -> bool:
    return (
        isinstance(values, list) and bool(values)
        and all(isinstance(item, str) and bool(item) for item in values)
        and len(values) == len(set(values))
    )


def _apple_grant_errors(envelope: dict[str, Any], grants: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    target = envelope.get("delivery_target")
    apple = envelope.get("apple")
    apple_grants = [grant for grant in grants if grant.get("system") == "apple"]
    if target == "pr_ready":
        if apple is not None or apple_grants:
            errors.append("pr_ready authorization cannot bind or grant Apple actions")
        return errors
    if not isinstance(apple, dict):
        return ["TestFlight authorization must bind the exact Apple target"]
    fields = set(APPLE_FIELDS) | {"internal_group_ids"}
    errors.extend(_object_shape(apple, fields, fields, "Apple authorization"))
    if any(not apple.get(key) for key in APPLE_FIELDS):
        errors.append("TestFlight authorization has an empty Apple binding")
    if apple.get("platform") not in {"ios", "ipados", "watchos", "macos"}:
        errors.append("TestFlight authorization platform is invalid")
    if apple.get("artifact_policy") != "fresh_archive_from_reviewed_pr_commit":
        errors.append("TestFlight artifact policy drifted")
    groups = apple.get("internal_group_ids")
    if not isinstance(groups, list) or any(not isinstance(item, str) or not item for item in groups):
        errors.append("TestFlight internal group IDs must be a string list")
        groups = []
    if len(groups) != len(set(groups)):
        errors.append("TestFlight internal group IDs must be unique")
    if len(groups) > 1:
        errors.append("authorization schema v1 supports one exact internal group per run")
    if target == "testflight_uploaded" and groups:
        errors.append("upload-only authorization cannot bind distribution groups")
    if target == "testflight_distributed" and not groups:
        errors.append("internal distribution must name at least one exact group ID")
    app_id = apple.get("app_id")
    expected = Counter({
        ("apple.testflight.upload", f"app:{app_id}"): 1,
        ("apple.testflight.processing.wait", f"app:{app_id}:processing"): 1,
        ("apple.testflight.readback", f"app:{app_id}:upload"): 1,
    })
    if target == "testflight_distributed":
        for group_id in groups:
            expected[("apple.testflight.distribute_internal", f"app:{app_id}:group:{group_id}")] += 1
            expected[("apple.testflight.readback", f"app:{app_id}:group:{group_id}")] += 1
    observed: Counter[tuple[Any, Any]] = Counter()
    for grant in apple_grants:
        if grant.get("target_from_grant_id"):
            errors.append("Apple grants must bind direct app/build/group targets")
        observed[(grant.get("action"), grant.get("target"))] += 1
    if observed != expected:
        errors.append("TestFlight grants do not exactly match the selected target and groups")
    return errors


def _repository_grant_errors(envelope: dict[str, Any], grants: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    repository = envelope.get("repository") or {}
    github = envelope.get("github") or {}
    repo_slug = f"{github.get('owner')}/{github.get('repository')}"
    branch = repository.get("branch")
    fingerprint = repository.get("fingerprint")
    canonical_targets = {
        "git.commit": f"{fingerprint}:{branch}",
        "git.push": f"{repo_slug}:{branch}",
        "github.pr.create": f"{repo_slug}:{branch}",
        "github.issue.create": f"{repo_slug}:feature:{branch}",
    }
    remote = str(repository.get("remote", ""))
    if _github_slug(remote) != repo_slug:
        errors.append("repository remote does not match the bound GitHub owner/repository")
    issue_number = github.get("issue_number")
    project = github.get("project")
    by_id = {grant.get("grant_id"): grant for grant in grants}
    consumer_kinds = {
        "github.issue.update": "github_issue",
        "github.issue.comment": "github_issue",
        "github.pr.update": "github_pr",
        "github.pr.comment": "github_pr",
        "github.evidence.publish": "github_pr",
        "github.checks.wait": "github_pr",
    }
    for grant in grants:
        action = grant.get("action")
        target = grant.get("target")
        if action in canonical_targets and target != canonical_targets[action]:
            errors.append(f"grant target does not match the bound repository: {action}")
        if action == "github.issue.create" and grant.get("produces_target_kind") != "github_issue":
            errors.append("Issue create grant must declare a GitHub Issue output")
        if action == "github.pr.create" and grant.get("produces_target_kind") != "github_pr":
            errors.append("PR create grant must declare a GitHub PR output")
        expected_kind = consumer_kinds.get(action)
        if expected_kind:
            source_id = grant.get("target_from_grant_id")
            if source_id:
                source = by_id.get(source_id)
                if not source or source.get("produces_target_kind") != expected_kind:
                    errors.append(f"derived GitHub target has the wrong object kind: {action}")
            elif expected_kind == "github_issue":
                expected = f"{repo_slug}:issue:{issue_number}" if issue_number else None
                if expected is None or target != expected:
                    errors.append(f"Issue grant must bind a known exact Issue or a derived target: {action}")
            elif not re.fullmatch(rf"{re.escape(repo_slug)}:pr:[1-9][0-9]*", str(target)):
                errors.append(f"PR grant must bind an exact PR in the authorized repository: {action}")
        if action == "github.project.update":
            project_id = project.get("id") if isinstance(project, dict) else None
            if not project_id or target != f"{repo_slug}:project:{project_id}" or grant.get("target_from_grant_id"):
                errors.append("Project grant must bind the exact configured Project")
    return errors


def _valid_produced_target(kind: Any, target: Any, repo_slug: str) -> bool:
    patterns = {
        "github_issue": rf"{re.escape(repo_slug)}:issue:[1-9][0-9]*",
        "github_pr": rf"{re.escape(repo_slug)}:pr:[1-9][0-9]*",
    }
    pattern = patterns.get(kind)
    return isinstance(target, str) and pattern is not None and re.fullmatch(pattern, target) is not None


def _green_path_grant_errors(envelope: dict[str, Any], grants: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    actions = Counter(grant.get("action") for grant in grants)
    for action in ("git.commit", "git.push", "github.pr.create", "github.checks.wait"):
        if actions[action] != 1:
            errors.append(f"delivery authorization requires exactly one {action} grant")
    pr_create = [grant for grant in grants if grant.get("action") == "github.pr.create"]
    if len(pr_create) == 1:
        pr_source_id = pr_create[0].get("grant_id")
        for grant in grants:
            if grant.get("action") in {
                "github.pr.update",
                "github.pr.comment",
                "github.evidence.publish",
                "github.checks.wait",
            } and grant.get("target_from_grant_id") != pr_source_id:
                errors.append(
                    f"PR consumer grant must derive the PR created by this run: {grant.get('grant_id')}"
                )
    target = envelope.get("delivery_target")
    expected_evidence = {
        "pr_ready": 1,
        "testflight_uploaded": 2,
        "testflight_distributed": 3,
    }.get(target, 0)
    if actions["github.evidence.publish"] != expected_evidence:
        errors.append("delivery authorization has the wrong evidence-publication grant count")
    evidence_operations = {
        (grant.get("operation"), grant.get("phase"))
        for grant in grants if grant.get("action") == "github.evidence.publish"
    }
    expected_evidence_operations = {
        ("publish_pr_evidence", "pr_delivery"),
    }
    if target in {"testflight_uploaded", "testflight_distributed"}:
        expected_evidence_operations.add(
            ("publish_testflight_upload_evidence", "testflight_upload")
        )
    if target == "testflight_distributed":
        expected_evidence_operations.add(
            ("publish_testflight_distribution_evidence", "testflight_distribution")
        )
    if evidence_operations != expected_evidence_operations:
        errors.append("evidence grants must bind the exact delivery phase and publication operation")
    github = envelope.get("github") or {}
    issue_number = github.get("issue_number")
    issue_create = [grant for grant in grants if grant.get("action") == "github.issue.create"]
    issue_updates = [grant for grant in grants if grant.get("action") == "github.issue.update"]
    if issue_number is None:
        if len(issue_create) != 1 or len(issue_updates) != 2:
            errors.append("a new feature Issue requires one create and two state-update grants")
        elif any(
            grant.get("target_from_grant_id") != issue_create[0].get("grant_id")
            for grant in issue_updates
        ):
            errors.append("new Issue state grants must derive from the Issue create grant")
        expected_issue_operations = {
            "transition_issue_in_progress",
            "transition_issue_in_review",
        }
    elif issue_create or len(issue_updates) != 3:
        errors.append("an existing feature Issue requires exactly three state-update grants")
        expected_issue_operations = {
            "transition_issue_ready",
            "transition_issue_in_progress",
            "transition_issue_in_review",
        }
    else:
        expected_issue_operations = {
            "transition_issue_ready",
            "transition_issue_in_progress",
            "transition_issue_in_review",
        }
    if {
        grant.get("operation") for grant in issue_updates
    } != expected_issue_operations:
        errors.append("Issue update grants must bind the exact authorized state transitions")
    project = github.get("project")
    expected_project_updates = 3 if project is not None else 0
    if actions["github.project.update"] != expected_project_updates:
        errors.append("Project tracking grants do not match the selected Project configuration")
    project_updates = [grant for grant in grants if grant.get("action") == "github.project.update"]
    if project is not None and {
        grant.get("operation") for grant in project_updates
    } != {
        "transition_project_ready",
        "transition_project_in_progress",
        "transition_project_in_review",
    }:
        errors.append("Project grants must bind the exact Ready, In Progress, and In Review transitions")
    return errors


def validate_authorization(envelope: dict[str, Any]) -> list[str]:
    errors = _object_shape(envelope, TOP_LEVEL_FIELDS, TOP_LEVEL_FIELDS | {"$schema"}, "authorization")
    if envelope.get("schema_version") != "1.0.0":
        errors.append("unsupported authorization schema")
    if envelope.get("decision") != "approved":
        errors.append("authorization is not approved")
    for field in ("run_id", "authorization_id", "actor"):
        if not isinstance(envelope.get(field), str) or not envelope.get(field):
            errors.append(f"authorization {field} must be a non-empty string")
    if envelope.get("delivery_target") not in {"pr_ready", "testflight_uploaded", "testflight_distributed"}:
        errors.append("unsupported delivery target")
    repository = envelope.get("repository")
    errors.extend(_object_shape(repository, set(REPOSITORY_FIELDS), set(REPOSITORY_FIELDS), "repository authorization"))
    if isinstance(repository, dict) and any(not repository.get(key) for key in REPOSITORY_FIELDS):
        errors.append("authorization must bind the exact repository and branch")
    if isinstance(repository, dict) and isinstance(repository.get("remote"), str):
        if sanitize_remote(repository["remote"]) != repository["remote"]:
            errors.append("authorization repository remote must not contain URL credentials")
    try:
        issued = _timestamp(str(envelope.get("issued_at", "")))
        expires = _timestamp(str(envelope.get("expires_at", "")))
        if expires <= issued:
            errors.append("authorization expiry must be after issuance")
    except ValueError:
        errors.append("authorization issue or expiry time is invalid or lacks timezone")
    if not _nonempty_strings(envelope.get("acceptance_ids")):
        errors.append("authorization requires unique acceptance IDs")
    allowed_paths = envelope.get("allowed_paths")
    if not _nonempty_strings(allowed_paths):
        errors.append("authorization requires unique allowed paths")
        allowed_paths = []
    if any(not _safe_relative_path(path) for path in allowed_paths):
        errors.append("authorization allowed paths must be safe repository-relative paths")
    limits = envelope.get("limits")
    errors.extend(_object_shape(limits, set(LIMIT_MINIMUMS), set(LIMIT_MINIMUMS), "limits"))
    if not isinstance(limits, dict) or any(
        not isinstance(limits.get(field), int) or isinstance(limits.get(field), bool)
        or limits.get(field) < minimum for field, minimum in LIMIT_MINIMUMS.items()
    ):
        errors.append("authorization attempt and time limits are invalid")
    github = envelope.get("github")
    github_fields = {"owner", "repository", "issue_number", "project"}
    errors.extend(_object_shape(github, github_fields, github_fields, "GitHub authorization"))
    if not isinstance(github, dict) or not github.get("owner") or not github.get("repository"):
        errors.append("authorization must bind the GitHub repository")
    spec_kit = envelope.get("spec_kit")
    if spec_kit is not None:
        spec_fields = {
            "release", "feature_id", "feature_directory", "approved_git_branch",
            "snapshot_sha256", "artifact_hashes", "workflow_run_id",
        }
        errors.extend(_object_shape(spec_kit, spec_fields, spec_fields, "Spec Kit binding"))
        if (
            not isinstance(spec_kit, dict) or spec_kit.get("release") != "v1.0.1"
            or any(not spec_kit.get(key) for key in spec_fields - {"artifact_hashes"})
            or not isinstance(spec_kit.get("artifact_hashes"), dict)
            or not spec_kit.get("artifact_hashes")
        ):
            errors.append("Spec Kit authorization binding is invalid")
        elif isinstance(repository, dict) and spec_kit.get("approved_git_branch") != repository.get("branch"):
            errors.append("Spec Kit accepted branch mapping drifted from repository binding")
    grants = envelope.get("action_grants")
    if not isinstance(grants, list) or not grants:
        errors.append("authorization requires at least one action grant")
        grants = []
    grant_ids: set[str] = set()
    idempotency_keys: set[str] = set()
    for grant in grants:
        if not isinstance(grant, dict):
            errors.append("action grants must be objects")
            continue
        fields = {
            "grant_id", "system", "action", "operation", "operation_input", "constraint_sha256",
            "resource_key", "target", "target_from_grant_id", "produces_target_kind",
            "phase", "single_use", "idempotency_key",
        }
        required = {
            "grant_id", "system", "action", "operation", "operation_input", "constraint_sha256",
            "resource_key", "phase", "single_use", "idempotency_key",
        }
        errors.extend(_object_shape(grant, required, fields, "action grant"))
        grant_id, key = grant.get("grant_id"), grant.get("idempotency_key")
        action, system = grant.get("action"), grant.get("system")
        has_target = isinstance(grant.get("target"), str) and bool(grant.get("target"))
        has_derived = isinstance(grant.get("target_from_grant_id"), str) and bool(grant.get("target_from_grant_id"))
        if has_target == has_derived:
            errors.append(f"action grant must bind one direct or derived target: {grant_id}")
        if action not in ALLOWED_ACTIONS or action in FORBIDDEN_ACTIONS:
            errors.append(f"action grant is not allowlisted: {action}")
        operation = grant.get("operation")
        if operation not in OPERATION_ALLOWLIST.get(action, set()):
            errors.append(f"action grant operation is not allowlisted for {action}: {operation}")
        if not isinstance(grant.get("operation_input"), dict) or not grant.get("operation_input"):
            errors.append(f"action grant operation input is invalid: {grant_id}")
        elif canonical_sha256(grant["operation_input"]) != grant.get("constraint_sha256"):
            errors.append(f"action grant operation input does not match its constraint: {grant_id}")
        else:
            errors.extend(
                f"action grant {grant_id}: {error}"
                for error in _operation_input_errors(
                    envelope, action, operation, grant["operation_input"]
                )
            )
        if not isinstance(grant.get("constraint_sha256"), str) or not HEX_SHA256.fullmatch(grant["constraint_sha256"]):
            errors.append(f"action grant constraint digest is invalid: {grant_id}")
        try:
            expected_resource_key = canonical_lease_resource_key(envelope, str(action))
            if grant.get("resource_key") != expected_resource_key:
                errors.append(f"action grant resource key is not canonical: {grant_id}")
        except ValueError:
            errors.append(f"action grant resource key cannot be derived: {grant_id}")
        if system not in {"git", "github", "apple"} or (isinstance(action, str) and system != action.split(".", 1)[0]):
            errors.append(f"action grant system does not match action: {grant_id}")
        if grant.get("single_use") is not True:
            errors.append(f"action grant must be single use: {grant_id}")
        if grant.get("produces_target_kind") and action not in {"github.issue.create", "github.pr.create"}:
            errors.append(f"only a GitHub create grant may produce a target: {grant_id}")
        phase = grant.get("phase")
        if phase not in {"pr_delivery", "testflight_upload", "testflight_distribution"}:
            errors.append(f"action grant phase is invalid: {grant_id}")
        if system in {"git", "github"} and action != "github.evidence.publish" and phase != "pr_delivery":
            errors.append(f"repository delivery action must use the pr_delivery phase: {grant_id}")
        if str(action).startswith("apple."):
            expected_phase = (
                "testflight_distribution"
                if action == "apple.testflight.distribute_internal"
                or (action == "apple.testflight.readback" and ":group:" in str(grant.get("target", "")))
                else "testflight_upload"
            )
            if phase != expected_phase:
                errors.append(f"Apple action is bound to the wrong continuation phase: {grant_id}")
        if not isinstance(grant_id, str) or not grant_id or grant_id in grant_ids:
            errors.append(f"action grant IDs must be non-empty and unique: {grant_id}")
        if not isinstance(key, str) or not key or key in idempotency_keys:
            errors.append(f"idempotency keys must be non-empty and unique: {key}")
        grant_ids.add(grant_id)
        idempotency_keys.add(key)
    by_id = {grant.get("grant_id"): grant for grant in grants if isinstance(grant, dict)}
    for grant in grants:
        if not isinstance(grant, dict) or not grant.get("target_from_grant_id"):
            continue
        source = by_id.get(grant["target_from_grant_id"])
        if source is None or not source.get("produces_target_kind"):
            errors.append(f"derived target has no producing grant: {grant.get('grant_id')}")
        if grant.get("target_from_grant_id") == grant.get("grant_id"):
            errors.append(f"action grant cannot derive its own target: {grant.get('grant_id')}")
    if set(envelope.get("forbidden_actions", [])) != FORBIDDEN_ACTIONS:
        errors.append("forbidden action boundary drifted")
    for flag in ("auto_merge", "app_review_submit", "credential_scope_expansion", "signing_resource_mutation", "destructive_cleanup"):
        if envelope.get(flag) is not False:
            errors.append(f"{flag} must remain false")
    errors.extend(_repository_grant_errors(envelope, grants))
    errors.extend(_green_path_grant_errors(envelope, grants))
    errors.extend(_apple_grant_errors(envelope, grants))
    return sorted(set(errors))


def _external_writes(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [record.get("payload", {}) for record in records if record.get("record_type") == "external_write" and isinstance(record.get("payload"), dict)]


def _standalone_ledger_lifecycle_errors(records: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    previous_sequence = 0
    previous_recorded_at: datetime | None = None
    run_id: str | None = None
    authorizations: dict[str, dict[str, Any]] = {}
    active: dict[tuple[Any, Any], dict[str, Any]] = {}
    reservations: dict[str, dict[str, Any]] = {}
    consumed_reservations: set[str] = set()
    used_grants: set[tuple[str, str]] = set()
    used_keys: set[tuple[str, str]] = set()
    produced_targets: dict[tuple[str, str], str] = {}
    passed_nodes: set[str] = set()
    successful_operations: set[tuple[str, str, str]] = set()
    contracts_root = Path(__file__).resolve().parents[1] / "contracts"
    try:
        main_workflow = json.loads((contracts_root / "workflow.json").read_text(encoding="utf-8"))
        continuation = json.loads(
            (contracts_root / "testflight-workflow.json").read_text(encoding="utf-8")
        )
        main_nodes = [node["id"] for node in main_workflow.get("nodes", [])]
        continuation_nodes = [node["id"] for node in continuation.get("nodes", [])]
        node_dependencies = {
            node["id"]: set(node.get("requires", []))
            for node in main_workflow.get("nodes", []) + continuation.get("nodes", [])
        }
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return ["installed workflow contracts are unavailable; refusing authorization"]
    for line_number, record in enumerate(records, 1):
        current_run_id = record.get("run_id")
        if run_id is None:
            run_id = current_run_id
        elif current_run_id != run_id:
            errors.append("ledger cannot mix run IDs")
        sequence = record.get("sequence")
        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= previous_sequence:
            errors.append(f"ledger sequence must strictly increase at line {line_number}")
        else:
            previous_sequence = sequence
        try:
            recorded_at = _timestamp(str(record.get("recorded_at", "")))
            if previous_recorded_at is not None and recorded_at < previous_recorded_at:
                errors.append(f"ledger recorded_at must be monotonic at line {line_number}")
            previous_recorded_at = recorded_at
        except ValueError:
            recorded_at = None
        record_type = record.get("record_type")
        payload = record.get("payload", {})
        if record_type == "approval" and payload.get("kind") == "run_authorization":
            digest = payload.get("authorization_hash")
            if payload.get("decision") != "approved" or not digest or digest in authorizations:
                errors.append("run authorization approval must be unique and approved")
            else:
                authorizations[digest] = payload
        elif record_type == "time_interval":
            if payload.get("authorization_hash") not in authorizations:
                errors.append("time interval must follow its run authorization")
            try:
                if _timestamp(str(payload.get("ended_at"))) <= _timestamp(str(payload.get("started_at"))):
                    errors.append("time interval must have positive duration")
            except ValueError:
                errors.append("time interval timestamps are invalid")
        elif record_type == "lease":
            key = (payload.get("resource"), payload.get("resource_key"))
            identity = (payload.get("lease_id"), payload.get("owner"))
            if payload.get("action") == "acquire":
                if key in active:
                    errors.append("ledger has duplicate active resource leases")
                else:
                    active[key] = dict(payload)
                try:
                    acquired_at = _timestamp(str(payload.get("acquired_at")))
                    expires_at = _timestamp(str(payload.get("expires_at")))
                    if expires_at <= acquired_at or (
                        recorded_at is not None and acquired_at > recorded_at
                    ):
                        errors.append("lease acquisition time range is invalid")
                except ValueError:
                    errors.append("lease acquisition timestamps are invalid")
            elif payload.get("action") == "release":
                current = active.get(key)
                if current is None or (current.get("lease_id"), current.get("owner")) != identity:
                    errors.append("lease release does not match its active lease")
                else:
                    del active[key]
            elif payload.get("action") == "heartbeat":
                current = active.get(key)
                if current is None or (current.get("lease_id"), current.get("owner")) != identity:
                    errors.append("lease heartbeat does not match its active lease")
                else:
                    try:
                        heartbeat = _timestamp(str(payload.get("heartbeat_at")))
                        old_expiry = _timestamp(str(current.get("expires_at")))
                        new_expiry = _timestamp(str(payload.get("expires_at")))
                        if heartbeat >= old_expiry or new_expiry <= old_expiry:
                            errors.append("lease heartbeat must be timely and extend expiry")
                        else:
                            current["expires_at"] = payload.get("expires_at")
                    except ValueError:
                        errors.append("lease heartbeat timestamps are invalid")
        elif record_type == "grant_reservation":
            digest = payload.get("authorization_hash")
            authorization = authorizations.get(digest)
            reservation_id = payload.get("reservation_id")
            grant_key = (str(digest), str(payload.get("grant_id")))
            idempotency_key = (str(digest), str(payload.get("idempotency_key")))
            if not reservation_id or reservation_id in reservations:
                errors.append("grant reservation ID must be unique")
            if not isinstance(payload.get("operation_input"), dict) or canonical_sha256(payload.get("operation_input")) != payload.get("constraint_sha256"):
                errors.append("grant reservation operation input drifted from its constraint")
            grant: dict[str, Any] | None = None
            if authorization is None:
                errors.append("grant reservation must follow its run authorization")
            else:
                candidates = [
                    candidate for candidate in authorization.get("action_grants", [])
                    if all(
                        candidate.get(field) == payload.get(field)
                        for field in (
                            "grant_id", "idempotency_key", "system", "action",
                            "operation", "operation_input", "constraint_sha256", "resource_key",
                            "phase",
                        )
                    )
                ]
                if len(candidates) != 1:
                    errors.append("grant reservation does not match one exact grant")
                else:
                    grant = candidates[0]
                    target = grant.get("target")
                    if grant.get("target_from_grant_id"):
                        target = produced_targets.get((str(digest), grant["target_from_grant_id"]))
                    if not target or payload.get("target") != target:
                        errors.append("grant reservation target is unavailable or drifted")
                try:
                    issued_at = _timestamp(str(authorization.get("issued_at")))
                    expires_at = _timestamp(str(authorization.get("expires_at")))
                    if recorded_at is None or not issued_at <= recorded_at < expires_at:
                        errors.append("grant reservation occurred outside authorization time bounds")
                except ValueError:
                    errors.append("grant reservation authorization time is invalid")
            lease = active.get((payload.get("resource"), payload.get("resource_key")))
            if (
                lease is None
                or lease.get("lease_id") != payload.get("lease_id")
                or lease.get("owner") != payload.get("lease_owner")
                or payload.get("action") not in lease.get("allowed_actions", [])
            ):
                errors.append("grant reservation lacks its exact active lease")
            else:
                try:
                    if recorded_at is None or recorded_at >= _timestamp(str(lease.get("expires_at"))):
                        errors.append("grant reservation cannot use an expired lease")
                except ValueError:
                    errors.append("grant reservation lease expiry is invalid")
            if grant_key in used_grants or idempotency_key in used_keys:
                errors.append("grant or idempotency key is already reserved")
            used_grants.add(grant_key)
            used_keys.add(idempotency_key)
            if reservation_id:
                reservations[reservation_id] = dict(payload)
        elif record_type == "external_write":
            reservation_id = payload.get("reservation_id")
            reservation = reservations.get(reservation_id)
            if reservation is None or reservation_id in consumed_reservations:
                errors.append("external write requires one unconsumed exact reservation")
            else:
                for field in (
                    "authorization_hash", "grant_id", "idempotency_key", "system",
                    "action", "operation", "operation_input", "constraint_sha256",
                    "resource_key", "phase", "lease_id", "lease_owner", "resource",
                    "target", "spec_checkpoint_sha256",
                    "apple_observation_sha256",
                ):
                    if reservation.get(field) != payload.get(field):
                        errors.append("external write drifted from its reservation")
                        break
                consumed_reservations.add(str(reservation_id))
            lease = active.get((payload.get("resource"), payload.get("resource_key")))
            if (
                lease is None
                or lease.get("lease_id") != payload.get("lease_id")
                or lease.get("owner") != payload.get("lease_owner")
                or payload.get("action") not in lease.get("allowed_actions", [])
            ):
                errors.append("external write requires its exact active reservation lease")
            digest = str(payload.get("authorization_hash"))
            authorization = authorizations.get(digest)
            if authorization is None:
                errors.append("external write must follow its run authorization")
            elif payload.get("outcome") == "succeeded":
                grant = next(
                    (
                        candidate for candidate in authorization.get("action_grants", [])
                        if candidate.get("grant_id") == payload.get("grant_id")
                    ),
                    None,
                )
                if grant and grant.get("produces_target_kind"):
                    repo_slug = str(grant.get("target", "")).split(":", 1)[0]
                    output = payload.get("output_target")
                    if not _valid_produced_target(grant.get("produces_target_kind"), output, repo_slug):
                        errors.append("external write produced an invalid GitHub target")
                    else:
                        produced_targets[(digest, str(payload.get("grant_id")))] = str(output)
                successful_operations.add(
                    (
                        str(payload.get("phase")),
                        str(payload.get("action")),
                        str(payload.get("operation")),
                    )
                )
            if authorization is not None:
                try:
                    issued_at = _timestamp(str(authorization.get("issued_at")))
                    expires_at = _timestamp(str(authorization.get("expires_at")))
                    if recorded_at is None or not issued_at <= recorded_at < expires_at:
                        errors.append("external write occurred outside authorization time bounds")
                except ValueError:
                    errors.append("external write authorization time is invalid")
            if lease is not None:
                try:
                    if recorded_at is None or recorded_at >= _timestamp(str(lease.get("expires_at"))):
                        errors.append("external write cannot use an expired lease")
                except ValueError:
                    errors.append("external write lease expiry is invalid")
        elif record_type == "node" and payload.get("status") == "passed":
            node_id = payload.get("node_id")
            if not isinstance(node_id, str) or node_id not in node_dependencies:
                errors.append("passed node is not present in the installed workflow contracts")
            else:
                if node_id == "bind_pr_ready" and "pr_ready" not in passed_nodes:
                    errors.append("TestFlight continuation cannot bind before pr_ready")
                if node_id in passed_nodes:
                    errors.append(f"workflow node cannot pass more than once: {node_id}")
                missing = node_dependencies[node_id] - passed_nodes
                if missing:
                    errors.append(
                        f"workflow node {node_id} passed before dependencies: "
                        + ", ".join(sorted(missing))
                    )
                passed_nodes.add(node_id)
            if node_id in {"pr_ready", "testflight_uploaded", "testflight_distributed"} and active:
                errors.append("terminal node cannot pass with an active lease")
            if node_id == "pr_ready":
                missing = set(main_nodes) - passed_nodes
                if missing:
                    errors.append("pr_ready requires every installed main-workflow node")
                matching = [
                    item
                    for item in authorizations.values()
                    if item.get("delivery_target")
                    in {"pr_ready", "testflight_uploaded", "testflight_distributed"}
                ]
                if len(matching) != 1:
                    errors.append("pr_ready requires one exact run authorization")
                else:
                    required_operations = {
                        (
                            str(grant.get("phase")),
                            str(grant.get("action")),
                            str(grant.get("operation")),
                        )
                        for grant in matching[0].get("action_grants", [])
                        if grant.get("phase") == "pr_delivery"
                    }
                    if required_operations - successful_operations:
                        errors.append("pr_ready requires every authorized delivery operation")
            if node_id == "testflight_uploaded":
                cutoff = continuation_nodes.index("testflight_uploaded") + 1
                if set(continuation_nodes[:cutoff]) - passed_nodes:
                    errors.append("testflight_uploaded requires every upload-continuation node")
            if node_id == "testflight_distributed" and set(continuation_nodes) - passed_nodes:
                errors.append("testflight_distributed requires every continuation node")
        elif record_type == "stop" and active:
            errors.append("terminal stop cannot leave an active lease")
    return errors


def _ledger_contract_errors(records: list[dict[str, Any]]) -> list[str]:
    schema_path = Path(__file__).resolve().parents[1] / "contracts" / "schemas" / "ledger-record.schema.json"
    if not schema_path.is_file():
        return ["installed ledger schema is unavailable; refusing authorization"]
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    for index, record in enumerate(records, 1):
        errors.extend(
            f"ledger schema line {index}: {error}"
            for error in _schema_errors(record, schema)
        )
    errors.extend(_standalone_ledger_lifecycle_errors(records))
    return sorted(set(errors))


def _active_leases(
    records: list[dict[str, Any]],
) -> tuple[dict[tuple[Any, Any], dict[str, Any]], list[str]]:
    active: dict[tuple[Any, Any], dict[str, Any]] = {}
    errors: list[str] = []
    for record in records:
        if record.get("record_type") != "lease" or not isinstance(record.get("payload"), dict):
            continue
        payload = record["payload"]
        key = (payload.get("resource"), payload.get("resource_key"))
        if payload.get("action") == "acquire":
            if key in active:
                errors.append("ledger lease replay found a duplicate acquire")
            else:
                active[key] = dict(payload)
        elif payload.get("action") == "heartbeat":
            current = active.get(key)
            if (
                current is None
                or current.get("lease_id") != payload.get("lease_id")
                or current.get("owner") != payload.get("owner")
            ):
                errors.append("ledger lease heartbeat does not match an active lease")
                continue
            try:
                heartbeat_at = _timestamp(str(payload.get("heartbeat_at", "")))
                previous_expiry = _timestamp(str(current.get("expires_at", "")))
                new_expiry = _timestamp(str(payload.get("expires_at", "")))
                if heartbeat_at >= previous_expiry or new_expiry <= previous_expiry or new_expiry <= heartbeat_at:
                    errors.append("ledger lease heartbeat must be timely and extend expiry monotonically")
                else:
                    current["heartbeat_at"] = payload.get("heartbeat_at")
                    current["expires_at"] = payload.get("expires_at")
            except ValueError:
                errors.append("ledger lease heartbeat has invalid timestamps")
        elif payload.get("action") == "release":
            current = active.get(key)
            if (
                current is None
                or current.get("lease_id") != payload.get("lease_id")
                or current.get("owner") != payload.get("owner")
            ):
                errors.append("ledger lease release does not match an active lease")
            else:
                del active[key]
    return active, errors


def _expected_lease_resource(action: Any) -> str | None:
    if action == "git.commit":
        return "source_checkout_writer"
    if action == "git.push" or str(action).startswith("github."):
        return "github_external_mutation"
    if str(action).startswith("apple."):
        return "signing_or_app_store_connect"
    return None


def _ledger_limit_errors(
    envelope: dict[str, Any], records: list[dict[str, Any]], now: datetime
) -> list[str]:
    errors: list[str] = []
    limits = envelope.get("limits", {})
    expected_hash = authorization_hash(envelope)
    attempts = [
        record.get("payload", {})
        for record in records
        if record.get("record_type") == "attempt"
        and isinstance(record.get("payload"), dict)
        and record.get("run_id") == envelope.get("run_id")
        and record["payload"].get("authorization_hash") == expected_hash
    ]
    implementation_attempts = sum(item.get("phase") == "implementation" for item in attempts)
    review_cycles = sum(item.get("phase") == "review" for item in attempts)
    transient_retries = sum(item.get("outcome") == "failed_retryable" for item in attempts)
    observed = {
        "max_implementation_attempts": implementation_attempts,
        "max_review_cycles": review_cycles,
        "max_transient_retries": transient_retries,
    }
    for field, count in observed.items():
        if count > limits.get(field, -1):
            errors.append(f"authorization ledger limit exceeded: {field}")
    minutes = {"active": 0.0, "async_wait": 0.0}
    interval_count = 0
    for record in records:
        payload = record.get("payload", {})
        if (
            record.get("record_type") != "time_interval"
            or record.get("run_id") != envelope.get("run_id")
            or payload.get("authorization_hash") != expected_hash
        ):
            continue
        interval_count += 1
        try:
            started = _timestamp(str(payload.get("started_at", "")))
            ended = _timestamp(str(payload.get("ended_at", "")))
            minutes[payload.get("kind")] += (ended - started).total_seconds() / 60
        except (KeyError, TypeError, ValueError):
            errors.append("authorization time interval cannot be evaluated")
    if interval_count == 0:
        errors.append("authorization requires ledger-derived active/async time intervals")
    if minutes["active"] > limits.get("active_wall_minutes", -1):
        errors.append("authorization active wall-time limit exceeded")
    if minutes["async_wait"] > limits.get("async_wait_minutes", -1):
        errors.append("authorization asynchronous wait limit exceeded")
    return errors


def _live_apple_errors(
    envelope: dict[str, Any],
    request: dict[str, Any],
    observation: Any,
    now: datetime,
) -> list[str]:
    errors: list[str] = []
    required = {
        "source", "guard_verified", "observed_at", "account_guard_ref", "team_id",
        "app_id", "bundle_id", "platform", "live_build", "internal_group_ids",
    }
    errors.extend(_object_shape(observation, required, required, "live Apple observation"))
    if not isinstance(observation, dict):
        return errors
    apple = envelope.get("apple") or {}
    if observation.get("source") != "asc_read_only" or observation.get("guard_verified") is not True:
        errors.append("live Apple observation must come from the guarded read-only ASC route")
    if any(
        observation.get(field) != apple.get(field)
        for field in ("account_guard_ref", "team_id", "app_id", "bundle_id", "platform")
    ):
        errors.append("live Apple account, team, app, bundle, or platform drifted")
    if observation.get("internal_group_ids") != apple.get("internal_group_ids"):
        errors.append("live TestFlight internal groups drifted from authorization")
    try:
        observed_at = _timestamp(str(observation.get("observed_at", "")))
        age = (now - observed_at).total_seconds()
        if age < -60 or age > 300:
            errors.append("live Apple observation is stale or from the future")
    except ValueError:
        errors.append("live Apple observation time is invalid")
    build_policy = apple.get("build_policy") or {}
    if build_policy.get("mode") == "next_after_live" and str(observation.get("live_build")) != str(build_policy.get("baseline")):
        errors.append("authorized live-build baseline drifted from the current ASC observation")
    digest = canonical_sha256(observation)
    if request.get("apple_observation_sha256") != digest:
        errors.append("live Apple observation digest drifted from the action request")
    return errors


def authorize_action(
    envelope: dict[str, Any], request: dict[str, Any], now: datetime | None = None,
    ledger_records: list[dict[str, Any]] | None = None,
    policy_overlay: dict[str, Any] | None = None,
    live_repository: dict[str, Any] | None = None,
    live_spec_snapshot: dict[str, Any] | None = None,
    live_apple_observation: dict[str, Any] | None = None,
) -> list[str]:
    errors = validate_authorization(envelope)
    errors.extend(validate_policy_overlay(envelope, policy_overlay))
    if not isinstance(request, dict):
        return sorted(set(errors + ["action request must be an object"]))
    missing_request = REQUEST_FIELDS - set(request)
    extra_request = set(request) - REQUEST_FIELDS
    if missing_request:
        errors.append("action request is missing fields: " + ", ".join(sorted(missing_request)))
    if extra_request:
        errors.append("action request has unsupported fields: " + ", ".join(sorted(extra_request)))
    operation_input = request.get("operation_input")
    if not isinstance(operation_input, dict) or not operation_input:
        errors.append("action request must include one non-empty structured operation_input")
    elif canonical_sha256(operation_input) != request.get("constraint_sha256"):
        errors.append("action request constraint digest does not match operation_input")
    else:
        errors.extend(
            _operation_input_errors(
                envelope, request.get("action"), request.get("operation"), operation_input
            )
        )
    expected_hash = authorization_hash(envelope)
    if request.get("authorization_id") != envelope.get("authorization_id"):
        errors.append("authorization ID drifted")
    if request.get("run_id") != envelope.get("run_id"):
        errors.append("run ID drifted")
    if request.get("authorization_hash") != expected_hash:
        errors.append("authorization hash drifted")
    if request.get("delivery_target") != envelope.get("delivery_target"):
        errors.append("delivery target drifted from authorization")
    action = request.get("action")
    if action in FORBIDDEN_ACTIONS or action not in ALLOWED_ACTIONS:
        errors.append("requested action is forbidden or not allowlisted")
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        errors.append("current time must be timezone aware")
    try:
        if now < _timestamp(str(envelope.get("issued_at", ""))):
            errors.append("authorization is not active yet")
        if now >= _timestamp(str(envelope.get("expires_at", ""))):
            errors.append("authorization expired")
    except ValueError:
        errors.append("authorization time boundary is invalid")
    expected_repository = envelope.get("repository", {})
    observed_repository = request.get("repository", {})
    if not isinstance(observed_repository, dict) or any(observed_repository.get(key) != expected_repository.get(key) for key in REPOSITORY_FIELDS):
        errors.append("repository or branch drifted from authorization")
    if not isinstance(live_repository, dict) or any(
        live_repository.get(key) != expected_repository.get(key) for key in REPOSITORY_FIELDS
    ):
        errors.append("live authoritative Git repository drifted from authorization")
    spec_kit = envelope.get("spec_kit")
    observed_snapshot = request.get("spec_snapshot_sha256")
    if spec_kit is None:
        if observed_snapshot is not None or request.get("spec_checkpoint_sha256") is not None:
            errors.append("unexpected Spec Kit snapshot for a disabled binding")
        if live_spec_snapshot is not None:
            errors.append("unexpected live Spec Kit snapshot for a disabled binding")
    else:
        if observed_snapshot != spec_kit.get("snapshot_sha256"):
            errors.append("Spec Kit snapshot drifted from authorization")
        if not isinstance(live_spec_snapshot, dict):
            errors.append("live Spec Kit snapshot is required for every authorized write")
        else:
            if any(
                live_spec_snapshot.get(live_key) != spec_kit.get(bound_key)
                for live_key, bound_key in (
                    ("spec_kit_release", "release"),
                    ("feature_id", "feature_id"),
                    ("feature_directory", "feature_directory"),
                    ("snapshot_sha256", "snapshot_sha256"),
                    ("artifact_hashes", "artifact_hashes"),
                )
            ):
                errors.append("live Spec Kit artifacts drifted from authorization")
            checkpoint = live_spec_snapshot.get("workflow_checkpoint")
            if request.get("spec_checkpoint_sha256") != canonical_sha256(checkpoint):
                errors.append("live Spec Kit checkpoint digest drifted from the action request")
    records = ledger_records or []
    errors.extend(_ledger_contract_errors(records))
    errors.extend(_ledger_limit_errors(envelope, records, now))
    if isinstance(spec_kit, dict) and isinstance(live_spec_snapshot, dict):
        checkpoint_evidence = [
            record.get("payload", {}).get("tool_tuple", {}).get("spec_kit_snapshot")
            for record in records
            if record.get("run_id") == envelope.get("run_id")
            and record.get("record_type") == "evidence"
            and record.get("payload", {}).get("evidence_kind") == "spec_kit_checkpoint"
            and record.get("payload", {}).get("outcome") == "passed"
            and record.get("payload", {}).get("repository_fingerprint") == expected_repository.get("fingerprint")
            and isinstance(record.get("payload", {}).get("tool_tuple", {}).get("spec_kit_snapshot"), dict)
        ]
        if len(checkpoint_evidence) != 1:
            errors.append("Spec Kit write requires one prior private checkpoint observation")
        else:
            errors.extend(
                spec_kit_snapshot.verify_snapshot(checkpoint_evidence[0], live_spec_snapshot)
            )
    paths = request.get("paths")
    if not _nonempty_strings(paths):
        errors.append("action request must bind at least one changed or affected path")
        paths = []
    if any(not _path_allowed(path, envelope.get("allowed_paths", [])) for path in paths):
        errors.append("requested path is outside authorization")
    if action == "git.commit" and isinstance(live_repository, dict):
        operation_paths = operation_input.get("paths", []) if isinstance(operation_input, dict) else []
        if paths != operation_paths:
            errors.append("git.commit paths drifted from the structured operation descriptor")
        if paths != live_repository.get("staged_paths"):
            errors.append("git.commit paths must exactly match the live staged paths")
        staged_digest = live_repository.get("staged_diff_sha256")
        review_evidence = [
            record for record in records
            if record.get("record_type") == "evidence"
            and record.get("run_id") == envelope.get("run_id")
            and record.get("payload", {}).get("evidence_kind") == "review"
            and record.get("payload", {}).get("outcome") == "passed"
            and record.get("payload", {}).get("repository_fingerprint") == expected_repository.get("fingerprint")
            and record.get("payload", {}).get("tool_tuple", {}).get("staged_diff_sha256") == staged_digest
        ]
        if len(review_evidence) != 1:
            errors.append("git.commit requires one review of the exact live staged diff")
    if action == "git.push" and isinstance(live_repository, dict):
        if paths != live_repository.get("outgoing_paths"):
            errors.append("git.push paths must exactly match the live outgoing commit paths")
        head_sha = live_repository.get("head_sha")
        equivalence = [
            record for record in records
            if record.get("record_type") == "evidence"
            and record.get("run_id") == envelope.get("run_id")
            and record.get("payload", {}).get("evidence_kind") == "commit_equivalence"
            and record.get("payload", {}).get("outcome") == "passed"
            and record.get("payload", {}).get("repository_fingerprint") == expected_repository.get("fingerprint")
            and record.get("payload", {}).get("local_sha") == head_sha
        ]
        if len(equivalence) != 1:
            errors.append("git.push requires one commit-equivalence proof for the live HEAD")
    writes = _external_writes(records)
    expected_resource = _expected_lease_resource(action)
    try:
        canonical_resource_key = canonical_lease_resource_key(envelope, str(action))
        if request.get("lease_resource_key") != canonical_resource_key:
            errors.append("action lease resource key is not the canonical authorized key")
    except ValueError:
        errors.append("action lease resource key cannot be derived")
    active, lease_replay_errors = _active_leases(records)
    errors.extend(lease_replay_errors)
    observed_lease = active.get(
        (request.get("lease_resource"), request.get("lease_resource_key"))
    )
    if request.get("lease_resource") != expected_resource:
        errors.append("action is not protected by the required resource lease")
    if (
        observed_lease is None
        or observed_lease.get("lease_id") != request.get("lease_id")
        or observed_lease.get("owner") != request.get("lease_owner")
    ):
        errors.append("action request does not own the exact active ledger lease")
    else:
        try:
            if now >= _timestamp(str(observed_lease.get("expires_at", ""))):
                errors.append("action lease expired before grant reservation")
        except ValueError:
            errors.append("action lease expiry is invalid")
        if action not in observed_lease.get("allowed_actions", []):
            errors.append("action is outside the active lease allowance")
        if observed_lease.get("branch") != expected_repository.get("branch"):
            errors.append("action lease branch drifted from authorization")
        if observed_lease.get("base_sha") != expected_repository.get("base_sha"):
            errors.append("action lease base SHA drifted from authorization")
        if observed_lease.get("approval_id") != envelope.get("authorization_id"):
            errors.append("action lease is not bound to this run authorization")
        lease_paths = observed_lease.get("allowed_paths", [])
        if any(not _path_allowed(path, lease_paths) for path in paths):
            errors.append("requested path is outside the active lease allowance")
    approvals = [
        record
        for record in records
        if record.get("record_type") == "approval"
        and isinstance(record.get("payload"), dict)
        and record["payload"].get("kind") == "run_authorization"
        and record["payload"].get("decision") == "approved"
        and record["payload"].get("approval_id") == envelope.get("authorization_id")
        and record["payload"].get("authorization_hash") == expected_hash
        and record["payload"].get("delivery_target") == envelope.get("delivery_target")
        and record["payload"].get("issued_at") == envelope.get("issued_at")
        and record["payload"].get("expires_at") == envelope.get("expires_at")
        and record["payload"].get("action_grants") == envelope.get("action_grants")
        and record.get("run_id") == envelope.get("run_id")
    ]
    if len(approvals) != 1:
        errors.append("ledger lacks one exact prior approved authorization record")
    else:
        try:
            approved_at = _timestamp(str(approvals[0].get("recorded_at", "")))
            if approved_at > now:
                errors.append("authorization approval record is in the future")
        except ValueError:
            errors.append("authorization approval record time is invalid")
    if action in {"git.commit", "git.push"}:
        repository_scope = ":".join(
            (
                str(expected_repository.get("fingerprint")),
                str(expected_repository.get("branch")),
                str(expected_repository.get("remote")),
            )
        )
        repository_approvals = [
            record for record in records
            if record.get("run_id") == envelope.get("run_id")
            and record.get("record_type") == "approval"
            and record.get("payload", {}).get("kind") == "repository"
            and record.get("payload", {}).get("decision") == "approved"
            and record.get("payload", {}).get("scope") == repository_scope
        ]
        if len(repository_approvals) != 1:
            errors.append("git commit or push requires one exact prior repository confirmation")
    grants = [
        grant for grant in envelope.get("action_grants", [])
        if grant.get("system") == request.get("system")
        and grant.get("action") == action
        and grant.get("operation") == request.get("operation")
        and grant.get("operation_input") == request.get("operation_input")
        and grant.get("constraint_sha256") == request.get("constraint_sha256")
        and grant.get("phase") == request.get("phase")
        and grant.get("resource_key") == request.get("lease_resource_key")
        and grant.get("grant_id") == request.get("grant_id")
        and grant.get("idempotency_key") == request.get("idempotency_key")
    ]
    if len(grants) != 1:
        errors.append("no one exact action grant matches the request")
    else:
        grant = grants[0]
        expected_target = grant.get("target")
        source_id = grant.get("target_from_grant_id")
        if source_id:
            source = next(
                (candidate for candidate in envelope.get("action_grants", []) if candidate.get("grant_id") == source_id),
                {},
            )
            repo_slug = (
                f"{envelope.get('github', {}).get('owner')}/"
                f"{envelope.get('github', {}).get('repository')}"
            )
            produced = [
                write.get("output_target")
                for write in writes
                if write.get("authorization_hash") == expected_hash
                and write.get("grant_id") == source_id
                and write.get("outcome") == "succeeded"
                and _valid_produced_target(
                    source.get("produces_target_kind"), write.get("output_target"), repo_slug
                )
            ]
            if len(set(produced)) != 1:
                errors.append("derived target is unavailable, ambiguous, or outside the bound repository")
            else:
                expected_target = produced[0]
        if request.get("target") != expected_target:
            errors.append("requested target drifted from its exact or derived grant")
        reserved_or_written = any(
            record.get("record_type") in {"grant_reservation", "external_write"}
            and isinstance(record.get("payload"), dict)
            and record["payload"].get("authorization_hash") == expected_hash
            and record["payload"].get("grant_id") == grant.get("grant_id")
            for record in records
        )
        if reserved_or_written:
            errors.append("single-use action grant was already reserved or consumed in the ledger")
    if str(action).startswith("apple."):
        errors.extend(_live_apple_errors(envelope, request, live_apple_observation, now))
        apple = envelope.get("apple") or {}
        observed_apple = request.get("apple")
        required_observed = set(APPLE_FIELDS) | {"internal_group_ids", "version", "build", "artifact_sha256", "artifact_source_commit", "reviewed_remote_sha"}
        if action == "apple.testflight.distribute_internal" or (action == "apple.testflight.readback" and ":group:" in str(request.get("target"))):
            required_observed.add("group_id")
        errors.extend(_object_shape(observed_apple, required_observed, required_observed, "observed Apple action"))
        if not isinstance(observed_apple, dict):
            observed_apple = {}
        if any(observed_apple.get(key) != apple.get(key) for key in APPLE_FIELDS):
            errors.append("Apple account, policy, app, bundle, or platform drifted")
        if observed_apple.get("internal_group_ids") != apple.get("internal_group_ids"):
            errors.append("TestFlight group set drifted from authorization")
        artifact_sha = observed_apple.get("artifact_sha256")
        source_commit = observed_apple.get("artifact_source_commit")
        if not isinstance(artifact_sha, str) or not HEX_SHA256.fullmatch(artifact_sha):
            errors.append("TestFlight action requires an exact artifact SHA-256")
        if not isinstance(source_commit, str) or not HEX_SHA.fullmatch(source_commit):
            errors.append("TestFlight action requires the full artifact source commit")
        if observed_apple.get("reviewed_remote_sha") != source_commit:
            errors.append("artifact source is not the reviewed remote PR commit")
        if not isinstance(observed_apple.get("version"), str) or not observed_apple.get("version"):
            errors.append("TestFlight action requires the exact marketing version")
        if not isinstance(observed_apple.get("build"), str) or not observed_apple.get("build"):
            errors.append("TestFlight action requires the exact build number")
        version_policy = apple.get("version_policy") or {}
        if version_policy.get("mode") != "exact" or observed_apple.get("version") != version_policy.get("value"):
            errors.append("TestFlight marketing version violates the exact authorization policy")
        build_policy = apple.get("build_policy") or {}
        if build_policy.get("mode") == "exact":
            if observed_apple.get("build") != build_policy.get("value"):
                errors.append("TestFlight build violates the exact authorization policy")
        elif build_policy.get("mode") == "next_after_live":
            try:
                if int(observed_apple.get("build", "")) != int(build_policy.get("baseline", "")) + 1:
                    errors.append("TestFlight build is not exactly one above the authorized live baseline")
            except (TypeError, ValueError):
                errors.append("TestFlight next-build authorization policy is invalid")
        else:
            errors.append("TestFlight build policy is unsupported")
        artifact_evidence = [
            record
            for record in records
            if record.get("run_id") == envelope.get("run_id")
            and record.get("record_type") == "evidence"
            and isinstance(record.get("payload"), dict)
            and record["payload"].get("evidence_kind") == "testflight_artifact"
            and record["payload"].get("outcome") == "passed"
            and record["payload"].get("repository_fingerprint") == expected_repository.get("fingerprint")
            and record["payload"].get("remote_sha") == source_commit
            and record["payload"].get("artifact_source_commit") == source_commit
            and record["payload"].get("artifact_sha256") == artifact_sha
            and record["payload"].get("version") == observed_apple.get("version")
            and record["payload"].get("build") == observed_apple.get("build")
        ]
        if len(artifact_evidence) != 1:
            errors.append("TestFlight artifact lacks one exact passed ledger provenance record")
        pr_ready_records = [
            record for record in records
            if record.get("run_id") == envelope.get("run_id")
            and record.get("record_type") == "node"
            and record.get("payload", {}).get("node_id") == "pr_ready"
            and record.get("payload", {}).get("status") == "passed"
        ]
        if len(pr_ready_records) != 1:
            errors.append("TestFlight continuation requires one prior pr_ready terminal")
        pushed = [
            record for record in records
            if record.get("run_id") == envelope.get("run_id")
            and record.get("record_type") == "external_write"
            and record.get("payload", {}).get("action") == "git.push"
            and record.get("payload", {}).get("outcome") == "succeeded"
            and record.get("payload", {}).get("remote_sha") == source_commit
        ]
        if len(pushed) != 1:
            errors.append("TestFlight artifact source is not the one verified pushed remote SHA")
        review_evidence = [
            record for record in records
            if record.get("run_id") == envelope.get("run_id")
            and record.get("record_type") == "evidence"
            and record.get("payload", {}).get("evidence_kind") in {"review", "commit_equivalence"}
            and record.get("payload", {}).get("outcome") == "passed"
            and record.get("payload", {}).get("remote_sha") == source_commit
        ]
        if not review_evidence:
            errors.append("TestFlight artifact source lacks current review/commit-equivalence evidence")
        if artifact_evidence and pr_ready_records:
            try:
                artifact_time = _timestamp(str(artifact_evidence[0].get("recorded_at", "")))
                ready_time = _timestamp(str(pr_ready_records[0].get("recorded_at", "")))
                if artifact_time <= ready_time:
                    errors.append("TestFlight archive evidence must be fresh after pr_ready")
            except ValueError:
                errors.append("TestFlight provenance record time is invalid")
        group_id = observed_apple.get("group_id")
        if group_id is not None and group_id not in apple.get("internal_group_ids", []):
            errors.append("TestFlight group is outside authorization")
        prior_uploads = [write for write in writes if write.get("authorization_hash") == expected_hash and write.get("action") == "apple.testflight.upload" and write.get("outcome") == "succeeded"]
        processing_complete = [
            write for write in writes
            if write.get("authorization_hash") == expected_hash
            and write.get("action") == "apple.testflight.processing.wait"
            and write.get("outcome") == "succeeded"
            and write.get("external_state") == "completed"
        ]
        upload_readback_complete = [
            write for write in writes
            if write.get("authorization_hash") == expected_hash
            and write.get("action") == "apple.testflight.readback"
            and str(write.get("target", "")).endswith(":upload")
            and write.get("outcome") == "succeeded"
            and write.get("external_state") == "completed"
        ]
        distributions = [
            write for write in writes
            if write.get("authorization_hash") == expected_hash
            and write.get("action") == "apple.testflight.distribute_internal"
            and write.get("outcome") == "succeeded"
            and write.get("target") == request.get("target")
        ]
        if action == "apple.testflight.processing.wait" and len(prior_uploads) != 1:
            errors.append("processing wait requires one successful authorized upload")
        if action == "apple.testflight.readback" and str(request.get("target", "")).endswith(":upload"):
            if len(prior_uploads) != 1 or len(processing_complete) != 1:
                errors.append("upload read-back requires a completed bounded processing wait")
        if action == "apple.testflight.distribute_internal" and len(upload_readback_complete) != 1:
            errors.append("distribution requires one completed upload read-back")
        if action == "apple.testflight.readback" and ":group:" in str(request.get("target", "")):
            if len(distributions) != 1:
                errors.append("distribution read-back requires the exact prior internal distribution")
        for write in prior_uploads:
            for field in ("artifact_sha256", "artifact_source_commit", "version", "build"):
                if write.get(field) != observed_apple.get(field):
                    errors.append(f"TestFlight artifact identity drifted after upload: {field}")
    else:
        if request.get("apple") is not None:
            errors.append("non-Apple action cannot carry Apple target observations")
        if request.get("apple_observation_sha256") is not None or live_apple_observation is not None:
            errors.append("non-Apple action cannot carry a live Apple observation")
    return sorted(set(errors))


def load_ledger(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid ledger JSON on line {line_number}") from error
        if not isinstance(record, dict):
            raise ValueError(f"ledger line {line_number} must be an object")
        records.append(record)
    return records


def reserve_action(
    path: Path,
    envelope: dict[str, Any],
    request: dict[str, Any],
    run_root: Path,
    policy_overlay: dict[str, Any],
    live_repository: dict[str, Any],
    live_spec_snapshot: dict[str, Any] | None = None,
    live_apple_observation: dict[str, Any] | None = None,
) -> tuple[list[str], dict[str, Any] | None]:
    """Validate and reserve one grant while holding an exclusive ledger lock."""
    canonical_run_root = run_root.resolve(strict=True)
    if path.is_symlink() or path.parent.resolve(strict=True) != canonical_run_root:
        return ["authorization ledger must be a non-symlink file directly under the private run root"], None
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW)
    except OSError as error:
        return [f"authorization ledger cannot be opened safely: {error}"], None
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        return ["authorization ledger must be a regular file"], None
    with os.fdopen(descriptor, "r+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        handle.seek(0)
        records: list[dict[str, Any]] = []
        for line_number, line in enumerate(handle.read().splitlines(), 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"invalid ledger JSON on line {line_number}") from error
            if not isinstance(record, dict):
                raise ValueError(f"ledger line {line_number} must be an object")
            records.append(record)
        now = datetime.now(timezone.utc)
        errors = authorize_action(
            envelope,
            request,
            now=now,
            ledger_records=records,
            policy_overlay=policy_overlay,
            live_repository=live_repository,
            live_spec_snapshot=live_spec_snapshot,
            live_apple_observation=live_apple_observation,
        )
        if errors:
            return errors, None
        run_ids = {record.get("run_id") for record in records if record.get("run_id")}
        if len(run_ids) != 1 or run_ids != {envelope.get("run_id")}:
            return ["ledger must contain exactly one run ID before grant reservation"], None
        sequence = max((record.get("sequence", 0) for record in records), default=0) + 1
        recorded_at = now.isoformat().replace("+00:00", "Z")
        reservation = {
            "schema_version": "1.0.0",
            "run_id": envelope["run_id"],
            "sequence": sequence,
            "recorded_at": recorded_at,
            "record_type": "grant_reservation",
            "payload": {
                "reservation_id": str(uuid.uuid4()),
                "authorization_hash": request["authorization_hash"],
                "grant_id": request["grant_id"],
                "idempotency_key": request["idempotency_key"],
                "system": request["system"],
                "action": request["action"],
                "operation": request["operation"],
                "operation_input": request["operation_input"],
                "constraint_sha256": request["constraint_sha256"],
                "phase": request["phase"],
                "target": request["target"],
                "lease_id": request["lease_id"],
                "lease_owner": request["lease_owner"],
                "resource": request["lease_resource"],
                "resource_key": request["lease_resource_key"],
                "spec_checkpoint_sha256": request["spec_checkpoint_sha256"],
                "apple_observation_sha256": request["apple_observation_sha256"],
            },
        }
        handle.seek(0, os.SEEK_END)
        if handle.tell() and not _file_ends_with_newline(path):
            handle.write("\n")
        handle.write(json.dumps(reservation, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
        return [], reservation


def _file_ends_with_newline(path: Path) -> bool:
    if not path.exists() or path.stat().st_size == 0:
        return True
    with path.open("rb") as handle:
        handle.seek(-1, os.SEEK_END)
        return handle.read(1) == b"\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorization", type=Path, required=True)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, required=True, help="Append-only ledger for single-use and derived-target state.")
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--policy-overlay", type=Path, required=True)
    parser.add_argument("--authoritative-root", type=Path, required=True)
    parser.add_argument(
        "--apple-observation",
        type=Path,
        help="Fresh guarded read-only ASC observation; required for Apple actions.",
    )
    arguments = parser.parse_args()
    envelope = json.loads(arguments.authorization.read_text(encoding="utf-8"))
    request = json.loads(arguments.request.read_text(encoding="utf-8"))
    overlay = json.loads(arguments.policy_overlay.read_text(encoding="utf-8"))
    try:
        live_repository = observe_repository(
            arguments.authoritative_root, envelope.get("repository", {}).get("base_sha", "")
        )
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"authorized": False, "errors": [str(error)], "reservation": None}, indent=2))
        return 2
    live_spec_snapshot = None
    spec_binding = envelope.get("spec_kit")
    if isinstance(spec_binding, dict):
        try:
            live_spec_snapshot = spec_kit_snapshot.build_snapshot(
                arguments.authoritative_root,
                release=spec_binding.get("release", ""),
                feature_directory=spec_binding.get("feature_directory"),
                run_id=spec_binding.get("workflow_run_id"),
            )
        except (OSError, ValueError) as error:
            print(json.dumps({"authorized": False, "errors": [str(error)], "reservation": None}, indent=2))
            return 2
    live_apple_observation = None
    if str(request.get("action", "")).startswith("apple."):
        boundary_errors = validate_policy_overlay(envelope, overlay)
        if boundary_errors:
            print(json.dumps({"authorized": False, "errors": boundary_errors, "reservation": None}, indent=2))
            return 2
        if arguments.apple_observation is None:
            print(json.dumps({"authorized": False, "errors": ["Apple action requires --apple-observation"], "reservation": None}, indent=2))
            return 2
        try:
            canonical_run_root = arguments.run_root.resolve(strict=True)
            observation_path = arguments.apple_observation
            if observation_path.is_symlink() or observation_path.parent.resolve(strict=True) != canonical_run_root:
                raise ValueError("Apple observation must be a non-symlink file directly under the private run root")
            live_apple_observation = json.loads(observation_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError) as error:
            print(json.dumps({"authorized": False, "errors": [str(error)], "reservation": None}, indent=2))
            return 2
    errors, reservation = reserve_action(
        arguments.ledger,
        envelope,
        request,
        arguments.run_root,
        overlay,
        live_repository,
        live_spec_snapshot,
        live_apple_observation,
    )
    print(
        json.dumps(
            {"authorized": not errors, "errors": errors, "reservation": reservation},
            indent=2,
            sort_keys=True,
        )
    )
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
