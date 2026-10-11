import CryptoKit
import Darwin
import Foundation

// Claude Code SessionStart and UserPromptSubmit hook. Collects, read-only, where this session
// works and what else is running: the directory's Git branch, upstream and worktree, the
// branches and worktrees that merged pull requests left there, the handoffs waiting for Claude,
// every workspace or project open in Xcode with its branch, the booted Simulators and Xcode
// Preview devices, the other Claude sessions active in the last 30 minutes, the host's load and
// memory, and the free storage of the working volume. It shows them to the person
// (`systemMessage`) and gives them to the agent (`additionalContext`). A failure only leaves a
// fact out or marks it unknown. Before a tool call (PreToolUse) it instead asks the user when
// the call would stall an overloaded host or break the Simulator rules.

struct Repository {
  var path: String
  var top: String?
  var branch: String?
  var isDetached = false
  var upstream: String?
  var ahead = 0
  var behind = 0
  /// Changed paths; nil when `git status` did not answer in time.
  var dirty: Int?
  var worktreeOf: String?
  /// The Git common directory every worktree of the repository shares.
  var common: String?
  /// Git did not answer before the deadline, so nothing is known about the folder.
  var isUnread = false
}

struct OtherSession {
  var cwd: String
  var branch: String?
  var minutesAgo: Int
}

struct Host {
  var load: Double
  var processors: Int
  /// The share of memory the kernel reports available, 0–100; nil when unknown.
  var memoryFree: Int?
  var simulatorProcesses: Int
  var volume: String
  var freeBytes: Int64?
  var totalBytes: Int64?

  var isOverloaded: Bool {
    load > Double(processors * 2) || (memoryFree.map { $0 < 15 } ?? false)
  }
  var isStorageLow: Bool {
    guard let freeBytes, let totalBytes, totalBytes > 0 else { return false }
    return freeBytes < 20_000_000_000 || Double(freeBytes) / Double(totalBytes) < 0.1
  }
}

/// A value shared between threads behind a lock.
final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
  /// Changes the value in one locked step; `box.value[i] = x` would read, change and write
  /// back in separate steps and lose a concurrent change.
  func mutate(_ body: (inout Value) -> Void) {
    lock.withLock { body(&stored) }
  }
}

/// How long one Git, `osascript` or `pgrep` call may take: `APE_STATUS_TIMEOUT` seconds, else 8,
/// which a heavily loaded host needs.
let commandTimeout =
  ProcessInfo.processInfo.environment["APE_STATUS_TIMEOUT"].flatMap(TimeInterval.init) ?? 8

/// When the whole status must be ready: `APE_STATUS_BUDGET` seconds after start, else 15, inside
/// the hook's 20 s timeout. Calls still running then are left out and shown as unknown.
let deadline = Date().addingTimeInterval(
  ProcessInfo.processInfo.environment["APE_STATUS_BUDGET"].flatMap(TimeInterval.init) ?? 15)

/// Runs a program by argument vector and returns its trimmed standard output, or nil when it
/// cannot start, fails or outlives `timeout`. Git runs without optional locks, so a status
/// never rewrites the index another process may be using.
func run(
  _ argv: [String], in directory: String? = nil, timeout: TimeInterval = commandTimeout
) -> String? {
  let timeout = min(timeout, deadline.timeIntervalSinceNow)
  guard timeout > 0 else { return nil }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: argv[0])
  process.arguments = Array(argv.dropFirst())
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  var environment = ProcessInfo.processInfo.environment
  environment["GIT_OPTIONAL_LOCKS"] = "0"
  process.environment = environment
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  process.standardInput = FileHandle.nullDevice
  guard (try? process.run()) != nil else { return nil }
  let data = Box(Data())
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    data.value = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    finished.signal()
  }
  if finished.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    return nil
  }
  guard process.terminationStatus == 0 else { return nil }
  return String(decoding: data.value, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Runs each command at once and returns their outputs in order.
func runAll(_ commands: [[String]]) -> [String?] {
  let results = Box([String?](repeating: nil, count: commands.count))
  DispatchQueue.concurrentPerform(iterations: commands.count) { index in
    let value = run(commands[index])
    results.mutate { $0[index] = value }
  }
  return results.value
}

func repository(at path: String) -> Repository {
  var repo = Repository(path: path)
  let git = ["/usr/bin/git", "--no-optional-locks", "-C"]
  guard let top = run(git + [path, "rev-parse", "--show-toplevel"]) else {
    repo.isUnread = deadline.timeIntervalSinceNow <= 0
    return repo
  }
  repo.top = top
  let prefix = git + [top]
  let results = runAll([
    prefix + ["branch", "--show-current"],
    prefix + ["rev-parse", "--short", "HEAD"],
    prefix + ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
    prefix + ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
    prefix + ["status", "--porcelain"],
    prefix + ["rev-parse", "--path-format=absolute", "--git-dir"],
    prefix + ["rev-parse", "--path-format=absolute", "--git-common-dir"],
  ])
  if let current = results[0], !current.isEmpty {
    repo.branch = current
  } else {
    repo.isDetached = true
    repo.branch = results[1]
  }
  repo.upstream = results[2]
  if repo.upstream != nil, let counts = results[3] {
    let numbers = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    if numbers.count == 2 { (repo.ahead, repo.behind) = (numbers[0], numbers[1]) }
  }
  repo.dirty = results[4].map { $0.split(separator: "\n").count }
  repo.common = results[6]
  if let gitDirectory = results[5], let common = results[6], gitDirectory != common {
    repo.worktreeOf = common.hasSuffix("/.git") ? String(common.dropLast(5)) : common
  }
  return repo
}

/// The absolute paths Xcode has open; empty when Xcode is not running, nil when it would not
/// say (Automation not allowed).
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
    .filter { $0.hasPrefix("/") }
}

