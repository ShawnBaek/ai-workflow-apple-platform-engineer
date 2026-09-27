import Darwin
import Foundation

extension Authorization {
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
    return reserveBoundAction(
      ledgerPath: ledgerPath, envelope: envelope, request: request, runRoot: runRoot,
      policyOverlay: policyOverlay, liveRepository: liveRepository,
      liveSpecSnapshot: liveSpecSnapshot, liveAppleObservation: liveAppleObservation,
      coordinatorState: coordinatorState, selectedWriter: selectedWriter,
      trustedHarnessSHA256: trustedHarnessSHA256,
      verifiedHealthAttestation: verifiedHealthAttestation, context: context)
  }

  /// Reserves after the caller validated the trusted coordinator binding, which identifies the
  /// executing binary; tests run inside another executable and enter here.
  static func reserveBoundAction(
    ledgerPath: URL, envelope: [String: Any], request: [String: Any], runRoot: URL,
    policyOverlay: [String: Any], liveRepository: [String: Any],
    liveSpecSnapshot: [String: Any]?, liveAppleObservation: [String: Any]?,
    coordinatorState: URL, selectedWriter: String?, trustedHarnessSHA256: String,
    verifiedHealthAttestation: [String: Any]?, context: RuntimeContext
  ) -> (errors: [String], reservation: [String: Any]?) {
    do {
      let status = try ResourceCoordinator.fullStatus(statePath: coordinatorState)
      let authority =
        (status["run_authorities"] as? [String: Any])?[text(envelope["run_id"])] as? [String: Any]
      let authorityErrors = reservationAuthorityErrors(
        authority, envelope: envelope, selectedWriter: selectedWriter,
        trustedHarnessSHA256: trustedHarnessSHA256)
      if !authorityErrors.isEmpty { return (authorityErrors, nil) }
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
        let ledgerData = try Data(contentsOf: ledgerPath)
        let records = try ledgerRecords(ledgerData)
        let headErrors = ledgerHeadErrors(
          ledgerData, ledgerPath: ledgerPath, runRoot: runRoot,
          binding: boundLedger)
        if !headErrors.isEmpty { return (headErrors, nil) }
        let now = ledgerClock(records, now: Date())
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
        try advanceLedgerHead(
          ledgerPath: ledgerPath, runRoot: runRoot, binding: boundLedger, prefix: ledgerData)
        try appendLedger(record, to: ledgerPath, expectedIdentity: ledgerIdentity)
        guard
          try ResourceCoordinator.ledgerBinding(
            ledgerPath, expectedRunID: text(envelope["run_id"]),
            expectedAuthorizationHash: authorizationHash(envelope)
          ).allSatisfy({ same(boundLedger[$0.key], $0.value) })
        else { return (["coordination_required: canonical ledger binding drifted"], nil) }
        try advanceLedgerHead(
          ledgerPath: ledgerPath, runRoot: runRoot, binding: boundLedger, prefix: ledgerData)
        return ([], record)
      }
    } catch { return (["coordination_required: \(errorCode(error))"], nil) }
  }

  static func reservationAuthorityErrors(
    _ authority: [String: Any]?, envelope: [String: Any], selectedWriter: String?,
    trustedHarnessSHA256: String
  ) -> [String] {
    guard let window = ResourceCoordinator.canonicalAuthorizationWindow(envelope),
      authority?["authorization_hash"] as? String == authorizationHash(envelope),
      authority?["selected_writer"] as? String == selectedWriter,
      authority?["harness_sha256"] as? String == trustedHarnessSHA256,
      authority?["authorization_issued_at"] as? String == window.issued,
      authority?["authorization_expires_at"] as? String == window.expires
    else { return ["coordination_required: run authority drifted or is unregistered"] }
    return []
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
}
