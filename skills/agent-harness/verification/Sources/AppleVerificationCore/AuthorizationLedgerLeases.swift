import Foundation

extension Authorization {
  /// Replays one `lease` record: an acquire, heartbeat or release against the active set.
  static func recordLease(
    _ payload: [String: Any], currentRun: String?, recorded: Date?, coordinatorState: URL?,
    into state: inout LedgerReplayState
  ) {
    let resource = text(payload["resource"])
    let key = text(payload["resource_key"])
    let leaseKey = resource + "\0" + key
    state.errors += coordinatorReceiptErrors(
      runID: currentRun, leaseID: payload["lease_id"], owner: payload["owner"],
      resource: payload["resource"], resourceKey: payload["resource_key"],
      descriptor: payload["resource_descriptor"], receipt: payload["coordinator_receipt"],
      now: payload["action"] as? String == "release" ? nil : recorded)
    switch payload["action"] as? String {
    case "acquire":
      let protects = payload["protects"] as? [String] ?? []
      let signature = resource + "\0" + protects.joined(separator: "\0")
      let protectsRequired: Set<String> = [
        "xcode_project_mutation", "build_tuple", "simulator_or_device",
        "coresimulator_runtime_registry", "macos_gui_session",
      ]
      if protectsRequired.contains(resource) {
        if protects.isEmpty {
          state.errors.append("extension-scoped lease must declare protected workflow nodes")
        } else if protects.contains(where: { state.workflow.nodes[$0] == nil }) {
          state.errors.append("extension-scoped lease protects an unknown workflow node")
        } else if !Set(protects).isDisjoint(with: state.passedNodes) {
          state.errors.append(
            "extension-scoped lease was acquired after its protected workflow node")
        }
      }
      let approvedWriters = Set(
        state.authorizations.values.compactMap { $0["selected_writer"] as? String })
      if !approvedWriters.isEmpty
        && (approvedWriters.count != 1 || !approvedWriters.contains(text(payload["owner"])))
      {
        state.errors.append("lease owner is not the approved selected writer")
      }
      let approvalIDs = Set(state.authorizations.values.compactMap { $0["approval_id"] as? String })
      if approvalIDs.count != 1 || !approvalIDs.contains(text(payload["approval_id"])) {
        state.errors.append("lease approval binding does not match the run authorization")
      }
      let fingerprints = Set(
        state.authorizations.values.compactMap { $0["repository_fingerprint"] as? String })
      if fingerprints.count == 1,
        let descriptor = payload["resource_descriptor"] as? [String: Any],
        descriptor["repository_fingerprint"] != nil,
        !same(descriptor["repository_fingerprint"], fingerprints.first!)
      {
        state.errors.append("lease repository fingerprint drifted from run authorization")
      }
      let conflicts = state.active.values.contains { other in
        guard let left = payload["resource_descriptor"] as? [String: Any],
          let right = other["resource_descriptor"] as? [String: Any]
        else { return true }
        let conflict = ResourceCoordinator.descriptorsConflict(
          resource: resource, descriptor: left, otherResource: text(other["resource"]),
          other: right)
        return conflict
          && !ResourceCoordinator.sameOwnerNestedCompatible(
            resource: resource, otherResource: text(other["resource"]),
            ownerRunID: text(currentRun), ownerActor: text(payload["owner"]),
            otherOwnerRunID: text(currentRun), otherOwnerActor: text(other["owner"]),
            descriptor: left, otherDescriptor: right)
      }
      let receipt = payload["coordinator_receipt"] as? [String: Any] ?? [:]
      let matchingPlans = state.resourcePlans.filter { _, plan in
        text(plan["resource"]) == resource && text(plan["resource_key"]) == key
          && same(plan["descriptor_sha256"], receipt["descriptor_sha256"])
          && same(plan["resource_descriptor"], payload["resource_descriptor"])
          && same(plan["owner_actor"], payload["owner"])
          && same(plan["protects"], payload["protects"])
      }
      if matchingPlans.count == 1 {
        let id = matchingPlans.first!.key
        if state.planBindings[id] != nil {
          state.errors.append("authorization resource plan cannot bind more than one lease")
        } else {
          state.planBindings[id] = text(payload["lease_id"])
        }
      } else if matchingPlans.count > 1 {
        state.errors.append("lease matches multiple authorization resource plans")
      } else if state.resourcePlans.values.contains(where: {
        text($0["resource"]) == resource && text($0["resource_key"]) == key
      }) {
        state.errors.append("lease drifted from its authorization resource plan")
      } else if !state.authorizations.isEmpty && !protects.isEmpty
        && !state.staticLeaseSignatures.contains(signature)
      {
        state.errors.append("dynamic workflow lease lacks an exact authorized resource plan")
      }
      if !same(payload["acquired_at"], receipt["acquired_at"])
        || !same(payload["expires_at"], receipt["expires_at"])
      {
        state.errors.append("lease acquisition times drifted from its coordinator receipt")
      }
      if let acquired = try? HarnessRuntime.parseTimestamp(text(payload["acquired_at"])),
        let expiry = try? HarnessRuntime.parseTimestamp(text(payload["expires_at"])),
        expiry > acquired, recorded == nil || acquired <= recorded!
      {
      } else {
        state.errors.append("lease acquisition time range is invalid")
      }
      if state.active[leaseKey] != nil || conflicts {
        state.errors.append("ledger lease acquire conflicts with an active lease")
      } else {
        state.active[leaseKey] = payload
      }
    case "heartbeat":
      guard var current = state.active[leaseKey], same(current["lease_id"], payload["lease_id"]),
        same(current["owner"], payload["owner"])
      else {
        state.errors.append("lease heartbeat does not match its active lease")
        return
      }
      guard same(current["protects"], payload["protects"]),
        receiptLineage(
          current["coordinator_receipt"], payload["coordinator_receipt"],
          extensionRequired: true),
        let heartbeat = try? HarnessRuntime.parseTimestamp(text(payload["heartbeat_at"])),
        let old = try? HarnessRuntime.parseTimestamp(text(current["expires_at"])),
        heartbeat < old
      else {
        state.errors.append(
          "lease heartbeat must be timely, extend expiry, and preserve its binding")
        return
      }
      current["expires_at"] = payload["expires_at"]
      current["coordinator_receipt"] = payload["coordinator_receipt"]
      state.active[leaseKey] = current
    case "release":
      guard let releasedAt = try? HarnessRuntime.parseTimestamp(text(payload["released_at"])),
        let recorded, releasedAt <= recorded
      else {
        state.errors.append("lease release record precedes coordinator transition")
        return
      }
      guard let current = state.active[leaseKey], same(current["lease_id"], payload["lease_id"]),
        same(current["owner"], payload["owner"]),
        same(current["resource_descriptor"], payload["resource_descriptor"]),
        receiptLineage(current["coordinator_receipt"], payload["coordinator_receipt"])
      else {
        state.errors.append("ledger lease release does not match an active lease")
        return
      }
      let unmet = Set(current["protects"] as? [String] ?? []).subtracting(state.passedNodes)
      if !unmet.isEmpty {
        state.errors.append(
          "lease release preceded protected workflow nodes: \(unmet.sorted().joined(separator: ", "))"
        )
        return
      }
      let recovery = releaseRecoveryErrors(
        current: current, release: payload, coordinatorState: coordinatorState)
      state.errors += recovery
      if recovery.isEmpty {
        for (id, leaseID) in state.planBindings where leaseID == text(payload["lease_id"]) {
          state.releasedPlans.insert(id)
        }
        state.releasedLeases[resource + "\0" + key + "\0" + text(payload["lease_id"])] = payload
        state.active.removeValue(forKey: leaseKey)
      }
    default: state.errors.append("ledger lease action is invalid")
    }
  }

