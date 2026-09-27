import Foundation

/// The persisted state model and its invariants. `load` re-proves every rule on each locked call,
/// and the lease operations apply the same helpers before they change state, so a rule a new
/// lease must satisfy is never re-implemented for a stored one.
extension ResourceCoordinator {
  /// Fields every stored lease carries.
  static let leaseFields: Set<String> = [
    "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource", "descriptor",
    "descriptor_sha256", "admission", "fencing_token", "acquired_at", "expires_at", "status",
  ]
  /// Fields a release adds.
  static let releasedLeaseFields: Set<String> = ["released_at", "release_id"]
  /// Fields a recovery adds.
  static let recoveredLeaseFields: Set<String> = [
    "recovered_at", "recovery_evidence", "recovery_id", "recovery_fencing_token",
    "recovery_evidence_sha256", "replacement_lease_id",
  ]
  /// Host capacity as (usage key, host policy key), in the order checks report them.
  static let capacityDimensions: [(usage: String, policy: String)] = [
    ("heavy_jobs", "max_heavy_jobs"), ("active_devices", "max_active_devices"),
    ("internal_workers", "max_internal_workers"),
  ]

  static func defaultHostPolicy() -> [String: Any] {
    [
      "schema_version": "1.0.0", "max_heavy_jobs": 1, "max_active_devices": 1,
      "max_internal_workers": 2,
    ]
  }
  static func blankState() -> [String: Any] {
    [
      "schema_version": schemaVersion, "runtime_kind": runtimeKind,
      "runtime_contract": runtimeContract,
      "coordinator_instance_id": UUID().uuidString.lowercased(), "migration_bootstrap": NSNull(),
      "host_policy": defaultHostPolicy(), "policy_history": [] as [[String: Any]],
      "next_fencing_token": 0, "run_authorities": [String: Any](), "leases": [String: Any](),
    ]
  }

  static func validateHostPolicy(_ raw: Any?) throws -> [String: Any] {
    guard let policy = raw as? [String: Any],
      Set(policy.keys) == [
        "schema_version", "max_heavy_jobs", "max_active_devices", "max_internal_workers",
      ], policy["schema_version"] as? String == "1.0.0",
      let heavy = integer(policy["max_heavy_jobs"]), heavy >= 1, heavy <= 64,
      let devices = integer(policy["max_active_devices"]), devices >= 1, devices <= 256,
      let workers = integer(policy["max_internal_workers"]), workers >= 1, workers <= 256
    else { throw ResourceCoordinatorError("invalid_host_policy") }
    return [
      "schema_version": "1.0.0", "max_heavy_jobs": heavy, "max_active_devices": devices,
      "max_internal_workers": workers,
    ]
  }

  static func normalizedAdmission(
    resource: String, descriptor: [String: Any], requested: [String: Any]?
  ) throws -> [String: Any] {
    var minimum: [String: Int] = [
      "heavy_jobs": resource == buildTuple ? 1 : 0,
      "active_devices": resource == simulator
        ? ((descriptor["udids"] as? [String])?.count ?? 0) : 0,
      "internal_workers": [sourceWriter, xcodeProject].contains(resource) ? 0 : 1,
    ]
    guard let requested else { return minimum }
    guard Set(requested.keys) == ["heavy_jobs", "active_devices", "internal_workers"] else {
      throw ResourceCoordinatorError("invalid_admission")
    }
    for key in minimum.keys {
      guard let value = integer(requested[key]), value >= minimum[key]!, value <= 256 else {
        throw ResourceCoordinatorError("invalid_admission")
      }
      minimum[key] = value
    }
    return minimum
  }

  static func capacityUsage(_ state: [String: Any]) -> [String: Int] {
    var usage = ["heavy_jobs": 0, "active_devices": 0, "internal_workers": 0]
    for lease in active(state) {
      if let admission = lease["admission"] as? [String: Any] {
        for key in usage.keys { usage[key, default: 0] += integer(admission[key]) ?? 0 }
      }
    }
    return usage
  }

