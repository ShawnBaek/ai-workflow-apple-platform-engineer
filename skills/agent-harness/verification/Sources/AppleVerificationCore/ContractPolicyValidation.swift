import Foundation

extension ContractValidation {
  // Canonical hashes bind every nested field of the four high-risk capability policies.
  static let runtimePolicySHA = "41a5e98efbafcccb388c9e53ffd469f495432ccd532979050f74c44be05a1b5b"
  static let xcodePolicySHA = "e2e4c0787219c2cf2ba67e84bba2c1b057b32eb90dbfa78687cb2509f47f2db9"
  static let overlapPolicySHA = "62de7d812e5e0d24e7298f63dc6b74b2a908abdb6fab2d39dd5d70a07d8889cd"
  static let coordinationPolicySHA =
    "5fb7367c942c7853cf557144afefbf7d69ff425512e58703a94135ee718cf4cb"

  public static func validateCapabilities(_ capabilities: [String: Any]) -> [String] {
    var errors: [String] = []
    if capabilities["resource_scopes"] as? [String] != resources {
      errors.append("capability resource scopes drifted")
    }
    let exactSections: [String: Any] = [
      "authority_order": [
        "system_and_current_user", "hard_account_and_repository_guards",
        "accepted_spec_and_decisions", "repository_defaults",
      ],
      "execution_order": [
        "xcode_official_tools", "apple_supported_external_agent_bridge", "host_apple_cli",
        "explicit_third_party_fallback",
      ],
      "platforms": ["ios", "ipados", "watchos", "macos"],
      "companion_upstream_policy": [
        "auto_merge": false, "drift_action": "create_or_update_review_issue",
        "execute_or_vendor": false, "mode": "reference-only", "public_metadata_read_only": true,
      ],
      "feedback_policy": [
        "current_run_feedback_is_authoritative": true,
        "durable_promotion_requires": "explicit_human_approval_or_repeated_evidence",
        "local_llm_role": "cluster_and_propose_only", "record_in_ledger": true,
        "rollback_required": true, "silent_durable_policy_mutation": false,
      ],
      "health_policy": [
        "account_or_scope_expansion": false, "read_only_observation": true,
        "repair_or_install": false, "required_profile_before_writes": true,
        "separate_app_and_infrastructure_results": true,
        "statuses": ["healthy", "degraded", "blocked", "not_applicable"],
      ],
      "knowledge_orders": [
        "apple_api_truth": [
          "live_apple_documentation_for_selected_toolchain", "one_apple_authored_skill_exposure",
          "commit_pinned_apple_sample", "ios_experts", "external_retrieved_material",
        ],
        "product_truth": [
          "accepted_spec_and_decisions", "repository_source_at_frozen_head",
          "commit_pinned_dependency_source", "approved_project_analysis",
        ],
      ],
      "local_llm": [
        "allowed_roles": ["retrieve", "rerank", "extract_entities", "cluster_logs"],
        "forbidden_roles": ["writer", "approver", "reviewer_of_record"],
      ],
      "spec_kit_policy": [
        "artifact_hash_binding": true, "feature_directory_and_git_branch_mapping_is_explicit": true,
        "managed_workflow_definitions_change_via_supported_overlays_only": true,
        "pinned_release": "v1.0.1", "workflow_checkpoint_separate_from_authorization_hash": true,
        "workflow_logs_are_subordinate_to_harness_ledger": true,
      ],
      "modes": [
        "claude": ["max_active_writers": 1, "writer_candidates": ["claude"]],
        "codex": ["max_active_writers": 1, "writer_candidates": ["codex"]],
        "collaborative": [
          "max_active_writers": 1, "review_requires_immutable_patch": true,
          "transfer_policy": [
            "fresh_capability_snapshot_required": true, "matching_state_hash_required": true,
            "release_before_acquire": true, "revoke_previous_writer_capabilities": true,
          ], "writer_candidates": ["codex", "claude"],
          "writer_selection": [
            "authority": "explicit_user_or_accepted_plan", "required_before_claim": true,
            "reviewer_must_differ": true,
          ],
        ],
      ],
    ]
    for (field, expected) in exactSections where !equal(capabilities[field], expected) {
      errors.append("capability \(field) policy drifted")
    }
    let expected: [String: [String]] = [
      "source_checkout_writer": ["identity_version", "repository_fingerprint"],
      "xcode_project_mutation": ["repository_fingerprint", "container_path"],
      "simulator_or_device": ["coordinator_instance_id", "udids"],
      "coresimulator_runtime_registry": ["coordinator_instance_id", "registry_scope"],
      "macos_gui_session": ["coordinator_instance_id", "session_scope"],
      "signing_or_app_store_connect": ["account_guard", "app_or_bundle_scope"],
      "github_external_mutation": ["repository_fingerprint", "remote_repository"],
      "build_tuple": [
        "repository_fingerprint", "container_path", "xcode_build", "sdk", "scheme", "configuration",
        "architecture", "package_fingerprint", "cache_paths", "cache_roles", "output_paths",
        "output_roles", "package_resolution_mode",
      ],
    ]
    if !equal(capabilities["resource_key_fields"], expected) {
      errors.append("capability resource key fields drifted")
    }
    for (field, digest, label) in [
      ("runtime_registry_policy", runtimePolicySHA, "CoreSimulator runtime registry"),
      ("xcode_mcp_provider_policy", xcodePolicySHA, "Xcode MCP provider"),
      ("resource_overlap_policy", overlapPolicySHA, "resource overlap"),
      ("cross_run_coordination_policy", coordinationPolicySHA, "cross-run coordination"),
    ] where hash(capabilities[field]) != digest { errors.append("\(label) policy drifted") }
    let profiles: [String: Any] = [
      "local_verified": ["continuation": "local-workflow.json", "terminal": "local_verified"],
      "pr_ready": ["continuation": NSNull(), "terminal": "pr_ready"],
      "testflight_uploaded": [
        "continuation": "testflight-workflow.json", "terminal": "testflight_uploaded",
      ],
      "testflight_distributed": [
        "continuation": "testflight-workflow.json", "terminal": "testflight_distributed",
      ],
    ]
    if !equal(capabilities["delivery_profiles"], profiles) {
      errors.append("delivery profile workflow bindings drifted")
    }
    return Array(Set(errors)).sorted()
  }

