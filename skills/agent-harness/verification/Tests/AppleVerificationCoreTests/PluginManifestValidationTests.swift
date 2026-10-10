import Foundation
import Testing

@testable import AppleVerificationCore

private var checkoutRoot: URL { GateRunSupport.repositoryRoot }

private func shippedVersion() throws -> String {
  try String(contentsOf: checkoutRoot.appendingPathComponent("VERSION"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Validates the shipped manifests after `edit` changes them.
private func errors(
  skillsLink: String? = PluginManifestValidation.skillsLinkTarget, version: String? = nil,
  _ edit: (inout [String: Any], inout [String: Any]) -> Void = { _, _ in }
) throws -> [String] {
  var marketplace = try HarnessRuntime.object(
    checkoutRoot.appendingPathComponent(PluginManifestValidation.marketplacePath))
  var manifest = try HarnessRuntime.object(
    checkoutRoot.appendingPathComponent(PluginManifestValidation.manifestPath))
  edit(&marketplace, &manifest)
  return PluginManifestValidation.validate(
    marketplace: marketplace, manifest: manifest, skillsLink: skillsLink,
    version: try version ?? shippedVersion())
}

@Test func shippedPluginMatchesTheCheckout() throws {
  #expect(
    PluginManifestValidation.validate(root: checkoutRoot, version: try shippedVersion()) == [])
}

@Test func pluginVersionDriftFails() throws {
  let manifestDrift = try errors { _, manifest in manifest["version"] = "0.0.1" }
  #expect(manifestDrift.contains { $0.contains("plugin.json version 0.0.1 must equal VERSION") })
  let entryDrift = try errors { marketplace, _ in
    var entries = marketplace["plugins"] as! [[String: Any]]
    entries[0]["version"] = "0.0.1"
    marketplace["plugins"] = entries
  }
  #expect(entryDrift.contains { $0.contains("marketplace.json version for") })
  #expect(try errors(version: "9.9.9").count == 1)
}

@Test func pluginSourceAndSkillsLinkAreFixed() throws {
  let moved = try errors { marketplace, _ in
    var entries = marketplace["plugins"] as! [[String: Any]]
    entries[0]["source"] = "./"
    marketplace["plugins"] = entries
  }
  #expect(
    moved == [".claude-plugin/marketplace.json must source apple-platform-engineer from ./plugin"])
  #expect(try errors(skillsLink: nil) == ["plugin/skills must be a symbolic link to ../skills"])
  let duplicated = try errors { marketplace, _ in
    let entries = marketplace["plugins"] as! [[String: Any]]
    marketplace["plugins"] = entries + entries
  }
  #expect(
    duplicated.contains(
      ".claude-plugin/marketplace.json must list apple-platform-engineer exactly once"))
}
