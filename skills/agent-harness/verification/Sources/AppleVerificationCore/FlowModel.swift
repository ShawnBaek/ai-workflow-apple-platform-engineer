import CryptoKit
import Foundation

/// One redacted hook observation, stored as a single JSONL line (schema_version 1).
///
/// Every field is an allowlisted enum, a salted hash, an allowlisted name, a timestamp or a
/// client-reported duration. Prompts, messages, tool input and output, commands, paths, working
/// directories, transcript paths, error text, descriptions and nicknames are never represented.
public struct FlowEvent: Codable, Equatable, Sendable {
  public struct Source: Codable, Equatable, Sendable {
    public var client: String
    public var capture: String
  }

  public struct Agent: Codable, Equatable, Sendable {
    /// Salted hash of the client's agent id; absent for the session's root agent.
    public var id: String?
    /// A known built-in agent type, or `custom:<hash>` for any other type.
    public var type: String?
    /// The raw custom type, present only when the recorder ran with `--include-labels`.
    public var typeLabel: String?

    enum CodingKeys: String, CodingKey {
      case id, type
      case typeLabel = "type_label"
    }
  }

  public struct Step: Codable, Equatable, Sendable {
    /// Salted hash of `tool_use_id` for tool steps.
    public var id: String?
    public var kind: String
    public var name: String
    public var status: String
    /// An allowlisted enum: session start source, session end reason or compaction trigger.
    public var detail: String?
    public var errorClass: String?
    /// Salted hash of the agent this step spawned.
    public var spawns: String?
    /// Raw MCP server or unknown tool name, present only with `--include-labels`.
    public var label: String?

    enum CodingKeys: String, CodingKey {
      case id, kind, name, status, detail, spawns, label
      case errorClass = "error_class"
    }
  }

  public var schemaVersion: Int
  public var source: Source
  public var event: String
  public var session: String
  public var agent: Agent?
  public var turn: String?
  public var step: Step
  public var at: String
  public var durationMs: Int?

  enum CodingKeys: String, CodingKey {
    case source, event, session, agent, turn, step, at
    case schemaVersion = "schema_version"
    case durationMs = "duration_ms"
  }

  public static let schemaVersion = 1
}

/// Salted, truncated HMAC-SHA256 of identifiers. The salt stays in the store.
public struct FlowHasher: Sendable {
  let salt: Data

  public init?(saltHex: String) {
    let trimmed = saltHex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 64, let data = Data(flowHex: trimmed) else { return nil }
    salt = data
  }

  /// 16 lowercase hex characters (64 bits), scoped by `domain` so equal values in different
  /// roles do not share a hash.
  public func hash(_ domain: String, _ value: String) -> String {
    let code = HMAC<SHA256>.authenticationCode(
      for: Data((domain + "\u{0}" + value).utf8), using: SymmetricKey(data: salt))
    return code.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  public static func isHash(_ value: String) -> Bool {
    value.count == 16 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}

extension Data {
  init?(flowHex text: String) {
    var bytes = [UInt8]()
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
      guard let byte = UInt8(text[index..<next], radix: 16), next != index else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}

/// Names and enum values that may be stored verbatim. Anything else is hashed or dropped.
public enum FlowVocabulary {
  public static let clients: Set<String> = ["claude", "codex"]

  /// Claude Code built-in tools (code.claude.com/docs/en/tools-reference), plus `Task`, the
  /// Agent tool's earlier name.
  public static let claudeTools: Set<String> = [
    "Agent", "Artifact", "AskUserQuestion", "Bash", "CronCreate", "CronDelete", "CronList",
    "Edit", "EndConversation", "EnterPlanMode", "EnterWorktree", "ExitPlanMode", "ExitWorktree",
    "Glob", "Grep", "ListAgents", "ListMcpResourcesTool", "LSP", "Monitor", "NotebookEdit",
    "PowerShell", "PushNotification", "Read", "ReadMcpResourceTool", "RemoteTrigger",
    "ReportFindings", "ScheduleWakeup", "SendFeedback", "SendMessage", "SendUserFile",
    "ShareOnboardingGuide", "Skill", "SubagentHandback", "Task", "TaskCreate", "TaskGet",
    "TaskList", "TaskOutput", "TaskStop", "TaskUpdate", "TodoWrite", "ToolSearch",
    "WaitForMcpServers", "WebFetch", "WebSearch", "Workflow", "Write",
  ]

  /// Codex hook tool names (openai/codex rust-v0.159.0: `hook_names.rs` and tool handlers).
  public static let codexTools: Set<String> = [
    "Bash", "apply_patch", "spawn_agent", "send_input", "wait", "close_agent", "resume_agent",
    "update_plan", "view_image", "request_user_input", "list_mcp_resources",
    "list_mcp_resource_templates", "read_mcp_resource",
  ]

  /// Tools whose successful result names the spawned agent.
  public static let claudeSpawnTools: Set<String> = ["Agent", "Task"]
  public static let codexSpawnTools: Set<String> = ["spawn_agent"]

  public static let claudeAgentTypes: Set<String> = [
    "general-purpose", "Explore", "Plan", "claude", "statusline-setup", "claude-code-guide",
  ]
  public static let codexAgentTypes: Set<String> = ["default", "explorer", "worker"]

  public static let sessionSources: Set<String> = ["startup", "resume", "clear", "compact", "fork"]
  public static let sessionEndReasons: Set<String> = [
    "clear", "resume", "logout", "prompt_input_exit", "other", "bypass_permissions_disabled",
  ]
  public static let compactTriggers: Set<String> = ["manual", "auto"]

  static func tools(for client: String) -> Set<String> {
    client == "claude" ? claudeTools : codexTools
  }

  static func spawnTools(for client: String) -> Set<String> {
    client == "claude" ? claudeSpawnTools : codexSpawnTools
  }

  static func agentTypes(for client: String) -> Set<String> {
    client == "claude" ? claudeAgentTypes : codexAgentTypes
  }
}

enum FlowTime {
  static func format(_ date: Date) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
  }

  static func parse(_ text: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
      return date
    }
    return try? Date.ISO8601FormatStyle().parse(text)
  }
}
