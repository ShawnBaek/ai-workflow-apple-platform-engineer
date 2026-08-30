#!/usr/bin/env python3
"""A small, local, fail-closed coordinator for host-shared agent resources.

The coordinator deliberately has no default location and no background process.
Callers choose an existing, non-symlink parent directory and pass an absolute
state path.  The sibling ``.lock`` file is the only synchronization primitive.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from typing import Any, Iterator
import unicodedata
import uuid


SCHEMA_VERSION = 1
SOURCE_WRITER = "source_checkout_writer"
XCODE_PROJECT = "xcode_project_mutation"
BUILD_TUPLE = "build_tuple"
SIMULATOR = "simulator_or_device"
CORE_SIMULATOR = "coresimulator_runtime_registry"
MACOS_GUI = "macos_gui_session"
SIGNING = "signing_or_app_store_connect"
GITHUB = "github_external_mutation"
RESOURCES = {
    SOURCE_WRITER, XCODE_PROJECT, BUILD_TUPLE, SIMULATOR, CORE_SIMULATOR,
    MACOS_GUI, SIGNING, GITHUB,
}
CACHE_ROLES = {
    "derived_data", "source_packages", "repository_checkouts", "artifacts",
    "package_cache",
}
OUTPUT_ROLES = {
    "result_bundle", "result_stream", "archive", "export", "diagnostic_bundle",
}
PACKAGE_RESOLUTION_MODES = {"none", "swiftpm_lockfile", "xcode_project_packages"}
MAX_TTL_SECONDS = 3600
FINGERPRINT = re.compile(r"(?:sha256:)?[0-9a-f]{64}$")
RECEIPT_FIELDS = {
    "coordinator_instance_id", "receipt_id", "lease_id", "owner_run_id",
    "owner_actor", "resource", "resource_key", "descriptor_sha256",
    "fencing_token", "acquired_at", "expires_at",
}
RELEASE_CONFIRMATION_FIELDS = {
    "coordinator_instance_id", "release_id", "receipt_id", "lease_id",
    "fencing_token", "released_at",
}
BUNDLE_SUFFIXES = {".json", ".py"}
RUN_AUTHORITY_FIELDS = {
    "authorization_hash",
    "selected_writer",
    "harness_sha256",
    "authorization_issued_at",
    "authorization_expires_at",
    "ledger_path",
    "ledger_identity_sha256",
    "ledger_approval_sha256",
}


class CoordinatorError(ValueError):
    """Stable, machine-readable error for a refused coordinator operation."""

    def __init__(self, code: str, detail: str = "") -> None:
        self.code = code
        super().__init__(code if not detail else f"{code}: {detail}")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_stamp(value: Any) -> datetime:
    if not isinstance(value, str):
        raise CoordinatorError("invalid_state", "timestamp is not a string")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError as error:
        raise CoordinatorError("invalid_state", "invalid timestamp") from error


def _aware_now(value: datetime | None) -> datetime:
    current = value or _utc_now()
    if current.tzinfo is None or current.utcoffset() is None:
        raise CoordinatorError("invalid_time", "timezone-aware UTC-compatible time required")
    return current.astimezone(timezone.utc)


def _state_path(value: str | os.PathLike[str]) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise CoordinatorError("invalid_state_path", "an absolute state path is required")
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink():
        raise CoordinatorError("invalid_state_path", "parent must exist and must not be a symlink")
    if path.exists():
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
            raise CoordinatorError("invalid_state_path", "state file must be a regular non-symlink")
    return path


def _json(value: Any) -> str:
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    except (TypeError, ValueError) as error:
        raise CoordinatorError("invalid_descriptor", "not JSON serializable") from error


def _descriptor_hash(value: dict[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(_json(value).encode("utf-8")).hexdigest()


def ledger_binding(
    value: str | os.PathLike[str],
    *,
    descriptor: int | None = None,
    expected_run_id: str | None = None,
    expected_authorization_hash: str | None = None,
) -> dict[str, str]:
    """Bind one canonical ledger pathname to its live inode and first approval.

    When ``descriptor`` is supplied, the pathname must still name that exact
    open file.  This lets callers detect rename/replacement races without ever
    reopening the ledger for reads or tail checks.
    """
    path = Path(value)
    if not path.is_absolute() or path.is_symlink():
        raise CoordinatorError("untrusted_ledger", "ledger path is unsafe")
    opened_here = descriptor is None
    fd = descriptor
    if opened_here:
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError as error:
            raise CoordinatorError("untrusted_ledger", "ledger cannot be opened") from error
    assert fd is not None
    try:
        opened = os.fstat(fd)
        try:
            named = os.stat(path, follow_symlinks=False)
            canonical = path.resolve(strict=True)
        except OSError as error:
            raise CoordinatorError("untrusted_ledger", "ledger pathname is unavailable") from error
        if (
            not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(named.st_mode)
            or opened.st_nlink != 1
            or named.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
        ):
            raise CoordinatorError("untrusted_ledger", "ledger inode drifted")
        prefix = os.pread(fd, 1024 * 1024, 0)
        first_line = prefix.splitlines()[0] if prefix.splitlines() else b""
        if not first_line or (b"\n" not in prefix and opened.st_size > len(prefix)):
            raise CoordinatorError("untrusted_ledger", "ledger approval record is unavailable")
        try:
            approval = json.loads(first_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CoordinatorError("untrusted_ledger", "ledger approval record is invalid") from error
        payload = approval.get("payload") if isinstance(approval, dict) else None
        if (
            not isinstance(payload, dict)
            or approval.get("record_type") != "approval"
            or approval.get("sequence") != 1
            or payload.get("kind") != "run_authorization"
            or payload.get("decision") != "approved"
            or (
                expected_run_id is not None
                and approval.get("run_id") != expected_run_id
            )
            or (
                expected_authorization_hash is not None
                and payload.get("authorization_hash")
                != expected_authorization_hash
            )
        ):
            raise CoordinatorError("untrusted_ledger", "ledger approval binding drifted")
        identity = {
            "path": os.fspath(canonical),
            "device": opened.st_dev,
            "inode": opened.st_ino,
        }
        return {
            "ledger_path": os.fspath(canonical),
            "ledger_identity_sha256": _descriptor_hash(identity),
            "ledger_approval_sha256": _descriptor_hash(approval),
        }
    finally:
        if opened_here:
            os.close(fd)


def descriptor_sha256(resource: str, descriptor: dict[str, Any]) -> str:
    """Return the digest of the validated canonical descriptor."""
    return _descriptor_hash(normalize_descriptor(resource, descriptor))


def recovery_evidence_sha256(evidence: dict[str, Any]) -> str:
    """Canonical digest for binding recovery evidence into a ledger record."""
    if not isinstance(evidence, dict):
        raise CoordinatorError("invalid_recovery_evidence")
    return "sha256:" + hashlib.sha256(_json(_safe_json(evidence)).encode("utf-8")).hexdigest()


def canonical_resource_key(resource: str, descriptor: dict[str, Any]) -> str:
    """Stable key for evidence binding; conflict detection remains descriptor-aware."""
    return f"{resource}:{descriptor_sha256(resource, descriptor)}"


def contract_bundle_sha256(skill_root: str | os.PathLike[str] | None = None) -> str:
    """Digest every executable and JSON contract in one installed skill copy."""
    root = (
        Path(skill_root).resolve(strict=True)
        if skill_root is not None
        else Path(__file__).resolve().parents[1]
    )
    candidates = [
        path
        for directory in (root / "scripts", root / "contracts")
        for path in directory.rglob("*")
        if path.is_file() and not path.is_symlink() and path.suffix in BUNDLE_SUFFIXES
    ]
    if not candidates:
        raise CoordinatorError("untrusted_binding", "installed contract bundle is empty")
    digest = hashlib.sha256()
    for path in sorted(candidates, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return "sha256:" + digest.hexdigest()


def _safe_json(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
            raise CoordinatorError("invalid_descriptor", "non-finite number")
        if isinstance(value, str) and (not value or "\x00" in value):
            raise CoordinatorError("invalid_descriptor", "empty or NUL string")
        return value
    if isinstance(value, list):
        return [_safe_json(item) for item in value]
    if isinstance(value, dict) and all(isinstance(key, str) and key for key in value):
        return {key: _safe_json(value[key]) for key in sorted(value)}
    raise CoordinatorError("invalid_descriptor", "unsupported descriptor value")


def _safe_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise CoordinatorError("invalid_descriptor", f"unsafe {field}")
    return value


def _absolute_path(value: Any, field: str) -> str:
    path = Path(_safe_string(value, field))
    if not path.is_absolute():
        raise CoordinatorError("invalid_descriptor", f"{field} must be absolute")
    return os.fspath(path.resolve(strict=False))


def _fingerprint(value: Any) -> str:
    fingerprint = _safe_string(value, "repository_fingerprint").lower()
    if FINGERPRINT.fullmatch(fingerprint) is None:
        raise CoordinatorError("invalid_descriptor", "unsafe repository fingerprint")
    return fingerprint if fingerprint.startswith("sha256:") else "sha256:" + fingerprint


def _github_repository(value: Any) -> str:
    repository = _safe_string(value, "remote_repository").strip().lower()
    if repository.endswith(".git"):
        repository = repository[:-4]
    if re.fullmatch(
        r"[a-z0-9](?:[a-z0-9.-]{0,99})/[a-z0-9](?:[a-z0-9._-]{0,99})",
        repository,
    ) is None:
        raise CoordinatorError(
            "invalid_descriptor", "remote_repository must be canonical owner/repository"
        )
    return repository


def normalize_descriptor(resource: str, descriptor: dict[str, Any]) -> dict[str, Any]:
    """Validate and canonicalize a structured resource descriptor.

    Device and CoreSimulator claims must bind the coordinator instance returned
    by `status`; a caller-controlled registry host label is never accepted as
    the host boundary.
    """
    if resource not in RESOURCES:
        raise CoordinatorError("invalid_resource")
    if not isinstance(descriptor, dict):
        raise CoordinatorError("invalid_descriptor", "descriptor must be an object")
    if resource == SOURCE_WRITER:
        if set(descriptor) != {"identity_version", "repository_fingerprint"} or descriptor["identity_version"] != "github_remote_v2":
            raise CoordinatorError("invalid_descriptor", "source writer requires github_remote_v2 identity")
        return {"identity_version": "github_remote_v2", "repository_fingerprint": _fingerprint(descriptor["repository_fingerprint"])}
    if resource == XCODE_PROJECT:
        if set(descriptor) != {"repository_fingerprint", "container_path"}:
            raise CoordinatorError("invalid_descriptor", "Xcode mutation requires exact container identity")
        return {"repository_fingerprint": _fingerprint(descriptor["repository_fingerprint"]), "container_path": _absolute_path(descriptor["container_path"], "container_path")}
    if resource == BUILD_TUPLE:
        fields = {
            "repository_fingerprint", "container_path", "xcode_build", "sdk",
            "scheme", "configuration", "architecture", "package_fingerprint",
            "cache_paths", "cache_roles", "output_paths", "output_roles",
            "package_resolution_mode",
        }
        if (
            set(descriptor) != fields
            or not isinstance(descriptor["cache_paths"], list)
            or not isinstance(descriptor["cache_roles"], dict)
            or set(descriptor["cache_roles"]) != CACHE_ROLES
            or not isinstance(descriptor["output_paths"], list)
            or not isinstance(descriptor["output_roles"], dict)
            or not set(descriptor["output_roles"]).issubset(OUTPUT_ROLES)
            or descriptor["package_resolution_mode"] not in PACKAGE_RESOLUTION_MODES
        ):
            raise CoordinatorError("invalid_descriptor", "build tuple requires all identity fields")
        paths = sorted({_absolute_path(value, "cache_path") for value in descriptor["cache_paths"]})
        if not paths or len(paths) != len(descriptor["cache_paths"]):
            raise CoordinatorError("invalid_descriptor", "cache paths must be nonempty and unique")
        cache_roles = {
            role: _absolute_path(descriptor["cache_roles"][role], role)
            for role in sorted(CACHE_ROLES)
        }
        if (
            len(set(cache_roles.values())) != len(CACHE_ROLES)
            or set(paths) != set(cache_roles.values())
        ):
            raise CoordinatorError(
                "invalid_descriptor",
                "cache roles must use unique paths and cache_paths must contain every role",
            )
        output_paths = sorted(
            {_absolute_path(value, "output_path") for value in descriptor["output_paths"]}
        )
        if len(output_paths) != len(descriptor["output_paths"]):
            raise CoordinatorError("invalid_descriptor", "output paths must be unique")
        output_roles = {
            role: _absolute_path(descriptor["output_roles"][role], role)
            for role in sorted(descriptor["output_roles"])
        }
        if len(set(output_roles.values())) != len(output_roles) or set(output_paths) != set(
            output_roles.values()
        ):
            raise CoordinatorError(
                "invalid_descriptor",
                "output_paths must contain every exact unique output role path",
            )
        result = {
            field: _safe_string(descriptor[field], field)
            for field in fields
            - {
                "repository_fingerprint", "container_path", "cache_paths",
                "cache_roles", "output_paths", "output_roles",
            }
        }
        result.update({
            "repository_fingerprint": _fingerprint(descriptor["repository_fingerprint"]),
            "container_path": _absolute_path(descriptor["container_path"], "container_path"),
            "cache_paths": paths,
            "cache_roles": cache_roles,
            "output_paths": output_paths,
            "output_roles": output_roles,
        })
        return {field: result[field] for field in sorted(result)}
    if resource == SIMULATOR:
        if set(descriptor) != {"udids", "coordinator_instance_id"}:
            raise CoordinatorError("invalid_descriptor", "device claim requires coordinator_instance_id and udids")
        instance = _safe_string(descriptor["coordinator_instance_id"], "coordinator_instance_id")
        udids = descriptor["udids"]
        if not isinstance(udids, list):
            raise CoordinatorError("invalid_descriptor", "udids must be a list")
        normalized = sorted({item.strip().lower() for item in udids if isinstance(item, str) and item.strip()})
        if len(normalized) != len(udids) or not normalized:
            raise CoordinatorError("invalid_descriptor", "UDIDs must be nonempty, unique strings")
        if any(not re.fullmatch(r"[a-z0-9-]{4,128}", item) for item in normalized):
            raise CoordinatorError("invalid_descriptor", "unsafe UDID")
        return {"coordinator_instance_id": instance, "udids": normalized}
    if resource == CORE_SIMULATOR:
        if set(descriptor) != {"coordinator_instance_id", "registry_scope"}:
            raise CoordinatorError("invalid_descriptor", "CoreSimulator registry requires exact scope")
        return {
            "coordinator_instance_id": _safe_string(
                descriptor["coordinator_instance_id"], "coordinator_instance_id"
            ),
            "registry_scope": _safe_string(descriptor["registry_scope"], "registry_scope"),
        }
    if resource == MACOS_GUI:
        if set(descriptor) != {"coordinator_instance_id", "session_scope"}:
            raise CoordinatorError(
                "invalid_descriptor", "macOS GUI claim requires exact host session identity"
            )
        if descriptor["session_scope"] != "foreground_ui":
            raise CoordinatorError(
                "invalid_descriptor", "macOS GUI session_scope must be foreground_ui"
            )
        return {
            "coordinator_instance_id": _safe_string(
                descriptor["coordinator_instance_id"], "coordinator_instance_id"
            ),
            "session_scope": "foreground_ui",
        }
    if resource == SIGNING:
        if set(descriptor) != {"account_guard", "app_or_bundle_scope"}:
            raise CoordinatorError("invalid_descriptor", "signing requires exact account/app scope")
        return {field: _safe_string(descriptor[field], field) for field in sorted(descriptor)}
    if resource == GITHUB:
        if set(descriptor) != {"repository_fingerprint", "remote_repository"}:
            raise CoordinatorError("invalid_descriptor", "GitHub mutation requires exact remote identity")
        return {"repository_fingerprint": _fingerprint(descriptor["repository_fingerprint"]), "remote_repository": _github_repository(descriptor["remote_repository"])}
    raise CoordinatorError("invalid_resource")


def descriptors_conflict(
    resource: str, descriptor: dict[str, Any], other_resource: str, other: dict[str, Any]
) -> bool:
    if resource == CORE_SIMULATOR and other_resource in {CORE_SIMULATOR, SIMULATOR}:
        return True
    if other_resource == CORE_SIMULATOR and resource == SIMULATOR:
        return True
    if {resource, other_resource} in (
        {SOURCE_WRITER, XCODE_PROJECT},
        {SOURCE_WRITER, BUILD_TUPLE},
        {XCODE_PROJECT, BUILD_TUPLE},
    ):
        return (
            descriptor["repository_fingerprint"]
            == other["repository_fingerprint"]
        )
    if resource != other_resource:
        return False
    if resource == SOURCE_WRITER:
        return descriptor["repository_fingerprint"] == other["repository_fingerprint"]
    if resource == SIMULATOR:
        return bool(set(descriptor["udids"]) & set(other["udids"]))
    if resource == BUILD_TUPLE:
        if (
            descriptor["repository_fingerprint"]
            == other["repository_fingerprint"]
        ):
            return True
        left_paths = descriptor["cache_paths"] + descriptor["output_paths"]
        right_paths = other["cache_paths"] + other["output_paths"]
        return any(_related(left, right) for left in left_paths for right in right_paths)
    if resource == XCODE_PROJECT:
        return (
            descriptor["repository_fingerprint"] == other["repository_fingerprint"]
            or descriptor["container_path"] == other["container_path"]
        )
    if resource == MACOS_GUI:
        return (
            descriptor["coordinator_instance_id"]
            == other["coordinator_instance_id"]
        )
    if resource == GITHUB:
        return (
            descriptor["repository_fingerprint"] == other["repository_fingerprint"]
            or descriptor["remote_repository"] == other["remote_repository"]
        )
    return descriptor == other


def same_owner_nested_compatible(
    resource: str,
    other_resource: str,
    owner_run_id: str,
    owner_actor: str,
    other_owner_run_id: str,
    other_owner_actor: str,
    descriptor: dict[str, Any] | None = None,
    other_descriptor: dict[str, Any] | None = None,
) -> bool:
    """Allow only the documented same-run composite lease shapes."""
    if owner_run_id != other_owner_run_id or owner_actor != other_owner_actor:
        return False
    if resource in {XCODE_PROJECT, BUILD_TUPLE} and other_resource == SOURCE_WRITER:
        return True
    if resource != BUILD_TUPLE or other_resource != XCODE_PROJECT:
        return False
    build = descriptor
    project = other_descriptor
    return bool(
        isinstance(build, dict)
        and isinstance(project, dict)
        and build.get("package_resolution_mode") == "xcode_project_packages"
        and build.get("repository_fingerprint") == project.get("repository_fingerprint")
        and build.get("container_path") == project.get("container_path")
    )


def _resolution_support_present(
    build: dict[str, Any], active_leases: list[dict[str, Any]]
) -> bool:
    descriptor = build["descriptor"]
    mode = descriptor.get("package_resolution_mode")
    source_present = any(
        lease["resource"] == SOURCE_WRITER
        and lease["owner_run_id"] == build["owner_run_id"]
        and lease["owner_actor"] == build["owner_actor"]
        and lease["descriptor"]["repository_fingerprint"]
        == descriptor["repository_fingerprint"]
        for lease in active_leases
    )
    if not source_present:
        return False
    if mode != "xcode_project_packages":
        return True
    return any(
        lease["resource"] == XCODE_PROJECT
        and lease["owner_run_id"] == build["owner_run_id"]
        and lease["owner_actor"] == build["owner_actor"]
        and lease["descriptor"]["repository_fingerprint"]
        == descriptor["repository_fingerprint"]
        and lease["descriptor"]["container_path"] == descriptor["container_path"]
        for lease in active_leases
    )


def _supports_active_resolution(
    candidate: dict[str, Any], active_leases: list[dict[str, Any]]
) -> bool:
    for build in active_leases:
        if build["resource"] != BUILD_TUPLE or build["lease_id"] == candidate["lease_id"]:
            continue
        descriptor = build["descriptor"]
        same_owner = (
            candidate["owner_run_id"] == build["owner_run_id"]
            and candidate["owner_actor"] == build["owner_actor"]
        )
        same_repository = candidate["descriptor"].get("repository_fingerprint") == descriptor.get(
            "repository_fingerprint"
        )
        if candidate["resource"] == SOURCE_WRITER and same_owner and same_repository:
            return True
        if (
            candidate["resource"] == XCODE_PROJECT
            and descriptor.get("package_resolution_mode") == "xcode_project_packages"
            and same_owner
            and same_repository
            and candidate["descriptor"].get("container_path")
            == descriptor.get("container_path")
        ):
            return True
    return False


def _related(left: str, right: str) -> bool:
    try:
        if os.path.exists(left) and os.path.exists(right) and os.path.samefile(left, right):
            return True
    except OSError:
        pass

    def comparable(value: str) -> Path:
        normalized = unicodedata.normalize("NFC", value).casefold()
        return Path(normalized)

    left_path = comparable(left)
    right_path = comparable(right)
    try:
        left_path.relative_to(right_path)
        return True
    except ValueError:
        try:
            right_path.relative_to(left_path)
            return True
        except ValueError:
            return False


def _blank_state() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "coordinator_instance_id": str(uuid.uuid4()),
        "migration_bootstrap": None,
        "next_fencing_token": 0,
        "run_authorities": {},
        "leases": {},
    }


def _load(path: Path) -> dict[str, Any]:
    if not path.exists():
        return _blank_state()
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise CoordinatorError("invalid_state", "state is not a regular file")
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise CoordinatorError("invalid_state", "cannot read state") from error
    required = {
        "schema_version", "coordinator_instance_id", "migration_bootstrap",
        "next_fencing_token", "run_authorities", "leases",
    }
    if not isinstance(data, dict) or set(data) != required or data["schema_version"] != SCHEMA_VERSION:
        raise CoordinatorError("invalid_state", "unknown state schema")
    if (not isinstance(data["coordinator_instance_id"], str) or not data["coordinator_instance_id"]
            or not isinstance(data["next_fencing_token"], int) or data["next_fencing_token"] < 0
            or not isinstance(data["run_authorities"], dict)
            or not isinstance(data["leases"], dict)):
        raise CoordinatorError("invalid_state", "invalid state fields")
    for authority_run_id, authority in data["run_authorities"].items():
        if (
            not isinstance(authority_run_id, str)
            or not authority_run_id
            or not isinstance(authority, dict)
            or set(authority) != RUN_AUTHORITY_FIELDS
            or not _sha256(authority.get("authorization_hash"))
            or authority.get("selected_writer") not in {"codex", "claude"}
            or not _sha256(authority.get("harness_sha256"))
            or not isinstance(authority.get("ledger_path"), str)
            or not Path(authority["ledger_path"]).is_absolute()
            or not _sha256(authority.get("ledger_identity_sha256"))
            or not _sha256(authority.get("ledger_approval_sha256"))
        ):
            raise CoordinatorError("invalid_state", "invalid run authority")
        issued_at = _parse_stamp(authority["authorization_issued_at"])
        expires_at = _parse_stamp(authority["authorization_expires_at"])
        if expires_at <= issued_at:
            raise CoordinatorError("invalid_state", "invalid run authority time range")
    bootstrap = data["migration_bootstrap"]
    if bootstrap is not None and (not isinstance(bootstrap, dict) or set(bootstrap) != {"legacy_leases_quiesced", "confirmed_at"} or bootstrap["legacy_leases_quiesced"] is not True):
        raise CoordinatorError("invalid_state", "invalid bootstrap")
    if bootstrap is not None:
        _parse_stamp(bootstrap["confirmed_at"])
    highest_fence = 0
    receipt_ids: set[str] = set()
    fencing_tokens: set[int] = set()
    recovery_ids: set[str] = set()
    active_leases: list[dict[str, Any]] = []
    replacement_links: list[tuple[dict[str, Any], str | None]] = []
    for lease_id, lease in data["leases"].items():
        if not isinstance(lease_id, str) or not isinstance(lease, dict):
            raise CoordinatorError("invalid_state", "invalid lease record")
        required_lease = {"receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource", "descriptor", "descriptor_sha256", "fencing_token", "acquired_at", "expires_at", "status"}
        optional = {"released_at", "release_id", "recovered_at", "recovery_evidence", "recovery_id", "recovery_fencing_token", "recovery_evidence_sha256", "replacement_lease_id"}
        if not set(lease).issubset(required_lease | optional) or not required_lease.issubset(lease) or lease["lease_id"] != lease_id:
            raise CoordinatorError("invalid_state", "lease fields drifted")
        normalized = normalize_descriptor(lease["resource"], lease["descriptor"])
        if normalized != lease["descriptor"] or lease["descriptor_sha256"] != _descriptor_hash(normalized):
            raise CoordinatorError("invalid_state", "lease descriptor drifted")
        if not isinstance(lease["fencing_token"], int) or isinstance(lease["fencing_token"], bool) or lease["fencing_token"] <= 0:
            raise CoordinatorError("invalid_state", "invalid lease fence")
        if lease["receipt_id"] in receipt_ids or lease["fencing_token"] in fencing_tokens:
            raise CoordinatorError("invalid_state", "duplicate receipt or fencing token")
        receipt_ids.add(lease["receipt_id"])
        fencing_tokens.add(lease["fencing_token"])
        highest_fence = max(highest_fence, lease["fencing_token"])
        if lease["status"] not in {"active", "released", "recovered"}:
            raise CoordinatorError("invalid_state", "invalid lease status")
        acquired_at = _parse_stamp(lease["acquired_at"])
        expires_at = _parse_stamp(lease["expires_at"])
        if expires_at <= acquired_at:
            raise CoordinatorError("invalid_state", "invalid lease time range")
        for field in ("receipt_id", "owner_run_id", "owner_actor"):
            _safe_string(lease[field], field)
        authority = data["run_authorities"].get(lease["owner_run_id"])
        if not isinstance(authority, dict):
            raise CoordinatorError("invalid_state", "lease authority is missing")
        if authority.get("selected_writer") != lease["owner_actor"]:
            raise CoordinatorError("invalid_state", "lease writer authority drifted")
        authority_issued_at = _parse_stamp(authority["authorization_issued_at"])
        authority_expires_at = _parse_stamp(authority["authorization_expires_at"])
        if acquired_at < authority_issued_at or expires_at > authority_expires_at:
            raise CoordinatorError("invalid_state", "lease exceeds authorization window")
        if lease["status"] == "active":
            if set(lease) != required_lease:
                raise CoordinatorError("invalid_state", "active lease has terminal fields")
            active_leases.append(lease)
        elif lease["status"] == "released":
            if set(lease) != required_lease | {"released_at", "release_id"}:
                raise CoordinatorError("invalid_state", "released lease fields drifted")
            _safe_string(lease["release_id"], "release_id")
            released_at = _parse_stamp(lease["released_at"])
            if released_at < acquired_at or released_at >= expires_at:
                raise CoordinatorError("invalid_state", "released lease time is invalid")
        else:
            required_recovery = {"recovered_at", "recovery_evidence", "recovery_id", "recovery_fencing_token", "recovery_evidence_sha256", "replacement_lease_id"}
            if set(lease) != required_lease | required_recovery:
                raise CoordinatorError("invalid_state", "recovered lease lacks confirmation")
            recovered_at = _parse_stamp(lease["recovered_at"])
            if recovered_at < expires_at:
                raise CoordinatorError("invalid_state", "recovery occurred before expiry")
            _safe_string(lease["recovery_id"], "recovery_id")
            if lease["recovery_id"] in recovery_ids:
                raise CoordinatorError("invalid_state", "duplicate recovery ID")
            recovery_ids.add(lease["recovery_id"])
            if (not isinstance(lease["recovery_fencing_token"], int)
                    or isinstance(lease["recovery_fencing_token"], bool)
                    or lease["recovery_fencing_token"] <= lease["fencing_token"]
                    or lease["recovery_fencing_token"] in fencing_tokens):
                raise CoordinatorError("invalid_state", "invalid recovery fence")
            fencing_tokens.add(lease["recovery_fencing_token"])
            if not _sha256(lease["recovery_evidence_sha256"]) or lease["recovery_evidence_sha256"] != recovery_evidence_sha256(lease["recovery_evidence"]):
                raise CoordinatorError("invalid_state", "recovery evidence digest drifted")
            _recovery_evidence(
                lease["recovery_evidence"],
                _receipt(lease, data["coordinator_instance_id"]),
                recovered_at,
            )
            replacement_id = lease["replacement_lease_id"]
            if replacement_id is not None and not isinstance(replacement_id, str):
                raise CoordinatorError("invalid_state", "replacement lease ID is invalid")
            replacement_links.append((lease, replacement_id))
            highest_fence = max(highest_fence, lease["recovery_fencing_token"])
    active_leases.sort(key=lambda item: item["fencing_token"])
    for index, lease in enumerate(active_leases):
        for other in active_leases[index + 1:]:
            if descriptors_conflict(
                lease["resource"], lease["descriptor"],
                other["resource"], other["descriptor"],
            ) and not same_owner_nested_compatible(
                other["resource"], lease["resource"],
                other["owner_run_id"], other["owner_actor"],
                lease["owner_run_id"], lease["owner_actor"],
                other["descriptor"], lease["descriptor"],
            ):
                raise CoordinatorError("invalid_state", "overlapping active leases")
    for lease in active_leases:
        if lease["resource"] == BUILD_TUPLE and not _resolution_support_present(
            lease, active_leases
        ):
            raise CoordinatorError(
                "invalid_state", "package resolution build lacks supporting mutation leases"
            )
    for recovered, replacement_id in replacement_links:
        if replacement_id is None:
            continue
        replacement = data["leases"].get(replacement_id)
        if not isinstance(replacement, dict):
            raise CoordinatorError("invalid_state", "replacement lease is missing")
        if (replacement["fencing_token"] <= recovered["recovery_fencing_token"]
                or replacement["acquired_at"] != recovered["recovered_at"]):
            raise CoordinatorError("invalid_state", "replacement lease binding drifted")
    if highest_fence != data["next_fencing_token"]:
        raise CoordinatorError("invalid_state", "fencing token drifted")
    return data


def _write(path: Path, state: dict[str, Any]) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=os.fspath(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def _locked_state(
    state_path: str | os.PathLike[str], *, bootstrap_create: bool = False
) -> Iterator[tuple[Path, dict[str, Any]]]:
    path = _state_path(state_path)
    lock_path = Path(os.fspath(path) + ".lock")
    if lock_path.exists() and lock_path.is_symlink():
        raise CoordinatorError("invalid_state_path", "lock file must not be a symlink")
    if not path.exists():
        if not bootstrap_create:
            raise CoordinatorError(
                "migration_required", "coordinator state is not bootstrapped"
            )
        if lock_path.exists():
            raise CoordinatorError(
                "invalid_state_path", "orphaned coordinator lock requires review"
            )
        flags = os.O_CREAT | os.O_EXCL | os.O_RDWR
    else:
        if not lock_path.exists():
            raise CoordinatorError(
                "invalid_state_path", "bootstrapped coordinator lock is missing"
            )
        flags = os.O_RDWR
    fd = os.open(lock_path, flags | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise CoordinatorError("invalid_state_path", "lock file must be regular")
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            current = os.stat(lock_path, follow_symlinks=False)
        except OSError as error:
            raise CoordinatorError(
                "invalid_state_path", "coordinator lock disappeared while held"
            ) from error
        if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
            raise CoordinatorError(
                "invalid_state_path", "coordinator lock identity changed while held"
            )
        yield path, _load(path)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def bootstrap(state_path: str | os.PathLike[str], *, legacy_leases_quiesced: bool) -> dict[str, Any]:
    """Perform the explicit, one-time migration acknowledgement."""
    if legacy_leases_quiesced is not True:
        raise CoordinatorError("migration_required", "legacy or unversioned leases must be quiesced")
    with _locked_state(state_path, bootstrap_create=True) as (path, state):
        if state["migration_bootstrap"] is not None:
            return {"coordinator_instance_id": state["coordinator_instance_id"], "already_bootstrapped": True}
        state["migration_bootstrap"] = {"legacy_leases_quiesced": True, "confirmed_at": _stamp(_utc_now())}
        _write(path, state)
        return {"coordinator_instance_id": state["coordinator_instance_id"], "already_bootstrapped": False}


bootstrap_state = bootstrap


def _full_status(state_path: str | os.PathLike[str]) -> dict[str, Any]:
    """Return the validated coordinator state to trusted sibling code only."""
    path = _state_path(state_path)
    if not path.exists():
        raise CoordinatorError("migration_required", "coordinator state is not bootstrapped")
    with _locked_state(state_path) as (_, state):
        _require_bootstrap(state)
        return json.loads(_json(state))


def status(state_path: str | os.PathLike[str]) -> dict[str, Any]:
    """Return a redacted public status without receipts or authority hashes."""
    state = _full_status(state_path)
    return {
        "schema_version": state["schema_version"],
        "coordinator_instance_id": state["coordinator_instance_id"],
        "migration_bootstrap": state["migration_bootstrap"],
        "active_lease_count": len(_active(state)),
    }


def load_trusted_harness(harness_path: str | os.PathLike[str]) -> dict[str, Any]:
    """Load one private, non-symlink harness used as the writer authority."""
    path = Path(harness_path)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise CoordinatorError("untrusted_binding", "harness must be an absolute regular file")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CoordinatorError("untrusted_binding", "harness cannot be read") from error
    if not isinstance(document, dict):
        raise CoordinatorError("untrusted_binding", "harness must contain an object")
    try:
        schema_path = (
            Path(__file__).resolve().parents[1]
            / "contracts"
            / "schemas"
            / "harness.schema.json"
        )
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        checker = _installed_contract_checker()
        schema_errors = checker._schema_errors(document, schema)
    except (OSError, AttributeError, json.JSONDecodeError) as error:
        raise CoordinatorError("untrusted_binding", "harness schema is unavailable") from error
    if schema_errors:
        raise CoordinatorError(
            "untrusted_binding", "; ".join(sorted(set(schema_errors)))
        )
    mode = document.get("mode")
    selected_writer = document.get("selected_writer")
    reviewer = document.get("reviewer")
    valid_roles = (
        (mode == "codex" and selected_writer == "codex" and reviewer is None)
        or (mode == "claude" and selected_writer == "claude" and reviewer is None)
        or (
            mode == "collaborative"
            and (selected_writer, reviewer)
            in {("codex", "claude"), ("claude", "codex")}
        )
    )
    if not valid_roles:
        raise CoordinatorError(
            "untrusted_binding", "harness writer and reviewer roles are invalid"
        )
    binding = document.get("resource_coordinator")
    if not isinstance(binding, dict):
        raise CoordinatorError("untrusted_binding", "harness lacks resource_coordinator")
    for field in (
        "authoritative_root",
        "private_policy_overlay",
        "run_authorization",
        "run_ledger",
    ):
        value = document.get(field)
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise CoordinatorError(
                "untrusted_binding", f"harness {field} must be an absolute path"
            )
    container = document.get("xcode_container")
    if container is not None and (
        not isinstance(container, str) or not Path(container).is_absolute()
    ):
        raise CoordinatorError(
            "untrusted_binding", "harness xcode_container must be an absolute path"
        )
    return document


def load_harness_binding(harness_path: str | os.PathLike[str]) -> dict[str, Any]:
    """Load the exact coordinator binding from one trusted private harness."""
    return load_trusted_harness(harness_path)["resource_coordinator"]


def _portable_document_sha256(document: dict[str, Any]) -> str:
    portable = {key: value for key, value in document.items() if key != "$schema"}
    encoded = json.dumps(portable, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def _installed_contract_checker() -> Any:
    """Load the exact sibling dependency-free schema/semantic checker."""
    checker_path = Path(__file__).resolve().with_name("check_authorization.py")
    scripts_path = str(checker_path.parent)
    specification = importlib.util.spec_from_file_location(
        "_installed_agent_harness_contract_checker", checker_path
    )
    if specification is None or specification.loader is None:
        raise OSError("checker loader unavailable")
    checker = importlib.util.module_from_spec(specification)
    inserted = scripts_path not in sys.path
    if inserted:
        sys.path.insert(0, scripts_path)
    try:
        specification.loader.exec_module(checker)
    finally:
        if inserted:
            sys.path.remove(scripts_path)
    return checker


def load_existing_run_authority(
    authorization_path: str | os.PathLike[str],
    harness_path: str | os.PathLike[str],
    harness: dict[str, Any],
    run_id: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Load one exact approved authority, including inactive cleanup authority."""
    path = Path(authorization_path)
    harness_path_value = harness.get("run_authorization")
    if (
        not path.is_absolute()
        or path.is_symlink()
        or not path.is_file()
        or not isinstance(harness_path_value, str)
        or not harness_path_value.startswith("/")
    ):
        raise CoordinatorError("untrusted_authority")
    try:
        if path.resolve(strict=True) != Path(harness_path_value).resolve(strict=True):
            raise CoordinatorError("untrusted_authority")
        authorization = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CoordinatorError("untrusted_authority") from error
    if (
        not isinstance(authorization, dict)
        or authorization.get("decision") != "approved"
        or authorization.get("run_id") != run_id
        or authorization.get("selected_writer") != harness.get("selected_writer")
    ):
        raise CoordinatorError("writer_mismatch")
    schema_path = (
        Path(__file__).resolve().parents[1]
        / "contracts"
        / "schemas"
        / "run-authorization.schema.json"
    )
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        schema_sha = "sha256:" + hashlib.sha256(schema_path.read_bytes()).hexdigest()
        checker = _installed_contract_checker()
        contract_errors = checker._schema_errors(authorization, schema)
        contract_errors.extend(checker.validate_authorization(authorization))
    except (OSError, AttributeError, json.JSONDecodeError) as error:
        raise CoordinatorError("untrusted_authority") from error
    if contract_errors:
        raise CoordinatorError("untrusted_authority", "; ".join(sorted(set(contract_errors))))
    issued_at = _parse_stamp(authorization.get("issued_at"))
    expires_at = _parse_stamp(authorization.get("expires_at"))
    if expires_at <= issued_at:
        raise CoordinatorError("untrusted_authority")
    if (
        authorization.get("contract_schema_id") != schema.get("$id")
        or authorization.get("contract_schema_sha256") != schema_sha
    ):
        raise CoordinatorError("untrusted_authority")
    harness_document = load_trusted_harness(harness_path)
    harness_ledger = harness_document.get("run_ledger")
    if not isinstance(harness_ledger, str):
        raise CoordinatorError("untrusted_authority")
    authorization_digest = _portable_document_sha256(authorization)
    canonical_ledger = ledger_binding(
        harness_ledger,
        expected_run_id=run_id,
        expected_authorization_hash=authorization_digest,
    )
    authority = {
        "authorization_hash": authorization_digest,
        "selected_writer": authorization["selected_writer"],
        "harness_sha256": _portable_document_sha256(harness_document),
        "authorization_issued_at": _stamp(issued_at),
        "authorization_expires_at": _stamp(expires_at),
        **canonical_ledger,
    }
    return authorization, authority


