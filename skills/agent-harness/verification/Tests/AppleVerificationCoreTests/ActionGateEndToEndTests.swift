import Darwin
import XCTest

@testable import AppleVerificationCore

/// The guarded action gate as one path: a private run root whose policy, authorization and
/// harness are materialized by the built `apple-verify`, `initialize-run`, a coordinator lease,
/// `prepare-action`, then the reservation `authorize` makes and the claim `verify-reservation`
/// makes, for one grant.
///
/// The harness binds the built CLI, which authenticates itself against that binding and the live
/// coordinator in every CLI step here. Reservation and claim run in-process through the entry
/// points the runtime keeps for tests, which skip only that binding check (this process is not the
/// bound binary) and take the live health result as input: a fixed attestation for the exact
/// report digest the request binds. The Git observation, coordinator state, run authority and
/// ledger are real.
final class ActionGateEndToEndTests: XCTestCase {
  private let repositoryRoot = GateRunSupport.repositoryRoot
  private var context: RuntimeContext { GateRunSupport.context }

  /// The product beside this test bundle, never an arbitrary older build.
  private var cli: AppleVerifyCLI {
    AppleVerifyCLI(
      executable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("apple-verify").resolvingSymlinksInPath(),
      repositoryRoot: repositoryRoot)
  }

  func testOneGrantIsReservedAndDispatchedExactlyOnce() throws {
    let run = try makeRun()
    // An approver may write any RFC 3339 instant; the registered authority stores the canonical
    // stamp, so the gate must compare instants rather than text.
    let issued = try XCTUnwrap(run.envelope["issued_at"] as? String)
    XCTAssertNotEqual(issued, HarnessRuntime.timestamp(try HarnessRuntime.parseTimestamp(issued)))

    let reserved = try run.reserve("grant-issue-progress")
    XCTAssertEqual(reserved.errors, [])
    let reservationID = try XCTUnwrap(reserved.reservationID)
    let dispatched = try run.dispatch("grant-issue-progress", reservationID: reservationID)
    XCTAssertEqual(dispatched.errors, [])
    let dispatch = try XCTUnwrap(dispatched.dispatch)
    XCTAssertEqual(dispatch["reservation_id"] as? String, reservationID)
    XCTAssertEqual(dispatch["grant_id"] as? String, "grant-issue-progress")
    XCTAssertEqual(dispatch["action"] as? String, "github.issue.update")
    XCTAssertEqual(dispatch["target"] as? String, "example/repository:issue:1")
    XCTAssertTrue(
      JSONSchemaValidator.equal(dispatch["coordinator_receipt"] as Any, run.receipt),
      "\(dispatch)")
    let deadline = try HarnessRuntime.parseTimestamp(
      try XCTUnwrap(dispatch["dispatch_deadline"] as? String))
    let leaseExpiry = try HarnessRuntime.parseTimestamp(
      try XCTUnwrap(run.receipt["expires_at"] as? String))
    XCTAssertLessThanOrEqual(deadline, leaseExpiry)

    // Single use: neither the grant nor its claimed reservation authorizes a second call.
    XCTAssertTrue(
      try run.reserve("grant-issue-progress").errors.contains(
        "single-use action grant was already reserved or consumed in the ledger"))
    XCTAssertEqual(
      try run.dispatch("grant-issue-progress", reservationID: reservationID).errors,
      ["protected dispatch reservation is already claimed"])

    let records = try Authorization.loadLedger(run.ledger)
    XCTAssertEqual(
      records.map { $0["record_type"] as? String },
      ["approval", "time_interval", "lease", "grant_reservation", "grant_dispatch"])
    XCTAssertEqual(
      Authorization.ledgerContractErrors(records, coordinatorState: run.state, context: context), []
    )
  }

  func testDispatchAfterTheApprovedWindowClosesIsRefused() throws {
    let run = try makeRun()
    let reservationID = try XCTUnwrap(try run.reserve("grant-issue-progress").reservationID)
    let expiry = try HarnessRuntime.parseTimestamp(
      try XCTUnwrap(run.envelope["expires_at"] as? String))

    let late = try run.dispatch(
      "grant-issue-progress", reservationID: reservationID, at: expiry.addingTimeInterval(1))
    XCTAssertNil(late.dispatch)
    XCTAssertEqual(late.errors, ["dispatch authorization is outside its active interval"])

    // Control: the refusal claimed nothing, and inside the window the same reservation passes.
    XCTAssertEqual(
      try run.dispatch("grant-issue-progress", reservationID: reservationID).errors, [])
  }

