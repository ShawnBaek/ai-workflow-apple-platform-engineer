import Foundation
import Testing

@testable import AppleVerificationCore

private final class BundleMarker {}

/// The product beside this test bundle, never an arbitrary older build.
private var executable: String {
  Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("apple-verify").resolvingSymlinksInPath().path
}

/// Runs the built command against `fixture` with only `HOME` in its environment.
private func inventory(_ fixture: SkillInventoryFixture, _ extra: [String] = [])
  throws -> ProcessResult
{
  try HarnessRuntime.run(
    executable: executable,
    arguments: [
      "--repository-root", fixture.collection.path, "skill-inventory", "--project",
      fixture.project.path,
    ] + extra,
    environment: ["HOME": fixture.home.path, "PATH": "/usr/bin:/bin"], timeout: 60,
    maxOutputBytes: 8 * 1_024 * 1_024)
}

@Test func theCommandLeavesEveryScannedFileLinkAndModeUnchanged() throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  // Two older bundles, so a copy's VERSION file and lifecycle file are read too: one recognized
  // by the harness contracts, one by a lifecycle file that names this repository.
  let bundles = [
    ("beta9", "2.0.0-beta.9", "sketch-design-from-codebase", "contracts/capabilities.json", "{}"),
    (
      "beta11", "2.0.0-beta.11", "xcode-project-workflow", "lifecycle/skill-lifecycle.json",
      #"{"source": "ShawnBaek/ai-workflow-apple-platform-engineer"}"#
    ),
  ]
  for (bundle, version, name, marker, text) in bundles {
    try fixture.write("bundles/\(bundle)/VERSION", "\(version)\n")
    try fixture.write("bundles/\(bundle)/skills/agent-harness/\(marker)", text)
    try fixture.skill("bundles/\(bundle)/skills/\(name)", "An older \(name).")
    try fixture.link(
      "home/.claude/skills/\(name)",
      to: fixture.base.appendingPathComponent("bundles/\(bundle)/skills/\(name)").path)
  }
  let before = try SkillInventoryFixture.snapshot(fixture.base)
  #expect(before.count > 60)
  #expect(before.values.contains { $0.hasPrefix("link ") })
  let result = try inventory(fixture)
  let after = try SkillInventoryFixture.snapshot(fixture.base)
  // Attention: the fixture has findings. The report came from the lifecycle file inside the
  // verifier's own harness folder (`--repository-root`).
  #expect(result.exitCode == 1, "\(result.stderr)")
  #expect(result.stderr == "")
  let report = try #require(
    try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
  #expect((report["collection"] as? [String: Any])?["version"] as? String == "1.0.0")
  #expect(inventoryFinding(report, "retired", "native-app-lead") != nil)
  for (bundle, version, name, _, _) in bundles {
    let root = try #require(
      SkillInventory.realPath(fixture.base.appendingPathComponent("bundles/\(bundle)").path))
    #expect(
      inventoryFinding(report, "outdated", name)?["installedFrom"] as? [String: String] == [
        "root": root, "version": version,
      ])
  }
  #expect(after == before)
  for (path, value) in before where after[path] != value {
    Issue.record("\(path) changed: \(value) -> \(after[path] ?? "(removed)")")
  }
}

@Test func theCommandWritesOnlyANewReportOutsideTheScannedRoots() throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let output = fixture.base.appendingPathComponent("report.json")
  let written = try inventory(fixture, ["--output", output.path])
  #expect(written.exitCode == 1, "\(written.stderr)")
  #expect(try Data(contentsOf: output) == Data(written.stdout.utf8))
  // A link inside a skill folder that leads out of every root.
  try FileManager.default.createDirectory(
    at: fixture.base.appendingPathComponent("outside"), withIntermediateDirectories: true)
  try fixture.link(
    "home/.claude/skills/xcodebuild/outside",
    to: fixture.base.appendingPathComponent("outside").path)
  // Never overwrites, never writes into a skill root, the collection or a folder a scanned
  // entry links to (by its path as given or its resolved parent), never takes --app-root.
  let inside = "inside a scanned or collection skill folder"
  let forbidden = [
    fixture.home.appendingPathComponent(".agents/skills/new.json"),
    fixture.skills.appendingPathComponent("new.json"),
    // Through the retired lead's link into the old bundle, and at that bundle directly.
    fixture.home.appendingPathComponent(".claude/skills/native-app-lead/new.json"),
    fixture.base.appendingPathComponent("old-bundle/skills/native-app-lead/new.json"),
    fixture.home.appendingPathComponent(".claude/skills/xcodebuild/outside/new.json"),
  ]
  // The project's absent skills-lock.json: a report there would be read as the lock, in any
  // capitalization on a case-insensitive volume.
  let projectLock = fixture.base.appendingPathComponent("project/skills-lock.json")
  let otherCase = fixture.base.appendingPathComponent("project/Skills-Lock.json")
  let refusals: [([String], String)] =
    [(["--output", output.path], "File exists")]
    + forbidden.map { (["--output", $0.path], inside) } + [
      (["--output", projectLock.path], "Skills CLI lock path"),
      (["--output", otherCase.path], "Skills CLI lock path"),
      (["--output", "relative.json"], "absolute"),
      (["--home", "relative"], "--home must be an absolute path"),
      (["--unknown", "x"], "Unknown options"),
    ]
  for (arguments, diagnostic) in refusals {
    let refused = try inventory(fixture, arguments)
    #expect(refused.exitCode == 2, "\(arguments): \(refused.stderr)")
    #expect(refused.stderr.contains(diagnostic), "\(arguments): \(refused.stderr)")
  }
  #expect(try Data(contentsOf: output) == Data(written.stdout.utf8))
  for url in forbidden {
    #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.path)")
  }
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.base.appendingPathComponent("outside/new.json").path))
  #expect(!FileManager.default.fileExists(atPath: projectLock.path))
  #expect(!FileManager.default.fileExists(atPath: otherCase.path))
  let appRoot = try HarnessRuntime.run(
    executable: executable,
    arguments: [
      "--repository-root", fixture.collection.path, "--app-root", fixture.project.path,
      "skill-inventory",
    ], environment: ["HOME": fixture.home.path], timeout: 60)
  #expect(appRoot.exitCode == 2)
  #expect(appRoot.stderr.contains("takes --project, not --app-root"))
}

