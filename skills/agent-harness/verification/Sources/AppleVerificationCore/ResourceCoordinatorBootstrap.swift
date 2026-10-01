import Darwin
import Foundation

/// The coordinator lock, bootstrap and the host-policy commands. The lock is `<state>.lock` beside
/// the state, and every locked call decides whether the state exists while holding it.
extension ResourceCoordinator {
  static func statePath(_ url: URL) throws -> URL {
    guard spelledAbsolute(url) else {
      throw ResourceCoordinatorError("invalid_state_path", "an absolute state path is required")
    }
    let parent = url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: parent.path), !isSymlink(parent) else {
      throw ResourceCoordinatorError(
        "invalid_state_path", "parent must exist and must not be a symlink")
    }
    if FileManager.default.fileExists(atPath: url.path) {
      guard !isSymlink(url), isRegular(url) else {
        throw ResourceCoordinatorError(
          "invalid_state_path", "state file must be a regular non-symlink")
      }
    }
    return url.standardizedFileURL
  }

  /// Runs `body` on a validated state while holding the coordinator lock.
  static func locked<T>(
    _ stateURL: URL, _ body: (URL, inout [String: Any]) throws -> T
  ) throws -> T {
    try withStateLock(stateURL, bootstrapCreate: false) { path in
      var state = try load(path)
      return try body(path, &state)
    }
  }

  /// Runs `body` with the state path while holding its lock. Only `bootstrap` may create them.
  ///
  /// Opening the lock creates it, so its absence is checked first: a call refuses to create a lock
  /// beside existing state, and only bootstrap may create one. Whether the state exists is decided
  /// again once the lock is held, so a bootstrap queued behind another first bootstrap finds the
  /// state that one published instead of calling its lock orphaned.
  ///
  /// A first bootstrap that fails before publishing state removes the lock it created, so a retry
  /// starts clean; a waiter on the removed lock fails as `io_error` and can retry. A lock without
  /// state that this call did not create is orphaned: a first bootstrap died before publishing,
  /// or the state was removed. That stays `invalid_state_path`. Review means confirming that no
  /// run still holds a receipt or harness bound to a coordinator at this path; then remove the
  /// empty lock and bootstrap again, and rematerialize any harness bound to an earlier instance.
  private static func withStateLock<T>(
    _ stateURL: URL, bootstrapCreate: Bool, _ body: (URL) throws -> T
  ) throws -> T {
    let path = try statePath(stateURL)
    let lock = URL(fileURLWithPath: path.path + ".lock")
    if isSymlink(lock) {
      throw ResourceCoordinatorError("invalid_state_path", "lock file must not be a symlink")
    }
    let lockExisted = FileManager.default.fileExists(atPath: lock.path)
    let stateExisted = FileManager.default.fileExists(atPath: path.path)
    if !stateExisted && !bootstrapCreate {
      throw ResourceCoordinatorError("migration_required", "coordinator state is not bootstrapped")
    }
    if stateExisted && !lockExisted {
      throw ResourceCoordinatorError(
        "invalid_state_path", "bootstrapped coordinator lock is missing")
    }
    // Only failures to take the lock are mapped here; the body reports its own errors.
    var holdingLock = false
    do {
      return try HarnessRuntime.withFileLock(at: lock, timeout: 5) {
        holdingLock = true
        guard !isSymlink(lock), isRegular(lock) else {
          throw ResourceCoordinatorError("invalid_state_path", "lock file must be regular")
        }
        if !FileManager.default.fileExists(atPath: path.path) {
          guard bootstrapCreate else {
            throw ResourceCoordinatorError(
              "migration_required", "coordinator state is not bootstrapped")
          }
          guard !lockExisted else {
            throw ResourceCoordinatorError(
              "invalid_state_path", "orphaned coordinator lock requires review")
          }
        }
        do { return try body(path) } catch {
          if bootstrapCreate, !lockExisted, !FileManager.default.fileExists(atPath: path.path) {
            unlink(lock.path)
          }
          throw error
        }
      }
    } catch VerificationError.lockTimedOut where !holdingLock {
      throw ResourceCoordinatorError("coordinator_busy")
    } catch let error as VerificationError where !holdingLock {
      throw ResourceCoordinatorError("io_error", error.description)
    }
  }

  /// The state a bootstrap starts from, and whether it is a quiescent legacy state migrated here.
  /// The caller holds the lock.
  private static func loadForBootstrap(_ path: URL) throws -> (
    state: [String: Any], migratedLegacy: Bool
  ) {
    guard FileManager.default.fileExists(atPath: path.path) else { return (blankState(), false) }
    let raw: [String: Any]
    do { raw = try HarnessRuntime.object(path) } catch {
      throw ResourceCoordinatorError("invalid_state", "cannot read state")
    }
    if integer(raw["schema_version"]) == schemaVersion { return (try load(path), false) }
    guard integer(raw["schema_version"]) == 1,
      Set(raw.keys) == [
        "schema_version", "coordinator_instance_id", "migration_bootstrap", "next_fencing_token",
        "run_authorities", "leases",
      ], let leases = raw["leases"] as? [String: Any],
      !leases.values.compactMap({ $0 as? [String: Any] }).contains(where: {
        $0["status"] as? String == "active"
      })
    else {
      throw ResourceCoordinatorError(
        "migration_required", "legacy coordinator must be quiescent before Swift migration")
    }
    var migrated = raw
    migrated["schema_version"] = schemaVersion
    migrated["runtime_kind"] = runtimeKind
    migrated["runtime_contract"] = runtimeContract
    migrated["host_policy"] = defaultHostPolicy()
    migrated["policy_history"] = [
      ["effective_at": stamp(Date()), "policy": defaultHostPolicy(), "operator_confirmed": true]
    ]
    var upgraded: [String: Any] = [:]
    for (id, value) in leases {
      guard var lease = value as? [String: Any], let resource = lease["resource"] as? String,
        let descriptor = lease["descriptor"] as? [String: Any]
      else { throw ResourceCoordinatorError("invalid_state", "invalid legacy lease") }
      lease["admission"] = try normalizedAdmission(
        resource: resource, descriptor: descriptor, requested: nil)
      upgraded[id] = lease
    }
    migrated["leases"] = upgraded
    let validationURL = path.deletingLastPathComponent().appendingPathComponent(
      ".coordinator-migration-validation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: validationURL) }
    try persist(migrated, to: validationURL)
    return (try load(validationURL), true)
  }

  public static func bootstrap(statePath: URL, legacyLeasesQuiesced: Bool) throws -> [String: Any] {
    guard legacyLeasesQuiesced else {
      throw ResourceCoordinatorError(
        "migration_required", "legacy or unversioned leases must be quiesced")
    }
    return try withStateLock(statePath, bootstrapCreate: true) { path in
      let loaded = try loadForBootstrap(path)
      var state = loaded.state
      let wasLegacy = loaded.migratedLegacy
      if !(state["migration_bootstrap"] is NSNull), !wasLegacy {
        return [
          "coordinator_instance_id": state["coordinator_instance_id"]!,
          "already_bootstrapped": true,
        ]
      }
      state["migration_bootstrap"] = [
        "legacy_leases_quiesced": true, "confirmed_at": stamp(Date()),
      ]
      if (state["policy_history"] as? [[String: Any]])?.isEmpty != false {
        state["policy_history"] = [
          [
            "effective_at": stamp(Date()), "policy": state["host_policy"]!,
            "operator_confirmed": false,
          ]
        ]
      }
      try persist(state, to: path)
      return [
        "coordinator_instance_id": state["coordinator_instance_id"]!, "already_bootstrapped": false,
        "migrated_legacy_state": wasLegacy,
      ]
    }
  }

  public static func fullStatus(statePath: URL) throws -> [String: Any] {
    try locked(statePath) { _, state in
      try requireBootstrap(state)
      return try object(
        JSONSerialization.jsonObject(with: HarnessRuntime.canonicalJSON(state, ensureASCII: true)))
    }
  }
  public static func status(statePath: URL, now: Date = Date()) throws -> [String: Any] {
    let state = try fullStatus(statePath: statePath)
    // An active lease past its expiry keeps its capacity until it is recovered. Reporting it
    // separately tells a blocked caller whether the blocker is live work or an expired owner.
    let expired = active(state).filter { lease in
      (try? parse(lease["expires_at"])).map { $0 <= now } ?? false
    }
    return [
      "schema_version": state["schema_version"]!, "runtime_kind": state["runtime_kind"]!,
      "runtime_contract": state["runtime_contract"]!,
      "coordinator_instance_id": state["coordinator_instance_id"]!,
      "migration_bootstrap": state["migration_bootstrap"]!, "host_policy": state["host_policy"]!,
      "capacity_in_use": capacityUsage(state), "active_lease_count": active(state).count,
      "expired_active_lease_count": expired.count,
      "capacity_held_by_expired": capacityUsage(of: expired),
    ]
  }

  public static func configureHostPolicy(
    statePath: URL, policy: [String: Any], operatorConfirmed: Bool, now: Date = Date()
  ) throws -> [String: Any] {
    let normalized = try validateHostPolicy(policy)
    return try locked(statePath) { path, state in
      try requireBootstrap(state)
      let current = try validateHostPolicy(state["host_policy"])
      let increased = capacityDimensions.contains {
        integer(normalized[$0.policy])! > integer(current[$0.policy])!
      }
      guard !increased || operatorConfirmed else {
        throw ResourceCoordinatorError("operator_confirmation_required")
      }
      guard exceededCapacity(capacityUsage(state), policy: normalized) == nil else {
        throw ResourceCoordinatorError("capacity_in_use")
      }
      state["host_policy"] = normalized
      var history = state["policy_history"] as! [[String: Any]]
      history.append([
        "effective_at": stamp(now), "policy": normalized, "operator_confirmed": operatorConfirmed,
      ])
      state["policy_history"] = history
      try persist(state, to: path)
      return [
        "host_policy": normalized, "operator_confirmed": operatorConfirmed,
        "effective_at": stamp(now),
      ]
    }
  }
}
