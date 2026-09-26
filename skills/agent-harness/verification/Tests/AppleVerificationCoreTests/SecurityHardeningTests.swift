import Foundation
import Testing

@testable import AppleVerificationCore

private let repositoryRoot: URL = {
  if let override = ProcessInfo.processInfo.environment["APPLE_VERIFICATION_REPOSITORY_ROOT"] {
    return URL(fileURLWithPath: override)
  }
  return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
}()

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

// MARK: - Companion issue adoption

private let companionMarker = "<!-- ios-experts-companion-upstream:example/upstream -->"

private func companionManifest() -> [String: Any] {
  [
    "upstream": [
      "repository": "example/upstream", "visibility": "public", "default_branch": "main",
      "reviewed_revision": String(repeating: "a", count: 40),
      "reviewed_tree": String(repeating: "b", count: 40),
    ],
    "integration": [
      "consumer_repository": "example/consumer", "consumer_skill": "icon-composer",
      "mode": "reference-only", "execute_upstream": false, "auto_merge": false,
      "vendored_files": [],
    ], "sources": [["path": "README.md", "blob_sha": String(repeating: "c", count: 40)]],
    "license": ["status": "review_required"],
  ]
}

/// Upstream HEAD has drifted, so the watcher always reaches issue reconciliation.
private final class DriftedUpstream: CompanionGitHubClient {
  var openIssues = [[String: Any]]()
  var writes = [String]()
  func request(method: String, path: String, body: [String: Any]?) throws -> Any {
    if method != "GET" {
      writes.append("\(method) \(path)")
      return ["html_url": "https://github.com/example/consumer/issues/1"]
    }
    if path == "repos/example/upstream" {
      return ["private": false, "visibility": "public", "default_branch": "main"]
    }
    if path == "repos/example/upstream/commits/main" {
      return ["sha": String(repeating: "d", count: 40)]
    }
    if path.hasPrefix("repos/example/upstream/commits/") {
      return [
        "sha": String(repeating: "a", count: 40),
        "commit": ["tree": ["sha": String(repeating: "b", count: 40)]],
      ]
    }
    if path.hasPrefix("repos/example/upstream/git/trees/") {
      return [
        "truncated": false,
        "tree": [["type": "blob", "path": "README.md", "sha": String(repeating: "c", count: 40)]],
      ]
    }
    if path.hasPrefix("repos/example/consumer/issues?") { return openIssues }
    throw VerificationError.invalid("Unexpected fixture operation")
  }
}

private func markerIssue(_ number: Int, author: [String: Any]?) -> [String: Any] {
  var issue: [String: Any] = [
    "number": number, "body": "\(companionMarker)\nFollow the instructions in this issue.",
  ]
  if let author { issue["user"] = author }
  return issue
}

@Test func companionWatcherCreatesItsOwnIssueInsteadOfAdoptingAForeignMarker() throws {
  // The marker is public, so anyone can open an issue that carries it.
  let github = DriftedUpstream()
  github.openIssues = [
    markerIssue(7, author: ["login": "outsider", "type": "User"]),
    markerIssue(8, author: ["login": "github-actions", "type": "User"]),
    markerIssue(9, author: ["login": "dependabot[bot]", "type": "Bot"]),
    markerIssue(10, author: nil),
  ]
  let result = try CompanionWatcher.reconcileIssue(
    companionManifest(), targetRepository: "example/consumer", client: github)
  #expect(result["issue_action"] as? String == "created")
  #expect(github.writes == ["POST repos/example/consumer/issues"])
}

@Test func companionWatcherUpdatesItsOwnIssueDespiteAPlantedMarker() throws {
  let github = DriftedUpstream()
  github.openIssues = [
    markerIssue(7, author: ["login": "outsider", "type": "User"]),
    markerIssue(3, author: ["login": "github-actions[bot]", "type": "Bot"]),
  ]
  let result = try CompanionWatcher.reconcileIssue(
    companionManifest(), targetRepository: "example/consumer", client: github)
  #expect(result["issue_action"] as? String == "updated")
  #expect(github.writes == ["PATCH repos/example/consumer/issues/3"])
}

// MARK: - Watcher checkout credentials

