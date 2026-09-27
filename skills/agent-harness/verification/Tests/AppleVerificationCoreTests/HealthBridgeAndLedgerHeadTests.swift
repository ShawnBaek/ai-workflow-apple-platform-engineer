import XCTest

@testable import AppleVerificationCore

/// The `mcp.xcode` health check reads client registrations for the app root without starting a
/// bridge unless asked to, `initialize-run` leaves a ledger head so a missing head always fails
/// closed, and a schema `.` and the `..`-segment path lookaheads follow ECMA-262 line terminators.
final class HealthBridgeAndLedgerHeadTests: XCTestCase {
  private let context = GateRunSupport.context

  // MARK: - Xcode MCP health check

  /// Records the working directory of every probe and answers only the exact expected command.
  private final class RecordingRunner: HealthProbeRunning {
    private var steps: [(executable: String, arguments: [String], stdout: String)]
    private(set) var directories: [URL?] = []
    init(_ steps: [(executable: String, arguments: [String], stdout: String)]) {
      self.steps = steps
    }
    func run(
      executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
      timeout: TimeInterval, maxOutputBytes: Int
    ) -> ProcessResult {
      guard let step = steps.first, step.executable == executable, step.arguments == arguments
      else {
        XCTFail("unexpected probe: \(([executable] + arguments).joined(separator: " "))")
        return .init(stdout: "", stderr: "", exitCode: 64, timedOut: false, truncated: false)
      }
      steps.removeFirst()
      directories.append(directory)
      return .init(stdout: step.stdout, stderr: "", exitCode: 0, timedOut: false, truncated: false)
    }
  }

  private final class CountingBridge: HealthMCPProbing {
    private(set) var xcodeCalls = 0
    func probeXcode(timeout: TimeInterval) -> HealthMCPProbeResult {
      xcodeCalls += 1
      return .init(passed: true, material: ["fixture": "bridge"])
    }
    func probeAppleSampleCode(endpoint: URL, timeout: TimeInterval) -> HealthMCPProbeResult {
      .init(passed: true, material: ["fixture": "apple"])
    }
  }

  private func harness(appRoot: URL, client: String) -> [String: Any] {
    [
      "authoritative_root": appRoot.path,
      "agent_skills": [
        "installations": [
          "codex": client == "codex" ? ["collection_root": "/fixture"] as Any : NSNull(),
          "claude": client == "claude" ? ["collection_root": "/fixture"] as Any : NSNull(),
        ]
      ],
    ]
  }

  private let xcodeEntry: [String: Any] = [
    "type": "stdio", "command": "xcrun", "args": ["mcpbridge"],
  ]
  /// The shape `codex mcp get --json` prints (codex-rs/cli/src/mcp_cmd.rs `run_get`).
  private let codexXcode =
    #"{"name":"xcode","enabled":true,"transport":{"type":"stdio","command":"xcrun","args":["mcpbridge"]}}"#

