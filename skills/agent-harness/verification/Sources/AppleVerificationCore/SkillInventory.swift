import Darwin
import Foundation

/// A strictly read-only inventory of the skills Claude Code, Codex and Xcode's agents can load,
/// classified against the collection's lifecycle file. It needs no private harness.
///
/// It lists the top-level entries of each client skill root, reads the Skills CLI's global and
/// project locks, and hashes a skill folder only where a classification needs its content. It
/// never creates, modifies, deletes or changes the mode of anything it scans, and it opens no
/// other file than the lifecycle file and `VERSION` of a copy of the collection an entry
/// resolves into and the files naming the reference checkout's `HEAD` commit: no client
/// configuration, authentication, history or session state, and no plugin manifest.
///
/// An entry belongs to the collection only when it resolves into the verifier's own `skills/`
/// folder or the `skills/` folder of another copy of this collection outside the scanned roots
/// (a versioned bundle or checkout, by its lifecycle file's source or, before that file, its
/// harness contracts), the lock that records installs into its root names this repository or
/// one of its former names, its `HealthCollection.skillSHA256` equals the collection copy's, or
/// it resolves to the folder of an entry one of those rules already made ours. When the
/// verifier's `skills/` folder is itself a scanned root (an installed copy), only the verifier's
/// own folder and the entries that root's lock gives this repository are the collection's
/// there. A collection name beside the verifier that the lock does not give a repository (no
/// entry, or a local path), a copy with its content, a collection name a lock records from a
/// local path, and one whose lock is unreadable are unverified: neither claimed nor foreign.
/// Everything else is foreign: reported, never claimed. Content Xcode renders for its own
/// agents is Apple's, and Apple and client builtin names the collection does not use are
/// reserved, whatever the evidence.
///
/// Only a reference outside every scanned root makes an entry `current` or `outdated`: a
/// reference inside one is itself an installed copy, so the entries it would decide are
/// unverified. Separately, a lock entry's recorded Git tree is compared with the installed
/// folder, which shows an installation replaced outside the Skills CLI.
public enum SkillInventory {
  /// The homes the clients read, from explicit options first and then the variables the clients
  /// themselves honour: `HOME`, `CODEX_HOME` (else `~/.codex`), `CLAUDE_CONFIG_DIR` (else
  /// `~/.claude`) and, for the Skills CLI lock, `XDG_STATE_HOME`.
  public struct Locations {
    public var home: URL
    public var codexHome: URL
    public var claudeConfigDirectory: URL
    public var xdgStateHome: URL?
    public var project: URL?

    public init(
      home: URL, codexHome: URL? = nil, claudeConfigDirectory: URL? = nil,
      xdgStateHome: URL? = nil, project: URL? = nil
    ) {
      self.home = home
      self.codexHome = codexHome ?? home.appendingPathComponent(".codex")
      self.claudeConfigDirectory = claudeConfigDirectory ?? home.appendingPathComponent(".claude")
      self.xdgStateHome = xdgStateHome
      self.project = project
    }

    public static func resolve(options: RuntimeArguments, environment: [String: String]) throws
      -> Locations
    {
      func absolute(_ value: String, _ label: String) throws -> URL {
        guard value.hasPrefix("/") else {
          throw VerificationError.invalid("\(label) must be an absolute path")
        }
        return URL(fileURLWithPath: value).standardizedFileURL
      }
      func pick(_ option: String, _ variable: String) throws -> URL? {
        if let value = options.value(option) { return try absolute(value, option) }
        let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : try absolute(value, variable)
      }
      guard let home = try pick("--home", "HOME") else {
        throw VerificationError.invalid("HOME is unset; pass --home <dir>")
      }
      return Locations(
        home: home, codexHome: try pick("--codex-home", "CODEX_HOME"),
        claudeConfigDirectory: try pick("--claude-config-dir", "CLAUDE_CONFIG_DIR"),
        xdgStateHome: try pick("--xdg-state-home", "XDG_STATE_HOME"),
        project: try options.value("--project").map { try absolute($0, "--project") })
    }

    /// Where the Skills CLI keeps its global lock: `$XDG_STATE_HOME/skills/.skill-lock.json`
    /// when that variable is set, else `~/.agents/.skill-lock.json`.
    var lock: (url: URL, label: String) {
      if let xdgStateHome {
        return (
          xdgStateHome.appendingPathComponent("skills/.skill-lock.json"),
          "$XDG_STATE_HOME/skills/.skill-lock.json"
        )
      }
      return (home.appendingPathComponent(".agents/.skill-lock.json"), "~/.agents/.skill-lock.json")
    }
  }

