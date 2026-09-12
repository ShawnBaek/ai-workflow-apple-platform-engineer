import XCTest
@testable import AppleVerificationCore

final class SpecKitSnapshotTests: XCTestCase {
  func testSnapshotAllowsRunProgressButRejectsLogRewriteAndArtifactDrift() throws {
    let root = try makeSpecKit()
    let expected = try SpecKitSnapshot.buildSnapshot(
      root: root, runID: "run-1", featureDirectory: "specs/001-example")
    try Data("{\"event\":\"two\"}\n".utf8).append(
      to: root.appendingPathComponent(".specify/workflows/runs/run-1/log.jsonl"))
    let progressed = try SpecKitSnapshot.buildSnapshot(
      root: root, runID: "run-1", featureDirectory: "specs/001-example")
    XCTAssertEqual(SpecKitSnapshot.verifySnapshot(expected: expected, current: progressed), [])
    try Data("{\"event\":\"rewritten\"}\n".utf8).write(
      to: root.appendingPathComponent(".specify/workflows/runs/run-1/log.jsonl"))
    let rewritten = try SpecKitSnapshot.buildSnapshot(
      root: root, runID: "run-1", featureDirectory: "specs/001-example")
    XCTAssertTrue(
      SpecKitSnapshot.verifySnapshot(expected: expected, current: rewritten).contains(
        "Spec Kit workflow log was rewritten"))
    try Data("changed".utf8).write(to: root.appendingPathComponent("specs/001-example/spec.md"))
    let changed = try SpecKitSnapshot.buildSnapshot(
      root: root, runID: "run-1", featureDirectory: "specs/001-example")
    XCTAssertTrue(
      SpecKitSnapshot.verifySnapshot(expected: expected, current: changed).contains(
        "accepted Spec Kit artifact set or content changed"))
  }

  func testSnapshotRejectsStalePointerAndSymlinkArtifact() throws {
    let root = try makeSpecKit()
    XCTAssertThrowsError(
      try SpecKitSnapshot.buildSnapshot(root: root, featureDirectory: "specs/other"))
    try FileManager.default.removeItem(
      at: root.appendingPathComponent("specs/001-example/tasks.md"))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("specs/001-example/tasks.md").path,
      withDestinationPath: "/etc/hosts")
    XCTAssertThrowsError(
      try SpecKitSnapshot.buildSnapshot(root: root, featureDirectory: "specs/001-example"))
  }

  private func makeSpecKit() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let feature = root.appendingPathComponent("specs/001-example")
    let run = root.appendingPathComponent(".specify/workflows/runs/run-1")
    try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".specify"), withIntermediateDirectories: true)
    try Data("{\"feature_directory\":\"specs/001-example\"}".utf8).write(
      to: root.appendingPathComponent(".specify/feature.json"))
    for name in ["spec.md", "plan.md", "tasks.md"] {
      try Data(name.utf8).write(to: feature.appendingPathComponent(name))
    }
    try Data("{\"run_id\":\"run-1\",\"workflow_id\":\"speckit\",\"status\":\"paused\"}".utf8).write(
      to: run.appendingPathComponent("state.json"))
    try Data("{\"inputs\":{}}".utf8).write(to: run.appendingPathComponent("inputs.json"))
    try Data("{\"event\":\"one\"}\n".utf8).write(to: run.appendingPathComponent("log.jsonl"))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

extension Data {
  fileprivate func append(to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: self)
  }
}
