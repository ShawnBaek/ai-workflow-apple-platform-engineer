from __future__ import annotations

import copy
import contextlib
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import io
import json
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
import spec_kit_snapshot  # noqa: E402
import resolve_project  # noqa: E402
sys.path.insert(0, str(ROOT / "skills" / "apple-development-health" / "scripts"))
import evaluate_health  # noqa: E402
sys.path.insert(0, str(ROOT / "skills" / "icon-composer" / "scripts"))
import watch_companion_upstream  # noqa: E402


def approved_envelope() -> dict:
    return validator.load_json(ROOT / "tests" / "fixtures" / "run-authorization-approved.json")


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


def authorization_ledger(envelope: dict, grant: dict) -> list[dict]:
    digest = check_authorization.authorization_hash(envelope)
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
                "owner": "fixture-agent",
                "resource": check_authorization._expected_lease_resource(grant["action"]),
                "resource_key": grant["resource_key"],
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
        "lease_id": "fixture-lease",
        "lease_owner": "fixture-agent",
        "lease_resource": check_authorization._expected_lease_resource(grant["action"]),
        "lease_resource_key": grant["resource_key"],
    }


def live_repository(envelope: dict) -> dict:
    return {
        **copy.deepcopy(envelope["repository"]),
        "head_sha": "2" * 40,
        "staged_paths": copy.deepcopy(envelope["allowed_paths"]),
        "staged_diff_sha256": "3" * 64,
        "outgoing_paths": copy.deepcopy(envelope["allowed_paths"]),
    }


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


def normalized_text(path: Path) -> str:
    return " ".join(path.read_text(encoding="utf-8").split())


