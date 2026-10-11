import Darwin
import Foundation

// Claude Code SessionStart and UserPromptSubmit hook. Collects, read-only, where this session
// works and what else is running: the directory's Git branch, upstream and worktree, every
// workspace or project open in Xcode with its branch, the booted Simulators, the other Claude
// sessions active in the last 30 minutes, the host's load and memory, and the free storage of
// the working volume. It shows them to the person (`systemMessage`) and gives them to the agent
// (`additionalContext`). A failure only leaves a fact out or marks it unknown.

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
func run(_ argv: [String], timeout: TimeInterval = commandTimeout) -> String? {
  let timeout = min(timeout, deadline.timeIntervalSinceNow)
  guard timeout > 0 else { return nil }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: argv[0])
  process.arguments = Array(argv.dropFirst())
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

/// Booted Simulator names, cached for a minute because `simctl` is slow. An unknown answer is
/// cached too, so a stuck CoreSimulator costs one wait a minute; nil when unknown.
func bootedSimulators(cache: URL) -> [String]? {
  let file = cache.appendingPathComponent("booted-simulators.json")
  if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
    let modified = attributes[.modificationDate] as? Date,
    Date().timeIntervalSince(modified) < 60,
    let data = try? Data(contentsOf: file),
    let cached = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  {
    return cached["names"] as? [String]
  }
  var names: [String]?
  if let json = run(["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"], timeout: 8),
    let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
    let devices = object["devices"] as? [String: [[String: Any]]]
  {
    names = devices.values.flatMap { $0 }.compactMap { $0["name"] as? String }.sorted()
  }
  try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  let record: [String: Any] = names.map { ["names": $0] } ?? [:]
  if let data = try? JSONSerialization.data(withJSONObject: record) {
    try? data.write(to: file, options: .atomic)
  }
  return names
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
  here: Repository, xcode: [(String, Repository)]?, simulators: [String]?,
  sessions: [OtherSession], host: Host, home: String
) -> [String] {
  var out = [String]()
  let loadText = String(format: "load %.0f on %d cores", host.load, host.processors)
  let memoryText = host.memoryFree.map { "memory \($0)% free" } ?? "memory unknown"
  if host.isOverloaded {
    out.append(
      "WARNING Host overloaded: \(loadText), \(memoryText), "
        + "\(host.simulatorProcesses) CoreSimulator processes")
  }
  if host.isStorageLow, let free = host.freeBytes {
    out.append("WARNING Storage low: \(gigabytes(free)) free on \(host.volume)")
  }
  out.append(
    "Directory \(tilde(here.top ?? here.path, home)) · \(branchText(here))"
      + worktreeText(here, home))
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
        + (simulators.isEmpty ? "" : " (\(simulators.joined(separator: ", ")))")
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

/// The words each simple command of a Bash command line starts with, quoted text removed, so
/// a word only mentioned in an argument (`grep xcodebuild`, a commit message) never counts.
func commandWords(_ command: String) -> [[String]] {
  var unquoted = ""
  var quote: Character?
  for character in command {
    if let open = quote {
      if character == open { quote = nil }
      continue
    }
    if character == "'" || character == "\"" {
      quote = character
      unquoted.append(" ")
    } else {
      unquoted.append(character)
    }
  }
  return unquoted.split(whereSeparator: { ";&|()\n".contains($0) }).map { segment in
    var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
    // Assignments and the wrappers that run the next word as the command.
    while let first = words.first,
      first.contains("=") && !first.hasPrefix("-")
        || ["env", "sudo", "time", "nohup", "command", "exec", "nice", "xcrun"].contains(first)
    {
      words.removeFirst()
    }
    return words
  }
}

/// What a tool call starts that an overloaded host would stall: an Xcode MCP build, test or
/// run tool, or a Bash command that runs `xcodebuild` (other than a query such as `-version`),
/// `swift build`, `swift test`, `simctl boot` or a repository's `gate.sh`; nil otherwise.
func heavyWork(_ event: [String: Any]) -> String? {
  let tool = event["tool_name"] as? String ?? ""
  if tool.hasPrefix("mcp__"),
    let action = ["BuildProject", "RunAllTests", "RunSomeTests", "RunProject"].first(where: {
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
// instead of a silent wait.
if event["hook_event_name"] as? String == "PreToolUse" {
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
      let reason =
        "apple-platform-engineer: the host is "
        + (measured.isOverloaded ? "overloaded" : "low on storage")
        + " (\(facts.joined(separator: ", "))). Starting \(work) now may stall for many "
        + "minutes before it makes progress. Run it now, or wait and retry later?"
      let output: [String: Any] = [
        "hookSpecificOutput": [
          "hookEventName": "PreToolUse", "permissionDecision": "ask",
          "permissionDecisionReason": reason,
        ]
      ]
      if let data = try? JSONSerialization.data(withJSONObject: output) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
      }
    }
  }
  exit(0)
}

let here = Box(Repository(path: cwd))
let xcode = Box<[(String, Repository)]?>(nil)
let simulators = Box<[String]?>(nil)
let sessions = Box([OtherSession]())
let machine = Box<Host?>(nil)
let group = DispatchGroup()
func concurrently(_ work: @escaping @Sendable () -> Void) {
  DispatchQueue.global().async(group: group, execute: work)
}
concurrently { here.value = repository(at: cwd) }
concurrently {
  guard let paths = xcodeDocuments() else { return }
  let documents = Box([(String, Repository)?](repeating: nil, count: paths.count))
  DispatchQueue.concurrentPerform(iterations: paths.count) { index in
    let repo = repository(at: (paths[index] as NSString).deletingLastPathComponent)
    documents.mutate { $0[index] = (paths[index], repo) }
  }
  xcode.value = documents.value.compactMap { $0 }
}
concurrently { simulators.value = bootedSimulators(cache: cache) }
concurrently { sessions.value = otherSessions(home: home, ownID: ownID) }
concurrently { machine.value = host(cwd: cwd) }
// Whatever is not in by the deadline stays unknown; the status never outlives its budget.
_ = group.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow) + 0.5)

let measured =
  machine.value
  ?? Host(load: 0, processors: 1, memoryFree: nil, simulatorProcesses: 0, volume: "volume")
let shown = lines(
  here: here.value, xcode: xcode.value, simulators: simulators.value, sessions: sessions.value,
  host: measured, home: home)
var guidance =
  "Live session environment, read just now. Before editing, building, testing, committing or "
  + "publishing, confirm the target directory, Xcode container, branch and worktree match the "
  + "task; on a mismatch, or another session working in the same checkout, stop and ask."
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
