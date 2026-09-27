import Foundation

/// Recovery of an expired lease: the evidence it requires, the recovery itself with an optional
/// replacement lease for the observer, and verification of a recovery confirmation.
extension ResourceCoordinator {
  static func validateRecoveryEvidence(
    _ evidence: [String: Any], receipt: [String: Any], now: Date
  ) throws {
    let quiescent = evidence["mode"] as? String == "quiescent_release"
    var expected: Set<String> = [
      "previous_receipt_id", "previous_fencing_token", "observer", "owner_liveness",
      "owner_tool_children", "dirty_state", "live_resource_revalidation",
    ]
    if quiescent { expected.insert("mode") }
    let ownerState = (evidence["owner_liveness"] as? [String: Any])?["state"] as? String
    let dirtyState = (evidence["dirty_state"] as? [String: Any])?["state"] as? String
    guard Set(evidence.keys) == expected,
      jsonEqual(evidence["previous_receipt_id"], receipt["receipt_id"]),
      jsonEqual(evidence["previous_fencing_token"], receipt["fencing_token"]),
      let observer = evidence["observer"] as? [String: Any],
      Set(observer.keys) == ["observer_run_id", "observer_actor", "method", "observed_at"],
      observer["method"] as? String == "bounded_read_only_host_probe"
    else { throw ResourceCoordinatorError("invalid_recovery_evidence") }
    let selfObserved = observer["observer_run_id"] as? String == receipt["owner_run_id"] as? String
    guard quiescent ? ownerState == (selfObserved ? "quiescent" : "completed") : !selfObserved,
      !quiescent
        || (["quiescent", "completed"].contains(ownerState ?? "")
          && ["clean", "preserved"].contains(dirtyState ?? ""))
    else { throw ResourceCoordinatorError("invalid_recovery_evidence") }
    _ = try string(observer["observer_run_id"], "observer_run_id")
    _ = try string(observer["observer_actor"], "observer_actor")
    let observerTime = try parse(observer["observed_at"])
    let expires = try parse(receipt["expires_at"])
    // Every observation is at most five minutes old and, for a quiescent release, no earlier
    // than the lease's expiry.
    func requireFresh(_ observed: Date) throws {
      guard observed <= now, now.timeIntervalSince(observed) <= 300,
        !quiescent || observed >= expires
      else {
        throw ResourceCoordinatorError("stale_recovery_evidence")
      }
    }
    try requireFresh(observerTime)
    let checks: [(String, String, Any)] = [
      ("owner_liveness", "state", quiescent ? ownerState! : "dead"),
      ("owner_tool_children", "state", quiescent ? "quiescent" : "dead"),
      ("dirty_state", "state", quiescent ? dirtyState! : "clean"),
      ("live_resource_revalidation", "passed", true),
    ]
    for (name, field, expectedValue) in checks {
      guard let item = evidence[name] as? [String: Any], jsonEqual(item[field], expectedValue),
        sha256String(item["digest"]), let raw = item["observed_at"] as? String
      else { throw ResourceCoordinatorError("invalid_recovery_evidence") }
      try requireFresh(parse(raw))
      let expectedKeys: Set<String> =
        name == "live_resource_revalidation"
        ? ["passed", "digest", "observed_at"] : ["state", "digest", "observed_at"]
      guard Set(item.keys) == expectedKeys else {
        throw ResourceCoordinatorError("invalid_recovery_evidence")
      }
    }
  }

