from __future__ import annotations

import copy
import contextlib
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import validate_repository as validator  # noqa: E402
sys.path.insert(0, str(ROOT / "skills" / "agent-harness" / "scripts"))
import rag_index  # noqa: E402
import check_authorization  # noqa: E402
import initialize_run  # noqa: E402
import resource_coordinator  # noqa: E402
import materialize_private_template  # noqa: E402
import prepare_action_request  # noqa: E402
import verify_reservation  # noqa: E402
import spec_kit_snapshot  # noqa: E402
import resolve_project  # noqa: E402
sys.path.insert(0, str(ROOT / "skills" / "apple-development-health" / "scripts"))
import evaluate_health  # noqa: E402
sys.path.insert(0, str(ROOT / "skills" / "icon-composer" / "scripts"))
import watch_companion_upstream  # noqa: E402


def approved_envelope() -> dict:
    envelope = validator.load_json(
        ROOT / "tests" / "fixtures" / "run-authorization-approved.json"
    )
    envelope["$schema"] = (
        ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
        / "run-authorization.schema.json"
    ).resolve().as_uri()
    schema_id, schema_sha256 = (
        check_authorization.installed_authorization_schema_binding()
    )
    envelope["contract_schema_id"] = schema_id
    envelope["contract_schema_sha256"] = schema_sha256
    return envelope


def policy_overlay() -> dict:
    return validator.load_json(ROOT / "tests" / "fixtures" / "private-policy-overlay-approved.json")


def ledger_record(sequence: int, record_type: str, payload: dict, second: int) -> dict:
    return {
        "schema_version": "1.0.0",
        "run_id": "fixture-run-001",
        "sequence": sequence,
        "recorded_at": f"2026-01-01T00:00:{second:02d}Z",
        "record_type": record_type,
        "payload": payload,
    }


def fixture_resource_binding(envelope: dict, grant: dict) -> tuple[dict, dict]:
    resource = check_authorization._expected_lease_resource(grant["action"])
    descriptor = check_authorization.canonical_resource_descriptor(
        envelope, grant["action"]
    )
    receipt = {
        "coordinator_instance_id": "fixture-coordinator",
        "receipt_id": "fixture-receipt",
        "lease_id": "fixture-lease",
        "owner_run_id": envelope["run_id"],
        "owner_actor": envelope["selected_writer"],
        "resource": resource,
        "resource_key": resource_coordinator.canonical_resource_key(
            resource, descriptor
        ),
        "descriptor_sha256": resource_coordinator.descriptor_sha256(
            resource, descriptor
        ),
        "fencing_token": 1,
        "acquired_at": "2026-01-01T00:00:03Z",
        "expires_at": "2097-01-01T00:00:00Z",
    }
    return descriptor, receipt


def authorization_ledger(envelope: dict, grant: dict) -> list[dict]:
    digest = check_authorization.authorization_hash(envelope)
    descriptor, receipt = fixture_resource_binding(envelope, grant)
    return [
        ledger_record(
            1,
            "approval",
            {
                "approval_id": envelope["authorization_id"],
                "kind": "run_authorization",
                "actor": "fixture-user",
                "decision": "approved",
                "scope": "fixture:approved-delivery",
                "authorization_hash": digest,
                "delivery_target": envelope["delivery_target"],
                "selected_writer": envelope["selected_writer"],
                "contract_schema_id": envelope["contract_schema_id"],
                "contract_schema_sha256": envelope[
                    "contract_schema_sha256"
                ],
                "health_profile": envelope["health_profile"],
                "health_attestation": copy.deepcopy(envelope["health_attestation"]),
                "resource_plan": copy.deepcopy(envelope["resource_plan"]),
                "repository_fingerprint": envelope["repository"]["fingerprint"],
                "repository_base_sha": envelope["repository"]["base_sha"],
                "allowed_paths": copy.deepcopy(envelope["allowed_paths"]),
                "acceptance_ids": copy.deepcopy(envelope["acceptance_ids"]),
                "issued_at": envelope["issued_at"],
                "expires_at": envelope["expires_at"],
                "action_grants": copy.deepcopy(envelope["action_grants"]),
            },
            1,
        ),
        ledger_record(
            2,
            "time_interval",
            {
                "authorization_hash": digest,
                "kind": "active",
                "started_at": "2026-01-01T00:00:01Z",
                "ended_at": "2026-01-01T00:00:02Z",
                "reason": "authorize one exact operation",
            },
            2,
        ),
        ledger_record(
            3,
            "lease",
            {
                "lease_id": "fixture-lease",
                "action": "acquire",
                "owner": envelope["selected_writer"],
                "resource": check_authorization._expected_lease_resource(grant["action"]),
                "resource_key": grant["resource_key"],
                "resource_descriptor": descriptor,
                "coordinator_receipt": receipt,
                "branch": envelope["repository"]["branch"],
                "base_sha": envelope["repository"]["base_sha"],
                "pre_state_hash": "sha256:pre-state",
                "allowed_paths": copy.deepcopy(envelope["allowed_paths"]),
                "allowed_actions": [grant["action"]],
                "approval_id": envelope["authorization_id"],
                "acquired_at": "2026-01-01T00:00:03Z",
                "expires_at": "2097-01-01T00:00:00Z",
            },
            3,
        ),
    ]


def action_request(envelope: dict, grant: dict) -> dict:
    descriptor, receipt = fixture_resource_binding(envelope, grant)
    return {
        "run_id": envelope["run_id"],
        "authorization_id": envelope["authorization_id"],
        "authorization_hash": check_authorization.authorization_hash(envelope),
        "delivery_target": envelope["delivery_target"],
        "system": grant["system"],
        "action": grant["action"],
        "operation": grant["operation"],
        "operation_input": copy.deepcopy(grant["operation_input"]),
        "constraint_sha256": grant["constraint_sha256"],
        "phase": grant["phase"],
        "target": grant.get("target"),
        "grant_id": grant["grant_id"],
        "idempotency_key": grant["idempotency_key"],
        "repository": copy.deepcopy(envelope["repository"]),
        "spec_snapshot_sha256": None,
        "spec_checkpoint_sha256": None,
        "paths": copy.deepcopy(envelope["allowed_paths"]),
        "apple": None,
        "apple_observation_sha256": None,
        "health_report_sha256": envelope["health_attestation"]["report_sha256"],
        "lease_id": "fixture-lease",
        "lease_owner": envelope["selected_writer"],
        "writer_actor": envelope["selected_writer"],
        "lease_resource": check_authorization._expected_lease_resource(grant["action"]),
        "lease_resource_key": grant["resource_key"],
        "resource_descriptor": descriptor,
        "coordinator_receipt": receipt,
    }


def live_repository(envelope: dict) -> dict:
    return {
        **copy.deepcopy(envelope["repository"]),
        "head_sha": "2" * 40,
        "staged_paths": copy.deepcopy(envelope["allowed_paths"]),
        "staged_diff_sha256": "3" * 64,
        "outgoing_paths": copy.deepcopy(envelope["allowed_paths"]),
    }


def live_action_guards(envelope: dict) -> dict:
    return {
        "selected_writer": envelope["selected_writer"],
        "verified_health_attestation": copy.deepcopy(
            envelope["health_attestation"]
        ),
    }


def fixture_run_authority(
    envelope: dict | None = None,
    *,
    run_id: str | None = None,
    actor: str = "codex",
    harness_sha256: str = "sha256:" + "a" * 64,
    ledger_path: Path | None = None,
) -> dict:
    resolved_run = envelope["run_id"] if envelope is not None else str(run_id)
    if ledger_path is not None:
        ledger_fields = resource_coordinator.ledger_binding(
            ledger_path,
            expected_run_id=resolved_run,
            expected_authorization_hash=(
                check_authorization.authorization_hash(envelope)
                if envelope is not None
                else None
            ),
        )
    else:
        ledger_fields = {
            "ledger_path": f"/fixture/private/{resolved_run}/ledger.jsonl",
            "ledger_identity_sha256": "sha256:" + hashlib.sha256(
                f"ledger:{resolved_run}:{actor}".encode()
            ).hexdigest(),
            "ledger_approval_sha256": "sha256:" + hashlib.sha256(
                f"approval:{resolved_run}:{actor}".encode()
            ).hexdigest(),
        }
    return {
        "authorization_hash": (
            check_authorization.authorization_hash(envelope)
            if envelope is not None
            else "sha256:" + hashlib.sha256(
                f"authorization:{run_id}:{actor}".encode()
            ).hexdigest()
        ),
        "selected_writer": actor,
        "harness_sha256": harness_sha256,
        "authorization_issued_at": (
            envelope["issued_at"] if envelope is not None else "2000-01-01T00:00:00Z"
        ),
        "authorization_expires_at": (
            envelope["expires_at"] if envelope is not None else "2099-01-01T00:00:00Z"
        ),
        **ledger_fields,
    }


def fixture_patch_manifest(envelope: dict) -> dict:
    return {
        "version": "patch_identity_v1",
        "base_sha": envelope["repository"]["base_sha"],
        "records": [
            {
                "path": envelope["allowed_paths"][0],
                "mode": "100644",
                "state": "modified",
                "content_sha256": "sha256:" + "9" * 64,
            }
        ],
    }


def full_pr_ready_ledger(envelope: dict) -> list[dict]:
    """Build one complete, schema-valid main workflow replay fixture."""
    workflow = validator.load_json(
        ROOT / "skills" / "agent-harness" / "contracts" / "workflow.json"
    )
    manifest = fixture_patch_manifest(envelope)
    patch_identity = check_authorization.patch_identity_v1(manifest)
    authorization_digest = check_authorization.authorization_hash(envelope)
    approval_payload = authorization_ledger(
        envelope, envelope["action_grants"][0]
    )[0]["payload"]
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    records: list[dict] = []
    active: dict[str, dict] = {}
    produced_targets: dict[str, str] = {}
    fencing_token = 0

    def stamp(value: datetime) -> str:
        return value.isoformat().replace("+00:00", "Z")

    def append(record_type: str, payload: dict) -> dict:
        sequence = len(records) + 1
        record = {
            "schema_version": "1.0.0",
            "run_id": envelope["run_id"],
            "sequence": sequence,
            "recorded_at": stamp(base + timedelta(seconds=sequence)),
            "record_type": record_type,
            "payload": payload,
        }
        records.append(record)
        return record

    def append_evidence(kind: str, specific: dict) -> None:
        sequence = len(records) + 1
        observed_at = base + timedelta(seconds=sequence)
        tool_tuple = {
            "provider": "fixture-provider",
            "tool": "fixture-tool",
            "tool_version": "1.0",
            "command_or_call": "fixture verification call",
            "started_at": stamp(observed_at - timedelta(milliseconds=500)),
            "ended_at": stamp(observed_at),
            "exit_status": 0,
            **specific,
        }
        payload = {
            "evidence_id": f"evidence-{kind}",
            "evidence_kind": kind,
            "acceptance_ids": copy.deepcopy(envelope["acceptance_ids"]),
            "patch_identity": patch_identity,
            "patch_manifest": copy.deepcopy(manifest),
            "repository_fingerprint": envelope["repository"]["fingerprint"],
            "tool_tuple": tool_tuple,
            "observed_result": f"{kind} passed",
            "outcome": "passed",
        }
        if kind == "commit_equivalence":
            payload["local_sha"] = "e" * 40
            payload["remote_sha"] = "e" * 40
        append("evidence", payload)

    def descriptor(resource: str) -> dict:
        action = (
            "git.commit"
            if resource == resource_coordinator.SOURCE_WRITER
            else "github.issue.update"
        )
        return check_authorization.canonical_resource_descriptor(envelope, action)

    def acquire(node: dict) -> dict:
        nonlocal fencing_token
        resource = node["resource"]
        resource_descriptor = descriptor(resource)
        resource_key = resource_coordinator.canonical_resource_key(
            resource, resource_descriptor
        )
        fencing_token += 1
        lease_id = f"lease-{node['id']}"
        acquired_at = stamp(base + timedelta(seconds=len(records) + 1))
        receipt = {
            "coordinator_instance_id": "fixture-coordinator",
            "receipt_id": f"receipt-{node['id']}",
            "lease_id": lease_id,
            "owner_run_id": envelope["run_id"],
            "owner_actor": envelope["selected_writer"],
            "resource": resource,
            "resource_key": resource_key,
            "descriptor_sha256": resource_coordinator.descriptor_sha256(
                resource, resource_descriptor
            ),
            "fencing_token": fencing_token,
            "acquired_at": acquired_at,
            "expires_at": "2096-01-01T00:00:00Z",
        }
        actions = {
            "claim_github_tracking": ["github.issue.update"],
            "claim_github_in_progress": ["github.issue.update"],
            "claim_delivery_writer": ["git.commit"],
            "claim_github_mutation": [
                "git.push",
                "github.pr.create",
                "github.issue.update",
                "github.evidence.publish",
                "github.checks.wait",
            ],
        }
        lease = {
            "resource": resource,
            "resource_key": resource_key,
            "resource_descriptor": resource_descriptor,
            "lease_id": lease_id,
            "coordinator_receipt": receipt,
            "protects": copy.deepcopy(node["protects"]),
            "node": node,
        }
        append(
            "lease",
            {
                "lease_id": lease_id,
                "action": "acquire",
                "owner": envelope["selected_writer"],
                "resource": resource,
                "resource_key": resource_key,
                "resource_descriptor": resource_descriptor,
                "coordinator_receipt": receipt,
                "branch": envelope["repository"]["branch"],
                "base_sha": envelope["repository"]["base_sha"],
                "pre_state_hash": "sha256:pre-state",
                "allowed_paths": copy.deepcopy(envelope["allowed_paths"]),
                "allowed_actions": actions.get(node["id"], []),
                "protects": copy.deepcopy(node["protects"]),
                "approval_id": envelope["authorization_id"],
                "acquired_at": acquired_at,
                "expires_at": receipt["expires_at"],
            },
        )
        active[node["id"]] = lease
        return lease

    def release(node: dict) -> dict:
        acquire_id, lease = next(
            (key, value)
            for key, value in active.items()
            if value["resource"] == node["resource"]
            and value["protects"] == node["protects"]
        )
        released_at = stamp(base + timedelta(seconds=len(records) + 1))
        receipt = lease["coordinator_receipt"]
        append(
            "lease",
            {
                "lease_id": lease["lease_id"],
                "action": "release",
                "owner": envelope["selected_writer"],
                "resource": lease["resource"],
                "resource_key": lease["resource_key"],
                "resource_descriptor": lease["resource_descriptor"],
                "coordinator_receipt": receipt,
                "protects": copy.deepcopy(lease["protects"]),
                "coordinator_release_confirmation": {
                    "coordinator_instance_id": receipt["coordinator_instance_id"],
                    "release_id": f"release-{lease['lease_id']}",
                    "receipt_id": receipt["receipt_id"],
                    "lease_id": lease["lease_id"],
                    "fencing_token": receipt["fencing_token"],
                    "released_at": released_at,
                },
                "released_at": released_at,
                "post_state_hash": "sha256:post-state",
            },
        )
        del active[acquire_id]
        return lease

    def append_external_write(grant: dict) -> None:
        resource = check_authorization._expected_lease_resource(grant["action"])
        matches = [lease for lease in active.values() if lease["resource"] == resource]
        if len(matches) != 1:
            raise AssertionError(f"fixture lacks one active {resource} lease")
        lease = matches[0]
        reservation_id = f"reservation-{grant['grant_id']}"
        dispatch_id = f"dispatch-{grant['grant_id']}"
        target = grant.get("target") or produced_targets[grant["target_from_grant_id"]]
        binding = {
            "authorization_hash": authorization_digest,
            "grant_id": grant["grant_id"],
            "idempotency_key": grant["idempotency_key"],
            "system": grant["system"],
            "action": grant["action"],
            "operation": grant["operation"],
            "operation_input": copy.deepcopy(grant["operation_input"]),
            "action_request_sha256": "sha256:" + "a" * 64,
            "constraint_sha256": grant["constraint_sha256"],
            "phase": grant["phase"],
            "target": target,
            "lease_id": lease["lease_id"],
            "lease_owner": envelope["selected_writer"],
            "writer_actor": envelope["selected_writer"],
            "resource": lease["resource"],
            "resource_key": lease["resource_key"],
            "resource_descriptor": lease["resource_descriptor"],
            "coordinator_receipt": lease["coordinator_receipt"],
            "spec_checkpoint_sha256": None,
            "apple_observation_sha256": None,
            "apple_observation_state_sha256": None,
            "health_report_sha256": envelope["health_attestation"][
                "report_sha256"
            ],
            "paths": copy.deepcopy(envelope["allowed_paths"]),
            "repository_observation_sha256": None,
        }
        append("grant_reservation", {"reservation_id": reservation_id, **binding})
        append(
            "grant_dispatch",
            {
                "dispatch_id": dispatch_id,
                "reservation_id": reservation_id,
                "coordinator_receipt": lease["coordinator_receipt"],
                "health_report_sha256": envelope["health_attestation"][
                    "report_sha256"
                ],
                "dispatch_deadline": stamp(
                    base + timedelta(seconds=len(records) + 60)
                ),
            },
        )
        outcome = {
            "system": grant["system"],
            "action": grant["action"],
            "operation": grant["operation"],
            "operation_input": copy.deepcopy(grant["operation_input"]),
            "constraint_sha256": grant["constraint_sha256"],
            "phase": grant["phase"],
            "resource": lease["resource"],
            "resource_key": lease["resource_key"],
            "resource_descriptor": lease["resource_descriptor"],
            "coordinator_receipt": lease["coordinator_receipt"],
            "lease_id": lease["lease_id"],
            "lease_owner": envelope["selected_writer"],
            "writer_actor": envelope["selected_writer"],
            "target": target,
            "outcome": "succeeded",
            "authorization_hash": authorization_digest,
            "grant_id": grant["grant_id"],
            "idempotency_key": grant["idempotency_key"],
            "reservation_id": reservation_id,
            "dispatch_id": dispatch_id,
            "spec_checkpoint_sha256": None,
            "apple_observation_sha256": None,
            "health_report_sha256": envelope["health_attestation"][
                "report_sha256"
            ],
        }
        if grant.get("produces_target_kind"):
            outcome["output_target"] = "example/repository:pr:42"
            produced_targets[grant["grant_id"]] = outcome["output_target"]
        append("external_write", outcome)

    grant_by_node = {
        "ensure_issue_ready": "grant-issue-ready",
        "mark_issue_in_progress": "grant-issue-progress",
        "commit": "grant-commit",
        "push": "grant-push",
        "create_pr": "grant-pr",
        "mark_issue_in_review": "grant-issue-review",
        "publish_evidence": "grant-pr-evidence",
        "checks": "grant-pr-checks",
    }
    evidence_by_node = {
        "verify": (
            "acceptance",
            {
                "verification_scope": "minimum-sufficient",
                "evidence_layer": "repository_contract",
                "platform": "repository",
                "destination": "local contract suite",
                "coverage": [
                    {
                        "acceptance_id": "AC-1",
                        "observable_contract": "authorized contract stays valid",
                        "prevented_failure": "invalid terminal evidence",
                        "unique_path": "terminal contract validation",
                        "result": "passed",
                    }
                ],
                "artifacts": [],
                "omitted_checks": ["runtime UI not in scope"],
            },
        ),
        "review": ("review", {"staged_diff_sha256": "d" * 64}),
        "verify_remote_sha": (
            "commit_equivalence",
            {"comparison": "commit_tree_and_changed_paths"},
        ),
        "verify_published_evidence": (
            "publication",
            {"viewable": True, "readback_sha256": "sha256:" + "f" * 64},
        ),
        "checks": (
            "checks_readback",
            {
                "required_checks_satisfied": True,
                "readback_sha256": "sha256:" + "1" * 64,
            },
        ),
    }
    grants = {grant["grant_id"]: grant for grant in envelope["action_grants"]}
    for node in workflow["nodes"]:
        node_id = node["id"]
        if node_id == "bind_run_authorization":
            append("approval", copy.deepcopy(approval_payload))
        if node_id in evidence_by_node:
            append_evidence(*evidence_by_node[node_id])
        lease: dict | None = None
        if node.get("lease_action") == "acquire":
            lease = acquire(node)
        if node_id in grant_by_node:
            append_external_write(grants[grant_by_node[node_id]])
        if node.get("lease_action") == "release":
            lease = release(node)
        node_payload = {"node_id": node_id, "status": "passed"}
        if node_id in check_authorization.PATCH_BOUND_NODES:
            node_payload.update(
                {
                    "patch_identity": patch_identity,
                    "patch_manifest": copy.deepcopy(manifest),
                }
            )
        if node.get("lease_action") in {"acquire", "release"}:
            if lease is None:
                raise AssertionError("fixture lease binding is missing")
            node_payload.update(
                {
                    "lease_id": lease["lease_id"],
                    "lease_resource": lease["resource"],
                    "lease_resource_key": lease["resource_key"],
                }
            )
        append("node", node_payload)
    return records