def load_run_authority(
    authorization_path: str | os.PathLike[str],
    harness_path: str | os.PathLike[str],
    harness: dict[str, Any],
    run_id: str,
    resource: str,
    descriptor: dict[str, Any],
    plan_id: str | None = None,
) -> dict[str, Any]:
    """Bind a run once to its active authorization and selected writer."""
    authorization, authority = load_existing_run_authority(
        authorization_path, harness_path, harness, run_id
    )
    current = _utc_now()
    if not (
        _parse_stamp(authority["authorization_issued_at"])
        <= current
        < _parse_stamp(authority["authorization_expires_at"])
    ):
        raise CoordinatorError("authorization_inactive")
    normalized_descriptor = normalize_descriptor(resource, descriptor)
    resource_key = canonical_resource_key(resource, normalized_descriptor)
    repository = authorization.get("repository")
    repository_fingerprint = (
        repository.get("fingerprint") if isinstance(repository, dict) else None
    )
    if resource in {SOURCE_WRITER, XCODE_PROJECT, BUILD_TUPLE, GITHUB} and (
        normalized_descriptor.get("repository_fingerprint")
        != repository_fingerprint
    ):
        raise CoordinatorError("authorization_scope_mismatch")
    if resource == GITHUB:
        github = authorization.get("github")
        expected_remote = (
            f"{github.get('owner')}/{github.get('repository')}".lower()
            if isinstance(github, dict)
            else None
        )
        if normalized_descriptor.get("remote_repository") != expected_remote:
            raise CoordinatorError("authorization_scope_mismatch")
    resource_plan = authorization.get("resource_plan")
    if not isinstance(resource_plan, list):
        raise CoordinatorError("authorization_scope_mismatch")
    exact_plans = [
        entry
        for entry in resource_plan
        if isinstance(entry, dict)
        and entry.get("resource") == resource
        and entry.get("resource_key") == resource_key
        and entry.get("resource_descriptor") == normalized_descriptor
        and entry.get("owner_actor") == authorization.get("selected_writer")
    ]
    if resource in {XCODE_PROJECT, BUILD_TUPLE, SIMULATOR, CORE_SIMULATOR, MACOS_GUI}:
        if (
            not isinstance(plan_id, str)
            or len(exact_plans) != 1
            or exact_plans[0].get("plan_id") != plan_id
        ):
            raise CoordinatorError("authorization_scope_mismatch")
    else:
        grant_keys = {
            grant.get("resource_key")
            for grant in authorization.get("action_grants", [])
            if isinstance(grant, dict)
        }
        if resource_key not in grant_keys and len(exact_plans) != 1:
            raise CoordinatorError("authorization_scope_mismatch")
    return authority


