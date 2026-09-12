import Darwin
import Foundation

extension Authorization {
  public static func verifyHealthReport(
    reportPath: URL, harnessPath: URL, runRoot: URL, policy: [String: Any],
    authorization: [String: Any]?,
    context: RuntimeContext, now: Date = Date()
  ) -> (errors: [String], attestation: [String: Any]?) {
    do {
      let bytes = try readStablePrivateData(reportPath, root: runRoot)
      let rawValue = try JSONSerialization.jsonObject(with: bytes)
      guard let raw = rawValue as? [String: Any] else {
        return (["health report must contain one JSON object"], nil)
      }
      let harness = try ResourceCoordinator.loadTrustedHarness(
        harnessPath: harnessPath, context: context)
      let exactBytesHash = "sha256:" + HarnessRuntime.sha256(bytes)
      let scope: RuntimeProbeScope? = {
        guard let value = harness["runtime_probe_scope"] as? [String: Any],
          let state = value["state_path"] as? String,
          let descriptor = value["descriptor"] as? [String: Any],
          let run = value["owner_run_id"] as? String,
          let actor = value["owner_actor"] as? String,
          let authority = value["run_authority"] as? [String: Any]
        else { return nil }
        return RuntimeProbeScope(
          statePath: URL(fileURLWithPath: state), descriptor: descriptor, ownerRunID: run,
          ownerActor: actor, ttlSeconds: intValue(value["ttl_seconds"]) ?? 120,
          runAuthority: authority)
      }()
      let evaluated = HealthEvaluation.revalidate(
        reportBytes: bytes, expectedBytesSHA256: exactBytesHash, harness: harness, policy: policy,
        authorization: authorization, runner: SystemHealthRunner(),
        runtimeCoordinator: scope == nil ? nil : ResourceCoordinatorRuntimeAdmission(),
        runtimeScope: scope, context: context, now: now)
      guard evaluated.valid else {
        return (["live health evaluation blocked"] + evaluated.errors, nil)
      }
      guard let manifest = raw["agent_skill_manifest"] as? [String: Any],
        let coordinator = raw["resource_coordinator_observation"] as? [String: Any]
      else { return (["live health report lacks required identity observations"], nil) }
      return (
        [],
        [
          "report_sha256": "sha256:" + (try canonicalSHA256(raw)),
          "observed_at": evaluated.report["observed_at"] ?? NSNull(),
          "profile": evaluated.report["profile"] ?? NSNull(),
          "overall_status": evaluated.report["overall_status"] ?? NSNull(),
          "authoritative_targets_sha256": "sha256:"
            + (try canonicalSHA256(raw["authoritative_targets"] ?? NSNull())),
          "agent_skill_bundle_sha256": manifest["expected_bundle_sha256"] ?? NSNull(),
          "coordinator_instance_id": coordinator["coordinator_instance_id"] ?? NSNull(),
          "coordinator_contract_bundle_sha256": coordinator["source_bundle_sha256"] ?? NSNull(),
        ]
      )
    } catch {
      return (["health report cannot be re-evaluated safely: \(String(describing: error))"], nil)
    }
  }

