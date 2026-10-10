import Foundation
import Testing

@testable import AppleVerificationCore

/// Installs a Claude Code plugin copy in the fixture's `~/.claude/plugins`, recorded as
/// `<plugin>@<marketplace>` from a GitHub marketplace of `repo`, with `installPath` (relative to
/// the fixture) holding `skills/`.
private func installPlugin(
  _ fixture: SkillInventoryFixture, marketplace: String = "ape", repo: String,
  installPath: String = "home/.claude/plugins/cache/ape/apple-platform-engineer/1.0.0"
) throws {
  let path = fixture.base.appendingPathComponent(installPath).path
  let installed: [String: Any] = [
    "version": 2,
    "plugins": [
      "apple-platform-engineer@\(marketplace)": [
        ["scope": "user", "installPath": path, "version": "1.0.0", "gitCommitSha": "abc123"]
      ]
    ],
  ]
  let marketplaces: [String: Any] = [
    marketplace: ["source": ["source": "github", "repo": repo]]
  ]
  try fixture.write(
    "home/.claude/plugins/installed_plugins.json",
    String(decoding: try JSONSerialization.data(withJSONObject: installed), as: UTF8.self))
  try fixture.write(
    "home/.claude/plugins/known_marketplaces.json",
    String(decoding: try JSONSerialization.data(withJSONObject: marketplaces), as: UTF8.self))
}

private func copySkill(_ fixture: SkillInventoryFixture, _ name: String, to folder: String) throws {
  let target = fixture.base.appendingPathComponent("\(folder)/skills/\(name)")
  try FileManager.default.createDirectory(
    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: fixture.skills.appendingPathComponent(name), to: target)
}

@Test func theCollectionPluginIsComparedAndDuplicatesAPersonalCopy() throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let cache = "home/.claude/plugins/cache/ape/apple-platform-engineer/1.0.0"
  try copySkill(fixture, "xcodebuild", to: cache)
  try copySkill(fixture, "agent-harness", to: cache)
  try fixture.skill("\(cache)/skills/git-workflow", "An older git-workflow.")
  try installPlugin(fixture, repo: "ShawnBaek/ai-workflow-apple-platform-engineer")

  let report = try fixture.report()
  let root = "claude-plugin:apple-platform-engineer@ape"
  #expect(
    inventoryEntries(report, "apple-platform-engineer:xcodebuild").contains {
      $0 == (root, "current", ["lock"])
    })
  #expect(
    inventoryEntries(report, "apple-platform-engineer:git-workflow").contains {
      $0 == (root, "outdated", ["lock"])
    })
  // The personal link and the plugin copy both load in Claude Code.
  let duplicate = try #require(inventoryFinding(report, "duplicate", "agent-harness"))
  #expect((duplicate["roots"] as? [String] ?? []).contains(root))
  #expect(duplicate["equalContent"] as? Bool == true)
  let plugins = report["claudePlugins"] as? [[String: Any]] ?? []
  #expect(plugins.count == 1)
  #expect(plugins.first?["collection"] as? Bool == true)
  #expect(plugins.first?["commit"] as? String == "abc123")
}

@Test func anotherMarketplaceOrAPathOutsideTheCacheIsNotOurs() throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let cache = "home/.claude/plugins/cache/other/apple-platform-engineer/1.0.0"
  try copySkill(fixture, "xcodebuild", to: cache)
  try fixture.skill("\(cache)/skills/git-workflow", "Another owner's git-workflow.")
  try installPlugin(fixture, marketplace: "other", repo: "someone/else", installPath: cache)
  var report = try fixture.report()
  let root = "claude-plugin:apple-platform-engineer@other"
  #expect(
    inventoryEntries(report, "apple-platform-engineer:git-workflow").contains {
      $0.0 == root && $0.1 == "foreignSameName"
    })
  // Identical content is still recognized by hash, as for any other root.
  #expect(
    inventoryEntries(report, "apple-platform-engineer:xcodebuild").contains {
      $0 == (root, "current", ["hash"])
    })
  #expect((report["claudePlugins"] as? [[String: Any]])?.first?["collection"] as? Bool == false)

  // A record whose install path leaves the plugin cache is not scanned.
  try fixture.skill("elsewhere/skills/git-workflow", "Outside the cache.")
  try installPlugin(
    fixture, repo: "ShawnBaek/ai-workflow-apple-platform-engineer", installPath: "elsewhere")
  report = try fixture.report()
  #expect(report["claudePlugins"] == nil)
  #expect(inventoryEntries(report, "apple-platform-engineer:git-workflow").isEmpty)
}
