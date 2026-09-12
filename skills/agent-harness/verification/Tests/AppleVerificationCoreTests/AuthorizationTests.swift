import XCTest

@testable import AppleVerificationCore

final class AuthorizationTests: XCTestCase {
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

  func testAuthorizationHashExcludesOnlySchemaLocation() throws {
    var first: [String: Any] = ["$schema": "file:///one", "run_id": "r", "unicode": "café"]
    var second = first
    second["$schema"] = "file:///two"
    XCTAssertEqual(Authorization.authorizationHash(first), Authorization.authorizationHash(second))
    first["run_id"] = "other"
    XCTAssertNotEqual(
      Authorization.authorizationHash(first), Authorization.authorizationHash(second))
  }

  func testPatchIdentityRequiresSortedUniqueCompleteManifest() throws {
    let record: [String: Any] = [
      "path": "Sources/Café.swift", "mode": "100644", "state": "modified",
      "content_sha256": "sha256:" + String(repeating: "a", count: 64),
    ]
    let manifest: [String: Any] = [
      "version": "patch_identity_v1", "base_sha": String(repeating: "1", count: 40),
      "records": [record],
    ]
    XCTAssertTrue(try Authorization.patchIdentityV1(manifest).hasPrefix("sha256:"))
    var unsafe = record
    unsafe["path"] = "../escape"
    XCTAssertThrowsError(
      try Authorization.patchIdentityV1([
        "version": "patch_identity_v1", "base_sha": String(repeating: "1", count: 40),
        "records": [unsafe],
      ]))
    XCTAssertThrowsError(
      try Authorization.patchIdentityV1([
        "version": "patch_identity_v1", "base_sha": String(repeating: "1", count: 40),
        "records": [record, record],
      ]))
  }

  func testGitHubIdentityNormalizesTransportAndStripsCredentials() throws {
    let forms = [
      "https://github.com/Example/Repo.git", "git@github.com:example/repo.git",
      "ssh://git@github.com/Example/Repo",
    ]
    XCTAssertEqual(Set(try forms.map(Authorization.repositoryFingerprint)).count, 1)
    XCTAssertEqual(
      Authorization.sanitizeRemote("https://token:secret@github.com/example/repo.git?x=1#fragment"),
      "https://github.com/example/repo.git")
    XCTAssertThrowsError(
      try Authorization.normalizeGitHubRemote("https://evil.example/example/repo"))
  }

