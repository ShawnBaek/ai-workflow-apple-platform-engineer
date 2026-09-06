import XCTest

@testable import AppleVerificationCore

final class CLIInvocationTests: XCTestCase {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var executable: URL {
    // Use the product beside this test bundle, never an arbitrary older build.
    Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("apple-verify").resolvingSymlinksInPath()
  }

  func testExternalAppKeepsInstalledRuntimeIdentityAndMaterializesLocalTemplate() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app) }
    let harness = root.appendingPathComponent("skills/agent-harness")
    let result = try HarnessRuntime.run(
      executable: executable.path,
      arguments: ["--repository-root", root.path, "--app-root", app.path, "runtime-identity"],
      timeout: 10)
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    XCTAssertEqual(result.stderr, "")
    guard result.exitCode == 0 else { return }
    let identity = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(identity["runtime_kind"] as? String, "swift")
    XCTAssertEqual(identity["executable_path"] as? String, executable.path)
    XCTAssertEqual(
      identity["source_bundle_sha256"] as? String,
      try ResourceCoordinator.sourceBundleSHA256(skillRoot: harness))

    // Also exercise installed-root discovery with the flags in the documented form.
    let output = app.appendingPathComponent("harness.json")
    let materialized = try HarnessRuntime.run(
      executable: executable.path,
      arguments: [
        "--app-root", app.path, "materialize",
        "--template", harness.appendingPathComponent("templates/harness-local.json").path,
        "--schema", harness.appendingPathComponent("contracts/schemas/harness.schema.json").path,
        "--output", output.path,
      ], timeout: 10)
    XCTAssertEqual(materialized.exitCode, 0, materialized.stdout + materialized.stderr)
    guard materialized.exitCode == 0 else { return }
    let document = try HarnessRuntime.object(output)
    XCTAssertEqual(document["delivery_target"] as? String, "local_verified")
    XCTAssertEqual((document["github_tracking"] as? [String: Any])?["issues"] as? Bool, false)
  }

  func testGlobalRootOptionsRejectAmbiguousOrIncompleteArguments() throws {
    let cases: [([String], String)] = [
      (["--app-root", "relative", "runtime-identity"], "absolute"),
      (["--app-root", "/a", "--app-root", "/b", "runtime-identity"], "duplicate --app-root"),
      (["--repository-root", root.path, "--repository-root", root.path, "runtime-identity"],
        "duplicate --repository-root"),
      (["--app-root", "/a"], "path and command"),
      (["--repository-root"], "path and command"),
      (["--app-root", "--repository-root", root.path, "runtime-identity"], "path and command"),
    ]
    for (arguments, diagnostic) in cases {
      let result = try HarnessRuntime.run(
        executable: executable.path, arguments: arguments, timeout: 10)
      XCTAssertEqual(result.exitCode, 2, "\(arguments): \(result.stderr)")
      XCTAssertTrue(result.stderr.contains(diagnostic), "\(arguments): \(result.stderr)")
    }
  }

  func testResourcesCLIKeepsNonContentionFailureShapeAndExitCode() throws {
    let result = try HarnessRuntime.run(
      executable: executable.path,
      arguments: ["--repository-root", root.path, "resources", "relative", "status"],
      timeout: 10)
    XCTAssertEqual(result.exitCode, 2, result.stdout + result.stderr)
    XCTAssertEqual(result.stderr, "")
    let response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(Set(response.keys), ["status", "reason_code"])
    XCTAssertEqual(response["status"] as? String, "blocked")
    XCTAssertEqual(response["reason_code"] as? String, "migration_required")
  }
}
