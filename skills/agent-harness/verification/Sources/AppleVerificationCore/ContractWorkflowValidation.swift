import Foundation

extension ContractValidation {
  public static func validateWorkflowSemantics(_ workflow: [String: Any], resources: Set<String>)
    -> [String]
  {
    let completion = [
      "required_nodes_passed", "required_health_profile_satisfied", "run_authorization_current",
      "spec_kit_snapshot_current_or_not_applicable", "latest_evidence_matches_patch_identity",
      "no_active_resource_lease", "review_patch_identity_current", "acceptance_evidence_complete",
      "evidence_published_and_viewable", "pull_request_exists", "remote_sha_matches_local_commit",
      "required_checks_satisfied", "issue_tracking_reconciled_or_recorded_partial",
    ]
    var errors = validateLinear(
      workflow, ids: controlSpine, terminal: "pr_ready", resources: resources,
      completion: completion)
    var byID = keyed(workflow["nodes"] as? [[String: Any]] ?? [])
    errors += validateLeasePairs(
      [
        ("claim_implementation_writer", "release_implementation_writer", "source_checkout_writer"),
        ("claim_delivery_writer", "release_delivery_writer", "source_checkout_writer"),
        ("claim_github_tracking", "release_github_tracking", "github_external_mutation"),
        ("claim_github_in_progress", "release_github_in_progress", "github_external_mutation"),
        ("claim_github_mutation", "release_github_mutation", "github_external_mutation"),
      ], byID: byID)
    errors += validateCommon(
      workflow, terminal: "pr_ready", cleanupResources: ContractValidation.resources)
    return Array(Set(errors)).sorted()
  }

  public static func validateLocalWorkflow(_ workflow: [String: Any], resources: Set<String>)
    -> [String]
  {
    let completion = [
      "required_nodes_passed", "required_health_profile_satisfied", "run_authorization_current",
      "spec_kit_snapshot_current_or_not_applicable", "latest_evidence_matches_patch_identity",
      "no_active_resource_lease", "review_current_or_not_required_by_accepted_plan",
      "acceptance_evidence_complete",
    ]
    var errors = validateLinear(
      workflow, ids: localSpine, terminal: "local_verified", resources: resources,
      completion: completion)
    errors += validateLeasePairs(
      [("claim_implementation_writer", "release_implementation_writer", "source_checkout_writer")],
      byID: keyed(workflow["nodes"] as? [[String: Any]] ?? []))
    errors += validateCommon(
      workflow, terminal: "local_verified", cleanupResources: ContractValidation.resources)
    return Array(Set(errors)).sorted()
  }

