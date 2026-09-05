import XCTest

@testable import AppleVerificationCore

final class ContractValidationTests: XCTestCase {
  var root: URL {
    if let override = ProcessInfo.processInfo.environment["APPLE_VERIFICATION_REPOSITORY_ROOT"] {
      return URL(fileURLWithPath: override)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
  var context: RuntimeContext {
    RuntimeContext(
      repositoryRoot: root, harnessRoot: root.appendingPathComponent("skills/agent-harness"))
  }

  func testShippedWorkflowsAndLeaseIntervalsAreExact() throws {
    let resources = Set(ContractValidation.resources)
    let main = try object("skills/agent-harness/contracts/workflow.json")
    let local = try object("skills/agent-harness/contracts/local-workflow.json")
    let testflight = try object("skills/agent-harness/contracts/testflight-workflow.json")
    XCTAssertEqual(ContractValidation.validateWorkflowSemantics(main, resources: resources), [])
    XCTAssertEqual(ContractValidation.validateLocalWorkflow(local, resources: resources), [])
    XCTAssertEqual(
      ContractValidation.validateTestFlightWorkflow(testflight, resources: resources), [])
    var nodes = testflight["nodes"] as! [[String: Any]]
    let release = nodes.firstIndex { $0["id"] as? String == "release_testflight_upload" }!
    nodes[release]["protects"] = ["upload"]
    var drifted = testflight
    drifted["nodes"] = nodes
    XCTAssertTrue(
      ContractValidation.validateTestFlightWorkflow(drifted, resources: resources).contains {
        $0.contains("protected nodes")
      })
    var bounded = main
    var attempt = main["attempt_policy"] as! [String: Any]
    attempt["max_implementation_attempts"] = 4
    bounded["attempt_policy"] = attempt
    XCTAssertTrue(
      ContractValidation.validateWorkflowSemantics(bounded, resources: resources).contains {
        $0.contains("attempt")
      })
    var cleanup = local
    var cleanupValue = local["cleanup"] as! [String: Any]
    cleanupValue["triggers"] = ["success_terminal"]
    cleanup["cleanup"] = cleanupValue
    XCTAssertTrue(
      ContractValidation.validateLocalWorkflow(cleanup, resources: resources).contains {
        $0.contains("cleanup")
      })
  }

  func testDAGRejectsCyclesMissingEdgesAndDuplicateDependencies() {
    XCTAssertFalse(
      ContractValidation.validateDAG([
        ["id": "a", "requires": ["b"]], ["id": "b", "requires": ["a"]],
      ]).isEmpty)
    XCTAssertFalse(ContractValidation.validateDAG([["id": "a", "requires": ["missing"]]]).isEmpty)
    XCTAssertFalse(
      ContractValidation.validateDAG([
        ["id": "a", "requires": []], ["id": "b", "requires": ["a", "a"]],
      ]).isEmpty)
  }

  func testDeliveryAliasesAndNullCredentials() {
    let disabled: [String: Any] = ["enabled": false, "channels": []]
    XCTAssertEqual(ContractValidation.validateDeliveryChannelConfig(disabled), [])
    let telegram: [String: Any] = [
      "enabled": true,
      "channels": [
        [
          "id": "t", "enabled": true, "kind": "telegram", "credential_ref": NSNull(),
          "destination_ref": "public.chat", "transport_ref": "http",
          "whatsapp_template_ref": NSNull(),
        ]
      ],
    ]
    let errors = ContractValidation.validateDeliveryChannelConfig(telegram)
    XCTAssertTrue(errors.contains { $0.contains("credential") })
    XCTAssertTrue(errors.contains { $0.contains("private alias") })
    XCTAssertTrue(errors.contains { $0.contains("transport") })
  }

  func testCompletionUsageTreatsJSONNullAsAbsentAndRejectsFractions() {
    let valid: [String: Any] = [
      "usage": [
        "status": "not_exposed", "missing_sources": ["codex"], "source_records": [:],
        "attribution": [], "cross_provider_total": NSNull(),
        "cost": ["status": "not_exposed", "amount": NSNull(), "currency": NSNull()],
      ]
    ]
    XCTAssertEqual(ContractValidation.validateCompletionReport(valid), [])
    let fractional: [String: Any] = [
      "usage": [
        "status": "full", "missing_sources": [],
        "source_records": ["x": ["input_tokens": 1.5, "output_tokens": 2]],
        "attribution": [["source_ids": ["x"]]],
        "cross_provider_total": ["input_tokens": 1, "output_tokens": 2],
        "cost": ["status": "not_exposed", "amount": NSNull(), "currency": NSNull()],
      ]
    ]
    XCTAssertTrue(
      ContractValidation.validateCompletionReport(fractional).contains {
        $0.contains("bounded integer")
      })
  }

  func testCompanionProvenanceAndRuntimeBindingMutations() throws {
    let companion = try object("skills/icon-composer/contracts/companion-upstream.json")
    XCTAssertEqual(ContractValidation.validateCompanionUpstream(companion), [])
    var drifted = companion
    var integration = drifted["integration"] as! [String: Any]
    integration["execute_upstream"] = true
    drifted["integration"] = integration
    XCTAssertTrue(
      ContractValidation.validateCompanionUpstream(drifted).contains {
        $0.contains("safety boundary")
      })
    let binding: [String: Any] = [
      "runtime_kind": "swift", "runtime_contract": Authorization.runtimeContract,
      "executable_path": "/bin/tool",
      "executable_sha256": "sha256:" + String(repeating: "a", count: 64),
      "source_bundle_sha256": "sha256:" + String(repeating: "b", count: 64),
    ]
    XCTAssertEqual(
      ContractValidation.validateSwiftRuntimeBinding(
        binding, contract: Authorization.runtimeContract, requireExecutablePath: true), [])
    var legacy = binding
    legacy["script_sha256"] = "sha256:" + String(repeating: "c", count: 64)
    XCTAssertFalse(
      ContractValidation.validateSwiftRuntimeBinding(
        legacy, contract: Authorization.runtimeContract, requireExecutablePath: true
      ).isEmpty)
    XCTAssertEqual(
      ContractValidation.validateIconGenWorkflow(
        at: root.appendingPathComponent(".github/workflows/icongen-upstream-watch.yml")), [])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".yml")
    try
      (try String(
        contentsOf: root.appendingPathComponent(".github/workflows/icongen-upstream-watch.yml"),
        encoding: .utf8) + "\npermissions: write-all\n").write(
        to: temporary, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temporary) }
    XCTAssertTrue(
      ContractValidation.validateIconGenWorkflow(at: temporary).contains {
        $0.contains("forbidden privilege")
      })
  }

