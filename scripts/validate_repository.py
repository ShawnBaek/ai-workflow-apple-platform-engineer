#!/usr/bin/env python3
"""Dependency-free structural validation for the iOS-experts skill repository."""
from __future__ import annotations

from datetime import datetime
import hashlib
import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills"
CONTRACTS = SKILLS / "agent-harness" / "contracts"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def validate_completion_report(report: dict[str, Any]) -> list[str]:
    """Validate usage aggregation rules that JSON Schema cannot express."""
    errors: list[str] = []
    usage = report.get("usage", {})
    status = usage.get("status")
    missing = usage.get("missing_sources", [])
    sources = usage.get("source_records", {})
    attribution = usage.get("attribution", [])
    total = usage.get("cross_provider_total")
    cost = usage.get("cost", {})

    if status == "full" and (missing or not sources):
        errors.append("full usage requires source records and no missing sources")
    if status == "partial" and (not missing or not sources):
        errors.append("partial usage requires reported and missing sources")
    if status == "not_exposed" and (not missing or sources or total is not None):
        errors.append("not_exposed usage must preserve missing sources without token records or totals")

    known_input = known_output = complete_source_count = 0
    unknown_counts: list[str] = []
    referenced: list[str] = []
    for source_id, source in sources.items():
        input_tokens, output_tokens = source.get("input_tokens"), source.get("output_tokens")
        cached = source.get("cached_input_tokens")
        reasoning = source.get("reasoning_tokens")
        if (input_tokens is None) != (output_tokens is None):
            errors.append(f"usage source {source_id} must expose input and output together")
        if input_tokens is None and output_tokens is None:
            unknown_counts.append(source_id)
        if input_tokens is not None and cached is not None and cached > input_tokens:
            errors.append(f"usage source {source_id} cached input exceeds input tokens")
        if output_tokens is not None and reasoning is not None and reasoning > output_tokens:
            errors.append(f"usage source {source_id} reasoning exceeds output tokens")
        if input_tokens is not None and output_tokens is not None:
            complete_source_count += 1
            known_input += input_tokens
            known_output += output_tokens
    if status == "full" and unknown_counts:
        errors.append(f"full usage cannot contain unexposed token sources: {sorted(unknown_counts)}")
    if status == "partial" and complete_source_count == 0:
        errors.append("partial usage requires at least one complete token source")
    for item in attribution:
        referenced.extend(item.get("source_ids", []))
    unknown_refs = sorted(set(referenced) - set(sources))
    if unknown_refs:
        errors.append(f"usage attribution references unknown sources: {unknown_refs}")
    duplicate_refs = sorted(source_id for source_id in set(referenced) if referenced.count(source_id) != 1)
    if duplicate_refs:
        errors.append(f"usage sources must be attributed exactly once: {duplicate_refs}")
    unattributed = sorted(set(sources) - set(referenced))
    if unattributed:
        errors.append(f"usage sources lack attribution: {unattributed}")

    if known_input or known_output:
        if total is None or total.get("input_tokens") != known_input or total.get("output_tokens") != known_output:
            errors.append("cross-provider token total must equal each unique reported source exactly once")
    elif total is not None:
        errors.append("cross-provider token total requires at least one complete source")

    cost_status, amount, currency = cost.get("status"), cost.get("amount"), cost.get("currency")
    if cost_status == "not_exposed" and (amount is not None or currency is not None):
        errors.append("unexposed cost cannot contain an amount or currency")
    if cost_status in {"provider_reported", "client_estimate"} and (amount is None or not currency):
        errors.append("reported or estimated cost requires amount and currency")
    return errors


def validate_delivery_channel_config(config: dict[str, Any]) -> list[str]:
    """Enforce alias and channel-ownership rules beyond JSON Schema."""
    errors: list[str] = []
    channels = config.get("channels", [])
    ids = [item.get("id") for item in channels]
    if len(ids) != len(set(ids)):
        errors.append("delivery channel IDs must be unique")
    active = [item for item in channels if item.get("enabled") is True]
    if config.get("enabled") is True and not active:
        errors.append("enabled delivery config requires one enabled channel")
    if config.get("enabled") is False and active:
        errors.append("disabled delivery config cannot contain enabled channels")
    transport_prefix = {"telegram": "bot-api", "whatsapp": "cloud-api", "imessage": "shortcuts"}
    for item in channels:
        kind = item.get("kind")
        credential, destination = item.get("credential_ref"), str(item.get("destination_ref", ""))
        if kind in {"telegram", "whatsapp"} and credential is None:
            errors.append(f"{kind} channel requires a private credential reference")
        if kind == "imessage" and (credential is not None or not destination.startswith("shortcuts.")):
            errors.append("iMessage channel must keep its recipient only inside a Shortcut")
        if kind != "imessage" and not destination.startswith("private."):
            errors.append(f"{kind} channel destination must be a private alias")
        if kind in transport_prefix and not str(item.get("transport_ref", "")).startswith(transport_prefix[kind]):
            errors.append(f"{kind} channel transport alias does not match its provider")
        if kind != "whatsapp" and item.get("whatsapp_template_ref") is not None:
            errors.append("only WhatsApp channels may reference a WhatsApp template")
    return errors


def frontmatter_name(path: Path) -> str | None:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"^name:\s*([^\n]+)$", text, re.MULTILINE) if text.startswith("---\n") else None
    return match.group(1).strip() if match else None


def _type(value: Any, name: str) -> bool:
    return {
        "object": isinstance(value, dict), "array": isinstance(value, list),
        "string": isinstance(value, str), "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool), "null": value is None,
    }.get(name, False)