  public static func validateTestFlightWorkflow(_ workflow: [String: Any], resources: Set<String>)
    -> [String]
  {
    guard let nodes = workflow["nodes"] as? [[String: Any]] else {
      return ["TestFlight workflow nodes are invalid"]
    }
    var errors = validateDAG(nodes)
    let byID = keyed(nodes)
    let ids = nodes.compactMap { $0["id"] as? String }
    if ids != testFlightSpine { errors.append("TestFlight continuation node order drifted") }
    for (index, id) in testFlightSpine.enumerated()
    where byID[id]?["requires"] as? [String] != (index == 0 ? [] : [testFlightSpine[index - 1]]) {
      errors.append("TestFlight continuation dependency edges drifted at \(id)")
    }
    for node in nodes {
      if let resource = node["resource"] as? String, !resources.contains(resource) {
        errors.append(
          "TestFlight node \(node["id"] as? String ?? "?") uses unknown resource \(resource)")
      }
      let resource = node["resource"] as? String
      let action = node["lease_action"] as? String
      if (resource == nil) != (action == nil) {
        errors.append("TestFlight node must pair resource and lease action")
      }
    }
    let wait = byID["wait_processing"] ?? [:]
    let waitPolicy: [String: Any] = [
      "timeout_from_authorization": wait["timeout_from_authorization"] ?? NSNull(),
      "retry_bound_from_authorization": wait["retry_bound_from_authorization"] ?? NSNull(),
      "heartbeat_active_lease": wait["heartbeat_active_lease"] ?? NSNull(),
    ]
    if !equal(
      waitPolicy,
      [
        "timeout_from_authorization": "async_wait_minutes",
        "retry_bound_from_authorization": "max_transient_retries", "heartbeat_active_lease": true,
      ])
    {
      errors.append("TestFlight processing wait must use authorization bounds and lease heartbeat")
    }
    let terminals = Dictionary(
      uniqueKeysWithValues: nodes.compactMap { node -> (String, String)? in
        guard let terminal = node["terminal_for"] as? String, let id = node["id"] as? String else {
          return nil
        }
        return (terminal, id)
      })
    if terminals != [
      "testflight_uploaded": "testflight_uploaded",
      "testflight_distributed": "testflight_distributed",
    ] {
      errors.append("TestFlight continuation terminals drifted")
    }
    if nodes.compactMap({ $0["grant_action"] as? String }) != [
      "apple.testflight.upload", "apple.testflight.processing.wait", "apple.testflight.readback",
      "github.evidence.publish", "apple.testflight.distribute_internal",
      "apple.testflight.readback", "github.evidence.publish",
    ] {
      errors.append("TestFlight action-grant sequence drifted")
    }
    errors += validateLeasePairs(
      [
        ("claim_archive_build", "release_archive_build", "build_tuple"),
        ("claim_testflight_upload", "release_testflight_upload", "signing_or_app_store_connect"),
        (
          "claim_upload_evidence_publication", "release_upload_evidence_publication",
          "github_external_mutation"
        ),
        (
          "claim_testflight_distribution", "release_testflight_distribution",
          "signing_or_app_store_connect"
        ),
        (
          "claim_distribution_evidence_publication", "release_distribution_evidence_publication",
          "github_external_mutation"
        ),
      ], byID: byID)
    if workflow["starts_after"] as? String != "pr_ready" {
      errors.append("TestFlight continuation must start after pr_ready")
    }
    let targets: [String: Any] = [
      "testflight_uploaded": [
        "terminal_node": "testflight_uploaded",
        "required_grants": [
          "apple.testflight.upload", "apple.testflight.processing.wait",
          "apple.testflight.readback", "github.evidence.publish",
        ],
      ],
      "testflight_distributed": [
        "terminal_node": "testflight_distributed",
        "required_grants": [
          "apple.testflight.upload", "apple.testflight.processing.wait",
          "apple.testflight.readback", "github.evidence.publish",
          "apple.testflight.distribute_internal", "apple.testflight.readback",
          "github.evidence.publish",
        ],
      ],
    ]
    if !equal(workflow["delivery_targets"], targets) {
      errors.append("TestFlight delivery target transition contract drifted")
    }
    let policy: [String: Any] = [
      "processing_wait_is_bounded": true, "distribution_is_internal_groups_only": true,
      "read_back_required": true, "evidence_publication_requires_github_lease": true,
      "release_every_acquired_lease_on_blocked_or_terminal": true,
      "forbidden_actions": [
        "apple.app_review_submit", "apple.production_release", "apple.signing_resource_mutation",
        "credential.scope_expansion", "github.auto_merge",
      ],
    ]
    if !equal(workflow["policy"], policy) {
      errors.append("TestFlight continuation policy drifted")
    }
    if !equal(
      workflow["cleanup"],
      cleanup(["build_tuple", "signing_or_app_store_connect", "github_external_mutation"]))
    {
      errors.append("TestFlight continuation finally cleanup contract drifted")
    }
    return Array(Set(errors)).sorted()
  }

