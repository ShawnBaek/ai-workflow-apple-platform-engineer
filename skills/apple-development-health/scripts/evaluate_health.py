#!/usr/bin/env python3
"""Aggregate and redact a read-only Apple development health report."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from typing import Any
import urllib.parse


PROFILES = {
    "pr_ready",
    "runtime_ui",
    "testflight_uploaded",
    "testflight_distributed",
    "icon_upstream",
}
PROFILE_REQUIREMENTS = {
    "pr_ready": {
        "repository.identity",
        "agent.skills",
        "cli.git",
        "github.issue_pr",
    },
    "runtime_ui": {
        "repository.identity",
        "agent.skills",
        "cli.git",
        "github.issue_pr",
        "xcode.authoritative_container",
        "apple.execution_path",
        "simulator.runtime",
        "app.runtime",
    },
    "testflight_uploaded": {
        "repository.identity",
        "agent.skills",
        "cli.git",
        "github.issue_pr",
        "xcode.authoritative_container",
        "apple.execution_path",
        "apple.account_guard",
        "cli.asc",
        "testflight.upload_target",
    },
    "testflight_distributed": {
        "repository.identity",
        "agent.skills",
        "cli.git",
        "github.issue_pr",
        "xcode.authoritative_container",
        "apple.execution_path",
        "apple.account_guard",
        "cli.asc",
        "testflight.upload_target",
        "testflight.internal_groups",
    },
    "icon_upstream": {
        "repository.identity",
        "agent.skills",
        "cli.git",
        "github.issue_pr",
        "companion_upstream.provenance",
    },
}
COMPONENT_REQUIREMENTS = {
    "project_registry": "repository.project_registry",
    "spec_kit": "spec_kit.snapshot",
    "xcode_mcp": "mcp.xcode",
    "apple_sample_code_mcp": "mcp.apple_sample_code",
    "github_project": "github.project",
    "local_llm": "local_llm",
}
STATUSES = {"healthy", "degraded", "blocked", "not_applicable"}
CATEGORIES = {
    "repository",
    "agent",
    "cli",
    "mcp",
    "github",
    "spec_kit",
    "xcode",
    "simulator",
    "apple_account",
    "testflight",
    "local_llm",
    "companion_upstream",
}
SENSITIVE_KEYS = ("token", "password", "secret", "authorization", "private_key", "otp")
TOKEN_PATTERNS = (
    re.compile(r"\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{8,}\b"),
    re.compile(r"\bBearer\s+\S+", re.IGNORECASE),
    re.compile(r"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----"),
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
)
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
FINGERPRINT = re.compile(r"^sha256:[0-9a-f]{64}$")
GITHUB_PATH = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
XCODE_CONTAINER = re.compile(
    r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[^\x00-\x1f\x7f]+\.(?:xcodeproj|xcworkspace)$"
)
STALE_REGISTRY_REASONS = {
    "missing_path",
    "not_git_root",
    "missing_xcode_container",
    "remote_fingerprint_mismatch",
}


def sanitize_remote(remote: str) -> str:
    """Keep repository identity while removing URL userinfo from health output."""
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


def remote_fingerprint(remote: str) -> str:
    """Match the registry resolver's credential-free GitHub identity digest."""
    if (
        not isinstance(remote, str)
        or not remote
        or remote.strip() != remote
        or CONTROL.search(remote) is not None
        or "?" in remote
        or "#" in remote
    ):
        raise ValueError("invalid GitHub remote")
    value = remote
    if value.startswith("git@github.com:"):
        path = value.removeprefix("git@github.com:")
    else:
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme not in {"https", "ssh"} or parsed.hostname != "github.com":
            raise ValueError("invalid GitHub remote")
        try:
            port = parsed.port
        except ValueError as error:
            raise ValueError("invalid GitHub remote") from error
        if (parsed.scheme == "https" and port not in {None, 443}) or (
            parsed.scheme == "ssh" and port not in {None, 22}
        ):
            raise ValueError("invalid GitHub remote")
        if parsed.query or parsed.fragment or parsed.password is not None:
            raise ValueError("invalid GitHub remote")
        if parsed.scheme == "https" and parsed.username is not None:
            raise ValueError("invalid GitHub remote")
        if parsed.scheme == "ssh" and parsed.username not in {None, "git"}:
            raise ValueError("invalid GitHub remote")
        path = parsed.path.lstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    if GITHUB_PATH.fullmatch(path) is None:
        raise ValueError("invalid GitHub remote")
    normalized = f"github.com/{path.lower()}"
    return "sha256:" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def redact(value: Any, key: str = "") -> Any:
    if any(fragment in key.lower() for fragment in SENSITIVE_KEYS):
        return "<redacted>"
    if isinstance(value, dict):
        return {child: redact(item, child) for child, item in value.items()}
    if isinstance(value, list):
        return [redact(item, key) for item in value]
    if isinstance(value, str):
        result = value
        for pattern in TOKEN_PATTERNS:
            result = pattern.sub("<redacted>", result)
        return result
    return value


