import Darwin
import Foundation

public struct ResourceCoordinatorError: Error, Equatable, CustomStringConvertible {
  public let code: String
  public let detail: String
  public init(_ code: String, _ detail: String = "") {
    self.code = code
    self.detail = detail
  }
  public var description: String { detail.isEmpty ? code : "\(code): \(detail)" }
}

public enum ResourceCoordinator {
  public static let schemaVersion = 2
  public static let runtimeKind = "swift"
  public static let runtimeContract = "apple-verification-core.resources.v1"
  public static let sourceWriter = "source_checkout_writer"
  public static let xcodeProject = "xcode_project_mutation"
  public static let buildTuple = "build_tuple"
  public static let simulator = "simulator_or_device"
  public static let coreSimulator = "coresimulator_runtime_registry"
  public static let macOSGUI = "macos_gui_session"
  public static let signing = "signing_or_app_store_connect"
  public static let github = "github_external_mutation"
  public static let resources: Set<String> = [
    sourceWriter, xcodeProject, buildTuple, simulator, coreSimulator, macOSGUI, signing, github,
  ]
  public static let maxTTLSeconds = 3_600

  private static let cacheRoles: Set<String> = [
    "derived_data", "source_packages", "repository_checkouts", "artifacts", "package_cache",
  ]
  private static let outputRoles: Set<String> = [
    "result_bundle", "result_stream", "archive", "export", "diagnostic_bundle",
  ]
  private static let packageModes: Set<String> = [
    "none", "swiftpm_lockfile", "xcode_project_packages",
  ]
  private static let receiptFields: Set<String> = [
    "coordinator_instance_id", "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource",
    "resource_key", "descriptor_sha256", "fencing_token", "acquired_at", "expires_at",
  ]
  private static let releaseFields: Set<String> = [
    "coordinator_instance_id", "release_id", "receipt_id", "lease_id", "fencing_token",
    "released_at",
  ]
  private static let authorityFields: Set<String> = [
    "authorization_hash", "selected_writer", "harness_sha256", "authorization_issued_at",
    "authorization_expires_at", "ledger_path", "ledger_identity_sha256", "ledger_approval_sha256",
  ]

