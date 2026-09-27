import Foundation

extension Authorization {
  public static func validateCoordinatorBinding(
    statePath: URL?, binding: Any?, context: RuntimeContext
  ) -> [String] {
    guard let statePath, let binding = binding as? [String: Any] else {
      return ["coordination_required: trusted coordinator binding is unavailable"]
    }
    do {
      _ = try ResourceCoordinator.validateTrustedBinding(
        statePath: statePath, binding: binding, context: context)
      return []
    } catch { return ["coordination_required: \(errorCode(error))"] }
  }

  public static func authorizeAction(
    envelope: [String: Any], request: [String: Any], now: Date = Date(),
    ledgerRecords: [[String: Any]],
    policyOverlay: [String: Any], liveRepository: [String: Any],
    liveSpecSnapshot: [String: Any]? = nil,
    liveAppleObservation: [String: Any]? = nil, verifiedCoordinatorReceipt: [String: Any]? = nil,
    coordinatorState: URL? = nil, selectedWriter: String?,
    verifiedHealthAttestation: [String: Any]?, context: RuntimeContext
  ) -> [String] {
    var errors =
      validateAuthorization(envelope, context: context)
      + validatePolicyOverlay(envelope, overlay: policyOverlay)
    let keys = Set(request.keys)
    let missing = requestFields.subtracting(keys)
    let extra = keys.subtracting(requestFields)
    if !missing.isEmpty {
      errors.append("action request is missing fields: \(missing.sorted().joined(separator: ", "))")
    }
    if !extra.isEmpty {
      errors.append(
        "action request has unsupported fields: \(extra.sorted().joined(separator: ", "))")
    }
    guard let operationInput = request["operation_input"] as? [String: Any], !operationInput.isEmpty
    else {
      return Array(
        Set(errors + ["action request must include one non-empty structured operation_input"])
      ).sorted()
    }
    if (try? canonicalSHA256(operationInput)) != request["constraint_sha256"] as? String {
      errors.append("action request constraint digest does not match operation_input")
    }
    let digest = authorizationHash(envelope)
    let action = text(request["action"])
    if request["authorization_id"] as? String != envelope["authorization_id"] as? String {
      errors.append("authorization ID drifted")
    }
    if request["run_id"] as? String != envelope["run_id"] as? String {
      errors.append("run ID drifted")
    }
    if request["authorization_hash"] as? String != digest {
      errors.append("authorization hash drifted")
    }
    if request["delivery_target"] as? String != envelope["delivery_target"] as? String {
      errors.append("delivery target drifted from authorization")
    }
    if !["codex", "claude"].contains(selectedWriter ?? "") {
      errors.append("selected writer is unavailable from the trusted harness")
    } else if selectedWriter != envelope["selected_writer"] as? String {
      errors.append("selected writer drifted from the authorization")
    }
    if request["writer_actor"] as? String != selectedWriter
      || request["lease_owner"] as? String != selectedWriter
    {
      errors.append("action request writer or lease owner is not the selected writer")
    }
    if !allowedActions.contains(action) || forbiddenActions.contains(action) {
      errors.append("requested action is forbidden or not allowlisted")
    }
    if let issued = try? HarnessRuntime.parseTimestamp(text(envelope["issued_at"])), now < issued {
      errors.append("authorization is not active yet")
    }
    if let expiry = try? HarnessRuntime.parseTimestamp(text(envelope["expires_at"])), now >= expiry
    {
      errors.append("authorization expired")
    }
    let repositoryFields = ["fingerprint", "canonical_root", "remote", "base_sha", "branch"]
    let expectedRepository = envelope["repository"] as? [String: Any] ?? [:]
    if repositoryFields.contains(where: {
      !same((request["repository"] as? [String: Any])?[$0], expectedRepository[$0])
    }) {
      errors.append("repository or branch drifted from authorization")
    }
    if repositoryFields.contains(where: { !same(liveRepository[$0], expectedRepository[$0]) }) {
      errors.append("live authoritative Git repository drifted from authorization")
    }
    if let spec = envelope["spec_kit"] as? [String: Any] {
      if request["spec_snapshot_sha256"] as? String != spec["snapshot_sha256"] as? String {
        errors.append("Spec Kit snapshot drifted from authorization")
      }
      guard let liveSpecSnapshot else {
        errors.append("live Spec Kit snapshot is required for every authorized write")
        return Array(Set(errors)).sorted()
      }
      for pair in [
        ("spec_kit_release", "release"), ("feature_id", "feature_id"),
        ("feature_directory", "feature_directory"), ("snapshot_sha256", "snapshot_sha256"),
        ("artifact_hashes", "artifact_hashes"),
      ] where !same(liveSpecSnapshot[pair.0], spec[pair.1]) {
        errors.append("live Spec Kit artifacts drifted from authorization")
        break
      }
      if request["spec_checkpoint_sha256"] as? String
        != (try? canonicalSHA256(liveSpecSnapshot["workflow_checkpoint"] ?? NSNull()))
      {
        errors.append("live Spec Kit checkpoint digest drifted from the action request")
      }
      let checkpoints = ledgerRecords.compactMap { $0["payload"] as? [String: Any] }.filter {
        $0["evidence_kind"] as? String == "spec_kit_checkpoint"
          && $0["outcome"] as? String == "passed"
          && $0["repository_fingerprint"] as? String == expectedRepository["fingerprint"] as? String
      }.compactMap { ($0["tool_tuple"] as? [String: Any])?["spec_kit_snapshot"] as? [String: Any] }
      if checkpoints.count != 1 {
        errors.append("Spec Kit write requires one prior private checkpoint observation")
      } else {
        errors += SpecKitSnapshot.verifySnapshot(
          expected: checkpoints[0], current: liveSpecSnapshot)
      }
    } else if !(request["spec_snapshot_sha256"] is NSNull)
      || !(request["spec_checkpoint_sha256"] is NSNull) || liveSpecSnapshot != nil
    {
      errors.append("unexpected Spec Kit snapshot for a disabled binding")
    }
    errors += ledgerContractErrors(
      ledgerRecords, coordinatorState: coordinatorState, context: context)
    errors += ledgerLimitErrors(envelope, records: ledgerRecords)
    let paths = request["paths"] as? [String] ?? []
    if paths.isEmpty || Set(paths).count != paths.count {
      errors.append("action request must bind at least one changed or affected path")
    }
    if paths.contains(where: { !exactPathAllowed($0, envelope["allowed_paths"] as? [String] ?? []) }
    ) {
      errors.append("requested path is outside authorization")
    }
    if action == "git.commit" {
      errors += commitPathErrors(
        paths: paths, scope: operationInput["paths"] as? [String] ?? [],
        stagedPaths: liveRepository["staged_paths"] as? [String])
      let evidence = ledgerRecords.compactMap {
        $0["record_type"] as? String == "evidence" ? $0["payload"] as? [String: Any] : nil
      }.filter {
        same($0["patch_identity"], liveRepository["staged_patch_identity"])
          && $0["outcome"] as? String == "passed"
      }
      let localReviewOptional =
        envelope["delivery_target"] as? String == "local_verified"
        && (envelope["local_requirements"] as? [String: Any])?["review_required"] as? Bool == false
      if localReviewOptional {
        let omissions = evidence.filter {
          $0["evidence_kind"] as? String == "acceptance"
            && (($0["tool_tuple"] as? [String: Any])?["omitted_checks"] as? [String] ?? [])
              .contains("independent_review:not_required_by_accepted_plan")
        }
        if omissions.count != 1 {
          errors.append(
            "local git.commit must record why independent review was omitted for the exact staged patch"
          )
        }
      } else if evidence.filter({ $0["evidence_kind"] as? String == "review" }).count != 1 {
        errors.append("git.commit requires one review of the exact live staged diff")
      }
    }
    if action == "git.push" {
      if paths != liveRepository["outgoing_paths"] as? [String] {
        errors.append("git.push paths must exactly match the live outgoing commit paths")
      }
      let evidence = ledgerRecords.filter {
        $0["record_type"] as? String == "evidence"
          && ($0["payload"] as? [String: Any])?["evidence_kind"] as? String == "commit_equivalence"
          && same(($0["payload"] as? [String: Any])?["local_sha"], liveRepository["head_sha"])
          && same(
            ($0["payload"] as? [String: Any])?["patch_identity"],
            liveRepository["head_patch_identity"])
      }
      if evidence.count != 1 {
        errors.append("git.push requires one commit-equivalence proof for the live HEAD")
      }
    }
    do {
      let descriptor = try canonicalResourceDescriptor(envelope, action: action)
      let key = try canonicalLeaseResourceKey(envelope, action: action)
      if !same(request["resource_descriptor"], descriptor)
        || request["lease_resource_key"] as? String != key
      {
        errors.append(
          "action resource descriptor or key is not the canonical authorized descriptor")
      }
    } catch { errors.append("action lease resource key cannot be derived") }
    if verifiedCoordinatorReceipt == nil {
      errors.append("coordination_required: live coordinator receipt is unavailable")
    } else if !same(verifiedCoordinatorReceipt, request["coordinator_receipt"]) {
      errors.append("live coordinator receipt drifted from the action request")
    }
    let active = activeLeases(ledgerRecords).leases
    let leaseKey = text(request["lease_resource"]) + "\0" + text(request["lease_resource_key"])
    let lease = active[leaseKey]
    if request["lease_resource"] as? String != expectedLeaseResource(action) {
      errors.append("action is not protected by the required resource lease")
    }
    if lease == nil || !same(lease?["lease_id"], request["lease_id"])
      || !same(lease?["owner"], request["lease_owner"])
      || !same(lease?["resource_descriptor"], request["resource_descriptor"])
      || !same(lease?["coordinator_receipt"], request["coordinator_receipt"])
    {
      errors.append("action request does not own the exact active ledger lease")
    } else {
      if let expiry = try? HarnessRuntime.parseTimestamp(text(lease?["expires_at"])), now >= expiry
      {
        errors.append("action lease expired before grant reservation")
      }
      if !(lease?["allowed_actions"] as? [String] ?? []).contains(action) {
        errors.append("action is outside the active lease allowance")
      }
      if lease?["branch"] as? String != expectedRepository["branch"] as? String {
        errors.append("action lease branch drifted from authorization")
      }
      if lease?["base_sha"] as? String != expectedRepository["base_sha"] as? String {
        errors.append("action lease base SHA drifted from authorization")
      }
      if lease?["approval_id"] as? String != envelope["authorization_id"] as? String {
        errors.append("action lease is not bound to this run authorization")
      }
      if paths.contains(where: { !exactPathAllowed($0, lease?["allowed_paths"] as? [String] ?? []) }
      ) {
        errors.append("requested path is outside the active lease allowance")
      }
    }
    let approvals = ledgerRecords.filter { record in
      guard record["record_type"] as? String == "approval",
        let payload = record["payload"] as? [String: Any]
      else { return false }
      return payload["kind"] as? String == "run_authorization"
        && payload["decision"] as? String == "approved"
        && payload["approval_id"] as? String == envelope["authorization_id"] as? String
        && payload["authorization_hash"] as? String == digest
        && record["run_id"] as? String == envelope["run_id"] as? String
    }
    if approvals.count != 1 {
      errors.append("ledger lacks one exact prior approved authorization record")
    }
    if ["git.commit", "git.push"].contains(action) {
      errors += repositoryConfirmationErrors(ledgerRecords, repository: expectedRepository)
    }
    let grants = (envelope["action_grants"] as? [[String: Any]] ?? []).filter { grant in
      [
        "system", "action", "operation", "operation_input", "constraint_sha256", "phase",
        "grant_id", "idempotency_key",
      ].allSatisfy { same(grant[$0], request[$0]) }
        && same(grant["resource_key"], request["lease_resource_key"])
    }
    if grants.count != 1 {
      errors.append("no one exact action grant matches the request")
    } else {
      var expectedTarget = grants[0]["target"]
      if let source = grants[0]["target_from_grant_id"] as? String {
        let outputs = ledgerRecords.compactMap { $0["payload"] as? [String: Any] }.filter {
          $0["authorization_hash"] as? String == digest && $0["grant_id"] as? String == source
            && $0["outcome"] as? String == "succeeded"
        }.compactMap { $0["output_target"] as? String }
        let sourceGrant = (envelope["action_grants"] as? [[String: Any]] ?? []).first {
          $0["grant_id"] as? String == source
        }
        let kind = sourceGrant?["produces_target_kind"]
        let valid = outputs.filter {
          validProducedTarget(kind: kind, target: $0, repository: boundGitHubSlug(envelope))
        }
        if outputs.count != 1 || valid.count != 1 {
          errors.append("derived target is unavailable, ambiguous, or outside the bound repository")
        } else {
          expectedTarget = valid[0]
        }
      }
      if !same(expectedTarget, request["target"]) {
        errors.append("requested target drifted from its exact or derived grant")
      }
      if ledgerRecords.contains(where: {
        ["grant_reservation", "external_write"].contains($0["record_type"] as? String ?? "")
          && ($0["payload"] as? [String: Any])?["authorization_hash"] as? String == digest
          && ($0["payload"] as? [String: Any])?["grant_id"] as? String == grants[0]["grant_id"]
            as? String
      }) {
        errors.append("single-use action grant was already reserved or consumed in the ledger")
      }
    }
    if action.hasPrefix("apple.") {
      errors += liveAppleErrors(
        envelope: envelope, request: request, observation: liveAppleObservation, now: now)
      errors += appleActionErrors(envelope, request: request, records: ledgerRecords)
    } else if !(request["apple"] is NSNull) || !(request["apple_observation_sha256"] is NSNull)
      || liveAppleObservation != nil
    {
      errors.append("non-Apple action cannot carry Apple target observations")
    }
    errors += liveHealthErrors(
      envelope, request: request, verified: verifiedHealthAttestation, now: now)
    return Array(Set(errors)).sorted()
  }

