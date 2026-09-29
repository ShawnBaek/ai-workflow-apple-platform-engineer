import Foundation

extension SkillInventory {
  /// Entry classes that need a decision; `current`, `foreign`, `ignored` and `apple` do not.
  static let attentionClasses: Set<String> = [
    "outdated", "unverified", "retired", "unlisted", "broken", "foreignSameName", "reserved",
    "split", "duplicate", "staleLock",
  ]

  /// The approval-gated step that would reconcile each class. The inventory runs none of them.
  static let nextSteps: [String: String] = [
    "outdated":
      "apple-platform-setup update, after approval: reinstall the entry from the reviewed "
      + "revision with its original method and client.",
    "unverified":
      "Inspect the entry: its content could not be compared, or no readable lock attributes it "
      + "to a repository (reason). Compare it with the reviewed source revision; setup changes "
      + "nothing until you decide.",
    "retired":
      "apple-platform-setup reconcile, after approval: back up and remove the owned retired "
      + "entry, then install its replacement.",
    "unlisted":
      "apple-platform-setup reconcile, after approval: its evidence makes the entry the "
      + "collection's, but the lifecycle file does not list the name; confirm it before removal.",
    "split":
      "apple-platform-setup reconcile, after approval: install the collection entry for the "
      + "client that lacks it, with the same method and revision. Where occupiedBy names a root, "
      + "another entry holds that name there; setup leaves it alone and reports it.",
    "duplicate":
      "Decide which copy each client loads. Setup removes only an owned stale copy, after "
      + "approval, and never a foreign one.",
    "broken":
      "apple-platform-setup reconcile, after approval: remove an owned broken link; a link "
      + "with no ownership evidence is left to its owner.",
    "staleLock":
      "apple-platform-setup reconcile, after approval: remove the lock entry with an explicit "
      + "agent list (-a), never a bare remove.",
    "foreignSameName":
      "Not reconciled by setup: no ownership evidence makes the entry the collection's. "
      + "Rename or remove it yourself, or keep it and leave the collection copy uninstalled "
      + "there.",
    "reserved":
      "Not reconciled by setup: Apple and client names belong to their owners. Keep one Apple "
      + "exposure per Xcode.",
  ]

