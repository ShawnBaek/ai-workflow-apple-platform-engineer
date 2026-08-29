#!/usr/bin/env python3
"""Aggregate and redact a read-only Apple development health report."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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
        remote = sanitize_remote(subprocess.run(
            ["git", "-C", str(canonical), "remote", "get-url", "origin"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip())
        branch = subprocess.run(
            ["git", "-C", str(canonical), "branch", "--show-current"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return [f"live repository health binding failed: {error}"]
    expected = {
        "repository": str(canonical),
        "remote": remote,
        "branch": branch,
    }
    profile = report.get("profile")
    if profile in {"runtime_ui", "testflight_uploaded", "testflight_distributed"}:
        container = harness.get("xcode_container")
        if not isinstance(container, str) or not container:
            errors.append("harness xcode_container is invalid")
        else:
            container_path = Path(container)
            if container_path.is_symlink():
                errors.append("harness xcode_container cannot be a symlink")
            try:
                canonical_container = container_path.resolve(strict=True)
                if canonical_container.suffix not in {".xcodeproj", ".xcworkspace"}:
                    errors.append("harness xcode_container must be an existing project or workspace")
                expected["xcode_container"] = str(canonical_container)
            except OSError as error:
                errors.append(f"harness xcode_container cannot be resolved: {error}")
    if report.get("authoritative_targets") != expected:
        errors.append("health authoritative targets drifted from the harness and live repository")
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