  public static func validatePendingAuthorization(_ pending: [String: Any]) -> [String] {
    var errors: [String] = []
    if pending["schema_version"] as? String != "1.0.0" {
      errors.append("run authorization template schema version drifted")
    }
    if pending["decision"] as? String != "pending" {
      errors.append("run authorization template must remain pending until instantiated")
    }
    for field in ["action_grants", "allowed_paths", "resource_plan", "acceptance_ids"]
    where !((pending[field] as? [Any])?.isEmpty == true) {
      errors.append("run authorization template \(field) must remain empty")
    }
    for field in [
      "run_id", "authorization_id", "actor", "selected_writer", "issued_at", "expires_at",
      "repository", "github", "apple", "health_attestation", "contract_schema_id",
      "contract_schema_sha256", "spec_kit", "local_requirements",
    ] where present(pending[field]) {
      errors.append(
        "run authorization template must not contain executable identity, authority, or time: \(field)"
      )
    }
    if pending["delivery_target"] as? String != "pr_ready"
      || pending["health_profile"] as? String != "pr_ready"
    {
      errors.append("run authorization template must retain the inert pr_ready profile")
    }
    let limits: [String: Any] = [
      "active_wall_minutes": 45, "async_wait_minutes": 45, "max_implementation_attempts": 3,
      "max_review_cycles": 2, "max_transient_retries": 1,
    ]
    if !equal(pending["limits"], limits) {
      errors.append("run authorization pending limits drifted")
    }
    if pending["forbidden_actions"] as? [String] != forbiddenActions {
      errors.append("run authorization pending forbidden action boundary drifted")
    }
    for field in [
      "auto_merge", "app_review_submit", "credential_scope_expansion", "signing_resource_mutation",
      "destructive_cleanup",
    ] where pending[field] as? Bool != false {
      errors.append("run authorization pending \(field) must remain false")
    }
    return Array(Set(errors)).sorted()
  }

