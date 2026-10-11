import Foundation

// Claude Code SessionStart and UserPromptSubmit hook. Collects, read-only, where this session
// works and what else is running: the directory's Git branch, upstream and worktree, every
// workspace or project open in Xcode with its branch, the booted Simulators, and the other
// Claude sessions active in the last 30 minutes. It shows them to the person (`systemMessage`)
// and gives them to the agent (`additionalContext`). A failure only leaves a fact out.

struct Repository {
  var path: String
  var top: String?
  var branch: String?
  var upstream: String?
  var ahead = 0
  var behind = 0
  var dirty = 0
  var worktreeOf: String?
}

struct OtherSession {
  var cwd: String
  var branch: String?
  var minutesAgo: Int
}

/// Runs a program by argument vector and returns its trimmed standard output, or nil when it
/// cannot start, fails or outlives `timeout`.
func run(_ argv: [String], timeout: TimeInterval = 4) -> String? {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: argv[0])
  process.arguments = Array(argv.dropFirst())
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  process.standardInput = FileHandle.nullDevice
  guard (try? process.run()) != nil else { return nil }
  let deadline = DispatchTime.now() + timeout
  let finished = DispatchSemaphore(value: 0)
  var data = Data()
  DispatchQueue.global().async {
    data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    finished.signal()
  }
  if finished.wait(timeout: deadline) == .timedOut {
    process.terminate()
    return nil
  }
  guard process.terminationStatus == 0 else { return nil }
  return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func git(_ arguments: [String], in directory: String) -> String? {
  run(["/usr/bin/git", "-C", directory] + arguments)
}

/// Runs each command at once and returns their outputs in order.
func runAll(_ commands: [[String]]) -> [String?] {
  var results = [String?](repeating: nil, count: commands.count)
  let lock = NSLock()
  DispatchQueue.concurrentPerform(iterations: commands.count) { index in
    let value = run(commands[index])
    lock.withLock { results[index] = value }
  }
  return results
}

func repository(at path: String) -> Repository {
  var repo = Repository(path: path)
  guard let top = git(["rev-parse", "--show-toplevel"], in: path) else { return repo }
  repo.top = top
  let prefix = ["/usr/bin/git", "-C", top]
  let results = runAll([
    prefix + ["branch", "--show-current"],
    prefix + ["rev-parse", "--short", "HEAD"],
    prefix + ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
    prefix + ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
    prefix + ["status", "--porcelain"],
    prefix + ["rev-parse", "--path-format=absolute", "--git-dir"],
    prefix + ["rev-parse", "--path-format=absolute", "--git-common-dir"],
  ])
  let current = results[0] ?? ""
  repo.branch = current.isEmpty ? results[1] : current
  repo.upstream = results[2]
  if repo.upstream != nil, let counts = results[3] {
    let numbers = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    if numbers.count == 2 { (repo.ahead, repo.behind) = (numbers[0], numbers[1]) }
  }
  repo.dirty = (results[4] ?? "").split(separator: "\n").count
  if let gitDirectory = results[5], let common = results[6], gitDirectory != common {
    repo.worktreeOf = common.hasSuffix("/.git") ? String(common.dropLast(5)) : common
  }
  return repo
}

/// The paths Xcode has open; empty when Xcode is not running, nil when it would not say
/// (Automation not allowed).
func xcodeDocuments() -> [String]? {
  guard run(["/usr/bin/pgrep", "-x", "Xcode"]) != nil else { return [] }
  guard
    let text = run([
      "/usr/bin/osascript", "-e",
      "tell application \"Xcode\" to set AppleScript's text item delimiters to linefeed",
      "-e", "tell application \"Xcode\" to get (path of every workspace document) as text",
    ])
  else { return nil }
  return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}

/// Booted Simulator names, cached for a minute because `simctl` is slow; nil when unknown.
func bootedSimulators(cache: URL) -> [String]? {
  let file = cache.appendingPathComponent("booted-simulators.json")
  if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
    let modified = attributes[.modificationDate] as? Date,
    Date().timeIntervalSince(modified) < 60,
    let data = try? Data(contentsOf: file),
    let names = try? JSONSerialization.jsonObject(with: data) as? [String]
  {
    return names
  }
  guard
    let json = run(["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"], timeout: 8),
    let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
    let devices = object["devices"] as? [String: [[String: Any]]]
  else { return nil }
  let names = devices.values.flatMap { $0 }.compactMap { $0["name"] as? String }.sorted()
  try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  if let data = try? JSONSerialization.data(withJSONObject: names) {
    try? data.write(to: file, options: .atomic)
  }
  return names
}

/// Claude sessions whose transcript changed in the last 30 minutes, other than `ownID`: the
/// directory and branch their last recorded entry names.
func otherSessions(home: String, ownID: String) -> [OtherSession] {
  let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
  let manager = FileManager.default
  var found = [OtherSession]()
  let now = Date()
  for folder in (try? manager.contentsOfDirectory(atPath: projects.path)) ?? [] {
    let directory = projects.appendingPathComponent(folder)
    for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
    where name.hasSuffix(".jsonl") && !name.hasPrefix(ownID) {
      let file = directory.appendingPathComponent(name)
      guard
        let modified = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate]
          as? Date,
        now.timeIntervalSince(modified) < 30 * 60,
        let handle = try? FileHandle(forReadingFrom: file)
      else { continue }
      defer { try? handle.close() }
      let size = (try? handle.seekToEnd()) ?? 0
      try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
      let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
      for line in tail.split(separator: "\n").reversed() {
        guard
          let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let cwd = entry["cwd"] as? String
        else { continue }
        let branch = (entry["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        found.append(
          OtherSession(
            cwd: cwd, branch: branch, minutesAgo: Int(now.timeIntervalSince(modified) / 60)))
        break
      }
    }
  }
  return found.sorted { $0.minutesAgo < $1.minutesAgo }
}