  /// One skill root. `client` is `claude` or `codex` for the roots those clients list, which
  /// duplicate and split detection compare, and `xcode` for the roots Xcode's agents use.
  struct Root {
    let id: String
    let path: String
    let client: String
    let scope: String
    /// The Skills CLI lock that records installs into this root: `global` for the user roots,
    /// `project:<label>` for a project directory's `.agents/skills` and `.claude/skills`, and
    /// none for `.codex/skills` and Xcode's roots, which the CLI never installs into.
    var lock: String?
    /// Lowercased names a client manages or skips inside the root, in any capitalization: Claude
    /// Code's claude.ai `synced` folder, Xcode's `__xcode`.
    var managed: Set<String> = []
    /// Namespaces a client reserves, exactly and as a `<namespace>:` prefix: Claude Code does not
    /// load a skill folder named `anthropic-skills` or `anthropic-skills:<name>` outside a plugin.
    var namespaces: Set<String> = []
    /// Xcode's own rendered Apple skills: listed, never hashed or classified as ours.
    var apple = false
    /// Xcode's imported plugins: `<plugin>/<skill>` and `<plugin>/skills/<skill>`.
    var plugins = false
    /// Earlier roots that reach the same folder.
    var sameFolderAs: [String] = []
    /// True when one of them belongs to the same client, which lists the folder once: the root
    /// is reported, not listed again.
    var alias = false

    func manages(_ name: String) -> Bool {
      managed.contains(name.lowercased())
        || namespaces.contains { name == $0 || name.hasPrefix($0 + ":") }
    }
  }

  /// A Skills CLI lock file: the global one, and `skills-lock.json` in each listed project
  /// directory, which records the project-scope installs made there.
  struct LockFile {
    let id: String
    let url: URL
    let label: String
  }

  static func lockFiles(_ locations: Locations) throws -> [LockFile] {
    var files = [LockFile(id: "global", url: locations.lock.url, label: locations.lock.label)]
    if let project = locations.project {
      for (label, directory) in try projectDirectories(project) {
        files.append(
          LockFile(
            id: "project:\(label)",
            url: URL(fileURLWithPath: directory).appendingPathComponent("skills-lock.json"),
            label: label == "." ? "./skills-lock.json" : "\(label)/skills-lock.json"))
      }
    }
    return files
  }

  struct Entry {
    let root: Root
    let name: String
    let label: String
    let path: String
    let kind: String
    let physical: String?
    let isSkill: Bool
    let linkTarget: String?
  }

  struct Scan {
    let root: Root
    var status = "absent"
    var entries: [Entry] = []
    var hidden = 0
    var managed: [String] = []
  }

  /// The roots each client scans, as the precedence reference records them: Claude Code reads
  /// `CLAUDE_CONFIG_DIR/skills` and `.claude/skills` from the working directory up to the
  /// repository root; Codex reads `~/.agents/skills`, the deprecated `CODEX_HOME/skills`, and
  /// `.agents/skills` and `.codex/skills` from the repository root down to the working directory,
  /// `.codex/skills` only for a trusted project (listed here without reading that setting).
  /// Xcode's agents keep their own roots under `~/Library/Developer/Xcode/CodingAssistant`.
  static func roots(_ locations: Locations) throws -> [Root] {
    // Claude Code skips these names in each of its skill locations.
    let claudeManaged: Set<String> = ["synced"]
    let claudeNamespaces: Set<String> = ["anthropic-skills"]
    var roots = [
      Root(
        id: "claude-user",
        path: locations.claudeConfigDirectory.appendingPathComponent("skills").path,
        client: "claude", scope: "user", lock: "global", managed: claudeManaged,
        namespaces: claudeNamespaces),
      Root(
        id: "agents-user", path: locations.home.appendingPathComponent(".agents/skills").path,
        client: "codex", scope: "user", lock: "global"),
      Root(
        id: "codex-user", path: locations.codexHome.appendingPathComponent("skills").path,
        client: "codex", scope: "user", lock: "global"),
    ]
    if let project = locations.project {
      for (label, directory) in try projectDirectories(project) {
        // The Skills CLI records a project-scope install in that directory's skills-lock.json;
        // it never installs into .codex/skills.
        for (id, folder, client, lock) in [
          ("claude-project", ".claude/skills", "claude", "project:\(label)"),
          ("agents-project", ".agents/skills", "codex", "project:\(label)"),
          ("codex-project", ".codex/skills", "codex", nil),
        ] {
          let claude = client == "claude"
          roots.append(
            Root(
              id: "\(id):\(label)", path: (directory as NSString).appendingPathComponent(folder),
              client: client, scope: "project", lock: lock, managed: claude ? claudeManaged : [],
              namespaces: claude ? claudeNamespaces : []))
        }
      }
    }
    let xcode = locations.home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant")
    roots += [
      Root(
        id: "xcode-codex", path: xcode.appendingPathComponent("codex/skills").path,
        client: "xcode", scope: "xcode", managed: ["__xcode"]),
      Root(
        id: "xcode-apple", path: xcode.appendingPathComponent("codex/skills/__xcode").path,
        client: "xcode", scope: "xcode", apple: true),
      Root(
        id: "xcode-claude", path: xcode.appendingPathComponent("ClaudeAgentConfig/skills").path,
        client: "xcode", scope: "xcode", managed: claudeManaged, namespaces: claudeNamespaces),
      Root(
        id: "xcode-plugins", path: xcode.appendingPathComponent("AgentPlugins").path,
        client: "xcode", scope: "xcode", plugins: true),
    ]
    // A client lists one folder once, so a later root of the same client that reaches an
    // earlier root's folder is an alias. Another client's root that shares the folder (for
    // example ~/.claude/skills linked to ~/.agents/skills) is listed for that client too.
    var byFolder = [String: [Root]]()
    return roots.map { root in
      var root = root
      let folder = realPath(root.path) ?? root.path
      let earlier = byFolder[folder, default: []]
      root.sameFolderAs = earlier.map(\.id)
      root.alias = earlier.contains { $0.client == root.client }
      byFolder[folder, default: []].append(root)
      return root
    }
  }

