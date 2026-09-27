import XCTest

@testable import AppleVerificationCore

/// capabilities.json is the one source of capability values, and one implementation judges
/// companion-upstream provenance for both of its callers.
final class ContractSingleSourceTests: XCTestCase {
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

  // MARK: Capability policy

  func testReviewedPolicyChangeIsEnforcedAtRuntime() throws {
    let envelope = try writerLeaseAuthorization()
    let shipped = try installedContracts(reviewed: false) { _ in }
    XCTAssertEqual(Authorization.validateAuthorization(envelope, context: shipped), [])

    // The value is edited in capabilities.json alone; its digest stands in for the reviewed pin.
    let narrowed = try installedContracts(reviewed: true) { policy in
      policy["resource_scopes"] = (policy["resource_scopes"] as! [String]).filter {
        $0 != "source_checkout_writer"
      }
    }
    XCTAssertEqual(
      Authorization.validateAuthorization(envelope, context: narrowed),
      ["authorization resource plan uses an unknown resource"])
  }

  func testRuntimeRefusesTamperedMalformedOrUnimplementedPolicy() throws {
    let envelope = try writerLeaseAuthorization()
    func coordination(_ policy: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
      var value = policy["cross_run_coordination_policy"] as! [String: Any]
      edit(&value)
      policy["cross_run_coordination_policy"] = value
    }
    let cases: [(reason: String, reviewed: Bool, edit: (inout [String: Any]) -> Void)] = [
      (
        "not the reviewed policy", false,
        { policy in
          coordination(&policy) { value in
            var expiry = value["lease_expiry"] as! [String: Any]
            expiry["silent_takeover"] = true
            value["lease_expiry"] = expiry
          }
        }
      ),
      (
        "schema violation", true,
        { policy in coordination(&policy) { $0["max_ttl_seconds"] = "1" } }
      ),
      (
        "lease ceiling", true, { policy in coordination(&policy) { $0["max_ttl_seconds"] = 7_200 } }
      ),
    ]
    for (reason, reviewed, edit) in cases {
      let context = try installedContracts(reviewed: reviewed, editing: edit)
      let errors = Authorization.validateAuthorization(envelope, context: context)
      // One rejection of the policy, not a second error for every planned resource.
      XCTAssertEqual(errors.count, 1, "\(reason): \(errors)")
      XCTAssertTrue(
        errors.contains {
          $0.hasPrefix("installed capability policy is rejected") && $0.contains(reason)
        }, "\(reason): \(errors)")
    }
  }

  // MARK: Companion provenance

  func testWatcherAndHealthGiveTheSameProvenanceVerdict() throws {
    let collection = try temporaryDirectory()
    let contracts = collection.appendingPathComponent("icon-composer/contracts")
    try FileManager.default.createDirectory(at: contracts, withIntermediateDirectories: true)
    let shipped = repositoryRoot.appendingPathComponent("skills/icon-composer/contracts")
    for name in ["companion-upstream.json", "companion-upstream.schema.json"] {
      try FileManager.default.copyItem(
        at: shipped.appendingPathComponent(name), to: contracts.appendingPathComponent(name))
    }
    let manifest = try HarnessRuntime.object(
      contracts.appendingPathComponent("companion-upstream.json"))
    let upstream = manifest["upstream"] as! [String: Any]
    let repository = upstream["repository"] as! String
    let reviewed = upstream["reviewed_revision"] as! String
    let tree = upstream["reviewed_tree"] as! String
    let consumer = (manifest["integration"] as! [String: Any])["consumer_repository"] as! String
    let blobs: [[String: Any]] = (manifest["sources"] as! [[String: Any]]).map {
      ["type": "blob", "path": $0["path"]!, "sha": $0["blob_sha"]!]
    }
    func answers(listing: [String: Any]? = nil, head: String? = nil) -> [String: Any] {
      [
        "repos/\(repository)": [
          "private": false, "visibility": "public", "default_branch": "main",
        ],
        "repos/\(repository)/commits/\(reviewed)": [
          "sha": reviewed, "commit": ["tree": ["sha": tree]],
        ],
        "repos/\(repository)/git/trees/\(tree)?recursive=1": listing
          ?? ["truncated": false, "tree": blobs],
        "repos/\(repository)/commits/main": ["sha": head ?? reviewed],
      ]
    }
    let harness: [String: Any] = [
      "selected_writer": "codex",
      "agent_skills": [
        "installations": ["codex": ["collection_root": collection.path], "claude": NSNull()]
      ],
    ]
    func verdicts(_ answers: [String: Any]) -> (watcher: Bool, health: String?) {
      let github = UpstreamAnswers(answers)
      let watcher =
        (try? CompanionWatcher.reconcileIssue(
          manifest, targetRepository: consumer, client: github)) != nil
      let health =
        HealthEvaluation.collectLiveObservations(
          report: ["required_check_ids": ["companion_upstream.provenance"]], harness: harness,
          policy: [:], authorization: nil, runner: github)["companion_upstream.provenance"]?[
          "status"] as? String
      XCTAssertEqual(github.writes, 0)
      return (watcher, health)
    }

    let reviewedAnswers = verdicts(answers())
    XCTAssertTrue(reviewedAnswers.watcher)
    XCTAssertEqual(reviewedAnswers.health, "healthy")
    // Each answer is one the two call sites used to judge differently.
    let shadowed = blobs + [["type": "tree", "path": blobs[0]["path"]!, "sha": tree]]
    for (label, bad) in [
      ("truncated tree", answers(listing: ["truncated": true, "tree": blobs])),
      ("path listed twice", answers(listing: ["truncated": false, "tree": shadowed])),
      ("abbreviated HEAD", answers(head: String(reviewed.prefix(12)))),
    ] {
      let verdict = verdicts(bad)
      XCTAssertFalse(verdict.watcher, label)
      XCTAssertEqual(verdict.health, "blocked", label)
    }
    // Completeness comes from GitHub's `truncated` flag, so a complete tree over the health
    // check's former 1 MiB read limit passes both, as it always passed the watcher.
    let padding: [[String: Any]] = (0..<15_000).map {
      ["type": "blob", "path": "Padding/\($0).png", "sha": tree]
    }
    let large: [String: Any] = ["truncated": false, "tree": blobs + padding]
    XCTAssertGreaterThan(try JSONSerialization.data(withJSONObject: large).count, 1_048_576)
    let largeVerdict = verdicts(answers(listing: large))
    XCTAssertTrue(largeVerdict.watcher)
    XCTAssertEqual(largeVerdict.health, "healthy")
  }