def health_report(
    profile: str,
    *,
    selected_components: list[str] | None = None,
    observed_at: str = "2026-08-29T00:00:00Z",
) -> dict:
    selected = selected_components or []
    required_ids = set(evaluate_health.PROFILE_REQUIREMENTS[profile])
    required_ids.update(
        evaluate_health.COMPONENT_REQUIREMENTS[item] for item in selected
    )

    def category(check_id: str) -> str:
        prefix = check_id.split(".", 1)[0]
        return {
            "apple": "apple_account",
            "app": "xcode",
            "companion_upstream": "companion_upstream",
            "repository": "repository",
            "agent": "agent",
            "cli": "cli",
            "github": "github",
            "spec_kit": "spec_kit",
            "xcode": "xcode",
            "simulator": "simulator",
            "testflight": "testflight",
            "mcp": "mcp",
            "local_llm": "local_llm",
        }[prefix]

    report = {
        "schema_version": "1.0.0",
        "profile": profile,
        "observed_at": observed_at,
        "authoritative_targets": {"repository": "/example"},
        "agent_skill_manifest": {
            "required_skills": [
                "agent-harness",
                "apple-development-health",
                "git-workflow",
                "github-projects",
                "native-app-lead",
            ],
            "expected_bundle_sha256": "sha256:" + "7" * 64,
            "clients": [
                {
                    "client": "codex",
                    "root_path_sha256": "sha256:" + "8" * 64,
                    "bundle_sha256": "sha256:" + "7" * 64,
                    "skills": [
                        {
                            "name": name,
                            "entry_kind": "directory",
                            "resolved_path_sha256": "sha256:" + "6" * 64,
                            "sha256": "sha256:" + "9" * 64,
                        }
                        for name in [
                            "agent-harness",
                            "apple-development-health",
                            "git-workflow",
                            "github-projects",
                            "native-app-lead",
                        ]
                    ],
                }
            ],
        },
        "resource_coordinator_observation": {
            "state_path_sha256": "sha256:" + "4" * 64,
            "coordinator_instance_id": "fixture-coordinator",
            "state_schema_version": 1,
            "migration_bootstrap_confirmed": True,
            "script_sha256": "sha256:" + "5" * 64,
            "contract_bundle_sha256": "sha256:" + "6" * 64,
            "active_lease_count": 0,
        },
        "selected_components": selected,
        "required_check_ids": sorted(required_ids),
        "checks": [
            {
                "id": check_id,
                "category": category(check_id),
                "required": True,
                "status": "healthy",
                "summary": f"{check_id} is healthy",
                "evidence": ["sanitized observation"],
            }
            for check_id in sorted(required_ids)
        ],
    }
    if "project_registry" in selected:
        report["project_registry_resolution"] = {
            "status": "resolved",
            "reason_code": "registry_candidate",
            "resolver_version": "1.0.0",
            "registry_sha256": "sha256:" + "1" * 64,
            "worktree_authorized": False,
            "candidate": {
                "project_id": "project-one",
                "checkout_id": "primary",
                "canonical_root": "/example",
                "remote_fingerprint": "sha256:" + "2" * 64,
                "kind": "primary",
                "xcode_containers": [],
            },
            "warnings": [],
        }
    return report


def evaluate_health_fixture(
    report: dict, now: datetime | None = None
) -> tuple[dict, list[str]]:
    """Mark only evaluator-owned fixture checks as recomputed for semantic tests."""
    observed = set(report.get("required_check_ids", [])) & set(
        evaluate_health.EVALUATOR_OWNED_CHECKS
    )
    return evaluate_health.evaluate(
        report, now=now, evaluator_observed_check_ids=observed
    )


def bind_resource_coordinator(
    harness: dict, report: dict, directory: Path
) -> Path:
    harness.setdefault("mode", "codex")
    harness.setdefault("selected_writer", "codex")
    harness.setdefault("health_profile", report["profile"])
    harness.setdefault("health_components", report.get("selected_components", []))
    harness.setdefault(
        "agent_skills",
        {
            "task_skills": ["native-app-lead"],
            "expected_bundle_sha256": "sha256:" + "0" * 64,
            "installations": {
                "codex": {"collection_root": str(ROOT / "skills")},
                "claude": None,
            },
        },
    )
    manifest, manifest_errors = evaluate_health.observe_agent_skills(
        harness, enforce_expected=False
    )
    if manifest_errors or manifest is None or not manifest["clients"]:
        raise AssertionError(manifest_errors)
    harness["agent_skills"]["expected_bundle_sha256"] = manifest["clients"][0][
        "bundle_sha256"
    ]
    manifest, manifest_errors = evaluate_health.observe_agent_skills(harness)
    if manifest_errors or manifest is None:
        raise AssertionError(manifest_errors)
    report["agent_skill_manifest"] = manifest
    state = directory / "resource-coordinator.json"
    resource_coordinator.bootstrap_state(state, legacy_leases_quiesced=True)
    status = resource_coordinator.status(state)
    script = (
        ROOT / "skills" / "agent-harness" / "scripts" / "resource_coordinator.py"
    )
    harness["resource_coordinator"] = {
        "state_path": str(state),
        "coordinator_instance_id": status["coordinator_instance_id"],
        "script_sha256": "sha256:" + hashlib.sha256(script.read_bytes()).hexdigest(),
        "contract_bundle_sha256": resource_coordinator.contract_bundle_sha256(
            ROOT / "skills" / "agent-harness"
        ),
    }
    observation, errors = evaluate_health.observe_resource_coordinator(harness)
    if errors or observation is None:
        raise AssertionError(errors)
    report["resource_coordinator_observation"] = observation
    return state


def normalized_text(path: Path) -> str:
    return " ".join(path.read_text(encoding="utf-8").split())


def testflight_envelope() -> dict:
    """A complete continuation envelope derived from the reviewed PR fixture."""
    envelope = approved_envelope()
    envelope["delivery_target"] = "testflight_distributed"
    envelope["health_profile"] = "testflight_distributed"
    envelope["health_attestation"]["profile"] = "testflight_distributed"
    envelope["apple"] = {
        "account_guard_ref": "private-guard",
        "team_id": "TEAM123",
        "app_id": "123",
        "bundle_id": "com.example.app",
        "platform": "ios",
        "version_policy": {"mode": "exact", "value": "1.2.3"},
        "build_policy": {"mode": "next_after_live", "baseline": "41"},
        "artifact_policy": "fresh_archive_from_reviewed_pr_commit",
        "internal_group_ids": ["group-a"],
    }

    def grant(grant_id: str, system: str, action: str, operation: str,
              operation_input: dict, phase: str, target: str) -> dict:
        return {
            "grant_id": grant_id, "system": system, "action": action,
            "operation": operation, "operation_input": operation_input,
            "constraint_sha256": check_authorization.canonical_sha256(operation_input),
            "resource_key": check_authorization.canonical_lease_resource_key(envelope, action),
            "phase": phase, "target": target, "single_use": True,
            "idempotency_key": f"fixture-{grant_id}",
        }

    envelope["action_grants"].extend([
        grant("upload-evidence", "github", "github.evidence.publish",
              "publish_testflight_upload_evidence", {"artifact_policy": "sanitized_testflight_upload_evidence"},
              "testflight_upload", "example/repository:pr:1"),
        grant("distribution-evidence", "github", "github.evidence.publish",
              "publish_testflight_distribution_evidence", {"artifact_policy": "sanitized_testflight_distribution_evidence"},
              "testflight_distribution", "example/repository:pr:1"),
        grant("upload", "apple", "apple.testflight.upload", "upload_verified_archive",
              {"artifact_policy": "fresh_archive_from_reviewed_pr_commit"}, "testflight_upload", "app:123"),
        grant("processing", "apple", "apple.testflight.processing.wait", "wait_bounded_processing",
              {"timeout_minutes": 45, "max_transient_retries": 1}, "testflight_upload", "app:123:processing"),
        grant("upload-readback", "apple", "apple.testflight.readback", "verify_uploaded_build",
              {"readback": "uploaded_build"}, "testflight_upload", "app:123:upload"),
        grant("distribution", "apple", "apple.testflight.distribute_internal", "distribute_named_internal_group",
              {"group_id": "group-a"}, "testflight_distribution", "app:123:group:group-a"),
        grant("distribution-readback", "apple", "apple.testflight.readback", "verify_internal_distribution",
              {"readback": "internal_group_build", "group_id": "group-a"}, "testflight_distribution", "app:123:group:group-a"),
    ])
    for grant_id in ("upload-evidence", "distribution-evidence"):
        evidence_grant = next(item for item in envelope["action_grants"] if item["grant_id"] == grant_id)
        evidence_grant.pop("target")
        evidence_grant["target_from_grant_id"] = "grant-pr"
    return envelope