  private static func object(_ value: Any?) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
      throw ResourceCoordinatorError("invalid_descriptor", "descriptor must be an object")
    }
    return value
  }

  static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }

  private static func string(_ value: Any?, _ field: String) throws -> String {
    guard let value = value as? String, !value.isEmpty, !value.contains("\0") else {
      throw ResourceCoordinatorError("invalid_descriptor", "unsafe \(field)")
    }
    return value
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let kind = String(cString: n.objCType)
    if kind == "d" || kind == "f" {
      let value = n.doubleValue
      guard value.isFinite, value.rounded() == value, value >= Double(Int.min),
        value <= Double(Int.max)
      else { return nil }
      return Int(value)
    }
    return Int(n.stringValue)
  }

  private static func absolutePath(_ value: Any?, _ field: String) throws -> String {
    let value = try string(value, field)
    guard value.hasPrefix("/") else {
      throw ResourceCoordinatorError("invalid_descriptor", "\(field) must be absolute")
    }
    return URL(fileURLWithPath: value).standardizedFileURL.path
  }

  private static func fingerprint(_ value: Any?) throws -> String {
    var value = try string(value, "repository_fingerprint").lowercased()
    if !value.hasPrefix("sha256:") { value = "sha256:" + value }
    guard value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw ResourceCoordinatorError("invalid_descriptor", "unsafe repository fingerprint")
    }
    return value
  }

  private static func githubRepository(_ value: Any?) throws -> String {
    var value = try string(value, "remote_repository").trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    if value.hasSuffix(".git") { value.removeLast(4) }
    guard
      value.range(
        of: "^[a-z0-9](?:[a-z0-9.-]{0,99})/[a-z0-9](?:[a-z0-9._-]{0,99})$",
        options: .regularExpression) != nil
    else {
      throw ResourceCoordinatorError(
        "invalid_descriptor", "remote_repository must be canonical owner/repository")
    }
    return value
  }

  private static func safeJSON(_ value: Any) throws -> Any {
    if value is NSNull || value is Bool || value is Int { return value }
    if let n = value as? NSNumber {
      guard n.doubleValue.isFinite else {
        throw ResourceCoordinatorError("invalid_descriptor", "non-finite number")
      }
      return value
    }
    if let s = value as? String {
      guard !s.isEmpty, !s.contains("\0") else {
        throw ResourceCoordinatorError("invalid_descriptor", "empty or NUL string")
      }
      return s
    }
    if let a = value as? [Any] { return try a.map(safeJSON) }
    if let d = value as? [String: Any], d.keys.allSatisfy({ !$0.isEmpty }) {
      return try Dictionary(
        uniqueKeysWithValues: d.keys.sorted().map { ($0, try safeJSON(d[$0]!)) })
    }
    throw ResourceCoordinatorError("invalid_descriptor", "unsupported descriptor value")
  }

  private static func digest(_ value: Any) throws -> String {
    "sha256:" + HarnessRuntime.sha256(try HarnessRuntime.canonicalJSON(value, ensureASCII: true))
  }

  public static func normalizeDescriptor(resource: String, descriptor: [String: Any]) throws
    -> [String: Any]
  {
    guard resources.contains(resource) else { throw ResourceCoordinatorError("invalid_resource") }
    let keys = Set(descriptor.keys)
    switch resource {
    case sourceWriter:
      guard keys == ["identity_version", "repository_fingerprint"],
        descriptor["identity_version"] as? String == "github_remote_v2"
      else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "source writer requires github_remote_v2 identity")
      }
      return [
        "identity_version": "github_remote_v2",
        "repository_fingerprint": try fingerprint(descriptor["repository_fingerprint"]),
      ]
    case xcodeProject:
      guard keys == ["repository_fingerprint", "container_path"] else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "Xcode mutation requires exact container identity")
      }
      return [
        "repository_fingerprint": try fingerprint(descriptor["repository_fingerprint"]),
        "container_path": try absolutePath(descriptor["container_path"], "container_path"),
      ]
    case buildTuple:
      let expected: Set<String> = [
        "repository_fingerprint", "container_path", "xcode_build", "sdk", "scheme", "configuration",
        "architecture", "package_fingerprint", "cache_paths", "cache_roles", "output_paths",
        "output_roles", "package_resolution_mode",
      ]
      guard keys == expected,
        let cachePaths = descriptor["cache_paths"] as? [Any],
        let cacheRoleValues = descriptor["cache_roles"] as? [String: Any],
        Set(cacheRoleValues.keys) == cacheRoles,
        let outputPaths = descriptor["output_paths"] as? [Any],
        let outputRoleValues = descriptor["output_roles"] as? [String: Any],
        Set(outputRoleValues.keys).isSubset(of: outputRoles),
        let mode = descriptor["package_resolution_mode"] as? String, packageModes.contains(mode)
      else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "build tuple requires all identity fields")
      }
      let caches = try cachePaths.map { try absolutePath($0, "cache_path") }.sorted()
      guard !caches.isEmpty, Set(caches).count == caches.count else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "cache paths must be nonempty and unique")
      }
      let roles = try Dictionary(
        uniqueKeysWithValues: cacheRoles.sorted().map {
          ($0, try absolutePath(cacheRoleValues[$0], $0))
        })
      guard Set(roles.values).count == cacheRoles.count, Set(caches) == Set(roles.values) else {
        throw ResourceCoordinatorError(
          "invalid_descriptor",
          "cache roles must use unique paths and cache_paths must contain every role")
      }
      let outputs = try outputPaths.map { try absolutePath($0, "output_path") }.sorted()
      guard Set(outputs).count == outputs.count else {
        throw ResourceCoordinatorError("invalid_descriptor", "output paths must be unique")
      }
      let outRoles = try Dictionary(
        uniqueKeysWithValues: outputRoleValues.keys.sorted().map {
          ($0, try absolutePath(outputRoleValues[$0], $0))
        })
      guard Set(outRoles.values).count == outRoles.count, Set(outputs) == Set(outRoles.values)
      else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "output_paths must contain every exact unique output role path")
      }
      var result: [String: Any] = [:]
      for field in expected.subtracting([
        "repository_fingerprint", "container_path", "cache_paths", "cache_roles", "output_paths",
        "output_roles",
      ]) { result[field] = try string(descriptor[field], field) }
      result["repository_fingerprint"] = try fingerprint(descriptor["repository_fingerprint"])
      result["container_path"] = try absolutePath(descriptor["container_path"], "container_path")
      result["cache_paths"] = caches
      result["cache_roles"] = roles
      result["output_paths"] = outputs
      result["output_roles"] = outRoles
      return result
    case simulator:
      guard keys == ["udids", "coordinator_instance_id"], let values = descriptor["udids"] as? [Any]
      else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "device claim requires coordinator_instance_id and udids")
      }
      let udids = values.compactMap {
        ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }.filter { !$0.isEmpty }.sorted()
      guard !udids.isEmpty, udids.count == values.count, Set(udids).count == udids.count,
        udids.allSatisfy({ $0.range(of: "^[a-z0-9-]{4,128}$", options: .regularExpression) != nil })
      else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "UDIDs must be nonempty, unique strings")
      }
      return [
        "coordinator_instance_id": try string(
          descriptor["coordinator_instance_id"], "coordinator_instance_id"), "udids": udids,
      ]
    case coreSimulator:
      guard keys == ["coordinator_instance_id", "registry_scope"] else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "CoreSimulator registry requires exact scope")
      }
      return [
        "coordinator_instance_id": try string(
          descriptor["coordinator_instance_id"], "coordinator_instance_id"),
        "registry_scope": try string(descriptor["registry_scope"], "registry_scope"),
      ]
    case macOSGUI:
      guard keys == ["coordinator_instance_id", "session_scope"],
        descriptor["session_scope"] as? String == "foreground_ui"
      else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "macOS GUI session_scope must be foreground_ui")
      }
      return [
        "coordinator_instance_id": try string(
          descriptor["coordinator_instance_id"], "coordinator_instance_id"),
        "session_scope": "foreground_ui",
      ]
    case signing:
      guard keys == ["account_guard", "app_or_bundle_scope"] else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "signing requires exact account/app scope")
      }
      return [
        "account_guard": try string(descriptor["account_guard"], "account_guard"),
        "app_or_bundle_scope": try string(descriptor["app_or_bundle_scope"], "app_or_bundle_scope"),
      ]
    case github:
      guard keys == ["repository_fingerprint", "remote_repository"] else {
        throw ResourceCoordinatorError(
          "invalid_descriptor", "GitHub mutation requires exact remote identity")
      }
      return [
        "repository_fingerprint": try fingerprint(descriptor["repository_fingerprint"]),
        "remote_repository": try githubRepository(descriptor["remote_repository"]),
      ]
    default: throw ResourceCoordinatorError("invalid_resource")
    }
  }

  public static func descriptorSHA256(resource: String, descriptor: [String: Any]) throws -> String
  { try digest(normalizeDescriptor(resource: resource, descriptor: descriptor)) }
  public static func recoveryEvidenceSHA256(_ evidence: [String: Any]) throws -> String {
    try digest(safeJSON(evidence))
  }
  public static func canonicalResourceKey(resource: String, descriptor: [String: Any]) throws
    -> String
  { "\(resource):\(try descriptorSHA256(resource: resource, descriptor: descriptor))" }

  private static func related(_ left: String, _ right: String) -> Bool {
    var ls = Darwin.stat()
    var rs = Darwin.stat()
    if lstat(left, &ls) == 0, lstat(right, &rs) == 0, ls.st_dev == rs.st_dev, ls.st_ino == rs.st_ino
    {
      return true
    }
    let l = URL(fileURLWithPath: left.precomposedStringWithCanonicalMapping.lowercased())
      .standardizedFileURL.pathComponents
    let r = URL(fileURLWithPath: right.precomposedStringWithCanonicalMapping.lowercased())
      .standardizedFileURL.pathComponents
    return (l.count >= r.count && Array(l.prefix(r.count)) == r)
      || (r.count >= l.count && Array(r.prefix(l.count)) == l)
  }

  public static func descriptorsConflict(
    resource: String, descriptor: [String: Any], otherResource: String, other: [String: Any]
  ) -> Bool {
    if resource == coreSimulator && [coreSimulator, simulator].contains(otherResource) {
      return true
    }
    if otherResource == coreSimulator && resource == simulator { return true }
    let pair: Set<String> = [resource, otherResource]
    if pair == [sourceWriter, xcodeProject] || pair == [sourceWriter, buildTuple]
      || pair == [xcodeProject, buildTuple]
    {
      return descriptor["repository_fingerprint"] as? String == other["repository_fingerprint"]
        as? String
    }
    guard resource == otherResource else { return false }
    switch resource {
    case sourceWriter:
      return descriptor["repository_fingerprint"] as? String == other["repository_fingerprint"]
        as? String
    case simulator:
      return !Set(descriptor["udids"] as? [String] ?? []).isDisjoint(
        with: Set(other["udids"] as? [String] ?? []))
    case buildTuple:
      if descriptor["repository_fingerprint"] as? String == other["repository_fingerprint"]
        as? String
      {
        return true
      }
      let left =
        (descriptor["cache_paths"] as? [String] ?? [])
        + (descriptor["output_paths"] as? [String] ?? [])
      let right =
        (other["cache_paths"] as? [String] ?? []) + (other["output_paths"] as? [String] ?? [])
      return left.contains { l in right.contains { related(l, $0) } }
    case xcodeProject:
      return descriptor["repository_fingerprint"] as? String == other["repository_fingerprint"]
        as? String || descriptor["container_path"] as? String == other["container_path"] as? String
    case macOSGUI:
      return descriptor["coordinator_instance_id"] as? String == other["coordinator_instance_id"]
        as? String
    case github:
      return descriptor["repository_fingerprint"] as? String == other["repository_fingerprint"]
        as? String
        || descriptor["remote_repository"] as? String == other["remote_repository"] as? String
    default: return jsonEqual(descriptor, other)
    }
  }

  public static func sameOwnerNestedCompatible(
    resource: String, otherResource: String, ownerRunID: String, ownerActor: String,
    otherOwnerRunID: String, otherOwnerActor: String, descriptor: [String: Any]? = nil,
    otherDescriptor: [String: Any]? = nil
  ) -> Bool {
    guard ownerRunID == otherOwnerRunID, ownerActor == otherOwnerActor else { return false }
    if [xcodeProject, buildTuple].contains(resource), otherResource == sourceWriter { return true }
    guard resource == buildTuple, otherResource == xcodeProject, let build = descriptor,
      let project = otherDescriptor
    else { return false }
    return build["package_resolution_mode"] as? String == "xcode_project_packages"
      && build["repository_fingerprint"] as? String == project["repository_fingerprint"] as? String
      && build["container_path"] as? String == project["container_path"] as? String
  }

  private static func statePath(_ url: URL) throws -> URL {
    guard url.path.hasPrefix("/") else {
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

  static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
  static func isRegular(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }
  private static func defaultHostPolicy() -> [String: Any] {
    [
      "schema_version": "1.0.0", "max_heavy_jobs": 1, "max_active_devices": 1,
      "max_internal_workers": 2,
    ]
  }
  private static func blankState() -> [String: Any] {
    [
      "schema_version": schemaVersion, "runtime_kind": runtimeKind,
      "runtime_contract": runtimeContract,
      "coordinator_instance_id": UUID().uuidString.lowercased(), "migration_bootstrap": NSNull(),
      "host_policy": defaultHostPolicy(), "policy_history": [] as [[String: Any]],
      "next_fencing_token": 0, "run_authorities": [String: Any](), "leases": [String: Any](),
    ]
  }

  private static func validateHostPolicy(_ raw: Any?) throws -> [String: Any] {
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

  private static func normalizedAdmission(
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

  private static func capacityUsage(_ state: [String: Any]) -> [String: Int] {
    var usage = ["heavy_jobs": 0, "active_devices": 0, "internal_workers": 0]
    for lease in active(state) {
      if let admission = lease["admission"] as? [String: Any] {
        for key in usage.keys { usage[key, default: 0] += integer(admission[key]) ?? 0 }
      }
    }
    return usage
  }

  private static func sha256String(_ value: Any?) -> Bool {
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

  private static func authorityWindow(
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

  private static func receipt(_ lease: [String: Any], instance: String) -> [String: Any] {
    var value: [String: Any] = ["coordinator_instance_id": instance]
    for key in [
      "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource", "descriptor_sha256",
      "fencing_token", "acquired_at", "expires_at",
    ] { value[key] = lease[key]! }
    value["resource_key"] =
      "\(lease["resource"] as! String):\(lease["descriptor_sha256"] as! String)"
    return value
  }

  private static func active(_ state: [String: Any]) -> [[String: Any]] {
    guard let leases = state["leases"] as? [String: Any] else { return [] }
    return leases.values.compactMap { $0 as? [String: Any] }.filter {
      $0["status"] as? String == "active"
    }
  }

  private static func requireBootstrap(_ state: [String: Any]) throws {
    guard let bootstrap = state["migration_bootstrap"] as? [String: Any],
      bootstrap["legacy_leases_quiesced"] as? Bool == true
    else { throw ResourceCoordinatorError("migration_required") }
  }

  private static func load(_ path: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path.path) else { return blankState() }
    let data: [String: Any]
    do { data = try HarnessRuntime.object(path) } catch {
      throw ResourceCoordinatorError("invalid_state", "cannot read state")
    }
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
    var highest = 0
    var receiptIDs = Set<String>()
    var fences = Set<Int>()
    var recoveryIDs = Set<String>()
    var activeLeases: [[String: Any]] = []
    var replacements: [([String: Any], String?)] = []
    let requiredLease: Set<String> = [
      "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource", "descriptor",
      "descriptor_sha256", "admission", "fencing_token", "acquired_at", "expires_at", "status",
    ]
    let optional: Set<String> = [
      "released_at", "release_id", "recovered_at", "recovery_evidence", "recovery_id",
      "recovery_fencing_token", "recovery_evidence_sha256", "replacement_lease_id",
    ]
    for (leaseID, raw) in leases {
      guard let lease = raw as? [String: Any], requiredLease.isSubset(of: Set(lease.keys)),
        Set(lease.keys).isSubset(of: requiredLease.union(optional)),
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
        let receiptID = lease["receipt_id"] as? String, receiptIDs.insert(receiptID).inserted,
        fences.insert(fence).inserted
      else { throw ResourceCoordinatorError("invalid_state", "lease descriptor drifted") }
      highest = max(highest, fence)
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
      if status == "active" {
        guard Set(lease.keys) == requiredLease else {
          throw ResourceCoordinatorError("invalid_state", "active lease has terminal fields")
        }
        activeLeases.append(lease)
      } else if status == "released" {
        guard Set(lease.keys) == requiredLease.union(["released_at", "release_id"]),
          let releaseID = lease["release_id"] as? String, !releaseID.isEmpty
        else { throw ResourceCoordinatorError("invalid_state", "released lease fields drifted") }
        let released = try parse(lease["released_at"])
        guard released >= acquired, released < expires else {
          throw ResourceCoordinatorError("invalid_state", "released lease time is invalid")
        }
      } else {
        let recovery: Set<String> = [
          "recovered_at", "recovery_evidence", "recovery_id", "recovery_fencing_token",
          "recovery_evidence_sha256", "replacement_lease_id",
        ]
        guard Set(lease.keys) == requiredLease.union(recovery),
          let recoveryID = lease["recovery_id"] as? String, !recoveryID.isEmpty,
          recoveryIDs.insert(recoveryID).inserted,
          let recoveryFence = integer(lease["recovery_fencing_token"]), recoveryFence > fence,
          fences.insert(recoveryFence).inserted,
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
        highest = max(highest, recoveryFence)
        replacements.append(
          (
            lease,
            lease["replacement_lease_id"] is NSNull ? nil : lease["replacement_lease_id"] as? String
          ))
      }
    }
    activeLeases.sort { integer($0["fencing_token"])! < integer($1["fencing_token"])! }
    for i in activeLeases.indices {
      for j in activeLeases.indices where j > i {
        let a = activeLeases[i]
        let b = activeLeases[j]
        if descriptorsConflict(
          resource: a["resource"] as! String, descriptor: a["descriptor"] as! [String: Any],
          otherResource: b["resource"] as! String, other: b["descriptor"] as! [String: Any])
          && !sameOwnerNestedCompatible(
            resource: b["resource"] as! String, otherResource: a["resource"] as! String,
            ownerRunID: b["owner_run_id"] as! String, ownerActor: b["owner_actor"] as! String,
            otherOwnerRunID: a["owner_run_id"] as! String,
            otherOwnerActor: a["owner_actor"] as! String,
            descriptor: b["descriptor"] as? [String: Any],
            otherDescriptor: a["descriptor"] as? [String: Any])
        {
          throw ResourceCoordinatorError("invalid_state", "overlapping active leases")
        }
      }
    }
    for lease in activeLeases where lease["resource"] as? String == buildTuple {
      guard resolutionSupportPresent(build: lease, activeLeases: activeLeases) else {
        throw ResourceCoordinatorError(
          "invalid_state", "package resolution build lacks supporting mutation leases")
      }
    }
    let usage = capacityUsage(data)
    for (usageKey, policyKey) in [
      ("heavy_jobs", "max_heavy_jobs"), ("active_devices", "max_active_devices"),
      ("internal_workers", "max_internal_workers"),
    ] {
      guard usage[usageKey]! <= integer(policy[policyKey])! else {
        throw ResourceCoordinatorError("invalid_state", "host capacity exceeded")
      }
    }
    for (lease, replacementID) in replacements {
      if let replacementID {
        guard let replacement = leases[replacementID] as? [String: Any],
          integer(replacement["fencing_token"])! > integer(lease["recovery_fencing_token"])!,
          replacement["acquired_at"] as? String == lease["recovered_at"] as? String
        else {
          throw ResourceCoordinatorError("invalid_state", "replacement lease binding drifted")
        }
      }
    }
    guard highest == next else {
      throw ResourceCoordinatorError("invalid_state", "fencing token drifted")
    }
    return data
  }

  private static func loadForBootstrap(_ path: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path.path) else { return blankState() }
    let raw: [String: Any]
    do { raw = try HarnessRuntime.object(path) } catch {
      throw ResourceCoordinatorError("invalid_state", "cannot read state")
    }
    if integer(raw["schema_version"]) == schemaVersion { return try load(path) }
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
    try HarnessRuntime.atomicWriteJSON(migrated, to: validationURL)
    return try load(validationURL)
  }

  private static func locked<T>(
    _ stateURL: URL, bootstrapCreate: Bool = false, _ body: (URL, inout [String: Any]) throws -> T
  ) throws -> T {
    let path = try statePath(stateURL)
    let lock = URL(fileURLWithPath: path.path + ".lock")
    if isSymlink(lock) {
      throw ResourceCoordinatorError("invalid_state_path", "lock file must not be a symlink")
    }
    let stateExists = FileManager.default.fileExists(atPath: path.path)
    let lockExists = FileManager.default.fileExists(atPath: lock.path)
    if !stateExists && !bootstrapCreate {
      throw ResourceCoordinatorError("migration_required", "coordinator state is not bootstrapped")
    }
    if !stateExists && lockExists {
      throw ResourceCoordinatorError(
        "invalid_state_path", "orphaned coordinator lock requires review")
    }
    if stateExists && !lockExists {
      throw ResourceCoordinatorError(
        "invalid_state_path", "bootstrapped coordinator lock is missing")
    }
    return try HarnessRuntime.withFileLock(at: lock, timeout: 5) {
      guard !isSymlink(lock), isRegular(lock) else {
        throw ResourceCoordinatorError("invalid_state_path", "lock file must be regular")
      }
      var state = try (bootstrapCreate ? loadForBootstrap(path) : load(path))
      return try body(path, &state)
    }
  }

  public static func bootstrap(statePath: URL, legacyLeasesQuiesced: Bool) throws -> [String: Any] {
    guard legacyLeasesQuiesced else {
      throw ResourceCoordinatorError(
        "migration_required", "legacy or unversioned leases must be quiesced")
    }
    let existed = FileManager.default.fileExists(atPath: statePath.path)
    let wasLegacy =
      existed && ((try? HarnessRuntime.object(statePath)["schema_version"]).flatMap(integer) == 1)
    return try locked(statePath, bootstrapCreate: true) { path, state in
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
      try HarnessRuntime.atomicWriteJSON(state, to: path)
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
  public static func status(statePath: URL) throws -> [String: Any] {
    let state = try fullStatus(statePath: statePath)
    return [
      "schema_version": state["schema_version"]!, "runtime_kind": state["runtime_kind"]!,
      "runtime_contract": state["runtime_contract"]!,
      "coordinator_instance_id": state["coordinator_instance_id"]!,
      "migration_bootstrap": state["migration_bootstrap"]!, "host_policy": state["host_policy"]!,
      "capacity_in_use": capacityUsage(state), "active_lease_count": active(state).count,
    ]
  }

  public static func portableDocumentSHA256(_ document: [String: Any]) throws -> String {
    var portable = document
    portable.removeValue(forKey: "$schema")
    return try digest(portable)
  }

  public static func sourceBundleSHA256(skillRoot: URL) throws -> String {
    let fm = FileManager.default
    var files: [URL] = []
    for directory in [
      skillRoot.appendingPathComponent("contracts"),
      skillRoot.appendingPathComponent("verification/Sources"),
    ] {
      if let enumerator = fm.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      {
        for case let url as URL in enumerator {
          let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          if values.isRegularFile == true, values.isSymbolicLink != true,
            ["json", "swift"].contains(url.pathExtension)
          {
            files.append(url)
          }
        }
      }
    }
    guard !files.isEmpty else {
      throw ResourceCoordinatorError("untrusted_binding", "installed contract bundle is empty")
    }
    var bytes = Data()
    for file in files.sorted(by: { $0.path < $1.path }) {
      let relative = file.path.replacingOccurrences(of: skillRoot.path + "/", with: "")
      let name = Data(relative.utf8)
      let count = UInt32(name.count).bigEndian
      withUnsafeBytes(of: count) { bytes.append(contentsOf: $0) }
      bytes.append(name)
      guard let hash = Data(hex: try HarnessRuntime.sha256File(file)) else {
        throw ResourceCoordinatorError("untrusted_binding")
      }
      bytes.append(hash)
    }
    return "sha256:" + HarnessRuntime.sha256(bytes)
  }

  @available(*, deprecated, message: "Use sourceBundleSHA256(skillRoot:)")
  public static func contractBundleSHA256(skillRoot: URL) throws -> String {
    try sourceBundleSHA256(skillRoot: skillRoot)
  }

  public static func ledgerBinding(
    _ ledgerPath: URL, descriptor: Int32? = nil, expectedRunID: String? = nil,
    expectedAuthorizationHash: String? = nil
  ) throws -> [String: Any] {
    guard ledgerPath.path.hasPrefix("/"), !isSymlink(ledgerPath) else {
      throw ResourceCoordinatorError("untrusted_ledger", "ledger path is unsafe")
    }
    let openedHere = descriptor == nil
    let fd = descriptor ?? open(ledgerPath.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else {
      throw ResourceCoordinatorError("untrusted_ledger", "ledger cannot be opened")
    }
    defer { if openedHere { close(fd) } }
    var opened = Darwin.stat()
    var named = Darwin.stat()
    guard fstat(fd, &opened) == 0, lstat(ledgerPath.path, &named) == 0,
      (opened.st_mode & S_IFMT) == S_IFREG, (named.st_mode & S_IFMT) == S_IFREG,
      opened.st_nlink == 1, named.st_nlink == 1, opened.st_dev == named.st_dev,
      opened.st_ino == named.st_ino
    else { throw ResourceCoordinatorError("untrusted_ledger", "ledger inode drifted") }
    var buffer = [UInt8](repeating: 0, count: min(1_048_576, max(1, Int(opened.st_size))))
    let readCount = pread(fd, &buffer, buffer.count, 0)
    guard readCount > 0 else {
      throw ResourceCoordinatorError("untrusted_ledger", "ledger approval record is unavailable")
    }
    let prefix = Data(buffer.prefix(readCount))
    let newline = prefix.firstIndex(of: 0x0a)
    guard let end = newline ?? (opened.st_size <= readCount ? prefix.endIndex : nil),
      end > prefix.startIndex,
      let approval = try? JSONSerialization.jsonObject(with: prefix[..<end]) as? [String: Any],
      let payload = approval["payload"] as? [String: Any],
      approval["record_type"] as? String == "approval", integer(approval["sequence"]) == 1,
      payload["kind"] as? String == "run_authorization",
      payload["decision"] as? String == "approved",
      expectedRunID == nil || approval["run_id"] as? String == expectedRunID,
      expectedAuthorizationHash == nil
        || payload["authorization_hash"] as? String == expectedAuthorizationHash
    else { throw ResourceCoordinatorError("untrusted_ledger", "ledger approval binding drifted") }
    let canonical = ledgerPath.resolvingSymlinksInPath().standardizedFileURL
    let identity: [String: Any] = [
      "path": canonical.path, "device": NSNumber(value: opened.st_dev),
      "inode": NSNumber(value: opened.st_ino),
    ]
    return [
      "ledger_path": canonical.path, "ledger_identity_sha256": try digest(identity),
      "ledger_approval_sha256": try digest(approval),
    ]
  }

  public static func loadTrustedHarness(harnessPath: URL, context: RuntimeContext) throws
    -> [String: Any]
  {
    guard harnessPath.path.hasPrefix("/"), !isSymlink(harnessPath), isRegular(harnessPath) else {
      throw ResourceCoordinatorError(
        "untrusted_binding", "harness must be an absolute regular file")
    }
    let document: [String: Any]
    do { document = try HarnessRuntime.object(harnessPath) } catch {
      throw ResourceCoordinatorError("untrusted_binding", "harness cannot be read")
    }
    let schemaURL = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/harness.schema.json")
    do {
      let schema = try HarnessRuntime.object(schemaURL)
      let errors = JSONSchemaValidator.errors(
        instance: document, schema: schema, path: "$", root: nil)
      if !errors.isEmpty {
        throw ResourceCoordinatorError(
          "untrusted_binding", Array(Set(errors)).sorted().joined(separator: "; "))
      }
    } catch let error as ResourceCoordinatorError { throw error } catch {
      throw ResourceCoordinatorError("untrusted_binding", "harness schema is unavailable")
    }
    let mode = document["mode"] as? String
    let writer = document["selected_writer"] as? String
    let reviewer = document["reviewer"] is NSNull ? nil : document["reviewer"] as? String
    let roles =
      (mode == "codex" && writer == "codex" && reviewer == nil)
      || (mode == "claude" && writer == "claude" && reviewer == nil)
      || (mode == "collaborative"
        && ((writer == "codex" && reviewer == "claude")
          || (writer == "claude" && reviewer == "codex")))
    guard roles, document["resource_coordinator"] is [String: Any] else {
      throw ResourceCoordinatorError(
        "untrusted_binding", "harness writer and reviewer roles are invalid")
    }
    for field in [
      "authoritative_root", "private_policy_overlay", "run_authorization", "run_ledger",
    ] {
      guard let path = document[field] as? String, path.hasPrefix("/") else {
        throw ResourceCoordinatorError(
          "untrusted_binding", "harness \(field) must be an absolute path")
      }
    }
    if !(document["xcode_container"] is NSNull), let path = document["xcode_container"] as? String,
      !path.hasPrefix("/")
    {
      throw ResourceCoordinatorError(
        "untrusted_binding", "harness xcode_container must be an absolute path")
    }
    return document
  }

  public static func loadHarnessBinding(harnessPath: URL, context: RuntimeContext) throws
    -> [String: Any]
  {
    try loadTrustedHarness(harnessPath: harnessPath, context: context)["resource_coordinator"]
      as! [String: Any]
  }

  public static func validateTrustedBinding(
    statePath: URL, binding: [String: Any], context: RuntimeContext
  ) throws -> [String: Any] {
    guard
      Set(binding.keys) == [
        "runtime_kind", "runtime_contract", "state_path", "coordinator_instance_id",
        "executable_sha256", "source_bundle_sha256",
      ], binding["runtime_kind"] as? String == runtimeKind,
      binding["runtime_contract"] as? String == runtimeContract,
      let expected = binding["state_path"] as? String, expected.hasPrefix("/")
    else {
      throw ResourceCoordinatorError(
        "untrusted_binding", "binding fields are incomplete or legacy runtime-bound")
    }
    let path = try self.statePath(statePath)
    let expectedURL = URL(fileURLWithPath: expected)
    guard !isSymlink(path), !isSymlink(expectedURL),
      path.resolvingSymlinksInPath() == expectedURL.resolvingSymlinksInPath()
    else { throw ResourceCoordinatorError("untrusted_binding", "state path drifted") }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    guard FileManager.default.fileExists(atPath: executable.path),
      binding["executable_sha256"] as? String == "sha256:"
        + (try HarnessRuntime.sha256File(executable))
    else {
      throw ResourceCoordinatorError("untrusted_binding", "coordinator executable hash drifted")
    }
    guard
      binding["source_bundle_sha256"] as? String
        == (try sourceBundleSHA256(skillRoot: context.harnessRoot))
    else {
      throw ResourceCoordinatorError("untrusted_binding", "installed source bundle hash drifted")
    }
    let live = try status(statePath: path)
    guard
      live["coordinator_instance_id"] as? String == binding["coordinator_instance_id"] as? String
    else { throw ResourceCoordinatorError("untrusted_binding", "coordinator instance drifted") }
    return live
  }

  public static func configureHostPolicy(
    statePath: URL, policy: [String: Any], operatorConfirmed: Bool, now: Date = Date()
  ) throws -> [String: Any] {
    let normalized = try validateHostPolicy(policy)
    return try locked(statePath) { path, state in
      try requireBootstrap(state)
      let current = try validateHostPolicy(state["host_policy"])
      let increased = ["max_heavy_jobs", "max_active_devices", "max_internal_workers"].contains {
        integer(normalized[$0])! > integer(current[$0])!
      }
      guard !increased || operatorConfirmed else {
        throw ResourceCoordinatorError("operator_confirmation_required")
      }
      let usage = capacityUsage(state)
      for (usageKey, policyKey) in [
        ("heavy_jobs", "max_heavy_jobs"), ("active_devices", "max_active_devices"),
        ("internal_workers", "max_internal_workers"),
      ] {
        guard usage[usageKey]! <= integer(normalized[policyKey])! else {
          throw ResourceCoordinatorError("capacity_in_use")
        }
      }
      state["host_policy"] = normalized
      var history = state["policy_history"] as! [[String: Any]]
      history.append([
        "effective_at": stamp(now), "policy": normalized, "operator_confirmed": operatorConfirmed,
      ])
      state["policy_history"] = history
      try HarnessRuntime.atomicWriteJSON(state, to: path)
      return [
        "host_policy": normalized, "operator_confirmed": operatorConfirmed,
        "effective_at": stamp(now),
      ]
    }
  }

  private static func resolutionSupportPresent(build: [String: Any], activeLeases: [[String: Any]])
    -> Bool
  {
    let descriptor = build["descriptor"] as! [String: Any]
    let ownerRun = build["owner_run_id"] as? String
    let actor = build["owner_actor"] as? String
    let source = activeLeases.contains {
      $0["resource"] as? String == sourceWriter && $0["owner_run_id"] as? String == ownerRun
        && $0["owner_actor"] as? String == actor
        && ($0["descriptor"] as? [String: Any])?["repository_fingerprint"] as? String == descriptor[
          "repository_fingerprint"] as? String
    }
    guard source else { return false }
    guard descriptor["package_resolution_mode"] as? String == "xcode_project_packages" else {
      return true
    }
    return activeLeases.contains {
      $0["resource"] as? String == xcodeProject && $0["owner_run_id"] as? String == ownerRun
        && $0["owner_actor"] as? String == actor
        && ($0["descriptor"] as? [String: Any])?["repository_fingerprint"] as? String == descriptor[
          "repository_fingerprint"] as? String
        && ($0["descriptor"] as? [String: Any])?["container_path"] as? String == descriptor[
          "container_path"] as? String
    }
  }

  private static func supportsActiveResolution(
    candidate: [String: Any], activeLeases: [[String: Any]]
  ) -> Bool {
    for build in activeLeases
    where build["resource"] as? String == buildTuple
      && build["lease_id"] as? String != candidate["lease_id"] as? String
    {
      guard let descriptor = build["descriptor"] as? [String: Any],
        let candidateDescriptor = candidate["descriptor"] as? [String: Any]
      else { continue }
      let sameOwner =
        candidate["owner_run_id"] as? String == build["owner_run_id"] as? String
        && candidate["owner_actor"] as? String == build["owner_actor"] as? String
      let sameRepository =
        candidateDescriptor["repository_fingerprint"] as? String == descriptor[
          "repository_fingerprint"] as? String
      if candidate["resource"] as? String == sourceWriter && sameOwner && sameRepository {
        return true
      }
      if candidate["resource"] as? String == xcodeProject
        && descriptor["package_resolution_mode"] as? String == "xcode_project_packages" && sameOwner
        && sameRepository
        && candidateDescriptor["container_path"] as? String == descriptor["container_path"]
          as? String
      {
        return true
      }
    }
    return false
  }

  private static func newLease(
    state: inout [String: Any], resource: String, descriptor: [String: Any], ownerRunID: String,
    ownerActor: String, ttlSeconds: Int, admission requestedAdmission: [String: Any]? = nil,
    authorizationExpiresAt: Date, now: Date
  ) throws -> [String: Any] {
    guard !ownerRunID.isEmpty, !ownerActor.isEmpty else {
      throw ResourceCoordinatorError("invalid_owner")
    }
    guard ttlSeconds > 0, ttlSeconds <= maxTTLSeconds else {
      throw ResourceCoordinatorError("invalid_ttl")
    }
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
    for lease in activeLeases {
      if descriptorsConflict(
        resource: resource, descriptor: normalized, otherResource: lease["resource"] as! String,
        other: lease["descriptor"] as! [String: Any])
        && !sameOwnerNestedCompatible(
          resource: resource, otherResource: lease["resource"] as! String, ownerRunID: ownerRunID,
          ownerActor: ownerActor, otherOwnerRunID: lease["owner_run_id"] as! String,
          otherOwnerActor: lease["owner_actor"] as! String, descriptor: normalized,
          otherDescriptor: lease["descriptor"] as? [String: Any])
      {
        throw ResourceCoordinatorError("resource_conflict", lease["lease_id"] as? String ?? "")
      }
    }
    if resource == buildTuple {
      let source = activeLeases.contains {
        $0["resource"] as? String == sourceWriter && $0["owner_run_id"] as? String == ownerRunID
          && $0["owner_actor"] as? String == ownerActor
          && ($0["descriptor"] as? [String: Any])?["repository_fingerprint"] as? String
            == normalized["repository_fingerprint"] as? String
      }
      guard source else { throw ResourceCoordinatorError("source_writer_required") }
      if normalized["package_resolution_mode"] as? String == "xcode_project_packages" {
        let project = activeLeases.contains {
          $0["resource"] as? String == xcodeProject && $0["owner_run_id"] as? String == ownerRunID
            && $0["owner_actor"] as? String == ownerActor
            && ($0["descriptor"] as? [String: Any])?["repository_fingerprint"] as? String
              == normalized["repository_fingerprint"] as? String
            && ($0["descriptor"] as? [String: Any])?["container_path"] as? String == normalized[
              "container_path"] as? String
        }
        guard project else { throw ResourceCoordinatorError("xcode_project_lease_required") }
      }
    }
    let policy = try validateHostPolicy(state["host_policy"])
    let usage = capacityUsage(state)
    for (usageKey, policyKey) in [
      ("heavy_jobs", "max_heavy_jobs"), ("active_devices", "max_active_devices"),
      ("internal_workers", "max_internal_workers"),
    ] {
      if usage[usageKey]! + integer(admission[usageKey])! > integer(policy[policyKey])! {
        throw ResourceCoordinatorError("capacity_exceeded", usageKey)
      }
    }
    let expires = now.addingTimeInterval(TimeInterval(ttlSeconds))
    guard expires <= authorizationExpiresAt else {
      throw ResourceCoordinatorError("authorization_window_too_short")
    }
    let fence = (integer(state["next_fencing_token"]) ?? 0) + 1
    state["next_fencing_token"] = fence
    let leaseID = UUID().uuidString.lowercased()
    let lease: [String: Any] = [
      "receipt_id": UUID().uuidString.lowercased(), "lease_id": leaseID, "owner_run_id": ownerRunID,
      "owner_actor": ownerActor, "resource": resource, "descriptor": normalized,
      "descriptor_sha256": try digest(normalized), "admission": admission, "fencing_token": fence,
      "acquired_at": stamp(now), "expires_at": stamp(expires), "status": "active",
    ]
    var leases = state["leases"] as! [String: Any]
    leases[leaseID] = lease
    state["leases"] = leases
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
        try HarnessRuntime.atomicWriteJSON(state, to: path)
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
      guard let existing = (state["run_authorities"] as? [String: Any])?[ownerRunID] else {
        throw ResourceCoordinatorError("unregistered_run_authority")
      }
      guard jsonEqual(existing, runAuthority) else {
        throw ResourceCoordinatorError("writer_mismatch")
      }
      let lease = try newLease(
        state: &state, resource: resource, descriptor: descriptor, ownerRunID: ownerRunID,
        ownerActor: ownerActor, ttlSeconds: ttlSeconds, admission: admission,
        authorizationExpiresAt: window.1, now: now)
      try HarnessRuntime.atomicWriteJSON(state, to: path)
      return receipt(lease, instance: state["coordinator_instance_id"] as! String)
    }
  }

  private static func leaseForReceipt(state: [String: Any], supplied: [String: Any]) throws
    -> [String: Any]
  {
    guard Set(supplied.keys) == receiptFields else {
      throw ResourceCoordinatorError("invalid_receipt")
    }
    guard let id = supplied["lease_id"] as? String,
      let lease = (state["leases"] as? [String: Any])?[id] as? [String: Any],
      lease["status"] as? String == "active",
      jsonEqual(supplied, receipt(lease, instance: state["coordinator_instance_id"] as! String))
    else { throw ResourceCoordinatorError("stale_receipt") }
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
      return receipt(lease, instance: state["coordinator_instance_id"] as! String)
    }
  }

  public static func verifyReceipt(
    statePath: URL, receipt supplied: [String: Any], now: Date = Date()
  ) -> (errors: [String], receipt: [String: Any]?) {
    do {
      return try locked(statePath) { _, state in
        guard Set(supplied.keys) == receiptFields else {
          throw ResourceCoordinatorError("invalid_receipt")
        }
        guard let id = supplied["lease_id"] as? String,
          let lease = (state["leases"] as? [String: Any])?[id] as? [String: Any],
          lease["status"] as? String == "active"
        else { throw ResourceCoordinatorError("stale_receipt") }
        let current = receipt(lease, instance: state["coordinator_instance_id"] as! String)
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

  private static func requireReceiptAuthority(
    state: [String: Any], lease: [String: Any], authority: [String: Any]?
  ) throws -> (Date, Date) {
    let window = try authorityWindow(authority, ownerActor: lease["owner_actor"] as? String)
    guard
      jsonEqual(
        (state["run_authorities"] as? [String: Any])?[lease["owner_run_id"] as! String], authority)
    else { throw ResourceCoordinatorError("untrusted_authority") }
    return window
  }

  public static func heartbeat(
    statePath: URL, receipt supplied: [String: Any], ttlSeconds: Int, runAuthority: [String: Any]?,
    now: Date = Date()
  ) throws -> [String: Any] {
    guard ttlSeconds > 0, ttlSeconds <= maxTTLSeconds else {
      throw ResourceCoordinatorError("invalid_ttl")
    }
    return try locked(statePath) { path, state in
      var lease = try leaseForReceipt(state: state, supplied: supplied)
      var window = try requireReceiptAuthority(state: state, lease: lease, authority: runAuthority)
      guard now < window.1 else { throw ResourceCoordinatorError("authorization_inactive") }
      let old = try parse(lease["expires_at"])
      guard old > now else { throw ResourceCoordinatorError("expired_requires_recover") }
      let next = now.addingTimeInterval(TimeInterval(ttlSeconds))
      guard next > old else { throw ResourceCoordinatorError("heartbeat_must_extend") }
      guard next <= window.1 else {
        throw ResourceCoordinatorError("authorization_window_too_short")
      }
      lease["expires_at"] = stamp(next)
      var leases = state["leases"] as! [String: Any]
      leases[lease["lease_id"] as! String] = lease
      state["leases"] = leases
      try HarnessRuntime.atomicWriteJSON(state, to: path)
      return receipt(lease, instance: state["coordinator_instance_id"] as! String)
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
      guard try parse(lease["expires_at"]) > now else {
        throw ResourceCoordinatorError("expired_requires_recover")
      }
      lease["status"] = "released"
      lease["release_id"] = UUID().uuidString.lowercased()
      lease["released_at"] = stamp(now)
      var leases = state["leases"] as! [String: Any]
      leases[lease["lease_id"] as! String] = lease
      state["leases"] = leases
      try HarnessRuntime.atomicWriteJSON(state, to: path)
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
          jsonEqual(supplied, receipt(lease, instance: state["coordinator_instance_id"] as! String))
        else { return false }
        return lease["release_id"] as? String == id
          && lease["released_at"] as? String == confirmation["released_at"] as? String
      }
    } catch { return false }
  }

  private static func validateRecoveryEvidence(
    _ evidence: [String: Any], receipt: [String: Any], now: Date
  ) throws {
    let expected: Set<String> = [
      "previous_receipt_id", "previous_fencing_token", "observer", "owner_liveness",
      "owner_tool_children", "dirty_state", "live_resource_revalidation",
    ]
    guard Set(evidence.keys) == expected,
      jsonEqual(evidence["previous_receipt_id"], receipt["receipt_id"]),
      jsonEqual(evidence["previous_fencing_token"], receipt["fencing_token"]),
      let observer = evidence["observer"] as? [String: Any],
      Set(observer.keys) == ["observer_run_id", "observer_actor", "method", "observed_at"],
      observer["method"] as? String == "bounded_read_only_host_probe",
      observer["observer_run_id"] as? String != receipt["owner_run_id"] as? String
    else { throw ResourceCoordinatorError("invalid_recovery_evidence") }
    _ = try string(observer["observer_run_id"], "observer_run_id")
    _ = try string(observer["observer_actor"], "observer_actor")
    let observerTime = try parse(observer["observed_at"])
    guard observerTime <= now, now.timeIntervalSince(observerTime) <= 300 else {
      throw ResourceCoordinatorError("stale_recovery_evidence")
    }
    let checks: [(String, String, Any)] = [
      ("owner_liveness", "state", "dead"), ("owner_tool_children", "state", "dead"),
      ("dirty_state", "state", "clean"), ("live_resource_revalidation", "passed", true),
    ]
    for (name, field, expectedValue) in checks {
      guard let item = evidence[name] as? [String: Any], jsonEqual(item[field], expectedValue),
        sha256String(item["digest"]), let raw = item["observed_at"] as? String
      else { throw ResourceCoordinatorError("invalid_recovery_evidence") }
      let observed = try parse(raw)
      guard observed <= now, now.timeIntervalSince(observed) <= 300 else {
        throw ResourceCoordinatorError("stale_recovery_evidence")
      }
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
          jsonEqual(supplied, receipt(lease, instance: state["coordinator_instance_id"] as! String))
        else { return false }
        let replacementID =
          lease["replacement_lease_id"] is NSNull ? nil : lease["replacement_lease_id"] as? String
        let expectedReplacement: Any =
          replacementID.flatMap { leases[$0] as? [String: Any] }.map {
            receipt($0, instance: state["coordinator_instance_id"] as! String)
          } ?? NSNull()
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
    now: Date = Date()
  ) throws -> [String: Any] {
    try locked(statePath) { path, state in
      try requireBootstrap(state)
      var lease = try leaseForReceipt(state: state, supplied: supplied)
      _ = try requireReceiptAuthority(state: state, lease: lease, authority: runAuthority)
      guard try parse(lease["expires_at"]) <= now else {
        throw ResourceCoordinatorError("recovery_not_yet_allowed")
      }
      if supportsActiveResolution(candidate: lease, activeLeases: active(state)) {
        throw ResourceCoordinatorError("dependent_lease_active")
      }
      try validateRecoveryEvidence(evidence, receipt: supplied, now: now)
      let observer = evidence["observer"] as! [String: Any]
      let observerRunID = observer["observer_run_id"] as! String
      let observerActor = observer["observer_actor"] as! String
      do {
        _ = try authorityWindow(observerAuthority, ownerActor: observerActor, activeAt: now)
      } catch { throw ResourceCoordinatorError("untrusted_authority") }
      guard observerRunID != lease["owner_run_id"] as? String,
        let storedObserver = (state["run_authorities"] as? [String: Any])?[observerRunID],
        jsonEqual(storedObserver, observerAuthority)
      else {
        throw ResourceCoordinatorError(
          storedObserverMissing(state, observerRunID)
            ? "unregistered_run_authority" : "untrusted_authority")
      }
      lease["status"] = "recovered"
      lease["recovered_at"] = stamp(now)
      lease["recovery_evidence"] = try safeJSON(evidence)
      let recoveryFence = (integer(state["next_fencing_token"]) ?? 0) + 1
      state["next_fencing_token"] = recoveryFence
      lease["recovery_id"] = UUID().uuidString.lowercased()
      lease["recovery_fencing_token"] = recoveryFence
      lease["recovery_evidence_sha256"] = try recoveryEvidenceSHA256(evidence)
      var leases = state["leases"] as! [String: Any]
      leases[lease["lease_id"] as! String] = lease
      state["leases"] = leases
      var newReceipt: [String: Any]?
      if let replacement {
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
          window = try authorityWindow(replacementAuthority, ownerActor: actor, activeAt: now)
        } catch { throw ResourceCoordinatorError("untrusted_authority") }
        guard runID != lease["owner_run_id"] as? String, observerRunID == runID,
          observerActor == actor, jsonEqual(replacementAuthority, observerAuthority),
          let stored = (state["run_authorities"] as? [String: Any])?[runID],
          jsonEqual(stored, replacementAuthority)
        else {
          throw ResourceCoordinatorError(
            storedObserverMissing(state, runID)
              ? "unregistered_run_authority" : "untrusted_authority")
        }
        let replacementLease = try newLease(
          state: &state, resource: resource, descriptor: descriptor, ownerRunID: runID,
          ownerActor: actor, ttlSeconds: ttl, authorizationExpiresAt: window.1, now: now)
        newReceipt = receipt(
          replacementLease, instance: state["coordinator_instance_id"] as! String)
      }
      lease["replacement_lease_id"] = newReceipt?["lease_id"] ?? NSNull()
      leases = state["leases"] as! [String: Any]
      leases[lease["lease_id"] as! String] = lease
      state["leases"] = leases
      try HarnessRuntime.atomicWriteJSON(state, to: path)
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

  private static func storedObserverMissing(_ state: [String: Any], _ runID: String) -> Bool {
    (state["run_authorities"] as? [String: Any])?[runID] == nil
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
    do {
      let value = try body(acquired)
      _ = try release(statePath: statePath, receipt: acquired, runAuthority: runAuthority)
      return value
    } catch {
      _ = try? release(statePath: statePath, receipt: acquired, runAuthority: runAuthority)
      throw error
    }
  }

}

extension Data {
  fileprivate init?(hex: String) {
    let hex = hex.hasPrefix("sha256:") ? String(hex.dropFirst(7)) : hex
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    self = data
  }
}