  static func validateLinear(
    _ workflow: [String: Any], ids expected: [String], terminal: String, resources: Set<String>,
    completion: [String]
  ) -> [String] {
    guard let nodes = workflow["nodes"] as? [[String: Any]] else {
      return ["workflow nodes are invalid"]
    }
    var errors = validateDAG(nodes)
    let byID = keyed(nodes)
    let ids = nodes.compactMap { $0["id"] as? String }
    if ids != expected { errors.append("workflow control-spine node order drifted") }
    for (index, id) in expected.enumerated()
    where byID[id]?["requires"] as? [String] != (index == 0 ? [] : [expected[index - 1]]) {
      errors.append("control-spine dependency drift at \(id)")
    }
    if nodes.filter({ $0["terminal"] as? Bool == true }).compactMap({ $0["id"] as? String }) != [
      terminal
    ] {
      errors.append("\(terminal) must be the single terminal node")
    }
    for node in nodes {
      let resource = node["resource"] as? String
      let action = node["lease_action"] as? String
      if let resource, !resources.contains(resource) {
        errors.append("node \(node["id"] as? String ?? "?") uses unknown resource \(resource)")
      }
      if (resource == nil) != (action == nil)
        || (action != nil && !["acquire", "release"].contains(action!))
      {
        errors.append(
          "node \(node["id"] as? String ?? "?") must pair resource with valid lease_action")
      }
    }
    if workflow["completion_requires"] as? [String] != completion {
      errors.append("workflow completion requirements drifted")
    }
    if dependencies(of: terminal, byID: byID).union([terminal]) != Set(ids) {
      errors.append("every success-path node must reach \(terminal)")
    }
    return errors
  }

  static func validateLeasePairs(_ pairs: [(String, String, String)], byID: [String: [String: Any]])
    -> [String]
  {
    var errors: [String] = []
    var used = Set<String>()
    for (acquireID, releaseID, resource) in pairs {
      let acquire = byID[acquireID] ?? [:]
      let release = byID[releaseID] ?? [:]
      let protects = acquire["protects"] as? [String] ?? []
      if acquire["resource"] as? String != resource
        || acquire["lease_action"] as? String != "acquire"
        || release["resource"] as? String != resource
        || release["lease_action"] as? String != "release"
      {
        errors.append(
          "workflow must balance acquire/release for \(resource): \(acquireID)/\(releaseID)")
      }
      if protects.isEmpty || release["protects"] as? [String] != protects
        || Set(protects).count != protects.count
      {
        errors.append(
          "workflow pair must declare identical unique protected nodes for \(resource): \(acquireID)/\(releaseID)"
        )
      }
      for protected in protects {
        if byID[protected] == nil {
          errors.append("workflow protected node is unknown: \(protected)")
        } else if !dependencies(of: protected, byID: byID).contains(acquireID) {
          errors.append("workflow protected node \(protected) must depend on \(acquireID)")
        }
        if !dependencies(of: releaseID, byID: byID).contains(protected) {
          errors.append("workflow release \(releaseID) must follow protected node \(protected)")
        }
      }
      used.insert(acquireID)
      used.insert(releaseID)
    }
    let leaseNodes = Set(byID.compactMap { $0.value["lease_action"] == nil ? nil : $0.key })
    let unpaired = leaseNodes.subtracting(used)
    if !unpaired.isEmpty {
      errors.append("workflow contains unpaired lease nodes: \(unpaired.sorted())")
    }
    return errors
  }

  static func validateCommon(
    _ workflow: [String: Any], terminal: String, cleanupResources: [String]
  ) -> [String] {
    var errors: [String] = []
    if !equal(workflow["attempt_policy"], attemptPolicy) {
      errors.append("workflow attempt and pause policy drifted")
    }
    if workflow["runtime_edge_types"] as? [String] != edgeTypes {
      errors.append("workflow runtime edge types drifted")
    }
    if !equal(
      workflow["terminal_outcomes"],
      ["success": terminal, "non_success": ["blocked", "failed_terminal", "cancelled"]])
    {
      errors.append("workflow terminal outcomes drifted")
    }
    if !equal(workflow["identity_policy"], identityPolicy) {
      errors.append("workflow identity policy drifted")
    }
    if !equal(workflow["cleanup"], cleanup(cleanupResources)) {
      errors.append("workflow finally cleanup contract drifted")
    }
    return errors
  }
}
