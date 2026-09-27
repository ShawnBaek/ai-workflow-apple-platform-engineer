import Foundation

/// Lease operations: run registration, acquisition, receipt verification, heartbeat and release.
/// Recovery of an expired lease lives in `ResourceCoordinatorRecovery.swift`.
extension ResourceCoordinator {
  /// Adds an active lease to `state` after the same overlap, support and capacity rules `load`
  /// enforces on stored leases.
  static func newLease(
    state: inout [String: Any], resource: String, descriptor: [String: Any], ownerRunID: String,
    ownerActor: String, ttlSeconds: Int, admission requestedAdmission: [String: Any]? = nil,
    authorizationExpiresAt: Date, now: Date
  ) throws -> [String: Any] {
    guard !ownerRunID.isEmpty, !ownerActor.isEmpty else {
      throw ResourceCoordinatorError("invalid_owner")
    }
    try requireTTL(ttlSeconds)
    let normalized = try normalizeDescriptor(resource: resource, descriptor: descriptor)
    let admission = try normalizedAdmission(
      resource: resource, descriptor: normalized, requested: requestedAdmission)
    if [simulator, coreSimulator, macOSGUI].contains(resource),
      normalized["coordinator_instance_id"] as? String != state["coordinator_instance_id"]
        as? String
    {
      throw ResourceCoordinatorError("coordinator_instance_mismatch")
    }
    let activeLeases = active(state)
    if let conflict = activeLeases.first(where: {
      overlaps(
        resource: resource, descriptor: normalized, ownerRunID: ownerRunID,
        ownerActor: ownerActor, with: $0)
    }) {
      throw ResourceCoordinatorError("resource_conflict", conflict["lease_id"] as? String ?? "")
    }
    if resource == buildTuple,
      let missing = missingResolutionSupport(
        ownerRunID: ownerRunID, ownerActor: ownerActor, build: normalized,
        activeLeases: activeLeases)
    {
      throw ResourceCoordinatorError(missing)
    }
    let policy = try validateHostPolicy(state["host_policy"])
    if let dimension = exceededCapacity(capacityUsage(state), adding: admission, policy: policy) {
      throw ResourceCoordinatorError("capacity_exceeded", dimension)
    }
    let expires = now.addingTimeInterval(TimeInterval(ttlSeconds))
    guard expires <= authorizationExpiresAt else {
      throw ResourceCoordinatorError("authorization_window_too_short")
    }
    let fence = (integer(state["next_fencing_token"]) ?? 0) + 1
    state["next_fencing_token"] = fence
    let lease: [String: Any] = [
      "receipt_id": UUID().uuidString.lowercased(), "lease_id": UUID().uuidString.lowercased(),
      "owner_run_id": ownerRunID, "owner_actor": ownerActor, "resource": resource,
      "descriptor": normalized, "descriptor_sha256": try digest(normalized),
      "admission": admission, "fencing_token": fence, "acquired_at": stamp(now),
      "expires_at": stamp(expires), "status": "active",
    ]
    store(lease, in: &state)
    return lease
  }

  public static func registerRunAuthority(
    statePath: URL, runID: String, runAuthority: [String: Any], now: Date = Date()
  ) throws -> [String: Any] {
    guard !runID.isEmpty else { throw ResourceCoordinatorError("invalid_owner") }
    _ = try authorityWindow(runAuthority, activeAt: now)
    return try locked(statePath) { path, state in
      try requireBootstrap(state)
      var authorities = state["run_authorities"] as! [String: Any]
      let existing = authorities[runID]
      if existing == nil {
        authorities[runID] = runAuthority
        state["run_authorities"] = authorities
        try persist(state, to: path)
      } else if !jsonEqual(existing, runAuthority) {
        throw ResourceCoordinatorError("untrusted_authority", "run authority is immutable")
      }
      return [
        "run_id": runID, "registered": existing == nil,
        "authorization_hash": runAuthority["authorization_hash"]!,
        "ledger_identity_sha256": runAuthority["ledger_identity_sha256"]!,
      ]
    }
  }