def validate_trusted_binding(
    state_path: str | os.PathLike[str], binding: dict[str, Any]
) -> dict[str, Any]:
    """Fail closed unless path, instance, and installed contracts match the harness."""
    required = {
        "state_path", "coordinator_instance_id", "script_sha256",
        "contract_bundle_sha256",
    }
    if not isinstance(binding, dict) or set(binding) != required:
        raise CoordinatorError("untrusted_binding", "binding fields are incomplete")
    path = _state_path(state_path)
    expected_value = binding.get("state_path")
    if not isinstance(expected_value, str) or not expected_value.startswith("/"):
        raise CoordinatorError("untrusted_binding", "bound state path is invalid")
    expected = Path(expected_value)
    try:
        if path.is_symlink() or expected.is_symlink():
            raise OSError
        if path.resolve(strict=True) != expected.resolve(strict=True):
            raise CoordinatorError("untrusted_binding", "state path drifted")
    except OSError as error:
        raise CoordinatorError("untrusted_binding", "state path cannot be resolved") from error
    script = Path(__file__)
    if script.is_symlink():
        raise CoordinatorError("untrusted_binding", "coordinator script is a symlink")
    script_sha256 = "sha256:" + hashlib.sha256(script.read_bytes()).hexdigest()
    if binding.get("script_sha256") != script_sha256:
        raise CoordinatorError("untrusted_binding", "coordinator script hash drifted")
    if binding.get("contract_bundle_sha256") != contract_bundle_sha256():
        raise CoordinatorError("untrusted_binding", "installed contract bundle hash drifted")
    live = status(path)
    if live.get("coordinator_instance_id") != binding.get("coordinator_instance_id"):
        raise CoordinatorError("untrusted_binding", "coordinator instance drifted")
    return live