  func testApprovedFixtureAndOperationDrift() throws {
    let fixture = repositoryRoot.appendingPathComponent(
      "tests/fixtures/run-authorization-approved.json")
    var envelope = try HarnessRuntime.object(fixture)
    envelope["$schema"] =
      repositoryRoot.appendingPathComponent(
        "skills/agent-harness/contracts/schemas/run-authorization.schema.json"
      ).absoluteString
    let schema = repositoryRoot.appendingPathComponent(
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json")
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    XCTAssertEqual(Authorization.validateAuthorization(envelope, context: context), [])
    var grants = envelope["action_grants"] as! [[String: Any]]
    let index = grants.firstIndex { $0["action"] as? String == "git.push" }!
    grants[index]["operation_input"] = ["branch": "codex/fixture-branch", "force": true]
    grants[index]["constraint_sha256"] = try Authorization.canonicalSHA256(
      grants[index]["operation_input"]!)
    envelope["action_grants"] = grants
    XCTAssertTrue(
      Authorization.validateAuthorization(envelope, context: context).contains {
        $0.contains("force false")
      })
  }

  func testCurrentSchemaAcceptsLocalAuthorizationWithoutRemoteGrantsAndWithImplementationLeasePlan()
    throws
  {
    var envelope = try currentApprovedEnvelope()
    envelope["delivery_target"] = "local_verified"
    envelope["health_profile"] = "local_verified"
    var health = envelope["health_attestation"] as! [String: Any]
    health["profile"] = "local_verified"
    envelope["health_attestation"] = health
    envelope["github"] = NSNull()
    envelope["apple"] = NSNull()
    envelope["spec_kit"] = NSNull()
    envelope["local_requirements"] = ["review_required": false, "spec_kit_required": false]
    envelope["action_grants"] = []
    envelope["resource_plan"] = []
    let currentContext = context
    XCTAssertEqual(Authorization.validateAuthorization(envelope, context: currentContext), [])

    let fingerprint = (envelope["repository"] as! [String: Any])["fingerprint"]!
    let descriptor: [String: Any] = [
      "identity_version": "github_remote_v2", "repository_fingerprint": fingerprint,
    ]
    envelope["resource_plan"] = [
      [
        "plan_id": "local-writer", "resource": "source_checkout_writer",
        "resource_key": try ResourceCoordinator.canonicalResourceKey(
          resource: "source_checkout_writer", descriptor: descriptor),
        "descriptor_sha256": try ResourceCoordinator.descriptorSHA256(
          resource: "source_checkout_writer", descriptor: descriptor),
        "resource_descriptor": descriptor, "owner_actor": envelope["selected_writer"]!,
        "protects": ["implement"],
      ]
    ]
    XCTAssertEqual(Authorization.validateAuthorization(envelope, context: currentContext), [])

    let original = try currentApprovedEnvelope()["action_grants"] as! [[String: Any]]
    var commit = original.first { $0["action"] as? String == "git.commit" }!
    commit["phase"] = "local_delivery"
    envelope["action_grants"] = [commit]
    XCTAssertEqual(Authorization.validateAuthorization(envelope, context: currentContext), [])

    var specEnvelope = envelope
    specEnvelope["local_requirements"] = ["review_required": false, "spec_kit_required": true]
    let repository = envelope["repository"] as! [String: Any]
    specEnvelope["spec_kit"] = [
      "release": "v1.0.1", "feature_id": "001-example", "feature_directory": "specs/001-example",
      "approved_git_branch": repository["branch"]!,
      "snapshot_sha256": String(repeating: "a", count: 64),
      "artifact_hashes": ["specs/001-example/spec.md": String(repeating: "b", count: 64)],
      "workflow_run_id": "run",
    ]
    XCTAssertEqual(Authorization.validateAuthorization(specEnvelope, context: currentContext), [])
  }

  func testGrantIdentityPhaseProducerAndTopologyMutationsFailClosedWithoutTrapping() throws {
    let envelope = try currentApprovedEnvelope()
    let currentContext = context
    let original = envelope["action_grants"] as! [[String: Any]]

    var duplicate = envelope
    duplicate["action_grants"] = original + [original[0]]
    XCTAssertTrue(
      Authorization.validateAuthorization(duplicate, context: currentContext).contains {
        $0.contains("IDs must be non-empty and unique")
      })

    var wrongPhase = envelope
    var grants = original
    let commit = grants.firstIndex { $0["action"] as? String == "git.commit" }!
    grants[commit]["phase"] = "testflight_upload"
    wrongPhase["action_grants"] = grants
    XCTAssertTrue(
      Authorization.validateAuthorization(wrongPhase, context: currentContext).contains {
        $0.contains("repository delivery action must use the pr_delivery phase")
      })

    var invalidProducer = envelope
    grants = original
    let push = grants.firstIndex { $0["action"] as? String == "git.push" }!
    grants[push]["produces_target_kind"] = "github_pr"
    invalidProducer["action_grants"] = grants
    XCTAssertTrue(
      Authorization.validateAuthorization(invalidProducer, context: currentContext).contains {
        $0.contains("only a GitHub create grant may produce a target")
      })

    var selfDerived = envelope
    grants = original
    let evidence = grants.firstIndex { $0["action"] as? String == "github.evidence.publish" }!
    grants[evidence]["target_from_grant_id"] = grants[evidence]["grant_id"]
    selfDerived["action_grants"] = grants
    XCTAssertTrue(
      Authorization.validateAuthorization(selfDerived, context: currentContext).contains {
        $0.contains("cannot derive its own target")
      })

    var duplicateIssueTransition = envelope
    grants = original
    let review = grants.firstIndex { $0["operation"] as? String == "transition_issue_in_review" }!
    grants[review]["operation"] = "transition_issue_in_progress"
    grants[review]["operation_input"] = ["state": "In Progress"]
    grants[review]["constraint_sha256"] = try Authorization.canonicalSHA256(
      grants[review]["operation_input"]!)
    duplicateIssueTransition["action_grants"] = grants
    XCTAssertTrue(
      Authorization.validateAuthorization(duplicateIssueTransition, context: currentContext)
        .contains { $0.contains("exact authorized state transitions") })

    var configuredProject = envelope
    var github = configuredProject["github"] as! [String: Any]
    github["project"] = ["id": "PVT_kwDOExample"]
    configuredProject["github"] = github
    XCTAssertTrue(
      Authorization.validateAuthorization(configuredProject, context: currentContext).contains {
        $0.contains("Project tracking grants")
      })
  }

  func testRuntimeUIRequiresPlansThatProtectRuntimeVerification() throws {
    var envelope = try currentApprovedEnvelope()
    envelope["health_profile"] = "runtime_ui"
    var health = envelope["health_attestation"] as! [String: Any]
    health["profile"] = "runtime_ui"
    envelope["health_attestation"] = health
    let currentContext = context
    let errors = Authorization.validateAuthorization(envelope, context: currentContext)
    XCTAssertTrue(
      errors.contains { $0.contains("build_tuple resource plan protecting runtime verification") })
    XCTAssertTrue(
      errors.contains {
        $0.contains("device or macOS GUI resource plan protecting runtime verification")
      })
  }

  func testPrepareRequestCreatesExclusivePrivateFile() throws {
    let run = try temporaryDirectory()
    var envelope = try HarnessRuntime.object(
      repositoryRoot.appendingPathComponent("tests/fixtures/run-authorization-approved.json"))
    let schema = repositoryRoot.appendingPathComponent(
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    let grant = (envelope["action_grants"] as! [[String: Any]]).first {
      $0["action"] as? String == "github.issue.update"
    }!
    let descriptor = try Authorization.canonicalResourceDescriptor(
      envelope, action: grant["action"] as! String)
    let receipt: [String: Any] = [
      "coordinator_instance_id": "c", "receipt_id": "r", "lease_id": "l",
      "owner_run_id": envelope["run_id"]!, "owner_actor": envelope["selected_writer"]!,
      "resource": "github_external_mutation", "resource_key": grant["resource_key"]!,
      "descriptor_sha256": "sha256:" + (try Authorization.canonicalSHA256(descriptor)),
      "fencing_token": 1, "acquired_at": "2026-01-01T00:00:03Z",
      "expires_at": "2097-01-01T00:00:00Z",
    ]
    let authURL = run.appendingPathComponent("authorization.json")
    let receiptURL = run.appendingPathComponent("receipt.json")
    let descriptorURL = run.appendingPathComponent("descriptor.json")
    let healthURL = run.appendingPathComponent("health.json")
    let output = run.appendingPathComponent("request.json")
    try write(envelope, authURL)
    try write(receipt, receiptURL)
    try write(descriptor, descriptorURL)
    try write(["ok": true], healthURL)
    let request = try PrepareActionRequest.prepare(
      authorizationPath: authURL, receiptPath: receiptURL, descriptorPath: descriptorURL,
      healthReportPath: healthURL, outputPath: output, runRoot: run,
      grantID: grant["grant_id"] as! String, target: grant["target"] as! String, paths: ["Sources"],
      context: context)
    XCTAssertEqual(Set(request.keys), Authorization.requestFields)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o600)
    XCTAssertThrowsError(
      try PrepareActionRequest.prepare(
        authorizationPath: authURL, receiptPath: receiptURL, descriptorPath: descriptorURL,
        healthReportPath: healthURL, outputPath: output, runRoot: run,
        grantID: grant["grant_id"] as! String, target: grant["target"] as! String,
        paths: ["Sources"], context: context))
  }

  func testPrivateAuthorizationInputsRejectHardLinksOutsideRunRoot() throws {
    let run = try temporaryDirectory()
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
    try write(["trusted": true], outside)
    let alias = run.appendingPathComponent("authorization.json")
    try FileManager.default.linkItem(at: outside, to: alias)
    XCTAssertThrowsError(try Authorization.loadStablePrivateJSON(alias, root: run))
    try FileManager.default.removeItem(at: alias)
    try write(["trusted": true], alias)
    XCTAssertNotNil(try Authorization.loadStablePrivateJSON(alias, root: run) as? [String: Any])
  }

  func testSwiftRuntimeBindingRejectsLegacyPythonIdentity() throws {
    let executable = URL(fileURLWithPath: "/bin/echo")
    XCTAssertEqual(
      Authorization.validateRuntimeBinding(
        ["runtime_kind": "python", "script_sha256": "sha256:" + String(repeating: "0", count: 64)],
        executable: executable
      ).first,
      "legacy Python authorization runtime binding is unsupported; rematerialize authorization state at the Swift v1 boundary"
    )
    let binding = try Authorization.runtimeBinding(executable: executable)
    XCTAssertEqual(Authorization.validateRuntimeBinding(binding, executable: executable), [])
    var drifted = binding
    drifted["executable_sha256"] = "sha256:" + String(repeating: "0", count: 64)
    XCTAssertFalse(Authorization.validateRuntimeBinding(drifted, executable: executable).isEmpty)
  }

  func testDispatchAppleProbeRevalidatesFreshStableState() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("asc-probe")
    let now = Date()
    let observedAt = HarnessRuntime.timestamp(now)
    let observation: [String: Any] = [
      "source": "asc_read_only", "guard_verified": true, "observed_at": observedAt,
      "account_guard_ref": "guard", "team_id": "TEAM", "app_id": "123",
      "bundle_id": "com.example.app", "platform": "ios", "live_build": "41",
      "internal_group_ids": ["group"],
    ]
    try writeProbe(observation, executable)
    let apple: [String: Any] = [
      "account_guard_ref": "guard", "team_id": "TEAM", "app_id": "123",
      "bundle_id": "com.example.app", "platform": "ios",
      "version_policy": ["mode": "exact", "value": "1.0"],
      "build_policy": ["mode": "next_after_live", "baseline": "41"],
      "artifact_policy": "fresh_archive_from_reviewed_pr_commit", "internal_group_ids": ["group"],
    ]
    let authorization: [String: Any] = ["apple": apple]
    let reservation: [String: Any] = [
      "action": "apple.testflight.upload",
      "apple_observation_sha256": try Authorization.canonicalSHA256(observation),
      "apple_observation_state_sha256": try Authorization.appleObservationStateSHA256(observation),
    ]
    let harness: [String: Any] = [
      "apple_observation_probe": [
        "executable": executable.path,
        "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
        "output_contract": "apple_observation_v1", "timeout_seconds": 10,
      ]
    ]
    XCTAssertEqual(
      Authorization.dispatchAppleStateErrors(
        authorization: authorization, reservation: reservation, trustedHarness: harness,
        reservedAt: now.addingTimeInterval(-1), verifiedAt: now), [])
    var drifted = observation
    drifted["live_build"] = "42"
    try writeProbe(drifted, executable)
    let driftedHarness: [String: Any] = [
      "apple_observation_probe": [
        "executable": executable.path,
        "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
        "output_contract": "apple_observation_v1", "timeout_seconds": 10,
      ]
    ]
    let errors = Authorization.dispatchAppleStateErrors(
      authorization: authorization, reservation: reservation, trustedHarness: driftedHarness,
      reservedAt: now.addingTimeInterval(-1), verifiedAt: now)
    XCTAssertTrue(
      errors.contains { $0.contains("baseline drifted") || $0.contains("state drifted") })
  }

