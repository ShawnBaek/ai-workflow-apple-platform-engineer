#!/usr/bin/env python3
"""Dependency-free structural validation for the iOS-experts skill repository."""
from __future__ import annotations

from datetime import datetime
import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills"
CONTRACTS = SKILLS / "agent-harness" / "contracts"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


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
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        if schema.get("additionalProperties") is False:
            errors.extend(f"{path}: additional property {key!r} is forbidden" for key in instance if key not in properties)
        for key, child in properties.items():
            if key in instance and isinstance(child, dict):
                errors.extend(validate_json_schema(instance[key], child, f"{path}.{key}"))
    for child in schema.get("allOf", []):
        errors.extend(validate_json_schema(instance, child, path))
    if "oneOf" in schema:
        matches = sum(not validate_json_schema(instance, child, path) for child in schema["oneOf"])
        if matches != 1:
            errors.append(f"{path}: must match exactly one oneOf branch (matched {matches})")
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


CONTROL_SPINE = ["intake", "guard", "discover", "plan", "approve_plan", "branch_approval", "claim_implementation_writer", "implement", "release_implementation_writer", "verify", "freeze_review", "review", "converge", "reverify", "prepare_evidence", "prepare_pr", "repository_confirmation", "claim_delivery_writer", "commit", "release_delivery_writer", "claim_github_mutation", "push", "verify_remote_sha", "create_pr", "publish_evidence", "verify_published_evidence", "release_github_mutation", "checks", "pr_ready"]
LEASE_PAIRS = {"source_checkout_writer": ["claim_implementation_writer", "release_implementation_writer", "claim_delivery_writer", "release_delivery_writer"], "github_external_mutation": ["claim_github_mutation", "release_github_mutation"]}
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
    ],
    "record_install_provenance": [
        "config_scope",
        "configured_command_and_args",
        "resolved_executable",
        "package_manager_owner",
        "resolved_version",
    ],
    "same_codex_host_clients_share_configuration": True,
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
    if workflow.get("runtime_edge_types") != ["attempt_of", "supersedes", "produced_by", "validates", "invalidates", "feedback_on", "promoted_to"]:
        errors.append("workflow runtime edge types drifted")
    if workflow.get("terminal_outcomes") != {"success": "pr_ready", "non_success": ["blocked", "failed_terminal", "cancelled"]}:
        errors.append("workflow terminal outcomes drifted")
    identity = {"algorithm": "patch_identity_v1", "digest": "sha256", "base": "base_sha", "path_order": "utf8_bytewise", "path_record_fields": ["path", "mode", "state", "content_sha256_or_deletion"], "commit_equivalence": "commit_tree_and_changed_paths_match_reviewed_identity"}
    if workflow.get("identity_policy") != identity:
        errors.append("workflow identity policy drifted")
    completion = ["required_nodes_passed", "latest_evidence_matches_patch_identity", "no_active_resource_lease", "review_patch_identity_current", "acceptance_evidence_complete", "evidence_published_and_viewable", "pull_request_exists", "remote_sha_matches_local_commit", "required_checks_satisfied"]
    if workflow.get("completion_requires") != completion:
        errors.append("workflow completion requirements drifted")
    return errors


def validate_ledger_lifecycle(records: list[dict[str, Any]]) -> list[str]:
    errors, previous, active = [], 0, {}
    registry_approvals: dict[str, dict[str, Any]] = {}
    consumed_registry_approvals: set[str] = set()
    for line, record in enumerate(records, 1):
        sequence = record.get("sequence")
        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= previous:
            errors.append(f"ledger sequence must be strictly increasing (line {line})")
        else:
            previous = sequence
        payload = record.get("payload", {})
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
                    active[resource_key] = identity
            elif action in {"heartbeat", "release"}:
                if active.get(resource_key) != identity:
                    errors.append(f"ledger {action} must match active lease id, owner, and resource for {resource_key}")
                elif action == "release":
                    del active[resource_key]
        if record.get("record_type") == "node" and payload.get("node_id") == "pr_ready" and payload.get("status") == "passed" and active:
            errors.append("pr_ready cannot pass with an active resource lease")
    return errors


def validate_contracts() -> list[str]:
    errors = []
    for path in sorted(CONTRACTS.rglob("*.json")):
        try: load_json(path)
        except (OSError, json.JSONDecodeError) as exc: errors.append(f"invalid JSON {path.relative_to(ROOT)}: {exc}")
    schemas = CONTRACTS / "schemas"
    pairs = [(CONTRACTS / "capabilities.json", schemas / "capabilities.schema.json"), (CONTRACTS / "workflow.json", schemas / "workflow.schema.json"), (SKILLS / "agent-harness" / "templates" / "harness.json", schemas / "harness.schema.json")]
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
    template = load_json(SKILLS / "agent-harness" / "templates" / "harness.json")
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
    if text.count("```mermaid") < 2: errors.append("README needs at least two Mermaid diagrams")
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
    for phrase in ("without rebuilding", "same install/launch phase hangs on both destinations", "blocked"):
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