class RepositoryContractTests(unittest.TestCase):
    def test_repository_contracts(self) -> None:
        self.assertEqual([], validator.validate_repository())

    def test_cycle_is_rejected(self) -> None:
        nodes = [
            {"id": "a", "requires": ["b"]},
            {"id": "b", "requires": ["a"]},
        ]
        self.assertTrue(any("cycle" in error for error in validator.validate_dag(nodes)))

    def test_missing_dependency_is_rejected(self) -> None:
        errors = validator.validate_dag([{"id": "a", "requires": ["missing"]}])
        self.assertTrue(any("missing dependency" in error for error in errors))

    def test_workflow_schema_rejects_wrong_type_and_additional_property(self) -> None:
        contract = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "workflow.json"
        )
        schema = validator.load_json(
            ROOT
            / "skills"
            / "agent-harness"
            / "contracts"
            / "schemas"
            / "workflow.schema.json"
        )
        contract["nodes"][-1]["terminal"] = "yes"
        contract["nodes"][-1]["unexpected"] = True
        contract.pop("$schema")
        errors = validator.validate_json_schema(contract, schema)
        self.assertTrue(any("expected type" in error for error in errors))
        self.assertTrue(any("additional property" in error for error in errors))

    def test_private_templates_materialize_with_resolvable_installed_schema_uri(self) -> None:
        pairs = [
            (
                ROOT / "skills" / "agent-harness" / "templates" / "harness.json",
                ROOT / "skills" / "agent-harness" / "contracts" / "schemas" / "harness.schema.json",
            ),
            (
                ROOT / "skills" / "agent-harness" / "templates" / "run-authorization.json",
                ROOT / "skills" / "agent-harness" / "contracts" / "schemas" / "run-authorization.pending.schema.json",
            ),
            (
                ROOT / "skills" / "agent-harness" / "templates" / "private-policy-overlay.json",
                ROOT / "skills" / "agent-harness" / "contracts" / "schemas" / "private-policy-overlay.schema.json",
            ),
            (
                ROOT / "skills" / "agent-harness" / "templates" / "project-registry.local.example.json",
                ROOT / "skills" / "agent-harness" / "contracts" / "schemas" / "project-registry.schema.json",
            ),
            (
                ROOT / "skills" / "apple-development-health" / "templates" / "health-observations.json",
                ROOT / "skills" / "apple-development-health" / "contracts" / "health-report.schema.json",
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            private_root = Path(directory)
            for index, (template, schema) in enumerate(pairs):
                output = private_root / f"private-{index}.json"
                result = materialize_private_template.materialize(
                    template.resolve(), schema.resolve(), output.resolve()
                )
                document = validator.load_json(output)
                self.assertEqual(schema.resolve().as_uri(), document["$schema"])
                self.assertEqual(schema.resolve().as_uri(), result["schema_uri"])
                self.assertEqual(
                    [],
                    check_authorization._schema_errors(
                        document, validator.load_json(schema)
                    ),
                )
                self.assertEqual(0o600, output.stat().st_mode & 0o777)

            with self.assertRaisesRegex(
                materialize_private_template.MaterializeError,
                "already exists",
            ):
                materialize_private_template.materialize(
                    pairs[0][0].resolve(), pairs[0][1].resolve(), output.resolve()
                )

            authorization_path = private_root / "authorization.json"
            authorization_path.write_text(
                json.dumps(approved_envelope(), indent=2) + "\n", encoding="utf-8"
            )
            finalized = materialize_private_template.materialize(
                authorization_path.resolve(),
                (
                    ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
                    / "run-authorization.schema.json"
                ).resolve(),
                authorization_path.resolve(),
                replace=True,
            )
            self.assertEqual(
                check_authorization.installed_authorization_schema_binding()[1],
                finalized["contract_schema_sha256"],
            )
            self.assertEqual(
                [],
                check_authorization.validate_authorization(
                    validator.load_json(authorization_path)
                ),
            )

        stale = approved_envelope()
        stale["$schema"] = (
            ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
            / "run-authorization.pending.schema.json"
        ).resolve().as_uri()
        self.assertEqual([], check_authorization.validate_authorization(stale))
        self.assertEqual(
            check_authorization.authorization_hash(approved_envelope()),
            check_authorization.authorization_hash(stale),
        )
        mixed = copy.deepcopy(stale)
        mixed["contract_schema_sha256"] = "sha256:" + "0" * 64
        self.assertTrue(
            any(
                "schema content drifted" in error
                for error in check_authorization.validate_authorization(mixed)
            )
        )

    def test_installed_schema_checker_matches_repository_keywords(self) -> None:
        harness = validator.load_json(
            ROOT / "skills" / "agent-harness" / "templates" / "harness.json"
        )
        schema = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
            / "harness.schema.json"
        )
        harness["spec_kit"]["enabled"] = True
        harness["health_components"] = []
        repository_errors = validator.validate_json_schema(harness, schema)
        installed_errors = check_authorization._schema_errors(harness, schema)
        self.assertTrue(any("contain" in error for error in repository_errors))
        self.assertTrue(any("contain" in error for error in installed_errors))

        probe_harness = validator.load_json(
            ROOT / "skills" / "agent-harness" / "templates" / "harness.json"
        )
        probe_harness["apple_observation_probe"] = {
            "executable": "/private/asc-observation-probe",
            "executable_sha256": "sha256:" + "a" * 64,
            "output_contract": "apple_observation_v1",
            "timeout_seconds": 20,
        }
        self.assertEqual(
            [], validator.validate_json_schema(probe_harness, schema)
        )
        probe_harness["apple_observation_probe"]["executable"] = "relative"
        self.assertTrue(validator.validate_json_schema(probe_harness, schema))

        min_properties_schema = {"type": "object", "minProperties": 1}
        self.assertTrue(validator.validate_json_schema({}, min_properties_schema))
        self.assertTrue(check_authorization._schema_errors({}, min_properties_schema))

        for numeric_schema in (
            {"type": "integer", "minimum": 1},
            {"enum": [1]},
            {"const": 1},
        ):
            self.assertTrue(validator.validate_json_schema(True, numeric_schema))
            self.assertTrue(
                check_authorization._schema_errors(True, numeric_schema)
            )

    def test_private_run_initialization_and_action_request_are_deterministic(self) -> None:
        envelope = approved_envelope()
        grant = next(
            item for item in envelope["action_grants"]
            if item["grant_id"] == "grant-issue-ready"
        )
        descriptor = {
            "repository_fingerprint": envelope["repository"]["fingerprint"],
            "remote_repository": "Example/Repository.git",
        }
        receipt = {
            "coordinator_instance_id": "fixture-coordinator",
            "receipt_id": "receipt-1",
            "lease_id": "lease-1",
            "owner_run_id": envelope["run_id"],
            "owner_actor": envelope["selected_writer"],
            "resource": "github_external_mutation",
            "resource_key": grant["resource_key"],
            "descriptor_sha256": resource_coordinator.descriptor_sha256(
                resource_coordinator.GITHUB, descriptor
            ),
            "fencing_token": 1,
            "acquired_at": "2026-01-01T00:00:01Z",
            "expires_at": "2098-01-01T00:00:00Z",
        }
        with tempfile.TemporaryDirectory() as directory:
            run_root = Path(directory).resolve()
            authorization_path = run_root / "authorization.json"
            receipt_path = run_root / "receipt.json"
            descriptor_path = run_root / "descriptor.json"
            health_path = run_root / "health.json"
            ledger_path = run_root / "ledger.jsonl"
            request_path = run_root / "request.json"
            policy_path = run_root / "policy.json"
            harness_path = run_root / "harness.json"
            coordinator_state = run_root / "coordinator.json"
            for path, payload in (
                (authorization_path, envelope),
                (receipt_path, receipt),
                (descriptor_path, descriptor),
                (health_path, {"overall_status": "healthy"}),
            ):
                path.write_text(json.dumps(payload), encoding="utf-8")
            policy_path.write_text(json.dumps(policy_overlay()), encoding="utf-8")
            resource_coordinator.bootstrap_state(
                coordinator_state, legacy_leases_quiesced=True
            )
            harness = validator.load_json(
                ROOT / "skills" / "agent-harness" / "templates" / "harness.json"
            )
            harness.update(
                {
                    "$schema": (
                        ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
                        / "harness.schema.json"
                    ).resolve().as_uri(),
                    "authoritative_root": str(ROOT),
                    "xcode_container": str(ROOT / "Fixture.xcodeproj"),
                    "private_policy_overlay": str(policy_path),
                    "run_authorization": str(authorization_path),
                    "run_ledger": str(ledger_path),
                    "resource_coordinator": {
                        "state_path": str(coordinator_state),
                        "coordinator_instance_id": resource_coordinator.status(
                            coordinator_state
                        )["coordinator_instance_id"],
                        "script_sha256": "sha256:" + hashlib.sha256(
                            (
                                ROOT / "skills" / "agent-harness" / "scripts"
                                / "resource_coordinator.py"
                            ).read_bytes()
                        ).hexdigest(),
                        "contract_bundle_sha256": resource_coordinator.contract_bundle_sha256(
                            ROOT / "skills" / "agent-harness"
                        ),
                    },
                }
            )
            harness["agent_skills"]["installations"]["codex"] = {
                "collection_root": str(ROOT / "skills")
            }
            harness_path.write_text(json.dumps(harness), encoding="utf-8")
            initialized = initialize_run.initialize(
                authorization_path,
                ledger_path,
                run_root,
                harness_path=harness_path,
                coordinator_state=coordinator_state,
                recorded_at=datetime(2026, 1, 1, 0, 0, 2, tzinfo=timezone.utc),
            )
            self.assertEqual(1, initialized["sequence"])
            records = check_authorization.load_ledger(ledger_path)
            self.assertEqual([], check_authorization._ledger_contract_errors(records))
            self.assertEqual(0o600, ledger_path.stat().st_mode & 0o777)
            request = prepare_action_request.prepare(
                authorization_path=authorization_path,
                receipt_path=receipt_path,
                descriptor_path=descriptor_path,
                health_report_path=health_path,
                output_path=request_path,
                run_root=run_root,
                grant_id=grant["grant_id"],
                target=grant["target"],
                paths=["Sources"],
            )
            self.assertEqual(check_authorization.REQUEST_FIELDS, set(request))
            self.assertEqual(grant["constraint_sha256"], request["constraint_sha256"])
            self.assertEqual(receipt, request["coordinator_receipt"])
            self.assertEqual(
                "example/repository",
                request["resource_descriptor"]["remote_repository"],
            )
            self.assertEqual(0o600, request_path.stat().st_mode & 0o777)
            with self.assertRaisesRegex(
                prepare_action_request.RequestError, "output must be a new"
            ):
                prepare_action_request.prepare(
                    authorization_path=authorization_path,
                    receipt_path=receipt_path,
                    descriptor_path=descriptor_path,
                    health_report_path=health_path,
                    output_path=request_path,
                    run_root=run_root,
                    grant_id=grant["grant_id"],
                    target=grant["target"],
                    paths=["Sources"],
                )

            alternate_ledger = run_root / "alternate-ledger.jsonl"
            shutil.copy2(ledger_path, alternate_ledger)
            alternate_ledger.chmod(0o600)
            alternate_harness = copy.deepcopy(harness)
            alternate_harness["run_ledger"] = str(alternate_ledger)
            alternate_harness_path = run_root / "alternate-harness.json"
            alternate_harness_path.write_text(
                json.dumps(alternate_harness), encoding="utf-8"
            )
            _document, alternate_authority = (
                resource_coordinator.load_existing_run_authority(
                    authorization_path,
                    alternate_harness_path,
                    alternate_harness,
                    envelope["run_id"],
                )
            )
            with self.assertRaisesRegex(
                resource_coordinator.CoordinatorError, "immutable"
            ):
                resource_coordinator.register_run_authority(
                    coordinator_state,
                    envelope["run_id"],
                    alternate_authority,
                )

            original_descriptor = os.open(ledger_path, os.O_RDONLY)
            try:
                replacement = run_root / "replacement-ledger.jsonl"
                shutil.copy2(ledger_path, replacement)
                replacement.chmod(0o600)
                os.replace(replacement, ledger_path)
                with self.assertRaisesRegex(
                    resource_coordinator.CoordinatorError, "inode drifted"
                ):
                    resource_coordinator.ledger_binding(
                        ledger_path, descriptor=original_descriptor
                    )
            finally:
                os.close(original_descriptor)

    def test_workflow_rejects_task_specific_control_node_extensions(self) -> None:
        workflow = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "workflow.json"
        )
        nodes = workflow["nodes"]
        verify_index = next(index for index, node in enumerate(nodes) if node["id"] == "verify")
        nodes.insert(
            verify_index,
            {
                "id": "claim_runtime_registry",
                "requires": ["release_implementation_writer"],
                "resource": "coresimulator_runtime_registry",
                "resource_key": "host-a",
                "lease_action": "acquire",
                "extension": True,
                "protects": ["verify"],
            },
        )
        verify = next(node for node in nodes if node["id"] == "verify")
        verify["requires"].append("claim_runtime_registry")
        freeze_index = next(index for index, node in enumerate(nodes) if node["id"] == "freeze_review")
        nodes.insert(
            freeze_index,
            {
                "id": "release_runtime_registry",
                "requires": ["verify"],
                "resource": "coresimulator_runtime_registry",
                "resource_key": "host-a",
                "lease_action": "release",
                "extension": True,
                "protects": ["verify"],
            },
        )
        freeze = next(node for node in nodes if node["id"] == "freeze_review")
        freeze["requires"].append("release_runtime_registry")
        resources = set(
            validator.load_json(
                ROOT / "skills" / "agent-harness" / "contracts" / "capabilities.json"
            )["resource_scopes"]
        )
        schema = validator.load_json(
            ROOT
            / "skills"
            / "agent-harness"
            / "contracts"
            / "schemas"
            / "workflow.schema.json"
        )
        schema_instance = {key: value for key, value in workflow.items() if key != "$schema"}
        self.assertTrue(validator.validate_json_schema(schema_instance, schema))
        self.assertTrue(
            any(
                "cannot add task-specific control node" in error
                for error in validator.validate_workflow_semantics(workflow, resources)
            )
        )

    def test_ledger_rejects_active_lease_at_pr_ready(self) -> None:
        records = [
            {"run_id": "run-1", "sequence": 1, "record_type": "lease", "payload": {"lease_id": "lease-1", "action": "acquire", "owner": "codex", "resource": "source_checkout_writer", "resource_key": "repo-a"}},
            {"run_id": "run-1", "sequence": 2, "record_type": "node", "payload": {"node_id": "pr_ready", "status": "passed"}},
        ]
        errors = validator.validate_ledger_lifecycle(records)
        self.assertTrue(any("pr_ready cannot pass" in error for error in errors))

    def test_ledger_rejects_release_before_declared_protected_node(self) -> None:
        envelope = approved_envelope()
        grant = envelope["action_grants"][0]
        records = authorization_ledger(envelope, grant)
        acquire = records[-1]["payload"]
        acquire["protects"] = ["verify"]
        receipt = acquire["coordinator_receipt"]
        release_payload = copy.deepcopy(acquire)
        release_payload.update(
            {
                "action": "release",
                "protects": ["verify"],
                "released_at": "2026-01-01T00:00:04Z",
                "coordinator_release_confirmation": {
                    "coordinator_instance_id": receipt["coordinator_instance_id"],
                    "release_id": "release-protected-lease",
                    "receipt_id": receipt["receipt_id"],
                    "lease_id": receipt["lease_id"],
                    "fencing_token": receipt["fencing_token"],
                    "released_at": "2026-01-01T00:00:04Z",
                },
            }
        )
        records.append(ledger_record(4, "lease", release_payload, 4))
        for errors in (
            validator.validate_ledger_lifecycle(records),
            check_authorization._standalone_ledger_lifecycle_errors(records),
        ):
            self.assertTrue(
                any("preceded protected workflow nodes" in error for error in errors)
            )

    def test_ledger_rejects_lone_or_out_of_order_terminal_nodes(self) -> None:
        lone = [{"run_id": "run-1", "sequence": 1, "record_type": "node", "payload": {"node_id": "pr_ready", "status": "passed"}}]
        self.assertTrue(any("control" in error or "dependency" in error for error in validator.validate_ledger_lifecycle(lone)))
        out_of_order = [{"run_id": "run-1", "sequence": 1, "record_type": "node", "payload": {"node_id": "health_gate", "status": "passed"}}]
        self.assertTrue(any("prerequisite" in error or "dependenc" in error for error in validator.validate_ledger_lifecycle(out_of_order)))
        continuation_too_early = [
            ledger_record(1, "node", {"node_id": "bind_pr_ready", "status": "passed"}, 1)
        ]
        self.assertTrue(
            any(
                "cannot bind before pr_ready" in error
                for error in validator.validate_ledger_lifecycle(continuation_too_early)
            )
        )
        self.assertTrue(
            any(
                "cannot bind before pr_ready" in error
                for error in check_authorization._standalone_ledger_lifecycle_errors(
                    continuation_too_early
                )
            )
        )

    def test_static_workflow_nodes_require_exact_lease_intervals(self) -> None:
        workflow = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "workflow.json"
        )
        records = []
        for sequence, node in enumerate(workflow["nodes"], 1):
            records.append(
                ledger_record(
                    sequence,
                    "node",
                    {"node_id": node["id"], "status": "passed"},
                    sequence,
                )
            )
            if node["id"] == "implement":
                break
        for errors in (
            validator.validate_ledger_lifecycle(records),
            check_authorization._standalone_ledger_lifecycle_errors(records),
        ):
            self.assertTrue(
                any(
                    "claim_implementation_writer lacks its exact active lease binding"
                    in error
                    for error in errors
                )
            )
            self.assertTrue(
                any("implement passed without its bound active lease" in error for error in errors)
            )

        continuation = [
            ledger_record(
                1,
                "node",
                {"node_id": "claim_archive_build", "status": "passed"},
                1,
            ),
            ledger_record(
                2,
                "node",
                {"node_id": "claim_testflight_upload", "status": "passed"},
                2,
            ),
            ledger_record(
                3,
                "node",
                {"node_id": "archive", "status": "passed"},
                3,
            ),
        ]
        errors = check_authorization._standalone_ledger_lifecycle_errors(continuation)
        self.assertTrue(
            any("claim_archive_build lacks its exact active lease binding" in error for error in errors)
        )
        self.assertTrue(
            any("claim_testflight_upload lacks its exact active lease binding" in error for error in errors)
        )
        self.assertTrue(
            any("archive passed without its bound active lease" in error for error in errors)
        )

    def test_runtime_ui_resource_plan_must_cover_selected_runtime_work(self) -> None:
        envelope = approved_envelope()
        envelope["health_profile"] = "runtime_ui"
        build_cache = "/fixture/cache"
        build_descriptor = {
            "repository_fingerprint": envelope["repository"]["fingerprint"],
            "container_path": "/fixture/repository/App.xcodeproj",
            "xcode_build": "27A",
            "sdk": "iphonesimulator",
            "scheme": "App",
            "configuration": "Debug",
            "architecture": "arm64",
            "package_fingerprint": "sha256:" + "f" * 64,
            "cache_paths": [
                build_cache,
                f"{build_cache}/SourcePackages",
                f"{build_cache}/SourcePackages/checkouts",
                f"{build_cache}/SourcePackages/artifacts",
                f"{build_cache}/package-cache",
            ],
            "cache_roles": {
                "derived_data": build_cache,
                "source_packages": f"{build_cache}/SourcePackages",
                "repository_checkouts": f"{build_cache}/SourcePackages/checkouts",
                "artifacts": f"{build_cache}/SourcePackages/artifacts",
                "package_cache": f"{build_cache}/package-cache",
            },
            "output_paths": [],
            "output_roles": {},
            "package_resolution_mode": "none",
        }
        build_descriptor = resource_coordinator.normalize_descriptor(
            "build_tuple", build_descriptor
        )
        device_descriptor = {
            "coordinator_instance_id": "fixture-coordinator",
            "udids": ["fixture-device-0001"],
        }
        envelope["resource_plan"] = [
            {
                "plan_id": "build-plan",
                "resource": "build_tuple",
                "resource_key": resource_coordinator.canonical_resource_key(
                    "build_tuple", build_descriptor
                ),
                "descriptor_sha256": resource_coordinator.descriptor_sha256(
                    "build_tuple", build_descriptor
                ),
                "resource_descriptor": build_descriptor,
                "owner_actor": envelope["selected_writer"],
                "protects": ["archive"],
            },
            {
                "plan_id": "device-plan",
                "resource": "simulator_or_device",
                "resource_key": resource_coordinator.canonical_resource_key(
                    "simulator_or_device", device_descriptor
                ),
                "descriptor_sha256": resource_coordinator.descriptor_sha256(
                    "simulator_or_device", device_descriptor
                ),
                "resource_descriptor": device_descriptor,
                "owner_actor": envelope["selected_writer"],
                "protects": ["archive"],
            },
        ]
        errors = check_authorization.validate_authorization(envelope)
        self.assertTrue(any("outside its delivery target" in error for error in errors))
        self.assertTrue(any("build plan must protect runtime verification" in error for error in errors))
        self.assertTrue(any("destination plan must protect runtime verification" in error for error in errors))

    def test_planned_resource_lease_is_required_and_exact(self) -> None:
        envelope = approved_envelope()
        descriptor = {
            "repository_fingerprint": envelope["repository"]["fingerprint"],
            "container_path": "/fixture/repository/App.xcodeproj",
        }
        descriptor_sha = resource_coordinator.descriptor_sha256(
            "xcode_project_mutation", descriptor
        )
        resource_key = resource_coordinator.canonical_resource_key(
            "xcode_project_mutation", descriptor
        )
        envelope["resource_plan"] = [
            {
                "plan_id": "xcode-verify",
                "resource": "xcode_project_mutation",
                "resource_key": resource_key,
                "descriptor_sha256": descriptor_sha,
                "resource_descriptor": descriptor,
                "owner_actor": envelope["selected_writer"],
                "protects": ["verify"],
            }
        ]
        approval = authorization_ledger(envelope, envelope["action_grants"][0])[0]
        missing = [
            approval,
            ledger_record(2, "node", {"node_id": "verify", "status": "passed"}, 2),
        ]
        for errors in (
            validator.validate_ledger_lifecycle(missing),
            check_authorization._standalone_ledger_lifecycle_errors(missing),
        ):
            self.assertTrue(
                any("passed without planned resource lease xcode-verify" in error for error in errors)
            )

        receipt = {
            "coordinator_instance_id": "fixture-coordinator",
            "receipt_id": "planned-receipt",
            "lease_id": "planned-lease",
            "owner_run_id": envelope["run_id"],
            "owner_actor": "wrong-agent",
            "resource": "xcode_project_mutation",
            "resource_key": resource_key,
            "descriptor_sha256": descriptor_sha,
            "fencing_token": 1,
            "acquired_at": "2026-01-01T00:00:02Z",
            "expires_at": "2097-01-01T00:00:00Z",
        }
        drifted = [
            approval,
            ledger_record(
                2,
                "lease",
                {
                    "lease_id": "planned-lease",
                    "action": "acquire",
                    "owner": "wrong-agent",
                    "resource": "xcode_project_mutation",
                    "resource_key": resource_key,
                    "resource_descriptor": descriptor,
                    "coordinator_receipt": receipt,
                    "protects": ["verify"],
                    "branch": envelope["repository"]["branch"],
                    "base_sha": envelope["repository"]["base_sha"],
                    "pre_state_hash": "sha256:pre",
                    "allowed_paths": ["Sources"],
                    "allowed_actions": ["project.edit"],
                    "approval_id": envelope["authorization_id"],
                    "acquired_at": "2026-01-01T00:00:02Z",
                    "expires_at": "2097-01-01T00:00:00Z",
                },
                2,
            ),
        ]
        for errors in (
            validator.validate_ledger_lifecycle(drifted),
            check_authorization._standalone_ledger_lifecycle_errors(drifted),
        ):
            self.assertTrue(any("drifted from its authorization resource plan" in error for error in errors))

    def test_pr_terminal_reconciles_every_current_evidence_class(self) -> None:
        envelope = approved_envelope()
        complete = full_pr_ready_ledger(envelope)
        self.assertEqual([], validator.validate_ledger_lifecycle(complete))
        self.assertEqual([], check_authorization._ledger_contract_errors(complete))

        expected = {
            "acceptance": "complete acceptance evidence",
            "review": "review evidence",
            "commit_equivalence": "commit equivalence evidence",
            "publication": "viewable publication evidence",
            "checks_readback": "required-checks read-back evidence",
        }
        for missing_kind, phrase in expected.items():
            incomplete = [
                record
                for record in complete
                if not (
                    record["record_type"] == "evidence"
                    and record["payload"]["evidence_kind"] == missing_kind
                )
            ]
            for errors in (
                validator.validate_ledger_lifecycle(incomplete),
                check_authorization._ledger_contract_errors(incomplete),
            ):
                self.assertTrue(any(phrase in error for error in errors), (missing_kind, errors))

        forged_exit = copy.deepcopy(complete)
        acceptance = next(
            record
            for record in forged_exit
            if record.get("payload", {}).get("evidence_kind") == "acceptance"
        )
        acceptance["payload"]["tool_tuple"]["exit_status"] = 1
        forged_coverage = copy.deepcopy(complete)
        acceptance_coverage = next(
            record
            for record in forged_coverage
            if record.get("payload", {}).get("evidence_kind") == "acceptance"
        )
        acceptance_coverage["payload"]["tool_tuple"]["coverage"][0][
            "acceptance_id"
        ] = "AC-forged"
        missing_runtime_artifact = copy.deepcopy(complete)
        runtime_acceptance = next(
            record
            for record in missing_runtime_artifact
            if record.get("payload", {}).get("evidence_kind") == "acceptance"
        )
        runtime_acceptance["payload"]["tool_tuple"]["evidence_layer"] = "runtime_ui"
        for invalid, phrase in (
            (forged_exit, "zero tool exit status"),
            (forged_coverage, "exactly match evidence acceptance IDs"),
            (missing_runtime_artifact, "requires screenshot evidence"),
        ):
            for errors in (
                validator.validate_ledger_lifecycle(invalid),
                check_authorization._ledger_contract_errors(invalid),
            ):
                self.assertTrue(any(phrase in error for error in errors), errors)

    def test_protected_workflow_node_cannot_outlive_run_authorization(self) -> None:
        envelope = approved_envelope()
        manifest = fixture_patch_manifest(envelope)
        record = {
            "schema_version": "1.0.0",
            "run_id": envelope["run_id"],
            "sequence": 2,
            "recorded_at": "2098-01-03T00:00:00Z",
            "record_type": "node",
            "payload": {
                "node_id": "verify",
                "status": "passed",
                "patch_identity": check_authorization.patch_identity_v1(manifest),
                "patch_manifest": manifest,
            },
        }
        records = [
            authorization_ledger(envelope, envelope["action_grants"][0])[0],
            record,
        ]
        for errors in (
            validator.validate_ledger_lifecycle(records),
            check_authorization._standalone_ledger_lifecycle_errors(records),
        ):
            self.assertTrue(
                any("outside run authorization time bounds" in error for error in errors),
                errors,
            )

    def test_external_write_requires_prior_authorization_and_single_use_grant(self) -> None:
        envelope = approved_envelope()
        grant = envelope["action_grants"][0]
        request = action_request(envelope, grant)
        reservation_id = "reservation-issue-ready"
        reservation = ledger_record(
            4,
            "grant_reservation",
            {
                "reservation_id": reservation_id,
                "authorization_hash": request["authorization_hash"],
                "grant_id": request["grant_id"],
                "idempotency_key": request["idempotency_key"],
                "system": request["system"],
                "action": request["action"],
                "operation": request["operation"],
                "operation_input": request["operation_input"],
                "action_request_sha256": "sha256:"
                + check_authorization.canonical_sha256(request),
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
                "spec_checkpoint_sha256": None,
                "apple_observation_sha256": None,
                "apple_observation_state_sha256": None,
                "health_report_sha256": request["health_report_sha256"],
                "paths": copy.deepcopy(request["paths"]),
                "repository_observation_sha256": None,
            },
            4,
        )
        external_write = ledger_record(
            6,
            "external_write",
            {
                "system": request["system"],
                "action": request["action"],
                "operation": request["operation"],
                "operation_input": request["operation_input"],
                "constraint_sha256": request["constraint_sha256"],
                "phase": request["phase"],
                "resource": request["lease_resource"],
                "resource_key": request["lease_resource_key"],
                "resource_descriptor": request["resource_descriptor"],
                "coordinator_receipt": request["coordinator_receipt"],
                "lease_id": request["lease_id"],
                "lease_owner": request["lease_owner"],
                "writer_actor": request["writer_actor"],
                "target": request["target"],
                "outcome": "succeeded",
                "authorization_hash": request["authorization_hash"],
                "grant_id": request["grant_id"],
                "idempotency_key": request["idempotency_key"],
                "reservation_id": reservation_id,
                "dispatch_id": "dispatch-issue-ready",
                "spec_checkpoint_sha256": None,
                "apple_observation_sha256": None,
                "health_report_sha256": request["health_report_sha256"],
            },
            6,
        )
        dispatch = ledger_record(
            5,
            "grant_dispatch",
            {
                "dispatch_id": "dispatch-issue-ready",
                "reservation_id": reservation_id,
                "coordinator_receipt": request["coordinator_receipt"],
                "health_report_sha256": request["health_report_sha256"],
                "dispatch_deadline": "2026-01-01T00:00:45Z",
            },
            5,
        )
        self.assertTrue(
            any(
                "prior approved run authorization" in error
                for error in validator.validate_ledger_lifecycle([external_write])
            )
        )
        records = authorization_ledger(envelope, grant) + [reservation, dispatch, external_write]
        self.assertEqual([], validator.validate_ledger_lifecycle(records))
        self.assertEqual(
            [], check_authorization._standalone_ledger_lifecycle_errors(records)
        )
        slow_completion = copy.deepcopy(records)
        slow_completion[-1]["recorded_at"] = "2026-01-01T00:00:46Z"
        self.assertEqual([], validator.validate_ledger_lifecycle(slow_completion))
        self.assertEqual(
            [],
            check_authorization._standalone_ledger_lifecycle_errors(
                slow_completion
            ),
        )

        without_dispatch = authorization_ledger(envelope, grant) + [
            reservation,
            external_write,
        ]
        mismatched_dispatch = copy.deepcopy(records)
        mismatched_dispatch[-1]["payload"]["dispatch_id"] = "dispatch-other"
        overlong_dispatch = copy.deepcopy(records)
        overlong_dispatch[-2]["payload"][
            "dispatch_deadline"
        ] = "2026-01-01T00:02:00Z"
        for invalid_records in (
            without_dispatch, mismatched_dispatch, overlong_dispatch
        ):
            for errors in (
                validator.validate_ledger_lifecycle(invalid_records),
                check_authorization._standalone_ledger_lifecycle_errors(invalid_records),
            ):
                self.assertTrue(
                    any("dispatch" in error for error in errors),
                    errors,
                )

        renewed_receipt = copy.deepcopy(request["coordinator_receipt"])
        renewed_receipt["expires_at"] = "2098-01-01T00:00:00Z"
        heartbeat_payload = copy.deepcopy(authorization_ledger(envelope, grant)[-1]["payload"])
        heartbeat_payload.update(
            {
                "action": "heartbeat",
                "coordinator_receipt": renewed_receipt,
                "heartbeat_at": "2026-01-01T00:00:06Z",
                "expires_at": renewed_receipt["expires_at"],
            }
        )
        heartbeat = ledger_record(6, "lease", heartbeat_payload, 6)
        renewed_write = copy.deepcopy(external_write)
        renewed_write["sequence"] = 7
        renewed_write["recorded_at"] = "2026-01-01T00:00:07Z"
        renewed_write["payload"]["coordinator_receipt"] = renewed_receipt
        renewed_records = (
            authorization_ledger(envelope, grant)
            + [reservation, dispatch, heartbeat, renewed_write]
        )
        self.assertEqual([], validator.validate_ledger_lifecycle(renewed_records))
        self.assertEqual(
            [],
            check_authorization._standalone_ledger_lifecycle_errors(renewed_records),
        )
        drifted_write = copy.deepcopy(renewed_write)
        drifted_write["payload"]["coordinator_receipt"]["fencing_token"] += 1
        self.assertTrue(
            any(
                "receipt lineage" in error or "active" in error
                for error in validator.validate_ledger_lifecycle(
                    authorization_ledger(envelope, grant)
                    + [reservation, dispatch, heartbeat, drifted_write]
                )
            )
        )
        failed_records = copy.deepcopy(records)
        failed_records[-1]["payload"]["outcome"] = "failed"
        self.assertEqual([], validator.validate_ledger_lifecycle(failed_records))
        reused = copy.deepcopy(external_write)
        reused["sequence"] = 7
        reused["recorded_at"] = "2026-01-01T00:00:07Z"
        errors = validator.validate_ledger_lifecycle(records + [reused])
        self.assertTrue(any("single-use grant" in error for error in errors))
        self.assertTrue(any("idempotency key" in error for error in errors))
        failed_retry_errors = validator.validate_ledger_lifecycle(failed_records + [reused])
        self.assertTrue(any("single-use grant" in error for error in failed_retry_errors))

    def test_runtime_registry_and_device_leases_conflict_both_ways(self) -> None:
        device_then_registry = [
            {"run_id": "run-1", "sequence": 1, "record_type": "lease", "payload": {"lease_id": "device", "action": "acquire", "owner": "codex", "resource": "simulator_or_device", "resource_key": "device-a"}},
            {"run_id": "run-1", "sequence": 2, "record_type": "lease", "payload": {"lease_id": "registry", "action": "acquire", "owner": "codex", "resource": "coresimulator_runtime_registry", "resource_key": "host-a", "allowed_actions": ["read_only_diagnosis"]}},
        ]
        registry_then_device = [
            {"run_id": "run-1", "sequence": 1, "record_type": "lease", "payload": {"lease_id": "registry", "action": "acquire", "owner": "codex", "resource": "coresimulator_runtime_registry", "resource_key": "host-a", "allowed_actions": ["read_only_diagnosis"]}},
            {"run_id": "run-1", "sequence": 2, "record_type": "lease", "payload": {"lease_id": "device", "action": "acquire", "owner": "codex", "resource": "simulator_or_device", "resource_key": "device-a"}},
        ]
        self.assertTrue(any("conflicts" in error for error in validator.validate_ledger_lifecycle(device_then_registry)))
        self.assertTrue(any("conflicts" in error for error in validator.validate_ledger_lifecycle(registry_then_device)))

    def test_mutating_runtime_registry_lease_requires_matching_approval(self) -> None:
        descriptor = {
            "coordinator_instance_id": "coordinator-a",
            "registry_scope": "all-runtimes",
        }
        resource_key = resource_coordinator.canonical_resource_key(
            resource_coordinator.CORE_SIMULATOR, descriptor
        )
        receipt = {
            "coordinator_instance_id": "coordinator-a",
            "receipt_id": "receipt-registry",
            "lease_id": "registry",
            "owner_run_id": "run-1",
            "owner_actor": "codex",
            "resource": "coresimulator_runtime_registry",
            "resource_key": resource_key,
            "descriptor_sha256": resource_coordinator.descriptor_sha256(
                resource_coordinator.CORE_SIMULATOR, descriptor
            ),
            "fencing_token": 1,
            "acquired_at": "2026-01-01T00:00:00Z",
            "expires_at": "2097-01-01T00:00:00Z",
        }

        def approval(decision: str = "approved", target: str = "runtime-a") -> dict:
            return {
                "run_id": "run-1",
                "sequence": 1,
                "record_type": "approval",
                "payload": {
                    "approval_id": "approval-a",
                    "kind": "destructive_action",
                    "decision": decision,
                    "scope": f"coresimulator_runtime_registry:{resource_key}:remove_exact_runtime:{target}",
                    "resource": "coresimulator_runtime_registry",
                    "resource_key": resource_key,
                    "action": "remove_exact_runtime",
                    "target": target,
                    "single_use": True,
                },
            }

        def acquire(sequence: int = 2, target: str = "runtime-a") -> dict:
            return {
                "run_id": "run-1",
                "sequence": sequence,
                "record_type": "lease",
                "payload": {
                    "lease_id": "registry",
                    "action": "acquire",
                    "owner": "codex",
                    "resource": "coresimulator_runtime_registry",
                    "resource_key": resource_key,
                    "resource_descriptor": descriptor,
                    "coordinator_receipt": receipt,
                    "protects": ["intake"],
                    "acquired_at": receipt["acquired_at"],
                    "expires_at": receipt["expires_at"],
                    "allowed_actions": ["remove_exact_runtime"],
                    "approval_id": "approval-a",
                    "mutation_target": target,
                },
            }

        unapproved = acquire(sequence=1)
        self.assertTrue(any("exact unrevoked prior approval" in error for error in validator.validate_ledger_lifecycle([unapproved])))

        wrong_target = [approval(target="runtime-a"), acquire(target="runtime-b")]
        self.assertTrue(any("exact unrevoked prior approval" in error for error in validator.validate_ledger_lifecycle(wrong_target)))

        cancelled = [approval(), {**approval(decision="rejected"), "sequence": 2}, acquire(sequence=3)]
        self.assertTrue(any("exact unrevoked prior approval" in error for error in validator.validate_ledger_lifecycle(cancelled)))

        missing_protection = [approval(), acquire()]
        missing_protection[-1]["payload"].pop("protects")
        self.assertTrue(
            any(
                "must declare protected workflow nodes" in error
                for error in validator.validate_ledger_lifecycle(missing_protection)
            )
        )

        late_acquire = [
            approval(),
            {"run_id": "run-1", "sequence": 2, "record_type": "node", "payload": {"node_id": "intake", "status": "passed"}},
            acquire(sequence=3),
        ]
        self.assertTrue(
            any(
                "acquired after its protected workflow node" in error
                for error in validator.validate_ledger_lifecycle(late_acquire)
            )
        )
        self.assertTrue(
            any(
                "acquired after its protected workflow node" in error
                for error in check_authorization._standalone_ledger_lifecycle_errors(
                    late_acquire
                )
            )
        )

        approved = [
            approval(),
            acquire(),
            {"run_id": "run-1", "sequence": 3, "record_type": "node", "payload": {"node_id": "intake", "status": "passed"}},
            {"run_id": "run-1", "sequence": 4, "record_type": "lease", "payload": {"lease_id": "registry", "action": "release", "owner": "codex", "resource": "coresimulator_runtime_registry", "resource_key": resource_key, "resource_descriptor": descriptor, "coordinator_receipt": receipt, "protects": ["intake"], "coordinator_release_confirmation": {"coordinator_instance_id": "coordinator-a", "release_id": "release-registry", "receipt_id": "receipt-registry", "lease_id": "registry", "fencing_token": 1, "released_at": "2026-01-01T00:00:03Z"}, "released_at": "2026-01-01T00:00:03Z"}},
        ]
        self.assertEqual([], validator.validate_ledger_lifecycle(approved))

        reused = approved + [acquire(sequence=5)]
        self.assertTrue(any("single-use" in error for error in validator.validate_ledger_lifecycle(reused)))

    def test_runtime_registry_policy_drift_is_rejected(self) -> None:
        capabilities = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "capabilities.json"
        )
        capabilities["runtime_registry_policy"]["supporting_enumeration_gap_seconds"] = 31
        self.assertTrue(validator.validate_runtime_registry_policy(capabilities))

    def test_xcode_mcp_provider_policy_drift_is_rejected(self) -> None:
        capabilities = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "capabilities.json"
        )
        capabilities["xcode_mcp_provider_policy"]["max_active_simulator_capable_providers_during_incident"] = 2
        self.assertTrue(validator.validate_xcode_mcp_provider_policy(capabilities))

    def test_cross_run_resource_coordination_policy_is_exact_and_fail_closed(self) -> None:
        path = ROOT / "skills" / "agent-harness" / "contracts" / "capabilities.json"
        capabilities = validator.load_json(path)
        self.assertEqual([], validator.validate_resource_coordination_policy(capabilities))
        self.assertEqual(
            ["identity_version", "repository_fingerprint"],
            capabilities["resource_key_fields"]["source_checkout_writer"],
        )
        self.assertEqual(
            ["coordinator_instance_id", "udids"],
            capabilities["resource_key_fields"]["simulator_or_device"],
        )
        overlap = capabilities["resource_overlap_policy"]
        self.assertEqual(
            "same_host_and_udid_intersection_nonempty",
            overlap["simulator_or_device"]["conflict_when"],
        )
        self.assertEqual(
            "canonical_cache_or_output_path_tree_overlap_or_same_repository_when_either_resolves_packages",
            overlap["build_tuple"]["conflict_when"],
        )
        self.assertEqual(
            "samefile_then_unicode_casefolded_tree_overlap",
            overlap["build_tuple"]["path_alias_policy"],
        )
        self.assertEqual(
            "repository_fingerprint_or_canonical_container_path_equal",
            overlap["xcode_project_mutation"]["conflict_when"],
        )
        self.assertEqual(
            "xcode_project_or_build_same_repository_fingerprint",
            overlap["source_checkout_writer"]["cross_resource_conflict"],
        )
        self.assertEqual(
            ["coordinator_instance_id", "session_scope"],
            capabilities["resource_key_fields"]["macos_gui_session"],
        )
        self.assertEqual(
            ["derived_data", "source_packages", "repository_checkouts", "artifacts", "package_cache"],
            overlap["build_tuple"]["required_cache_roles"],
        )
        self.assertEqual(
            "coordinator_instance_id",
            overlap["simulator_or_device"]["host_identity_source"],
        )
        coordination = capabilities["cross_run_coordination_policy"]
        self.assertEqual(
            {"graph_state": "blocked", "reason_code": "coordination_required"},
            coordination["unavailable_outcome"],
        )
        self.assertFalse(coordination["lease_expiry"]["silent_takeover"])
        self.assertTrue(coordination["live_receipt_verification_before_dispatch"])
        self.assertEqual(3600, coordination["max_ttl_seconds"])

        mutations = []
        for field, value in (
            ("simulator_or_device", "same_host_and_exact_set_equal"),
            ("build_tuple", "all_tuple_fields_equal"),
        ):
            changed = copy.deepcopy(capabilities)
            changed["resource_overlap_policy"][field]["conflict_when"] = value
            mutations.append(changed)
        changed = copy.deepcopy(capabilities)
        changed["cross_run_coordination_policy"]["atomic_acquire_required"] = False
        mutations.append(changed)
        changed = copy.deepcopy(capabilities)
        changed["cross_run_coordination_policy"]["lease_expiry"]["silent_takeover"] = True
        mutations.append(changed)
        self.assertTrue(
            all(validator.validate_resource_coordination_policy(item) for item in mutations)
        )

    def test_private_coordinator_setup_documents_the_executable_green_path(self) -> None:
        setup = normalized_text(
            ROOT / "skills" / "agent-harness" / "references"
            / "coordinator-setup.md"
        )
        for phrase in (
            "templates/private-policy-overlay.json",
            "--observe-agent-skills",
            "run-authorization.pending.schema.json",
            "run-authorization.schema.json",
            "scripts/initialize_run.py",
            "--authorization '<run-root>/authorization.json'",
            "--plan-id '<resource-plan-id>'",
            "scripts/prepare_action_request.py",
            "--health-report '<run-root>/health.json'",
            "--observer-harness",
            "--observer-authorization",
            "reboot is neither an automatic step",
        ):
            self.assertIn(phrase, setup)

    def test_run_authorization_allows_exact_action_and_rejects_branch_drift(self) -> None:
        envelope = approved_envelope()
        grant = envelope["action_grants"][0]
        request = action_request(envelope, grant)
        ledger = authorization_ledger(envelope, grant)
        current = datetime(2026, 1, 1, 0, 1, tzinfo=timezone.utc)
        self.assertEqual(
            [],
            check_authorization.authorize_action(
                envelope,
                request,
                now=current,
                ledger_records=ledger,
                policy_overlay=policy_overlay(),
                live_repository=live_repository(envelope),
                verified_coordinator_receipt=request["coordinator_receipt"],
                **live_action_guards(envelope),
            ),
        )
        request["repository"]["branch"] = "different-branch"
        self.assertTrue(any("repository or branch drifted" in error for error in check_authorization.authorize_action(envelope, request, now=current, ledger_records=ledger, policy_overlay=policy_overlay(), live_repository=live_repository(envelope), verified_coordinator_receipt=request["coordinator_receipt"], **live_action_guards(envelope))))
        request["repository"] = copy.deepcopy(envelope["repository"])
        request["paths"] = ["outside-approved-scope/file.swift"]
        self.assertTrue(any("path is outside authorization" in error for error in check_authorization.authorize_action(envelope, request, now=current, ledger_records=ledger, policy_overlay=policy_overlay(), live_repository=live_repository(envelope), verified_coordinator_receipt=request["coordinator_receipt"], **live_action_guards(envelope))))
        request["paths"] = copy.deepcopy(envelope["allowed_paths"])
        request["operation_input"]["state"] = "Closed"
        self.assertTrue(any("constraint digest" in error or "exact action grant" in error for error in check_authorization.authorize_action(envelope, request, now=current, ledger_records=ledger, policy_overlay=policy_overlay(), live_repository=live_repository(envelope), verified_coordinator_receipt=request["coordinator_receipt"], **live_action_guards(envelope))))

    def test_operation_descriptors_block_force_push_and_remote_credentials(self) -> None:
        envelope = approved_envelope()
        push = next(item for item in envelope["action_grants"] if item["action"] == "git.push")
        push["operation_input"]["force"] = True
        push["constraint_sha256"] = check_authorization.canonical_sha256(push["operation_input"])
        self.assertTrue(
            any("force false" in error for error in check_authorization.validate_authorization(envelope))
        )
        credentialed = "https://user:secret@github.com/example/repository.git"
        sanitized = "https://github.com/example/repository.git"
        self.assertEqual(sanitized, check_authorization.sanitize_remote(credentialed))
        self.assertEqual(sanitized, evaluate_health.sanitize_remote(credentialed))

    def test_logical_repository_fingerprint_normalizes_github_forms_and_rejects_unsafe_raw_remotes(self) -> None:
        forms = (
            "https://github.com/Example/Repository.git",
            "git@github.com:Example/Repository.git",
            "ssh://git@github.com/Example/Repository",
        )
        fingerprints = {check_authorization.repository_fingerprint(remote) for remote in forms}
        self.assertEqual(len(fingerprints), 1)
        self.assertEqual(
            fingerprints,
            {resolve_project.remote_fingerprint(remote) for remote in forms},
        )
        self.assertEqual(
            check_authorization.repository_fingerprint(
                "/ignored/legacy/root", forms[0]
            ),
            next(iter(fingerprints)),
        )
        self.assertEqual(
            "github.com/example/repository",
            check_authorization.normalize_github_remote(forms[0]),
        )
        for remote in (
            "https://user:secret@github.com/example/repository.git",
            "https://github.com/example/repository.git?token=secret",
            "https://github.com:8443/example/repository.git",
            "file:///tmp/repository",
        ):
            with self.assertRaises(ValueError):
                check_authorization.repository_fingerprint(remote)

    def test_git_commit_writer_lease_is_checkout_independent(self) -> None:
        first, second = approved_envelope(), approved_envelope()
        second["repository"]["canonical_root"] = "/another/checkout"
        second["repository"]["remote"] = "git@github.com:example/repository.git"
        second["repository"]["fingerprint"] = check_authorization.repository_fingerprint(
            second["repository"]["remote"]
        )
        self.assertEqual(
            check_authorization.canonical_lease_resource_key(first, "git.commit"),
            check_authorization.canonical_lease_resource_key(second, "git.commit"),
        )
        self.assertNotIn(
            first["repository"]["canonical_root"],
            check_authorization.canonical_lease_resource_key(first, "git.commit"),
        )

        mixed_case = approved_envelope()
        mixed_case["github"].update(owner="Example", repository="Repository")
        mixed_case["repository"]["remote"] = (
            "git@github.com:EXAMPLE/REPOSITORY.git"
        )
        self.assertEqual([], check_authorization.validate_authorization(mixed_case))
        github_action = next(
            item["action"] for item in first["action_grants"]
            if item["action"] == "github.issue.update"
        )
        self.assertEqual(
            check_authorization.canonical_lease_resource_key(first, github_action),
            check_authorization.canonical_lease_resource_key(
                mixed_case, github_action
            ),
        )

        wrong_fingerprint = approved_envelope()
        wrong_fingerprint["repository"]["fingerprint"] = "sha256:" + "f" * 64
        self.assertIn(
            "authorization repository fingerprint does not match its logical remote",
            check_authorization.validate_authorization(wrong_fingerprint),
        )

    def test_expired_lease_cannot_be_reacquired_without_release(self) -> None:
        records = [
            {
                "record_type": "lease",
                "payload": {
                    "lease_id": "first", "owner": "agent-a", "action": "acquire",
                    "resource": "source_checkout_writer", "resource_key": "logical-repository",
                    "expires_at": "2020-01-01T00:00:00Z",
                },
            },
            {
                "record_type": "lease",
                "payload": {
                    "lease_id": "second", "owner": "agent-b", "action": "acquire",
                    "resource": "source_checkout_writer", "resource_key": "logical-repository",
                    "expires_at": "2030-01-01T00:00:00Z",
                },
            },
        ]
        _, errors = check_authorization._active_leases(records)
        self.assertTrue(any("overlapping acquire" in error for error in errors))

    def test_expired_lease_release_requires_fenced_recovery_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "coordinator.json"
            resource_coordinator.bootstrap_state(
                state, legacy_leases_quiesced=True
            )
            now = datetime(2026, 1, 1, tzinfo=timezone.utc)
            descriptor = {
                "identity_version": "github_remote_v2",
                "repository_fingerprint": "sha256:" + "a" * 64,
            }
            recovery_authority = fixture_run_authority(run_id="run-recovery")
            observer_authority = fixture_run_authority(
                run_id="independent-recovery-audit"
            )
            resource_coordinator.register_run_authority(
                state, "run-recovery", recovery_authority, now=now
            )
            resource_coordinator.register_run_authority(
                state,
                "independent-recovery-audit",
                observer_authority,
                now=now,
            )
            receipt = resource_coordinator.acquire(
                state,
                resource=resource_coordinator.SOURCE_WRITER,
                descriptor=descriptor,
                owner_run_id="run-recovery",
                owner_actor="codex",
                ttl_seconds=1,
                now=now,
                run_authority=recovery_authority,
            )
            acquire = {
                "schema_version": "1.0.0",
                "run_id": "run-recovery",
                "sequence": 1,
                "recorded_at": "2026-01-01T00:00:00Z",
                "record_type": "lease",
                "payload": {
                    "lease_id": receipt["lease_id"],
                    "action": "acquire",
                    "owner": "codex",
                    "resource": resource_coordinator.SOURCE_WRITER,
                    "resource_key": receipt["resource_key"],
                    "resource_descriptor": descriptor,
                    "coordinator_receipt": receipt,
                    "branch": "codex/example",
                    "base_sha": "1" * 40,
                    "pre_state_hash": "sha256:pre",
                    "allowed_paths": ["Sources"],
                    "allowed_actions": ["git.commit"],
                    "acquired_at": receipt["acquired_at"],
                    "expires_at": receipt["expires_at"],
                },
            }
            release = {
                "schema_version": "1.0.0",
                "run_id": "run-recovery",
                "sequence": 2,
                "recorded_at": "2026-01-01T00:00:02Z",
                "record_type": "lease",
                "payload": {
                    "lease_id": receipt["lease_id"],
                    "action": "release",
                    "owner": "codex",
                    "resource": resource_coordinator.SOURCE_WRITER,
                    "resource_key": receipt["resource_key"],
                    "resource_descriptor": descriptor,
                    "coordinator_receipt": receipt,
                    "released_at": "2026-01-01T00:00:02Z",
                    "post_state_hash": "sha256:post",
                },
            }
            self.assertTrue(
                any(
                    "requires coordinator recovery evidence" in error
                    for error in validator.validate_ledger_lifecycle(
                        [acquire, release]
                    )
                )
            )
            recovery_time = now + timedelta(seconds=2)
            evidence = {
                "previous_receipt_id": receipt["receipt_id"],
                "previous_fencing_token": receipt["fencing_token"],
                "observer": {
                    "observer_run_id": "independent-recovery-audit",
                    "observer_actor": "codex",
                    "method": "bounded_read_only_host_probe",
                    "observed_at": "2026-01-01T00:00:02Z",
                },
                "owner_liveness": {"state": "dead", "digest": "sha256:" + "b" * 64, "observed_at": "2026-01-01T00:00:02Z"},
                "owner_tool_children": {"state": "dead", "digest": "sha256:" + "e" * 64, "observed_at": "2026-01-01T00:00:02Z"},
                "dirty_state": {"state": "clean", "digest": "sha256:" + "c" * 64, "observed_at": "2026-01-01T00:00:02Z"},
                "live_resource_revalidation": {"passed": True, "digest": "sha256:" + "d" * 64, "observed_at": "2026-01-01T00:00:02Z"},
            }
            confirmation = resource_coordinator.recover(
                state,
                receipt,
                evidence=evidence,
                run_authority=recovery_authority,
                observer_authority=observer_authority,
                now=recovery_time,
            )
            release["payload"]["recovery_evidence"] = evidence
            release["payload"]["recovery_confirmation"] = confirmation
            schema = validator.load_json(
                ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
                / "ledger-record.schema.json"
            )
            self.assertEqual([], validator.validate_json_schema(release, schema))
            for field in ("observer", "owner_tool_children"):
                invalid = copy.deepcopy(release)
                invalid["payload"]["recovery_evidence"].pop(field)
                self.assertTrue(validator.validate_json_schema(invalid, schema))
            self.assertEqual(
                [], validator.validate_ledger_lifecycle([acquire, release])
            )
            self.assertEqual(
                [],
                check_authorization._standalone_ledger_lifecycle_errors(
                    [acquire, release], coordinator_state=state
                ),
            )

    def test_normal_release_requires_live_coordinator_confirmation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "coordinator.json"
            resource_coordinator.bootstrap_state(
                state, legacy_leases_quiesced=True
            )
            descriptor = {
                "identity_version": "github_remote_v2",
                "repository_fingerprint": "sha256:" + "a" * 64,
            }
            release_authority = fixture_run_authority(run_id="run-release")
            resource_coordinator.register_run_authority(
                state, "run-release", release_authority
            )
            receipt = resource_coordinator.acquire(
                state,
                resource=resource_coordinator.SOURCE_WRITER,
                descriptor=descriptor,
                owner_run_id="run-release",
                owner_actor="codex",
                ttl_seconds=60,
                run_authority=release_authority,
            )
            acquire = {
                "schema_version": "1.0.0",
                "run_id": "run-release",
                "sequence": 1,
                "recorded_at": receipt["acquired_at"],
                "record_type": "lease",
                "payload": {
                    "lease_id": receipt["lease_id"],
                    "action": "acquire",
                    "owner": "codex",
                    "resource": resource_coordinator.SOURCE_WRITER,
                    "resource_key": receipt["resource_key"],
                    "resource_descriptor": descriptor,
                    "coordinator_receipt": receipt,
                    "branch": "example",
                    "base_sha": "base",
                    "pre_state_hash": "sha256:pre",
                    "allowed_paths": ["Sources"],
                    "allowed_actions": ["git.commit"],
                    "approval_id": "approval",
                    "acquired_at": receipt["acquired_at"],
                    "expires_at": receipt["expires_at"],
                },
            }
            forged_time = receipt["acquired_at"]
            release = {
                "schema_version": "1.0.0",
                "run_id": "run-release",
                "sequence": 2,
                "recorded_at": forged_time,
                "record_type": "lease",
                "payload": {
                    "lease_id": receipt["lease_id"],
                    "action": "release",
                    "owner": "codex",
                    "resource": resource_coordinator.SOURCE_WRITER,
                    "resource_key": receipt["resource_key"],
                    "resource_descriptor": descriptor,
                    "coordinator_receipt": receipt,
                    "coordinator_release_confirmation": {
                        "coordinator_instance_id": receipt["coordinator_instance_id"],
                        "release_id": "forged-release",
                        "receipt_id": receipt["receipt_id"],
                        "lease_id": receipt["lease_id"],
                        "fencing_token": receipt["fencing_token"],
                        "released_at": forged_time,
                    },
                    "released_at": forged_time,
                    "post_state_hash": "sha256:post",
                },
            }
            self.assertTrue(
                any(
                    "not live" in error
                    for error in validator.validate_ledger_lifecycle(
                        [acquire, release], coordinator_state=state
                    )
                )
            )
            confirmation = resource_coordinator.release(
                state,
                receipt,
                run_authority=fixture_run_authority(run_id="run-release"),
            )
            release["recorded_at"] = confirmation["released_at"]
            release["payload"]["released_at"] = confirmation["released_at"]
            release["payload"]["coordinator_release_confirmation"] = confirmation
            self.assertEqual(
                [],
                validator.validate_ledger_lifecycle(
                    [acquire, release], coordinator_state=state
                ),
            )

    def test_release_schema_anyof_requires_one_coordinator_terminal_proof(self) -> None:
        schema = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
            / "ledger-record.schema.json"
        )
        records = [
            json.loads(line)
            for line in (
                ROOT / "skills" / "agent-harness" / "contracts"
                / "example-ledger.jsonl"
            ).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        release = copy.deepcopy(
            next(record for record in records if record.get("sequence") == 10)
        )
        release["payload"].pop("coordinator_release_confirmation")
        self.assertTrue(validator.validate_json_schema(release, schema))
        self.assertTrue(check_authorization._schema_errors(release, schema))

    def test_grant_reservation_lease_requires_authorization_approval_binding(self) -> None:
        records = [
            json.loads(line)
            for line in (
                ROOT / "skills" / "agent-harness" / "contracts"
                / "example-ledger.jsonl"
            ).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        acquire = next(
            record
            for record in records
            if record.get("record_type") == "lease"
            and record.get("payload", {}).get("action") == "acquire"
        )
        acquire["payload"].pop("approval_id")
        repository_errors = validator.validate_ledger_lifecycle(records)
        installed_errors = check_authorization._ledger_contract_errors(records)
        self.assertTrue(
            any("not bound to the authorization" in error for error in repository_errors),
            repository_errors,
        )
        self.assertTrue(
            any(
                "ledger schema line" in error
                or "approval_id" in error
                or "not bound to the authorization" in error
                for error in installed_errors
            ),
            installed_errors,
        )

    def test_malformed_ledger_fails_closed_through_reservation_cli(self) -> None:
        envelope = approved_envelope()
        records = authorization_ledger(envelope, envelope["action_grants"][0])
        records[0]["payload"].pop("decision")
        with tempfile.TemporaryDirectory() as directory:
            run_root = Path(directory)
            coordinator_state = run_root / "coordinator.json"
            resource_coordinator.bootstrap_state(
                coordinator_state, legacy_leases_quiesced=True
            )
            coordinator_binding = {
                "state_path": str(coordinator_state),
                "coordinator_instance_id": resource_coordinator.status(
                    coordinator_state
                )["coordinator_instance_id"],
                "script_sha256": "sha256:" + hashlib.sha256(
                    (
                        ROOT
                        / "skills"
                        / "agent-harness"
                        / "scripts"
                        / "resource_coordinator.py"
                    ).read_bytes()
                ).hexdigest(),
                "contract_bundle_sha256": resource_coordinator.contract_bundle_sha256(
                    ROOT / "skills" / "agent-harness"
                ),
            }
            authorization_path = run_root / "authorization.json"
            authorization_path.write_text(json.dumps(envelope), encoding="utf-8")
            policy_path = run_root / "policy.json"
            policy_path.write_text(json.dumps(policy_overlay()), encoding="utf-8")
            ledger_path = run_root / "ledger.jsonl"
            harness = validator.load_json(
                ROOT / "skills" / "agent-harness" / "templates" / "harness.json"
            )
            harness.update(
                {
                    "$schema": (
                        ROOT
                        / "skills"
                        / "agent-harness"
                        / "contracts"
                        / "schemas"
                        / "harness.schema.json"
                    ).resolve().as_uri(),
                    "authoritative_root": str(ROOT),
                    "xcode_container": str(ROOT / "Fixture.xcodeproj"),
                    "private_policy_overlay": str(policy_path),
                    "run_authorization": str(authorization_path),
                    "run_ledger": str(ledger_path),
                    "resource_coordinator": coordinator_binding,
                }
            )
            harness["agent_skills"]["installations"]["codex"] = {
                "collection_root": str(ROOT / "skills")
            }
            harness_path = run_root / "private-harness.json"
            harness_path.write_text(json.dumps(harness), encoding="utf-8")
            ledger_path.write_text(
                "\n".join(json.dumps(item) for item in records) + "\n",
                encoding="utf-8",
            )
            health_path = run_root / "health.json"
            health_path.write_text("{}", encoding="utf-8")
            request_path = run_root / "request.json"
            request_path.write_text("{}", encoding="utf-8")
            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                patch.object(
                    check_authorization,
                    "verify_health_report",
                    return_value=([], {}),
                ),
                patch.object(
                    sys,
                    "argv",
                    [
                        "verify_reservation.py",
                        "--ledger",
                        str(ledger_path),
                        "--reservation-id",
                        "missing-reservation",
                        "--run-root",
                        str(run_root),
                        "--harness",
                        str(harness_path),
                        "--coordinator-state",
                        str(coordinator_state),
                        "--health-report",
                        str(health_path),
                        "--request",
                        str(request_path),
                    ],
                ),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                return_code = verify_reservation.main()
            result = json.loads(stdout.getvalue())
            self.assertEqual(2, return_code)
            self.assertFalse(result["verified"])
            self.assertIsNone(result["dispatch"])
            self.assertTrue(
                any("ledger schema line 1" in error for error in result["errors"]),
                result,
            )
            self.assertEqual("", stderr.getvalue())

    def test_reservation_is_atomic_and_copied_skill_keeps_contract_checker(self) -> None:
        envelope = approved_envelope()
        grant = envelope["action_grants"][0]
        request = action_request(envelope, grant)
        with tempfile.TemporaryDirectory() as directory:
            run_root = Path(directory)
            coordinator_state = run_root / "coordinator.json"
            resource_coordinator.bootstrap_state(
                coordinator_state, legacy_leases_quiesced=True
            )
            coordinator_binding = {
                "state_path": str(coordinator_state),
                "coordinator_instance_id": resource_coordinator.status(
                    coordinator_state
                )["coordinator_instance_id"],
                "script_sha256": "sha256:" + hashlib.sha256(
                    (ROOT / "skills" / "agent-harness" / "scripts" / "resource_coordinator.py").read_bytes()
                ).hexdigest(),
                "contract_bundle_sha256": resource_coordinator.contract_bundle_sha256(
                    ROOT / "skills" / "agent-harness"
                ),
            }
            authorization_path = run_root / "authorization.json"
            authorization_path.write_text(json.dumps(envelope), encoding="utf-8")
            policy_path = run_root / "policy.json"
            policy_path.write_text(json.dumps(policy_overlay()), encoding="utf-8")
            records = authorization_ledger(envelope, grant)
            ledger_path = run_root / "ledger.jsonl"
            ledger_path.write_text(
                "\n".join(json.dumps(item) for item in records) + "\n",
                encoding="utf-8",
            )
            ledger_path.chmod(0o600)
            harness = validator.load_json(
                ROOT / "skills" / "agent-harness" / "templates" / "harness.json"
            )
            harness.update(
                {
                    "$schema": (
                        ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
                        / "harness.schema.json"
                    ).resolve().as_uri(),
                    "authoritative_root": str(ROOT),
                    "xcode_container": str(ROOT / "Fixture.xcodeproj"),
                    "private_policy_overlay": str(policy_path),
                    "run_authorization": str(authorization_path),
                    "run_ledger": str(ledger_path),
                    "resource_coordinator": coordinator_binding,
                }
            )
            harness["agent_skills"]["installations"]["codex"] = {
                "collection_root": str(ROOT / "skills")
            }
            harness_path = run_root / "private-harness.json"
            harness_path.write_text(json.dumps(harness), encoding="utf-8")
            harness_sha256 = resource_coordinator._portable_document_sha256(harness)
            run_authority = fixture_run_authority(
                envelope,
                harness_sha256=harness_sha256,
                ledger_path=ledger_path,
            )
            resource_coordinator.register_run_authority(
                coordinator_state,
                envelope["run_id"],
                run_authority,
            )
            live_receipt = resource_coordinator.acquire(
                coordinator_state,
                resource=request["lease_resource"],
                descriptor=request["resource_descriptor"],
                owner_run_id=envelope["run_id"],
                owner_actor=request["lease_owner"],
                ttl_seconds=3600,
                run_authority=run_authority,
            )
            request["lease_id"] = live_receipt["lease_id"]
            request["coordinator_receipt"] = live_receipt
            lease_payload = records[-1]["payload"]
            lease_payload["lease_id"] = live_receipt["lease_id"]
            lease_payload["coordinator_receipt"] = live_receipt
            lease_payload["acquired_at"] = live_receipt["acquired_at"]
            lease_payload["expires_at"] = live_receipt["expires_at"]
            records[-1]["recorded_at"] = live_receipt["acquired_at"]
            ledger_path.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
            fresh_health = copy.deepcopy(envelope["health_attestation"])
            fresh_health["observed_at"] = datetime.now(timezone.utc).isoformat().replace(
                "+00:00", "Z"
            )
            def reserve() -> tuple[list[str], dict | None]:
                return check_authorization.reserve_action(
                    ledger_path,
                    envelope,
                    copy.deepcopy(request),
                    run_root,
                    policy_overlay(),
                    live_repository(envelope),
                    coordinator_state=coordinator_state,
                    coordinator_binding=coordinator_binding,
                    selected_writer=envelope["selected_writer"],
                    trusted_harness_sha256=harness_sha256,
                    verified_health_attestation=copy.deepcopy(fresh_health),
                )
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: reserve(), range(2)))
            self.assertEqual(
                1,
                sum(
                    not errors and reservation is not None
                    for errors, reservation in results
                ),
                results,
            )
            self.assertEqual(1, sum(any("single-use" in error for error in errors) for errors, _ in results))
            reservation = next(
                item for errors, item in results if not errors and item is not None
            )
            stable_repository = live_repository(envelope)
            persisted = check_authorization.load_ledger(ledger_path)
            persisted_reservation = next(
                record
                for record in persisted
                if record.get("record_type") == "grant_reservation"
            )
            persisted_reservation["payload"][
                "repository_observation_sha256"
            ] = "sha256:" + check_authorization.canonical_sha256(
                stable_repository
            )
            ledger_path.write_text(
                "\n".join(json.dumps(item) for item in persisted) + "\n",
                encoding="utf-8",
            )
            health_path = run_root / "health.json"
            health_path.write_text("{}", encoding="utf-8")
            request_path = run_root / "request.json"
            request_path.write_text(json.dumps(request), encoding="utf-8")

            def dispatch_once() -> tuple[list[str], dict | None]:
                return check_authorization.verify_reserved_action(
                    ledger_path,
                    reservation["payload"]["reservation_id"],
                    run_root,
                    coordinator_state,
                    coordinator_binding,
                    health_path,
                    harness_path,
                    request_path=request_path,
                )

            drifted_request = copy.deepcopy(request)
            drifted_request["operation_input"] = {"state": "drifted"}
            request_path.write_text(json.dumps(drifted_request), encoding="utf-8")
            with patch.object(
                check_authorization,
                "verify_health_report",
                return_value=([], copy.deepcopy(fresh_health)),
            ):
                request_errors, request_dispatch = dispatch_once()
            self.assertIsNone(request_dispatch)
            self.assertTrue(
                any("action request drifted" in error for error in request_errors),
                request_errors,
            )
            request_path.write_text(json.dumps(request), encoding="utf-8")

            drifted_repository = copy.deepcopy(stable_repository)
            drifted_repository["staged_diff_sha256"] = "4" * 64
            with (
                patch.object(
                    check_authorization,
                    "verify_health_report",
                    return_value=([], copy.deepcopy(fresh_health)),
                ),
                patch.object(
                    check_authorization,
                    "observe_repository",
                    return_value=drifted_repository,
                ),
            ):
                drift_errors, drift_dispatch = dispatch_once()
            self.assertIsNone(drift_dispatch)
            self.assertTrue(
                any("repository observation drifted" in error for error in drift_errors),
                drift_errors,
            )

            with (
                patch.object(
                    check_authorization,
                    "verify_health_report",
                    return_value=([], copy.deepcopy(fresh_health)),
                ),
                patch.object(
                    check_authorization,
                    "observe_repository",
                    return_value=stable_repository,
                ),
            ):
                near_expiry = datetime.fromisoformat(
                    live_receipt["expires_at"].replace("Z", "+00:00")
                ) - timedelta(seconds=20)
                short_errors, short_dispatch = check_authorization.verify_reserved_action(
                    ledger_path,
                    reservation["payload"]["reservation_id"],
                    run_root,
                    coordinator_state,
                    coordinator_binding,
                    health_path,
                    harness_path,
                    now=near_expiry,
                    request_path=request_path,
                )
                self.assertIsNone(short_dispatch)
                self.assertTrue(
                    any("dispatch window is too short" in error for error in short_errors),
                    short_errors,
                )
                with ThreadPoolExecutor(max_workers=2) as pool:
                    dispatch_results = list(
                        pool.map(lambda _: dispatch_once(), range(2))
                    )
                self.assertEqual(
                    1,
                    sum(
                        not errors and item is not None
                        for errors, item in dispatch_results
                    ),
                    dispatch_results,
                )
                dispatch = next(
                    item
                    for errors, item in dispatch_results
                    if not errors and item is not None
                )
                repeated_errors, repeated_dispatch = dispatch_once()
            self.assertEqual(
                reservation["payload"]["reservation_id"],
                dispatch["reservation_id"],
            )
            verified_at = datetime.fromisoformat(
                dispatch["verified_at"].replace("Z", "+00:00")
            )
            dispatch_deadline = datetime.fromisoformat(
                dispatch["dispatch_deadline"].replace("Z", "+00:00")
            )
            self.assertLessEqual(
                (dispatch_deadline - verified_at).total_seconds(),
                check_authorization.MAX_DISPATCH_WINDOW_SECONDS,
            )
            self.assertIsNone(repeated_dispatch)
            self.assertTrue(any("already claimed" in error for error in repeated_errors))
            copied = run_root / "agent-harness-copy"
            shutil.copytree(ROOT / "skills" / "agent-harness", copied)
            probe = "import json,sys; sys.path.insert(0,sys.argv[1]); import check_authorization as c; print(c._ledger_contract_errors(json.load(open(sys.argv[2]))))"
            records_path = run_root / "records.json"
            records_path.write_text(json.dumps(records), encoding="utf-8")
            completed = subprocess.run([sys.executable, "-c", probe, str(copied / "scripts"), str(records_path)], check=True, capture_output=True, text=True)
            self.assertEqual("[]", completed.stdout.strip())

    def test_dispatch_revalidates_spec_kit_and_apple_observations(self) -> None:
        checkpoint = {"run_id": "workflow-1", "state": {"sha256": "1" * 64}}
        snapshot = {
            "spec_kit_release": "v1.0.1",
            "feature_id": "feature-one",
            "feature_directory": "specs/feature-one",
            "snapshot_sha256": "2" * 64,
            "artifact_hashes": {"specs/feature-one/spec.md": "3" * 64},
            "workflow_checkpoint": checkpoint,
        }
        authorization = {
            "spec_kit": {
                "release": snapshot["spec_kit_release"],
                "feature_id": snapshot["feature_id"],
                "feature_directory": snapshot["feature_directory"],
                "approved_git_branch": "codex/feature-one",
                "snapshot_sha256": snapshot["snapshot_sha256"],
                "workflow_run_id": "workflow-1",
                "artifact_hashes": snapshot["artifact_hashes"],
            }
        }
        reservation = {
            "action": "git.commit",
            "spec_checkpoint_sha256": check_authorization.canonical_sha256(
                checkpoint
            ),
            "apple_observation_sha256": None,
        }
        with patch.object(
            check_authorization.spec_kit_snapshot,
            "build_snapshot",
            return_value=copy.deepcopy(snapshot),
        ):
            self.assertEqual(
                [],
                check_authorization._dispatch_spec_state_errors(
                    authorization,
                    reservation,
                    {"authoritative_root": str(ROOT)},
                ),
            )
        drifted_snapshot = copy.deepcopy(snapshot)
        drifted_snapshot["workflow_checkpoint"] = {
            "run_id": "workflow-1",
            "state": {"sha256": "4" * 64},
        }
        with patch.object(
            check_authorization.spec_kit_snapshot,
            "build_snapshot",
            return_value=drifted_snapshot,
        ):
            errors = check_authorization._dispatch_spec_state_errors(
                authorization,
                reservation,
                {"authoritative_root": str(ROOT)},
            )
        self.assertTrue(any("checkpoint drifted" in error for error in errors), errors)

        apple_authorization = testflight_envelope()
        now = datetime.now(timezone.utc)
        apple = apple_authorization["apple"]
        observation = {
            "source": "asc_read_only",
            "guard_verified": True,
            "observed_at": now.isoformat().replace("+00:00", "Z"),
            "account_guard_ref": apple["account_guard_ref"],
            "team_id": apple["team_id"],
            "app_id": apple["app_id"],
            "bundle_id": apple["bundle_id"],
            "platform": apple["platform"],
            "live_build": apple["build_policy"]["baseline"],
            "internal_group_ids": apple["internal_group_ids"],
        }
        apple_reservation = {
            "action": "apple.testflight.upload",
            "spec_checkpoint_sha256": None,
            "apple_observation_sha256": check_authorization.canonical_sha256(
                observation
            ),
            "apple_observation_state_sha256": (
                check_authorization.apple_observation_state_sha256(observation)
            ),
        }
        with tempfile.TemporaryDirectory() as directory:
            probe = Path(directory).resolve() / "asc-observation-probe"
            probe.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            probe.chmod(0o700)
            harness = {
                "apple_observation_probe": {
                    "executable": str(probe),
                    "executable_sha256": "sha256:"
                    + hashlib.sha256(probe.read_bytes()).hexdigest(),
                    "output_contract": "apple_observation_v1",
                    "timeout_seconds": 10,
                }
            }

            def apple_runner(
                command: list[str], **kwargs: object
            ) -> subprocess.CompletedProcess[str]:
                self.assertEqual([str(probe)], command)
                return subprocess.CompletedProcess(
                    command, 0, stdout=json.dumps(observation), stderr=""
                )

            self.assertEqual(
                [],
                check_authorization._dispatch_apple_state_errors(
                    apple_authorization,
                    apple_reservation,
                    harness,
                    now - timedelta(seconds=1),
                    now,
                    runner=apple_runner,
                ),
            )
            drifted_observation = copy.deepcopy(observation)
            drifted_observation["live_build"] = "999"

            def drifted_runner(
                command: list[str], **kwargs: object
            ) -> subprocess.CompletedProcess[str]:
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout=json.dumps(drifted_observation),
                    stderr="",
                )

            errors = check_authorization._dispatch_apple_state_errors(
                apple_authorization,
                apple_reservation,
                harness,
                now - timedelta(seconds=1),
                now,
                runner=drifted_runner,
            )
            cached_observation = copy.deepcopy(observation)
            cached_observation["observed_at"] = (
                now - timedelta(seconds=2)
            ).isoformat().replace("+00:00", "Z")

            def cached_runner(
                command: list[str], **kwargs: object
            ) -> subprocess.CompletedProcess[str]:
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout=json.dumps(cached_observation),
                    stderr="",
                )

            cached_errors = check_authorization._dispatch_apple_state_errors(
                apple_authorization,
                apple_reservation,
                harness,
                now - timedelta(seconds=1),
                now,
                runner=cached_runner,
            )
        self.assertTrue(
            any("baseline drifted" in error for error in errors), errors
        )
        self.assertTrue(
            any("state drifted" in error for error in errors), errors
        )
        self.assertTrue(
            any("predates" in error for error in cached_errors), cached_errors
        )

    def test_action_checker_rejects_split_brain_or_drifted_coordinator_binding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state_a = root / "coordinator-a.json"
            state_b = root / "coordinator-b.json"
            resource_coordinator.bootstrap_state(state_a, legacy_leases_quiesced=True)
            resource_coordinator.bootstrap_state(state_b, legacy_leases_quiesced=True)
            script = ROOT / "skills" / "agent-harness" / "scripts" / "resource_coordinator.py"
            binding_a = {
                "state_path": str(state_a),
                "coordinator_instance_id": resource_coordinator.status(state_a)["coordinator_instance_id"],
                "script_sha256": "sha256:" + hashlib.sha256(script.read_bytes()).hexdigest(),
                "contract_bundle_sha256": resource_coordinator.contract_bundle_sha256(
                    ROOT / "skills" / "agent-harness"
                ),
            }
            self.assertEqual(
                [], check_authorization.validate_coordinator_binding(state_a, binding_a)
            )
            self.assertTrue(
                check_authorization.validate_coordinator_binding(state_b, binding_a)
            )
            drifted = copy.deepcopy(binding_a)
            drifted["script_sha256"] = "sha256:" + "0" * 64
            self.assertTrue(
                check_authorization.validate_coordinator_binding(state_a, drifted)
            )
    def test_testflight_authorization_is_limited_to_named_internal_group(self) -> None:
        envelope = testflight_envelope()
        self.assertEqual([], check_authorization.validate_authorization(envelope))
        group_grant = next(item for item in envelope["action_grants"] if item["grant_id"] == "distribution")
        self.assertEqual("app:123:group:group-a", group_grant["target"])
        mutated = copy.deepcopy(envelope)
        mutated["apple"]["internal_group_ids"] = ["group-b"]
        self.assertTrue(
            any(
                "exactly match" in error or "canonical" in error
                for error in check_authorization.validate_authorization(mutated)
            )
        )
        mutated = copy.deepcopy(envelope)
        mutated["action_grants"].append({
            **group_grant,
            "grant_id": "forbidden-review",
            "action": "apple.app_review_submit",
            "operation": "submit",
            "operation_input": {"submit": True},
            "constraint_sha256": check_authorization.canonical_sha256({"submit": True}),
            "idempotency_key": "forbidden-review",
        })
        self.assertTrue(
            any(
                "forbidden" in error or "not allowlisted" in error
                for error in check_authorization.validate_authorization(mutated)
            )
        )

    def test_spec_kit_snapshot_uses_feature_directory_and_allows_run_progress(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pointer = root / ".specify" / "feature.json"
            pointer.parent.mkdir(parents=True)
            pointer.write_text(
                '{"feature_directory":"specs/001-example"}', encoding="utf-8"
            )
            feature = root / "specs" / "001-example"
            feature.mkdir(parents=True)
            for name in ("spec.md", "plan.md", "tasks.md"):
                (feature / name).write_text(f"accepted {name}", encoding="utf-8")
            run = root / ".specify" / "workflows" / "runs" / "run-1"
            run.mkdir(parents=True)
            (run / "state.json").write_text(
                '{"run_id":"run-1","workflow_id":"speckit","status":"paused","current_step_index":1}',
                encoding="utf-8",
            )
            (run / "inputs.json").write_text('{"inputs":{}}', encoding="utf-8")
            (run / "log.jsonl").write_text('{"event":"one"}\n', encoding="utf-8")

            expected = spec_kit_snapshot.build_snapshot(
                root,
                feature_directory="specs/001-example",
                run_id="run-1",
            )
            self.assertEqual("001-example", expected["feature_id"])
            self.assertNotIn("git_branch", expected)
            self.assertTrue(
                all(
                    not item["path"].startswith(".specify/workflows/runs/")
                    for item in expected["accepted_artifacts"]
                )
            )

            (run / "state.json").write_text(
                '{"run_id":"run-1","workflow_id":"speckit","status":"running","current_step_index":2}',
                encoding="utf-8",
            )
            (run / "inputs.json").write_text(
                '{"inputs":{"verdict":"approved"}}', encoding="utf-8"
            )
            with (run / "log.jsonl").open("a", encoding="utf-8") as handle:
                handle.write('{"event":"two"}\n')
            current = spec_kit_snapshot.build_snapshot(
                root,
                feature_directory="specs/001-example",
                run_id="run-1",
            )
            self.assertEqual(expected["snapshot_sha256"], current["snapshot_sha256"])
            self.assertEqual([], spec_kit_snapshot.verify_snapshot(expected, expected))
            self.assertEqual([], spec_kit_snapshot.verify_snapshot(expected, current))

    def test_spec_kit_snapshot_rejects_escape_stale_pointer_and_missing_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pointer = root / ".specify" / "feature.json"
            pointer.parent.mkdir(parents=True)
            pointer.write_text(
                '{"feature_directory":"specs/001-example"}', encoding="utf-8"
            )
            feature = root / "specs" / "001-example"
            feature.mkdir(parents=True)
            for name in ("spec.md", "plan.md", "tasks.md"):
                (feature / name).write_text(name, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "approved feature_directory"):
                spec_kit_snapshot.build_snapshot(root)

            with self.assertRaisesRegex(ValueError, "pointer is stale"):
                spec_kit_snapshot.build_snapshot(
                    root, feature_directory="specs/002-other"
                )

            pointer.write_text(
                '{"feature_directory":"specs/../outside"}', encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "exactly specs/<feature>"):
                spec_kit_snapshot.build_snapshot(root, discovery=True)

            pointer.write_text(
                '{"feature_directory":"specs/001-example"}', encoding="utf-8"
            )
            (feature / "tasks.md").unlink()
            with self.assertRaisesRegex(ValueError, "missing selected feature artifact"):
                spec_kit_snapshot.build_snapshot(
                    root, feature_directory="specs/001-example"
                )
            (feature / "tasks.md").write_text("tasks", encoding="utf-8")

            run = root / ".specify" / "workflows" / "runs" / "run-1"
            run.mkdir(parents=True)
            (run / "state.json").write_text(
                '{"run_id":"run-1","workflow_id":"speckit","status":"created"}',
                encoding="utf-8",
            )
            (run / "inputs.json").write_text('{"inputs":{}}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing Spec Kit workflow log"):
                spec_kit_snapshot.build_snapshot(
                    root,
                    feature_directory="specs/001-example",
                    run_id="run-1",
                )

    def test_spec_kit_snapshot_detects_artifact_drift_and_log_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pointer = root / ".specify" / "feature.json"
            pointer.parent.mkdir(parents=True)
            pointer.write_text(
                '{"feature_directory":"specs/001-example"}', encoding="utf-8"
            )
            feature = root / "specs" / "001-example"
            feature.mkdir(parents=True)
            for name in ("spec.md", "plan.md", "tasks.md"):
                (feature / name).write_text(name, encoding="utf-8")
            run = root / ".specify" / "workflows" / "runs" / "run-1"
            run.mkdir(parents=True)
            (run / "state.json").write_text(
                '{"run_id":"run-1","workflow_id":"speckit","status":"paused"}',
                encoding="utf-8",
            )
            (run / "inputs.json").write_text('{"inputs":{}}', encoding="utf-8")
            log = run / "log.jsonl"
            log.write_text('{"event":"one"}\n{"event":"two"}\n', encoding="utf-8")
            expected = spec_kit_snapshot.build_snapshot(
                root, feature_directory="specs/001-example", run_id="run-1"
            )

            (feature / "spec.md").write_text("changed", encoding="utf-8")
            changed = spec_kit_snapshot.build_snapshot(
                root, feature_directory="specs/001-example", run_id="run-1"
            )
            self.assertTrue(
                any(
                    "accepted Spec Kit artifact" in error
                    for error in spec_kit_snapshot.verify_snapshot(expected, changed)
                )
            )
            (feature / "spec.md").write_text("spec.md", encoding="utf-8")

            log.write_text(
                '{"event":"rewritten"}\n{"event":"two"}\n', encoding="utf-8"
            )
            rewritten = spec_kit_snapshot.build_snapshot(
                root, feature_directory="specs/001-example", run_id="run-1"
            )
            self.assertTrue(
                any(
                    "log was rewritten" in error
                    for error in spec_kit_snapshot.verify_snapshot(expected, rewritten)
                )
            )

            log.write_text('{"event":"one"}\n', encoding="utf-8")
            truncated = spec_kit_snapshot.build_snapshot(
                root, feature_directory="specs/001-example", run_id="run-1"
            )
            self.assertTrue(
                any(
                    "log was truncated" in error
                    for error in spec_kit_snapshot.verify_snapshot(expected, truncated)
                )
            )

    def test_health_evaluator_keeps_required_blocker_and_redacts_evidence(self) -> None:
        report = health_report("runtime_ui", selected_components=["xcode_mcp"])
        check = next(item for item in report["checks"] if item["id"] == "mcp.xcode")
        check.update(status="blocked", evidence=["Bearer secret-value"], next_action="Repair provider.")
        evaluated, errors = evaluate_health_fixture(
            report, now=datetime(2026, 8, 29, 0, 1, tzinfo=timezone.utc)
        )
        self.assertEqual([], errors)
        self.assertEqual("blocked", evaluated["overall_status"])
        self.assertEqual("<redacted>", next(item for item in evaluated["checks"] if item["id"] == "mcp.xcode")["evidence"][0])

    def test_health_placeholder_cannot_claim_live_github_success(self) -> None:
        report = health_report(
            "pr_ready",
            observed_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        evaluated, errors = evaluate_health.evaluate(report)
        self.assertEqual("blocked", evaluated["overall_status"])
        self.assertIn(
            "required health check needs evaluator-owned live observation: github.issue_pr",
            errors,
        )

    def test_live_health_overwrites_forged_github_success_with_probe_failure(self) -> None:
        report = health_report(
            "pr_ready",
            observed_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        report["authoritative_targets"] = {
            "repository": "/example",
            "remote": "https://github.com/example/repository.git",
            "branch": "codex/example",
        }
        harness = {"agent_skills": {"installations": {"codex": {}, "claude": None}}}
        policy = {"github": {"owner": "example"}, "apple": None}

        def missing_cli(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            raise FileNotFoundError("gh")

        observations = evaluate_health.collect_live_observations(
            report, harness, policy, None, runner=missing_cli
        )
        reconciled = evaluate_health.reconcile_live_observations(report, observations)
        check = next(item for item in reconciled["checks"] if item["id"] == "github.issue_pr")
        self.assertEqual("blocked", check["status"])
        self.assertTrue(check["evidence"][0].startswith("evaluator-live:github.issue_pr:"))
        evaluated, errors = evaluate_health.evaluate(
            reconciled, evaluator_observed_check_ids=set(observations)
        )
        self.assertEqual([], errors)
        self.assertEqual("blocked", evaluated["overall_status"])

    def test_simulator_health_timeout_is_read_only_and_never_reboots(self) -> None:
        commands: list[list[str]] = []

        def timeout_runner(
            command: list[str], **kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            commands.append(command)
            raise subprocess.TimeoutExpired(command, 30)

        observations = evaluate_health.collect_live_observations(
            {"required_check_ids": ["simulator.runtime"]},
            {"agent_skills": {"installations": {"codex": None, "claude": None}}},
            {"github": {"owner": "example"}, "apple": None},
            None,
            runner=timeout_runner,
        )
        self.assertEqual("blocked", observations["simulator.runtime"]["status"])
        self.assertEqual(
            [["/usr/bin/xcrun", "simctl", "list", "runtimes", "--json"]],
            commands,
        )
        flattened = " ".join(commands[0]).lower()
        for forbidden in ("boot", "shutdown", "delete", "erase", "kill", "reboot"):
            self.assertNotIn(forbidden, flattened)

    def test_apple_guard_mismatch_blocks_before_any_asc_discovery(self) -> None:
        commands: list[list[str]] = []

        def unexpected_runner(
            command: list[str], **kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            commands.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        observations = evaluate_health.collect_live_observations(
            {"required_check_ids": ["apple.account_guard", "cli.asc"]},
            {"agent_skills": {"installations": {"codex": None, "claude": None}}},
            {
                "github": {"owner": "example"},
                "apple": {"account_guard_ref": "personal", "team_id": "TEAM-A"},
            },
            {"apple": {"account_guard_ref": "personal", "team_id": "TEAM-B"}},
            runner=unexpected_runner,
        )
        self.assertEqual([], commands)
        self.assertEqual("blocked", observations["apple.account_guard"]["status"])
        self.assertEqual("blocked", observations["cli.asc"]["status"])

    def test_unselected_mcp_is_not_probed(self) -> None:
        calls: list[str] = []

        def forbidden_probe() -> tuple[bool, object]:
            calls.append("mcp")
            return False, {}

        observations = evaluate_health.collect_live_observations(
            {"required_check_ids": ["github.issue_pr"]},
            {"agent_skills": {"installations": {"codex": None, "claude": None}}},
            {"github": {"owner": "example"}, "apple": None},
            None,
            runner=lambda *args, **kwargs: (_ for _ in ()).throw(FileNotFoundError()),
            xcode_mcp_probe=forbidden_probe,
            apple_sample_code_probe=forbidden_probe,
        )
        self.assertEqual([], calls)
        self.assertNotIn("mcp.xcode", observations)
        self.assertNotIn("mcp.apple_sample_code", observations)

    def test_mcp_registration_without_read_only_connectivity_is_blocked(self) -> None:
        commands: list[list[str]] = []

        def registered_runner(
            command: list[str], **kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            commands.append(command)
            return subprocess.CompletedProcess(
                command, 0,
                stdout="apple-sample-code https://mcp.applesamplecode.com/mcp",
                stderr="",
            )

        observations = evaluate_health.collect_live_observations(
            {"required_check_ids": ["mcp.apple_sample_code"]},
            {"agent_skills": {"installations": {"codex": {}, "claude": None}}},
            {"github": {"owner": "example"}, "apple": None},
            None,
            runner=registered_runner,
            apple_sample_code_probe=lambda: (False, {"failure": "offline"}),
        )
        self.assertEqual(
            [["codex", "mcp", "get", "apple-sample-code", "--json"]], commands
        )
        self.assertEqual("blocked", observations["mcp.apple_sample_code"]["status"])

    def test_optional_health_failure_is_degraded_not_blocked(self) -> None:
        report = health_report("pr_ready")
        report["checks"].append({"id": "local_llm", "category": "local_llm", "required": False,
                                 "status": "blocked", "summary": "Optional loopback model is unavailable.",
                                 "evidence": ["connection refused"], "next_action": "Continue without Local LLM."})
        evaluated, errors = evaluate_health_fixture(
            report, now=datetime(2026, 8, 29, 0, 1, tzinfo=timezone.utc)
        )
        self.assertEqual([], errors)
        self.assertEqual("degraded", evaluated["overall_status"])

    def test_required_specialized_health_cannot_be_caller_self_attested(self) -> None:
        cases = [
            ("icon_upstream", []),
            ("pr_ready", ["spec_kit"]),
            ("pr_ready", ["local_llm"]),
        ]
        for profile, components in cases:
            with self.subTest(profile=profile, components=components):
                report = health_report(profile, selected_components=components)
                evaluated, errors = evaluate_health.evaluate(
                    report,
                    now=datetime(2026, 8, 29, 0, 1, tzinfo=timezone.utc),
                    evaluator_observed_check_ids=(
                        set(report["required_check_ids"])
                        & evaluate_health.EVALUATOR_OWNED_CHECKS
                        - {
                            "companion_upstream.provenance",
                            "spec_kit.snapshot",
                            "local_llm",
                        }
                    ),
                )
                self.assertEqual("blocked", evaluated["overall_status"])
                self.assertTrue(
                    any("evaluator-owned live observation" in error for error in errors),
                    errors,
                )

    def test_specialized_health_collectors_accept_live_readbacks_and_reject_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            repository.mkdir()
            pointer = repository / ".specify" / "feature.json"
            pointer.parent.mkdir(parents=True)
            pointer.write_text('{"feature_directory":"specs/001-health"}', encoding="utf-8")
            feature = repository / "specs" / "001-health"
            feature.mkdir(parents=True)
            for name in ("spec.md", "plan.md", "tasks.md"):
                (feature / name).write_text(name, encoding="utf-8")
            run = repository / ".specify" / "workflows" / "runs" / "health-run"
            run.mkdir(parents=True)
            (run / "state.json").write_text('{"run_id":"health-run","workflow_id":"speckit","status":"paused"}', encoding="utf-8")
            (run / "inputs.json").write_text('{"inputs":{}}', encoding="utf-8")
            (run / "log.jsonl").write_text('{"event":"bound"}\n', encoding="utf-8")
            snapshot = spec_kit_snapshot.build_snapshot(
                repository, feature_directory="specs/001-health", run_id="health-run"
            )
            harness = {
                "selected_writer": "codex",
                "spec_kit": {"enabled": True, "release": "v1.0.1"},
                "agent_skills": {"installations": {"codex": {"collection_root": str(ROOT / "skills")}, "claude": None}},
            }
            report = {"authoritative_targets": {"repository": str(repository)}, "required_check_ids": ["spec_kit.snapshot", "local_llm"]}
            authorization = {"spec_kit": {
                "release": "v1.0.1", "feature_id": snapshot["feature_id"],
                "feature_directory": snapshot["feature_directory"], "approved_git_branch": "main",
                "snapshot_sha256": snapshot["snapshot_sha256"], "workflow_run_id": "health-run",
                "artifact_hashes": snapshot["artifact_hashes"],
            }}

            def live_runner(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                self.assertEqual(["ollama", "list"], command)
                return subprocess.CompletedProcess(command, 0, stdout="NAME ID SIZE MODIFIED\nqwen3:8b abc 1 GB now\n", stderr="")

            observations = evaluate_health.collect_live_observations(
                report, harness, {"github": {"owner": "example"}, "apple": None}, authorization,
                runner=live_runner,
            )
            self.assertEqual("healthy", observations["spec_kit.snapshot"]["status"])
            self.assertEqual("healthy", observations["local_llm"]["status"])
            with patch.dict(
                os.environ,
                {"OLLAMA_HOST": "https://remote.example:11434"},
            ):
                remote_llm = evaluate_health.collect_live_observations(
                    {
                        "authoritative_targets": {"repository": str(repository)},
                        "required_check_ids": ["local_llm"],
                    },
                    harness,
                    {"github": {"owner": "example"}, "apple": None},
                    authorization,
                    runner=live_runner,
                )
            self.assertEqual("blocked", remote_llm["local_llm"]["status"])
            authorization["spec_kit"]["snapshot_sha256"] = "0" * 64
            forged = evaluate_health.collect_live_observations(
                {"authoritative_targets": {"repository": str(repository)}, "required_check_ids": ["spec_kit.snapshot"]},
                harness, {"github": {"owner": "example"}, "apple": None}, authorization,
                runner=live_runner,
            )
            self.assertEqual("blocked", forged["spec_kit.snapshot"]["status"])

    def test_companion_provenance_cli_collector_rejects_forged_source_blob(self) -> None:
        harness = {
            "selected_writer": "codex",
            "agent_skills": {"installations": {"codex": {"collection_root": str(ROOT / "skills")}, "claude": None}},
        }
        manifest = validator.load_json(ROOT / "skills" / "icon-composer" / "contracts" / "companion-upstream.json")
        upstream = manifest["upstream"]
        blobs = [{"path": item["path"], "sha": item["blob_sha"], "type": "blob"} for item in manifest["sources"]]

        def runner(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            endpoint = command[-1]
            if endpoint == f"repos/{upstream['repository']}":
                payload = {"private": False, "visibility": "public", "default_branch": upstream["default_branch"]}
            elif endpoint.endswith(f"commits/{upstream['reviewed_revision']}"):
                payload = {"sha": upstream["reviewed_revision"], "commit": {"tree": {"sha": upstream["reviewed_tree"]}}}
            elif "/git/trees/" in endpoint:
                payload = {"tree": blobs}
            else:
                payload = {"sha": "a" * 40}
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps(payload), stderr="")

        report = {"required_check_ids": ["companion_upstream.provenance"]}
        observations = evaluate_health.collect_live_observations(
            report, harness, {"github": {"owner": "example"}, "apple": None}, None, runner=runner
        )
        self.assertEqual("healthy", observations["companion_upstream.provenance"]["status"])
        blobs[0]["sha"] = "f" * 40
        forged = evaluate_health.collect_live_observations(
            report, harness, {"github": {"owner": "example"}, "apple": None}, None, runner=runner
        )
        self.assertEqual("blocked", forged["companion_upstream.provenance"]["status"])

    def test_health_rejects_stale_future_and_wrong_harness_targets(self) -> None:
        report = health_report("pr_ready")
        now = datetime(2026, 8, 29, 0, 11, tzinfo=timezone.utc)
        self.assertTrue(any("stale" in error for error in evaluate_health_fixture(report, now=now)[1]))
        report["observed_at"] = "2026-08-29T00:13:00Z"
        self.assertTrue(any("future" in error for error in evaluate_health_fixture(report, now=now)[1]))
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            repository.mkdir()
            subprocess.run(["git", "init", "-b", "main", str(repository)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repository), "remote", "add", "origin", "https://github.com/example/repository.git"], check=True)
            live = health_report("pr_ready")
            remote = subprocess.run(["git", "-C", str(repository), "remote", "get-url", "origin"], check=True, capture_output=True, text=True).stdout.strip()
            branch = subprocess.run(["git", "-C", str(repository), "branch", "--show-current"], check=True, capture_output=True, text=True).stdout.strip()
            live["authoritative_targets"] = {"repository": str(repository.resolve()), "remote": remote, "branch": branch}
            harness = {"authoritative_root": str(repository)}
            coordinator_state = bind_resource_coordinator(harness, live, Path(directory))
            self.assertEqual([], evaluate_health.validate_harness_binding(live, harness))
            unrelated_authority = fixture_run_authority(
                run_id="other-run", actor="claude"
            )
            resource_coordinator.register_run_authority(
                coordinator_state, "other-run", unrelated_authority
            )
            unrelated = resource_coordinator.acquire(
                coordinator_state,
                resource=resource_coordinator.GITHUB,
                descriptor={
                    "repository_fingerprint": "sha256:" + "a" * 64,
                    "remote_repository": "example/other-repository",
                },
                owner_run_id="other-run",
                owner_actor="claude",
                ttl_seconds=60,
                run_authority=unrelated_authority,
            )
            self.assertEqual([], evaluate_health.validate_harness_binding(live, harness))
            resource_coordinator.release(
                coordinator_state,
                unrelated,
                run_authority=unrelated_authority,
            )
            malformed_components = copy.deepcopy(live)
            malformed_components["selected_components"] = None
            self.assertIn(
                "health report selected_components are invalid",
                evaluate_health_fixture(malformed_components)[1],
            )
            self.assertEqual(
                [],
                evaluate_health.validate_harness_binding(
                    malformed_components, harness
                ),
            )
            live["authoritative_targets"]["branch"] = "wrong"
            self.assertTrue(evaluate_health.validate_harness_binding(live, harness))

    def test_copied_health_skill_blocks_when_agent_harness_dependency_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            copied = root / "apple-development-health"
            shutil.copytree(ROOT / "skills" / "apple-development-health", copied)
            state = root / "coordinator.json"
            resource_coordinator.bootstrap_state(state, legacy_leases_quiesced=True)
            harness = {
                "resource_coordinator": {
                    "state_path": str(state),
                    "coordinator_instance_id": resource_coordinator.status(state)["coordinator_instance_id"],
                    "script_sha256": "sha256:" + hashlib.sha256(
                        (ROOT / "skills" / "agent-harness" / "scripts" / "resource_coordinator.py").read_bytes()
                    ).hexdigest(),
                    "contract_bundle_sha256": resource_coordinator.contract_bundle_sha256(
                        ROOT / "skills" / "agent-harness"
                    ),
                }
            }
            probe = (
                "import json,sys; sys.path.insert(0,sys.argv[1]); "
                "import evaluate_health as e; print(json.dumps(e.observe_resource_coordinator(json.load(open(sys.argv[2])))))"
            )
            harness_path = root / "harness.json"
            harness_path.write_text(json.dumps(harness), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, "-c", probe, str(copied / "scripts"), str(harness_path)],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("installed resource coordinator script is unavailable", completed.stdout)

    def test_agent_skill_manifest_detects_mixed_or_missing_client_copy(self) -> None:
        required = [
            "agent-harness",
            "apple-development-health",
            "git-workflow",
            "github-projects",
            "native-app-lead",
        ]
        with tempfile.TemporaryDirectory() as directory:
            claude_root = Path(directory) / "claude-skills"
            claude_root.mkdir()
            for name in required:
                shutil.copytree(ROOT / "skills" / name, claude_root / name)
            harness = {
                "mode": "collaborative",
                "selected_writer": "codex",
                "health_profile": "pr_ready",
                "health_components": [],
                "agent_skills": {
                    "task_skills": ["native-app-lead"],
                    "expected_bundle_sha256": "sha256:" + "0" * 64,
                    "installations": {
                        "codex": {"collection_root": str(ROOT / "skills")},
                        "claude": {"collection_root": str(claude_root)},
                    },
                },
            }
            manifest, errors = evaluate_health.observe_agent_skills(
                harness, enforce_expected=False
            )
            self.assertEqual([], errors)
            self.assertIsNotNone(manifest)
            assert manifest is not None
            self.assertEqual(1, len({item["bundle_sha256"] for item in manifest["clients"]}))
            harness["agent_skills"]["expected_bundle_sha256"] = manifest["clients"][0][
                "bundle_sha256"
            ]
            self.assertEqual([], evaluate_health.observe_agent_skills(harness)[1])
            selected_coordinator = evaluate_health._load_installed_agent_harness_module(
                harness_document=harness
            )
            self.assertTrue(
                Path(selected_coordinator.__file__).resolve().is_relative_to(
                    (ROOT / "skills" / "agent-harness").resolve()
                )
            )

            evaluator = (
                claude_root / "apple-development-health" / "scripts" / "evaluate_health.py"
            )
            evaluator.write_text(
                evaluator.read_text(encoding="utf-8") + "\n# simulated stale client\n",
                encoding="utf-8",
            )
            drift_errors = evaluate_health.observe_agent_skills(harness)[1]
            self.assertTrue(any("bundles differ" in error for error in drift_errors))
            self.assertTrue(any("drifted from the harness" in error for error in drift_errors))

            shutil.rmtree(claude_root / "native-app-lead")
            missing_errors = evaluate_health.observe_agent_skills(harness)[1]
            self.assertTrue(
                any("missing from configured search roots" in error for error in missing_errors)
            )
            (claude_root / "native-app-lead").symlink_to(
                claude_root / "missing-native-app-lead", target_is_directory=True
            )
            broken_errors = evaluate_health.observe_agent_skills(harness)[1]
            self.assertTrue(
                any(
                    "broken" in error and "symlink" in error
                    for error in broken_errors
                ),
                broken_errors,
            )

    def test_agent_skill_manifest_accepts_client_visible_top_level_symlinks(self) -> None:
        required = [
            "agent-harness",
            "apple-development-health",
            "git-workflow",
            "github-projects",
            "native-app-lead",
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_root = root / "source-skills"
            visible_root = root / "client-skills"
            source_root.mkdir()
            visible_root.mkdir()
            for name in required:
                shutil.copytree(ROOT / "skills" / name, source_root / name)
                (visible_root / name).symlink_to(
                    source_root / name, target_is_directory=True
                )
            harness = validator.load_json(
                ROOT / "skills" / "agent-harness" / "templates" / "harness.json"
            )
            harness.update({
                "authoritative_root": str(root),
                "xcode_container": str(root / "Application.xcodeproj"),
                "private_policy_overlay": str(root / "private-policy.json"),
                "run_authorization": str(root / "authorization.json"),
                "run_ledger": str(root / "ledger.jsonl"),
            })
            harness["agent_skills"] = {
                "task_skills": ["native-app-lead"],
                "expected_bundle_sha256": "sha256:" + "0" * 64,
                "installations": {
                    "codex": {"collection_root": str(visible_root)},
                    "claude": None,
                },
            }
            harness_path = root / "harness.json"
            harness_path.write_text(json.dumps(harness), encoding="utf-8")
            evaluator = (
                visible_root
                / "apple-development-health"
                / "scripts"
                / "evaluate_health.py"
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(evaluator),
                    "--harness",
                    str(harness_path),
                    "--observe-agent-skills",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, completed.returncode, completed.stdout)
            observed = json.loads(completed.stdout)
            self.assertTrue(observed["valid"])
            self.assertEqual(
                {"symlink"},
                {
                    item["entry_kind"]
                    for item in observed["manifest"]["clients"][0]["skills"]
                },
            )

            harness["agent_skills"]["installations"]["codex"]["collection_root"] = str(
                ROOT / "skills"
            )
            harness_path.write_text(json.dumps(harness), encoding="utf-8")
            shadowed = subprocess.run(
                [
                    sys.executable,
                    str(evaluator),
                    "--harness",
                    str(harness_path),
                    "--observe-agent-skills",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(2, shadowed.returncode)
            self.assertTrue(
                "running health evaluator is outside the bound skill installations"
                in shadowed.stdout
                or "missing or shadowed across configured roots" in shadowed.stdout,
                shadowed.stdout,
            )

    def test_every_health_profile_resolves_from_the_shipped_skill_collection(self) -> None:
        for profile in sorted(evaluate_health.PROFILES):
            with self.subTest(profile=profile):
                harness = {
                    "mode": "codex",
                    "health_profile": profile,
                    "health_components": [],
                    "agent_skills": {
                        "task_skills": ["native-app-lead"],
                        "expected_bundle_sha256": "sha256:" + "0" * 64,
                        "installations": {
                            "codex": {"collection_root": str(ROOT / "skills")},
                            "claude": None,
                        },
                    },
                }
                manifest, errors = evaluate_health.observe_agent_skills(
                    harness, enforce_expected=False
                )
                self.assertEqual([], errors)
                self.assertIsNotNone(manifest)

    def test_project_registry_schema_is_static_and_path_neutral(self) -> None:
        schema = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
            / "project-registry.schema.json"
        )
        example_path = (
            ROOT / "skills" / "agent-harness" / "templates"
            / "project-registry.local.example.json"
        )
        example = validator.load_json(example_path)
        instance = {key: value for key, value in example.items() if key != "$schema"}
        self.assertEqual([], validator.validate_json_schema(instance, schema))
        self.assertNotIn("/Users/", example_path.read_text(encoding="utf-8"))

        runtime_state = copy.deepcopy(instance)
        runtime_state["projects"][0]["branch"] = "feature/runtime-state"
        self.assertTrue(validator.validate_json_schema(runtime_state, schema))

        relative_path = copy.deepcopy(instance)
        relative_path["projects"][0]["checkouts"][0]["path"] = "../repository"
        self.assertTrue(validator.validate_json_schema(relative_path, schema))

        for unsafe in ("/../repository", "/absolute/../repository", "/absolute/\trepository", "/absolute/\x7frepository"):
            unsafe_path = copy.deepcopy(instance)
            unsafe_path["projects"][0]["checkouts"][0]["path"] = unsafe
            self.assertTrue(validator.validate_json_schema(unsafe_path, schema))

    def test_project_registry_health_component_is_explicit_and_optional(self) -> None:
        harness_schema = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
            / "harness.schema.json"
        )
        report_schema = validator.load_json(
            ROOT / "skills" / "apple-development-health" / "contracts"
            / "health-report.schema.json"
        )
        component = "project_registry"
        self.assertIn(
            component,
            harness_schema["properties"]["health_components"]["items"]["enum"],
        )
        self.assertIn(
            component,
            report_schema["properties"]["selected_components"]["items"]["enum"],
        )
        report = health_report(
            "pr_ready",
            selected_components=[component],
            observed_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        self.assertEqual([], validator.validate_json_schema(report, report_schema))
        evaluated, errors = evaluate_health_fixture(report)
        self.assertEqual([], errors)
        self.assertEqual("healthy", evaluated["overall_status"])

        missing = copy.deepcopy(report)
        missing.pop("project_registry_resolution")
        self.assertIn(
            "selected project registry requires a structured resolution",
            evaluate_health_fixture(missing)[1],
        )

        degraded = copy.deepcopy(report)
        degraded["project_registry_resolution"]["warnings"] = [{
            "project_id": "project-two",
            "checkout_id": "stale",
            "reason_code": "missing_path",
        }]
        registry_check = next(
            item for item in degraded["checks"]
            if item["id"] == "repository.project_registry"
        )
        registry_check["status"] = "degraded"
        registry_check["next_action"] = "Repair the stale private entry outside health."
        evaluated, errors = evaluate_health_fixture(degraded)
        self.assertEqual([], errors)
        self.assertEqual("degraded", evaluated["overall_status"])

        unsafe_warning = copy.deepcopy(degraded)
        unsafe_warning["project_registry_resolution"]["warnings"][0][
            "reason_code"
        ] = "checkout_kind_mismatch"
        self.assertIn(
            "project registry warning is invalid",
            evaluate_health_fixture(unsafe_warning)[1],
        )
        self.assertTrue(
            validator.validate_json_schema(unsafe_warning, report_schema)
        )

        unsafe_container = copy.deepcopy(report)
        unsafe_container["project_registry_resolution"]["candidate"][
            "xcode_containers"
        ] = ["../private.xcodeproj"]
        self.assertIn(
            "project registry candidate Xcode containers are invalid",
            evaluate_health_fixture(unsafe_container)[1],
        )

        duplicate_container = copy.deepcopy(report)
        duplicate_container["project_registry_resolution"]["candidate"][
            "xcode_containers"
        ] = ["Application.xcodeproj", "Application.xcodeproj"]
        self.assertIn(
            "project registry candidate Xcode containers are invalid",
            evaluate_health_fixture(duplicate_container)[1],
        )

        ambiguous = copy.deepcopy(report)
        ambiguous["project_registry_resolution"].update({
            "status": "needs_selection",
            "reason_code": "multiple_candidates",
            "candidate": None,
        })
        registry_check = next(
            item for item in ambiguous["checks"]
            if item["id"] == "repository.project_registry"
        )
        registry_check["status"] = "blocked"
        registry_check["next_action"] = "Select one validated checkout."
        evaluated, errors = evaluate_health_fixture(ambiguous)
        self.assertEqual([], errors)
        self.assertEqual("blocked", evaluated["overall_status"])

    def test_project_registry_health_binds_live_remote_root_and_kind(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            repository.mkdir()
            xcode_container = repository / "Application.xcodeproj"
            xcode_container.mkdir()
            subprocess.run(
                ["git", "init", "-b", "main", str(repository)],
                check=True,
                capture_output=True,
            )
            configured_remote = "git@github.com:example/repository.git"
            subprocess.run(
                ["git", "-C", str(repository), "remote", "add", "origin", configured_remote],
                check=True,
            )
            remote = subprocess.run(
                ["git", "-C", str(repository), "remote", "get-url", "origin"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            branch = subprocess.run(
                ["git", "-C", str(repository), "branch", "--show-current"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            report = health_report(
                "pr_ready",
                selected_components=["project_registry", "xcode_mcp"],
                observed_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            )
            report["authoritative_targets"] = {
                "repository": str(repository.resolve()),
                "remote": remote,
                "branch": branch,
                "xcode_container": str(xcode_container.resolve()),
            }
            candidate = report["project_registry_resolution"]["candidate"]
            candidate["canonical_root"] = str(repository.resolve())
            candidate["remote_fingerprint"] = resolve_project.remote_fingerprint(remote)
            candidate["xcode_containers"] = ["Application.xcodeproj"]
            harness = {
                "authoritative_root": str(repository),
                "xcode_container": str(xcode_container),
            }
            bind_resource_coordinator(harness, report, Path(directory))
            self.assertEqual([], evaluate_health.validate_harness_binding(report, harness))

            fake_container = repository / "NotAContainer.xcodeproj"
            fake_container.write_text("not a directory\n", encoding="utf-8")
            file_harness = {
                **harness,
                "xcode_container": str(fake_container),
            }
            self.assertIn(
                "harness xcode_container must be an existing project or workspace",
                evaluate_health.validate_harness_binding(report, file_harness),
            )

            candidate["xcode_containers"] = []
            self.assertIn(
                "project registry candidate does not bind the authoritative Xcode container",
                evaluate_health.validate_harness_binding(report, harness),
            )
            candidate["xcode_containers"] = None
            self.assertIn(
                "project registry candidate Xcode containers are invalid",
                evaluate_health_fixture(report)[1],
            )
            self.assertIn(
                "project registry candidate does not bind the authoritative Xcode container",
                evaluate_health.validate_harness_binding(report, harness),
            )
            candidate["xcode_containers"] = ["Application.xcodeproj"]

            candidate["remote_fingerprint"] = "sha256:" + "f" * 64
            self.assertIn(
                "project registry candidate remote fingerprint drifted from the live repository",
                evaluate_health.validate_harness_binding(report, harness),
            )

            unsafe_live_remote = (
                "https://token@github.com/example/repository.git?token=value"
            )
            subprocess.run(
                [
                    "git", "-C", str(repository), "remote", "set-url", "origin",
                    unsafe_live_remote,
                ],
                check=True,
            )
            report["authoritative_targets"]["remote"] = (
                evaluate_health.sanitize_remote(unsafe_live_remote)
            )
            candidate["remote_fingerprint"] = resolve_project.remote_fingerprint(
                "https://github.com/example/repository.git"
            )
            self.assertIn(
                "live repository remote cannot be normalized for project registry binding",
                evaluate_health.validate_harness_binding(report, harness),
            )

        for unsafe_remote in (
            "https://token@github.com/example/repository.git",
            "https://github.com/example/repository.git?token=value",
            "https://github.com/example/repository.git#fragment",
        ):
            with self.assertRaises(ValueError):
                evaluate_health.remote_fingerprint(unsafe_remote)

    def test_apple_sample_code_mcp_schema_and_harness_binding(self) -> None:
        harness_schema = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
            / "harness.schema.json"
        )
        report_schema = validator.load_json(
            ROOT / "skills" / "apple-development-health" / "contracts"
            / "health-report.schema.json"
        )
        component = "apple_sample_code_mcp"
        self.assertIn(
            component,
            harness_schema["properties"]["health_components"]["items"]["enum"],
        )
        self.assertIn(
            component,
            report_schema["properties"]["selected_components"]["items"]["enum"],
        )
        report = health_report(
            "pr_ready",
            selected_components=[component],
            observed_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        harness = validator.load_json(
            ROOT / "skills" / "agent-harness" / "templates" / "harness.json"
        )
        harness["health_components"] = ["apple_sample_code_mcp"]
        self.assertEqual([], validator.validate_json_schema(harness, harness_schema))
        self.assertEqual([], validator.validate_json_schema(report, report_schema))
        self.assertEqual([], evaluate_health_fixture(report)[1])
        with tempfile.TemporaryDirectory() as directory:
            private_root = Path(directory)
            report_path = Path(directory) / "report.json"
            harness_path = Path(directory) / "harness.json"
            policy_path = private_root / "private-policy.json"
            authorization_path = private_root / "authorization.json"
            harness["authoritative_root"] = str(private_root)
            harness["xcode_container"] = str(private_root / "Application.xcodeproj")
            harness["private_policy_overlay"] = str(policy_path)
            harness["run_authorization"] = str(authorization_path)
            harness["run_ledger"] = str(private_root / "ledger.jsonl")
            harness["agent_skills"]["installations"] = {
                "codex": {"collection_root": str(ROOT / "skills")},
                "claude": None,
            }
            policy_path.write_text(
                json.dumps({
                    "schema_version": "1.0.0",
                    "decision": "approved",
                    "github": {"owner": "example"},
                    "apple": None,
                }),
                encoding="utf-8",
            )
            harness_path.write_text(json.dumps(harness), encoding="utf-8")

            def trusted_live(payload: dict, *args: object, **kwargs: object) -> dict:
                return {
                    check_id: evaluate_health._live_observation(
                        check_id,
                        status="healthy",
                        reason_code="fixture_live",
                        material={"check_id": check_id},
                        summary=f"{check_id} fixture probe succeeded",
                    )
                    for check_id in set(payload.get("required_check_ids", []))
                    & evaluate_health.EVALUATOR_OWNED_CHECKS
                }

            def run(
                payload: dict, expected_bytes_sha256: str | None = None
            ) -> tuple[int, dict]:
                report_path.write_text(json.dumps(payload), encoding="utf-8")
                output = io.StringIO()
                arguments = [
                    "evaluate_health.py", str(report_path),
                    "--harness", str(harness_path),
                ]
                if expected_bytes_sha256 is not None:
                    arguments.extend(
                        ["--expected-report-bytes-sha256", expected_bytes_sha256]
                    )
                with patch.object(sys, "argv", arguments), contextlib.redirect_stdout(output):
                    return evaluate_health.main(), json.loads(output.getvalue())
            with (
                patch.object(evaluate_health, "validate_harness_binding", return_value=[]),
                patch.object(evaluate_health, "collect_live_observations", side_effect=trusted_live),
            ):
                self.assertTrue(run(report)[1]["valid"])
                drift_code, drift_result = run(
                    report, "sha256:" + "0" * 64
                )
                self.assertEqual(2, drift_code)
                self.assertTrue(
                    any("bytes drifted" in error for error in drift_result["errors"]),
                    drift_result,
                )
                omitted = copy.deepcopy(report)
                omitted["selected_components"] = []
                omitted["required_check_ids"].remove("mcp.apple_sample_code")
                omitted["checks"] = [
                    item for item in omitted["checks"]
                    if item["id"] != "mcp.apple_sample_code"
                ]
                self.assertEqual([], validator.validate_json_schema(omitted, report_schema))
                code, result = run(omitted)
        self.assertEqual(2, code)
        self.assertIn(
            "harness-required component is missing from report: apple_sample_code_mcp",
            result["errors"],
        )

    def test_apple_sample_code_mcp_contract_keeps_exact_read_only_route(self) -> None:
        knowledge = normalized_text(
            ROOT / "skills" / "agent-harness" / "references" / "knowledge-and-rag.md"
        )
        health = normalized_text(
            ROOT / "skills" / "apple-development-health" / "references"
            / "health-matrix.md"
        )
        exact_route = "https://mcp.applesamplecode.com/mcp"
        for phrase in (
            exact_route, "search_samples", "get_sample", "compare_samples",
            "get_status", "`refresh: false`", "independent source-cited analysis",
            "If the live MCP is unavailable", "Otherwise mark retrieval blocked.",
            "content/result hash", "similarly named domain.",
        ):
            self.assertIn(phrase, knowledge)
        for command in (
            f"codex mcp add apple-sample-code --url {exact_route}",
            f"claude mcp add --transport http apple-sample-code {exact_route}",
        ):
            self.assertIn(command, health)

    def test_visual_evidence_contract_separates_static_motion_and_trimmed_publication(self) -> None:
        screenshot = normalized_text(ROOT / "skills" / "screenshot" / "SKILL.md")
        testing = normalized_text(
            ROOT / "skills" / "apple-platform-testing" / "references"
            / "test-selection-and-evidence.md"
        )
        delivery = normalized_text(
            ROOT / "skills" / "agent-harness" / "references" / "delivery.md"
        )
        for phrase in (
            "static UI:",
            "interaction/motion:",
            "Capture both only when they prove distinct criteria.",
            "stable precondition immediately before the first relevant action",
            "Prepare the app at that scenario state before recording.",
            "exclude SpringBoard/Home, icon tap, app launch, the Launch Screen",
            "launch trigger and named ready milestone",
            "/usr/bin/avconvert --source <raw.mov>",
            "Never overwrite the raw recording.",
            "raw source hash, trim start/duration, final artifact hash",
            "full trimmed video, codec/container, dimensions, duration, and playback",
            "first and last meaningful frames",
            "Publish the trimmed artifact, not the raw recording.",
            "sanitized trimmed result",
        ):
            self.assertIn(phrase, screenshot)
        for phrase in (
            "screenshot as point-in-time UI evidence",
            "video can demonstrate a sequence",
            "deterministic steps",
            "attached test result evidence",
        ):
            self.assertIn(phrase, testing)
        for phrase in (
            "visible UI | affected build, one critical flow, relevant visual evidence",
            "interaction/motion | affected build/flow plus trimmed video or UI-test recording",
            "decode images",
            "verify video codec and playback",
        ):
            self.assertIn(phrase, delivery)

    def test_stacked_pr_contract_keeps_phases_reviewable_and_non_authorizing(self) -> None:
        workflow = normalized_text(
            ROOT / "skills" / "git-workflow" / "SKILL.md"
        )
        pr_delivery = normalized_text(
            ROOT / "skills" / "git-workflow" / "references" / "pr-delivery.md"
        )
        harness_delivery = normalized_text(
            ROOT / "skills" / "agent-harness" / "references" / "delivery.md"
        )
        for phrase in (
            "derive an ordered phase map from the dependency graph",
            "answer one reviewer question",
            "coherent intermediate state",
            "400 non-generated changed lines or 12 changed files is a review checkpoint, not a target",
            "Obtain approval for every branch name",
            "base each branch and PR on its approved predecessor",
            "ordered stack map in every PR body",
            "does not grant merge, force-push, or branch-retarget authority",
        ):
            self.assertIn(phrase, workflow)
        for phrase in (
            "Phase N/M: <reviewer outcome>",
            "phase, branch, PR link or pending marker, base, dependency, scope, and checks",
            "first phase targets the repository default branch",
            "later phase targets its predecessor branch",
            "GitHub base/head read-back for every PR",
            "retarget only with authority",
            "never hide stack state with a force push",
        ):
            self.assertIn(phrase, pr_delivery)
        for phrase in (
            "smallest coherent PR phases before the writer starts",
            "one reviewer question, own a bounded path set",
            "ordered stack map, base/head, dependency, checks, and evidence",
            "Do not create artificial micro-PRs",
            "do not infer merge or retarget authority",
        ):
            self.assertIn(phrase, harness_delivery)

    def test_completion_report_requires_exact_provider_usage_aggregation(self) -> None:
        schema = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "schemas"
            / "completion-report.schema.json"
        )
        report = validator.load_json(
            ROOT / "skills" / "agent-harness" / "templates"
            / "completion-report.json"
        )
        self.assertEqual([], validator.validate_json_schema(report, schema))
        self.assertEqual([], validator.validate_completion_report(report))

        report["usage"] = {
            "status": "full",
            "missing_sources": [],
            "source_records": {
                "codex-response-1": {
                    "provider": "openai", "input_tokens": 10,
                    "output_tokens": 5, "cached_input_tokens": 2,
                    "reasoning_tokens": 3,
                },
                "claude-message-1": {
                    "provider": "anthropic", "input_tokens": 20,
                    "output_tokens": 10, "cached_input_tokens": 1,
                    "reasoning_tokens": 4,
                },
            },
            "attribution": [
                {"agent_id": "writer", "session_id": "session-a", "model": "balanced", "source_ids": ["codex-response-1"]},
                {"agent_id": "reviewer", "session_id": "session-b", "model": "deep", "source_ids": ["claude-message-1"]},
            ],
            "cross_provider_total": {
                "input_tokens": 30, "output_tokens": 15,
                "label": "informational; cached input and reasoning are subsets, not added",
            },
            "cost": {"status": "client_estimate", "amount": 0.25, "currency": "USD"},
        }
        self.assertEqual([], validator.validate_json_schema(report, schema))
        self.assertEqual([], validator.validate_completion_report(report))

        report["usage"]["source_records"]["codex-response-1"]["cached_input_tokens"] = 11
        report["usage"]["cross_provider_total"]["output_tokens"] = 16
        errors = validator.validate_completion_report(report)
        self.assertTrue(any("cached input exceeds" in error for error in errors))
        self.assertTrue(any("must equal each unique" in error for error in errors))

    def test_companion_upstream_drift_creates_review_candidate_only(self) -> None:
        manifest = validator.load_json(
            ROOT / "skills" / "icon-composer" / "contracts" / "companion-upstream.json"
        )
        current = watch_companion_upstream.compare(
            manifest, manifest["upstream"]["reviewed_revision"]
        )
        self.assertFalse(current["changed"])
        changed = watch_companion_upstream.compare(manifest, "f" * 40)
        self.assertTrue(changed["changed"])
        self.assertEqual("create_or_update_review_issue", changed["action"])
        self.assertFalse(changed["copy_or_execute_upstream"])
        self.assertFalse(changed["auto_merge"])
        with self.assertRaisesRegex(ValueError, "pinned consumer repository"):
            watch_companion_upstream.reconcile_issue(
                manifest, "someone/else", object()  # type: ignore[arg-type]
            )

    def test_companion_upstream_requires_public_provenance_before_noop(self) -> None:
        manifest = validator.load_json(ROOT / "skills" / "icon-composer" / "contracts" / "companion-upstream.json")

        class Client:
            def __init__(self, responses: dict[str, object]) -> None:
                self.responses, self.calls = responses, []
            def request(self, method: str, path: str, body: dict | None = None) -> object:
                self.calls.append((method, path, body))
                return self.responses[path]

        upstream = manifest["upstream"]
        owner, repository = upstream["repository"].split("/", 1)
        reviewed = upstream["reviewed_revision"]
        tree = upstream["reviewed_tree"]
        prefix = f"/repos/{owner}/{repository}"
        source_tree = {"tree": [{"path": source["path"], "type": "blob", "sha": source["blob_sha"]} for source in manifest["sources"]]}
        responses = {
            prefix: {"private": False, "visibility": "public", "default_branch": upstream["default_branch"]},
            f"{prefix}/commits/{reviewed}": {"sha": reviewed, "commit": {"tree": {"sha": tree}}},
            f"{prefix}/git/trees/{tree}?recursive=1": source_tree,
            f"{prefix}/commits/{upstream['default_branch']}": {"sha": reviewed},
        }
        client = Client(responses)
        result = watch_companion_upstream.reconcile_issue(manifest, "ShawnBaek/iOS-experts", client)  # type: ignore[arg-type]
        self.assertEqual("none", result["issue_action"])
        self.assertTrue(all(call[0] == "GET" for call in client.calls))
        for mutation, message in (({prefix: {**responses[prefix], "private": True}}, "no longer public"),
                                  ({prefix: {**responses[prefix], "default_branch": "unexpected"}}, "default branch drifted"),
                                  ({f"{prefix}/git/trees/{tree}?recursive=1": {"tree": []}}, "source blob drifted")):
            changed = dict(responses)
            changed.update(mutation)
            with self.assertRaisesRegex(RuntimeError, message):
                watch_companion_upstream.reconcile_issue(manifest, "ShawnBaek/iOS-experts", Client(changed))  # type: ignore[arg-type]

    def test_testflight_continuation_rejects_action_boundary_drift(self) -> None:
        workflow = validator.load_json(
            ROOT / "skills" / "agent-harness" / "contracts" / "testflight-workflow.json"
        )
        self.assertEqual([], validator.validate_testflight_workflow(workflow))
        workflow["policy"]["forbidden_actions"].remove("apple.app_review_submit")
        self.assertTrue(
            any(
                "forbidden action missing" in error
                for error in validator.validate_testflight_workflow(workflow)
            )
        )
        workflow = validator.load_json(ROOT / "skills" / "agent-harness" / "contracts" / "testflight-workflow.json")
        next(node for node in workflow["nodes"] if node["id"] == "wait_processing")[
            "timeout_from_authorization"
        ] = "unbounded"
        self.assertTrue(any("processing wait" in error for error in validator.validate_testflight_workflow(workflow)))
        workflow = validator.load_json(ROOT / "skills" / "agent-harness" / "contracts" / "testflight-workflow.json")
        next(node for node in workflow["nodes"] if node["id"] == "wait_processing")[
            "requires"
        ] = ["health_gate"]
        self.assertTrue(any("dependency" in error for error in validator.validate_testflight_workflow(workflow)))
        workflow = validator.load_json(ROOT / "skills" / "agent-harness" / "contracts" / "testflight-workflow.json")
        next(node for node in workflow["nodes"] if node["id"] == "release_archive_build")[
            "requires"
        ] = ["archive"]
        self.assertTrue(
            any(
                "dependency" in error or "order" in error
                for error in validator.validate_testflight_workflow(workflow)
            )
        )

    def test_rag_injection_fixture_is_fail_closed(self) -> None:
        fixture = json.loads(
            (ROOT / "tests" / "fixtures" / "rag-prompt-injection.json").read_text()
        )
        mutated = copy.deepcopy(fixture)
        self.assertFalse(mutated["immutable_policy"]["retrieved_text_is_instruction"])
        self.assertEqual(0, mutated["expected"]["tool_calls"])
        self.assertEqual("immutable_policy", mutated["expected"]["authority"])

    def test_rag_query_cli_accepts_current_commit(self) -> None:
        arguments = rag_index.parser().parse_args(
            [
                "query",
                "--database",
                "knowledge.sqlite",
                "--query",
                "writer lease",
                "--commit",
                "abc123",
            ]
        )
        self.assertEqual("abc123", arguments.commit)

    def test_rag_index_returns_provenance_and_excludes_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            (source / "guide.md").write_text("writer lease evidence graph", encoding="utf-8")
            (source / ".env").write_text("TOKEN=do-not-index", encoding="utf-8")
            (source / "AuthKey_test.p8").write_text("private", encoding="utf-8")
            (source / "unsafe.md").write_text("api_key=secret-value", encoding="utf-8")
            inside_database = source / "rag.sqlite"
            with self.assertRaisesRegex(ValueError, "inside the indexed root"):
                rag_index.index(
                    Namespace(
                        database=inside_database,
                        root=source,
                        source_id="project",
                        authority="repository_source",
                        commit="abc123",
                        include=["*.md"],
                        allow_structured=False,
                        allow_database_inside_root=False,
                    )
                )
            self.assertFalse(inside_database.exists())
            database = Path(directory) / "rag.sqlite"
            with contextlib.redirect_stdout(io.StringIO()):
                rag_index.index(
                    Namespace(
                        database=database,
                        root=source,
                        source_id="project",
                        authority="repository_source",
                        commit="abc123",
                        include=["*.md"],
                        allow_structured=False,
                    )
                )
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                rag_index.query(
                    Namespace(database=database, query="writer lease", limit=5, commit="abc123")
                )
            result = json.loads(output.getvalue())
            self.assertEqual(1, len(result["results"]))
            self.assertEqual("guide.md", result["results"][0]["path"])
            self.assertEqual("abc123", result["results"][0]["commit_sha"])
            self.assertTrue(result["results"][0]["fresh"])
            self.assertTrue(result["results"][0]["indexed_at"])
            self.assertFalse(result["results"][0]["trusted_as_instructions"])

    def test_rag_structured_content_requires_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            (source / "guide.md").write_text("plain evidence", encoding="utf-8")
            (source / "decision.json").write_text('{"decision":"structured evidence"}', encoding="utf-8")
            (source / "credentials.json").write_text(
                '{"client_secret":"credential-value"}', encoding="utf-8"
            )
            (source / "GoogleService-Info.plist").write_text(
                "<plist><dict><key>API_KEY</key><string>credential-value</string></dict></plist>",
                encoding="utf-8",
            )
            database = Path(directory) / "rag.sqlite"
            base = dict(database=database, root=source, source_id="project", authority="repository_source", commit="abc123", include=["*"], allow_structured=False)
            with contextlib.redirect_stdout(io.StringIO()):
                rag_index.index(Namespace(**base))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                rag_index.query(Namespace(database=database, query="structured evidence", limit=5, commit="abc123"))
            self.assertEqual([], json.loads(output.getvalue())["results"])

            base["allow_structured"] = True
            indexed = io.StringIO()
            with contextlib.redirect_stdout(indexed):
                rag_index.index(Namespace(**base))
            self.assertEqual(2, json.loads(indexed.getvalue())["skipped_secret_files"])
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                rag_index.query(Namespace(database=database, query="structured evidence", limit=5, commit="abc123"))
            self.assertEqual("decision.json", json.loads(output.getvalue())["results"][0]["path"])

    def test_rag_query_refuses_stale_index(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            guide = source / "guide.md"
            guide.write_text("writer lease", encoding="utf-8")
            database = Path(directory) / "rag.sqlite"
            with contextlib.redirect_stdout(io.StringIO()):
                rag_index.index(Namespace(database=database, root=source, source_id="project", authority="repository_source", commit="abc123", include=["*.md"], allow_structured=False))
            with self.assertRaisesRegex(ValueError, "stale"):
                rag_index.query(Namespace(database=database, query="writer lease", limit=5, commit="different"))
            guide.write_text("changed after indexing", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "stale"):
                rag_index.query(Namespace(database=database, query="writer lease", limit=5, commit="abc123"))

    def test_live_git_patch_manifest_preserves_staged_content_modes_and_commit_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            repository.mkdir()
            subprocess.run(
                ["git", "init", "-b", "main", str(repository)],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "-C", str(repository), "remote", "add", "origin", "https://github.com/example/repository.git"],
                check=True,
            )
            (repository / "modified.txt").write_text("before\n", encoding="utf-8")
            (repository / "deleted.txt").write_text("remove me\n", encoding="utf-8")
            executable = repository / "script.sh"
            executable.write_text("#!/bin/sh\necho before\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
            subprocess.run(
                [
                    "git", "-C", str(repository), "-c", "user.name=Test User",
                    "-c", "user.email=test@example.com", "commit", "-m", "base",
                ],
                check=True,
                capture_output=True,
            )
            base_sha = subprocess.run(
                ["git", "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            (repository / "modified.txt").write_text("after\n", encoding="utf-8")
            (repository / "deleted.txt").unlink()
            executable.write_text("#!/bin/sh\necho after\n", encoding="utf-8")
            executable.chmod(0o755)
            (repository / "added.txt").write_text("new file\n", encoding="utf-8")
            (repository / "linked.txt").symlink_to("modified.txt")
            subprocess.run(["git", "-C", str(repository), "add", "-A"], check=True)

            staged = check_authorization.observe_repository(repository, base_sha)
            records = {
                record["path"]: record
                for record in staged["staged_patch_manifest"]["records"]
            }
            self.assertEqual(
                ["added.txt", "deleted.txt", "linked.txt", "modified.txt", "script.sh"],
                list(records),
            )
            self.assertEqual(("100644", "added"), (records["added.txt"]["mode"], records["added.txt"]["state"]))
            self.assertEqual(("100644", "deleted"), (records["deleted.txt"]["mode"], records["deleted.txt"]["state"]))
            self.assertEqual("deleted", records["deleted.txt"]["content_sha256"])
            self.assertEqual(("120000", "symlink"), (records["linked.txt"]["mode"], records["linked.txt"]["state"]))
            self.assertEqual(("100644", "modified"), (records["modified.txt"]["mode"], records["modified.txt"]["state"]))
            self.assertEqual(("100755", "modified"), (records["script.sh"]["mode"], records["script.sh"]["state"]))
            for path, content in {
                "added.txt": b"new file\n",
                "linked.txt": b"modified.txt",
                "modified.txt": b"after\n",
                "script.sh": b"#!/bin/sh\necho after\n",
            }.items():
                self.assertEqual(
                    "sha256:" + hashlib.sha256(content).hexdigest(),
                    records[path]["content_sha256"],
                )

            staged_identity = staged["staged_patch_identity"]
            subprocess.run(
                [
                    "git", "-C", str(repository), "-c", "user.name=Test User",
                    "-c", "user.email=test@example.com", "commit", "-m", "patch",
                ],
                check=True,
                capture_output=True,
            )
            committed = check_authorization.observe_repository(repository, base_sha)
            self.assertEqual(staged_identity, committed["head_patch_identity"])
            self.assertEqual(
                staged["staged_patch_manifest"], committed["head_patch_manifest"]
            )


if __name__ == "__main__":
    unittest.main()
