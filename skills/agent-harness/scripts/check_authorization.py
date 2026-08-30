#!/usr/bin/env python3
"""Fail closed before one action covered by an immutable run authorization.

It never performs the external action. It validates the instantiated envelope,
binds the request to exact repository/time/attempt/artifact facts, then atomically
reserves the single-use grant in the local append-only ledger before returning.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import sys
from typing import Any
import urllib.parse
import uuid

import spec_kit_snapshot
import resource_coordinator
from resolve_project import (
    normalize_github_remote as normalize_registry_github_remote,
    remote_fingerprint as registry_remote_fingerprint,
)


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
APPLE_OBSERVATION_STABLE_FIELDS = (
    "source",
    "guard_verified",
    "account_guard_ref",
    "team_id",
    "app_id",
    "bundle_id",
    "platform",
    "live_build",
    "internal_group_ids",
)
LIMIT_MINIMUMS = {
    "max_implementation_attempts": 1, "max_review_cycles": 1,
    "max_transient_retries": 0, "active_wall_minutes": 1,
    "async_wait_minutes": 1,
}
TOP_LEVEL_FIELDS = {
    "schema_version", "contract_schema_id", "contract_schema_sha256",
    "run_id", "authorization_id", "decision", "actor", "selected_writer", "issued_at",
    "expires_at", "delivery_target", "health_profile", "resource_plan",
    "health_attestation",
    "repository", "spec_kit",
    "acceptance_ids", "allowed_paths", "limits", "github", "apple",
    "action_grants", "forbidden_actions", "auto_merge", "app_review_submit",
    "credential_scope_expansion", "signing_resource_mutation",
    "destructive_cleanup",
}
REQUEST_FIELDS = {
    "run_id", "authorization_id", "authorization_hash", "delivery_target", "system",
    "action", "target", "grant_id", "idempotency_key", "repository",
    "spec_snapshot_sha256", "paths", "apple", "lease_id", "lease_owner",
    "lease_resource", "lease_resource_key", "resource_descriptor",
    "coordinator_receipt",
    "operation", "operation_input", "constraint_sha256", "phase",
    "spec_checkpoint_sha256", "apple_observation_sha256", "writer_actor",
    "health_report_sha256",
}
COORDINATOR_RECEIPT_FIELDS = {
    "coordinator_instance_id", "receipt_id", "lease_id", "owner_run_id",
    "owner_actor", "resource", "resource_key", "descriptor_sha256",
    "fencing_token", "acquired_at", "expires_at",
}
PROTECTS_REQUIRED_RESOURCES = {
    "xcode_project_mutation",
    "build_tuple",
    "simulator_or_device",
    "coresimulator_runtime_registry",
    "macos_gui_session",
}
MIN_DISPATCH_WINDOW_SECONDS = 30
MAX_DISPATCH_WINDOW_SECONDS = 60
RESOURCE_SCOPES = {
    "source_checkout_writer",
    "xcode_project_mutation",
    "build_tuple",
    "simulator_or_device",
    "coresimulator_runtime_registry",
    "macos_gui_session",
    "signing_or_app_store_connect",
    "github_external_mutation",
}
HEALTH_PROFILES = {
    "pr_ready", "runtime_ui", "testflight_uploaded",
    "testflight_distributed", "icon_upstream",
}
PATCH_BOUND_NODES = {
    "verify", "freeze_review", "review", "converge", "reverify",
    "prepare_evidence", "prepare_pr", "repository_confirmation", "commit",
    "push", "verify_remote_sha", "create_pr", "publish_evidence",
    "verify_published_evidence", "checks", "pr_ready",
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


def _installed_workflow_contracts() -> tuple[
    list[str], list[str], dict[str, dict[str, Any]]
]:
    """Load the immutable control spine used by authorization and ledger checks."""
    contracts_root = Path(__file__).resolve().parents[1] / "contracts"
    main = json.loads((contracts_root / "workflow.json").read_text(encoding="utf-8"))
    continuation = json.loads(
        (contracts_root / "testflight-workflow.json").read_text(encoding="utf-8")
    )
    main_nodes = [node["id"] for node in main.get("nodes", [])]
    continuation_nodes = [node["id"] for node in continuation.get("nodes", [])]
    installed = main.get("nodes", []) + continuation.get("nodes", [])
    if (
        not main_nodes
        or not continuation_nodes
        or len({node["id"] for node in installed}) != len(installed)
    ):
        raise ValueError("installed workflow nodes are missing or duplicated")
    return main_nodes, continuation_nodes, {node["id"]: node for node in installed}


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


def _receipt_lineage_compatible(
    earlier: Any, later: Any, *, require_extension: bool = False
) -> bool:
    """Return whether two receipts identify one fenced, monotonic lease."""
    if (
        not isinstance(earlier, dict)
        or not isinstance(later, dict)
        or set(earlier) != COORDINATOR_RECEIPT_FIELDS
        or set(later) != COORDINATOR_RECEIPT_FIELDS
    ):
        return False
    stable = COORDINATOR_RECEIPT_FIELDS - {"expires_at"}
    if any(earlier.get(field) != later.get(field) for field in stable):
        return False
    try:
        earlier_expiry = _timestamp(str(earlier.get("expires_at")))
        later_expiry = _timestamp(str(later.get("expires_at")))
    except ValueError:
        return False
    return later_expiry > earlier_expiry if require_extension else later_expiry >= earlier_expiry


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
    portable = {key: value for key, value in envelope.items() if key != "$schema"}
    encoded = json.dumps(portable, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def patch_identity_v1(manifest: Any) -> str:
    """Validate and hash one complete, reviewable patch manifest."""
    if not isinstance(manifest, dict) or set(manifest) != {
        "version", "base_sha", "records"
    }:
        raise ValueError("patch manifest fields are invalid")
    if manifest.get("version") != "patch_identity_v1" or HEX_SHA.fullmatch(
        str(manifest.get("base_sha"))
    ) is None:
        raise ValueError("patch manifest version or base SHA is invalid")
    records = manifest.get("records")
    if not isinstance(records, list) or not records:
        raise ValueError("patch manifest records are required")
    paths: list[str] = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "path", "mode", "state", "content_sha256"
        }:
            raise ValueError("patch manifest record fields are invalid")
        path = record.get("path")
        state = record.get("state")
        mode = record.get("mode")
        content_sha = record.get("content_sha256")
        if not isinstance(path, str) or not _safe_relative_path(path):
            raise ValueError("patch manifest path is unsafe")
        if mode not in {"100644", "100755", "120000", "160000"}:
            raise ValueError("patch manifest mode is invalid")
        if state not in {"added", "modified", "deleted", "symlink"}:
            raise ValueError("patch manifest state is invalid")
        if state == "deleted":
            if content_sha != "deleted":
                raise ValueError("deleted patch record lacks its deletion marker")
        elif re.fullmatch(r"sha256:[0-9a-f]{64}", str(content_sha)) is None:
            raise ValueError("patch manifest content digest is invalid")
        paths.append(path)
    if len(paths) != len(set(paths)) or paths != sorted(
        paths, key=lambda item: item.encode("utf-8")
    ):
        raise ValueError("patch manifest paths must be unique and UTF-8 sorted")
    encoded = json.dumps(
        manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def _git_entry(
    git_bytes: Any, revision: str, path: str, *, staged: bool
) -> tuple[str, str]:
    """Return the exact Git mode and object ID for one path."""
    if staged:
        raw = git_bytes("ls-files", "--stage", "-z", "--", path)
        entries = [item for item in raw.split(b"\0") if item]
        if len(entries) != 1:
            raise ValueError(f"staged patch path has no unique index entry: {path}")
        try:
            metadata, encoded_path = entries[0].split(b"\t", 1)
            mode, object_id, stage = metadata.decode("ascii").split()
            decoded_path = encoded_path.decode("utf-8")
        except (UnicodeDecodeError, ValueError) as error:
            raise ValueError("staged patch entry is not canonical UTF-8 Git metadata") from error
        if stage != "0" or decoded_path != path:
            raise ValueError(f"staged patch path is unmerged or drifted: {path}")
        return mode, object_id
    raw = git_bytes("ls-tree", "-z", revision, "--", path)
    entries = [item for item in raw.split(b"\0") if item]
    if len(entries) != 1:
        raise ValueError(f"committed patch path has no unique tree entry: {path}")
    try:
        metadata, encoded_path = entries[0].split(b"\t", 1)
        mode, _kind, object_id = metadata.decode("ascii").split()
        decoded_path = encoded_path.decode("utf-8")
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("committed patch entry is not canonical UTF-8 Git metadata") from error
    if decoded_path != path:
        raise ValueError(f"committed patch path drifted: {path}")
    return mode, object_id


def _git_patch_manifest(
    git: Any,
    git_bytes: Any,
    base_sha: str,
    revision: str,
    *,
    staged: bool,
) -> dict[str, Any]:
    """Derive patch_identity_v1 from the live index or one committed tree."""
    resolved_base = git("rev-parse", f"{base_sha}^{{commit}}")
    if HEX_SHA.fullmatch(base_sha) is None or resolved_base != base_sha:
        raise ValueError("patch base must be one exact full commit SHA")
    if staged:
        raw = git_bytes(
            "diff", "--cached", "--name-status", "-z", "--no-renames", base_sha
        )
    else:
        resolved_revision = git("rev-parse", f"{revision}^{{commit}}")
        raw = git_bytes(
            "diff", "--name-status", "-z", "--no-renames",
            f"{base_sha}..{resolved_revision}",
        )
        revision = resolved_revision
    tokens = [item for item in raw.split(b"\0") if item]
    if len(tokens) % 2:
        raise ValueError("Git patch name-status stream is malformed")
    records: list[dict[str, str]] = []
    for index in range(0, len(tokens), 2):
        try:
            status = tokens[index].decode("ascii")
            path = tokens[index + 1].decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError("Git patch contains a non-UTF-8 path or status") from error
        if status not in {"A", "D", "M", "T"} or not _safe_relative_path(path):
            raise ValueError(f"Git patch contains an unsupported status or path: {status}")
        if status == "D":
            mode, _object_id = _git_entry(
                git_bytes, base_sha, path, staged=False
            )
            state = "deleted"
            content_sha256 = "deleted"
        else:
            mode, object_id = _git_entry(
                git_bytes, revision, path, staged=staged
            )
            state = "symlink" if mode == "120000" else (
                "added" if status == "A" else "modified"
            )
            content = (
                object_id.encode("ascii")
                if mode == "160000"
                else git_bytes("cat-file", "blob", object_id)
            )
            content_sha256 = "sha256:" + hashlib.sha256(content).hexdigest()
        records.append(
            {
                "path": path,
                "mode": mode,
                "state": state,
                "content_sha256": content_sha256,
            }
        )
    manifest = {
        "version": "patch_identity_v1",
        "base_sha": base_sha,
        "records": sorted(records, key=lambda item: item["path"].encode("utf-8")),
    }
    if records:
        patch_identity_v1(manifest)
    return manifest


def installed_authorization_schema_binding() -> tuple[str, str]:
    """Return the stable schema identity and exact installed content digest."""
    schema_path = (
        Path(__file__).resolve().parents[1]
        / "contracts"
        / "schemas"
        / "run-authorization.schema.json"
    )
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    schema_id = schema.get("$id")
    if not isinstance(schema_id, str) or not schema_id:
        raise ValueError("installed authorization schema lacks a stable ID")
    return schema_id, "sha256:" + hashlib.sha256(schema_path.read_bytes()).hexdigest()


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


def normalize_github_remote(remote: str) -> str:
    """Reuse the registry's strict GitHub identity without exposing raw remotes."""
    try:
        return normalize_registry_github_remote(remote)
    except ValueError as error:
        raise ValueError("unsafe GitHub remote") from error


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def repository_fingerprint(remote_or_root: str, remote: str | None = None) -> str:
    """Hash logical GitHub identity; a legacy root argument is ignored."""
    remote_value = remote if remote is not None else remote_or_root
    try:
        return registry_remote_fingerprint(remote_value)
    except ValueError as error:
        raise ValueError("unsafe GitHub remote") from error


def _github_slug(remote: str) -> str | None:
    try:
        return normalize_github_remote(remote).removeprefix("github.com/")
    except ValueError:
        return None


def _bound_github_slug(github: dict[str, Any]) -> str | None:
    owner, repository = github.get("owner"), github.get("repository")
    if not isinstance(owner, str) or not isinstance(repository, str):
        return None
    try:
        return normalize_github_remote(
            f"https://github.com/{owner}/{repository}"
        ).removeprefix("github.com/")
    except ValueError:
        return None


def canonical_resource_descriptor(envelope: dict[str, Any], action: str) -> dict[str, Any]:
    repository = envelope.get("repository") or {}
    github = envelope.get("github") or {}
    if action == "git.commit":
        return {
            "identity_version": "github_remote_v2",
            "repository_fingerprint": str(repository.get("fingerprint")),
        }
    if action == "git.push" or action.startswith("github."):
        return {
            "repository_fingerprint": str(repository.get("fingerprint")),
            "remote_repository": _bound_github_slug(github) or "<invalid-repository>",
        }
    if action.startswith("apple."):
        apple = envelope.get("apple") or {}
        return {
            "account_guard": str(apple.get("account_guard_ref")),
            "app_or_bundle_scope": str(apple.get("app_id") or apple.get("bundle_id")),
        }
    raise ValueError(f"cannot derive a resource key for action {action!r}")


