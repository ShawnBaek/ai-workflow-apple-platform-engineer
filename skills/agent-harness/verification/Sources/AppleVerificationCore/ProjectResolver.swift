import Foundation

public struct ProjectResolverError: Error, Equatable, CustomStringConvertible {
  public let code: String
  public let detail: String
  public init(_ code: String, _ detail: String = "") {
    self.code = code
    self.detail = detail
  }
  public var description: String { detail.isEmpty ? code : "\(code): \(detail)" }
}

public enum ProjectResolver {
  public static let resolverVersion = "1.0.0"
  private static let identifiers = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$")
  private static let githubPath = try! NSRegularExpression(
    pattern: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
  private static let fingerprints = try! NSRegularExpression(pattern: "^sha256:[0-9a-f]{64}$")

  private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
    regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))?.range
      == NSRange(value.startIndex..., in: value)
  }

  private static func invalidText(_ value: Any?) -> Bool {
    guard let value = value as? String, !value.isEmpty else { return true }
    return value.unicodeScalars.contains { $0.value <= 0x1f || $0.value == 0x7f }
  }

  private static func validIdentifier(_ value: Any?) -> Bool {
    guard let value = value as? String else { return false }
    return matches(identifiers, value)
  }

  private static func safeAbsolutePath(_ value: Any?) throws -> URL {
    guard !invalidText(value), let string = value as? String else {
      throw ProjectResolverError("unsafe_path")
    }
    let url = URL(fileURLWithPath: string)
    guard string.hasPrefix("/"),
      !string.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    else { throw ProjectResolverError("unsafe_path") }
    return url
  }

  public static func normalizeGitHubRemote(_ value: Any) throws -> String {
    guard !invalidText(value), let original = value as? String,
      original == original.trimmingCharacters(in: .whitespacesAndNewlines),
      !original.contains("?"), !original.contains("#")
    else {
      throw ProjectResolverError("invalid_remote")
    }
    var path: String
    if original.hasPrefix("git@github.com:") {
      path = String(original.dropFirst("git@github.com:".count))
    } else {
      guard let components = URLComponents(string: original),
        ["https", "ssh"].contains(components.scheme ?? ""),
        components.host == "github.com",
        components.password == nil,
        components.query == nil,
        components.fragment == nil
      else { throw ProjectResolverError("invalid_remote") }
      if components.scheme == "https" {
        guard components.user == nil, components.port == nil || components.port == 443 else {
          throw ProjectResolverError("invalid_remote")
        }
      } else {
        guard components.user == nil || components.user == "git",
          components.port == nil || components.port == 22
        else { throw ProjectResolverError("invalid_remote") }
      }
      path = components.path
      while path.hasPrefix("/") { path.removeFirst() }
    }
    if path.hasSuffix(".git") { path.removeLast(4) }
    guard matches(githubPath, path) else { throw ProjectResolverError("invalid_remote") }
    return "github.com/\(path.lowercased())"
  }

  public static func remoteFingerprint(_ value: Any) throws -> String {
    "sha256:" + HarnessRuntime.sha256(Data(try normalizeGitHubRemote(value).utf8))
  }

  private static func git(_ root: URL, _ arguments: [String]) throws -> String {
    let result: ProcessResult
    do {
      result = try HarnessRuntime.run(
        executable: "/usr/bin/git", arguments: ["-C", root.path] + arguments, directory: nil,
        environment: nil, timeout: 5, maxOutputBytes: 1_048_576)
    } catch {
      throw ProjectResolverError(
        FileManager.default.fileExists(atPath: "/usr/bin/git")
          ? "git_execution_failed" : "git_unavailable")
    }
    if result.timedOut { throw ProjectResolverError("git_timeout") }
    guard result.exitCode == 0 else { throw ProjectResolverError("not_git_root") }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private static func canonicalExisting(_ url: URL, missingCode: String) throws -> URL {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ProjectResolverError(missingCode)
    }
    return url.resolvingSymlinksInPath().standardizedFileURL
  }

  private static func isWithin(_ child: URL, _ parent: URL) -> Bool {
    let c = child.standardizedFileURL.pathComponents
    let p = parent.standardizedFileURL.pathComponents
    return c.count >= p.count && Array(c.prefix(p.count)) == p
  }

  private static func containerRelative(root: URL, value: Any) throws -> String {
    guard !invalidText(value), let relative = value as? String else {
      throw ProjectResolverError("invalid_xcode_container")
    }
    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.hasPrefix("/"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      components.map(String.init).joined(separator: "/") == relative,
      relative.hasSuffix(".xcodeproj") || relative.hasSuffix(".xcworkspace")
    else {
      throw ProjectResolverError("invalid_xcode_container")
    }
    let candidate = root.appendingPathComponent(relative)
    guard !isSymbolicLink(candidate) else { throw ProjectResolverError("invalid_xcode_container") }
    let resolved = try canonicalExisting(candidate, missingCode: "missing_xcode_container")
    guard isDirectory(resolved), isWithin(resolved, root) else {
      throw ProjectResolverError("invalid_xcode_container")
    }
    return relative
  }

  public static func validateProjectRoot(
    pathValue: Any, containers: Any? = nil, context: RuntimeContext
  ) throws -> [String: Any] {
    let path = try safeAbsolutePath(pathValue)
    guard !isSymbolicLink(path) else { throw ProjectResolverError("unsafe_path") }
    let root = try canonicalExisting(path, missingCode: "missing_path")
    guard isDirectory(root) else { throw ProjectResolverError("unsafe_path") }
    let top = try canonicalExisting(
      URL(fileURLWithPath: try git(root, ["rev-parse", "--show-toplevel"])),
      missingCode: "not_git_root")
    guard top == root else { throw ProjectResolverError("not_git_root") }
    let fingerprint = try remoteFingerprint(git(root, ["config", "--get", "remote.origin.url"]))
    func metadata(_ argument: String) throws -> URL {
      let raw = try git(root, ["rev-parse", argument])
      let u = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)
      return try canonicalExisting(u, missingCode: "not_git_root")
    }
    let kind = try metadata("--git-dir") == metadata("--git-common-dir") ? "primary" : "worktree"
    var checked: [String] = []
    if let containers {
      guard let values = containers as? [Any], values.allSatisfy({ $0 is String }) else {
        throw ProjectResolverError("invalid_xcode_container")
      }
      checked = try values.map { try containerRelative(root: root, value: $0) }
      guard Set(checked).count == checked.count else {
        throw ProjectResolverError("invalid_xcode_container")
      }
      checked.sort()
    }
    return [
      "canonical_root": root.path, "remote_fingerprint": fingerprint, "kind": kind,
      "xcode_containers": checked,
    ]
  }

  private static func openedContainer(_ value: Any, context: RuntimeContext) throws -> (
    [String: Any], String
  ) {
    let path = try safeAbsolutePath(value)
    guard !isSymbolicLink(path),
      path.path.hasSuffix(".xcodeproj") || path.path.hasSuffix(".xcworkspace")
    else { throw ProjectResolverError("invalid_opened_xcode_container") }
    let container = try canonicalExisting(path, missingCode: "invalid_opened_xcode_container")
    guard isDirectory(container) else {
      throw ProjectResolverError("invalid_opened_xcode_container")
    }
    let rawRoot: String
    do { rawRoot = try git(container, ["rev-parse", "--show-toplevel"]) } catch {
      throw ProjectResolverError("invalid_opened_xcode_container")
    }
    let facts = try validateProjectRoot(pathValue: rawRoot, context: context)
    let root = URL(fileURLWithPath: facts["canonical_root"] as! String)
    guard isWithin(container, root) else {
      throw ProjectResolverError("invalid_opened_xcode_container")
    }
    return (facts, String(container.path.dropFirst(root.path.count + (root.path == "/" ? 0 : 1))))
  }

  private static func registryProjects(_ registry: Any, developerID: String, hostID: String) throws
    -> [[String: Any]]
  {
    guard let registry = registry as? [String: Any],
      Set(registry.keys).subtracting([
        "$schema", "schema_version", "developer_id", "host_id", "projects",
      ]).isEmpty
    else { throw ProjectResolverError("invalid_registry") }
    guard registry["developer_id"] as? String == developerID,
      registry["host_id"] as? String == hostID
    else { return [] }
    guard registry["schema_version"] as? String == "1.0.0",
      let projects = registry["projects"] as? [[String: Any]], !projects.isEmpty
    else { throw ProjectResolverError("invalid_registry") }
    return projects
  }

  private static func checkedProject(_ project: [String: Any]) throws -> (
    String, String, [[String: Any]]
  ) {
    guard Set(project.keys) == ["project_id", "remote_fingerprint", "checkouts"],
      validIdentifier(project["project_id"]), let id = project["project_id"] as? String,
      let fingerprint = project["remote_fingerprint"] as? String,
      matches(fingerprints, fingerprint),
      let checkouts = project["checkouts"] as? [[String: Any]], !checkouts.isEmpty
    else { throw ProjectResolverError("invalid_registry") }
    return (id, fingerprint, checkouts)
  }

  private static func checkedCandidate(
    projectID: String, expectedFingerprint: String, checkout: [String: Any], allowWorktree: Bool,
    context: RuntimeContext
  ) throws -> [String: Any] {
    guard Set(checkout.keys) == ["checkout_id", "path", "kind", "xcode_containers"],
      validIdentifier(checkout["checkout_id"]), let checkoutID = checkout["checkout_id"] as? String,
      let kind = checkout["kind"] as? String, ["primary", "worktree"].contains(kind)
    else { throw ProjectResolverError("invalid_registry") }
    let facts = try validateProjectRoot(
      pathValue: checkout["path"] as Any, containers: checkout["xcode_containers"], context: context
    )
    guard facts["remote_fingerprint"] as? String == expectedFingerprint else {
      throw ProjectResolverError("remote_fingerprint_mismatch")
    }
    guard allowWorktree || facts["kind"] as? String != "worktree" else {
      throw ProjectResolverError("worktree_not_authorized")
    }
    guard facts["kind"] as? String == kind else {
      throw ProjectResolverError("checkout_kind_mismatch")
    }
    return facts.merging(["project_id": projectID, "checkout_id": checkoutID]) { _, new in new }
  }

  private static func validateIntegrity(_ projects: [[String: Any]]) throws {
    var projectIDs = Set<String>()
    var fingerprints = Set<String>()
    for project in projects {
      let (id, fingerprint, checkouts) = try checkedProject(project)
      guard projectIDs.insert(id.lowercased()).inserted, fingerprints.insert(fingerprint).inserted
      else { throw ProjectResolverError("duplicate_registry_identity") }
      var checkoutIDs = Set<String>()
      for checkout in checkouts {
        guard validIdentifier(checkout["checkout_id"]), let id = checkout["checkout_id"] as? String,
          checkoutIDs.insert(id.lowercased()).inserted
        else { throw ProjectResolverError("duplicate_checkout_id") }
      }
    }
  }

  public static func resolveProject(
    registry: Any?, developerID: String? = nil, hostID: String? = nil, explicitPath: String? = nil,
    projectID: String? = nil, openedXcodeContainer: String? = nil, allowWorktree: Bool = false,
    context: RuntimeContext
  ) -> [String: Any] {
    var explicitFacts: [String: Any]?
    var openedFacts: [String: Any]?
    var openedRelative: String?
    do {
      if let explicitPath {
        explicitFacts = try validateProjectRoot(pathValue: explicitPath, context: context)
      }
      if let openedXcodeContainer {
        (openedFacts, openedRelative) = try openedContainer(openedXcodeContainer, context: context)
      }
    } catch let error as ProjectResolverError {
      return ["status": "blocked", "reason_code": error.code]
    } catch { return ["status": "blocked", "reason_code": "not_git_root"] }
    if let explicitFacts, let openedFacts,
      explicitFacts["canonical_root"] as? String != openedFacts["canonical_root"] as? String
    {
      return ["status": "blocked", "reason_code": "opened_xcode_conflicts_explicit_path"]
    }
    if var candidate = openedFacts ?? explicitFacts {
      if candidate["kind"] as? String == "worktree" && !allowWorktree {
        return ["status": "unavailable", "reason_code": "worktree_not_authorized"]
      }
      if let openedRelative { candidate["xcode_containers"] = [openedRelative] }
      return [
        "status": "resolved",
        "reason_code": openedFacts != nil ? "opened_xcode_container" : "explicit_path",
        "candidate": candidate,
      ]
    }
    guard registry != nil else {
      return ["status": "unavailable", "reason_code": "registry_not_configured"]
    }
    guard validIdentifier(developerID), validIdentifier(hostID),
      projectID == nil || validIdentifier(projectID)
    else { return ["status": "blocked", "reason_code": "invalid_selector"] }
    let projects: [[String: Any]]
    do {
      projects = try registryProjects(registry!, developerID: developerID!, hostID: hostID!)
      try validateIntegrity(projects)
    } catch let error as ProjectResolverError {
      return ["status": "blocked", "reason_code": error.code]
    } catch { return ["status": "blocked", "reason_code": "invalid_registry"] }
    guard !projects.isEmpty else {
      return ["status": "unavailable", "reason_code": "no_matching_profile"]
    }
    var candidates: [[String: Any]] = []
    var warnings: [[String: String]] = []
    var skippedWorktree = false
    do {
      for project in projects {
        let (id, fingerprint, checkouts) = try checkedProject(project)
        if let projectID, id != projectID { continue }
        for checkout in checkouts {
          do {
            candidates.append(
              try checkedCandidate(
                projectID: id, expectedFingerprint: fingerprint, checkout: checkout,
                allowWorktree: allowWorktree, context: context))
          } catch let error as ProjectResolverError {
            if error.code == "worktree_not_authorized" {
              skippedWorktree = true
              continue
            }
            if [
              "missing_path", "not_git_root", "missing_xcode_container",
              "remote_fingerprint_mismatch",
            ].contains(error.code) {
              warnings.append([
                "project_id": id, "checkout_id": checkout["checkout_id"] as? String ?? "",
                "reason_code": error.code,
              ])
              continue
            }
            throw error
          } catch { throw ProjectResolverError("not_git_root") }
        }
      }
    } catch let error as ProjectResolverError {
      return ["status": "blocked", "reason_code": error.code]
    } catch { return ["status": "blocked", "reason_code": "invalid_registry"] }
    warnings.sort {
      ($0["project_id"]!, $0["checkout_id"]!, $0["reason_code"]!) < (
        $1["project_id"]!, $1["checkout_id"]!, $1["reason_code"]!
      )
    }
    if candidates.isEmpty && !warnings.isEmpty {
      return ["status": "blocked", "reason_code": "no_valid_candidates", "warnings": warnings]
    }
    if candidates.isEmpty && skippedWorktree {
      return ["status": "unavailable", "reason_code": "worktree_not_authorized"]
    }
    if candidates.isEmpty {
      return ["status": "unavailable", "reason_code": "no_matching_candidates"]
    }
    var roots: [String: [String: Any]] = [:]
    for candidate in candidates {
      let root = candidate["canonical_root"] as! String
      if let prior = roots[root],
        prior["project_id"] as? String != candidate["project_id"] as? String
          || prior["checkout_id"] as? String != candidate["checkout_id"] as? String
      {
        return ["status": "blocked", "reason_code": "duplicate_canonical_root"]
      }
      roots[root] = candidate
    }
    candidates = roots.values.sorted {
      (
        ($0["project_id"] as! String), ($0["checkout_id"] as! String),
        ($0["canonical_root"] as! String)
      ) < (
        ($1["project_id"] as! String), ($1["checkout_id"] as! String),
        ($1["canonical_root"] as! String)
      )
    }
    var result: [String: Any] =
      candidates.count == 1
      ? ["status": "resolved", "reason_code": "registry_candidate", "candidate": candidates[0]]
      : [
        "status": "needs_selection", "reason_code": "multiple_candidates", "candidates": candidates,
      ]
    if !warnings.isEmpty { result["warnings"] = warnings }
    return result
  }

  public static func registrySHA256(_ registry: Any) throws -> String {
    "sha256:" + HarnessRuntime.sha256(try HarnessRuntime.canonicalJSON(registry, ensureASCII: true))
  }

  private struct RegistryJSONScanner {
    let bytes: [UInt8]
    var index = 0
    mutating func scan() throws {
      try value()
      space()
      guard index == bytes.count else { throw ProjectResolverError("invalid_registry") }
    }
    mutating func space() {
      while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func value() throws {
      space()
      guard index < bytes.count else { throw ProjectResolverError("invalid_registry") }
      switch bytes[index] {
      case 0x7b: try object()
      case 0x5b: try array()
      case 0x22: _ = try string()
      case 0x74: try literal("true")
      case 0x66: try literal("false")
      case 0x6e: try literal("null")
      default: try number()
      }
    }
    mutating func object() throws {
      index += 1
      space()
      var keys = Set<String>()
      if take(0x7d) { return }
      while true {
        space()
        let key = try string()
        guard keys.insert(key).inserted else { throw ProjectResolverError("invalid_registry") }
        space()
        guard take(0x3a) else { throw ProjectResolverError("invalid_registry") }
        try value()
        space()
        if take(0x7d) { return }
        guard take(0x2c) else { throw ProjectResolverError("invalid_registry") }
      }
    }
    mutating func array() throws {
      index += 1
      space()
      if take(0x5d) { return }
      while true {
        try value()
        space()
        if take(0x5d) { return }
        guard take(0x2c) else { throw ProjectResolverError("invalid_registry") }
      }
    }
    mutating func string() throws -> String {
      guard index < bytes.count, bytes[index] == 0x22 else {
        throw ProjectResolverError("invalid_registry")
      }
      let start = index
      index += 1
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 0x22 {
          let data = Data(bytes[start..<index])
          guard
            let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
              as? String
          else { throw ProjectResolverError("invalid_registry") }
          return decoded
        }
        if byte == 0x5c {
          guard index < bytes.count else { throw ProjectResolverError("invalid_registry") }
          let escape = bytes[index]
          index += 1
          if escape == 0x75 {
            guard index + 4 <= bytes.count else { throw ProjectResolverError("invalid_registry") }
            index += 4
          }
        } else if byte < 0x20 {
          throw ProjectResolverError("invalid_registry")
        }
      }
      throw ProjectResolverError("invalid_registry")
    }
    mutating func literal(_ text: String) throws {
      let target = Array(text.utf8)
      guard index + target.count <= bytes.count,
        Array(bytes[index..<index + target.count]) == target
      else { throw ProjectResolverError("invalid_registry") }
      index += target.count
    }
    mutating func number() throws {
      let start = index
      while index < bytes.count, [UInt8]("-+0123456789.eE".utf8).contains(bytes[index]) {
        index += 1
      }
      guard index > start, Double(String(decoding: bytes[start..<index], as: UTF8.self)) != nil
      else { throw ProjectResolverError("invalid_registry") }
    }
    mutating func take(_ byte: UInt8) -> Bool {
      if index < bytes.count, bytes[index] == byte {
        index += 1
        return true
      }
      return false
    }
  }

  private static func loadRegistry(_ path: URL) throws -> Any {
    let data: Data
    do { data = try Data(contentsOf: path) } catch {
      throw ProjectResolverError("invalid_registry")
    }
    var scanner = RegistryJSONScanner(bytes: Array(data))
    try scanner.scan()
    let value: Any
    do { value = try HarnessRuntime.loadJSON(path) } catch {
      throw ProjectResolverError("invalid_registry")
    }
    guard value is [String: Any] else { throw ProjectResolverError("invalid_registry") }
    return value
  }

  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    var registryPath: String?
    var developerID: String?
    var hostID: String?
    var projectID: String?
    var explicitPath: String?
    var opened: String?
    var fingerprintPath: String?
    var allowWorktree = false
    var index = 0
    var seen = Set<String>()
    while index < arguments.count {
      let key = arguments[index]
      guard seen.insert(key).inserted else { throw ProjectResolverError("invalid_arguments") }
      if key == "--allow-worktree" {
        allowWorktree = true
        index += 1
        continue
      }
      guard index + 1 < arguments.count else { throw ProjectResolverError("invalid_arguments") }
      let value = arguments[index + 1]
      switch key {
      case "--registry": registryPath = value
      case "--developer-id": developerID = value
      case "--host-id": hostID = value
      case "--project-id": projectID = value
      case "--explicit-path": explicitPath = value
      case "--opened-xcode-container": opened = value
      case "--fingerprint-path": fingerprintPath = value
      default: throw ProjectResolverError("invalid_arguments")
      }
      index += 2
    }
    let output: [String: Any]
    if let fingerprintPath {
      guard registryPath == nil, developerID == nil, hostID == nil, projectID == nil,
        explicitPath == nil, opened == nil, !allowWorktree
      else { throw ProjectResolverError("invalid_arguments") }
      do {
        let facts = try validateProjectRoot(pathValue: fingerprintPath, context: context)
        output = [
          "status": "resolved", "reason_code": "fingerprinted",
          "remote_fingerprint": facts["remote_fingerprint"]!,
        ]
      } catch let error as ProjectResolverError {
        output = ["status": "blocked", "reason_code": error.code]
      }
    } else {
      let authoritative = explicitPath != nil || opened != nil
      var registry: Any?
      if let registryPath, !authoritative {
        do { registry = try loadRegistry(URL(fileURLWithPath: registryPath)) } catch {
          registry = NSNull()
        }
      }
      if registry is NSNull {
        output = ["status": "blocked", "reason_code": "invalid_registry"]
      } else {
        var value = resolveProject(
          registry: registry, developerID: developerID, hostID: hostID, explicitPath: explicitPath,
          projectID: projectID, openedXcodeContainer: opened, allowWorktree: allowWorktree,
          context: context)
        if let registry {
          value["resolver_version"] = resolverVersion
          value["registry_sha256"] = try registrySHA256(registry)
          value["worktree_authorized"] = allowWorktree
          if value["warnings"] == nil { value["warnings"] = [] as [[String: String]] }
          if value["candidate"] == nil { value["candidate"] = NSNull() }
        }
        output = value
      }
    }
    FileHandle.standardOutput.write(
      try HarnessRuntime.canonicalJSON(output, ensureASCII: true) + Data([0x0a]))
    return output["status"] as? String == "resolved"
      ? 0
      : output["status"] as? String == "needs_selection"
        ? 3 : output["status"] as? String == "unavailable" ? 4 : 2
  }
}