  private func claudeStatus(home: URL, appRoot: URL, configDirectory: URL? = nil) -> String? {
    // Any `claude` invocation fails the runner: `claude mcp get` health-checks the server.
    HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["mcp.xcode"]],
      harness: harness(appRoot: appRoot, client: "claude"), policy: [:], authorization: nil,
      runner: RecordingRunner([]), mcpProbe: CountingBridge(),
      environment: ["HOME": home.path].merging(
        configDirectory.map { ["CLAUDE_CONFIG_DIR": $0.path] } ?? [:]
      ) { $1 }
    )["mcp.xcode"]?["status"] as? String
  }

  func testXcodeCheckReadsCodexForTheAppRootWithoutStartingABridge() throws {
    let appRoot = try GateRunSupport.temporaryDirectory(for: self)
    let runner = RecordingRunner([
      ("codex", ["mcp", "get", "xcode", "--json"], codexXcode)
    ])
    let bridge = CountingBridge()
    let observations = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["mcp.xcode"]],
      harness: harness(appRoot: appRoot, client: "codex"),
      policy: [:], authorization: nil, runner: runner, mcpProbe: bridge, environment: [:])
    XCTAssertEqual(observations["mcp.xcode"]?["status"] as? String, "healthy")
    XCTAssertEqual(bridge.xcodeCalls, 0, "a default health check must not start xcrun mcpbridge")
    // Codex resolves a trusted project's .codex/config.toml from its working directory.
    XCTAssertEqual(runner.directories.map { $0?.path }, [appRoot.path])
  }

  func testLiveBridgeProbeRunsOnlyOnExplicitOptIn() throws {
    let appRoot = try GateRunSupport.temporaryDirectory(for: self)
    let bridge = CountingBridge()
    let observations = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["mcp.xcode"]],
      harness: harness(appRoot: appRoot, client: "codex"), policy: [:], authorization: nil,
      runner: RecordingRunner([
        ("codex", ["mcp", "get", "xcode", "--json"], codexXcode)
      ]), mcpProbe: bridge, liveXcodeBridgeProbe: true, environment: [:])
    XCTAssertEqual(observations["mcp.xcode"]?["status"] as? String, "healthy")
    XCTAssertEqual(
      observations["mcp.xcode"]?["reason_code"] as? String, "registration_and_read_only_tools")
    XCTAssertEqual(bridge.xcodeCalls, 1)
  }

  func testClaudeRegistrationIsReadFromConfigFilesForTheAppRoot() throws {
    let home = try GateRunSupport.temporaryDirectory(for: self)
    let appRoot = try GateRunSupport.temporaryDirectory(for: self)
    let other = try GateRunSupport.temporaryDirectory(for: self)
    let config = home.appendingPathComponent(".claude.json")
    func status() -> String? { claudeStatus(home: home, appRoot: appRoot) }

    // A local-scope entry for another repository does not register the server for this app.
    try HarnessRuntime.atomicWriteJSON(
      ["projects": [other.path: ["mcpServers": ["xcode": xcodeEntry]]]], to: config)
    XCTAssertEqual(status(), "blocked")

    // The app's own .mcp.json counts wherever the evaluator was launched from.
    try HarnessRuntime.atomicWriteJSON(
      ["mcpServers": ["xcode": xcodeEntry]], to: appRoot.appendingPathComponent(".mcp.json"))
    XCTAssertEqual(status(), "healthy")

    // ...unless the developer disabled that project server for this app.
    try HarnessRuntime.atomicWriteJSON(
      ["projects": [appRoot.path: ["disabledMcpjsonServers": ["xcode"]]]], to: config)
    XCTAssertEqual(status(), "blocked")

    // A local-scope entry for this app root registers it, and a drifted one does not.
    try FileManager.default.removeItem(at: appRoot.appendingPathComponent(".mcp.json"))
    try HarnessRuntime.atomicWriteJSON(
      ["projects": [appRoot.path: ["mcpServers": ["xcode": xcodeEntry]]]], to: config)
    XCTAssertEqual(status(), "healthy")
    try HarnessRuntime.atomicWriteJSON(
      ["projects": [appRoot.path: ["mcpServers": ["xcode": ["command": "other"]]]]], to: config)
    XCTAssertEqual(status(), "blocked")
  }

  func testDisabledClaudeServersInAnySettingsFileFailClosed() throws {
    let home = try GateRunSupport.temporaryDirectory(for: self)
    let appRoot = try GateRunSupport.temporaryDirectory(for: self)
    let config = home.appendingPathComponent(".claude.json")
    let projectServers = appRoot.appendingPathComponent(".mcp.json")
    try HarnessRuntime.atomicWriteJSON(["mcpServers": ["xcode": xcodeEntry]], to: projectServers)
    XCTAssertEqual(claudeStatus(home: home, appRoot: appRoot), "healthy")

    // `disabledMcpjsonServers` is a settings key: user, project and local settings each reject
    // the project server.
    for settings in [
      home.appendingPathComponent(".claude/settings.json"),
      appRoot.appendingPathComponent(".claude/settings.json"),
      appRoot.appendingPathComponent(".claude/settings.local.json"),
    ] {
      try FileManager.default.createDirectory(
        at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
      try HarnessRuntime.atomicWriteJSON(["disabledMcpjsonServers": ["xcode"]], to: settings)
      XCTAssertEqual(claudeStatus(home: home, appRoot: appRoot), "blocked", settings.path)
      try FileManager.default.removeItem(at: settings)
      XCTAssertEqual(claudeStatus(home: home, appRoot: appRoot), "healthy", settings.path)
    }
    try FileManager.default.removeItem(at: projectServers)

    // The `/mcp` toggle records `disabledMcpServers` for this app; it disables a local or a user
    // entry.
    for global in [
      ["projects": [appRoot.path: ["mcpServers": ["xcode": xcodeEntry]]]],
      ["mcpServers": ["xcode": xcodeEntry], "projects": [appRoot.path: [String: Any]()]],
    ] as [[String: Any]] {
      try HarnessRuntime.atomicWriteJSON(global, to: config)
      XCTAssertEqual(claudeStatus(home: home, appRoot: appRoot), "healthy")
      var disabled = global
      var projects = disabled["projects"] as! [String: Any]
      var project = projects[appRoot.path] as! [String: Any]
      project["disabledMcpServers"] = ["xcode"]
      projects[appRoot.path] = project
      disabled["projects"] = projects
      try HarnessRuntime.atomicWriteJSON(disabled, to: config)
      XCTAssertEqual(claudeStatus(home: home, appRoot: appRoot), "blocked")
    }
  }

  func testToggleDisablesAProjectEntryAndARejectedOneFallsThroughToUserScope() throws {
    let home = try GateRunSupport.temporaryDirectory(for: self)
    let appRoot = try GateRunSupport.temporaryDirectory(for: self)
    let config = home.appendingPathComponent(".claude.json")
    try HarnessRuntime.atomicWriteJSON(
      ["mcpServers": ["xcode": xcodeEntry]], to: appRoot.appendingPathComponent(".mcp.json"))

    // The `/mcp` toggle names a server per project, whatever its scope.
    try HarnessRuntime.atomicWriteJSON(
      ["projects": [appRoot.path: ["disabledMcpServers": ["xcode"]]]], to: config)
    XCTAssertEqual(claudeStatus(home: home, appRoot: appRoot), "blocked")

    // A project entry rejected by settings leaves a same-named user entry in effect.
    let local = appRoot.appendingPathComponent(".claude/settings.local.json")
    try FileManager.default.createDirectory(
      at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try HarnessRuntime.atomicWriteJSON(["disabledMcpjsonServers": ["xcode"]], to: local)
    try HarnessRuntime.atomicWriteJSON(["mcpServers": ["xcode": xcodeEntry]], to: config)
    XCTAssertEqual(claudeStatus(home: home, appRoot: appRoot), "healthy")

    // With CLAUDE_CONFIG_DIR set, the home directory's `.claude.json` is not the client's.
    let custom = try GateRunSupport.temporaryDirectory(for: self)
    XCTAssertEqual(
      claudeStatus(home: home, appRoot: appRoot, configDirectory: custom), "blocked")
  }

  func testCodexServerMustBeEnabled() throws {
    let appRoot = try GateRunSupport.temporaryDirectory(for: self)
    for (output, expected) in [
      (codexXcode, "healthy"),
      (
        codexXcode.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#),
        "blocked"
      ),
      (codexXcode.replacingOccurrences(of: #""enabled":true,"#, with: ""), "blocked"),
    ] {
      let observations = HealthEvaluation.collectLiveObservations(
        report: ["required_check_ids": ["mcp.xcode"]],
        harness: harness(appRoot: appRoot, client: "codex"), policy: [:], authorization: nil,
        runner: RecordingRunner([("codex", ["mcp", "get", "xcode", "--json"], output)]),
        mcpProbe: CountingBridge(), environment: [:])
      XCTAssertEqual(observations["mcp.xcode"]?["status"] as? String, expected, output)
    }
  }

  func testBridgeProbeFlagIsSingleAndNotForSkillObservation() {
    let missing = "/nonexistent/\(UUID().uuidString)/harness.json"
    func message(_ arguments: [String]) -> String? {
      do {
        _ = try HealthEvaluation.run(arguments: arguments, context: context)
        return nil
      } catch { return String(describing: error) }
    }
    XCTAssertEqual(
      message([
        "report.json", "--harness", missing, "--probe-xcode-mcp-bridge",
        "--probe-xcode-mcp-bridge",
      ]), "duplicate --probe-xcode-mcp-bridge")
    // Refused before the harness is read, so the combination never reaches an observation.
    XCTAssertEqual(
      message(["--harness", missing, "--observe-agent-skills", "--probe-xcode-mcp-bridge"]),
      "--observe-agent-skills does not accept a report or --probe-xcode-mcp-bridge")
  }

  // MARK: - Ledger head written by initialize-run

  private var executable: URL {
    Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("apple-verify").resolvingSymlinksInPath()
  }

  private func initializeRun(root: URL, base: URL, state: URL) throws -> (
    code: Int32, response: [String: Any]
  ) {
    let result = try HarnessRuntime.run(
      executable: executable.path,
      arguments: [
        "--repository-root", GateRunSupport.repositoryRoot.path, "initialize-run",
        "--authorization", root.appendingPathComponent("authorization.json").path,
        "--ledger", root.appendingPathComponent("ledger.jsonl").path, "--run-root", root.path,
        "--harness", root.appendingPathComponent("harness.json").path,
        "--coordinator-state", state.path,
      ], timeout: 30)
    let response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
      result.stdout + result.stderr)
    return (result.exitCode, response)
  }

  func testInitializeRunWritesTheLedgerHeadAndAMissingHeadFailsClosed() throws {
    let base = try GateRunSupport.temporaryDirectory(for: self)
    let root = base.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let state = base.appendingPathComponent("coordinator.json")
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    let authorization = root.appendingPathComponent("authorization.json")
    let ledger = root.appendingPathComponent("ledger.jsonl")
    try HarnessRuntime.atomicWriteJSON(
      approvalWindow(of: try GateRunSupport.approvedEnvelope(), containing: Date()),
      to: authorization)
    var document = try HarnessRuntime.object(
      context.harnessRoot.appendingPathComponent("templates/harness-local.json"))
    document["authoritative_root"] = base.path
    document["private_policy_overlay"] = root.appendingPathComponent("policy.json").path
    document["run_authorization"] = authorization.path
    document["run_ledger"] = ledger.path
    document["resource_coordinator"] = [
      "runtime_kind": "swift", "runtime_contract": ResourceCoordinator.runtimeContract,
      "state_path": state.path, "coordinator_instance_id": boot["coordinator_instance_id"]!,
      "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
      "source_bundle_sha256": try ResourceCoordinator.sourceBundleSHA256(
        skillRoot: context.harnessRoot),
    ]
    try HarnessRuntime.atomicWriteJSON(document, to: root.appendingPathComponent("harness.json"))

    let created = try initializeRun(root: root, base: base, state: state)
    XCTAssertEqual(created.code, 0, "\(created.response)")
    let head = URL(fileURLWithPath: ledger.path + ".head.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: head.path))
    let binding = try ResourceCoordinator.ledgerBinding(ledger)
    let data = try Data(contentsOf: ledger)
    XCTAssertEqual(
      Authorization.ledgerHeadErrors(data, ledgerPath: ledger, runRoot: root, binding: binding), [])
    let adopted = try initializeRun(root: root, base: base, state: state)
    XCTAssertEqual(adopted.response["created"] as? Bool, false, "\(adopted.response)")

    // Only the approval record exists, yet a removed head still blocks the run.
    try FileManager.default.removeItem(at: head)
    XCTAssertEqual(
      Authorization.ledgerHeadErrors(data, ledgerPath: ledger, runRoot: root, binding: binding),
      ["coordination_required: ledger head checkpoint is missing or unreadable"])
    let rerun = try initializeRun(root: root, base: base, state: state)
    XCTAssertEqual(rerun.code, 2, "\(rerun.response)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: head.path))
  }

  // MARK: - ECMA-262 `.` and `..`-segment lookaheads

  private func accepts(_ pattern: String, _ value: String) -> Bool {
    JSONSchemaValidator.errors(instance: value, schema: ["pattern": pattern]).isEmpty
  }

  func testDotExcludesOnlyECMA262LineTerminators() {
    // ECMA-262 LineTerminator is LF, CR, U+2028 and U+2029; ICU also stops at U+0085, VT and FF.
    for accepted in ["\u{85}", "\u{0B}", "\u{0C}", "x"] {
      XCTAssertTrue(accepts("^a.b$", "a\(accepted)b"), accepted.debugDescription)
    }
    for refused in ["\n", "\r", "\u{2028}", "\u{2029}", "\r\n"] {
      XCTAssertFalse(accepts("^a.b$", "a\(refused)b"), refused.debugDescription)
    }
    // An escaped dot and a dot in a character class stay literal.
    XCTAssertFalse(accepts(#"^a\.b$"#, "axb"))
    XCTAssertFalse(accepts("^a[.]b$", "axb"))
    XCTAssertTrue(accepts("^a[.]b$", "a.b"))
  }

  func testDotDotSegmentLookaheadsRejectLineSeparatorTricks() throws {
    var patterns: [String] = []
    for schema in [
      "skills/agent-harness/contracts/schemas/project-registry.schema.json",
      "skills/apple-development-health/contracts/health-report.schema.json",
    ] {
      func collect(_ value: Any) {
        if let object = value as? [String: Any] {
          if let pattern = object["pattern"] as? String, pattern.contains(#"\.\.(?:/|$)"#) {
            patterns.append(pattern)
          }
          object.values.forEach(collect)
        } else if let array = value as? [Any] {
          array.forEach(collect)
        }
      }
      collect(
        try HarnessRuntime.object(GateRunSupport.repositoryRoot.appendingPathComponent(schema)))
    }
    XCTAssertEqual(patterns.count, 4)
    for pattern in patterns {
      let absolute = pattern.contains("(?!/)") ? "" : "/"
      let clean = absolute + "App/App.xcodeproj"
      XCTAssertTrue(accepts(pattern, clean), pattern)
      XCTAssertFalse(accepts(pattern, absolute + "App/../App.xcodeproj"), pattern)
      for separator in ["\u{85}", "\u{2028}", "\u{2029}"] {
        XCTAssertTrue(
          accepts(pattern, absolute + "App\(separator)/App.xcodeproj"), pattern)
        XCTAssertFalse(
          accepts(pattern, absolute + "App\(separator)/../App.xcodeproj"),
          "\(pattern) \(separator.debugDescription)")
      }
    }
    // The evaluator's own copy of the container pattern closes the same gap.
    func container(_ value: String) -> Bool {
      HealthEvaluation.xcodeContainer.firstMatch(
        in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
    XCTAssertTrue(container("App/App.xcodeproj"))
    for separator in ["\u{85}", "\u{2028}", "\u{2029}"] {
      XCTAssertFalse(container("App\(separator)/../App.xcodeproj"))
    }
  }
}
