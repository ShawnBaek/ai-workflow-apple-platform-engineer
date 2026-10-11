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
    try JSONSerialization.data(withJSONObject: ["names": ["iPhone Fixture"]]).write(
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
  func status(
    cwd: URL, event: String = "UserPromptSubmit", sessionID: String = "own-session",
    budget: String? = nil, gh: String = "/usr/bin/false"
  ) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [hook.path]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment["CLAUDE_PLUGIN_DATA"] = data.path
    // A loaded host can take seconds per Git call; the test checks content, not speed.
    environment["APE_STATUS_TIMEOUT"] = "60"
    environment["APE_SIMULATOR_BUDGET"] = "2"
    // A failing `gh` keeps pull requests unknown unless a test supplies its own.
    environment["APE_GH"] = gh
    if let budget { environment["APE_STATUS_BUDGET"] = budget }
    process.environment = environment
    // Keep the Simulator cache fresh however long the run has taken.
    try FileManager.default.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: data.appendingPathComponent("booted-simulators.json").path)
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    try process.run()
    stdin.fileHandleForWriting.write(
      try JSONSerialization.data(withJSONObject: [
        "cwd": cwd.path, "session_id": sessionID, "hook_event_name": event,
      ]))
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
  }
}

/// The status lines, and the one that starts with `prefix`.
private func line(_ output: [String: Any], _ prefix: String) throws -> String? {
  try #require(output["systemMessage"] as? String).split(separator: "\n").map(String.init)
    .first { $0.hasPrefix(prefix) }
}

@Test func sessionStatusShowsTheWorktreeSimulatorsHostAndOtherSessions() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  let output = try fixture.status(cwd: fixture.worktree)
  #expect(
    try line(output, "Directory")
      == "Directory ~/worktree/feature · feature/x (no upstream) 1 changed · worktree of "
      + "~/app with space")
  #expect(
    try line(output, "Simulators")?.hasPrefix("Simulators: 1 booted (iPhone Fixture), ") == true)
  #expect(try line(output, "Host: load ")?.contains(" on ") == true)
  // This session's own transcript is not another session.
  #expect(
    try line(output, "Other Claude sessions")?.hasPrefix(
      "Other Claude sessions active in 30 min: 1 (/tmp/other@fix/y ") == true)
  let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
  #expect(specific["hookEventName"] as? String == "UserPromptSubmit")
  let context = try #require(specific["additionalContext"] as? String)
  #expect(context.hasPrefix("Live session environment"))
  #expect(context.contains("- Simulators: 1 booted (iPhone Fixture)"))
}

@Test func sessionStatusLeavesTheGitIndexAlone() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  // A tracked file touched after the commit leaves stale stat data that a plain
  // `git status` would refresh by rewriting the index.
  let file = fixture.repository.appendingPathComponent("tracked.txt")
  try Data("one".utf8).write(to: file)
  try fixture.git(["add", "tracked.txt"], in: fixture.repository)
  try fixture.git(["commit", "-q", "-m", "tracked"], in: fixture.repository)
  let index = fixture.repository.appendingPathComponent(".git/index")
  let before = try #require(
    FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date)
  Thread.sleep(forTimeInterval: 1.1)
  try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
  _ = try fixture.status(cwd: fixture.repository)
  let after = try #require(
    FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date)
  #expect(after == before)
}

@Test func sessionStatusLabelsADetachedHeadAndKeepsSessionsWithoutAnID() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  try fixture.git(["checkout", "-q", "--detach"], in: fixture.repository)
  let output = try fixture.status(cwd: fixture.repository, sessionID: "")
  #expect(try line(output, "Directory")?.contains("· (detached ") == true)
  // Without a session id, every recent transcript counts as another session.
  #expect(
    try line(output, "Other Claude sessions")?.hasPrefix(
      "Other Claude sessions active in 30 min: 2") == true)
}

@Test func sessionStatusOutsideGitStillAnswers() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  let outside = fixture.home.appendingPathComponent("plain")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  let output = try fixture.status(cwd: outside, event: "SessionStart")
  #expect(try line(output, "Directory") == "Directory ~/plain · not a Git repository")
  let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
  #expect(specific["hookEventName"] as? String == "SessionStart")
}

/// The hook's answer before a tool call: the permission decision, or nil for none.
private func decision(_ event: [String: Any], data: URL) throws -> String? {
  try answer(event, data: data).decision
}