def canonical_lease_resource_key(envelope: dict[str, Any], action: str) -> str:
    resource = _expected_lease_resource(action)
    if resource is None:
        raise ValueError(f"cannot derive a resource key for action {action!r}")
    try:
        return resource_coordinator.canonical_resource_key(
            resource, canonical_resource_descriptor(envelope, action)
        )
    except resource_coordinator.CoordinatorError as error:
        raise ValueError(f"cannot derive a resource key for action {action!r}") from error


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
    raw_remote = git("remote", "get-url", "origin")
    normalize_github_remote(raw_remote)
    remote = sanitize_remote(raw_remote)
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
    staged_patch_manifest = _git_patch_manifest(
        git, git_bytes, expected_base_sha, "INDEX", staged=True
    )
    head_patch_manifest = _git_patch_manifest(
        git, git_bytes, expected_base_sha, "HEAD", staged=False
    )
    return {
        "fingerprint": repository_fingerprint(raw_remote),
        "canonical_root": canonical_string,
        "remote": remote,
        "base_sha": expected_base_sha,
        "branch": branch,
        "head_sha": git("rev-parse", "HEAD"),
        "staged_paths": staged_paths,
        "staged_diff_sha256": hashlib.sha256(staged_diff).hexdigest(),
        "outgoing_paths": outgoing_paths,
        "staged_patch_manifest": staged_patch_manifest,
        "staged_patch_identity": (
            patch_identity_v1(staged_patch_manifest)
            if staged_patch_manifest["records"] else None
        ),
        "head_patch_manifest": head_patch_manifest,
        "head_patch_identity": (
            patch_identity_v1(head_patch_manifest)
            if head_patch_manifest["records"] else None
        ),
    }


def validate_policy_overlay(envelope: dict[str, Any], overlay: Any) -> list[str]:
    errors: list[str] = []
    fields = {"schema_version", "decision", "github", "apple"}
    errors.extend(
        _object_shape(
            overlay, fields, fields | {"$schema"}, "private policy overlay"
        )
    )
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


def _json_schema_equal(left: Any, right: Any) -> bool:
    """Use JSON Schema equality, where booleans are never numbers."""
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left == right
    numeric = (int, float)
    if isinstance(left, numeric) or isinstance(right, numeric):
        return (
            isinstance(left, numeric)
            and isinstance(right, numeric)
            and not isinstance(left, bool)
            and not isinstance(right, bool)
            and left == right
        )
    if isinstance(left, list) or isinstance(right, list):
        return (
            isinstance(left, list)
            and isinstance(right, list)
            and len(left) == len(right)
            and all(_json_schema_equal(a, b) for a, b in zip(left, right))
        )
    if isinstance(left, dict) or isinstance(right, dict):
        return (
            isinstance(left, dict)
            and isinstance(right, dict)
            and set(left) == set(right)
            and all(_json_schema_equal(left[key], right[key]) for key in left)
        )
    return type(left) is type(right) and left == right


