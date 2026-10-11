import Darwin
import Foundation
import Testing

@testable import AppleVerificationCore

private let hook = GateRunSupport.repositoryRoot.appendingPathComponent(
  "plugin/hooks/session-status.sh")

/// A fixture home with a repository, a linked worktree of it, a fresh Simulator cache and two
/// session transcripts: this session's and another one's.
private struct Fixture {
  let home: URL
  let repository: URL
  let worktree: URL
  let data: URL

  init() throws {
    let created = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    // Git reports real paths (/private/var/...); `resolvingSymlinksInPath` would strip
    // /private, so take the home from realpath(3).
    let real = try #require(realpath(created.path, nil))
    defer { free(real) }
    home = URL(fileURLWithPath: String(cString: real))
    repository = home.appendingPathComponent("app with space")
    worktree = home.appendingPathComponent("worktree/feature")
    data = home.appendingPathComponent("plugin-data")
    let manager = FileManager.default
    try manager.createDirectory(at: repository, withIntermediateDirectories: true)
    try manager.createDirectory(at: data, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], in: repository)
    try git(["commit", "-q", "--allow-empty", "-m", "one"], in: repository)
    try git(["worktree", "add", "-q", "-b", "feature/x", worktree.path], in: repository)
    try Data("changed".utf8).write(to: worktree.appendingPathComponent("file.txt"))
    try JSONSerialization.data(withJSONObject: ["iPhone Fixture"]).write(
      to: data.appendingPathComponent("booted-simulators.json"))
    let projects = home.appendingPathComponent(".claude/projects/fixture")
    try manager.createDirectory(at: projects, withIntermediateDirectories: true)
    for (id, cwd, branch) in [
      ("own-session", repository.path, "main"), ("other-session", "/tmp/other", "fix/y"),
    ] {
      let entry = try JSONSerialization.data(withJSONObject: [
        "cwd": cwd, "gitBranch": branch, "sessionId": id,
      ])
      try (Data("{\"type\":\"summary\"}\n".utf8) + entry + Data("\n".utf8)).write(
        to: projects.appendingPathComponent("\(id).jsonl"))
    }
  }

  func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      ["-C", directory.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com"]
      + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
  }

  /// Runs the hook from `cwd` and returns its decoded output.
  func status(cwd: URL, event: String = "UserPromptSubmit") throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [hook.path]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment["CLAUDE_PLUGIN_DATA"] = data.path
    process.environment = environment
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    try process.run()
    stdin.fileHandleForWriting.write(
      try JSONSerialization.data(withJSONObject: [
        "cwd": cwd.path, "session_id": "own-session", "hook_event_name": event,
      ]))
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
  }
}

@Test func sessionStatusShowsTheWorktreeSimulatorsAndOtherSessions() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  let output = try fixture.status(cwd: fixture.worktree)
  let shown = try #require(output["systemMessage"] as? String).split(separator: "\n").map(
    String.init)
  #expect(
    shown.first
      == "Directory ~/worktree/feature · feature/x (no upstream) 1 changed · worktree of "
      + "~/app with space")
  #expect(shown.contains("Simulators: 1 booted (iPhone Fixture)"))
  // This session's own transcript is not another session.
  #expect(shown.contains("Other Claude sessions active in 30 min: 1 (/tmp/other@fix/y 0m)"))
  let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
  #expect(specific["hookEventName"] as? String == "UserPromptSubmit")
  let context = try #require(specific["additionalContext"] as? String)
  #expect(context.hasPrefix("Live session environment"))
  #expect(context.contains("- Simulators: 1 booted (iPhone Fixture)"))
}

@Test func sessionStatusOutsideGitStillAnswers() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  let outside = fixture.home.appendingPathComponent("plain")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  let output = try fixture.status(cwd: outside, event: "SessionStart")
  let shown = try #require(output["systemMessage"] as? String)
  #expect(shown.hasPrefix("Directory ~/plain · not a Git repository"))
  let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
  #expect(specific["hookEventName"] as? String == "SessionStart")
}
