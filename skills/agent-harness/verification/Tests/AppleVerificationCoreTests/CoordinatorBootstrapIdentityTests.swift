import Darwin
import XCTest

@testable import AppleVerificationCore

final class CoordinatorBootstrapIdentityTests: XCTestCase {
  private var repository: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
  }

  private var harnessRoot: URL { repository.appendingPathComponent("skills/agent-harness") }

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

  private func response(_ result: ProcessResult) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
      result.stdout + result.stderr)
  }

  // MARK: Bootstrap existence checks

  func testBootstrapQueuedBehindAFirstBootstrapAdoptsTheStateItPublishes() throws {
    let root = try temporaryRoot()
    let state = root.appendingPathComponent("coordinator.json")
    let published = try temporaryRoot().appendingPathComponent("coordinator.json")
    let first = try ResourceCoordinator.bootstrap(statePath: published, legacyLeasesQuiesced: true)

    // Another process is mid-way through the first bootstrap: it holds the lock it just created
    // and has not published the state yet.
    let second = Process()
    second.executableURL = executable
    second.arguments = [
      "--repository-root", repository.path, "resources", state.path, "bootstrap",
      "--legacy-leases-quiesced",
    ]
    let output = Pipe()
    second.standardOutput = output
    try HarnessRuntime.withFileLock(at: URL(fileURLWithPath: state.path + ".lock")) {
      try second.run()
      // Long enough for the second bootstrap to look at the path and queue for the lock.
      Thread.sleep(forTimeInterval: 1)
      XCTAssertTrue(second.isRunning, "a queued bootstrap must wait for the lock holder")
      try FileManager.default.copyItem(at: published, to: state)
    }
    second.waitUntilExit()
    let result = try XCTUnwrap(
      JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile())
        as? [String: Any])
    XCTAssertEqual(second.terminationStatus, 0, "\(result)")
    let adopted = try XCTUnwrap(result["result"] as? [String: Any], "\(result)")
    XCTAssertEqual(adopted["already_bootstrapped"] as? Bool, true)
    XCTAssertEqual(
      adopted["coordinator_instance_id"] as? String, first["coordinator_instance_id"] as? String)
  }

  func testFailedFirstBootstrapRemovesItsLockButAnOrphanedLockStillNeedsReview() throws {
    let root = try temporaryRoot()
    let state = root.appendingPathComponent("coordinator.json")
    let lock = URL(fileURLWithPath: state.path + ".lock")

    // A lock this call did not create, without state, is orphaned and is never adopted.
    FileManager.default.createFile(atPath: lock.path, contents: Data())
    XCTAssertThrowsError(
      try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "invalid_state_path") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    try FileManager.default.removeItem(at: lock)

    // A dangling link at the state path makes the first atomic publication fail after the lock
    // was created; nothing was published, so the lock must not outlive the attempt.
    try FileManager.default.createSymbolicLink(
      at: state, withDestinationURL: root.appendingPathComponent("absent.json"))
    XCTAssertThrowsError(
      try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    ) { XCTAssertEqual(($0 as? ResourceCoordinatorError)?.code, "io_error") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))

    try FileManager.default.removeItem(at: state)
    let retried = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    XCTAssertEqual(retried["already_bootstrapped"] as? Bool, false)
    XCTAssertEqual(
      try ResourceCoordinator.status(statePath: state)["coordinator_instance_id"] as? String,
      retried["coordinator_instance_id"] as? String)
  }

  // MARK: Executable identity

  func testBareNameInvocationFindsTheInstalledContractsOfTheRunningBinary() throws {
    let elsewhere = try temporaryRoot()
    // A shell PATH lookup leaves argv[0] as the bare name, whatever the working directory.
    let result = try HarnessRuntime.run(
      executable: "/usr/bin/env",
      arguments: [
        "PATH=\(executable.deletingLastPathComponent().path)", "apple-verify", "runtime-identity",
      ], directory: elsewhere, timeout: 30)
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    let identity = try response(result)
    XCTAssertEqual(identity["executable_path"] as? String, executable.path)
    XCTAssertEqual(
      identity["executable_sha256"] as? String,
      "sha256:" + (try HarnessRuntime.sha256File(executable)))
    XCTAssertEqual(
      identity["source_bundle_sha256"] as? String,
      try ResourceCoordinator.sourceBundleSHA256(skillRoot: harnessRoot))
  }

  func testLinkedInvocationPassesTheSameExecutableBindingAsTheBinaryItNames() throws {
    let root = try temporaryRoot()
    let state = root.appendingPathComponent("coordinator.json")
    let boot = try ResourceCoordinator.bootstrap(statePath: state, legacyLeasesQuiesced: true)
    var harness = try HarnessRuntime.object(
      harnessRoot.appendingPathComponent("templates/harness-local.json"))
    harness["authoritative_root"] = root.path
    harness["private_policy_overlay"] = root.appendingPathComponent("policy.json").path
    harness["run_authorization"] = root.appendingPathComponent("authorization.json").path
    harness["run_ledger"] = root.appendingPathComponent("ledger.jsonl").path
    harness["resource_coordinator"] = [
      "runtime_kind": ResourceCoordinator.runtimeKind,
      "runtime_contract": ResourceCoordinator.runtimeContract, "state_path": state.path,
      "coordinator_instance_id": boot["coordinator_instance_id"]!,
      "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
      "source_bundle_sha256": try ResourceCoordinator.sourceBundleSHA256(skillRoot: harnessRoot),
    ]
    let harnessPath = root.appendingPathComponent("harness.json")
    try HarnessRuntime.atomicWriteJSON(harness, to: harnessPath)
    let link = root.appendingPathComponent("apple-verify")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

    // A receipt without an owner passes every binding check and then fails as the wrong writer,
    // so `writer_mismatch` shows the executable binding held.
    let arguments = [
      "--repository-root", repository.path, "resources", state.path, "verify", "--harness",
      harnessPath.path, "--receipt", "{}",
    ]
    for invoked in [executable, link] {
      let result = try HarnessRuntime.run(
        executable: invoked.path, arguments: arguments, timeout: 30)
      XCTAssertEqual(result.exitCode, 2, invoked.path)
      XCTAssertEqual(
        try response(result)["reason_code"] as? String, "writer_mismatch", invoked.path)
    }
  }
}
