import Foundation
import Testing

@testable import AppleVerificationCore

@Test func retainsBothClientsAndExcludesOnlyExactOwnIdentity() throws {
  try withHome { home, write in
    let claude = home.appendingPathComponent("custom-claude")
    try write(
      "custom-claude/projects/demo/a.jsonl",
      #"{"sessionId":"same","cwd":"/tmp/claude","gitBranch":"main"}"#)
    try write(
      ".codex/sessions/2026/10/18/a.jsonl",
      #"{"type":"session_meta","payload":{"id":"same","cwd":"/tmp/codex","git":{"branch":"feature"}}}"#
    )
    let both = SessionInventory.scan(
      home: home.path, environment: ["CLAUDE_CONFIG_DIR": claude.path])
    #expect(Set(both.sessions.map(\.client)) == ["claude", "codex"])
    let scan = SessionInventory.scan(
      home: home.path, environment: ["CLAUDE_CONFIG_DIR": claude.path], ownClient: "codex",
      ownID: "same")
    #expect(scan.sessions.count == 1)
    #expect(scan.sessions[0].client == "claude")
    #expect(scan.sessions[0].id == "same")
  }
}

@Test func honorsConfiguredRootsAndTurnContextCwd() throws {
  try withHome { home, write in
    try write(
      "custom-codex/sessions/2026/10/18/a.jsonl",
      #"{"type":"session_meta","payload":{"id":"a","cwd":"/old","git":{"branch":"dev"}}}"# + "\n"
        + #"{"type":"turn_context","payload":{"cwd":"/new"}}"#)
    let scan = SessionInventory.scan(
      home: home.path, environment: ["CODEX_HOME": home.appendingPathComponent("custom-codex").path]
    )
    #expect(scan.sessions.map(\.cwd) == ["/new"])
    #expect(scan.sessions.first?.branch == "dev")
  }
}

@Test func claudeProgressWithoutCwdDoesNotHideTheLastRecordedPlace() throws {
  try withHome { home, write in
    try write(
      ".claude/projects/demo/a.jsonl",
      #"{"sessionId":"a","cwd":"/recorded","gitBranch":"main"}"# + "\n"
        + #"{"type":"progress","sessionId":"a"}"#)
    let scan = SessionInventory.scan(home: home.path, environment: [:])
    #expect(scan.sessions.map(\.cwd) == ["/recorded"])
    #expect(scan.warnings.isEmpty)
  }
}

@Test func aDeadlineReportsPartialRatherThanClaimingNoSessions() throws {
  try withHome { home, write in
    try write(".claude/projects/demo/a.jsonl", #"{"sessionId":"a","cwd":"/a"}"#)
    let scan = SessionInventory.scan(home: home.path, environment: [:], deadline: .distantPast)
    #expect(scan.sessions.isEmpty)
    #expect(scan.warnings.contains(where: { $0.contains("deadline") }))
  }
}

@Test func codexHeaderIdentitySurvivesLargeBodyAndStaleAndFutureAreHandled() throws {
  try withHome { home, write in
    let metadata =
      #"{"type":"session_meta","payload":{"id":"kept","cwd":"/kept","base_instructions":""#
      + String(repeating: "m", count: 70_000) + #""}}"#
    try write(
      ".codex/sessions/2026/10/18/large.jsonl",
      metadata + "\n" + String(repeating: "x", count: 1_200_000))
    try write(".claude/projects/demo/stale.jsonl", #"{"sessionId":"old","cwd":"/old"}"#)
    try write(".claude/projects/demo/future.jsonl", #"{"sessionId":"future","cwd":"/future"}"#)
    let stale = home.appendingPathComponent(".claude/projects/demo/stale.jsonl")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: stale.path)
    let future = home.appendingPathComponent(".claude/projects/demo/future.jsonl")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: future.path)
    let scan = SessionInventory.scan(home: home.path, environment: [:], within: 10)
    #expect(Set(scan.sessions.map(\.id)) == ["kept", "future"])
  }
}

@Test func missingRootsAreQuietAndMalformedMetadataWarns() throws {
  try withHome { home, write in
    let absent = SessionInventory.scan(home: home.path, environment: [:])
    #expect(absent.sessions.isEmpty)
    #expect(absent.warnings.isEmpty)
    try write(".claude/projects/demo/bad.jsonl", "not json")
    let scan = SessionInventory.scan(home: home.path, environment: [:])
    #expect(scan.sessions.isEmpty)
    #expect(!scan.warnings.isEmpty)
  }
}

@Test func keepsTheNewestDuplicateDeterministically() throws {
  try withHome { home, write in
    try write(".claude/projects/demo/old.jsonl", #"{"sessionId":"duplicate","cwd":"/old"}"#)
    try write(".claude/projects/demo/new.jsonl", #"{"sessionId":"duplicate","cwd":"/new"}"#)
    let old = home.appendingPathComponent(".claude/projects/demo/old.jsonl")
    let new = home.appendingPathComponent(".claude/projects/demo/new.jsonl")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -20)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: new.path)
    let scan = SessionInventory.scan(home: home.path, environment: [:], within: 60)
    #expect(scan.sessions.map(\.cwd) == ["/new"])
  }
}

private func withHome(
  _ body: (URL, (_ relative: String, _ contents: String) throws -> Void) throws -> Void
) throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  try body(home) { relative, contents in
    let url = home.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }
}