  public static func validateRecoveryConfirmation(
    receipt supplied: [String: Any], evidence: [String: Any], confirmation: [String: Any],
    statePath: URL? = nil
  ) -> Bool {
    let fields: Set<String> = [
      "coordinator_instance_id", "recovery_id", "previous_receipt_id", "previous_fencing_token",
      "recovery_fencing_token", "recovered_at", "evidence_sha256", "replacement_receipt",
    ]
    guard Set(confirmation.keys) == fields,
      jsonEqual(confirmation["coordinator_instance_id"], supplied["coordinator_instance_id"]),
      jsonEqual(confirmation["previous_receipt_id"], supplied["receipt_id"]),
      jsonEqual(confirmation["previous_fencing_token"], supplied["fencing_token"]),
      let recoveryFence = integer(confirmation["recovery_fencing_token"]),
      let previousFence = integer(supplied["fencing_token"]), recoveryFence > previousFence,
      let recoveryID = confirmation["recovery_id"] as? String, !recoveryID.isEmpty,
      sha256String(confirmation["evidence_sha256"]),
      let recovered = try? parse(confirmation["recovered_at"]),
      (try? validateRecoveryEvidence(evidence, receipt: supplied, now: recovered)) != nil,
      confirmation["evidence_sha256"] as? String == (try? recoveryEvidenceSHA256(evidence))
    else { return false }
    let replacement = confirmation["replacement_receipt"]
    if evidence["mode"] as? String == "quiescent_release", !(replacement is NSNull) {
      return false
    }
    let validReplacement =
      replacement is NSNull || replacement == nil
      || ((replacement as? [String: Any])?["coordinator_instance_id"] as? String == supplied[
        "coordinator_instance_id"] as? String
        && integer((replacement as? [String: Any])?["fencing_token"]) ?? -1 > recoveryFence)
    guard validReplacement, let statePath else { return validReplacement }
    do {
      return try locked(statePath) { _, state in
        guard
          confirmation["coordinator_instance_id"] as? String == state["coordinator_instance_id"]
            as? String,
          let leases = state["leases"] as? [String: Any],
          let lease = leases.values.compactMap({ $0 as? [String: Any] }).first(where: {
            $0["receipt_id"] as? String == supplied["receipt_id"] as? String
          }), lease["status"] as? String == "recovered",
          jsonEqual(supplied, receipt(lease, in: state))
        else { return false }
        let replacementID =
          lease["replacement_lease_id"] is NSNull ? nil : lease["replacement_lease_id"] as? String
        let expectedReplacement: Any =
          replacementID.flatMap { leases[$0] as? [String: Any] }.map { receipt($0, in: state) }
          ?? NSNull()
        return lease["recovery_id"] as? String == recoveryID
          && integer(lease["recovery_fencing_token"]) == recoveryFence
          && lease["recovery_evidence_sha256"] as? String == confirmation["evidence_sha256"]
            as? String
          && lease["recovered_at"] as? String == confirmation["recovered_at"] as? String
          && jsonEqual(replacement, expectedReplacement)
      }
    } catch { return false }
  }