  /// The first capacity dimension whose usage plus `added` exceeds `policy`, or nil when all fit.
  static func exceededCapacity(
    _ usage: [String: Int], adding added: [String: Any] = [:], policy: [String: Any]
  ) -> String? {
    capacityDimensions.first {
      usage[$0.usage]! + (integer(added[$0.usage]) ?? 0) > integer(policy[$0.policy])!
    }?.usage
  }

  static func sha256String(_ value: Any?) -> Bool {
    (value as? String)?.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
  }
  static func parse(_ value: Any?) throws -> Date {
    guard let value = value as? String else {
      throw ResourceCoordinatorError("invalid_state", "timestamp is not a string")
    }
    do { return try HarnessRuntime.parseTimestamp(value) } catch {
      throw ResourceCoordinatorError("invalid_state", "invalid timestamp")
    }
  }
  static func stamp(_ date: Date) -> String { HarnessRuntime.timestamp(date) }

  static func authorityWindow(
    _ authority: [String: Any]?, ownerActor: String? = nil, activeAt: Date? = nil
  ) throws -> (Date, Date) {
    guard let authority, Set(authority.keys) == authorityFields,
      sha256String(authority["authorization_hash"]),
      ["codex", "claude"].contains(authority["selected_writer"] as? String ?? ""),
      ownerActor == nil || authority["selected_writer"] as? String == ownerActor,
      sha256String(authority["harness_sha256"]), let ledger = authority["ledger_path"] as? String,
      ledger.hasPrefix("/"), sha256String(authority["ledger_identity_sha256"]),
      sha256String(authority["ledger_approval_sha256"])
    else { throw ResourceCoordinatorError("untrusted_authority") }
    let issued: Date
    let expires: Date
    do {
      issued = try parse(authority["authorization_issued_at"])
      expires = try parse(authority["authorization_expires_at"])
    } catch { throw ResourceCoordinatorError("untrusted_authority") }
    guard expires > issued else { throw ResourceCoordinatorError("untrusted_authority") }
    if let activeAt, !(issued <= activeAt && activeAt < expires) {
      throw ResourceCoordinatorError("authorization_inactive")
    }
    return (issued, expires)
  }

  /// The run authority registered for `runID`, or nil when that run never registered.
  static func registeredAuthority(_ state: [String: Any], _ runID: String) -> Any? {
    (state["run_authorities"] as? [String: Any])?[runID]
  }

  static func receipt(_ lease: [String: Any], instance: String) -> [String: Any] {
    var value: [String: Any] = ["coordinator_instance_id": instance]
    for key in [
      "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource", "descriptor_sha256",
      "fencing_token", "acquired_at", "expires_at",
    ] { value[key] = lease[key]! }
    value["resource_key"] =
      "\(lease["resource"] as! String):\(lease["descriptor_sha256"] as! String)"
    return value
  }

  /// The receipt of a lease held in `state`.
  static func receipt(_ lease: [String: Any], in state: [String: Any]) -> [String: Any] {
    receipt(lease, instance: state["coordinator_instance_id"] as! String)
  }

  static func active(_ state: [String: Any]) -> [[String: Any]] {
    guard let leases = state["leases"] as? [String: Any] else { return [] }
    return leases.values.compactMap { $0 as? [String: Any] }.filter {
      $0["status"] as? String == "active"
    }
  }

  /// Writes `lease` back into `state` under its own lease ID.
  static func store(_ lease: [String: Any], in state: inout [String: Any]) {
    var leases = state["leases"] as! [String: Any]
    leases[lease["lease_id"] as! String] = lease
    state["leases"] = leases
  }

  static func requireBootstrap(_ state: [String: Any]) throws {
    guard let bootstrap = state["migration_bootstrap"] as? [String: Any],
      bootstrap["legacy_leases_quiesced"] as? Bool == true
    else { throw ResourceCoordinatorError("migration_required") }
  }

