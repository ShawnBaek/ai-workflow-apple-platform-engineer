import Darwin
import XCTest

@testable import AppleVerificationCore

final class ResourcePortTests: XCTestCase {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func authority(now: Date = Date(), actor: String = "codex") -> [String: Any] {
    [
      "authorization_hash": "sha256:" + String(repeating: "a", count: 64), "selected_writer": actor,
      "harness_sha256": "sha256:" + String(repeating: "b", count: 64),
      "authorization_issued_at": HarnessRuntime.timestamp(now.addingTimeInterval(-60)),
      "authorization_expires_at": HarnessRuntime.timestamp(now.addingTimeInterval(600)),
      "ledger_path": "/tmp/ledger",
      "ledger_identity_sha256": "sha256:" + String(repeating: "c", count: 64),
      "ledger_approval_sha256": "sha256:" + String(repeating: "d", count: 64),
    ]
  }

  private var writerDescriptor: [String: Any] {
    [
      "identity_version": "github_remote_v2",
      "repository_fingerprint": "sha256:" + String(repeating: "e", count: 64),
    ]
  }

  func testRemoteNormalization() throws {
    XCTAssertEqual(
      try ProjectResolver.normalizeGitHubRemote("git@github.com:ExampleOrg/Sample.git"),
      "github.com/exampleorg/sample")
    XCTAssertEqual(
      try ProjectResolver.normalizeGitHubRemote("https://github.com/ExampleOrg/Sample.git"),
      "github.com/exampleorg/sample")
    XCTAssertThrowsError(try ProjectResolver.normalizeGitHubRemote("https://token@github.com/a/b"))
    XCTAssertThrowsError(try ProjectResolver.normalizeGitHubRemote("https://github.com:8443/a/b"))
  }

