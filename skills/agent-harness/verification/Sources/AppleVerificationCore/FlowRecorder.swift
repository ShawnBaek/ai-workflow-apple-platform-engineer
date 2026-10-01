import Foundation

/// Turns one hook stdin object into at most one redacted `FlowEvent`.
///
/// Normalization reads only the documented fields it needs. It classifies error text and
/// extracts the spawned agent id from a spawn tool's result without keeping either.
public enum FlowNormalizer {
  public static func event(
    from input: [String: Any], client: String, hasher: FlowHasher, includeLabels: Bool = false,
    at date: Date
  ) -> FlowEvent? {
    guard FlowVocabulary.clients.contains(client),
      let hookEvent = input["hook_event_name"] as? String,
      let sessionID = nonEmpty(input["session_id"])
    else { return nil }
    func agentHash(_ raw: String) -> String {
      hasher.hash("agent", normalizedAgentID(raw, client: client))
    }
    var agent = FlowEvent.Agent()
    if let id = nonEmpty(input["agent_id"]) { agent.id = agentHash(id) }
    if let type = nonEmpty(input["agent_type"]) {
      if FlowVocabulary.agentTypes(for: client).contains(type) {
        agent.type = type
      } else {
        agent.type = "custom:" + hasher.hash("agent_type", type)
        if includeLabels { agent.typeLabel = label(type) }
      }
    }
    // Codex sends turn_id; Claude Code's prompt_id identifies the prompt being processed.
    let turn = nonEmpty(input["turn_id"] ?? input["prompt_id"]).map { hasher.hash("turn", $0) }
    var step: FlowEvent.Step
    var duration: Int?
    switch hookEvent {
    case "PreToolUse", "PostToolUse", "PostToolUseFailure":
      if hookEvent == "PostToolUseFailure" && client != "claude" { return nil }
      guard let toolName = nonEmpty(input["tool_name"]) else { return nil }
      // Claude Code 2.1.274 and later name an MCP tool's server in `mcp_server.name`.
      let server = (input["mcp_server"] as? [String: Any]).flatMap { nonEmpty($0["name"]) }
      let named = toolIdentity(
        toolName, client: client, hasher: hasher, mcpServer: client == "claude" ? server : nil)
      step = FlowEvent.Step(
        id: nonEmpty(input["tool_use_id"]).map { hasher.hash("tool_use", $0) }, kind: "tool",
        name: named.name, status: "started")
      if includeLabels { step.label = named.label }
      if hookEvent == "PostToolUse" {
        step.status = "completed"
        if FlowVocabulary.spawnTools(for: client).contains(toolName),
          let child = spawnedAgentID(input["tool_response"], client: client)
        {
          step.spawns = agentHash(child)
        }
      } else if hookEvent == "PostToolUseFailure" {
        let interrupted = input["is_interrupt"] as? Bool == true
        step.status = interrupted ? "interrupted" : "failed"
        step.errorClass = interrupted ? "interrupt" : errorClass(input["error"])
      }
      if hookEvent != "PreToolUse" { duration = clientDuration(input["duration_ms"]) }
    case "SubagentStart", "SubagentStop":
      guard agent.id != nil else { return nil }
      step = FlowEvent.Step(
        kind: "subagent", name: hookEvent,
        status: hookEvent == "SubagentStart" ? "started" : "completed")
    case "PreCompact", "PostCompact":
      step = FlowEvent.Step(
        kind: "compaction", name: "Compact",
        status: hookEvent == "PreCompact" ? "started" : "completed",
        detail: allowed(input["trigger"], FlowVocabulary.compactTriggers))
    case "SessionStart":
      step = FlowEvent.Step(
        kind: "session", name: "SessionStart", status: "completed",
        detail: allowed(input["source"], FlowVocabulary.sessionSources))
    case "SessionEnd":
      step = FlowEvent.Step(
        kind: "session", name: "SessionEnd", status: "completed",
        detail: allowed(input["reason"], FlowVocabulary.sessionEndReasons))
    case "Stop":
      step = FlowEvent.Step(kind: "turn", name: "Stop", status: "completed")
    case "Interrupt" where client == "codex":
      step = FlowEvent.Step(kind: "turn", name: "Interrupt", status: "interrupted")
    default:
      return nil
    }
    return FlowEvent(
      schemaVersion: FlowEvent.schemaVersion,
      source: FlowEvent.Source(client: client, capture: "hook"), event: hookEvent,
      session: hasher.hash("session", sessionID),
      agent: agent.id == nil && agent.type == nil ? nil : agent, turn: turn, step: step,
      at: FlowTime.format(date), durationMs: duration)
  }

