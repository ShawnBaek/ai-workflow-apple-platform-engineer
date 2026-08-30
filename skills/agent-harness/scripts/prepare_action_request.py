#!/usr/bin/env python3
"""Materialize one exact private action request from an approved grant and lease."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
from typing import Any

import check_authorization


class RequestError(ValueError):
    pass


def _load(path: Path, label: str, run_root: Path) -> Any:
    if (
        not path.is_absolute()
        or path.is_symlink()
        or not path.is_file()
        or path.parent.resolve(strict=True) != run_root
    ):
        raise RequestError(f"{label} must be a regular file directly under the run root")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RequestError(f"{label} is not readable JSON") from error


def prepare(
    *,
    authorization_path: Path,
    receipt_path: Path,
    descriptor_path: Path,
    health_report_path: Path,
    output_path: Path,
    run_root: Path,
    grant_id: str,
    target: str,
    paths: list[str],
    spec_checkpoint_path: Path | None = None,
    apple_action_path: Path | None = None,
    apple_observation_path: Path | None = None,
) -> dict[str, Any]:
    canonical_root = run_root.resolve(strict=True)
    if run_root.is_symlink() or not canonical_root.is_dir():
        raise RequestError("run root must be an existing non-symlink directory")
    if (
        not output_path.is_absolute()
        or output_path.parent.resolve(strict=True) != canonical_root
        or output_path.exists()
        or output_path.is_symlink()
    ):
        raise RequestError("output must be a new regular file directly under the run root")
    authorization = _load(authorization_path, "authorization", canonical_root)
    receipt = _load(receipt_path, "coordinator receipt", canonical_root)
    descriptor = _load(descriptor_path, "resource descriptor", canonical_root)
    health_report = _load(health_report_path, "health report", canonical_root)
    if not isinstance(authorization, dict):
        raise RequestError("authorization must contain an object")
    errors = check_authorization.validate_authorization(authorization)
    if errors:
        raise RequestError("authorization is invalid: " + "; ".join(sorted(set(errors))))
    grants = [
        grant for grant in authorization.get("action_grants", [])
        if isinstance(grant, dict) and grant.get("grant_id") == grant_id
    ]
    if len(grants) != 1:
        raise RequestError("grant_id must resolve exactly once")
    grant = grants[0]
    if grant.get("target") is not None and target != grant.get("target"):
        raise RequestError("target differs from the exact grant target")
    if not isinstance(receipt, dict) or set(receipt) != check_authorization.COORDINATOR_RECEIPT_FIELDS:
        raise RequestError("coordinator receipt shape is invalid")
    if receipt.get("owner_run_id") != authorization.get("run_id"):
        raise RequestError("coordinator receipt belongs to another run")
    if receipt.get("owner_actor") != authorization.get("selected_writer"):
        raise RequestError("coordinator receipt belongs to another writer")
    if receipt.get("resource_key") != grant.get("resource_key"):
        raise RequestError("coordinator receipt resource differs from the grant")
    if not isinstance(descriptor, dict) or not descriptor:
        raise RequestError("resource descriptor must be a non-empty object")
    try:
        descriptor = check_authorization.resource_coordinator.normalize_descriptor(
            str(receipt.get("resource")), descriptor
        )
        descriptor_sha256 = (
            check_authorization.resource_coordinator.descriptor_sha256(
                str(receipt.get("resource")), descriptor
            )
        )
    except check_authorization.resource_coordinator.CoordinatorError as error:
        raise RequestError(f"resource descriptor is invalid: {error.code}") from error
    if receipt.get("descriptor_sha256") != descriptor_sha256:
        raise RequestError("resource descriptor digest differs from the receipt")
    if not paths or len(paths) != len(set(paths)) or any(
        not isinstance(path, str) or not path for path in paths
    ):
        raise RequestError("paths must be non-empty unique strings")
    spec_checkpoint_sha256 = None
    if spec_checkpoint_path is not None:
        checkpoint = _load(spec_checkpoint_path, "Spec Kit checkpoint", canonical_root)
        spec_checkpoint_sha256 = check_authorization.canonical_sha256(checkpoint)
    apple_observation_sha256 = None
    if apple_observation_path is not None:
        observation = _load(apple_observation_path, "Apple observation", canonical_root)
        apple_observation_sha256 = check_authorization.canonical_sha256(observation)
    apple_action = None
    if apple_action_path is not None:
        apple_action = _load(apple_action_path, "Apple action", canonical_root)
    if str(grant.get("action", "")).startswith("apple.") and not isinstance(apple_action, dict):
        raise RequestError("Apple grants require --apple-action")
    if not str(grant.get("action", "")).startswith("apple.") and apple_action is not None:
        raise RequestError("non-Apple grants cannot include --apple-action")
    request = {
        "run_id": authorization["run_id"],
        "authorization_id": authorization["authorization_id"],
        "authorization_hash": check_authorization.authorization_hash(authorization),
        "delivery_target": authorization["delivery_target"],
        "system": grant["system"],
        "action": grant["action"],
        "target": target,
        "grant_id": grant["grant_id"],
        "idempotency_key": grant["idempotency_key"],
        "repository": authorization["repository"],
        "spec_snapshot_sha256": (
            authorization.get("spec_kit", {}).get("snapshot_sha256")
            if isinstance(authorization.get("spec_kit"), dict)
            else None
        ),
        "paths": paths,
        "apple": apple_action,
        "lease_id": receipt["lease_id"],
        "lease_owner": receipt["owner_actor"],
        "lease_resource": receipt["resource"],
        "lease_resource_key": receipt["resource_key"],
        "resource_descriptor": descriptor,
        "coordinator_receipt": receipt,
        "operation": grant["operation"],
        "operation_input": grant["operation_input"],
        "constraint_sha256": grant["constraint_sha256"],
        "phase": grant["phase"],
        "spec_checkpoint_sha256": spec_checkpoint_sha256,
        "apple_observation_sha256": apple_observation_sha256,
        "writer_actor": authorization["selected_writer"],
        "health_report_sha256": "sha256:"
        + check_authorization.canonical_sha256(health_report),
    }
    missing = check_authorization.REQUEST_FIELDS - set(request)
    extra = set(request) - check_authorization.REQUEST_FIELDS
    if missing or extra:
        raise RequestError("generated request field set drifted from the installed contract")
    descriptor_fd = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        stat.S_IRUSR | stat.S_IWUSR,
    )
    try:
        with os.fdopen(descriptor_fd, "w", encoding="utf-8") as handle:
            json.dump(request, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            output_path.unlink()
        except OSError:
            pass
        raise
    return request


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorization", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--resource-descriptor", type=Path, required=True)
    parser.add_argument("--health-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--grant-id", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--path", action="append", dest="paths", required=True)
    parser.add_argument("--spec-checkpoint", type=Path)
    parser.add_argument("--apple-action", type=Path)
    parser.add_argument("--apple-observation", type=Path)
    arguments = parser.parse_args()
    try:
        request = prepare(
            authorization_path=arguments.authorization,
            receipt_path=arguments.receipt,
            descriptor_path=arguments.resource_descriptor,
            health_report_path=arguments.health_report,
            output_path=arguments.output,
            run_root=arguments.run_root,
            grant_id=arguments.grant_id,
            target=arguments.target,
            paths=arguments.paths,
            spec_checkpoint_path=arguments.spec_checkpoint,
            apple_action_path=arguments.apple_action,
            apple_observation_path=arguments.apple_observation,
        )
    except (RequestError, OSError) as error:
        print(json.dumps({"status": "blocked", "reason": str(error)}, sort_keys=True))
        return 2
    print(json.dumps({
        "status": "ok",
        "output": str(arguments.output.resolve(strict=True)),
        "grant_id": request["grant_id"],
        "authorization_hash": request["authorization_hash"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