  public static func validateApprovedAuthorization(
    _ authorization: [String: Any], schemaURL: URL, context: RuntimeContext
  ) -> [String] {
    var errors = Authorization.validateAuthorization(authorization, context: context)
    if let schema = try? HarnessRuntime.object(schemaURL),
      authorization["contract_schema_id"] as? String != schema["$id"] as? String
    {
      errors.append("approved authorization schema ID drifted")
    }
    if let digest = try? HarnessRuntime.sha256File(schemaURL),
      authorization["contract_schema_sha256"] as? String != "sha256:" + digest
    {
      errors.append("approved authorization schema content binding drifted")
    }
    return Array(Set(errors)).sorted()
  }

  public static func validateHarnessTemplate(_ template: [String: Any], workflow: [String: Any])
    -> [String]
  {
    var errors: [String] = []
    if integer(template["max_active_repository_writers"]) != 1 {
      errors.append("harness must allow exactly one active repository writer")
    }
    let policy = workflow["attempt_policy"] as? [String: Any] ?? [:]
    for key in ["max_implementation_attempts", "max_review_cycles"]
    where !equal(template[key], policy[key]) {
      errors.append("harness template \(key) drifted from workflow")
    }
    let components = Set(template["health_components"] as? [String] ?? [])
    let spec = template["spec_kit"] as? [String: Any]
    if spec?["enabled"] as? Bool == true && !components.contains("spec_kit") {
      errors.append("harness enabled Spec Kit must select the Spec Kit health component")
    }
    if let project = (template["github_tracking"] as? [String: Any])?["project"], present(project),
      !components.contains("github_project")
    {
      errors.append("harness configured Project must select the Project health component")
    }
    guard let runtime = template["authorization_runtime"] as? [String: Any] else {
      return errors + ["harness must bind the Swift authorization runtime"]
    }
    errors += validateSwiftRuntimeBinding(
      runtime, contract: Authorization.runtimeContract, requireExecutablePath: true)
    if template["delivery_target"] as? String == "local_verified" {
      guard let requirements = template["local_requirements"] as? [String: Any],
        Set(requirements.keys) == ["review_required", "spec_kit_required"],
        requirements.values.allSatisfy({ $0 is Bool })
      else {
        errors.append("local harness must bind exact local requirements")
        return errors
      }
    } else if present(template["local_requirements"]) {
      errors.append("non-local harness cannot bind local requirements")
    }
    return errors
  }

  public static func validateSwiftRuntimeBinding(
    _ binding: [String: Any], contract: String, requireExecutablePath: Bool = false
  ) -> [String] {
    var exact: Set<String> = [
      "runtime_kind", "runtime_contract", "executable_sha256", "source_bundle_sha256",
    ]
    if requireExecutablePath { exact.insert("executable_path") }
    guard Set(binding.keys) == exact else {
      return ["runtime binding fields are invalid or legacy"]
    }
    guard binding["runtime_kind"] as? String == "swift",
      binding["runtime_contract"] as? String == contract
    else { return ["runtime binding must name the installed Swift contract"] }
    if requireExecutablePath && !(binding["executable_path"] as? String ?? "").hasPrefix("/") {
      return ["runtime binding executable path must be absolute"]
    }
    for key in ["executable_sha256", "source_bundle_sha256"]
    where !matches(binding[key], #"^sha256:[0-9a-f]{64}$"#) {
      return ["runtime binding \(key) is invalid"]
    }
    return []
  }