  func testHarnessEditedAfterInitializationDriftsTheRunAuthority() throws {
    let run = try makeRun()
    let reservationID = try XCTUnwrap(try run.reserve("grant-issue-progress").reservationID)
    // The registered authority binds the harness digest from initialize-run, so any later edit
    // of the private harness, however small, is a different authority.
    let original = try HarnessRuntime.object(run.harness)
    var edited = original
    edited["platforms"] = ["ios", "macos"]
    try HarnessRuntime.atomicWriteJSON(edited, to: run.harness)

    let dispatch = try run.dispatch("grant-issue-progress", reservationID: reservationID)
    XCTAssertNil(dispatch.dispatch)
    XCTAssertEqual(dispatch.errors, ["coordination_required: dispatch run authority drifted"])
    let reservation = try run.reserve("grant-issue-ready")
    XCTAssertNil(reservation.reservationID)
    XCTAssertEqual(
      reservation.errors, ["coordination_required: run authority drifted or is unregistered"])

    // Control: restoring the exact harness restores the authority.
    try HarnessRuntime.atomicWriteJSON(original, to: run.harness)
    XCTAssertEqual(
      try run.dispatch("grant-issue-progress", reservationID: reservationID).errors, [])
  }

  func testActionWithoutItsLeaseIsRefusedAtReservationAndDispatch() throws {
    // The coordinator granted the lease, but the ledger never recorded it.
    let run = try makeRun(recordLease: false)
    let unrecorded = try run.reserve("grant-issue-progress")
    XCTAssertNil(unrecorded.reservationID)
    XCTAssertEqual(
      unrecorded.errors, ["action request does not own the exact active ledger lease"])

    try run.recordLease()
    let reservationID = try XCTUnwrap(try run.reserve("grant-issue-progress").reservationID)
    // The coordinator lease is released after the reservation and before dispatch.
    _ = try cli([
      "resources", run.state.path, "release", "--harness", run.harness.path, "--receipt",
      String(decoding: try HarnessRuntime.canonicalJSON(run.receipt), as: UTF8.self),
    ])
    let released = try run.dispatch("grant-issue-progress", reservationID: reservationID)
    XCTAssertNil(released.dispatch)
    XCTAssertEqual(released.errors, ["coordination_required: stale_receipt"])
    XCTAssertFalse(
      try Authorization.loadLedger(run.ledger).contains {
        $0["record_type"] as? String == "grant_dispatch"
      })
  }

  // MARK: - A private run initialized through the built runtime

  private struct AppleVerifyCLI {
    let executable: URL
    let repositoryRoot: URL