  /// Commit and push need the repository confirmation for the exact
  /// `<fingerprint>:<branch>:<remote>` scope. Exactly one approval may exist for that scope. A
  /// rejection recorded after it revokes the confirmation for the rest of the run, and a second
  /// approval does not restore it.
  static func repositoryConfirmationErrors(_ records: [[String: Any]], repository: [String: Any])
    -> [String]
  {
    let scope =
      "\(text(repository["fingerprint"])):\(text(repository["branch"])):\(text(repository["remote"]))"
    let decisions = records.compactMap { record -> String? in
      guard record["record_type"] as? String == "approval",
        let payload = record["payload"] as? [String: Any],
        payload["kind"] as? String == "repository", payload["scope"] as? String == scope
      else { return nil }
      return text(payload["decision"])
    }
    if decisions.filter({ $0 == "approved" }).count != 1 {
      return ["git commit or push requires one exact prior repository confirmation"]
    }
    return decisions.last == "approved"
      ? [] : ["repository confirmation was revoked by a later rejection"]
  }

  /// A run approved while degraded may continue once health recovers, but never below the
  /// approved status.
  static func healthStatusSatisfies(_ live: Any?, approved: Any?) -> Bool {
    let rank = ["degraded": 1, "healthy": 2]
    guard let live = rank[text(live)], let approved = rank[text(approved)] else { return false }
    return live >= approved
  }

