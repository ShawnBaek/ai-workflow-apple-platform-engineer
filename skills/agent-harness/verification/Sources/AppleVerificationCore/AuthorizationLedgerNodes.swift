import Foundation

extension Authorization {
  /// Replays one `evidence` record; passed evidence becomes available to later node gates.
  static func recordEvidence(
    _ payload: [String: Any], recorded: Date?, into state: inout LedgerReplayState
  ) {
    let id = text(payload["evidence_id"])
    if id.isEmpty || !state.evidenceIDs.insert(id).inserted {
      state.errors.append("evidence IDs must be unique and non-empty")
    }
    do {
      if try patchIdentityV1(payload["patch_manifest"] as Any) != payload["patch_identity"]
        as? String
      {
        state.errors.append("evidence patch identity drifted from its manifest")
      }
    } catch { state.errors.append("evidence must bind one valid patch_identity_v1 manifest") }
    if payload["outcome"] as? String == "passed" {
      let kind = payload["evidence_kind"] as? String ?? ""
      if ![
        "acceptance", "review", "commit_equivalence", "spec_kit_checkpoint",
        "testflight_artifact", "publication", "checks_readback",
      ].contains(kind) {
        state.errors.append("passed evidence kind is unsupported")
      } else {
        state.passingEvidence.append(payload)
      }
      state.errors += evidenceTupleErrors(payload, recordedAt: recorded)
    }
  }