def _schema_errors(instance: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    """Validate the dependency-free JSON Schema subset used by this installed skill."""
    errors: list[str] = []
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(isinstance(name, str) and _schema_type(instance, name) for name in names):
            return [f"{path}: expected type {schema['type']!r}"]
    if "const" in schema and not _json_schema_equal(instance, schema["const"]):
        errors.append(f"{path}: must equal {schema['const']!r}")
    if "enum" in schema and not any(
        _json_schema_equal(instance, candidate) for candidate in schema["enum"]
    ):
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
        if isinstance(schema.get("contains"), dict) and not any(
            not _schema_errors(item, schema["contains"], f"{path}[*]")
            for item in instance
        ):
            errors.append(f"{path}: must contain an item matching the required schema")
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            errors.append(f"{path}: contains too few properties")
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
    if "anyOf" in schema:
        matches = sum(not _schema_errors(instance, child, path) for child in schema["anyOf"])
        if matches < 1:
            errors.append(f"{path}: must match at least one anyOf branch")
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
    repo_slug = _bound_github_slug(github)
    if repo_slug is None:
        errors.append("GitHub owner/repository cannot form a canonical repository identity")
        repo_slug = "<invalid-repository>"
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
    try:
        schema_id, schema_sha256 = installed_authorization_schema_binding()
        if envelope.get("contract_schema_id") != schema_id:
            errors.append("approved authorization schema identity drifted")
        if envelope.get("contract_schema_sha256") != schema_sha256:
            errors.append("approved authorization schema content drifted")
    except (OSError, ValueError, json.JSONDecodeError):
        errors.append("installed approved authorization schema is unavailable")
    if not isinstance(envelope.get("$schema"), str) or not envelope.get("$schema"):
        errors.append("authorization schema location must be a non-empty string")
    if envelope.get("schema_version") != "1.0.0":
        errors.append("unsupported authorization schema")
    if envelope.get("decision") != "approved":
        errors.append("authorization is not approved")
    for field in ("run_id", "authorization_id", "actor"):
        if not isinstance(envelope.get(field), str) or not envelope.get(field):
            errors.append(f"authorization {field} must be a non-empty string")
    selected_writer = envelope.get("selected_writer")
    if selected_writer not in {"codex", "claude"}:
        errors.append("authorization selected_writer must be codex or claude")
    if envelope.get("delivery_target") not in {"pr_ready", "testflight_uploaded", "testflight_distributed"}:
        errors.append("unsupported delivery target")
    health_profile = envelope.get("health_profile")
    if health_profile not in HEALTH_PROFILES:
        errors.append("authorization health profile is invalid")
    if envelope.get("delivery_target") in {
        "testflight_uploaded", "testflight_distributed",
    } and health_profile != envelope.get("delivery_target"):
        errors.append("TestFlight authorization health profile must match its delivery target")
    health_attestation = envelope.get("health_attestation")
    health_fields = {
        "report_sha256", "observed_at", "profile", "overall_status",
        "authoritative_targets_sha256", "agent_skill_bundle_sha256",
        "coordinator_instance_id", "coordinator_contract_bundle_sha256",
    }
    errors.extend(
        _object_shape(
            health_attestation,
            health_fields,
            health_fields,
            "authorization health attestation",
        )
    )
    if isinstance(health_attestation, dict):
        if health_attestation.get("profile") != health_profile:
            errors.append("authorization health attestation profile drifted")
        if health_attestation.get("overall_status") not in {"healthy", "degraded"}:
            errors.append("authorization health attestation is not usable")
        for field in (
            "report_sha256", "authoritative_targets_sha256",
            "agent_skill_bundle_sha256", "coordinator_contract_bundle_sha256",
        ):
            if re.fullmatch(
                r"sha256:[0-9a-f]{64}", str(health_attestation.get(field))
            ) is None:
                errors.append(f"authorization health attestation {field} is invalid")
        if not isinstance(health_attestation.get("coordinator_instance_id"), str) or not health_attestation.get("coordinator_instance_id"):
            errors.append("authorization health coordinator instance is invalid")
        try:
            health_observed = _timestamp(str(health_attestation.get("observed_at")))
            issued = _timestamp(str(envelope.get("issued_at")))
            if health_observed > issued or (issued - health_observed).total_seconds() > 300:
                errors.append("authorization health attestation is stale at issuance")
        except ValueError:
            errors.append("authorization health attestation time is invalid")
    resource_plan = envelope.get("resource_plan")
    if not isinstance(resource_plan, list):
        errors.append("authorization resource plan must be an array")
        resource_plan = []
    plan_ids: set[str] = set()
    resource_identities: set[tuple[str, str]] = set()
    try:
        main_workflow_ids, continuation_workflow_ids, installed_workflow_nodes = (
            _installed_workflow_contracts()
        )
        delivery_target = envelope.get("delivery_target")
        bind_index = main_workflow_ids.index("bind_run_authorization")
        allowed_plan_nodes = set(main_workflow_ids[bind_index + 1 :])
        if delivery_target in {"testflight_uploaded", "testflight_distributed"}:
            upload_cutoff = continuation_workflow_ids.index("testflight_uploaded") + 1
            continuation_start = continuation_workflow_ids.index("health_gate") + 1
            allowed_plan_nodes.update(
                continuation_workflow_ids[continuation_start:upload_cutoff]
            )
        if delivery_target == "testflight_distributed":
            allowed_plan_nodes.update(
                continuation_workflow_ids[continuation_start:]
            )
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        installed_workflow_nodes = {}
        allowed_plan_nodes = set()
        errors.append("installed workflow contracts are unavailable; refusing authorization")
    for entry in resource_plan:
        if not isinstance(entry, dict) or set(entry) != {
            "plan_id", "resource", "resource_key", "descriptor_sha256",
            "resource_descriptor", "owner_actor", "protects",
        }:
            errors.append("authorization resource plan entry has invalid fields")
            continue
        plan_id = entry.get("plan_id")
        resource = entry.get("resource")
        resource_key = entry.get("resource_key")
        protects = entry.get("protects")
        if not isinstance(plan_id, str) or not plan_id or plan_id in plan_ids:
            errors.append("authorization resource plan IDs must be unique and non-empty")
        else:
            plan_ids.add(plan_id)
        if resource not in RESOURCE_SCOPES:
            errors.append("authorization resource plan uses an unknown resource")
        identity = (str(resource), str(resource_key))
        if (
            not isinstance(resource_key, str)
            or not resource_key.startswith(f"{resource}:sha256:")
            or identity in resource_identities
        ):
            errors.append("authorization resource plan identity is invalid or duplicated")
        else:
            resource_identities.add(identity)
        descriptor_sha = entry.get("descriptor_sha256")
        descriptor = entry.get("resource_descriptor")
        try:
            normalized_descriptor = resource_coordinator.normalize_descriptor(
                str(resource), descriptor
            )
            expected_descriptor_sha = resource_coordinator.descriptor_sha256(
                str(resource), normalized_descriptor
            )
            expected_resource_key = resource_coordinator.canonical_resource_key(
                str(resource), normalized_descriptor
            )
            if (
                descriptor != normalized_descriptor
                or descriptor_sha != expected_descriptor_sha
                or resource_key != expected_resource_key
            ):
                errors.append("authorization resource plan descriptor binding is invalid")
        except resource_coordinator.CoordinatorError:
            errors.append("authorization resource plan descriptor binding is invalid")
        if entry.get("owner_actor") != selected_writer:
            errors.append("authorization resource plan owner must be the selected writer")
        if (
            not isinstance(protects, list)
            or not protects
            or any(not isinstance(node, str) or not node for node in protects)
            or len(protects) != len(set(protects))
        ):
            errors.append("authorization resource plan protected nodes are invalid")
        elif any(node not in installed_workflow_nodes for node in protects):
            errors.append("authorization resource plan protects an unknown workflow node")
        elif any(node not in allowed_plan_nodes for node in protects):
            errors.append(
                "authorization resource plan protects a node outside its delivery target"
            )
        elif any(
            installed_workflow_nodes[node].get("lease_action") is not None
            or installed_workflow_nodes[node].get("terminal") is True
            for node in protects
        ):
            errors.append(
                "authorization resource plan may protect work nodes, not lease or terminal nodes"
            )
    if health_profile == "runtime_ui":
        runtime_nodes = {"verify", "reverify", "prepare_evidence"}
        build_plans = [
            entry for entry in resource_plan
            if isinstance(entry, dict) and entry.get("resource") == "build_tuple"
        ]
        runtime_plans = [
            entry for entry in resource_plan
            if isinstance(entry, dict)
            and entry.get("resource") in {"simulator_or_device", "macos_gui_session"}
        ]
        if not build_plans:
            errors.append("runtime_ui authorization requires a build_tuple resource plan")
        elif not any(runtime_nodes & set(entry.get("protects", [])) for entry in build_plans):
            errors.append("runtime_ui build plan must protect runtime verification work")
        if not runtime_plans:
            errors.append("runtime_ui authorization requires a device or macOS GUI resource plan")
        elif not any(runtime_nodes & set(entry.get("protects", [])) for entry in runtime_plans):
            errors.append("runtime_ui destination plan must protect runtime verification work")
    repository = envelope.get("repository")
    errors.extend(_object_shape(repository, set(REPOSITORY_FIELDS), set(REPOSITORY_FIELDS), "repository authorization"))
    if isinstance(repository, dict) and any(not repository.get(key) for key in REPOSITORY_FIELDS):
        errors.append("authorization must bind the exact repository and branch")
    if isinstance(repository, dict) and isinstance(repository.get("remote"), str):
        try:
            if repository_fingerprint(repository["remote"]) != repository.get("fingerprint"):
                errors.append("authorization repository fingerprint does not match its logical remote")
        except ValueError:
            errors.append("authorization repository remote is unsafe or unsupported")
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


def _standalone_ledger_lifecycle_errors(
    records: list[dict[str, Any]], coordinator_state: Path | None = None
) -> list[str]:
    errors: list[str] = []
    previous_sequence = 0
    previous_recorded_at: datetime | None = None
    run_id: str | None = None
    authorizations: dict[str, dict[str, Any]] = {}
    active: dict[tuple[Any, Any], dict[str, Any]] = {}
    reservations: dict[str, dict[str, Any]] = {}
    consumed_reservations: set[str] = set()
    dispatches: dict[str, dict[str, Any]] = {}
    claimed_reservations: set[str] = set()
    consumed_dispatches: set[str] = set()
    used_grants: set[tuple[str, str]] = set()
    used_keys: set[tuple[str, str]] = set()
    produced_targets: dict[tuple[str, str], str] = {}
    passed_nodes: set[str] = set()
    successful_operations: set[tuple[str, str, str]] = set()
    released_leases: dict[tuple[Any, Any, Any], dict[str, Any]] = {}
    workflow_lease_bindings: dict[str, dict[str, Any]] = {}
    resource_plans: dict[str, dict[str, Any]] = {}
    resource_plan_bindings: dict[str, tuple[Any, Any, Any]] = {}
    released_resource_plans: set[str] = set()
    evidence_ids: set[str] = set()
    passing_evidence: list[dict[str, Any]] = []
    try:
        main_nodes, continuation_nodes, workflow_nodes = _installed_workflow_contracts()
        installed_nodes = list(workflow_nodes.values())
        node_dependencies = {
            node["id"]: set(node.get("requires", [])) for node in installed_nodes
        }
        pending_acquires: dict[tuple[str, tuple[str, ...]], list[str]] = {}
        release_to_acquire: dict[str, str] = {}
        protected_by: dict[str, list[str]] = {}
        static_lease_signatures: set[tuple[str, tuple[str, ...]]] = set()
        for node in installed_nodes:
            action = node.get("lease_action")
            if action not in {"acquire", "release"}:
                continue
            protects = node.get("protects")
            if not isinstance(protects, list) or not protects:
                raise ValueError("installed workflow lease lacks protected nodes")
            signature = (str(node.get("resource")), tuple(protects))
            if action == "acquire":
                pending_acquires.setdefault(signature, []).append(node["id"])
                static_lease_signatures.add(signature)
                for protected in protects:
                    protected_by.setdefault(protected, []).append(node["id"])
            else:
                candidates = pending_acquires.get(signature, [])
                if not candidates:
                    raise ValueError("installed workflow lease pair is unbalanced")
                release_to_acquire[node["id"]] = candidates.pop(0)
        if any(candidates for candidates in pending_acquires.values()):
            raise ValueError("installed workflow lease pair is unbalanced")
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
                if payload.get("selected_writer") not in {"codex", "claude"}:
                    errors.append("run authorization approval has an invalid selected writer")
                try:
                    schema_id, schema_sha256 = installed_authorization_schema_binding()
                    if (
                        payload.get("contract_schema_id") != schema_id
                        or payload.get("contract_schema_sha256") != schema_sha256
                    ):
                        errors.append("run authorization approval schema binding drifted")
                except (OSError, ValueError, json.JSONDecodeError):
                    errors.append("installed approved authorization schema is unavailable")
                if payload.get("health_profile") not in HEALTH_PROFILES:
                    errors.append("run authorization approval has an invalid health profile")
                health = payload.get("health_attestation")
                if (
                    not isinstance(health, dict)
                    or health.get("profile") != payload.get("health_profile")
                    or health.get("overall_status") not in {"healthy", "degraded"}
                ):
                    errors.append("run authorization approval has an invalid health attestation")
                if re.fullmatch(
                    r"sha256:[0-9a-f]{64}",
                    str(payload.get("repository_fingerprint")),
                ) is None:
                    errors.append("run authorization approval must bind its repository fingerprint")
                if HEX_SHA.fullmatch(str(payload.get("repository_base_sha"))) is None:
                    errors.append("run authorization approval must bind its repository base SHA")
                approval_allowed_paths = payload.get("allowed_paths")
                if (
                    not _nonempty_strings(approval_allowed_paths)
                    or any(not _safe_relative_path(path) for path in approval_allowed_paths)
                ):
                    errors.append("run authorization approval must bind safe allowed paths")
                approval_acceptance_ids = payload.get("acceptance_ids")
                if (
                    not isinstance(approval_acceptance_ids, list)
                    or not approval_acceptance_ids
                    or len(approval_acceptance_ids) != len(set(approval_acceptance_ids))
                ):
                    errors.append("run authorization approval must bind acceptance IDs")
                plan_entries = payload.get("resource_plan")
                if not isinstance(plan_entries, list):
                    errors.append("run authorization approval must bind its resource plan")
                    plan_entries = []
                for entry in plan_entries:
                    if not isinstance(entry, dict):
                        errors.append("run authorization resource plan entry is invalid")
                        continue
                    plan_id = entry.get("plan_id")
                    identity = (entry.get("resource"), entry.get("resource_key"))
                    if not isinstance(plan_id, str) or not plan_id or plan_id in resource_plans:
                        errors.append("run authorization resource plan IDs must be unique")
                        continue
                    if any(
                        existing.get("resource") == identity[0]
                        and existing.get("resource_key") == identity[1]
                        for existing in resource_plans.values()
                    ):
                        errors.append("run authorization resource plan identity is duplicated")
                        continue
                    resource = entry.get("resource")
                    descriptor_sha = entry.get("descriptor_sha256")
                    protects = entry.get("protects")
                    if (
                        resource not in RESOURCE_SCOPES
                        or entry.get("resource_key") != f"{resource}:{descriptor_sha}"
                        or not isinstance(descriptor_sha, str)
                        or re.fullmatch(r"sha256:[0-9a-f]{64}", descriptor_sha) is None
                        or entry.get("owner_actor") != payload.get("selected_writer")
                        or not isinstance(entry.get("resource_descriptor"), dict)
                        or not isinstance(protects, list)
                        or not protects
                        or len(protects) != len(set(protects))
                        or any(node not in workflow_nodes for node in protects)
                    ):
                        errors.append("run authorization resource plan binding is invalid")
                        continue
                    try:
                        normalized_descriptor = resource_coordinator.normalize_descriptor(
                            str(resource), entry["resource_descriptor"]
                        )
                        if (
                            normalized_descriptor != entry["resource_descriptor"]
                            or resource_coordinator.descriptor_sha256(
                                str(resource), normalized_descriptor
                            )
                            != descriptor_sha
                            or resource_coordinator.canonical_resource_key(
                                str(resource), normalized_descriptor
                            )
                            != entry.get("resource_key")
                        ):
                            raise resource_coordinator.CoordinatorError(
                                "invalid_descriptor"
                            )
                    except resource_coordinator.CoordinatorError:
                        errors.append("run authorization resource plan binding is invalid")
                        continue
                    resource_plans[plan_id] = {
                        **entry,
                        "authorization_hash": digest,
                    }
        elif record_type == "time_interval":
            if payload.get("authorization_hash") not in authorizations:
                errors.append("time interval must follow its run authorization")
            try:
                if _timestamp(str(payload.get("ended_at"))) <= _timestamp(str(payload.get("started_at"))):
                    errors.append("time interval must have positive duration")
            except ValueError:
                errors.append("time interval timestamps are invalid")
        elif record_type == "evidence":
            evidence_id = payload.get("evidence_id")
            if (
                not isinstance(evidence_id, str)
                or not evidence_id
                or evidence_id in evidence_ids
            ):
                errors.append("evidence IDs must be unique and non-empty")
            else:
                evidence_ids.add(evidence_id)
            try:
                if patch_identity_v1(payload.get("patch_manifest")) != payload.get(
                    "patch_identity"
                ):
                    errors.append("evidence patch identity drifted from its manifest")
            except ValueError:
                errors.append("evidence must bind one valid patch_identity_v1 manifest")
            if re.fullmatch(
                r"sha256:[0-9a-f]{64}", str(payload.get("repository_fingerprint"))
            ) is None:
                errors.append("evidence must bind one repository fingerprint")
            acceptance_ids = payload.get("acceptance_ids")
            if (
                not isinstance(acceptance_ids, list)
                or not acceptance_ids
                or any(not isinstance(item, str) or not item for item in acceptance_ids)
                or len(acceptance_ids) != len(set(acceptance_ids))
            ):
                errors.append("evidence acceptance IDs must be unique and non-empty")
            if payload.get("outcome") == "passed":
                kind = payload.get("evidence_kind")
                tool_tuple = payload.get("tool_tuple")
                errors.extend(_evidence_tool_tuple_errors(payload, recorded_at))
                if kind == "review":
                    digest = tool_tuple.get("staged_diff_sha256") if isinstance(tool_tuple, dict) else None
                    if re.fullmatch(r"[0-9a-f]{64}", str(digest)) is None:
                        errors.append("passed review evidence must bind the staged diff digest")
                elif kind == "commit_equivalence":
                    if (
                        not _full_sha256(payload.get("local_sha"))
                        and not isinstance(payload.get("local_sha"), str)
                    ):
                        errors.append("passed commit evidence must bind a full local SHA")
                    if (
                        payload.get("local_sha") != payload.get("remote_sha")
                        or HEX_SHA.fullmatch(str(payload.get("local_sha"))) is None
                    ):
                        errors.append("passed commit evidence requires equal local and remote SHAs")
                elif kind == "publication":
                    if (
                        not isinstance(tool_tuple, dict)
                        or tool_tuple.get("viewable") is not True
                        or re.fullmatch(
                            r"sha256:[0-9a-f]{64}",
                            str(tool_tuple.get("readback_sha256")),
                        )
                        is None
                    ):
                        errors.append("passed publication evidence requires a viewable read-back digest")
                elif kind == "checks_readback":
                    if (
                        not isinstance(tool_tuple, dict)
                        or tool_tuple.get("required_checks_satisfied") is not True
                        or re.fullmatch(
                            r"sha256:[0-9a-f]{64}",
                            str(tool_tuple.get("readback_sha256")),
                        )
                        is None
                    ):
                        errors.append("passed checks evidence requires a satisfied read-back digest")
                if kind in {
                    "acceptance", "review", "commit_equivalence",
                    "spec_kit_checkpoint", "testflight_artifact", "publication",
                    "checks_readback",
                }:
                    passing_evidence.append(dict(payload))
                else:
                    errors.append("passed evidence kind is unsupported")
        elif record_type == "lease":
            key = (payload.get("resource"), payload.get("resource_key"))
            identity = (payload.get("lease_id"), payload.get("owner"))
            errors.extend(
                _coordinator_binding_errors(
                    run_id=record.get("run_id"),
                    lease_id=payload.get("lease_id"),
                    owner=payload.get("owner"),
                    resource=payload.get("resource"),
                    resource_key=payload.get("resource_key"),
                    descriptor=payload.get("resource_descriptor"),
                    receipt=payload.get("coordinator_receipt"),
                )
            )
            if payload.get("action") == "acquire":
                receipt = payload.get("coordinator_receipt", {})
                protects = payload.get("protects")
                descriptor = payload.get("resource_descriptor")
                approved_writers = {
                    item.get("selected_writer") for item in authorizations.values()
                    if item.get("selected_writer") in {"codex", "claude"}
                }
                if approved_writers and (
                    len(approved_writers) != 1
                    or payload.get("owner") not in approved_writers
                ):
                    errors.append("lease owner is not the approved selected writer")
                repository_bound = [
                    item.get("repository_fingerprint")
                    for item in authorizations.values()
                    if isinstance(item.get("repository_fingerprint"), str)
                ]
                if (
                    len(repository_bound) == 1
                    and isinstance(descriptor, dict)
                    and "repository_fingerprint" in descriptor
                    and descriptor.get("repository_fingerprint") != repository_bound[0]
                ):
                    errors.append(
                        "lease repository fingerprint drifted from run authorization"
                    )
                if payload.get("resource") in PROTECTS_REQUIRED_RESOURCES:
                    if not isinstance(protects, list) or not protects:
                        errors.append("extension-scoped lease must declare protected workflow nodes")
                    elif any(node_id not in node_dependencies for node_id in protects):
                        errors.append("extension-scoped lease protects an unknown workflow node")
                    elif set(protects) & passed_nodes:
                        errors.append(
                            "extension-scoped lease was acquired after its protected workflow node"
                        )
                signature = (
                    str(payload.get("resource")),
                    tuple(protects) if isinstance(protects, list) else tuple(),
                )
                exact_plan_ids = [
                    plan_id
                    for plan_id, plan in resource_plans.items()
                    if plan.get("resource") == payload.get("resource")
                    and plan.get("resource_key") == payload.get("resource_key")
                    and plan.get("descriptor_sha256") == receipt.get("descriptor_sha256")
                    and plan.get("resource_descriptor") == descriptor
                    and plan.get("owner_actor") == payload.get("owner")
                    and plan.get("protects") == protects
                ]
                same_plan_identity = any(
                    plan.get("resource") == payload.get("resource")
                    and plan.get("resource_key") == payload.get("resource_key")
                    for plan in resource_plans.values()
                )
                if len(exact_plan_ids) == 1:
                    plan_id = exact_plan_ids[0]
                    if plan_id in resource_plan_bindings:
                        errors.append("authorization resource plan cannot bind more than one lease")
                    else:
                        resource_plan_bindings[plan_id] = (
                            payload.get("resource"),
                            payload.get("resource_key"),
                            payload.get("lease_id"),
                        )
                elif len(exact_plan_ids) > 1:
                    errors.append("lease matches multiple authorization resource plans")
                elif same_plan_identity:
                    errors.append("lease drifted from its authorization resource plan")
                elif (
                    authorizations
                    and isinstance(protects, list)
                    and protects
                    and signature not in static_lease_signatures
                ):
                    errors.append("dynamic workflow lease lacks an exact authorized resource plan")
                if (
                    payload.get("acquired_at") != receipt.get("acquired_at")
                    or payload.get("expires_at") != receipt.get("expires_at")
                ):
                    errors.append("lease acquisition times drifted from its coordinator receipt")
                conflicts = any(
                    _coordinated_leases_conflict(payload, current)
                    for current in active.values()
                )
                if key in active or conflicts:
                    errors.append("ledger has overlapping active resource leases")
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
                elif (
                    current.get("resource_descriptor") != payload.get("resource_descriptor")
                    or current.get("coordinator_receipt") != payload.get("coordinator_receipt")
                    or current.get("protects", []) != payload.get("protects", [])
                ):
                    errors.append("lease release drifted from its coordinator binding")
                else:
                    unmet = set(current.get("protects", [])) - passed_nodes
                    if unmet:
                        errors.append(
                            "lease release preceded protected workflow nodes: "
                            + ", ".join(sorted(unmet))
                        )
                    recovery_errors = _lease_release_recovery_errors(
                        current, payload, coordinator_state=coordinator_state
                    )
                    errors.extend(recovery_errors)
                    if not recovery_errors and not unmet:
                        released_identity = (
                            payload.get("resource"),
                            payload.get("resource_key"),
                            payload.get("lease_id"),
                        )
                        for plan_id, binding in resource_plan_bindings.items():
                            if binding == released_identity:
                                released_resource_plans.add(plan_id)
                        released_leases[
                            (
                                payload.get("resource"),
                                payload.get("resource_key"),
                                payload.get("lease_id"),
                            )
                        ] = dict(payload)
                        del active[key]
            elif payload.get("action") == "heartbeat":
                current = active.get(key)
                if current is None or (current.get("lease_id"), current.get("owner")) != identity:
                    errors.append("lease heartbeat does not match its active lease")
                elif current.get("protects", []) != payload.get("protects", []):
                    errors.append("lease heartbeat drifted from its protected workflow nodes")
                else:
                    try:
                        heartbeat = _timestamp(str(payload.get("heartbeat_at")))
                        old_expiry = _timestamp(str(current.get("expires_at")))
                        new_expiry = _timestamp(str(payload.get("expires_at")))
                        if heartbeat >= old_expiry or new_expiry <= old_expiry:
                            errors.append("lease heartbeat must be timely and extend expiry")
                        else:
                            current_receipt = current.get("coordinator_receipt", {})
                            next_receipt = payload.get("coordinator_receipt", {})
                            stable = COORDINATOR_RECEIPT_FIELDS - {"expires_at"}
                            if any(current_receipt.get(field) != next_receipt.get(field) for field in stable):
                                errors.append("lease heartbeat changed its coordinator receipt identity")
                            current["expires_at"] = payload.get("expires_at")
                            current["coordinator_receipt"] = next_receipt
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
            if re.fullmatch(
                r"sha256:[0-9a-f]{64}", str(payload.get("health_report_sha256"))
            ) is None:
                errors.append("grant reservation must bind its evaluated health report")
            grant: dict[str, Any] | None = None
            if authorization is None:
                errors.append("grant reservation must follow its run authorization")
            else:
                if (
                    payload.get("writer_actor") != authorization.get("selected_writer")
                    or payload.get("lease_owner") != authorization.get("selected_writer")
                ):
                    errors.append("grant reservation writer drifted from authorization")
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
                or lease.get("resource_descriptor") != payload.get("resource_descriptor")
                or lease.get("coordinator_receipt") != payload.get("coordinator_receipt")
            ):
                errors.append("grant reservation lacks its exact active lease")
            else:
                try:
                    if recorded_at is None or recorded_at >= _timestamp(str(lease.get("expires_at"))):
                        errors.append("grant reservation cannot use an expired lease")
                except ValueError:
                    errors.append("grant reservation lease expiry is invalid")
                if lease.get("approval_id") != authorization.get("approval_id"):
                    errors.append(
                        "grant reservation lease is not bound to the authorization"
                    )
            if grant_key in used_grants or idempotency_key in used_keys:
                errors.append("grant or idempotency key is already reserved")
            used_grants.add(grant_key)
            used_keys.add(idempotency_key)
            if reservation_id:
                reservations[reservation_id] = dict(payload)
        elif record_type == "grant_dispatch":
            reservation_id = payload.get("reservation_id")
            dispatch_id = payload.get("dispatch_id")
            reservation = reservations.get(reservation_id)
            if (
                reservation is None
                or reservation_id in claimed_reservations
                or not isinstance(dispatch_id, str)
                or not dispatch_id
                or dispatch_id in dispatches
            ):
                errors.append("grant dispatch requires one unclaimed exact reservation")
            elif not _receipt_lineage_compatible(
                reservation.get("coordinator_receipt"),
                payload.get("coordinator_receipt"),
            ):
                errors.append("grant dispatch drifted from its reservation fence")
            elif payload.get("health_report_sha256") != reservation.get(
                "health_report_sha256"
            ):
                errors.append("grant dispatch drifted from its reserved health report")
            else:
                lease = active.get(
                    (reservation.get("resource"), reservation.get("resource_key"))
                )
                if (
                    lease is None
                    or lease.get("lease_id") != reservation.get("lease_id")
                    or lease.get("owner") != reservation.get("lease_owner")
                    or lease.get("coordinator_receipt")
                    != payload.get("coordinator_receipt")
                ):
                    errors.append("grant dispatch requires its exact active reservation lease")
                try:
                    lease_expiry = _timestamp(
                        str(payload.get("coordinator_receipt", {}).get("expires_at"))
                    )
                    dispatch_deadline = _timestamp(
                        str(payload.get("dispatch_deadline"))
                    )
                    dispatch_authorization = authorizations.get(
                        reservation.get("authorization_hash")
                    )
                    if (
                        recorded_at is None
                        or recorded_at >= dispatch_deadline
                        or (
                            dispatch_deadline - recorded_at
                        ).total_seconds() > MAX_DISPATCH_WINDOW_SECONDS
                        or dispatch_deadline > lease_expiry
                        or not isinstance(dispatch_authorization, dict)
                        or dispatch_deadline
                        > _timestamp(
                            str(dispatch_authorization.get("expires_at"))
                        )
                    ):
                        errors.append("grant dispatch cannot use an expired lease")
                except ValueError:
                    errors.append("grant dispatch deadline is invalid")
                claimed_reservations.add(str(reservation_id))
                dispatches[dispatch_id] = dict(payload)
        elif record_type == "external_write":
            reservation_id = payload.get("reservation_id")
            dispatch_id = payload.get("dispatch_id")
            reservation = reservations.get(reservation_id)
            if reservation is None or reservation_id in consumed_reservations:
                errors.append("external write requires one unconsumed exact reservation")
            else:
                for field in (
                    "authorization_hash", "grant_id", "idempotency_key", "system",
                    "action", "operation", "operation_input", "constraint_sha256",
                    "resource_key", "phase", "lease_id", "lease_owner", "resource",
                    "resource_descriptor", "target", "spec_checkpoint_sha256",
                    "apple_observation_sha256", "writer_actor",
                    "health_report_sha256",
                ):
                    if reservation.get(field) != payload.get(field):
                        errors.append("external write drifted from its reservation")
                        break
                if not _receipt_lineage_compatible(
                    reservation.get("coordinator_receipt"),
                    payload.get("coordinator_receipt"),
                ):
                    errors.append("external write drifted from its reservation receipt lineage")
                consumed_reservations.add(str(reservation_id))
            dispatch = dispatches.get(dispatch_id)
            if dispatch is None or dispatch_id in consumed_dispatches:
                errors.append("external write requires one unconsumed dispatch claim")
            elif (
                dispatch.get("reservation_id") != reservation_id
                or not _receipt_lineage_compatible(
                    dispatch.get("coordinator_receipt"),
                    payload.get("coordinator_receipt"),
                )
            ):
                errors.append("external write drifted from its dispatch claim")
            else:
                consumed_dispatches.add(str(dispatch_id))
            lease = active.get((payload.get("resource"), payload.get("resource_key")))
            if (
                lease is None
                or lease.get("lease_id") != payload.get("lease_id")
                or lease.get("owner") != payload.get("lease_owner")
                or payload.get("action") not in lease.get("allowed_actions", [])
                or lease.get("resource_descriptor") != payload.get("resource_descriptor")
                or lease.get("coordinator_receipt") != payload.get("coordinator_receipt")
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

                patch_identity = payload.get("patch_identity")
                authorization = (
                    next(iter(authorizations.values()))
                    if len(authorizations) == 1
                    else None
                )
                if node_id in PATCH_BOUND_NODES or node_id in protected_by:
                    try:
                        if (
                            authorization is None
                            or recorded_at is None
                            or not _timestamp(str(authorization.get("issued_at")))
                            <= recorded_at
                            < _timestamp(str(authorization.get("expires_at")))
                        ):
                            errors.append(
                                f"workflow node {node_id} is outside run authorization time bounds"
                            )
                    except ValueError:
                        errors.append(
                            f"workflow node {node_id} has invalid run authorization time bounds"
                        )
                repository_fingerprint = (
                    authorization.get("repository_fingerprint")
                    if authorization is not None
                    else None
                )
                if node_id in PATCH_BOUND_NODES:
                    try:
                        manifest = payload.get("patch_manifest")
                        if patch_identity_v1(manifest) != patch_identity:
                            raise ValueError("digest drift")
                        if (
                            authorization is None
                            or manifest.get("base_sha")
                            != authorization.get("repository_base_sha")
                            or any(
                                not _path_allowed(
                                    record["path"],
                                    authorization.get("allowed_paths", []),
                                )
                                for record in manifest.get("records", [])
                            )
                        ):
                            raise ValueError("authorization drift")
                    except (AttributeError, KeyError, TypeError, ValueError):
                        errors.append(
                            f"workflow node {node_id} must recompute one authorized patch_identity_v1 manifest"
                        )
                current_evidence = [
                    item
                    for item in passing_evidence
                    if item.get("patch_identity") == patch_identity
                    and item.get("repository_fingerprint") == repository_fingerprint
                ]
                acceptance_coverage = {
                    acceptance_id
                    for item in current_evidence
                    if item.get("evidence_kind") == "acceptance"
                    for acceptance_id in item.get("acceptance_ids", [])
                }
                required_acceptance = set(
                    authorization.get("acceptance_ids", [])
                    if authorization is not None
                    else []
                )
                acceptance_nodes = {
                    "verify", "reverify", "prepare_evidence", "prepare_pr",
                    "repository_confirmation", "commit", "push",
                    "verify_remote_sha", "create_pr", "publish_evidence",
                    "verify_published_evidence", "checks", "pr_ready",
                }
                review_nodes = {
                    "review", "prepare_evidence", "prepare_pr",
                    "repository_confirmation", "commit", "push",
                    "verify_remote_sha", "create_pr", "publish_evidence",
                    "verify_published_evidence", "checks", "pr_ready",
                }
                commit_nodes = {
                    "verify_remote_sha", "create_pr", "publish_evidence",
                    "verify_published_evidence", "checks", "pr_ready",
                }
                publication_nodes = {"verify_published_evidence", "checks", "pr_ready"}
                if node_id in acceptance_nodes and (
                    authorization is None
                    or not required_acceptance
                    or not required_acceptance <= acceptance_coverage
                ):
                    errors.append(
                        f"workflow node {node_id} lacks current complete acceptance evidence"
                    )
                if node_id in review_nodes and not any(
                    item.get("evidence_kind") == "review" for item in current_evidence
                ):
                    errors.append(
                        f"workflow node {node_id} lacks current review evidence"
                    )
                if node_id in commit_nodes and not any(
                    item.get("evidence_kind") == "commit_equivalence"
                    and item.get("local_sha") == item.get("remote_sha")
                    for item in current_evidence
                ):
                    errors.append(
                        f"workflow node {node_id} lacks current commit equivalence evidence"
                    )
                if node_id in publication_nodes and not any(
                    item.get("evidence_kind") == "publication"
                    and isinstance(item.get("tool_tuple"), dict)
                    and item["tool_tuple"].get("viewable") is True
                    for item in current_evidence
                ):
                    errors.append(
                        f"workflow node {node_id} lacks current viewable publication evidence"
                    )
                if node_id in {"checks", "pr_ready"} and not any(
                    item.get("evidence_kind") == "checks_readback"
                    and isinstance(item.get("tool_tuple"), dict)
                    and item["tool_tuple"].get("required_checks_satisfied") is True
                    for item in current_evidence
                ):
                    errors.append(
                        f"workflow node {node_id} lacks current required-checks read-back evidence"
                    )

                for plan_id, plan in resource_plans.items():
                    if node_id not in plan.get("protects", []):
                        continue
                    binding = resource_plan_bindings.get(plan_id)
                    if binding is None:
                        errors.append(
                            f"workflow node {node_id} passed without planned resource lease {plan_id}"
                        )
                        continue
                    active_lease = active.get((binding[0], binding[1]))
                    if active_lease is None or active_lease.get("lease_id") != binding[2]:
                        errors.append(
                            f"workflow node {node_id} passed outside planned resource lease {plan_id}"
                        )
                    else:
                        try:
                            if (
                                recorded_at is None
                                or not _timestamp(str(active_lease.get("acquired_at")))
                                <= recorded_at
                                < _timestamp(str(active_lease.get("expires_at")))
                            ):
                                errors.append(
                                    f"workflow node {node_id} passed outside planned resource lease {plan_id} time bounds"
                                )
                        except ValueError:
                            errors.append(
                                f"workflow node {node_id} has invalid planned lease time bounds"
                            )

                for acquire_node_id in protected_by.get(node_id, []):
                    binding = workflow_lease_bindings.get(acquire_node_id)
                    if binding is None:
                        errors.append(
                            f"workflow node {node_id} passed without its bound active lease"
                        )
                        continue
                    active_lease = active.get(
                        (binding["resource"], binding["resource_key"])
                    )
                    if (
                        active_lease is None
                        or active_lease.get("lease_id") != binding["lease_id"]
                    ):
                        errors.append(
                            f"workflow node {node_id} passed outside its bound lease interval"
                        )
                    else:
                        try:
                            if (
                                recorded_at is None
                                or not _timestamp(str(active_lease.get("acquired_at")))
                                <= recorded_at
                                < _timestamp(str(active_lease.get("expires_at")))
                            ):
                                errors.append(
                                    f"workflow node {node_id} passed outside its bound lease time interval"
                                )
                        except ValueError:
                            errors.append(
                                f"workflow node {node_id} has invalid bound lease time interval"
                            )

                contract_node = workflow_nodes[node_id]
                lease_action = contract_node.get("lease_action")
                if lease_action == "acquire":
                    binding = {
                        "resource": payload.get("lease_resource"),
                        "resource_key": payload.get("lease_resource_key"),
                        "lease_id": payload.get("lease_id"),
                    }
                    expected_resource = contract_node.get("resource")
                    active_lease = active.get(
                        (binding["resource"], binding["resource_key"])
                    )
                    if (
                        binding["resource"] != expected_resource
                        or not all(isinstance(binding[field], str) and binding[field]
                                   for field in binding)
                        or active_lease is None
                        or active_lease.get("lease_id") != binding["lease_id"]
                        or active_lease.get("protects") != contract_node.get("protects")
                    ):
                        errors.append(
                            f"workflow lease-acquire node {node_id} lacks its exact active lease binding"
                        )
                    elif any(
                        existing == binding for existing in workflow_lease_bindings.values()
                    ):
                        errors.append("one lease cannot satisfy multiple workflow acquire nodes")
                    else:
                        workflow_lease_bindings[node_id] = binding
                elif lease_action == "release":
                    acquire_node_id = release_to_acquire.get(node_id)
                    binding = workflow_lease_bindings.get(str(acquire_node_id))
                    recorded_binding = {
                        "resource": payload.get("lease_resource"),
                        "resource_key": payload.get("lease_resource_key"),
                        "lease_id": payload.get("lease_id"),
                    }
                    if (
                        binding is None
                        or recorded_binding != binding
                        or (
                            binding["resource"], binding["resource_key"],
                            binding["lease_id"],
                        ) not in released_leases
                    ):
                        errors.append(
                            f"workflow lease-release node {node_id} lacks its exact released lease binding"
                        )
                passed_nodes.add(node_id)
            if node_id in {"pr_ready", "testflight_uploaded", "testflight_distributed"} and active:
                errors.append("terminal node cannot pass with an active lease")
            if node_id in {"pr_ready", "testflight_uploaded", "testflight_distributed"}:
                unreleased_plans = {
                    plan_id
                    for plan_id, plan in resource_plans.items()
                    if set(plan.get("protects", [])) <= passed_nodes
                    and plan_id not in released_resource_plans
                }
                if unreleased_plans:
                    errors.append(
                        "terminal node requires every applicable resource plan to be released: "
                        + ", ".join(sorted(unreleased_plans))
                    )
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


def _ledger_contract_errors(
    records: list[dict[str, Any]], coordinator_state: Path | None = None
) -> list[str]:
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
    if errors:
        return sorted(set(errors))
    errors.extend(
        _standalone_ledger_lifecycle_errors(
            records, coordinator_state=coordinator_state
        )
    )
    return sorted(set(errors))


def _active_leases(
    records: list[dict[str, Any]],
    coordinator_state: Path | None = None,
) -> tuple[dict[tuple[Any, Any], dict[str, Any]], list[str]]:
    active: dict[tuple[Any, Any], dict[str, Any]] = {}
    errors: list[str] = []
    for record in records:
        if record.get("record_type") != "lease" or not isinstance(record.get("payload"), dict):
            continue
        payload = record["payload"]
        key = (payload.get("resource"), payload.get("resource_key"))
        errors.extend(
            _coordinator_binding_errors(
                run_id=record.get("run_id"),
                lease_id=payload.get("lease_id"),
                owner=payload.get("owner"),
                resource=payload.get("resource"),
                resource_key=payload.get("resource_key"),
                descriptor=payload.get("resource_descriptor"),
                receipt=payload.get("coordinator_receipt"),
            )
        )
        if payload.get("action") == "acquire":
            receipt = payload.get("coordinator_receipt", {})
            if (
                payload.get("acquired_at") != receipt.get("acquired_at")
                or payload.get("expires_at") != receipt.get("expires_at")
            ):
                errors.append("ledger lease acquisition times drifted from its coordinator receipt")
            conflicts = any(
                _coordinated_leases_conflict(payload, current)
                for current in active.values()
            )
            if key in active or conflicts:
                errors.append("ledger lease replay found an overlapping acquire")
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
                    current_receipt = current.get("coordinator_receipt", {})
                    next_receipt = payload.get("coordinator_receipt", {})
                    stable = COORDINATOR_RECEIPT_FIELDS - {"expires_at"}
                    if any(current_receipt.get(field) != next_receipt.get(field) for field in stable):
                        errors.append("ledger lease heartbeat changed its coordinator receipt identity")
                    current["heartbeat_at"] = payload.get("heartbeat_at")
                    current["expires_at"] = payload.get("expires_at")
                    current["coordinator_receipt"] = next_receipt
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
            elif (
                current.get("resource_descriptor") != payload.get("resource_descriptor")
                or current.get("coordinator_receipt") != payload.get("coordinator_receipt")
            ):
                errors.append("ledger lease release drifted from its coordinator binding")
            else:
                recovery_errors = _lease_release_recovery_errors(
                    current, payload, coordinator_state=coordinator_state
                )
                errors.extend(recovery_errors)
                if not recovery_errors:
                    del active[key]
    return active, errors


def _coordinator_binding_errors(
    *,
    run_id: Any,
    lease_id: Any,
    owner: Any,
    resource: Any,
    resource_key: Any,
    descriptor: Any,
    receipt: Any,
    now: datetime | None = None,
) -> list[str]:
    """Validate the immutable per-run binding to one coordinator receipt."""
    errors = _object_shape(
        receipt,
        COORDINATOR_RECEIPT_FIELDS,
        COORDINATOR_RECEIPT_FIELDS,
        "coordinator receipt",
    )
    if not isinstance(descriptor, dict) or not isinstance(resource, str):
        return errors + ["resource lease requires a structured descriptor"]
    try:
        normalized = resource_coordinator.normalize_descriptor(resource, descriptor)
        expected_digest = resource_coordinator.descriptor_sha256(resource, normalized)
        expected_key = resource_coordinator.canonical_resource_key(resource, normalized)
    except resource_coordinator.CoordinatorError:
        return errors + ["resource lease descriptor is invalid"]
    if normalized != descriptor:
        errors.append("resource lease descriptor is not canonical")
    if resource_key != expected_key:
        errors.append("resource lease key does not match its canonical descriptor")
    if not isinstance(receipt, dict):
        return errors
    expected = {
        "lease_id": lease_id,
        "owner_run_id": run_id,
        "owner_actor": owner,
        "resource": resource,
        "resource_key": expected_key,
        "descriptor_sha256": expected_digest,
    }
    for field, value in expected.items():
        if receipt.get(field) != value:
            errors.append(f"coordinator receipt {field} drifted from the lease")
    if resource in {
        resource_coordinator.SIMULATOR,
        resource_coordinator.CORE_SIMULATOR,
        resource_coordinator.MACOS_GUI,
    } and descriptor.get("coordinator_instance_id") != receipt.get(
        "coordinator_instance_id"
    ):
        errors.append("resource descriptor is bound to a different coordinator instance")
    if not isinstance(receipt.get("fencing_token"), int) or isinstance(
        receipt.get("fencing_token"), bool
    ) or receipt.get("fencing_token", 0) <= 0:
        errors.append("coordinator receipt fencing token is invalid")
    try:
        acquired_at = _timestamp(str(receipt.get("acquired_at", "")))
        expires_at = _timestamp(str(receipt.get("expires_at", "")))
        if expires_at <= acquired_at:
            errors.append("coordinator receipt time range is invalid")
        if now is not None and not acquired_at <= now < expires_at:
            errors.append("coordinator receipt is not live for the protected action")
    except ValueError:
        errors.append("coordinator receipt timestamps are invalid")
    return errors


def _coordinated_leases_conflict(
    left: dict[str, Any], right: dict[str, Any]
) -> bool:
    left_receipt = left.get("coordinator_receipt")
    right_receipt = right.get("coordinator_receipt")
    if not isinstance(left_receipt, dict) or not isinstance(right_receipt, dict):
        return True
    if left_receipt.get("coordinator_instance_id") != right_receipt.get(
        "coordinator_instance_id"
    ):
        return False
    try:
        left_resource = str(left.get("resource"))
        right_resource = str(right.get("resource"))
        left_descriptor = resource_coordinator.normalize_descriptor(
            left_resource, left.get("resource_descriptor")
        )
        right_descriptor = resource_coordinator.normalize_descriptor(
            right_resource, right.get("resource_descriptor")
        )
        conflicts = resource_coordinator.descriptors_conflict(
            left_resource, left_descriptor, right_resource, right_descriptor
        )
        if not conflicts:
            return False
        return not resource_coordinator.same_owner_nested_compatible(
            left_resource,
            right_resource,
            str(left_receipt.get("owner_run_id")),
            str(left_receipt.get("owner_actor")),
            str(right_receipt.get("owner_run_id")),
            str(right_receipt.get("owner_actor")),
            left_descriptor,
            right_descriptor,
        )
    except resource_coordinator.CoordinatorError:
        return True


def _lease_release_recovery_errors(
    current: dict[str, Any],
    release: dict[str, Any],
    *,
    coordinator_state: Path | None = None,
) -> list[str]:
    """Bind normal release or expiry recovery to coordinator state."""
    errors: list[str] = []
    try:
        released_at = _timestamp(str(release.get("released_at", "")))
        expires_at = _timestamp(str(current.get("expires_at", "")))
    except ValueError:
        return ["lease release or expiry timestamp is invalid"]
    evidence = release.get("recovery_evidence")
    confirmation = release.get("recovery_confirmation")
    release_confirmation = release.get("coordinator_release_confirmation")
    if released_at < expires_at:
        if evidence is not None or confirmation is not None:
            errors.append("unexpired lease release cannot claim coordinator recovery")
        if not resource_coordinator.validate_release_confirmation(
            current.get("coordinator_receipt"),
            release_confirmation,
            state_path=coordinator_state,
        ):
            errors.append("lease release confirmation is invalid or not live")
        elif release_confirmation.get("released_at") != release.get("released_at"):
            errors.append("lease release time drifted from coordinator confirmation")
        return errors
    if release_confirmation is not None:
        errors.append("expired lease recovery cannot carry a normal release confirmation")
    if not isinstance(evidence, dict) or not isinstance(confirmation, dict):
        return ["expired lease release requires coordinator recovery evidence"]
    try:
        resource_coordinator._recovery_evidence(
            evidence, current.get("coordinator_receipt"), released_at
        )
    except resource_coordinator.CoordinatorError as error:
        errors.append(f"expired lease recovery evidence is invalid: {error.code}")
    if not resource_coordinator.validate_recovery_confirmation(
        current.get("coordinator_receipt"),
        evidence,
        confirmation,
        state_path=coordinator_state,
    ):
        errors.append("expired lease recovery confirmation is invalid")
    else:
        try:
            recovered_at = _timestamp(str(confirmation.get("recovered_at", "")))
            if recovered_at < expires_at or recovered_at > released_at:
                errors.append("expired lease recovery time is outside its valid range")
        except ValueError:
            errors.append("expired lease recovery time is invalid")
    return errors


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


def apple_observation_state_sha256(observation: dict[str, Any]) -> str:
    """Hash stable guarded ASC state while excluding the observation timestamp."""
    return canonical_sha256(
        {
            field: observation.get(field)
            for field in APPLE_OBSERVATION_STABLE_FIELDS
        }
    )


def authorize_action(
    envelope: dict[str, Any], request: dict[str, Any], now: datetime | None = None,
    ledger_records: list[dict[str, Any]] | None = None,
    policy_overlay: dict[str, Any] | None = None,
    live_repository: dict[str, Any] | None = None,
    live_spec_snapshot: dict[str, Any] | None = None,
    live_apple_observation: dict[str, Any] | None = None,
    verified_coordinator_receipt: dict[str, Any] | None = None,
    coordinator_state: Path | None = None,
    selected_writer: str | None = None,
    verified_health_attestation: dict[str, Any] | None = None,
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
    if selected_writer not in {"codex", "claude"}:
        errors.append("selected writer is unavailable from the trusted harness")
    elif envelope.get("selected_writer") != selected_writer:
        errors.append("selected writer drifted from the authorization")
    if request.get("writer_actor") != selected_writer:
        errors.append("action request writer is not the selected writer")
    if request.get("lease_owner") != selected_writer:
        errors.append("action lease owner is not the selected writer")
    action = request.get("action")
    if action in FORBIDDEN_ACTIONS or action not in ALLOWED_ACTIONS:
        errors.append("requested action is forbidden or not allowlisted")
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        errors.append("current time must be timezone aware")
    errors.extend(
        _live_health_errors(
            envelope, request, verified_health_attestation, now
        )
    )
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
    errors.extend(
        _ledger_contract_errors(records, coordinator_state=coordinator_state)
    )
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
        staged_manifest = live_repository.get("staged_patch_manifest")
        staged_identity = live_repository.get("staged_patch_identity")
        if not isinstance(staged_manifest, dict) or not isinstance(
            staged_identity, str
        ):
            errors.append("git.commit requires one non-empty live staged patch manifest")
        review_evidence = [
            record for record in records
            if record.get("record_type") == "evidence"
            and record.get("run_id") == envelope.get("run_id")
            and record.get("payload", {}).get("evidence_kind") == "review"
            and record.get("payload", {}).get("outcome") == "passed"
            and record.get("payload", {}).get("repository_fingerprint") == expected_repository.get("fingerprint")
            and record.get("payload", {}).get("tool_tuple", {}).get("staged_diff_sha256") == staged_digest
            and record.get("payload", {}).get("patch_manifest") == staged_manifest
            and record.get("payload", {}).get("patch_identity") == staged_identity
        ]
        if len(review_evidence) != 1:
            errors.append("git.commit requires one review of the exact live staged diff")
    if action == "git.push" and isinstance(live_repository, dict):
        if paths != live_repository.get("outgoing_paths"):
            errors.append("git.push paths must exactly match the live outgoing commit paths")
        head_sha = live_repository.get("head_sha")
        head_manifest = live_repository.get("head_patch_manifest")
        head_identity = live_repository.get("head_patch_identity")
        if not isinstance(head_manifest, dict) or not isinstance(head_identity, str):
            errors.append("git.push requires one non-empty live committed patch manifest")
        equivalence = [
            record for record in records
            if record.get("record_type") == "evidence"
            and record.get("run_id") == envelope.get("run_id")
            and record.get("payload", {}).get("evidence_kind") == "commit_equivalence"
            and record.get("payload", {}).get("outcome") == "passed"
            and record.get("payload", {}).get("repository_fingerprint") == expected_repository.get("fingerprint")
            and record.get("payload", {}).get("local_sha") == head_sha
            and record.get("payload", {}).get("patch_manifest") == head_manifest
            and record.get("payload", {}).get("patch_identity") == head_identity
        ]
        if len(equivalence) != 1:
            errors.append("git.push requires one commit-equivalence proof for the live HEAD")
    writes = _external_writes(records)
    expected_resource = _expected_lease_resource(action)
    try:
        canonical_descriptor = canonical_resource_descriptor(envelope, str(action))
        canonical_resource_key = canonical_lease_resource_key(envelope, str(action))
        if request.get("lease_resource_key") != canonical_resource_key:
            errors.append("action lease resource key is not the canonical authorized key")
        if request.get("resource_descriptor") != canonical_descriptor:
            errors.append("action resource descriptor is not the canonical authorized descriptor")
    except ValueError:
        canonical_descriptor = None
        errors.append("action lease resource key cannot be derived")
    errors.extend(
        _coordinator_binding_errors(
            run_id=request.get("run_id"),
            lease_id=request.get("lease_id"),
            owner=request.get("lease_owner"),
            resource=request.get("lease_resource"),
            resource_key=request.get("lease_resource_key"),
            descriptor=request.get("resource_descriptor"),
            receipt=request.get("coordinator_receipt"),
            now=now,
        )
    )
    if verified_coordinator_receipt is None:
        errors.append("coordination_required: live coordinator receipt is unavailable")
    elif verified_coordinator_receipt != request.get("coordinator_receipt"):
        errors.append("live coordinator receipt drifted from the action request")
    active, lease_replay_errors = _active_leases(
        records, coordinator_state=coordinator_state
    )
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
        or observed_lease.get("resource_descriptor") != request.get("resource_descriptor")
        or observed_lease.get("coordinator_receipt") != request.get("coordinator_receipt")
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
        and record["payload"].get("selected_writer") == envelope.get("selected_writer")
        and record["payload"].get("contract_schema_id")
        == envelope.get("contract_schema_id")
        and record["payload"].get("contract_schema_sha256")
        == envelope.get("contract_schema_sha256")
        and record["payload"].get("health_profile") == envelope.get("health_profile")
        and record["payload"].get("health_attestation")
        == envelope.get("health_attestation")
        and record["payload"].get("resource_plan") == envelope.get("resource_plan")
        and record["payload"].get("repository_fingerprint")
        == envelope.get("repository", {}).get("fingerprint")
        and record["payload"].get("repository_base_sha")
        == envelope.get("repository", {}).get("base_sha")
        and record["payload"].get("allowed_paths") == envelope.get("allowed_paths")
        and record["payload"].get("acceptance_ids") == envelope.get("acceptance_ids")
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


def validate_coordinator_binding(
    coordinator_state: Path | None, binding: Any
) -> list[str]:
    """Bind protected actions to the coordinator selected by the private harness."""
    if coordinator_state is None or not isinstance(binding, dict):
        return ["coordination_required: trusted coordinator binding is unavailable"]
    try:
        resource_coordinator.validate_trusted_binding(coordinator_state, binding)
    except resource_coordinator.CoordinatorError as error:
        return [f"coordination_required: {error.code}"]
    return []


def verify_health_report(
    health_report_path: Path,
    harness_path: Path,
    run_root: Path,
) -> tuple[list[str], dict[str, Any] | None]:
    """Run the exact installed health evaluator and derive a portable attestation."""
    try:
        canonical_run_root = run_root.resolve(strict=True)
        if (
            health_report_path.is_symlink()
            or health_report_path.parent.resolve(strict=True) != canonical_run_root
            or not health_report_path.is_file()
        ):
            return ["health report must be a regular non-symlink file directly under the private run root"], None
        raw_report_bytes = health_report_path.read_bytes()
        raw_report = json.loads(raw_report_bytes.decode("utf-8"))
        raw_report_bytes_sha256 = "sha256:" + hashlib.sha256(
            raw_report_bytes
        ).hexdigest()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return [f"health report cannot be read safely: {error}"], None
    evaluator = (
        Path(__file__).resolve().parents[2]
        / "apple-development-health"
        / "scripts"
        / "evaluate_health.py"
    )
    if evaluator.is_symlink() or not evaluator.is_file():
        return ["installed health evaluator is unavailable"], None
    try:
        completed = subprocess.run(
            [
                sys.executable,
                str(evaluator),
                str(health_report_path),
                "--harness",
                str(harness_path),
                "--expected-report-bytes-sha256",
                raw_report_bytes_sha256,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        result = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        return [f"live health evaluator failed: {error}"], None
    evaluator_errors = result.get("errors") if isinstance(result, dict) else None
    if (
        completed.returncode != 0
        or not isinstance(result, dict)
        or result.get("valid") is not True
        or not isinstance(result.get("report"), dict)
    ):
        details = evaluator_errors if isinstance(evaluator_errors, list) else []
        return ["live health evaluation blocked"] + [str(item) for item in details], None
    evaluated = result["report"]
    manifest = raw_report.get("agent_skill_manifest")
    coordinator = raw_report.get("resource_coordinator_observation")
    if not isinstance(manifest, dict) or not isinstance(coordinator, dict):
        return ["live health report lacks required identity observations"], None
    attestation = {
        "report_sha256": "sha256:" + canonical_sha256(raw_report),
        "observed_at": evaluated.get("observed_at"),
        "profile": evaluated.get("profile"),
        "overall_status": evaluated.get("overall_status"),
        "authoritative_targets_sha256": "sha256:"
        + canonical_sha256(raw_report.get("authoritative_targets")),
        "agent_skill_bundle_sha256": manifest.get("expected_bundle_sha256"),
        "coordinator_instance_id": coordinator.get("coordinator_instance_id"),
        "coordinator_contract_bundle_sha256": coordinator.get(
            "contract_bundle_sha256"
        ),
    }
    return [], attestation


def _live_health_errors(
    envelope: dict[str, Any],
    request: dict[str, Any],
    verified: dict[str, Any] | None,
    now: datetime,
) -> list[str]:
    if not isinstance(verified, dict):
        return ["health_required: live evaluated health attestation is unavailable"]
    fields = {
        "report_sha256", "observed_at", "profile", "overall_status",
        "authoritative_targets_sha256", "agent_skill_bundle_sha256",
        "coordinator_instance_id", "coordinator_contract_bundle_sha256",
    }
    errors = _object_shape(verified, fields, fields, "live health attestation")
    if request.get("health_report_sha256") != verified.get("report_sha256"):
        errors.append("live health report digest drifted from the action request")
    authorized = envelope.get("health_attestation")
    stable = fields - {"report_sha256", "observed_at"}
    if not isinstance(authorized, dict) or any(
        verified.get(field) != authorized.get(field) for field in stable
    ):
        errors.append("live health identity or status drifted from authorization")
    try:
        observed = _timestamp(str(verified.get("observed_at", "")))
        age = (now - observed).total_seconds()
        if age < -60 or age > 600:
            errors.append("live health report is stale or from the future")
    except ValueError:
        errors.append("live health report time is invalid")
    return errors


def _evidence_tool_tuple_errors(
    payload: dict[str, Any], recorded_at: datetime | None
) -> list[str]:
    """Validate minimum-sufficient evidence provenance and acceptance coverage."""
    errors: list[str] = []
    tool_tuple = payload.get("tool_tuple")
    common = {
        "provider", "tool", "tool_version", "command_or_call",
        "started_at", "ended_at", "exit_status",
    }
    kind = payload.get("evidence_kind")
    kind_fields = {
        "acceptance": {
            "verification_scope", "evidence_layer", "platform", "destination",
            "coverage", "artifacts", "omitted_checks",
        },
        "review": {"staged_diff_sha256"},
        "commit_equivalence": {"comparison"},
        "spec_kit_checkpoint": {"spec_kit_snapshot"},
        "testflight_artifact": set(),
        "publication": {"viewable", "readback_sha256"},
        "checks_readback": {"required_checks_satisfied", "readback_sha256"},
    }
    allowed = common | kind_fields.get(str(kind), set())
    if not isinstance(tool_tuple, dict) or set(tool_tuple) != allowed:
        return ["passed evidence requires its exact evidence-kind tool tuple"]
    for field in ("provider", "tool", "tool_version", "command_or_call"):
        if not isinstance(tool_tuple.get(field), str) or not tool_tuple[field].strip():
            errors.append(f"passed evidence tool tuple requires {field}")
    exit_status = tool_tuple.get("exit_status")
    if not isinstance(exit_status, int) or isinstance(exit_status, bool) or exit_status != 0:
        errors.append("passed evidence requires zero tool exit status")
    try:
        started_at = _timestamp(str(tool_tuple.get("started_at")))
        ended_at = _timestamp(str(tool_tuple.get("ended_at")))
        if ended_at < started_at or (
            recorded_at is not None and ended_at > recorded_at
        ):
            errors.append("passed evidence tool time range is invalid")
    except ValueError:
        errors.append("passed evidence tool timestamps are invalid")
    if kind != "acceptance":
        return errors
    if tool_tuple.get("verification_scope") != "minimum-sufficient":
        errors.append("acceptance evidence must use minimum-sufficient scope")
    layer = tool_tuple.get("evidence_layer")
    if layer not in {"repository_contract", "build", "runtime_ui", "motion"}:
        errors.append("acceptance evidence layer is invalid")
    if tool_tuple.get("platform") not in {
        "repository", "ios", "ipados", "watchos", "macos", "multi-platform"
    }:
        errors.append("acceptance evidence platform is invalid")
    if not isinstance(tool_tuple.get("destination"), str) or not tool_tuple[
        "destination"
    ].strip():
        errors.append("acceptance evidence destination is required")
    coverage = tool_tuple.get("coverage")
    coverage_ids: list[str] = []
    if not isinstance(coverage, list) or not coverage:
        errors.append("acceptance evidence requires structured coverage")
    else:
        expected_fields = {
            "acceptance_id", "observable_contract", "prevented_failure",
            "unique_path", "result",
        }
        for item in coverage:
            if not isinstance(item, dict) or set(item) != expected_fields:
                errors.append("acceptance coverage fields are invalid")
                continue
            acceptance_id = item.get("acceptance_id")
            if not isinstance(acceptance_id, str) or not acceptance_id:
                errors.append("acceptance coverage ID is invalid")
            else:
                coverage_ids.append(acceptance_id)
            for field in ("observable_contract", "prevented_failure", "unique_path"):
                if not isinstance(item.get(field), str) or not item[field].strip():
                    errors.append(f"acceptance coverage requires {field}")
            if item.get("result") != "passed":
                errors.append("passed acceptance evidence requires passed coverage")
    if (
        len(coverage_ids) != len(set(coverage_ids))
        or set(coverage_ids) != set(payload.get("acceptance_ids", []))
    ):
        errors.append("acceptance coverage must exactly match evidence acceptance IDs")
    omissions = tool_tuple.get("omitted_checks")
    if (
        not isinstance(omissions, list)
        or any(not isinstance(item, str) or not item for item in omissions)
        or len(omissions) != len(set(omissions))
    ):
        errors.append("acceptance evidence omissions must be unique strings")
    artifacts = tool_tuple.get("artifacts")
    artifact_kinds: set[str] = set()
    if not isinstance(artifacts, list):
        errors.append("acceptance evidence artifacts must be an array")
    else:
        for artifact in artifacts:
            if (
                not isinstance(artifact, dict)
                or set(artifact) != {"kind", "reference", "content_sha256"}
                or artifact.get("kind")
                not in {"screenshot", "video", "xcresult", "log", "report"}
                or not isinstance(artifact.get("reference"), str)
                or not artifact["reference"]
                or re.fullmatch(
                    r"sha256:[0-9a-f]{64}", str(artifact.get("content_sha256"))
                )
                is None
            ):
                errors.append("acceptance evidence artifact is invalid")
            else:
                artifact_kinds.add(artifact["kind"])
    if layer == "runtime_ui" and "screenshot" not in artifact_kinds:
        errors.append("runtime UI acceptance requires screenshot evidence")
    if layer == "motion" and "video" not in artifact_kinds:
        errors.append("motion acceptance requires video evidence")
    return errors


def reserve_action(
    path: Path,
    envelope: dict[str, Any],
    request: dict[str, Any],
    run_root: Path,
    policy_overlay: dict[str, Any],
    live_repository: dict[str, Any],
    live_spec_snapshot: dict[str, Any] | None = None,
    live_apple_observation: dict[str, Any] | None = None,
    coordinator_state: Path | None = None,
    coordinator_binding: dict[str, Any] | None = None,
    selected_writer: str | None = None,
    trusted_harness_sha256: str | None = None,
    verified_health_attestation: dict[str, Any] | None = None,
) -> tuple[list[str], dict[str, Any] | None]:
    """Validate and reserve one grant while holding an exclusive ledger lock."""
    binding_errors = validate_coordinator_binding(
        coordinator_state, coordinator_binding
    )
    if binding_errors:
        return binding_errors, None
    try:
        live_coordinator = resource_coordinator._full_status(coordinator_state)
        run_authority = live_coordinator.get("run_authorities", {}).get(
            envelope.get("run_id")
        )
        if (
            not isinstance(run_authority, dict)
            or run_authority.get("authorization_hash")
            != authorization_hash(envelope)
            or run_authority.get("selected_writer") != selected_writer
            or run_authority.get("harness_sha256") != trusted_harness_sha256
            or run_authority.get("authorization_issued_at")
            != envelope.get("issued_at")
            or run_authority.get("authorization_expires_at")
            != envelope.get("expires_at")
        ):
            return ["coordination_required: run authority drifted or is unregistered"], None
    except resource_coordinator.CoordinatorError as error:
        return [f"coordination_required: {error.code}"], None
    canonical_run_root = run_root.resolve(strict=True)
    if path.is_symlink() or path.parent.resolve(strict=True) != canonical_run_root:
        return ["authorization ledger must be a non-symlink file directly under the private run root"], None
    try:
        descriptor = os.open(
            path, os.O_RDWR | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
        )
    except OSError as error:
        return [f"authorization ledger cannot be opened safely: {error}"], None
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        return ["authorization ledger must be a regular file"], None
    with os.fdopen(descriptor, "r+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            bound_ledger = resource_coordinator.ledger_binding(
                path,
                descriptor=handle.fileno(),
                expected_run_id=str(envelope.get("run_id")),
                expected_authorization_hash=authorization_hash(envelope),
            )
        except resource_coordinator.CoordinatorError as error:
            return [f"coordination_required: {error.code}"], None
        if any(run_authority.get(field) != value for field, value in bound_ledger.items()):
            return ["coordination_required: canonical ledger binding drifted"], None
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
        if coordinator_state is None:
            return ["coordination_required: coordinator state path is unavailable"], None
        coordinator_errors, verified_receipt = resource_coordinator.verify_receipt(
            coordinator_state,
            request.get("coordinator_receipt"),
            now=now,
        )
        if coordinator_errors:
            return [
                "coordination_required: " + ", ".join(coordinator_errors)
            ], None
        errors = authorize_action(
            envelope,
            request,
            now=now,
            ledger_records=records,
            policy_overlay=policy_overlay,
            live_repository=live_repository,
            live_spec_snapshot=live_spec_snapshot,
            live_apple_observation=live_apple_observation,
            verified_coordinator_receipt=verified_receipt,
            coordinator_state=coordinator_state,
            selected_writer=selected_writer,
            verified_health_attestation=verified_health_attestation,
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
                "action_request_sha256": "sha256:" + canonical_sha256(request),
                "constraint_sha256": request["constraint_sha256"],
                "phase": request["phase"],
                "target": request["target"],
                "lease_id": request["lease_id"],
                "lease_owner": request["lease_owner"],
                "writer_actor": request["writer_actor"],
                "resource": request["lease_resource"],
                "resource_key": request["lease_resource_key"],
                "resource_descriptor": request["resource_descriptor"],
                "coordinator_receipt": request["coordinator_receipt"],
                "spec_checkpoint_sha256": request["spec_checkpoint_sha256"],
                "apple_observation_sha256": request["apple_observation_sha256"],
                "apple_observation_state_sha256": (
                    apple_observation_state_sha256(live_apple_observation)
                    if isinstance(live_apple_observation, dict)
                    else None
                ),
                "health_report_sha256": request["health_report_sha256"],
                "paths": request["paths"],
                "repository_observation_sha256": (
                    "sha256:" + canonical_sha256(live_repository)
                    if request.get("action")
                    in {"git.commit", "git.push", "github.pr.create"}
                    else None
                ),
            },
        }
        handle.seek(0, os.SEEK_END)
        try:
            if resource_coordinator.ledger_binding(
                path,
                descriptor=handle.fileno(),
                expected_run_id=str(envelope.get("run_id")),
                expected_authorization_hash=authorization_hash(envelope),
            ) != bound_ledger:
                return ["coordination_required: canonical ledger binding drifted"], None
        except resource_coordinator.CoordinatorError as error:
            return [f"coordination_required: {error.code}"], None
        if handle.tell() and not _descriptor_ends_with_newline(handle.fileno()):
            handle.write("\n")
        handle.write(json.dumps(reservation, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
        try:
            if resource_coordinator.ledger_binding(
                path,
                descriptor=handle.fileno(),
                expected_run_id=str(envelope.get("run_id")),
                expected_authorization_hash=authorization_hash(envelope),
            ) != bound_ledger:
                return ["coordination_required: canonical ledger binding drifted"], None
        except resource_coordinator.CoordinatorError as error:
            return [f"coordination_required: {error.code}"], None
        return [], reservation


def _dispatch_spec_state_errors(
    authorization: dict[str, Any],
    reservation: dict[str, Any],
    trusted_harness: dict[str, Any],
) -> list[str]:
    spec_binding = authorization.get("spec_kit")
    if not isinstance(spec_binding, dict):
        return (
            ["dispatch reservation contains an unexpected Spec Kit checkpoint"]
            if reservation.get("spec_checkpoint_sha256") is not None
            else []
        )
    try:
        live_spec_snapshot = spec_kit_snapshot.build_snapshot(
            Path(str(trusted_harness.get("authoritative_root"))),
            release=str(spec_binding.get("release", "")),
            feature_directory=spec_binding.get("feature_directory"),
            run_id=spec_binding.get("workflow_run_id"),
        )
    except (OSError, ValueError) as error:
        return [f"dispatch Spec Kit observation failed: {type(error).__name__}"]
    errors: list[str] = []
    for live_key, bound_key in (
        ("spec_kit_release", "release"),
        ("feature_id", "feature_id"),
        ("feature_directory", "feature_directory"),
        ("snapshot_sha256", "snapshot_sha256"),
        ("artifact_hashes", "artifact_hashes"),
    ):
        if live_spec_snapshot.get(live_key) != spec_binding.get(bound_key):
            errors.append("dispatch Spec Kit snapshot drifted from authorization")
            break
    if canonical_sha256(
        live_spec_snapshot.get("workflow_checkpoint")
    ) != reservation.get("spec_checkpoint_sha256"):
        errors.append("dispatch Spec Kit checkpoint drifted from its reservation")
    return errors


def _dispatch_apple_state_errors(
    authorization: dict[str, Any],
    reservation: dict[str, Any],
    trusted_harness: dict[str, Any],
    reserved_at: datetime,
    verified_at: datetime,
    *,
    runner: Any = subprocess.run,
) -> list[str]:
    is_apple_action = str(reservation.get("action", "")).startswith("apple.")
    if not is_apple_action:
        if (
            reservation.get("apple_observation_sha256") is not None
            or reservation.get("apple_observation_state_sha256") is not None
        ):
            return ["non-Apple dispatch cannot carry an Apple observation"]
        return []
    binding = trusted_harness.get("apple_observation_probe")
    expected_binding_fields = {
        "executable",
        "executable_sha256",
        "output_contract",
        "timeout_seconds",
    }
    if not isinstance(binding, dict) or set(binding) != expected_binding_fields:
        return ["dispatch Apple action requires a pinned guarded ASC probe"]
    try:
        executable = Path(str(binding.get("executable")))
        mode = executable.lstat()
        if (
            not executable.is_absolute()
            or executable.is_symlink()
            or not stat.S_ISREG(mode.st_mode)
            or mode.st_nlink != 1
            or mode.st_mode & 0o022
            or not os.access(executable, os.X_OK)
            or binding.get("output_contract") != "apple_observation_v1"
            or not isinstance(binding.get("timeout_seconds"), int)
            or isinstance(binding.get("timeout_seconds"), bool)
            or not 1 <= binding["timeout_seconds"] <= 30
        ):
            raise ValueError(
                "guarded ASC probe executable or permissions are unsafe"
            )
        executable_sha256 = "sha256:" + hashlib.sha256(
            executable.read_bytes()
        ).hexdigest()
        if executable_sha256 != binding.get("executable_sha256"):
            raise ValueError("guarded ASC probe executable digest drifted")
        completed = runner(
            [str(executable)],
            check=False,
            capture_output=True,
            text=True,
            timeout=binding["timeout_seconds"],
        )
        if completed.returncode != 0:
            raise ValueError("guarded ASC probe failed")
        live_apple_observation = json.loads(completed.stdout)
        if not isinstance(live_apple_observation, dict):
            raise ValueError("guarded ASC probe must return one JSON object")
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.SubprocessError,
    ) as error:
        return [f"dispatch guarded ASC probe failed closed: {error}"]
    errors = _live_apple_errors(
        authorization,
        {
            "apple_observation_sha256": canonical_sha256(
                live_apple_observation
            )
        },
        live_apple_observation,
        verified_at,
    )
    try:
        observed_at = _timestamp(str(live_apple_observation.get("observed_at", "")))
        if observed_at < reserved_at:
            errors.append("dispatch guarded ASC observation predates its reservation")
    except ValueError:
        pass
    if apple_observation_state_sha256(
        live_apple_observation
    ) != reservation.get("apple_observation_state_sha256"):
        errors.append("dispatch guarded ASC state drifted from its reservation")
    return errors


def verify_reserved_action(
    path: Path,
    reservation_id: str,
    run_root: Path,
    coordinator_state: Path | None,
    coordinator_binding: dict[str, Any] | None,
    health_report_path: Path | None = None,
    harness_path: Path | None = None,
    now: datetime | None = None,
    request_path: Path | None = None,
) -> tuple[list[str], dict[str, Any] | None]:
    """Reverify one unconsumed reservation and its live fence before dispatch."""
    binding_errors = validate_coordinator_binding(
        coordinator_state, coordinator_binding
    )
    if binding_errors:
        return binding_errors, None
    if health_report_path is None or harness_path is None:
        return ["health_required: dispatch must re-evaluate the reserved health report"], None
    if request_path is None:
        return ["dispatch must revalidate the exact private action request"], None
    health_errors, dispatch_health = verify_health_report(
        health_report_path, harness_path, run_root
    )
    if health_errors:
        return health_errors, None
    try:
        trusted_harness = resource_coordinator.load_trusted_harness(harness_path)
        authorization_path = Path(str(trusted_harness.get("run_authorization")))
        overlay_path = Path(str(trusted_harness.get("private_policy_overlay")))
        if (
            not authorization_path.is_absolute()
            or authorization_path.is_symlink()
            or not overlay_path.is_absolute()
            or overlay_path.is_symlink()
        ):
            raise OSError("private dispatch bindings are unsafe")
        authorization = json.loads(
            authorization_path.read_text(encoding="utf-8")
        )
        policy_overlay = json.loads(overlay_path.read_text(encoding="utf-8"))
    except (
        OSError,
        json.JSONDecodeError,
        resource_coordinator.CoordinatorError,
    ):
        return ["dispatch authorization or policy binding is unavailable"], None
    if not isinstance(reservation_id, str) or not reservation_id:
        return ["reservation ID is required for protected dispatch"], None
    try:
        harness_ledger = Path(str(trusted_harness.get("run_ledger")))
        if harness_ledger.resolve(strict=True) != path.resolve(strict=True):
            return ["coordination_required: dispatch ledger drifted from the trusted harness"], None
    except OSError:
        return ["coordination_required: untrusted_ledger"], None
    try:
        canonical_run_root = run_root.resolve(strict=True)
        if path.is_symlink() or path.parent.resolve(strict=True) != canonical_run_root:
            return ["authorization ledger must be a non-symlink file directly under the private run root"], None
        descriptor = os.open(
            path, os.O_RDWR | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
        )
    except OSError as error:
        return [f"authorization ledger cannot be opened safely: {error}"], None
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        return ["authorization ledger must be a regular file"], None
    with os.fdopen(descriptor, "r+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            records: list[dict[str, Any]] = []
            for line_number, line in enumerate(handle.read().splitlines(), 1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as error:
                    return [f"invalid ledger JSON on line {line_number}"], None
                if not isinstance(record, dict):
                    return [f"ledger line {line_number} must be an object"], None
                records.append(record)
            lifecycle_errors = _ledger_contract_errors(
                records, coordinator_state=coordinator_state
            )
            if lifecycle_errors:
                return lifecycle_errors, None
            try:
                coordinator_status = resource_coordinator._full_status(
                    coordinator_state
                )
                run_authority = coordinator_status.get(
                    "run_authorities", {}
                ).get(authorization.get("run_id"))
                if not isinstance(run_authority, dict):
                    return [
                        "coordination_required: dispatch run authority is unregistered"
                    ], None
                bound_ledger = resource_coordinator.ledger_binding(
                    path,
                    descriptor=handle.fileno(),
                    expected_run_id=str(authorization.get("run_id")),
                    expected_authorization_hash=authorization_hash(authorization),
                )
            except resource_coordinator.CoordinatorError as error:
                return [f"coordination_required: {error.code}"], None
            if any(
                run_authority.get(field) != value
                for field, value in bound_ledger.items()
            ):
                return ["coordination_required: canonical ledger binding drifted"], None
            reservation_records = [
                record
                for record in records
                if record.get("record_type") == "grant_reservation"
                and isinstance(record.get("payload"), dict)
                and record["payload"].get("reservation_id") == reservation_id
            ]
            if len(reservation_records) != 1:
                return ["protected dispatch requires one exact reservation"], None
            if any(
                record.get("record_type") == "grant_dispatch"
                and isinstance(record.get("payload"), dict)
                and record["payload"].get("reservation_id") == reservation_id
                for record in records
            ):
                return ["protected dispatch reservation is already claimed"], None
            if any(
                record.get("record_type") == "external_write"
                and isinstance(record.get("payload"), dict)
                and record["payload"].get("reservation_id") == reservation_id
                for record in records
            ):
                return ["protected dispatch reservation is already consumed"], None
            reservation_record = reservation_records[0]
            reservation = reservation_record["payload"]
            try:
                reserved_at = _timestamp(
                    str(reservation_record.get("recorded_at", ""))
                )
            except ValueError:
                return ["protected dispatch reservation time is invalid"], None
            verified_at = now or datetime.now(timezone.utc)
            if verified_at.tzinfo is None or verified_at.utcoffset() is None:
                return ["dispatch verification time must be timezone aware"], None
            dispatch_contract_errors = validate_authorization(authorization)
            dispatch_contract_errors.extend(
                validate_policy_overlay(authorization, policy_overlay)
            )
            try:
                if (
                    not request_path.is_absolute()
                    or request_path.is_symlink()
                    or not request_path.is_file()
                    or request_path.parent.resolve(strict=True) != canonical_run_root
                ):
                    raise ValueError(
                        "action request must be a regular non-symlink file directly under the private run root"
                    )
                live_request = json.loads(request_path.read_text(encoding="utf-8"))
                if not isinstance(live_request, dict):
                    raise ValueError("action request must contain an object")
                if (
                    "sha256:" + canonical_sha256(live_request)
                    != reservation.get("action_request_sha256")
                ):
                    dispatch_contract_errors.append(
                        "dispatch action request drifted from its reservation"
                    )
            except (OSError, ValueError, json.JSONDecodeError) as error:
                dispatch_contract_errors.append(
                    f"dispatch action request cannot be read safely: {error}"
                )
            if (
                authorization_hash(authorization)
                != reservation.get("authorization_hash")
            ):
                dispatch_contract_errors.append(
                    "dispatch authorization hash drifted from its reservation"
                )
            reserved_repository_sha256 = reservation.get(
                "repository_observation_sha256"
            )
            if reserved_repository_sha256 is not None:
                try:
                    live_repository = observe_repository(
                        Path(str(trusted_harness.get("authoritative_root"))),
                        str(authorization.get("repository", {}).get("base_sha", "")),
                    )
                    if (
                        "sha256:" + canonical_sha256(live_repository)
                        != reserved_repository_sha256
                    ):
                        dispatch_contract_errors.append(
                            "dispatch repository observation drifted from its reservation"
                        )
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    dispatch_contract_errors.append(
                        f"dispatch repository observation failed: {type(error).__name__}"
                    )
            dispatch_contract_errors.extend(
                _dispatch_spec_state_errors(
                    authorization, reservation, trusted_harness
                )
            )
            dispatch_contract_errors.extend(
                _dispatch_apple_state_errors(
                    authorization,
                    reservation,
                    trusted_harness,
                    reserved_at,
                    verified_at,
                )
            )
            try:
                authorization_issued_at = _timestamp(
                    str(authorization.get("issued_at", ""))
                )
                authorization_expires_at = _timestamp(
                    str(authorization.get("expires_at", ""))
                )
                if not authorization_issued_at <= verified_at < authorization_expires_at:
                    dispatch_contract_errors.append(
                        "dispatch authorization is outside its active interval"
                    )
            except ValueError:
                dispatch_contract_errors.append(
                    "dispatch authorization time boundary is invalid"
                )
            approvals = [
                record.get("payload")
                for record in records
                if record.get("record_type") == "approval"
                and record.get("run_id") == authorization.get("run_id")
                and isinstance(record.get("payload"), dict)
                and record["payload"].get("authorization_hash")
                == reservation.get("authorization_hash")
            ]
            if len(approvals) != 1:
                dispatch_contract_errors.append(
                    "dispatch requires one exact approval for the reservation"
                )
            expected_authority = {
                "authorization_hash": reservation.get("authorization_hash"),
                "selected_writer": trusted_harness.get("selected_writer"),
                "harness_sha256": resource_coordinator._portable_document_sha256(
                    trusted_harness
                ),
                "authorization_issued_at": authorization.get("issued_at"),
                "authorization_expires_at": authorization.get("expires_at"),
                **bound_ledger,
            }
            if run_authority != expected_authority:
                dispatch_contract_errors.append(
                    "coordination_required: dispatch run authority drifted"
                )
            if dispatch_contract_errors:
                return sorted(set(dispatch_contract_errors)), None
            if (
                not isinstance(dispatch_health, dict)
                or reservation.get("health_report_sha256")
                != dispatch_health.get("report_sha256")
            ):
                return ["dispatch health report drifted from its reservation"], None
            if coordinator_state is None:
                return ["coordination_required: coordinator state path is unavailable"], None
            coordinator_errors, receipt = resource_coordinator.verify_receipt(
                coordinator_state,
                reservation.get("coordinator_receipt"),
                now=verified_at,
            )
            if coordinator_errors or receipt is None:
                return [
                    "coordination_required: " + ", ".join(coordinator_errors)
                ], None
            try:
                dispatch_deadline = min(
                    authorization_expires_at,
                    _timestamp(str(receipt.get("expires_at"))),
                    verified_at
                    + timedelta(seconds=MAX_DISPATCH_WINDOW_SECONDS),
                )
            except (UnboundLocalError, ValueError):
                return ["dispatch deadline cannot be derived"], None
            if (
                dispatch_deadline - verified_at
            ).total_seconds() < MIN_DISPATCH_WINDOW_SECONDS:
                return ["dispatch window is too short; renew authority or lease"], None
            run_ids = {
                record.get("run_id") for record in records if record.get("run_id")
            }
            if len(run_ids) != 1:
                return ["ledger must contain exactly one run ID before dispatch"], None
            dispatch_id = str(uuid.uuid4())
            dispatch_record = {
                "schema_version": "1.0.0",
                "run_id": next(iter(run_ids)),
                "sequence": max(
                    (record.get("sequence", 0) for record in records), default=0
                ) + 1,
                "recorded_at": verified_at.isoformat().replace("+00:00", "Z"),
                "record_type": "grant_dispatch",
                "payload": {
                    "dispatch_id": dispatch_id,
                    "reservation_id": reservation_id,
                    "coordinator_receipt": receipt,
                    "health_report_sha256": reservation.get(
                        "health_report_sha256"
                    ),
                    "dispatch_deadline": dispatch_deadline.isoformat().replace(
                        "+00:00", "Z"
                    ),
                },
            }
            handle.seek(0, os.SEEK_END)
            try:
                if resource_coordinator.ledger_binding(
                    path,
                    descriptor=handle.fileno(),
                    expected_run_id=str(authorization.get("run_id")),
                    expected_authorization_hash=authorization_hash(authorization),
                ) != bound_ledger:
                    return ["coordination_required: canonical ledger binding drifted"], None
            except resource_coordinator.CoordinatorError as error:
                return [f"coordination_required: {error.code}"], None
            if handle.tell() and not _descriptor_ends_with_newline(handle.fileno()):
                handle.write("\n")
            handle.write(
                json.dumps(dispatch_record, sort_keys=True, separators=(",", ":"))
                + "\n"
            )
            handle.flush()
            os.fsync(handle.fileno())
            try:
                if resource_coordinator.ledger_binding(
                    path,
                    descriptor=handle.fileno(),
                    expected_run_id=str(authorization.get("run_id")),
                    expected_authorization_hash=authorization_hash(authorization),
                ) != bound_ledger:
                    return ["coordination_required: canonical ledger binding drifted"], None
            except resource_coordinator.CoordinatorError as error:
                return [f"coordination_required: {error.code}"], None
            return [], {
                "dispatch_id": dispatch_id,
                "reservation_id": reservation_id,
                "authorization_hash": reservation.get("authorization_hash"),
                "grant_id": reservation.get("grant_id"),
                "idempotency_key": reservation.get("idempotency_key"),
                "system": reservation.get("system"),
                "action": reservation.get("action"),
                "operation": reservation.get("operation"),
                "operation_input": reservation.get("operation_input"),
                "action_request_sha256": reservation.get(
                    "action_request_sha256"
                ),
                "target": reservation.get("target"),
                "coordinator_receipt": receipt,
                "health_report_sha256": reservation.get(
                    "health_report_sha256"
                ),
                "verified_at": dispatch_record["recorded_at"],
                "dispatch_deadline": dispatch_record["payload"][
                    "dispatch_deadline"
                ],
            }
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _descriptor_ends_with_newline(descriptor: int) -> bool:
    size = os.fstat(descriptor).st_size
    if size == 0:
        return True
    return os.pread(descriptor, 1, size - 1) == b"\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorization", type=Path, required=True)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, required=True, help="Append-only ledger for single-use and derived-target state.")
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--policy-overlay", type=Path, required=True)
    parser.add_argument("--authoritative-root", type=Path, required=True)
    parser.add_argument(
        "--harness",
        type=Path,
        required=True,
        help="Private trusted harness containing the exact coordinator binding.",
    )
    parser.add_argument(
        "--coordinator-state",
        type=Path,
        required=True,
        help="Explicit host-shared coordinator state file; there is no default.",
    )
    parser.add_argument(
        "--health-report",
        type=Path,
        required=True,
        help="Fresh private health report re-evaluated by the installed health skill.",
    )
    parser.add_argument(
        "--apple-observation",
        type=Path,
        help="Fresh guarded read-only ASC observation; required for Apple actions.",
    )
    arguments = parser.parse_args()
    try:
        harness = resource_coordinator.load_trusted_harness(arguments.harness)
    except resource_coordinator.CoordinatorError as error:
        print(json.dumps({"authorized": False, "errors": [f"coordination_required: {error.code}"], "reservation": None}, indent=2))
        return 2
    try:
        bound_authorization = Path(str(harness.get("run_authorization")))
        bound_overlay = Path(str(harness.get("private_policy_overlay")))
        if (
            not arguments.authorization.is_absolute()
            or arguments.authorization.is_symlink()
            or not arguments.policy_overlay.is_absolute()
            or arguments.policy_overlay.is_symlink()
            or not bound_authorization.is_absolute()
            or not bound_overlay.is_absolute()
            or arguments.authorization.resolve(strict=True)
            != bound_authorization.resolve(strict=True)
            or arguments.policy_overlay.resolve(strict=True)
            != bound_overlay.resolve(strict=True)
        ):
            raise OSError("private authorization or policy path drifted")
    except OSError:
        print(json.dumps({"authorized": False, "errors": ["untrusted private authorization or policy binding"], "reservation": None}, indent=2))
        return 2
    try:
        canonical_run_root = arguments.run_root.resolve(strict=True)
        if (
            arguments.request.is_symlink()
            or arguments.request.parent.resolve(strict=True) != canonical_run_root
        ):
            raise OSError("action request is outside the private run root")
        envelope = json.loads(arguments.authorization.read_text(encoding="utf-8"))
        request = json.loads(arguments.request.read_text(encoding="utf-8"))
        overlay = json.loads(arguments.policy_overlay.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(json.dumps({"authorized": False, "errors": [f"private action input is invalid: {error}"], "reservation": None}, indent=2))
        return 2
    health_errors, verified_health_attestation = verify_health_report(
        arguments.health_report,
        arguments.harness,
        arguments.run_root,
    )
    if health_errors:
        print(json.dumps({"authorized": False, "errors": health_errors, "reservation": None}, indent=2))
        return 2
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
        arguments.coordinator_state,
        harness.get("resource_coordinator"),
        harness.get("selected_writer"),
        resource_coordinator._portable_document_sha256(harness),
        verified_health_attestation,
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