  func testProjectResolverValidatesGitRootAndNeverSelectsFirstOfMany() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let context = RuntimeContext(repositoryRoot: base, harnessRoot: base)
    func repository(_ name: String, _ remote: String) throws -> URL {
      let root = base.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Sample.xcodeproj"), withIntermediateDirectories: true)
      _ = try HarnessRuntime.run(executable: "/usr/bin/git", arguments: ["init", "-q", root.path])
      _ = try HarnessRuntime.run(
        executable: "/usr/bin/git",
        arguments: [
          "-C", root.path, "remote", "add", "origin", "git@github.com:ExampleOrg/\(remote).git",
        ])
      return root
    }
    let first = try repository("one", "One")
    let second = try repository("two", "Two")
    let explicit = ProjectResolver.resolveProject(
      registry: ["bad": true], explicitPath: first.path, context: context)
    XCTAssertEqual(explicit["reason_code"] as? String, "explicit_path")
    let projects: [[String: Any]] = try [first, second].enumerated().map { index, root in
      [
        "project_id": "p\(index)",
        "remote_fingerprint": try ProjectResolver.remoteFingerprint(
          "git@github.com:ExampleOrg/\(index == 0 ? "One":"Two").git"),
        "checkouts": [
          [
            "checkout_id": "c\(index)", "path": root.path, "kind": "primary",
            "xcode_containers": ["Sample.xcodeproj"],
          ]
        ],
      ]
    }
    let result = ProjectResolver.resolveProject(
      registry: [
        "schema_version": "1.0.0", "developer_id": "dev", "host_id": "host", "projects": projects,
      ], developerID: "dev", hostID: "host", context: context)
    XCTAssertEqual(result["status"] as? String, "needs_selection")
    XCTAssertEqual((result["candidates"] as? [[String: Any]])?.count, 2)
  }

  func testDescriptorCanonicalizationAndConflictAliases() throws {
    let unprefixed = [
      "identity_version": "github_remote_v2",
      "repository_fingerprint": String(repeating: "E", count: 64),
    ]
    XCTAssertEqual(
      try ResourceCoordinator.descriptorSHA256(
        resource: ResourceCoordinator.sourceWriter, descriptor: unprefixed),
      try ResourceCoordinator.descriptorSHA256(
        resource: ResourceCoordinator.sourceWriter, descriptor: writerDescriptor))
    let simA: [String: Any] = [
      "coordinator_instance_id": "host", "udids": ["DEVICE-A", "device-b"],
    ]
    let simB: [String: Any] = ["coordinator_instance_id": "host", "udids": ["device-b"]]
    let a = try ResourceCoordinator.normalizeDescriptor(
      resource: ResourceCoordinator.simulator, descriptor: simA)
    let b = try ResourceCoordinator.normalizeDescriptor(
      resource: ResourceCoordinator.simulator, descriptor: simB)
    XCTAssertTrue(
      ResourceCoordinator.descriptorsConflict(
        resource: ResourceCoordinator.simulator, descriptor: a,
        otherResource: ResourceCoordinator.simulator, other: b))
    XCTAssertThrowsError(
      try ResourceCoordinator.normalizeDescriptor(
        resource: ResourceCoordinator.buildTuple, descriptor: ["cache_paths": []]))
  }

  func testLifecycleFencingHeartbeatReleaseAndRecovery() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let now = Date()
    let owner = authority(now: now)
    let observer = authority(now: now)
    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "run-a", runAuthority: owner, now: now)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "run-b", runAuthority: observer, now: now)
    let receipt = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.sourceWriter, descriptor: writerDescriptor,
      ownerRunID: "run-a", ownerActor: "codex", ttlSeconds: 10, now: now, runAuthority: owner)
    XCTAssertEqual(receipt["fencing_token"] as? Int, 1)
    let beat = try ResourceCoordinator.heartbeat(
      statePath: state, receipt: receipt, ttlSeconds: 20, runAuthority: owner,
      now: now.addingTimeInterval(1))
    XCTAssertNil(
      try? ResourceCoordinator.verify(
        statePath: state, receipt: receipt, now: now.addingTimeInterval(2)))
    XCTAssertNotNil(
      ResourceCoordinator.verifyReceipt(
        statePath: state, receipt: receipt, now: now.addingTimeInterval(2)
      ).receipt)
    XCTAssertThrowsError(
      try ResourceCoordinator.release(
        statePath: state, receipt: beat, runAuthority: ["bad": true], now: now.addingTimeInterval(2)
      ))
    let release = try ResourceCoordinator.release(
      statePath: state, receipt: beat, runAuthority: owner, now: now.addingTimeInterval(2))
    XCTAssertTrue(
      ResourceCoordinator.validateReleaseConfirmation(
        receipt: beat, confirmation: release, statePath: state))

    let second = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.sourceWriter, descriptor: writerDescriptor,
      ownerRunID: "run-a", ownerActor: "codex", ttlSeconds: 1, now: now.addingTimeInterval(3),
      runAuthority: owner)
    let stamp = HarnessRuntime.timestamp(now.addingTimeInterval(5))
    let observed = try HarnessRuntime.parseTimestamp(stamp)
    let evidence: [String: Any] = [
      "previous_receipt_id": second["receipt_id"]!,
      "previous_fencing_token": second["fencing_token"]!,
      "observer": [
        "observer_run_id": "run-b", "observer_actor": "codex",
        "method": "bounded_read_only_host_probe", "observed_at": stamp,
      ],
      "owner_liveness": [
        "state": "dead", "digest": "sha256:" + String(repeating: "1", count: 64),
        "observed_at": stamp,
      ],
      "owner_tool_children": [
        "state": "dead", "digest": "sha256:" + String(repeating: "2", count: 64),
        "observed_at": stamp,
      ],
      "dirty_state": [
        "state": "clean", "digest": "sha256:" + String(repeating: "3", count: 64),
        "observed_at": stamp,
      ],
      "live_resource_revalidation": [
        "passed": true, "digest": "sha256:" + String(repeating: "4", count: 64),
        "observed_at": stamp,
      ],
    ]
    let recovered = try ResourceCoordinator.recover(
      statePath: state, receipt: second, evidence: evidence, runAuthority: owner,
      observerAuthority: observer, now: observed)
    XCTAssertEqual(recovered["recovery_fencing_token"] as? Int, 3)
    XCTAssertTrue(
      ResourceCoordinator.validateRecoveryConfirmation(
        receipt: second, evidence: evidence, confirmation: recovered, statePath: state))
  }

  func testRecoveryReplacementGetsHigherFenceAndCapacity() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let now = Date()
    let owner = authority(now: now)
    let observer = authority(now: now)
    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "old", runAuthority: owner, now: now)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "new", runAuthority: observer, now: now)
    let receipt = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.github,
      descriptor: [
        "repository_fingerprint": "sha256:" + String(repeating: "a", count: 64),
        "remote_repository": "owner/repo",
      ], ownerRunID: "old", ownerActor: "codex", ttlSeconds: 1, now: now, runAuthority: owner)
    let stamp = HarnessRuntime.timestamp(now.addingTimeInterval(2))
    let recoveredAt = try HarnessRuntime.parseTimestamp(stamp)
    let evidence: [String: Any] = [
      "previous_receipt_id": receipt["receipt_id"]!,
      "previous_fencing_token": receipt["fencing_token"]!,
      "observer": [
        "observer_run_id": "new", "observer_actor": "codex",
        "method": "bounded_read_only_host_probe", "observed_at": stamp,
      ],
      "owner_liveness": [
        "state": "dead", "digest": "sha256:" + String(repeating: "1", count: 64),
        "observed_at": stamp,
      ],
      "owner_tool_children": [
        "state": "dead", "digest": "sha256:" + String(repeating: "2", count: 64),
        "observed_at": stamp,
      ],
      "dirty_state": [
        "state": "clean", "digest": "sha256:" + String(repeating: "3", count: 64),
        "observed_at": stamp,
      ],
      "live_resource_revalidation": [
        "passed": true, "digest": "sha256:" + String(repeating: "4", count: 64),
        "observed_at": stamp,
      ],
    ]
    let replacement: [String: Any] = [
      "resource": ResourceCoordinator.github,
      "descriptor": [
        "repository_fingerprint": "sha256:" + String(repeating: "a", count: 64),
        "remote_repository": "owner/repo",
      ], "owner_run_id": "new", "owner_actor": "codex", "ttl_seconds": 30,
    ]
    let confirmation = try ResourceCoordinator.recover(
      statePath: state, receipt: receipt, evidence: evidence, runAuthority: owner,
      observerAuthority: observer, replacement: replacement, replacementAuthority: observer,
      now: recoveredAt)
    XCTAssertEqual(
      (confirmation["replacement_receipt"] as? [String: Any])?["fencing_token"] as? Int, 3)
    XCTAssertTrue(
      ResourceCoordinator.validateRecoveryConfirmation(
        receipt: receipt, evidence: evidence, confirmation: confirmation, statePath: state))
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["active_lease_count"] as? Int, 1)
  }

  func testActualProcessesSerializeConflictingAcquisition() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let now = Date()
    let auth = authority(now: now)
    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "run", runAuthority: auth, now: now)
    let authorityURL = base.appendingPathComponent("authority.json")
    try HarnessRuntime.atomicWriteJSON(auth, to: authorityURL)
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let executable =
      (FileManager.default.enumerator(
        at: packageRoot.appendingPathComponent(".build"),
        includingPropertiesForKeys: [.isExecutableKey])?.compactMap { $0 as? URL }.first {
        $0.lastPathComponent == "ContentionProbe"
          && FileManager.default.isExecutableFile(atPath: $0.path)
      })!
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)
    func process() -> Process {
      let p = Process()
      p.executableURL = executable
      p.arguments = [state.path, authorityURL.path]
      return p
    }
    let a = process()
    let b = process()
    try a.run()
    try b.run()
    a.waitUntilExit()
    b.waitUntilExit()
    XCTAssertEqual(Set([a.terminationStatus, b.terminationStatus]), Set([0, 2]))
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["active_lease_count"] as? Int, 1)
  }

  func testActualProcessesAtomicallyEnforceGlobalCapacity() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let now = Date()
    let auth = authority(now: now)
    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "run", runAuthority: auth, now: now)
    let authorityURL = base.appendingPathComponent("authority.json")
    try HarnessRuntime.atomicWriteJSON(auth, to: authorityURL)
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let executable =
      (FileManager.default.enumerator(
        at: packageRoot.appendingPathComponent(".build"),
        includingPropertiesForKeys: [.isExecutableKey])?.compactMap { $0 as? URL }.first {
        $0.lastPathComponent == "ContentionProbe"
          && FileManager.default.isExecutableFile(atPath: $0.path)
      })!
    func process(_ discriminator: String) -> Process {
      let p = Process()
      p.executableURL = executable
      p.arguments = [state.path, authorityURL.path, discriminator, "capacity"]
      return p
    }
    let a = process("a")
    let b = process("b")
    try a.run()
    try b.run()
    a.waitUntilExit()
    b.waitUntilExit()
    XCTAssertEqual(Set([a.terminationStatus, b.terminationStatus]), Set([0, 2]))
    let status = try ResourceCoordinator.status(statePath: state)
    XCTAssertEqual((status["capacity_in_use"] as? [String: Any])?["heavy_jobs"] as? Int, 1)
    XCTAssertEqual((status["capacity_in_use"] as? [String: Any])?["internal_workers"] as? Int, 1)
  }

  func testMaterializationIsPrivateAtomicAndExplicitReplace() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let template = base.appendingPathComponent("template.json")
    let schema = base.appendingPathComponent("schema.json")
    let output = base.appendingPathComponent("out.json")
    try Data(
      "{\"name\":\"value\",\"contract_schema_id\":\"pending\",\"contract_schema_sha256\":\"pending\"}"
        .utf8
    ).write(to: template)
    try Data(
      "{\"$id\":\"urn:test\",\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"},\"$schema\":{\"type\":\"string\"},\"contract_schema_id\":{\"type\":\"string\"},\"contract_schema_sha256\":{\"type\":\"string\"}},\"additionalProperties\":false}"
        .utf8
    ).write(to: schema)
    let result = try MaterializePrivateTemplate.materialize(
      templatePath: template, schemaPath: schema, outputPath: output)
    XCTAssertEqual(result["contract_schema_id"] as? String, "urn:test")
    var st = Darwin.stat()
    XCTAssertEqual(lstat(output.path, &st), 0)
    XCTAssertEqual(st.st_mode & 0o777, 0o600)
    XCTAssertThrowsError(
      try MaterializePrivateTemplate.materialize(
        templatePath: template, schemaPath: schema, outputPath: output))
  }

  func testStateAndLedgerIdentityFailClosed() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    XCTAssertThrowsError(try ResourceCoordinator.status(statePath: state)) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "migration_required")
    }
    _ = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    try FileManager.default.removeItem(at: URL(fileURLWithPath: state.path + ".lock"))
    XCTAssertThrowsError(try ResourceCoordinator.status(statePath: state)) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "invalid_state_path")
    }

    let ledger = base.appendingPathComponent("ledger.jsonl")
    let approval: [String: Any] = [
      "run_id": "run", "sequence": 1, "record_type": "approval",
      "payload": [
        "kind": "run_authorization", "decision": "approved",
        "authorization_hash": "sha256:" + String(repeating: "a", count: 64),
      ],
    ]
    try (HarnessRuntime.canonicalJSON(approval, ensureASCII: true) + Data([0x0a])).write(to: ledger)
    _ = chmod(ledger.path, 0o600)
    let fd = open(ledger.path, O_RDONLY | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }
    XCTAssertNoThrow(
      try ResourceCoordinator.ledgerBinding(
        ledger, descriptor: fd, expectedRunID: "run",
        expectedAuthorizationHash: "sha256:" + String(repeating: "a", count: 64)))
    let replacement = base.appendingPathComponent("replacement")
    try (HarnessRuntime.canonicalJSON(approval, ensureASCII: true) + Data([0x0a])).write(
      to: replacement)
    _ = try FileManager.default.replaceItemAt(ledger, withItemAt: replacement)
    XCTAssertThrowsError(try ResourceCoordinator.ledgerBinding(ledger, descriptor: fd)) {
      XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "untrusted_ledger")
    }
  }

  func testRuntimeRegistryAdmissionBindsProbeScopeAndReleases() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let now = Date()
    let auth = authority(now: now)
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "health", runAuthority: auth, now: now)
    XCTAssertThrowsError(
      try ResourceCoordinator.withRuntimeRegistryAdmission(
        statePath: state, descriptor: [:], ownerRunID: "health", ownerActor: "codex",
        runAuthority: auth
      ) { _ in true }
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "invalid_runtime_probe_scope") }
    let descriptor: [String: Any] = [
      "coordinator_instance_id": boot["coordinator_instance_id"]!, "registry_scope": "default",
      "platform": "iOS Simulator", "destination_id": "device-1",
      "runtime_identifier": "com.apple.CoreSimulator.SimRuntime.iOS",
    ]
    let observed = try ResourceCoordinator.withRuntimeRegistryAdmission(
      statePath: state, descriptor: descriptor, ownerRunID: "health", ownerActor: "codex",
      runAuthority: auth
    ) { receipt in receipt["resource"] as? String }
    XCTAssertEqual(observed, ResourceCoordinator.coreSimulator)
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["active_lease_count"] as? Int, 0)
  }

  func testRegistryCLIRejectsDuplicateKeys() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let registry = base.appendingPathComponent("registry.json")
    try Data(
      "{\"schema_version\":\"1.0.0\",\"schema_version\":\"1.0.0\",\"developer_id\":\"dev\",\"host_id\":\"host\",\"projects\":[]}"
        .utf8
    ).write(to: registry)
    let context = RuntimeContext(repositoryRoot: base, harnessRoot: base)
    XCTAssertEqual(
      try ProjectResolver.run(
        arguments: ["--registry", registry.path, "--developer-id", "dev", "--host-id", "host"],
        context: context), 2)
  }

  func testHostPolicyIncreaseRequiresOperatorAndExpiredLeaseKeepsCapacity() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let now = Date()
    let owner = authority(now: now)
    let observer = authority(now: now)
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "owner", runAuthority: owner, now: now)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "observer", runAuthority: observer, now: now)
    let increased: [String: Any] = [
      "schema_version": "1.0.0", "max_heavy_jobs": 2, "max_active_devices": 2,
      "max_internal_workers": 2,
    ]
    XCTAssertThrowsError(
      try ResourceCoordinator.configureHostPolicy(
        statePath: state, policy: increased, operatorConfirmed: false)
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "operator_confirmation_required") }
    _ = try ResourceCoordinator.configureHostPolicy(
      statePath: state, policy: increased, operatorConfirmed: true, now: now)
    let instance = boot["coordinator_instance_id"]!
    let two: [String: Any] = [
      "coordinator_instance_id": instance, "udids": ["device-a", "device-b"],
    ]
    let receipt = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.simulator, descriptor: two,
      ownerRunID: "owner", ownerActor: "codex", ttlSeconds: 1, now: now, runAuthority: owner)
    let other: [String: Any] = ["coordinator_instance_id": instance, "udids": ["device-c"]]
    XCTAssertThrowsError(
      try ResourceCoordinator.acquire(
        statePath: state, resource: ResourceCoordinator.simulator, descriptor: other,
        ownerRunID: "observer", ownerActor: "codex", ttlSeconds: 10, now: now.addingTimeInterval(2),
        runAuthority: observer)
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "capacity_exceeded") }
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["active_lease_count"] as? Int, 1)
    XCTAssertEqual(receipt["fencing_token"] as? Int, 1)
  }

  func testLegacyStateNeedsQuiescentMigrationAndOldBindingIsRejected() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let lock = URL(fileURLWithPath: state.path + ".lock")
    let legacy: [String: Any] = [
      "schema_version": 1, "coordinator_instance_id": "legacy-instance",
      "migration_bootstrap": [
        "legacy_leases_quiesced": true, "confirmed_at": HarnessRuntime.timestamp(),
      ], "next_fencing_token": 0, "run_authorities": [String: Any](), "leases": [String: Any](),
    ]
    try HarnessRuntime.atomicWriteJSON(legacy, to: state)
    FileManager.default.createFile(atPath: lock.path, contents: Data())
    let migrated = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    XCTAssertEqual(migrated["migrated_legacy_state"] as? Bool, true)
    let status = try ResourceCoordinator.status(statePath: state)
    XCTAssertEqual(status["schema_version"] as? Int, 2)
    XCTAssertEqual(status["runtime_kind"] as? String, "swift")
    let old: [String: Any] = [
      "state_path": state.path, "coordinator_instance_id": "legacy-instance",
      "script_sha256": "sha256:" + String(repeating: "a", count: 64),
      "contract_bundle_sha256": "sha256:" + String(repeating: "b", count: 64),
    ]
    XCTAssertThrowsError(
      try ResourceCoordinator.validateTrustedBinding(
        statePath: state, binding: old,
        context: RuntimeContext(repositoryRoot: base, harnessRoot: base))
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "untrusted_binding") }
  }

  func testDefaultCapacityAllowsOneBuildAndOneDeviceWorker() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let state = base.appendingPathComponent("state.json")
    let now = Date()
    let auth = authority(now: now)
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "build", runAuthority: auth, now: now)
    _ = try ResourceCoordinator.registerRunAuthority(
      statePath: state, runID: "device", runAuthority: auth, now: now)
    _ = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.sourceWriter, descriptor: writerDescriptor,
      ownerRunID: "build", ownerActor: "codex", ttlSeconds: 60, now: now, runAuthority: auth)
    let roles: [String: String] = [
      "derived_data": base.appendingPathComponent("dd").path,
      "source_packages": base.appendingPathComponent("sp").path,
      "repository_checkouts": base.appendingPathComponent("rc").path,
      "artifacts": base.appendingPathComponent("ar").path,
      "package_cache": base.appendingPathComponent("pc").path,
    ]
    let build: [String: Any] = [
      "repository_fingerprint": writerDescriptor["repository_fingerprint"]!,
      "container_path": base.appendingPathComponent("App.xcodeproj").path, "xcode_build": "1",
      "sdk": "iphonesimulator", "scheme": "App", "configuration": "Debug", "architecture": "arm64",
      "package_fingerprint": "sha256:" + String(repeating: "f", count: 64),
      "cache_paths": roles.values.sorted(), "cache_roles": roles, "output_paths": [] as [String],
      "output_roles": [String: String](), "package_resolution_mode": "swiftpm_lockfile",
    ]
    _ = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.buildTuple, descriptor: build,
      ownerRunID: "build", ownerActor: "codex", ttlSeconds: 60, now: now, runAuthority: auth)
    _ = try ResourceCoordinator.acquire(
      statePath: state, resource: ResourceCoordinator.simulator,
      descriptor: [
        "coordinator_instance_id": boot["coordinator_instance_id"]!, "udids": ["device-a"],
      ], ownerRunID: "device", ownerActor: "codex", ttlSeconds: 60, now: now, runAuthority: auth)
    let status = try ResourceCoordinator.status(statePath: state)
    let usage = status["capacity_in_use"] as! [String: Any]
    XCTAssertEqual(usage["heavy_jobs"] as? Int, 1)
    XCTAssertEqual(usage["active_devices"] as? Int, 1)
    XCTAssertEqual(usage["internal_workers"] as? Int, 2)
  }

}
