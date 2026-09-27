import XCTest

@testable import AppleVerificationCore

/// A consumed grant must stay consumed after an in-place ledger rewrite, an approval must not
/// outlive a bounded window, schema `pattern` anchors follow ECMA-262 and a wrongly typed keyword
/// fails closed, and a Spec Kit CLI other than the pinned release is reported rather than
/// snapshotted as the pin.
final class LowRuntimeAuthorizationTests: XCTestCase {
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
  let truncated = "coordination_required: ledger was truncated or rewritten below its recorded head"

  // MARK: - Ledger continuity

  func testReservationRefusesALedgerTruncatedInPlaceOrStrippedOfItsHead() throws {
    let run = try preparedRun()
    let beforeReservation = try Data(contentsOf: run.ledger)
    XCTAssertEqual(try reserve(run, grant: "grant-issue-ready").errors, [])
    let reserved = try Data(contentsOf: run.ledger)

    // Truncating in place keeps the path, inode and approval line the coordinator binds.
    try rewriteInPlace(run.ledger, with: beforeReservation)
    let replay = try reserve(run, grant: "grant-issue-ready")
    XCTAssertNil(replay.reservation)
    XCTAssertEqual(replay.errors, [truncated])

    // Control: the intact ledger keeps authorizing its remaining grants.
    try rewriteInPlace(run.ledger, with: reserved)
    XCTAssertEqual(try reserve(run, grant: "grant-issue-progress").errors, [])

    try FileManager.default.removeItem(atPath: run.ledger.path + ".head.json")
    XCTAssertEqual(
      try reserve(run, grant: "grant-issue-review").errors,
      ["coordination_required: ledger head checkpoint is missing or unreadable"])
  }

  func testDispatchRefusesToClaimAReservationAgainAfterAnInPlaceTruncation() throws {
    let run = try preparedRun()
    let reserved = try reserve(run, grant: "grant-issue-ready")
    XCTAssertEqual(reserved.errors, [])
    let reservationID = try XCTUnwrap(
      (reserved.reservation?["payload"] as? [String: Any])?["reservation_id"] as? String)
    let beforeClaim = try Data(contentsOf: run.ledger)
    XCTAssertEqual(dispatch(run, reservationID: reservationID).errors, [])

    try rewriteInPlace(run.ledger, with: beforeClaim)
    let replay = dispatch(run, reservationID: reservationID)
    XCTAssertNil(replay.dispatch)
    XCTAssertEqual(replay.errors, [truncated])
  }

  func testLedgerCheckRejectsASequenceGapLeftByARemovedRecord() throws {
    let records = try Authorization.loadLedger(
      context.harnessRoot.appendingPathComponent("contracts/example-ledger.jsonl"))
    XCTAssertEqual(Authorization.ledgerContractErrors(records, context: context), [])
    var removed = records
    removed.remove(at: 2)
    XCTAssertEqual(
      Authorization.ledgerContractErrors(removed, context: context),
      ["ledger sequence skips a record before line 3"])
  }

  // MARK: - Authorization bounds

  func testAuthorizationWindowAndLimitsHaveUpperBounds() throws {
    let schema = try HarnessRuntime.object(
      context.harnessRoot.appendingPathComponent("contracts/schemas/run-authorization.schema.json"))
    var envelope = try approvedEnvelope(issuedAt: Date())
    let issued = try HarnessRuntime.parseTimestamp(envelope["issued_at"] as! String)
    envelope["expires_at"] = HarnessRuntime.timestamp(issued.addingTimeInterval(24 * 60 * 60))
    XCTAssertEqual(Authorization.validateAuthorization(envelope, context: context), [])
    envelope["expires_at"] = HarnessRuntime.timestamp(issued.addingTimeInterval(24 * 60 * 60 + 1))
    XCTAssertEqual(
      Authorization.validateAuthorization(envelope, context: context),
      ["authorization expiry exceeds the 24-hour maximum approval window"])

    envelope["expires_at"] = HarnessRuntime.timestamp(issued.addingTimeInterval(60 * 60))
    let invalidLimits = "authorization attempt and time limits are invalid"
    for (key, maximum) in [
      ("max_implementation_attempts", 10), ("max_review_cycles", 10),
      ("max_transient_retries", 10), ("active_wall_minutes", 1_440),
      ("async_wait_minutes", 1_440),
    ] {
      var limits = envelope["limits"] as! [String: Any]
      limits[key] = maximum
      var bounded = envelope
      bounded["limits"] = limits
      XCTAssertEqual(Authorization.schemaErrors(instance: bounded, schema: schema), [], key)
      XCTAssertFalse(
        Authorization.validateAuthorization(bounded, context: context).contains(invalidLimits),
        key)
      limits[key] = maximum + 1
      bounded["limits"] = limits
      XCTAssertEqual(
        Authorization.schemaErrors(instance: bounded, schema: schema),
        ["$.limits.\(key): violates maximum"], key)
      XCTAssertTrue(
        Authorization.validateAuthorization(bounded, context: context).contains(invalidLimits),
        key)
    }
  }