  public static func recover(
    statePath: URL, receipt supplied: [String: Any], evidence: [String: Any],
    runAuthority: [String: Any]?, observerAuthority: [String: Any]?,
    replacement: [String: Any]? = nil, replacementAuthority: [String: Any]? = nil,
    preview: Bool = false, now: Date = Date()
  ) throws -> [String: Any] {
    try locked(statePath) { path, state in
      try requireBootstrap(state)
      var lease = try leaseForReceipt(state: state, supplied: supplied)
      let quiescent = evidence["mode"] as? String == "quiescent_release"
      // Cleanup can use the archived owner's immutable authority already in state.
      // It grants no new work; the caller still needs a bound owner/observer below.
      let ownerAuthority =
        runAuthority
        ?? (quiescent
          ? registeredAuthority(state, lease["owner_run_id"] as! String) as? [String: Any] : nil)
      _ = try requireReceiptAuthority(state: state, lease: lease, authority: ownerAuthority)
      guard try parse(lease["expires_at"]) <= now else {
        throw ResourceCoordinatorError("recovery_not_yet_allowed")
      }
      if supportsActiveResolution(candidate: lease, activeLeases: active(state)) {
        throw ResourceCoordinatorError("dependent_lease_active")
      }
      try validateRecoveryEvidence(evidence, receipt: supplied, now: now)
      guard !quiescent || (replacement == nil && replacementAuthority == nil) else {
        throw ResourceCoordinatorError("quiescent_release_cannot_replace")
      }
      let observer = evidence["observer"] as! [String: Any]
      let observerRunID = observer["observer_run_id"] as! String
      let observerActor = observer["observer_actor"] as! String
      do {
        let selfCleanup = quiescent && observerRunID == lease["owner_run_id"] as? String
        _ = try authorityWindow(
          observerAuthority, ownerActor: observerActor, activeAt: selfCleanup ? nil : now)
      } catch { throw ResourceCoordinatorError("untrusted_authority") }
      guard let storedObserver = registeredAuthority(state, observerRunID),
        jsonEqual(storedObserver, observerAuthority)
      else {
        throw ResourceCoordinatorError(
          registeredAuthority(state, observerRunID) == nil
            ? "unregistered_run_authority" : "untrusted_authority")
      }
      let capacityBefore = capacityUsage(state)
      lease["status"] = "recovered"
      lease["recovered_at"] = stamp(now)
      lease["recovery_evidence"] = try safeJSON(evidence)
      let recoveryFence = (integer(state["next_fencing_token"]) ?? 0) + 1
      state["next_fencing_token"] = recoveryFence
      lease["recovery_id"] = UUID().uuidString.lowercased()
      lease["recovery_fencing_token"] = recoveryFence
      lease["recovery_evidence_sha256"] = try recoveryEvidenceSHA256(evidence)
      // The recovered lease leaves the active set before any replacement is checked against it.
      store(lease, in: &state)
      var newReceipt: [String: Any]?
      if let replacement {
        newReceipt = try acquireReplacement(
          replacement, authority: replacementAuthority, observerAuthority: observerAuthority,
          observerRunID: observerRunID, observerActor: observerActor,
          previousOwnerRunID: lease["owner_run_id"] as? String, state: &state, now: now)
      }
      lease["replacement_lease_id"] = newReceipt?["lease_id"] ?? NSNull()
      store(lease, in: &state)
      if preview {
        return [
          "preview": true, "mode": quiescent ? "quiescent_release" : "dead_owner_recovery",
          "receipt": supplied, "evidence_sha256": lease["recovery_evidence_sha256"]!,
          "capacity_before": capacityBefore, "capacity_after": capacityUsage(state),
          "replacement_requested": replacement != nil,
        ]
      }
      compactTerminalLeases(&state, now: now)
      try persist(state, to: path)
      return [
        "coordinator_instance_id": state["coordinator_instance_id"]!,
        "recovery_id": lease["recovery_id"]!, "previous_receipt_id": lease["receipt_id"]!,
        "previous_fencing_token": lease["fencing_token"]!, "recovery_fencing_token": recoveryFence,
        "recovered_at": lease["recovered_at"]!,
        "evidence_sha256": lease["recovery_evidence_sha256"]!,
        "replacement_receipt": newReceipt ?? NSNull(),
      ]
    }
  }

  /// Acquires the lease a dead-owner recovery hands to its observer, which must request it under
  /// its own registered authority, and returns its receipt.
  private static func acquireReplacement(
    _ replacement: [String: Any], authority: [String: Any]?, observerAuthority: [String: Any]?,
    observerRunID: String, observerActor: String, previousOwnerRunID: String?,
    state: inout [String: Any], now: Date
  ) throws -> [String: Any] {
    guard
      Set(replacement.keys) == [
        "resource", "descriptor", "owner_run_id", "owner_actor", "ttl_seconds",
      ], let resource = replacement["resource"] as? String,
      let descriptor = replacement["descriptor"] as? [String: Any],
      let runID = replacement["owner_run_id"] as? String,
      let actor = replacement["owner_actor"] as? String,
      let ttl = integer(replacement["ttl_seconds"])
    else { throw ResourceCoordinatorError("invalid_replacement") }
    let window: (Date, Date)
    do {
      window = try authorityWindow(authority, ownerActor: actor, activeAt: now)
    } catch { throw ResourceCoordinatorError("untrusted_authority") }
    guard runID != previousOwnerRunID, observerRunID == runID, observerActor == actor,
      jsonEqual(authority, observerAuthority), let stored = registeredAuthority(state, runID),
      jsonEqual(stored, authority)
    else {
      throw ResourceCoordinatorError(
        registeredAuthority(state, runID) == nil
          ? "unregistered_run_authority" : "untrusted_authority")
    }
    let lease = try newLease(
      state: &state, resource: resource, descriptor: descriptor, ownerRunID: runID,
      ownerActor: actor, ttlSeconds: ttl, authorizationExpiresAt: window.1, now: now)
    return receipt(lease, in: state)
  }
}