  // The commit descriptor is fixed before implementation, so its paths are an approved scope with
  // allowed_paths prefix semantics; the request names the live staged set within that scope.
  static func commitPathErrors(paths: [String], scope: [String], stagedPaths: [String]?)
    -> [String]
  {
    var errors: [String] = []
    if paths.contains(where: { !exactPathAllowed($0, scope) }) {
      errors.append("git.commit path is outside the structured operation descriptor path scope")
    }
    guard let stagedPaths, !paths.isEmpty, Set(paths).count == paths.count,
      paths.count == stagedPaths.count, Set(paths) == Set(stagedPaths)
    else { return errors + ["git.commit paths must exactly match the live staged paths"] }
    return errors
  }

  private static func ledgerLimitErrors(_ envelope: [String: Any], records: [[String: Any]])
    -> [String]
  {
    let limits = envelope["limits"] as? [String: Any] ?? [:]
    let digest = authorizationHash(envelope)
    let attempts = records.compactMap {
      $0["record_type"] as? String == "attempt" ? $0["payload"] as? [String: Any] : nil
    }.filter { $0["authorization_hash"] as? String == digest }
    let values = [
      "max_implementation_attempts": attempts.filter { $0["phase"] as? String == "implementation" }
        .count, "max_review_cycles": attempts.filter { $0["phase"] as? String == "review" }.count,
      "max_transient_retries": attempts.filter { $0["outcome"] as? String == "failed_retryable" }
        .count,
    ]
    var errors = values.compactMap {
      $0.value > (jsonInt(limits[$0.key]) ?? -1)
        ? "authorization ledger limit exceeded: \($0.key)" : nil
    }
    var minutes = ["active": 0.0, "async_wait": 0.0]
    var count = 0
    for record in records where record["record_type"] as? String == "time_interval" {
      guard let payload = record["payload"] as? [String: Any],
        payload["authorization_hash"] as? String == digest
      else { continue }
      count += 1
      if let start = try? HarnessRuntime.parseTimestamp(text(payload["started_at"])),
        let end = try? HarnessRuntime.parseTimestamp(text(payload["ended_at"])),
        minutes[text(payload["kind"])] != nil
      {
        minutes[text(payload["kind"])]! += end.timeIntervalSince(start) / 60
      } else {
        errors.append("authorization time interval cannot be evaluated")
      }
    }
    if count == 0 {
      errors.append("authorization requires ledger-derived active/async time intervals")
    }
    if minutes["active"]! > Double(jsonInt(limits["active_wall_minutes"]) ?? -1) {
      errors.append("authorization active wall-time limit exceeded")
    }
    if minutes["async_wait"]! > Double(jsonInt(limits["async_wait_minutes"]) ?? -1) {
      errors.append("authorization asynchronous wait limit exceeded")
    }
    return errors
  }