def evaluate(
    report: dict[str, Any], now: datetime | None = None
) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    if not isinstance(report, dict):
        return {"overall_status": "blocked"}, ["health report must be an object"]
    allowed_top_level = {
        "$schema",
        "schema_version",
        "profile",
        "observed_at",
        "authoritative_targets",
        "project_registry_resolution",
        "selected_components",
        "required_check_ids",
        "checks",
    }
    if set(report) - allowed_top_level:
        errors.append("health report contains unsupported top-level fields")
    if report.get("schema_version") != "1.0.0":
        errors.append("unsupported health report schema")
    profile = report.get("profile")
    if profile not in PROFILES:
        errors.append("unsupported health profile")
    observed_at = report.get("observed_at")
    try:
        observed = datetime.fromisoformat(str(observed_at).replace("Z", "+00:00"))
        if observed.tzinfo is None:
            raise ValueError
        current = now or datetime.now(timezone.utc)
        if current.tzinfo is None:
            raise ValueError
        age = (current - observed).total_seconds()
        if age < -60 or age > 600:
            errors.append("health report is stale or from the future")
    except ValueError:
        errors.append("health report observed_at must be a timezone-aware timestamp")
    targets = report.get("authoritative_targets")
    if not isinstance(targets, dict) or not targets:
        errors.append("health report requires authoritative targets")
    selected_components = report.get("selected_components")
    if (
        not isinstance(selected_components, list)
        or any(item not in COMPONENT_REQUIREMENTS for item in selected_components)
        or len(selected_components) != len(set(selected_components))
    ):
        errors.append("health report selected_components are invalid")
        selected_components = []
    required_check_ids = report.get("required_check_ids")
    if (
        not isinstance(required_check_ids, list)
        or not required_check_ids
        or any(not isinstance(item, str) or not item for item in required_check_ids)
        or len(required_check_ids) != len(set(required_check_ids))
    ):
        errors.append("health report requires unique required_check_ids")
        required_check_ids = []
    expected_requirements = set(PROFILE_REQUIREMENTS.get(profile, set()))
    expected_requirements.update(
        COMPONENT_REQUIREMENTS[component] for component in selected_components
    )
    missing_base = expected_requirements - set(required_check_ids)
    unexpected_required = set(required_check_ids) - expected_requirements
    if missing_base:
        errors.append(
            "health profile is missing required check IDs: " + ", ".join(sorted(missing_base))
        )
    if unexpected_required:
        errors.append(
            "health report has unbound required check IDs: "
            + ", ".join(sorted(unexpected_required))
        )
    checks = report.get("checks")
    if not isinstance(checks, list) or not checks:
        errors.append("health report requires at least one check")
        checks = []
    ids: set[str] = set()
    for check in checks:
        if not isinstance(check, dict):
            errors.append("health checks must be objects")
            continue
        allowed_check_fields = {
            "id",
            "category",
            "required",
            "status",
            "summary",
            "evidence",
            "next_action",
        }
        if set(check) - allowed_check_fields:
            errors.append("health check contains unsupported fields")
        check_id = check.get("id")
        if not isinstance(check_id, str) or not check_id or check_id in ids:
            errors.append("health check IDs must be non-empty and unique")
        if isinstance(check_id, str):
            ids.add(check_id)
        if check.get("category") not in CATEGORIES:
            errors.append(f"invalid health category for {check_id}")
        if not isinstance(check.get("required"), bool):
            errors.append(f"health check required flag must be boolean: {check_id}")
        status = check.get("status")
        if status not in STATUSES:
            errors.append(f"invalid health status for {check_id}")
        if not isinstance(check.get("summary"), str) or not check.get("summary"):
            errors.append(f"health check requires a summary: {check_id}")
        evidence = check.get("evidence")
        if not isinstance(evidence, list) or any(
            not isinstance(item, str) or not item for item in evidence
        ):
            errors.append(f"health check evidence must be a string list: {check_id}")
        elif status != "not_applicable" and not evidence:
            errors.append(f"applicable health check requires evidence: {check_id}")
        if check.get("required") is True and status == "not_applicable":
            errors.append(f"required health check cannot be not_applicable: {check_id}")
        if status in {"degraded", "blocked"} and not check.get("next_action"):
            errors.append(f"non-healthy check requires a next action: {check_id}")
    checks_by_id = {
        check.get("id"): check for check in checks if isinstance(check, dict) and check.get("id")
    }
    for check_id in required_check_ids:
        check = checks_by_id.get(check_id)
        if check is None:
            errors.append(f"required health check is missing: {check_id}")
        elif check.get("required") is not True:
            errors.append(f"required health check must set required true: {check_id}")

    registry_selected = "project_registry" in selected_components
    registry_resolution = report.get("project_registry_resolution")
    if not registry_selected:
        if registry_resolution is not None:
            errors.append("unselected project registry must not include a resolution")
    elif not isinstance(registry_resolution, dict):
        errors.append("selected project registry requires a structured resolution")
    else:
        allowed_resolution = {
            "status", "reason_code", "resolver_version", "registry_sha256",
            "worktree_authorized", "candidate", "warnings",
        }
        if set(registry_resolution) != allowed_resolution:
            errors.append("project registry resolution fields are invalid")
        status = registry_resolution.get("status")
        reason = registry_resolution.get("reason_code")
        resolver_version = registry_resolution.get("resolver_version")
        registry_digest = registry_resolution.get("registry_sha256")
        worktree_authorized = registry_resolution.get("worktree_authorized")
        candidate = registry_resolution.get("candidate")
        warnings = registry_resolution.get("warnings")
        if status not in {"resolved", "blocked", "needs_selection", "unavailable"}:
            errors.append("project registry resolution status is invalid")
        if not isinstance(reason, str) or not reason:
            errors.append("project registry resolution reason is invalid")
        if resolver_version != "1.0.0":
            errors.append("project registry resolver version is unsupported")
        if not isinstance(registry_digest, str) or FINGERPRINT.fullmatch(registry_digest) is None:
            errors.append("project registry resolution hash is invalid")
        if not isinstance(worktree_authorized, bool):
            errors.append("project registry worktree authorization must be boolean")
        if not isinstance(warnings, list):
            errors.append("project registry warnings must be an array")
            warnings = []
        else:
            warning_keys: set[tuple[str, str, str]] = set()
            for warning in warnings:
                if (
                    not isinstance(warning, dict)
                    or set(warning) != {"project_id", "checkout_id", "reason_code"}
                    or any(
                        not isinstance(warning.get(key), str) or not warning.get(key)
                        for key in ("project_id", "checkout_id", "reason_code")
                    )
                    or warning.get("reason_code") not in STALE_REGISTRY_REASONS
                    or any(
                        IDENTIFIER.fullmatch(str(warning.get(key, ""))) is None
                        for key in ("project_id", "checkout_id")
                    )
                ):
                    errors.append("project registry warning is invalid")
                    break
                warning_key = (
                    warning["project_id"], warning["checkout_id"], warning["reason_code"]
                )
                if warning_key in warning_keys:
                    errors.append("project registry warnings must be unique")
                    break
                warning_keys.add(warning_key)
        expected_registry_status = "blocked"
        if status == "resolved":
            allowed_candidate = {
                "project_id", "checkout_id", "canonical_root",
                "remote_fingerprint", "kind", "xcode_containers",
            }
            if not isinstance(candidate, dict) or set(candidate) != allowed_candidate:
                errors.append("resolved project registry requires one exact candidate")
            else:
                for key in ("project_id", "checkout_id"):
                    if not isinstance(candidate.get(key), str) or IDENTIFIER.fullmatch(candidate[key]) is None:
                        errors.append(f"project registry candidate {key} is invalid")
                candidate_root = candidate.get("canonical_root")
                if (
                    not isinstance(candidate_root, str)
                    or not candidate_root.startswith("/")
                    or CONTROL.search(candidate_root) is not None
                    or ".." in Path(candidate_root).parts
                ):
                    errors.append("project registry candidate root is invalid")
                if not isinstance(candidate.get("remote_fingerprint"), str) or FINGERPRINT.fullmatch(candidate["remote_fingerprint"]) is None:
                    errors.append("project registry candidate remote fingerprint is invalid")
                if candidate.get("kind") not in {"primary", "worktree"}:
                    errors.append("project registry candidate checkout kind is invalid")
                containers = candidate.get("xcode_containers")
                if not isinstance(containers, list) or any(
                    not isinstance(item, str) or XCODE_CONTAINER.fullmatch(item) is None
                    for item in containers
                ) or len(containers) != len(set(containers)):
                    errors.append("project registry candidate Xcode containers are invalid")
                if candidate.get("kind") == "worktree" and not worktree_authorized:
                    expected_registry_status = "blocked"
                elif warnings:
                    expected_registry_status = "degraded"
                else:
                    expected_registry_status = "healthy"
            if reason != "registry_candidate":
                errors.append("resolved project registry reason must identify a registry candidate")
        elif candidate is not None:
            errors.append("unresolved project registry must not select a candidate")
        registry_check = checks_by_id.get("repository.project_registry")
        if isinstance(registry_check, dict) and registry_check.get("status") != expected_registry_status:
            errors.append("project registry health status does not match its structured resolution")
    if errors:
        overall = "blocked"
    elif any(check.get("required") and check.get("status") == "blocked" for check in checks):
        overall = "blocked"
    elif any(check.get("status") in {"degraded", "blocked"} for check in checks):
        overall = "degraded"
    else:
        overall = "healthy"
    sanitized = redact(report)
    return {**sanitized, "overall_status": overall}, sorted(set(errors))