  /// Claude Code names a subagent transcript `agent-<id>.jsonl`; accept either spelling of the
  /// id so the Agent tool's `agentId` and a hook's `agent_id` hash alike.
  static func normalizedAgentID(_ raw: String, client: String) -> String {
    client == "claude" && raw.hasPrefix("agent-") ? String(raw.dropFirst(6)) : raw
  }

  /// Claude Code's Agent tool result carries `agentId`. Codex's v1 `spawn_agent` result is
  /// JSON text whose `agent_id` is the child thread id, the same id its SubagentStart reports.
  static func spawnedAgentID(_ response: Any?, client: String) -> String? {
    var object = response as? [String: Any]
    if object == nil, let text = response as? String, text.utf8.count <= 65_536,
      let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    {
      object = parsed
    }
    return nonEmpty(object?[client == "claude" ? "agentId" : "agent_id"])
  }

  /// An MCP tool is `mcp__<server>__<tool>`. The split is trusted only when the client names
  /// the server or the name has one `__` after the prefix; otherwise part of the server name
  /// could land in the tool segment, so that segment is hashed too.
  static func toolIdentity(
    _ raw: String, client: String, hasher: FlowHasher, mcpServer: String? = nil
  ) -> (name: String, label: String?) {
    if raw.hasPrefix("mcp__") {
      let rest = raw.dropFirst(5)
      var server = rest
      var tool: Substring = ""
      var trusted = false
      if let mcpServer, rest.hasPrefix(mcpServer + "__") {
        server = rest.prefix(mcpServer.count)
        tool = rest.dropFirst(mcpServer.count + 2)
        trusted = true
      } else if let separator = rest.range(of: "__") {
        server = rest[..<separator.lowerBound]
        tool = rest[separator.upperBound...]
        trusted = !tool.contains("__")
      }
      let toolPart =
        trusted && isSafeToken(tool) ? String(tool) : "#" + hasher.hash("mcp_tool", String(tool))
      return (
        "mcp:\(hasher.hash("mcp_server", String(server)))/\(toolPart)",
        label(trusted ? server : rest)
      )
    }
    if FlowVocabulary.tools(for: client).contains(raw) { return (raw, nil) }
    return ("tool:" + hasher.hash("tool", raw), label(raw))
  }

  /// Maps error text to a class. The text itself is never stored.
  static func errorClass(_ value: Any?) -> String {
    guard let text = value as? String else { return "error" }
    let lowered = text.prefix(4_096).lowercased()
    if lowered.hasPrefix("exit code ") { return "exit_code" }
    if lowered.contains("timed out") || lowered.contains("timeout") { return "timeout" }
    if lowered.contains("permission") || lowered.contains("denied") { return "denied" }
    return "error"
  }

  static func clientDuration(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let milliseconds = number.doubleValue
    guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 604_800_000 else { return nil }
    return Int(milliseconds.rounded())
  }

  static func allowed(_ value: Any?, _ vocabulary: Set<String>) -> String? {
    guard let text = value as? String else { return nil }
    return vocabulary.contains(text) ? text : "unknown"
  }

  static func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty, text.utf8.count <= 1_024 else { return nil }
    return text
  }

  static func isSafeToken<S: StringProtocol>(_ value: S) -> Bool {
    !value.isEmpty && value.count <= 64
      && value.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0))
          || "_-.".unicodeScalars.contains($0)
      }
  }

  /// A label keeps no control, format (including bidi overrides and isolates) or line and
  /// paragraph separator characters, and at most 64 scalars.
  static func label<S: StringProtocol>(_ value: S) -> String {
    String(
      String.UnicodeScalarView(
        value.unicodeScalars.filter {
          ![.control, .format, .lineSeparator, .paragraphSeparator].contains(
            $0.properties.generalCategory)
        }.prefix(64)))
  }
}

