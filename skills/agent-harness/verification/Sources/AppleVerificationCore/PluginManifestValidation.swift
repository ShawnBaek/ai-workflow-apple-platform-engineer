import Foundation

/// Keeps the Claude Code plugin and its marketplace true to the checkout.
///
/// The marketplace lists one plugin sourced from `./plugin`, whose `skills` entry is a symbolic
/// link to the real `skills/` folder; installation copies it as a real folder. This checks what
/// `claude plugin validate` cannot see through that link or across files:
/// - the marketplace lists exactly one entry for the plugin, sourced from `./plugin`;
/// - the plugin manifest names that plugin;
/// - every declared version equals `VERSION`, so a release changes them together;
/// - `plugin/skills` is a symbolic link to `../skills`.
public enum PluginManifestValidation {
  static let pluginName = "apple-platform-engineer"
  static let marketplacePath = ".claude-plugin/marketplace.json"
  static let manifestPath = "plugin/.claude-plugin/plugin.json"
  static let skillsLinkPath = "plugin/skills"
  static let pluginSource = "./plugin"
  static let skillsLinkTarget = "../skills"

  /// Validates the shipped marketplace, plugin manifest and skills link against `VERSION`.
  static func validate(root: URL, version: String) -> [String] {
    let marketplace: [String: Any]
    let manifest: [String: Any]
    do {
      marketplace = try HarnessRuntime.object(root.appendingPathComponent(marketplacePath))
      manifest = try HarnessRuntime.object(root.appendingPathComponent(manifestPath))
    } catch {
      return ["Claude Code plugin manifests are unavailable or invalid: \(error)"]
    }
    let link = try? FileManager.default.destinationOfSymbolicLink(
      atPath: root.appendingPathComponent(skillsLinkPath).path)
    return validate(
      marketplace: marketplace, manifest: manifest, skillsLink: link, version: version)
  }

  static func validate(
    marketplace: [String: Any], manifest: [String: Any], skillsLink: String?, version: String
  ) -> [String] {
    var errors = [String]()
    let entries = (marketplace["plugins"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
      .filter { $0["name"] as? String == pluginName }
    if entries.count != 1 {
      errors.append("\(marketplacePath) must list \(pluginName) exactly once")
    }
    for entry in entries {
      if entry["source"] as? String != pluginSource {
        errors.append("\(marketplacePath) must source \(pluginName) from \(pluginSource)")
      }
      if let declared = entry["version"], declared as? String != version {
        errors.append("\(marketplacePath) version for \(pluginName) must equal VERSION \(version)")
      }
    }
    if manifest["name"] as? String != pluginName {
      errors.append("\(manifestPath) name must be \(pluginName)")
    }
    let declared = manifest["version"] as? String
    if declared != version {
      errors.append(
        "\(manifestPath) version \(declared ?? "(missing)") must equal VERSION \(version)")
    }
    if skillsLink != skillsLinkTarget {
      errors.append("\(skillsLinkPath) must be a symbolic link to \(skillsLinkTarget)")
    }
    return errors.sorted()
  }
}