  /// Scans every root read-only and classifies each entry against `lifecycle`, using the
  /// verifier's own `collectionSkills` folder as the reference copy; `verifier` is the
  /// verifier's own folder inside it.
  public static func inventory(
    locations: Locations, collectionSkills: URL, verifier: String = "agent-harness",
    lifecycle object: [String: Any]
  ) throws -> [String: Any] {
    let lifecycle = try Lifecycle(object)
    guard let reference = realPath(collectionSkills.path), isDirectory(reference) else {
      throw VerificationError.invalid("the collection's skills folder is unavailable")
    }
    let scans = try roots(locations).map(scan)
    let locks = try lockFiles(locations).map(readLock)
    let referenceRoot = scans.first {
      $0.status == "present" && realPath($0.root.path) == reference
    }?.root
    let classifier = Classifier(
      lifecycle: lifecycle,
      locks: Dictionary(uniqueKeysWithValues: locks.map { ($0.id, $0) }), reference: reference,
      verifier: verifier, referenceRoot: referenceRoot,
      scannedFolders: Set(scans.compactMap { realPath($0.root.path) }))
    let classified = scans.flatMap { $0.entries.map(classifier.classify) }

    var findings = [String: [[String: Any]]]()
    var byClass = [String: [String: [Classified]]]()
    for item in classified where !["foreign", "ignored", "apple"].contains(item.kind) {
      byClass[item.kind, default: [:]][item.entry.label, default: []].append(item)
    }
    for (kind, names) in byClass {
      findings[kind] = names.keys.sorted().map { label in
        let items = names[label]!
        var finding = items[0].detail
        finding["name"] = label
        finding["roots"] = items.map(\.entry.root.id)
        let evidence = Set(items.flatMap(\.evidence))
        if !evidence.isEmpty { finding["evidence"] = evidence.sorted() }
        return finding
      }
    }
    findings["duplicate"] = duplicates(classified, classifier: classifier)
    findings["split"] = split(classified, current: lifecycle.current)
    findings["staleLock"] = staleLock(classified, locks: locks, lifecycle: lifecycle)
    findings = findings.filter { !$0.value.isEmpty }

    var summary = [String: Any]()
    var namesByClass = [String: Set<String>]()
    var entriesByClass = [String: Int]()
    for item in classified {
      namesByClass[item.kind, default: []].insert(item.entry.label)
      entriesByClass[item.kind, default: 0] += 1
    }
    for kind in ["split", "duplicate", "staleLock"] {
      for finding in findings[kind] ?? [] {
        namesByClass[kind, default: []].insert(finding["name"] as! String)
        entriesByClass[kind, default: 0] += 1
      }
    }
    for (kind, names) in namesByClass {
      summary[kind] = ["names": names.sorted(), "count": entriesByClass[kind] ?? 0]
    }
    let attention = Set(findings.keys).intersection(attentionClasses)

    var report: [String: Any] = [
      "command": "skill-inventory",
      "readOnly": true,
      "status": attention.isEmpty ? "clean" : "attention",
      "collection": [
        "source": lifecycle.source, "version": lifecycle.version, "skillsFolder": reference,
        "reference": referenceRoot.map { "scanned root \($0.id)" } ?? "verifier skills folder",
      ],
      "lock": lockReport(locks[0], lifecycle: lifecycle),
      "roots": scans.map { rootReport($0, classified: classified) },
      "findings": findings,
      "summary": summary,
      "nextSteps": nextSteps.filter { attention.contains($0.key) },
    ]
    if locks.count > 1 {
      report["projectLocks"] = locks.dropFirst().map { lockReport($0, lifecycle: lifecycle) }
    }
    return report
  }

  /// One name listed by two or more roots of the same client for different folders. Claude Code
  /// runs the personal copy over a project one, and `/<name>` runs the repository root's copy over
  /// a nested directory's, which stays reachable as `/<dir>:<name>`; Codex lists both and a plain
  /// `$name` injects neither. Entries that resolve to one folder are no duplicate: Codex dedupes a
  /// `SKILL.md` it reaches twice, and Claude Code runs that same content whichever entry wins.
  static func duplicates(_ classified: [Classified], classifier: Classifier) -> [[String: Any]] {
    var findings = [[String: Any]]()
    for client in ["claude", "codex"] {
      let listed = classified.filter {
        $0.entry.root.client == client && $0.entry.isSkill && $0.entry.physical != nil
      }
      for (name, items) in Dictionary(grouping: listed, by: \.entry.name).sorted(by: {
        $0.key < $1.key
      }) where items.count > 1 {
        let targets = Set(items.compactMap(\.entry.physical))
        guard targets.count > 1 else { continue }
        let digests = targets.map { classifier.hash($0) }
        // Unknown (null) when a copy could not be hashed.
        let equal: Any =
          digests.contains(where: { $0 == nil }) ? NSNull() : Set(digests).count == 1
        findings.append([
          "name": name, "client": client, "roots": items.map(\.entry.root.id),
          "classes": items.map(\.kind), "equalContent": equal,
        ])
      }
    }
    return findings
  }

