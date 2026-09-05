import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Optional local FTS retrieval. Source text is data, never instructions.
public enum KnowledgeIndex {
  private static let excluded: Set<String> = [
    ".git", ".build", ".swiftpm", ".codex", ".claude", "DerivedData", "SourcePackages",
    "xcuserdata", "node_modules", "Pods", "Archives",
  ]
  private static let secrets = [
    #"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#,
    #"(?im)^\s*(?:api[_-]?key|access[_-]?token|auth[_-]?token|password|secret|token)\s*[:=]\s*[^\s#][^\r\n]*$"#,
    #"(?i)"(?:private_key|client_secret|refresh_token)"\s*:\s*"[^"\r\n]+""#,
    #"(?is)<key>(?:API_KEY|CLIENT_ID|GOOGLE_APP_ID|GCM_SENDER_ID)</key>\s*<string>[^<]+</string>"#,
    #"\b(?:sk|ghp|github_pat)_[A-Za-z0-9_-]{16,}\b"#,
  ]
  public struct Policy: Codable, Sendable {
    public let includes: [String]
    public let allow_structured: Bool
    public init(includes: [String], allowStructured: Bool = false) throws {
      guard !includes.isEmpty, includes.count <= 64,
        includes.allSatisfy({
          !$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
            && $0.utf8.count <= 1_024
        })
      else {
        throw VerificationError.invalid(
          "An explicit bounded repository-relative include policy is required")
      }
      self.includes = Array(Set(includes)).sorted()
      self.allow_structured = allowStructured
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        includes: container.decode([String].self, forKey: .includes),
        allowStructured: container.decode(Bool.self, forKey: .allow_structured))
    }
  }
  private struct FileRecord {
    let path: String
    let text: String
    let hash: String
  }
  private static func matches(_ relative: String, pattern: String) -> Bool {
    // Match the legacy case-sensitive glob contract, including character
    // classes and * crossing separators; backslashes remain literal.
    return fnmatch(pattern, relative, FNM_NOESCAPE) == 0
      || (pattern.hasPrefix("**/")
        && fnmatch(String(pattern.dropFirst(3)), relative, FNM_NOESCAPE) == 0)
  }
  private static func visit(root: URL, policy: Policy, _ consume: (FileRecord) throws -> Void)
    throws -> (hash: String, files: Int, skipped: Int)
  {
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    guard (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
      throw VerificationError.invalid("Index source root is missing")
    }
    let suffixes = Set(["md", "txt", "swift"]).union(
      policy.allow_structured ? ["json", "yaml", "yml", "plist"] : [])
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: Array(keys))
    else { throw VerificationError.invalid("Cannot enumerate index source") }
    var files = [URL]()
    for case let file as URL in enumerator {
      let info = try file.resourceValues(forKeys: keys)
      if info.isDirectory == true {
        if excluded.contains(file.lastPathComponent) || info.isSymbolicLink == true {
          enumerator.skipDescendants()
        }
        continue
      }
      guard info.isRegularFile == true, info.isSymbolicLink != true,
        suffixes.contains(file.pathExtension.lowercased()), (info.fileSize ?? Int.max) <= 1_000_000
      else { continue }
      let resolved = file.resolvingSymlinksInPath()
      guard resolved.path.hasPrefix(root.path + "/") else { continue }
      let relative = String(resolved.path.dropFirst(root.path.count + 1))
      guard !relative.split(separator: "/").contains(where: { excluded.contains(String($0)) }),
        ![".env", "id_rsa", "id_ed25519"].contains(file.lastPathComponent),
        policy.includes.contains(where: { matches(relative, pattern: $0) })
      else { continue }
      files.append(resolved)
      guard files.count <= 10_000 else {
        throw VerificationError.invalid("Index scope exceeds 10000 files; narrow --include")
      }
    }
    var digest = SHA256()
    var count = 0
    var skipped = 0
    var totalBytes = 0
    for file in files.sorted(by: { $0.path < $1.path }) {
      let data = try HarnessRuntime.readRegularFile(file, maximumBytes: 1_000_000)
      guard data.count <= 1_000_000 else {
        throw VerificationError.invalid("Index input grew beyond 1 MB")
      }
      totalBytes += data.count
      guard totalBytes <= 64 * 1_024 * 1_024 else {
        throw VerificationError.invalid("Index scope exceeds 64 MiB; narrow --include")
      }
      guard let text = String(data: data, encoding: .utf8),
        !secrets.contains(where: { text.range(of: $0, options: .regularExpression) != nil })
      else {
        skipped += 1
        continue
      }
      let relative = String(file.path.dropFirst(root.path.count + 1))
      let hash = HarnessRuntime.sha256(data)
      digest.update(data: Data(relative.utf8))
      digest.update(data: Data(hash.utf8))
      try consume(FileRecord(path: relative, text: text, hash: hash))
      count += 1
    }
    return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count, skipped)
  }

  public static func index(
    database: URL, root: URL, sourceID: String, authority: String, commit: String?, policy: Policy,
    allowDatabaseInsideRoot: Bool = false
  ) throws -> [String: Any] {
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    let database = database.standardizedFileURL.resolvingSymlinksInPath()
    guard !sourceID.isEmpty, sourceID.utf8.count <= 256,
      ["accepted_spec", "repository_source", "pinned_sample", "approved_analysis"].contains(
        authority), authority != "repository_source" || !(commit ?? "").isEmpty
    else {
      throw VerificationError.invalid(
        "Invalid index source identity, authority, or missing repository commit")
    }
    guard allowDatabaseInsideRoot || !database.path.hasPrefix(root.path + "/") else {
      throw VerificationError.invalid(
        "Choose an external database or explicitly allow the reviewed ignored location")
    }
    try FileManager.default.createDirectory(
      at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sql = try Database(database, readonly: false)
    try sql.execute("PRAGMA journal_mode=WAL")
    try sql.execute(
      "CREATE TABLE IF NOT EXISTS sources (source_id TEXT PRIMARY KEY, authority TEXT NOT NULL, root TEXT NOT NULL, commit_sha TEXT, indexed_at TEXT NOT NULL, corpus_hash TEXT NOT NULL, policy_json TEXT)"
    )
    try sql.execute(
      "CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(source_id UNINDEXED, authority UNINDEXED, path UNINDEXED, start_line UNINDEXED, end_line UNINDEXED, commit_sha UNINDEXED, content_hash UNINDEXED, content, tokenize='unicode61')"
    )
    if !(try sql.rows("PRAGMA table_info(sources)")).contains(where: {
      $0[1] as? String == "policy_json"
    }) {
      try sql.execute("ALTER TABLE sources ADD COLUMN policy_json TEXT")
    }
    try sql.execute("BEGIN IMMEDIATE")
    do {
      try sql.execute("DELETE FROM chunks WHERE source_id = ?", [sourceID])
      var chunks = 0
      let corpus = try visit(root: root, policy: policy) { file in
        var lines = file.text.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        for offset in stride(from: 0, to: lines.count, by: 70) {
          let end = min(lines.count, offset + 80)
          let body = lines[offset..<end].joined(separator: "\n").trimmingCharacters(
            in: .whitespacesAndNewlines)
          if !body.isEmpty {
            try sql.execute(
              "INSERT INTO chunks VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
              [
                sourceID, authority, file.path, offset + 1, end, commit ?? NSNull() as Any,
                file.hash, body,
              ])
            chunks += 1
          }
          if end == lines.count { break }
        }
      }
      let policyJSON = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
      try sql.execute(
        "INSERT OR REPLACE INTO sources VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
          sourceID, authority, root.path, commit ?? NSNull() as Any, HarnessRuntime.timestamp(),
          corpus.hash, policyJSON,
        ])
      try sql.execute("COMMIT")
      return [
        "source_id": sourceID, "files": corpus.files, "chunks": chunks,
        "skipped_secret_files": corpus.skipped,
      ]
    } catch {
      try? sql.execute("ROLLBACK")
      throw error
    }
  }

  private static func sources(_ sql: Database, expectedCommit: String?) throws -> [[String: Any]] {
    try sql.rows(
      "SELECT source_id, authority, root, commit_sha, indexed_at, corpus_hash, policy_json FROM sources ORDER BY source_id"
    ).map { row in
      let raw = row[6] as? String
      let policy = raw.flatMap { try? JSONDecoder().decode(Policy.self, from: Data($0.utf8)) }
      let root = URL(fileURLWithPath: row[2] as? String ?? "/nonexistent")
      let current = policy.flatMap { try? visit(root: root, policy: $0) { _ in } }
      let repository = row[1] as? String == "repository_source"
      let staleCommit = repository && (expectedCommit == nil || row[3] as? String != expectedCommit)
      return [
        "source_id": row[0], "authority": row[1], "root": row[2], "commit_sha": row[3],
        "indexed_at": row[4], "corpus_hash": row[5],
        "policy": raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
          ?? NSNull(), "stale_for_commit": staleCommit,
        "stale_for_content": current?.hash != row[5] as? String,
      ]
    }
  }
  public static func status(database: URL, commit: String?) throws -> [String: Any] {
    ["sources": try sources(Database(database, readonly: true), expectedCommit: commit)]
  }
  public static func query(database: URL, query: String, limit: Int = 5, commit: String?) throws
    -> [String: Any]
  {
    guard (1...20).contains(limit), query.utf8.count <= 4_096 else {
      throw VerificationError.invalid("Query requires a limit of 1...20 and at most 4096 bytes")
    }
    let regex = try NSRegularExpression(pattern: #"[\w.-]+"#)
    let matches = regex.matches(in: query, range: NSRange(query.startIndex..., in: query))
    let tokens = matches.map {
      "\""
        + (query as NSString).substring(with: $0.range).replacingOccurrences(of: "\"", with: "\"\"")
        + "\""
    }
    guard !tokens.isEmpty else {
      throw VerificationError.invalid("Query contains no searchable tokens")
    }
    let sql = try Database(database, readonly: true)
    let stale = try sources(sql, expectedCommit: commit).filter {
      $0["stale_for_commit"] as? Bool == true || $0["stale_for_content"] as? Bool == true
    }
    guard stale.isEmpty else {
      throw VerificationError.invalid(
        "Index is stale or lacks its policy; re-index: "
          + stale.compactMap { $0["source_id"] as? String }.joined(separator: ", "))
    }
    let rows = try sql.rows(
      "SELECT chunks.source_id, chunks.authority, chunks.path, chunks.start_line, chunks.end_line, chunks.commit_sha, chunks.content_hash, snippet(chunks, 7, '', '', ' … ', 24), bm25(chunks), sources.indexed_at, sources.root FROM chunks JOIN sources ON sources.source_id = chunks.source_id WHERE chunks MATCH ? ORDER BY bm25(chunks), chunks.source_id, chunks.path, chunks.start_line LIMIT ?",
      [tokens.joined(separator: " AND "), limit])
    let keys = [
      "source_id", "authority", "path", "start_line", "end_line", "commit_sha", "content_hash",
      "excerpt", "score", "indexed_at", "root",
    ]
    return [
      "query": query,
      "results": rows.map { row in
        var result = Dictionary(uniqueKeysWithValues: zip(keys, row))
        result["fresh"] = true
        result["trusted_as_instructions"] = false
        return result
      },
    ]
  }
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    guard let command = arguments.first, ["index", "query", "status"].contains(command) else {
      throw VerificationError.invalid("knowledge requires index, query, or status")
    }
    let args = try RuntimeArguments(
      Array(arguments.dropFirst()), flags: ["--allow-structured", "--allow-database-inside-root"],
      repeated: ["--include"])
    try args.allow([
      "--database", "--root", "--source-id", "--authority", "--commit", "--include",
      "--allow-structured", "--allow-database-inside-root", "--query", "--limit",
    ])
    let database = URL(fileURLWithPath: try args.required("--database"))
    let commit = args.value("--commit")
    let result: [String: Any]
    switch command {
    case "index":
      result = try index(
        database: database, root: URL(fileURLWithPath: args.required("--root")),
        sourceID: args.required("--source-id"), authority: args.required("--authority"),
        commit: commit,
        policy: Policy(
          includes: args.values("--include"), allowStructured: args.flag("--allow-structured")),
        allowDatabaseInsideRoot: args.flag("--allow-database-inside-root"))
    case "query":
      guard let limit = Int(args.value("--limit") ?? "5") else {
        throw VerificationError.invalid("Invalid result limit")
      }
      result = try query(
        database: database, query: args.required("--query"), limit: limit, commit: commit)
    default: result = try status(database: database, commit: commit)
    }
    FileHandle.standardOutput.write(try HarnessRuntime.canonicalJSON(result, ensureASCII: false))
    print()
    return 0
  }
}

