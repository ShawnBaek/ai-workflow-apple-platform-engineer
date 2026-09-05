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




}
