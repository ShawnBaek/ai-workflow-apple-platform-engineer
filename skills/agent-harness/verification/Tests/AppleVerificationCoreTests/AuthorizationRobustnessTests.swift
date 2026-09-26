import XCTest

@testable import AppleVerificationCore

/// Authority must not outlive what was approved: a terminal stop, a later rejection, a lease that
/// expired during slow probes, a health drop, or an Issue target outside the bound repository.
/// The ledger must keep valid records readable and in time order.
final class AuthorizationRobustnessTests: XCTestCase {
  let repositoryRoot: URL = {
    if let override = ProcessInfo.processInfo.environment["APPLE_VERIFICATION_REPOSITORY_ROOT"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override).standardizedFileURL
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return root.standardizedFileURL
  }()
  var context: RuntimeContext {
    RuntimeContext(
      repositoryRoot: repositoryRoot,
      harnessRoot: repositoryRoot.appendingPathComponent("skills/agent-harness"))
  }

  func testTerminalStopBlocksALaterLeaseFromReservingAnAction() throws {
    let resumed = try reservedRun(stopBeforeLease: true)
    XCTAssertNil(resumed.reservation)
    XCTAssertTrue(
      resumed.errors.contains { $0.contains("after its terminal stop") }, "\(resumed.errors)")

    let active = try reservedRun()
    XCTAssertEqual(active.errors, [])
    XCTAssertNotNil(active.reservation)
  }

  func testDispatchRejectsALeaseThatExpiredDuringSlowHealthProbes() throws {
    let run = try reservedRun(leaseSeconds: 60)
    let clock = TestClock()
    let result = dispatch(run, clock: clock) { clock.now.addTimeInterval(70) }
    XCTAssertNil(result.dispatch)
    XCTAssertTrue(
      result.errors.contains { $0.contains("expired_requires_recover") }, "\(result.errors)")
  }

  func testDispatchAndReservationKeepLedgerTimeMonotonicAcrossAWriterWithAFasterClock() throws {
    // The writer that appended the lease and a later progress record reads a clock a few
    // seconds ahead of the runtime's; the runtime's own records must not step back in time.
    let run = try reservedRun(leaseStampOffset: 3)
    XCTAssertEqual(run.errors, [])
    let clock = TestClock()
    let aheadStamp = HarnessRuntime.timestamp(clock.now.addingTimeInterval(8))
    let result = dispatch(run, clock: clock) {
      clock.now.addTimeInterval(5)
      do {
        try self.append(
          run, "node", ["node_id": "mark_issue_in_review", "status": "pending"], at: aheadStamp)
      } catch { XCTFail("\(error)") }
    }
    XCTAssertEqual(result.errors, [])
    XCTAssertEqual(result.dispatch?["verified_at"] as? String, aheadStamp)
    let records = try Authorization.loadLedger(run.ledger)
    XCTAssertEqual(
      Authorization.ledgerContractErrors(records, coordinatorState: run.state, context: context), []
    )
  }

  func testDispatchRejectsLiveHealthBelowTheApprovedStatus() throws {
    let run = try reservedRun()
    var degraded = run.attestation
    degraded["overall_status"] = "degraded"
    let result = dispatch(run, clock: TestClock(), attestation: degraded) {}
    XCTAssertNil(result.dispatch)
    XCTAssertEqual(result.errors, ["dispatch live health status fell below the approved status"])
  }

