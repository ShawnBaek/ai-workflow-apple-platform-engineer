#!/usr/bin/env python3
"""Validate and render a delivery preview to stdout; never sends it."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import re
import sys


def fail(message):
    raise ValueError(message)


def exact_object(value, keys, label, allow_schema=False):
    if not isinstance(value, dict) or set(value) - ({"$schema"} if allow_schema else set()) != set(keys):
        fail(label + " fields differ from the completion-report contract")


def nullable_string(value):
    return value is None or isinstance(value, str)


def validate_report(report):
    required = {"schema_version", "status", "task", "changes", "pull_requests", "checks", "evidence", "omissions", "usage"}
    exact_object(report, required, "completion report", allow_schema=True)
    if "$schema" in report and not isinstance(report["$schema"], str):
        fail("completion-report schema reference must be a string")
    if report["schema_version"] != "1.0.0" or report["status"] not in {"complete", "partial", "blocked"} or not nullable_string(report["task"]):
        fail("invalid completion-report identity or status")
    if any(not isinstance(report[key], list) for key in ("changes", "pull_requests", "checks", "evidence", "omissions")):
        fail("completion-report collection fields must be arrays")
    if not all(isinstance(value, str) for value in report["changes"]):
        fail("completion-report changes must be strings")
    for item in report["pull_requests"]:
        exact_object(item, {"url", "state"}, "pull request")
        if not nullable_string(item["url"]) or item["state"] not in {"created", "not_created", "unknown"}:
            fail("invalid pull-request result")
    for item in report["checks"]:
        exact_object(item, {"name", "result", "summary"}, "check")
        if not isinstance(item["name"], str) or item["result"] not in {"passed", "failed", "not_run", "unknown"} or not nullable_string(item["summary"]):
            fail("invalid check result")
    for item in report["evidence"]:
        exact_object(item, {"kind", "reference", "observed_result", "sha256"}, "evidence")
        if item["kind"] not in {"screenshot", "trimmed_video", "xcresult", "log", "other"} or not nullable_string(item["reference"]) or not nullable_string(item["observed_result"]) or (item["sha256"] is not None and not re.fullmatch(r"[0-9a-f]{64}", str(item["sha256"]))):
            fail("invalid evidence record")
    for item in report["omissions"]:
        exact_object(item, {"check", "reason", "residual_risk"}, "omission")
        if not all(isinstance(item[key], str) for key in ("check", "reason", "residual_risk")):
            fail("invalid omission record")
    validate_usage(report["usage"])


def validate_usage(usage):
    exact_object(usage, {"status", "missing_sources", "source_records", "attribution", "cross_provider_total", "cost"}, "usage")
    status = usage.get("status")
    missing, records = usage.get("missing_sources"), usage.get("source_records")
    attribution, total = usage.get("attribution"), usage.get("cross_provider_total")
    if status not in {"full", "partial", "not_exposed"} or not isinstance(missing, list) or not isinstance(records, dict) or not isinstance(attribution, list):
        fail("invalid usage structure")
    if status == "full" and (missing or not records):
        fail("full usage requires records and no missing sources")
    if status == "partial" and (not missing or not records):
        fail("partial usage requires reported and missing sources")
    if status == "not_exposed" and (not missing or records or total is not None):
        fail("not_exposed usage cannot contain token records or totals")
    if not all(isinstance(value, str) for value in missing):
        fail("missing usage sources must be strings")

    known_input = known_output = complete = 0
    for source_id, item in records.items():
        exact_object(item, {"provider", "input_tokens", "output_tokens", "cached_input_tokens", "reasoning_tokens"}, "usage source")
        if not isinstance(item["provider"], str):
            fail("usage provider must be a string: " + source_id)
        inp, out = item.get("input_tokens"), item.get("output_tokens")
        cached, reasoning = item.get("cached_input_tokens"), item.get("reasoning_tokens")
        if any(value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 0) for value in (inp, out, cached, reasoning)):
            fail("usage token values must be nonnegative integers: " + source_id)
        if (inp is None) != (out is None):
            fail("usage source must expose input and output together: " + source_id)
        if (cached is not None and (inp is None or cached > inp)) or (reasoning is not None and (out is None or reasoning > out)):
            fail("usage subset exceeds or lacks its parent total: " + source_id)
        if inp is not None:
            complete += 1; known_input += inp; known_output += out
    if status == "full" and complete != len(records):
        fail("full usage cannot contain unknown token counts")
    if status == "partial" and complete == 0:
        fail("partial usage needs at least one complete source")

    referenced = []
    for item in attribution:
        exact_object(item, {"agent_id", "session_id", "model", "source_ids"}, "usage attribution")
        if not all(isinstance(item[key], str) for key in ("agent_id", "session_id", "model")) or not isinstance(item["source_ids"], list) or not all(isinstance(value, str) for value in item["source_ids"]) or len(item["source_ids"]) != len(set(item["source_ids"])):
            fail("invalid usage attribution")
        referenced.extend(item["source_ids"])
    if len(referenced) != len(set(referenced)):
        fail("usage source IDs must be attributed exactly once")
    if set(referenced) != set(records):
        fail("usage attribution must match source records")
    if complete:
        exact_object(total, {"input_tokens", "output_tokens", "label"}, "cross-provider total")
        if any(not isinstance(total.get(key), int) or isinstance(total.get(key), bool) or total.get(key) < 0 for key in ("input_tokens", "output_tokens")) or total.get("input_tokens") != known_input or total.get("output_tokens") != known_output or total.get("label") != "informational; cached input and reasoning are subsets, not added":
            fail("cross-provider total does not equal unique reported sources")
    elif total is not None:
        fail("cross-provider total requires complete token sources")

    cost = usage.get("cost", {})
    exact_object(cost, {"status", "amount", "currency"}, "cost")
    cost_status, amount, currency = cost.get("status"), cost.get("amount"), cost.get("currency")
    if amount is not None and (not isinstance(amount, (int, float)) or isinstance(amount, bool) or amount < 0):
        fail("cost amount must be nonnegative")
    if cost_status == "not_exposed" and (amount is not None or currency is not None):
        fail("unexposed cost cannot contain amount or currency")
    if cost_status in {"provider_reported", "client_estimate"} and (amount is None or not isinstance(currency, str) or not currency):
        fail("reported or estimated cost requires amount and currency")
    if cost_status not in {"provider_reported", "client_estimate", "not_exposed"}:
        fail("invalid cost status")


def lines(report, channel):
    if not isinstance(report, dict):
        fail("completion report must be an object")
    validate_report(report)
    usage = report["usage"]
    records, owners = usage["source_records"], {}
    for item in usage["attribution"]:
        label = "/".join(str(item.get(key, "?")) for key in ("agent_id", "session_id", "model"))
        for source_id in item.get("source_ids", []):
            owners[source_id] = label
    heading = (lambda text: "# " + text) if channel == "markdown" else (lambda text: "📌 " + text)
    out = [heading("Completion Report"), f"Status: {report.get('status', 'unknown')}", f"Task: {report.get('task') or 'not recorded'}"]

    def section(name, values):
        out.append(heading(name)); out.extend(values or ["- none recorded"])

    section("Changes", ["- " + str(value) for value in report.get("changes", [])])
    section("PRs", [f"- {item.get('state', 'unknown')}: {item.get('url') or 'no link'}" for item in report.get("pull_requests", [])])
    section("Checks", [f"- {item.get('name')}: {item.get('result')} — {item.get('summary') or 'no summary'}" for item in report.get("checks", [])])
    evidence = [item for item in report.get("evidence", []) if item.get("kind") in {"screenshot", "trimmed_video", "xcresult"}]
    section("Evidence", [f"- {item['kind']}: {item.get('observed_result') or 'no observed result'} ({item.get('reference') or 'no reference'})" for item in evidence])
    section("Omissions / residual risk", [f"- {item.get('check')}: {item.get('reason')} Risk: {item.get('residual_risk')}" for item in report.get("omissions", [])])
    source_lines = []
    for source_id, item in records.items():
        source_lines.append(f"- {item.get('provider')}/{source_id}: input {item.get('input_tokens')}, output {item.get('output_tokens')}; cached-input {item.get('cached_input_tokens')} and reasoning {item.get('reasoning_tokens')} are subsets; {owners[source_id]}")
    section("Resource Usage (" + str(usage["status"]) + ")", source_lines)
    if usage["missing_sources"]:
        out.append("Missing usage sources: " + ", ".join(str(value) for value in usage["missing_sources"]))
    total = usage["cross_provider_total"]
    out.append("Cross-provider total (informational): " + (f"input {total.get('input_tokens')}, output {total.get('output_tokens')}" if total else "not exposed"))
    cost = usage["cost"]
    out.append(f"Cost: {cost['status']}; {cost.get('amount') if cost.get('amount') is not None else 'not exposed'} {cost.get('currency') or ''}".rstrip())
    return "\n".join(out) + "\n"


def _timestamp(value):
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        fail("authorization timestamps require a timezone")
    return parsed


def validate_authorization(auth, rendered, channel, channel_id, destination_ref, whatsapp_request_sha256=None, now=None):
    required = {"schema_version", "decision", "authorization_id", "run_id", "issued_at", "expires_at", "channel_id", "channel_kind", "destination_ref", "report_sha256", "media_allowlist", "transport_ref", "idempotency_key", "single_use", "whatsapp_mode", "whatsapp_template_ref", "whatsapp_template_language", "whatsapp_request_sha256", "cost_approval"}
    if set(auth) - {"$schema"} != required:
        fail("authorization fields differ from the exact contract")
    if auth["schema_version"] != "1.0.0" or auth["decision"] != "approved" or auth["single_use"] is not True:
        fail("authorization must be approved, versioned, and single-use")
    if auth["channel_kind"] != channel or auth["channel_id"] != channel_id or auth["destination_ref"] != destination_ref:
        fail("authorization channel or destination drifted")
    if not re.fullmatch(r"[a-z][a-z0-9._-]{1,63}", channel_id) or not re.fullmatch(r"(?:private|shortcuts)\.[a-z][a-z0-9._-]{1,127}", destination_ref):
        fail("authorization must use private aliases, not raw recipient identifiers")
    for field in ("authorization_id", "run_id", "idempotency_key"):
        if not isinstance(auth[field], str) or not re.fullmatch(r"[A-Za-z0-9._:-]{3,128}", auth[field]):
            fail("authorization identity is incomplete: " + field)
    if not isinstance(auth["transport_ref"], str) or not re.fullmatch(r"[a-z][a-z0-9.-]{1,63}", auth["transport_ref"]):
        fail("authorization transport alias is invalid")
    expected_transport = {"telegram": "bot-api", "whatsapp": "cloud-api", "imessage": "shortcuts"}[channel]
    if not auth["transport_ref"].startswith(expected_transport):
        fail("authorization transport does not match its channel")
    if channel == "imessage" and not destination_ref.startswith("shortcuts."):
        fail("iMessage destination must remain inside a Shortcut alias")
    if channel != "imessage" and not destination_ref.startswith("private."):
        fail("network-channel destination must be a private alias")
    observed_at = now or datetime.now(timezone.utc)
    if not (_timestamp(auth["issued_at"]) <= observed_at < _timestamp(auth["expires_at"])):
        fail("authorization is not active")
    if auth["report_sha256"] != hashlib.sha256(rendered.encode("utf-8")).hexdigest():
        fail("rendered report hash drifted from authorization")
    media = auth["media_allowlist"]
    if not isinstance(media, list):
        fail("media_allowlist must be an array")
    references = []
    for item in media:
        if not isinstance(item, dict) or set(item) != {"kind", "reference", "sha256"} or item["kind"] not in {"screenshot", "trimmed_video"} or not isinstance(item["reference"], str) or not item["reference"] or not re.fullmatch(r"[0-9a-f]{64}", str(item["sha256"])):
            fail("media_allowlist contains an invalid or raw artifact")
        references.append(item["reference"])
    if len(references) != len(set(references)):
        fail("media_allowlist references must be unique")
    mode, cost = auth["whatsapp_mode"], auth["cost_approval"]
    template_ref, language, request_hash = auth["whatsapp_template_ref"], auth["whatsapp_template_language"], auth["whatsapp_request_sha256"]
    if channel == "whatsapp":
        if mode not in {"service_window", "approved_template"}:
            fail("WhatsApp authorization must bind service window or approved template mode")
        if mode == "approved_template":
            if cost != "approved_for_this_send" or not isinstance(template_ref, str) or not re.fullmatch(r"private\.[a-z][a-z0-9._-]{1,127}", template_ref) or not isinstance(language, str) or not re.fullmatch(r"[a-z]{2,3}(?:_[A-Z]{2})?", language) or not re.fullmatch(r"[0-9a-f]{64}", str(request_hash)):
                fail("WhatsApp template identity, language, request hash, or cost approval is incomplete")
            if whatsapp_request_sha256 != request_hash:
                fail("canonical WhatsApp request hash drifted from authorization")
        elif any(value is not None for value in (template_ref, language, request_hash, whatsapp_request_sha256)):
            fail("WhatsApp service-window authorization cannot carry template request fields")
    elif mode is not None or cost != "not_applicable" or any(value is not None for value in (template_ref, language, request_hash, whatsapp_request_sha256)):
        fail("non-WhatsApp authorization cannot carry WhatsApp mode or cost approval")


def main():
    parser = argparse.ArgumentParser(description="Validate and format a preview to stdout; never send it.")
    parser.add_argument("report")
    parser.add_argument("--channel", choices=["markdown", "telegram", "whatsapp", "imessage"], default="markdown")
    parser.add_argument("--authorization")
    parser.add_argument("--channel-id")
    parser.add_argument("--destination-ref")
    parser.add_argument("--whatsapp-request-sha256")
    args = parser.parse_args()
    try:
        with open(args.report, encoding="utf-8") as handle:
            rendered = lines(json.load(handle), args.channel)
        if args.authorization:
            if not args.channel_id or not args.destination_ref or args.channel == "markdown":
                fail("authorization validation requires channel, channel-id, and destination-ref")
            with open(args.authorization, encoding="utf-8") as handle:
                validate_authorization(json.load(handle), rendered, args.channel, args.channel_id, args.destination_ref, args.whatsapp_request_sha256)
        elif args.channel_id or args.destination_ref or args.whatsapp_request_sha256:
            fail("channel identity arguments require an authorization file")
        print(rendered, end="")
    except (OSError, TypeError, KeyError, AttributeError, json.JSONDecodeError, ValueError) as error:
        print("render_report: " + str(error), file=sys.stderr); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