  public static func acquire(
    statePath: URL, request: [String: Any]? = nil, resource: String? = nil,
    descriptor: [String: Any]? = nil, ownerRunID: String? = nil, ownerActor: String? = nil,
    ttlSeconds: Int? = nil, admission: [String: Any]? = nil, now: Date = Date(),
    runAuthority: [String: Any]? = nil
  ) throws -> [String: Any] {
    var resource = resource
    var descriptor = descriptor
    var ownerRunID = ownerRunID
    var ownerActor = ownerActor
    var ttlSeconds = ttlSeconds
    var admission = admission
    if let request {
      guard
        Set(request.keys).isSubset(of: [
          "resource", "descriptor", "owner_run_id", "owner_actor", "run_id", "actor", "ttl_seconds",
          "admission",
        ])
      else { throw ResourceCoordinatorError("invalid_request") }
      resource = request["resource"] as? String ?? resource
      descriptor = request["descriptor"] as? [String: Any] ?? descriptor
      ownerRunID = request["owner_run_id"] as? String ?? request["run_id"] as? String ?? ownerRunID
      ownerActor = request["owner_actor"] as? String ?? request["actor"] as? String ?? ownerActor
      ttlSeconds = integer(request["ttl_seconds"]) ?? ttlSeconds
      admission = request["admission"] as? [String: Any] ?? admission
    }
    guard let resource, let descriptor, let ownerRunID, let ownerActor, let ttlSeconds else {
      throw ResourceCoordinatorError("invalid_request")
    }
    return try locked(statePath) { path, state in
      try requireBootstrap(state)
      let window = try authorityWindow(runAuthority, ownerActor: ownerActor, activeAt: now)
      guard let existing = registeredAuthority(state, ownerRunID) else {
        throw ResourceCoordinatorError("unregistered_run_authority")
      }
      guard jsonEqual(existing, runAuthority) else {
        throw ResourceCoordinatorError("writer_mismatch")
      }
      let lease = try newLease(
        state: &state, resource: resource, descriptor: descriptor, ownerRunID: ownerRunID,
        ownerActor: ownerActor, ttlSeconds: ttlSeconds, admission: admission,
        authorizationExpiresAt: window.1, now: now)
      compactTerminalLeases(&state, now: now)
      try persist(state, to: path)
      return receipt(lease, in: state)
    }
  }

  /// The active lease a well-formed receipt names, before its other fields are compared.
  private static func activeLease(
    named supplied: [String: Any], in state: [String: Any]
  ) throws -> [String: Any] {
    guard Set(supplied.keys) == receiptFields else {
      throw ResourceCoordinatorError("invalid_receipt")
    }
    guard let id = supplied["lease_id"] as? String,
      let lease = (state["leases"] as? [String: Any])?[id] as? [String: Any],
      lease["status"] as? String == "active"
    else { throw ResourceCoordinatorError("stale_receipt") }
    return lease
  }

  /// The active lease whose current receipt is exactly `supplied`.
  static func leaseForReceipt(state: [String: Any], supplied: [String: Any]) throws
    -> [String: Any]
  {
    let lease = try activeLease(named: supplied, in: state)
    guard jsonEqual(supplied, receipt(lease, in: state)) else {
      throw ResourceCoordinatorError("stale_receipt")
    }
    return lease
  }

  public static func verify(statePath: URL, receipt supplied: [String: Any], now: Date = Date())
    throws -> [String: Any]
  {
    try locked(statePath) { _, state in
      let lease = try leaseForReceipt(state: state, supplied: supplied)
      guard try parse(lease["expires_at"]) > now else {
        throw ResourceCoordinatorError("expired_requires_recover")
      }
      return receipt(lease, in: state)
    }
  }

  public static func verifyReceipt(
    statePath: URL, receipt supplied: [String: Any], now: Date = Date()
  ) -> (errors: [String], receipt: [String: Any]?) {
    do {
      return try locked(statePath) { _, state in
        let lease = try activeLease(named: supplied, in: state)
        let current = receipt(lease, in: state)
        for field in receiptFields.subtracting(["expires_at"])
        where !jsonEqual(supplied[field], current[field]) {
          throw ResourceCoordinatorError("stale_receipt")
        }
        guard try parse(supplied["expires_at"]) <= parse(current["expires_at"]) else {
          throw ResourceCoordinatorError("stale_receipt")
        }
        guard try parse(current["expires_at"]) > now else {
          throw ResourceCoordinatorError("expired_requires_recover")
        }
        return ([], current)
      }
    } catch let error as ResourceCoordinatorError { return ([error.code], nil) } catch {
      return (["invalid_state"], nil)
    }
  }

  static func requireReceiptAuthority(
    state: [String: Any], lease: [String: Any], authority: [String: Any]?
  ) throws -> (Date, Date) {
    let window = try authorityWindow(authority, ownerActor: lease["owner_actor"] as? String)
    guard jsonEqual(registeredAuthority(state, lease["owner_run_id"] as! String), authority) else {
      throw ResourceCoordinatorError("untrusted_authority")
    }
    return window
  }

  public static func heartbeat(
    statePath: URL, receipt supplied: [String: Any], ttlSeconds: Int, runAuthority: [String: Any]?,
    now: Date = Date()
  ) throws -> [String: Any] {
    try requireTTL(ttlSeconds)
    return try locked(statePath) { path, state in
      var lease = try leaseForReceipt(state: state, supplied: supplied)
      let window = try requireReceiptAuthority(state: state, lease: lease, authority: runAuthority)
      guard now < window.1 else { throw ResourceCoordinatorError("authorization_inactive") }
      let old = try parse(lease["expires_at"])
      guard old > now else { throw ResourceCoordinatorError("expired_requires_recover") }
      // Compare what is persisted: stamps round to the nearest millisecond.
      let next = stamp(now.addingTimeInterval(TimeInterval(ttlSeconds)))
      guard try parse(next) > old else { throw ResourceCoordinatorError("heartbeat_must_extend") }
      guard try parse(next) <= window.1 else {
        throw ResourceCoordinatorError("authorization_window_too_short")
      }
      lease["expires_at"] = next
      store(lease, in: &state)
      compactTerminalLeases(&state, now: now)
      try persist(state, to: path)
      return receipt(lease, in: state)
    }
  }

