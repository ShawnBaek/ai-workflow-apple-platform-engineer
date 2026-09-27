import XCTest

@testable import AppleVerificationCore

final class RuntimeStateAndProbeScopeTests: XCTestCase {
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

  private func cli(_ arguments: [String]) throws -> (code: Int32, response: [String: Any]) {
    let result = try HarnessRuntime.run(
      executable: executable.path, arguments: ["--repository-root", repository.path] + arguments,
      timeout: 30)
    let response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
      result.stdout + result.stderr)
    return (result.exitCode, response)
  }

  private func authority(issued: Date, expires: Date) -> [String: Any] {
    [
      "authorization_hash": "sha256:" + String(repeating: "a", count: 64),
      "selected_writer": "codex", "harness_sha256": "sha256:" + String(repeating: "b", count: 64),
      "authorization_issued_at": HarnessRuntime.timestamp(issued),
      "authorization_expires_at": HarnessRuntime.timestamp(expires),
      "ledger_path": "/tmp/synthetic-ledger",
      "ledger_identity_sha256": "sha256:" + String(repeating: "c", count: 64),
      "ledger_approval_sha256": "sha256:" + String(repeating: "d", count: 64),
    ]
  }

  private func fingerprint(_ digit: Character) -> String {
    "sha256:" + String(repeating: digit, count: 64)
  }

  // MARK: Coordinator state retention

  /// Measures the lease records a host accumulates over 20 days of three runtime-probe cycles a
  /// day, each day under its own short run. Terminal leases are kept for the documented 7 days
  /// after both their transition and their owner's authorization window ended, so the lease
  /// section stays the same size once the window is full. The fencing proof, a recovery's
  /// replacement and an open owner's history survive.
  func testTerminalLeaseRetentionBoundsStateAndKeepsEveryLoadInvariant() throws {
    let root = try temporaryRoot()
    let state = root.appendingPathComponent("coordinator.json")
    let instance = try XCTUnwrap(
      try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)[
        "coordinator_instance_id"] as? String)
    let start = Date()
    let day: TimeInterval = 86_400
    let registry: [String: Any] = [
      "coordinator_instance_id": instance, "registry_scope": "health-probe",
    ]
    func leases() throws -> [String: Any] {
      try XCTUnwrap(
        try ResourceCoordinator.fullStatus(statePath: state)["leases"] as? [String: Any])
    }
    func leaseBytes() throws -> Int {
      try HarnessRuntime.canonicalJSON(try leases(), ensureASCII: true).count
    }
    func fileBytes() throws -> Int {
      try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: state.path)[.size] as? NSNumber
      ).intValue
    }

    // An owner whose authorization is still open keeps its history: its ledger check still
    // compares this release confirmation with the stored lease.
    let open = authority(issued: start.addingTimeInterval(-60), expires: start + 60 * day)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "open-run", runAuthority: open, now: start)
    let openReceipt = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.coreSimulator, descriptor: registry,
      ownerRunID: "open-run", ownerActor: "codex", ttlSeconds: 60, now: start, runAuthority: open)
    let openRelease = try ResourceCoordinator.release(
      statePath: state, receipt: openReceipt, runAuthority: open, now: start.addingTimeInterval(1))

    var firstReceipt: [String: Any]?
    var firstRelease: [String: Any]?
    var measured: [Int: (leases: Int, leaseBytes: Int, fileBytes: Int)] = [:]
    for index in 0..<20 {
      let opened = start + Double(index) * day + 3_600
      let runID = "probe-run-\(index)"
      let probe = authority(issued: opened.addingTimeInterval(-60), expires: opened + 600)
      _ = try ResourceCoordinator.registerRunAuthority(
        statePath: state, runID: runID, runAuthority: probe, now: opened)
      for cycle in 0..<3 {
        let now = opened + Double(cycle) * 60
        let receipt = try ResourceCoordinator.acquire(
          statePath: state, resource: ResourceCoordinator.coreSimulator, descriptor: registry,
          ownerRunID: runID, ownerActor: "codex", ttlSeconds: 90, now: now, runAuthority: probe)
        let release = try ResourceCoordinator.release(
          statePath: state, receipt: receipt, runAuthority: probe, now: now.addingTimeInterval(5))
        if firstReceipt == nil { (firstReceipt, firstRelease) = (receipt, release) }
      }
      if [9, 19].contains(index) {
        measured[index] = (try leases().count, try leaseBytes(), try fileBytes())
      }
    }
    for index in measured.keys.sorted() {
      print(
        "coordinator state after day \(index + 1): \(measured[index]!.leases) leases, "
          + "\(measured[index]!.leaseBytes) lease bytes, \(measured[index]!.fileBytes) file bytes")
    }
    // Eight days of three probe leases each fit the window, plus the open owner's lease.
    XCTAssertLessThanOrEqual(try XCTUnwrap(measured[19]).leases, 8 * 3 + 1)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(measured[19]).leaseBytes, try XCTUnwrap(measured[9]).leaseBytes * 105 / 100,
      "terminal lease records must stop growing once the retention window is full")
    let status = try ResourceCoordinator.fullStatus(statePath: state)
    XCTAssertEqual((status["next_fencing_token"] as? NSNumber)?.intValue, 1 + 20 * 3)
    XCTAssertNotNil(try leases()[openReceipt["lease_id"] as! String])
    XCTAssertTrue(
      ResourceCoordinator.validateReleaseConfirmation(
        receipt: openReceipt, confirmation: openRelease, statePath: state))
    // A compacted receipt stays stale and its confirmation no longer proves a live release.
    let first = try XCTUnwrap(firstReceipt)
    XCTAssertNil(try leases()[first["lease_id"] as! String])
    XCTAssertThrowsError(try ResourceCoordinator.verify(statePath: state, receipt: first)) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "stale_receipt")
    }
    XCTAssertFalse(
      ResourceCoordinator.validateReleaseConfirmation(
        receipt: first, confirmation: try XCTUnwrap(firstRelease), statePath: state))

    // Past the retention window, the lease that proves next_fencing_token and a replacement that
    // a kept recovery names must both survive, or the next load rejects the state.
    let later = start + 50 * day
    let holder = authority(issued: later.addingTimeInterval(-60), expires: later + 30 * day)
    let deadOwner = authority(issued: later.addingTimeInterval(-60), expires: later + 30 * day)
    let observer = authority(issued: later.addingTimeInterval(-60), expires: later + 600)
    let short = authority(issued: later.addingTimeInterval(-60), expires: later + 600)
    for (runID, value) in [
      ("holder", holder), ("dead-owner", deadOwner), ("observer", observer), ("short", short),
    ] {
      _ = try ResourceCoordinator.registerRunAuthority(
        statePath: state, runID: runID, runAuthority: value, now: later)
    }
    let held = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.sourceWriter,
      descriptor: [
        "identity_version": "github_remote_v2", "repository_fingerprint": fingerprint("e"),
      ],
      ownerRunID: "holder", ownerActor: "codex", ttlSeconds: 3_600, now: later + 8 * day,
      runAuthority: holder)
    let github: [String: Any] = [
      "repository_fingerprint": fingerprint("f"), "remote_repository": "example/app",
    ]
    let dead = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.github, descriptor: github,
      ownerRunID: "dead-owner", ownerActor: "codex", ttlSeconds: 1, now: later,
      runAuthority: deadOwner)
    let observedAt = HarnessRuntime.timestamp(later.addingTimeInterval(2))
    func observation(_ state: String) -> [String: Any] {
      ["state": state, "digest": fingerprint("1"), "observed_at": observedAt]
    }
    let evidence: [String: Any] = [
      "previous_receipt_id": dead["receipt_id"]!, "previous_fencing_token": dead["fencing_token"]!,
      "observer": [
        "observer_run_id": "observer", "observer_actor": "codex",
        "method": "bounded_read_only_host_probe", "observed_at": observedAt,
      ],
      "owner_liveness": observation("dead"), "owner_tool_children": observation("dead"),
      "dirty_state": observation("clean"),
      "live_resource_revalidation": [
        "passed": true, "digest": fingerprint("2"), "observed_at": observedAt,
      ],
    ]
    let recovery = try ResourceCoordinator.recover(
      statePath: state, receipt: dead, evidence: evidence, runAuthority: deadOwner,
      observerAuthority: observer,
      replacement: [
        "resource": ResourceCoordinator.github, "descriptor": github, "owner_run_id": "observer",
        "owner_actor": "codex", "ttl_seconds": 30,
      ], replacementAuthority: observer,
      now: try HarnessRuntime.parseTimestamp(observedAt))
    let replacement = try XCTUnwrap(recovery["replacement_receipt"] as? [String: Any])
    _ = try ResourceCoordinator.release(
      statePath: state, receipt: replacement, runAuthority: observer, now: later + 10)
    let newest = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.coreSimulator, descriptor: registry,
      ownerRunID: "short", ownerActor: "codex", ttlSeconds: 90, now: later + 20,
      runAuthority: short)
    _ = try ResourceCoordinator.release(
      statePath: state, receipt: newest, runAuthority: short, now: later + 30)
    // Only the holder's heartbeat runs after the window; it creates no fencing token.
    _ = try ResourceCoordinator.heartbeat(
      statePath: state, receipt: held, ttlSeconds: 3_600, runAuthority: holder,
      now: later + 8 * day + 1_800)
    let kept = try leases()
    for receipt in [held, dead, replacement, newest] {
      XCTAssertNotNil(kept[receipt["lease_id"] as! String], "\(receipt["resource"]!)")
    }
    XCTAssertTrue(
      ResourceCoordinator.validateRecoveryConfirmation(
        receipt: dead, evidence: evidence, confirmation: recovery, statePath: state))
    XCTAssertEqual(
      try ResourceCoordinator.fullStatus(statePath: state)["next_fencing_token"] as? NSNumber,
      newest["fencing_token"] as? NSNumber)
  }

  // MARK: Runtime probe scope

  private struct ProbeRuns {
    let state: URL
    let instance: String
    let probeHarness: URL
    let taskHarness: URL
    let task: [String: Any]
  }

  /// A registered probe run whose authorization plans the CoreSimulator registry admission, and a
  /// task harness on the same coordinator that names it as its runtime probe scope.
  private func probeRuns(planID: String = "runtime-probe") throws -> ProbeRuns {
    let base = try temporaryRoot()
    let state = base.appendingPathComponent("coordinator.json")
    let instance = try XCTUnwrap(
      try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)[
        "coordinator_instance_id"] as? String)
    let binding: [String: Any] = [
      "runtime_kind": "swift", "runtime_contract": ResourceCoordinator.runtimeContract,
      "state_path": state.path, "coordinator_instance_id": instance,
      "executable_sha256": fingerprint("1"), "source_bundle_sha256": fingerprint("2"),
    ]
    let registry: [String: Any] = [
      "coordinator_instance_id": instance, "registry_scope": "health-probe",
    ]
    var harnessTemplate = try HarnessRuntime.object(
      context.harnessRoot.appendingPathComponent("templates/harness-local.json"))
    harnessTemplate["authoritative_root"] = base.path
    harnessTemplate["resource_coordinator"] = binding
    func runRoot(_ name: String) throws -> URL {
      let url = base.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      return url
    }

    let probeRoot = try runRoot("probe")
    var envelope = try HarnessRuntime.object(
      repository.appendingPathComponent("tests/fixtures/run-authorization-approved.json"))
    let schema = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    envelope = approvalWindow(of: envelope, containing: Date())
    envelope["run_id"] = "probe-run"
    envelope["resource_plan"] = [
      [
        "plan_id": "runtime-probe", "resource": ResourceCoordinator.coreSimulator,
        "resource_key": try ResourceCoordinator.canonicalResourceKey(
          resource: ResourceCoordinator.coreSimulator, descriptor: registry),
        "descriptor_sha256": try ResourceCoordinator.descriptorSHA256(
          resource: ResourceCoordinator.coreSimulator, descriptor: registry),
        "resource_descriptor": registry, "owner_actor": "codex", "protects": ["verify"],
      ]
    ]
    let authorization = probeRoot.appendingPathComponent("authorization.json")
    let ledger = probeRoot.appendingPathComponent("ledger.jsonl")
    try HarnessRuntime.atomicWriteJSON(envelope, to: authorization)
    let approval = try InitializeRun.approvalRecord(
      authorization: envelope, recordedAt: Date(), context: context)
    try (HarnessRuntime.canonicalJSON(approval) + Data([0x0a])).write(to: ledger)
    var probe = harnessTemplate
    probe["private_policy_overlay"] = probeRoot.appendingPathComponent("policy.json").path
    probe["run_authorization"] = authorization.path
    probe["run_ledger"] = ledger.path
    let probeHarness = probeRoot.appendingPathComponent("harness.json")
    try HarnessRuntime.atomicWriteJSON(probe, to: probeHarness)
    let (_, probeAuthority) = try ResourceCoordinator.loadExistingRunAuthority(
      authorizationPath: authorization, harnessPath: probeHarness, harness: probe,
      runID: "probe-run", context: context)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "probe-run", runAuthority: probeAuthority)

    let taskRoot = try runRoot("task")
    var task = harnessTemplate
    task["private_policy_overlay"] = taskRoot.appendingPathComponent("policy.json").path
    task["run_authorization"] = taskRoot.appendingPathComponent("authorization.json").path
    task["run_ledger"] = taskRoot.appendingPathComponent("ledger.jsonl").path
    task["runtime_probe_scope"] = [
      "harness": probeHarness.path, "owner_run_id": "probe-run", "plan_id": planID,
      "descriptor": registry.merging([
        "platform": "iOS", "destination_id": "DEVICE-1",
        "runtime_identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
      ]) { current, _ in current },
      "ttl_seconds": 120,
    ]
    let taskHarness = taskRoot.appendingPathComponent("harness.json")
    try HarnessRuntime.atomicWriteJSON(task, to: taskHarness)
    return ProbeRuns(
      state: state, instance: instance, probeHarness: probeHarness, taskHarness: taskHarness,
      task: task)
  }

  private func loadScope(_ harness: [String: Any], at url: URL) throws -> RuntimeProbeScope? {
    try HarnessRuntime.atomicWriteJSON(harness, to: url)
    return try ResourceCoordinator.runtimeProbeScope(
      trustedHarness: try ResourceCoordinator.loadTrustedHarness(
        harnessPath: url, context: context),
      context: context)
  }

  /// The task's own run cannot be registered before its pre-authorization health report, and an
  /// authority copied into its harness would have to contain that harness's own SHA-256. The
  /// scope therefore names a separate probe run whose authority is derived live, with its plan.
  func testRuntimeProbeScopeAcquiresUnderASeparateProbeRunsLiveAuthority() throws {
    let runs = try probeRuns()
    let scope = try XCTUnwrap(try loadScope(runs.task, at: runs.taskHarness))
    let receipt = try ResourceCoordinatorRuntimeAdmission().withRuntimeRegistryAdmission(
      scope: scope
    ) { $0 }
    XCTAssertEqual(receipt["owner_run_id"] as? String, "probe-run")
    XCTAssertEqual(receipt["resource"] as? String, ResourceCoordinator.coreSimulator)
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: runs.state)["active_lease_count"] as? Int, 0)

    // The admission must be the probe run's planned entry, on the task's own coordinator, by
    // a run other than the task.
    var unplanned = runs.task
    var scopeValue = try XCTUnwrap(unplanned["runtime_probe_scope"] as? [String: Any])
    scopeValue["plan_id"] = "unplanned"
    unplanned["runtime_probe_scope"] = scopeValue
    XCTAssertThrowsError(try loadScope(unplanned, at: runs.taskHarness)) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "authorization_scope_mismatch")
    }
    var otherCoordinator = runs.task
    var binding = try XCTUnwrap(otherCoordinator["resource_coordinator"] as? [String: Any])
    binding["coordinator_instance_id"] = "another-coordinator"
    otherCoordinator["resource_coordinator"] = binding
    XCTAssertThrowsError(try loadScope(otherCoordinator, at: runs.taskHarness)) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "untrusted_binding")
    }
    var selfProbe = runs.task
    scopeValue = try XCTUnwrap(selfProbe["runtime_probe_scope"] as? [String: Any])
    scopeValue["harness"] = runs.taskHarness.path
    selfProbe["runtime_probe_scope"] = scopeValue
    XCTAssertThrowsError(try loadScope(selfProbe, at: runs.taskHarness)) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "invalid_runtime_probe_scope")
    }

    // A pre-fix scope that embeds a copied authority is refused rather than misread.
    var embedded = runs.task
    embedded["runtime_probe_scope"] = [
      "state_path": runs.state.path, "descriptor": scope.descriptor, "owner_run_id": "probe-run",
      "owner_actor": "codex", "ttl_seconds": 120, "run_authority": scope.runAuthority,
    ]
    try HarnessRuntime.atomicWriteJSON(embedded, to: runs.taskHarness)
    XCTAssertThrowsError(
      try ResourceCoordinator.loadTrustedHarness(harnessPath: runs.taskHarness, context: context)
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "untrusted_binding") }
  }

  // MARK: Project registry resolution

  private func makeRepository(at root: URL, containers: [String]) throws {
    for container in containers {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(container), withIntermediateDirectories: true)
    }
    _ = try HarnessRuntime.run(executable: "/usr/bin/git", arguments: ["init", "-q", root.path])
    _ = try HarnessRuntime.run(
      executable: "/usr/bin/git",
      arguments: ["-C", root.path, "remote", "add", "origin", "git@github.com:Example/App.git"])
  }

  private func registryReport(_ resolution: [String: Any], root: URL) -> [String: Any] {
    let ids = [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      "repository.project_registry",
    ]
    return [
      "schema_version": "1.0.0", "profile": "local_verified",
      "observed_at": HarnessRuntime.timestamp(Date()),
      "authoritative_targets": ["repository": root.path],
      "agent_skill_manifest": [
        "required_skills": ["agent-harness"], "expected_bundle_sha256": fingerprint("3"),
        "clients": [
          [
            "client": "codex", "root_path_sha256": fingerprint("4"),
            "bundle_sha256": fingerprint("3"),
            "skills": [
              [
                "name": "agent-harness", "entry_kind": "directory",
                "resolved_path_sha256": fingerprint("5"), "sha256": fingerprint("6"),
              ]
            ],
          ]
        ],
      ],
      "resource_coordinator_observation": [
        "state_path_sha256": fingerprint("7"), "coordinator_instance_id": "fixture",
        "state_schema_version": 2, "migration_bootstrap_confirmed": true,
        "runtime_kind": "swift", "runtime_contract": ResourceCoordinator.runtimeContract,
        "executable_sha256": fingerprint("8"), "source_bundle_sha256": fingerprint("9"),
        "active_lease_count": 0,
      ],
      "project_registry_resolution": resolution, "selected_components": ["project_registry"],
      "required_check_ids": ids,
      "checks": ids.map { id -> [String: Any] in
        [
          "id": id, "category": String(id.prefix(while: { $0 != "." })), "required": true,
          "status": "healthy", "summary": "fixture", "evidence": ["fixture"],
        ]
      },
    ]
  }

  /// health-matrix.md runs the resolver with the intake signals; an Xcode task always passes the
  /// opened container. That output must be the projection health accepts, naming the registry
  /// checkout that the authoritative signal identifies.
  func testDocumentedResolveProjectCallFeedsTheHealthEvaluator() throws {
    let base = try temporaryRoot()
    let app = base.appendingPathComponent("app")
    let unregistered = base.appendingPathComponent("unregistered")
    try makeRepository(at: app, containers: ["App.xcodeproj", "Tools.xcodeproj"])
    try makeRepository(at: unregistered, containers: ["App.xcodeproj"])
    let registry = base.appendingPathComponent("registry.json")
    try HarnessRuntime.atomicWriteJSON(
      [
        "schema_version": "1.0.0", "developer_id": "dev", "host_id": "host",
        "projects": [
          [
            "project_id": "app",
            "remote_fingerprint": try ProjectResolver.remoteFingerprint(
              "git@github.com:Example/App.git"),
            "checkouts": [
              [
                "checkout_id": "primary", "path": app.path, "kind": "primary",
                "xcode_containers": ["App.xcodeproj"],
              ]
            ],
          ]
        ],
      ], to: registry)
    let selectors = ["--registry", registry.path, "--developer-id", "dev", "--host-id", "host"]
    for signal in [
      ["--opened-xcode-container", app.appendingPathComponent("App.xcodeproj").path],
      ["--explicit-path", app.path],
    ] {
      let resolved = try cli(["resolve-project"] + selectors + signal)
      XCTAssertEqual(resolved.code, 0, "\(resolved.response)")
      XCTAssertEqual(resolved.response["reason_code"] as? String, "registry_candidate")
      let evaluated = HealthEvaluation.evaluate(registryReport(resolved.response, root: app))
      XCTAssertEqual(evaluated.errors, [], "\(signal)")
      XCTAssertEqual(evaluated.report["overall_status"] as? String, "healthy", "\(signal)")
    }

    // The opened container and the root must both be the registry's; a mismatch is not healthy.
    let otherContainer = try cli(
      ["resolve-project"] + selectors + [
        "--opened-xcode-container", app.appendingPathComponent("Tools.xcodeproj").path,
      ])
    XCTAssertEqual(otherContainer.code, 2, "\(otherContainer.response)")
    XCTAssertEqual(
      otherContainer.response["reason_code"] as? String, "opened_xcode_container_not_registered")
    let outside = try cli(["resolve-project"] + selectors + ["--explicit-path", unregistered.path])
    XCTAssertEqual(outside.code, 4, "\(outside.response)")
    XCTAssertEqual(
      outside.response["reason_code"] as? String, "authoritative_target_not_registered")
    for response in [otherContainer.response, outside.response] {
      var report = registryReport(response, root: app)
      var checks = report["checks"] as! [[String: Any]]
      checks[checks.count - 1]["status"] = "blocked"
      checks[checks.count - 1]["next_action"] = "Select the registered checkout."
      report["checks"] = checks
      let evaluated = HealthEvaluation.evaluate(report)
      XCTAssertEqual(evaluated.errors, [], "\(response)")
      XCTAssertEqual(evaluated.report["overall_status"] as? String, "blocked")
    }
  }
}