  func testLiveHealthMayRecoverAboveButNeverFallBelowTheApprovedStatus() throws {
    func healthErrors(approved: String, live: String, profile: String = "pr_ready") throws
      -> [String]
    {
      var envelope = try currentApprovedEnvelope()
      var authorized = envelope["health_attestation"] as! [String: Any]
      authorized["overall_status"] = approved
      envelope["health_attestation"] = authorized
      var verified = authorized
      verified["overall_status"] = live
      verified["profile"] = profile
      verified["observed_at"] = HarnessRuntime.timestamp()
      let grant = (envelope["action_grants"] as! [[String: Any]])[0]
      var request: [String: Any] = [:]
      for field in Authorization.requestFields { request[field] = grant[field] ?? NSNull() }
      request["health_report_sha256"] = verified["report_sha256"]
      return Authorization.authorizeAction(
        envelope: envelope, request: request, ledgerRecords: [], policyOverlay: [:],
        liveRepository: [:], selectedWriter: "codex", verifiedHealthAttestation: verified,
        context: context
      ).filter { $0.hasPrefix("live health") }
    }
    XCTAssertEqual(try healthErrors(approved: "degraded", live: "healthy"), [])
    XCTAssertEqual(
      try healthErrors(approved: "healthy", live: "degraded"),
      ["live health status fell below the approved status"])
    XCTAssertEqual(
      try healthErrors(approved: "degraded", live: "healthy", profile: "runtime_ui"),
      ["live health identity drifted from authorization"])
  }

  func testLaterRepositoryRejectionRevokesTheConfirmationForItsScope() throws {
    let envelope = try currentApprovedEnvelope()
    let repository = envelope["repository"] as! [String: Any]
    let scope = "\(repository["fingerprint"]!):\(repository["branch"]!):\(repository["remote"]!)"
    let grant = (envelope["action_grants"] as! [[String: Any]]).first {
      $0["action"] as? String == "git.push"
    }!
    var request: [String: Any] = [:]
    for field in Authorization.requestFields { request[field] = grant[field] ?? NSNull() }
    let currentContext = context
    func confirmationErrors(_ decisions: [(scope: String, decision: String)]) -> [String] {
      let records = decisions.enumerated().map { index, approval in
        record(
          index + 1, "approval",
          [
            "approval_id": "repository-\(index)", "kind": "repository", "actor": "user",
            "decision": approval.decision, "scope": approval.scope,
          ], at: "2026-01-01T00:00:0\(index)Z")
      }
      return Authorization.authorizeAction(
        envelope: envelope, request: request, ledgerRecords: records, policyOverlay: [:],
        liveRepository: [:], selectedWriter: "codex", verifiedHealthAttestation: nil,
        context: currentContext
      ).filter { $0.contains("repository confirmation") }
    }
    XCTAssertEqual(confirmationErrors([(scope, "approved")]), [])
    XCTAssertEqual(confirmationErrors([(scope, "approved"), (scope + "-other", "rejected")]), [])
    XCTAssertEqual(
      confirmationErrors([(scope, "approved"), (scope, "rejected")]),
      ["repository confirmation was revoked by a later rejection"])
    // A declined request may still be confirmed later, but a revoked confirmation stays revoked
    // for the run: confirming again needs a new authorization.
    XCTAssertEqual(confirmationErrors([(scope, "rejected"), (scope, "approved")]), [])
    XCTAssertEqual(
      confirmationErrors([(scope, "approved"), (scope, "rejected"), (scope, "approved")]),
      ["git commit or push requires one exact prior repository confirmation"])
  }