def testflight_envelope() -> dict:
    """A complete continuation envelope derived from the reviewed PR fixture."""
    envelope = approved_envelope()
    envelope["delivery_target"] = "testflight_distributed"
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

    def test_workflow_accepts_balanced_runtime_registry_extension_only(self) -> None:
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
        self.assertEqual([], validator.validate_json_schema(schema_instance, schema))
        self.assertEqual([], validator.validate_workflow_semantics(workflow, resources))

        release_node = next(node for node in nodes if node["id"] == "release_runtime_registry")
        valid_release_requires = release_node["requires"]
        release_node["requires"] = ["release_implementation_writer"]
        self.assertTrue(
            any(
                "release must depend on its acquire" in error
                for error in validator.validate_workflow_semantics(workflow, resources)
            )
        )
        release_node["requires"] = valid_release_requires

        nodes.remove(next(node for node in nodes if node["id"] == "release_runtime_registry"))
        freeze["requires"].remove("release_runtime_registry")
        self.assertTrue(
            any(
                "one acquire and one release" in error
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
                "constraint_sha256": request["constraint_sha256"],
                "phase": request["phase"],
                "target": request["target"],
                "lease_id": request["lease_id"],
                "lease_owner": request["lease_owner"],
                "resource": request["lease_resource"],
                "resource_key": request["lease_resource_key"],
                "spec_checkpoint_sha256": None,
                "apple_observation_sha256": None,
            },
            4,
        )
        external_write = ledger_record(
            5,
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
                "lease_id": request["lease_id"],
                "lease_owner": request["lease_owner"],
                "target": request["target"],
                "outcome": "succeeded",
                "authorization_hash": request["authorization_hash"],
                "grant_id": request["grant_id"],
                "idempotency_key": request["idempotency_key"],
                "reservation_id": reservation_id,
                "spec_checkpoint_sha256": None,
                "apple_observation_sha256": None,
            },
            5,
        )
        self.assertTrue(
            any(
                "prior approved run authorization" in error
                for error in validator.validate_ledger_lifecycle([external_write])
            )
        )
        records = authorization_ledger(envelope, grant) + [reservation, external_write]
        self.assertEqual([], validator.validate_ledger_lifecycle(records))
        failed_records = copy.deepcopy(records)
        failed_records[-1]["payload"]["outcome"] = "failed"
        self.assertEqual([], validator.validate_ledger_lifecycle(failed_records))
        reused = copy.deepcopy(external_write)
        reused["sequence"] = 6
        reused["recorded_at"] = "2026-01-01T00:00:06Z"
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
        def approval(decision: str = "approved", target: str = "runtime-a") -> dict:
            return {
                "run_id": "run-1",
                "sequence": 1,
                "record_type": "approval",
                "payload": {
                    "approval_id": "approval-a",
                    "kind": "destructive_action",
                    "decision": decision,
                    "scope": f"coresimulator_runtime_registry:host-a:remove_exact_runtime:{target}",
                    "resource": "coresimulator_runtime_registry",
                    "resource_key": "host-a",
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
                    "resource_key": "host-a",
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

        approved = [
            approval(),
            acquire(),
            {"run_id": "run-1", "sequence": 3, "record_type": "lease", "payload": {"lease_id": "registry", "action": "release", "owner": "codex", "resource": "coresimulator_runtime_registry", "resource_key": "host-a"}},
        ]
        self.assertEqual([], validator.validate_ledger_lifecycle(approved))

        reused = approved + [acquire(sequence=4)]
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
            ),
        )
        request["repository"]["branch"] = "different-branch"
        self.assertTrue(any("repository or branch drifted" in error for error in check_authorization.authorize_action(envelope, request, now=current, ledger_records=ledger, policy_overlay=policy_overlay(), live_repository=live_repository(envelope))))
        request["repository"] = copy.deepcopy(envelope["repository"])
        request["paths"] = ["outside-approved-scope/file.swift"]
        self.assertTrue(any("path is outside authorization" in error for error in check_authorization.authorize_action(envelope, request, now=current, ledger_records=ledger, policy_overlay=policy_overlay(), live_repository=live_repository(envelope))))
        request["paths"] = copy.deepcopy(envelope["allowed_paths"])
        request["operation_input"]["state"] = "Closed"
        self.assertTrue(any("constraint digest" in error or "exact action grant" in error for error in check_authorization.authorize_action(envelope, request, now=current, ledger_records=ledger, policy_overlay=policy_overlay(), live_repository=live_repository(envelope))))

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

    def test_reservation_is_atomic_and_copied_skill_keeps_contract_checker(self) -> None:
        envelope = approved_envelope()
        grant = envelope["action_grants"][0]
        request = action_request(envelope, grant)
        with tempfile.TemporaryDirectory() as directory:
            run_root = Path(directory)
            ledger_path = run_root / "ledger.jsonl"
            ledger_path.write_text("\n".join(json.dumps(item) for item in authorization_ledger(envelope, grant)) + "\n", encoding="utf-8")
            def reserve() -> tuple[list[str], dict | None]:
                return check_authorization.reserve_action(ledger_path, envelope, copy.deepcopy(request), run_root, policy_overlay(), live_repository(envelope))
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: reserve(), range(2)))
            self.assertEqual(1, sum(not errors and reservation is not None for errors, reservation in results))
            self.assertEqual(1, sum(any("single-use" in error for error in errors) for errors, _ in results))
            copied = run_root / "agent-harness"
            shutil.copytree(ROOT / "skills" / "agent-harness", copied)
            probe = "import json,sys; sys.path.insert(0,sys.argv[1]); import check_authorization as c; print(c._ledger_contract_errors(json.load(open(sys.argv[2]))))"
            records_path = run_root / "records.json"
            records_path.write_text(json.dumps(authorization_ledger(envelope, grant)), encoding="utf-8")
            completed = subprocess.run([sys.executable, "-c", probe, str(copied / "scripts"), str(records_path)], check=True, capture_output=True, text=True)
            self.assertEqual("[]", completed.stdout.strip())
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
        evaluated, errors = evaluate_health.evaluate(
            report, now=datetime(2026, 8, 29, 0, 1, tzinfo=timezone.utc)
        )
        self.assertEqual([], errors)
        self.assertEqual("blocked", evaluated["overall_status"])
        self.assertEqual("<redacted>", next(item for item in evaluated["checks"] if item["id"] == "mcp.xcode")["evidence"][0])

    def test_optional_health_failure_is_degraded_not_blocked(self) -> None:
        report = health_report("pr_ready")
        report["checks"].append({"id": "local_llm", "category": "local_llm", "required": False,
                                 "status": "blocked", "summary": "Optional loopback model is unavailable.",
                                 "evidence": ["connection refused"], "next_action": "Continue without Local LLM."})
        evaluated, errors = evaluate_health.evaluate(
            report, now=datetime(2026, 8, 29, 0, 1, tzinfo=timezone.utc)
        )
        self.assertEqual([], errors)
        self.assertEqual("degraded", evaluated["overall_status"])

    def test_health_rejects_stale_future_and_wrong_harness_targets(self) -> None:
        report = health_report("pr_ready")
        now = datetime(2026, 8, 29, 0, 11, tzinfo=timezone.utc)
        self.assertTrue(any("stale" in error for error in evaluate_health.evaluate(report, now=now)[1]))
        report["observed_at"] = "2026-08-29T00:13:00Z"
        self.assertTrue(any("future" in error for error in evaluate_health.evaluate(report, now=now)[1]))
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
            self.assertEqual([], evaluate_health.validate_harness_binding(live, harness))
            malformed_components = copy.deepcopy(live)
            malformed_components["selected_components"] = None
            self.assertIn(
                "health report selected_components are invalid",
                evaluate_health.evaluate(malformed_components)[1],
            )
            self.assertEqual(
                [],
                evaluate_health.validate_harness_binding(
                    malformed_components, harness
                ),
            )
            live["authoritative_targets"]["branch"] = "wrong"
            self.assertTrue(evaluate_health.validate_harness_binding(live, harness))

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
        evaluated, errors = evaluate_health.evaluate(report)
        self.assertEqual([], errors)
        self.assertEqual("healthy", evaluated["overall_status"])

        missing = copy.deepcopy(report)
        missing.pop("project_registry_resolution")
        self.assertIn(
            "selected project registry requires a structured resolution",
            evaluate_health.evaluate(missing)[1],
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
        evaluated, errors = evaluate_health.evaluate(degraded)
        self.assertEqual([], errors)
        self.assertEqual("degraded", evaluated["overall_status"])

        unsafe_warning = copy.deepcopy(degraded)
        unsafe_warning["project_registry_resolution"]["warnings"][0][
            "reason_code"
        ] = "checkout_kind_mismatch"
        self.assertIn(
            "project registry warning is invalid",
            evaluate_health.evaluate(unsafe_warning)[1],
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
            evaluate_health.evaluate(unsafe_container)[1],
        )

        duplicate_container = copy.deepcopy(report)
        duplicate_container["project_registry_resolution"]["candidate"][
            "xcode_containers"
        ] = ["Application.xcodeproj", "Application.xcodeproj"]
        self.assertIn(
            "project registry candidate Xcode containers are invalid",
            evaluate_health.evaluate(duplicate_container)[1],
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
        evaluated, errors = evaluate_health.evaluate(ambiguous)
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
            self.assertEqual([], evaluate_health.validate_harness_binding(report, harness))

            fake_container = repository / "NotAContainer.xcodeproj"
            fake_container.write_text("not a directory\n", encoding="utf-8")
            file_harness = {
                "authoritative_root": str(repository),
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
                evaluate_health.evaluate(report)[1],
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
        self.assertEqual([], evaluate_health.evaluate(report)[1])
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            harness_path = Path(directory) / "harness.json"
            harness_path.write_text(json.dumps(harness), encoding="utf-8")
            def run(payload: dict) -> tuple[int, dict]:
                report_path.write_text(json.dumps(payload), encoding="utf-8")
                output = io.StringIO()
                arguments = [
                    "evaluate_health.py", str(report_path),
                    "--harness", str(harness_path),
                ]
                with patch.object(sys, "argv", arguments), contextlib.redirect_stdout(output):
                    return evaluate_health.main(), json.loads(output.getvalue())
            with patch.object(evaluate_health, "validate_harness_binding", return_value=[]):
                self.assertTrue(run(report)[1]["valid"])
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
        workflow["nodes"][7]["timeout_from_authorization"] = "unbounded"
        self.assertTrue(any("processing wait" in error for error in validator.validate_testflight_workflow(workflow)))
        workflow = validator.load_json(ROOT / "skills" / "agent-harness" / "contracts" / "testflight-workflow.json")
        workflow["nodes"][7]["requires"] = ["health_gate"]
        self.assertTrue(any("dependency" in error for error in validator.validate_testflight_workflow(workflow)))

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


if __name__ == "__main__":
    unittest.main()