  static func requireTTL(_ ttlSeconds: Int) throws {
    guard ttlSeconds > 0, ttlSeconds <= maxTTLSeconds else {
      throw ResourceCoordinatorError("invalid_ttl")
    }
  }

  // MARK: Shared lease invariants

  /// Whether a lease on `resource` overlaps the stored `other` lease without being the same
  /// owner's permitted nested hold. Acquisition and every load apply this one rule.
  static func overlaps(
    resource: String, descriptor: [String: Any], ownerRunID: String, ownerActor: String,
    with other: [String: Any]
  ) -> Bool {
    descriptorsConflict(
      resource: resource, descriptor: descriptor, otherResource: other["resource"] as! String,
      other: other["descriptor"] as! [String: Any])
      && !sameOwnerNestedCompatible(
        resource: resource, otherResource: other["resource"] as! String, ownerRunID: ownerRunID,
        ownerActor: ownerActor, otherOwnerRunID: other["owner_run_id"] as! String,
        otherOwnerActor: other["owner_actor"] as! String, descriptor: descriptor,
        otherDescriptor: other["descriptor"] as? [String: Any])
  }

  /// Whether `support` is a `resource` lease of the build's owner that a package-resolving build
  /// tuple needs: the source writer for its repository or, for Xcode project packages, the
  /// project mutation lease for its exact container.
  private static func supportsResolution(
    _ support: [String: Any], as resource: String, ownerRunID: String?, ownerActor: String?,
    build descriptor: [String: Any]
  ) -> Bool {
    guard support["resource"] as? String == resource,
      support["owner_run_id"] as? String == ownerRunID,
      support["owner_actor"] as? String == ownerActor,
      let supportDescriptor = support["descriptor"] as? [String: Any],
      supportDescriptor["repository_fingerprint"] as? String
        == descriptor["repository_fingerprint"] as? String
    else { return false }
    return resource == sourceWriter
      || supportDescriptor["container_path"] as? String == descriptor["container_path"] as? String
  }

  /// The error code naming the supporting lease a build tuple still lacks among `activeLeases`,
  /// or nil when its source writer and, for Xcode project packages, its project lease are held.
  static func missingResolutionSupport(
    ownerRunID: String?, ownerActor: String?, build descriptor: [String: Any],
    activeLeases: [[String: Any]]
  ) -> String? {
    func held(_ resource: String) -> Bool {
      activeLeases.contains {
        supportsResolution(
          $0, as: resource, ownerRunID: ownerRunID, ownerActor: ownerActor, build: descriptor)
      }
    }
    guard held(sourceWriter) else { return "source_writer_required" }
    guard
      descriptor["package_resolution_mode"] as? String != "xcode_project_packages"
        || held(xcodeProject)
    else { return "xcode_project_lease_required" }
    return nil
  }

  /// Whether `candidate` is support another active build tuple still needs, so it cannot end first.
  static func supportsActiveResolution(
    candidate: [String: Any], activeLeases: [[String: Any]]
  ) -> Bool {
    guard let resource = candidate["resource"] as? String,
      [sourceWriter, xcodeProject].contains(resource)
    else { return false }
    return activeLeases.contains { build in
      guard build["resource"] as? String == buildTuple,
        build["lease_id"] as? String != candidate["lease_id"] as? String,
        let descriptor = build["descriptor"] as? [String: Any],
        resource == sourceWriter
          || descriptor["package_resolution_mode"] as? String == "xcode_project_packages"
      else { return false }
      return supportsResolution(
        candidate, as: resource, ownerRunID: build["owner_run_id"] as? String,
        ownerActor: build["owner_actor"] as? String, build: descriptor)
    }
  }