    /// Runs one command that must succeed and returns its JSON response.
    func callAsFunction(_ arguments: [String]) throws -> [String: Any] {
      let result = try HarnessRuntime.run(
        executable: executable.path,
        arguments: ["--repository-root", repositoryRoot.path] + arguments, timeout: 30)
      XCTAssertEqual(
        result.exitCode, 0, "\(arguments.prefix(3)): \(result.stdout)\(result.stderr)")
      return try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
        result.stdout + result.stderr)
    }
  }

  private struct GateRun {
    let cli: AppleVerifyCLI
    let context: RuntimeContext
    let checkout: URL
    let root: URL
    let state: URL
    let harness: URL
    let authorization: URL
    let policy: URL
    let ledger: URL
    let envelope: [String: Any]
    let receipt: [String: Any]

    /// What `authorize` does after its health evaluation: re-observe the checkout and reserve the
    /// grant's prepared request against the live coordinator and ledger.
    func reserve(_ grantID: String) throws -> (errors: [String], reservationID: String?) {
      let request = try privateObject(try requestURL(grantID))
      let trusted = try ResourceCoordinator.loadTrustedHarness(
        harnessPath: harness, context: context)
      let envelope = try privateObject(authorization)
      let result = Authorization.reserveBoundAction(
        ledgerPath: ledger, envelope: envelope, request: request, runRoot: root,
        policyOverlay: try privateObject(policy),
        liveRepository: try Authorization.observeRepository(
          checkout,
          expectedBaseSHA: try XCTUnwrap(
            (envelope["repository"] as? [String: Any])?["base_sha"] as? String)),
        liveSpecSnapshot: nil, liveAppleObservation: nil, coordinatorState: state,
        selectedWriter: trusted["selected_writer"] as? String,
        trustedHarnessSHA256: try ResourceCoordinator.portableDocumentSHA256(trusted),
        verifiedHealthAttestation: try health(for: request), context: context)
      let payload = result.reservation?["payload"] as? [String: Any]
      return (result.errors, payload?["reservation_id"] as? String)
    }

    /// What `verify-reservation` does: claim the reservation after the live health probes, with
    /// every authority, lease and deadline judged at the clock read after them.
    func dispatch(_ grantID: String, reservationID: String, at time: Date? = nil) throws -> (
      errors: [String], dispatch: [String: Any]?
    ) {
      let requestURL = try requestURL(grantID)
      let attestation = try health(for: try privateObject(requestURL))
      return Authorization.verifyReservedAction(
        ledgerPath: ledger, reservationID: reservationID, runRoot: root, coordinatorState: state,
        harnessPath: harness, requestPath: requestURL, context: context,
        clock: { time ?? Date() }, evaluateHealth: { _, _, _ in ([], attestation) })
    }

    /// The writer's ledger record of the coordinator lease it acquired.
    func recordLease() throws {
      try GateRunSupport.append(
        "lease",
        try GateRunSupport.leaseAcquisition(
          receipt: receipt,
          descriptor: try privateObject(root.appendingPathComponent("descriptor.json")),
          envelope: envelope, action: "github.issue.update"), to: ledger)
    }

    /// `prepare-action` for the grant, once; later calls reuse the exact request file.
    private func requestURL(_ grantID: String) throws -> URL {
      let output = root.appendingPathComponent("request-\(grantID).json")
      guard !FileManager.default.fileExists(atPath: output.path) else { return output }
      let grant = try XCTUnwrap(
        (envelope["action_grants"] as? [[String: Any]])?.first {
          $0["grant_id"] as? String == grantID
        })
      _ = try cli([
        "prepare-action", "--authorization", authorization.path, "--grant-id", grantID,
        "--receipt", root.appendingPathComponent("receipt.json").path,
        "--resource-descriptor", root.appendingPathComponent("descriptor.json").path,
        "--health-report", root.appendingPathComponent("health.json").path,
        "--target", try XCTUnwrap(grant["target"] as? String), "--path", "Sources",
        "--output", output.path, "--run-root", root.path,
      ])
      return output
    }

    private func health(for request: [String: Any]) throws -> [String: Any] {
      try GateRunSupport.liveAttestation(envelope: envelope, request: request)
    }

    private func privateObject(_ url: URL) throws -> [String: Any] {
      try XCTUnwrap(try Authorization.loadStablePrivateJSON(url, root: root) as? [String: Any])
    }
  }

  /// Follows the documented setup: bootstrap, materialize and populate the private files, bind
  /// the harness to the observed runtime identity, initialize the run, and acquire the GitHub
  /// mutation lease.
  private func makeRun(recordLease: Bool = true) throws -> GateRun {
    let base = try GateRunSupport.temporaryDirectory(for: self)
    let checkout = base.appendingPathComponent("checkout")
    let root = base.appendingPathComponent("run")
    let state = base.appendingPathComponent("coordinator.json")
    for directory in [checkout, root] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    XCTAssertEqual(chmod(root.path, 0o700), 0)
    let baseSHA = try commitCheckout(checkout)
    let boot = try XCTUnwrap(
      try cli(["resources", state.path, "bootstrap", "--legacy-leases-quiesced"])["result"]
        as? [String: Any])
    let identity = try cli(["runtime-identity"])
    let templates = context.harnessRoot.appendingPathComponent("templates")
    let schemas = context.harnessRoot.appendingPathComponent("contracts/schemas")
    func materialize(_ template: URL, _ schema: String, to output: URL, replace: Bool = false)
      throws
    {
      _ = try cli(
        [
          "materialize", "--template", template.path, "--schema",
          schemas.appendingPathComponent(schema).path, "--output", output.path,
        ] + (replace ? ["--replace"] : []))
    }

    let policy = root.appendingPathComponent("policy.json")
    try materialize(
      templates.appendingPathComponent("private-policy-overlay.json"),
      "private-policy-overlay.schema.json", to: policy)
    var overlay = try HarnessRuntime.object(policy)
    overlay["github"] = ["owner": "example"]
    try HarnessRuntime.atomicWriteJSON(overlay, to: policy)

    // The approved fixture, bound to the live checkout, with its window and health observation
    // written as whole-second "Z" instants rather than the runtime's canonical stamp.
    let authorization = root.appendingPathComponent("authorization.json")
    var envelope = try GateRunSupport.approvedEnvelope()
    var repository = try XCTUnwrap(envelope["repository"] as? [String: Any])
    repository["canonical_root"] = checkout.path
    repository["base_sha"] = baseSHA
    envelope["repository"] = repository
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let wholeSeconds = ISO8601DateFormatter()
    var health = try XCTUnwrap(envelope["health_attestation"] as? [String: Any])
    health["observed_at"] = wholeSeconds.string(from: now.addingTimeInterval(-90))
    envelope["health_attestation"] = health
    envelope["issued_at"] = wholeSeconds.string(from: now.addingTimeInterval(-60))
    envelope["expires_at"] = wholeSeconds.string(from: now.addingTimeInterval(900))
    try HarnessRuntime.atomicWriteJSON(envelope, to: authorization)
    try materialize(
      authorization, "run-authorization.schema.json", to: authorization, replace: true)
    envelope = try HarnessRuntime.object(authorization)

    let harness = root.appendingPathComponent("harness.json")
    let ledger = root.appendingPathComponent("ledger.jsonl")
    try materialize(
      templates.appendingPathComponent("harness-local.json"), "harness.schema.json", to: harness)
    var document = GateRunSupport.prReadyHarness(
      try HarnessRuntime.object(harness), checkout: checkout, policy: policy,
      authorization: authorization, ledger: ledger)
    document["authorization_runtime"] = identity
    document["resource_coordinator"] = [
      "runtime_kind": ResourceCoordinator.runtimeKind,
      "runtime_contract": ResourceCoordinator.runtimeContract, "state_path": state.path,
      "coordinator_instance_id": boot["coordinator_instance_id"]!,
      "executable_sha256": identity["executable_sha256"]!,
      "source_bundle_sha256": identity["source_bundle_sha256"]!,
    ]
    try HarnessRuntime.atomicWriteJSON(document, to: harness)

    let initialized = try cli([
      "initialize-run", "--authorization", authorization.path, "--ledger", ledger.path,
      "--run-root", root.path, "--harness", harness.path, "--coordinator-state", state.path,
    ])
    XCTAssertEqual(initialized["created"] as? Bool, true, "\(initialized)")
    XCTAssertEqual(initialized["registered"] as? Bool, true, "\(initialized)")

    let runID = try XCTUnwrap(envelope["run_id"] as? String)
    let descriptor = try Authorization.canonicalResourceDescriptor(
      envelope, action: "github.issue.update")
    let receipt = try XCTUnwrap(
      try cli([
        "resources", state.path, "acquire", "--harness", harness.path, "--authorization",
        authorization.path, "--resource", ResourceCoordinator.github, "--descriptor",
        String(decoding: try HarnessRuntime.canonicalJSON(descriptor), as: UTF8.self),
        "--run-id", runID, "--actor", "codex", "--ttl-seconds", "300",
      ])["result"] as? [String: Any])
    try HarnessRuntime.atomicWriteJSON(receipt, to: root.appendingPathComponent("receipt.json"))
    try HarnessRuntime.atomicWriteJSON(
      try ResourceCoordinator.normalizeDescriptor(
        resource: ResourceCoordinator.github, descriptor: descriptor),
      to: root.appendingPathComponent("descriptor.json"))
    try HarnessRuntime.atomicWriteJSON(
      ["fixture": "live health report"], to: root.appendingPathComponent("health.json"))

    let run = GateRun(
      cli: cli, context: context, checkout: checkout, root: root, state: state, harness: harness,
      authorization: authorization, policy: policy, ledger: ledger, envelope: envelope,
      receipt: receipt)
    let approvedAt = try HarnessRuntime.parseTimestamp(
      try XCTUnwrap(try Authorization.loadLedger(ledger).first?["recorded_at"] as? String))
    try GateRunSupport.append(
      "time_interval",
      GateRunSupport.activeInterval(
        authorizationHash: Authorization.authorizationHash(envelope), startingAt: approvedAt),
      to: ledger)
    if recordLease { try run.recordLease() }
    return run
  }

  private func commitCheckout(_ checkout: URL) throws -> String {
    func git(_ arguments: [String]) throws -> String {
      let result = try HarnessRuntime.run(
        executable: "/usr/bin/git",
        arguments: [
          "-C", checkout.path, "-c", "user.name=Gate Test", "-c", "user.email=gate@example.com",
          "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
        ] + arguments, timeout: 15)
      XCTAssertEqual(result.exitCode, 0, "\(arguments): \(result.stderr)")
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try git(["init", "-q", "-b", "codex/fixture-branch"])
    _ = try git(["remote", "add", "origin", "https://github.com/example/repository.git"])
    let sources = checkout.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
    try Data("struct App {}\n".utf8).write(to: sources.appendingPathComponent("App.swift"))
    _ = try git(["add", "Sources/App.swift"])
    _ = try git(["commit", "-q", "-m", "base"])
    return try git(["rev-parse", "HEAD"])
  }
}
