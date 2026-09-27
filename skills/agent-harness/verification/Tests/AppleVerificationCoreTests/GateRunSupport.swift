import XCTest

@testable import AppleVerificationCore

/// Setup the action-gate suites share: the repository under test, private run roots, the approved
/// fixture, the pr_ready harness both derive from the local template, and the ledger records a
/// writer appends before its first reservation.
enum GateRunSupport {
  /// This checkout, or the one `APPLE_VERIFICATION_REPOSITORY_ROOT` names.
  static let repositoryRoot: URL = {
    if let override = ProcessInfo.processInfo.environment["APPLE_VERIFICATION_REPOSITORY_ROOT"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override).standardizedFileURL
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return root.standardizedFileURL
  }()

  static var context: RuntimeContext {
    RuntimeContext(
      repositoryRoot: repositoryRoot,
      harnessRoot: repositoryRoot.appendingPathComponent("skills/agent-harness"))
  }

  /// A new directory, spelled without symlinks, that is removed when `testCase` ends.
  static func temporaryDirectory(for testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url.resolvingSymlinksInPath()
  }

  /// The approved fixture bound to the installed run-authorization schema.
  static func approvedEnvelope() throws -> [String: Any] {
    var envelope = try HarnessRuntime.object(
      repositoryRoot.appendingPathComponent("tests/fixtures/run-authorization-approved.json"))
    let schema = repositoryRoot.appendingPathComponent(
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    return envelope
  }

  /// The local harness template's fields rebound for a pr_ready run on these private files.
  static func prReadyHarness(
    _ template: [String: Any], checkout: URL, policy: URL, authorization: URL, ledger: URL
  ) -> [String: Any] {
    var harness = template
    harness["authoritative_root"] = checkout.path
    harness["private_policy_overlay"] = policy.path
    harness["run_authorization"] = authorization.path
    harness["run_ledger"] = ledger.path
    harness["delivery_target"] = "pr_ready"
    harness["health_profile"] = "pr_ready"
    harness["github_tracking"] = ["issues": true, "project": NSNull()]
    harness["local_requirements"] = NSNull()
    return harness
  }

  static func record(
    _ sequence: Int, _ type: String, _ payload: [String: Any], at stamp: String,
    runID: String = "run"
  ) -> [String: Any] {
    [
      "schema_version": "1.0.0", "run_id": runID, "sequence": sequence, "recorded_at": stamp,
      "record_type": type, "payload": payload,
    ]
  }

  /// Appends a writer record as the agent does: under the ledger lock, one above the highest
  /// sequence, stamped at `stamp` or else never earlier than the latest record.
  static func append(
    _ type: String, _ payload: [String: Any], to ledger: URL, at stamp: String? = nil
  )
    throws
  {
    try HarnessRuntime.withFileLock(at: ledger) {
      let records = try Authorization.loadLedger(ledger)
      let sequence = (records.compactMap { $0["sequence"] as? Int }.max() ?? 0) + 1
      let line = record(
        sequence, type, payload,
        at: stamp ?? HarnessRuntime.timestamp(Authorization.ledgerClock(records, now: Date())),
        runID: records.first?["run_id"] as? String ?? "")
      let handle = try FileHandle(forWritingTo: ledger)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: try HarnessRuntime.canonicalJSON(line) + Data([0x0a]))
    }
  }

  /// The active interval a run records before its first reservation.
  static func activeInterval(authorizationHash: String, startingAt start: Date) -> [String: Any] {
    [
      "authorization_hash": authorizationHash, "kind": "active",
      "started_at": HarnessRuntime.timestamp(start),
      "ended_at": HarnessRuntime.timestamp(start.addingTimeInterval(1)), "reason": "implement",
    ]
  }

  /// The writer's ledger record of the GitHub mutation lease the coordinator granted.
  static func leaseAcquisition(
    receipt: [String: Any], descriptor: [String: Any], envelope: [String: Any], action: String
  ) throws -> [String: Any] {
    let repository = try XCTUnwrap(envelope["repository"] as? [String: Any])
    return [
      "lease_id": receipt["lease_id"]!, "action": "acquire", "owner": "codex",
      "resource": ResourceCoordinator.github, "resource_key": receipt["resource_key"]!,
      "resource_descriptor": descriptor, "coordinator_receipt": receipt,
      "branch": repository["branch"]!, "base_sha": repository["base_sha"]!,
      "pre_state_hash": "sha256:" + String(repeating: "0", count: 64),
      "allowed_paths": ["Sources"], "allowed_actions": [action],
      "approval_id": envelope["authorization_id"]!, "acquired_at": receipt["acquired_at"]!,
      "expires_at": receipt["expires_at"]!,
    ]
  }

  /// The attestation live health evaluation returns for the request's exact report.
  static func liveAttestation(envelope: [String: Any], request: [String: Any]) throws
    -> [String: Any]
  {
    var attestation = try XCTUnwrap(envelope["health_attestation"] as? [String: Any])
    attestation["report_sha256"] = request["health_report_sha256"]
    attestation["observed_at"] = HarnessRuntime.timestamp()
    return attestation
  }
}
