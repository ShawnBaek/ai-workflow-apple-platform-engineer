import XCTest

@testable import AppleVerificationCore

final class ExpiredLeaseTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let state: URL
    let now: Date
    let owner: [String: Any]
    let observer: [String: Any]
    let receipt: [String: Any]
    let otherReceipt: [String: Any]
  }

  private func authority(_ now: Date, actor: String = "codex") -> [String: Any] {
    [
      "authorization_hash": "sha256:" + String(repeating: "a", count: 64),
      "selected_writer": actor, "harness_sha256": "sha256:" + String(repeating: "b", count: 64),
      "authorization_issued_at": HarnessRuntime.timestamp(now.addingTimeInterval(-60)),
      "authorization_expires_at": HarnessRuntime.timestamp(now.addingTimeInterval(600)),
      "ledger_path": "/tmp/synthetic-ledger",
      "ledger_identity_sha256": "sha256:" + String(repeating: "c", count: 64),
      "ledger_approval_sha256": "sha256:" + String(repeating: "d", count: 64),
    ]
  }

  private func fixture(observerOffset: TimeInterval = 0) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("coordinator.json")
    let now = try HarnessRuntime.parseTimestamp("2026-09-06T00:00:00Z")
    let owner = authority(now)
    let observer = authority(now.addingTimeInterval(observerOffset), actor: "claude")
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "owner", runAuthority: owner, now: now)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "observer", runAuthority: observer,
      now: now.addingTimeInterval(observerOffset))
    let receipt = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.simulator,
      descriptor: [
        "coordinator_instance_id": boot["coordinator_instance_id"]!, "udids": ["synthetic-a"],
      ],
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 1, now: now, runAuthority: owner)
    let other = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.sourceWriter,
      descriptor: [
        "identity_version": "github_remote_v2",
        "repository_fingerprint": "sha256:" + String(repeating: "e", count: 64),
      ],
      ownerRunID: "observer", ownerActor: "claude", ttlSeconds: 60,
      now: now.addingTimeInterval(observerOffset), runAuthority: observer)
    return Fixture(
      root: root, state: state, now: now, owner: owner, observer: observer,
      receipt: receipt, otherReceipt: other)
  }

  private func evidence(_ f: Fixture, at: Date, completed: Bool = false) -> [String: Any] {
    let stamp = HarnessRuntime.timestamp(at)
    func observation(_ state: String) -> [String: Any] {
      [
        "state": state, "observed_at": stamp,
        "digest": "sha256:" + String(repeating: "1", count: 64),
      ]
    }
    return [
      "mode": "quiescent_release", "previous_receipt_id": f.receipt["receipt_id"]!,
      "previous_fencing_token": f.receipt["fencing_token"]!,
      "observer": [
        "observer_run_id": completed ? "observer" : "owner",
        "observer_actor": completed ? "claude" : "codex",
        "method": "bounded_read_only_host_probe", "observed_at": stamp,
      ],
      "owner_liveness": observation(completed ? "completed" : "quiescent"),
      "owner_tool_children": observation("quiescent"), "dirty_state": observation("preserved"),
      "live_resource_revalidation": [
        "passed": true, "observed_at": stamp,
        "digest": "sha256:" + String(repeating: "2", count: 64),
      ],
    ]
  }

  func testQuiescentReleaseRestoresCapacityWithoutRevivingReceiptOrChangingOtherLease() throws {
    let f = try fixture()
    let at = f.now.addingTimeInterval(2)
    let preservedFile = f.root.appendingPathComponent("Working.swift")
    let originalContent = Data("// legitimate uncommitted work\n".utf8)
    try originalContent.write(to: preservedFile)
    var proof = evidence(f, at: at)
    var dirty = proof["dirty_state"] as! [String: Any]
    dirty["digest"] = "sha256:" + (try HarnessRuntime.sha256File(preservedFile))
    proof["dirty_state"] = dirty
    let nextDescriptor: [String: Any] = [
      "coordinator_instance_id": f.receipt["coordinator_instance_id"]!, "udids": ["synthetic-b"],
    ]
    XCTAssertThrowsError(
      try ResourceCoordinator.acquire(
        statePath: f.state, resource: ResourceCoordinator.simulator, descriptor: nextDescriptor,
        ownerRunID: "observer", ownerActor: "claude", ttlSeconds: 10, now: at,
        runAuthority: f.observer)
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "capacity_exceeded") }
    let before = try Data(contentsOf: f.state)
    let preview = try ResourceCoordinator.recover(
      statePath: f.state, receipt: f.receipt, evidence: proof, runAuthority: f.owner,
      observerAuthority: f.owner, preview: true, now: at)
    XCTAssertEqual(try Data(contentsOf: f.state), before)
    XCTAssertEqual(preview["preview"] as? Bool, true)
    XCTAssertNil(preview["recovery_id"])
    XCTAssertEqual((preview["capacity_after"] as? [String: Int])?["active_devices"], 0)
    let confirmation = try ResourceCoordinator.recover(
      statePath: f.state, receipt: f.receipt, evidence: proof, runAuthority: f.owner,
      observerAuthority: f.owner, now: at)
    XCTAssertTrue(
      ResourceCoordinator.validateRecoveryConfirmation(
        receipt: f.receipt, evidence: proof, confirmation: confirmation, statePath: f.state))
    XCTAssertEqual(try Data(contentsOf: preservedFile), originalContent)
    XCTAssertThrowsError(
      try ResourceCoordinator.verify(statePath: f.state, receipt: f.receipt, now: at))
    XCTAssertThrowsError(
      try ResourceCoordinator.heartbeat(
        statePath: f.state, receipt: f.receipt, ttlSeconds: 10, runAuthority: f.owner, now: at))
    XCTAssertThrowsError(
      try ResourceCoordinator.recover(
        statePath: f.state, receipt: f.receipt, evidence: proof, runAuthority: f.owner,
        observerAuthority: f.owner, now: at))
    XCTAssertEqual(
      try ResourceCoordinator.verify(
        statePath: f.state, receipt: f.otherReceipt, now: at)["receipt_id"] as? String,
      f.otherReceipt["receipt_id"] as? String)
    let next = try ResourceCoordinator.acquire(
      statePath: f.state, resource: ResourceCoordinator.simulator, descriptor: nextDescriptor,
      ownerRunID: "observer", ownerActor: "claude", ttlSeconds: 10, now: at,
      runAuthority: f.observer)
    XCTAssertGreaterThan(
      try XCTUnwrap(next["fencing_token"] as? Int),
      try XCTUnwrap(confirmation["recovery_fencing_token"] as? Int))
  }

  func testExpiredOwnerAuthorityCanOnlyFinalizeAndActiveObserverCanFinalizeCompletedOwner() throws {
    for completed in [false, true] {
      let f = try fixture(observerOffset: 700)
      let at = f.now.addingTimeInterval(702)
      let proof = evidence(f, at: at, completed: completed)
      XCTAssertThrowsError(
        try ResourceCoordinator.verify(statePath: f.state, receipt: f.receipt, now: at))
      let result = try ResourceCoordinator.recover(
        statePath: f.state, receipt: f.receipt, evidence: proof, runAuthority: nil,
        observerAuthority: completed ? f.observer : f.owner, now: at)
      XCTAssertTrue(
        ResourceCoordinator.validateRecoveryConfirmation(
          receipt: f.receipt, evidence: proof, confirmation: result, statePath: f.state))
      XCTAssertEqual(
        try ResourceCoordinator.status(statePath: f.state)["active_lease_count"] as? Int, 1)
    }
  }

  func testQuiescentReleaseRejectsUnsafeOrUnboundEvidenceWithoutWriting() throws {
    let f = try fixture()
    let at = f.now.addingTimeInterval(2)
    let original = evidence(f, at: at)
    let cases: [(String, Any)] = [
      ("owner_tool_children", ["state": "running"]),
      ("owner_liveness", ["state": "running"]),
      ("owner_liveness", ["state": "completed"]),
      ("dirty_state", ["state": "incomplete"]),
      ("live_resource_revalidation", ["passed": false]),
      ("owner_tool_children", ["observed_at": HarnessRuntime.timestamp(f.now)]),
      ("owner_tool_children", ["observed_at": HarnessRuntime.timestamp(at.addingTimeInterval(1))]),
      ("previous_fencing_token", 999), ("previous_receipt_id", "other"),
      ("observer", ["observer_run_id": "unregistered"]),
      ("mode", "unknown"),
    ]
    let before = try Data(contentsOf: f.state)
    for (key, mutation) in cases {
      var changed = original
      if let delta = mutation as? [String: Any], var value = changed[key] as? [String: Any] {
        value.merge(delta) { _, new in new }
        changed[key] = value
      } else {
        changed[key] = mutation
      }
      XCTAssertThrowsError(
        try ResourceCoordinator.recover(
          statePath: f.state, receipt: f.receipt, evidence: changed, runAuthority: f.owner,
          observerAuthority: f.owner, now: at), key)
      XCTAssertEqual(try Data(contentsOf: f.state), before)
    }
    XCTAssertThrowsError(
      try ResourceCoordinator.recover(
        statePath: f.state, receipt: f.receipt, evidence: original, runAuthority: f.owner,
        observerAuthority: f.observer, now: at))
    var otherObserver = original
    var observation = otherObserver["observer"] as! [String: Any]
    observation["observer_run_id"] = "observer"
    observation["observer_actor"] = "claude"
    otherObserver["observer"] = observation
    XCTAssertThrowsError(
      try ResourceCoordinator.recover(
        statePath: f.state, receipt: f.receipt, evidence: otherObserver, runAuthority: nil,
        observerAuthority: f.observer, now: at)
    ) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "invalid_recovery_evidence")
    }
    XCTAssertThrowsError(
      try ResourceCoordinator.recover(
        statePath: f.state, receipt: f.receipt, evidence: original, runAuthority: f.owner,
        observerAuthority: f.owner, replacement: [:], now: at)
    ) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "quiescent_release_cannot_replace")
    }
    XCTAssertThrowsError(
      try ResourceCoordinator.recover(
        statePath: f.state, receipt: f.receipt, evidence: original, runAuthority: f.owner,
        observerAuthority: f.owner, now: f.now)
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "recovery_not_yet_allowed") }
    XCTAssertEqual(try Data(contentsOf: f.state), before)
  }

  func testRecoveryLedgerAcceptsTerminalExpiryButRejectsForgedConfirmation() throws {
    let f = try fixture()
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { repository.deleteLastPathComponent() }
    let context = RuntimeContext(
      repositoryRoot: repository,
      harnessRoot: repository.appendingPathComponent("skills/agent-harness"))
    var envelope = try HarnessRuntime.object(
      repository.appendingPathComponent(
        "tests/fixtures/run-authorization-approved.json"))
    envelope["run_id"] = "owner"
    let schema = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    let approval = try InitializeRun.approvalRecord(
      authorization: envelope, recordedAt: f.now, context: context)
    let repo = envelope["repository"] as! [String: Any]
    let descriptor: [String: Any] = [
      "repository_fingerprint": repo["fingerprint"]!, "remote_repository": "example/repository",
    ]
    let receipt = try ResourceCoordinator.acquire(
      statePath: f.state, resource: ResourceCoordinator.github, descriptor: descriptor,
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 1, now: f.now, runAuthority: f.owner)
    let at = f.now.addingTimeInterval(2)
    var proof = evidence(f, at: at)
    proof["previous_receipt_id"] = receipt["receipt_id"]!
    proof["previous_fencing_token"] = receipt["fencing_token"]!
    let confirmation = try ResourceCoordinator.recover(
      statePath: f.state, receipt: receipt, evidence: proof, runAuthority: f.owner,
      observerAuthority: f.owner, now: at)
    let common: [String: Any] = [
      "lease_id": receipt["lease_id"]!, "owner": "codex", "resource": ResourceCoordinator.github,
      "resource_key": receipt["resource_key"]!, "resource_descriptor": descriptor,
      "coordinator_receipt": receipt,
    ]
    var acquire = common
    acquire.merge([
      "action": "acquire", "branch": repo["branch"]!, "base_sha": repo["base_sha"]!,
      "pre_state_hash": "sha256:" + String(repeating: "f", count: 64),
      "allowed_paths": envelope["allowed_paths"]!, "allowed_actions": ["github.issue.update"],
      "approval_id": envelope["authorization_id"]!, "acquired_at": receipt["acquired_at"]!,
      "expires_at": receipt["expires_at"]!,
    ]) { _, new in new }
    var release = common
    release.merge([
      "action": "release", "released_at": confirmation["recovered_at"]!,
      "post_state_hash": "sha256:" + String(repeating: "f", count: 64),
      "recovery_evidence": proof, "recovery_confirmation": confirmation,
    ]) { _, new in new }
    func record(_ payload: [String: Any], sequence: Int, at: Date) -> [String: Any] {
      [
        "schema_version": "1.0.0", "run_id": "owner", "sequence": sequence,
        "record_type": "lease", "recorded_at": HarnessRuntime.timestamp(at), "payload": payload,
      ]
    }
    let records = [
      approval, record(acquire, sequence: 2, at: f.now), record(release, sequence: 3, at: at),
    ]
    XCTAssertEqual(
      Authorization.ledgerContractErrors(records, coordinatorState: f.state, context: context), [])
    XCTAssertTrue(Authorization.activeLeases(records, coordinatorState: f.state).leases.isEmpty)
    let premature = [approval, records[1], record(release, sequence: 3, at: f.now)]
    XCTAssertTrue(
      Authorization.ledgerContractErrors(premature, coordinatorState: f.state, context: context)
        .contains { $0.contains("precedes coordinator transition") })
    var wrongTime = release
    wrongTime["released_at"] = HarnessRuntime.timestamp(at.addingTimeInterval(1))
    let mismatched = [
      approval, records[1], record(wrongTime, sequence: 3, at: at.addingTimeInterval(1)),
    ]
    XCTAssertTrue(
      Authorization.ledgerContractErrors(mismatched, coordinatorState: f.state, context: context)
        .contains { $0.contains("valid coordinator recovery evidence") })
    var forged = confirmation
    forged["recovery_fencing_token"] = 999
    release["recovery_confirmation"] = forged
    let invalid = [approval, records[1], record(release, sequence: 3, at: at)]
    XCTAssertTrue(
      Authorization.ledgerContractErrors(invalid, coordinatorState: f.state, context: context)
        .contains { $0.contains("valid coordinator recovery evidence") })

    // Reconcile a lost release response later, using its actual persisted time.
    let later = f.now.addingTimeInterval(3)
    let next = try ResourceCoordinator.acquire(
      statePath: f.state, resource: ResourceCoordinator.github, descriptor: descriptor,
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 2, now: later, runAuthority: f.owner)
    let normal = try ResourceCoordinator.release(
      statePath: f.state, receipt: next, runAuthority: f.owner, now: later.addingTimeInterval(1))
    var nextAcquire = acquire
    nextAcquire["lease_id"] = next["lease_id"]!
    nextAcquire["coordinator_receipt"] = next
    nextAcquire["acquired_at"] = next["acquired_at"]!
    nextAcquire["expires_at"] = next["expires_at"]!
    var nextRelease = common
    nextRelease["lease_id"] = next["lease_id"]!
    nextRelease["coordinator_receipt"] = next
    nextRelease["action"] = "release"
    nextRelease["released_at"] = normal["released_at"]!
    nextRelease["post_state_hash"] = "sha256:" + String(repeating: "f", count: 64)
    nextRelease["coordinator_release_confirmation"] = normal
    let delayed =
      records + [
        record(nextAcquire, sequence: 4, at: later),
        record(nextRelease, sequence: 5, at: later.addingTimeInterval(5)),
      ]
    XCTAssertEqual(
      Authorization.ledgerContractErrors(delayed, coordinatorState: f.state, context: context), [])
    let expiredAcquire =
      records + [record(nextAcquire, sequence: 4, at: later.addingTimeInterval(5))]
    XCTAssertTrue(
      Authorization.ledgerContractErrors(
        expiredAcquire, coordinatorState: f.state, context: context
      )
      .contains { $0.contains("lease coordinator receipt is expired") })
  }

  func testCLIObserverPreviewsAndFinalizesWithoutArchivedOwnerHarness() throws {
    let f = try fixture()
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { repository.deleteLastPathComponent() }
    let context = RuntimeContext(
      repositoryRoot: repository,
      harnessRoot: repository.appendingPathComponent("skills/agent-harness"))
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("apple-verify").resolvingSymlinksInPath()
    let callerRoot = f.root.appendingPathComponent("observer").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: callerRoot, withIntermediateDirectories: true)
    let authPath = callerRoot.appendingPathComponent("authorization.json")
    let harnessPath = callerRoot.appendingPathComponent("harness.json")
    let ledgerPath = callerRoot.appendingPathComponent("ledger.jsonl")
    var envelope = try HarnessRuntime.object(
      repository.appendingPathComponent(
        "tests/fixtures/run-authorization-approved.json"))
    envelope["run_id"] = "cli-observer"
    envelope["selected_writer"] = "claude"
    let schema = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    try HarnessRuntime.atomicWriteJSON(envelope, to: authPath)
    let approval = try InitializeRun.approvalRecord(
      authorization: envelope, recordedAt: Date(), context: context)
    try (HarnessRuntime.canonicalJSON(approval) + Data([0x0a])).write(to: ledgerPath)
    var harness = try HarnessRuntime.object(
      context.harnessRoot.appendingPathComponent("templates/harness-local.json"))
    harness["mode"] = "claude"
    harness["selected_writer"] = "claude"
    var skills = harness["agent_skills"] as! [String: Any]
    skills["installations"] = [
      "codex": NSNull(),
      "claude": ["collection_root": context.harnessRoot.deletingLastPathComponent().path],
    ]
    harness["agent_skills"] = skills
    harness["authoritative_root"] = f.root.path
    harness["private_policy_overlay"] = callerRoot.appendingPathComponent("policy.json").path
    harness["run_authorization"] = authPath.path
    harness["run_ledger"] = ledgerPath.path
    harness["resource_coordinator"] = [
      "runtime_kind": "swift", "runtime_contract": ResourceCoordinator.runtimeContract,
      "state_path": f.state.path, "coordinator_instance_id": f.receipt["coordinator_instance_id"]!,
      "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
      "source_bundle_sha256": try ResourceCoordinator.sourceBundleSHA256(
        skillRoot: context.harnessRoot),
    ]
    try HarnessRuntime.atomicWriteJSON(harness, to: harnessPath)
    let (_, callerAuthority) = try ResourceCoordinator.loadExistingRunAuthority(
      authorizationPath: authPath, harnessPath: harnessPath, harness: harness,
      runID: "cli-observer", context: context)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: f.state, runID: "cli-observer", runAuthority: callerAuthority)
    var proof = evidence(f, at: Date(), completed: true)
    var observer = proof["observer"] as! [String: Any]
    observer["observer_run_id"] = "cli-observer"
    proof["observer"] = observer
    let arguments = [
      "--repository-root", repository.path, "resources", f.state.path, "recover",
      "--harness", harnessPath.path,
      "--receipt", String(decoding: try HarnessRuntime.canonicalJSON(f.receipt), as: UTF8.self),
      "--evidence", String(decoding: try HarnessRuntime.canonicalJSON(proof), as: UTF8.self),
    ]
    let before = try Data(contentsOf: f.state)
    let preview = try HarnessRuntime.run(
      executable: executable.path, arguments: arguments + ["--preview"], timeout: 10)
    XCTAssertEqual(preview.exitCode, 0, preview.stdout + preview.stderr)
    XCTAssertEqual(try Data(contentsOf: f.state), before)
    let result = try HarnessRuntime.run(
      executable: executable.path, arguments: arguments, timeout: 10)
    XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
    let wrapper = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let confirmation = try XCTUnwrap(wrapper["result"] as? [String: Any])
    XCTAssertTrue(
      ResourceCoordinator.validateRecoveryConfirmation(
        receipt: f.receipt, evidence: proof, confirmation: confirmation, statePath: f.state))
  }

  func testQuiescentCleanupStillRequiresDependentBuildToFinishFirst() throws {
    let f = try fixture()
    let fingerprint = "sha256:" + String(repeating: "f", count: 64)
    let container = f.root.appendingPathComponent("Fixture.xcodeproj").path
    let source = try ResourceCoordinator.acquire(
      statePath: f.state, resource: ResourceCoordinator.sourceWriter,
      descriptor: ["identity_version": "github_remote_v2", "repository_fingerprint": fingerprint],
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 1, now: f.now, runAuthority: f.owner)
    let project = try ResourceCoordinator.acquire(
      statePath: f.state, resource: ResourceCoordinator.xcodeProject,
      descriptor: ["repository_fingerprint": fingerprint, "container_path": container],
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 1, now: f.now, runAuthority: f.owner)
    let roles = Dictionary(
      uniqueKeysWithValues: [
        "derived_data", "source_packages", "repository_checkouts", "artifacts", "package_cache",
      ]
      .map { ($0, f.root.appendingPathComponent($0).path) })
    let build = try ResourceCoordinator.acquire(
      statePath: f.state, resource: ResourceCoordinator.buildTuple,
      descriptor: [
        "repository_fingerprint": fingerprint, "container_path": container,
        "xcode_build": "fixture", "sdk": "iphonesimulator", "scheme": "Fixture",
        "configuration": "Debug", "architecture": "arm64", "package_fingerprint": fingerprint,
        "cache_paths": roles.values.sorted(), "cache_roles": roles, "output_paths": [String](),
        "output_roles": [String: String](), "package_resolution_mode": "xcode_project_packages",
      ],
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 1, now: f.now, runAuthority: f.owner)
    let at = f.now.addingTimeInterval(2)
    func finalize(_ receipt: [String: Any]) throws {
      var proof = evidence(f, at: at)
      proof["previous_receipt_id"] = receipt["receipt_id"]!
      proof["previous_fencing_token"] = receipt["fencing_token"]!
      _ = try ResourceCoordinator.recover(
        statePath: f.state, receipt: receipt, evidence: proof, runAuthority: f.owner,
        observerAuthority: f.owner, now: at)
    }
    for parent in [source, project] {
      XCTAssertThrowsError(try finalize(parent)) {
        XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "dependent_lease_active")
      }
    }
    try finalize(build)
    try finalize(project)
    try finalize(source)
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: f.state)["active_lease_count"] as? Int, 2)
  }
}