  /// Replays one `grant_reservation` record against its authorization grant and active lease.
  static func recordGrantReservation(
    _ payload: [String: Any], recorded: Date?, into state: inout LedgerReplayState
  ) {
    let digest = text(payload["authorization_hash"])
    let id = text(payload["reservation_id"])
    let authorization = state.authorizations[digest]
    if id.isEmpty || state.reservations[id] != nil {
      state.errors.append("grant reservation ID must be unique")
    }
    if let input = payload["operation_input"],
      (try? canonicalSHA256(input)) != payload["constraint_sha256"] as? String
    {
      state.errors.append("grant reservation operation input drifted from its constraint")
    }
    if !hash(payload["health_report_sha256"]) {
      state.errors.append("grant reservation must bind its evaluated health report")
    }
    if authorization == nil {
      state.errors.append("grant reservation must follow its run authorization")
    } else {
      if payload["writer_actor"] as? String != authorization?["selected_writer"] as? String
        || payload["lease_owner"] as? String != authorization?["selected_writer"] as? String
      {
        state.errors.append("grant reservation writer drifted from authorization")
      }
      let candidates = (authorization!["action_grants"] as? [[String: Any]] ?? []).filter {
        grant in
        [
          "grant_id", "idempotency_key", "system", "action", "operation", "operation_input",
          "constraint_sha256", "resource_key", "phase",
        ].allSatisfy { same(grant[$0], payload[$0]) }
      }
      if candidates.count != 1 {
        state.errors.append("grant reservation does not match one exact grant")
      } else {
        var target = candidates[0]["target"]
        if let source = candidates[0]["target_from_grant_id"] as? String {
          target = state.producedTargets[digest + "\0" + source]
        }
        if target == nil || !same(target, payload["target"]) {
          state.errors.append("grant reservation target is unavailable or drifted")
        }
      }
      if let issued = try? HarnessRuntime.parseTimestamp(text(authorization!["issued_at"])),
        let expiry = try? HarnessRuntime.parseTimestamp(text(authorization!["expires_at"])),
        let recorded, issued <= recorded, recorded < expiry
      {
      } else {
        state.errors.append("grant reservation occurred outside authorization time bounds")
      }
    }
    let leaseKey = text(payload["resource"]) + "\0" + text(payload["resource_key"])
    let lease = state.active[leaseKey]
    if lease == nil || !same(lease?["lease_id"], payload["lease_id"])
      || !same(lease?["owner"], payload["lease_owner"])
      || !(lease?["allowed_actions"] as? [String] ?? []).contains(text(payload["action"]))
      || !same(lease?["resource_descriptor"], payload["resource_descriptor"])
      || !same(lease?["coordinator_receipt"], payload["coordinator_receipt"])
      || text(payload["resource"]) != expectedLeaseResource(payload["action"])
    {
      state.errors.append("grant reservation lacks its exact active lease")
    } else {
      if let recorded,
        let expiry = try? HarnessRuntime.parseTimestamp(text(lease?["expires_at"])),
        recorded < expiry
      {
      } else {
        state.errors.append("grant reservation cannot use an expired lease")
      }
      if !same(lease?["approval_id"], authorization?["approval_id"]) {
        state.errors.append("grant reservation lease is not bound to the authorization")
      }
    }
    let grantKey = digest + "\0" + text(payload["grant_id"])
    let idempotency = digest + "\0" + text(payload["idempotency_key"])
    if !state.usedGrants.insert(grantKey).inserted || !state.usedKeys.insert(idempotency).inserted {
      state.errors.append("grant or idempotency key is already reserved")
    }
    if !id.isEmpty { state.reservations[id] = payload }
  }