func tilde(_ path: String, _ home: String) -> String {
  !home.isEmpty && path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func branchText(_ repo: Repository) -> String {
  guard repo.top != nil else { return "not a Git repository" }
  var parts = [repo.branch ?? "(detached)"]
  if let upstream = repo.upstream {
    let sync = [repo.ahead > 0 ? "↑\(repo.ahead)" : "", repo.behind > 0 ? "↓\(repo.behind)" : ""]
      .filter { !$0.isEmpty }.joined(separator: " ")
    parts.append("→ \(upstream)" + (sync.isEmpty ? "" : " \(sync)"))
  } else {
    parts.append("(no upstream)")
  }
  if repo.dirty > 0 { parts.append("\(repo.dirty) changed") }
  return parts.joined(separator: " ")
}

func worktreeText(_ repo: Repository, _ home: String) -> String {
  repo.worktreeOf.map { " · worktree of \(tilde($0, home))" } ?? ""
}

/// The status lines, shortest facts first.
func lines(
  here: Repository, xcode: [(String, Repository)]?, simulators: [String]?,
  sessions: [OtherSession], home: String
) -> [String] {
  var out = [
    "Directory \(tilde(here.top ?? here.path, home)) · \(branchText(here))"
      + worktreeText(here, home)
  ]
  switch xcode {
  case nil:
    out.append("Xcode: open workspace unknown (allow Automation for Xcode to show it)")
  case let documents? where documents.isEmpty:
    out.append("Xcode: not running")
  case let documents?:
    for (path, repo) in documents {
      out.append(
        "Xcode \(tilde(path, home))"
          + (repo.top != nil ? " · \(branchText(repo))" : "") + worktreeText(repo, home))
    }
  }
  if let simulators {
    out.append(
      "Simulators: \(simulators.count) booted"
        + (simulators.isEmpty ? "" : " (\(simulators.joined(separator: ", ")))"))
  } else {
    out.append("Simulators: unknown (xcrun simctl unavailable)")
  }
  let listed = sessions.map {
    "\(tilde($0.cwd, home))" + ($0.branch.map { "@\($0)" } ?? "") + " \($0.minutesAgo)m"
  }
  out.append(
    "Other Claude sessions active in 30 min: \(sessions.count)"
      + (listed.isEmpty ? "" : " (\(listed.joined(separator: "; ")))"))
  return out
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let event = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
let environment = ProcessInfo.processInfo.environment
let home = environment["HOME"] ?? NSHomeDirectory()
let cwd = event["cwd"] as? String ?? FileManager.default.currentDirectoryPath
let ownID = event["session_id"] as? String ?? ""
let cache = URL(
  fileURLWithPath: environment["CLAUDE_PLUGIN_DATA"]
    ?? "\(home)/Library/Caches/apple-platform-engineer")

var here = Repository(path: cwd)
var xcode: [(String, Repository)]?
var simulators: [String]?
var sessions = [OtherSession]()
let group = DispatchGroup()
let lock = NSLock()
func concurrently(_ work: @escaping () -> Void) {
  DispatchQueue.global().async(group: group) { work() }
}
concurrently {
  let value = repository(at: cwd)
  lock.withLock { here = value }
}
concurrently {
  guard let paths = xcodeDocuments() else { return }
  var documents = [(String, Repository)?](repeating: nil, count: paths.count)
  let documentsLock = NSLock()
  DispatchQueue.concurrentPerform(iterations: paths.count) { index in
    let repo = repository(at: (paths[index] as NSString).deletingLastPathComponent)
    documentsLock.withLock { documents[index] = (paths[index], repo) }
  }
  let value = documents.compactMap { $0 }
  lock.withLock { xcode = value }
}
concurrently {
  let value = bootedSimulators(cache: cache)
  lock.withLock { simulators = value }
}
concurrently {
  let value = otherSessions(home: home, ownID: ownID)
  lock.withLock { sessions = value }
}
group.wait()

let shown = lines(
  here: here, xcode: xcode, simulators: simulators, sessions: sessions, home: home)
let context =
  ([
    "Live session environment (refreshed for this prompt). Before editing, building, testing, "
      + "committing or publishing, confirm the target directory, Xcode container, branch and "
      + "worktree match the task; on a mismatch, or another session working in the same "
      + "checkout, stop and ask."
  ] + shown.map { "- \($0)" }).joined(separator: "\n")
let output: [String: Any] = [
  "systemMessage": shown.joined(separator: "\n"),
  "hookSpecificOutput": [
    "hookEventName": event["hook_event_name"] as? String ?? "UserPromptSubmit",
    "additionalContext": context,
  ],
]
if let data = try? JSONSerialization.data(withJSONObject: output) {
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}
