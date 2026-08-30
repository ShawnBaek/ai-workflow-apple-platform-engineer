from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "agent-harness" / "scripts"))
import resource_coordinator as coordinator  # noqa: E402


FINGERPRINT = "sha256:" + "a" * 64
SOURCE = {"identity_version": "github_remote_v2", "repository_fingerprint": FINGERPRINT}


class ResourceCoordinatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.state = self.root / "coordinator.json"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def boot(self, path: Path | None = None) -> None:
        coordinator.bootstrap(path or self.state, legacy_leases_quiesced=True)

    def instance(self, path: Path | None = None) -> str:
        return coordinator.status(path or self.state)["coordinator_instance_id"]

    def acquire(self, resource: str, descriptor: dict, *, run: str = "run-a", now: datetime | None = None, ttl: int = 60) -> dict:
        authority = self.authority(run)
        coordinator.register_run_authority(
            self.state,
            run,
            authority,
            now=now or datetime.now(timezone.utc),
        )
        return coordinator.acquire(self.state, resource=resource, descriptor=descriptor,
                                   owner_run_id=run, owner_actor="codex", ttl_seconds=ttl, now=now,
                                   run_authority=authority)

    def heartbeat(
        self, receipt: dict, *, ttl: int, now: datetime | None = None
    ) -> dict:
        return coordinator.heartbeat(
            self.state,
            receipt,
            ttl_seconds=ttl,
            run_authority=self.authority(
                receipt["owner_run_id"], receipt["owner_actor"]
            ),
            now=now,
        )

    def release(self, receipt: dict, *, now: datetime | None = None) -> dict:
        return coordinator.release(
            self.state,
            receipt,
            run_authority=self.authority(
                receipt["owner_run_id"], receipt["owner_actor"]
            ),
            now=now,
        )

    def recover(self, receipt: dict, **kwargs: object) -> dict:
        evidence = kwargs.get("evidence")
        if not isinstance(evidence, dict):
            raise AssertionError("recovery test requires evidence")
        observer = evidence.get("observer")
        if not isinstance(observer, dict):
            raise AssertionError("recovery test requires observer")
        observer_authority = self.authority(
            observer["observer_run_id"], observer["observer_actor"]
        )
        coordinator.register_run_authority(
            self.state,
            observer["observer_run_id"],
            observer_authority,
            now=kwargs.get("now") if isinstance(kwargs.get("now"), datetime) else None,
        )
        kwargs.setdefault("observer_authority", observer_authority)
        replacement = kwargs.get("replacement")
        replacement_authority = kwargs.get("replacement_authority")
        if isinstance(replacement, dict) and isinstance(replacement_authority, dict):
            coordinator.register_run_authority(
                self.state,
                replacement["owner_run_id"],
                replacement_authority,
                now=kwargs.get("now") if isinstance(kwargs.get("now"), datetime) else None,
            )
        return coordinator.recover(
            self.state,
            receipt,
            run_authority=self.authority(
                receipt["owner_run_id"], receipt["owner_actor"]
            ),
            **kwargs,
        )

    @staticmethod
    def authority(run: str, actor: str = "codex") -> dict:
        return {
            "authorization_hash": "sha256:" + hashlib.sha256(
                f"authorization:{run}:{actor}".encode()
            ).hexdigest(),
            "selected_writer": actor,
            "harness_sha256": "sha256:" + hashlib.sha256(
                f"harness:{run}:{actor}".encode()
            ).hexdigest(),
            "authorization_issued_at": "2000-01-01T00:00:00Z",
            "authorization_expires_at": "2099-01-01T00:00:00Z",
            "ledger_path": f"/fixture/private/{run}/ledger.jsonl",
            "ledger_identity_sha256": "sha256:" + hashlib.sha256(
                f"ledger:{run}:{actor}".encode()
            ).hexdigest(),
            "ledger_approval_sha256": "sha256:" + hashlib.sha256(
                f"approval:{run}:{actor}".encode()
            ).hexdigest(),
        }

    def cli_harness(
        self, skill_root: Path, run_id: str, name: str
    ) -> tuple[Path, Path, dict]:
        schema_path = skill_root / "contracts" / "schemas" / "run-authorization.schema.json"
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        authorization = json.loads(
            (ROOT / "tests" / "fixtures" / "run-authorization-approved.json").read_text(
                encoding="utf-8"
            )
        )
        authorization["$schema"] = schema_path.resolve().as_uri()
        authorization["contract_schema_id"] = schema["$id"]
        authorization["contract_schema_sha256"] = "sha256:" + hashlib.sha256(
            schema_path.read_bytes()
        ).hexdigest()
        authorization["run_id"] = run_id
        authorization["authorization_id"] = f"authorization-{run_id}"
        authorization_path = self.root / f"{name}-authorization.json"
        authorization_path.write_text(json.dumps(authorization), encoding="utf-8")
        ledger_path = self.root / f"{name}-ledger.jsonl"
        authorization_hash = coordinator._portable_document_sha256(authorization)
        ledger_path.write_text(
            json.dumps(
                {
                    "schema_version": "1.0.0",
                    "run_id": run_id,
                    "sequence": 1,
                    "recorded_at": "2026-01-01T00:00:00Z",
                    "record_type": "approval",
                    "payload": {
                        "kind": "run_authorization",
                        "decision": "approved",
                        "authorization_hash": authorization_hash,
                    },
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        ledger_path.chmod(0o600)
        policy_path = self.root / f"{name}-policy.json"
        policy_path.write_text("{}", encoding="utf-8")
        harness = json.loads(
            (skill_root / "templates" / "harness.json").read_text(encoding="utf-8")
        )
        harness.update(
            {
                "$schema": (
                    skill_root / "contracts" / "schemas" / "harness.schema.json"
                ).resolve().as_uri(),
                "authoritative_root": str(self.root),
                "xcode_container": str(self.root / "App.xcodeproj"),
                "private_policy_overlay": str(policy_path),
                "run_authorization": str(authorization_path),
                "run_ledger": str(ledger_path),
            }
        )
        harness["agent_skills"]["installations"]["codex"] = {
            "collection_root": str(skill_root.parent)
        }
        harness["resource_coordinator"] = {
            "state_path": str(self.state),
            "coordinator_instance_id": self.instance(),
            "script_sha256": "sha256:" + hashlib.sha256(
                (skill_root / "scripts" / "resource_coordinator.py").read_bytes()
            ).hexdigest(),
            "contract_bundle_sha256": coordinator.contract_bundle_sha256(skill_root),
        }
        harness_path = self.root / f"{name}-harness.json"
        harness_path.write_text(json.dumps(harness), encoding="utf-8")
        _document, authority = coordinator.load_existing_run_authority(
            authorization_path, harness_path, harness, run_id
        )
        coordinator.register_run_authority(self.state, run_id, authority)
        source = {
            "identity_version": "github_remote_v2",
            "repository_fingerprint": authorization["repository"]["fingerprint"],
        }
        return harness_path, authorization_path, source

    @staticmethod
    def evidence(
        receipt: dict,
        now: datetime,
        *,
        observer_run_id: str = "independent-recovery-audit",
        observer_actor: str = "codex",
    ) -> dict:
        observed_at = now.isoformat().replace("+00:00", "Z")
        return {
            "previous_receipt_id": receipt["receipt_id"],
            "previous_fencing_token": receipt["fencing_token"],
            "observer": {
                "observer_run_id": observer_run_id,
                "observer_actor": observer_actor,
                "method": "bounded_read_only_host_probe",
                "observed_at": observed_at,
            },
            "owner_liveness": {"state": "dead", "digest": "sha256:" + "b" * 64, "observed_at": observed_at},
            "owner_tool_children": {"state": "dead", "digest": "sha256:" + "e" * 64, "observed_at": observed_at},
            "dirty_state": {"state": "clean", "digest": "sha256:" + "c" * 64, "observed_at": observed_at},
            "live_resource_revalidation": {
                "passed": True, "digest": "sha256:" + "d" * 64,
                "observed_at": observed_at,
            },
        }

    def build_descriptor(self, cache_root: Path) -> dict:
        source_packages = cache_root / "SourcePackages"
        roles = {
            "derived_data": str(cache_root),
            "source_packages": str(source_packages),
            "repository_checkouts": str(source_packages / "checkouts"),
            "artifacts": str(source_packages / "artifacts"),
            "package_cache": str(cache_root / "package-cache"),
        }
        return {
            "repository_fingerprint": FINGERPRINT,
            "container_path": str(self.root / "App.xcodeproj"),
            "xcode_build": "27A",
            "sdk": "iphonesimulator",
            "scheme": "App",
            "configuration": "Debug",
            "architecture": "arm64",
            "package_fingerprint": "sha256:" + "f" * 64,
            "cache_paths": list(roles.values()),
            "cache_roles": roles,
            "output_paths": [],
            "output_roles": {},
            "package_resolution_mode": "none",
        }

    def test_bootstrap_gate_and_absolute_safe_parent(self) -> None:
        with self.assertRaisesRegex(coordinator.CoordinatorError, "migration_required"):
            coordinator.status(self.state)
        self.assertFalse(Path(str(self.state) + ".lock").exists())
        with self.assertRaisesRegex(coordinator.CoordinatorError, "migration_required"):
            self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "migration_required"):
            coordinator.bootstrap(self.state, legacy_leases_quiesced=False)
        self.boot()
        self.assertTrue(coordinator.status(self.state)["migration_bootstrap"]["legacy_leases_quiesced"])
        linked = self.root / "linked"
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_state_path"):
            coordinator.bootstrap(linked / "state.json", legacy_leases_quiesced=True)

    def test_acquire_requires_registered_run_authority(self) -> None:
        self.boot()
        with self.assertRaisesRegex(
            coordinator.CoordinatorError, "unregistered_run_authority"
        ):
            coordinator.acquire(
                self.state,
                resource=coordinator.SOURCE_WRITER,
                descriptor=SOURCE,
                owner_run_id="unregistered-run",
                owner_actor="codex",
                ttl_seconds=60,
                run_authority=self.authority("unregistered-run"),
            )

    def test_build_descriptor_rejects_duplicate_cache_role_paths(self) -> None:
        descriptor = self.build_descriptor(self.root / "cache")
        descriptor["cache_roles"]["package_cache"] = descriptor["cache_roles"][
            "artifacts"
        ]
        descriptor["cache_paths"] = sorted(set(descriptor["cache_roles"].values()))
        with self.assertRaisesRegex(coordinator.CoordinatorError, "unique paths"):
            coordinator.normalize_descriptor(coordinator.BUILD_TUPLE, descriptor)

    def test_missing_bootstrapped_lock_fails_closed_without_recreation(self) -> None:
        self.boot()
        lock_path = Path(str(self.state) + ".lock")
        held = lock_path.open("r+")
        try:
            lock_path.unlink()
            self.assertFalse(lock_path.exists())
            with self.assertRaisesRegex(
                coordinator.CoordinatorError, "bootstrapped coordinator lock is missing"
            ):
                coordinator.status(self.state)
            with self.assertRaisesRegex(
                coordinator.CoordinatorError, "bootstrapped coordinator lock is missing"
            ):
                self.acquire(coordinator.SOURCE_WRITER, SOURCE)
            self.assertFalse(lock_path.exists())
        finally:
            held.close()

    def test_two_threads_only_one_conflicting_writer_wins(self) -> None:
        self.boot()
        barrier = threading.Barrier(3)
        outcomes: list[str] = []

        def claim(run: str) -> None:
            barrier.wait()
            try:
                self.acquire(coordinator.SOURCE_WRITER, SOURCE, run=run)
                outcomes.append("won")
            except coordinator.CoordinatorError as error:
                outcomes.append(error.code)

        threads = [threading.Thread(target=claim, args=(f"run-{index}",)) for index in range(2)]
        for thread in threads: thread.start()
        barrier.wait()
        for thread in threads: thread.join()
        self.assertEqual(sorted(outcomes), ["resource_conflict", "won"])

    def test_independent_coordinator_copies_only_one_conflicting_writer_wins(self) -> None:
        self.boot()
        copies = [self.root / f"agent-harness-{index}" for index in range(2)]
        source = ROOT / "skills" / "agent-harness"
        for copy in copies:
            shutil.copytree(source, copy)
        bindings = [
            self.cli_harness(copy_root, f"process-{index}", f"process-{index}")
            for index, copy_root in enumerate(copies)
        ]

        wrapper = (
            "import os, runpy, sys; os.read(0, 1); sys.argv = sys.argv[1:]; "
            "runpy.run_path(sys.argv[0], run_name='__main__')"
        )
        processes = [
            subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    wrapper,
                    str(copy / "scripts" / "resource_coordinator.py"),
                    str(self.state),
                    "acquire",
                    "--harness",
                    str(harness),
                    "--authorization",
                    str(authorization),
                    "--resource",
                    coordinator.SOURCE_WRITER,
                    "--descriptor",
                    json.dumps(source_descriptor),
                    "--run-id",
                    f"process-{index}",
                    "--actor",
                    "codex",
                    "--ttl-seconds",
                    "60",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for index, copy in enumerate(copies)
            for harness, authorization, source_descriptor in [bindings[index]]
        ]
        try:
            for process in processes:
                assert process.stdin is not None
                process.stdin.write("x")
                process.stdin.flush()
            results = [process.communicate(timeout=10) for process in processes]
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

        payloads = []
        for process, (stdout, stderr) in zip(processes, results):
            self.assertEqual(process.returncode in (0, 2), True, stderr)
            payloads.append(json.loads(stdout))
        self.assertEqual(
            sorted((payload["status"], payload.get("reason_code")) for payload in payloads),
            [("blocked", "resource_conflict"), ("ok", None)],
        )

    def test_cli_malformed_json_is_machine_readable_without_traceback(self) -> None:
        self.boot()
        script = ROOT / "skills" / "agent-harness" / "scripts" / "resource_coordinator.py"
        harness, authorization, _source = self.cli_harness(
            ROOT / "skills" / "agent-harness", "run-a", "malformed"
        )
        commands = [
            ["acquire", "--harness", str(harness), "--authorization", str(authorization), "--resource", coordinator.SOURCE_WRITER,
             "--descriptor", "{", "--run-id", "run-a", "--actor", "codex", "--ttl-seconds", "60"],
            ["verify", "--harness", str(harness), "--receipt", "{"],
            ["heartbeat", "--harness", str(harness), "--receipt", "{", "--ttl-seconds", "60"],
            ["release", "--harness", str(harness), "--receipt", "{"],
            [
                "recover", "--harness", str(harness), "--receipt", "{",
                "--evidence", "{}", "--observer-harness", str(harness),
                "--observer-authorization", str(authorization),
            ],
        ]
        for arguments in commands:
            completed = subprocess.run(
                [sys.executable, str(script), str(self.state), *arguments],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(2, completed.returncode)
            self.assertEqual("", completed.stderr)
            self.assertEqual(
                {"status": "blocked", "reason_code": "invalid_request"},
                json.loads(completed.stdout),
            )

    def test_binding_rejects_mixed_installed_contract_bundle(self) -> None:
        self.boot()
        copied = self.root / "agent-harness"
        shutil.copytree(ROOT / "skills" / "agent-harness", copied)
        coordinator_script = copied / "scripts" / "resource_coordinator.py"
        harness, authorization, source_descriptor = self.cli_harness(
            copied, "mixed-run", "mixed"
        )
        checker = copied / "scripts" / "check_authorization.py"
        checker.write_text(
            checker.read_text(encoding="utf-8") + "\n# simulated mixed installation\n",
            encoding="utf-8",
        )
        completed = subprocess.run(
            [
                sys.executable,
                str(coordinator_script),
                str(self.state),
                "acquire",
                "--harness",
                str(harness),
                "--authorization",
                str(authorization),
                "--resource",
                coordinator.SOURCE_WRITER,
                "--descriptor",
                json.dumps(source_descriptor),
                "--run-id",
                "mixed-run",
                "--actor",
                "codex",
                "--ttl-seconds",
                "60",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(2, completed.returncode)
        self.assertEqual(
            {"status": "blocked", "reason_code": "untrusted_binding"},
            json.loads(completed.stdout),
        )

    def test_repository_fingerprint_prefix_alias_cannot_split_writer(self) -> None:
        self.boot()
        receipt = self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        self.assertEqual(
            receipt["resource_key"],
            coordinator.canonical_resource_key(
                coordinator.SOURCE_WRITER,
                {
                    "identity_version": "github_remote_v2",
                    "repository_fingerprint": "a" * 64,
                },
            ),
        )
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(
                coordinator.SOURCE_WRITER,
                {
                    "identity_version": "github_remote_v2",
                    "repository_fingerprint": "a" * 64,
                },
                run="run-b",
            )

    def test_receipt_verification_accepts_only_monotonic_heartbeat_lineage(self) -> None:
        self.boot()
        original = self.acquire(coordinator.SOURCE_WRITER, SOURCE, ttl=60)
        renewed = self.heartbeat(original, ttl=120)
        errors, current = coordinator.verify_receipt(self.state, original)
        self.assertEqual([], errors)
        self.assertEqual(renewed, current)

        forged = dict(original)
        forged["fencing_token"] += 1
        errors, current = coordinator.verify_receipt(self.state, forged)
        self.assertIsNone(current)
        self.assertIn("stale_receipt", errors)

        future = dict(renewed)
        future["expires_at"] = "2099-01-01T00:00:00Z"
        errors, current = coordinator.verify_receipt(self.state, future)
        self.assertIsNone(current)
        self.assertIn("stale_receipt", errors)

    def test_simulator_pair_single_disjoint_and_registry_conflicts(self) -> None:
        self.boot()
        instance = self.instance()
        pair = self.acquire(coordinator.SIMULATOR, {"coordinator_instance_id": instance, "udids": ["WATCH-1", "PHONE-1"]})
        self.assertEqual(pair["resource_key"], coordinator.canonical_resource_key(coordinator.SIMULATOR, {"coordinator_instance_id": instance, "udids": ["phone-1", "watch-1"]}))
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.SIMULATOR, {"coordinator_instance_id": instance, "udids": ["watch-1"]}, run="run-b")
        self.acquire(coordinator.SIMULATOR, {"coordinator_instance_id": instance, "udids": ["tablet-1"]}, run="run-c")
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.CORE_SIMULATOR, {"coordinator_instance_id": instance, "registry_scope": "all-runtimes"}, run="run-d")
        self.boot(self.root / "other.json")
        other_instance = self.instance(self.root / "other.json")
        other_authority = self.authority("run-x")
        coordinator.register_run_authority(
            self.root / "other.json", "run-x", other_authority
        )
        other = coordinator.acquire(self.root / "other.json", resource=coordinator.CORE_SIMULATOR, descriptor={"coordinator_instance_id": other_instance, "registry_scope": "all-runtimes"}, owner_run_id="run-x", owner_actor="codex", ttl_seconds=60, run_authority=other_authority)
        self.assertNotEqual(pair["coordinator_instance_id"], other["coordinator_instance_id"])

    def test_cache_nested_paths_and_symlink_alias_conflict(self) -> None:
        self.boot()
        self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        cache = self.root / "cache"
        child = cache / "child"
        child.mkdir(parents=True)
        alias = self.root / "cache-alias"
        alias.symlink_to(cache, target_is_directory=True)
        build = self.build_descriptor(cache)
        self.acquire(coordinator.BUILD_TUPLE, build)
        for path in (child, alias):
            with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
                other = self.build_descriptor(path)
                self.acquire(coordinator.BUILD_TUPLE, other, run=str(path))
        case_alias = self.root / "CACHE" / "other"
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            other = self.build_descriptor(case_alias)
            self.acquire(coordinator.BUILD_TUPLE, other, run="case-alias")

        incomplete = self.build_descriptor(self.root / "separate")
        incomplete["cache_roles"].pop("artifacts")
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_descriptor"):
            self.acquire(coordinator.BUILD_TUPLE, incomplete, run="incomplete")

    def test_disjoint_caches_with_shared_xcode_output_path_conflict(self) -> None:
        self.boot()
        self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        shared_result = self.root / "Results" / "tests.xcresult"
        first = self.build_descriptor(self.root / "cache-a")
        first["output_roles"] = {"result_bundle": str(shared_result)}
        first["output_paths"] = [str(shared_result)]
        second = self.build_descriptor(self.root / "cache-b")
        second["output_roles"] = {"result_bundle": str(shared_result)}
        second["output_paths"] = [str(shared_result)]
        self.acquire(coordinator.BUILD_TUPLE, first)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.BUILD_TUPLE, second, run="run-b")

    def test_package_resolution_requires_writer_and_xcode_mutation_leases(self) -> None:
        self.boot()
        guarded_build = self.build_descriptor(self.root / "guarded-cache")
        with self.assertRaisesRegex(coordinator.CoordinatorError, "source_writer_required"):
            self.acquire(coordinator.BUILD_TUPLE, guarded_build)
        package_build = self.build_descriptor(self.root / "package-cache")
        package_build["package_resolution_mode"] = "swiftpm_lockfile"
        with self.assertRaisesRegex(coordinator.CoordinatorError, "source_writer_required"):
            self.acquire(coordinator.BUILD_TUPLE, package_build)

        source = self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        package_receipt = self.acquire(coordinator.BUILD_TUPLE, package_build)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "dependent_lease_active"):
            self.release(source)
        self.release(package_receipt)
        self.release(source)

        source = self.acquire(coordinator.SOURCE_WRITER, SOURCE, run="run-xcode")
        xcode_build = self.build_descriptor(self.root / "xcode-cache")
        xcode_build["package_resolution_mode"] = "xcode_project_packages"
        with self.assertRaisesRegex(
            coordinator.CoordinatorError, "xcode_project_lease_required"
        ):
            self.acquire(coordinator.BUILD_TUPLE, xcode_build, run="run-xcode")
        project_descriptor = {
            "repository_fingerprint": FINGERPRINT,
            "container_path": xcode_build["container_path"],
        }
        project = self.acquire(
            coordinator.XCODE_PROJECT, project_descriptor, run="run-xcode"
        )
        build = self.acquire(coordinator.BUILD_TUPLE, xcode_build, run="run-xcode")
        with self.assertRaisesRegex(coordinator.CoordinatorError, "dependent_lease_active"):
            self.release(project)
        self.release(build)
        self.release(project)
        self.release(source)

    def test_same_owner_package_resolution_builds_are_serialized_per_repository(self) -> None:
        self.boot()
        source = self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        first = self.build_descriptor(self.root / "resolution-a")
        first["package_resolution_mode"] = "swiftpm_lockfile"
        second = self.build_descriptor(self.root / "resolution-b")
        second["package_resolution_mode"] = "swiftpm_lockfile"
        first_receipt = self.acquire(coordinator.BUILD_TUPLE, first)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.BUILD_TUPLE, second)
        self.release(first_receipt)
        self.release(source)

        source = self.acquire(coordinator.SOURCE_WRITER, SOURCE, run="run-xcode")
        project_descriptor = {
            "repository_fingerprint": FINGERPRINT,
            "container_path": first["container_path"],
        }
        project = self.acquire(
            coordinator.XCODE_PROJECT, project_descriptor, run="run-xcode"
        )
        first["package_resolution_mode"] = "xcode_project_packages"
        second["package_resolution_mode"] = "xcode_project_packages"
        first_receipt = self.acquire(
            coordinator.BUILD_TUPLE, first, run="run-xcode"
        )
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.BUILD_TUPLE, second, run="run-xcode")
        self.release(first_receipt)
        self.release(project)
        self.release(source)

    def test_standalone_swiftpm_cache_role_mapping_is_accepted(self) -> None:
        package_root = self.root / "package"
        build_root = package_root / ".build"
        roles = {
            "derived_data": str(build_root),
            "source_packages": str(build_root / "workspace-state.json"),
            "repository_checkouts": str(build_root / "checkouts"),
            "artifacts": str(build_root / "artifacts"),
            "package_cache": str(self.root / "swiftpm-cache"),
        }
        descriptor = {
            "repository_fingerprint": FINGERPRINT,
            "container_path": str(package_root / "Package.swift"),
            "xcode_build": "swift-6.2",
            "sdk": "macosx",
            "scheme": "package",
            "configuration": "debug",
            "architecture": "arm64",
            "package_fingerprint": "sha256:" + "f" * 64,
            "cache_roles": roles,
            "cache_paths": list(roles.values()),
            "output_paths": [],
            "output_roles": {},
            "package_resolution_mode": "swiftpm_lockfile",
        }
        normalized = coordinator.normalize_descriptor(
            coordinator.BUILD_TUPLE, descriptor
        )
        self.assertEqual(
            {role: str(Path(path).resolve()) for role, path in roles.items()},
            normalized["cache_roles"],
        )

    def test_same_owner_can_nest_source_with_xcode_or_build_but_other_run_cannot(self) -> None:
        self.boot()
        self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        xcode = {
            "repository_fingerprint": FINGERPRINT,
            "container_path": str(self.root / "App.xcodeproj"),
        }
        xcode_receipt = self.acquire(coordinator.XCODE_PROJECT, xcode)
        self.release(xcode_receipt)
        self.acquire(coordinator.BUILD_TUPLE, self.build_descriptor(self.root / "cache"))
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.XCODE_PROJECT, xcode, run="run-b")
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(
                coordinator.BUILD_TUPLE,
                self.build_descriptor(self.root / "other-cache"),
                run="run-b",
            )

    def test_macos_foreground_gui_session_is_host_scoped(self) -> None:
        self.boot()
        descriptor = {
            "coordinator_instance_id": self.instance(),
            "session_scope": "foreground_ui",
        }
        self.acquire(coordinator.MACOS_GUI, descriptor)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.MACOS_GUI, descriptor, run="run-b")

    def test_xcode_container_and_repository_writer_overlap_fail_closed(self) -> None:
        self.boot()
        container = str(self.root / "App.xcodeproj")
        xcode_descriptor = {
            "repository_fingerprint": FINGERPRINT,
            "container_path": container,
        }
        self.acquire(coordinator.XCODE_PROJECT, xcode_descriptor)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(
                coordinator.SOURCE_WRITER,
                SOURCE,
                run="run-source",
            )
        coordinator_state = self.root / "other-coordinator.json"
        self.boot(coordinator_state)
        coordinator.register_run_authority(
            coordinator_state, "run-a", self.authority("run-a")
        )
        coordinator.register_run_authority(
            coordinator_state, "run-b", self.authority("run-b")
        )
        first = coordinator.acquire(
            coordinator_state,
            resource=coordinator.XCODE_PROJECT,
            descriptor=xcode_descriptor,
            owner_run_id="run-a",
            owner_actor="codex",
            ttl_seconds=60,
            run_authority=self.authority("run-a"),
        )
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            coordinator.acquire(
                coordinator_state,
                resource=coordinator.XCODE_PROJECT,
                descriptor={
                    "repository_fingerprint": "sha256:" + "b" * 64,
                    "container_path": container,
                },
                owner_run_id="run-b",
                owner_actor="codex",
                ttl_seconds=60,
                run_authority=self.authority("run-b"),
            )
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            coordinator.acquire(
                coordinator_state,
                resource=coordinator.XCODE_PROJECT,
                descriptor={
                    "repository_fingerprint": FINGERPRINT,
                    "container_path": str(self.root / "App.xcworkspace"),
                },
                owner_run_id="run-b",
                owner_actor="codex",
                ttl_seconds=60,
                run_authority=self.authority("run-b"),
            )
        coordinator.release(
            coordinator_state,
            first,
            run_authority=self.authority(first["owner_run_id"]),
        )

    def test_github_remote_aliases_share_one_mutation_lease(self) -> None:
        self.boot()
        receipt = self.acquire(
            coordinator.GITHUB,
            {
                "repository_fingerprint": FINGERPRINT,
                "remote_repository": "Example/Repository.git",
            },
        )
        self.assertEqual(
            coordinator.canonical_resource_key(
                coordinator.GITHUB,
                {
                    "repository_fingerprint": FINGERPRINT,
                    "remote_repository": "example/repository",
                },
            ),
            receipt["resource_key"],
        )
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(
                coordinator.GITHUB,
                {
                    "repository_fingerprint": "sha256:" + "b" * 64,
                    "remote_repository": "EXAMPLE/REPOSITORY",
                },
                run="run-b",
            )
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_descriptor"):
            coordinator.normalize_descriptor(
                coordinator.GITHUB,
                {
                    "repository_fingerprint": FINGERPRINT,
                    "remote_repository": "https://github.com/example/repository",
                },
            )

    def test_expiry_cannot_take_over_and_forged_release_is_refused(self) -> None:
        self.boot()
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        receipt = self.acquire(coordinator.SOURCE_WRITER, SOURCE, now=now, ttl=1)
        self.assertEqual(coordinator.verify_receipt(self.state, receipt, now=now + timedelta(seconds=2)), (["expired_requires_recover"], None))
        with self.assertRaisesRegex(coordinator.CoordinatorError, "resource_conflict"):
            self.acquire(coordinator.SOURCE_WRITER, SOURCE, run="run-b", now=now + timedelta(days=1))
        forged = dict(receipt); forged["fencing_token"] += 1
        with self.assertRaisesRegex(coordinator.CoordinatorError, "stale_receipt"):
            coordinator.release(
                self.state,
                forged,
                run_authority=self.authority(receipt["owner_run_id"]),
            )

    def test_heartbeat_invalidates_the_previous_exact_receipt(self) -> None:
        self.boot()
        receipt = self.acquire(coordinator.SOURCE_WRITER, SOURCE, ttl=60)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_ttl"):
            self.heartbeat(receipt, ttl=3601)
        with self.assertRaisesRegex(coordinator.CoordinatorError, "heartbeat_must_extend"):
            self.heartbeat(receipt, ttl=1)
        extended = self.heartbeat(receipt, ttl=120)
        self.assertNotEqual(receipt["expires_at"], extended["expires_at"])
        with self.assertRaisesRegex(coordinator.CoordinatorError, "stale_receipt"):
            self.release(receipt)
        confirmation = self.release(extended)
        self.assertTrue(
            coordinator.validate_release_confirmation(
                extended, confirmation, state_path=self.state
            )
        )
        forged = dict(confirmation)
        forged["release_id"] = "forged"
        self.assertFalse(
            coordinator.validate_release_confirmation(
                extended, forged, state_path=self.state
            )
        )

    def test_authorization_window_bounds_acquire_and_heartbeat(self) -> None:
        self.boot()
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        authority = self.authority("run-window")
        authority["authorization_issued_at"] = "2026-01-01T00:00:00Z"
        authority["authorization_expires_at"] = "2026-01-01T00:00:30Z"
        coordinator.register_run_authority(
            self.state, "run-window", authority, now=now
        )
        with self.assertRaisesRegex(
            coordinator.CoordinatorError, "authorization_window_too_short"
        ):
            coordinator.acquire(
                self.state,
                resource=coordinator.SOURCE_WRITER,
                descriptor=SOURCE,
                owner_run_id="run-window",
                owner_actor="codex",
                ttl_seconds=31,
                now=now,
                run_authority=authority,
            )
        receipt = coordinator.acquire(
            self.state,
            resource=coordinator.SOURCE_WRITER,
            descriptor=SOURCE,
            owner_run_id="run-window",
            owner_actor="codex",
            ttl_seconds=10,
            now=now,
            run_authority=authority,
        )
        with self.assertRaisesRegex(
            coordinator.CoordinatorError, "authorization_window_too_short"
        ):
            coordinator.heartbeat(
                self.state,
                receipt,
                ttl_seconds=26,
                run_authority=authority,
                now=now + timedelta(seconds=5),
            )

    def test_receipt_mutation_requires_exact_run_authority_and_status_is_redacted(self) -> None:
        self.boot()
        receipt = self.acquire(coordinator.SOURCE_WRITER, SOURCE, run="run-a")
        other_authority = self.authority("run-b")
        with self.assertRaisesRegex(coordinator.CoordinatorError, "untrusted_authority"):
            coordinator.heartbeat(
                self.state,
                receipt,
                ttl_seconds=120,
                run_authority=other_authority,
            )
        with self.assertRaisesRegex(coordinator.CoordinatorError, "untrusted_authority"):
            coordinator.release(
                self.state, receipt, run_authority=other_authority
            )
        public_status = coordinator.status(self.state)
        self.assertEqual(
            {
                "schema_version",
                "coordinator_instance_id",
                "migration_bootstrap",
                "active_lease_count",
            },
            set(public_status),
        )
        self.assertEqual(1, public_status["active_lease_count"])
        self.assertNotIn("leases", public_status)
        self.assertNotIn("run_authorities", public_status)
        self.release(receipt)

    def test_recovery_replaces_lease_with_higher_fence_and_invalidates_old_receipt(self) -> None:
        self.boot()
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        old = self.acquire(coordinator.SOURCE_WRITER, SOURCE, now=now, ttl=1)
        recovery_time = now + timedelta(seconds=2)
        evidence = self.evidence(
            old, recovery_time, observer_run_id="run-b"
        )
        confirmation = self.recover(
            old, evidence=evidence, now=recovery_time,
            replacement={"resource": coordinator.SOURCE_WRITER, "descriptor": SOURCE, "owner_run_id": "run-b", "owner_actor": "codex", "ttl_seconds": 60},
            replacement_authority=self.authority("run-b"),
        )
        replacement = confirmation["replacement_receipt"]
        self.assertIsNotNone(replacement)
        self.assertGreater(confirmation["recovery_fencing_token"], old["fencing_token"])
        self.assertGreater(replacement["fencing_token"], confirmation["recovery_fencing_token"])
        self.assertTrue(coordinator.validate_recovery_confirmation(old, evidence, confirmation, state_path=self.state))
        forged_replacement = dict(confirmation)
        forged_replacement["replacement_receipt"] = dict(replacement)
        forged_replacement["replacement_receipt"]["owner_actor"] = "forged"
        self.assertFalse(
            coordinator.validate_recovery_confirmation(
                old,
                evidence,
                forged_replacement,
                state_path=self.state,
            )
        )
        self.assertEqual(coordinator.verify_receipt(self.state, old), (["stale_receipt"], None))
        self.assertEqual(coordinator.verify(self.state, replacement, now=recovery_time)["lease_id"], replacement["lease_id"])

    def test_no_replacement_recovery_advances_fence_and_forged_confirmation_fails(self) -> None:
        self.boot()
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        receipt = self.acquire(coordinator.SOURCE_WRITER, SOURCE, now=now, ttl=1)
        recovery_time = now + timedelta(seconds=2)
        evidence = self.evidence(receipt, recovery_time)
        confirmation = self.recover(receipt, evidence=evidence, now=recovery_time)
        self.assertIsNone(confirmation["replacement_receipt"])
        self.assertGreater(confirmation["recovery_fencing_token"], receipt["fencing_token"])
        self.assertEqual(coordinator.verify_receipt(self.state, receipt, now=recovery_time), (["stale_receipt"], None))
        self.assertTrue(coordinator.validate_recovery_confirmation(receipt, evidence, confirmation, state_path=self.state))
        forged = dict(confirmation); forged["recovery_fencing_token"] += 1
        self.assertFalse(coordinator.validate_recovery_confirmation(receipt, evidence, forged, state_path=self.state))

    def test_recovery_rejects_live_owner_and_stale_observations(self) -> None:
        self.boot()
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        receipt = self.acquire(coordinator.SOURCE_WRITER, SOURCE, now=now, ttl=1)
        recovery_time = now + timedelta(seconds=2)
        valid_evidence = self.evidence(receipt, recovery_time)
        with self.assertRaisesRegex(
            coordinator.CoordinatorError, "untrusted_authority"
        ):
            coordinator.recover(
                self.state,
                receipt,
                evidence=valid_evidence,
                run_authority=self.authority(receipt["owner_run_id"]),
                now=recovery_time,
            )
        live_owner = self.evidence(receipt, recovery_time)
        live_owner["owner_liveness"]["state"] = "live"
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_recovery_evidence"):
            self.recover(receipt, evidence=live_owner, now=recovery_time)
        live_child = self.evidence(receipt, recovery_time)
        live_child["owner_tool_children"]["state"] = "live"
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_recovery_evidence"):
            self.recover(receipt, evidence=live_child, now=recovery_time)
        same_run_observer = self.evidence(receipt, recovery_time)
        same_run_observer["observer"]["observer_run_id"] = receipt["owner_run_id"]
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_recovery_evidence"):
            self.recover(receipt, evidence=same_run_observer, now=recovery_time)
        stale = self.evidence(receipt, recovery_time - timedelta(minutes=6))
        with self.assertRaisesRegex(coordinator.CoordinatorError, "stale_recovery_evidence"):
            self.recover(receipt, evidence=stale, now=recovery_time)

    def test_malformed_persisted_state_fails_closed(self) -> None:
        self.state.write_text('{"schema_version":1,"coordinator_instance_id":"x","migration_bootstrap":null,"next_fencing_token":0,"leases":{"bad":{}}}')
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_state"):
            coordinator.status(self.state)

    def test_duplicate_or_overlapping_persisted_leases_fail_closed(self) -> None:
        self.boot()
        self.acquire(coordinator.SOURCE_WRITER, SOURCE)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        original = next(iter(state["leases"].values()))
        duplicate = dict(original)
        duplicate["lease_id"] = "forged-lease"
        duplicate["receipt_id"] = "forged-receipt"
        duplicate["fencing_token"] = 2
        state["leases"][duplicate["lease_id"]] = duplicate
        state["next_fencing_token"] = 2
        self.state.write_text(json.dumps(state), encoding="utf-8")
        with self.assertRaisesRegex(coordinator.CoordinatorError, "overlapping active leases"):
            coordinator.status(self.state)

    def test_naive_test_clock_is_rejected(self) -> None:
        self.boot()
        with self.assertRaisesRegex(coordinator.CoordinatorError, "invalid_time"):
            self.acquire(
                coordinator.SOURCE_WRITER,
                SOURCE,
                now=datetime(2026, 1, 1),
            )


if __name__ == "__main__":
    unittest.main()
