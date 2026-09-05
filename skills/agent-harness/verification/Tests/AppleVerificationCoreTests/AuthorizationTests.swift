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