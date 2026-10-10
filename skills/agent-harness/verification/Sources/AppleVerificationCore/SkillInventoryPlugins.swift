import Darwin
import Foundation

extension SkillInventory {
  /// One installed Claude Code plugin copy from `plugins/installed_plugins.json`, with the
  /// source its marketplace records in `plugins/known_marketplaces.json`.
  struct PluginInstall {
    let key: String
    let plugin: String
    let marketplace: String
    let scope: String
    let installPath: String
    let version: String?
    let commit: String?
    /// `owner/repo`, lowercased, for a GitHub marketplace; nil for any other source.
    let source: String?

    var root: Root {
      Root(
        id: "claude-plugin:\(key)", path: (installPath as NSString).appendingPathComponent("skills"),
        client: "claude", scope: "plugin:\(scope)", lock: "plugin:\(key)", labelPrefix: plugin)
    }
  }

  /// The plugin records Claude Code keeps under `CLAUDE_CONFIG_DIR/plugins`, read-only as
  /// bounded regular files. Only an install path inside that folder's `cache` is kept, so a
  /// record cannot point the scan elsewhere. Missing or unreadable records yield no installs.
  static func pluginInstalls(_ locations: Locations) -> [PluginInstall] {
    let plugins = locations.claudeConfigDirectory.appendingPathComponent("plugins")
    func object(_ name: String) -> [String: Any]? {
      let url = plugins.appendingPathComponent(name)
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        let data = try? HarnessRuntime.readRegularFile(url, maximumBytes: 8 * 1_024 * 1_024)
      else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    guard let installed = object("installed_plugins.json")?["plugins"] as? [String: Any],
      let cache = realPath(plugins.appendingPathComponent("cache").path)
    else { return [] }
    let marketplaces = object("known_marketplaces.json") ?? [:]
    var installs = [PluginInstall]()
    for (key, value) in installed.sorted(by: { $0.key < $1.key }) {
      let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
      guard parts.count == 2, let records = value as? [[String: Any]] else { continue }
      let declared = (marketplaces[parts[1]] as? [String: Any])?["source"] as? [String: Any]
      let source = (declared?["source"] as? String == "github")
        ? (declared?["repo"] as? String).map(normalizedSource) : nil
      for record in records {
        guard let path = record["installPath"] as? String,
          let physical = realPath(path), physical.hasPrefix(cache + "/")
        else { continue }
        installs.append(
          PluginInstall(
            key: key, plugin: parts[0], marketplace: parts[1],
            scope: record["scope"] as? String ?? "user", installPath: physical,
            version: record["version"] as? String, commit: record["gitCommitSha"] as? String,
            source: source))
      }
    }
    return installs
  }

  /// A lock-shaped record for one plugin copy: every skill folder in it is attributed to the
  /// marketplace's GitHub source, as a Skills CLI lock attributes its entries, and pinned to the
  /// recorded commit. A marketplace from a local path or another host attributes nothing.
  static func pluginLock(_ install: PluginInstall) -> Lock {
    var lock = Lock(
      id: "plugin:\(install.key)", path: install.installPath,
      label: "plugins/installed_plugins.json \(install.key)")
    lock.status = "read"
    guard let source = install.source else { return lock }
    let skills = (install.installPath as NSString).appendingPathComponent("skills")
    for name in (try? FileManager.default.contentsOfDirectory(atPath: skills)) ?? []
    where !name.hasPrefix(".") {
      lock.sources[name] = source
      lock.records[name] = LockRecord(ref: install.commit, treeID: nil)
    }
    return lock
  }

  /// One plugin install as the report lists it, marking the collection's own.
  static func pluginReport(_ install: PluginInstall, lifecycle: Lifecycle) -> [String: Any] {
    var report: [String: Any] = [
      "key": install.key, "scope": install.scope, "installPath": install.installPath,
      "collection": install.source.map(lifecycle.sources.contains) ?? false,
    ]
    if let version = install.version { report["version"] = version }
    if let commit = install.commit { report["commit"] = commit }
    if let source = install.source { report["source"] = source }
    return report
  }
}