  func testCapabilityPoliciesRemainFullyBound() throws {
    let capabilities = try object("skills/agent-harness/contracts/capabilities.json")
    let current = ContractValidation.validateCapabilities(capabilities)
    let hashes = [
      "runtime_registry_policy", "xcode_mcp_provider_policy", "resource_overlap_policy",
      "cross_run_coordination_policy",
    ].map { "\($0)=\(ContractValidation.hash(capabilities[$0]) ?? "nil")" }
    XCTAssertFalse(
      current.contains {
        $0.contains("CoreSimulator") || $0.contains("Xcode MCP") || $0.contains("resource overlap")
          || $0.contains("cross-run")
      }, "\(current); \(hashes)")
    var drifted = capabilities
    var varPolicy = capabilities["runtime_registry_policy"] as! [String: Any]
    varPolicy["minimum_repeat_observations"] = 1
    drifted["runtime_registry_policy"] = varPolicy
    XCTAssertTrue(
      ContractValidation.validateCapabilities(drifted).contains { $0.contains("CoreSimulator") })
  }

  func testTestFlightTransitionRequiresOrderedCompletedReadbackAndStableArtifact() {
    func record(_ type: String, _ payload: [String: Any]) -> [String: Any] {
      ["record_type": type, "payload": payload]
    }
    let base: [String: Any] = [
      "system": "apple", "authorization_hash": "auth", "outcome": "succeeded",
      "artifact_sha256": "sha256:" + String(repeating: "a", count: 64),
      "artifact_source_commit": String(repeating: "b", count: 40), "version": "1.0", "build": "1",
    ]
    var readback = base
    readback["action"] = "apple.testflight.readback"
    readback["target"] = "app:1:upload"
    readback["external_state"] = "completed"
    let errors = ContractValidation.validateTestFlightLedgerTransitions([
      record("external_write", readback),
      record("node", ["node_id": "testflight_uploaded", "status": "passed"]),
    ])
    XCTAssertTrue(errors.contains { $0.contains("bounded processing") })
    XCTAssertTrue(errors.contains { $0.contains("completed upload read-back") })
    var upload = base
    upload["action"] = "apple.testflight.upload"
    upload["target"] = "app:1"
    var wait = base
    wait["action"] = "apple.testflight.processing.wait"
    wait["target"] = "app:1:processing"
    XCTAssertEqual(
      ContractValidation.validateTestFlightLedgerTransitions([
        record("external_write", upload), record("external_write", wait),
        record("external_write", readback),
        record("node", ["node_id": "testflight_uploaded", "status": "passed"]),
      ]), [])
    var changed = readback
    changed["build"] = "2"
    XCTAssertTrue(
      ContractValidation.validateTestFlightLedgerTransitions([
        record("external_write", upload), record("external_write", wait),
        record("external_write", changed),
      ]).contains { $0.contains("artifact identity drifted") })
  }

  func testAuthorizationTemplatesAndSchemaContentBinding() throws {
    let pending = try object("skills/agent-harness/templates/run-authorization.json")
    XCTAssertEqual(ContractValidation.validatePendingAuthorization(pending), [])
    var executable = pending
    executable["allowed_paths"] = ["Sources"]
    XCTAssertTrue(
      ContractValidation.validatePendingAuthorization(executable).contains {
        $0.contains("allowed_paths")
      })
    let schema = root.appendingPathComponent(
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json")
    var approved = try object("tests/fixtures/run-authorization-approved.json")
    approved["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    XCTAssertEqual(
      ContractValidation.validateApprovedAuthorization(
        approved, schemaURL: schema, context: context), [])
    approved["contract_schema_sha256"] = "sha256:" + String(repeating: "0", count: 64)
    XCTAssertTrue(
      ContractValidation.validateApprovedAuthorization(
        approved, schemaURL: schema, context: context
      ).contains { $0.contains("schema content") })
  }

  func testImmutableAuthorityInjectionFixture() throws {
    let fixture = try object("tests/fixtures/rag-prompt-injection.json")
    XCTAssertEqual(ContractValidation.validatePromptInjectionFixture(fixture), [])
    var drifted = fixture
    var expected = fixture["expected"] as! [String: Any]
    expected["tool_calls"] = 1
    drifted["expected"] = expected
    XCTAssertTrue(
      ContractValidation.validatePromptInjectionFixture(drifted).contains {
        $0.contains("zero tool calls")
      })
  }

  private func object(_ path: String) throws -> [String: Any] {
    try HarnessRuntime.object(root.appendingPathComponent(path))
  }
}
