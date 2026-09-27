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

/// Host-wide leases on shared Apple-platform resources, kept in one private JSON state.
///
/// This file holds the resource vocabulary: descriptor normalization, digests and the overlap
/// rules. The state model and its invariants, locking and bootstrap, lease operations, recovery,
/// trusted bindings and the command line live in the other `ResourceCoordinator*.swift` files.
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
  /// A released or recovered lease stays in state until this long after both its terminal
  /// transition and its owner's authorization window have ended. While that window is open, the
  /// owner's ledger check still compares its release or recovery confirmation with the record.
  public static let terminalLeaseRetentionSeconds = 7 * 24 * 60 * 60

  private static let cacheRoles: Set<String> = [
    "derived_data", "source_packages", "repository_checkouts", "artifacts", "package_cache",
  ]
  private static let outputRoles: Set<String> = [
    "result_bundle", "result_stream", "archive", "export", "diagnostic_bundle",
  ]
  private static let packageModes: Set<String> = [
    "none", "swiftpm_lockfile", "xcode_project_packages",
  ]
  static let receiptFields: Set<String> = [
    "coordinator_instance_id", "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource",
    "resource_key", "descriptor_sha256", "fencing_token", "acquired_at", "expires_at",
  ]
  static let releaseFields: Set<String> = [
    "coordinator_instance_id", "release_id", "receipt_id", "lease_id", "fencing_token",
    "released_at",
  ]
  static let authorityFields: Set<String> = [
    "authorization_hash", "selected_writer", "harness_sha256", "authorization_issued_at",
    "authorization_expires_at", "ledger_path", "ledger_identity_sha256", "ledger_approval_sha256",
  ]

  static func object(_ value: Any?) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
      throw ResourceCoordinatorError("invalid_descriptor", "descriptor must be an object")
    }
    return value
  }

  static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }

  static func string(_ value: Any?, _ field: String) throws -> String {
    guard let value = value as? String, !value.isEmpty, !value.contains("\0") else {
      throw ResourceCoordinatorError("invalid_descriptor", "unsafe \(field)")
    }
    return value
  }

  static func integer(_ value: Any?) -> Int? {
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

  static func safeJSON(_ value: Any) throws -> Any {
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

  static func digest(_ value: Any) throws -> String {
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

  /// `URL(fileURLWithPath:)` resolves a relative spelling against the working directory, so its
  /// `path` is always absolute; an absolute-path guard must check the caller's spelling.
  static func spelledAbsolute(_ url: URL) -> Bool { url.relativePath.hasPrefix("/") }

  static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
  static func isRegular(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }
}