  /// Replays one passed `node` record through its workflow, evidence, lease and terminal gates.
  static func recordPassedNode(
    _ payload: [String: Any], recorded: Date?, into state: inout LedgerReplayState
  ) {
    let node = text(payload["node_id"])
    guard let definition = state.workflow.nodes[node] else {
      state.errors.append("passed node is not present in the installed workflow contracts")
      return
    }
    if node == "bind_pr_ready" && !state.passedNodes.contains("pr_ready") {
      state.errors.append("TestFlight continuation cannot bind before pr_ready")
    }
    if state.passedNodes.contains(node) {
      state.errors.append("workflow node cannot pass more than once: \(node)")
    }
    if state.terminallyFailedNodes.contains(node) {
      state.errors.append("workflow node cannot pass after failed_terminal: \(node)")
    }
    let dependencies = Set(definition["requires"] as? [String] ?? [])
    if !dependencies.isSubset(of: state.passedNodes) {
      state.errors.append(
        "workflow node \(node) passed before dependencies: \(dependencies.subtracting(state.passedNodes).sorted().joined(separator: ", "))"
      )
    }
    let authorization = state.authorizations.count == 1 ? state.authorizations.values.first : nil
    if state.workflow.patchBound.contains(node) || state.protectedBy[node] != nil {
      if let authorization, let recorded,
        let issued = try? HarnessRuntime.parseTimestamp(text(authorization["issued_at"])),
        let expiry = try? HarnessRuntime.parseTimestamp(text(authorization["expires_at"])),
        issued <= recorded, recorded < expiry
      {
      } else {
        state.errors.append("workflow node \(node) is outside run authorization time bounds")
      }
    }
    if state.workflow.patchBound.contains(node) {
      do {
        guard let manifest = payload["patch_manifest"] as? [String: Any],
          try patchIdentityV1(manifest) == payload["patch_identity"] as? String,
          same(manifest["base_sha"], authorization?["repository_base_sha"]),
          (manifest["records"] as? [[String: Any]] ?? []).allSatisfy({ record in
            pathAllowed(
              text(record["path"]), authorization?["allowed_paths"] as? [String] ?? [])
          })
        else { throw VerificationError.invalid("drift") }
      } catch {
        state.errors.append(
          "workflow node \(node) must recompute one authorized patch_identity_v1 manifest")
      }
    }
    let patchIdentity = payload["patch_identity"] as? String
    let repositoryFingerprint = authorization?["repository_fingerprint"] as? String
    let currentEvidence = state.passingEvidence.filter {
      $0["patch_identity"] as? String == patchIdentity
        && $0["repository_fingerprint"] as? String == repositoryFingerprint
    }
    let acceptanceCoverage = Set(
      currentEvidence.filter { $0["evidence_kind"] as? String == "acceptance" }.flatMap {
        $0["acceptance_ids"] as? [String] ?? []
      })
    let requiredAcceptance = Set(authorization?["acceptance_ids"] as? [String] ?? [])
    let acceptanceNodes: Set<String> = [
      "verify", "reverify", "prepare_evidence", "prepare_pr", "repository_confirmation",
      "commit", "push", "verify_remote_sha", "create_pr", "publish_evidence",
      "verify_published_evidence", "checks", "pr_ready", "local_verified",
    ]
    let reviewNodes: Set<String> = [
      "review", "prepare_evidence", "prepare_pr", "repository_confirmation", "commit", "push",
      "verify_remote_sha", "create_pr", "publish_evidence", "verify_published_evidence",
      "checks", "pr_ready",
    ]
    let commitNodes: Set<String> = [
      "verify_remote_sha", "create_pr", "publish_evidence", "verify_published_evidence",
      "checks", "pr_ready",
    ]
    let publicationNodes: Set<String> = ["verify_published_evidence", "checks", "pr_ready"]
    if acceptanceNodes.contains(node),
      authorization == nil || requiredAcceptance.isEmpty
        || !requiredAcceptance.isSubset(of: acceptanceCoverage)
    {
      state.errors.append("workflow node \(node) lacks current complete acceptance evidence")
    }
    if node == "local_verified",
      let local = authorization?["local_requirements"] as? [String: Any]
    {
      if local["review_required"] as? Bool == true {
        if !currentEvidence.contains(where: { $0["evidence_kind"] as? String == "review" }) {
          state.errors.append("local_verified lacks the review required by its accepted plan")
        }
      } else if !currentEvidence.contains(where: { evidence in
        evidence["evidence_kind"] as? String == "acceptance"
          && ((evidence["tool_tuple"] as? [String: Any])?["omitted_checks"] as? [String] ?? [])
            .contains("independent_review:not_required_by_accepted_plan")
      }) {
        state.errors.append("local_verified must record why independent review was omitted")
      }
      if local["spec_kit_required"] as? Bool == true {
        let checkpoints = currentEvidence.filter {
          $0["evidence_kind"] as? String == "spec_kit_checkpoint"
        }
        if checkpoints.count == 1,
          let snapshot = (checkpoints[0]["tool_tuple"] as? [String: Any])?["spec_kit_snapshot"]
            as? [String: Any], let expected = authorization?["spec_kit"] as? [String: Any]
        {
          state.errors += specKitCheckpointErrors(snapshot: snapshot, expected: expected)
        } else {
          state.errors.append(
            "local_verified requires one current Spec Kit checkpoint matching its authorization"
          )
        }
      }
    }
    if reviewNodes.contains(node),
      !currentEvidence.contains(where: { $0["evidence_kind"] as? String == "review" })
    {
      state.errors.append("workflow node \(node) lacks current review evidence")
    }
    if commitNodes.contains(node),
      !currentEvidence.contains(where: {
        $0["evidence_kind"] as? String == "commit_equivalence"
          && same($0["local_sha"], $0["remote_sha"])
      })
    {
      state.errors.append("workflow node \(node) lacks current commit equivalence evidence")
    }
    if publicationNodes.contains(node),
      !currentEvidence.contains(where: {
        $0["evidence_kind"] as? String == "publication"
          && ($0["tool_tuple"] as? [String: Any])?["viewable"] as? Bool == true
      })
    {
      state.errors.append("workflow node \(node) lacks current viewable publication evidence")
    }
    if ["checks", "pr_ready"].contains(node),
      !currentEvidence.contains(where: {
        $0["evidence_kind"] as? String == "checks_readback"
          && ($0["tool_tuple"] as? [String: Any])?["required_checks_satisfied"] as? Bool == true
      })
    {
      state.errors.append("workflow node \(node) lacks current required-checks read-back evidence")
    }

    for (planID, plan) in state.resourcePlans
    where (plan["protects"] as? [String] ?? []).contains(node) {
      guard let leaseID = state.planBindings[planID],
        let lease = state.active.values.first(where: { text($0["lease_id"]) == leaseID })
      else {
        state.errors.append("workflow node \(node) passed without planned resource lease \(planID)")
        continue
      }
      if let recorded,
        let acquired = try? HarnessRuntime.parseTimestamp(text(lease["acquired_at"])),
        let expires = try? HarnessRuntime.parseTimestamp(text(lease["expires_at"])),
        acquired <= recorded, recorded < expires
      {
      } else {
        state.errors.append(
          "workflow node \(node) passed outside planned resource lease \(planID) time bounds")
      }
    }
    for acquireNode in state.protectedBy[node] ?? [] {
      guard let binding = state.workflowLeaseBindings[acquireNode],
        let lease = state.active[text(binding["resource"]) + "\0" + text(binding["resource_key"])],
        same(lease["lease_id"], binding["lease_id"])
      else {
        state.errors.append("workflow node \(node) passed without its bound active lease")
        continue
      }
      if let recorded,
        let acquired = try? HarnessRuntime.parseTimestamp(text(lease["acquired_at"])),
        let expires = try? HarnessRuntime.parseTimestamp(text(lease["expires_at"])),
        acquired <= recorded, recorded < expires
      {
      } else {
        state.errors.append("workflow node \(node) passed outside its bound lease time interval")
      }
    }
    if definition["lease_action"] as? String == "acquire" {
      let binding: [String: Any] = [
        "resource": payload["lease_resource"] as Any,
        "resource_key": payload["lease_resource_key"] as Any,
        "lease_id": payload["lease_id"] as Any,
      ]
      let lease = state.active[text(binding["resource"]) + "\0" + text(binding["resource_key"])]
      if text(binding["resource"]) != text(definition["resource"])
        || ["resource", "resource_key", "lease_id"].contains(where: {
          text(binding[$0]).isEmpty
        }) || lease == nil || !same(lease?["lease_id"], binding["lease_id"])
        || !same(lease?["protects"], definition["protects"])
      {
        state.errors.append(
          "workflow lease-acquire node \(node) lacks its exact active lease binding")
      } else if state.workflowLeaseBindings.values.contains(where: { same($0, binding) }) {
        state.errors.append("one lease cannot satisfy multiple workflow acquire nodes")
      } else {
        state.workflowLeaseBindings[node] = binding
      }
    } else if definition["lease_action"] as? String == "release" {
      let binding: [String: Any] = [
        "resource": payload["lease_resource"] as Any,
        "resource_key": payload["lease_resource_key"] as Any,
        "lease_id": payload["lease_id"] as Any,
      ]
      guard let acquire = state.releaseToAcquire[node],
        let expected = state.workflowLeaseBindings[acquire],
        same(binding, expected),
        state.releasedLeases[
          text(binding["resource"]) + "\0" + text(binding["resource_key"]) + "\0"
            + text(binding["lease_id"])] != nil
      else {
        state.errors.append(
          "workflow lease-release node \(node) lacks its exact released lease binding")
        state.passedNodes.insert(node)
        return
      }
    }
    state.passedNodes.insert(node)
    if ["local_verified", "pr_ready", "testflight_uploaded", "testflight_distributed"].contains(
      node), !state.active.isEmpty
    {
      state.errors.append("terminal node cannot pass with an active lease")
    }
    if ["local_verified", "pr_ready", "testflight_uploaded", "testflight_distributed"].contains(
      node)
    {
      let applicable = state.resourcePlans.filter { _, plan in
        Set(plan["protects"] as? [String] ?? []).isSubset(of: state.passedNodes)
      }.keys
      let unreleased = Set(applicable).subtracting(state.releasedPlans)
      if !unreleased.isEmpty {
        state.errors.append(
          "terminal node requires every applicable resource plan to be released: \(unreleased.sorted().joined(separator: ", "))"
        )
      }
    }
    if node == "pr_ready", !Set(state.workflow.main).isSubset(of: state.passedNodes) {
      state.errors.append("pr_ready requires every installed main-workflow node")
    }
    if node == "pr_ready", let authorization = state.authorizations.values.first {
      let required = Set(
        (authorization["action_grants"] as? [[String: Any]] ?? []).filter {
          $0["phase"] as? String == "pr_delivery"
        }.map { "pr_delivery\0\(text($0["action"]))\0\(text($0["operation"]))" })
      if !required.isSubset(of: state.successfulOperations) {
        state.errors.append("pr_ready requires every authorized delivery operation")
      }
    }
    if node == "testflight_uploaded",
      let cutoff = state.workflow.continuation.firstIndex(of: "testflight_uploaded"),
      !Set(state.workflow.continuation[...cutoff]).isSubset(of: state.passedNodes)
    {
      state.errors.append("testflight_uploaded requires every upload-continuation node")
    }
    if node == "testflight_distributed",
      !Set(state.workflow.continuation).isSubset(of: state.passedNodes)
    {
      state.errors.append("testflight_distributed requires every continuation node")
    }
    if node == "local_verified", !Set(state.workflow.main).isSubset(of: state.passedNodes) {
      state.errors.append("local_verified requires every installed local-workflow node")
    }
  }