def _date_time(value: str) -> bool:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})", value):
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def validate_json_schema(instance: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    """Validate the JSON Schema subset used by contracts/schemas, without dependencies."""
    errors: list[str] = []
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(isinstance(name, str) and _type(instance, name) for name in names):
            return [f"{path}: expected type {schema['type']!r}"]
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: must equal {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: must be one of {schema['enum']!r}")
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{path}: must have minLength {schema['minLength']}")
        if schema.get("format") == "date-time" and not _date_time(instance):
            errors.append(f"{path}: must be an RFC3339 date-time")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errors.append(f"{path}: must match pattern {schema['pattern']!r}")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool) and "minimum" in schema and instance < schema["minimum"]:
        errors.append(f"{path}: must be at least {schema['minimum']}")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: must contain at least {schema['minItems']} items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            errors.append(f"{path}: must contain at most {schema['maxItems']} items")
        if schema.get("uniqueItems") and len({json.dumps(value, sort_keys=True) for value in instance}) != len(instance):
            errors.append(f"{path}: items must be unique")
        if isinstance(schema.get("items"), dict):
            for index, value in enumerate(instance):
                errors.extend(validate_json_schema(value, schema["items"], f"{path}[{index}]"))
        if isinstance(schema.get("contains"), dict) and not any(
            not validate_json_schema(value, schema["contains"], f"{path}[*]")
            for value in instance
        ):
            errors.append(f"{path}: must contain an item matching the required schema")
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            errors.append(f"{path}: must contain at least {schema['minProperties']} properties")
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        if schema.get("additionalProperties") is False:
            errors.extend(f"{path}: additional property {key!r} is forbidden" for key in instance if key not in properties)
        elif isinstance(schema.get("additionalProperties"), dict):
            for key in instance:
                if key not in properties:
                    errors.extend(
                        validate_json_schema(
                            instance[key], schema["additionalProperties"], f"{path}.{key}"
                        )
                    )
        for key, child in properties.items():
            if key in instance and isinstance(child, dict):
                errors.extend(validate_json_schema(instance[key], child, f"{path}.{key}"))
    for child in schema.get("allOf", []):
        errors.extend(validate_json_schema(instance, child, path))
    if "oneOf" in schema:
        matches = sum(not validate_json_schema(instance, child, path) for child in schema["oneOf"])
        if matches != 1:
            errors.append(f"{path}: must match exactly one oneOf branch (matched {matches})")
    if "not" in schema and not validate_json_schema(instance, schema["not"], path):
        errors.append(f"{path}: must not match the forbidden schema")
    if "if" in schema:
        branch = "then" if not validate_json_schema(instance, schema["if"], path) else "else"
        if isinstance(schema.get(branch), dict):
            errors.extend(validate_json_schema(instance, schema[branch], path))
    return errors


def validate_skills() -> tuple[list[str], list[str]]:
    errors, names = [], []
    for skill_file in sorted(SKILLS.glob("*/SKILL.md")):
        folder, name = skill_file.parent.name, frontmatter_name(skill_file)
        if name is None:
            errors.append(f"missing frontmatter name: {skill_file.relative_to(ROOT)}")
        else:
            if name != folder:
                errors.append(f"skill name mismatch: {folder} != {name}")
            names.append(name)
    if len(names) != len(set(names)):
        errors.append("skill names must be unique")
    return errors, names


LINK_PATTERN = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def validate_relative_links() -> list[str]:
    errors = []
    for markdown in sorted(ROOT.rglob("*.md")):
        for raw in LINK_PATTERN.findall(markdown.read_text(encoding="utf-8")):
            target = raw.strip().strip("<>").split("#", 1)[0]
            if target and not target.startswith(("http://", "https://", "mailto:")) and not (markdown.parent / target).resolve().exists():
                errors.append(f"broken relative link in {markdown.relative_to(ROOT)}: {raw}")
    return errors


def validate_dag(nodes: list[dict[str, Any]]) -> list[str]:
    ids = [node.get("id") for node in nodes]
    if any(not isinstance(node_id, str) or not node_id for node_id in ids):
        return ["every workflow node needs a non-empty string id"]
    errors, known, dependencies = [], set(ids), {}
    if len(ids) != len(known):
        errors.append("workflow node ids must be unique")
    for node in nodes:
        node_id, requires = node["id"], node.get("requires")
        if not isinstance(requires, list) or not all(isinstance(item, str) for item in requires):
            errors.append(f"node {node_id} requires must be a string array")
            continue
        dependencies[node_id] = requires
        for dependency in requires:
            if dependency == node_id:
                errors.append(f"node {node_id} cannot depend on itself")
            elif dependency not in known:
                errors.append(f"node {node_id} references missing dependency {dependency}")
    visiting, visited = set(), set()
    def visit(node_id: str) -> None:
        if node_id in visiting:
            errors.append(f"workflow contains a cycle at {node_id}")
        elif node_id not in visited:
            visiting.add(node_id)
            for dependency in dependencies.get(node_id, []):
                if dependency in dependencies:
                    visit(dependency)
            visiting.remove(node_id)
            visited.add(node_id)
    for node_id in ids:
        visit(node_id)
    return sorted(set(errors))


CONTROL_SPINE = [
    "intake",
    "guard",
    "health",
    "discover",
    "discover_spec_kit",
    "plan",
    "approve_plan",
    "branch_approval",
    "bind_spec_kit_snapshot",
    "bind_run_authorization",
    "claim_implementation_writer",
    "prepare_and_verify_branch",
    "claim_github_tracking",
    "ensure_issue_ready",
    "release_github_tracking",
    "claim_github_in_progress",
    "mark_issue_in_progress",
    "release_github_in_progress",
    "implement",
    "release_implementation_writer",
    "verify",
    "freeze_review",
    "review",
    "converge",
    "reverify",
    "prepare_evidence",
    "prepare_pr",
    "repository_confirmation",
    "claim_delivery_writer",
    "commit",
    "release_delivery_writer",
    "claim_github_mutation",
    "push",
    "verify_remote_sha",
    "create_pr",
    "mark_issue_in_review",
    "publish_evidence",
    "verify_published_evidence",
    "checks",
    "release_github_mutation",
    "pr_ready",
]
LEASE_PAIRS = {
    "source_checkout_writer": [
        "claim_implementation_writer",
        "release_implementation_writer",
        "claim_delivery_writer",
        "release_delivery_writer",
    ],
    "github_external_mutation": [
        "claim_github_tracking",
        "release_github_tracking",
        "claim_github_in_progress",
        "release_github_in_progress",
        "claim_github_mutation",
        "release_github_mutation",
    ],
}
RUNTIME_REGISTRY_POLICY = {
    "failure_class": "coresimulator_runtime_disk_registration",
    "normalized_signatures": ["unable to get a dev_t for store <store-id>"],
    "minimum_repeat_observations": 2,
    "supporting_enumeration_gap_seconds": 30,
    "supporting_evidence_not_causal_proof": [
        "simdiskimaged_process_continuity",
        "mixed_build_or_image_kind_inventory",
        "large_runtime_count",
        "low_free_storage",
    ],
    "restart_resets_processes_not_persisted_registry": True,
    "max_active_simulator_tool_providers_during_diagnosis": 1,
    "max_new_bounded_discovery_probes": 1,
    "recovery_resource": "coresimulator_runtime_registry",
    "conflicts_with": ["simulator_or_device"],
    "mutation_requires_matching_approval": True,
    "mutating_approval_binding": [
        "approval_id",
        "resource_key",
        "allowed_action",
        "runtime_identifier",
    ],
    "mutating_approval_single_use": True,
    "privileged_diagnostics_require_explicit_approval": True,
    "release_note_precedent_is_not_defect_equivalence": True,
    "verification_order": [
        "one_bounded_runtime_inventory",
        "release_runtime_registry_lease",
        "acquire_control_destination_lease",
        "one_designated_control_destination",
    ],
    "verification_repetitions": {
        "default": 1,
        "stability_acceptance": 3,
    },
    "toolchain_comparison": "sequential_one_provider_fixed_non_toolchain_inputs_record_runtime_confounders",
    "forbidden_automatic_actions": [
        "direct_registry_runtime_or_mount_mutation",
        "daemon_or_service_force_termination",
        "global_device_or_runtime_removal",
        "derived_data_deletion",
    ],
}
XCODE_MCP_PROVIDER_POLICY = {
    "state_dimensions": [
        "installation",
        "registration",
        "current_task_exposure",
        "read_only_connectivity",
        "exact_workspace_binding",
    ],
    "record_install_provenance": [
        "config_scope",
        "configured_command_and_args",
        "resolved_executable",
        "package_manager_owner",
        "resolved_version",
    ],
    "same_codex_host_clients_share_configuration": True,
    "provider_injection_layers": [
        "official_codex_mcpbridge",
        "direct_codex_mcp",
        "codex_plugin_mcp",
        "xcode_agent_plugin",
    ],
    "capability_results": [
        "workspace_discovery",
        "interaction_session",
        "workspace_bound_run",
        "hierarchy_touch_capture",
        "direct_apple_cli",
    ],
    "read_only_probe_timeout_seconds": 30,
    "max_unchanged_read_only_retries": 1,
    "official_external_agent_route_first": True,
    "configuration_mutation_requires_explicit_approval": True,
    "max_active_simulator_capable_providers_during_incident": 1,
    "verification_order": [
        "configured_and_enabled",
        "fresh_client_or_task_exposes_tools",
        "read_only_workspace_response",
        "exact_workspace_identifier_selected",
    ],
    "forbidden_security_mode": "blanket_unsafe_allow_all_agents",
    "forbidden_automatic_actions": [
        "provider_install_update_uninstall_or_config_mutation",
        "provider_process_force_termination",
        "build_or_destination_inventory_as_connectivity_probe",
    ],
}

FORBIDDEN_RUN_ACTIONS = [
    "git.force_push",
    "github.auto_merge",
    "github.ruleset_change",
    "apple.app_review_submit",
    "apple.production_release",
    "apple.signing_resource_mutation",
    "credential.scope_expansion",
    "environment.destructive_cleanup",
]
ALLOWED_RUN_ACTIONS = {
    "git.commit",
    "git.push",
    "github.issue.create",
    "github.issue.update",
    "github.issue.comment",
    "github.project.update",
    "github.pr.create",
    "github.pr.update",
    "github.pr.comment",
    "github.evidence.publish",
    "github.checks.wait",
    "apple.testflight.upload",
    "apple.testflight.processing.wait",
    "apple.testflight.distribute_internal",
    "apple.testflight.readback",
}
TESTFLIGHT_NODE_ORDER = [
    "bind_pr_ready",
    "verify_run_authorization",
    "health_gate",
    "claim_testflight_upload",
    "archive",
    "verify_artifact",
    "upload",
    "wait_processing",
    "read_back_upload",
    "release_testflight_upload",
    "claim_upload_evidence_publication",
    "publish_upload_evidence",
    "verify_upload_evidence",
    "release_upload_evidence_publication",
    "testflight_uploaded",
    "claim_testflight_distribution",
    "verify_internal_groups",
    "distribute_internal",
    "read_back_distribution",
    "release_testflight_distribution",
    "claim_distribution_evidence_publication",
    "publish_distribution_evidence",
    "verify_distribution_evidence",
    "release_distribution_evidence_publication",
    "testflight_distributed",
]


def valid_created_github_target(grant: dict[str, Any], output_target: Any) -> bool:
    direct = str(grant.get("target", ""))
    kind = grant.get("produces_target_kind")
    if kind == "github_issue" and ":feature:" in direct:
        repository = direct.split(":feature:", 1)[0]
        return re.fullmatch(rf"{re.escape(repository)}:issue:[1-9][0-9]*", str(output_target)) is not None
    if kind == "github_pr" and ":" in direct:
        repository = direct.split(":", 1)[0]
        return re.fullmatch(rf"{re.escape(repository)}:pr:[1-9][0-9]*", str(output_target)) is not None
    return False


def validate_run_authorization_contract(envelope: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if envelope.get("forbidden_actions") != FORBIDDEN_RUN_ACTIONS:
        errors.append("run authorization forbidden action boundary drifted")
    for flag in (
        "auto_merge",
        "app_review_submit",
        "credential_scope_expansion",
        "signing_resource_mutation",
        "destructive_cleanup",
    ):
        if envelope.get(flag) is not False:
            errors.append(f"run authorization {flag} must remain false")
    grants = envelope.get("action_grants", [])
    grant_ids, idempotency_keys = set(), set()
    for grant in grants:
        action = grant.get("action")
        if action not in ALLOWED_RUN_ACTIONS:
            errors.append(f"run authorization contains non-allowlisted action {action}")
        if grant.get("grant_id") in grant_ids:
            errors.append("run authorization grant IDs must be unique")
        if grant.get("idempotency_key") in idempotency_keys:
            errors.append("run authorization idempotency keys must be unique")
        grant_ids.add(grant.get("grant_id"))
        idempotency_keys.add(grant.get("idempotency_key"))
        if grant.get("single_use") is not True:
            errors.append("every run authorization action grant must be single use")
    actions = {grant.get("action") for grant in grants}
    target = envelope.get("delivery_target")
    apple = envelope.get("apple")
    if target == "pr_ready" and (apple is not None or any(str(action).startswith("apple.") for action in actions)):
        errors.append("pr_ready authorization cannot grant Apple mutations")
    if target in {"testflight_uploaded", "testflight_distributed"}:
        if not isinstance(apple, dict):
            errors.append("TestFlight authorization must bind an Apple target")
        for required in (
            "apple.testflight.upload",
            "apple.testflight.processing.wait",
            "apple.testflight.readback",
        ):
            if required not in actions:
                errors.append(f"TestFlight authorization missing {required}")
    if target == "testflight_distributed":
        if "apple.testflight.distribute_internal" not in actions:
            errors.append("TestFlight distribution authorization missing exact distribution grant")
        if not isinstance(apple, dict) or not apple.get("internal_group_ids"):
            errors.append("TestFlight distribution authorization missing exact group IDs")
    return errors


def validate_testflight_workflow(workflow: dict[str, Any]) -> list[str]:
    errors = validate_dag(workflow.get("nodes", []))
    nodes = workflow.get("nodes", [])
    ids = [node.get("id") for node in nodes]
    if ids != TESTFLIGHT_NODE_ORDER:
        errors.append("TestFlight continuation node order drifted")
    expected_dependencies = {
        node_id: ([] if index == 0 else [TESTFLIGHT_NODE_ORDER[index - 1]])
        for index, node_id in enumerate(TESTFLIGHT_NODE_ORDER)
    }
    observed_dependencies = {
        node.get("id"): node.get("requires") for node in nodes
    }
    if observed_dependencies != expected_dependencies:
        errors.append("TestFlight continuation dependency edges drifted")
    wait_node = next((node for node in nodes if node.get("id") == "wait_processing"), {})
    if {
        "timeout_from_authorization": wait_node.get("timeout_from_authorization"),
        "retry_bound_from_authorization": wait_node.get("retry_bound_from_authorization"),
        "heartbeat_active_lease": wait_node.get("heartbeat_active_lease"),
    } != {
        "timeout_from_authorization": "async_wait_minutes",
        "retry_bound_from_authorization": "max_transient_retries",
        "heartbeat_active_lease": True,
    }:
        errors.append("TestFlight processing wait must use authorization bounds and lease heartbeat")
    terminals = {
        node.get("terminal_for"): node.get("id")
        for node in nodes
        if node.get("terminal_for")
    }
    if terminals != {
        "testflight_uploaded": "testflight_uploaded",
        "testflight_distributed": "testflight_distributed",
    }:
        errors.append("TestFlight continuation terminals drifted")
    actions = [node.get("grant_action") for node in nodes if node.get("grant_action")]
    if actions != [
        "apple.testflight.upload",
        "apple.testflight.processing.wait",
        "apple.testflight.readback",
        "github.evidence.publish",
        "apple.testflight.distribute_internal",
        "apple.testflight.readback",
        "github.evidence.publish",
    ]:
        errors.append("TestFlight action-grant sequence drifted")
    leases = [
        (node.get("id"), node.get("resource"), node.get("lease_action"))
        for node in nodes
        if node.get("resource")
    ]
    if leases != [
        ("claim_testflight_upload", "signing_or_app_store_connect", "acquire"),
        ("release_testflight_upload", "signing_or_app_store_connect", "release"),
        ("claim_upload_evidence_publication", "github_external_mutation", "acquire"),
        ("release_upload_evidence_publication", "github_external_mutation", "release"),
        ("claim_testflight_distribution", "signing_or_app_store_connect", "acquire"),
        ("release_testflight_distribution", "signing_or_app_store_connect", "release"),
        ("claim_distribution_evidence_publication", "github_external_mutation", "acquire"),
        ("release_distribution_evidence_publication", "github_external_mutation", "release"),
    ]:
        errors.append("TestFlight continuation must balance Apple and evidence-publication leases")
    if workflow.get("starts_after") != "pr_ready":
        errors.append("TestFlight continuation must start after pr_ready")
    forbidden = workflow.get("policy", {}).get("forbidden_actions", [])
    if workflow.get("policy", {}).get("evidence_publication_requires_github_lease") is not True:
        errors.append("TestFlight evidence publication must require a GitHub lease")
    if workflow.get("policy", {}).get("release_every_acquired_lease_on_blocked_or_terminal") is not True:
        errors.append("TestFlight continuation must release every lease on blocked or terminal paths")
    if workflow.get("cleanup") != {
        "mode": "finally",
        "triggers": ["blocked", "failed_terminal", "cancelled", "success_terminal"],
        "release_active_resources": [
            "signing_or_app_store_connect",
            "github_external_mutation",
        ],
    }:
        errors.append("TestFlight continuation finally cleanup contract drifted")
    for action in (
        "apple.app_review_submit",
        "apple.production_release",
        "apple.signing_resource_mutation",
        "credential.scope_expansion",
        "github.auto_merge",
    ):
        if action not in forbidden:
            errors.append(f"TestFlight continuation forbidden action missing: {action}")
    return errors


def validate_companion_upstream(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    upstream = manifest.get("upstream", {})
    integration = manifest.get("integration", {})
    if upstream.get("repository") != "ShawnBaek/IconGen" or upstream.get("visibility") != "public":
        errors.append("IconGen companion upstream identity or visibility drifted")
    if integration != {
        "mode": "reference-only",
        "execute_upstream": False,
        "vendored_files": [],
        "consumer_skill": "icon-composer",
        "consumer_repository": "ShawnBaek/iOS-experts",
        "drift_action": "create_or_update_review_issue",
        "auto_merge": False,
    }:
        errors.append("IconGen companion upstream safety boundary drifted")
    if manifest.get("license", {}).get("status") == "absent" and integration.get("vendored_files"):
        errors.append("unlicensed companion upstream cannot have vendored files")
    return errors


def validate_icongen_workflow_text(text: str) -> list[str]:
    """Fail closed if the reference-only watcher gains broader triggers or writes."""
    errors: list[str] = []
    trigger_match = re.search(r"(?ms)^on:\n(?P<body>.*?)^permissions:\n", text)
    if trigger_match is None:
        return ["IconGen watcher trigger block is missing"]
    trigger_keys = re.findall(r"(?m)^  ([A-Za-z_][A-Za-z0-9_-]*):?\s*$", trigger_match.group("body"))
    if trigger_keys != ["schedule", "workflow_dispatch"]:
        errors.append("IconGen watcher triggers must be exactly schedule and workflow_dispatch")
    permission_match = re.search(r"(?ms)^permissions:\n(?P<body>.*?)^concurrency:\n", text)
    permission_lines = [] if permission_match is None else [
        line.strip() for line in permission_match.group("body").splitlines() if line.strip()
    ]
    if permission_lines != ["contents: read", "issues: write"]:
        errors.append("IconGen watcher permissions must remain contents read and issues write only")
    uses = re.findall(r"(?m)^\s*uses:\s*(\S+)", text)
    if uses != ["actions/checkout@11d5960a326750d5838078e36cf38b85af677262"]:
        errors.append("IconGen watcher may use only the pinned checkout action")
    jobs_match = re.search(r"(?ms)^jobs:\n(?P<body>.*)\Z", text)
    jobs = [] if jobs_match is None else re.findall(
        r"(?m)^  ([A-Za-z_][A-Za-z0-9_-]*):\s*$", jobs_match.group("body")
    )
    if jobs != ["compare"]:
        errors.append("IconGen watcher must contain exactly one compare job")
    required = (
        "runs-on: ubuntu-latest",
        "timeout-minutes: 5",
        "watch_companion_upstream.py",
        "--target-repository \"$GITHUB_REPOSITORY\"",
    )
    if any(item not in text for item in required):
        errors.append("IconGen watcher execution contract drifted")
    forbidden = (
        "pull_request_target",
        "auto-merge",
        "write-all",
        "contents: write",
        "pull-requests: write",
        "id-token: write",
    )
    if any(item in text for item in forbidden):
        errors.append("IconGen watcher gained a forbidden privilege or action")
    return errors


def validate_runtime_registry_policy(capabilities: dict[str, Any]) -> list[str]:
    errors = []
    if capabilities.get("runtime_registry_policy") != RUNTIME_REGISTRY_POLICY:
        errors.append("CoreSimulator runtime registry policy drifted")
    if "coresimulator_runtime_registry" not in capabilities.get("resource_scopes", []):
        errors.append("CoreSimulator runtime registry resource scope missing")
    if capabilities.get("resource_key_fields", {}).get("coresimulator_runtime_registry") != [
        "host_id",
        "registry_scope",
    ]:
        errors.append("CoreSimulator runtime registry key must be host-scoped")
    return errors


def validate_xcode_mcp_provider_policy(capabilities: dict[str, Any]) -> list[str]:
    if capabilities.get("xcode_mcp_provider_policy") != XCODE_MCP_PROVIDER_POLICY:
        return ["Xcode MCP provider policy drifted"]
    return []


def validate_workflow_semantics(workflow: dict[str, Any], resources: set[str]) -> list[str]:
    nodes, errors = workflow.get("nodes", []), validate_dag(workflow.get("nodes", []))
    ids = [node.get("id") for node in nodes]
    by_id = {node.get("id"): node for node in nodes if isinstance(node.get("id"), str)}
    spine_ids = [node_id for node_id in ids if node_id in CONTROL_SPINE]
    if spine_ids != CONTROL_SPINE:
        errors.append("workflow must preserve the exact approved control-spine node order")
    extension_ids = {node_id for node_id in ids if node_id not in CONTROL_SPINE}
    for node_id in extension_ids:
        node = by_id.get(node_id, {})
        if node.get("extension") is not True:
            errors.append(f"workflow extension node {node_id} must declare extension true")
        if not node.get("resource_key"):
            errors.append(f"workflow extension node {node_id} must declare resource_key")
        if not node.get("resource") or not node.get("lease_action"):
            errors.append(f"workflow extension node {node_id} must be an explicit resource lease action")
    for index, node_id in enumerate(CONTROL_SPINE):
        if node_id not in by_id:
            continue
        requires = by_id[node_id].get("requires", [])
        if index == 0:
            if requires:
                errors.append(f"control-spine dependency drift at {node_id}")
            continue
        previous = CONTROL_SPINE[index - 1]
        if previous not in requires or any(dependency not in extension_ids and dependency != previous for dependency in requires):
            errors.append(f"control-spine dependency drift at {node_id}")
    if [node.get("id") for node in nodes if node.get("terminal")] != ["pr_ready"]:
        errors.append("pr_ready must be the single terminal node")
    for node in nodes:
        resource, action = node.get("resource"), node.get("lease_action")
        if resource is not None and resource not in resources:
            errors.append(f"node {node.get('id')} uses unknown resource {resource}")
        if (resource is None) != (action is None):
            errors.append(f"node {node.get('id')} must pair resource and lease_action")
    for resource, expected in LEASE_PAIRS.items():
        observed = [node_id for node_id in ids if node_id in CONTROL_SPINE and by_id.get(node_id, {}).get("resource") == resource]
        if observed != expected:
            errors.append(f"workflow lease actions drifted for {resource}")
        for acquire, release in zip(expected[::2], expected[1::2]):
            if by_id.get(acquire, {}).get("lease_action") != "acquire" or by_id.get(release, {}).get("lease_action") != "release":
                errors.append(f"workflow must balance acquire/release for {resource}")
    extension_leases: dict[tuple[str, str], dict[str, list[str]]] = {}
    for node in nodes:
        if node.get("id") not in extension_ids:
            continue
        key = (node.get("resource"), node.get("resource_key"))
        action = node.get("lease_action")
        extension_leases.setdefault(key, {"acquire": [], "release": []}).setdefault(action, []).append(node["id"])

    def transitively_depends(node_id: str, required_id: str) -> bool:
        pending = list(by_id.get(node_id, {}).get("requires", []))
        seen: set[str] = set()
        while pending:
            dependency = pending.pop()
            if dependency == required_id:
                return True
            if dependency not in seen:
                seen.add(dependency)
                pending.extend(by_id.get(dependency, {}).get("requires", []))
        return False

    for key, actions in extension_leases.items():
        acquires, releases = actions.get("acquire", []), actions.get("release", [])
        if len(acquires) != 1 or len(releases) != 1:
            errors.append(f"workflow extension lease must have one acquire and one release for {key}")
        elif not transitively_depends(releases[0], acquires[0]):
            errors.append(f"workflow extension release must depend on its acquire for {key}")
    reachable: set[str] = set()
    def reach(node_id: str) -> None:
        if node_id not in reachable:
            reachable.add(node_id)
            for dependency in by_id.get(node_id, {}).get("requires", []):
                reach(dependency)
    if "pr_ready" in by_id:
        reach("pr_ready")
    if set(ids) != reachable:
        errors.append("every success-path node must reach pr_ready")
    policy = workflow.get("attempt_policy", {})
    for key, value in {"max_implementation_attempts": 3, "max_review_cycles": 2, "max_transient_retries": 1, "identical_failure_stop_count": 2, "default_active_wall_minutes": 45}.items():
        if policy.get(key) != value:
            errors.append(f"unexpected attempt bound {key}")
    if policy.get("pause_while_awaiting_human_or_ci") is not True:
        errors.append("workflow must pause active wall time while awaiting human or CI")
    if workflow.get("runtime_edge_types") != [
        "attempt_of",
        "supersedes",
        "produced_by",
        "validates",
        "invalidates",
        "feedback_on",
        "promoted_to",
        "authorized_by",
        "tracks",
        "continues_from",
        "derived_from",
    ]:
        errors.append("workflow runtime edge types drifted")
    if workflow.get("terminal_outcomes") != {"success": "pr_ready", "non_success": ["blocked", "failed_terminal", "cancelled"]}:
        errors.append("workflow terminal outcomes drifted")
    identity = {"algorithm": "patch_identity_v1", "digest": "sha256", "base": "base_sha", "path_order": "utf8_bytewise", "path_record_fields": ["path", "mode", "state", "content_sha256_or_deletion"], "commit_equivalence": "commit_tree_and_changed_paths_match_reviewed_identity"}
    if workflow.get("identity_policy") != identity:
        errors.append("workflow identity policy drifted")
    completion = [
        "required_nodes_passed",
        "required_health_profile_satisfied",
        "run_authorization_current",
        "spec_kit_snapshot_current_or_not_applicable",
        "latest_evidence_matches_patch_identity",
        "no_active_resource_lease",
        "review_patch_identity_current",
        "acceptance_evidence_complete",
        "evidence_published_and_viewable",
        "pull_request_exists",
        "remote_sha_matches_local_commit",
        "required_checks_satisfied",
        "issue_tracking_reconciled_or_recorded_partial",
    ]
    if workflow.get("completion_requires") != completion:
        errors.append("workflow completion requirements drifted")
    expected_cleanup = {
        "mode": "finally",
        "triggers": ["blocked", "failed_terminal", "cancelled", "success_terminal"],
        "release_active_resources": [
            "source_checkout_writer",
            "xcode_project_mutation",
            "build_tuple",
            "simulator_or_device",
            "coresimulator_runtime_registry",
            "signing_or_app_store_connect",
            "github_external_mutation",
        ],
    }
    if workflow.get("cleanup") != expected_cleanup:
        errors.append("workflow finally cleanup contract drifted")
    return errors


def validate_ledger_lifecycle(records: list[dict[str, Any]]) -> list[str]:
    errors, previous, active = [], 0, {}
    main_workflow = load_json(CONTRACTS / "workflow.json")
    continuation_workflow = load_json(CONTRACTS / "testflight-workflow.json")
    node_dependencies = {
        node["id"]: set(node.get("requires", []))
        for node in main_workflow.get("nodes", []) + continuation_workflow.get("nodes", [])
    }
    ledger_run_id: str | None = None
    registry_approvals: dict[str, dict[str, Any]] = {}
    consumed_registry_approvals: set[str] = set()
    run_authorizations: dict[str, dict[str, Any]] = {}
    produced_targets: dict[tuple[str, str], str] = {}
    apple_artifacts: dict[str, tuple[Any, Any, Any, Any]] = {}
    consumed_action_grants: set[tuple[str, str]] = set()
    consumed_idempotency_keys: set[tuple[str, str]] = set()
    reservations: dict[str, dict[str, Any]] = {}
    reserved_action_grants: set[tuple[str, str]] = set()
    reserved_idempotency_keys: set[tuple[str, str]] = set()
    consumed_reservations: set[str] = set()
    time_intervals: dict[str, list[tuple[datetime, datetime]]] = {}
    apple_states: dict[str, set[str]] = {}
    passed_nodes: set[str] = set()
    successful_operations: set[tuple[str, str, str]] = set()
    for line, record in enumerate(records, 1):
        run_id = record.get("run_id")
        if not isinstance(run_id, str) or not run_id:
            errors.append(f"ledger record must bind a run ID (line {line})")
        elif ledger_run_id is None:
            ledger_run_id = run_id
        elif run_id != ledger_run_id:
            errors.append("ledger cannot mix records from different run IDs")
        sequence = record.get("sequence")
        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= previous:
            errors.append(f"ledger sequence must be strictly increasing (line {line})")
        else:
            previous = sequence
        payload = record.get("payload", {})
        if record.get("record_type") == "approval" and payload.get("kind") == "run_authorization":
            if any(
                not payload.get(field)
                for field in (
                    "approval_id",
                    "scope",
                    "authorization_hash",
                    "delivery_target",
                    "issued_at",
                    "expires_at",
                    "action_grants",
                )
            ):
                errors.append("run authorization ledger record must bind ID, hash, target, scope, times, and grants")
            if payload.get("decision") != "approved":
                errors.append("run authorization ledger record must be an approved immutable envelope")
            elif payload.get("authorization_hash"):
                authorization_hash = payload["authorization_hash"]
                if authorization_hash in run_authorizations:
                    errors.append("run authorization hash must identify one immutable approval")
                else:
                    run_authorizations[authorization_hash] = payload
                grants = payload.get("action_grants", [])
                grant_ids = [grant.get("grant_id") for grant in grants]
                keys = [grant.get("idempotency_key") for grant in grants]
                if len(grant_ids) != len(set(grant_ids)) or len(keys) != len(set(keys)):
                    errors.append("run authorization ledger grants and idempotency keys must be unique")
                for grant in grants:
                    action = grant.get("action")
                    system = grant.get("system")
                    if action not in ALLOWED_RUN_ACTIONS or action in FORBIDDEN_RUN_ACTIONS:
                        errors.append("run authorization ledger contains a forbidden or unknown action")
                    if not isinstance(action, str) or system != action.split(".", 1)[0]:
                        errors.append("run authorization ledger grant system must match its action")
                    if not grant.get("operation") or not isinstance(grant.get("operation_input"), dict) or not grant.get("operation_input") or grant.get("phase") not in {"pr_delivery", "testflight_upload", "testflight_distribution"} or not re.fullmatch(
                        r"[0-9a-f]{64}", str(grant.get("constraint_sha256", ""))
                    ) or not grant.get("resource_key"):
                        errors.append("run authorization ledger grant must bind operation, constraint, and canonical resource key")
                    elif canonical_sha256(grant["operation_input"]) != grant.get("constraint_sha256"):
                        errors.append("run authorization ledger grant operation input drifted from its constraint")
                target = payload.get("delivery_target")
                apple_actions = [
                    grant.get("action") for grant in grants if grant.get("system") == "apple"
                ]
                if target == "pr_ready" and apple_actions:
                    errors.append("pr_ready ledger authorization cannot grant Apple actions")
                if target == "testflight_uploaded" and "apple.testflight.distribute_internal" in apple_actions:
                    errors.append("upload-only ledger authorization cannot grant distribution")
                try:
                    issued = datetime.fromisoformat(str(payload.get("issued_at")).replace("Z", "+00:00"))
                    expires = datetime.fromisoformat(str(payload.get("expires_at")).replace("Z", "+00:00"))
                    if issued.tzinfo is None or expires.tzinfo is None or expires <= issued:
                        raise ValueError
                except ValueError:
                    errors.append("run authorization ledger time range is invalid")
        if record.get("record_type") == "time_interval":
            authorization_hash = payload.get("authorization_hash")
            if authorization_hash not in run_authorizations:
                errors.append("time interval must reference a prior run authorization")
            try:
                started = datetime.fromisoformat(str(payload.get("started_at")).replace("Z", "+00:00"))
                ended = datetime.fromisoformat(str(payload.get("ended_at")).replace("Z", "+00:00"))
                if started.tzinfo is None or ended.tzinfo is None or ended <= started:
                    raise ValueError
                intervals = time_intervals.setdefault(authorization_hash, [])
                if any(started < existing_end and existing_start < ended for existing_start, existing_end in intervals):
                    errors.append("authorization time intervals cannot overlap")
                intervals.append((started, ended))
            except ValueError:
                errors.append("authorization time interval is invalid")
        if record.get("record_type") == "approval" and payload.get("kind") == "destructive_action":
            scope = str(payload.get("scope", ""))
            is_registry = payload.get("resource") == "coresimulator_runtime_registry" or scope.startswith(
                "coresimulator_runtime_registry:"
            )
            if is_registry:
                approval_id = payload.get("approval_id")
                fields = ("approval_id", "resource_key", "action", "target")
                if any(not payload.get(field) for field in fields) or payload.get("single_use") is not True:
                    errors.append("CoreSimulator registry approval must bind ID, resource key, action, exact target, and single use")
                expected_scope = (
                    f"coresimulator_runtime_registry:{payload.get('resource_key')}:"
                    f"{payload.get('action')}:{payload.get('target')}"
                )
                if scope != expected_scope:
                    errors.append("CoreSimulator registry approval scope must match its exact structured target")
                previous_approval = registry_approvals.get(approval_id)
                identity_fields = ("resource", "resource_key", "action", "target", "single_use")
                if previous_approval:
                    if any(previous_approval.get(field) != payload.get(field) for field in identity_fields):
                        errors.append("CoreSimulator registry approval ID cannot change target or action")
                    elif approval_id in consumed_registry_approvals:
                        errors.append("consumed CoreSimulator registry approval cannot be changed")
                    elif previous_approval.get("decision") == "approved" and payload.get("decision") == "rejected":
                        registry_approvals[approval_id] = payload
                    else:
                        errors.append("CoreSimulator registry approval ID must be unique; use a new ID")
                elif approval_id:
                    registry_approvals[approval_id] = payload
        if record.get("record_type") == "lease":
            resource_key = (payload.get("resource"), payload.get("resource_key"))
            identity = {key: payload.get(key) for key in ("lease_id", "owner", "resource", "resource_key")}
            action = payload.get("action")
            if action == "acquire":
                if payload.get("resource") == "coresimulator_runtime_registry":
                    if any(key[0] == "simulator_or_device" for key in active):
                        errors.append("CoreSimulator runtime registry lease conflicts with active Simulator/device lease")
                    allowed_actions = payload.get("allowed_actions", [])
                    read_only = allowed_actions == ["read_only_diagnosis"]
                    if not read_only:
                        approval_id = payload.get("approval_id")
                        mutation_target = payload.get("mutation_target")
                        approval = registry_approvals.get(approval_id)
                        exact_action = allowed_actions[0] if len(allowed_actions) == 1 else None
                        matches = bool(
                            approval
                            and approval.get("decision") == "approved"
                            and approval.get("resource") == "coresimulator_runtime_registry"
                            and approval.get("resource_key") == payload.get("resource_key")
                            and approval.get("action") == exact_action
                            and approval.get("target") == mutation_target
                            and approval.get("single_use") is True
                        )
                        if not matches:
                            errors.append("mutating CoreSimulator runtime registry lease requires one exact unrevoked prior approval")
                        elif approval_id in consumed_registry_approvals:
                            errors.append("CoreSimulator runtime registry approval is single-use and already consumed")
                        else:
                            consumed_registry_approvals.add(approval_id)
                elif payload.get("resource") == "simulator_or_device" and any(
                    key[0] == "coresimulator_runtime_registry" for key in active
                ):
                    errors.append("Simulator/device lease conflicts with active CoreSimulator runtime registry lease")
                if resource_key in active:
                    errors.append(f"ledger has two active leases for resource {resource_key}")
                else:
                    active[resource_key] = dict(payload)
            elif action in {"heartbeat", "release"}:
                current = active.get(resource_key)
                if current is None or any(current.get(key) != value for key, value in identity.items()):
                    errors.append(f"ledger {action} must match active lease id, owner, and resource for {resource_key}")
                elif action == "release":
                    del active[resource_key]
                else:
                    try:
                        heartbeat_at = datetime.fromisoformat(str(payload.get("heartbeat_at")).replace("Z", "+00:00"))
                        old_expiry = datetime.fromisoformat(str(current.get("expires_at")).replace("Z", "+00:00"))
                        new_expiry = datetime.fromisoformat(str(payload.get("expires_at")).replace("Z", "+00:00"))
                        if heartbeat_at >= old_expiry or new_expiry <= old_expiry or new_expiry <= heartbeat_at:
                            errors.append("ledger heartbeat must be timely and extend expiry monotonically")
                        else:
                            current["heartbeat_at"] = payload.get("heartbeat_at")
                            current["expires_at"] = payload.get("expires_at")
                    except ValueError:
                        errors.append("ledger heartbeat timestamps are invalid")
        if record.get("record_type") == "grant_reservation":
            authorization_hash = payload.get("authorization_hash")
            authorization = run_authorizations.get(authorization_hash)
            reservation_id = payload.get("reservation_id")
            grant_key = (authorization_hash, payload.get("grant_id"))
            idempotency_key = (authorization_hash, payload.get("idempotency_key"))
            if not reservation_id or reservation_id in reservations:
                errors.append("grant reservation IDs must be non-empty and unique")
            if not isinstance(payload.get("operation_input"), dict) or not payload.get("operation_input"):
                errors.append("grant reservation requires a structured operation input")
            elif canonical_sha256(payload["operation_input"]) != payload.get("constraint_sha256"):
                errors.append("grant reservation operation input does not match its constraint digest")
            if authorization is None:
                errors.append("grant reservation must reference a prior approved authorization")
            else:
                candidates = [
                    grant
                    for grant in authorization.get("action_grants", [])
                    if grant.get("grant_id") == payload.get("grant_id")
                    and grant.get("idempotency_key") == payload.get("idempotency_key")
                    and grant.get("system") == payload.get("system")
                    and grant.get("action") == payload.get("action")
                    and grant.get("operation") == payload.get("operation")
                    and grant.get("operation_input") == payload.get("operation_input")
                    and grant.get("constraint_sha256") == payload.get("constraint_sha256")
                    and grant.get("resource_key") == payload.get("resource_key")
                    and grant.get("phase") == payload.get("phase")
                ]
                if len(candidates) != 1:
                    errors.append("grant reservation does not match one exact approved grant")
                else:
                    grant = candidates[0]
                    expected_target = grant.get("target")
                    source_id = grant.get("target_from_grant_id")
                    if source_id:
                        expected_target = produced_targets.get((authorization_hash, source_id))
                    if not expected_target or payload.get("target") != expected_target:
                        errors.append("grant reservation target drifted or lacks its producer")
                try:
                    reserved_at = datetime.fromisoformat(str(record.get("recorded_at")).replace("Z", "+00:00"))
                    issued = datetime.fromisoformat(str(authorization.get("issued_at")).replace("Z", "+00:00"))
                    expires = datetime.fromisoformat(str(authorization.get("expires_at")).replace("Z", "+00:00"))
                    if reserved_at.tzinfo is None or not issued <= reserved_at < expires:
                        errors.append("grant reservation occurred outside authorization time bounds")
                except ValueError:
                    errors.append("grant reservation timestamp is invalid")
            lease_key = (payload.get("resource"), payload.get("resource_key"))
            lease = active.get(lease_key)
            if (
                lease is None
                or lease.get("lease_id") != payload.get("lease_id")
                or lease.get("owner") != payload.get("lease_owner")
                or payload.get("action") not in lease.get("allowed_actions", [])
            ):
                errors.append("grant reservation requires the exact active action lease")
            else:
                try:
                    reserved_at = datetime.fromisoformat(str(record.get("recorded_at")).replace("Z", "+00:00"))
                    lease_expiry = datetime.fromisoformat(str(lease.get("expires_at")).replace("Z", "+00:00"))
                    if reserved_at >= lease_expiry:
                        errors.append("grant reservation cannot use an expired lease")
                except ValueError:
                    errors.append("grant reservation lease time is invalid")
                authorization = run_authorizations.get(authorization_hash) or {}
                if lease.get("approval_id") != authorization.get("approval_id"):
                    errors.append("grant reservation lease is not bound to the authorization")
            if grant_key in reserved_action_grants or grant_key in consumed_action_grants:
                errors.append("single-use grant was already reserved or consumed")
            else:
                reserved_action_grants.add(grant_key)
            if idempotency_key in reserved_idempotency_keys or idempotency_key in consumed_idempotency_keys:
                errors.append("idempotency key was already reserved or consumed")
            else:
                reserved_idempotency_keys.add(idempotency_key)
            if reservation_id:
                reservations[reservation_id] = payload
        if record.get("record_type") == "external_write":
            authorization_hash = payload.get("authorization_hash")
            grant_key = (authorization_hash, payload.get("grant_id"))
            idempotency_key = (authorization_hash, payload.get("idempotency_key"))
            authorization = run_authorizations.get(authorization_hash)
            if authorization is None:
                errors.append("external write must reference a prior approved run authorization")
            if not isinstance(payload.get("operation_input"), dict) or not payload.get("operation_input"):
                errors.append("external write requires a structured operation input")
            elif canonical_sha256(payload["operation_input"]) != payload.get("constraint_sha256"):
                errors.append("external write operation input does not match its constraint digest")
            reservation_id = payload.get("reservation_id")
            reservation = reservations.get(reservation_id)
            if reservation is None:
                errors.append("external write requires a prior exact grant reservation")
            elif reservation_id in consumed_reservations:
                errors.append("grant reservation was already consumed")
            else:
                for field in (
                    "authorization_hash",
                    "grant_id",
                    "idempotency_key",
                    "system",
                    "action",
                    "operation",
                    "operation_input",
                    "constraint_sha256",
                    "resource_key",
                    "phase",
                    "lease_id",
                    "lease_owner",
                    "resource",
                    "target",
                    "spec_checkpoint_sha256",
                    "apple_observation_sha256",
                ):
                    if reservation.get(field) != payload.get(field):
                        errors.append("external write drifted from its grant reservation")
                        break
                consumed_reservations.add(reservation_id)
            live_lease = active.get((payload.get("resource"), payload.get("resource_key")))
            if (
                live_lease is None
                or live_lease.get("lease_id") != payload.get("lease_id")
                or live_lease.get("owner") != payload.get("lease_owner")
                or payload.get("action") not in live_lease.get("allowed_actions", [])
            ):
                errors.append("external write requires the same active lease used for reservation")
            else:
                try:
                    write_at = datetime.fromisoformat(
                        str(record.get("recorded_at")).replace("Z", "+00:00")
                    )
                    lease_expiry = datetime.fromisoformat(
                        str(live_lease.get("expires_at")).replace("Z", "+00:00")
                    )
                    if write_at.tzinfo is None or write_at >= lease_expiry:
                        errors.append("external write cannot use an expired lease")
                except ValueError:
                    errors.append("external write lease time is invalid")
            action = payload.get("action")
            system = payload.get("system")
            if action not in ALLOWED_RUN_ACTIONS or action in FORBIDDEN_RUN_ACTIONS:
                errors.append("external write action is forbidden or not allowlisted")
            if not isinstance(action, str) or system != action.split(".", 1)[0]:
                errors.append("external write system must match its action")
            if authorization is not None:
                try:
                    recorded_at = datetime.fromisoformat(
                        str(record.get("recorded_at")).replace("Z", "+00:00")
                    )
                    issued = datetime.fromisoformat(
                        str(authorization.get("issued_at")).replace("Z", "+00:00")
                    )
                    expires = datetime.fromisoformat(
                        str(authorization.get("expires_at")).replace("Z", "+00:00")
                    )
                    if recorded_at.tzinfo is None or not issued <= recorded_at < expires:
                        errors.append("external write occurred outside authorization time bounds")
                except ValueError:
                    errors.append("external write or authorization timestamp is invalid")
                candidates = [
                    grant
                    for grant in authorization.get("action_grants", [])
                    if grant.get("grant_id") == payload.get("grant_id")
                    and grant.get("idempotency_key") == payload.get("idempotency_key")
                    and grant.get("system") == system
                    and grant.get("action") == action
                    and grant.get("operation") == payload.get("operation")
                    and grant.get("operation_input") == payload.get("operation_input")
                    and grant.get("constraint_sha256") == payload.get("constraint_sha256")
                    and grant.get("resource_key") == payload.get("resource_key")
                    and grant.get("phase") == payload.get("phase")
                ]
                if len(candidates) != 1:
                    errors.append("external write does not match one exact approved action grant")
                else:
                    grant = candidates[0]
                    expected_target = grant.get("target")
                    source_id = grant.get("target_from_grant_id")
                    if source_id:
                        expected_target = produced_targets.get((authorization_hash, source_id))
                        if expected_target is None:
                            errors.append("external write derived target has no prior successful producer")
                    if payload.get("target") != expected_target:
                        errors.append("external write target drifted from its approved grant")
                    if grant.get("produces_target_kind") and payload.get("outcome") == "succeeded":
                        output_target = payload.get("output_target")
                        if not valid_created_github_target(grant, output_target):
                            errors.append("successful create grant output target has the wrong repository or object kind")
                        else:
                            produced_targets[(authorization_hash, payload.get("grant_id"))] = output_target
                delivery_target = authorization.get("delivery_target")
                if delivery_target == "pr_ready" and system == "apple":
                    errors.append("pr_ready authorization cannot record Apple writes")
                if delivery_target == "testflight_uploaded" and action == "apple.testflight.distribute_internal":
                    errors.append("upload-only authorization cannot record distribution")
            if system == "apple":
                identity = tuple(
                    payload.get(field)
                    for field in ("artifact_sha256", "artifact_source_commit", "version", "build")
                )
                if any(not value for value in identity):
                    errors.append("Apple external writes must record exact artifact, source, version, and build")
                previous_identity = apple_artifacts.get(authorization_hash)
                if previous_identity is not None and identity != previous_identity:
                    errors.append("Apple external write artifact identity drifted within authorization")
                elif all(identity):
                    apple_artifacts[authorization_hash] = identity
                states = apple_states.setdefault(authorization_hash, set())
                target = str(payload.get("target"))
                if action == "apple.testflight.upload" and payload.get("outcome") == "succeeded":
                    states.add("upload_accepted")
                elif action == "apple.testflight.processing.wait" and payload.get("outcome") == "succeeded":
                    if "upload_accepted" not in states:
                        errors.append("processing wait requires a prior accepted upload")
                    states.add("processing_waited")
                elif action == "apple.testflight.readback" and target.endswith(":upload") and payload.get("outcome") == "succeeded":
                    if "processing_waited" not in states or payload.get("external_state") != "completed":
                        errors.append("upload read-back must follow bounded processing and be completed")
                    else:
                        states.add("upload_completed")
                elif action == "apple.testflight.distribute_internal" and payload.get("outcome") == "succeeded":
                    if "upload_completed" not in states:
                        errors.append("internal distribution requires completed upload read-back")
                    states.add(f"distributed:{target}")
                elif action == "apple.testflight.readback" and ":group:" in target and payload.get("outcome") == "succeeded":
                    if f"distributed:{target}" not in states or payload.get("external_state") != "completed":
                        errors.append("distribution read-back must follow distribution and be completed")
                    else:
                        states.add(f"distribution_completed:{target}")
            if grant_key in consumed_action_grants:
                errors.append("external write single-use grant was already consumed")
            else:
                consumed_action_grants.add(grant_key)
            if idempotency_key in consumed_idempotency_keys:
                errors.append("external write idempotency key was already consumed")
            else:
                consumed_idempotency_keys.add(idempotency_key)
            if payload.get("outcome") == "succeeded":
                successful_operations.add(
                    (str(payload.get("phase")), str(action), str(payload.get("operation")))
                )
        if record.get("record_type") == "node" and payload.get("status") == "passed":
            node_id = payload.get("node_id")
            if isinstance(node_id, str):
                if node_id == "bind_pr_ready" and "pr_ready" not in passed_nodes:
                    errors.append("TestFlight continuation cannot bind before pr_ready")
                if node_id in passed_nodes:
                    errors.append(f"workflow node cannot pass more than once: {node_id}")
                missing_dependencies = node_dependencies.get(node_id, set()) - passed_nodes
                if missing_dependencies:
                    errors.append(
                        f"workflow node {node_id} passed before dependencies: "
                        + ", ".join(sorted(missing_dependencies))
                    )
                passed_nodes.add(node_id)
            if node_id in {"pr_ready", "testflight_uploaded", "testflight_distributed"} and active:
                errors.append(f"{node_id} cannot pass with an active resource lease")
            if node_id == "pr_ready":
                missing_nodes = set(CONTROL_SPINE) - passed_nodes
                if missing_nodes:
                    errors.append(
                        "pr_ready requires every control-spine node to pass: "
                        + ", ".join(sorted(missing_nodes))
                    )
                pr_authorizations = [
                    authorization
                    for authorization in run_authorizations.values()
                    if authorization.get("delivery_target") in {
                        "pr_ready", "testflight_uploaded", "testflight_distributed"
                    }
                ]
                if len(pr_authorizations) != 1:
                    errors.append("pr_ready requires one exact run authorization")
                else:
                    required_operations = {
                        (
                            str(grant.get("phase")),
                            str(grant.get("action")),
                            str(grant.get("operation")),
                        )
                        for grant in pr_authorizations[0].get("action_grants", [])
                        if grant.get("phase") == "pr_delivery"
                    }
                    missing_operations = required_operations - successful_operations
                    if missing_operations:
                        errors.append("pr_ready requires every authorized delivery operation to succeed")
            if node_id == "testflight_uploaded" and not any(
                "upload_completed" in states for states in apple_states.values()
            ):
                errors.append("testflight_uploaded requires completed upload read-back")
            if node_id == "testflight_uploaded":
                required = set(TESTFLIGHT_NODE_ORDER[: TESTFLIGHT_NODE_ORDER.index("testflight_uploaded") + 1])
                if required - passed_nodes:
                    errors.append("testflight_uploaded requires every upload-continuation node to pass")
                upload_authorizations = [
                    authorization
                    for authorization in run_authorizations.values()
                    if authorization.get("delivery_target") in {
                        "testflight_uploaded", "testflight_distributed"
                    }
                ]
                if len(upload_authorizations) != 1:
                    errors.append("testflight_uploaded requires one exact continuation authorization")
                else:
                    required_operations = {
                        (
                            str(grant.get("phase")),
                            str(grant.get("action")),
                            str(grant.get("operation")),
                        )
                        for grant in upload_authorizations[0].get("action_grants", [])
                        if grant.get("phase") == "testflight_upload"
                    }
                    if required_operations - successful_operations:
                        errors.append("testflight_uploaded requires every upload-phase operation to succeed")
            if node_id == "testflight_distributed" and not any(
                any(state.startswith("distribution_completed:") for state in states)
                for states in apple_states.values()
            ):
                errors.append("testflight_distributed requires completed distribution read-back")
            if node_id == "testflight_distributed" and set(TESTFLIGHT_NODE_ORDER) - passed_nodes:
                errors.append("testflight_distributed requires every continuation node to pass")
            if node_id == "testflight_distributed":
                distribution_authorizations = [
                    authorization
                    for authorization in run_authorizations.values()
                    if authorization.get("delivery_target") == "testflight_distributed"
                ]
                if len(distribution_authorizations) != 1:
                    errors.append("testflight_distributed requires one exact continuation authorization")
                else:
                    required_operations = {
                        (
                            str(grant.get("phase")),
                            str(grant.get("action")),
                            str(grant.get("operation")),
                        )
                        for grant in distribution_authorizations[0].get("action_grants", [])
                        if grant.get("phase") == "testflight_distribution"
                    }
                    if required_operations - successful_operations:
                        errors.append("testflight_distributed requires every distribution operation to succeed")
        if record.get("record_type") == "stop" and active:
            errors.append("terminal stop cannot leave an active resource lease")
    return errors


def validate_contracts() -> list[str]:
    errors = []
    for path in sorted(CONTRACTS.rglob("*.json")):
        try: load_json(path)
        except (OSError, json.JSONDecodeError) as exc: errors.append(f"invalid JSON {path.relative_to(ROOT)}: {exc}")
    schemas = CONTRACTS / "schemas"
    authorization_template = SKILLS / "agent-harness" / "templates" / "run-authorization.json"
    authorization_fixture = ROOT / "tests" / "fixtures" / "run-authorization-approved.json"
    policy_fixture = ROOT / "tests" / "fixtures" / "private-policy-overlay-approved.json"
    testflight_workflow = CONTRACTS / "testflight-workflow.json"
    health_root = SKILLS / "apple-development-health"
    health_template = health_root / "templates" / "health-observations.json"
    icon_root = SKILLS / "icon-composer"
    companion_manifest = icon_root / "contracts" / "companion-upstream.json"
    delivery_root = SKILLS / "delivery-report"
    for path in sorted((delivery_root / "contracts").glob("*.json")):
        try: load_json(path)
        except (OSError, json.JSONDecodeError) as exc: errors.append(f"invalid JSON {path.relative_to(ROOT)}: {exc}")
    pairs = [
        (CONTRACTS / "capabilities.json", schemas / "capabilities.schema.json"),
        (CONTRACTS / "workflow.json", schemas / "workflow.schema.json"),
        (SKILLS / "agent-harness" / "templates" / "completion-report.json", schemas / "completion-report.schema.json"),
        (testflight_workflow, schemas / "testflight-workflow.schema.json"),
        (authorization_fixture, schemas / "run-authorization.schema.json"),
        (policy_fixture, schemas / "private-policy-overlay.schema.json"),
        (SKILLS / "agent-harness" / "templates" / "harness.json", schemas / "harness.schema.json"),
        (health_template, health_root / "contracts" / "health-report.schema.json"),
        (companion_manifest, icon_root / "contracts" / "companion-upstream.schema.json"),
        (delivery_root / "templates" / "channel-config.json", delivery_root / "contracts" / "channel-config.schema.json"),
    ]
    for contract, schema_path in pairs:
        instance = load_json(contract)
        # $schema is a JSON Schema document-location annotation, not contract data.
        if "$schema" not in load_json(schema_path).get("properties", {}):
            instance = {key: value for key, value in instance.items() if key != "$schema"}
        errors.extend(f"schema violation {contract.relative_to(ROOT)}: {error}" for error in validate_json_schema(instance, load_json(schema_path)))
    capabilities, workflow = load_json(CONTRACTS / "capabilities.json"), load_json(CONTRACTS / "workflow.json")
    errors.extend(validate_runtime_registry_policy(capabilities))
    errors.extend(validate_xcode_mcp_provider_policy(capabilities))
    errors.extend(validate_workflow_semantics(workflow, set(capabilities.get("resource_scopes", []))))
    errors.extend(validate_testflight_workflow(load_json(testflight_workflow)))
    errors.extend(validate_completion_report(load_json(SKILLS / "agent-harness" / "templates" / "completion-report.json")))
    errors.extend(validate_delivery_channel_config(load_json(delivery_root / "templates" / "channel-config.json")))
    errors.extend(validate_run_authorization_contract(load_json(authorization_fixture)))
    pending_authorization = load_json(authorization_template)
    if pending_authorization.get("decision") != "pending":
        errors.append("run authorization template must remain pending until instantiated")
    if pending_authorization.get("action_grants") != []:
        errors.append("run authorization template cannot contain executable action grants")
    if any(
        pending_authorization.get(field) is not None
        for field in ("run_id", "authorization_id", "actor", "issued_at", "expires_at", "repository", "github")
    ):
        errors.append("run authorization template must not contain executable identities or times")
    errors.extend(validate_companion_upstream(load_json(companion_manifest)))
    template = load_json(SKILLS / "agent-harness" / "templates" / "harness.json")
    components = set(template.get("health_components", []))
    if template.get("spec_kit", {}).get("enabled") is True and "spec_kit" not in components:
        errors.append("harness enabled Spec Kit must select the Spec Kit health component")
    if template.get("github_tracking", {}).get("project") is not None and "github_project" not in components:
        errors.append("harness configured Project must select the Project health component")
    for key in ("max_implementation_attempts", "max_review_cycles"):
        if template.get(key) != workflow.get("attempt_policy", {}).get(key):
            errors.append(f"harness template {key} drifted from workflow")
    ledger_path, schema, records = CONTRACTS / "example-ledger.jsonl", load_json(schemas / "ledger-record.schema.json"), []
    for line, text in enumerate(ledger_path.read_text(encoding="utf-8").splitlines(), 1):
        if not text.strip(): continue
        try: record = json.loads(text)
        except json.JSONDecodeError as exc:
            errors.append(f"invalid ledger JSON at line {line}: {exc}"); continue
        if not isinstance(record, dict): errors.append(f"invalid ledger record at line {line}: expected object"); continue
        records.append(record)
        errors.extend(f"schema violation {ledger_path.relative_to(ROOT)} line {line}: {error}" for error in validate_json_schema(record, schema))
    errors.extend(validate_ledger_lifecycle(records))
    return errors


def validate_readme(skill_names: list[str]) -> list[str]:
    text, version, errors = (ROOT / "README.md").read_text(encoding="utf-8"), (ROOT / "VERSION").read_text(encoding="utf-8").strip(), []
    if f"**Version:** {version}" not in text: errors.append("README version must match VERSION")
    errors.extend(f"README inventory missing skill {name}" for name in skill_names if f"skills/{name}/SKILL.md" not in text)
    sections = [line for line in text.splitlines() if line.startswith("## ")]
    if not sections or sections[0] != "## How to Install": errors.append("README first section must be How to Install")
    if len(text.splitlines()) > 200: errors.append("README must stay within 200 lines")
    if text.count("```mermaid") != 1: errors.append("README needs exactly one Mermaid diagram")
    if text.count("```mermaid") > text.count("```") // 2: errors.append("unbalanced README code fences")
    return errors


def validate_safety_contracts() -> list[str]:
    errors = []
    content = "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in sorted(SKILLS.rglob("*.md")))
    for needle, label in {"rm -rf ~/Library/Developer/Xcode/DerivedData/*": "blanket DerivedData deletion", "xcrun simctl erase all": "blanket Simulator erase", "rm -rf ~/Library/Caches/org.swift.swiftpm": "blanket SwiftPM cache deletion", "rm -rf ~/actions-runner/_work/*/": "blanket runner workspace deletion", "sudo rm /Library/Developer/CoreSimulator/Images/images.plist": "manual CoreSimulator registry deletion", "sudo rm -rf /Library/Developer/CoreSimulator/Cryptex": "manual CoreSimulator Cryptex deletion", "simctl runtime delete all": "blanket Simulator runtime deletion", "csrutil disable": "system protection disablement", "killall simdiskimaged": "forced Simulator disk daemon termination"}.items():
        if needle in content: errors.append(f"unsafe guidance remains: {label}")
    git_text = "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in sorted((SKILLS / "git-workflow").rglob("*.md")))
    errors.extend(f"Git sandbox/AD recovery contract missing: {phrase}" for phrase in ["git restore --staged --", "<exact-path-from-status>", "git --no-optional-locks status", "index.lock"] if phrase not in git_text)
    injection = load_json(ROOT / "tests" / "fixtures" / "rag-prompt-injection.json")
    if injection.get("expected", {}).get("tool_calls") != 0: errors.append("RAG injection fixture must expect zero tool calls")
    if injection.get("expected", {}).get("authority") != "immutable_policy": errors.append("RAG injection fixture must keep immutable policy authoritative")
    ci_template = (SKILLS / "cicd" / "workflow-templates.md").read_text(encoding="utf-8")
    for phrase in (
        "runs-on: macos-latest",
        "BUILD_RESULT_BUNDLE: BuildResults.xcresult",
        "TEST_RESULT_BUNDLE: TestResults.xcresult",
    ):
        if phrase not in ci_template:
            errors.append(f"CI safety template missing: {phrase}")
    if re.search(r"uses:\s+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@v\d+", content):
        errors.append("skill workflow example contains a mutable major-version action ref")
    simulator_hang = (SKILLS / "xcodebuild" / "references" / "simulator-hang-recovery.md").read_text(encoding="utf-8")
    for phrase in (
        "without rebuilding",
        "same install/launch phase hangs on both destinations",
        "blocked",
        "no new state for 30 seconds",
        "SpringBoard/Home",
        "app Launch Screen",
        "command-line and GUI provenance",
        "different Xcode installation",
        "absence read-back",
        "new-container read-back",
    ):
        if phrase not in simulator_hang:
            errors.append(f"Simulator hang recovery contract missing: {phrase}")
    runtime_registry = (SKILLS / "xcodebuild" / "references" / "runtime-disk-registry-recovery.md").read_text(encoding="utf-8")
    for phrase in (
        "unable to get a dev_t for store <store-id>",
        "simdiskimaged",
        "Patchable Cryptex Disk Image",
        "coresimulator_runtime_registry",
        "A numeric store identifier is never a deletion target",
        "Do not disable SIP",
        "Xcode Settings > Components",
        "one runtime inventory",
        "single-use approved `destructive_action`",
        "host-wide registry lease is explicitly released before any",
        "select exactly one provider",
        "restart clears",
        "low storage as the sole cause",
        "172343027",
        "three consecutive passes only when",
        "stable-versus-beta comparison",
    ):
        if phrase not in runtime_registry:
            errors.append(f"CoreSimulator runtime registry contract missing: {phrase}")
    provider_preflight = (SKILLS / "xcodebuild" / "references" / "xcode-mcp-provider-preflight.md").read_text(encoding="utf-8")
    for phrase in (
        "Installation, registration, exposure, and connectivity are four separate facts",
        "A `brew tap` only registers a formula source",
        "`npm exec ...@latest`",
        "codex mcp add xcode -- xcrun mcpbridge",
        "`xcrun mcp-server enable` is not Codex registration",
        "`--unsafe-always-allow-all-agents`",
        "`workspaceIdentifier`",
        "Do not start a build or destination inventory merely to prove MCP connectivity",
    ):
        if phrase not in provider_preflight:
            errors.append(f"Xcode MCP provider contract missing: {phrase}")
    concurrent = (SKILLS / "xcodebuild" / "references" / "concurrent-project-resources.md").read_text(encoding="utf-8")
    for phrase in ("exact destination UDID", "ambiguous `booted`", "one active owner per UDID", "coresimulator_runtime_registry"):
        if phrase not in concurrent:
            errors.append(f"concurrent Xcode resource contract missing: {phrase}")
    health = (SKILLS / "apple-development-health" / "references" / "health-matrix.md").read_text(encoding="utf-8")
    for phrase in (
        "Installation, registration, current-task exposure, and read-only connectivity",
        "direct third-party Codex MCP entry",
        "Codex plugin",
        "Xcode Coding Assistant AgentPlugin",
        "30 seconds",
        "Data Migration Failed",
        "partially usable",
        "continuous drag",
        "apple_sample_code_mcp",
        "mcp.apple_sample_code",
        "https://mcp.applesamplecode.com/mcp",
        "get_status",
        "refresh: false",
        "isLatest: null",
    ):
        if phrase not in health:
            errors.append(f"Apple development health contract missing: {phrase}")
    knowledge = (SKILLS / "agent-harness" / "references" / "knowledge-and-rag.md").read_text(encoding="utf-8")
    for phrase in (
        "codex mcp add apple-sample-code --url https://mcp.applesamplecode.com/mcp",
        "claude mcp add --transport http apple-sample-code https://mcp.applesamplecode.com/mcp",
        "search_samples",
        "get_sample",
        "compare_samples",
        "get_status",
        "content/result hash",
        "If the live MCP is unavailable",
        "mirror or double-index",
    ):
        if phrase not in knowledge:
            errors.append(f"AppleSampleCode MCP contract missing: {phrase}")
    ui_automation = (SKILLS / "apple-platform-testing" / "references" / "xctest-and-ui-automation.md").read_text(encoding="utf-8")
    for phrase in (
        "touch-down, held move, and touch-up",
        "XCUIElement.pinch(withScale:velocity:)",
        "active scheme/test plan",
        "not pinch runtime evidence",
        "accessibility tree",
        "stable, unique, nonlocalized `accessibilityIdentifier`",
        "not a substitute for `accessibilityLabel`",
        "a label only to make a test pass",
        "localized label selector is acceptable only when",
    ):
        if phrase not in ui_automation:
            errors.append(f"Apple UI automation contract missing: {phrase}")
    screenshot = (SKILLS / "screenshot" / "SKILL.md").read_text(encoding="utf-8")
    for phrase in (
        "Unless app launch/startup is the acceptance criterion",
        "SpringBoard/Home",
        "/usr/bin/avconvert",
        "--start <seconds> --duration <seconds>",
        "Never overwrite the raw recording",
        "trimmed artifact, not the raw recording",
        "first and last meaningful frames",
    ):
        if phrase not in screenshot:
            errors.append(f"Screenshot/video evidence contract missing: {phrase}")
    testing_evidence = (SKILLS / "apple-platform-testing" / "references" / "test-selection-and-evidence.md").read_text(encoding="utf-8")
    for phrase in (
        "prepared-state-to-outcome",
        "launch/startup acceptance criterion",
        "trimmed acceptance window",
        "trim start/duration/tool",
    ):
        if phrase not in testing_evidence:
            errors.append(f"Apple testing evidence contract missing: {phrase}")
    delivery = (SKILLS / "agent-harness" / "references" / "delivery.md").read_text(encoding="utf-8")
    for phrase in (
        "trimmed video or UI-test recording",
        "shortest trimmed acceptance window",
        "first and last meaningful frames",
        "Phase the review surface",
        "one reviewer question",
        "approved stacked branches",
        "Do not create artificial micro-PRs",
    ):
        if phrase not in delivery:
            errors.append(f"Harness delivery evidence contract missing: {phrase}")
    delivery_report = " ".join("\n".join(
        path.read_text(encoding="utf-8")
        for path in (
            SKILLS / "delivery-report" / "SKILL.md",
            SKILLS / "delivery-report" / "references" / "setup.md",
        )
    ).split())
    for phrase in (
        "Config alone is not authority",
        "`channel_id`, `destination_ref`, `report_sha256`",
        "`media_allowlist`",
        "`idempotency_key`",
        "accepted",
        "delivered/read",
        "24-hour customer service window",
        "iMessage has no public server API",
        "`trimmed_video`, never a raw recording",
        "delivery-authorization.schema.json",
        "preview-only",
    ):
        if phrase not in delivery_report:
            errors.append(f"Delivery report safety contract missing: {phrase}")
    cost_usage = " ".join(
        (SKILLS / "agent-harness" / "references" / "cost-and-usage.md")
        .read_text(encoding="utf-8")
        .split()
    )
    for phrase in (
        "Current examples—not permanent mappings",
        "Escalate only for recorded evidence",
        "provider/client-reported only",
        "cached_input_tokens` is a subset of input",
        "reasoning_tokens` a subset of output",
        "multi-provider total is informational",
        "client_estimate",
    ):
        if phrase not in cost_usage:
            errors.append(f"Cost-aware model and usage contract missing: {phrase}")
    git_workflow = (SKILLS / "git-workflow" / "SKILL.md").read_text(encoding="utf-8")
    for phrase in (
        "ordered phase map",
        "one reviewer question",
        "400 non-generated",
        "12 changed files",
        "use stacked PRs",
        "approval for every",
        "does not grant merge, force-push, or",
    ):
        if phrase not in git_workflow:
            errors.append(f"Git phased PR contract missing: {phrase}")
    pr_delivery = (SKILLS / "git-workflow" / "references" / "pr-delivery.md").read_text(encoding="utf-8")
    for phrase in (
        "Phase N/M: <reviewer outcome>",
        "ordered stack map",
        "predecessor branch",
        "GitHub base/head read-back",
    ):
        if phrase not in pr_delivery:
            errors.append(f"Git stacked PR delivery contract missing: {phrase}")
    figma_parity = (SKILLS / "figma-bridge" / "simulator-parity.md").read_text(encoding="utf-8")
    for phrase in (
        "full-screen coordinates",
        "safe-area-adjusted coordinates",
        "container-local coordinates",
        "outer container",
        "component | Figma geometry | Simulator geometry",
        "same dimensions and coordinate space",
    ):
        if phrase not in figma_parity:
            errors.append(f"Figma Simulator parity contract missing: {phrase}")
    hig = (SKILLS / "apple-platform-ui" / "hig-source-policy.md").read_text(encoding="utf-8")
    for phrase in ("live [Apple Human Interface Guidelines]", "Do not RAG-index", "selected platform and OS generation"):
        if phrase not in hig:
            errors.append(f"Apple HIG source policy missing: {phrase}")
    spec_adapter = (SKILLS / "agent-harness" / "references" / "spec-kit-adapter.md").read_text(encoding="utf-8")
    for phrase in ("v1.0.1", ".specify/feature.json", "append-only", "spec_kit_snapshot.py", "/speckit.taskstoissues"):
        if phrase not in spec_adapter:
            errors.append(f"Spec Kit adapter contract missing: {phrase}")
    authorization = (SKILLS / "agent-harness" / "references" / "run-authorization.md").read_text(encoding="utf-8")
    for phrase in ("testflight_uploaded", "testflight_distributed", "single-use", "App Review", "auto-merge"):
        if phrase not in authorization:
            errors.append(f"run authorization contract missing: {phrase}")
    upstream_workflow = (ROOT / ".github" / "workflows" / "icongen-upstream-watch.yml").read_text(encoding="utf-8")
    for phrase in (
        "contents: read",
        "issues: write",
        "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
        "watch_companion_upstream.py",
    ):
        if phrase not in upstream_workflow:
            errors.append(f"IconGen upstream watcher contract missing: {phrase}")
    errors.extend(validate_icongen_workflow_text(upstream_workflow))
    return errors


def validate_repository() -> list[str]:
    errors, names = validate_skills()
    errors.extend(validate_relative_links()); errors.extend(validate_contracts()); errors.extend(validate_readme(names)); errors.extend(validate_safety_contracts())
    return sorted(set(errors))


def main() -> int:
    errors = validate_repository()
    if errors:
        print("Repository validation failed:"); print(*(f"- {error}" for error in errors), sep="\n"); return 1
    print(f"Repository validation passed ({len(list(SKILLS.glob('*/SKILL.md')))} skills).")
    return 0


if __name__ == "__main__": raise SystemExit(main())