def _require_bootstrap(state: dict[str, Any]) -> None:
    bootstrap_record = state["migration_bootstrap"]
    if not isinstance(bootstrap_record, dict) or bootstrap_record.get("legacy_leases_quiesced") is not True:
        raise CoordinatorError("migration_required")


def _active(state: dict[str, Any]) -> list[dict[str, Any]]:
    # Expiration never changes ownership: only release or evidence-backed recovery does.
    return [lease for lease in state["leases"].values() if lease.get("status") == "active"]


def _receipt(lease: dict[str, Any], instance: str) -> dict[str, Any]:
    receipt = {key: lease[key] for key in (
        "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource",
        "descriptor_sha256", "fencing_token", "acquired_at", "expires_at",
    )} | {"coordinator_instance_id": instance}
    receipt["resource_key"] = f"{lease['resource']}:{lease['descriptor_sha256']}"
    return receipt


def _authority_window(
    authority: dict[str, Any] | None,
    *,
    owner_actor: str | None = None,
    require_active_at: datetime | None = None,
) -> tuple[datetime, datetime]:
    required = RUN_AUTHORITY_FIELDS
    if (
        not isinstance(authority, dict)
        or set(authority) != required
        or not _sha256(authority.get("authorization_hash"))
        or authority.get("selected_writer") not in {"codex", "claude"}
        or (owner_actor is not None and authority.get("selected_writer") != owner_actor)
        or not _sha256(authority.get("harness_sha256"))
        or not isinstance(authority.get("ledger_path"), str)
        or not Path(authority["ledger_path"]).is_absolute()
        or not _sha256(authority.get("ledger_identity_sha256"))
        or not _sha256(authority.get("ledger_approval_sha256"))
    ):
        raise CoordinatorError("untrusted_authority")
    try:
        issued_at = _parse_stamp(authority["authorization_issued_at"])
        expires_at = _parse_stamp(authority["authorization_expires_at"])
    except CoordinatorError as error:
        raise CoordinatorError("untrusted_authority") from error
    if expires_at <= issued_at:
        raise CoordinatorError("untrusted_authority")
    if require_active_at is not None and not issued_at <= require_active_at < expires_at:
        raise CoordinatorError("authorization_inactive")
    return issued_at, expires_at