  /// Replays one `grant_dispatch` claim of an unclaimed reservation.
  static func recordGrantDispatch(
    _ payload: [String: Any], recorded: Date?, into state: inout LedgerReplayState
  ) {
    let reservationID = text(payload["reservation_id"])
    let dispatchID = text(payload["dispatch_id"])
    let reservation = state.reservations[reservationID]
    if reservation == nil || state.claimed.contains(reservationID) || dispatchID.isEmpty
      || state.dispatches[dispatchID] != nil
    {
      state.errors.append("grant dispatch requires one unclaimed exact reservation")
    } else if !receiptLineage(
      reservation?["coordinator_receipt"], payload["coordinator_receipt"])
      || !same(reservation?["health_report_sha256"], payload["health_report_sha256"])
    {
      state.errors.append("grant dispatch drifted from its reservation fence or health report")
    } else {
      let leaseKey = text(reservation?["resource"]) + "\0" + text(reservation?["resource_key"])
      let lease = state.active[leaseKey]
      if lease == nil || !same(lease?["lease_id"], reservation?["lease_id"])
        || !same(lease?["owner"], reservation?["lease_owner"])
        || !same(lease?["coordinator_receipt"], payload["coordinator_receipt"])
      {
        state.errors.append("grant dispatch requires its exact active reservation lease")
      }
      let authorization = state.authorizations[text(reservation?["authorization_hash"])]
      if let recorded,
        let deadline = try? HarnessRuntime.parseTimestamp(text(payload["dispatch_deadline"])),
        let leaseExpiry = try? HarnessRuntime.parseTimestamp(
          text((payload["coordinator_receipt"] as? [String: Any])?["expires_at"])),
        let authorizationExpiry = try? HarnessRuntime.parseTimestamp(
          text(authorization?["expires_at"])), deadline > recorded,
        deadline.timeIntervalSince(recorded) <= maximumDispatchWindow, deadline <= leaseExpiry,
        deadline <= authorizationExpiry
      {
      } else {
        state.errors.append(
          "grant dispatch deadline is invalid or exceeds lease/authorization authority")
      }
    }
    state.claimed.insert(reservationID)
    if !dispatchID.isEmpty { state.dispatches[dispatchID] = payload }
  }