private final class Database {
  private var handle: OpaquePointer?
  init(_ url: URL, readonly: Bool) throws {
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw VerificationError.invalid("Database cannot be a symlink")
    }
    let flags = readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      let message = error
      sqlite3_close(handle)
      handle = nil
      throw VerificationError.invalid(message)
    }
    sqlite3_busy_timeout(handle, 5_000)
  }
  deinit { sqlite3_close(handle) }
  private var error: String {
    handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
  }
  func execute(_ query: String, _ values: [Any] = []) throws { _ = try rows(query, values) }
  func rows(_ query: String, _ values: [Any] = []) throws -> [[Any]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
      throw VerificationError.invalid(error)
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in values.enumerated() {
      let code: Int32
      if value is NSNull {
        code = sqlite3_bind_null(statement, Int32(index + 1))
      } else if let integer = value as? Int {
        code = sqlite3_bind_int64(statement, Int32(index + 1), sqlite3_int64(integer))
      } else if let string = value as? String {
        code = sqlite3_bind_text(statement, Int32(index + 1), string, -1, transient)
      } else {
        throw VerificationError.invalid("Unsupported SQLite parameter")
      }
      guard code == SQLITE_OK else { throw VerificationError.invalid(error) }
    }
    var result = [[Any]]()
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return result }
      guard status == SQLITE_ROW else { throw VerificationError.invalid(error) }
      var row = [Any]()
      for i in 0..<sqlite3_column_count(statement) {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(statement, i)))
        case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, i))
        case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(statement, i)))
        default: row.append(NSNull())
        }
      }
      result.append(row)
      guard result.count <= 10_000 else {
        throw VerificationError.invalid("SQLite result exceeds bound")
      }
    }
  }
}