def _require_receipt_authority(
    state: dict[str, Any], lease: dict[str, Any], authority: dict[str, Any] | None
) -> tuple[datetime, datetime]:
    window = _authority_window(authority, owner_actor=lease.get("owner_actor"))
    stored = state["run_authorities"].get(lease.get("owner_run_id"))
    if stored != authority:
        raise CoordinatorError("untrusted_authority")
    return window


def _new_lease(
    state: dict[str, Any],
    resource: str,
    descriptor: dict[str, Any],
    owner_run_id: str,
    owner_actor: str,
    ttl_seconds: int,
    *,
    authorization_expires_at: datetime,
    now: datetime | None = None,
) -> dict[str, Any]:
    if not isinstance(owner_run_id, str) or not owner_run_id or not isinstance(owner_actor, str) or not owner_actor:
        raise CoordinatorError("invalid_owner")
    if (
        not isinstance(ttl_seconds, int)
        or isinstance(ttl_seconds, bool)
        or ttl_seconds <= 0
        or ttl_seconds > MAX_TTL_SECONDS
    ):
        raise CoordinatorError("invalid_ttl")
    normalized = normalize_descriptor(resource, descriptor)
    if resource in {SIMULATOR, CORE_SIMULATOR, MACOS_GUI} and normalized.get(
        "coordinator_instance_id"
    ) != state["coordinator_instance_id"]:
        raise CoordinatorError("coordinator_instance_mismatch")
    active_leases = _active(state)
    for lease in active_leases:
        if descriptors_conflict(
            resource, normalized, lease["resource"], lease["descriptor"]
        ) and not same_owner_nested_compatible(
            resource, lease["resource"], owner_run_id, owner_actor,
            lease["owner_run_id"], lease["owner_actor"],
            normalized, lease["descriptor"],
        ):
            raise CoordinatorError("resource_conflict", lease["lease_id"])
    if resource == BUILD_TUPLE:
        supporting_source = any(
            lease["resource"] == SOURCE_WRITER
            and lease["owner_run_id"] == owner_run_id
            and lease["owner_actor"] == owner_actor
            and lease["descriptor"]["repository_fingerprint"]
            == normalized["repository_fingerprint"]
            for lease in active_leases
        )
        if not supporting_source:
            raise CoordinatorError("source_writer_required")
        if normalized["package_resolution_mode"] == "xcode_project_packages":
            supporting_project = any(
                lease["resource"] == XCODE_PROJECT
                and lease["owner_run_id"] == owner_run_id
                and lease["owner_actor"] == owner_actor
                and lease["descriptor"]["repository_fingerprint"]
                == normalized["repository_fingerprint"]
                and lease["descriptor"]["container_path"]
                == normalized["container_path"]
                for lease in active_leases
            )
            if not supporting_project:
                raise CoordinatorError("xcode_project_lease_required")
    now = _aware_now(now)
    lease_expires_at = now + timedelta(seconds=ttl_seconds)
    if lease_expires_at > authorization_expires_at:
        raise CoordinatorError("authorization_window_too_short")
    state["next_fencing_token"] += 1
    lease = {
        "receipt_id": str(uuid.uuid4()), "lease_id": str(uuid.uuid4()),
        "owner_run_id": owner_run_id, "owner_actor": owner_actor,
        "resource": resource, "descriptor": normalized,
        "descriptor_sha256": _descriptor_hash(normalized),
        "fencing_token": state["next_fencing_token"],
        "acquired_at": _stamp(now), "expires_at": _stamp(lease_expires_at),
        "status": "active",
    }
    state["leases"][lease["lease_id"]] = lease
    return lease