  public static func release(
    statePath: URL, receipt supplied: [String: Any], runAuthority: [String: Any]?,
    now: Date = Date()
  ) throws -> [String: Any] {
    try locked(statePath) { path, state in
      var lease = try leaseForReceipt(state: state, supplied: supplied)
      _ = try requireReceiptAuthority(state: state, lease: lease, authority: runAuthority)
      if supportsActiveResolution(candidate: lease, activeLeases: active(state)) {
        throw ResourceCoordinatorError("dependent_lease_active")
      }
      // Stamps round to the nearest millisecond, so compare the persisted instant: a release in
      // the last half millisecond would otherwise store released_at == expires_at, which every
      // later load rejects as invalid state.
      let releasedAt = stamp(now)
      guard try parse(lease["expires_at"]) > parse(releasedAt) else {
        throw ResourceCoordinatorError("expired_requires_recover")
      }
      lease["status"] = "released"
      lease["release_id"] = UUID().uuidString.lowercased()
      lease["released_at"] = releasedAt
      store(lease, in: &state)
      compactTerminalLeases(&state, now: now)
      try persist(state, to: path)
      return [
        "coordinator_instance_id": state["coordinator_instance_id"]!,
        "release_id": lease["release_id"]!, "receipt_id": lease["receipt_id"]!,
        "lease_id": lease["lease_id"]!, "fencing_token": lease["fencing_token"]!,
        "released_at": lease["released_at"]!,
      ]
    }
  }

  public static func validateReleaseConfirmation(
    receipt supplied: [String: Any], confirmation: [String: Any], statePath: URL? = nil
  ) -> Bool {
    guard Set(supplied.keys) == receiptFields, Set(confirmation.keys) == releaseFields,
      ["coordinator_instance_id", "receipt_id", "lease_id", "fencing_token"].allSatisfy({
        jsonEqual(confirmation[$0], supplied[$0])
      }), let id = confirmation["release_id"] as? String, !id.isEmpty,
      let acquired = try? parse(supplied["acquired_at"]),
      let expires = try? parse(supplied["expires_at"]),
      let released = try? parse(confirmation["released_at"]), acquired <= released,
      released < expires
    else { return false }
    guard let statePath else { return true }
    do {
      return try locked(statePath) { _, state in
        guard
          let lease = (state["leases"] as? [String: Any])?[supplied["lease_id"] as! String]
            as? [String: Any], lease["status"] as? String == "released",
          jsonEqual(supplied, receipt(lease, in: state))
        else { return false }
        return lease["release_id"] as? String == id
          && lease["released_at"] as? String == confirmation["released_at"] as? String
      }
    } catch { return false }
  }

  public static func withRuntimeRegistryAdmission<T>(
    statePath: URL, descriptor: [String: Any], ownerRunID: String, ownerActor: String,
    ttlSeconds: Int = 120, runAuthority: [String: Any], body: ([String: Any]) throws -> T
  ) throws -> T {
    guard
      Set(descriptor.keys) == [
        "coordinator_instance_id", "registry_scope", "platform", "destination_id",
        "runtime_identifier",
      ],
      ["platform", "destination_id", "runtime_identifier"].allSatisfy({
        (descriptor[$0] as? String)?.isEmpty == false
      })
    else { throw ResourceCoordinatorError("invalid_runtime_probe_scope") }
    let leaseDescriptor: [String: Any] = [
      "coordinator_instance_id": descriptor["coordinator_instance_id"]!,
      "registry_scope": descriptor["registry_scope"]!,
    ]
    let acquired = try acquire(
      statePath: statePath, resource: coreSimulator, descriptor: leaseDescriptor,
      ownerRunID: ownerRunID, ownerActor: ownerActor, ttlSeconds: ttlSeconds,
      runAuthority: runAuthority)
    // An unreleased registry lease conflicts with every destination claim on the host until it
    // is recovered, so a failed release is reported whether or not the body succeeded.
    func releaseAdmission(after bodyError: Error?) throws {
      do {
        _ = try release(statePath: statePath, receipt: acquired, runAuthority: runAuthority)
      } catch {
        let code = (error as? ResourceCoordinatorError)?.code ?? String(describing: error)
        throw ResourceCoordinatorError(
          "runtime_registry_release_failed",
          bodyError.map { "\(code) after \(String(describing: $0))" } ?? code)
      }
    }
    let value: T
    do { value = try body(acquired) } catch {
      try releaseAdmission(after: error)
      throw error
    }
    try releaseAdmission(after: nil)
    return value
  }
}
