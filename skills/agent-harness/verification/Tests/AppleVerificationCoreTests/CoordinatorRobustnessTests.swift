import Darwin
import XCTest

@testable import AppleVerificationCore

final class CoordinatorRobustnessTests: XCTestCase {
  private var repository: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
  }

  private var context: RuntimeContext {
    RuntimeContext(
      repositoryRoot: repository,
      harnessRoot: repository.appendingPathComponent("skills/agent-harness"))
  }

  /// The product beside this test bundle, never an arbitrary older build.
  private var executable: URL {
    Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("apple-verify").resolvingSymlinksInPath()
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func cli(
    _ arguments: [String], repositoryRoot: URL? = nil, in directory: URL? = nil
  ) throws -> (code: Int32, response: [String: Any]) {
    let result = try HarnessRuntime.run(
      executable: executable.path,
      arguments: ["--repository-root", (repositoryRoot ?? repository).path] + arguments,
      directory: directory, timeout: 30)
    let response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
      result.stdout + result.stderr)
    return (result.exitCode, response)
  }

  private func authority(_ now: Date) -> [String: Any] {
    [
      "authorization_hash": "sha256:" + String(repeating: "a", count: 64),
      "selected_writer": "codex", "harness_sha256": "sha256:" + String(repeating: "b", count: 64),
      "authorization_issued_at": HarnessRuntime.timestamp(now.addingTimeInterval(-60)),
      "authorization_expires_at": HarnessRuntime.timestamp(now.addingTimeInterval(600)),
      "ledger_path": "/tmp/synthetic-ledger",
      "ledger_identity_sha256": "sha256:" + String(repeating: "c", count: 64),
      "ledger_approval_sha256": "sha256:" + String(repeating: "d", count: 64),
    ]
  }

  private struct PrivateRun {
    let root: URL
    let state: URL
    let harness: URL
    let authorization: URL
    let ledger: URL
    var initializeArguments: [String] {
      [
        "initialize-run", "--authorization", authorization.path, "--ledger", ledger.path,
        "--run-root", root.path, "--harness", harness.path, "--coordinator-state", state.path,
      ]
    }
  }

  /// A bootstrapped coordinator plus a run root whose harness is bound to the built CLI.
  private func privateRun() throws -> PrivateRun {
    let base = try temporaryRoot()
    let root = base.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let state = base.appendingPathComponent("coordinator.json")
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    let authorization = root.appendingPathComponent("authorization.json")
    let harness = root.appendingPathComponent("harness.json")
    let ledger = root.appendingPathComponent("ledger.jsonl")
    var envelope = try HarnessRuntime.object(
      repository.appendingPathComponent("tests/fixtures/run-authorization-approved.json"))
    let schema = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    envelope = approvalWindow(of: envelope, containing: Date())
    try HarnessRuntime.atomicWriteJSON(envelope, to: authorization)
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
    try HarnessRuntime.atomicWriteJSON(document, to: harness)
    return PrivateRun(
      root: root, state: state, harness: harness, authorization: authorization, ledger: ledger)
  }

  // MARK: CoreSimulator runtime probe lease

  private final class InventoryRunner: HealthProbeRunning {
    private(set) var timeouts: [TimeInterval] = []
    func run(
      executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
      timeout: TimeInterval, maxOutputBytes: Int
    ) -> ProcessResult {
      timeouts.append(timeout)
      let stdout =
        arguments.contains("runtimes")
        ? #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","platform":"iOS","isAvailable":true}]}"#
        : #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"DEVICE-1","isAvailable":true}]}}"#
      return .init(stdout: stdout, stderr: "", exitCode: 0, timedOut: false, truncated: false)
    }
  }

  private final class RecordingCoordinator: RuntimeRegistryCoordinating {
    private(set) var admissions = 0
    let releaseFailure: ResourceCoordinatorError?
    init(releaseFailure: ResourceCoordinatorError? = nil) { self.releaseFailure = releaseFailure }
    func withRuntimeRegistryAdmission<T>(
      scope: RuntimeProbeScope, body: ([String: Any]) throws -> T
    ) throws -> T {
      admissions += 1
      let value = try body(["lease_id": "fixture-lease"])
      if let releaseFailure { throw releaseFailure }
      return value
    }
  }

  private func probeScope(ttlSeconds: Int) -> RuntimeProbeScope {
    RuntimeProbeScope(
      statePath: URL(fileURLWithPath: "/fixture/coordinator.json"),
      descriptor: [
        "coordinator_instance_id": "fixture-coordinator", "registry_scope": "runtime_inventory",
        "platform": "iOS", "destination_id": "DEVICE-1",
        "runtime_identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
      ],
      ownerRunID: "run-1", ownerActor: "codex", ttlSeconds: ttlSeconds,
      runAuthority: ["approval_id": "approval-1"])
  }

  private func runtimeObservation(
    ttlSeconds: Int, coordinator: RecordingCoordinator, runner: InventoryRunner = InventoryRunner()
  ) -> [String: Any]? {
    HealthEvaluation.collectLiveObservations(
      report: ["required_check_ids": ["simulator.runtime"]], harness: [:], policy: [:],
      authorization: nil, runner: runner, runtimeCoordinator: coordinator,
      runtimeScope: probeScope(ttlSeconds: ttlSeconds))["simulator.runtime"]
  }

  func testRuntimeProbeRefusesALeaseThatCannotOutliveItsInventoryCommands() {
    // The schema allows any TTL from 1 s, but both inventory commands may use their full timeout.
    let runner = InventoryRunner()
    let short = RecordingCoordinator()
    let refused = runtimeObservation(
      ttlSeconds: HealthEvaluation.minimumRuntimeProbeTTLSeconds - 1, coordinator: short,
      runner: runner)
    XCTAssertEqual(refused?["status"] as? String, "blocked")
    XCTAssertEqual(refused?["reason_code"] as? String, "runtime_probe_lease_too_short_blocked")
    XCTAssertEqual(short.admissions, 0, "a lease that can expire mid-probe must not be acquired")
    XCTAssertTrue(runner.timeouts.isEmpty)

    let sufficient = RecordingCoordinator()
    let admitted = runtimeObservation(
      ttlSeconds: HealthEvaluation.minimumRuntimeProbeTTLSeconds, coordinator: sufficient,
      runner: runner)
    XCTAssertEqual(admitted?["status"] as? String, "healthy")
    XCTAssertEqual(sufficient.admissions, 1)
    XCTAssertLessThanOrEqual(
      runner.timeouts.reduce(0, +), TimeInterval(HealthEvaluation.minimumRuntimeProbeTTLSeconds))

    // A probe that passed but left its lease active is reported as that, not as a success or a
    // generic ownership failure, because the host stays blocked until the lease is recovered.
    let unreleased = runtimeObservation(
      ttlSeconds: 120,
      coordinator: RecordingCoordinator(
        releaseFailure: ResourceCoordinatorError(
          "runtime_registry_release_failed", "expired_requires_recover")))
    XCTAssertEqual(unreleased?["status"] as? String, "blocked")
    XCTAssertEqual(unreleased?["reason_code"] as? String, "runtime_registry_release_blocked")
  }

  func testRuntimeRegistryAdmissionReportsTheLeaseItCouldNotRelease() throws {
    let root = try temporaryRoot()
    let state = root.appendingPathComponent("coordinator.json")
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    let owner = authority(Date())
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "owner", runAuthority: owner)
    struct ProbeFailure: Error {}
    XCTAssertThrowsError(
      try ResourceCoordinator.withRuntimeRegistryAdmission(
        statePath: state,
        descriptor: [
          "coordinator_instance_id": boot["coordinator_instance_id"]!,
          "registry_scope": "runtime_inventory", "platform": "iOS", "destination_id": "DEVICE-1",
          "runtime_identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
        ],
        ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 1, runAuthority: owner
      ) { _ -> Void in
        // The probe outlives its lease and then fails, so the release is refused as expired.
        Thread.sleep(forTimeInterval: 1.2)
        throw ProbeFailure()
      }
    ) { error in
      let failure = error as? ResourceCoordinatorError
      XCTAssertEqual(failure?.code, "runtime_registry_release_failed", "\(error)")
      XCTAssertEqual(failure?.detail.hasPrefix("expired_requires_recover"), true, "\(error)")
    }
    // The lease stays active and conflicts with every destination claim until it is recovered.
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["active_lease_count"] as? Int, 1)
  }

  // MARK: CLI path and failure precision

  func testCLIPathArgumentsMustBeAbsoluteInsteadOfFollowingTheWorkingDirectory() throws {
    let caller = try temporaryRoot()
    let bootstrap = try cli(
      ["resources", "coordinator.json", "bootstrap", "--legacy-leases-quiesced"], in: caller)
    XCTAssertEqual(bootstrap.code, 2)
    XCTAssertEqual(bootstrap.response["reason_code"] as? String, "invalid_state_path")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: caller.path), [],
      "a relative state path must not create a second coordinator in the caller's directory")

    let run = try privateRun()
    let relativeHarness = try cli(
      ["resources", run.state.path, "verify", "--harness", "harness.json", "--receipt", "{}"],
      in: run.root)
    XCTAssertEqual(relativeHarness.response["reason_code"] as? String, "untrusted_binding")
    // Control: the absolute spelling passes the path guard and is refused later for the receipt.
    let absoluteHarness = try cli(
      ["resources", run.state.path, "verify", "--harness", run.harness.path, "--receipt", "{}"],
      in: run.root)
    XCTAssertEqual(absoluteHarness.response["reason_code"] as? String, "writer_mismatch")

    // Every other path is absolute and consistent, so only the run root's spelling is at stake.
    var relativeRoot = run.initializeArguments
    relativeRoot[try XCTUnwrap(relativeRoot.firstIndex(of: run.root.path))] = "."
    let relativeRun = try cli(relativeRoot, in: run.root)
    XCTAssertEqual(relativeRun.code, 2)
    XCTAssertEqual(relativeRun.response["status"] as? String, "blocked")
    XCTAssertTrue(
      (relativeRun.response["reason"] as? String)?.contains("absolute") == true,
      "\(relativeRun.response)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: run.ledger.path))
  }

  func testCLIReportsContentionIOAndHashFailuresWithTheirOwnCodes() throws {
    try XCTSkipIf(getuid() == 0, "permission denials do not apply to root")
    let root = try temporaryRoot()
    let state = root.appendingPathComponent("coordinator.json")
    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)

    // Another call holding the lock for the whole bounded wait is retryable contention.
    try HarnessRuntime.withFileLock(at: URL(fileURLWithPath: state.path + ".lock")) {
      let busy = try cli(["resources", state.path, "status"])
      XCTAssertEqual(busy.code, 2)
      XCTAssertEqual(busy.response["reason_code"] as? String, "coordinator_busy")
    }

    // A state directory that refuses the atomic replacement is a host I/O failure.
    XCTAssertEqual(chmod(root.path, 0o500), 0)
    defer { chmod(root.path, 0o700) }
    let policy =
      #"{"max_active_devices":1,"max_heavy_jobs":1,"max_internal_workers":1,"schema_version":"1.0.0"}"#
    let io = try cli(["resources", state.path, "configure-host-policy", "--policy", policy])
    XCTAssertEqual(chmod(root.path, 0o700), 0)
    XCTAssertEqual(io.code, 2)
    XCTAssertEqual(io.response["reason_code"] as? String, "io_error")

    // An installed contract file that cannot be hashed breaks the source binding.
    let installed = root.appendingPathComponent("installed")
    let contracts = installed.appendingPathComponent("skills/agent-harness/contracts")
    try FileManager.default.createDirectory(at: contracts, withIntermediateDirectories: true)
    let unreadable = contracts.appendingPathComponent("capabilities.json")
    try Data("{}".utf8).write(to: unreadable)
    XCTAssertEqual(chmod(unreadable.path, 0o000), 0)
    let hash = try cli(["resources", state.path, "bundle-digest"], repositoryRoot: installed)
    XCTAssertEqual(hash.code, 2)
    XCTAssertEqual(hash.response["reason_code"] as? String, "untrusted_binding")

    // Control: a malformed request keeps its own code.
    let malformed = try cli(
      ["resources", state.path, "configure-host-policy", "--policy", "{"])
    XCTAssertEqual(malformed.response["reason_code"] as? String, "invalid_request")
  }

  // MARK: Persisted lease times

  func testLeaseTimesAreComparedAsTheyArePersisted() throws {
    let root = try temporaryRoot()
    let state = root.appendingPathComponent("coordinator.json")
    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    let now = try HarnessRuntime.parseTimestamp("2026-09-06T00:00:00Z")
    let owner = authority(now)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "owner", runAuthority: owner, now: now)
    let receipt = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.sourceWriter,
      descriptor: [
        "identity_version": "github_remote_v2",
        "repository_fingerprint": "sha256:" + String(repeating: "e", count: 64),
      ],
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 10, now: now, runAuthority: owner)
    let stored = try XCTUnwrap(receipt["expires_at"] as? String)
    let expiry = try HarnessRuntime.parseTimestamp(stored)
    // Timestamps round to the nearest millisecond, so 0.4 ms either side prints as the expiry.
    XCTAssertEqual(HarnessRuntime.timestamp(expiry.addingTimeInterval(-0.0004)), stored)
    XCTAssertEqual(HarnessRuntime.timestamp(expiry.addingTimeInterval(0.0004)), stored)

    XCTAssertThrowsError(
      try ResourceCoordinator.heartbeat(
        statePath: state, receipt: receipt, ttlSeconds: 10, runAuthority: owner,
        now: expiry.addingTimeInterval(-10 + 0.0004))
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "heartbeat_must_extend") }

    XCTAssertThrowsError(
      try ResourceCoordinator.release(
        statePath: state, receipt: receipt, runAuthority: owner,
        now: expiry.addingTimeInterval(-0.0004))
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "expired_requires_recover") }
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["active_lease_count"] as? Int, 1,
      "a release persisted at its expiry makes the whole coordinator unloadable")

    let released = try ResourceCoordinator.release(
      statePath: state, receipt: receipt, runAuthority: owner,
      now: expiry.addingTimeInterval(-0.001))
    XCTAssertLessThan(
      try HarnessRuntime.parseTimestamp(try XCTUnwrap(released["released_at"] as? String)), expiry)
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["active_lease_count"] as? Int, 0)
  }

  // MARK: Run initialization

  func testInitializeRunKilledWhileCreatingItsLedgerCanBeRerun() throws {
    let run = try privateRun()
    // RLIMIT_FSIZE 0 makes the first byte written to a file raise SIGXFSZ, whose default action
    // terminates the process mid-creation (getrlimit(2), signal(3)); pipes are unaffected.
    let killed = try HarnessRuntime.run(
      executable: "/bin/sh",
      arguments: [
        "-c", #"ulimit -f 0; exec "$0" "$@""#, executable.path, "--repository-root",
        repository.path,
      ] + run.initializeArguments, timeout: 30)
    XCTAssertEqual(killed.exitCode, 128 + SIGXFSZ, killed.stdout + killed.stderr)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: run.ledger.path),
      "an interrupted creation must not leave a partial ledger behind")

    let rerun = try cli(run.initializeArguments)
    XCTAssertEqual(rerun.code, 0, "\(rerun.response)")
    XCTAssertEqual(rerun.response["created"] as? Bool, true)
    let lines = try String(contentsOf: run.ledger, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 1)

    // Control: once published, the ledger is adopted rather than created again.
    let adopted = try cli(run.initializeArguments)
    XCTAssertEqual(adopted.code, 0, "\(adopted.response)")
    XCTAssertEqual(adopted.response["created"] as? Bool, false)
  }

  // MARK: Contract validation

  func testTestFlightValidatorReportsADuplicateTerminalInsteadOfTrapping() throws {
    var workflow = try HarnessRuntime.object(
      repository.appendingPathComponent("skills/agent-harness/contracts/testflight-workflow.json"))
    var nodes = try XCTUnwrap(workflow["nodes"] as? [[String: Any]])
    let distributed = try XCTUnwrap(
      nodes.firstIndex { $0["terminal_for"] as? String == "testflight_distributed" })
    nodes[distributed]["terminal_for"] = "testflight_uploaded"
    workflow["nodes"] = nodes
    XCTAssertTrue(
      ContractValidation.validateTestFlightWorkflow(
        workflow, resources: Set(ContractValidation.resources)
      ).contains("TestFlight continuation terminals drifted"))
  }
}