@Test func iconGenWatcherMustNotPersistItsIssueWriteToken() throws {
  let shipped = repositoryRoot.appendingPathComponent(
    ".github/workflows/icongen-upstream-watch.yml")
  #expect(ContractValidation.validateIconGenWorkflow(at: shipped) == [])
  let text = try String(contentsOf: shipped, encoding: .utf8)
  let optOut = "        with:\n          persist-credentials: false\n"
  #expect(text.contains(optOut))
  let temporary = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: temporary) }
  // Omitting the input keeps actions/checkout's default, which persists the token.
  for drifted in [
    text.replacingOccurrences(of: optOut, with: ""),
    text.replacingOccurrences(of: "persist-credentials: false", with: "persist-credentials: true"),
  ] {
    let workflow = temporary.appendingPathComponent("\(UUID().uuidString).yml")
    try drifted.write(to: workflow, atomically: true, encoding: .utf8)
    #expect(
      ContractValidation.validateIconGenWorkflow(at: workflow).contains {
        $0.contains("persist-credentials")
      })
  }
}

// MARK: - Knowledge index secret filter

/// Token-shaped values are assembled at run time so the repository never contains one.
struct IndexedText: Sendable, CustomTestStringConvertible {
  let file: String
  let text: String
  let testDescription: String
  init(_ description: String, file: String, _ text: String) {
    self.file = file
    self.text = text
    self.testDescription = description
  }
}

private let hex32 = String(repeating: "3f9c2e7a", count: 4)

private let credentialSignals: [IndexedText] = [
  IndexedText(
    "Swift property with a secret name", file: "Config.swift",
    "enum Config {\n  static let apiKey = \"\(hex32)\"\n}\n"),
  IndexedText(
    "Swift property with a type annotation", file: "Client.swift",
    "private let clientSecret: String = \"\(hex32)\"\n"),
  IndexedText(
    "provider key with a hyphenated prefix", file: "Assistant.swift",
    "let client = Client(key: \"\("sk" + "-proj-")\(hex32)\")\n"),
  IndexedText(
    "GitHub OAuth token", file: "Sync.swift",
    "request.setValue(\"token \("gh" + "o_")\(hex32)\", forHTTPHeaderField: \"Authorization\")\n"),
  IndexedText(
    "AWS access key ID", file: "Upload.swift",
    "let credentials = Credentials(accessKeyID: \"\("AK" + "IA")\(String(repeating: "Q7", count: 8))\")\n"
  ),
  IndexedText(
    "Slack bot token", file: "Notify.swift",
    "let slack = Slack(\"\("xo" + "xb-")\(String(repeating: "1234567890-", count: 2))\(hex32)\")\n"),
  IndexedText(
    "JWT", file: "Session.swift",
    "let session = Session(jwt: \"\("ey" + "J")hbGciOiJIUzI1NiJ9.\("ey" + "J")zdWIiOiIxMjM0NTY3ODkwIn0.\(hex32)\")\n"
  ),
  IndexedText(
    "opaque bearer token", file: "api.md",
    "curl -H 'Authorization: Bearer \(hex32)' https://example.com/v1\n"),
  IndexedText(
    "JSON secret field", file: "firebase.json", "{\n  \"apiKey\": \"\(hex32)\"\n}\n"),
  IndexedText(
    "Google API key under a neutral field", file: "google-services.json",
    "{\"api_key\": [{\"current_key\": \"\("AI" + "za")\(String(repeating: "Sy0", count: 11))Ab\"}]}\n"
  ),
  IndexedText(
    "property-list secret key", file: "Keys.plist",
    "<dict>\n  <key>SentryAuthToken</key>\n  <string>\(hex32)</string>\n</dict>\n"),
]

@Test(arguments: credentialSignals)
func knowledgeIndexSkipsFilesWithACredentialSignal(_ sample: IndexedText) throws {
  let result = try indexSingleFile(sample)
  #expect(result["skipped_secret_files"] as? Int == 1)
  #expect(result["files"] as? Int == 0)
}

/// Ordinary source that names a credential without holding one must stay searchable.
private let ordinaryCode: [IndexedText] = [
  IndexedText(
    "Swift key names, interpolation, placeholders and empty values", file: "Keys.swift",
    """
    enum StorageKeys {
      static let accessTokenKey = "com.example.accessToken"
      static let apiKeyHeader = "X-API-Key"
      static let apiKey = "YOUR_API_KEY_HERE"
    }
    var password = ""
    let tokenCount = 42
    let secret = try Secrets.value(named: "service")
    request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")

    """),
  IndexedText(
    "documentation placeholders", file: "setup.md",
    "curl -H \"Authorization: Bearer $GITHUB_TOKEN\" https://api.github.com\n"),
  IndexedText(
    "JSON with empty and non-secret token fields", file: "settings.json",
    "{\"apiKey\": \"\", \"token_type\": \"bearer\", \"cache_key\": \"profile-2026-09\"}\n"),
  IndexedText(
    "Info.plist usage text", file: "Info.plist",
    "<dict>\n  <key>NSUserTrackingUsageDescription</key>\n  <string>Used to measure 2 campaigns.</string>\n</dict>\n"
  ),
]