  public static func verifyReservedAction(
    ledgerPath: URL, reservationID: String, runRoot: URL, coordinatorState: URL,
    coordinatorBinding: [String: Any], healthReportPath: URL, harnessPath: URL,
    requestPath: URL, context: RuntimeContext, now: Date = Date()
  ) -> (errors: [String], dispatch: [String: Any]?) {
    let bindingErrors = validateCoordinatorBinding(
      statePath: coordinatorState, binding: coordinatorBinding, context: context)
    if !bindingErrors.isEmpty { return (bindingErrors, nil) }
    guard !reservationID.isEmpty else {
      return (["reservation ID is required for protected dispatch"], nil)
    }
    do {
      let harness = try ResourceCoordinator.loadTrustedHarness(
        harnessPath: harnessPath, context: context)
      guard let authorizationPath = absoluteURL(harness["run_authorization"]),
        let overlayPath = absoluteURL(harness["private_policy_overlay"]),
        safePrivateFile(ledgerPath, root: runRoot)
      else { return (["dispatch private bindings are unsafe or drifted"], nil) }
      if let boundLedger = absoluteURL(harness["run_ledger"]),
        boundLedger.resolvingSymlinksInPath() != ledgerPath.resolvingSymlinksInPath()
      {
        return (["coordination_required: dispatch ledger drifted from the trusted harness"], nil)
      }
      guard
        let authorization = try loadStablePrivateJSON(authorizationPath, root: runRoot)
          as? [String: Any],
        let overlay = try loadStablePrivateJSON(overlayPath, root: runRoot) as? [String: Any]
      else {
        return (["dispatch authorization or policy is not a JSON object"], nil)
      }
      guard
        jsonSame(
          harness["local_requirements"] ?? NSNull(), authorization["local_requirements"] ?? NSNull()
        )
      else { return (["trusted harness local requirements drifted from authorization"], nil) }
      let health = verifyHealthReport(
        reportPath: healthReportPath, harnessPath: harnessPath, runRoot: runRoot, policy: overlay,
        authorization: authorization, context: context, now: now)
      if !health.errors.isEmpty { return (health.errors, nil) }
      return try HarnessRuntime.withFileLock(at: ledgerPath) {
        let records = try loadLedger(ledgerPath)
        let lifecycle = ledgerContractErrors(
          records, coordinatorState: coordinatorState, context: context)
        if !lifecycle.isEmpty { return (lifecycle, nil) }
        let status = try ResourceCoordinator.fullStatus(statePath: coordinatorState)
        guard
          let authority = (status["run_authorities"] as? [String: Any])?[
            string(authorization["run_id"])] as? [String: Any]
        else { return (["coordination_required: dispatch run authority is unregistered"], nil) }
        let bindings = try ResourceCoordinator.ledgerBinding(
          ledgerPath, expectedRunID: string(authorization["run_id"]),
          expectedAuthorizationHash: authorizationHash(authorization))
        let ledgerIdentity = try fileIdentity(ledgerPath)
        for (key, value) in bindings where !jsonSame(authority[key], value) {
          return (["coordination_required: canonical ledger binding drifted"], nil)
        }
        let matching = records.filter {
          $0["record_type"] as? String == "grant_reservation"
            && ($0["payload"] as? [String: Any])?["reservation_id"] as? String == reservationID
        }
        guard matching.count == 1, let reservation = matching[0]["payload"] as? [String: Any] else {
          return (["protected dispatch requires one exact reservation"], nil)
        }
        if records.contains(where: {
          $0["record_type"] as? String == "grant_dispatch"
            && ($0["payload"] as? [String: Any])?["reservation_id"] as? String == reservationID
        }) {
          return (["protected dispatch reservation is already claimed"], nil)
        }
        if records.contains(where: {
          $0["record_type"] as? String == "external_write"
            && ($0["payload"] as? [String: Any])?["reservation_id"] as? String == reservationID
        }) {
          return (["protected dispatch reservation is already consumed"], nil)
        }
        guard
          let reservedAt = try? HarnessRuntime.parseTimestamp(string(matching[0]["recorded_at"]))
        else { return (["protected dispatch reservation time is invalid"], nil) }
        var errors =
          validateAuthorization(authorization, context: context)
          + validatePolicyOverlay(authorization, overlay: overlay)
        guard let request = try loadStablePrivateJSON(requestPath, root: runRoot) as? [String: Any]
        else { return (["dispatch request is not a JSON object"], nil) }
        if "sha256:" + (try canonicalSHA256(request)) != reservation["action_request_sha256"]
          as? String
        {
          errors.append("dispatch action request drifted from its reservation")
        }
        if authorizationHash(authorization) != reservation["authorization_hash"] as? String {
          errors.append("dispatch authorization hash drifted from its reservation")
        }
        if let expected = reservation["repository_observation_sha256"] as? String,
          !(reservation["repository_observation_sha256"] is NSNull),
          let root = absoluteURL(harness["authoritative_root"])
        {
          do {
            let observed = try observeRepository(
              root,
              expectedBaseSHA: string((authorization["repository"] as? [String: Any])?["base_sha"]))
            if "sha256:" + (try canonicalSHA256(observed)) != expected {
              errors.append("dispatch repository observation drifted from its reservation")
            }
          } catch {
            errors.append(
              "dispatch repository observation failed: \(String(describing: type(of: error)))")
          }
        }
        errors += dispatchSpecStateErrors(
          authorization: authorization, reservation: reservation, trustedHarness: harness)
        errors += dispatchAppleStateErrors(
          authorization: authorization, reservation: reservation, trustedHarness: harness,
          reservedAt: reservedAt, verifiedAt: now)
        guard let issued = try? HarnessRuntime.parseTimestamp(string(authorization["issued_at"])),
          let expires = try? HarnessRuntime.parseTimestamp(string(authorization["expires_at"])),
          issued <= now, now < expires
        else {
          errors.append("dispatch authorization is outside its active interval")
          return (Array(Set(errors)).sorted(), nil)
        }
        let approvals = records.filter {
          $0["record_type"] as? String == "approval"
            && $0["run_id"] as? String == authorization["run_id"] as? String
            && ($0["payload"] as? [String: Any])?["authorization_hash"] as? String == reservation[
              "authorization_hash"] as? String
        }
        if approvals.count != 1 {
          errors.append("dispatch requires one exact approval for the reservation")
        }
        let harnessDigest = try ResourceCoordinator.portableDocumentSHA256(harness)
        var expectedAuthority: [String: Any] = [
          "authorization_hash": reservation["authorization_hash"]!,
          "selected_writer": harness["selected_writer"]!, "harness_sha256": harnessDigest,
          "authorization_issued_at": authorization["issued_at"]!,
          "authorization_expires_at": authorization["expires_at"]!,
        ]
        for (key, value) in bindings { expectedAuthority[key] = value }
        if !jsonSame(authority, expectedAuthority) {
          errors.append("coordination_required: dispatch run authority drifted")
        }
        if !errors.isEmpty { return (Array(Set(errors)).sorted(), nil) }
        guard
          health.attestation?["report_sha256"] as? String == reservation["health_report_sha256"]
            as? String
        else { return (["dispatch health report drifted from its reservation"], nil) }
        let verified = ResourceCoordinator.verifyReceipt(
          statePath: coordinatorState,
          receipt: reservation["coordinator_receipt"] as? [String: Any] ?? [:], now: now)
        if !verified.errors.isEmpty || verified.receipt == nil {
          return (["coordination_required: " + verified.errors.joined(separator: ", ")], nil)
        }
        guard
          let leaseExpiry = try? HarnessRuntime.parseTimestamp(
            string(verified.receipt?["expires_at"]))
        else { return (["dispatch deadline cannot be derived"], nil) }
        let deadline = min(expires, leaseExpiry, now.addingTimeInterval(maximumDispatchWindow))
        guard deadline.timeIntervalSince(now) >= minimumDispatchWindow else {
          return (["dispatch window is too short; renew authority or lease"], nil)
        }
        let dispatchID = UUID().uuidString.lowercased()
        let payload: [String: Any] = [
          "dispatch_id": dispatchID, "reservation_id": reservationID,
          "coordinator_receipt": verified.receipt!,
          "health_report_sha256": reservation["health_report_sha256"]!,
          "dispatch_deadline": HarnessRuntime.timestamp(deadline),
        ]
        let record: [String: Any] = [
          "schema_version": "1.0.0", "run_id": authorization["run_id"]!,
          "sequence": (records.compactMap { intValue($0["sequence"]) }.max() ?? 0) + 1,
          "recorded_at": HarnessRuntime.timestamp(now), "record_type": "grant_dispatch",
          "payload": payload,
        ]
        guard
          try ResourceCoordinator.ledgerBinding(
            ledgerPath, expectedRunID: string(authorization["run_id"]),
            expectedAuthorizationHash: authorizationHash(authorization)
          ).allSatisfy({ jsonSame(bindings[$0.key], $0.value) })
        else { return (["coordination_required: canonical ledger binding drifted"], nil) }
        try appendRecord(record, ledgerPath, expectedIdentity: ledgerIdentity)
        guard
          try ResourceCoordinator.ledgerBinding(
            ledgerPath, expectedRunID: string(authorization["run_id"]),
            expectedAuthorizationHash: authorizationHash(authorization)
          ).allSatisfy({ jsonSame(bindings[$0.key], $0.value) })
        else { return (["coordination_required: canonical ledger binding drifted"], nil) }
        return (
          [],
          [
            "dispatch_id": dispatchID, "reservation_id": reservationID,
            "authorization_hash": reservation["authorization_hash"]!,
            "grant_id": reservation["grant_id"]!,
            "idempotency_key": reservation["idempotency_key"]!, "system": reservation["system"]!,
            "action": reservation["action"]!, "operation": reservation["operation"]!,
            "operation_input": reservation["operation_input"]!,
            "action_request_sha256": reservation["action_request_sha256"]!,
            "target": reservation["target"]!, "coordinator_receipt": verified.receipt!,
            "health_report_sha256": reservation["health_report_sha256"]!,
            "verified_at": record["recorded_at"]!,
            "dispatch_deadline": payload["dispatch_deadline"]!,
          ]
        )
      }
    } catch { return (["dispatch verification failed closed: \(String(describing: error))"], nil) }
  }

