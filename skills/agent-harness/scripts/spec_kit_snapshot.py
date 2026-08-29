#!/usr/bin/env python3
"""Snapshot accepted Spec Kit artifacts and verify mutable run-log continuity."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
from typing import Any


PINNED_RELEASE = "v1.0.1"
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
FEATURE_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
REQUIRED_FEATURE_ARTIFACTS = ("spec.md", "plan.md", "tasks.md")
OPTIONAL_FEATURE_ARTIFACTS = ("research.md", "data-model.md", "quickstart.md")
FEATURE_ARTIFACT_DIRECTORIES = ("checklists", "contracts")
RUN_FILES = ("state.json", "inputs.json", "log.jsonl")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _require_regular_file(root: Path, path: Path, label: str) -> Path:
    if path.is_symlink():
        raise ValueError(f"{label} must not be a symbolic link")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"missing {label}: {path}") from error
    if not resolved.is_file():
        raise ValueError(f"{label} is not a regular file: {path}")
    if not _is_within(resolved, root):
        raise ValueError(f"{label} escaped the authoritative root")
    return resolved


def _normalize_feature_directory(value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("feature.json must contain a non-empty feature_directory string")
    if "\\" in value or "\x00" in value:
        raise ValueError("feature_directory contains an unsafe path character")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or len(parsed.parts) != 2 or parsed.parts[0] != "specs":
        raise ValueError("feature_directory must be exactly specs/<feature>")
    feature_id = parsed.parts[1]
    if FEATURE_COMPONENT.fullmatch(feature_id) is None:
        raise ValueError("feature_directory contains an unsafe feature identifier")
    canonical = f"specs/{feature_id}"
    if value != canonical:
        raise ValueError("feature_directory must use the canonical specs/<feature> form")
    return canonical


def _read_feature_pointer(root: Path) -> str:
    pointer = root / ".specify" / "feature.json"
    pointer = _require_regular_file(root, pointer, "Spec Kit feature pointer")
    try:
        document = json.loads(pointer.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("Spec Kit feature pointer is not valid UTF-8 JSON") from error
    if not isinstance(document, dict):
        raise ValueError("Spec Kit feature pointer must be a JSON object")
    return _normalize_feature_directory(document.get("feature_directory"))


def _resolve_feature_directory(
    root: Path, expected_feature_directory: str | None
) -> tuple[str, Path]:
    selected = _read_feature_pointer(root)
    if expected_feature_directory is not None:
        expected = _normalize_feature_directory(expected_feature_directory)
        if selected != expected:
            raise ValueError(
                "Spec Kit feature pointer is stale: "
                f"expected {expected!r}, found {selected!r}"
            )

    specs = root / "specs"
    if specs.is_symlink():
        raise ValueError("Spec Kit specs directory must not be a symbolic link")
    try:
        resolved_specs = specs.resolve(strict=True)
    except OSError as error:
        raise ValueError("missing Spec Kit specs directory") from error
    if not resolved_specs.is_dir() or resolved_specs.parent != root:
        raise ValueError("Spec Kit specs directory escaped the authoritative root")

    feature = root / selected
    if feature.is_symlink():
        raise ValueError("selected Spec Kit feature directory must not be a symbolic link")
    try:
        resolved_feature = feature.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"selected Spec Kit feature directory is missing: {selected}") from error
    if not resolved_feature.is_dir() or resolved_feature.parent != resolved_specs:
        raise ValueError("selected Spec Kit feature directory escaped specs/<feature>")
    return selected, resolved_feature


def _artifact_record(root: Path, path: Path, label: str) -> dict[str, Any]:
    resolved = _require_regular_file(root, path, label)
    data = resolved.read_bytes()
    return {
        "path": path.relative_to(root).as_posix(),
        "sha256": _sha256_bytes(data),
        "size": len(data),
    }


def _optional_path_exists(path: Path) -> bool:
    return path.exists() or path.is_symlink() or os.path.lexists(path)


def _accepted_artifacts(root: Path, feature: Path) -> list[dict[str, Any]]:
    paths: list[tuple[Path, str]] = []
    for name in REQUIRED_FEATURE_ARTIFACTS:
        paths.append((feature / name, f"selected feature artifact {name}"))

    constitution = root / ".specify" / "memory" / "constitution.md"
    if _optional_path_exists(constitution):
        paths.append((constitution, "Spec Kit constitution"))

    for name in OPTIONAL_FEATURE_ARTIFACTS:
        path = feature / name
        if _optional_path_exists(path):
            paths.append((path, f"selected feature artifact {name}"))

    for directory_name in FEATURE_ARTIFACT_DIRECTORIES:
        directory = feature / directory_name
        if not _optional_path_exists(directory):
            continue
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError(
                f"selected feature artifact directory {directory_name} is invalid"
            )
        for path in directory.rglob("*"):
            if path.is_symlink():
                raise ValueError("selected feature artifact tree contains a symbolic link")
            if path.is_file():
                paths.append((path, "selected feature artifact"))
            elif not path.is_dir():
                raise ValueError("selected feature artifact tree contains a non-file entry")

    records = [_artifact_record(root, path, label) for path, label in paths]
    return sorted(records, key=lambda item: item["path"].encode("utf-8"))


def _json_checkpoint_record(root: Path, path: Path, label: str) -> dict[str, Any]:
    record = _artifact_record(root, path, label)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(document, dict):
        raise ValueError(f"{label} must contain a JSON object")
    return record


def _log_checkpoint_record(root: Path, path: Path) -> dict[str, Any]:
    resolved = _require_regular_file(root, path, "Spec Kit workflow log")
    data = resolved.read_bytes()
    entries: list[str] = []
    for line_number, line in enumerate(data.splitlines(keepends=True), 1):
        payload = line.rstrip(b"\r\n")
        if not payload:
            raise ValueError(f"Spec Kit workflow log line {line_number} is empty")
        try:
            event = json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ValueError(
                f"Spec Kit workflow log line {line_number} is not valid JSON"
            ) from error
        if not isinstance(event, dict):
            raise ValueError(
                f"Spec Kit workflow log line {line_number} must contain a JSON object"
            )
        entries.append(_sha256_bytes(line))
    return {
        "path": path.relative_to(root).as_posix(),
        "sha256": _sha256_bytes(data),
        "size": len(data),
        "entry_sha256": entries,
        "line_count": len(entries),
        "ends_with_newline": not data or data.endswith((b"\n", b"\r")),
    }


def _workflow_checkpoint(root: Path, run_id: str) -> dict[str, Any]:
    if RUN_ID.fullmatch(run_id) is None:
        raise ValueError("run_id contains unsafe characters")
    runs = root / ".specify" / "workflows" / "runs"
    if runs.is_symlink():
        raise ValueError("Spec Kit workflow runs directory must not be a symbolic link")
    try:
        resolved_runs = runs.resolve(strict=True)
    except OSError as error:
        raise ValueError("missing Spec Kit workflow runs directory") from error
    if not resolved_runs.is_dir() or not _is_within(resolved_runs, root):
        raise ValueError("Spec Kit workflow runs directory escaped the authoritative root")

    run = runs / run_id
    if run.is_symlink():
        raise ValueError("selected Spec Kit workflow run must not be a symbolic link")
    try:
        resolved_run = run.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"selected Spec Kit workflow run is missing: {run_id}") from error
    if not resolved_run.is_dir() or resolved_run.parent != resolved_runs:
        raise ValueError("selected Spec Kit workflow run escaped the runs directory")

    state_path = run / RUN_FILES[0]
    inputs_path = run / RUN_FILES[1]
    log_path = run / RUN_FILES[2]
    state = _json_checkpoint_record(root, state_path, "Spec Kit workflow state")
    state_document = json.loads(state_path.read_text(encoding="utf-8"))
    if state_document.get("run_id") != run_id:
        raise ValueError("Spec Kit workflow state run_id does not match the selected run")
    if not isinstance(state_document.get("workflow_id"), str) or not state_document.get(
        "workflow_id"
    ):
        raise ValueError("Spec Kit workflow state is missing workflow_id")
    if state_document.get("status") not in {
        "created",
        "running",
        "completed",
        "paused",
        "failed",
        "aborted",
    }:
        raise ValueError("Spec Kit workflow state has an invalid status")
    inputs = _json_checkpoint_record(root, inputs_path, "Spec Kit workflow inputs")
    inputs_document = json.loads(inputs_path.read_text(encoding="utf-8"))
    if not isinstance(inputs_document.get("inputs"), dict):
        raise ValueError("Spec Kit workflow inputs must contain an inputs object")
    log = _log_checkpoint_record(root, log_path)
    return {"run_id": run_id, "state": state, "inputs": inputs, "log": log}


def build_snapshot(
    root: Path,
    release: str = PINNED_RELEASE,
    run_id: str | None = None,
    feature_directory: str | None = None,
    discovery: bool = False,
) -> dict[str, Any]:
    try:
        root = root.resolve(strict=True)
    except OSError as error:
        raise ValueError("authoritative root does not exist") from error
    if not root.is_dir():
        raise ValueError("authoritative root is not a directory")
    if release != PINNED_RELEASE:
        raise ValueError(f"Spec Kit release must be pinned to {PINNED_RELEASE}")
    if feature_directory is None and not discovery:
        raise ValueError(
            "approved feature_directory is required; use discovery mode only for read-only discovery"
        )
    if feature_directory is not None and discovery:
        raise ValueError("choose approved feature_directory or discovery mode, not both")

    selected, feature = _resolve_feature_directory(root, feature_directory)
    artifacts = _accepted_artifacts(root, feature)
    if _read_feature_pointer(root) != selected:
        raise ValueError("Spec Kit feature pointer changed while snapshotting")

    feature_id = PurePosixPath(selected).name
    immutable = {
        "schema_version": "1.0.0",
        "spec_kit_release": release,
        "feature_id": feature_id,
        "feature_directory": selected,
        "accepted_artifacts": artifacts,
    }
    encoded = json.dumps(immutable, sort_keys=True, separators=(",", ":")).encode()
    checkpoint = _workflow_checkpoint(root, run_id) if run_id is not None else None
    return {
        **immutable,
        "artifact_hashes": {item["path"]: item["sha256"] for item in artifacts},
        "snapshot_sha256": _sha256_bytes(encoded),
        "workflow_checkpoint": checkpoint,
    }


def verify_snapshot(expected: dict[str, Any], current: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if expected.get("spec_kit_release") != PINNED_RELEASE:
        errors.append("expected snapshot does not use the pinned Spec Kit release")
    if current.get("spec_kit_release") != expected.get("spec_kit_release"):
        errors.append("Spec Kit release changed")
    if current.get("feature_directory") != expected.get("feature_directory"):
        errors.append("Spec Kit feature_directory pointer changed or became stale")
    if current.get("feature_id") != expected.get("feature_id"):
        errors.append("Spec Kit feature identity changed")
    if current.get("accepted_artifacts") != expected.get("accepted_artifacts"):
        errors.append("accepted Spec Kit artifact set or content changed")
    if current.get("snapshot_sha256") != expected.get("snapshot_sha256"):
        errors.append("immutable Spec Kit snapshot hash changed")

    expected_checkpoint = expected.get("workflow_checkpoint")
    current_checkpoint = current.get("workflow_checkpoint")
    if (expected_checkpoint is None) != (current_checkpoint is None):
        errors.append("Spec Kit workflow checkpoint selection changed")
    elif isinstance(expected_checkpoint, dict) and isinstance(current_checkpoint, dict):
        if current_checkpoint.get("run_id") != expected_checkpoint.get("run_id"):
            errors.append("Spec Kit workflow run selection changed")
        expected_entries = expected_checkpoint.get("log", {}).get("entry_sha256", [])
        current_entries = current_checkpoint.get("log", {}).get("entry_sha256", [])
        if len(current_entries) < len(expected_entries):
            errors.append("Spec Kit workflow log was truncated")
        elif current_entries[: len(expected_entries)] != expected_entries:
            errors.append("Spec Kit workflow log was rewritten")

    return sorted(set(errors))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("--root", type=Path, required=True)
    snapshot.add_argument("--release", default=PINNED_RELEASE)
    snapshot.add_argument("--run-id")
    snapshot_selection = snapshot.add_mutually_exclusive_group(required=True)
    snapshot_selection.add_argument("--feature-directory")
    snapshot_selection.add_argument("--discovery", action="store_true")

    verify = commands.add_parser("verify")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--release", default=PINNED_RELEASE)
    verify.add_argument("--run-id")
    verify.add_argument("--feature-directory", required=True)
    verify.add_argument("--expected", type=Path, required=True)
    return root


def main() -> int:
    arguments = parser().parse_args()
    current = build_snapshot(
        arguments.root,
        release=arguments.release,
        run_id=arguments.run_id,
        feature_directory=arguments.feature_directory,
        discovery=getattr(arguments, "discovery", False),
    )
    if arguments.command == "snapshot":
        print(json.dumps(current, indent=2, sort_keys=True))
        return 0
    expected = json.loads(arguments.expected.read_text(encoding="utf-8"))
    errors = verify_snapshot(expected, current)
    print(
        json.dumps(
            {"current": current, "valid": not errors, "errors": errors},
            indent=2,
            sort_keys=True,
        )
    )
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