  public static func validateCompanionUpstream(_ manifest: [String: Any]) -> [String] {
    var errors: [String] = []
    let upstream = manifest["upstream"] as? [String: Any] ?? [:]
    let integration = manifest["integration"] as? [String: Any] ?? [:]
    let license = manifest["license"] as? [String: Any] ?? [:]
    if upstream["repository"] as? String != "ShawnBaek/IconGen"
      || upstream["visibility"] as? String != "public"
      || upstream["default_branch"] as? String != "main"
    {
      errors.append("IconGen companion upstream identity, visibility, or branch drifted")
    }
    for field in ["reviewed_revision", "reviewed_tree"]
    where !matches(upstream[field], #"^[0-9a-f]{40}$"#) {
      errors.append("IconGen companion \(field) must be a full Git object identity")
    }
    if (try? HarnessRuntime.parseTimestamp(upstream["observed_at"] as? String ?? "")) == nil {
      errors.append("IconGen companion observation timestamp is invalid")
    }
    let expected: [String: Any] = [
      "mode": "reference-only", "execute_upstream": false, "vendored_files": [],
      "consumer_skill": "icon-composer", "consumer_repository": "ShawnBaek/iOS-experts",
      "drift_action": "create_or_update_review_issue", "auto_merge": false,
    ]
    if !equal(integration, expected) {
      errors.append("IconGen companion upstream safety boundary drifted")
    }
    if license["status"] as? String == "absent"
      && !((integration["vendored_files"] as? [Any])?.isEmpty ?? false)
    {
      errors.append("unlicensed companion upstream cannot have vendored files")
    }
    let sources = manifest["sources"] as? [[String: Any]] ?? []
    let paths = sources.compactMap { $0["path"] as? String }
    if sources.isEmpty || paths.count != sources.count || Set(paths).count != paths.count
      || sources.contains(where: {
        Set($0.keys) != ["path", "blob_sha", "purpose"]
          || !matches($0["blob_sha"], #"^[0-9a-f]{40}$"#)
          || ($0["purpose"] as? String)?.isEmpty != false
          || !safeRelative($0["path"] as? String ?? "")
      })
    {
      errors.append("IconGen reviewed source provenance is incomplete or unsafe")
    }
    return Array(Set(errors)).sorted()
  }

  static func validateIconGenWorkflow(at path: URL) -> [String] {
    guard let text = try? String(contentsOf: path, encoding: .utf8) else {
      return ["IconGen watcher workflow is unavailable"]
    }
    var errors: [String] = []
    guard let trigger = capture(text, #"(?ms)^on:\n(?<body>.*?)^permissions:\n"#, name: "body")
    else { return ["IconGen watcher trigger block is missing"] }
    if captures(trigger, #"(?m)^  ([A-Za-z_][A-Za-z0-9_-]*):?\s*$"#) != [
      "schedule", "workflow_dispatch",
    ] {
      errors.append("IconGen watcher triggers must be exactly schedule and workflow_dispatch")
    }
    let permissions =
      capture(text, #"(?ms)^permissions:\n(?<body>.*?)^concurrency:\n"#, name: "body")?.split(
        separator: "\n"
      ).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    if permissions != ["contents: read", "issues: write"] {
      errors.append("IconGen watcher permissions must remain contents read and issues write only")
    }
    if captures(text, #"(?m)^\s*uses:\s*(\S+)"#) != [
      "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
    ] {
      errors.append("IconGen watcher may use only the pinned checkout action")
    }
    guard let jobs = capture(text, #"(?ms)^jobs:\n(?<body>.*)\z"#, name: "body") else {
      return errors + ["IconGen watcher jobs block is missing"]
    }
    if captures(jobs, #"(?m)^  ([A-Za-z_][A-Za-z0-9_-]*):\s*$"#) != ["compare"] {
      errors.append("IconGen watcher must contain exactly one compare job")
    }
    for required in [
      "runs-on: macos-15", "timeout-minutes: 15", "apple-verify companion",
      "--target-repository \"$GITHUB_REPOSITORY\"",
    ] where !text.contains(required) { errors.append("IconGen watcher execution contract drifted") }
    for forbidden in [
      "pull_request_target", "auto-merge", "write-all", "contents: write", "pull-requests: write",
      "id-token: write",
    ] where text.contains(forbidden) {
      errors.append("IconGen watcher gained a forbidden privilege or action: \(forbidden)")
    }
    return Array(Set(errors)).sorted()
  }
  static func capture(_ text: String, _ pattern: String, name: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(withName: name), in: text)
    else { return nil }
    return String(text[range])
  }
  static func captures(_ text: String, _ pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      match in
      guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else {
        return nil
      }
      return String(text[range])
    }
  }
}