  // MARK: - Schema pattern anchors

  func testSchemaPatternDollarMatchesOnlyAtTheEndOfInput() {
    func accepts(_ pattern: String, _ value: String) -> Bool {
      JSONSchemaValidator.errors(instance: value, schema: ["pattern": pattern]).isEmpty
    }
    let digest = "sha256:" + String(repeating: "a", count: 64)
    XCTAssertTrue(accepts(#"^sha256:[0-9a-f]{64}$"#, digest))
    XCTAssertFalse(accepts(#"^sha256:[0-9a-f]{64}$"#, digest + "\n"))
    // The harness path pattern forbids control characters; a final newline is one.
    XCTAssertFalse(accepts(#"^/[^\u0000-\u001f\u007f]*$"#, "/private/run\n"))
    // Inside a group `$` is still the end of input.
    XCTAssertTrue(accepts(#"^specs(?:/|$)"#, "specs"))
    XCTAssertFalse(accepts(#"^specs(?:/|$)"#, "specs\n"))
    // An escaped `$` or one in a character class stays a literal dollar sign.
    XCTAssertTrue(accepts(#"^a\$[$]$"#, "a$$"))
    XCTAssertFalse(accepts(#"^a\$[$]$"#, "a$$\n"))
  }

  func testSchemaKeywordValueOfTheWrongTypeFailsClosed() {
    XCTAssertEqual(
      JSONSchemaValidator.errors(instance: [String: Any](), schema: ["required": "name"]),
      ["$: invalid schema keyword value required"])
    XCTAssertEqual(
      JSONSchemaValidator.errors(instance: [Any](), schema: ["minItems": "1"]),
      ["$: invalid schema keyword value minItems"])
    XCTAssertEqual(
      JSONSchemaValidator.errors(instance: "x\n", schema: ["pattern": 1]),
      ["$: invalid schema keyword value pattern"])
  }

  // MARK: - Spec Kit CLI release

  func testSpecSnapshotReportsAnInstalledCLIOtherThanThePinnedRelease() throws {
    let root = try temporaryDirectory()
    let feature = root.appendingPathComponent("specs/001-example")
    try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".specify"), withIntermediateDirectories: true)
    try Data(#"{"feature_directory":"specs/001-example"}"#.utf8).write(
      to: root.appendingPathComponent(".specify/feature.json"))
    for name in ["spec.md", "plan.md", "tasks.md"] {
      try Data("# \(name)\n".utf8).write(to: feature.appendingPathComponent(name))
    }
    func snapshot(specifyPrints output: String?) throws -> ProcessResult {
      let bin = try temporaryDirectory()
      if let output {
        let script = bin.appendingPathComponent("specify")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(output)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: script.path)
      }
      let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("apple-verify")
      return try HarnessRuntime.run(
        executable: executable.path,
        arguments: [
          "--repository-root", repositoryRoot.path, "spec-snapshot", "snapshot", "--root",
          root.path, "--feature-directory", "specs/001-example",
        ], environment: ["PATH": bin.path + ":/usr/bin:/bin"], timeout: 30)
    }

    let newer = try snapshot(specifyPrints: "specify 1.1.0")
    XCTAssertEqual(newer.exitCode, 2, newer.stdout)
    XCTAssertTrue(newer.stderr.contains("reports 1.1.0"), newer.stderr)
    XCTAssertTrue(newer.stderr.contains("migration candidate"), newer.stderr)
    let unrecognized = try snapshot(specifyPrints: "Usage: specify [OPTIONS] COMMAND [ARGS]...")
    XCTAssertEqual(unrecognized.exitCode, 2, unrecognized.stdout)

    let pinned = try snapshot(specifyPrints: "specify 1.0.1")
    XCTAssertEqual(pinned.exitCode, 0, pinned.stderr)
    let object = try JSONSerialization.jsonObject(with: Data(pinned.stdout.utf8)) as? [String: Any]
    XCTAssertEqual(object?["spec_kit_release"] as? String, "v1.0.1")
    let absent = try snapshot(specifyPrints: nil)
    XCTAssertEqual(absent.exitCode, 0, absent.stderr)
    XCTAssertTrue(absent.stderr.contains("unverified"), absent.stderr)
  }

  // MARK: - A registered pr_ready run holding the GitHub mutation lease

  private struct PreparedRun {
    let root: URL
    let ledger: URL
    let state: URL
    let harness: URL
    let envelope: [String: Any]
    let overlay: [String: Any]
    let trustedHarnessSHA256: String
  }

  /// The approved fixture bound to the installed schema, its window moved to contain `issuedAt`.
  private func approvedEnvelope(issuedAt: Date) throws -> [String: Any] {
    var envelope = try HarnessRuntime.object(
      repositoryRoot.appendingPathComponent("tests/fixtures/run-authorization-approved.json"))
    let schema = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    return approvalWindow(of: envelope, containing: issuedAt)
  }

  /// Initializes a real ledger and coordinator, registers the run, and records the GitHub
  /// mutation lease that every `github.issue.update` grant of the fixture uses.
  private func preparedRun() throws -> PreparedRun {
    let root = try temporaryDirectory().resolvingSymlinksInPath()
    let start = Date().addingTimeInterval(-5)
    let envelope = try approvedEnvelope(issuedAt: start)
    let runID = envelope["run_id"] as! String
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
    let approval = try InitializeRun.approvalRecord(
      authorization: envelope, recordedAt: start, context: context)
    try GateRunSupport.writeApprovalLedger(approval, to: ledger, runRoot: root)

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

    let action = "github.issue.update"
    let descriptor = try ResourceCoordinator.normalizeDescriptor(
      resource: "github_external_mutation",
      descriptor: try Authorization.canonicalResourceDescriptor(envelope, action: action))
    let receipt = try ResourceCoordinator.acquire(
      statePath: state, resource: "github_external_mutation", descriptor: descriptor,
      ownerRunID: runID, ownerActor: "codex", ttlSeconds: 300, now: start.addingTimeInterval(2),
      runAuthority: authority)
    let digest = Authorization.authorizationHash(envelope)
    for (sequence, type, payload) in [
      (
        2, "time_interval",
        [
          "authorization_hash": digest, "kind": "active",
          "started_at": HarnessRuntime.timestamp(start),
          "ended_at": HarnessRuntime.timestamp(start.addingTimeInterval(1)), "reason": "implement",
        ] as [String: Any]
      ),
      (
        3, "lease",
        [
          "lease_id": receipt["lease_id"]!, "action": "acquire", "owner": "codex",
          "resource": "github_external_mutation", "resource_key": receipt["resource_key"]!,
          "resource_descriptor": descriptor, "coordinator_receipt": receipt,
          "branch": repository["branch"]!, "base_sha": repository["base_sha"]!,
          "pre_state_hash": "sha256:" + String(repeating: "0", count: 64),
          "allowed_paths": ["Sources"], "allowed_actions": [action],
          "approval_id": envelope["authorization_id"]!, "acquired_at": receipt["acquired_at"]!,
          "expires_at": receipt["expires_at"]!,
        ]
      ),
    ] {
      let record: [String: Any] = [
        "schema_version": "1.0.0", "run_id": runID, "sequence": sequence,
        "recorded_at": HarnessRuntime.timestamp(start.addingTimeInterval(Double(sequence))),
        "record_type": type, "payload": payload,
      ]
      let handle = try FileHandle(forWritingTo: ledger)
      try handle.seekToEnd()
      try handle.write(contentsOf: try HarnessRuntime.canonicalJSON(record) + Data([0x0a]))
      try handle.close()
    }
    try HarnessRuntime.atomicWriteJSON(receipt, to: root.appendingPathComponent("receipt.json"))
    try HarnessRuntime.atomicWriteJSON(
      descriptor, to: root.appendingPathComponent("descriptor.json"))
    try HarnessRuntime.atomicWriteJSON(
      ["fixture": "live health report"], to: root.appendingPathComponent("health.json"))
    return PreparedRun(
      root: root, ledger: ledger, state: state, harness: harnessURL, envelope: envelope,
      overlay: overlay,
      trustedHarnessSHA256: try ResourceCoordinator.portableDocumentSHA256(trustedHarness))
  }

  /// Prepares the grant's request as `request.json` and reserves it. The executable-identity
  /// binding check is skipped because tests run inside `xctest`, not the bound `apple-verify`.
  private func reserve(_ run: PreparedRun, grant grantID: String) throws -> (
    errors: [String], reservation: [String: Any]?
  ) {
    let grant = (run.envelope["action_grants"] as! [[String: Any]]).first {
      $0["grant_id"] as? String == grantID
    }!
    let requestURL = run.root.appendingPathComponent("request.json")
    try? FileManager.default.removeItem(at: requestURL)
    _ = try PrepareActionRequest.prepare(
      authorizationPath: run.root.appendingPathComponent("authorization.json"),
      receiptPath: run.root.appendingPathComponent("receipt.json"),
      descriptorPath: run.root.appendingPathComponent("descriptor.json"),
      healthReportPath: run.root.appendingPathComponent("health.json"), outputPath: requestURL,
      runRoot: run.root, grantID: grantID, target: grant["target"] as! String,
      paths: ["Sources"], context: context)
    let request = try XCTUnwrap(
      try Authorization.loadStablePrivateJSON(requestURL, root: run.root) as? [String: Any])
    return Authorization.reserveBoundAction(
      ledgerPath: run.ledger, envelope: run.envelope, request: request, runRoot: run.root,
      policyOverlay: run.overlay, liveRepository: run.envelope["repository"] as! [String: Any],
      liveSpecSnapshot: nil, liveAppleObservation: nil, coordinatorState: run.state,
      selectedWriter: "codex", trustedHarnessSHA256: run.trustedHarnessSHA256,
      verifiedHealthAttestation: try attestation(run, request: request), context: context)
  }

  /// Claims a reservation of the request last prepared, with the live health probes stubbed.
  private func dispatch(_ run: PreparedRun, reservationID: String) -> (
    errors: [String], dispatch: [String: Any]?
  ) {
    let requestURL = run.root.appendingPathComponent("request.json")
    return Authorization.verifyReservedAction(
      ledgerPath: run.ledger, reservationID: reservationID, runRoot: run.root,
      coordinatorState: run.state, harnessPath: run.harness, requestPath: requestURL,
      context: context, clock: { Date() },
      evaluateHealth: { _, _, _ in
        guard
          let request = try? Authorization.loadStablePrivateJSON(requestURL, root: run.root)
            as? [String: Any],
          let attestation = try? self.attestation(run, request: request)
        else { return (["test request is unavailable"], nil) }
        return ([], attestation)
      })
  }

  private func attestation(_ run: PreparedRun, request: [String: Any]) throws -> [String: Any] {
    var attestation = run.envelope["health_attestation"] as! [String: Any]
    attestation["report_sha256"] = request["health_report_sha256"]!
    attestation["observed_at"] = HarnessRuntime.timestamp()
    return attestation
  }

  /// Replaces the file's bytes through its existing inode, as `truncate`, an `r+` rewrite or
  /// `cat copy > ledger` would.
  private func rewriteInPlace(_ url: URL, with data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}

extension XCTestCase {
  /// The approved fixture's window is a fixed day in the past. A test that initializes or
  /// registers a run on its own clock moves that window, and the health observation that must
  /// precede issuance by at most five minutes, to a one-hour window containing `now`.
  func approvalWindow(of envelope: [String: Any], containing now: Date) -> [String: Any] {
    var envelope = envelope
    let issued = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) - 60)
    envelope["issued_at"] = HarnessRuntime.timestamp(issued)
    envelope["expires_at"] = HarnessRuntime.timestamp(issued.addingTimeInterval(60 * 60))
    var health = envelope["health_attestation"] as! [String: Any]
    health["observed_at"] = HarnessRuntime.timestamp(issued.addingTimeInterval(-30))
    envelope["health_attestation"] = health
    return envelope
  }
}
