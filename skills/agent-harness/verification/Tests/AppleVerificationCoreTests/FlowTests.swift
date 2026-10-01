import Foundation
import Testing

@testable import AppleVerificationCore

/// Synthetic hook fixtures only: every sensitive value in them contains "CANARY".
private enum FlowFixture {
  static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/flow")
  static let salt = String(repeating: "5a", count: 32)
  static let start = Date(timeIntervalSince1970: 1_790_000_000)

  static func hookLines(_ name: String) throws -> [String] {
    try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  /// A fresh store whose salt is fixed, so hashes and Mermaid ids are reproducible.
  static func store(salt: String? = FlowFixture.salt) throws -> URL {
    let store = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    if let salt {
      try (salt + "\n").write(
        to: store.appendingPathComponent(FlowStore.saltFile), atomically: true, encoding: .utf8)
    }
    return store
  }

  /// Records hook inputs one second apart and returns the single session file's lines.
  @discardableResult
  static func record(
    _ inputs: [String], client: String, store: URL, includeLabels: Bool = false
  ) throws -> [String] {
    for (index, input) in inputs.enumerated() {
      FlowStore.record(
        input: Data(input.utf8), client: client, store: store.path, includeLabels: includeLabels,
        now: start.addingTimeInterval(Double(index)))
    }
    return try sessionLines(store)
  }

  static func sessionFiles(_ store: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
  }

  static func sessionLines(_ store: URL) throws -> [String] {
    let files = try sessionFiles(store)
    guard files.count == 1 else { return [] }
    return try String(contentsOf: files[0], encoding: .utf8).split(separator: "\n")
      .map(String.init)
  }

  static func render(
    _ lines: [String], _ format: FlowRenderFormat, maxSteps: Int = 500,
    includeLabels: Bool = false, ledger: [String]? = nil
  ) -> String {
    FlowRenderer.render(
      eventLines: lines, ledgerLines: ledger,
      options: FlowRenderOptions(format: format, maxSteps: maxSteps, includeLabels: includeLabels))
  }

  static func hook(_ fields: [String: Any]) -> String {
    var object: [String: Any] = [
      "session_id": "CANARY-session", "cwd": "/Users/CANARY-home",
      "transcript_path": "/Users/CANARY-home/t.jsonl",
    ]
    object.merge(fields) { $1 }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  /// Reduces a tree to its client-neutral shape: hashes, durations, the client name and each
  /// client's spelling of the same tool or agent type become placeholders.
  static func shape(_ tree: String) -> String {
    var text = tree
    for (pattern, replacement) in [
      (#"\b[0-9a-f]{8}\b"#, "#"), (#" · [0-9.]+ m?s\b"#, ""), (#"\b(claude|codex)\b"#, "CLIENT"),
      (#"\b(Edit|apply_patch)\b"#, "EDIT"), (#"\b(Agent|spawn_agent)\b"#, "SPAWN"),
      (#"\b(Explore|explorer)\b"#, "TYPE1"), (#"(general-purpose|\bworker\b)"#, "TYPE2"),
    ] {
      text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return text
  }
}

private final class FlowBundleLocator {}

@Suite struct FlowTests {
  @Test(arguments: ["claude", "codex"])
  func fixtureRendersItsGoldenFiles(client: String) throws {
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    let lines = try FlowFixture.record(
      try FlowFixture.hookLines("\(client)-session.jsonl"), client: client, store: store)
    // UserPromptSubmit is not a flow event, so 25 of the 26 hook inputs are stored.
    #expect(lines.count == 25)
    for (format, suffix) in [(FlowRenderFormat.tree, "tree.txt"), (.mermaid, "mmd")] {
      let output = FlowFixture.render(lines, format)
      let golden = FlowFixture.directory.appendingPathComponent("\(client).\(suffix)")
      if ProcessInfo.processInfo.environment["FLOW_UPDATE_GOLDENS"] == "1" {
        try output.write(to: golden, atomically: true, encoding: .utf8)
      }
      #expect(output == (try String(contentsOf: golden, encoding: .utf8)))
    }
  }

  @Test func claudeAndCodexFixturesShareOneTreeShape() throws {
    var shapes: [String] = []
    for client in ["claude", "codex"] {
      let store = try FlowFixture.store()
      defer { try? FileManager.default.removeItem(at: store) }
      let lines = try FlowFixture.record(
        try FlowFixture.hookLines("\(client)-session.jsonl"), client: client, store: store)
      shapes.append(FlowFixture.shape(FlowFixture.render(lines, .tree)))
    }
    #expect(shapes[0] == shapes[1])
    // The shape still carries the nested spawn chain and every lane's completion.
    #expect(shapes[0].contains("SPAWN → TYPE1 #"))
    #expect(shapes[0].contains("SPAWN → TYPE2 #"))
    #expect(shapes[0].contains("TYPE2 # · completed"))
    #expect(!shapes[0].contains("unlinked"))
  }

  @Test func canaryStringsNeverReachTheStoreOrOutput() throws {
    for (client, session) in [
      ("claude", "CANARY-session-7c1d"), ("codex", "019a-CANARY-thread-root"),
    ] {
      let store = try FlowFixture.store(salt: nil)
      defer { try? FileManager.default.removeItem(at: store) }
      var inputs = try FlowFixture.hookLines("\(client)-session.jsonl")
      inputs += [
        FlowFixture.hook([
          "hook_event_name": "PreToolUse", "session_id": session, "tool_name": "CANARY_custom_tool",
          "tool_use_id": "CANARY-9", "agent_id": "CANARY-agent-x", "agent_type": "CANARY-type",
          "tool_input": ["path": "/CANARY/path"],
        ]),
        FlowFixture.hook([
          "hook_event_name": "PostToolUseFailure", "session_id": session, "tool_name": "Bash",
          "tool_use_id": "CANARY-10",
          "error": "Exit code 1\nCANARY-ERROR at /Users/CANARY-home", "is_interrupt": false,
        ]),
      ]
      let lines = try FlowFixture.record(inputs, client: client, store: store)
      #expect(lines.count > 20)
      var outputs = [FlowFixture.render(lines, .tree), FlowFixture.render(lines, .mermaid)]
      // Without a recorder opt-in, render-side labels have nothing to reveal.
      outputs.append(FlowFixture.render(lines, .mermaid, includeLabels: true))
      for file in try FileManager.default.contentsOfDirectory(
        at: store, includingPropertiesForKeys: nil)
      {
        outputs.append(try String(contentsOf: file, encoding: .utf8))
      }
      for text in outputs {
        #expect(!text.contains("CANARY"), "\(client): \(text)")
        #expect(!text.lowercased().contains("canary"))
      }
    }
  }

  @Test func labelsNeedBothTheRecorderAndTheRendererOptIn() throws {
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    let inputs = [
      FlowFixture.hook([
        "hook_event_name": "PreToolUse", "tool_name": "mcp__github__search", "tool_use_id": "u1",
        "agent_id": "x1", "agent_type": "security-reviewer",
      ])
    ]
    let lines = try FlowFixture.record(inputs, client: "claude", store: store, includeLabels: true)
    #expect(!FlowFixture.render(lines, .tree).contains("github"))
    let labeled = FlowFixture.render(lines, .tree, includeLabels: true)
    #expect(labeled.contains("mcp:github/search"))
    #expect(labeled.contains("security-reviewer"))

    let plainStore = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: plainStore) }
    let plain = try FlowFixture.record(inputs, client: "claude", store: plainStore)
    let unlabeled = FlowFixture.render(plain, .tree, includeLabels: true)
    #expect(!unlabeled.contains("github") && !unlabeled.contains("security-reviewer"))
    #expect(unlabeled.contains("/search"))
  }

  @Test func missingPostIsIncompleteAndFailuresAreFailedOrInterrupted() throws {
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    let lines = try FlowFixture.record(
      [
        FlowFixture.hook(["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_use_id": "1"]
        ),
        FlowFixture.hook(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "2"]
        ),
        FlowFixture.hook([
          "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_use_id": "2",
          "error": "Exit code 2", "duration_ms": 4187,
        ]),
        FlowFixture.hook(["hook_event_name": "PreToolUse", "tool_name": "Grep", "tool_use_id": "3"]
        ),
        FlowFixture.hook([
          "hook_event_name": "PostToolUseFailure", "tool_name": "Grep", "tool_use_id": "3",
          "error": "aborted", "is_interrupt": true,
        ]),
      ], client: "claude", store: store)
    let tree = FlowFixture.render(lines, .tree)
    #expect(tree.contains("├─ Read (incomplete)\n"))
    #expect(tree.contains("├─ Bash (failed: exit_code) · 4.2 s\n"))
    #expect(tree.contains("└─ Grep (interrupted: interrupt)\n"))
    let mermaid = FlowFixture.render(lines, .mermaid)
    #expect(mermaid.contains("class root_0 incomplete"))
    #expect(mermaid.contains("class root_1 failed"))
    #expect(mermaid.contains("class root_2 interrupted"))

    // Codex reports no tool failure; a pending step in an interrupted turn is interrupted.
    let codexStore = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: codexStore) }
    let codex = try FlowFixture.record(
      [
        FlowFixture.hook([
          "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "a", "turn_id": "t1",
        ]),
        FlowFixture.hook([
          "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "b", "turn_id": "t2",
        ]),
        FlowFixture.hook(["hook_event_name": "Interrupt", "turn_id": "t2"]),
        FlowFixture.hook([
          "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_use_id": "a",
        ]),
      ], client: "codex", store: codexStore)
    #expect(codex.count == 3)
    #expect(
      FlowFixture.render(codex, .tree).contains(
        "├─ Bash ×2 (1 interrupted, 1 incomplete)\n└─ Interrupt (interrupted)\n"))
  }