  func testDirectIssueTargetsStayOnTheBoundIssueOrDeriveFromTheCreatedIssue() throws {
    let bound = try currentApprovedEnvelope()
    let original = bound["action_grants"] as! [[String: Any]]
    let key = original[0]["resource_key"]!
    let branch = (bound["repository"] as! [String: Any])["branch"] as! String
    let body = ["body_sha256": String(repeating: "e", count: 64)]
    func comment(target: String? = nil, derivedFrom source: String? = nil) throws -> [String: Any] {
      var grant: [String: Any] = [
        "grant_id": "grant-comment", "idempotency_key": "comment-key", "system": "github",
        "action": "github.issue.comment", "operation": "publish_exact_issue_comment",
        "operation_input": body, "constraint_sha256": try Authorization.canonicalSHA256(body),
        "resource_key": key, "phase": "pr_delivery", "single_use": true,
      ]
      grant["target"] = target
      grant["target_from_grant_id"] = source
      return grant
    }
    let targetErrors = { (envelope: [String: Any]) in
      Authorization.validateAuthorization(envelope, context: self.context).filter {
        $0.contains("Issue grant must bind")
      }
    }
    let misbound = [
      "Issue grant must bind a known exact Issue or a derived target: github.issue.comment"
    ]

    var existing = bound
    existing["action_grants"] = original + [try comment(target: "example/repository:issue:1")]
    XCTAssertEqual(targetErrors(existing), [])
    existing["action_grants"] = original + [try comment(target: "example/repository:issue:2")]
    XCTAssertEqual(targetErrors(existing), misbound)

    // A new feature Issue has no number until its create grant succeeds.
    var feature = bound
    var github = feature["github"] as! [String: Any]
    github["issue_number"] = NSNull()
    feature["github"] = github
    let input = ["title_policy": "accepted_plan", "body_policy": "accepted_plan"]
    var grants = original.filter { $0["action"] as? String != "github.issue.update" }
    grants.append([
      "grant_id": "grant-issue-create", "idempotency_key": "issue-create-key", "system": "github",
      "action": "github.issue.create", "operation": "ensure_feature_issue",
      "operation_input": input, "constraint_sha256": try Authorization.canonicalSHA256(input),
      "resource_key": key, "phase": "pr_delivery", "single_use": true,
      "target": "example/repository:feature:\(branch)", "produces_target_kind": "github_issue",
    ])
    for update in original
    where update["action"] as? String == "github.issue.update"
      && update["operation"] as? String != "transition_issue_ready"
    {
      var derived = update
      derived.removeValue(forKey: "target")
      derived["target_from_grant_id"] = "grant-issue-create"
      grants.append(derived)
    }
    feature["action_grants"] = grants + [try comment(derivedFrom: "grant-issue-create")]
    XCTAssertEqual(Authorization.validateAuthorization(feature, context: context), [])
    for target in ["example/repository:issue:7", "other-owner/other-repository:issue:7"] {
      feature["action_grants"] = grants + [try comment(target: target)]
      XCTAssertEqual(targetErrors(feature), misbound, target)
    }
  }

  func testLedgerRecordsSplitOnlyOnLineFeedBytes() throws {
    let ledger = try temporaryDirectory().appendingPathComponent("ledger.jsonl")
    // JSON permits these separators raw inside a string, and serializers do not escape them.
    let summary = "keep\u{2028}verification\u{2029}minimal\u{0085}and risk-derived"
    func line(_ sequence: Int) -> String {
      #"{"schema_version":"1.0.0","run_id":"run","sequence":"# + "\(sequence)"
        + #","recorded_at":"2026-01-01T00:00:01Z","record_type":"feedback","payload":{"summary":""#
        + summary + #""}}"#
    }
    try Data((line(1) + "\n" + line(2) + "\n").utf8).write(to: ledger)
    let records = try Authorization.loadLedger(ledger)
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual((records[1]["payload"] as? [String: Any])?["summary"] as? String, summary)

    try Data((line(1) + "\u{2028}" + line(2) + "\n").utf8).write(to: ledger)
    XCTAssertThrowsError(try Authorization.loadLedger(ledger))
  }

  // MARK: - A reserved pr_ready run with a live coordinator lease

  private final class TestClock {
    var now = Date()
  }

  private struct ReservedRun {
    let root: URL
    let ledger: URL
    let state: URL
    let harness: URL
    let request: URL
    let attestation: [String: Any]
    let errors: [String]
    let reservation: [String: Any]?
  }