  /// Drops terminal leases past their retention from a state `load` already validated, so the
  /// state stops growing with every acquisition while every rule `load` enforces still holds:
  /// the lease carrying `next_fencing_token` stays as its proof, and a kept recovery keeps the
  /// replacement it names. Active leases, run authorities and the fencing sequence are untouched,
  /// so a dropped receipt stays stale and no token is reissued. The layout is unchanged.
  static func compactTerminalLeases(_ state: inout [String: Any], now: Date) {
    guard var leases = state["leases"] as? [String: Any],
      let authorities = state["run_authorities"] as? [String: Any],
      let next = integer(state["next_fencing_token"])
    else { return }
    let horizon = now.addingTimeInterval(-TimeInterval(terminalLeaseRetentionSeconds))
    var expired = Set<String>()
    var kept: [String] = []
    for (id, raw) in leases {
      let lease = raw as? [String: Any] ?? [:]
      let terminalAt: Any? =
        switch lease["status"] as? String {
        case "released": lease["released_at"]
        case "recovered": lease["recovered_at"]
        default: nil
        }
      guard let terminalAt, let terminal = try? parse(terminalAt), terminal <= horizon,
        integer(lease["fencing_token"]) != next, integer(lease["recovery_fencing_token"]) != next,
        let owner = lease["owner_run_id"] as? String,
        let ownerExpires = try? parse(
          (authorities[owner] as? [String: Any])?["authorization_expires_at"]),
        ownerExpires <= horizon
      else {
        kept.append(id)
        continue
      }
      expired.insert(id)
    }
    while let id = kept.popLast() {
      if let replacement = (leases[id] as? [String: Any])?["replacement_lease_id"] as? String,
        expired.remove(replacement) != nil
      {
        kept.append(replacement)
      }
    }
    guard !expired.isEmpty else { return }
    for id in expired { leases.removeValue(forKey: id) }
    state["leases"] = leases
  }

  // MARK: Loading

  /// The identities and fences every stored lease must keep unique, gathered while loading.
  private struct LeaseInventory {
    var highestFence = 0
    var receiptIDs = Set<String>()
    var fences = Set<Int>()
    var recoveryIDs = Set<String>()
    var active: [[String: Any]] = []
    var replacements: [(lease: [String: Any], replacementID: String?)] = []
  }

  /// Reads the state at `path` and re-proves every invariant: its header, each lease, the active
  /// set's overlap, support and capacity rules, recovery replacements and the fencing sequence.
  /// The caller holds the coordinator lock and has established that the state exists.
  static func load(_ path: URL) throws -> [String: Any] {
    let data: [String: Any]
    do { data = try HarnessRuntime.object(path) } catch {
      throw ResourceCoordinatorError("invalid_state", "cannot read state")
    }
    let header = try validateHeader(data)
    var inventory = LeaseInventory()
    for (leaseID, raw) in header.leases {
      try validateLease(
        raw, id: leaseID, instance: header.instance, authorities: header.authorities,
        into: &inventory)
    }
    try validateActiveLeases(
      inventory.active.sorted { integer($0["fencing_token"])! < integer($1["fencing_token"])! },
      in: data, policy: header.policy)
    for (lease, replacementID) in inventory.replacements {
      if let replacementID {
        guard let replacement = header.leases[replacementID] as? [String: Any],
          integer(replacement["fencing_token"])! > integer(lease["recovery_fencing_token"])!,
          replacement["acquired_at"] as? String == lease["recovered_at"] as? String
        else {
          throw ResourceCoordinatorError("invalid_state", "replacement lease binding drifted")
        }
      }
    }
    guard inventory.highestFence == header.next else {
      throw ResourceCoordinatorError("invalid_state", "fencing token drifted")
    }
    return data
  }

