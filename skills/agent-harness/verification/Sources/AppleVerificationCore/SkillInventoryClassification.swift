import Foundation

extension SkillInventory {
  /// The lifecycle fields the inventory needs, from `skills/agent-harness/lifecycle`.
  struct Lifecycle {
    let version: String
    let source: String
    /// This repository and its former names, lowercased as the lock is compared.
    let sources: Set<String>
    let current: Set<String>
    let replacements: [String: Any]
    /// Xcode's skill names and its plugin namespace: never ours, whatever the evidence.
    let appleNames: Set<String>
    /// Client-bundled names, with the lifecycle field that reserves each one.
    let clientBuiltins: [String: String]

    init(_ object: [String: Any]) throws {
      guard let version = object["version"] as? String, let source = object["source"] as? String,
        let legacy = object["legacySources"] as? [String],
        let current = object["current"] as? [String],
        let retired = object["retired"] as? [[String: Any]],
        let reserved = object["reservedNames"] as? [String: Any],
        let apple = reserved["appleSkills"] as? [String],
        let namespace = reserved["appleNamespace"] as? String,
        let builtins = reserved["clientBuiltins"] as? [String: [String]]
      else { throw VerificationError.invalid("skill lifecycle file is invalid") }
      self.version = version
      self.source = source
      sources = Set(([source] + legacy).map(SkillInventory.normalizedSource))
      self.current = Set(current)
      var replacements = [String: Any]()
      for entry in retired {
        guard let id = entry["id"] as? String else {
          throw VerificationError.invalid("skill lifecycle file is invalid")
        }
        replacements[id] = entry["replacedBy"] as? String ?? NSNull()
      }
      self.replacements = replacements
      appleNames = Set(apple + [namespace])
      var clientBuiltins = [String: String]()
      for (client, names) in builtins.sorted(by: { $0.key < $1.key }) {
        for name in names where clientBuiltins[name] == nil {
          clientBuiltins[name] = "reservedNames.clientBuiltins.\(client)"
        }
      }
      self.clientBuiltins = clientBuiltins
    }

    /// A current or retired collection name.
    func names(_ name: String) -> Bool { current.contains(name) || replacements[name] != nil }
  }

  /// A Skills CLI lock: skill name to its normalized `source`, for the entries installed from a
  /// repository or another remote source.
  struct Lock {
    let id: String
    let path: String
    let label: String
    var status = "absent"
    var reason: String?
    var version: Int?
    var sources: [String: String] = [:]
    /// Entries installed from a local path. The CLI records one only in a project's
    /// `skills-lock.json` (`sourceType` `local`, a path relative to the lock); a global install
    /// from a path gets no entry. A path may be a checkout of this repository or of another, so it
    /// attributes the entry to no one.
    var local: Set<String> = []
  }

  /// Whether a lock `source` is a filesystem path rather than a repository or package.
  static func isPathSource(_ source: String) -> Bool {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    return value == "." || value == ".."
      || ["/", "./", "../", "~"].contains { value.hasPrefix($0) }
  }

  /// `owner/repo`, lowercased, from a shorthand, HTTPS or SSH GitHub source.
  static func normalizedSource(_ source: String) -> String {
    var value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for prefix in [
      "https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:",
      "github.com/",
    ] where value.hasPrefix(prefix) {
      value.removeFirst(prefix.count)
    }
    while value.hasSuffix("/") { value.removeLast() }
    if value.hasSuffix(".git") { value.removeLast(4) }
    return value
  }