@Test func rootsAndTheLockFollowTheClientsEnvironment() throws {
  let options = try RuntimeArguments([])
  let defaults = try SkillInventory.Locations.resolve(options: options, environment: ["HOME": "/h"])
  #expect(defaults.codexHome.path == "/h/.codex")
  #expect(defaults.claudeConfigDirectory.path == "/h/.claude")
  #expect(defaults.lock.url.path == "/h/.agents/.skill-lock.json")
  let custom = try SkillInventory.Locations.resolve(
    options: options,
    environment: [
      "HOME": "/h", "CODEX_HOME": "/c", "CLAUDE_CONFIG_DIR": " /k ", "XDG_STATE_HOME": "/s",
    ])
  #expect(custom.codexHome.path == "/c")
  #expect(custom.claudeConfigDirectory.path == "/k")
  #expect(custom.lock.url.path == "/s/skills/.skill-lock.json")
  let explicit = try SkillInventory.Locations.resolve(
    options: try RuntimeArguments(["--home", "/o", "--codex-home", "/x"]),
    environment: ["HOME": "/h", "CODEX_HOME": "/c"])
  #expect(explicit.home.path == "/o")
  #expect(explicit.codexHome.path == "/x")
  #expect(explicit.claudeConfigDirectory.path == "/o/.claude")
  #expect(throws: VerificationError.self) {
    try SkillInventory.Locations.resolve(options: options, environment: [:])
  }
  #expect(throws: VerificationError.self) {
    try SkillInventory.Locations.resolve(options: options, environment: ["HOME": "relative"])
  }
  let ids = try SkillInventory.roots(defaults).map(\.id)
  #expect(
    ids == [
      "claude-user", "agents-user", "codex-user", "xcode-codex", "xcode-apple", "xcode-claude",
      "xcode-plugins",
    ])
}

@Test func theInventoryReadsTheClientHomesAndLockTheEnvironmentNames() throws {
  // With CODEX_HOME, CLAUDE_CONFIG_DIR and XDG_STATE_HOME moved, the default homes are not
  // read: the stale Codex copy and the retired Claude link move with them.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let manager = FileManager.default
  let moved = fixture.base.appendingPathComponent("moved")
  try manager.createDirectory(at: moved, withIntermediateDirectories: true)
  try manager.moveItem(
    at: fixture.home.appendingPathComponent(".codex"), to: moved.appendingPathComponent("codex"))
  try manager.moveItem(
    at: fixture.home.appendingPathComponent(".claude"), to: moved.appendingPathComponent("claude"))
  try manager.createDirectory(
    at: moved.appendingPathComponent("state/skills"), withIntermediateDirectories: true)
  try manager.moveItem(
    at: fixture.home.appendingPathComponent(".agents/.skill-lock.json"),
    to: moved.appendingPathComponent("state/skills/.skill-lock.json"))
  let locations = try SkillInventory.Locations.resolve(
    options: try RuntimeArguments(["--project", fixture.project.path]),
    environment: [
      "HOME": fixture.home.path, "CODEX_HOME": moved.appendingPathComponent("codex").path,
      "CLAUDE_CONFIG_DIR": moved.appendingPathComponent("claude").path,
      "XDG_STATE_HOME": moved.appendingPathComponent("state").path,
    ])
  let report = try fixture.report(locations)
  #expect((report["lock"] as? [String: Any])?["status"] as? String == "read")
  #expect(
    inventoryEntries(report, "native-app-lead").map { "\($0.0) \($0.1)" } == [
      "claude-user retired"
    ])
  #expect(
    inventoryEntries(report, "device-interaction").map { "\($0.0) \($0.1)" } == [
      "codex-user reserved"
    ])
  let fallback = try fixture.report()
  #expect((fallback["lock"] as? [String: Any])?["status"] as? String == "absent")
  #expect(inventoryEntries(fallback, "native-app-lead").isEmpty)
}