/// The hook's permission decision and reason before a tool call; both nil when it says nothing.
private func answer(_ event: [String: Any], data: URL) throws -> (
  decision: String?, reason: String?
) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [hook.path]
  var environment = ProcessInfo.processInfo.environment
  environment["CLAUDE_PLUGIN_DATA"] = data.path
  environment["APE_SIMULATOR_BUDGET"] = "2"
  process.environment = environment
  // However long compiling the hook takes on a loaded host, the written Simulators stay fresh: a
  // date an hour ahead never ages past the cache's minute.
  let cached = data.appendingPathComponent("booted-simulators.json")
  if FileManager.default.fileExists(atPath: cached.path) {
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: cached.path)
  }
  let stdin = Pipe()
  let stdout = Pipe()
  process.standardInput = stdin
  process.standardOutput = stdout
  try process.run()
  stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event))
  try stdin.fileHandleForWriting.close()
  let output = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  guard !output.isEmpty else { return (nil, nil) }
  let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
  let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
  #expect(specific["hookEventName"] as? String == "PreToolUse")
  return (
    specific["permissionDecision"] as? String, specific["permissionDecisionReason"] as? String
  )
}

@Test func heavyWorkOnAnOverloadedHostGoesToTheUser() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  func event(_ tool: String, _ command: String? = nil) -> [String: Any] {
    var event: [String: Any] = [
      "hook_event_name": "PreToolUse", "cwd": fixture.repository.path, "tool_name": tool,
    ]
    event["tool_input"] = command.map { ["command": $0] } ?? [:]
    return event
  }
  // Ordinary commands never ask.
  for command in [
    "ls -la", "git status", "echo swift is fun", "grep -rn xcodebuild skills",
    "git commit -m \"bump xcodebuild flags\"", "cat scripts/gate.sh", "xcodebuild -version",
    "xcrun simctl list", "swift --version", "sh -c 'echo hi'", "bash",
  ] {
    #expect(try decision(event("Bash", command), data: fixture.data) == nil, "\(command)")
  }
  // Heavy work asks exactly when the host is overloaded; near the threshold the load can move
  // between the two readings, so only clear cases are judged.
  var averages = [Double](repeating: 0, count: 3)
  _ = getloadavg(&averages, 3)
  let limit = Double(ProcessInfo.processInfo.activeProcessorCount * 2)
  guard abs(averages[0] - limit) > limit * 0.25 else { return }
  var level: Int32 = 100
  var size = MemoryLayout<Int32>.size
  _ = sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0)
  let overloaded = averages[0] > limit || level < 15
  for heavy in [
    event("Bash", "xcodebuild test -scheme App"), event("Bash", "swift test --parallel"),
    event("Bash", "xcrun simctl boot ABC"), event("Bash", "cd app && scripts/gate.sh --full"),
    event("Bash", "env CI=1 xcodebuild build -scheme App 2>&1 | tail"),
    event("Bash", "bash scripts/gate.sh --dry-run"),
    event("mcp__xcode__RunAllTests"),
  ] {
    #expect(try decision(heavy, data: fixture.data) == (overloaded ? "ask" : nil))
  }
}

@Test func sessionStatusIsStableAcrossRuns() throws {
  // Concurrent Git reads must never drop an answer: a lost one shows a branch as detached or
  // its changes as unknown.
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  for _ in 0..<20 {
    let output = try fixture.status(cwd: fixture.repository)
    #expect(try line(output, "Directory") == "Directory ~/app with space · main (no upstream)")
  }
}

@Test func sessionStatusAnswersWithinItsBudget() throws {
  // With almost no budget left, every slow call is skipped and the status still answers at
  // once, marking what it could not read.
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  _ = try fixture.status(cwd: fixture.repository)  // compiles the binary first
  let started = Date()
  let output = try fixture.status(cwd: fixture.repository, budget: "0.001")
  #expect(Date().timeIntervalSince(started) < 10)
  #expect(
    try line(output, "Directory")
      == "Directory ~/app with space · Git state unknown (no answer in time)")
  #expect(try line(output, "Host: load ") != nil)
}