  /// Reads a lock as a bounded regular file, read-only, and keeps only each entry's source and
  /// whether that source is a local path. Anything else at that path (a link, a FIFO that would
  /// block the open) is not opened.
  static func readLock(_ file: LockFile) -> Lock {
    let url = file.url
    var lock = Lock(id: file.id, path: url.path, label: file.label)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return lock }
    guard info.st_mode & S_IFMT == S_IFREG else {
      lock.status = "unreadable"
      lock.reason = "not a regular file"
      return lock
    }
    do {
      let data = try HarnessRuntime.readRegularFile(url, maximumBytes: 8 * 1_024 * 1_024)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let skills = object["skills"] as? [String: Any]
      else { throw VerificationError.invalid("the lock has no skills object") }
      lock.version = object["version"] as? Int
      for (name, value) in skills {
        guard let entry = value as? [String: Any], let source = entry["source"] as? String
        else { continue }
        if entry["sourceType"] as? String == "local" || isPathSource(source) {
          lock.local.insert(name)
        } else {
          lock.sources[name] = normalizedSource(source)
        }
      }
      lock.status = "read"
    } catch {
      lock.status = "unreadable"
      lock.reason = "\(error)"
    }
    return lock
  }

  struct Classified {
    let entry: Entry
    let kind: String
    var evidence: [String] = []
    var detail: [String: Any] = [:]
  }

  /// What `path` itself is, never following a link at it.
  enum Node {
    case absent, directory, file, other

    init(_ path: String) {
      var info = stat()
      guard lstat(path, &info) == 0 else {
        self = errno == ENOENT ? .absent : .other
        return
      }
      switch info.st_mode & S_IFMT {
      case S_IFDIR: self = .directory
      case S_IFREG: self = .file
      default: self = .other
      }
    }
  }

  /// Whether `folder`, a resolved `skills/` folder, belongs to a copy of this collection: a
  /// versioned bundle or another checkout. Its `<harness>/lifecycle/skill-lifecycle.json` must
  /// name this repository or a former name (`sources`); a release from before that file is
  /// recognized by `<harness>/contracts/capabilities.json`, the marker the verifier uses to find
  /// its own harness. A lifecycle file that names another source, or cannot be read, makes the
  /// copy another owner's. Either file counts only in a real harness folder: `<harness>` and its
  /// `lifecycle` or `contracts` folder must be directories and the file a regular file, none of
  /// them a link, or a folder of other owners' skills (a link farm, a dotfiles folder) would pass
  /// for a copy by linking one of them to a real one. Returns the copy's root and the `VERSION`
  /// it ships, when readable.
  static func collectionCopy(_ folder: String, harness: String, sources: Set<String>)
    -> [String: String]?
  {
    guard (folder as NSString).lastPathComponent == "skills" else { return nil }
    let harness = (folder as NSString).appendingPathComponent(harness)
    guard Node(harness) == .directory else { return nil }
    let lifecycleFolder = (harness as NSString).appendingPathComponent("lifecycle")
    let lifecycle = (lifecycleFolder as NSString).appendingPathComponent("skill-lifecycle.json")
    let contracts = (harness as NSString).appendingPathComponent("contracts")
    let lifecycleNode = Node(lifecycleFolder)
    switch lifecycleNode == .directory ? Node(lifecycle) : lifecycleNode {
    case .file:
      guard
        let data = try? HarnessRuntime.readRegularFile(
          URL(fileURLWithPath: lifecycle), maximumBytes: 1_024 * 1_024),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let source = object["source"] as? String, sources.contains(normalizedSource(source))
      else { return nil }
    case .absent:
      guard Node(contracts) == .directory,
        Node((contracts as NSString).appendingPathComponent("capabilities.json")) == .file
      else { return nil }
    case .directory, .other:
      return nil
    }
    let root = (folder as NSString).deletingLastPathComponent
    var copy = ["root": root]
    let version = (root as NSString).appendingPathComponent("VERSION")
    var info = stat()
    if lstat(version, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      let data = try? HarnessRuntime.readRegularFile(
        URL(fileURLWithPath: version), maximumBytes: 256)
    {
      let value = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty, !value.contains(where: \.isNewline) { copy["version"] = value }
    }
    return copy
  }

  /// Applies the ownership rule and the content comparison to each entry, in root order, so an
  /// entry can inherit ownership from an entry an earlier root already proved ours.
  final class Classifier {
    let lifecycle: Lifecycle
    /// Each lock by id; a root names the one that records installs into it.
    let locks: [String: Lock]
    /// The verifier's own `skills/` folder, resolved.
    let reference: String
    /// The verifier's own folder inside it (`agent-harness`).
    let verifier: String
    /// The scanned root that is that folder (an installed copy of the collection, such as
    /// `~/.agents/skills` or a project's `.agents/skills`), where other owners' skills can sit
    /// beside the collection's; nil for a checkout.
    let referenceRoot: Root?
    /// The resolved folders of the scanned roots. A copy of the collection there is an
    /// installed copy that other owners' skills can share, so its location proves nothing.
    let scannedFolders: Set<String>
    private var hashes: [String: String] = [:]
    private var hashErrors: [String: String] = [:]
    private var owned = Set<String>()
    private var copies: [String: [String: String]?] = [:]
    /// Folders of entries left unverified because the lock covering their root is unreadable.
    private var unreadableLockFolders = Set<String>()

    init(
      lifecycle: Lifecycle, locks: [String: Lock], reference: String, verifier: String,
      referenceRoot: Root?, scannedFolders: Set<String>
    ) {
      self.lifecycle = lifecycle
      self.locks = locks
      self.reference = reference
      self.verifier = verifier
      self.referenceRoot = referenceRoot
      self.scannedFolders = scannedFolders
    }

    /// The copy of this collection whose `skills/` folder is `folder`, once per folder; never the
    /// verifier's own folder, which `path` covers, or a scanned root.
    func collectionCopy(_ folder: String) -> [String: String]? {
      guard folder != reference, !scannedFolders.contains(folder) else { return nil }
      if let known = copies[folder] { return known }
      let copy = SkillInventory.collectionCopy(
        folder, harness: verifier, sources: lifecycle.sources)
      copies[folder] = copy
      return copy
    }

    /// Whether the lock `id` exists but could not be read, so it proves nothing either way.
    func lockUnreadable(_ id: String?) -> Bool {
      guard let id else { return false }
      return locks[id]?.status == "unreadable"
    }

    /// What the lock `id` says about `name`: true for this repository or a former name, false
    /// for another remote source, nil when it has no such entry, records a local path (which
    /// names no repository), or there is no such lock.
    func lockOwns(_ name: String, lock id: String?) -> Bool? {
      guard let id, let source = locks[id]?.sources[name] else { return nil }
      return lifecycle.sources.contains(source)
    }

    /// Whether the lock `id` records `name` as installed from a local path.
    func lockRecordsLocal(_ name: String, lock id: String?) -> Bool {
      guard let id else { return false }
      return locks[id]?.local.contains(name) == true
    }

    /// Whether `name` inside the verifier's `skills/` folder is the collection's. In a checkout
    /// every entry there is. In an installed copy only the verifier's own folder and the entries
    /// that root's lock gives this repository or a former name are proved the collection's.
    func referenceOwns(_ name: String) -> Bool {
      guard let referenceRoot else { return true }
      return name == verifier || lockOwns(name, lock: referenceRoot.lock) == true
    }

    func referencePath(_ name: String) -> String? {
      let path = (reference as NSString).appendingPathComponent(name)
      guard referenceOwns(name), SkillInventory.isSkillFolder(path) else { return nil }
      return SkillInventory.realPath(path)
    }

    /// A collection name beside the verifier in an installed copy that its root's lock does not
    /// give a repository: no entry (a copy made without the Skills CLI, a global install from a
    /// local path, which the CLI never records, or an absent lock) or a local-path entry (a
    /// project install from a local path). A lock that records the verifier or other collection
    /// skills proves nothing about it: one installation can mix sources. It may be this
    /// installation's or another owner's, so it is neither claimed nor foreign.
    func unattributedCopy(_ name: String) -> String? {
      guard let referenceRoot, name != verifier, lifecycle.names(name),
        lockOwns(name, lock: referenceRoot.lock) == nil
      else { return nil }
      let path = (reference as NSString).appendingPathComponent(name)
      guard SkillInventory.isSkillFolder(path) else { return nil }
      return SkillInventory.realPath(path)
    }

    /// `HealthCollection.skillSHA256` of a resolved skill folder, once per folder.
    func hash(_ physical: String) -> String? {
      if let known = hashes[physical] { return known }
      if hashErrors[physical] != nil { return nil }
      do {
        let value = try HealthCollection.skillSHA256(URL(fileURLWithPath: physical))
        hashes[physical] = value
        return value
      } catch {
        hashErrors[physical] = "\(error)"
        return nil
      }
    }

    func hashError(_ physical: String) -> String? { hashErrors[physical] }

    func classify(_ entry: Entry) -> Classified {
      // Xcode's own Apple skills; anything else in that folder (a manifest) is no skill.
      if entry.root.apple {
        return Classified(entry: entry, kind: entry.isSkill ? "apple" : "ignored")
      }
      let name = entry.name
      let lock = entry.root.lock
      guard let physical = entry.physical else {
        var result = Classified(entry: entry, kind: "broken")
        if lockOwns(name, lock: lock) == true { result.evidence.append("lock") }
        if let target = entry.linkTarget,
          let folder = referenceName(target, from: entry.path), referenceOwns(folder)
        {
          result.evidence.append("path")
        }
        return result
      }
      guard entry.isSkill else { return Classified(entry: entry, kind: "ignored") }
      // Apple's names, and the client builtins the collection does not use, are never ours.
      if lifecycle.appleNames.contains(name) {
        return Classified(
          entry: entry, kind: "reserved", detail: ["reservedBy": "reservedNames.appleSkills"])
      }
      if let field = lifecycle.clientBuiltins[name], !lifecycle.current.contains(name) {
        return Classified(entry: entry, kind: "reserved", detail: ["reservedBy": field])
      }
      var evidence = [String]()
      let folder = (physical as NSString).deletingLastPathComponent
      if folder == reference, referencePath((physical as NSString).lastPathComponent) != nil {
        evidence.append("path")
      }
      // A versioned bundle or another checkout of this collection, compared with the verifier's
      // copy like any other entry of ours.
      let origin = collectionCopy(folder)
      if origin != nil { evidence.append("copy") }
      if lockOwns(name, lock: lock) == true { evidence.append("lock") }
      if evidence.isEmpty, lifecycle.current.contains(name), let copy = referencePath(name),
        let digest = hash(physical), digest == hash(copy)
      {
        evidence.append("hash")
      }
      // The folder of an entry already proved ours, reached through this entry's own link or
      // through a root that links to another root.
      if evidence.isEmpty, owned.contains(physical) { evidence.append("link") }
      guard evidence.isEmpty else {
        owned.insert(physical)
        var result = classifyOwned(entry, physical: physical, evidence: evidence)
        if let origin { result.detail["installedFrom"] = origin }
        return result
      }
      guard lifecycle.names(name) else { return Classified(entry: entry, kind: "foreign") }
      if let reason = unattributedReason(name, physical: physical, lock: lock) {
        var result = Classified(entry: entry, kind: "unverified", detail: ["reason": reason])
        if lockRecordsLocal(name, lock: lock) {
          result.detail["lock"] = "local"
        } else if lockUnreadable(lock) {
          result.detail["lock"] = "unreadable"
        }
        if let replacement = lifecycle.replacements[name] {
          result.detail["replacedBy"] = replacement
        }
        return result
      }
      var result = Classified(entry: entry, kind: "foreignSameName")
      if lockOwns(name, lock: lock) == false { result.detail["lock"] = "foreign" }
      return result
    }

    /// Why a collection name with no ownership evidence is unverified rather than another
    /// owner's: it is the unattributed copy beside the verifier or has that copy's content, the
    /// lock covering its root records it from a local path, which may be a checkout of this
    /// repository, or that lock is unreadable, so only it could have said whose the entry is (and
    /// an entry that resolves to such an entry's folder is unverified with it). Nil when nothing
    /// says it could be this installation's.
    private func unattributedReason(_ name: String, physical: String, lock: String?) -> String? {
      if let copy = unattributedCopy(name) {
        if physical == copy {
          return lockRecordsLocal(name, lock: referenceRoot?.lock)
            ? "beside the verifier; its lock records a local path, which names no repository"
            : "beside the verifier; no lock records it"
        }
        if let digest = hash(physical), digest == hash(copy) {
          return "same content as the copy beside the verifier, which no lock attributes"
        }
      }
      if lockRecordsLocal(name, lock: lock) {
        return "its lock records a local path, which names no repository"
      }
      if lockUnreadable(lock) {
        unreadableLockFolders.insert(physical)
        return "the lock covering its root is unreadable"
      }
      if unreadableLockFolders.contains(physical) {
        return "resolves to the folder of an entry whose lock is unreadable"
      }
      return nil
    }

    private func classifyOwned(_ entry: Entry, physical: String, evidence: [String])
      -> Classified
    {
      var result = Classified(entry: entry, kind: "unlisted", evidence: evidence)
      if let replacement = lifecycle.replacements[entry.name] {
        return Classified(
          entry: entry, kind: "retired", evidence: evidence,
          detail: ["replacedBy": replacement])
      }
      guard lifecycle.current.contains(entry.name) else { return result }
      guard let copy = referencePath(entry.name) else {
        result = Classified(entry: entry, kind: "unverified", evidence: evidence)
        result.detail["reason"] = "no collection copy to compare"
        return result
      }
      if physical == copy { return Classified(entry: entry, kind: "current", evidence: evidence) }
      guard let digest = hash(physical), let expected = hash(copy) else {
        result = Classified(entry: entry, kind: "unverified", evidence: evidence)
        result.detail["reason"] = hashError(physical) ?? hashError(copy) ?? "hash unavailable"
        return result
      }
      return Classified(
        entry: entry, kind: digest == expected ? "current" : "outdated", evidence: evidence)
    }

    /// The folder name a broken link's text names directly inside the verifier's `skills/`.
    private func referenceName(_ target: String, from link: String) -> String? {
      let absolute =
        target.hasPrefix("/")
        ? target
        : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
      let standardized = (absolute as NSString).standardizingPath
      let parent = (standardized as NSString).deletingLastPathComponent
      guard SkillInventory.realPath(parent) == reference else { return nil }
      return (standardized as NSString).lastPathComponent
    }
  }
}