  func testLedgerRejectsReservationReplayAndSecondDispatch() throws {
    let descriptor: [String: Any] = [
      "repository_fingerprint": "sha256:" + String(repeating: "a", count: 64),
      "remote_repository": "example/repository",
    ]
    let digest = "sha256:" + String(repeating: "b", count: 64)
    let health = "sha256:" + String(repeating: "c", count: 64)
    let grant: [String: Any] = [
      "grant_id": "g", "idempotency_key": "i", "system": "github", "action": "github.issue.update",
      "operation": "transition_issue_ready", "operation_input": ["state": "Ready"],
      "constraint_sha256": try Authorization.canonicalSHA256(["state": "Ready"]),
      "resource_key": "github_external_mutation:sha256:" + String(repeating: "d", count: 64),
      "phase": "pr_delivery", "target": "example/repository:issue:1",
    ]
    let receipt: [String: Any] = [
      "coordinator_instance_id": "c", "receipt_id": "r", "lease_id": "l", "owner_run_id": "run",
      "owner_actor": "codex", "resource": "github_external_mutation",
      "resource_key": grant["resource_key"]!,
      "descriptor_sha256": "sha256:" + (try Authorization.canonicalSHA256(descriptor)),
      "fencing_token": 1, "acquired_at": "2026-01-01T00:00:02Z",
      "expires_at": "2097-01-01T00:00:00Z",
    ]
    let approval = record(
      1, "approval",
      [
        "kind": "run_authorization", "decision": "approved", "approval_id": "approval",
        "authorization_hash": digest, "selected_writer": "codex",
        "repository_fingerprint": "sha256:" + String(repeating: "a", count: 64),
        "repository_base_sha": String(repeating: "1", count: 40), "allowed_paths": ["Sources"],
        "acceptance_ids": ["AC-1"], "issued_at": "2026-01-01T00:00:00Z",
        "expires_at": "2097-01-01T00:00:00Z", "action_grants": [grant],
      ], second: 1)
    let leasePayload: [String: Any] = [
      "lease_id": "l", "action": "acquire", "owner": "codex", "approval_id": "approval",
      "resource": "github_external_mutation", "resource_key": grant["resource_key"]!,
      "resource_descriptor": descriptor, "coordinator_receipt": receipt,
      "allowed_actions": ["github.issue.update"], "acquired_at": "2026-01-01T00:00:02Z",
      "expires_at": "2097-01-01T00:00:00Z",
    ]
    let reservationPayload: [String: Any] = [
      "reservation_id": "reservation", "authorization_hash": digest, "grant_id": "g",
      "idempotency_key": "i", "system": "github", "action": "github.issue.update",
      "operation": "transition_issue_ready", "operation_input": ["state": "Ready"],
      "constraint_sha256": grant["constraint_sha256"]!, "resource_key": grant["resource_key"]!,
      "phase": "pr_delivery", "target": grant["target"]!, "lease_id": "l", "lease_owner": "codex",
      "writer_actor": "codex", "resource": "github_external_mutation",
      "resource_descriptor": descriptor, "coordinator_receipt": receipt,
      "health_report_sha256": health,
    ]
    let dispatchPayload: [String: Any] = [
      "dispatch_id": "dispatch", "reservation_id": "reservation", "coordinator_receipt": receipt,
      "health_report_sha256": health, "dispatch_deadline": "2026-01-01T00:00:50Z",
    ]
    let base = [
      approval, record(2, "lease", leasePayload, second: 2),
      record(3, "grant_reservation", reservationPayload, second: 3),
      record(4, "grant_dispatch", dispatchPayload, second: 4),
    ]
    XCTAssertFalse(
      Authorization.standaloneLedgerLifecycleErrors(base, context: context).contains {
        $0.contains("unclaimed")
      })
    var secondDispatch = dispatchPayload
    secondDispatch["dispatch_id"] = "dispatch-2"
    let errors = Authorization.standaloneLedgerLifecycleErrors(
      base + [record(5, "grant_dispatch", secondDispatch, second: 5)], context: context)
    XCTAssertTrue(errors.contains { $0.contains("unclaimed exact reservation") })
  }