  @Test func duplicateAndReorderedEventsRenderIdentically() throws {
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    let lines = try FlowFixture.record(
      try FlowFixture.hookLines("claude-session.jsonl"), client: "claude", store: store)
    // Deliver every line twice, in reverse and in an interleaved order.
    let reordered =
      Array(lines.reversed()) + stride(from: 0, to: lines.count, by: 2).map { lines[$0] }
      + stride(from: 1, to: lines.count, by: 2).map { lines[$0] }
    for format in [FlowRenderFormat.tree, .mermaid] {
      #expect(FlowFixture.render(reordered, format) == FlowFixture.render(lines, format))
    }
  }

  @Test func repeatedDeliveryCollapsesButSeparateEventsInOneTurnStay() throws {
    let stop = FlowFixture.hook(["hook_event_name": "Stop", "prompt_id": "p"])
    // One Stop line delivered twice renders one Stop.
    let onceStore = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: onceStore) }
    let once = try FlowFixture.record([stop], client: "claude", store: onceStore)
    #expect(FlowFixture.render(once + once, .tree).hasSuffix("root\n└─ Stop\n"))

    // Two Stops a second apart, as after a Stop-hook continuation, render two.
    let twiceStore = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: twiceStore) }
    let twice = try FlowFixture.record([stop, stop], client: "claude", store: twiceStore)
    #expect(FlowFixture.render(twice, .tree).hasSuffix("root\n├─ Stop\n└─ Stop\n"))

    // Two compactions in one prompt render two, in their places between the tools.
    let turnStore = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: turnStore) }
    func tool(_ name: String, _ id: String) -> [String] {
      ["PreToolUse", "PostToolUse"].map {
        FlowFixture.hook([
          "hook_event_name": $0, "tool_name": name, "tool_use_id": id, "prompt_id": "p",
        ])
      }
    }
    let compact = ["PreCompact", "PostCompact"].map {
      FlowFixture.hook(["hook_event_name": $0, "trigger": "auto", "prompt_id": "p"])
    }
    let turn = try FlowFixture.record(
      tool("Bash", "1") + compact + tool("Read", "2") + compact + [stop] + tool("Edit", "3")
        + [stop], client: "claude", store: turnStore)
    #expect(
      FlowFixture.render(turn, .tree).hasSuffix(
        "root\n├─ Bash\n├─ Compact (auto)\n├─ Read\n├─ Compact (auto)\n├─ Stop\n├─ Edit\n"
          + "└─ Stop\n"))
    #expect(FlowFixture.render(turn + turn.reversed(), .tree) == FlowFixture.render(turn, .tree))
  }

  @Test func nestedSubagentLinksToItsParentAndUnknownOnesAreUnlinked() throws {
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    let lines = try FlowFixture.record(
      try FlowFixture.hookLines("codex-session.jsonl"), client: "codex", store: store)
    let tree = FlowFixture.render(lines, .tree)
    let rows = tree.split(separator: "\n").map(String.init)
    let child = try #require(rows.firstIndex { $0.contains("│  └─ explorer ") })
    let grandchild = try #require(rows.firstIndex { $0.contains("└─ worker ") })
    #expect(rows[child - 1].hasPrefix("├─ spawn_agent → explorer"))
    #expect(rows[grandchild - 1].contains("└─ spawn_agent → worker"))
    #expect(grandchild > child)
    let mermaid = FlowFixture.render(lines, .mermaid)
    #expect(mermaid.components(separatedBy: " -.-> a_").count == 3)

    let orphanStore = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: orphanStore) }
    let orphan = try FlowFixture.record(
      [
        FlowFixture.hook([
          "hook_event_name": "SubagentStart", "agent_id": "lonely", "agent_type": "Plan",
        ]),
        FlowFixture.hook([
          "hook_event_name": "PreToolUse", "agent_id": "lonely", "agent_type": "Plan",
          "tool_name": "Read", "tool_use_id": "r",
        ]),
      ], client: "claude", store: orphanStore)
    let orphanTree = FlowFixture.render(orphan, .tree)
    #expect(orphanTree.contains("unlinked\n└─ Plan "))
    #expect(orphanTree.hasSuffix(" · incomplete\n   └─ Read (incomplete)\n"))
    #expect(FlowFixture.render(orphan, .mermaid).contains("  subgraph unlinked[\"unlinked\"]"))
  }

  @Test func maxStepsElidesFiveThousandStepsAndSaysWhat() throws {
    let hasher = try #require(FlowHasher(saltHex: FlowFixture.salt))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var lines: [String] = []
    for index in 0..<5_000 {
      for event in ["PreToolUse", "PostToolUse"] {
        let input: [String: Any] = [
          "hook_event_name": event, "session_id": "s", "tool_use_id": "t\(index)",
          "tool_name": index % 2 == 0 ? "Read" : "Bash",
        ]
        let flow = try #require(
          FlowNormalizer.event(
            from: input, client: "claude", hasher: hasher,
            at: FlowFixture.start.addingTimeInterval(Double(index))))
        lines.append(String(decoding: try encoder.encode(flow), as: UTF8.self))
      }
    }
    let tree = FlowFixture.render(lines, .tree, maxSteps: 100)
    #expect(tree.hasPrefix("flow \(hasher.hash("session", "s").prefix(8)) · claude · 5000 steps"))
    #expect(tree.split(separator: "\n").filter { $0.hasPrefix("├─ ") }.count == 100)
    #expect(tree.contains("└─ … 4900 more nodes (4900 steps) elided\n"))
    #expect(
      tree.hasSuffix(
        "note: --max-steps 100 counts step nodes, 4900 more nodes (4900 steps) elided\n"))
    let mermaid = FlowFixture.render(lines, .mermaid, maxSteps: 100)
    #expect(mermaid.contains("root_99[") && !mermaid.contains("root_100["))
    #expect(mermaid.contains("root_more[\"… 4900 more nodes (4900 steps) elided\"]"))
    #expect(
      mermaid.hasSuffix(
        "%% --max-steps 100 counts step nodes, 4900 more nodes (4900 steps) elided\n"))
    // A collapsed run is one node, so the note separates nodes from the steps they held.
    var runs: [String] = []
    for index in 0..<30 {
      let input: [String: Any] = [
        "hook_event_name": "PreToolUse", "session_id": "s", "tool_use_id": "r\(index)",
        "tool_name": index / 3 % 2 == 0 ? "Read" : "Bash",
      ]
      let flow = try #require(
        FlowNormalizer.event(
          from: input, client: "claude", hasher: hasher,
          at: FlowFixture.start.addingTimeInterval(Double(index))))
      runs.append(String(decoding: try encoder.encode(flow), as: UTF8.self))
    }
    let runTree = FlowFixture.render(runs, .tree, maxSteps: 4)
    #expect(runTree.contains("├─ Read ×3 (3 incomplete)\n"))
    #expect(runTree.contains("└─ … 6 more nodes (18 steps) elided\n"))
    #expect(!FlowFixture.render(lines, .tree, maxSteps: 10_000).contains("elided"))
  }

  @Test func consecutiveSameToolStepsCollapse() throws {
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    var inputs: [String] = []
    for index in 0..<12 {
      inputs.append(
        FlowFixture.hook([
          "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "b\(index)",
        ]))
      inputs.append(
        FlowFixture.hook([
          "hook_event_name": index < 2 ? "PostToolUseFailure" : "PostToolUse",
          "tool_name": "Bash", "tool_use_id": "b\(index)",
        ]))
    }
    inputs.append(
      FlowFixture.hook(["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_use_id": "r"]))
    let lines = try FlowFixture.record(inputs, client: "claude", store: store)
    #expect(FlowFixture.render(lines, .tree).contains("├─ Bash ×12 (2 failed)\n└─ Read"))
  }

  @Test func mermaidLabelsAreEscaped() throws {
    let hostile = "x\"]; click root call alert(1)\n%%{init}%% <b>`#&;"
    let escaped = FlowRenderer.escapeMermaid(hostile)
    for character in ["\"", "]", ";", "\n", "%", "<", ">", "`", "&", "{", "["] {
      #expect(
        !escaped.replacingOccurrences(of: #"#\d+;"#, with: "", options: .regularExpression)
          .contains(character))
    }
    #expect(escaped.hasPrefix("x#34;#93;#59; click root call alert(1)#10;#37;#37;#123;"))

    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    let lines = try FlowFixture.record(
      [
        FlowFixture.hook([
          "hook_event_name": "PreToolUse", "tool_name": "mcp__a\"]b__q", "tool_use_id": "1",
          "agent_id": "z", "agent_type": hostile,
        ])
      ], client: "claude", store: store, includeLabels: true)
    let mermaid = FlowFixture.render(lines, .mermaid, includeLabels: true)
    for line in mermaid.split(separator: "\n") where line.contains("[\"") {
      #expect(line.filter { $0 == "\"" }.count == 2, "\(line)")
      #expect(line.hasSuffix("\"]"))
    }
    // The hostile text stays inside its quoted label: no raw markup and no directive line.
    #expect(!mermaid.contains("<b>") && !mermaid.contains("%%{"))
    #expect(
      !mermaid.split(separator: "\n").contains {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("click")
      })
  }

  @Test func ledgerAddsAReadOnlyHarnessLaneInTimeOrder() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let ledgerURL = root.appendingPathComponent("contracts/example-ledger.jsonl")
    let before = try Data(contentsOf: ledgerURL)
    // A shown field holding free text instead of an identifier is dropped, not displayed.
    let ledger =
      try String(contentsOf: ledgerURL, encoding: .utf8).split(separator: "\n").map(String.init)
      + [
        #"{"record_type":"node","recorded_at":"2026-01-01T00:00:11Z","sequence":13,"#
          + #""payload":{"node_id":"/Users/CANARY home/notes","status":"passed"}}"#
      ]
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    let lines = try FlowFixture.record(
      [FlowFixture.hook(["hook_event_name": "Stop"])], client: "claude", store: store)
    // Reverse the records: the lane is ordered by recorded_at, not file order.
    let tree = FlowFixture.render(lines, .tree, ledger: ledger.reversed())
    let harness = try #require(tree.components(separatedBy: "harness\n").last)
    #expect(harness.hasPrefix("├─ node · intake · passed\n├─ node · guard · passed\n"))
    #expect(harness.contains("├─ lease · acquire · github_external_mutation\n"))
    #expect(harness.contains("├─ approval · run_authorization · approved\n"))
    #expect(harness.hasSuffix("├─ stop · blocked\n└─ node · passed\n"))
    // Free text, paths and operation inputs stay out of the lane.
    #expect(!tree.contains("Keep verification") && !tree.contains("example-branch"))
    #expect(!tree.contains("spec.md") && !tree.contains("CANARY"))
    #expect(FlowFixture.render(lines, .mermaid, ledger: ledger).contains("subgraph harness["))
    // Ledger records have their own budget and note; they never displace session steps.
    let limited = FlowFixture.render(lines, .tree, maxSteps: 1, ledger: ledger)
    #expect(limited.contains("root\n└─ Stop\nharness\n├─ node · intake · passed\n"))
    #expect(
      limited.hasSuffix(
        "└─ … 12 more records elided\n"
          + "note: --max-steps 1 counts harness records separately, 12 more records elided\n"))
    #expect(!limited.contains("step nodes"))
    #expect(try Data(contentsOf: ledgerURL) == before)
  }

  @Test func mcpServerNamesNeverLeakThroughAnAmbiguousSplit() throws {
    let hasher = try #require(FlowHasher(saltHex: FlowFixture.salt))
    func name(_ input: [String: Any], _ client: String) throws -> String {
      var input = input
      input["session_id"] = "s"
      input["hook_event_name"] = "PreToolUse"
      return try #require(
        FlowNormalizer.event(from: input, client: client, hasher: hasher, at: FlowFixture.start)
      ).step.name
    }
    // Claude Code names the server, so the split is exact even with `__` inside it.
    #expect(
      try name(
        ["tool_name": "mcp__CANARY__srv__query", "mcp_server": ["name": "CANARY__srv"]], "claude")
        == "mcp:\(hasher.hash("mcp_server", "CANARY__srv"))/query")
    // Without that name, or when it does not prefix the tool name, the tool segment is hashed.
    for (input, client) in [
      (["tool_name": "mcp__CANARY__srv__query"], "codex"),
      (["tool_name": "mcp__CANARY__srv__query"], "claude"),
      (["tool_name": "mcp__CANARY__srv__query", "mcp_server": ["name": "other"]], "claude"),
    ] as [([String: Any], String)] {
      let stored = try name(input, client)
      #expect(
        stored == "mcp:\(hasher.hash("mcp_server", "CANARY"))/#"
          + hasher.hash("mcp_tool", "srv__query"))
      #expect(!stored.contains("srv") && !stored.contains("query"))
    }
    #expect(try name(["tool_name": "mcp__github__search"], "codex").hasSuffix("/search"))
  }

  @Test func labelsDropBidiAndFormatCharacters() throws {
    let tricky = "a\u{202E}b\u{2066}c\u{200B}d\u{2028}e\u{7}f"
    #expect(FlowNormalizer.label(tricky) == "abcdef")
    let store = try FlowFixture.store()
    defer { try? FileManager.default.removeItem(at: store) }
    var lines = try FlowFixture.record(
      [
        FlowFixture.hook([
          "hook_event_name": "PreToolUse", "tool_name": "mcp__x\u{202E}y__q", "tool_use_id": "1",
          "agent_id": "z", "agent_type": "t\u{2067}ype",
        ])
      ], client: "claude", store: store, includeLabels: true)
    // A label written by hand or by an older recorder is cleaned when rendered as well.
    lines.append(
      lines[0].replacingOccurrences(of: "\"label\":\"xy\"", with: "\"label\":\"p\\u202Eq\"")
        .replacingOccurrences(of: #""id":""#, with: #""id":"0"#))
    for format in [FlowRenderFormat.tree, .mermaid] {
      let output = FlowFixture.render(lines, format, includeLabels: true)
      #expect(output.contains("type"))
      for scalar in output.unicodeScalars {
        #expect(scalar.properties.generalCategory != .format, "\(format) U+\(scalar.value)")
      }
      #expect(!output.contains("#8238;") && !output.contains("#8295;"))
    }
  }

  @Test func symlinksInTheStoreAreNeverFollowed() throws {
    let root = try FlowFixture.store(salt: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FileManager.default
    let input = Data(
      FlowFixture.hook(["hook_event_name": "Stop", "session_id": "linked"]).utf8)
    let hasher = try #require(FlowHasher(saltHex: FlowFixture.salt))

    // A session file that is a symlink is not appended to.
    let store = try FlowFixture.store()
    defer { try? manager.removeItem(at: store) }
    let target = root.appendingPathComponent("target.txt")
    try "keep\n".write(to: target, atomically: true, encoding: .utf8)
    try manager.createSymbolicLink(
      at: store.appendingPathComponent(hasher.hash("session", "linked") + ".jsonl"),
      withDestinationURL: target)
    #expect(!FlowStore.record(input: input, client: "claude", store: store.path))
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep\n")

    // A salt that is a symlink, even to a valid salt, is neither read nor replaced.
    let saltStore = try FlowFixture.store(salt: nil)
    defer { try? manager.removeItem(at: saltStore) }
    let saltTarget = root.appendingPathComponent("salt-target")
    try (FlowFixture.salt + "\n").write(to: saltTarget, atomically: true, encoding: .utf8)
    try manager.createSymbolicLink(
      at: saltStore.appendingPathComponent(FlowStore.saltFile), withDestinationURL: saltTarget)
    #expect(!FlowStore.record(input: input, client: "claude", store: saltStore.path))
    #expect(try FlowFixture.sessionFiles(saltStore).isEmpty)
    #expect(try String(contentsOf: saltTarget, encoding: .utf8) == FlowFixture.salt + "\n")
    #expect(
      try manager.destinationOfSymbolicLink(
        atPath: saltStore.appendingPathComponent(FlowStore.saltFile).path) == saltTarget.path)

    // A store that is itself a symlink to a directory is refused.
    let real = root.appendingPathComponent("real")
    try manager.createDirectory(at: real, withIntermediateDirectories: false)
    let linkedStore = root.appendingPathComponent("linked-store")
    try manager.createSymbolicLink(at: linkedStore, withDestinationURL: real)
    for path in [linkedStore.path, linkedStore.path + "/", linkedStore.path + "//"] {
      #expect(!FlowStore.record(input: input, client: "claude", store: path))
    }
    #expect(try manager.contentsOfDirectory(atPath: real.path).isEmpty)
  }

  @Test func storeCreationMakesOnlyTheFinalDirectory() throws {
    let root = try FlowFixture.store(salt: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = Data(FlowFixture.hook(["hook_event_name": "Stop"]).utf8)
    for path in ["s7/../s8", "./s9", "missing/store"] {
      #expect(
        !FlowStore.record(
          input: input, client: "claude", store: root.path + "/" + path))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let store = root.appendingPathComponent("store")
    #expect(FlowStore.record(input: input, client: "claude", store: store.path))
    let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o700)
  }

  @Test func concurrentRecordersAppendWholeLinesAndShareOneSalt() throws {
    let store = try FlowFixture.store(salt: nil)
    defer { try? FileManager.default.removeItem(at: store) }
    DispatchQueue.concurrentPerform(iterations: 64) { index in
      FlowStore.record(
        input: Data(
          FlowFixture.hook([
            "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "c\(index)",
          ]).utf8), client: "codex", store: store.path)
    }
    let lines = try FlowFixture.sessionLines(store)
    #expect(lines.count == 64)
    let decoder = JSONDecoder()
    #expect(lines.allSatisfy { (try? decoder.decode(FlowEvent.self, from: Data($0.utf8))) != nil })
    // Racing recorders published one salt and left no temporary salt file behind.
    let entries = try FileManager.default.contentsOfDirectory(atPath: store.path)
    #expect(Set(entries.filter { !$0.hasSuffix(".jsonl") }) == [FlowStore.saltFile])
  }

  // MARK: - The hook command

  private var executable: URL {
    Bundle(for: FlowBundleLocator.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("apple-verify").resolvingSymlinksInPath()
  }

  private func runRecorder(_ arguments: [String], stdin: Data) throws -> (Int32, Data, Data) {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["flow", "record"] + arguments
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    input.fileHandleForWriting.write(stdin)
    try input.fileHandleForWriting.close()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, stdout, stderr)
  }

  @Test func recorderExitsZeroSilentlyAndRecordsNothingForBadInput() throws {
    let parent = try FlowFixture.store(salt: nil)
    defer { try? FileManager.default.removeItem(at: parent) }
    let store = parent.appendingPathComponent("store")
    let valid = FlowFixture.hook(["hook_event_name": "PreToolUse", "tool_name": "Bash"])
    let cases: [([String], String)] = [
      (["--client", "claude", "--store", store.path], ""),
      (["--client", "claude", "--store", store.path], "not json {"),
      (["--client", "claude", "--store", store.path], "[1, 2]"),
      (["--client", "claude", "--store", store.path], #"{"hook_event_name":"PreToolUse"}"#),
      (
        ["--client", "claude", "--store", store.path],
        FlowFixture.hook(["hook_event_name": "Notification", "message": "CANARY"])
      ),
      (
        ["--client", "claude", "--store", store.path],
        FlowFixture.hook(["hook_event_name": "Interrupt", "turn_id": "t"])
      ),
      (["--client", "other", "--store", store.path], valid),
      (["--client", "claude", "--store", "relative/store"], valid),
      (["--client", "claude"], valid),
      (["--client", "claude", "--store", store.path, "--unknown", "x"], valid),
    ]
    for (arguments, input) in cases {
      let (status, stdout, stderr) = try runRecorder(arguments, stdin: Data(input.utf8))
      #expect(status == 0, "\(arguments) \(input)")
      #expect(stdout.isEmpty && stderr.isEmpty, "\(arguments) \(input)")
      #expect(!FileManager.default.fileExists(atPath: store.path), "\(arguments) \(input)")
    }

    let (status, stdout, _) = try runRecorder(
      ["--client", "claude", "--store", store.path], stdin: Data(valid.utf8))
    #expect(status == 0 && stdout.isEmpty)
    let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o700)
    #expect(try FlowFixture.sessionLines(store).count == 1)
  }
}