  private static func evidenceTupleErrors(_ payload: [String: Any], recordedAt: Date?) -> [String] {
    guard let tuple = payload["tool_tuple"] as? [String: Any] else {
      return ["passed evidence requires its exact evidence-kind tool tuple"]
    }
    let common: Set<String> = [
      "provider", "tool", "tool_version", "command_or_call", "started_at", "ended_at",
      "exit_status",
    ]
    let kindFields: [String: Set<String>] = [
      "acceptance": [
        "verification_scope", "evidence_layer", "platform", "destination", "coverage", "artifacts",
        "omitted_checks",
      ],
      "review": ["staged_diff_sha256"], "commit_equivalence": ["comparison"],
      "spec_kit_checkpoint": ["spec_kit_snapshot"], "testflight_artifact": [],
      "publication": ["viewable", "readback_sha256"],
      "checks_readback": ["required_checks_satisfied", "readback_sha256"],
    ]
    guard let kind = payload["evidence_kind"] as? String, let specific = kindFields[kind],
      Set(tuple.keys) == common.union(specific)
    else { return ["passed evidence requires its exact evidence-kind tool tuple"] }
    var errors: [String] = []
    for field in ["provider", "tool", "tool_version", "command_or_call"]
    where (tuple[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      != false
    { errors.append("passed evidence tool tuple requires \(field)") }
    if jsonInt(tuple["exit_status"]) != 0 {
      errors.append("passed evidence requires zero tool exit status")
    }
    if let start = try? HarnessRuntime.parseTimestamp(text(tuple["started_at"])),
      let end = try? HarnessRuntime.parseTimestamp(text(tuple["ended_at"])), end >= start,
      recordedAt == nil || end <= recordedAt!
    {
    } else {
      errors.append("passed evidence tool time range is invalid")
    }
    if kind == "review", !sha256(tuple["staged_diff_sha256"]) {
      errors.append("passed review evidence must bind the staged diff digest")
    }
    if kind == "commit_equivalence",
      !same(payload["local_sha"], payload["remote_sha"]) || !sha(text(payload["local_sha"]))
    {
      errors.append("passed commit evidence requires equal local and remote SHAs")
    }
    if kind == "publication", tuple["viewable"] as? Bool != true || !hash(tuple["readback_sha256"])
    {
      errors.append("passed publication evidence requires a viewable read-back digest")
    }
    if kind == "checks_readback",
      tuple["required_checks_satisfied"] as? Bool != true || !hash(tuple["readback_sha256"])
    {
      errors.append("passed checks evidence requires a satisfied read-back digest")
    }
    if kind == "acceptance" {
      if tuple["verification_scope"] as? String != "minimum-sufficient" {
        errors.append("acceptance evidence must use minimum-sufficient scope")
      }
      let layer = tuple["evidence_layer"] as? String
      if !["repository_contract", "build", "runtime_ui", "motion"].contains(layer ?? "") {
        errors.append("acceptance evidence layer is invalid")
      }
      if !["repository", "ios", "ipados", "watchos", "macos", "multi-platform"].contains(
        tuple["platform"] as? String ?? "")
      {
        errors.append("acceptance evidence platform is invalid")
      }
      if (tuple["destination"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        != false
      {
        errors.append("acceptance evidence destination is required")
      }
      let coverage = tuple["coverage"] as? [[String: Any]] ?? []
      let coverageIDs = coverage.compactMap { $0["acceptance_id"] as? String }
      let coverageFields: Set<String> = [
        "acceptance_id", "observable_contract", "prevented_failure", "unique_path", "result",
      ]
      if coverage.isEmpty
        || coverage.contains(where: { item in
          Set(item.keys) != coverageFields
            || ["acceptance_id", "observable_contract", "prevented_failure", "unique_path"]
              .contains(where: { field in
                (item[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  != false
              })
            || item["result"] as? String != "passed"
        })
      {
        errors.append("acceptance coverage fields are invalid or did not pass")
      }
      if Set(coverageIDs) != Set(payload["acceptance_ids"] as? [String] ?? [])
        || Set(coverageIDs).count != coverageIDs.count
      {
        errors.append("acceptance coverage must exactly match evidence acceptance IDs")
      }
      if let omissions = tuple["omitted_checks"] as? [String],
        Set(omissions).count == omissions.count, omissions.allSatisfy({ !$0.isEmpty })
      {
      } else {
        errors.append("acceptance evidence omissions must be unique strings")
      }
      let artifacts = tuple["artifacts"] as? [[String: Any]] ?? []
      let kinds = Set(artifacts.compactMap { $0["kind"] as? String })
      let artifactFields: Set<String> = ["kind", "reference", "content_sha256"]
      if artifacts.contains(where: {
        Set($0.keys) != artifactFields
          || !["screenshot", "video", "xcresult", "log", "report"].contains(
            $0["kind"] as? String ?? "")
          || ($0["reference"] as? String)?.isEmpty != false || !hash($0["content_sha256"])
      }) {
        errors.append("acceptance evidence artifact is invalid")
      }
      if layer == "runtime_ui" && !kinds.contains("screenshot") {
        errors.append("runtime UI acceptance requires screenshot evidence")
      }
      if layer == "motion" && !kinds.contains("video") {
        errors.append("motion acceptance requires video evidence")
      }
    }
    return errors
  }

  private static func specKitCheckpointErrors(snapshot: [String: Any], expected: [String: Any])
    -> [String]
  {
    var errors: [String] = []
    let mappings = [
      ("spec_kit_release", "release"), ("feature_id", "feature_id"),
      ("feature_directory", "feature_directory"), ("snapshot_sha256", "snapshot_sha256"),
      ("artifact_hashes", "artifact_hashes"),
    ]
    if mappings.contains(where: { !same(snapshot[$0.0], expected[$0.1]) }) {
      errors.append("local_verified Spec Kit checkpoint drifted from authorization")
    }
    let immutableKeys: Set<String> = [
      "schema_version", "spec_kit_release", "feature_id", "feature_directory", "accepted_artifacts",
    ]
    guard immutableKeys.isSubset(of: Set(snapshot.keys)),
      let expectedHash = snapshot["snapshot_sha256"] as? String
    else { return errors + ["local_verified Spec Kit checkpoint shape is invalid"] }
    let immutable = Dictionary(
      uniqueKeysWithValues: immutableKeys.map { ($0, snapshot[$0] ?? NSNull()) })
    if (try? canonicalSHA256(immutable)) != expectedHash {
      errors.append("local_verified Spec Kit checkpoint hash is not canonical")
    }
    return errors
  }
}
