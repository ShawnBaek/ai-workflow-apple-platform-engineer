import Darwin
import Foundation

extension Authorization {
  public static func observeRepository(_ root: URL, expectedBaseSHA: String) throws -> [String: Any]
  {
    guard !isSymlink(root) else {
      throw VerificationError.invalid("authoritative repository root cannot be a symlink")
    }
    let canonical = root.resolvingSymlinksInPath().standardizedFileURL
    func git(_ arguments: [String]) throws -> String {
      let result = try HarnessRuntime.run(
        executable: "/usr/bin/git", arguments: ["-C", canonical.path] + arguments, timeout: 15)
      guard result.exitCode == 0, !result.timedOut, !result.truncated else {
        throw VerificationError.invalid("Git observation failed: \(arguments.first ?? "command")")
      }
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard
      URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"])).resolvingSymlinksInPath()
        == canonical
    else { throw VerificationError.invalid("authoritative root is not the exact Git top level") }
    let rawRemote = try git(["remote", "get-url", "origin"])
    _ = try normalizeGitHubRemote(rawRemote)
    let branch = try git(["branch", "--show-current"])
    guard !branch.isEmpty else {
      throw VerificationError.invalid("authoritative repository is in detached HEAD state")
    }
    guard
      (try? HarnessRuntime.run(
        executable: "/usr/bin/git",
        arguments: ["-C", canonical.path, "cat-file", "-e", "\(expectedBaseSHA)^{commit}"],
        timeout: 15
      ).exitCode) == 0
    else { throw VerificationError.invalid("authorized base SHA is unavailable") }
    guard
      (try? HarnessRuntime.run(
        executable: "/usr/bin/git",
        arguments: ["-C", canonical.path, "merge-base", "--is-ancestor", expectedBaseSHA, "HEAD"],
        timeout: 15
      ).exitCode) == 0
    else {
      throw VerificationError.invalid("authorized base SHA is not an ancestor of current HEAD")
    }
    let stagedPaths = try nulList(canonical, ["diff", "--cached", "--name-only", "-z"])
    let outgoingPaths = try nulList(
      canonical, ["diff", "--name-only", "-z", "\(expectedBaseSHA)..HEAD"])
    let stagedManifest = try gitPatchManifest(
      root: canonical, baseSHA: expectedBaseSHA, revision: "INDEX", staged: true)
    let headManifest = try gitPatchManifest(
      root: canonical, baseSHA: expectedBaseSHA, revision: "HEAD", staged: false)
    let stagedDiff = try gitData(canonical, ["diff", "--cached", "--binary"])
    return [
      "fingerprint": try repositoryFingerprint(rawRemote), "canonical_root": canonical.path,
      "remote": sanitizeRemote(rawRemote),
      "base_sha": expectedBaseSHA, "branch": branch, "head_sha": try git(["rev-parse", "HEAD"]),
      "staged_paths": stagedPaths, "staged_diff_sha256": HarnessRuntime.sha256(stagedDiff),
      "outgoing_paths": outgoingPaths,
      "staged_patch_manifest": stagedManifest,
      "staged_patch_identity": (stagedManifest["records"] as? [Any])?.isEmpty == false
        ? try patchIdentityV1(stagedManifest) : NSNull(),
      "head_patch_manifest": headManifest,
      "head_patch_identity": (headManifest["records"] as? [Any])?.isEmpty == false
        ? try patchIdentityV1(headManifest) : NSNull(),
    ]
  }

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
    if paths.contains(where: { !pathAllowed($0, envelope["allowed_paths"] as? [String] ?? []) }) {
      errors.append("requested path is outside authorization")
    }
    if action == "git.commit" {
      if paths != operationInput["paths"] as? [String] {
        errors.append("git.commit paths drifted from the structured operation descriptor")
      }
      if paths != liveRepository["staged_paths"] as? [String] {
        errors.append("git.commit paths must exactly match the live staged paths")
      }
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
      if paths.contains(where: { !pathAllowed($0, lease?["allowed_paths"] as? [String] ?? []) }) {
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
      let scope =
        "\(text(expectedRepository["fingerprint"])):\(text(expectedRepository["branch"])):\(text(expectedRepository["remote"]))"
      let repositoryApprovals = ledgerRecords.filter {
        $0["record_type"] as? String == "approval"
          && ($0["payload"] as? [String: Any])?["kind"] as? String == "repository"
          && ($0["payload"] as? [String: Any])?["decision"] as? String == "approved"
          && ($0["payload"] as? [String: Any])?["scope"] as? String == scope
      }
      if repositoryApprovals.count != 1 {
        errors.append("git commit or push requires one exact prior repository confirmation")
      }
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

  public static func reserveAction(
    ledgerPath: URL, envelope: [String: Any], request: [String: Any], runRoot: URL,
    policyOverlay: [String: Any],
    liveRepository: [String: Any], liveSpecSnapshot: [String: Any]? = nil,
    liveAppleObservation: [String: Any]? = nil,
    coordinatorState: URL, coordinatorBinding: [String: Any], selectedWriter: String?,
    trustedHarnessSHA256: String,
    verifiedHealthAttestation: [String: Any]?, context: RuntimeContext
  ) -> (errors: [String], reservation: [String: Any]?) {
    let bindingErrors = validateCoordinatorBinding(
      statePath: coordinatorState, binding: coordinatorBinding, context: context)
    if !bindingErrors.isEmpty { return (bindingErrors, nil) }
    do {
      let status = try ResourceCoordinator.fullStatus(statePath: coordinatorState)
      let authority =
        (status["run_authorities"] as? [String: Any])?[text(envelope["run_id"])] as? [String: Any]
      guard authority?["authorization_hash"] as? String == authorizationHash(envelope),
        authority?["selected_writer"] as? String == selectedWriter,
        authority?["harness_sha256"] as? String == trustedHarnessSHA256,
        authority?["authorization_issued_at"] as? String == envelope["issued_at"] as? String,
        authority?["authorization_expires_at"] as? String == envelope["expires_at"] as? String
      else { return (["coordination_required: run authority drifted or is unregistered"], nil) }
      guard safeDirectFile(ledgerPath, root: runRoot) else {
        return (
          ["authorization ledger must be a non-symlink file directly under the private run root"],
          nil
        )
      }
      return try HarnessRuntime.withFileLock(at: ledgerPath) {
        let boundLedger = try ResourceCoordinator.ledgerBinding(
          ledgerPath, expectedRunID: text(envelope["run_id"]),
          expectedAuthorizationHash: authorizationHash(envelope))
        let ledgerIdentity = try fileIdentity(ledgerPath)
        for (field, value) in boundLedger where !same(authority?[field], value) {
          return (["coordination_required: canonical ledger binding drifted"], nil)
        }
        let records = try loadLedger(ledgerPath)
        let now = Date()
        let verified = ResourceCoordinator.verifyReceipt(
          statePath: coordinatorState,
          receipt: request["coordinator_receipt"] as? [String: Any] ?? [:], now: now)
        if !verified.errors.isEmpty {
          return (["coordination_required: " + verified.errors.joined(separator: ", ")], nil)
        }
        let errors = authorizeAction(
          envelope: envelope, request: request, now: now, ledgerRecords: records,
          policyOverlay: policyOverlay, liveRepository: liveRepository,
          liveSpecSnapshot: liveSpecSnapshot, liveAppleObservation: liveAppleObservation,
          verifiedCoordinatorReceipt: verified.receipt, coordinatorState: coordinatorState,
          selectedWriter: selectedWriter, verifiedHealthAttestation: verifiedHealthAttestation,
          context: context)
        if !errors.isEmpty { return (errors, nil) }
        let runIDs = Set(records.compactMap { $0["run_id"] as? String })
        guard runIDs == [text(envelope["run_id"])] else {
          return (["ledger must contain exactly one run ID before grant reservation"], nil)
        }
        let payload: [String: Any] = [
          "reservation_id": UUID().uuidString.lowercased(),
          "authorization_hash": request["authorization_hash"]!, "grant_id": request["grant_id"]!,
          "idempotency_key": request["idempotency_key"]!,
          "system": request["system"]!, "action": request["action"]!,
          "operation": request["operation"]!, "operation_input": request["operation_input"]!,
          "action_request_sha256": "sha256:" + (try canonicalSHA256(request)),
          "constraint_sha256": request["constraint_sha256"]!, "phase": request["phase"]!,
          "target": request["target"]!,
          "lease_id": request["lease_id"]!, "lease_owner": request["lease_owner"]!,
          "writer_actor": request["writer_actor"]!, "resource": request["lease_resource"]!,
          "resource_key": request["lease_resource_key"]!,
          "resource_descriptor": request["resource_descriptor"]!,
          "coordinator_receipt": request["coordinator_receipt"]!,
          "spec_checkpoint_sha256": request["spec_checkpoint_sha256"]!,
          "apple_observation_sha256": request["apple_observation_sha256"]!,
          "apple_observation_state_sha256": try liveAppleObservation.map {
            try appleObservationStateSHA256($0)
          } ?? NSNull(),
          "health_report_sha256": request["health_report_sha256"]!, "paths": request["paths"]!,
          "repository_observation_sha256": ["git.commit", "git.push", "github.pr.create"].contains(
            text(request["action"])) ? "sha256:" + (try canonicalSHA256(liveRepository)) : NSNull(),
        ]
        let record: [String: Any] = [
          "schema_version": "1.0.0", "run_id": envelope["run_id"]!,
          "sequence": (records.compactMap { jsonInt($0["sequence"]) }.max() ?? 0) + 1,
          "recorded_at": HarnessRuntime.timestamp(now), "record_type": "grant_reservation",
          "payload": payload,
        ]
        guard
          try ResourceCoordinator.ledgerBinding(
            ledgerPath, expectedRunID: text(envelope["run_id"]),
            expectedAuthorizationHash: authorizationHash(envelope)
          ).allSatisfy({ same(boundLedger[$0.key], $0.value) })
        else { return (["coordination_required: canonical ledger binding drifted"], nil) }
        try appendLedger(record, to: ledgerPath, expectedIdentity: ledgerIdentity)
        guard
          try ResourceCoordinator.ledgerBinding(
            ledgerPath, expectedRunID: text(envelope["run_id"]),
            expectedAuthorizationHash: authorizationHash(envelope)
          ).allSatisfy({ same(boundLedger[$0.key], $0.value) })
        else { return (["coordination_required: canonical ledger binding drifted"], nil) }
        return ([], record)
      }
    } catch { return (["coordination_required: \(errorCode(error))"], nil) }
  }

  public static func dispatchSpecStateErrors(
    authorization: [String: Any], reservation: [String: Any], trustedHarness: [String: Any]
  ) -> [String] {
    guard let spec = authorization["spec_kit"] as? [String: Any] else {
      return reservation["spec_checkpoint_sha256"] is NSNull
        ? [] : ["dispatch reservation contains an unexpected Spec Kit checkpoint"]
    }
    do {
      let snapshot = try SpecKitSnapshot.buildSnapshot(
        root: URL(fileURLWithPath: text(trustedHarness["authoritative_root"])),
        release: text(spec["release"]), runID: text(spec["workflow_run_id"]),
        featureDirectory: text(spec["feature_directory"]))
      var errors: [String] = []
      for pair in [
        ("spec_kit_release", "release"), ("feature_id", "feature_id"),
        ("feature_directory", "feature_directory"), ("snapshot_sha256", "snapshot_sha256"),
        ("artifact_hashes", "artifact_hashes"),
      ] where !same(snapshot[pair.0], spec[pair.1]) {
        errors.append("dispatch Spec Kit snapshot drifted from authorization")
        break
      }
      if (try? canonicalSHA256(snapshot["workflow_checkpoint"] ?? NSNull())) != reservation[
        "spec_checkpoint_sha256"] as? String
      {
        errors.append("dispatch Spec Kit checkpoint drifted from its reservation")
      }
      return errors
    } catch { return ["dispatch Spec Kit observation failed: \(errorCode(error))"] }
  }

  public static func dispatchAppleStateErrors(
    authorization: [String: Any], reservation: [String: Any], trustedHarness: [String: Any],
    reservedAt: Date, verifiedAt: Date
  ) -> [String] {
    guard text(reservation["action"]).hasPrefix("apple.") else {
      return
        (reservation["apple_observation_sha256"] is NSNull
        && reservation["apple_observation_state_sha256"] is NSNull)
        ? [] : ["non-Apple dispatch cannot carry an Apple observation"]
    }
    guard let binding = trustedHarness["apple_observation_probe"] as? [String: Any],
      Set(binding.keys) == [
        "executable", "executable_sha256", "output_contract", "timeout_seconds",
      ], let timeout = jsonInt(binding["timeout_seconds"]), (1...30).contains(timeout)
    else { return ["dispatch Apple action requires a pinned guarded ASC probe"] }
    let executable = URL(fileURLWithPath: text(binding["executable"]))
    var info = stat()
    guard executable.path.hasPrefix("/"), lstat(executable.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_mode & 0o022 == 0,
      access(executable.path, X_OK) == 0,
      binding["output_contract"] as? String == "apple_observation_v1",
      (try? HarnessRuntime.sha256File(executable)).map({ "sha256:" + $0 }) == binding[
        "executable_sha256"] as? String
    else { return ["dispatch guarded ASC probe failed closed: unsafe executable or digest drift"] }
    do {
      let result = try HarnessRuntime.run(
        executable: executable.path, arguments: [], timeout: Double(timeout))
      guard result.exitCode == 0, !result.timedOut, !result.truncated,
        let data = result.stdout.data(using: .utf8),
        let observation = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw VerificationError.invalid("guarded ASC probe failed") }
      var errors = liveAppleErrors(
        envelope: authorization,
        request: ["apple_observation_sha256": try canonicalSHA256(observation)],
        observation: observation, now: verifiedAt)
      if let observed = try? HarnessRuntime.parseTimestamp(text(observation["observed_at"])),
        observed < reservedAt
      {
        errors.append("dispatch guarded ASC observation predates its reservation")
      }
      if (try? appleObservationStateSHA256(observation)) != reservation[
        "apple_observation_state_sha256"] as? String
      {
        errors.append("dispatch guarded ASC state drifted from its reservation")
      }
      return errors
    } catch { return ["dispatch guarded ASC probe failed closed: \(errorCode(error))"] }
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
      "profile", "overall_status", "authoritative_targets_sha256", "agent_skill_bundle_sha256",
      "coordinator_instance_id", "coordinator_contract_bundle_sha256",
    ] where !same(verified[field], authorized[field]) {
      errors.append("live health identity or status drifted from authorization")
      break
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

  private static func gitPatchManifest(root: URL, baseSHA: String, revision: String, staged: Bool)
    throws -> [String: Any]
  {
    guard sha(baseSHA) else {
      throw VerificationError.invalid("patch base must be one exact full commit SHA")
    }
    let tokens = try nulList(
      root,
      staged
        ? ["diff", "--cached", "--name-status", "-z", "--no-renames", baseSHA]
        : ["diff", "--name-status", "-z", "--no-renames", "\(baseSHA)..\(revision)"])
    guard tokens.count % 2 == 0 else {
      throw VerificationError.invalid("Git patch name-status stream is malformed")
    }
    var records: [[String: Any]] = []
    for index in stride(from: 0, to: tokens.count, by: 2) {
      let status = tokens[index]
      let path = tokens[index + 1]
      guard ["A", "D", "M", "T"].contains(status), safeRelative(path) else {
        throw VerificationError.invalid("Git patch contains an unsupported status or path")
      }
      if status == "D" {
        records.append([
          "path": path, "mode": try gitMode(root, revision: baseSHA, path: path, staged: false).0,
          "state": "deleted", "content_sha256": "deleted",
        ])
        continue
      }
      let (mode, object) = try gitMode(root, revision: revision, path: path, staged: staged)
      let content =
        mode == "160000" ? Data(object.utf8) : try gitData(root, ["cat-file", "blob", object])
      records.append([
        "path": path, "mode": mode,
        "state": mode == "120000" ? "symlink" : status == "A" ? "added" : "modified",
        "content_sha256": "sha256:" + HarnessRuntime.sha256(content),
      ])
    }
    let sortedRecords = records.sorted { lhs, rhs in
      (lhs["path"] as! String).utf8.lexicographicallyPrecedes((rhs["path"] as! String).utf8)
    }
    return ["version": "patch_identity_v1", "base_sha": baseSHA, "records": sortedRecords]
  }

  private static func gitMode(_ root: URL, revision: String, path: String, staged: Bool) throws -> (
    String, String
  ) {
    let data = try gitData(
      root,
      staged ? ["ls-files", "--stage", "-z", "--", path] : ["ls-tree", "-z", revision, "--", path])
    let entries = data.split(separator: 0)
    guard entries.count == 1, let line = String(data: entries[0], encoding: .utf8),
      let tab = line.firstIndex(of: "\t")
    else { throw VerificationError.invalid("Git patch path has no unique entry") }
    let metadata = line[..<tab].split(separator: " ").map(String.init)
    guard metadata.count >= 3 else {
      throw VerificationError.invalid("Git patch metadata is malformed")
    }
    return (metadata[0], staged ? metadata[1] : metadata[2])
  }
  private static func nulList(_ root: URL, _ arguments: [String]) throws -> [String] {
    try gitData(root, arguments).split(separator: 0).map {
      guard let value = String(data: $0, encoding: .utf8) else { return "\0" }
      return value
    }
  }
  private static func gitData(_ root: URL, _ arguments: [String]) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    process.standardOutput = pipe
    process.standardError = errorPipe
    try process.run()
    let outputFD = pipe.fileHandleForReading.fileDescriptor
    let errorFD = errorPipe.fileHandleForReading.fileDescriptor
    _ = fcntl(outputFD, F_SETFL, O_NONBLOCK)
    _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
    var output = Data()
    var errors = Data()
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    let limit = 64 * 1024 * 1024
    func drain(_ descriptor: Int32, into data: inout Data) throws {
      while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
          guard data.count + count <= limit else {
            throw VerificationError.invalid("Git output exceeded 64 MiB")
          }
          data.append(contentsOf: buffer.prefix(count))
          continue
        }
        if count < 0 && errno == EINTR { continue }
        break
      }
    }
    while process.isRunning {
      try drain(outputFD, into: &output)
      try drain(errorFD, into: &errors)
      if ProcessInfo.processInfo.systemUptime >= deadline {
        process.terminate()
        process.waitUntilExit()
        throw VerificationError.invalid("Git command timed out")
      }
      usleep(10_000)
    }
    process.waitUntilExit()
    try drain(outputFD, into: &output)
    try drain(errorFD, into: &errors)
    guard process.terminationStatus == 0 else {
      throw VerificationError.invalid("Git command failed")
    }
    return output
  }
  private static func fileIdentity(_ path: URL) throws -> (dev_t, ino_t) {
    var value = stat()
    guard lstat(path.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1
    else { throw VerificationError.invalid("authorization ledger identity is unsafe") }
    return (value.st_dev, value.st_ino)
  }
  private static func appendLedger(
    _ record: [String: Any], to path: URL, expectedIdentity: (dev_t, ino_t)
  ) throws {
    var data = try HarnessRuntime.canonicalJSON(record)
    data.append(10)
    let fd = open(path.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      throw VerificationError.invalid("authorization ledger append failed closed")
    }
    defer { close(fd) }
    var opened = stat()
    var named = stat()
    guard fstat(fd, &opened) == 0, lstat(path.path, &named) == 0,
      opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
      opened.st_dev == expectedIdentity.0, opened.st_ino == expectedIdentity.1
    else { throw VerificationError.invalid("authorization ledger inode drifted before append") }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else {
          throw VerificationError.invalid("authorization ledger append failed closed")
        }
        offset += count
      }
    }
    guard fsync(fd) == 0 else {
      throw VerificationError.invalid("authorization ledger fsync failed")
    }
  }
  private static func safeDirectFile(_ path: URL, root: URL) -> Bool {
    !isSymlink(path)
      && path.deletingLastPathComponent().resolvingSymlinksInPath()
        == root.resolvingSymlinksInPath()
      && FileManager.default.fileExists(atPath: path.path)
  }
  private static func isSymlink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
  }
  private static func safeRelative(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/")
      && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
  private static func pathAllowed(_ path: String, _ allowed: [String]) -> Bool {
    safeRelative(path)
      && allowed.contains {
        path == $0
          || path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
      }
  }
  private static func sha(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil
  }
  private static func text(_ value: Any?) -> String {
    value == nil || value is NSNull ? "" : ((value as? String) ?? String(describing: value!))
  }
  private static func jsonInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !HarnessRuntime.isBoolean(number) else { return nil }
    let raw = number.stringValue
    guard let value = Int(raw), raw == String(value) || raw == "-0" else { return nil }
    return value
  }
  private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }
  private static func errorCode(_ error: Error) -> String {
    (error as? VerificationError)?.description ?? String(describing: error)
  }
}