  private static func fileIdentity(_ path: URL) throws -> (dev_t, ino_t) {
    var value = stat()
    guard lstat(path.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1
    else { throw VerificationError.invalid("authorization ledger identity is unsafe") }
    return (value.st_dev, value.st_ino)
  }
  private static func appendRecord(
    _ record: [String: Any], _ path: URL, expectedIdentity: (dev_t, ino_t)
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
  private static func safePrivateFile(_ path: URL, root: URL) -> Bool {
    var info = stat()
    return path.path.hasPrefix("/") && lstat(path.path, &info) == 0
      && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
      && path.deletingLastPathComponent().resolvingSymlinksInPath()
        == root.resolvingSymlinksInPath()
  }
  private static func absoluteURL(_ value: Any?) -> URL? {
    guard let path = value as? String, path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path)
  }
  private static func string(_ value: Any?) -> String {
    value == nil || value is NSNull ? "" : ((value as? String) ?? String(describing: value!))
  }
  private static func jsonSame(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }
  private static func intValue(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !HarnessRuntime.isBoolean(number) else { return nil }
    let raw = number.stringValue
    guard let value = Int(raw), raw == String(value) || raw == "-0" else { return nil }
    return value
  }
}

public enum VerifyReservation {
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    try VerifyReservationCommand.run(arguments: arguments, context: context)
  }
}