  /// The project directory and each parent up to its repository root (the nearest `.git`),
  /// labelled relative to that root; only the project directory outside a repository.
  static func projectDirectories(_ project: URL) throws -> [(String, String)] {
    guard let start = realPath(project.path), isDirectory(start) else {
      throw VerificationError.invalid("--project must be an existing directory")
    }
    var chain = [String]()
    var candidate = start
    var top: String?
    while true {
      chain.append(candidate)
      var info = stat()
      if lstat((candidate as NSString).appendingPathComponent(".git"), &info) == 0 {
        top = candidate
        break
      }
      let parent = (candidate as NSString).deletingLastPathComponent
      if parent == candidate || parent.isEmpty { break }
      candidate = parent
    }
    let base = top ?? start
    return (top == nil ? [start] : chain).reversed().map { directory in
      (directory == base ? "." : String(directory.dropFirst(base.count + 1)), directory)
    }
  }

  static func scan(_ root: Root) -> Scan {
    var scan = Scan(root: root)
    var info = stat()
    guard lstat(root.path, &info) == 0 else { return scan }
    guard !root.alias else {
      scan.status = "sameFolder"
      return scan
    }
    guard isDirectory(root.path),
      let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
    else {
      scan.status = "unreadable"
      return scan
    }
    scan.status = "present"
    for name in names.sorted().prefix(10_000) {
      let path = (root.path as NSString).appendingPathComponent(name)
      if name.hasPrefix(".") {
        scan.hidden += 1
      } else if root.manages(name) {
        scan.managed.append(name)
      } else if root.plugins {
        scan.entries += pluginEntries(root, plugin: name, path: path)
      } else {
        scan.entries.append(entry(root, name: name, label: name, path: path))
      }
    }
    return scan
  }

  /// Skill folders inside one imported Xcode plugin, named `<plugin>:<skill>` as the clients
  /// namespace them. The plugin's manifest files are not opened.
  static func pluginEntries(_ root: Root, plugin: String, path: String) -> [Entry] {
    guard isDirectory(path) else { return [] }
    var entries = [Entry]()
    for folder in [path, (path as NSString).appendingPathComponent("skills")]
    where isDirectory(folder) {
      for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
      where !name.hasPrefix(".") && !(folder == path && name == "skills") {
        let candidate = entry(
          root, name: name, label: "\(plugin):\(name)",
          path: (folder as NSString).appendingPathComponent(name))
        if candidate.isSkill || candidate.physical == nil { entries.append(candidate) }
      }
    }
    return entries
  }

  static func entry(_ root: Root, name: String, label: String, path: String) -> Entry {
    var info = stat()
    _ = lstat(path, &info)
    let kind: String
    switch info.st_mode & S_IFMT {
    case S_IFLNK: kind = "symlink"
    case S_IFDIR: kind = "directory"
    case S_IFREG: kind = "file"
    default: kind = "other"
    }
    let physical = realPath(path)
    var target: String?
    if kind == "symlink" {
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
      let count = readlink(path, &buffer, Int(PATH_MAX))
      if count > 0 {
        target = String(
          decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      }
    }
    return Entry(
      root: root, name: name, label: label, path: path, kind: kind, physical: physical,
      isSkill: physical.map(isSkillFolder) ?? false, linkTarget: target)
  }

  static func realPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func isDirectory(_ path: String) -> Bool {
    var info = stat()
    return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
  }

  static func isSkillFolder(_ path: String) -> Bool {
    var info = stat()
    return isDirectory(path)
      && stat((path as NSString).appendingPathComponent("SKILL.md"), &info) == 0
      && info.st_mode & S_IFMT == S_IFREG
  }
}