/// Writes a fresh Simulator cache: booted default-set names, booted Xcode Preview names and the
/// available devices with their types.
private func cacheSimulators(
  _ data: URL, booted: [String], previews: [String] = [],
  available: [(String, String)] = []
) throws {
  try JSONSerialization.data(withJSONObject: [
    "names": booted, "previews": previews,
    "available": available.map { ["name": $0.0, "type": $0.1] },
  ]).write(to: data.appendingPathComponent("booted-simulators.json"))
}

@Test func sessionStatusCountsXcodePreviewSimulatorsAgainstTheBudget() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  try cacheSimulators(fixture.data, booted: ["Gate"], previews: ["iPhone Air", "iPad Air"])
  let output = try fixture.status(cwd: fixture.repository)
  #expect(
    try line(output, "Simulators: ")?.hasPrefix(
      "Simulators: 1 booted (Gate), 2 Xcode Preview booted (iPhone Air, iPad Air), ") == true)
  #expect(
    try line(output, "WARNING Simulators over budget")
      == "WARNING Simulators over budget: 3 booted (1 + 2 Xcode Preview), budget 2")
}

@Test func simulatorRulesGoToTheUser() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  let phone = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
  let available = [("Old Phone", phone), ("Gate", phone), ("iPad", "com.apple.iPad-Air")]
  var booted = ["Gate"]
  var previews = [String]()
  // Writes the Simulators before every call: a call that changes devices drops the cache.
  func ask(_ command: String, tool: String = "Bash") throws -> String? {
    try cacheSimulators(fixture.data, booted: booted, previews: previews, available: available)
    var event: [String: Any] = [
      "hook_event_name": "PreToolUse", "cwd": fixture.repository.path, "tool_name": tool,
    ]
    event["tool_input"] = ["command": command]
    let (decision, reason) = try answer(event, data: fixture.data)
    #expect(decision == (reason == nil ? nil : "ask"), "\(command)")
    return reason
  }

  // Creating or cloning always asks and names the devices of the same type to reuse, by
  // identifier or by display name.
  let create = try #require(
    try ask(
      "xcrun simctl create 'Agent Phone' \(phone) com.apple.CoreSimulator.SimRuntime.iOS-27-2"))
  #expect(create.contains("`simctl create` adds a Simulator"))
  #expect(create.contains("Existing devices of that type to reuse: Gate, Old Phone."))
  #expect(
    try ask("xcrun simctl create agent-1 \"iPhone 18 Pro\" iOS-27-2")?.contains(
      "to reuse: Gate, Old Phone.") == true)
  #expect(try ask("xcrun simctl create x \"Apple TV\" tvOS")?.contains("to reuse") == false)
  #expect(try ask("cd app && /usr/bin/xcrun simctl clone ABC copy")?.contains("clone") == true)
  // Removing devices or data, or stopping every device, asks, however it is written.
  for command in [
    "xcrun simctl delete unavailable", "xcrun simctl erase ABC", "xcrun simctl shutdown all",
    "xcrun simctl --set previews shutdown all", "xcrun --sdk iphonesimulator simctl delete X",
    "xcrun simctl --profiles /tmp/p delete X", "xcrun simctl \"delete\" X",
    "xcrun simctl shutdown 'all'", "xcrun simctl \\\n  delete X",
  ] {
    #expect(try ask(command) != nil, "\(command)")
  }
  #expect(try ask("xcrun simctl --set previews shutdown all")?.contains("Xcode Preview") == true)
  // Reading, or stopping one named device, never asks for a Simulator rule.
  for command in [
    "xcrun simctl list devices", "xcrun simctl shutdown ABC", "echo simctl create x",
    "git commit -m 'simctl delete docs; xcrun simctl delete all'", "echo don\\'t simctl delete",
  ] {
    #expect(try ask(command)?.contains("Simulator") != true, "\(command)")
  }
  // Under the budget one boot or test run passes the Simulator rules; a second boot in the
  // same command line counts the first.
  #expect(try ask("xcrun simctl boot ABC")?.contains("budget") != true)
  #expect(
    try ask("xcrun simctl boot A && xcrun simctl boot B")?.contains("the budget is 2") == true)
  // At the budget another boot asks; tests and runs ask only above it.
  previews = ["Preview"]
  #expect(try ask("xcrun simctl boot ABC")?.contains("the budget is 2") == true)
  #expect(try ask("xcodebuild test -scheme App")?.contains("budget") != true)
  booted = ["Gate", "Other"]
  for (command, tool) in [
    ("xcodebuild test -scheme App", "Bash"), ("sh scripts/gate.sh", "Bash"),
    ("", "mcp__xcode__RunAllTests"), ("", "mcp__xcode__DeviceInteractionStartSession"),
    ("xcodebuild -scheme App \\\n  test -destination id=X", "Bash"),
  ] {
    #expect(
      try ask(command, tool: tool)?.contains("over the budget of 2") == true, "\(tool) \(command)")
  }
  #expect(try ask("xcodebuild build -scheme App")?.contains("budget") != true)
}

