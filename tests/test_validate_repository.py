from __future__ import annotations

import copy
import contextlib
import io
import json
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import validate_repository as validator  # noqa: E402
sys.path.insert(0, str(ROOT / "skills" / "agent-harness" / "scripts"))
import rag_index  # noqa: E402


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
            {"sequence": 1, "record_type": "lease", "payload": {"lease_id": "lease-1", "action": "acquire", "owner": "codex", "resource": "source_checkout_writer", "resource_key": "repo-a"}},
            {"sequence": 2, "record_type": "node", "payload": {"node_id": "pr_ready", "status": "passed"}},
        ]
        errors = validator.validate_ledger_lifecycle(records)
        self.assertTrue(any("pr_ready cannot pass" in error for error in errors))

    def test_runtime_registry_and_device_leases_conflict_both_ways(self) -> None:
        device_then_registry = [
            {"sequence": 1, "record_type": "lease", "payload": {"lease_id": "device", "action": "acquire", "owner": "codex", "resource": "simulator_or_device", "resource_key": "device-a"}},
            {"sequence": 2, "record_type": "lease", "payload": {"lease_id": "registry", "action": "acquire", "owner": "codex", "resource": "coresimulator_runtime_registry", "resource_key": "host-a", "allowed_actions": ["read_only_diagnosis"]}},
        ]
        registry_then_device = [
            {"sequence": 1, "record_type": "lease", "payload": {"lease_id": "registry", "action": "acquire", "owner": "codex", "resource": "coresimulator_runtime_registry", "resource_key": "host-a", "allowed_actions": ["read_only_diagnosis"]}},
            {"sequence": 2, "record_type": "lease", "payload": {"lease_id": "device", "action": "acquire", "owner": "codex", "resource": "simulator_or_device", "resource_key": "device-a"}},
        ]
        self.assertTrue(any("conflicts" in error for error in validator.validate_ledger_lifecycle(device_then_registry)))
        self.assertTrue(any("conflicts" in error for error in validator.validate_ledger_lifecycle(registry_then_device)))

    def test_mutating_runtime_registry_lease_requires_matching_approval(self) -> None:
        def approval(decision: str = "approved", target: str = "runtime-a") -> dict:
            return {
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
            {"sequence": 3, "record_type": "lease", "payload": {"lease_id": "registry", "action": "release", "owner": "codex", "resource": "coresimulator_runtime_registry", "resource_key": "host-a"}},
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
