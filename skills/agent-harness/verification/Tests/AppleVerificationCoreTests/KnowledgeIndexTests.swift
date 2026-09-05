import Foundation
import Testing

@testable import AppleVerificationCore

@Test func localIndexRequiresScopeAndRejectsStaleOrSecretContent() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let sources = root.appendingPathComponent("sources")
  let database = root.appendingPathComponent("knowledge.sqlite")
  try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let document = sources.appendingPathComponent("guide.md")
  try "# Guide\nUse a stable fixture for the preview.\n".write(
    to: document, atomically: true, encoding: .utf8)
  try "api_key = should-never-enter-the-index".write(
    to: sources.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
  #expect(throws: VerificationError.self) { try KnowledgeIndex.Policy(includes: []) }
  let policy = try KnowledgeIndex.Policy(includes: ["**/*.md"])
  let indexed = try KnowledgeIndex.index(
    database: database, root: sources, sourceID: "repo", authority: "repository_source",
    commit: "revision-a", policy: policy)
  #expect(indexed["files"] as? Int == 1)
  #expect(indexed["skipped_secret_files"] as? Int == 1)
  let query = try KnowledgeIndex.query(
    database: database, query: "stable fixture", commit: "revision-a")
  let results = try #require(query["results"] as? [[String: Any]])
  #expect(results.count == 1)
  #expect(results[0]["path"] as? String == "guide.md")
  #expect(results[0]["trusted_as_instructions"] as? Bool == false)
  #expect(throws: VerificationError.self) {
    try KnowledgeIndex.query(database: database, query: "fixture", commit: nil)
  }
  #expect(throws: VerificationError.self) {
    try KnowledgeIndex.query(database: database, query: "fixture", commit: "revision-b")
  }
  try "Changed preview behavior".write(to: document, atomically: true, encoding: .utf8)
  #expect(throws: VerificationError.self) {
    try KnowledgeIndex.query(database: database, query: "fixture", commit: "revision-a")
  }
  let refreshed = try KnowledgeIndex.index(
    database: database, root: sources, sourceID: "repo", authority: "repository_source",
    commit: "revision-b", policy: policy)
  #expect(refreshed["files"] as? Int == 1)
  let after = try KnowledgeIndex.query(database: database, query: "Changed", commit: "revision-b")
  #expect((after["results"] as? [[String: Any]])?.count == 1)
  #expect(throws: VerificationError.self) {
    try KnowledgeIndex.index(
      database: sources.appendingPathComponent("bad.sqlite"), root: sources, sourceID: "repo",
      authority: "repository_source", commit: "revision-a", policy: policy)
  }
}