  /// A current skill the collection installed for one client but not the other, in any
  /// current, outdated or unverified copy. Only compared once both clients hold at least one
  /// collection entry, so a single-client setup is not split. `occupiedBy` names the lacking
  /// client's roots that hold another entry with that name.
  static func split(_ classified: [Classified], current: Set<String>) -> [[String: Any]] {
    var ours = ["claude": Set<String>(), "codex": Set<String>()]
    for item in classified
    where current.contains(item.entry.name)
      && ["current", "outdated", "unverified"].contains(item.kind)
    {
      ours[item.entry.root.client]?.insert(item.entry.name)
    }
    let claude = ours["claude"]!
    let codex = ours["codex"]!
    guard !claude.isEmpty, !codex.isEmpty else { return [] }
    return claude.symmetricDifference(codex).sorted().map { name in
      let present = claude.contains(name) ? "claude" : "codex"
      let missing = present == "claude" ? "codex" : "claude"
      var finding: [String: Any] = [
        "name": name, "presentFor": [present], "missingFor": [missing],
      ]
      let occupied = classified.filter { $0.entry.root.client == missing && $0.entry.name == name }
      if !occupied.isEmpty { finding["occupiedBy"] = occupied.map(\.entry.root.id) }
      return finding
    }
  }

  /// A lock entry from this repository or a former name whose skill is retired, unknown to the
  /// lifecycle file, or installed in none of the roots that lock records installs into.
  static func staleLock(_ classified: [Classified], locks: [Lock], lifecycle: Lifecycle)
    -> [[String: Any]]
  {
    var findings = [[String: Any]]()
    for lock in locks {
      let installed = Set(
        classified.filter { $0.entry.root.lock == lock.id && $0.entry.isSkill }.map(\.entry.name))
      for (name, source) in lock.sources.sorted(by: { $0.key < $1.key })
      where lifecycle.sources.contains(source) {
        var finding: [String: Any] = ["name": name, "lock": lock.id]
        if let replacement = lifecycle.replacements[name] {
          finding["reason"] = "retired"
          finding["replacedBy"] = replacement
        } else if !lifecycle.current.contains(name) {
          finding["reason"] = "notInLifecycle"
        } else if !installed.contains(name) {
          finding["reason"] = "missing"
        } else {
          continue
        }
        findings.append(finding)
      }
    }
    return findings
  }

  /// A lock's counts, plus the names it still gives a former name of this repository (installed
  /// before the rename, so likely outdated) and the names it records from a local path (which
  /// attribute nothing).
  static func lockReport(_ lock: Lock, lifecycle: Lifecycle) -> [String: Any] {
    var report: [String: Any] = [
      "id": lock.id, "path": lock.path, "location": lock.label, "status": lock.status,
      "entries": lock.sources.count + lock.local.count,
      "collectionEntries": lock.sources.values.filter { lifecycle.sources.contains($0) }.count,
    ]
    let current = normalizedSource(lifecycle.source)
    let legacy = lock.sources.filter { $0.value != current && lifecycle.sources.contains($0.value) }
    if !legacy.isEmpty { report["legacySource"] = legacy.keys.sorted() }
    if !lock.local.isEmpty { report["localSource"] = lock.local.sorted() }
    if let version = lock.version { report["version"] = version }
    if let reason = lock.reason { report["reason"] = reason }
    return report
  }

  static func rootReport(_ scan: Scan, classified: [Classified]) -> [String: Any] {
    let items = classified.filter { $0.entry.root.id == scan.root.id }
    var counts = ["entries": items.count, "hidden": scan.hidden]
    for item in items { counts[item.kind, default: 0] += 1 }
    var report: [String: Any] = [
      "id": scan.root.id, "client": scan.root.client, "scope": scan.root.scope,
      "path": scan.root.path, "status": scan.status, "counts": counts,
      "entries": items.map { item -> [String: Any] in
        var entry = item.detail
        entry["name"] = item.entry.label
        entry["kind"] = item.entry.kind
        entry["class"] = item.kind
        if !item.evidence.isEmpty { entry["evidence"] = item.evidence }
        return entry
      },
    ]
    if !scan.managed.isEmpty { report["clientManaged"] = scan.managed }
    if !scan.root.sameFolderAs.isEmpty { report["sameFolderAs"] = scan.root.sameFolderAs }
    return report
  }
}
