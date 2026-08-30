#!/usr/bin/env python3
"""Resolve an optional local project registry without changing machine state.

The registry is discovery-only. An explicit path or opened Xcode container is
authoritative after live validation. This program never writes Git state and
never creates a checkout, branch, or worktree.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any
from urllib.parse import urlsplit


CONTROL = re.compile(r"[\x00-\x1f\x7f]")
GITHUB_PATH = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
FINGERPRINT = re.compile(r"^sha256:[0-9a-f]{64}$")
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
CONTAINER_SUFFIXES = (".xcodeproj", ".xcworkspace")
RESOLVER_VERSION = "1.0.0"


def _invalid_text(value: object) -> bool:
    return not isinstance(value, str) or not value or CONTROL.search(value) is not None


def _valid_identifier(value: object) -> bool:
    return isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None


def _safe_absolute_path(value: object) -> Path:
    if _invalid_text(value):
        raise ValueError("unsafe_path")
    assert isinstance(value, str)
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("unsafe_path")
    return path


def normalize_github_remote(value: object) -> str:
    """Normalize supported GitHub SSH/HTTPS URLs without returning credentials."""
    if _invalid_text(value):
        raise ValueError("invalid_remote")
    assert isinstance(value, str)
    remote = value.strip()
    if remote != value or "?" in remote or "#" in remote:
        raise ValueError("invalid_remote")
    if remote.startswith("git@github.com:"):
        path = remote.removeprefix("git@github.com:")
    else:
        parsed = urlsplit(remote)
        if parsed.scheme not in {"https", "ssh"} or parsed.hostname != "github.com":
            raise ValueError("invalid_remote")
        try:
            port = parsed.port
        except ValueError as error:
            raise ValueError("invalid_remote") from error
        if (parsed.scheme == "https" and port not in {None, 443}) or (
                parsed.scheme == "ssh" and port not in {None, 22}):
            raise ValueError("invalid_remote")
        if parsed.query or parsed.fragment or parsed.password is not None:
            raise ValueError("invalid_remote")
        if parsed.scheme == "https" and parsed.username is not None:
            raise ValueError("invalid_remote")
        if parsed.scheme == "ssh" and parsed.username not in {None, "git"}:
            raise ValueError("invalid_remote")
        path = parsed.path.lstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    if not GITHUB_PATH.fullmatch(path):
        raise ValueError("invalid_remote")
    return f"github.com/{path.lower()}"


def remote_fingerprint(value: object) -> str:
    return "sha256:" + hashlib.sha256(
        normalize_github_remote(value).encode("utf-8")
    ).hexdigest()


def _run_git(root: Path, *arguments: str) -> str:
    try:
        completed = subprocess.run(
            ["git", "-C", os.fspath(root), *arguments],
            check=False, capture_output=True, text=True, timeout=5,
        )
    except FileNotFoundError as error:
        raise ValueError("git_unavailable") from error
    except subprocess.TimeoutExpired as error:
        raise ValueError("git_timeout") from error
    except OSError as error:
        raise ValueError("git_execution_failed") from error
    if completed.returncode != 0:
        raise ValueError("not_git_root")
    return completed.stdout.strip()


def _git_metadata_path(root: Path, argument: str) -> Path:
    value = Path(_run_git(root, "rev-parse", argument))
    return value if value.is_absolute() else root / value


def _is_within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
    except ValueError:
        return False
    return True


def _container_relative(root: Path, value: object) -> str:
    if _invalid_text(value):
        raise ValueError("invalid_xcode_container")
    assert isinstance(value, str)
    relative = PurePosixPath(value)
    if (relative.is_absolute() or ".." in relative.parts or str(relative) != value
            or not value.endswith(CONTAINER_SUFFIXES)):
        raise ValueError("invalid_xcode_container")
    candidate = root.joinpath(*relative.parts)
    if candidate.is_symlink():
        raise ValueError("invalid_xcode_container")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ValueError("missing_xcode_container") from error
    if not resolved.is_dir() or not _is_within(resolved, root):
        raise ValueError("invalid_xcode_container")
    return relative.as_posix()


def validate_project_root(path_value: object, *, containers: object = None) -> dict[str, Any]:
    """Validate exact Git top level and optional registry-listed containers."""
    path = _safe_absolute_path(path_value)
    if path.is_symlink():
        raise ValueError("unsafe_path")
    try:
        root = path.resolve(strict=True)
    except OSError as error:
        raise ValueError("missing_path") from error
    if not root.is_dir():
        raise ValueError("unsafe_path")
    try:
        git_root = Path(_run_git(root, "rev-parse", "--show-toplevel")).resolve(strict=True)
    except OSError as error:
        raise ValueError("not_git_root") from error
    if git_root != root:
        raise ValueError("not_git_root")
    fingerprint = remote_fingerprint(_run_git(root, "config", "--get", "remote.origin.url"))
    try:
        git_dir = _git_metadata_path(root, "--git-dir").resolve(strict=True)
        common_dir = _git_metadata_path(root, "--git-common-dir").resolve(strict=True)
    except OSError as error:
        raise ValueError("not_git_root") from error
    if containers is None:
        checked_containers: list[str] = []
    elif not isinstance(containers, list) or any(not isinstance(item, str) for item in containers):
        raise ValueError("invalid_xcode_container")
    else:
        checked_containers = [_container_relative(root, item) for item in containers]
        if len(checked_containers) != len(set(checked_containers)):
            raise ValueError("invalid_xcode_container")
        checked_containers.sort()
    return {
        "canonical_root": os.fspath(root),
        "remote_fingerprint": fingerprint,
        "kind": "worktree" if git_dir != common_dir else "primary",
        "xcode_containers": checked_containers,
    }


def _opened_container(path_value: object) -> tuple[dict[str, Any], str]:
    path = _safe_absolute_path(path_value)
    if path.is_symlink() or not os.fspath(path).endswith(CONTAINER_SUFFIXES):
        raise ValueError("invalid_opened_xcode_container")
    try:
        container = path.resolve(strict=True)
    except OSError as error:
        raise ValueError("invalid_opened_xcode_container") from error
    if not container.is_dir():
        raise ValueError("invalid_opened_xcode_container")
    try:
        root = Path(_run_git(container, "rev-parse", "--show-toplevel")).resolve(strict=True)
    except OSError as error:
        raise ValueError("invalid_opened_xcode_container") from error
    facts = validate_project_root(os.fspath(root))
    if not _is_within(container, Path(facts["canonical_root"])):
        raise ValueError("invalid_opened_xcode_container")
    return facts, container.relative_to(facts["canonical_root"]).as_posix()


def _registry_projects(registry: object, developer_id: str, host_id: str) -> list[dict[str, Any]]:
    if not isinstance(registry, dict):
        raise ValueError("invalid_registry")
    if set(registry) - {"$schema", "schema_version", "developer_id", "host_id", "projects"}:
        raise ValueError("invalid_registry")
    if registry.get("developer_id") != developer_id or registry.get("host_id") != host_id:
        return []
    if registry.get("schema_version") != "1.0.0" or not isinstance(registry.get("projects"), list) or not registry["projects"]:
        raise ValueError("invalid_registry")
    projects = registry["projects"]
    if any(not isinstance(project, dict) for project in projects):
        raise ValueError("invalid_registry")
    return projects


def _checked_project(project: dict[str, Any]) -> tuple[str, str, list[dict[str, Any]]]:
    identifier, fingerprint, checkouts = (
        project.get("project_id"), project.get("remote_fingerprint"), project.get("checkouts")
    )
    if set(project) != {"project_id", "remote_fingerprint", "checkouts"}:
        raise ValueError("invalid_registry")
    if not _valid_identifier(identifier) or not isinstance(fingerprint, str) or FINGERPRINT.fullmatch(fingerprint) is None:
        raise ValueError("invalid_registry")
    if not isinstance(checkouts, list) or not checkouts or any(not isinstance(item, dict) for item in checkouts):
        raise ValueError("invalid_registry")
    return identifier, fingerprint, checkouts


def _candidate(project_id: str, expected_fingerprint: str, checkout: dict[str, Any],
               *, allow_worktree: bool) -> dict[str, Any] | None:
    checkout_id, kind = checkout.get("checkout_id"), checkout.get("kind")
    if set(checkout) != {"checkout_id", "path", "kind", "xcode_containers"}:
        raise ValueError("invalid_registry")
    if not _valid_identifier(checkout_id) or kind not in {"primary", "worktree"}:
        raise ValueError("invalid_registry")
    facts = validate_project_root(checkout.get("path"), containers=checkout.get("xcode_containers"))
    if facts["remote_fingerprint"] != expected_fingerprint:
        raise ValueError("remote_fingerprint_mismatch")
    if facts["kind"] == "worktree" and not allow_worktree:
        raise ValueError("worktree_not_authorized")
    if kind != facts["kind"]:
        raise ValueError("checkout_kind_mismatch")
    return {"project_id": project_id, "checkout_id": checkout_id, **facts}


def _validate_project_integrity(projects: list[dict[str, Any]]) -> None:
    project_ids: set[str] = set()
    fingerprints: set[str] = set()
    for project in projects:
        project_id, fingerprint, checkouts = _checked_project(project)
        normalized_project_id = project_id.casefold()
        if normalized_project_id in project_ids or fingerprint in fingerprints:
            raise ValueError("duplicate_registry_identity")
        project_ids.add(normalized_project_id)
        fingerprints.add(fingerprint)
        checkout_ids: set[str] = set()
        for checkout in checkouts:
            checkout_id = checkout.get("checkout_id")
            normalized_checkout_id = checkout_id.casefold() if isinstance(checkout_id, str) else ""
            if not _valid_identifier(checkout_id) or normalized_checkout_id in checkout_ids:
                raise ValueError("duplicate_checkout_id")
            checkout_ids.add(normalized_checkout_id)


def resolve_project(registry: object | None, *, developer_id: str | None = None,
                    host_id: str | None = None,
                    explicit_path: str | None = None, project_id: str | None = None,
                    opened_xcode_container: str | None = None,
                    allow_worktree: bool = False) -> dict[str, Any]:
    """Resolve exactly one candidate or return a deterministic non-success state."""
    explicit_facts: dict[str, Any] | None = None
    opened_facts: dict[str, Any] | None = None
    opened_relative: str | None = None
    try:
        if explicit_path is not None:
            explicit_facts = validate_project_root(explicit_path)
        if opened_xcode_container is not None:
            opened_facts, opened_relative = _opened_container(opened_xcode_container)
    except ValueError as error:
        return {"status": "blocked", "reason_code": str(error)}
    if explicit_facts is not None and opened_facts is not None and explicit_facts["canonical_root"] != opened_facts["canonical_root"]:
        return {"status": "blocked", "reason_code": "opened_xcode_conflicts_explicit_path"}

    authoritative = opened_facts or explicit_facts
    if authoritative is not None:
        if authoritative["kind"] == "worktree" and not allow_worktree:
            return {"status": "unavailable", "reason_code": "worktree_not_authorized"}
        candidate = dict(authoritative)
        if opened_relative is not None:
            candidate["xcode_containers"] = [opened_relative]
        return {
            "status": "resolved",
            "reason_code": "opened_xcode_container" if opened_facts is not None else "explicit_path",
            "candidate": candidate,
        }

    if registry is None:
        return {"status": "unavailable", "reason_code": "registry_not_configured"}
    if (not _valid_identifier(developer_id) or not _valid_identifier(host_id)
            or (project_id is not None and not _valid_identifier(project_id))):
        return {"status": "blocked", "reason_code": "invalid_selector"}
    try:
        assert isinstance(developer_id, str) and isinstance(host_id, str)
        projects = _registry_projects(registry, developer_id, host_id)
        _validate_project_integrity(projects)
    except ValueError as error:
        return {"status": "blocked", "reason_code": str(error)}
    if not projects:
        return {"status": "unavailable", "reason_code": "no_matching_profile"}
    try:
        candidates: list[dict[str, Any]] = []
        warnings: list[dict[str, str]] = []
        skipped_worktree = False
        for project in projects:
            identifier, fingerprint, checkouts = _checked_project(project)
            if project_id is not None and identifier != project_id:
                continue
            for checkout in checkouts:
                try:
                    candidate = _candidate(identifier, fingerprint, checkout, allow_worktree=allow_worktree)
                except ValueError as error:
                    reason = str(error)
                    if reason == "worktree_not_authorized":
                        skipped_worktree = True
                        continue
                    if reason in {
                        "missing_path", "not_git_root", "missing_xcode_container",
                        "remote_fingerprint_mismatch",
                    }:
                        warnings.append({
                            "project_id": identifier,
                            "checkout_id": str(checkout.get("checkout_id", "")),
                            "reason_code": reason,
                        })
                        continue
                    raise
                if candidate is not None:
                    candidates.append(candidate)
    except ValueError as error:
        return {"status": "blocked", "reason_code": str(error)}
    if not candidates and warnings:
        return {
            "status": "blocked", "reason_code": "no_valid_candidates",
            "warnings": sorted(warnings, key=lambda item: (item["project_id"], item["checkout_id"], item["reason_code"])),
        }
    if not candidates and skipped_worktree:
        return {"status": "unavailable", "reason_code": "worktree_not_authorized"}
    if not candidates:
        return {"status": "unavailable", "reason_code": "no_matching_candidates"}
    roots: dict[str, dict[str, Any]] = {}
    for candidate in candidates:
        previous = roots.get(candidate["canonical_root"])
        if previous is not None and (previous["project_id"], previous["checkout_id"]) != (candidate["project_id"], candidate["checkout_id"]):
            return {"status": "blocked", "reason_code": "duplicate_canonical_root"}
        roots[candidate["canonical_root"]] = candidate
    candidates = sorted(roots.values(), key=lambda item: (item["project_id"], item["checkout_id"], item["canonical_root"]))
    if len(candidates) == 1:
        result: dict[str, Any] = {"status": "resolved", "reason_code": "registry_candidate", "candidate": candidates[0]}
    else:
        result = {"status": "needs_selection", "reason_code": "multiple_candidates", "candidates": candidates}
    if warnings:
        result["warnings"] = sorted(
            warnings, key=lambda item: (item["project_id"], item["checkout_id"], item["reason_code"])
        )
    return result


def _load_registry(path: str | None) -> object | None:
    if path is None:
        return None

    def object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON object key")
            result[key] = value
        return result

    try:
        registry = json.loads(
            Path(path).read_text(encoding="utf-8"),
            object_pairs_hook=object_without_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("invalid_registry") from error
    if not isinstance(registry, dict):
        raise ValueError("invalid_registry")
    return registry


def _fingerprint_result(path: str) -> dict[str, str]:
    try:
        facts = validate_project_root(path)
    except ValueError as error:
        return {"status": "blocked", "reason_code": str(error)}
    return {"status": "resolved", "reason_code": "fingerprinted", "remote_fingerprint": facts["remote_fingerprint"]}


def registry_sha256(registry: object) -> str:
    encoded = json.dumps(registry, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", help="private local project-registry JSON file")
    parser.add_argument("--developer-id")
    parser.add_argument("--host-id")
    parser.add_argument("--project-id")
    parser.add_argument("--explicit-path")
    parser.add_argument("--opened-xcode-container")
    parser.add_argument("--allow-worktree", action="store_true")
    parser.add_argument("--fingerprint-path", help="read-only remote fingerprint mode")
    args = parser.parse_args()
    if args.fingerprint_path is not None:
        if any((args.registry, args.developer_id, args.host_id, args.project_id, args.explicit_path, args.opened_xcode_container, args.allow_worktree)):
            parser.error("--fingerprint-path cannot be combined with resolution options")
        result: dict[str, Any] = _fingerprint_result(args.fingerprint_path)
    else:
        registry = None
        try:
            authoritative = args.explicit_path is not None or args.opened_xcode_container is not None
            if args.registry is not None and not authoritative:
                registry = _load_registry(args.registry)
            if registry is not None and (not args.developer_id or not args.host_id):
                parser.error("--developer-id and --host-id are required for registry discovery")
            result = resolve_project(
                registry, developer_id=args.developer_id, host_id=args.host_id,
                project_id=args.project_id, explicit_path=args.explicit_path,
                opened_xcode_container=args.opened_xcode_container,
                allow_worktree=args.allow_worktree,
            )
        except ValueError as error:
            result = {"status": "blocked", "reason_code": str(error)}
        if registry is not None:
            result["resolver_version"] = RESOLVER_VERSION
            result["registry_sha256"] = registry_sha256(registry)
            result["worktree_authorized"] = args.allow_worktree
            result.setdefault("warnings", [])
            result.setdefault("candidate", None)
    json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return {
        "resolved": 0,
        "blocked": 2,
        "needs_selection": 3,
        "unavailable": 4,
    }[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