struct Simulators {
  /// Booted devices of the default set, by name.
  var booted: [String]
  /// Booted devices of Xcode Previews' own set, which `simctl list` alone never shows.
  var previews: [String]
  /// Available devices of the default set: name and device type identifier.
  var available: [(name: String, type: String)]

  var bootedCount: Int { booted.count + previews.count }
}

/// How many booted Simulators, Xcode Preview devices included, the host keeps before another
/// boot, test or run needs the user: `APE_SIMULATOR_BUDGET`, else 2.
let simulatorBudget =
  ProcessInfo.processInfo.environment["APE_SIMULATOR_BUDGET"].flatMap(Int.init) ?? 2

/// The Simulators, cached for a minute because `simctl` is slow. An unknown answer is cached
/// too, so a stuck CoreSimulator costs one wait a minute; nil when unknown.
func simulators(cache: URL) -> Simulators? {
  let file = cache.appendingPathComponent("booted-simulators.json")
  if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
    let modified = attributes[.modificationDate] as? Date,
    Date().timeIntervalSince(modified) < 60,
    let data = try? Data(contentsOf: file),
    let cached = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  {
    guard let booted = cached["names"] as? [String] else { return nil }
    let available = (cached["available"] as? [[String: String]] ?? []).compactMap { device in
      device["name"].map { (name: $0, type: device["type"] ?? "") }
    }
    return Simulators(
      booted: booted, previews: cached["previews"] as? [String] ?? [], available: available)
  }
  let answers = runAll([
    ["/usr/bin/xcrun", "simctl", "list", "devices", "-j"],
    ["/usr/bin/xcrun", "simctl", "--set", "previews", "list", "devices", "booted", "-j"],
  ])
  func devices(_ json: String?) -> [[String: Any]]? {
    guard let json,
      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let devices = object["devices"] as? [String: [[String: Any]]]
    else { return nil }
    return devices.values.flatMap { $0 }
  }
  var found: Simulators?
  if let all = devices(answers[0]) {
    found = Simulators(
      booted: all.filter { ["Booted", "Booting"].contains($0["state"] as? String ?? "") }
        .compactMap { $0["name"] as? String }.sorted(),
      previews: (devices(answers[1]) ?? []).compactMap { $0["name"] as? String }.sorted(),
      available: all.filter { $0["isAvailable"] as? Bool == true }.compactMap { device in
        (device["name"] as? String).map {
          (name: $0, type: device["deviceTypeIdentifier"] as? String ?? "")
        }
      })
  }
  try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  let record: [String: Any] =
    found.map {
      [
        "names": $0.booted, "previews": $0.previews,
        "available": $0.available.map { ["name": $0.name, "type": $0.type] },
      ]
    } ?? [:]
  if let data = try? JSONSerialization.data(withJSONObject: record) {
    try? data.write(to: file, options: .atomic)
  }
  return found
}