  // MARK: Fixtures

  /// A copy of the shipped contracts whose capabilities.json went through `edit`. With
  /// `reviewed`, the runtime accepts the edited file's digest, as after a reviewed pin update.
  private func installedContracts(
    reviewed: Bool, editing edit: (inout [String: Any]) -> Void
  ) throws -> RuntimeContext {
    let harness = try temporaryDirectory()
    try FileManager.default.copyItem(
      at: repositoryRoot.appendingPathComponent("skills/agent-harness/contracts"),
      to: harness.appendingPathComponent("contracts"))
    let file = harness.appendingPathComponent("contracts/capabilities.json")
    var policy = try HarnessRuntime.object(file)
    edit(&policy)
    try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]).write(to: file)
    let digest =
      try reviewed
      ? XCTUnwrap(CapabilityPolicy.canonicalSHA256(HarnessRuntime.object(file)))
      : CapabilityPolicy.reviewedSHA256
    return RuntimeContext(
      repositoryRoot: repositoryRoot, harnessRoot: harness, reviewedCapabilitySHA256: digest)
  }

  /// The approved fixture as a local run that plans one source-writer lease.
  private func writerLeaseAuthorization() throws -> [String: Any] {
    var envelope = try HarnessRuntime.object(
      repositoryRoot.appendingPathComponent("tests/fixtures/run-authorization-approved.json"))
    let schema = repositoryRoot.appendingPathComponent(
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json")
    envelope["$schema"] = schema.absoluteString
    envelope["contract_schema_sha256"] = "sha256:" + (try HarnessRuntime.sha256File(schema))
    envelope["delivery_target"] = "local_verified"
    envelope["health_profile"] = "local_verified"
    var health = envelope["health_attestation"] as! [String: Any]
    health["profile"] = "local_verified"
    envelope["health_attestation"] = health
    for field in ["github", "apple", "spec_kit"] { envelope[field] = NSNull() }
    envelope["local_requirements"] = ["review_required": false, "spec_kit_required": false]
    envelope["action_grants"] = []
    let descriptor: [String: Any] = [
      "identity_version": "github_remote_v2",
      "repository_fingerprint": (envelope["repository"] as! [String: Any])["fingerprint"]!,
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
    return envelope
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}

/// Serves one set of GitHub answers to the watcher's API client and to the health check's
/// `gh api` runner, so both judge exactly the same upstream.
private final class UpstreamAnswers: CompanionGitHubClient, HealthProbeRunning {
  let answers: [String: Any]
  private(set) var writes = 0
  init(_ answers: [String: Any]) { self.answers = answers }
  func request(method: String, path: String, body: [String: Any]?) throws -> Any {
    guard method == "GET" else {
      writes += 1
      throw VerificationError.invalid("unexpected write")
    }
    guard let answer = answers[path] else {
      throw VerificationError.invalid("unexpected route \(path)")
    }
    return answer
  }
  func run(
    executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
    timeout: TimeInterval, maxOutputBytes: Int
  ) -> ProcessResult {
    guard executable == "gh", arguments.count == 2, arguments[0] == "api",
      let answer = answers[arguments[1]],
      let data = try? JSONSerialization.data(withJSONObject: answer)
    else {
      return ProcessResult(
        stdout: "", stderr: "unexpected invocation", exitCode: 1, timedOut: false, truncated: false
      )
    }
    return ProcessResult(
      stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0, timedOut: false,
      truncated: data.count > maxOutputBytes)
  }
}