@Test func aCallThatChangesSimulatorsDropsTheCache() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  let file = fixture.data.appendingPathComponent("booted-simulators.json")
  for (command, drops) in [("xcrun simctl list", false), ("xcrun simctl boot ABC", true)] {
    try cacheSimulators(fixture.data, booted: [])
    _ = try answer(
      [
        "hook_event_name": "PreToolUse", "cwd": fixture.repository.path, "tool_name": "Bash",
        "tool_input": ["command": command],
      ], data: fixture.data)
    #expect(FileManager.default.fileExists(atPath: file.path) == !drops, "\(command)")
  }
}

/// A stand-in `gh` that prints `pullRequests` as `gh pr list --json` would.
private func fakeGitHub(in home: URL, _ pullRequests: [[String: Any]]) throws -> String {
  let json = home.appendingPathComponent("pull-requests.json")
  try JSONSerialization.data(withJSONObject: pullRequests).write(to: json)
  let script = home.appendingPathComponent("gh")
  try Data("#!/bin/sh\ncat '\(json.path)'\n".utf8).write(to: script)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  return script.path
}

private func pullRequest(
  _ number: Int, _ head: String, _ state: String, base: String = "main", fork: Bool = false
) -> [String: Any] {
  [
    "number": number, "headRefName": head, "baseRefName": base, "state": state,
    "isCrossRepository": fork,
  ]
}

@Test func sessionStatusFlagsWhatMergedPullRequestsLeft() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  for branch in ["fix/old", "feature/reused", "release/2", "patch-1"] {
    try fixture.git(["branch", branch], in: fixture.repository)
  }
  try fixture.git(
    ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"],
    in: fixture.repository)
  let gh = try fakeGitHub(
    in: fixture.home,
    [
      // feature/x (the linked worktree) merged after an earlier closed PR; fix/old merged.
      pullRequest(4, "feature/x", "CLOSED"), pullRequest(7, "feature/x", "MERGED"),
      pullRequest(3, "fix/old", "MERGED"),
      // Merged once, open again: its latest PR is open.
      pullRequest(5, "feature/reused", "MERGED"), pullRequest(9, "feature/reused", "OPEN"),
      // A back-merge from the default branch and a fork's PR never count.
      pullRequest(6, "main", "MERGED", base: "release/2"),
      pullRequest(8, "patch-1", "MERGED", fork: true),
      // A merged release branch that an open PR still targets is still in use.
      pullRequest(10, "release/2", "MERGED"),
      pullRequest(11, "feature/next", "OPEN", base: "release/2"),
    ])
  let main = try fixture.status(cwd: fixture.repository, gh: gh)
  #expect(try line(main, "WARNING Branch") == nil)
  #expect(
    try line(main, "Cleanup")
      == "Cleanup: 2 local branches and 1 worktree from merged PRs (git-workflow branch hygiene)")
  let worktree = try fixture.status(cwd: fixture.worktree, gh: gh)
  #expect(
    try line(worktree, "WARNING Branch")
      == "WARNING Branch feature/x belongs to merged PR #7: start new work on a new branch from "
      + "the refreshed base")
  let context = try #require(
    (worktree["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String)
  #expect(context.contains("follow git-workflow branch hygiene"))
}

@Test func sessionStatusWithoutPullRequestsShowsNoCleanup() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.home) }
  for gh in [try fakeGitHub(in: fixture.home, []), "/usr/bin/false"] {
    try? FileManager.default.removeItem(at: fixture.data.appendingPathComponent("pull-requests"))
    let output = try fixture.status(cwd: fixture.repository, gh: gh)
    #expect(try line(output, "Cleanup") == nil)
    #expect(try line(output, "WARNING Branch") == nil)
  }
}
