#!/usr/bin/env python3
"""Aggregate and redact a read-only Apple development health report."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time
from typing import Any
import urllib.parse
import urllib.error
import urllib.request


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
for _requirements in PROFILE_REQUIREMENTS.values():
    _requirements.add("agent.resource_coordinator")
COMPONENT_REQUIREMENTS = {
    "project_registry": "repository.project_registry",
    "spec_kit": "spec_kit.snapshot",
    "xcode_mcp": "mcp.xcode",
    "apple_sample_code_mcp": "mcp.apple_sample_code",
    "github_project": "github.project",
    "local_llm": "local_llm",
}
BASE_AGENT_SKILLS = {
    "agent-harness",
    "apple-development-health",
    "git-workflow",
    "github-projects",
}
PROFILE_AGENT_SKILLS = {
    "pr_ready": set(),
    "runtime_ui": {
        "xcode-project-workflow", "xcodebuild", "apple-platform-testing",
        "core-simulator-health",
    },
    "testflight_uploaded": {
        "xcode-project-workflow", "xcodebuild", "app-store-connect",
        "app-versioning",
    },
    "testflight_distributed": {
        "xcode-project-workflow", "xcodebuild", "app-store-connect",
        "app-versioning",
    },
    "icon_upstream": {"icon-composer"},
}
COMPONENT_AGENT_SKILLS = {
    "project_registry": {"agent-harness"},
    "spec_kit": {"agent-harness"},
    "xcode_mcp": {"xcode-project-workflow", "xcodebuild"},
    "apple_sample_code_mcp": {"agent-harness"},
    "github_project": {"github-projects"},
    "local_llm": {"agent-harness"},
}
STATUSES = {"healthy", "degraded", "blocked", "not_applicable"}
EVALUATOR_OWNED_CHECKS = {
    "github.issue_pr",
    "github.project",
    "xcode.authoritative_container",
    "apple.execution_path",
    "simulator.runtime",
    "apple.account_guard",
    "cli.asc",
    "testflight.upload_target",
    "testflight.internal_groups",
    "mcp.xcode",
    "mcp.apple_sample_code",
    "spec_kit.snapshot",
    "local_llm",
    "companion_upstream.provenance",
}
APPLE_SAMPLE_CODE_ENDPOINT = "https://mcp.applesamplecode.com/mcp"
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
SKILL_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
IGNORED_SKILL_PATH_PARTS = {"__pycache__", ".git"}
IGNORED_SKILL_FILES = {".DS_Store"}


def required_agent_skills(harness: dict[str, Any]) -> tuple[list[str], list[str]]:
    """Derive the exact skill set from trusted profile/components plus task skills."""
    errors: list[str] = []
    profile = harness.get("health_profile")
    components = harness.get("health_components")
    configured = harness.get("agent_skills")
    task_skills = configured.get("task_skills") if isinstance(configured, dict) else None
    if profile not in PROFILE_AGENT_SKILLS:
        errors.append("harness health profile is invalid for agent skill derivation")
    if (
        not isinstance(components, list)
        or any(item not in COMPONENT_AGENT_SKILLS for item in components)
        or len(components) != len(set(components))
    ):
        errors.append("harness health components are invalid for agent skill derivation")
        components = []
    if (
        not isinstance(task_skills, list)
        or any(not isinstance(item, str) or SKILL_NAME.fullmatch(item) is None for item in task_skills)
        or len(task_skills) != len(set(task_skills))
    ):
        errors.append("harness task skills are invalid")
        task_skills = []
    required = set(BASE_AGENT_SKILLS)
    required.update(PROFILE_AGENT_SKILLS.get(str(profile), set()))
    for component in components:
        required.update(COMPONENT_AGENT_SKILLS[component])
    required.update(task_skills)
    return sorted(required), errors


def _skill_sha256(skill_path: Path) -> str:
    resolved = skill_path.resolve(strict=True)
    if not resolved.is_dir() or not (resolved / "SKILL.md").is_file():
        raise ValueError("installed skill lacks a regular SKILL.md")
    candidates = []
    for path in resolved.rglob("*"):
        relative = path.relative_to(resolved)
        if any(part in IGNORED_SKILL_PATH_PARTS for part in relative.parts):
            continue
        if path.name in IGNORED_SKILL_FILES or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise ValueError("installed skill contains an unsupported nested symlink")
        if path.is_file():
            candidates.append(path)
    if not candidates:
        raise ValueError("installed skill bundle is empty")
    digest = hashlib.sha256()
    for path in sorted(candidates, key=lambda item: item.relative_to(resolved).as_posix()):
        relative = path.relative_to(resolved).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return "sha256:" + digest.hexdigest()


def _skill_bundle(root: Path, required_skills: list[str]) -> tuple[str, list[dict[str, str]]]:
    entries: list[dict[str, str]] = []
    for name in required_skills:
        visible_entry = root / name
        resolved_entry = visible_entry.resolve(strict=True)
        entries.append(
            {
                "name": name,
                "entry_kind": "symlink" if visible_entry.is_symlink() else "directory",
                "resolved_path_sha256": "sha256:" + hashlib.sha256(
                    str(resolved_entry).encode("utf-8")
                ).hexdigest(),
                "sha256": _skill_sha256(visible_entry),
            }
        )
    digest = hashlib.sha256()
    for entry in entries:
        name = entry["name"].encode("utf-8")
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(bytes.fromhex(entry["sha256"].removeprefix("sha256:")))
    return "sha256:" + digest.hexdigest(), entries


def _skill_bundle_from_search_roots(
    roots: list[Path], required_skills: list[str]
) -> tuple[str, list[dict[str, str]], list[str]]:
    """Resolve the first skill in client order and reject every shadowing copy."""
    entries: list[dict[str, str]] = []
    errors: list[str] = []
    for name in required_skills:
        candidates = [
            root / name
            for root in roots
            if (root / name).exists() or (root / name).is_symlink()
        ]
        if not candidates:
            errors.append(f"required skill is missing from configured search roots: {name}")
            continue
        if len(candidates) != 1:
            errors.append(f"duplicate shadowing skill copies are configured: {name}")
            continue
        visible_entry = candidates[0]
        if visible_entry.is_symlink() and not visible_entry.exists():
            errors.append(f"required skill is a broken top-level symlink: {name}")
            continue
        try:
            resolved_entry = visible_entry.resolve(strict=True)
            entry_sha = _skill_sha256(visible_entry)
        except (OSError, ValueError) as error:
            errors.append(f"required skill cannot be resolved: {name}: {error}")
            continue
        entries.append(
            {
                "name": name,
                "entry_kind": "symlink" if visible_entry.is_symlink() else "directory",
                "resolved_path_sha256": "sha256:" + hashlib.sha256(
                    str(resolved_entry).encode("utf-8")
                ).hexdigest(),
                "sha256": entry_sha,
            }
        )
    digest = hashlib.sha256()
    for entry in entries:
        name = entry["name"].encode("utf-8")
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(bytes.fromhex(entry["sha256"].removeprefix("sha256:")))
    return "sha256:" + digest.hexdigest(), entries, errors


def observe_agent_skills(
    harness: dict[str, Any], *, enforce_expected: bool = True
) -> tuple[dict[str, Any] | None, list[str]]:
    """Hash the evaluator and every profile/task-selected skill for each client."""
    required_skills, errors = required_agent_skills(harness)
    configured = harness.get("agent_skills")
    if not isinstance(configured, dict) or set(configured) != {
        "task_skills", "expected_bundle_sha256", "installations",
    }:
        return None, errors + ["harness agent skill binding is invalid"]
    expected_bundle = configured.get("expected_bundle_sha256")
    if not isinstance(expected_bundle, str) or FINGERPRINT.fullmatch(expected_bundle) is None:
        errors.append("harness expected agent skill bundle hash is invalid")
    installations = configured.get("installations")
    if not isinstance(installations, dict) or set(installations) != {"codex", "claude"}:
        return None, errors + ["harness agent skill installations are invalid"]
    mode = harness.get("mode")
    expected_clients = {
        "codex": {"codex"},
        "claude": {"claude"},
        "collaborative": {"codex", "claude"},
    }.get(mode)
    if expected_clients is None:
        return None, errors + ["harness mode is invalid for agent skill installations"]
    observed_clients: list[dict[str, Any]] = []
    visible_roots: list[Path] = []
    evaluator_skill = Path(__file__).resolve().parents[1]
    evaluator_entries: list[Path] = []
    for client in ("codex", "claude"):
        installation = installations.get(client)
        if client not in expected_clients:
            if installation is not None:
                errors.append(f"unselected {client} skill installation must be null")
            continue
        if not isinstance(installation, dict) or set(installation) not in (
            {"collection_root"}, {"search_roots"}
        ):
            errors.append(f"selected {client} skill installation is invalid")
            continue
        if "collection_root" in installation:
            root_values = [installation.get("collection_root")]
        else:
            root_values = installation.get("search_roots")
        if (
            not isinstance(root_values, list)
            or not root_values
            or len(root_values) != len(set(root_values))
            or any(not isinstance(value, str) or not value.startswith("/") for value in root_values)
        ):
            errors.append(f"selected {client} skill search roots must be unique absolute paths")
            continue
        try:
            roots = [Path(value) for value in root_values]
            if any(root.is_symlink() or not root.is_dir() for root in roots):
                raise ValueError("search root is not a regular directory")
            roots = [root.absolute() for root in roots]
            bundle_sha256, skill_entries, search_errors = (
                _skill_bundle_from_search_roots(roots, required_skills)
            )
            errors.extend(f"selected {client}: {error}" for error in search_errors)
            evaluator_candidates = [
                root / "apple-development-health"
                for root in roots
                if (root / "apple-development-health").exists()
            ]
            if len(evaluator_candidates) == 1:
                evaluator_entries.append(evaluator_candidates[0].resolve(strict=True))
        except (OSError, ValueError) as error:
            errors.append(f"selected {client} skill bundle is unavailable: {error}")
            continue
        visible_roots.extend(roots)
        root_identity = (
            str(roots[0])
            if len(roots) == 1
            else json.dumps([str(root) for root in roots], separators=(",", ":"))
        )
        observed_clients.append(
            {
                "client": client,
                "root_path_sha256": "sha256:" + hashlib.sha256(
                    root_identity.encode("utf-8")
                ).hexdigest(),
                "bundle_sha256": bundle_sha256,
                "skills": skill_entries,
            }
        )
    if visible_roots and evaluator_skill not in evaluator_entries:
        errors.append("running health evaluator is outside the bound skill installations")
    bundle_values = {client["bundle_sha256"] for client in observed_clients}
    if len(bundle_values) > 1:
        errors.append("Codex and Claude installed skill bundles differ")
    if enforce_expected and (
        not observed_clients
        or any(client["bundle_sha256"] != expected_bundle for client in observed_clients)
    ):
        errors.append("installed agent skill bundle drifted from the harness")
    observation = {
        "required_skills": required_skills,
        "expected_bundle_sha256": expected_bundle,
        "clients": observed_clients,
    }
    return observation, errors


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


def _live_evidence(check_id: str, reason_code: str, material: Any) -> str:
    encoded = json.dumps(
        material, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return (
        f"evaluator-live:{check_id}:{reason_code}:sha256:"
        + hashlib.sha256(encoded).hexdigest()
    )


def _live_observation(
    check_id: str,
    *,
    status: str,
    reason_code: str,
    material: Any,
    summary: str,
) -> dict[str, Any]:
    observation = {
        "id": check_id,
        "status": status,
        "reason_code": reason_code,
        "summary": summary,
        "evidence": [_live_evidence(check_id, reason_code, material)],
    }
    if status != "healthy":
        observation["next_action"] = (
            "Repair or reconnect only this exact required surface, then run the "
            "bounded read-only health probe again."
        )
    return observation


def _run_read_only_probe(
    command: list[str],
    *,
    timeout: int = 15,
    runner: Any = subprocess.run,
) -> tuple[subprocess.CompletedProcess[str] | None, str | None]:
    """Run one allowlisted read-only command and classify failures without repair."""
    try:
        completed = runner(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except OSError:
        return None, "command_unavailable"
    if completed.returncode != 0:
        return completed, "command_failed"
    return completed, None


def _github_repository(remote: str) -> str:
    sanitized = sanitize_remote(remote)
    if sanitized.startswith("git@github.com:"):
        path = sanitized.removeprefix("git@github.com:")
    else:
        parsed = urllib.parse.urlsplit(sanitized)
        if parsed.hostname != "github.com":
            raise ValueError("GitHub remote must use github.com")
        path = parsed.path.lstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    if GITHUB_PATH.fullmatch(path) is None:
        raise ValueError("invalid GitHub repository")
    return path


def _parse_json_output(completed: subprocess.CompletedProcess[str]) -> Any:
    return json.loads(completed.stdout)


def _extract_json_rpc(body: str) -> dict[str, Any]:
    stripped = body.strip()
    if not stripped:
        return {}
    candidates = [
        line.removeprefix("data:").strip()
        for line in stripped.splitlines()
        if line.strip() and (line.lstrip().startswith("data:") or line.lstrip().startswith("{"))
    ]
    for candidate in reversed(candidates or [stripped]):
        try:
            payload = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            return payload
    raise ValueError("MCP response did not contain a JSON object")


def _mcp_http_post(
    payload: dict[str, Any], session_id: str | None, timeout: int = 15
) -> tuple[dict[str, Any], str | None]:
    headers = {
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
        "MCP-Protocol-Version": "2025-06-18",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    request = urllib.request.Request(
        APPLE_SAMPLE_CODE_ENDPOINT,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read(2_000_000).decode("utf-8", errors="strict")
        response_session = response.headers.get("Mcp-Session-Id") or session_id
    return _extract_json_rpc(body), response_session


def _probe_apple_sample_code_mcp() -> tuple[bool, Any]:
    """Perform a bounded initialize/tools-list/get-status sequence on the exact route."""
    try:
        initialized, session_id = _mcp_http_post(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "ios-experts-health", "version": "1.0.0"},
                },
            },
            None,
        )
        if "result" not in initialized or "error" in initialized:
            raise ValueError("initialize failed")
        _mcp_http_post(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}, session_id
        )
        tools_result, session_id = _mcp_http_post(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            session_id,
        )
        tools = tools_result.get("result", {}).get("tools", [])
        names = {
            item.get("name") for item in tools if isinstance(item, dict)
        }
        required = {"search_samples", "get_sample", "compare_samples", "get_status"}
        if not required.issubset(names):
            raise ValueError("required tools are unavailable")
        status_result, _ = _mcp_http_post(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "get_status", "arguments": {"refresh": False}},
            },
            session_id,
        )
        if "error" in status_result or status_result.get("result", {}).get("isError") is True:
            raise ValueError("get_status failed")
        return True, {
            "endpoint": APPLE_SAMPLE_CODE_ENDPOINT,
            "server": initialized.get("result", {}).get("serverInfo"),
            "tools": sorted(required),
            "status": status_result.get("result"),
        }
    except (
        OSError,
        ValueError,
        urllib.error.URLError,
        TimeoutError,
        json.JSONDecodeError,
    ) as error:
        return False, {"error_class": type(error).__name__}


def _read_stdio_json(
    process: subprocess.Popen[str], selector: selectors.BaseSelector, deadline: float
) -> dict[str, Any]:
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("MCP stdio response timed out")
        if not selector.select(remaining):
            raise TimeoutError("MCP stdio response timed out")
        assert process.stdout is not None
        line = process.stdout.readline()
        if not line:
            raise ValueError("MCP stdio server closed")
        payload = json.loads(line)
        if isinstance(payload, dict) and "id" in payload:
            return payload


def _probe_xcode_mcp_stdio(timeout: int = 15) -> tuple[bool, Any]:
    """Probe only initialize/tools-list; never invoke an Xcode mutation tool."""
    process: subprocess.Popen[str] | None = None
    selector: selectors.BaseSelector | None = None
    try:
        process = subprocess.Popen(
            ["xcrun", "mcpbridge"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        messages = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "ios-experts-health", "version": "1.0.0"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        ]
        for message in messages:
            process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        process.stdin.flush()
        initialized = _read_stdio_json(process, selector, deadline)
        listed = _read_stdio_json(process, selector, deadline)
        tools = listed.get("result", {}).get("tools", [])
        if "error" in initialized or "error" in listed or not isinstance(tools, list) or not tools:
            raise ValueError("Xcode MCP initialize or tools/list failed")
        return True, {
            "server": initialized.get("result", {}).get("serverInfo"),
            "tool_count": len(tools),
        }
    except (OSError, ValueError, TimeoutError, json.JSONDecodeError) as error:
        return False, {"error_class": type(error).__name__}
    finally:
        if selector is not None:
            selector.close()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def _selected_writer_skill_path(
    harness_document: dict[str, Any], skill_name: str
) -> Path:
    """Resolve one skill from the explicitly selected writer's installation.

    Codex and Claude may use distinct, byte-identical skill collections.  That
    is a supported split-root configuration; only duplicate copies *within the
    selected writer's ordered installation* are ambiguous.
    """
    writer = harness_document.get("selected_writer")
    installations = harness_document.get("agent_skills", {}).get("installations", {})
    if writer not in {"codex", "claude"} or not isinstance(installations, dict):
        raise OSError("selected writer skill installation is unavailable")
    installation = installations.get(writer)
    if not isinstance(installation, dict):
        raise OSError("selected writer skill installation is unavailable")
    roots = (
        [installation["collection_root"]]
        if isinstance(installation.get("collection_root"), str)
        else installation.get("search_roots", [])
    )
    if not isinstance(roots, list) or not roots:
        raise OSError("selected writer skill search roots are unavailable")
    candidates = [
        Path(root) / skill_name
        for root in roots
        if isinstance(root, str)
        and (Path(root) / skill_name).is_dir()
    ]
    if len(candidates) != 1:
        raise OSError(
            f"selected writer {skill_name} is missing or shadowed across configured roots"
        )
    return candidates[0].resolve(strict=True)


def _load_installed_agent_harness_module(
    harness_path: Path | None = None,
    harness_document: dict[str, Any] | None = None,
) -> Any:
    candidates: list[Path] = []
    if harness_document is not None:
        raw = harness_document
    elif harness_path is not None:
        try:
            raw = json.loads(harness_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise OSError("harness cannot be read for installed-skill resolution") from error
    else:
        raw = None
    if isinstance(raw, dict):
        selected = _selected_writer_skill_path(raw, "agent-harness")
        candidate = selected / "scripts" / "resource_coordinator.py"
        if candidate.is_file() and not candidate.is_symlink():
            candidates.append(candidate)
    else:
        sibling = (
            Path(__file__).resolve().parents[2]
            / "agent-harness"
            / "scripts"
            / "resource_coordinator.py"
        )
        if sibling.is_file() and not sibling.is_symlink():
            candidates.append(sibling)
    resolved = {candidate.resolve(strict=True) for candidate in candidates}
    if len(resolved) != 1:
        raise OSError(
            "selected writer agent-harness coordinator is missing or shadowed"
        )
    path = next(iter(resolved))
    specification = importlib.util.spec_from_file_location(
        "_health_installed_resource_coordinator", path
    )
    if specification is None or specification.loader is None:
        raise OSError("installed agent-harness coordinator cannot be loaded")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def load_trusted_scope(
    harness_path: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any] | None]:
    """Load harness plus private policy/authorization from installed trusted code."""
    coordinator = _load_installed_agent_harness_module(harness_path)
    harness = coordinator.load_trusted_harness(harness_path)
    documents: list[dict[str, Any] | None] = []
    for field, optional in (("private_policy_overlay", False), ("run_authorization", True)):
        path = Path(str(harness[field]))
        if not path.is_absolute() or path.is_symlink() or not path.is_file():
            if optional:
                documents.append(None)
                continue
            raise OSError(f"trusted {field} is unavailable")
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"trusted {field} must contain an object")
        documents.append(payload)
    policy = documents[0]
    authorization = documents[1]
    if not isinstance(policy, dict) or policy.get("decision") != "approved":
        raise ValueError("private policy overlay is not approved")
    allowed_policy_fields = {"$schema", "schema_version", "decision", "github", "apple"}
    if set(policy) - allowed_policy_fields:
        raise ValueError("private policy overlay contains unsupported fields")
    github_policy = policy.get("github")
    if (
        policy.get("schema_version") != "1.0.0"
        or not isinstance(github_policy, dict)
        or set(github_policy) != {"owner"}
        or not isinstance(github_policy.get("owner"), str)
        or not github_policy["owner"]
    ):
        raise ValueError("private policy overlay GitHub boundary is invalid")
    return harness, policy, authorization


def _probe_registration(
    harness: dict[str, Any], name: str, expected: tuple[str, ...], runner: Any
) -> tuple[bool, Any]:
    installations = harness.get("agent_skills", {}).get("installations", {})
    results: list[dict[str, Any]] = []
    for client in ("codex", "claude"):
        if installations.get(client) is None:
            continue
        command = (
            ["codex", "mcp", "get", name, "--json"]
            if client == "codex"
            else ["claude", "mcp", "get", name]
        )
        completed, failure = _run_read_only_probe(command, runner=runner)
        if failure or completed is None:
            return False, {"client": client, "failure": failure}
        combined = completed.stdout + "\n" + completed.stderr
        if any(fragment not in combined for fragment in expected):
            return False, {"client": client, "failure": "registration_drift"}
        results.append({"client": client, "registration_sha256": hashlib.sha256(combined.encode()).hexdigest()})
    return (bool(results), results or {"failure": "no_selected_client"})


def _load_selected_agent_harness_script(
    harness: dict[str, Any], script_name: str
) -> Any:
    root = _selected_writer_skill_path(harness, "agent-harness")
    path = root / "scripts" / script_name
    if not path.is_file() or path.is_symlink():
        raise OSError(f"selected writer agent-harness {script_name} is unavailable")
    specification = importlib.util.spec_from_file_location(
        f"_health_selected_{script_name.removesuffix('.py')}", path
    )
    if specification is None or specification.loader is None:
        raise OSError(f"selected writer agent-harness {script_name} cannot be loaded")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def _collect_spec_kit_snapshot(
    report: dict[str, Any], harness: dict[str, Any], authorization: dict[str, Any] | None
) -> tuple[bool, dict[str, Any]]:
    if harness.get("spec_kit", {}).get("enabled") is not True:
        raise ValueError("Spec Kit is not enabled in the trusted harness")
    binding = authorization.get("spec_kit") if isinstance(authorization, dict) else None
    if not isinstance(binding, dict):
        raise ValueError("approved Spec Kit authorization binding is unavailable")
    root = report.get("authoritative_targets", {}).get("repository")
    if not isinstance(root, str) or not root.startswith("/"):
        raise ValueError("authoritative repository is unavailable for Spec Kit snapshot")
    snapshot = _load_selected_agent_harness_script(harness, "spec_kit_snapshot.py")
    current = snapshot.build_snapshot(
        Path(root),
        feature_directory=binding.get("feature_directory"),
        run_id=binding.get("workflow_run_id"),
        release=binding.get("release"),
    )
    expected = {
        "spec_kit_release": binding.get("release"),
        "feature_id": binding.get("feature_id"),
        "feature_directory": binding.get("feature_directory"),
        "artifact_hashes": binding.get("artifact_hashes"),
        "snapshot_sha256": binding.get("snapshot_sha256"),
    }
    matches = all(current.get(key) == value for key, value in expected.items())
    return matches, {
        "feature_id": current.get("feature_id"),
        "feature_directory": current.get("feature_directory"),
        "snapshot_sha256": current.get("snapshot_sha256"),
        "workflow_run_id": binding.get("workflow_run_id"),
        "matches_authorization": matches,
    }


def _collect_local_llm(runner: Any) -> tuple[bool, dict[str, Any]]:
    """Check one conventional local-only model inventory without invoking inference."""
    configured_host = os.environ.get("OLLAMA_HOST")
    candidate = configured_host or "http://127.0.0.1:11434"
    parsed = urllib.parse.urlsplit(
        candidate if "://" in candidate else "http://" + candidate
    )
    hostname = parsed.hostname
    loopback = hostname == "localhost"
    if isinstance(hostname, str) and not loopback:
        try:
            loopback = ipaddress.ip_address(hostname).is_loopback
        except ValueError:
            loopback = False
    if (
        parsed.scheme not in {"http", "https"}
        or not loopback
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError("OLLAMA_HOST must bind to an explicit loopback endpoint")
    completed, failure = _run_read_only_probe(["ollama", "list"], runner=runner)
    if failure or completed is None:
        raise OSError(failure or "local_llm_inventory_failed")
    lines = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if not lines or not lines[0].split() or lines[0].split()[0].upper() != "NAME":
        raise ValueError("local LLM inventory has an unsupported format")
    models = [line.split()[0] for line in lines[1:] if line.split()]
    if not models:
        raise ValueError("local LLM inventory contains no installed model")
    return True, {
        "provider": "ollama",
        "endpoint_scope": "loopback",
        "model_count": len(models),
        "model_names_sha256": hashlib.sha256(",".join(sorted(models)).encode()).hexdigest(),
    }


def _collect_companion_upstream(
    harness: dict[str, Any], runner: Any
) -> tuple[bool, dict[str, Any]]:
    skill_root = _selected_writer_skill_path(harness, "icon-composer")
    manifest_path = skill_root / "contracts" / "companion-upstream.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise OSError("selected writer companion provenance manifest is unavailable")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    upstream = manifest.get("upstream", {})
    sources = manifest.get("sources", [])
    repository = upstream.get("repository")
    reviewed = upstream.get("reviewed_revision")
    reviewed_tree = upstream.get("reviewed_tree")
    branch = upstream.get("default_branch")
    if not all(isinstance(value, str) and value for value in (repository, reviewed, reviewed_tree, branch)):
        raise ValueError("companion provenance manifest is incomplete")
    metadata, metadata_failure = _run_read_only_probe(
        ["gh", "api", f"repos/{repository}"], runner=runner
    )
    commit, commit_failure = _run_read_only_probe(
        ["gh", "api", f"repos/{repository}/commits/{reviewed}"], runner=runner
    )
    tree, tree_failure = _run_read_only_probe(
        ["gh", "api", f"repos/{repository}/git/trees/{reviewed_tree}?recursive=1"], runner=runner
    )
    head, head_failure = _run_read_only_probe(
        ["gh", "api", f"repos/{repository}/commits/{branch}"], runner=runner
    )
    if any((metadata_failure, commit_failure, tree_failure, head_failure)):
        raise OSError("companion upstream probe failed")
    metadata_value = _parse_json_output(metadata)  # type: ignore[arg-type]
    commit_value = _parse_json_output(commit)  # type: ignore[arg-type]
    tree_value = _parse_json_output(tree)  # type: ignore[arg-type]
    head_value = _parse_json_output(head)  # type: ignore[arg-type]
    blobs = {
        item.get("path"): item.get("sha")
        for item in tree_value.get("tree", [])
        if isinstance(item, dict) and item.get("type") == "blob"
    }
    sources_match = isinstance(sources, list) and all(
        isinstance(source, dict) and blobs.get(source.get("path")) == source.get("blob_sha")
        for source in sources
    )
    valid = (
        metadata_value.get("private") is False
        and metadata_value.get("visibility") == "public"
        and metadata_value.get("default_branch") == branch
        and commit_value.get("sha") == reviewed
        and commit_value.get("commit", {}).get("tree", {}).get("sha") == reviewed_tree
        and isinstance(head_value.get("sha"), str)
        and sources_match
    )
    return valid, {
        "repository": repository,
        "reviewed_revision": reviewed,
        "reviewed_tree": reviewed_tree,
        "observed_head": head_value.get("sha"),
        "sources_match": sources_match,
    }


def collect_live_observations(
    report: dict[str, Any],
    harness: dict[str, Any],
    policy: dict[str, Any],
    authorization: dict[str, Any] | None,
    *,
    runner: Any = subprocess.run,
    xcode_mcp_probe: Any = _probe_xcode_mcp_stdio,
    apple_sample_code_probe: Any = _probe_apple_sample_code_mcp,
) -> dict[str, dict[str, Any]]:
    """Recompute high-risk health facts; never repair, mutate, boot, or reboot."""
    required = set(report.get("required_check_ids", []))
    selected = EVALUATOR_OWNED_CHECKS & required
    observations: dict[str, dict[str, Any]] = {}

    def record(
        check_id: str, ok: bool, reason: str, material: Any, healthy: str
    ) -> None:
        observations[check_id] = _live_observation(
            check_id,
            status="healthy" if ok else "blocked",
            reason_code=reason if ok else f"{reason}_blocked",
            material=material,
            summary=healthy if ok else f"Required live {check_id} observation failed closed.",
        )

    if {"github.issue_pr", "github.project"} & selected:
        try:
            remote = str(report.get("authoritative_targets", {}).get("remote", ""))
            repository = _github_repository(remote)
            owner = str(policy.get("github", {}).get("owner", ""))
            if repository.split("/", 1)[0].lower() != owner.lower():
                raise ValueError("policy owner differs from repository owner")
            identity, identity_failure = _run_read_only_probe(
                ["gh", "api", "user", "--jq", ".login"], runner=runner
            )
            repository_result, repository_failure = _run_read_only_probe(
                [
                    "gh", "repo", "view", repository,
                    "--json", "nameWithOwner,viewerPermission,hasIssuesEnabled",
                ],
                runner=runner,
            )
            if identity_failure or repository_failure or identity is None or repository_result is None:
                raise OSError(identity_failure or repository_failure or "github_probe_failed")
            identity_value = identity.stdout.strip()
            repository_value = _parse_json_output(repository_result)
            if (
                identity_value.lower() != owner.lower()
                or str(repository_value.get("nameWithOwner", "")).lower() != repository.lower()
                or repository_value.get("hasIssuesEnabled") is not True
                or repository_value.get("viewerPermission") not in {"WRITE", "MAINTAIN", "ADMIN"}
            ):
                raise ValueError("GitHub identity, repository, Issues, or write permission drifted")
            github_material = {
                "owner_match": True,
                "repository_match": True,
                "issues": True,
                "permission": repository_value.get("viewerPermission"),
            }
            if "github.issue_pr" in selected:
                record(
                    "github.issue_pr", True, "exact_repository_access", github_material,
                    "Evaluator confirmed the approved GitHub identity and exact Issue/PR repository.",
                )
            if "github.project" in selected:
                project = harness.get("github_tracking", {}).get("project")
                project_number = project.get("number") if isinstance(project, dict) else None
                project_owner = project.get("owner", owner) if isinstance(project, dict) else owner
                if not isinstance(project_number, int) or isinstance(project_number, bool) or project_number < 1:
                    raise ValueError("GitHub Project lacks an exact numeric project number")
                project_result, project_failure = _run_read_only_probe(
                    [
                        "gh", "project", "view", str(project_number),
                        "--owner", str(project_owner), "--format", "json",
                    ],
                    runner=runner,
                )
                if project_failure or project_result is None:
                    raise OSError(project_failure or "github_project_probe_failed")
                project_value = _parse_json_output(project_result)
                if str(project_value.get("number", project_number)) != str(project_number):
                    raise ValueError("GitHub Project identity drifted")
                record(
                    "github.project", True, "exact_project_access",
                    {"owner": str(project_owner).lower(), "number": project_number},
                    "Evaluator confirmed the exact selected GitHub Project.",
                )
        except (OSError, ValueError, json.JSONDecodeError) as error:
            for check_id in {"github.issue_pr", "github.project"} & selected:
                if check_id not in observations:
                    record(check_id, False, "github_probe", {"error_class": type(error).__name__}, "")

    xcode_checks = {"xcode.authoritative_container", "apple.execution_path"} & selected
    if xcode_checks:
        try:
            selected_path, selected_failure = _run_read_only_probe(
                ["/usr/bin/xcode-select", "-p"], runner=runner
            )
            found, found_failure = _run_read_only_probe(
                ["/usr/bin/xcrun", "--find", "xcodebuild"], runner=runner
            )
            if selected_failure or found_failure or selected_path is None or found is None:
                raise OSError(selected_failure or found_failure or "xcode_probe_failed")
            developer = selected_path.stdout.strip()
            executable = found.stdout.strip()
            if not developer or not executable or not Path(executable).is_relative_to(Path(developer)):
                raise ValueError("xcodebuild does not belong to the selected developer directory")
            version, version_failure = _run_read_only_probe(
                [executable, "-version"], runner=runner
            )
            if version_failure or version is None or not version.stdout.strip():
                raise OSError(version_failure or "xcode_version_failed")
            material = {
                "developer_sha256": hashlib.sha256(developer.encode()).hexdigest(),
                "xcodebuild_sha256": hashlib.sha256(executable.encode()).hexdigest(),
                "version_sha256": hashlib.sha256(version.stdout.encode()).hexdigest(),
            }
            for check_id in xcode_checks:
                record(
                    check_id, True, "selected_xcode_toolchain", material,
                    "Evaluator confirmed the selected Xcode developer directory and toolchain.",
                )
        except (OSError, ValueError) as error:
            for check_id in xcode_checks:
                record(check_id, False, "xcode_probe", {"error_class": type(error).__name__}, "")

    if "simulator.runtime" in selected:
        completed, failure = _run_read_only_probe(
            ["/usr/bin/xcrun", "simctl", "list", "runtimes", "--json"],
            timeout=30,
            runner=runner,
        )
        try:
            if failure or completed is None:
                raise OSError(failure or "simulator_inventory_failed")
            payload = _parse_json_output(completed)
            runtimes = payload.get("runtimes") if isinstance(payload, dict) else None
            if not isinstance(runtimes, list) or not any(
                isinstance(item, dict) and item.get("isAvailable") is not False
                for item in runtimes
            ):
                raise ValueError("no available Simulator runtime")
            record(
                "simulator.runtime", True, "bounded_runtime_inventory",
                {"available_runtime_count": sum(
                    isinstance(item, dict) and item.get("isAvailable") is not False
                    for item in runtimes
                )},
                "Evaluator completed one bounded, read-only Simulator runtime inventory.",
            )
        except (OSError, ValueError, json.JSONDecodeError) as error:
            record(
                "simulator.runtime", False, "simulator_inventory",
                {"error_class": type(error).__name__, "mutation_attempted": False}, "",
            )

    apple_checks = {
        "apple.account_guard", "cli.asc", "testflight.upload_target",
        "testflight.internal_groups",
    } & selected
    if apple_checks:
        try:
            policy_apple = policy.get("apple")
            authorized_apple = authorization.get("apple") if isinstance(authorization, dict) else None
            if not isinstance(policy_apple, dict) or not isinstance(authorized_apple, dict):
                raise ValueError("Apple policy or exact authorization is unavailable")
            profile = policy_apple.get("account_guard_ref")
            if (
                not isinstance(profile, str) or not profile
                or authorized_apple.get("account_guard_ref") != profile
                or authorized_apple.get("team_id") != policy_apple.get("team_id")
            ):
                raise ValueError("Apple account guard or team drifted")
            if "apple.account_guard" in selected:
                record(
                    "apple.account_guard", True, "private_guard_match",
                    {"profile_sha256": hashlib.sha256(profile.encode()).hexdigest(), "team_match": True},
                    "Evaluator bound the exact private ASC profile and approved Apple team.",
                )
            auth_status, auth_failure = _run_read_only_probe(
                ["asc", "--profile", profile, "auth", "status", "--validate"], runner=runner
            )
            if auth_failure or auth_status is None:
                raise OSError(auth_failure or "asc_auth_failed")
            if "cli.asc" in selected:
                record(
                    "cli.asc", True, "guarded_auth_validation",
                    {"status_sha256": hashlib.sha256(auth_status.stdout.encode()).hexdigest()},
                    "Evaluator validated ASC authentication under the exact private profile.",
                )
            target_checks = {"testflight.upload_target", "testflight.internal_groups"} & selected
            if target_checks:
                apps_result, apps_failure = _run_read_only_probe(
                    [
                        "asc", "--profile", profile, "apps", "list",
                        "--paginate", "--output", "json",
                    ],
                    runner=runner,
                )
                if apps_failure or apps_result is None:
                    raise OSError(apps_failure or "asc_apps_failed")
                apps_payload = _parse_json_output(apps_result)
                apps = apps_payload.get("data") if isinstance(apps_payload, dict) else None
                matches = [
                    item for item in apps or []
                    if isinstance(item, dict)
                    and item.get("id") == authorized_apple.get("app_id")
                    and item.get("attributes", {}).get("bundleId") == authorized_apple.get("bundle_id")
                ]
                if len(matches) != 1:
                    raise ValueError("exact ASC app and bundle target did not resolve once")
                if "testflight.upload_target" in selected:
                    record(
                        "testflight.upload_target", True, "exact_app_target",
                        {"app_id": authorized_apple.get("app_id"), "bundle_match": True},
                        "Evaluator confirmed the exact authorized App Store Connect app target.",
                    )
                if "testflight.internal_groups" in selected:
                    groups_result, groups_failure = _run_read_only_probe(
                        [
                            "asc", "--profile", profile, "testflight", "beta-groups", "list",
                            "--app", str(authorized_apple.get("app_id")),
                            "--paginate", "--output", "json",
                        ],
                        runner=runner,
                    )
                    if groups_failure or groups_result is None:
                        raise OSError(groups_failure or "asc_groups_failed")
                    groups_payload = _parse_json_output(groups_result)
                    groups = groups_payload.get("data") if isinstance(groups_payload, dict) else None
                    live_ids = {
                        item.get("id") for item in groups or [] if isinstance(item, dict)
                    }
                    expected_ids = set(authorized_apple.get("internal_group_ids", []))
                    if not expected_ids or not expected_ids.issubset(live_ids):
                        raise ValueError("authorized internal TestFlight group set drifted")
                    record(
                        "testflight.internal_groups", True, "exact_internal_groups",
                        {"group_ids": sorted(expected_ids)},
                        "Evaluator confirmed every exact authorized internal TestFlight group.",
                    )
        except (OSError, ValueError, json.JSONDecodeError) as error:
            for check_id in apple_checks:
                if check_id not in observations:
                    record(check_id, False, "apple_probe", {"error_class": type(error).__name__}, "")

    if "mcp.xcode" in selected:
        registered, registration = _probe_registration(
            harness, "xcode", ("xcrun", "mcpbridge"), runner
        )
        connected, connection = xcode_mcp_probe() if registered else (False, {})
        record(
            "mcp.xcode", registered and connected, "registration_and_read_only_tools",
            {"registration": registration, "connection": connection},
            "Evaluator confirmed exact Xcode MCP registration and a bounded read-only tools/list call.",
        )

    if "mcp.apple_sample_code" in selected:
        registered, registration = _probe_registration(
            harness, "apple-sample-code", (APPLE_SAMPLE_CODE_ENDPOINT,), runner
        )
        connected, connection = apple_sample_code_probe() if registered else (False, {})
        record(
            "mcp.apple_sample_code", registered and connected,
            "registration_tools_and_get_status",
            {"registration": registration, "connection": connection},
            "Evaluator confirmed exact AppleSampleCode registration, tools, and get_status read-back.",
        )

    if "spec_kit.snapshot" in selected:
        try:
            ok, material = _collect_spec_kit_snapshot(report, harness, authorization)
            record(
                "spec_kit.snapshot", ok, "approved_snapshot_readback", material,
                "Evaluator rebuilt the approved Spec Kit snapshot from the authoritative repository.",
            )
        except (OSError, ValueError, json.JSONDecodeError) as error:
            record("spec_kit.snapshot", False, "spec_kit_snapshot", {"error_class": type(error).__name__}, "")

    if "local_llm" in selected:
        try:
            ok, material = _collect_local_llm(runner)
            record(
                "local_llm", ok, "local_model_inventory", material,
                "Evaluator confirmed a bounded local-only model inventory without inference.",
            )
        except (OSError, ValueError) as error:
            record("local_llm", False, "local_llm_inventory", {"error_class": type(error).__name__}, "")

    if "companion_upstream.provenance" in selected:
        try:
            ok, material = _collect_companion_upstream(harness, runner)
            record(
                "companion_upstream.provenance", ok, "public_provenance_readback", material,
                "Evaluator confirmed the public companion provenance and source blob bindings.",
            )
        except (OSError, ValueError, json.JSONDecodeError) as error:
            record(
                "companion_upstream.provenance", False, "companion_upstream",
                {"error_class": type(error).__name__}, "",
            )
    return observations


def reconcile_live_observations(
    report: dict[str, Any], observations: dict[str, dict[str, Any]]
) -> dict[str, Any]:
    reconciled = copy.deepcopy(report)
    for check in reconciled.get("checks", []):
        if not isinstance(check, dict) or check.get("id") not in observations:
            continue
        observation = observations[check["id"]]
        check["status"] = observation["status"]
        check["summary"] = observation["summary"]
        check["evidence"] = observation["evidence"]
        check.pop("next_action", None)
        if "next_action" in observation:
            check["next_action"] = observation["next_action"]
    return reconciled


def evaluate(
    report: dict[str, Any],
    now: datetime | None = None,
    evaluator_observed_check_ids: set[str] | None = None,
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
        "agent_skill_manifest",
        "resource_coordinator_observation",
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
    skill_manifest = report.get("agent_skill_manifest")
    if not isinstance(skill_manifest, dict) or set(skill_manifest) != {
        "required_skills", "expected_bundle_sha256", "clients",
    }:
        errors.append("agent skill manifest is invalid")
    else:
        required_skills = skill_manifest.get("required_skills")
        expected_bundle = skill_manifest.get("expected_bundle_sha256")
        clients = skill_manifest.get("clients")
        if (
            not isinstance(required_skills, list)
            or not required_skills
            or required_skills != sorted(set(required_skills))
            or any(not isinstance(item, str) or SKILL_NAME.fullmatch(item) is None
                   for item in required_skills)
        ):
            errors.append("agent skill manifest required skills are invalid")
        if not isinstance(expected_bundle, str) or FINGERPRINT.fullmatch(expected_bundle) is None:
            errors.append("agent skill manifest expected bundle hash is invalid")
        if not isinstance(clients, list) or not clients or len(clients) > 2:
            errors.append("agent skill manifest clients are invalid")
        else:
            seen_clients: set[str] = set()
            for client in clients:
                if not isinstance(client, dict) or set(client) != {
                    "client", "root_path_sha256", "bundle_sha256", "skills",
                }:
                    errors.append("agent skill manifest client entry is invalid")
                    continue
                client_name = client.get("client")
                if client_name not in {"codex", "claude"} or client_name in seen_clients:
                    errors.append("agent skill manifest clients must be unique and known")
                else:
                    seen_clients.add(client_name)
                for field in ("root_path_sha256", "bundle_sha256"):
                    value = client.get(field)
                    if not isinstance(value, str) or FINGERPRINT.fullmatch(value) is None:
                        errors.append(f"agent skill manifest {field} is invalid")
                entries = client.get("skills")
                if (
                    not isinstance(entries, list)
                    or [entry.get("name") for entry in entries if isinstance(entry, dict)]
                    != required_skills
                    or any(
                        not isinstance(entry, dict)
                        or set(entry) != {
                            "name", "entry_kind", "resolved_path_sha256", "sha256"
                        }
                        or entry.get("entry_kind") not in {"directory", "symlink"}
                        or not isinstance(entry.get("resolved_path_sha256"), str)
                        or FINGERPRINT.fullmatch(entry["resolved_path_sha256"]) is None
                        or not isinstance(entry.get("sha256"), str)
                        or FINGERPRINT.fullmatch(entry["sha256"]) is None
                        for entry in entries
                    )
                ):
                    errors.append("agent skill manifest per-client skills are invalid")
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
    observed_check_ids = evaluator_observed_check_ids or set()
    for check_id, check in checks_by_id.items():
        if (
            check_id in EVALUATOR_OWNED_CHECKS
            and check_id not in required_check_ids
            and check.get("status") in {"healthy", "degraded"}
        ):
            errors.append(
                f"unselected evaluator-owned check cannot claim success: {check_id}"
            )
    for check_id in required_check_ids:
        check = checks_by_id.get(check_id)
        if check is None:
            errors.append(f"required health check is missing: {check_id}")
        elif check.get("required") is not True:
            errors.append(f"required health check must set required true: {check_id}")
        elif (
            check_id in EVALUATOR_OWNED_CHECKS
            and check.get("status") in {"healthy", "degraded"}
            and check_id not in observed_check_ids
        ):
            errors.append(
                f"required health check needs evaluator-owned live observation: {check_id}"
            )

    coordinator_observation = report.get("resource_coordinator_observation")
    coordinator_fields = {
        "state_path_sha256", "coordinator_instance_id", "state_schema_version",
        "migration_bootstrap_confirmed", "script_sha256",
        "contract_bundle_sha256", "active_lease_count",
    }
    coordinator_observation_valid = isinstance(coordinator_observation, dict)
    if coordinator_observation_valid:
        coordinator_observation_valid = (
            set(coordinator_observation) == coordinator_fields
            and isinstance(coordinator_observation.get("state_path_sha256"), str)
            and FINGERPRINT.fullmatch(coordinator_observation["state_path_sha256"]) is not None
            and isinstance(coordinator_observation.get("coordinator_instance_id"), str)
            and bool(coordinator_observation["coordinator_instance_id"])
            and coordinator_observation.get("state_schema_version") == 1
            and coordinator_observation.get("migration_bootstrap_confirmed") is True
            and isinstance(coordinator_observation.get("script_sha256"), str)
            and FINGERPRINT.fullmatch(coordinator_observation["script_sha256"]) is not None
            and isinstance(coordinator_observation.get("contract_bundle_sha256"), str)
            and FINGERPRINT.fullmatch(coordinator_observation["contract_bundle_sha256"]) is not None
            and isinstance(coordinator_observation.get("active_lease_count"), int)
            and not isinstance(coordinator_observation.get("active_lease_count"), bool)
            and coordinator_observation["active_lease_count"] >= 0
        )
    if not coordinator_observation_valid:
        errors.append("resource coordinator observation is invalid")
    coordinator_check = checks_by_id.get("agent.resource_coordinator")
    if isinstance(coordinator_check, dict) and coordinator_check.get("status") != "healthy":
        errors.append("required resource coordinator health check must be healthy")

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


def observe_resource_coordinator(
    harness: dict[str, Any],
) -> tuple[dict[str, Any] | None, list[str]]:
    """Read back the one coordinator bound by the trusted private harness."""
    binding = harness.get("resource_coordinator")
    required = {
        "state_path", "coordinator_instance_id", "script_sha256",
        "contract_bundle_sha256",
    }
    if not isinstance(binding, dict) or set(binding) != required:
        return None, ["harness resource coordinator binding is invalid"]
    state_value = binding.get("state_path")
    if not isinstance(state_value, str) or not state_value.startswith("/"):
        return None, ["harness resource coordinator state path must be absolute"]
    state_path = Path(state_value)
    if state_path.is_symlink() or not state_path.is_file():
        return None, ["harness resource coordinator state must be an existing non-symlink file"]
    try:
        installed_coordinator = _load_installed_agent_harness_module(
            harness_document=harness
        )
        script_path = Path(installed_coordinator.__file__).resolve(strict=True)
    except (OSError, AttributeError) as error:
        return None, [f"installed resource coordinator script is unavailable: {error}"]
    if script_path.is_symlink() or not script_path.is_file():
        return None, ["installed resource coordinator script is unavailable"]
    script_sha256 = "sha256:" + hashlib.sha256(script_path.read_bytes()).hexdigest()
    if binding.get("script_sha256") != script_sha256:
        return None, ["installed resource coordinator script hash drifted from the harness"]
    try:
        bundle_completed = subprocess.run(
            [sys.executable, str(script_path), str(state_path), "bundle-digest"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        bundle_payload = json.loads(bundle_completed.stdout)
        bundle_result = bundle_payload.get("result") if isinstance(bundle_payload, dict) else None
        contract_bundle_sha256 = (
            bundle_result.get("contract_bundle_sha256")
            if isinstance(bundle_result, dict)
            else None
        )
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        return None, [f"resource coordinator contract bundle read-back failed: {error}"]
    if (
        bundle_completed.returncode != 0
        or bundle_payload.get("status") != "ok"
        or not isinstance(contract_bundle_sha256, str)
        or FINGERPRINT.fullmatch(contract_bundle_sha256) is None
    ):
        return None, ["resource coordinator contract bundle read-back was blocked"]
    if binding.get("contract_bundle_sha256") != contract_bundle_sha256:
        return None, ["installed contract bundle hash drifted from the harness"]
    try:
        completed = subprocess.run(
            [sys.executable, str(script_path), str(state_path), "status"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        payload = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        return None, [f"resource coordinator status read-back failed: {error}"]
    state = payload.get("result") if isinstance(payload, dict) else None
    if completed.returncode != 0 or payload.get("status") != "ok" or not isinstance(state, dict):
        return None, ["resource coordinator status read-back was blocked"]
    bootstrap = state.get("migration_bootstrap")
    instance = state.get("coordinator_instance_id")
    active_lease_count = state.get("active_lease_count")
    if (
        state.get("schema_version") != 1
        or not isinstance(instance, str)
        or not instance
        or not isinstance(bootstrap, dict)
        or bootstrap.get("legacy_leases_quiesced") is not True
        or not isinstance(active_lease_count, int)
        or isinstance(active_lease_count, bool)
        or active_lease_count < 0
    ):
        return None, ["resource coordinator state is not bootstrapped or valid"]
    if binding.get("coordinator_instance_id") != instance:
        return None, ["resource coordinator instance drifted from the harness"]
    canonical_state = state_path.resolve(strict=True)
    observation = {
        "state_path_sha256": "sha256:" + hashlib.sha256(
            str(canonical_state).encode("utf-8")
        ).hexdigest(),
        "coordinator_instance_id": instance,
        "state_schema_version": 1,
        "migration_bootstrap_confirmed": True,
        "script_sha256": script_sha256,
        "contract_bundle_sha256": contract_bundle_sha256,
        "active_lease_count": active_lease_count,
    }
    return observation, []


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
    skill_observation, skill_errors = observe_agent_skills(harness)
    errors.extend(skill_errors)
    if skill_observation is not None and report.get("agent_skill_manifest") != skill_observation:
        errors.append("agent skill manifest drifted from live installed skills")
    coordinator_observation, coordinator_errors = observe_resource_coordinator(harness)
    errors.extend(coordinator_errors)
    reported_coordinator = report.get("resource_coordinator_observation")
    if coordinator_observation is not None and isinstance(reported_coordinator, dict):
        stable_fields = {
            "state_path_sha256", "coordinator_instance_id", "state_schema_version",
            "migration_bootstrap_confirmed", "script_sha256",
            "contract_bundle_sha256",
        }
        if any(
            reported_coordinator.get(field) != coordinator_observation.get(field)
            for field in stable_fields
        ):
            errors.append("resource coordinator identity drifted from live harness state")
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
    parser.add_argument("report", type=Path, nargs="?")
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
    parser.add_argument(
        "--observe-agent-skills",
        action="store_true",
        help="Print the derived live skill manifest without evaluating a health report.",
    )
    parser.add_argument(
        "--expected-report-bytes-sha256",
        help="Optional sha256:<hex> binding supplied by the trusted caller for the exact report bytes.",
    )
    arguments = parser.parse_args()
    try:
        coordinator = _load_installed_agent_harness_module(arguments.harness)
        harness = coordinator.load_trusted_harness(arguments.harness)
    except Exception as error:
        print(json.dumps({
            "report": {"overall_status": "blocked"},
            "valid": False,
            "errors": [f"trusted harness loading failed: {error}"],
        }, indent=2, sort_keys=True))
        return 2
    if arguments.observe_agent_skills:
        observation, errors = observe_agent_skills(harness, enforce_expected=False)
        valid = observation is not None and not errors
        print(json.dumps({"manifest": observation, "valid": valid, "errors": errors}, indent=2, sort_keys=True))
        return 0 if valid else 2
    if arguments.report is None:
        parser.error("report is required unless --observe-agent-skills is used")
    try:
        _, policy, authorization = load_trusted_scope(arguments.harness)
        report_bytes = arguments.report.read_bytes()
        observed_bytes_sha256 = "sha256:" + hashlib.sha256(report_bytes).hexdigest()
        if (
            arguments.expected_report_bytes_sha256 is not None
            and arguments.expected_report_bytes_sha256 != observed_bytes_sha256
        ):
            raise ValueError("health report bytes drifted before evaluator read")
        report = json.loads(report_bytes.decode("utf-8"))
        if not isinstance(report, dict):
            raise ValueError("health report must contain an object")
        observations = collect_live_observations(
            report, harness, policy, authorization
        )
        reconciled = reconcile_live_observations(report, observations)
        evaluated, errors = evaluate(
            reconciled,
            evaluator_observed_check_ids=set(observations),
        )
    except Exception as error:
        print(json.dumps({
            "report": {"overall_status": "blocked"},
            "valid": False,
            "errors": [f"live health observation failed closed: {error}"],
        }, indent=2, sort_keys=True))
        return 2
    trusted_components = set(arguments.require_component)
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
    if harness.get("health_profile") != reconciled.get("profile"):
        errors.append("health report profile drifted from harness")
    errors.extend(validate_harness_binding(reconciled, harness))
    observed_components = set(reconciled.get("selected_components", []))
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
    required_live_failures = {
        check.get("id")
        for check in evaluated.get("checks", [])
        if isinstance(check, dict)
        and check.get("required") is True
        and check.get("id") in EVALUATOR_OWNED_CHECKS
        and check.get("status") != "healthy"
    }
    if required_live_failures:
        errors.append(
            "required evaluator-owned checks are not healthy: "
            + ", ".join(sorted(required_live_failures))
        )
        evaluated["overall_status"] = "blocked"
    errors = sorted(set(errors))
    valid = not errors and evaluated["overall_status"] != "blocked"
    print(json.dumps({"report": evaluated, "valid": valid, "errors": errors}, indent=2, sort_keys=True))
    return 0 if valid else 2


if __name__ == "__main__":
    raise SystemExit(main())