/// The per-user store: a `salt` file and one `<session-hash>.jsonl` file per session.
public enum FlowStore {
  public static let saltFile = "salt"
  static let maximumInputBytes = 64 * 1_024 * 1_024

  /// The hook entry point. It never throws, never writes to stdout and never reads anything
  /// other than `input` and the store's salt; a failure records nothing.
  @discardableResult
  public static func record(
    input: Data, client: String, store: String, includeLabels: Bool = false, now: Date = Date()
  ) -> Bool {
    // Check that the input is recordable before touching the disk.
    guard store.hasPrefix("/"), FlowVocabulary.clients.contains(client),
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let probe = FlowHasher(saltHex: String(repeating: "0", count: 64)),
      FlowNormalizer.event(from: object, client: client, hasher: probe, at: now) != nil,
      ensureDirectory(store), let hasher = salt(store: store, create: true),
      let event = FlowNormalizer.event(
        from: object, client: client, hasher: hasher, includeLabels: includeLabels, at: now)
    else { return false }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard var line = try? encoder.encode(event) else { return false }
    line.append(10)
    return append(line, to: store + "/" + event.session + ".jsonl")
  }

  /// Reads stdin up to the bound, then drains the rest so the client never sees a broken pipe.
  static func readStandardInput() -> Data? {
    var data = Data()
    var overflow = false
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(STDIN_FILENO, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      if data.count + count > maximumInputBytes { overflow = true }
      if !overflow { data.append(buffer, count: count) }
    }
    return overflow ? nil : data
  }

  /// Accepts an existing real directory, or creates only the final directory with mode 0700
  /// inside an existing parent. A symlinked store and `.` or `..` components are refused, so
  /// the recorder never writes outside the directory it was given.
  static func ensureDirectory(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    // A trailing slash would make lstat resolve a symlinked store, so it is refused too.
    guard path.hasPrefix("/"), !path.hasSuffix("/"), !components.isEmpty,
      !components.contains(where: { $0 == "." || $0 == ".." })
    else { return false }
    var info = stat()
    if lstat(path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
    guard errno == ENOENT else { return false }
    let created = mkdir(path, 0o700) == 0
    guard created || errno == EEXIST, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
    else { return false }
    if created { chmod(path, 0o700) }
    return true
  }

  /// Returns the store's hasher. The salt is created once with an exclusive link, so racing
  /// recorders agree on one salt without locks, and it is never overwritten.
  public static func salt(store: String, create: Bool) -> FlowHasher? {
    let path = store + "/" + saltFile
    if let hasher = readSalt(path) { return hasher }
    guard create else { return nil }
    // SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let hex = Array((bytes.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
    let temporary = store + "/.salt-\(getpid())-\(UUID().uuidString)"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    let written = hex.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    close(fd)
    defer { unlink(temporary) }
    guard written == hex.count else { return nil }
    _ = link(temporary, path)
    return readSalt(path)
  }

  static func readSalt(_ path: String) -> FlowHasher? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: 128)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { return nil }
    return FlowHasher(saltHex: String(decoding: buffer[0..<count], as: UTF8.self))
  }

  /// One `write` of one complete line under `O_APPEND`: concurrent hooks interleave whole
  /// lines without a lock.
  static func append(_ line: Data, to path: String) -> Bool {
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return written == line.count
  }

  /// Resolves a raw session id or a stored session hash to its file without creating anything.
  public static func sessionFile(store: String, session: String) throws -> URL {
    let directory = URL(fileURLWithPath: store)
    if FlowHasher.isHash(session) {
      let file = directory.appendingPathComponent(session + ".jsonl")
      if FileManager.default.fileExists(atPath: file.path) { return file }
    }
    guard let hasher = salt(store: store, create: false) else {
      throw VerificationError.invalid("No flow store salt at \(store)")
    }
    let file = directory.appendingPathComponent(hasher.hash("session", session) + ".jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw VerificationError.invalid("No recorded flow for that session in \(store)")
    }
    return file
  }
}