  func testDispatchAndExternalWriteRequireCurrentLeaseDeadlineAndProducedTarget() throws {
    let fingerprint = "sha256:" + String(repeating: "a", count: 64)
    let descriptor: [String: Any] = [
      "repository_fingerprint": fingerprint, "remote_repository": "example/repository",
    ]
    let digest = "sha256:" + String(repeating: "b", count: 64)
    let health = "sha256:" + String(repeating: "c", count: 64)
    let input: [String: Any] = ["title_policy": "accepted_plan", "body_policy": "accepted_plan"]
    let grant: [String: Any] = [
      "grant_id": "producer", "idempotency_key": "producer-key", "system": "github",
      "action": "github.issue.create", "operation": "ensure_feature_issue",
      "operation_input": input, "constraint_sha256": try Authorization.canonicalSHA256(input),
      "resource_key": "github_external_mutation:sha256:" + String(repeating: "d", count: 64),
      "phase": "pr_delivery", "target": "example/repository:feature:branch",
      "produces_target_kind": "github_issue",
    ]
    let receipt: [String: Any] = [
      "coordinator_instance_id": "c", "receipt_id": "r", "lease_id": "l", "owner_run_id": "run",
      "owner_actor": "codex", "resource": "github_external_mutation",
      "resource_key": grant["resource_key"]!,
      "descriptor_sha256": "sha256:" + (try Authorization.canonicalSHA256(descriptor)),
      "fencing_token": 1, "acquired_at": "2026-01-01T00:00:02Z",
      "expires_at": "2026-01-01T00:00:40Z",
    ]
    let approval = record(
      1, "approval",
      [
        "kind": "run_authorization", "decision": "approved", "approval_id": "approval",
        "authorization_hash": digest, "selected_writer": "codex",
        "repository_fingerprint": fingerprint,
        "repository_base_sha": String(repeating: "1", count: 40), "allowed_paths": ["Sources"],
        "acceptance_ids": ["AC-1"], "issued_at": "2026-01-01T00:00:00Z",
        "expires_at": "2026-01-01T00:00:40Z", "action_grants": [grant],
      ], second: 1)
    let lease: [String: Any] = [
      "lease_id": "l", "action": "acquire", "owner": "codex", "approval_id": "approval",
      "resource": "github_external_mutation", "resource_key": grant["resource_key"]!,
      "resource_descriptor": descriptor, "coordinator_receipt": receipt,
      "allowed_actions": ["github.issue.create"], "acquired_at": "2026-01-01T00:00:02Z",
      "expires_at": "2026-01-01T00:00:40Z",
    ]
    let reservation: [String: Any] = [
      "reservation_id": "reservation", "authorization_hash": digest, "grant_id": "producer",
      "idempotency_key": "producer-key", "system": "github", "action": "github.issue.create",
      "operation": "ensure_feature_issue", "operation_input": input,
      "constraint_sha256": grant["constraint_sha256"]!, "resource_key": grant["resource_key"]!,
      "phase": "pr_delivery", "target": grant["target"]!, "lease_id": "l", "lease_owner": "codex",
      "writer_actor": "codex", "resource": "github_external_mutation",
      "resource_descriptor": descriptor, "coordinator_receipt": receipt,
      "health_report_sha256": health,
    ]
    let lateDispatch: [String: Any] = [
      "dispatch_id": "dispatch", "reservation_id": "reservation", "coordinator_receipt": receipt,
      "health_report_sha256": health, "dispatch_deadline": "2026-01-01T00:00:50Z",
    ]
    let lateErrors = Authorization.standaloneLedgerLifecycleErrors(
      [
        approval, record(2, "lease", lease, second: 2),
        record(3, "grant_reservation", reservation, second: 3),
        record(4, "grant_dispatch", lateDispatch, second: 4),
      ], context: context)
    XCTAssertTrue(
      lateErrors.contains {
        $0.contains("deadline is invalid or exceeds lease/authorization authority")
      })

    let dispatch: [String: Any] = [
      "dispatch_id": "dispatch", "reservation_id": "reservation", "coordinator_receipt": receipt,
      "health_report_sha256": health, "dispatch_deadline": "2026-01-01T00:00:30Z",
    ]
    var write = reservation
    write["dispatch_id"] = "dispatch"
    write["outcome"] = "succeeded"
    write["output_target"] = "attacker/repository:issue:1"
    let outputErrors = Authorization.standaloneLedgerLifecycleErrors(
      [
        approval, record(2, "lease", lease, second: 2),
        record(3, "grant_reservation", reservation, second: 3),
        record(4, "grant_dispatch", dispatch, second: 4),
        record(5, "external_write", write, second: 5),
      ], context: context)
    XCTAssertTrue(outputErrors.contains { $0.contains("produced an invalid GitHub target") })

    let noLeaseErrors = Authorization.standaloneLedgerLifecycleErrors(
      [
        approval, record(2, "grant_reservation", reservation, second: 3),
        record(3, "grant_dispatch", dispatch, second: 4),
      ], context: context)
    XCTAssertTrue(noLeaseErrors.contains { $0.contains("lacks its exact active lease") })
    XCTAssertTrue(
      noLeaseErrors.contains { $0.contains("requires its exact active reservation lease") })

    var unauthorizedLease = lease
    unauthorizedLease["allowed_actions"] = []
    unauthorizedLease["approval_id"] = "another-approval"
    let unauthorizedErrors = Authorization.standaloneLedgerLifecycleErrors(
      [
        approval, record(2, "lease", unauthorizedLease, second: 2),
        record(3, "grant_reservation", reservation, second: 3),
      ], context: context)
    XCTAssertTrue(unauthorizedErrors.contains { $0.contains("lease approval binding") })
    XCTAssertTrue(unauthorizedErrors.contains { $0.contains("lacks its exact active lease") })

    var driftedTimeLease = lease
    driftedTimeLease["acquired_at"] = "2026-01-01T00:00:01Z"
    XCTAssertTrue(
      Authorization.standaloneLedgerLifecycleErrors(
        [approval, record(2, "lease", driftedTimeLease, second: 2)], context: context
      ).contains { $0.contains("acquisition times drifted") })

    let expiredErrors = Authorization.standaloneLedgerLifecycleErrors(
      [
        approval, record(2, "lease", lease, second: 2),
        record(3, "grant_reservation", reservation, second: 3),
        record(4, "grant_dispatch", dispatch, second: 4),
        record(5, "external_write", write, second: 41),
      ], context: context)
    XCTAssertTrue(expiredErrors.contains { $0.contains("outside authorization time bounds") })
    XCTAssertTrue(expiredErrors.contains { $0.contains("expired lease") })
  }