  /// Replays one `external_write` that consumes its reservation and dispatch claim.
  static func recordExternalWrite(
    _ payload: [String: Any], recorded: Date?, into state: inout LedgerReplayState
  ) {
    let reservationID = text(payload["reservation_id"])
    let dispatchID = text(payload["dispatch_id"])
    let reservation = state.reservations[reservationID]
    let dispatch = state.dispatches[dispatchID]
    if reservation == nil || !state.consumedReservations.insert(reservationID).inserted {
      state.errors.append("external write requires one unconsumed exact reservation")
    } else {
      for field in [
        "authorization_hash", "grant_id", "idempotency_key", "system", "action", "operation",
        "operation_input", "constraint_sha256", "resource_key", "phase", "lease_id",
        "lease_owner", "resource", "resource_descriptor", "target", "spec_checkpoint_sha256",
        "apple_observation_sha256", "writer_actor", "health_report_sha256",
      ] where !same(reservation?[field], payload[field]) {
        state.errors.append("external write drifted from its reservation")
        break
      }
      if !receiptLineage(reservation?["coordinator_receipt"], payload["coordinator_receipt"]) {
        state.errors.append("external write drifted from its reservation receipt lineage")
      }
    }
    if dispatch == nil || !state.consumedDispatches.insert(dispatchID).inserted
      || !same(dispatch?["reservation_id"], reservationID)
      || !receiptLineage(dispatch?["coordinator_receipt"], payload["coordinator_receipt"])
    {
      state.errors.append("external write requires one unconsumed matching dispatch claim")
    }
    if let recorded,
      let deadline = try? HarnessRuntime.parseTimestamp(text(dispatch?["dispatch_deadline"])),
      recorded < deadline
    {
    } else {
      state.errors.append("external write occurred outside its dispatch deadline")
    }
    let leaseKey = text(payload["resource"]) + "\0" + text(payload["resource_key"])
    let lease = state.active[leaseKey]
    if lease == nil || !same(lease?["lease_id"], payload["lease_id"])
      || !same(lease?["owner"], payload["lease_owner"])
      || !(lease?["allowed_actions"] as? [String] ?? []).contains(text(payload["action"]))
      || !same(lease?["resource_descriptor"], payload["resource_descriptor"])
      || !same(lease?["coordinator_receipt"], payload["coordinator_receipt"])
    {
      state.errors.append("external write requires its exact active reservation lease")
    }
    let digest = text(payload["authorization_hash"])
    let authorization = state.authorizations[digest]
    if authorization == nil {
      state.errors.append("external write must follow its run authorization")
    } else if let recorded,
      let issued = try? HarnessRuntime.parseTimestamp(text(authorization?["issued_at"])),
      let expiry = try? HarnessRuntime.parseTimestamp(text(authorization?["expires_at"])),
      issued <= recorded, recorded < expiry
    {
    } else {
      state.errors.append("external write occurred outside authorization time bounds")
    }
    if let recorded,
      let leaseExpiry = try? HarnessRuntime.parseTimestamp(text(lease?["expires_at"])),
      recorded < leaseExpiry
    {
    } else {
      state.errors.append("external write cannot use an expired lease")
    }
    if payload["outcome"] as? String == "succeeded" {
      state.successfulOperations.insert(
        text(payload["phase"]) + "\0" + text(payload["action"]) + "\0"
          + text(payload["operation"]))
      if let grant = (authorization?["action_grants"] as? [[String: Any]])?.first(where: {
        $0["grant_id"] as? String == payload["grant_id"] as? String
      }), let kind = grant["produces_target_kind"], !(kind is NSNull) {
        if validProducedTarget(
          kind: kind, target: payload["output_target"],
          repository: stringRepository(from: grant["target"]))
        {
          state.producedTargets[digest + "\0" + text(payload["grant_id"])] = text(
            payload["output_target"])
        } else {
          state.errors.append("external write produced an invalid GitHub target")
        }
      }
    }
  }

