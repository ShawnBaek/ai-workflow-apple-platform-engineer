import Foundation

/// Discovers recent session metadata and returns only metadata fields.
public enum SessionInventory {
  public struct Entry: Codable, Equatable, Sendable {
    public var client: String
    public var id: String
    public var cwd: String
    public var branch: String?
    public var modified: Date
  }

  public struct Scan: Sendable {
    public var sessions: [Entry]
    public var warnings: [String]
  }

  private static let maximumEntries = 20_000
  private static let headerBytes = 1024 * 1024
  private static let tailBytes = 1024 * 1024

  public static func scan(
    home: String, environment: [String: String], ownClient: String? = nil, ownID: String? = nil,
    now: Date = Date(), within: TimeInterval = 1_800, deadline: Date? = nil
  ) -> Scan {
    var result = Scan(sessions: [], warnings: [])
    var candidates = [Entry]()
    var visited = 0
    var stopped = false
    let fileManager = FileManager.default
    let claudeRoot = URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude")
    let codexRoot = URL(fileURLWithPath: environment["CODEX_HOME"] ?? home + "/.codex")

    func append(_ entry: Entry) {
      guard !(entry.client == ownClient && entry.id == ownID) else { return }
      candidates.append(entry)
    }

    func checkBudget() -> Bool {
      guard !stopped else { return false }
      if let deadline, Date() >= deadline {
        result.warnings.append("session inventory deadline reached; results are partial")
        stopped = true
        return false
      }
      if visited >= maximumEntries {
        result.warnings.append("session inventory entry limit reached; results are partial")
        stopped = true
        return false
      }
      return true
    }

    func inspect(_ url: URL, client: String, countVisit: Bool = true) -> Bool {
      if countVisit && !visit() { return false }
      guard !isSymlink(url, fileManager: fileManager) else { return true }
      do {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return true }
        let rawModified = attributes[.modificationDate] as? Date ?? now
        let age = max(0, now.timeIntervalSince(rawModified))
        guard age <= max(0, within) else { return true }
        let modified = min(rawModified, now)
        let metadata: Metadata?
        switch client {
        case "codex": metadata = try codexMetadata(url)
        default: metadata = try claudeMetadata(url)
        }
        guard let metadata else {
          result.warnings.append("unreadable session metadata at \(url.path)")
          return true
        }
        let fallback = url.deletingPathExtension().lastPathComponent
        let id = metadata.id?.isEmpty == false ? metadata.id! : client == "claude" ? fallback : ""
        guard !id.isEmpty, let cwd = metadata.cwd, cwd.hasPrefix("/") else {
          result.warnings.append("malformed session metadata at \(url.path)")
          return true
        }
        append(
          Entry(
            client: client, id: id, cwd: normalized(cwd), branch: metadata.branch,
            modified: modified))
      } catch {
        result.warnings.append("could not inspect session metadata at \(url.path)")
      }
      return true
    }

    func visit() -> Bool {
      guard checkBudget() else { return false }
      visited += 1
      return true
    }

    enumerate(
      claudeRoot.appendingPathComponent("projects", isDirectory: true), fileManager: fileManager,
      onWarning: { result.warnings.append($0) },
      body: { enumerator, url in
        guard visit() else { return false }
        if isSymlink(url, fileManager: fileManager) {
          enumerator.skipDescendants()
          return true
        }
        let level = enumerator.level
        if isDirectory(url, fileManager: fileManager) {
          if level >= 2 { enumerator.skipDescendants() }
          return true
        }
        guard level == 2, url.pathExtension == "jsonl" else { return true }
        return inspect(url, client: "claude", countVisit: false)
      })

    enumerate(
      codexRoot.appendingPathComponent("sessions", isDirectory: true), fileManager: fileManager,
      onWarning: { result.warnings.append($0) },
      body: { enumerator, url in
        guard visit() else { return false }
        if isSymlink(url, fileManager: fileManager) {
          enumerator.skipDescendants()
          return true
        }
        let level = enumerator.level
        if isDirectory(url, fileManager: fileManager) {
          if level == 1,
            url.lastPathComponent.range(of: #"^\d{4}$"#, options: .regularExpression) == nil
          {
            enumerator.skipDescendants()
          }
          if level >= 4 { enumerator.skipDescendants() }
          return true
        }
        guard level == 4, url.pathExtension == "jsonl" else { return true }
        return inspect(url, client: "codex", countVisit: false)
      })
    candidates.sort {
      if $0.modified != $1.modified { return $0.modified > $1.modified }
      if $0.client != $1.client { return $0.client < $1.client }
      if $0.id != $1.id { return $0.id < $1.id }
      return $0.cwd < $1.cwd
    }
    var seen = Set<String>()
    result.sessions = candidates.filter { seen.insert($0.client + "\u{0}" + $0.id).inserted }
    return result
  }

  private struct Metadata {
    var id: String? = nil
    var cwd: String? = nil
    var branch: String? = nil
  }

  private static func enumerate(
    _ root: URL, fileManager: FileManager, onWarning: @escaping (String) -> Void,
    body: (FileManager.DirectoryEnumerator, URL) -> Bool
  ) {
    do {
      let attributes = try fileManager.attributesOfItem(atPath: root.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        onWarning("session directory is not a readable directory: \(root.path)")
        return
      }
    } catch {
      let error = error as NSError
      if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
        onWarning("could not inspect session directory \(root.path)")
      }
      return
    }
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles],
        errorHandler: { url, _ in
          onWarning("could not enumerate session directory \(url.path)")
          return true
        })
    else {
      onWarning("could not enumerate session directory \(root.path)")
      return
    }
    while let url = enumerator.nextObject() as? URL {
      if !body(enumerator, url) { break }
    }
  }

  private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    var value: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
  }

  private static func isSymlink(_ url: URL, fileManager: FileManager) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
    return attributes[.type] as? FileAttributeType == .typeSymbolicLink
  }

  private static func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func claudeMetadata(_ url: URL) throws -> Metadata? {
    let lines = try lines(from: tail(url, limit: tailBytes))
    for line in lines.reversed() {
      guard let object = json(line) else { continue }
      let id = object["sessionId"] as? String
      let cwd = object["cwd"] as? String
      let branch = object["gitBranch"] as? String
      if let cwd, !cwd.isEmpty {
        return Metadata(id: id, cwd: cwd, branch: branch)
      }
    }
    return nil
  }

  private static func codexMetadata(_ url: URL) throws -> Metadata? {
    var result = Metadata()
    for line in try lines(from: header(url, limit: headerBytes)) {
      guard let object = json(line), object["type"] as? String == "session_meta",
        let payload = object["payload"] as? [String: Any]
      else { continue }
      result.id = payload["id"] as? String
      result.cwd = payload["cwd"] as? String
      result.branch = (payload["git"] as? [String: Any])?["branch"] as? String
      break
    }
    // The initial ID can be outside the tail; tail context may only refine the working directory.
    for line in try lines(from: tail(url, limit: tailBytes)).reversed() {
      guard let object = json(line), object["type"] as? String == "turn_context",
        let payload = object["payload"] as? [String: Any]
      else { continue }
      if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
        result.cwd = cwd
        break
      }
    }
    return result.id == nil && result.cwd == nil && result.branch == nil ? nil : result
  }

  private static func header(_ url: URL, limit: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return handle.readData(ofLength: limit)
  }

  private static func tail(_ url: URL, limit: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    try handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
    return handle.readData(ofLength: limit)
  }

  private static func lines(from data: Data) throws -> [Data] {
    data.split(separator: 10, omittingEmptySubsequences: true).map(Data.init)
  }

  private static func json(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