  func testLocalVerifiedRequiresCurrentAcceptanceAndConditionalReviewOmission() throws {
    let harness = try temporaryDirectory()
    let contracts = harness.appendingPathComponent("contracts")
    let schemas = contracts.appendingPathComponent("schemas")
    try FileManager.default.createDirectory(at: schemas, withIntermediateDirectories: true)
    let schema: [String: Any] = [
      "$id": "https://example.invalid/run-authorization.schema.json", "type": "object",
    ]
    try write(schema, schemas.appendingPathComponent("run-authorization.schema.json"))
    try write(
      [
        "nodes": [
          ["id": "verify", "requires": []],
          ["id": "local_verified", "requires": ["verify"], "terminal": true],
        ]
      ], contracts.appendingPathComponent("local-workflow.json"))
    let localContext = RuntimeContext(repositoryRoot: repositoryRoot, harnessRoot: harness)
    let manifest: [String: Any] = [
      "version": "patch_identity_v1", "base_sha": String(repeating: "1", count: 40),
      "records": [
        [
          "path": "Sources/App.swift", "mode": "100644", "state": "modified",
          "content_sha256": "sha256:" + String(repeating: "c", count: 64),
        ]
      ],
    ]
    let patch = try Authorization.patchIdentityV1(manifest)
    let fingerprint = "sha256:" + String(repeating: "a", count: 64)
    let approval: [String: Any] = [
      "kind": "run_authorization", "decision": "approved",
      "authorization_hash": "sha256:" + String(repeating: "b", count: 64),
      "selected_writer": "codex",
      "repository_fingerprint": fingerprint,
      "repository_base_sha": String(repeating: "1", count: 40), "allowed_paths": ["Sources"],
      "acceptance_ids": ["AC-1"],
      "issued_at": "2026-01-01T00:00:00Z", "expires_at": "2097-01-01T00:00:00Z",
      "action_grants": [], "resource_plan": [], "delivery_target": "local_verified",
      "contract_schema_id": schema["$id"]!,
      "contract_schema_sha256": "sha256:"
        + (try HarnessRuntime.sha256File(
          schemas.appendingPathComponent("run-authorization.schema.json"))),
      "local_requirements": ["review_required": false, "spec_kit_required": false],
    ]
    let tuple: [String: Any] = [
      "provider": "xcode", "tool": "xcodebuild", "tool_version": "1", "command_or_call": "test",
      "started_at": "2026-01-01T00:00:01Z", "ended_at": "2026-01-01T00:00:02Z", "exit_status": 0,
      "verification_scope": "minimum-sufficient", "evidence_layer": "build", "platform": "ios",
      "destination": "generic/platform=iOS Simulator",
      "coverage": [
        [
          "acceptance_id": "AC-1", "observable_contract": "builds",
          "prevented_failure": "compile regression", "unique_path": "swift test",
          "result": "passed",
        ]
      ], "artifacts": [],
      "omitted_checks": ["independent_review:not_required_by_accepted_plan"],
    ]
    let evidence: [String: Any] = [
      "evidence_id": "e1", "evidence_kind": "acceptance", "outcome": "passed",
      "patch_manifest": manifest, "patch_identity": patch, "repository_fingerprint": fingerprint,
      "acceptance_ids": ["AC-1"], "tool_tuple": tuple,
    ]
    let node: [String: Any] = [
      "status": "passed", "patch_manifest": manifest, "patch_identity": patch,
    ]
    let valid = [
      record(1, "approval", approval, second: 1), record(2, "evidence", evidence, second: 3),
      record(3, "node", node.merging(["node_id": "verify"]) { _, new in new }, second: 4),
      record(4, "node", node.merging(["node_id": "local_verified"]) { _, new in new }, second: 5),
    ]
    XCTAssertFalse(
      Authorization.standaloneLedgerLifecycleErrors(valid, context: localContext).contains {
        $0.contains("local_verified")
      })
    var missingOmission = evidence
    var missingTuple = tuple
    missingTuple["omitted_checks"] = []
    missingOmission["tool_tuple"] = missingTuple
    let invalid = [valid[0], record(2, "evidence", missingOmission, second: 3), valid[2], valid[3]]
    XCTAssertTrue(
      Authorization.standaloneLedgerLifecycleErrors(invalid, context: localContext).contains {
        $0.contains("record why independent review was omitted")
      })

    let acceptedArtifacts: [[String: Any]] = [
      ["path": "specs/001-example/spec.md", "sha256": String(repeating: "d", count: 64), "size": 1]
    ]
    let immutableSnapshot: [String: Any] = [
      "schema_version": "1.0.0", "spec_kit_release": "v1.0.1", "feature_id": "001-example",
      "feature_directory": "specs/001-example", "accepted_artifacts": acceptedArtifacts,
    ]
    var snapshot = immutableSnapshot
    snapshot["artifact_hashes"] = ["specs/001-example/spec.md": String(repeating: "d", count: 64)]
    snapshot["snapshot_sha256"] = try Authorization.canonicalSHA256(immutableSnapshot)
    snapshot["workflow_checkpoint"] = NSNull()
    var specApproval = approval
    specApproval["local_requirements"] = ["review_required": false, "spec_kit_required": true]
    specApproval["spec_kit"] = [
      "release": "v1.0.1", "feature_id": "001-example", "feature_directory": "specs/001-example",
      "approved_git_branch": "branch", "snapshot_sha256": snapshot["snapshot_sha256"]!,
      "artifact_hashes": snapshot["artifact_hashes"]!, "workflow_run_id": "run",
    ]
    let missingSpec = [
      record(1, "approval", specApproval, second: 1), valid[1], valid[2], valid[3],
    ]
    XCTAssertTrue(
      Authorization.standaloneLedgerLifecycleErrors(missingSpec, context: localContext).contains {
        $0.contains("requires one current Spec Kit checkpoint")
      })
    let specTuple: [String: Any] = [
      "provider": "speckit", "tool": "spec-kit", "tool_version": "v1.0.1",
      "command_or_call": "snapshot", "started_at": "2026-01-01T00:00:01Z",
      "ended_at": "2026-01-01T00:00:02Z", "exit_status": 0, "spec_kit_snapshot": snapshot,
    ]
    let specEvidence: [String: Any] = [
      "evidence_id": "spec", "evidence_kind": "spec_kit_checkpoint", "outcome": "passed",
      "patch_manifest": manifest, "patch_identity": patch, "repository_fingerprint": fingerprint,
      "acceptance_ids": [], "tool_tuple": specTuple,
    ]
    let withSpec = [
      record(1, "approval", specApproval, second: 1), valid[1],
      record(3, "evidence", specEvidence, second: 3),
      record(4, "node", node.merging(["node_id": "verify"]) { _, new in new }, second: 4),
      record(5, "node", node.merging(["node_id": "local_verified"]) { _, new in new }, second: 5),
    ]
    XCTAssertFalse(
      Authorization.standaloneLedgerLifecycleErrors(withSpec, context: localContext).contains {
        $0.contains("local_verified Spec Kit") || $0.contains("requires one current Spec Kit")
      })
  }

