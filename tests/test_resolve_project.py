from __future__ import annotations

import os
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "agent-harness" / "scripts"))
import resolve_project  # noqa: E402


class ProjectRegistryResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tempdir.name)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def repository(self, name: str, remote_repository: str = "Sample") -> Path:
        root = self.base / name
        root.mkdir()
        (root / "Sample.xcodeproj").mkdir()
        subprocess.run(["git", "init", "-q", os.fspath(root)], check=True)
        subprocess.run(["git", "-C", os.fspath(root), "remote", "add", "origin", f"git@github.com:ExampleOrg/{remote_repository}.git"], check=True)
        return root

    def registry(self, *roots: Path) -> dict:
        return {
            "schema_version": "1.0.0",
            "developer_id": "developer-a",
            "host_id": "host-a",
            "projects": [{
                "project_id": f"sample-{index}",
                "remote_fingerprint": resolve_project.remote_fingerprint(
                    subprocess.run(
                        ["git", "-C", os.fspath(root), "config", "--get", "remote.origin.url"],
                        check=True, capture_output=True, text=True,
                    ).stdout.strip()
                ),
                "checkouts": [{
                    "checkout_id": f"checkout-{index}", "kind": "primary",
                    "path": os.fspath(root),
                    "xcode_containers": ["Sample.xcodeproj"],
                }],
            } for index, root in enumerate(roots, 1)],
        }

    def test_normalizes_github_https_and_ssh_without_git_suffix(self) -> None:
        expected = "github.com/exampleorg/sample"
        for value in (
            "https://github.com/ExampleOrg/Sample.git",
            "ssh://git@github.com/ExampleOrg/Sample",
            "git@github.com:ExampleOrg/Sample.git",
        ):
            self.assertEqual(resolve_project.normalize_github_remote(value), expected)
        for value in (
            "https://token@github.com/ExampleOrg/Sample.git",
            "https://github.com/ExampleOrg/Sample.git?token=value",
            "file:///tmp/repository",
            "https://github.com:8443/ExampleOrg/Sample.git",
            "ssh://git@github.com:2222/ExampleOrg/Sample.git",
            "https://github.com:not-a-port/ExampleOrg/Sample.git",
        ):
            with self.assertRaises(ValueError):
                resolve_project.normalize_github_remote(value)

    def test_explicit_path_wins_without_reading_registry(self) -> None:
        root = self.repository("one")
        result = resolve_project.resolve_project(
            {"not": "a registry"}, developer_id="developer-a", host_id="host-a",
            explicit_path=os.fspath(root),
        )
        self.assertEqual(result["status"], "resolved")
        self.assertEqual(result["reason_code"], "explicit_path")
        self.assertEqual(result["candidate"]["canonical_root"], os.fspath(root.resolve()))

    def test_multiple_valid_candidates_never_selects_first(self) -> None:
        first, second = self.repository("first"), self.repository("second", "Second")
        result = resolve_project.resolve_project(
            self.registry(second, first), developer_id="developer-a", host_id="host-a"
        )
        self.assertEqual(result["status"], "needs_selection")
        self.assertEqual(result["reason_code"], "multiple_candidates")
        self.assertEqual(len(result["candidates"]), 2)
        self.assertEqual(
            result["candidates"],
            sorted(result["candidates"], key=lambda item: (item["project_id"], item["canonical_root"])),
        )

    def test_filters_to_current_developer_and_host(self) -> None:
        root = self.repository("one")
        registry = self.registry(root)
        result = resolve_project.resolve_project(
            registry, developer_id="developer-b", host_id="host-a"
        )
        self.assertEqual(result, {"status": "unavailable", "reason_code": "no_matching_profile"})

    def test_rejects_non_root_symlink_and_unsafe_container(self) -> None:
        root = self.repository("one")
        child = root / "child"
        child.mkdir()
        link = self.base / "linked"
        link.symlink_to(root, target_is_directory=True)
        for path in (child, link):
            result = resolve_project.resolve_project(
                None, developer_id="developer-a", host_id="host-a", explicit_path=os.fspath(path)
            )
            self.assertEqual(result["status"], "blocked")
            self.assertIn(result["reason_code"], {"not_git_root", "unsafe_path"})

        registry = self.registry(root)
        registry["projects"][0]["checkouts"][0]["xcode_containers"] = ["../escaped.xcodeproj"]
        result = resolve_project.resolve_project(registry, developer_id="developer-a", host_id="host-a")
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason_code"], "invalid_xcode_container")

    def test_registry_is_optional_and_nonmatching_is_unavailable(self) -> None:
        self.assertEqual(
            resolve_project.resolve_project(None, developer_id="developer-a", host_id="host-a"),
            {"status": "unavailable", "reason_code": "registry_not_configured"},
        )
        root = self.repository("one")
        self.assertEqual(
            resolve_project.resolve_project(self.registry(root), developer_id="developer-a", host_id="host-b"),
            {"status": "unavailable", "reason_code": "no_matching_profile"},
        )

    def test_opened_container_wins_and_conflicts_with_explicit_root(self) -> None:
        first, second = self.repository("first"), self.repository("second")
        result = resolve_project.resolve_project(
            self.registry(first), developer_id="developer-a", host_id="host-a",
            opened_xcode_container=os.fspath(first / "Sample.xcodeproj"),
        )
        self.assertEqual(result["reason_code"], "opened_xcode_container")
        self.assertEqual(result["candidate"]["canonical_root"], os.fspath(first.resolve()))
        conflict = resolve_project.resolve_project(
            None, developer_id="developer-a", host_id="host-a",
            explicit_path=os.fspath(first),
            opened_xcode_container=os.fspath(second / "Sample.xcodeproj"),
        )
        self.assertEqual(conflict, {
            "status": "blocked", "reason_code": "opened_xcode_conflicts_explicit_path",
        })

    def test_authoritative_targets_bypass_stale_or_invalid_registry(self) -> None:
        first, second = self.repository("first"), self.repository("second")
        registry = {"not": "a valid registry"}
        result = resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a",
            project_id="sample-1", explicit_path=os.fspath(second),
        )
        self.assertEqual(result["reason_code"], "explicit_path")
        opened = resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a",
            project_id="sample-1",
            opened_xcode_container=os.fspath(first / "Sample.xcodeproj"),
        )
        self.assertEqual(opened["reason_code"], "opened_xcode_container")

    def test_registry_kind_mismatch_is_blocked(self) -> None:
        root = self.repository("one")
        registry = self.registry(root)
        registry["projects"][0]["checkouts"][0]["kind"] = "worktree"
        unavailable = resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a"
        )
        self.assertEqual(unavailable, {
            "status": "blocked", "reason_code": "checkout_kind_mismatch",
        })
        resolved = resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a", allow_worktree=True
        )
        self.assertEqual(resolved, {
            "status": "blocked", "reason_code": "checkout_kind_mismatch",
        })

    def test_fingerprint_cli_never_prints_raw_remote(self) -> None:
        root = self.repository("one")
        script = ROOT / "skills" / "agent-harness" / "scripts" / "resolve_project.py"
        result = subprocess.run(
            [sys.executable, os.fspath(script), "--fingerprint-path", os.fspath(root)],
            check=True, capture_output=True, text=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "resolved")
        self.assertEqual(payload["reason_code"], "fingerprinted")
        self.assertEqual(set(payload), {"status", "reason_code", "remote_fingerprint"})
        self.assertNotIn("github.com", result.stdout)

    def test_stale_candidate_warns_while_valid_candidate_resolves(self) -> None:
        valid, stale = self.repository("valid"), self.repository("stale", "Stale")
        registry = self.registry(valid, stale)
        stale_checkout = registry["projects"][1]["checkouts"][0]
        stale_checkout["path"] = os.fspath(self.base / "missing")
        result = resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a"
        )
        self.assertEqual(result["status"], "resolved")
        self.assertEqual(result["candidate"]["checkout_id"], "checkout-1")
        self.assertEqual(result["warnings"], [{
            "project_id": "sample-2", "checkout_id": "checkout-2", "reason_code": "missing_path",
        }])

    def test_missing_container_is_stale_but_unsafe_container_is_blocked(self) -> None:
        valid, stale = self.repository("valid"), self.repository("stale", "Stale")
        registry = self.registry(valid, stale)
        (stale / "Sample.xcodeproj").rmdir()
        result = resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a"
        )
        self.assertEqual(result["status"], "resolved")
        self.assertEqual(result["warnings"][0]["reason_code"], "missing_xcode_container")

        duplicate = self.registry(valid)
        duplicate["projects"][0]["checkouts"][0]["xcode_containers"] = [
            "Sample.xcodeproj",
            "Sample.xcodeproj",
        ]
        self.assertEqual(
            resolve_project.resolve_project(
                duplicate, developer_id="developer-a", host_id="host-a"
            ),
            {"status": "blocked", "reason_code": "invalid_xcode_container"},
        )

    def test_all_stale_candidates_block_and_duplicate_registry_identities_reject(self) -> None:
        root = self.repository("one")
        registry = self.registry(root)
        registry["projects"][0]["checkouts"][0]["path"] = os.fspath(self.base / "missing")
        self.assertEqual(resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a"
        )["reason_code"], "no_valid_candidates")
        duplicate = self.registry(root)
        duplicate["projects"].append(duplicate["projects"][0].copy())
        self.assertEqual(resolve_project.resolve_project(
            duplicate, developer_id="developer-a", host_id="host-a"
        ), {"status": "blocked", "reason_code": "duplicate_registry_identity"})

    def test_registry_cli_hash_output(self) -> None:
        root = self.repository("one")
        registry = self.registry(root)
        registry_path = self.base / "registry.json"
        registry_path.write_text(json.dumps(registry), encoding="utf-8")
        script = ROOT / "skills" / "agent-harness" / "scripts" / "resolve_project.py"
        result = subprocess.run(
            [sys.executable, os.fspath(script), "--registry", os.fspath(registry_path),
             "--developer-id", "developer-a", "--host-id", "host-a"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["registry_sha256"], resolve_project.registry_sha256(registry))
        self.assertFalse(payload["worktree_authorized"])
        self.assertEqual(
            {
                key: payload[key] for key in (
                    "resolver_version", "registry_sha256", "worktree_authorized",
                    "warnings", "candidate",
                )
            },
            {
                "resolver_version": "1.0.0",
                "registry_sha256": resolve_project.registry_sha256(registry),
                "worktree_authorized": False,
                "warnings": [],
                "candidate": payload["candidate"],
            },
        )
        self.assertIsNotNone(payload["candidate"])

    def test_invalid_selectors_and_duplicate_checkout_ids_are_blocked(self) -> None:
        root = self.repository("one")
        self.assertEqual(resolve_project.resolve_project(
            self.registry(root), developer_id="developer/a", host_id="host-a"
        ), {"status": "blocked", "reason_code": "invalid_selector"})
        registry = self.registry(root)
        registry["projects"][0]["checkouts"][0]["checkout_id"] = "CheckOut"
        duplicate_checkout = dict(registry["projects"][0]["checkouts"][0])
        duplicate_checkout["checkout_id"] = "checkout"
        registry["projects"][0]["checkouts"].append(duplicate_checkout)
        self.assertEqual(resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a"
        ), {"status": "blocked", "reason_code": "duplicate_checkout_id"})

    def test_cli_status_exit_codes(self) -> None:
        first, second = self.repository("first"), self.repository("second", "Second")
        registry_path = self.base / "registry.json"
        registry_path.write_text(json.dumps(self.registry(first, second)), encoding="utf-8")
        script = ROOT / "skills" / "agent-harness" / "scripts" / "resolve_project.py"
        common = [sys.executable, os.fspath(script), "--registry", os.fspath(registry_path),
                  "--developer-id", "developer-a", "--host-id", "host-a"]
        self.assertEqual(subprocess.run(common, capture_output=True, text=True).returncode, 3)
        self.assertEqual(subprocess.run(
            [sys.executable, os.fspath(script), "--developer-id", "developer-a",
             "--host-id", "host-a", "--explicit-path", os.fspath(first)],
            capture_output=True, text=True,
        ).returncode, 0)
        self.assertEqual(subprocess.run(
            [sys.executable, os.fspath(script), "--developer-id", "developer-a",
             "--host-id", "host-a", "--explicit-path", os.fspath(first / "not-a-root")],
            capture_output=True, text=True,
        ).returncode, 2)

    def test_cli_authoritative_path_does_not_load_malformed_registry_or_require_selectors(self) -> None:
        root = self.repository("one")
        registry_path = self.base / "malformed.json"
        registry_path.write_text("{", encoding="utf-8")
        script = ROOT / "skills" / "agent-harness" / "scripts" / "resolve_project.py"
        result = subprocess.run(
            [sys.executable, os.fspath(script), "--registry", os.fspath(registry_path),
             "--explicit-path", os.fspath(root)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["reason_code"], "explicit_path")
        self.assertNotIn("registry_sha256", payload)

    def test_cli_rejects_null_and_duplicate_json_registry_keys(self) -> None:
        script = ROOT / "skills" / "agent-harness" / "scripts" / "resolve_project.py"
        for index, content in enumerate((
            "null",
            '{"schema_version":"1.0.0","schema_version":"1.0.0"}',
            '{"schema_version":"1.0.0","developer_id":"developer-a","host_id":"host-a","projects":[{"project_id":"one","project_id":"two"}]}',
        )):
            registry_path = self.base / f"invalid-{index}.json"
            registry_path.write_text(content, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, os.fspath(script), "--registry", os.fspath(registry_path),
                 "--developer-id", "developer-a", "--host-id", "host-a"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout), {
                "status": "blocked", "reason_code": "invalid_registry",
            })

    def test_live_linked_worktree_requires_opt_in_even_when_registry_claims_primary(self) -> None:
        source = self.repository("source")
        (source / "tracked.txt").write_text("tracked\n", encoding="utf-8")
        subprocess.run(["git", "-C", os.fspath(source), "add", "tracked.txt"], check=True)
        subprocess.run(
            ["git", "-C", os.fspath(source), "-c", "user.name=Fixture", "-c",
             "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
            check=True,
        )
        linked = self.base / "linked"
        subprocess.run(["git", "-C", os.fspath(source), "worktree", "add", "-q", "--detach", os.fspath(linked), "HEAD"], check=True)
        facts = resolve_project.validate_project_root(os.fspath(linked))
        self.assertEqual(facts["kind"], "worktree")
        denied = resolve_project.resolve_project(
            None, developer_id="developer-a", host_id="host-a", explicit_path=os.fspath(linked)
        )
        self.assertEqual(denied, {
            "status": "unavailable", "reason_code": "worktree_not_authorized",
        })
        allowed = resolve_project.resolve_project(
            None, developer_id="developer-a", host_id="host-a", explicit_path=os.fspath(linked),
            allow_worktree=True,
        )
        self.assertEqual(allowed["candidate"]["kind"], "worktree")
        registry = self.registry(source)
        registry["projects"][0]["checkouts"][0].update({
            "path": os.fspath(linked), "kind": "primary", "xcode_containers": [],
        })
        mismatched = resolve_project.resolve_project(
            registry, developer_id="developer-a", host_id="host-a", allow_worktree=True
        )
        self.assertEqual(mismatched, {
            "status": "blocked", "reason_code": "checkout_kind_mismatch",
        })


if __name__ == "__main__":
    unittest.main()
