import XCTest

@testable import AppleVerificationCore

final class HealthAndContractTests: XCTestCase {
  func testInstalledSkillBundleDetectsByteDriftShadowAndBrokenSymlink() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a")
    let b = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(
      at: a.appendingPathComponent("demo"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: b.appendingPathComponent("demo"), withIntermediateDirectories: true)
    try Data("---\nname: demo\n---\n".utf8).write(to: a.appendingPathComponent("demo/SKILL.md"))
    try Data("---\nname: demo\n---\n".utf8).write(to: b.appendingPathComponent("demo/SKILL.md"))
    let first = try HealthCollection.installedSkillManifest(
      searchRoots: [a], requiredSkills: ["demo"], client: "codex")
    try Data("changed".utf8).write(to: a.appendingPathComponent("demo/extra.txt"))
    let second = try HealthCollection.installedSkillManifest(
      searchRoots: [a], requiredSkills: ["demo"], client: "codex")
    XCTAssertNotEqual(first["bundle_sha256"] as? String, second["bundle_sha256"] as? String)
    XCTAssertThrowsError(
      try HealthCollection.installedSkillManifest(
        searchRoots: [a, b], requiredSkills: ["demo"], client: "codex"))
    let broken = root.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: broken.appendingPathComponent("demo").path, withDestinationPath: "/missing")
    XCTAssertThrowsError(
      try HealthCollection.installedSkillManifest(
        searchRoots: [broken], requiredSkills: ["demo"], client: "codex"))
  }
  private final class FakeRunner: HealthProbeRunning {
    var results: [ProcessResult]
    private(set) var invocations: [(String, [String])] = []
    init(_ results: [ProcessResult]) { self.results = results }
    func run(
      executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
      timeout: TimeInterval, maxOutputBytes: Int
    ) -> ProcessResult {
      invocations.append((executable, arguments))
      return results.removeFirst()
    }
  }

  private final class FakeCoordinator: RuntimeRegistryCoordinating {
    private(set) var admissions = 0
    func withRuntimeRegistryAdmission<T>(
      scope: RuntimeProbeScope, body: ([String: Any]) throws -> T
    ) throws -> T {
      admissions += 1
      XCTAssertTrue(scope.isWellFormed)
      return try body(["lease_id": "fixture-lease", "resource": "coresimulator_runtime_registry"])
    }
  }

  private final class FakeMCPProbe: HealthMCPProbing {
    var xcode: HealthMCPProbeResult
    var apple: HealthMCPProbeResult
    private(set) var xcodeCalls = 0
    private(set) var appleCalls = 0
    init(xcode: Bool = true, apple: Bool = true) {
      self.xcode = .init(passed: xcode, material: ["fixture": "xcode"])
      self.apple = .init(passed: apple, material: ["fixture": "apple"])
    }
    func probeXcode(timeout: TimeInterval) -> HealthMCPProbeResult {
      xcodeCalls += 1
      return xcode
    }
    func probeAppleSampleCode(endpoint: URL, timeout: TimeInterval) -> HealthMCPProbeResult {
      appleCalls += 1
      XCTAssertEqual(endpoint.absoluteString, "https://mcp.applesamplecode.com/mcp")
      return apple
    }
  }

  private func runtimeScope() -> RuntimeProbeScope {
    RuntimeProbeScope(
      statePath: URL(fileURLWithPath: "/fixture/coordinator.json"),
      descriptor: [
        "coordinator_instance_id": "fixture-coordinator", "registry_scope": "runtime_inventory",
        "platform": "iOS", "destination_id": "DEVICE-1",
        "runtime_identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
      ],
      ownerRunID: "run-1", ownerActor: "writer", runAuthority: ["approval_id": "approval-1"]
    )
  }

  func testMalformedOrUnrelatedRuntimeCannotPassSelectedScope() {
    let coordinator = FakeCoordinator()
    let report: [String: Any] = ["required_check_ids": ["simulator.runtime"]]
    let malformed = FakeRunner([
      .init(stdout: "{}", stderr: "", exitCode: 0, timedOut: false, truncated: false)
    ])
    let first = HealthEvaluation.collectLiveObservations(
      report: report, harness: [:], policy: [:], authorization: nil, runner: malformed,
      runtimeCoordinator: coordinator, runtimeScope: runtimeScope())
    XCTAssertEqual(first["simulator.runtime"]?["status"] as? String, "blocked")
    let unrelated = FakeRunner([
      .init(
        stdout:
          #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-18-0","platform":"tvOS","isAvailable":true}]}"#,
        stderr: "", exitCode: 0, timedOut: false, truncated: false)
    ])
    let second = HealthEvaluation.collectLiveObservations(
      report: report, harness: [:], policy: [:], authorization: nil, runner: unrelated,
      runtimeCoordinator: coordinator, runtimeScope: runtimeScope())
    XCTAssertEqual(second["simulator.runtime"]?["status"] as? String, "blocked")
    let truncated = FakeRunner([
      .init(
        stdout:
          #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","platform":"iOS","isAvailable":true}]}"#,
        stderr: "", exitCode: 0, timedOut: false, truncated: true)
    ])
    let third = HealthEvaluation.collectLiveObservations(
      report: report, harness: [:], policy: [:], authorization: nil, runner: truncated,
      runtimeCoordinator: coordinator, runtimeScope: runtimeScope())
    XCTAssertEqual(third["simulator.runtime"]?["status"] as? String, "blocked")
    XCTAssertEqual(
      coordinator.admissions, 3, "the probe must occur only inside coordinator admission")
  }

  func testExactRuntimeRequiresCoordinatorAndThenPasses() {
    let json =
      #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","platform":"iOS","isAvailable":true}]}"#
    let runner = FakeRunner([
      .init(stdout: json, stderr: "", exitCode: 0, timedOut: false, truncated: false)
    ])
    let report: [String: Any] = ["required_check_ids": ["simulator.runtime"]]
    let blocked = HealthEvaluation.collectLiveObservations(
      report: report, harness: [:], policy: [:], authorization: nil, runner: runner,
      runtimeCoordinator: nil, runtimeScope: runtimeScope())
    XCTAssertEqual(blocked["simulator.runtime"]?["status"] as? String, "blocked")
    XCTAssertTrue(runner.invocations.isEmpty, "unowned runtime inventory must not start")
    let devices =
      #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"DEVICE-1","isAvailable":true}]}}"#
    let successRunner = FakeRunner([
      .init(stdout: json, stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: devices, stderr: "", exitCode: 0, timedOut: false, truncated: false),
    ])
    let success = HealthEvaluation.collectLiveObservations(
      report: report, harness: [:], policy: [:], authorization: nil, runner: successRunner,
      runtimeCoordinator: FakeCoordinator(), runtimeScope: runtimeScope())
    XCTAssertEqual(success["simulator.runtime"]?["status"] as? String, "healthy")
    let wrongDevice =
      #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"OTHER","isAvailable":true}]}}"#
    let mismatchRunner = FakeRunner([
      .init(stdout: json, stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: wrongDevice, stderr: "", exitCode: 0, timedOut: false, truncated: false),
    ])
    let mismatch = HealthEvaluation.collectLiveObservations(
      report: report, harness: [:], policy: [:], authorization: nil, runner: mismatchRunner,
      runtimeCoordinator: FakeCoordinator(), runtimeScope: runtimeScope())
    XCTAssertEqual(mismatch["simulator.runtime"]?["status"] as? String, "blocked")
  }

  func testEvaluatorRejectsCallerClaimAndRedactsSecrets() {
    let now = Date()
    let report = baseReport(
      now: now, githubStatus: "healthy", evidence: ["Bearer super-secret-token"])
    let result = HealthEvaluation.evaluate(report, now: now)
    XCTAssertTrue(result.errors.contains(where: { $0.contains("live observation") }))
    let rendered = String(
      data: try! JSONSerialization.data(withJSONObject: result.report), encoding: .utf8)!
    XCTAssertFalse(rendered.contains("super-secret-token"))
    var malformed = report
    var checks = malformed["checks"] as! [[String: Any]]
    checks[0]["category"] = "invented"
    malformed["checks"] = checks
    XCTAssertTrue(
      HealthEvaluation.evaluate(malformed, now: now).errors.contains(where: {
        $0.contains("malformed")
      }))
  }

  func testMalformedAuthoritativeTargetsFailClosedWithoutTrap() {
    let now = Date()
    let report: [String: Any] = [
      "schema_version": "1.0.0", "profile": "local_verified",
      "observed_at": HarnessRuntime.timestamp(now), "selected_components": [],
      "required_check_ids": [
        "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      ], "checks": [],
    ]
    let result = HealthEvaluation.evaluate(report, now: now)
    XCTAssertTrue(result.errors.contains("health report requires authoritative targets"))
    XCTAssertEqual(result.report["overall_status"] as? String, "blocked")
  }

  func testProjectRegistryResolutionCannotClaimHealthyWithMalformedIdentity() {
    let now = Date()
    var report = baseReport(now: now, githubStatus: "healthy", evidence: ["x"])
    report["profile"] = "local_verified"
    report["selected_components"] = ["project_registry"]
    report["required_check_ids"] = [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      "repository.project_registry",
    ]
    var checks = (report["checks"] as! [[String: Any]]).filter {
      $0["id"] as? String != "github.issue_pr"
    }
    checks.append([
      "id": "repository.project_registry", "category": "repository", "required": true,
      "status": "healthy", "summary": "fixture", "evidence": ["x"],
    ])
    report["checks"] = checks
    report["project_registry_resolution"] = [
      "status": "resolved", "reason_code": "registry_candidate", "resolver_version": "1.0.0",
      "registry_sha256": "sha256:" + String(repeating: "a", count: 64), "worktree_authorized": true,
      "candidate": [
        "project_id": "project", "checkout_id": "checkout", "canonical_root": "relative/path",
        "remote_fingerprint": "sha256:" + String(repeating: "b", count: 64), "kind": "primary",
        "xcode_containers": [],
      ], "warnings": [],
    ]
    let result = HealthEvaluation.evaluate(report, now: now)
    XCTAssertTrue(result.errors.contains("project registry candidate root is invalid"))
    XCTAssertEqual(result.report["overall_status"] as? String, "blocked")
  }

  func testCoordinatorObservationRejectsBooleanLeaseCount() {
    let now = Date()
    var report = baseReport(now: now, githubStatus: "blocked", evidence: ["x"])
    var observation = report["resource_coordinator_observation"] as! [String: Any]
    observation["active_lease_count"] = true
    report["resource_coordinator_observation"] = observation
    XCTAssertTrue(
      HealthEvaluation.evaluate(report, now: now).errors.contains(
        "resource coordinator observation is invalid"))
  }

  func testSkillDigestExcludesGeneratedSwiftState() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".build/cache"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".swiftpm/config"), withIntermediateDirectories: true)
    try Data("---\nname: demo\n---\n".utf8).write(to: root.appendingPathComponent("SKILL.md"))
    let first = try HealthCollection.skillSHA256(root)
    try Data("generated churn".utf8).write(to: root.appendingPathComponent(".build/cache/object"))
    try Data("more churn".utf8).write(to: root.appendingPathComponent(".swiftpm/config/state"))
    XCTAssertEqual(first, try HealthCollection.skillSHA256(root))
  }

  func testSkillManifestBootstrapDiscoversObservedHashButHealthRejectsPlaceholderAndDrift() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let required = ["agent-harness", "apple-development-health", "git-workflow", "github-projects"]
    for name in required {
      let directory = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("---\nname: \(name)\n---\n".utf8).write(
        to: directory.appendingPathComponent("SKILL.md"))
    }
    let placeholder = "sha256:" + String(repeating: "0", count: 64)
    let harness: [String: Any] = [
      "health_profile": "local_verified", "health_components": [] as [String], "mode": "codex",
      "agent_skills": [
        "task_skills": [] as [String], "expected_bundle_sha256": placeholder,
        "installations": ["codex": ["collection_root": root.path], "claude": NSNull()],
      ],
    ]
    let discovered = try HealthCollection.observeAgentSkills(
      harness: harness, enforceExpected: false)
    let first = discovered["expected_bundle_sha256"] as? String
    XCTAssertNotEqual(first, placeholder)
    XCTAssertEqual(
      first, ((discovered["clients"] as? [[String: Any]])?.first)?["bundle_sha256"] as? String)
    XCTAssertThrowsError(
      try HealthCollection.observeAgentSkills(harness: harness),
      "ordinary health must reject the unreviewed placeholder")
    try Data("drift\n".utf8).write(to: root.appendingPathComponent("agent-harness/new-source.txt"))
    let changed = try HealthCollection.observeAgentSkills(harness: harness, enforceExpected: false)
    XCTAssertNotEqual(changed["expected_bundle_sha256"] as? String, first)
    XCTAssertThrowsError(
      try HealthCollection.observeAgentSkills(harness: harness),
      "ordinary health must reject post-bootstrap drift")
  }

  func testRevalidationBindsExactInputBytesBeforeAnyProbe() {
    let bytes = Data("{}".utf8)
    let runner = FakeRunner([])
    let result = HealthEvaluation.revalidate(
      reportBytes: bytes, expectedBytesSHA256: "sha256:" + String(repeating: "0", count: 64),
      harness: [:], policy: [:], authorization: nil, runner: runner)
    XCTAssertEqual(result.errors, ["health report bytes drifted before evaluator read"])
    XCTAssertTrue(runner.invocations.isEmpty)
  }

  func testLocalProfilesDoNotRequireGitHub() {
    XCTAssertEqual(
      HealthEvaluation.profileRequirements["local_verified"],
      ["repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git"])
    XCTAssertFalse(HealthEvaluation.profileRequirements["runtime_ui"]!.contains("github.issue_pr"))
    XCTAssertTrue(HealthEvaluation.profileRequirements["pr_ready"]!.contains("github.issue_pr"))
    XCTAssertTrue(
      HealthEvaluation.profileRequirements["testflight_uploaded"]!.contains("github.issue_pr"))
    let localPolicy: [String: Any] = [
      "schema_version": "1.0.0", "decision": "approved", "github": NSNull(), "apple": NSNull(),
    ]
    XCTAssertEqual(
      HealthCollection.trustedPolicyErrors(
        policy: localPolicy, harness: ["delivery_target": "local_verified"]), [])
    XCTAssertFalse(
      HealthCollection.trustedPolicyErrors(
        policy: ["decision": "approved"], harness: ["delivery_target": "local_verified"]
      ).isEmpty)
    XCTAssertFalse(
      HealthCollection.trustedPolicyErrors(
        policy: [
          "schema_version": "1.0.0", "decision": "approved", "github": ["owner": "shawn"],
          "apple": NSNull(),
        ], harness: ["delivery_target": "local_verified"]
      ).isEmpty)
  }

  func testGitHubProbeRequiresExactRepositoryPermissionAndProjectReadback() {
    let runner = FakeRunner([
      .init(stdout: "Shawn\n", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout:
          #"{"nameWithOwner":"Shawn/App","viewerPermission":"WRITE","hasIssuesEnabled":true}"#,
        stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: #"{"number":7,"title":"Delivery"}"#, stderr: "", exitCode: 0, timedOut: false,
        truncated: false),
    ])
    let observations = HealthEvaluation.collectLiveObservations(
      report: [
        "required_check_ids": ["github.issue_pr", "github.project"],
        "authoritative_targets": ["remote": "git@github.com:Shawn/App.git"],
      ],
      harness: ["github_tracking": ["project": ["number": 7, "owner": "Shawn"]]],
      policy: ["github": ["owner": "Shawn"]], authorization: nil, runner: runner
    )
    XCTAssertEqual(observations["github.issue_pr"]?["status"] as? String, "healthy")
    XCTAssertEqual(observations["github.project"]?["status"] as? String, "healthy")
    XCTAssertEqual(
      runner.invocations.last?.1, ["project", "view", "7", "--owner", "Shawn", "--format", "json"])
  }

  func testGitHubTimeoutFailsClosedBeforeRepositoryClaim() {
    let runner = FakeRunner([
      .init(stdout: "", stderr: "", exitCode: 0, timedOut: true, truncated: false)
    ])
    let observations = HealthEvaluation.collectLiveObservations(
      report: [
        "required_check_ids": ["github.issue_pr"],
        "authoritative_targets": ["remote": "https://github.com/shawn/app.git"],
      ],
      harness: [:], policy: ["github": ["owner": "shawn"]], authorization: nil, runner: runner
    )
    XCTAssertEqual(observations["github.issue_pr"]?["status"] as? String, "blocked")
    XCTAssertEqual(runner.invocations.count, 1)
  }

  func testSelectedXcodeVersionAndExactASCAppGroupsAreReadBack() {
    let developer = "/Applications/Xcode.app/Contents/Developer"
    let xcodebuild = developer + "/usr/bin/xcodebuild"
    let runner = FakeRunner([
      .init(stdout: developer + "\n", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: xcodebuild + "\n", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: "Xcode 18.0\nBuild version 22A1\n", stderr: "", exitCode: 0, timedOut: false,
        truncated: false),
      .init(stdout: "authenticated", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: #"{"data":[{"id":"123","attributes":{"bundleId":"com.example.app"}}]}"#, stderr: "",
        exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: #"{"data":[{"id":"group-a"},{"id":"group-b"}]}"#, stderr: "", exitCode: 0,
        timedOut: false, truncated: false),
    ])
    let ids = [
      "xcode.authoritative_container", "apple.execution_path", "apple.account_guard", "cli.asc",
      "testflight.upload_target", "testflight.internal_groups",
    ]
    let observations = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ids], harness: [:],
      policy: ["apple": ["account_guard_ref": "private", "team_id": "TEAM"]],
      authorization: [
        "apple": [
          "account_guard_ref": "private", "team_id": "TEAM", "app_id": "123",
          "bundle_id": "com.example.app", "internal_group_ids": ["group-b"],
        ]
      ], runner: runner)
    for id in ids { XCTAssertEqual(observations[id]?["status"] as? String, "healthy", id) }
    XCTAssertEqual(runner.invocations[2].0, xcodebuild)
  }

  func testASCGroupMismatchAndXcodeVersionTimeoutFailClosed() {
    let developer = "/Applications/Xcode.app/Contents/Developer"
    let xcodebuild = developer + "/usr/bin/xcodebuild"
    let runner = FakeRunner([
      .init(stdout: developer, stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: xcodebuild, stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: "", stderr: "", exitCode: 0, timedOut: true, truncated: false),
      .init(stdout: "ok", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: #"{"data":[{"id":"123","attributes":{"bundleId":"com.example.app"}}]}"#, stderr: "",
        exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: #"{"data":[{"id":"other"}]}"#, stderr: "", exitCode: 0, timedOut: false,
        truncated: false),
    ])
    let ids = ["apple.execution_path", "testflight.internal_groups"]
    let observations = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ids], harness: [:],
      policy: ["apple": ["account_guard_ref": "p", "team_id": "T"]],
      authorization: [
        "apple": [
          "account_guard_ref": "p", "team_id": "T", "app_id": "123", "bundle_id": "com.example.app",
          "internal_group_ids": ["wanted"],
        ]
      ], runner: runner)
    XCTAssertEqual(observations["apple.execution_path"]?["status"] as? String, "blocked")
    XCTAssertEqual(observations["testflight.internal_groups"]?["status"] as? String, "blocked")
  }

  func testMCPRegistrationIsBoundBeforeInjectedToolsProbes() {
    let runner = FakeRunner([
      .init(
        stdout: #"{"command":"xcrun","args":["mcpbridge"]}"#, stderr: "", exitCode: 0,
        timedOut: false, truncated: false),
      .init(
        stdout: #"{"url":"https://mcp.applesamplecode.com/mcp"}"#, stderr: "", exitCode: 0,
        timedOut: false, truncated: false),
    ])
    let mcp = FakeMCPProbe()
    let harness: [String: Any] = [
      "agent_skills": [
        "installations": ["codex": ["collection_root": "/fixture"], "claude": NSNull()]
      ]
    ]
    let observations = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["mcp.xcode", "mcp.apple_sample_code"]], harness: harness,
      policy: [:], authorization: nil, runner: runner, mcpProbe: mcp)
    XCTAssertEqual(observations["mcp.xcode"]?["status"] as? String, "healthy")
    XCTAssertEqual(observations["mcp.apple_sample_code"]?["status"] as? String, "healthy")
    XCTAssertEqual(mcp.xcodeCalls, 1)
    XCTAssertEqual(mcp.appleCalls, 1)
  }

  func testMCPRegistrationDriftPreventsConnectionAndLocalLLMRejectsNonLoopback() {
    let registration = FakeRunner([
      .init(
        stdout: #"{"command":"other"}"#, stderr: "", exitCode: 0, timedOut: false, truncated: false)
    ])
    let mcp = FakeMCPProbe()
    let harness: [String: Any] = [
      "agent_skills": [
        "installations": ["codex": ["collection_root": "/fixture"], "claude": NSNull()]
      ]
    ]
    let first = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["mcp.xcode"]], harness: harness, policy: [:],
      authorization: nil, runner: registration, mcpProbe: mcp)
    XCTAssertEqual(first["mcp.xcode"]?["status"] as? String, "blocked")
    XCTAssertEqual(mcp.xcodeCalls, 0)
    let second = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["local_llm"]], harness: [:], policy: [:], authorization: nil,
      runner: FakeRunner([]), environment: ["OLLAMA_HOST": "https://models.example.com"])
    XCTAssertEqual(second["local_llm"]?["status"] as? String, "blocked")
  }

  func testMCPResponseValidationRejectsWrongCorrelationAndEmptyStatus() {
    XCTAssertTrue(HealthMCPResponseValidation.hasResponseID(["id": 2], 2))
    XCTAssertFalse(HealthMCPResponseValidation.hasResponseID(["id": 1], 2))
    XCTAssertFalse(HealthMCPResponseValidation.hasResponseID(["id": true], 1))
    XCTAssertFalse(HealthMCPResponseValidation.hasUsableToolResult(["id": 3, "result": [:]]))
    XCTAssertFalse(
      HealthMCPResponseValidation.hasUsableToolResult([
        "id": 3, "result": ["isError": true, "content": [["type": "text", "text": "ok"]]],
      ]))
    XCTAssertTrue(
      HealthMCPResponseValidation.hasUsableToolResult([
        "id": 3, "result": ["content": [["type": "text", "text": #"{"isLatest":true}"#]]],
      ]))
  }

  func testLocalLLMReadsOnlyModelTagsOnLoopback() {
    let runner = FakeRunner([
      .init(
        stdout: "NAME ID SIZE\nqwen:7b abc 4GB\nllama:8b def 5GB\n", stderr: "", exitCode: 0,
        timedOut: false, truncated: false)
    ])
    let observations = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["local_llm"]], harness: [:], policy: [:], authorization: nil,
      runner: runner, environment: ["OLLAMA_HOST": "http://[::1]:11434"])
    XCTAssertEqual(observations["local_llm"]?["status"] as? String, "healthy")
    XCTAssertEqual(runner.invocations.first?.1, ["list"])
  }

  func testSpecKitSnapshotIsRebuiltAndBoundToAuthorization() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".specify"), withIntermediateDirectories: true)
    let feature = root.appendingPathComponent("specs/001-feature")
    try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
    try Data(#"{"feature_directory":"specs/001-feature"}"#.utf8).write(
      to: root.appendingPathComponent(".specify/feature.json"))
    for name in ["spec.md", "plan.md", "tasks.md"] {
      try Data("# \(name)\n".utf8).write(to: feature.appendingPathComponent(name))
    }
    let directoryRoot = URL(fileURLWithPath: root.path, isDirectory: true)
    let snapshot = try SpecKitSnapshot.buildSnapshot(
      root: directoryRoot, featureDirectory: "specs/001-feature")
    let binding: [String: Any] = [
      "release": snapshot["spec_kit_release"]!, "feature_id": snapshot["feature_id"]!,
      "feature_directory": snapshot["feature_directory"]!,
      "artifact_hashes": snapshot["artifact_hashes"]!,
      "snapshot_sha256": snapshot["snapshot_sha256"]!,
    ]
    let healthy = HealthEvaluation.collectLiveObservations(
      report: [
        "required_check_ids": ["spec_kit.snapshot"],
        "authoritative_targets": ["repository": directoryRoot.path],
      ], harness: ["spec_kit": ["enabled": true]], policy: [:],
      authorization: ["spec_kit": binding], runner: FakeRunner([]))
    XCTAssertEqual(healthy["spec_kit.snapshot"]?["status"] as? String, "healthy")
    try Data("changed\n".utf8).write(to: feature.appendingPathComponent("tasks.md"))
    let changed = HealthEvaluation.collectLiveObservations(
      report: [
        "required_check_ids": ["spec_kit.snapshot"],
        "authoritative_targets": ["repository": directoryRoot.path],
      ], harness: ["spec_kit": ["enabled": true]], policy: [:],
      authorization: ["spec_kit": binding], runner: FakeRunner([]))
    XCTAssertEqual(changed["spec_kit.snapshot"]?["status"] as? String, "blocked")
  }

  func testCompanionProvenanceChecksPublicMetadataCommitTreeAndEveryBlob() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contracts = root.appendingPathComponent("icon-composer/contracts")
    try FileManager.default.createDirectory(at: contracts, withIntermediateDirectories: true)
    let schema: [String: Any] = [
      "type": "object", "required": ["upstream", "sources"],
      "properties": ["upstream": ["type": "object"], "sources": ["type": "array", "minItems": 1]],
      "additionalProperties": true,
    ]
    try HarnessRuntime.atomicWriteJSON(
      schema, to: contracts.appendingPathComponent("companion-upstream.schema.json"))
    let manifest: [String: Any] = [
      "upstream": [
        "repository": "apple/Icon-Composer", "reviewed_revision": "commit-1",
        "reviewed_tree": "tree-1", "default_branch": "main",
      ],
      "sources": [
        ["path": "Sources/A.swift", "blob_sha": "blob-a"],
        ["path": "Sources/B.swift", "blob_sha": "blob-b"],
      ],
    ]
    try HarnessRuntime.atomicWriteJSON(
      manifest, to: contracts.appendingPathComponent("companion-upstream.json"))
    let runner = FakeRunner([
      .init(
        stdout: #"{"private":false,"visibility":"public","default_branch":"main"}"#, stderr: "",
        exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: #"{"sha":"commit-1","commit":{"tree":{"sha":"tree-1"}}}"#, stderr: "", exitCode: 0,
        timedOut: false, truncated: false),
      .init(
        stdout:
          #"{"tree":[{"path":"Sources/A.swift","type":"blob","sha":"blob-a"},{"path":"Sources/B.swift","type":"blob","sha":"blob-b"}]}"#,
        stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(
        stdout: #"{"sha":"head-2"}"#, stderr: "", exitCode: 0, timedOut: false, truncated: false),
    ])
    let harness: [String: Any] = [
      "selected_writer": "codex",
      "agent_skills": [
        "installations": ["codex": ["collection_root": root.path], "claude": NSNull()]
      ],
    ]
    let observations = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["companion_upstream.provenance"]], harness: harness,
      policy: [:], authorization: nil, runner: runner)
    XCTAssertEqual(observations["companion_upstream.provenance"]?["status"] as? String, "healthy")
    XCTAssertEqual(runner.invocations.count, 4)

    var empty = manifest
    empty["sources"] = [] as [[String: Any]]
    try HarnessRuntime.atomicWriteJSON(
      empty, to: contracts.appendingPathComponent("companion-upstream.json"))
    let blocked = HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["companion_upstream.provenance"]], harness: harness,
      policy: [:], authorization: nil, runner: FakeRunner([]))
    XCTAssertEqual(blocked["companion_upstream.provenance"]?["status"] as? String, "blocked")
  }

  func testTrustedHarnessBindsLiveGitSkillsAndSwiftCoordinatorIdentity() throws {
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let repository = temporary.appendingPathComponent("repository", isDirectory: true)
    let skillRoot = temporary.appendingPathComponent("harness-skill", isDirectory: true)
    let installed = temporary.appendingPathComponent("installed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: skillRoot.appendingPathComponent("contracts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: skillRoot.appendingPathComponent("verification/Sources"),
      withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: skillRoot.appendingPathComponent("contracts/schema.json"))
    try Data("public enum Fixture {}\n".utf8).write(
      to: skillRoot.appendingPathComponent("verification/Sources/Fixture.swift"))
    for name in ["agent-harness", "apple-development-health", "git-workflow", "github-projects"] {
      let directory = installed.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("---\nname: \(name)\n---\n".utf8).write(
        to: directory.appendingPathComponent("SKILL.md"))
    }
    let required = ["agent-harness", "apple-development-health", "git-workflow", "github-projects"]
      .sorted()
    let firstManifest = try HealthCollection.installedSkillManifest(
      searchRoots: [installed], requiredSkills: required, client: "codex")
    let expectedBundle = firstManifest["bundle_sha256"] as! String
    let state = temporary.appendingPathComponent("coordinator.json")
    let bootstrapped = try ResourceCoordinator.bootstrap(
      statePath: state, legacyLeasesQuiesced: true)
    let executable = temporary.appendingPathComponent("apple-verify")
    try Data("fixture executable".utf8).write(to: executable)
    let binding: [String: Any] = [
      "runtime_kind": "swift", "runtime_contract": "apple-verification-core.resources.v1",
      "state_path": state.path,
      "coordinator_instance_id": bootstrapped["coordinator_instance_id"]!,
      "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
      "source_bundle_sha256": try ResourceCoordinator.sourceBundleSHA256(skillRoot: skillRoot),
    ]
    let harness: [String: Any] = [
      "authoritative_root": repository.path, "health_profile": "local_verified",
      "health_components": [], "mode": "codex",
      "agent_skills": [
        "task_skills": [], "expected_bundle_sha256": expectedBundle,
        "installations": ["codex": ["collection_root": installed.path], "claude": NSNull()],
      ],
      "resource_coordinator": binding,
    ]
    let skills = try HealthCollection.observeAgentSkills(harness: harness)
    let coordinator = try HealthCollection.observeResourceCoordinator(
      harness: harness, context: .init(repositoryRoot: repository, harnessRoot: skillRoot),
      executableURL: executable)
    let report: [String: Any] = [
      "profile": "local_verified", "selected_components": [],
      "authoritative_targets": [
        "repository": repository.resolvingSymlinksInPath().path,
        "remote": "https://github.com/shawn/app.git", "branch": "main",
      ],
      "agent_skill_manifest": skills, "resource_coordinator_observation": coordinator,
    ]
    let runner = FakeRunner([
      .init(
        stdout: repository.resolvingSymlinksInPath().path, stderr: "", exitCode: 0, timedOut: false,
        truncated: false),
      .init(
        stdout: "https://github.com/shawn/app.git", stderr: "", exitCode: 0, timedOut: false,
        truncated: false),
      .init(stdout: "main", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: ".git", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: ".git", stderr: "", exitCode: 0, timedOut: false, truncated: false),
    ])
    XCTAssertEqual(
      HealthCollection.validateHarnessBinding(
        report: report, harness: harness,
        context: .init(repositoryRoot: repository, harnessRoot: skillRoot), runner: runner,
        executableURL: executable), [])

    var registryHarness = harness
    registryHarness["health_components"] = ["project_registry"]
    var registryReport = report
    registryReport["selected_components"] = ["project_registry"]
    registryReport["authoritative_targets"] = [
      "repository": repository.resolvingSymlinksInPath().path,
      "remote": "https://gitlab.com/shawn/app.git", "branch": "main",
    ]
    registryReport["project_registry_resolution"] = [
      "status": "resolved",
      "candidate": [
        "canonical_root": repository.path,
        "remote_fingerprint": "sha256:" + String(repeating: "a", count: 64), "kind": "primary",
        "xcode_containers": [],
      ], "worktree_authorized": false,
    ]
    let nonGitHub = FakeRunner([
      .init(
        stdout: repository.resolvingSymlinksInPath().path, stderr: "", exitCode: 0, timedOut: false,
        truncated: false),
      .init(
        stdout: "https://gitlab.com/shawn/app.git", stderr: "", exitCode: 0, timedOut: false,
        truncated: false),
      .init(stdout: "main", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: ".git", stderr: "", exitCode: 0, timedOut: false, truncated: false),
      .init(stdout: ".git", stderr: "", exitCode: 0, timedOut: false, truncated: false),
    ])
    XCTAssertTrue(
      HealthCollection.validateHarnessBinding(
        report: registryReport, harness: registryHarness,
        context: .init(repositoryRoot: repository, harnessRoot: skillRoot), runner: nonGitHub,
        executableURL: executable
      ).contains("live repository health binding failed"))
  }

  private func baseReport(now: Date, githubStatus: String, evidence: [String]) -> [String: Any] {
    let checks: [[String: Any]] = [
      [
        "id": "repository.identity", "category": "repository", "required": true,
        "status": "healthy", "summary": "fixture", "evidence": ["x"],
      ],
      [
        "id": "agent.skills", "category": "agent", "required": true, "status": "healthy",
        "summary": "fixture", "evidence": ["x"],
      ],
      [
        "id": "agent.resource_coordinator", "category": "agent", "required": true,
        "status": "healthy", "summary": "fixture", "evidence": ["x"],
      ],
      [
        "id": "cli.git", "category": "cli", "required": true, "status": "healthy",
        "summary": "fixture", "evidence": ["x"],
      ],
      [
        "id": "github.issue_pr", "category": "github", "required": true, "status": githubStatus,
        "summary": "fixture", "evidence": evidence,
      ],
    ]
    return [
      "schema_version": "1.0.0", "profile": "pr_ready",
      "observed_at": HarnessRuntime.timestamp(now),
      "authoritative_targets": ["repository": "/fixture"],
      "selected_components": [],
      "required_check_ids": [
        "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
        "github.issue_pr",
      ], "checks": checks,
      "resource_coordinator_observation": [
        "state_path_sha256": "sha256:" + String(repeating: "0", count: 64),
        "coordinator_instance_id": "fixture", "state_schema_version": 2,
        "migration_bootstrap_confirmed": true, "runtime_kind": "swift",
        "runtime_contract": "apple-verification-core.resources.v1",
        "executable_sha256": "sha256:" + String(repeating: "1", count: 64),
        "source_bundle_sha256": "sha256:" + String(repeating: "2", count: 64),
        "active_lease_count": 0,
      ],
    ]
  }
}
