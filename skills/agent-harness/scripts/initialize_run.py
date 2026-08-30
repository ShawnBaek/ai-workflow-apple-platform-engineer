#!/usr/bin/env python3
"""Create the first immutable approval record in a private run ledger."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
from typing import Any

import check_authorization


class InitializeError(ValueError):
    pass


def _load_object(path: Path, label: str) -> dict[str, Any]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise InitializeError(f"{label} must be an absolute regular non-symlink file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InitializeError(f"{label} is not readable JSON") from error
    if not isinstance(value, dict):
        raise InitializeError(f"{label} must contain an object")
    return value


def approval_record(
    authorization: dict[str, Any], recorded_at: datetime
) -> dict[str, Any]:
    if recorded_at.tzinfo is None:
        raise InitializeError("recorded_at must be timezone aware")
    schema_path = (
        Path(__file__).resolve().parents[1]
        / "contracts"
        / "schemas"
        / "run-authorization.schema.json"
    )
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InitializeError("installed authorization schema is unavailable") from error
    errors = check_authorization._schema_errors(authorization, schema)
    errors.extend(check_authorization.validate_authorization(authorization))
    if errors:
        raise InitializeError(
            "approved authorization is invalid: " + "; ".join(sorted(set(errors)))
        )
    try:
        issued = check_authorization._timestamp(str(authorization["issued_at"]))
        expires = check_authorization._timestamp(str(authorization["expires_at"]))
    except (KeyError, ValueError) as error:
        raise InitializeError("authorization time boundary is invalid") from error
    if not issued <= recorded_at < expires:
        raise InitializeError("ledger approval time is outside authorization bounds")
    repository = authorization["repository"]
    payload = {
        "approval_id": authorization["authorization_id"],
        "kind": "run_authorization",
        "actor": authorization["actor"],
        "decision": "approved",
        "scope": f"run:{authorization['run_id']}:{authorization['delivery_target']}",
        "authorization_hash": check_authorization.authorization_hash(authorization),
        "delivery_target": authorization["delivery_target"],
        "selected_writer": authorization["selected_writer"],
        "contract_schema_id": authorization["contract_schema_id"],
        "contract_schema_sha256": authorization["contract_schema_sha256"],
        "health_profile": authorization["health_profile"],
        "health_attestation": authorization["health_attestation"],
        "resource_plan": authorization["resource_plan"],
        "repository_fingerprint": repository["fingerprint"],
        "repository_base_sha": repository["base_sha"],
        "allowed_paths": authorization["allowed_paths"],
        "acceptance_ids": authorization["acceptance_ids"],
        "issued_at": authorization["issued_at"],
        "expires_at": authorization["expires_at"],
        "action_grants": authorization["action_grants"],
    }
    return {
        "schema_version": "1.0.0",
        "run_id": authorization["run_id"],
        "sequence": 1,
        "recorded_at": recorded_at.astimezone(timezone.utc).isoformat().replace(
            "+00:00", "Z"
        ),
        "record_type": "approval",
        "payload": payload,
    }


def initialize(
    authorization_path: Path,
    ledger_path: Path,
    run_root: Path,
    *,
    harness_path: Path,
    coordinator_state: Path,
    recorded_at: datetime | None = None,
) -> dict[str, Any]:
    try:
        canonical_root = run_root.resolve(strict=True)
    except OSError as error:
        raise InitializeError("run root must already exist") from error
    if run_root.is_symlink() or not canonical_root.is_dir():
        raise InitializeError("run root must be a non-symlink directory")
    try:
        harness = check_authorization.resource_coordinator.load_trusted_harness(
            harness_path
        )
        check_authorization.resource_coordinator.validate_trusted_binding(
            coordinator_state, harness["resource_coordinator"]
        )
    except check_authorization.resource_coordinator.CoordinatorError as error:
        raise InitializeError(f"trusted harness is invalid: {error.code}") from error
    for candidate, label in (
        (harness_path, "harness"),
        (authorization_path, "authorization"),
        (Path(str(harness.get("private_policy_overlay"))), "private policy"),
    ):
        if (
            not candidate.is_absolute()
            or candidate.is_symlink()
            or candidate.parent.resolve(strict=True) != canonical_root
        ):
            raise InitializeError(
                f"{label} must be a non-symlink file directly under the private run root"
            )
    if authorization_path.resolve(strict=True) != Path(
        str(harness.get("run_authorization"))
    ).resolve(strict=True):
        raise InitializeError("authorization drifted from the trusted harness")
    if not ledger_path.is_absolute() or ledger_path.parent.resolve(strict=True) != canonical_root:
        raise InitializeError("ledger must be directly under the private run root")
    harness_ledger = Path(str(harness.get("run_ledger")))
    if (
        not harness_ledger.is_absolute()
        or harness_ledger.parent.resolve(strict=True) != canonical_root
        or harness_ledger.resolve(strict=False) != ledger_path.resolve(strict=False)
    ):
        raise InitializeError("ledger drifted from the trusted harness")
    if ledger_path.is_symlink():
        raise InitializeError("ledger must not be a symlink")
    authorization = _load_object(authorization_path, "authorization")
    record_time = recorded_at or datetime.now(timezone.utc)
    record = approval_record(authorization, record_time)
    schema_path = (
        Path(__file__).resolve().parents[1]
        / "contracts"
        / "schemas"
        / "ledger-record.schema.json"
    )
    schema = _load_object(schema_path, "installed ledger schema")
    schema_errors = check_authorization._schema_errors(record, schema)
    lifecycle_errors = check_authorization._standalone_ledger_lifecycle_errors([record])
    if schema_errors or lifecycle_errors:
        raise InitializeError(
            "initial ledger record failed installed contracts: "
            + "; ".join(sorted(set(schema_errors + lifecycle_errors)))
        )
    created = False
    if ledger_path.exists():
        mode = ledger_path.lstat()
        if (
            not stat.S_ISREG(mode.st_mode)
            or mode.st_nlink != 1
            or mode.st_mode & 0o077
        ):
            raise InitializeError("existing ledger identity or permissions are unsafe")
        try:
            existing_records = check_authorization.load_ledger(ledger_path)
        except (OSError, ValueError) as error:
            raise InitializeError("existing ledger cannot be adopted") from error
        if len(existing_records) != 1:
            raise InitializeError("existing ledger is not an unmodified initial approval")
        existing = existing_records[0]
        try:
            existing_time = check_authorization._timestamp(existing["recorded_at"])
            expected_existing = approval_record(authorization, existing_time)
        except (KeyError, TypeError, ValueError) as error:
            raise InitializeError("existing ledger approval is invalid") from error
        if existing != expected_existing:
            raise InitializeError("existing ledger approval drifted")
        record = existing
    else:
        descriptor = os.open(
            ledger_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            stat.S_IRUSR | stat.S_IWUSR,
        )
        created = True
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        directory_descriptor = os.open(canonical_root, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    try:
        _authorization, run_authority = (
            check_authorization.resource_coordinator.load_existing_run_authority(
                authorization_path,
                harness_path,
                harness,
                authorization["run_id"],
            )
        )
        registration = (
            check_authorization.resource_coordinator.register_run_authority(
                coordinator_state,
                authorization["run_id"],
                run_authority,
                now=check_authorization._timestamp(record["recorded_at"]),
            )
        )
    except check_authorization.resource_coordinator.CoordinatorError as error:
        raise InitializeError(
            f"coordinator refused run registration: {error.code}"
        ) from error
    return {
        "ledger": str(ledger_path.resolve(strict=True)),
        "run_id": authorization["run_id"],
        "sequence": 1,
        "authorization_hash": record["payload"]["authorization_hash"],
        "created": created,
        "registered": registration["registered"],
        "ledger_identity_sha256": registration["ledger_identity_sha256"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorization", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--coordinator-state", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        result = initialize(
            arguments.authorization,
            arguments.ledger,
            arguments.run_root,
            harness_path=arguments.harness,
            coordinator_state=arguments.coordinator_state,
        )
    except (InitializeError, OSError) as error:
        print(json.dumps({"status": "blocked", "reason": str(error)}, sort_keys=True))
        return 2
    print(json.dumps({"status": "ok", **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