  public static func activeLeases(_ records: [[String: Any]], coordinatorState: URL? = nil) -> (
    leases: [String: [String: Any]], errors: [String]
  ) {
    var active: [String: [String: Any]] = [:]
    var errors: [String] = []
    for record in records where record["record_type"] as? String == "lease" {
      guard let payload = record["payload"] as? [String: Any] else { continue }
      let key = text(payload["resource"]) + "\0" + text(payload["resource_key"])
      if payload["action"] as? String == "acquire" {
        if active[key] != nil {
          errors.append("ledger contains overlapping lease acquisitions")
        } else {
          active[key] = payload
        }
      } else if payload["action"] as? String == "heartbeat" {
        guard var value = active[key], same(value["lease_id"], payload["lease_id"]),
          receiptLineage(
            value["coordinator_receipt"], payload["coordinator_receipt"], extensionRequired: true)
        else {
          errors.append("ledger lease heartbeat does not match an active lease")
          continue
        }
        value["expires_at"] = payload["expires_at"]
        value["coordinator_receipt"] = payload["coordinator_receipt"]
        active[key] = value
      } else if payload["action"] as? String == "release" {
        guard let value = active[key], same(value["lease_id"], payload["lease_id"]),
          same(value["owner"], payload["owner"])
        else {
          errors.append("ledger lease release does not match an active lease")
          continue
        }
        active.removeValue(forKey: key)
      }
    }
    return (active, errors)
  }