  private static func liveHealthErrors(
    _ envelope: [String: Any], request: [String: Any], verified: [String: Any]?, now: Date
  ) -> [String] {
    guard let verified else {
      return ["health_required: live evaluated health attestation is unavailable"]
    }
    var errors: [String] = []
    if request["health_report_sha256"] as? String != verified["report_sha256"] as? String {
      errors.append("live health report digest drifted from the action request")
    }
    let authorized = envelope["health_attestation"] as? [String: Any] ?? [:]
    for field in [
      "profile", "authoritative_targets_sha256", "agent_skill_bundle_sha256",
      "coordinator_instance_id", "coordinator_contract_bundle_sha256",
    ] where !same(verified[field], authorized[field]) {
      errors.append("live health identity drifted from authorization")
      break
    }
    if !healthStatusSatisfies(verified["overall_status"], approved: authorized["overall_status"]) {
      errors.append("live health status fell below the approved status")
    }
    if let observed = try? HarnessRuntime.parseTimestamp(text(verified["observed_at"])),
      (-60...600).contains(now.timeIntervalSince(observed))
    {
    } else {
      errors.append("live health report is stale or from the future")
    }
    return errors
  }

  private static func appleActionErrors(
    _ envelope: [String: Any], request: [String: Any], records: [[String: Any]]
  ) -> [String] {
    guard let authorized = envelope["apple"] as? [String: Any],
      let observed = request["apple"] as? [String: Any]
    else { return ["observed Apple action must be a fully bound object"] }
    let action = text(request["action"])
    let target = text(request["target"])
    var required: Set<String> = [
      "account_guard_ref", "team_id", "app_id", "bundle_id", "platform", "version_policy",
      "build_policy", "artifact_policy", "internal_group_ids", "version", "build",
      "artifact_sha256", "artifact_source_commit", "reviewed_remote_sha",
    ]
    if action == "apple.testflight.distribute_internal"
      || (action == "apple.testflight.readback" && target.contains(":group:"))
    {
      required.insert("group_id")
    }
    var errors: [String] = []
    if Set(observed.keys) != required {
      errors.append("observed Apple action has unsupported or missing fields")
    }
    for field in [
      "account_guard_ref", "team_id", "app_id", "bundle_id", "platform", "version_policy",
      "build_policy", "artifact_policy", "internal_group_ids",
    ] where !same(observed[field], authorized[field]) {
      errors.append("Apple account, policy, app, bundle, platform, or groups drifted")
      break
    }
    guard let artifact = observed["artifact_sha256"] as? String,
      artifact.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
      let source = observed["artifact_source_commit"] as? String, sha(source)
    else { return errors + ["TestFlight action requires exact artifact and source commit digests"] }
    if observed["reviewed_remote_sha"] as? String != source {
      errors.append("artifact source is not the reviewed remote PR commit")
    }
    let version = text(observed["version"])
    let build = text(observed["build"])
    let versionPolicy = authorized["version_policy"] as? [String: Any] ?? [:]
    let buildPolicy = authorized["build_policy"] as? [String: Any] ?? [:]
    if version.isEmpty || versionPolicy["mode"] as? String != "exact"
      || version != text(versionPolicy["value"])
    {
      errors.append("TestFlight marketing version violates the exact authorization policy")
    }
    if buildPolicy["mode"] as? String == "exact" {
      if build != text(buildPolicy["value"]) {
        errors.append("TestFlight build violates the exact authorization policy")
      }
    } else if buildPolicy["mode"] as? String == "next_after_live" {
      if Int(build) != (Int(text(buildPolicy["baseline"])) ?? -2) + 1 {
        errors.append("TestFlight build is not exactly one above the authorized live baseline")
      }
    } else {
      errors.append("TestFlight build policy is unsupported")
    }
    let payloads = records.compactMap { record -> (String, [String: Any], Date?)? in
      guard let payload = record["payload"] as? [String: Any] else { return nil }
      return (
        record["record_type"] as? String ?? "", payload,
        try? HarnessRuntime.parseTimestamp(text(record["recorded_at"]))
      )
    }
    let artifactEvidence = payloads.filter {
      $0.0 == "evidence" && $0.1["evidence_kind"] as? String == "testflight_artifact"
        && $0.1["outcome"] as? String == "passed" && $0.1["remote_sha"] as? String == source
        && $0.1["artifact_source_commit"] as? String == source
        && $0.1["artifact_sha256"] as? String == artifact && $0.1["version"] as? String == version
        && $0.1["build"] as? String == build
    }
    if artifactEvidence.count != 1 {
      errors.append("TestFlight artifact lacks one exact passed ledger provenance record")
    }
    let ready = payloads.filter {
      $0.0 == "node" && $0.1["node_id"] as? String == "pr_ready"
        && $0.1["status"] as? String == "passed"
    }
    if ready.count != 1 {
      errors.append("TestFlight continuation requires one prior pr_ready terminal")
    }
    let writes = payloads.filter { $0.0 == "external_write" }.map(\.1)
    let pushes = writes.filter {
      $0["action"] as? String == "git.push" && $0["outcome"] as? String == "succeeded"
        && $0["remote_sha"] as? String == source
    }
    if pushes.count != 1 {
      errors.append("TestFlight artifact source is not the one verified pushed remote SHA")
    }
    if let group = observed["group_id"] as? String,
      !(authorized["internal_group_ids"] as? [String] ?? []).contains(group)
    {
      errors.append("TestFlight group is outside authorization")
    }
    let digest = authorizationHash(envelope)
    let uploads = writes.filter {
      $0["authorization_hash"] as? String == digest
        && $0["action"] as? String == "apple.testflight.upload"
        && $0["outcome"] as? String == "succeeded"
    }
    let processing = writes.filter {
      $0["authorization_hash"] as? String == digest
        && $0["action"] as? String == "apple.testflight.processing.wait"
        && $0["outcome"] as? String == "succeeded" && $0["external_state"] as? String == "completed"
    }
    let uploadReadback = writes.filter {
      $0["authorization_hash"] as? String == digest
        && $0["action"] as? String == "apple.testflight.readback"
        && text($0["target"]).hasSuffix(":upload") && $0["outcome"] as? String == "succeeded"
        && $0["external_state"] as? String == "completed"
    }
    let distributions = writes.filter {
      $0["authorization_hash"] as? String == digest
        && $0["action"] as? String == "apple.testflight.distribute_internal"
        && $0["outcome"] as? String == "succeeded" && $0["target"] as? String == target
    }
    if action == "apple.testflight.processing.wait" && uploads.count != 1 {
      errors.append("processing wait requires one successful authorized upload")
    }
    if action == "apple.testflight.readback" && target.hasSuffix(":upload")
      && (uploads.count != 1 || processing.count != 1)
    {
      errors.append("upload read-back requires a completed bounded processing wait")
    }
    if action == "apple.testflight.distribute_internal" && uploadReadback.count != 1 {
      errors.append("distribution requires one completed upload read-back")
    }
    if action == "apple.testflight.readback" && target.contains(":group:")
      && distributions.count != 1
    {
      errors.append("distribution read-back requires the exact prior internal distribution")
    }
    for upload in uploads {
      for field in ["artifact_sha256", "artifact_source_commit", "version", "build"]
      where !same(upload[field], observed[field]) {
        errors.append("TestFlight artifact identity drifted after upload: \(field)")
      }
    }
    if let artifactTime = artifactEvidence.first?.2, let readyTime = ready.first?.2,
      artifactTime <= readyTime
    {
      errors.append("TestFlight archive evidence must be fresh after pr_ready")
    }
    return errors
  }

  /// Unlike the shared `pathAllowed`, an allowed entry matches the path itself only exactly as
  /// written (`dir/` still admits `dir/file`, but not `dir`).
  private static func exactPathAllowed(_ path: String, _ allowed: [String]) -> Bool {
    safeRelativePath(path)
      && allowed.contains {
        path == $0
          || path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
      }
  }
}