  func testKnowledgeAndFeedbackRecordsAreRecognizedAndValidated() {
    let valid = [
      record(
        1, "knowledge",
        [
          "source_id": "source", "authority": "accepted_spec",
          "content_hash": "sha256:" + String(repeating: "a", count: 64), "provenance": "repository",
        ], second: 1),
      record(
        2, "feedback",
        [
          "feedback_id": "feedback", "actor": "reviewer", "scope": "current_run", "target": "patch",
          "summary": "accepted", "disposition": "accepted", "invalidates": [],
        ], second: 2),
    ]
    let errors = Authorization.standaloneLedgerLifecycleErrors(valid, context: context)
    XCTAssertFalse(
      errors.contains {
        $0.contains("unsupported") || $0.contains("feedback record")
          || $0.contains("knowledge record")
      })
    var duplicate = valid
    duplicate.append(
      record(
        3, "feedback",
        [
          "feedback_id": "feedback", "actor": "reviewer", "scope": "current_run", "target": "patch",
          "summary": "duplicate", "disposition": "accepted",
        ], second: 3))
    XCTAssertTrue(
      Authorization.standaloneLedgerLifecycleErrors(duplicate, context: context).contains {
        $0.contains("unique valid disposition")
      })
  }

  func testLedgerRejectsFractionalSequence() {
    let fractional: [String: Any] = [
      "schema_version": "1.0.0", "run_id": "run", "sequence": 1.5,
      "recorded_at": "2026-01-01T00:00:01Z", "record_type": "attempt", "payload": [:],
    ]
    XCTAssertTrue(
      Authorization.standaloneLedgerLifecycleErrors([fractional], context: context).contains {
        $0.contains("strictly increase")
      })
  }

  private func record(_ sequence: Int, _ type: String, _ payload: [String: Any], second: Int)
    -> [String: Any]
  {
    [
      "schema_version": "1.0.0", "run_id": "run", "sequence": sequence,
      "recorded_at": String(format: "2026-01-01T00:00:%02dZ", second), "record_type": type,
      "payload": payload,
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
  private func write(_ object: Any, _ url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url)
  }
  private func writeProbe(_ object: Any, _ url: URL) throws {
    let json = String(
      decoding: try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    try Data("#!/bin/sh\nprintf '%s' '\(json)'\n".utf8).write(to: url)
    XCTAssertEqual(chmod(url.path, 0o700), 0)
  }
}