def validate_harness_binding(report: dict[str, Any], harness: dict[str, Any]) -> list[str]:
    """Bind report targets to the trusted harness and live read-only Git identity."""
    errors: list[str] = []
    root_value = harness.get("authoritative_root")
    if not isinstance(root_value, str) or not root_value:
        return ["harness authoritative_root is invalid"]
    root = Path(root_value)
    if root.is_symlink():
        return ["harness authoritative_root cannot be a symlink"]
    try:
        canonical = root.resolve(strict=True)
        top = Path(
            subprocess.run(
                ["git", "-C", str(canonical), "rev-parse", "--show-toplevel"],
                check=True,
                capture_output=True,
                text=True,
                timeout=15,
            ).stdout.strip()
        ).resolve(strict=True)
        if top != canonical:
            errors.append("harness authoritative_root is not the exact Git top level")
        raw_remote = subprocess.run(
            ["git", "-C", str(canonical), "remote", "get-url", "origin"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()
        remote = sanitize_remote(raw_remote)
        branch = subprocess.run(
            ["git", "-C", str(canonical), "branch", "--show-current"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()
        git_dir_value = Path(subprocess.run(
            ["git", "-C", str(canonical), "rev-parse", "--git-dir"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip())
        common_dir_value = Path(subprocess.run(
            ["git", "-C", str(canonical), "rev-parse", "--git-common-dir"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip())
        git_dir = (git_dir_value if git_dir_value.is_absolute() else canonical / git_dir_value).resolve(strict=True)
        common_dir = (common_dir_value if common_dir_value.is_absolute() else canonical / common_dir_value).resolve(strict=True)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return [f"live repository health binding failed: {error}"]
    expected = {
        "repository": str(canonical),
        "remote": remote,
        "branch": branch,
    }
    profile = report.get("profile")
    selected_value = report.get("selected_components")
    selected_components = selected_value if isinstance(selected_value, list) else []
    relative_container: str | None = None
    requires_xcode_container = (
        profile in {"runtime_ui", "testflight_uploaded", "testflight_distributed"}
        or "xcode_mcp" in selected_components
    )
    if requires_xcode_container:
        container = harness.get("xcode_container")
        if not isinstance(container, str) or not container:
            errors.append("harness xcode_container is invalid")
        else:
            container_path = Path(container)
            if container_path.is_symlink():
                errors.append("harness xcode_container cannot be a symlink")
            try:
                canonical_container = container_path.resolve(strict=True)
                if (
                    not canonical_container.is_dir()
                    or canonical_container.suffix not in {".xcodeproj", ".xcworkspace"}
                ):
                    errors.append("harness xcode_container must be an existing project or workspace")
                try:
                    relative_container = canonical_container.relative_to(canonical).as_posix()
                except ValueError:
                    errors.append("harness xcode_container must stay inside the authoritative repository")
                    relative_container = None
                expected["xcode_container"] = str(canonical_container)
            except OSError as error:
                errors.append(f"harness xcode_container cannot be resolved: {error}")
    if report.get("authoritative_targets") != expected:
        errors.append("health authoritative targets drifted from the harness and live repository")
    resolution = report.get("project_registry_resolution")
    if "project_registry" in selected_components and isinstance(resolution, dict):
        if resolution.get("status") == "resolved" and isinstance(resolution.get("candidate"), dict):
            candidate = resolution["candidate"]
            if candidate.get("canonical_root") != str(canonical):
                errors.append("project registry candidate root drifted from the harness")
            try:
                live_remote_fingerprint = remote_fingerprint(raw_remote)
            except ValueError:
                errors.append("live repository remote cannot be normalized for project registry binding")
            else:
                if candidate.get("remote_fingerprint") != live_remote_fingerprint:
                    errors.append("project registry candidate remote fingerprint drifted from the live repository")
            live_kind = "worktree" if git_dir != common_dir else "primary"
            if candidate.get("kind") != live_kind:
                errors.append("project registry candidate checkout kind drifted from live Git metadata")
            if live_kind == "worktree" and resolution.get("worktree_authorized") is not True:
                errors.append("project registry selected an unapproved worktree")
            if requires_xcode_container:
                candidate_containers = candidate.get("xcode_containers")
                if not isinstance(candidate_containers, list):
                    candidate_containers = []
                if relative_container is None or relative_container not in candidate_containers:
                    errors.append("project registry candidate does not bind the authoritative Xcode container")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument(
        "--harness",
        type=Path,
        required=True,
        help="Trusted harness configuration whose health_components must match the report.",
    )
    parser.add_argument(
        "--require-component",
        action="append",
        choices=sorted(COMPONENT_REQUIREMENTS),
        default=[],
        help="Bind task-selected surfaces from the harness instead of trusting report omission.",
    )
    arguments = parser.parse_args()
    report = json.loads(arguments.report.read_text(encoding="utf-8"))
    evaluated, errors = evaluate(report)
    trusted_components = set(arguments.require_component)
    harness = json.loads(arguments.harness.read_text(encoding="utf-8"))
    configured = harness.get("health_components")
    if not isinstance(configured, list) or any(
        item not in COMPONENT_REQUIREMENTS for item in configured
    ):
        errors.append("harness health_components are invalid")
    else:
        trusted_components.update(configured)
        if harness.get("spec_kit", {}).get("enabled") is True and "spec_kit" not in configured:
            errors.append("enabled Spec Kit is missing from harness health_components")
        if harness.get("github_tracking", {}).get("project") is not None and "github_project" not in configured:
            errors.append("configured GitHub Project is missing from harness health_components")
    if harness.get("health_profile") != report.get("profile"):
        errors.append("health report profile drifted from harness")
    errors.extend(validate_harness_binding(report, harness))
    observed_components = set(report.get("selected_components", []))
    missing_selected = trusted_components - observed_components
    unexpected_selected = observed_components - trusted_components
    if missing_selected or unexpected_selected:
        errors.extend(
            f"harness-required component is missing from report: {item}"
            for item in sorted(missing_selected)
        )
        errors.extend(
            f"health report selected an unbound harness component: {item}"
            for item in sorted(unexpected_selected)
        )
        evaluated["overall_status"] = "blocked"
    if errors:
        evaluated["overall_status"] = "blocked"
    valid = not errors and evaluated["overall_status"] != "blocked"
    print(json.dumps({"report": evaluated, "valid": valid, "errors": errors}, indent=2, sort_keys=True))
    return 0 if not errors and evaluated["overall_status"] != "blocked" else 2


if __name__ == "__main__":
    raise SystemExit(main())
