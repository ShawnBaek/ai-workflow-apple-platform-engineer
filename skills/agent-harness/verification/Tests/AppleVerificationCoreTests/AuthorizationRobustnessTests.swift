import XCTest

@testable import AppleVerificationCore

/// Authority must not outlive what was approved: a terminal stop, a later rejection, a lease that
/// expired during slow probes, a health drop, or an Issue target outside the bound repository.
/// The ledger must keep valid records readable and in time order.
final class AuthorizationRobustnessTests: XCTestCase {
  var context: RuntimeContext { GateRunSupport.context }

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
        try GateRunSupport.append(
          "node", ["node_id": "mark_issue_in_review", "status": "pending"], to: run.ledger,
          at: aheadStamp)
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
      var envelope = try GateRunSupport.approvedEnvelope()
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
    let envelope = try GateRunSupport.approvedEnvelope()
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
        GateRunSupport.record(
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
    let bound = try GateRunSupport.approvedEnvelope()
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
    let ledger = try GateRunSupport.temporaryDirectory(for: self).appendingPathComponent(
      "ledger.jsonl")
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
    let root = try GateRunSupport.temporaryDirectory(for: self)
    let action = "github.issue.update"
    let envelope = try GateRunSupport.approvedEnvelope()
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
    let harness = GateRunSupport.prReadyHarness(
      try HarnessRuntime.object(
        context.harnessRoot.appendingPathComponent("templates/harness-local.json")),
      checkout: root, policy: overlayURL, authorization: authorizationURL, ledger: ledger)
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
    func appendRecord(_ type: String, _ payload: [String: Any], at date: Date) throws {
      try GateRunSupport.append(type, payload, to: ledger, at: HarnessRuntime.timestamp(date))
    }
    try appendRecord(
      "time_interval", GateRunSupport.activeInterval(authorizationHash: digest, startingAt: start),
      at: start.addingTimeInterval(1))
    if stopBeforeLease {
      try appendRecord(
        "stop", ["reason": "user cancelled the run", "outcome": "cancelled"],
        at: start.addingTimeInterval(2))
    }
    try appendRecord(
      "lease",
      try GateRunSupport.leaseAcquisition(
        receipt: receipt, descriptor: descriptor, envelope: envelope, action: action),
      at: Date().addingTimeInterval(leaseStampOffset))

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
    let attestation = try GateRunSupport.liveAttestation(envelope: envelope, request: request)
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
}