def register_run_authority(
    state_path: str | os.PathLike[str],
    run_id: str,
    run_authority: dict[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Register one immutable run authority during the approval ceremony.

    Lease acquisition never creates authority.  Re-registration is idempotent
    only for the byte-equivalent authority, including canonical ledger inode.
    """
    if not isinstance(run_id, str) or not run_id:
        raise CoordinatorError("invalid_owner")
    current_time = _aware_now(now)
    _authority_window(run_authority, require_active_at=current_time)
    with _locked_state(state_path) as (path, state):
        _require_bootstrap(state)
        existing = state["run_authorities"].get(run_id)
        if existing is None:
            state["run_authorities"][run_id] = dict(run_authority)
            _write(path, state)
        elif existing != run_authority:
            raise CoordinatorError("untrusted_authority", "run authority is immutable")
        return {
            "run_id": run_id,
            "registered": existing is None,
            "authorization_hash": run_authority["authorization_hash"],
            "ledger_identity_sha256": run_authority["ledger_identity_sha256"],
        }


def acquire(state_path: str | os.PathLike[str], request: dict[str, Any] | None = None, *, resource: str | None = None, descriptor: dict[str, Any] | None = None, owner_run_id: str | None = None, owner_actor: str | None = None, ttl_seconds: int | None = None, now: datetime | None = None, run_authority: dict[str, Any] | None = None) -> dict[str, Any]:
    """Atomically acquire one lease. ``request`` uses the named keyword fields."""
    if request is not None:
        if not isinstance(request, dict):
            raise CoordinatorError("invalid_request")
        unexpected = set(request) - {"resource", "descriptor", "owner_run_id", "owner_actor", "run_id", "actor", "ttl_seconds"}
        if unexpected:
            raise CoordinatorError("invalid_request")
        resource = request.get("resource", resource)
        descriptor = request.get("descriptor", descriptor)
        owner_run_id = request.get("owner_run_id", request.get("run_id", owner_run_id))
        owner_actor = request.get("owner_actor", request.get("actor", owner_actor))
        ttl_seconds = request.get("ttl_seconds", ttl_seconds)
    with _locked_state(state_path) as (path, state):
        _require_bootstrap(state)
        current_time = _aware_now(now)
        _, authorization_expires_at = _authority_window(
            run_authority,
            owner_actor=owner_actor,
            require_active_at=current_time,
        )
        existing_authority = state["run_authorities"].get(owner_run_id)
        if existing_authority is None:
            raise CoordinatorError("unregistered_run_authority")
        if existing_authority != run_authority:
            raise CoordinatorError("writer_mismatch")
        lease = _new_lease(
            state,
            resource,
            descriptor,
            owner_run_id,
            owner_actor,
            ttl_seconds,
            authorization_expires_at=authorization_expires_at,
            now=current_time,
        )
        _write(path, state)
        return _receipt(lease, state["coordinator_instance_id"])


def _lease_for_receipt(state: dict[str, Any], receipt: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_FIELDS:
        raise CoordinatorError("invalid_receipt")
    lease_id = receipt.get("lease_id")
    lease = state["leases"].get(lease_id)
    if not isinstance(lease, dict) or lease.get("status") != "active":
        raise CoordinatorError("stale_receipt")
    if receipt != _receipt(lease, state["coordinator_instance_id"]):
        raise CoordinatorError("stale_receipt")
    return lease


def verify(state_path: str | os.PathLike[str], receipt: dict[str, Any], *, now: datetime | None = None) -> dict[str, Any]:
    with _locked_state(state_path) as (_, state):
        lease = _lease_for_receipt(state, receipt)
        if _parse_stamp(lease["expires_at"]) <= _aware_now(now):
            raise CoordinatorError("expired_requires_recover")
        return _receipt(lease, state["coordinator_instance_id"])


def verify_receipt(state_path: str | os.PathLike[str], receipt: dict[str, Any], *, now: datetime | None = None) -> tuple[list[str], dict[str, Any] | None]:
    """Verify a receipt in the active lease's monotonic heartbeat lineage.

    A reservation or dispatch may retain an earlier ``expires_at`` value after
    the same fenced lease is heartbeated.  All stable receipt fields must still
    match and the submitted expiry may never be newer than the persisted one.
    The current live receipt is returned for the caller's next ledger record.
    """
    try:
        if not isinstance(receipt, dict) or set(receipt) != RECEIPT_FIELDS:
            raise CoordinatorError("invalid_receipt")
        with _locked_state(state_path) as (_, state):
            lease = state["leases"].get(receipt.get("lease_id"))
            if not isinstance(lease, dict) or lease.get("status") != "active":
                raise CoordinatorError("stale_receipt")
            current = _receipt(lease, state["coordinator_instance_id"])
            stable = RECEIPT_FIELDS - {"expires_at"}
            if any(receipt.get(field) != current.get(field) for field in stable):
                raise CoordinatorError("stale_receipt")
            if _parse_stamp(receipt.get("expires_at")) > _parse_stamp(
                current.get("expires_at")
            ):
                raise CoordinatorError("stale_receipt")
            if _parse_stamp(current["expires_at"]) <= _aware_now(now):
                raise CoordinatorError("expired_requires_recover")
            return [], current
    except CoordinatorError as error:
        return [error.code], None


def heartbeat(
    state_path: str | os.PathLike[str],
    receipt: dict[str, Any],
    *,
    ttl_seconds: int,
    run_authority: dict[str, Any] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    if (
        not isinstance(ttl_seconds, int)
        or isinstance(ttl_seconds, bool)
        or ttl_seconds <= 0
        or ttl_seconds > MAX_TTL_SECONDS
    ):
        raise CoordinatorError("invalid_ttl")
    with _locked_state(state_path) as (path, state):
        lease = _lease_for_receipt(state, receipt)
        current_time = _aware_now(now)
        _, authorization_expires_at = _require_receipt_authority(
            state, lease, run_authority
        )
        if current_time >= authorization_expires_at:
            raise CoordinatorError("authorization_inactive")
        old_expiry = _parse_stamp(lease["expires_at"])
        if old_expiry <= current_time:
            raise CoordinatorError("expired_requires_recover")
        next_expiry = current_time + timedelta(seconds=ttl_seconds)
        if next_expiry <= old_expiry:
            raise CoordinatorError("heartbeat_must_extend")
        if next_expiry > authorization_expires_at:
            raise CoordinatorError("authorization_window_too_short")
        lease["expires_at"] = _stamp(next_expiry)
        _write(path, state)
        return _receipt(lease, state["coordinator_instance_id"])


def release(
    state_path: str | os.PathLike[str],
    receipt: dict[str, Any],
    *,
    run_authority: dict[str, Any] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    with _locked_state(state_path) as (path, state):
        lease = _lease_for_receipt(state, receipt)
        _require_receipt_authority(state, lease, run_authority)
        if _supports_active_resolution(lease, _active(state)):
            raise CoordinatorError("dependent_lease_active")
        current_time = _aware_now(now)
        if _parse_stamp(lease["expires_at"]) <= current_time:
            raise CoordinatorError("expired_requires_recover")
        lease["status"] = "released"
        lease["release_id"] = str(uuid.uuid4())
        lease["released_at"] = _stamp(current_time)
        confirmation = {
            "coordinator_instance_id": state["coordinator_instance_id"],
            "release_id": lease["release_id"],
            "receipt_id": lease["receipt_id"],
            "lease_id": lease["lease_id"],
            "fencing_token": lease["fencing_token"],
            "released_at": lease["released_at"],
        }
        _write(path, state)
        return confirmation


def validate_release_confirmation(
    receipt: dict[str, Any],
    confirmation: dict[str, Any],
    *,
    state_path: str | os.PathLike[str] | None = None,
) -> bool:
    """Validate a normal release, optionally against the live persisted state."""
    if (
        not isinstance(receipt, dict)
        or set(receipt) != RECEIPT_FIELDS
        or not isinstance(confirmation, dict)
        or set(confirmation) != RELEASE_CONFIRMATION_FIELDS
    ):
        return False
    expected = {
        "coordinator_instance_id": receipt.get("coordinator_instance_id"),
        "receipt_id": receipt.get("receipt_id"),
        "lease_id": receipt.get("lease_id"),
        "fencing_token": receipt.get("fencing_token"),
    }
    if any(confirmation.get(field) != value for field, value in expected.items()):
        return False
    if not isinstance(confirmation.get("release_id"), str) or not confirmation["release_id"]:
        return False
    try:
        released_at = _parse_stamp(confirmation.get("released_at"))
        if not _parse_stamp(receipt.get("acquired_at")) <= released_at < _parse_stamp(receipt.get("expires_at")):
            return False
    except CoordinatorError:
        return False
    if state_path is None:
        return True
    try:
        with _locked_state(state_path) as (_, state):
            lease = state["leases"].get(receipt.get("lease_id"))
            if not isinstance(lease, dict) or lease.get("status") != "released":
                return False
            if receipt != _receipt(lease, state["coordinator_instance_id"]):
                return False
            return (
                lease.get("release_id") == confirmation["release_id"]
                and lease.get("released_at") == confirmation["released_at"]
            )
    except CoordinatorError:
        return False


def _sha256(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value) is not None


def _recovery_evidence(value: dict[str, Any], receipt: dict[str, Any], now: datetime) -> None:
    if not isinstance(value, dict):
        raise CoordinatorError("invalid_recovery_evidence")
    expected = {
        "previous_receipt_id", "previous_fencing_token", "observer",
        "owner_liveness", "owner_tool_children", "dirty_state",
        "live_resource_revalidation",
    }
    if set(value) != expected or value["previous_receipt_id"] != receipt.get("receipt_id") or value["previous_fencing_token"] != receipt.get("fencing_token"):
        raise CoordinatorError("invalid_recovery_evidence")
    owner = value["owner_liveness"]
    children = value["owner_tool_children"]
    dirty = value["dirty_state"]
    live = value["live_resource_revalidation"]
    observer = value["observer"]
    if (
        not isinstance(observer, dict)
        or set(observer)
        != {"observer_run_id", "observer_actor", "method", "observed_at"}
        or observer.get("method") != "bounded_read_only_host_probe"
        or observer.get("observer_run_id") == receipt.get("owner_run_id")
    ):
        raise CoordinatorError("invalid_recovery_evidence")
    _safe_string(observer.get("observer_run_id"), "observer_run_id")
    _safe_string(observer.get("observer_actor"), "observer_actor")
    observer_time = _parse_stamp(observer.get("observed_at"))
    if observer_time > now or now - observer_time > timedelta(minutes=5):
        raise CoordinatorError("stale_recovery_evidence")
    observations = (
        (owner, "state", "dead"),
        (children, "state", "dead"),
        (dirty, "state", "clean"),
        (live, "passed", True),
    )
    for observation, field, expected_value in observations:
        if not isinstance(observation, dict) or observation.get(field) != expected_value or not _sha256(observation.get("digest")) or not isinstance(observation.get("observed_at"), str):
            raise CoordinatorError("invalid_recovery_evidence")
        observed = _parse_stamp(observation["observed_at"])
        if observed > now or now - observed > timedelta(minutes=5):
            raise CoordinatorError("stale_recovery_evidence")
    if set(owner) != {"state", "digest", "observed_at"}:
        raise CoordinatorError("invalid_recovery_evidence")
    if (
        set(children) != {"state", "digest", "observed_at"}
        or set(dirty) != {"state", "digest", "observed_at"}
        or set(live) != {"passed", "digest", "observed_at"}
    ):
        raise CoordinatorError("invalid_recovery_evidence")


def validate_recovery_confirmation(receipt: dict[str, Any], evidence: dict[str, Any], confirmation: dict[str, Any], *, state_path: str | os.PathLike[str] | None = None) -> bool:
    """Validate a confirmation; a state path additionally detects forged fields."""
    if not isinstance(receipt, dict) or not isinstance(confirmation, dict):
        return False
    expected = {"coordinator_instance_id", "recovery_id", "previous_receipt_id", "previous_fencing_token", "recovery_fencing_token", "recovered_at", "evidence_sha256", "replacement_receipt"}
    if set(confirmation) != expected:
        return False
    if (confirmation["coordinator_instance_id"] != receipt.get("coordinator_instance_id")
            or confirmation["previous_receipt_id"] != receipt.get("receipt_id")
            or confirmation["previous_fencing_token"] != receipt.get("fencing_token")
            or not isinstance(confirmation["recovery_fencing_token"], int)
            or confirmation["recovery_fencing_token"] <= receipt.get("fencing_token", -1)
            or not isinstance(confirmation["recovery_id"], str)
            or not _sha256(confirmation["evidence_sha256"])):
        return False
    try:
        recovered_at = _parse_stamp(confirmation["recovered_at"])
        _recovery_evidence(evidence, receipt, recovered_at)
    except CoordinatorError:
        return False
    if confirmation["evidence_sha256"] != recovery_evidence_sha256(evidence):
        return False
    replacement = confirmation["replacement_receipt"]
    valid = replacement is None or (isinstance(replacement, dict)
        and replacement.get("coordinator_instance_id") == receipt.get("coordinator_instance_id")
        and isinstance(replacement.get("fencing_token"), int)
        and replacement["fencing_token"] > confirmation["recovery_fencing_token"])
    if not valid or state_path is None:
        return valid
    try:
        with _locked_state(state_path) as (_, state):
            if confirmation["coordinator_instance_id"] != state["coordinator_instance_id"]:
                return False
            lease = next((item for item in state["leases"].values() if item["receipt_id"] == receipt.get("receipt_id")), None)
            if not isinstance(lease, dict) or lease.get("status") != "recovered":
                return False
            if receipt != _receipt(lease, state["coordinator_instance_id"]):
                return False
            replacement_id = lease.get("replacement_lease_id")
            expected_replacement = None
            if replacement_id is not None:
                replacement_lease = state["leases"].get(replacement_id)
                if not isinstance(replacement_lease, dict):
                    return False
                expected_replacement = _receipt(
                    replacement_lease, state["coordinator_instance_id"]
                )
            return (lease.get("recovery_id") == confirmation["recovery_id"]
                and lease.get("recovery_fencing_token") == confirmation["recovery_fencing_token"]
                and lease.get("recovery_evidence_sha256") == confirmation["evidence_sha256"]
                and lease.get("recovered_at") == confirmation["recovered_at"]
                and confirmation.get("replacement_receipt") == expected_replacement)
    except CoordinatorError:
        return False


def recover(
    state_path: str | os.PathLike[str],
    receipt: dict[str, Any],
    *,
    evidence: dict[str, Any],
    run_authority: dict[str, Any] | None = None,
    observer_authority: dict[str, Any] | None = None,
    replacement: dict[str, Any] | None = None,
    replacement_authority: dict[str, Any] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Evidence-backed recovery after expiry; optional replacement gets a new fence."""
    with _locked_state(state_path) as (path, state):
        _require_bootstrap(state)
        lease = _lease_for_receipt(state, receipt)
        _require_receipt_authority(state, lease, run_authority)
        current_time = _aware_now(now)
        if _parse_stamp(lease["expires_at"]) > current_time:
            raise CoordinatorError("recovery_not_yet_allowed")
        if _supports_active_resolution(lease, _active(state)):
            raise CoordinatorError("dependent_lease_active")
        _recovery_evidence(evidence, receipt, current_time)
        observer = evidence["observer"]
        observer_run_id = observer["observer_run_id"]
        observer_actor = observer["observer_actor"]
        try:
            _authority_window(
                observer_authority,
                owner_actor=observer_actor,
                require_active_at=current_time,
            )
        except CoordinatorError as error:
            raise CoordinatorError("untrusted_authority") from error
        if observer_run_id == lease.get("owner_run_id"):
            raise CoordinatorError("untrusted_authority")
        existing_observer_authority = state["run_authorities"].get(
            observer_run_id
        )
        if existing_observer_authority is None:
            raise CoordinatorError("unregistered_run_authority")
        if existing_observer_authority != observer_authority:
            raise CoordinatorError("untrusted_authority")
        lease["status"] = "recovered"
        lease["recovered_at"] = _stamp(current_time)
        lease["recovery_evidence"] = _safe_json(evidence)
        state["next_fencing_token"] += 1
        recovery_fence = state["next_fencing_token"]
        lease["recovery_id"] = str(uuid.uuid4())
        lease["recovery_fencing_token"] = recovery_fence
        lease["recovery_evidence_sha256"] = recovery_evidence_sha256(evidence)
        new_receipt: dict[str, Any] | None = None
        if replacement is not None:
            if not isinstance(replacement, dict) or set(replacement) != {"resource", "descriptor", "owner_run_id", "owner_actor", "ttl_seconds"}:
                raise CoordinatorError("invalid_replacement")
            try:
                _, replacement_authorization_expires_at = _authority_window(
                    replacement_authority,
                    owner_actor=replacement.get("owner_actor"),
                    require_active_at=current_time,
                )
            except CoordinatorError as error:
                raise CoordinatorError("untrusted_authority") from error
            if (
                replacement.get("owner_run_id") == lease.get("owner_run_id")
                or evidence.get("observer", {}).get("observer_run_id")
                != replacement.get("owner_run_id")
                or evidence.get("observer", {}).get("observer_actor")
                != replacement.get("owner_actor")
                or replacement_authority != observer_authority
            ):
                raise CoordinatorError("untrusted_authority")
            replacement_run = replacement["owner_run_id"]
            existing_authority = state["run_authorities"].get(replacement_run)
            if existing_authority is None:
                raise CoordinatorError("unregistered_run_authority")
            if existing_authority != replacement_authority:
                raise CoordinatorError("untrusted_authority")
            replacement_lease = _new_lease(
                state,
                **replacement,
                authorization_expires_at=replacement_authorization_expires_at,
                now=current_time,
            )
            new_receipt = _receipt(replacement_lease, state["coordinator_instance_id"])
        lease["replacement_lease_id"] = (
            new_receipt["lease_id"] if new_receipt is not None else None
        )
        confirmation = {
            "coordinator_instance_id": state["coordinator_instance_id"],
            "recovery_id": lease["recovery_id"],
            "previous_receipt_id": lease["receipt_id"],
            "previous_fencing_token": lease["fencing_token"],
            "recovery_fencing_token": recovery_fence,
            "recovered_at": lease["recovered_at"],
            "evidence_sha256": lease["recovery_evidence_sha256"],
            "replacement_receipt": new_receipt,
        }
        _write(path, state)
        return confirmation


def _cli() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state_path")
    sub = parser.add_subparsers(dest="command", required=True)
    boot = sub.add_parser("bootstrap"); boot.add_argument("--legacy-leases-quiesced", action="store_true")
    sub.add_parser("status")
    sub.add_parser("bundle-digest")
    for name in ("acquire",):
        command = sub.add_parser(name); command.add_argument("--harness", required=True); command.add_argument("--authorization", required=True); command.add_argument("--resource", required=True); command.add_argument("--descriptor", required=True); command.add_argument("--plan-id"); command.add_argument("--run-id", required=True); command.add_argument("--actor", required=True); command.add_argument("--ttl-seconds", required=True, type=int)
    for name in ("verify", "release"):
        command = sub.add_parser(name); command.add_argument("--harness", required=True); command.add_argument("--receipt", required=True)
    command = sub.add_parser("heartbeat"); command.add_argument("--harness", required=True); command.add_argument("--receipt", required=True); command.add_argument("--ttl-seconds", required=True, type=int)
    command = sub.add_parser("recover"); command.add_argument("--harness", required=True); command.add_argument("--receipt", required=True); command.add_argument("--evidence", required=True); command.add_argument("--observer-harness", required=True); command.add_argument("--observer-authorization", required=True); command.add_argument("--replacement"); command.add_argument("--replacement-harness"); command.add_argument("--replacement-authorization"); command.add_argument("--replacement-plan-id")
    args = parser.parse_args()
    try:
        if args.command not in {"bootstrap", "status", "bundle-digest"}:
            trusted_harness = load_trusted_harness(args.harness)
            validate_trusted_binding(
                args.state_path, trusted_harness["resource_coordinator"]
            )
            selected_writer = trusted_harness["selected_writer"]
            if args.command == "acquire" and args.actor != selected_writer:
                raise CoordinatorError(
                    "writer_mismatch", "only the selected writer may acquire a lease"
                )
            if args.command in {"verify", "heartbeat", "release", "recover"}:
                receipt = json.loads(args.receipt)
                if receipt.get("owner_actor") != selected_writer:
                    raise CoordinatorError(
                        "writer_mismatch", "lease owner is not the selected writer"
                    )
                if args.command in {"heartbeat", "release", "recover"}:
                    receipt_authority = load_existing_run_authority(
                        trusted_harness["run_authorization"],
                        args.harness,
                        trusted_harness,
                        receipt.get("owner_run_id"),
                    )[1]
                if args.command == "recover":
                    recovery_evidence = json.loads(args.evidence)
                    observer = recovery_evidence.get("observer", {})
                    observer_harness = load_trusted_harness(args.observer_harness)
                    validate_trusted_binding(
                        args.state_path,
                        observer_harness["resource_coordinator"],
                    )
                    observer_authority = load_existing_run_authority(
                        args.observer_authorization,
                        args.observer_harness,
                        observer_harness,
                        observer.get("observer_run_id"),
                    )[1]
                    _authority_window(
                        observer_authority,
                        owner_actor=observer.get("observer_actor"),
                        require_active_at=_utc_now(),
                    )
                if args.command == "recover" and args.replacement:
                    replacement_request = json.loads(args.replacement)
                    if not args.replacement_harness or not args.replacement_authorization:
                        raise CoordinatorError("untrusted_authority")
                    replacement_harness = load_trusted_harness(
                        args.replacement_harness
                    )
                    validate_trusted_binding(
                        args.state_path,
                        replacement_harness["resource_coordinator"],
                    )
                    if replacement_request.get("owner_actor") != replacement_harness.get("selected_writer"):
                        raise CoordinatorError(
                            "writer_mismatch",
                            "replacement lease owner is not the selected writer",
                        )
                    replacement_authority = load_run_authority(
                        args.replacement_authorization,
                        args.replacement_harness,
                        replacement_harness,
                        replacement_request.get("owner_run_id"),
                        replacement_request.get("resource"),
                        replacement_request.get("descriptor"),
                        args.replacement_plan_id,
                    )
        if args.command == "bootstrap": result = bootstrap(args.state_path, legacy_leases_quiesced=args.legacy_leases_quiesced)
        elif args.command == "status": result = status(args.state_path)
        elif args.command == "bundle-digest": result = {
            "contract_bundle_sha256": contract_bundle_sha256()
        }
        elif args.command == "acquire":
            acquire_descriptor = json.loads(args.descriptor)
            run_authority = load_run_authority(
                args.authorization, args.harness, trusted_harness, args.run_id,
                args.resource, acquire_descriptor, args.plan_id,
            )
            result = acquire(args.state_path, resource=args.resource, descriptor=acquire_descriptor, owner_run_id=args.run_id, owner_actor=args.actor, ttl_seconds=args.ttl_seconds, run_authority=run_authority)
        elif args.command == "verify": result = verify(args.state_path, receipt)
        elif args.command == "heartbeat": result = heartbeat(
            args.state_path, receipt, ttl_seconds=args.ttl_seconds,
            run_authority=receipt_authority,
        )
        elif args.command == "release": result = release(
            args.state_path, receipt, run_authority=receipt_authority,
        )
        else: result = recover(
            args.state_path,
            receipt,
            evidence=recovery_evidence,
            run_authority=receipt_authority,
            observer_authority=observer_authority,
            replacement=replacement_request if args.replacement else None,
            replacement_authority=replacement_authority if args.replacement else None,
        )
        print(json.dumps({"status": "ok", "result": result}, sort_keys=True))
        return 0
    except json.JSONDecodeError:
        print(json.dumps({"status": "blocked", "reason_code": "invalid_request"}, sort_keys=True))
        return 2
    except CoordinatorError as error:
        print(json.dumps({"status": "blocked", "reason_code": error.code}, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