  /// Initializes a real ledger and coordinator for the approved fixture, takes the GitHub
  /// mutation lease, and reserves the Ready transition. The executable-identity binding check
  /// is skipped because tests run inside `xctest`, not the bound `apple-verify`.
  private func reservedRun(
    leaseSeconds: Int = 300, leaseStampOffset: TimeInterval = 0, stopBeforeLease: Bool = false
  ) throws -> ReservedRun {
    let root = try temporaryDirectory().resolvingSymlinksInPath()
    let action = "github.issue.update"
    let envelope = try currentApprovedEnvelope()
    let runID = envelope["run_id"] as! String
    let digest = Authorization.authorizationHash(envelope)
    let repository = envelope["repository"] as! [String: Any]
    let authorizationURL = root.appendingPathComponent("authorization.json")
    let overlayURL = root.appendingPathComponent("policy.json")
    let harnessURL = root.appendingPathComponent("harness.json")
    let ledger = root.appendingPathComponent("ledger.jsonl")
    let state = root.appendingPathComponent("coordinator.json")
    try HarnessRuntime.atomicWriteJSON(envelope, to: authorizationURL)
    let overlay: [String: Any] = [
      "schema_version": "1.0.0", "decision": "approved", "github": ["owner": "example"],
      "apple": NSNull(),
    ]
    try HarnessRuntime.atomicWriteJSON(overlay, to: overlayURL)
    let start = Date().addingTimeInterval(-5)
    let approval = try InitializeRun.approvalRecord(
      authorization: envelope, recordedAt: start, context: context)
    try (HarnessRuntime.canonicalJSON(approval) + Data([0x0a])).write(to: ledger)

    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    var harness = try HarnessRuntime.object(
      context.harnessRoot.appendingPathComponent("templates/harness-local.json"))
    harness["authoritative_root"] = root.path
    harness["private_policy_overlay"] = overlayURL.path
    harness["run_authorization"] = authorizationURL.path
    harness["run_ledger"] = ledger.path
    harness["delivery_target"] = "pr_ready"
    harness["health_profile"] = "pr_ready"
    harness["github_tracking"] = ["issues": true, "project": NSNull()]
    harness["local_requirements"] = NSNull()
    try HarnessRuntime.atomicWriteJSON(harness, to: harnessURL)
    let trustedHarness = try ResourceCoordinator.loadTrustedHarness(
      harnessPath: harnessURL, context: context)
    let (_, authority) = try ResourceCoordinator.loadExistingRunAuthority(
      authorizationPath: authorizationURL, harnessPath: harnessURL, harness: trustedHarness,
      runID: runID, context: context)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: runID, runAuthority: authority)

    let descriptor = try ResourceCoordinator.normalizeDescriptor(
      resource: "github_external_mutation",
      descriptor: try Authorization.canonicalResourceDescriptor(envelope, action: action))
    let receipt = try ResourceCoordinator.acquire(
      statePath: state, resource: "github_external_mutation", descriptor: descriptor,
      ownerRunID: runID, ownerActor: "codex", ttlSeconds: leaseSeconds,
      now: start.addingTimeInterval(2), runAuthority: authority)
    var sequence = 1
    func appendRecord(_ type: String, _ payload: [String: Any], at date: Date) throws {
      sequence += 1
      let line = record(sequence, type, payload, at: HarnessRuntime.timestamp(date), runID: runID)
      try appendLine(line, to: ledger)
    }
    try appendRecord(
      "time_interval",
      [
        "authorization_hash": digest, "kind": "active",
        "started_at": HarnessRuntime.timestamp(start),
        "ended_at": HarnessRuntime.timestamp(start.addingTimeInterval(1)), "reason": "implement",
      ], at: start.addingTimeInterval(1))
    if stopBeforeLease {
      try appendRecord(
        "stop", ["reason": "user cancelled the run", "outcome": "cancelled"],
        at: start.addingTimeInterval(2))
    }
    try appendRecord(
      "lease",
      [
        "lease_id": receipt["lease_id"]!, "action": "acquire", "owner": "codex",
        "resource": "github_external_mutation", "resource_key": receipt["resource_key"]!,
        "resource_descriptor": descriptor, "coordinator_receipt": receipt,
        "branch": repository["branch"]!, "base_sha": repository["base_sha"]!,
        "pre_state_hash": "sha256:" + String(repeating: "0", count: 64),
        "allowed_paths": ["Sources"], "allowed_actions": [action],
        "approval_id": envelope["authorization_id"]!, "acquired_at": receipt["acquired_at"]!,
        "expires_at": receipt["expires_at"]!,
      ], at: Date().addingTimeInterval(leaseStampOffset))