  private static func coordinatorReceiptErrors(
    runID: Any?, leaseID: Any?, owner: Any?, resource: Any?, resourceKey: Any?, descriptor: Any?,
    receipt: Any?, now: Date?
  ) -> [String] {
    guard let receipt = receipt as? [String: Any], Set(receipt.keys) == coordinatorReceiptFields
    else { return ["lease lacks an exact coordinator receipt"] }
    var errors: [String] = []
    if !same(receipt["owner_run_id"], runID) || !same(receipt["lease_id"], leaseID)
      || !same(receipt["owner_actor"], owner) || !same(receipt["resource"], resource)
      || !same(receipt["resource_key"], resourceKey)
    {
      errors.append("lease coordinator receipt identity drifted")
    }
    if let descriptor = descriptor as? [String: Any], let resource = resource as? String {
      if let normalized = try? ResourceCoordinator.normalizeDescriptor(
        resource: resource, descriptor: descriptor),
        let digest = try? ResourceCoordinator.descriptorSHA256(
          resource: resource, descriptor: normalized),
        let key = try? ResourceCoordinator.canonicalResourceKey(
          resource: resource, descriptor: normalized)
      {
        if !same(descriptor, normalized) {
          errors.append("resource lease descriptor is not canonical")
        }
        if receipt["descriptor_sha256"] as? String != digest || resourceKey as? String != key {
          errors.append("lease coordinator descriptor digest or key drifted")
        }
      } else {
        errors.append("resource lease descriptor is invalid")
      }
    }
    if let now, let expiry = try? HarnessRuntime.parseTimestamp(text(receipt["expires_at"])),
      now >= expiry
    {
      errors.append("lease coordinator receipt is expired")
    }
    return errors
  }

  private static func receiptLineage(_ lhs: Any?, _ rhs: Any?, extensionRequired: Bool = false)
    -> Bool
  {
    guard let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any],
      Set(lhs.keys) == coordinatorReceiptFields, Set(rhs.keys) == coordinatorReceiptFields
    else { return false }
    for key in coordinatorReceiptFields.subtracting(["expires_at"]) where !same(lhs[key], rhs[key])
    { return false }
    guard let left = try? HarnessRuntime.parseTimestamp(text(lhs["expires_at"])),
      let right = try? HarnessRuntime.parseTimestamp(text(rhs["expires_at"]))
    else { return false }
    return extensionRequired ? right > left : right >= left
  }

  private static func releaseRecoveryErrors(
    current: [String: Any], release: [String: Any], coordinatorState: URL?
  ) -> [String] {
    guard let released = try? HarnessRuntime.parseTimestamp(text(release["released_at"])),
      let expires = try? HarnessRuntime.parseTimestamp(text(current["expires_at"])),
      let receipt = current["coordinator_receipt"] as? [String: Any]
    else { return ["lease release or expiry timestamp is invalid"] }
    if released < expires {
      if !(release["recovery_evidence"] is NSNull) && release["recovery_evidence"] != nil {
        return ["unexpired lease release cannot claim coordinator recovery"]
      }
      guard let confirmation = release["coordinator_release_confirmation"] as? [String: Any],
        ResourceCoordinator.validateReleaseConfirmation(
          receipt: receipt, confirmation: confirmation, statePath: coordinatorState),
        confirmation["released_at"] as? String == release["released_at"] as? String
      else { return ["lease release confirmation is invalid or not live"] }
      return []
    }
    if !(release["coordinator_release_confirmation"] is NSNull)
      && release["coordinator_release_confirmation"] != nil
    {
      return ["expired lease recovery cannot carry a normal release confirmation"]
    }
    guard let evidence = release["recovery_evidence"] as? [String: Any],
      let confirmation = release["recovery_confirmation"] as? [String: Any],
      ResourceCoordinator.validateRecoveryConfirmation(
        receipt: receipt, evidence: evidence, confirmation: confirmation,
        statePath: coordinatorState),
      same(confirmation["recovered_at"], release["released_at"])
    else { return ["expired lease release requires valid coordinator recovery evidence"] }
    return []
  }

  private static func stringRepository(from value: Any?) -> String? {
    guard let value = value as? String, let part = value.split(separator: ":", maxSplits: 1).first,
      !part.isEmpty
    else { return nil }
    return String(part)
  }
}