  private static func validateHeader(_ data: [String: Any]) throws -> (
    instance: String, next: Int, authorities: [String: Any], leases: [String: Any],
    policy: [String: Any]
  ) {
    let required: Set<String> = [
      "schema_version", "runtime_kind", "runtime_contract", "coordinator_instance_id",
      "migration_bootstrap", "host_policy", "policy_history", "next_fencing_token",
      "run_authorities", "leases",
    ]
    guard Set(data.keys) == required, integer(data["schema_version"]) == schemaVersion,
      data["runtime_kind"] as? String == runtimeKind,
      data["runtime_contract"] as? String == runtimeContract,
      let instance = data["coordinator_instance_id"] as? String, !instance.isEmpty,
      let next = integer(data["next_fencing_token"]), next >= 0,
      let authorities = data["run_authorities"] as? [String: Any],
      let leases = data["leases"] as? [String: Any],
      let history = data["policy_history"] as? [[String: Any]]
    else { throw ResourceCoordinatorError("invalid_state", "invalid state fields") }
    let policy = try validateHostPolicy(data["host_policy"])
    for entry in history {
      guard Set(entry.keys) == ["effective_at", "policy", "operator_confirmed"],
        entry["operator_confirmed"] is Bool
      else { throw ResourceCoordinatorError("invalid_state", "invalid policy history") }
      _ = try parse(entry["effective_at"])
      _ = try validateHostPolicy(entry["policy"])
    }
    for (runID, raw) in authorities {
      guard !runID.isEmpty, let authority = raw as? [String: Any] else {
        throw ResourceCoordinatorError("invalid_state", "invalid run authority")
      }
      do { _ = try authorityWindow(authority) } catch {
        throw ResourceCoordinatorError("invalid_state", "invalid run authority")
      }
    }
    if !(data["migration_bootstrap"] is NSNull) {
      guard let bootstrap = data["migration_bootstrap"] as? [String: Any],
        Set(bootstrap.keys) == ["legacy_leases_quiesced", "confirmed_at"],
        bootstrap["legacy_leases_quiesced"] as? Bool == true
      else { throw ResourceCoordinatorError("invalid_state", "invalid bootstrap") }
      _ = try parse(bootstrap["confirmed_at"])
    }
    return (instance, next, authorities, leases, policy)
  }

