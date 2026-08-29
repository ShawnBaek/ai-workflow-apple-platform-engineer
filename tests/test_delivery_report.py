from __future__ import annotations
import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills/delivery-report/scripts/render_report.py"
sys.path.insert(0, str(ROOT / "scripts"))
import validate_repository as validator  # noqa: E402

SPEC = importlib.util.spec_from_file_location("delivery_renderer", SCRIPT)
renderer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(renderer)

class DeliveryReportTest(unittest.TestCase):
    def render(self, report, channel="markdown"):
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(report, handle); handle.flush()
            return subprocess.run([sys.executable, str(SCRIPT), handle.name, "--channel", channel], text=True, capture_output=True)

    def test_full_report_deduplicates_and_never_claims_delivery(self):
        report = validator.load_json(ROOT / "skills/agent-harness/templates/completion-report.json")
        report.update({"status":"complete", "task":"Ship fix", "changes":["fix"], "pull_requests":[{"state":"created","url":"https://example.test/pr/1"}], "checks":[{"name":"unit","result":"passed","summary":"ok"}], "evidence":[{"kind":"screenshot","observed_result":"shown","reference":"shot.png","sha256":"a" * 64}]})
        report["usage"] = {"status":"full","missing_sources":[], "source_records":{"r1":{"provider":"openai","input_tokens":10,"output_tokens":5,"cached_input_tokens":2,"reasoning_tokens":3}}, "attribution":[{"agent_id":"writer","session_id":"s1","model":"terra","source_ids":["r1"]}], "cross_provider_total":{"input_tokens":10,"output_tokens":5,"label":"informational; cached input and reasoning are subsets, not added"}, "cost":{"status":"client_estimate","amount":0.1,"currency":"USD"}}
        result = self.render(report)
        self.assertEqual(result.returncode, 0); self.assertEqual(result.stdout.count("input 10"), 2)
        self.assertIn("cached-input 2 and reasoning 3 are subsets", result.stdout); self.assertNotIn("delivered", result.stdout.lower())
        invalid = copy.deepcopy(report); invalid.pop("schema_version")
        self.assertNotEqual(self.render(invalid).returncode, 0)
        report["usage"]["cross_provider_total"]["input_tokens"] = 11
        self.assertNotEqual(self.render(report).returncode, 0)

    def test_not_exposed_and_duplicate_attribution(self):
        report = validator.load_json(ROOT / "skills/agent-harness/templates/completion-report.json")
        report["usage"]["missing_sources"] = ["client"]
        result = self.render(report, "telegram")
        self.assertEqual(result.returncode, 0); self.assertIn("not_exposed", result.stdout); self.assertIn("client", result.stdout)
        report["usage"].update({"status":"full", "missing_sources":[], "source_records":{"r":{"provider":"x","input_tokens":1,"output_tokens":1,"cached_input_tokens":0,"reasoning_tokens":0}}, "attribution":[{"agent_id":"a","session_id":"s","model":"m","source_ids":["r"]}, {"agent_id":"b","session_id":"s","model":"m","source_ids":["r"]}], "cross_provider_total":{"input_tokens":1,"output_tokens":1,"label":"informational; cached input and reasoning are subsets, not added"}})
        self.assertNotEqual(self.render(report).returncode, 0)

    def test_channel_config_rejects_implicit_send_policy(self):
        root = ROOT / "skills/delivery-report"
        config = validator.load_json(root / "templates/channel-config.json")
        schema = validator.load_json(root / "contracts/channel-config.schema.json")
        self.assertEqual(validator.validate_json_schema(config, schema), [])
        config["enabled"] = True
        config["channels"] = [{
            "id": "owner", "kind": "telegram", "enabled": True,
            "destination_ref": "private.owner", "credential_ref": "keychain.telegram.owner",
            "transport_ref": "bot-api", "send_policy": "exact_task_authorization",
            "media_policy": "reviewed_allowlist_only", "whatsapp_template_ref": None,
        }]
        self.assertEqual(validator.validate_json_schema(config, schema), [])
        self.assertEqual(validator.validate_delivery_channel_config(config), [])
        config["channels"][0]["send_policy"] = "always"
        errors = validator.validate_json_schema(config, schema)
        self.assertTrue(any("exact_task_authorization" in error for error in errors))
        config["channels"][0]["send_policy"] = "exact_task_authorization"
        config["channels"].append(copy.deepcopy(config["channels"][0]))
        self.assertIn("delivery channel IDs must be unique", validator.validate_delivery_channel_config(config))
        config["channels"][0]["destination_ref"] = "6591234567"
        self.assertTrue(validator.validate_json_schema(config, schema))

    def test_exact_delivery_authorization_binds_rendered_hash(self):
        report = validator.load_json(ROOT / "skills/agent-harness/templates/completion-report.json")
        rendered = renderer.lines(report, "telegram")
        authorization = {
            "schema_version":"1.0.0", "decision":"approved", "authorization_id":"auth-001", "run_id":"run-001",
            "issued_at":"2026-01-01T00:00:00Z", "expires_at":"2099-01-01T00:00:00Z",
            "channel_id":"owner", "channel_kind":"telegram", "destination_ref":"private.telegram.owner",
            "report_sha256":hashlib.sha256(rendered.encode()).hexdigest(),
            "media_allowlist":[{"kind":"trimmed_video", "reference":"evidence/flow.mp4", "sha256":"1" * 64}],
            "transport_ref":"bot-api", "idempotency_key":"delivery-001", "single_use":True,
            "whatsapp_mode":None, "whatsapp_template_ref":None,
            "whatsapp_template_language":None, "whatsapp_request_sha256":None,
            "cost_approval":"not_applicable",
        }
        schema = validator.load_json(ROOT / "skills/delivery-report/contracts/delivery-authorization.schema.json")
        self.assertEqual(validator.validate_json_schema(authorization, schema), [])
        renderer.validate_authorization(authorization, rendered, "telegram", "owner", "private.telegram.owner", now=datetime(2026, 8, 30, tzinfo=timezone.utc))
        whatsapp = copy.deepcopy(authorization)
        whatsapp.update({"channel_id":"owner-wa", "channel_kind":"whatsapp", "destination_ref":"private.whatsapp.owner", "transport_ref":"cloud-api", "whatsapp_mode":"approved_template", "whatsapp_template_ref":"private.whatsapp.report", "whatsapp_template_language":"en_US", "whatsapp_request_sha256":"2" * 64, "cost_approval":"approved_for_this_send"})
        self.assertEqual(validator.validate_json_schema(whatsapp, schema), [])
        renderer.validate_authorization(whatsapp, rendered, "whatsapp", "owner-wa", "private.whatsapp.owner", "2" * 64, datetime(2026, 8, 30, tzinfo=timezone.utc))
        drifted = copy.deepcopy(authorization); drifted["report_sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            renderer.validate_authorization(drifted, rendered, "telegram", "owner", "private.telegram.owner", now=datetime(2026, 8, 30, tzinfo=timezone.utc))

if __name__ == "__main__": unittest.main()