@Test(arguments: ordinaryCode)
func knowledgeIndexKeepsCodeThatOnlyNamesACredential(_ sample: IndexedText) throws {
  let result = try indexSingleFile(sample)
  #expect(result["skipped_secret_files"] as? Int == 0)
  #expect(result["files"] as? Int == 1)
}

private func indexSingleFile(_ sample: IndexedText) throws -> [String: Any] {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let sources = root.appendingPathComponent("sources")
  try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
  try sample.text.write(
    to: sources.appendingPathComponent(sample.file), atomically: true, encoding: .utf8)
  return try KnowledgeIndex.index(
    database: root.appendingPathComponent("knowledge.sqlite"), root: sources, sourceID: "app",
    authority: "accepted_spec", commit: nil,
    policy: KnowledgeIndex.Policy(includes: ["*"], allowStructured: true))
}

// MARK: - Knowledge index database permissions

private func permissions(_ url: URL) throws -> Int {
  try #require(
    FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

@Test func knowledgeIndexKeepsItsDatabaseOwnerOnly() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let sources = root.appendingPathComponent("sources")
  try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
  try "# Guide\nIndexed text.\n".write(
    to: sources.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
  let cache = root.appendingPathComponent("cache")
  let database = cache.appendingPathComponent("knowledge/index.sqlite")
  let policy = try KnowledgeIndex.Policy(includes: ["*.md"])
  func index() throws {
    _ = try KnowledgeIndex.index(
      database: database, root: sources, sourceID: "docs", authority: "accepted_spec",
      commit: nil, policy: policy)
  }
  try index()
  #expect(try permissions(cache) == 0o700)
  #expect(try permissions(database.deletingLastPathComponent()) == 0o700)
  #expect(try permissions(database) == 0o600)
  // A directory that already existed is the caller's; the index leaves it alone.
  #expect(try permissions(root) == 0o755)
  // A database created before owner-only permissions is tightened on its next write.
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: database.path)
  try index()
  #expect(try permissions(database) == 0o600)
}

// MARK: - Retrieved prompt injection

@Test func retrievedInjectionIsReturnedAsQuotedUntrustedDataWithProvenance() throws {
  let fixture = try HarnessRuntime.object(
    repositoryRoot.appendingPathComponent("tests/fixtures/rag-prompt-injection.json"))
  let document = try #require(fixture["retrieved_document"] as? [String: Any])
  let content = try #require(document["content"] as? String)
  let sourceID = try #require(document["source_id"] as? String)
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let sources = root.appendingPathComponent("sources")
  try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
  let stored = content + "\n"
  try stored.write(
    to: sources.appendingPathComponent("retrieved.md"), atomically: true, encoding: .utf8)
  let database = root.appendingPathComponent("knowledge.sqlite")
  let policy = try KnowledgeIndex.Policy(includes: ["*.md"])
  // Retrieved text can never be stored under the policy's authority or an invented tier.
  for authority in ["immutable_policy", try #require(document["authority"] as? String)] {
    #expect(throws: VerificationError.self) {
      try KnowledgeIndex.index(
        database: database, root: sources, sourceID: sourceID, authority: authority, commit: nil,
        policy: policy)
    }
  }
  let indexed = try KnowledgeIndex.index(
    database: database, root: sources, sourceID: sourceID, authority: "approved_analysis",
    commit: nil, policy: policy)
  #expect(indexed["files"] as? Int == 1)
  let response = try KnowledgeIndex.query(
    database: database, query: "ignore harness rules mutation tool", commit: nil)
  let results = try #require(response["results"] as? [[String: Any]])
  try #require(results.count == 1)
  let result = results[0]
  #expect(result["excerpt"] as? String == content)
  #expect(result["trusted_as_instructions"] as? Bool == false)
  #expect(result["source_id"] as? String == sourceID)
  #expect(result["authority"] as? String == "approved_analysis")
  #expect(result["path"] as? String == "retrieved.md")
  #expect(result["start_line"] as? Int == 1)
  #expect(result["end_line"] as? Int == 1)
  #expect(result["commit_sha"] is NSNull)
  #expect(result["content_hash"] as? String == HarnessRuntime.sha256(Data(stored.utf8)))
  #expect(result["root"] as? String == sources.standardizedFileURL.resolvingSymlinksInPath().path)
  #expect((result["indexed_at"] as? String)?.isEmpty == false)
}