  private static func validateLease(
    _ raw: Any, id leaseID: String, instance: String, authorities: [String: Any],
    into inventory: inout LeaseInventory
  ) throws {
    guard let lease = raw as? [String: Any], leaseFields.isSubset(of: Set(lease.keys)),
      Set(lease.keys).isSubset(
        of: leaseFields.union(releasedLeaseFields).union(recoveredLeaseFields)),
      lease["lease_id"] as? String == leaseID,
      let resource = lease["resource"] as? String,
      let descriptor = lease["descriptor"] as? [String: Any]
    else { throw ResourceCoordinatorError("invalid_state", "lease fields drifted") }
    let normalized = try normalizeDescriptor(resource: resource, descriptor: descriptor)
    let admission = try normalizedAdmission(
      resource: resource, descriptor: normalized, requested: lease["admission"] as? [String: Any])
    guard jsonEqual(normalized, descriptor), jsonEqual(admission, lease["admission"]),
      lease["descriptor_sha256"] as? String == (try digest(normalized)),
      let fence = integer(lease["fencing_token"]), fence > 0,
      let receiptID = lease["receipt_id"] as? String,
      inventory.receiptIDs.insert(receiptID).inserted, inventory.fences.insert(fence).inserted
    else { throw ResourceCoordinatorError("invalid_state", "lease descriptor drifted") }
    inventory.highestFence = max(inventory.highestFence, fence)
    guard let status = lease["status"] as? String,
      ["active", "released", "recovered"].contains(status)
    else { throw ResourceCoordinatorError("invalid_state", "invalid lease status") }
    let acquired = try parse(lease["acquired_at"])
    let expires = try parse(lease["expires_at"])
    guard expires > acquired else {
      throw ResourceCoordinatorError("invalid_state", "invalid lease time range")
    }
    guard let ownerRun = lease["owner_run_id"] as? String, !ownerRun.isEmpty,
      let ownerActor = lease["owner_actor"] as? String, !ownerActor.isEmpty,
      let authority = authorities[ownerRun] as? [String: Any],
      authority["selected_writer"] as? String == ownerActor
    else { throw ResourceCoordinatorError("invalid_state", "lease authority is missing") }
    let window = try authorityWindow(authority)
    guard acquired >= window.0, expires <= window.1 else {
      throw ResourceCoordinatorError("invalid_state", "lease exceeds authorization window")
    }
    switch status {
    case "active":
      guard Set(lease.keys) == leaseFields else {
        throw ResourceCoordinatorError("invalid_state", "active lease has terminal fields")
      }
      inventory.active.append(lease)
    case "released":
      guard Set(lease.keys) == leaseFields.union(releasedLeaseFields),
        let releaseID = lease["release_id"] as? String, !releaseID.isEmpty
      else { throw ResourceCoordinatorError("invalid_state", "released lease fields drifted") }
      let released = try parse(lease["released_at"])
      guard released >= acquired, released < expires else {
        throw ResourceCoordinatorError("invalid_state", "released lease time is invalid")
      }
    default:
      guard Set(lease.keys) == leaseFields.union(recoveredLeaseFields),
        let recoveryID = lease["recovery_id"] as? String, !recoveryID.isEmpty,
        inventory.recoveryIDs.insert(recoveryID).inserted,
        let recoveryFence = integer(lease["recovery_fencing_token"]), recoveryFence > fence,
        inventory.fences.insert(recoveryFence).inserted,
        let evidence = lease["recovery_evidence"] as? [String: Any],
        sha256String(lease["recovery_evidence_sha256"]),
        lease["recovery_evidence_sha256"] as? String == (try recoveryEvidenceSHA256(evidence))
      else {
        throw ResourceCoordinatorError("invalid_state", "recovered lease lacks confirmation")
      }
      let recovered = try parse(lease["recovered_at"])
      guard recovered >= expires else {
        throw ResourceCoordinatorError("invalid_state", "recovery occurred before expiry")
      }
      try validateRecoveryEvidence(
        evidence, receipt: receipt(lease, instance: instance), now: recovered)
      if evidence["mode"] as? String == "quiescent_release",
        !(lease["replacement_lease_id"] is NSNull)
      {
        throw ResourceCoordinatorError(
          "invalid_state", "quiescent release cannot replace ownership")
      }
      inventory.highestFence = max(inventory.highestFence, recoveryFence)
      inventory.replacements.append(
        (
          lease,
          lease["replacement_lease_id"] is NSNull ? nil : lease["replacement_lease_id"] as? String
        ))
    }
  }

  /// Applies the rules acquisition enforces to the stored active set, ordered by fence.
  private static func validateActiveLeases(
    _ activeLeases: [[String: Any]], in state: [String: Any], policy: [String: Any]
  ) throws {
    for (index, lease) in activeLeases.enumerated() {
      let overlapsEarlier = activeLeases[..<index].contains {
        overlaps(
          resource: lease["resource"] as! String, descriptor: lease["descriptor"] as! [String: Any],
          ownerRunID: lease["owner_run_id"] as! String,
          ownerActor: lease["owner_actor"] as! String, with: $0)
      }
      guard !overlapsEarlier else {
        throw ResourceCoordinatorError("invalid_state", "overlapping active leases")
      }
    }
    for lease in activeLeases where lease["resource"] as? String == buildTuple {
      guard
        missingResolutionSupport(
          ownerRunID: lease["owner_run_id"] as? String,
          ownerActor: lease["owner_actor"] as? String,
          build: lease["descriptor"] as! [String: Any], activeLeases: activeLeases) == nil
      else {
        throw ResourceCoordinatorError(
          "invalid_state", "package resolution build lacks supporting mutation leases")
      }
    }
    guard exceededCapacity(capacityUsage(state), policy: policy) == nil else {
      throw ResourceCoordinatorError("invalid_state", "host capacity exceeded")
    }
  }

  /// A failed atomic replacement is host I/O, not a malformed request.
  static func persist(_ state: [String: Any], to path: URL) throws {
    do {
      try HarnessRuntime.atomicWriteJSON(state, to: path)
    } catch let error as VerificationError {
      throw ResourceCoordinatorError("io_error", error.description)
    }
  }
}