public enum VerifyReservationCommand {
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    let options = try CLIOptions(arguments)
    guard let ledger = options.url("ledger"), let reservationID = options.value("reservation-id"),
      let runRoot = options.url("run-root"), let harnessURL = options.url("harness"),
      let state = options.url("coordinator-state"), let health = options.url("health-report"),
      let request = options.url("request")
    else {
      throw VerificationError.invalid(
        "verify-reservation requires ledger, reservation-id, run-root, harness, coordinator-state, health-report, and request"
      )
    }
    do {
      let harness = try ResourceCoordinator.loadTrustedHarness(
        harnessPath: harnessURL, context: context)
      let binding = harness["resource_coordinator"] as? [String: Any] ?? [:]
      let result = Authorization.verifyReservedAction(
        ledgerPath: ledger, reservationID: reservationID, runRoot: runRoot, coordinatorState: state,
        coordinatorBinding: binding, healthReportPath: health, harnessPath: harnessURL,
        requestPath: request, context: context)
      printJSON([
        "verified": result.errors.isEmpty, "errors": result.errors,
        "dispatch": (result.dispatch ?? NSNull()) as Any,
      ])
      return result.errors.isEmpty ? 0 : 2
    } catch {
      printJSON(["verified": false, "errors": [String(describing: error)], "dispatch": NSNull()])
      return 2
    }
  }
}