/// The last `cwd` and `gitBranch` a transcript recorded, reading its tail.
func lastPlace(of file: URL) -> (String, String?)? {
  guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
  defer { try? handle.close() }
  let size = (try? handle.seekToEnd()) ?? 0
  for window in [UInt64(65_536), 1_048_576] {
    try? handle.seek(toOffset: size > window ? size - window : 0)
    let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    for line in tail.split(separator: "\n").reversed() {
      guard
        let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let cwd = entry["cwd"] as? String
      else { continue }
      return (cwd, (entry["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
    if size <= window { break }
  }
  return nil
}

/// Claude sessions whose transcript changed in the last 30 minutes, other than this one.
func otherSessions(home: String, ownID: String) -> [OtherSession] {
  let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
  let manager = FileManager.default
  var found = [OtherSession]()
  let now = Date()
  for folder in (try? manager.contentsOfDirectory(atPath: projects.path)) ?? [] {
    let directory = projects.appendingPathComponent(folder)
    for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
    where name.hasSuffix(".jsonl") && (ownID.isEmpty || name != "\(ownID).jsonl") {
      let file = directory.appendingPathComponent(name)
      guard
        let modified = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate]
          as? Date,
        now.timeIntervalSince(modified) < 30 * 60,
        let (cwd, branch) = lastPlace(of: file)
      else { continue }
      found.append(
        OtherSession(
          cwd: cwd, branch: branch, minutesAgo: Int(now.timeIntervalSince(modified) / 60)))
    }
  }
  return found.sorted { $0.minutesAgo < $1.minutesAgo }
}

/// Processes running from CoreSimulator or a Simulator runtime (services and booted devices),
/// counted from the kernel's process list: a load signal, not a device count.
func simulatorProcessCount() -> Int {
  let capacity = Int(proc_listallpids(nil, 0)) + 64
  guard capacity > 64 else { return 0 }
  var pids = [pid_t](repeating: 0, count: capacity)
  let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
  var buffer = [CChar](repeating: 0, count: 4096)
  var total = 0
  for pid in pids.prefix(max(0, count)) where pid > 0 {
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
    let path = String(cString: buffer)
    if path.contains("/CoreSimulator/") || path.contains(".simruntime/") { total += 1 }
  }
  return total
}

func host(cwd: String) -> Host {
  var averages = [Double](repeating: 0, count: 3)
  let load = getloadavg(&averages, 3) > 0 ? averages[0] : 0
  var level: Int32 = 0
  var size = MemoryLayout<Int32>.size
  let memoryFree =
    sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
  let values = try? URL(fileURLWithPath: cwd).resourceValues(forKeys: [
    .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeNameKey,
  ])
  return Host(
    load: load, processors: ProcessInfo.processInfo.activeProcessorCount,
    memoryFree: memoryFree, simulatorProcesses: simulatorProcessCount(),
    volume: values?.volumeName ?? "volume",
    freeBytes: values?.volumeAvailableCapacityForImportantUsage,
    totalBytes: values?.volumeTotalCapacity.map(Int64.init))
}

/// What merged pull requests left in a repository: the merged PR the checked-out branch
/// belongs to, and the local branches and linked worktrees whose latest PR merged.
struct Leftovers {
  var currentPullRequest: Int?
  var branches = 0
  var worktrees = 0
}

/// The `gh` to ask: `APE_GH`, else Homebrew's or /usr/local's, else the one on PATH, which a
/// hook started by an app often lacks.
let ghCommand: [String] = {
  if let path = ProcessInfo.processInfo.environment["APE_GH"] { return [path] }
  for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
  where FileManager.default.isExecutableFile(atPath: path) {
    return [path]
  }
  return ["/usr/bin/env", "gh"]
}()

/// What GitHub knows about a repository: the latest pull request of each head branch, by
/// number, and whether it merged, and the default branch.
struct GitHubState {
  var heads: [String: (number: Int, merged: Bool)]
  var defaultBranch: String?
}

/// How long one `gh` call may take: 4 seconds, so a slow network never holds up a prompt for
/// long, unless `APE_STATUS_TIMEOUT` sets the limit for every call.
let ghTimeout =
  ProcessInfo.processInfo.environment["APE_STATUS_TIMEOUT"] == nil
  ? min(commandTimeout, 4)
  : commandTimeout

/// The GitHub state of the repository whose Git common directory is `common`. A pull request
/// from a fork, and a branch that an open pull request still targets, never count. Asked of
/// `gh` in `top` and cached for ten minutes per repository; an unknown answer is cached for one
/// minute. Nil when unknown.
func gitHubState(common: String, top: String, cache: URL) -> GitHubState? {
  let folder = cache.appendingPathComponent("pull-requests")
  let key = SHA256.hash(data: Data(common.utf8)).map { String(format: "%02x", $0) }.joined()
  let file = folder.appendingPathComponent(key + ".json")
  func decode(_ heads: [String: [String: Any]], _ defaultBranch: String?) -> GitHubState {
    GitHubState(
      heads: heads.compactMapValues { pr in
        (pr["number"] as? Int).map { (number: $0, merged: pr["state"] as? String == "MERGED") }
      }, defaultBranch: defaultBranch)
  }
  if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
    let modified = attributes[.modificationDate] as? Date,
    let data = try? Data(contentsOf: file),
    let cached = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  {
    let heads = cached["heads"] as? [String: [String: Any]]
    if Date().timeIntervalSince(modified) < (heads == nil ? 60 : 600) {
      return heads.map { decode($0, cached["default"] as? String) }
    }
  }
  let answers = Box([String?](repeating: nil, count: 2))
  DispatchQueue.concurrentPerform(iterations: 2) { index in
    let arguments =
      index == 0
      ? [
        "pr", "list", "--state", "all", "--limit", "300", "--json",
        "number,headRefName,baseRefName,state,isCrossRepository",
      ] : ["repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"]
    let value = run(ghCommand + arguments, in: top, timeout: ghTimeout)
    answers.mutate { $0[index] = value }
  }
  let defaultBranch = answers.value[1].flatMap { $0.isEmpty ? nil : $0 }
  var heads: [String: [String: Any]]?
  if let json = answers.value[0],
    let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
  {
    let ownPullRequests = list.filter { $0["isCrossRepository"] as? Bool != true }
    let targeted = Set(
      ownPullRequests.filter { $0["state"] as? String == "OPEN" }
        .compactMap { $0["baseRefName"] as? String })
    var latest = [String: [String: Any]]()
    for pr in ownPullRequests {
      guard let head = pr["headRefName"] as? String, !targeted.contains(head),
        let number = pr["number"] as? Int
      else { continue }
      if number > (latest[head]?["number"] as? Int ?? 0) {
        latest[head] = ["number": number, "state": pr["state"] as? String ?? ""]
      }
    }
    heads = latest
  }
  try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var record: [String: Any] = heads.map { ["heads": $0] } ?? [:]
  record["default"] = defaultBranch
  if let data = try? JSONSerialization.data(withJSONObject: record) {
    try? data.write(to: file, options: .atomic)
  }
  return heads.map { decode($0, defaultBranch) }
}

/// The leftovers of merged pull requests in `repo`; the remote's default branch never counts.
/// Nil when unknown.
func leftovers(of repo: Repository, cache: URL) -> Leftovers? {
  guard let top = repo.top,
    let state = gitHubState(common: repo.worktreeOf ?? top, top: top, cache: cache)
  else { return nil }
  let git = ["/usr/bin/git", "--no-optional-locks", "-C", top]
  let answers = runAll([
    git + ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
    git + ["worktree", "list", "--porcelain"],
    git + ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
  ])
  // origin/HEAD exists only in a clone; GitHub's answer covers the rest.
  let defaultBranch =
    answers[2].map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 }
    ?? state.defaultBranch
  func merged(_ branch: String) -> Bool {
    branch != defaultBranch && state.heads[branch]?.merged == true
  }
  var result = Leftovers()
  if !repo.isDetached, let branch = repo.branch, merged(branch) {
    result.currentPullRequest = state.heads[branch]?.number
  }
  result.branches = (answers[0] ?? "").split(separator: "\n").filter { merged(String($0)) }.count
  // The first entry is the main worktree; the others are linked worktrees.
  result.worktrees =
    (answers[1] ?? "").components(separatedBy: "\n\n").dropFirst().filter { entry in
      entry.split(separator: "\n").contains {
        $0.hasPrefix("branch refs/heads/") && merged(String($0.dropFirst(18)))
      }
    }.count
  return result
}

/// A handoff another agent addressed to Claude that no session has resumed yet.
struct WaitingHandoff {
  var id: String
  var from: String
  var task: String
  var branch: String?
  var minutesAgo: Int
}

/// The handoffs waiting for Claude in the repository's `apple-verify handoff` ledger, as
/// `handoff list --pending-for claude` counts them: the newest handoff of each open thread, when
/// it is addressed to Claude and not resumed. Newest last; empty when there is no ledger.
func waitingHandoffs(common: String) -> [WaitingHandoff] {
  let ledger = URL(fileURLWithPath: common).appendingPathComponent("ape-handoffs/ledger.jsonl")
  guard let text = try? String(contentsOf: ledger, encoding: .utf8) else { return [] }
  let events = text.split(separator: "\n").compactMap {
    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
  }
  let resumed = Set(
    events.filter { $0["event"] as? String == "resume" }.compactMap { $0["id"] as? String })
  let closed = Set(
    events.filter { $0["event"] as? String == "close" }.compactMap { $0["thread"] as? String })
  var newest = [String: String]()
  for event in events where event["event"] as? String == "handoff" {
    if let thread = event["thread"] as? String { newest[thread] = event["id"] as? String }
  }
  let formatter = ISO8601DateFormatter()
  return events.compactMap { event in
    guard event["event"] as? String == "handoff", event["to"] as? String == "claude",
      let thread = event["thread"] as? String, newest[thread] == event["id"] as? String,
      let id = event["id"] as? String, !resumed.contains(id),
      !closed.contains(thread)
    else { return nil }
    let at = (event["at"] as? String).flatMap(formatter.date(from:)) ?? Date()
    return WaitingHandoff(
      id: id, from: event["from"] as? String ?? "another agent",
      // One line, whatever the ledger holds, so a task never forges a status line.
      task: String(
        String.UnicodeScalarView(
          (event["task"] as? String ?? "").unicodeScalars.prefix(200).map {
            CharacterSet.controlCharacters.union(.newlines).contains($0) ? " " : $0
          })), branch: event["branch"] as? String,
      minutesAgo: max(0, Int(Date().timeIntervalSince(at) / 60)))
  }
}

func ago(minutes: Int) -> String {
  switch minutes {
  case 0: return "just now"
  case ..<60: return "\(minutes) min ago"
  case ..<(48 * 60): return "\(minutes / 60) h ago"
  default: return "\(minutes / (24 * 60)) days ago"
  }
}

func plural(_ count: Int, _ noun: String, _ plural: String) -> String {
  "\(count) \(count == 1 ? noun : plural)"
}

func tilde(_ path: String, _ home: String) -> String {
  !home.isEmpty && path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func branchText(_ repo: Repository) -> String {
  guard repo.top != nil else {
    return repo.isUnread ? "Git state unknown (no answer in time)" : "not a Git repository"
  }
  var parts = [
    repo.isDetached ? "(detached \(repo.branch ?? "HEAD"))" : (repo.branch ?? "(unknown branch)")
  ]
  if let upstream = repo.upstream {
    let sync = [repo.ahead > 0 ? "↑\(repo.ahead)" : "", repo.behind > 0 ? "↓\(repo.behind)" : ""]
      .filter { !$0.isEmpty }.joined(separator: " ")
    parts.append("→ \(upstream)" + (sync.isEmpty ? "" : " \(sync)"))
  } else {
    parts.append("(no upstream)")
  }
  switch repo.dirty {
  case nil: parts.append("changes unknown")
  case let count? where count > 0: parts.append("\(count) changed")
  default: break
  }
  return parts.joined(separator: " ")
}

func worktreeText(_ repo: Repository, _ home: String) -> String {
  repo.worktreeOf.map { " · worktree of \(tilde($0, home))" } ?? ""
}

func gigabytes(_ bytes: Int64) -> String {
  String(format: "%.0f GB", Double(bytes) / 1_000_000_000)
}

/// The status lines, warnings first.
func lines(
  here: Repository, leftovers: Leftovers?, handoffs: [WaitingHandoff],
  xcode: [(String, Repository)]?,
  simulators: Simulators?, sessions: [OtherSession], host: Host, home: String
) -> [String] {
  var out = [String]()
  let loadText = String(format: "load %.0f on %d cores", host.load, host.processors)
  let memoryText = host.memoryFree.map { "memory \($0)% free" } ?? "memory unknown"
  if host.isOverloaded {
    out.append(
      "WARNING Host overloaded: \(loadText), \(memoryText), "
        + "\(host.simulatorProcesses) CoreSimulator processes")
  }
  if let simulators, simulators.bootedCount > simulatorBudget {
    out.append(
      "WARNING Simulators over budget: \(simulators.bootedCount) booted "
        + "(\(simulators.booted.count) + \(simulators.previews.count) Xcode Preview), "
        + "budget \(simulatorBudget)")
  }
  if host.isStorageLow, let free = host.freeBytes {
    out.append("WARNING Storage low: \(gigabytes(free)) free on \(host.volume)")
  }
  if let number = leftovers?.currentPullRequest, let branch = here.branch {
    out.append(
      "WARNING Branch \(branch) belongs to merged PR #\(number): start new work on a new branch "
        + "from the refreshed base")
  }
  out.append(
    "Directory \(tilde(here.top ?? here.path, home)) · \(branchText(here))"
      + worktreeText(here, home))
  if let newest = handoffs.last {
    out.append(
      "Handoff waiting for Claude"
        + (handoffs.count > 1 ? " (\(handoffs.count), newest shown)" : "")
        + ": \(newest.task) from \(newest.from) \(ago(minutes: newest.minutesAgo)) on "
        + "\(newest.branch ?? "a detached HEAD") (\(newest.id))")
  }
  if let leftovers, leftovers.branches + leftovers.worktrees > 0 {
    out.append(
      "Cleanup: \(plural(leftovers.branches, "local branch", "local branches")) and "
        + "\(plural(leftovers.worktrees, "worktree", "worktrees")) from merged PRs "
        + "(git-workflow branch hygiene)")
  }
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
    func listed(_ names: [String]) -> String {
      names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
    }
    out.append(
      "Simulators: \(simulators.booted.count) booted" + listed(simulators.booted)
        + (simulators.previews.isEmpty
          ? ""
          : ", \(simulators.previews.count) Xcode Preview booted" + listed(simulators.previews))
        + ", \(host.simulatorProcesses) CoreSimulator processes")
  } else {
    out.append(
      "Simulators: booted list unknown (xcrun simctl did not answer), "
        + "\(host.simulatorProcesses) CoreSimulator processes")
  }
  let storage =
    host.freeBytes.map { free in
      "\(gigabytes(free)) free" + (host.totalBytes.map { " of \(gigabytes($0))" } ?? "")
    } ?? "free space unknown"
  out.append("Host: \(loadText), \(memoryText), storage \(storage) on \(host.volume)")
  let listed = sessions.map {
    "\(tilde($0.cwd, home))" + ($0.branch.map { "@\($0)" } ?? "") + " \($0.minutesAgo)m"
  }
  out.append(
    "Other Claude sessions active in 30 min: \(sessions.count)"
      + (listed.isEmpty ? "" : " (\(listed.joined(separator: "; ")))"))
  return out
}

/// The words of each simple command of a Bash command line, quotes removed and quoted text kept
/// as one word, after the assignments and wrappers (`env`, `sudo`, `xcrun` with its options)
/// that run the next word as the command. Only a command's first word names what it runs, so a
/// word mentioned in an argument (`grep xcodebuild`, a commit message) never counts.
func commandWords(_ command: String) -> [[String]] {
  var commands = [[String]]()
  var words = [String]()
  var word = ""
  var inWord = false
  var quote: Character?
  func endWord() {
    if inWord { words.append(word) }
    word = ""
    inWord = false
  }
  func endCommand() {
    endWord()
    if !words.isEmpty { commands.append(words) }
    words = []
  }
  var escaped = false
  for character in command {
    if escaped {
      // A backslash and newline continue the line; any other escaped character is literal.
      if character != "\n" {
        word.append(character)
        inWord = true
      }
      escaped = false
    } else if character == "\\" && quote != "'" {
      escaped = true
    } else if let open = quote {
      if character == open { quote = nil } else { word.append(character) }
    } else if character == "'" || character == "\"" {
      quote = character
      inWord = true
    } else if ";&|()\n".contains(character) {
      endCommand()
    } else if character.isWhitespace {
      endWord()
    } else {
      word.append(character)
      inWord = true
    }
  }
  endCommand()
  let wrappers: Set = ["env", "sudo", "time", "nohup", "command", "exec", "nice"]
  let xcrunValueOptions: Set = ["--sdk", "-sdk", "--toolchain", "-toolchain"]
  return commands.map { words in
    var words = words
    while let first = words.first {
      let name = (first as NSString).lastPathComponent
      if first.contains("=") && !first.hasPrefix("-") || wrappers.contains(name) {
        words.removeFirst()
      } else if name == "xcrun" {
        words.removeFirst()
        while let option = words.first, option.hasPrefix("-") {
          words.removeFirst()
          if xcrunValueOptions.contains(option), !words.isEmpty { words.removeFirst() }
        }
      } else {
        break
      }
    }
    return words
  }
}

/// What a tool call starts that an overloaded host would stall: an Xcode MCP build, test or
/// run tool or `DeviceInteractionInstallAndRun`, or a Bash command that runs `xcodebuild` (other
/// than a query such as `-version`), `swift build`, `swift test`, `simctl boot` or a
/// repository's `gate.sh`; nil otherwise.
func heavyWork(_ event: [String: Any]) -> String? {
  let tool = event["tool_name"] as? String ?? ""
  if tool.hasPrefix("mcp__"),
    let action = [
      "BuildProject", "RunAllTests", "RunSomeTests", "RunProject", "DeviceInteractionInstallAndRun",
    ].first(where: {
      tool.hasSuffix("__\($0)")
    })
  {
    return "Xcode \(action)"
  }
  guard tool == "Bash",
    let command = (event["tool_input"] as? [String: Any])?["command"] as? String
  else { return nil }
  let queries: Set = [
    "-version", "-list", "-showsdks", "-showBuildSettings", "-showdestinations", "-help",
    "-usage", "-showTestPlans", "-showComponent",
  ]
  for words in commandWords(command) {
    guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else {
      continue
    }
    let arguments = words.dropFirst()
    switch program {
    case "xcodebuild" where !arguments.contains(where: queries.contains):
      return "xcodebuild"
    case "gate.sh":
      return "gate.sh"
    case _
    where ["sh", "bash", "zsh"].contains(program)
      && arguments.first.map({ ($0 as NSString).lastPathComponent == "gate.sh" }) == true:
      return "gate.sh"
    case "swift" where arguments.first == "build" || arguments.first == "test":
      return "swift \(arguments.first!)"
    case "simctl" where arguments.first == "boot":
      return "simctl boot"
    default:
      continue
    }
  }
  return nil
}

/// Each `simctl` call in a Bash command line: its device set, subcommand and remaining words.
func simctlCalls(_ command: String) -> [(set: String?, subcommand: String, arguments: [String])] {
  commandWords(command).compactMap { words in
    guard let program = words.first, (program as NSString).lastPathComponent == "simctl" else {
      return nil
    }
    var rest = Array(words.dropFirst())
    var set: String?
    while let first = rest.first, first.hasPrefix("-") {
      rest.removeFirst()
      guard first == "--set" || first == "--profiles", !rest.isEmpty else { continue }
      let value = rest.removeFirst()
      if first == "--set" { set = value }
    }
    guard let subcommand = rest.first else { return nil }
    return (set, subcommand, Array(rest.dropFirst()))
  }
}

/// The Xcode MCP tools that run tests or the app, or open a device session, on a Simulator
/// they may boot.
let deviceTools = [
  "RunAllTests", "RunSomeTests", "RunProject", "DeviceInteractionInstallAndRun",
  "DeviceInteractionStartSession", "DeviceInteractionStartWorkspaceSession",
]

/// Why a tool call needs the user under the Simulator rules, one reason per rule it meets: it
/// creates or clones a device, deletes or erases one, shuts down every device, boots one more
/// at the budget, or starts tests or a run above it. `simulators` is read only when needed.
func simulatorReasons(_ event: [String: Any], simulators: () -> Simulators?) -> [String] {
  let tool = event["tool_name"] as? String ?? ""
  var reasons = [String]()
  var startsTestsOrRun =
    tool.hasPrefix("mcp__")
    && deviceTools.contains { tool.hasSuffix("__\($0)") }
  let command =
    tool == "Bash" ? (event["tool_input"] as? [String: Any])?["command"] as? String ?? "" : ""
  for words in commandWords(command) {
    let names = words.prefix(2).map { ($0 as NSString).lastPathComponent }
    let isGate =
      names.first == "gate.sh"
      || ["sh", "bash", "zsh"].contains(names.first ?? "")
        && names.dropFirst().first == "gate.sh"
    if isGate
      || names.first == "xcodebuild"
        && words.contains(where: { $0 == "test" || $0 == "test-without-building" })
    {
      startsTestsOrRun = true
    }
  }
  // Each boot earlier in the same command line adds a device before the next one is judged.
  var boots = 0
  for call in simctlCalls(command) {
    switch call.subcommand {
    case "create", "clone":
      var reason =
        "`simctl \(call.subcommand)` adds a Simulator. Reuse an existing device first; create one "
        + "only when the user approves, name it `agent-<task-id> <device type>` and delete it "
        + "when the task ends."
      if let available = simulators()?.available, !available.isEmpty {
        let sameType = available.filter { device in
          call.arguments.contains {
            device.type == $0
              || device.type.hasSuffix("." + $0.replacingOccurrences(of: " ", with: "-"))
          }
        }
        let names = sameType.map(\.name).sorted()
        if !names.isEmpty {
          reason +=
            " Existing devices of that type to reuse: \(names.prefix(6).joined(separator: ", "))"
            + (names.count > 6 ? " (+\(names.count - 6) more)." : ".")
        }
      }
      reasons.append(reason)
    case "delete", "erase":
      reasons.append(
        "`simctl \(call.subcommand)` permanently removes Simulator devices or their data. Unless "
          + "the device is one this task created, it may belong to another session or to the "
          + "user; name the exact devices to the user first.")
    case "shutdown" where call.arguments.first == "all":
      reasons.append(
        "`simctl shutdown all` stops every "
          + (call.set == "previews" ? "Xcode Preview " : "")
          + "Simulator, including devices other sessions are using.")
    case "boot":
      defer { boots += 1 }
      if let found = simulators(), found.bootedCount + boots >= simulatorBudget {
        reasons.append(
          "\(found.bootedCount + boots) Simulators are already booted or booting "
            + "(\(found.booted.count) + \(found.previews.count) Xcode Preview before this "
            + "command); the budget is \(simulatorBudget). Reuse a booted device, or have the "
            + "user shut one down first.")
      }
    default:
      break
    }
  }
  if startsTestsOrRun, let found = simulators(), found.bootedCount > simulatorBudget {
    reasons.append(
      "\(found.bootedCount) Simulators are booted (\(found.booted.count) + "
        + "\(found.previews.count) Xcode Preview), over the budget of \(simulatorBudget). "
        + "Run on an already booted device, or have the user shut one down first.")
  }
  return reasons
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

// Before a build, test run or Simulator boot, an overloaded or full host goes to the user
// instead of a silent wait; so does a call that breaks the Simulator rules.
if event["hook_event_name"] as? String == "PreToolUse" {
  var reasons = [String]()
  if let work = heavyWork(event) {
    let measured = host(cwd: cwd)
    if measured.isOverloaded || measured.isStorageLow {
      var facts = [
        String(format: "load %.0f on %d cores", measured.load, measured.processors),
        measured.memoryFree.map { "memory \($0)% free" } ?? "memory unknown",
        "\(measured.simulatorProcesses) CoreSimulator processes",
      ]
      if measured.isStorageLow, let free = measured.freeBytes {
        facts.append("\(gigabytes(free)) free on \(measured.volume)")
      }
      reasons.append(
        "The host is " + (measured.isOverloaded ? "overloaded" : "low on storage")
          + " (\(facts.joined(separator: ", "))). Starting \(work) now may stall for many "
          + "minutes before it makes progress. Run it now, or wait and retry later?")
    }
  }
  var read: Simulators??
  reasons += simulatorReasons(event) {
    if read == nil { read = .some(simulators(cache: cache)) }
    return read!
  }
  // A call that may change which devices exist or run makes the cached list stale; the next
  // reading asks `simctl` again rather than letting a second boot pass on the old count.
  let changing: Set = ["boot", "create", "clone", "delete", "erase", "shutdown"]
  let command = (event["tool_input"] as? [String: Any])?["command"] as? String ?? ""
  let tool = event["tool_name"] as? String ?? ""
  if tool == "Bash" && simctlCalls(command).contains(where: { changing.contains($0.subcommand) })
    || tool.hasPrefix("mcp__") && deviceTools.contains(where: { tool.hasSuffix("__\($0)") })
  {
    try? FileManager.default.removeItem(
      at: cache.appendingPathComponent("booted-simulators.json"))
  }
  if !reasons.isEmpty {
    let output: [String: Any] = [
      "hookSpecificOutput": [
        "hookEventName": "PreToolUse", "permissionDecision": "ask",
        "permissionDecisionReason": "apple-platform-engineer: " + reasons.joined(separator: " "),
      ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output) {
      FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
  }
  exit(0)
}

let here = Box(Repository(path: cwd))
let leftoverState = Box<Leftovers?>(nil)
let handoffState = Box([WaitingHandoff]())
let xcode = Box<[(String, Repository)]?>(nil)
let simulatorState = Box<Simulators?>(nil)
let sessions = Box([OtherSession]())
let machine = Box<Host?>(nil)
let group = DispatchGroup()
func concurrently(_ work: @escaping @Sendable () -> Void) {
  DispatchQueue.global().async(group: group, execute: work)
}
concurrently {
  let repo = repository(at: cwd)
  here.value = repo
  handoffState.value = repo.common.map(waitingHandoffs) ?? []
  leftoverState.value = leftovers(of: repo, cache: cache)
}
concurrently {
  guard let paths = xcodeDocuments() else { return }
  let documents = Box([(String, Repository)?](repeating: nil, count: paths.count))
  DispatchQueue.concurrentPerform(iterations: paths.count) { index in
    let repo = repository(at: (paths[index] as NSString).deletingLastPathComponent)
    documents.mutate { $0[index] = (paths[index], repo) }
  }
  xcode.value = documents.value.compactMap { $0 }
}
concurrently { simulatorState.value = simulators(cache: cache) }
concurrently { sessions.value = otherSessions(home: home, ownID: ownID) }
concurrently { machine.value = host(cwd: cwd) }
// Whatever is not in by the deadline stays unknown; the status never outlives its budget.
_ = group.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow) + 0.5)

let measured =
  machine.value
  ?? Host(load: 0, processors: 1, memoryFree: nil, simulatorProcesses: 0, volume: "volume")
let shown = lines(
  here: here.value, leftovers: leftoverState.value, handoffs: handoffState.value,
  xcode: xcode.value,
  simulators: simulatorState.value, sessions: sessions.value, host: measured, home: home)
var guidance =
  "Live session environment, read just now. Before editing, building, testing, committing or "
  + "publishing, confirm the target directory, Xcode container, branch and worktree match the "
  + "task; on a mismatch, or another session working in the same checkout, stop and ask. "
  + "Reuse a booted or existing Simulator; never create, delete, erase or shut down every "
  + "Simulator without the user's approval."
if let found = leftoverState.value,
  found.currentPullRequest != nil || found.branches + found.worktrees > 0
{
  guidance +=
    " Merged pull requests left branches or worktrees here: follow git-workflow branch "
    + "hygiene, start new work on a new branch, and remove only what this task created."
}
if !handoffState.value.isEmpty {
  guidance +=
    " A handoff from another agent is waiting for Claude in this repository: tell the user, "
    + "and when they want to continue it, follow the session-handoff skill and run "
    + "`handoff resume --as claude` with the apple-verify it locates."
}
if measured.isOverloaded || measured.isStorageLow {
  guidance +=
    " The host is overloaded or low on storage: before starting a build, test run or Simulator, "
    + "tell the user and ask whether to wait, rather than waiting silently for it to finish."
}
let output: [String: Any] = [
  "systemMessage": shown.joined(separator: "\n"),
  "hookSpecificOutput": [
    "hookEventName": event["hook_event_name"] as? String ?? "UserPromptSubmit",
    "additionalContext": ([guidance] + shown.map { "- \($0)" }).joined(separator: "\n"),
  ],
]
if let data = try? JSONSerialization.data(withJSONObject: output) {
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}