    let health: [String: Any] = ["fixture": "live health report"]
    try HarnessRuntime.atomicWriteJSON(receipt, to: root.appendingPathComponent("receipt.json"))
    try HarnessRuntime.atomicWriteJSON(
      descriptor, to: root.appendingPathComponent("descriptor.json"))
    try HarnessRuntime.atomicWriteJSON(health, to: root.appendingPathComponent("health.json"))
    let requestURL = root.appendingPathComponent("request.json")
    let grant = (envelope["action_grants"] as! [[String: Any]]).first {
      $0["operation"] as? String == "transition_issue_ready"
    }!
    _ = try PrepareActionRequest.prepare(
      authorizationPath: authorizationURL,
      receiptPath: root.appendingPathComponent("receipt.json"),
      descriptorPath: root.appendingPathComponent("descriptor.json"),
      healthReportPath: root.appendingPathComponent("health.json"), outputPath: requestURL,
      runRoot: root, grantID: grant["grant_id"] as! String, target: grant["target"] as! String,
      paths: ["Sources"], context: context)
    let request = try XCTUnwrap(
      try Authorization.loadStablePrivateJSON(requestURL, root: root) as? [String: Any])
    var attestation = envelope["health_attestation"] as! [String: Any]
    attestation["report_sha256"] = request["health_report_sha256"]!
    attestation["observed_at"] = HarnessRuntime.timestamp()
    let reserved = Authorization.reserveBoundAction(
      ledgerPath: ledger, envelope: envelope, request: request, runRoot: root,
      policyOverlay: overlay, liveRepository: repository, liveSpecSnapshot: nil,
      liveAppleObservation: nil, coordinatorState: state, selectedWriter: "codex",
      trustedHarnessSHA256: try ResourceCoordinator.portableDocumentSHA256(trustedHarness),
      verifiedHealthAttestation: attestation, context: context)
    return ReservedRun(
      root: root, ledger: ledger, state: state, harness: harnessURL, request: requestURL,
      attestation: attestation, errors: reserved.errors,
      reservation: reserved.reservation)
  }

  /// Claims the run's reservation. `probes` stands in for the live health probes, which run
  /// before the ledger lock; the injected clock advances only as far as they move it.
  private func dispatch(
    _ run: ReservedRun, clock: TestClock, attestation: [String: Any]? = nil,
    probes: () -> Void
  ) -> (errors: [String], dispatch: [String: Any]?) {
    let reservationID =
      (run.reservation?["payload"] as? [String: Any])?["reservation_id"] as? String ?? ""
    return Authorization.verifyReservedAction(
      ledgerPath: run.ledger, reservationID: reservationID, runRoot: run.root,
      coordinatorState: run.state, harnessPath: run.harness, requestPath: run.request,
      context: context, clock: { clock.now },
      evaluateHealth: { _, _, _ in
        probes()
        return ([], attestation ?? run.attestation)
      })
  }

  private func append(_ run: ReservedRun, _ type: String, _ payload: [String: Any], at: String)
    throws
  {
    try HarnessRuntime.withFileLock(at: run.ledger) {
      let records = try Authorization.loadLedger(run.ledger)
      let sequence = (records.compactMap { $0["sequence"] as? Int }.max() ?? 0) + 1
      let runID = records.first?["run_id"] as? String ?? ""
      try appendLine(record(sequence, type, payload, at: at, runID: runID), to: run.ledger)
    }
  }

  private func appendLine(_ record: [String: Any], to ledger: URL) throws {
    let handle = try FileHandle(forWritingTo: ledger)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: try HarnessRuntime.canonicalJSON(record) + Data([0x0a]))
  }

  private func record(
    _ sequence: Int, _ type: String, _ payload: [String: Any], at: String, runID: String = "run"
  ) -> [String: Any] {
    [
      "schema_version": "1.0.0", "run_id": runID, "sequence": sequence, "recorded_at": at,
      "record_type": type, "payload": payload,
    ]
  }

  private func currentApprovedEnvelope() throws -> [String: Any] {
    var envelope = try HarnessRuntime.object(
      repositoryRoot.appendingPathComponent("tests/fixtures/run-authorization-approved.json"))
    let schema = repositoryRoot.appendingPathComponent(
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    return envelope
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
