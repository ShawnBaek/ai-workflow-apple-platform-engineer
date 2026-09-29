import CryptoKit
import Darwin
import Foundation

@testable import AppleVerificationCore

/// Temporary skill roots that reproduce the installed-state failures a real Mac showed: a
/// retired `native-app-lead` link, a Claude root missing a skill the agents root has, a differing
/// `core-simulator-health` copy under `CODEX_HOME/skills`, Apple-named folders, a Skills CLI lock
/// that still names `ShawnBaek/iOS-experts` for a retired and a missing skill, a foreign
/// same-name folder, and broken links. It adds the layouts the classes depend on: dangling links
/// with and without ownership evidence, a personal and a project skill of one name, a project
/// skill whose name the global lock gives the collection, a checkout skill the lifecycle file
/// does not list, copies and links of another pack's skills in two Codex roots, names Claude Code
/// skips, a file beside Xcode's own Apple skills, and both Xcode plugin layouts. The collection
/// it compares against is a small copy of the layout the verifier ships in, with its own
/// lifecycle file.
struct SkillInventoryFixture {
  static var lifecycle: [String: Any] {
    [
      "schemaVersion": "1.0.0", "version": "1.0.0",
      "source": "ShawnBaek/ai-workflow-apple-platform-engineer",
      "legacySources": ["ShawnBaek/iOS-experts"],
      "current": [
        "agent-harness", "apple-platform-engineer", "code-review", "core-simulator-health",
        "git-workflow", "sketch-design-from-codebase", "xcode-project-workflow", "xcodebuild",
      ],
      "retired": [
        ["id": "native-app-lead", "replacedBy": "apple-platform-engineer", "since": "1.0.0"]
      ],
      "reservedNames": [
        "appleSkills": ["device-interaction", "swiftui-specialist"],
        "appleNamespace": "xcode-integration",
        "clientBuiltins": [
          "claudeCode": ["code-review", "simplify"], "codex": ["skill-installer"],
        ],
        "exceptions": [["id": "code-review", "reason": "Kept until an approved rename."]],
      ],
    ]
  }

  let base: URL
  var collection: URL { base.appendingPathComponent("collection") }
  var skills: URL { collection.appendingPathComponent("skills") }
  var home: URL { base.appendingPathComponent("home") }
  var project: URL { base.appendingPathComponent("project/app") }
  var locations: SkillInventory.Locations {
    SkillInventory.Locations(home: home, project: project)
  }

  /// Builds the fixture in a new temporary directory; call `remove()` when done.
  static func make() throws -> SkillInventoryFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = SkillInventoryFixture(base: base)
    try fixture.build()
    return fixture
  }

  func remove() { try? FileManager.default.removeItem(at: base) }

  /// Runs the inventory in process against this fixture's collection.
  func report(_ locations: SkillInventory.Locations? = nil) throws -> [String: Any] {
    try SkillInventory.inventory(
      locations: locations ?? self.locations, collectionSkills: skills,
      lifecycle: Self.lifecycle)
  }

  func skill(_ path: String, _ body: String, extra: [String: String] = [:]) throws {
    let folder = base.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = folder.lastPathComponent
    try Data("---\nname: \(name)\ndescription: Fixture.\n---\n\(body)\n".utf8).write(
      to: folder.appendingPathComponent("SKILL.md"))
    for (file, text) in extra {
      let url = folder.appendingPathComponent(file)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  func link(_ path: String, to target: String) throws {
    let url = base.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
  }

  func write(_ path: String, _ text: String) throws {
    let url = base.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func build() throws {
    let collection = "collection/skills"
    for name in Self.lifecycle["current"] as! [String] {
      try skill(
        "\(collection)/\(name)", "Collection \(name).", extra: ["references/notes.md": name])
    }
    try write(
      "\(collection)/agent-harness/lifecycle/skill-lifecycle.json",
      String(decoding: try JSONSerialization.data(withJSONObject: Self.lifecycle), as: UTF8.self))
    // A skill in the checkout that the lifecycle file does not list.
    try skill("\(collection)/wip", "Work in progress.")
    try skill("old-bundle/skills/native-app-lead", "The retired lead.")
    try skill("old-bundle/skills/swift-testing-expert", "An iOS Experts skill never listed.")
    try skill("other-pack/find-skills", "Another pack's find-skills.")
    try skill("other-pack/screenshot", "Another pack's screenshot.")
    let skills = skills.path

    // Claude Code user root: links into the collection, the retired lead, a foreign
    // xcodebuild, broken links with and without ownership evidence, a personal skill a project
    // also has, and entries Claude Code manages itself.
    for name in ["agent-harness", "apple-platform-engineer", "core-simulator-health"] {
      try link("home/.claude/skills/\(name)", to: "\(skills)/\(name)")
    }
    try link(
      "home/.claude/skills/native-app-lead",
      to: base.appendingPathComponent("old-bundle/skills/native-app-lead").path)
    try skill("home/.claude/skills/xcodebuild", "Another pack's xcodebuild.")
    try link("home/.claude/skills/gone-skill", to: "../../missing/gone-skill")
    try link("home/.claude/skills/removed-skill", to: "\(skills)/removed-skill")
    try skill("home/.claude/skills/deploy", "The user's personal deploy skill.")
    try link("home/.claude/skills/wip", to: "\(skills)/wip")
    try skill("home/.claude/skills/.trash/stale", "Moved aside by Claude Code.")
    try skill("home/.claude/skills/synced/account-skill", "Synced from claude.ai.")
    try skill("home/.claude/skills/anthropic-skills:pdf", "A name Claude Code does not load.")

    // Agents root: one more collection link than Claude has, a byte-identical copy, an Apple
    // export, and an unlisted iOS Experts skill.
    for name in [
      "agent-harness", "apple-platform-engineer", "core-simulator-health",
      "sketch-design-from-codebase",
    ] {
      try link("home/.agents/skills/\(name)", to: "\(skills)/\(name)")
    }
    try FileManager.default.copyItem(
      atPath: "\(skills)/xcodebuild",
      toPath: home.appendingPathComponent(".agents/skills/xcodebuild").path)
    try skill("home/.agents/skills/swiftui-specialist", "An exported Apple skill.")
    try link(
      "home/.agents/skills/swift-testing-expert",
      to: base.appendingPathComponent("old-bundle/skills/swift-testing-expert").path)
    // A dangling link the lock attributes to iOS Experts.
    try link("home/.agents/skills/git-workflow", to: "../../gone/git-workflow")
    for name in ["find-skills", "screenshot"] {
      try link(
        "home/.agents/skills/\(name)", to: base.appendingPathComponent("other-pack/\(name)").path)
    }
    try write(
      "home/.agents/.skill-lock.json",
      """
      {"version": 3, "skills": {
        "native-app-lead": {
          "source": "https://github.com/ShawnBaek/iOS-experts.git", "sourceType": "github"},
        "core-simulator-health": {"source": "ShawnBaek/iOS-experts", "sourceType": "github"},
        "git-workflow": {"source": "shawnbaek/ios-experts", "sourceType": "github"},
        "swift-testing-expert": {
          "source": "git@github.com:ShawnBaek/iOS-experts.git", "sourceType": "git"},
        "asc-cli-usage": {"source": "someone/asc-skills", "sourceType": "github"}
      }}
      """)

    // Deprecated Codex root: a differing core-simulator-health, Apple and client names, a link
    // to the folder the agents root links to, and a byte-identical copy of another.
    try skill("home/.codex/skills/core-simulator-health", "An older core-simulator-health.")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: home.appendingPathComponent(".codex/skills/core-simulator-health").path)
    try skill("home/.codex/skills/device-interaction", "An exported Apple skill.")
    try skill("home/.codex/skills/skill-installer", "A copy of a Codex system skill.")
    try skill("home/.codex/skills/.system/skill-installer", "Codex's own system skill.")
    try link(
      "home/.codex/skills/find-skills",
      to: base.appendingPathComponent("other-pack/find-skills").path)
    try FileManager.default.copyItem(
      at: base.appendingPathComponent("other-pack/screenshot"),
      to: home.appendingPathComponent(".codex/skills/screenshot"))

    // Xcode's agents: its own Apple skills beside a file that is no skill, a link to the stale
    // Codex copy, imported plugins.
    let xcode = "home/Library/Developer/Xcode/CodingAssistant"
    try skill("\(xcode)/codex/skills/__xcode/swiftui-specialist", "Xcode's own Apple skill.")
    try write("\(xcode)/codex/skills/__xcode/manifest.json", "{}")
    try link(
      "\(xcode)/codex/skills/core-simulator-health",
      to: home.appendingPathComponent(".codex/skills/core-simulator-health").path)
    try skill(
      "\(xcode)/AgentPlugins/xcode-project-workflow/xcode-project-workflow", "A stale import.")
    try write("\(xcode)/AgentPlugins/xcode-project-workflow/plugin.json", "{}")
    try skill("\(xcode)/AgentPlugins/swiftui-specialist/swiftui-specialist", "An Apple import.")
    try skill("\(xcode)/AgentPlugins/figma/skills/figma-use", "A plugin's skills folder.")
    try write("\(xcode)/AgentPlugins/figma/.claude-plugin/plugin.json", "{}")

    // A repository with its own skills; the inventory starts one directory below its root.
    try FileManager.default.createDirectory(
      at: base.appendingPathComponent("project/.git"), withIntermediateDirectories: true)
    try skill("project/.claude/skills/deploy", "The repository's deploy skill.")
    try skill("project/.claude/skills/Synced", "Claude Code skips this name in any case.")
    try skill("project/.agents/skills/code-review", "The repository's own review skill.")
    // The global lock gives git-workflow to iOS Experts, but it records no project install.
    try skill("project/.agents/skills/git-workflow", "The repository's own git workflow.")
    try FileManager.default.createDirectory(
      at: base.appendingPathComponent("project/app/.claude/skills"),
      withIntermediateDirectories: true)
  }

  /// Every path below `root` with its type, mode, modification time and either its content
  /// digest or its link text, read without following links.
  static func snapshot(_ root: URL) throws -> [String: String] {
    var result = [String: String]()
    func visit(_ path: String, _ relative: String) throws {
      var info = stat()
      guard lstat(path, &info) == 0 else {
        throw VerificationError.invalid("snapshot cannot read \(relative)")
      }
      let stamp =
        "\(String(info.st_mode, radix: 8)) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
      switch info.st_mode & S_IFMT {
      case S_IFLNK:
        result[relative] =
          "link \(stamp) \(try FileManager.default.destinationOfSymbolicLink(atPath: path))"
      case S_IFREG:
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        result[relative] = "file \(stamp) \(digest.map { String(format: "%02x", $0) }.joined())"
      case S_IFDIR:
        result[relative] = "directory \(stamp)"
        for child in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
          try visit((path as NSString).appendingPathComponent(child), "\(relative)/\(child)")
        }
      default:
        result[relative] = "other \(stamp)"
      }
    }
    try visit(root.path, ".")
    return result
  }
}

/// The `unverified` reason of an entry compared with a reference inside the scanned root `root`:
/// its own folder (`itself`) or another folder.
func noIndependentReference(_ root: String, itself: Bool) -> String {
  "no independent reference (not compared, not a fault): "
    + (itself
      ? "this is the verifier's own reference copy"
      : "the verifier's reference copy is itself installed")
    + " in scanned root \(root); to compare, run apple-verify --repository-root "
    + "<reviewed checkout> skill-inventory, or build the verifier from the reviewed revision "
    + "outside the skill roots"
}

/// The findings of one class in a report.
func inventoryFindings(_ report: [String: Any], _ kind: String) -> [[String: Any]] {
  (report["findings"] as? [String: Any])?[kind] as? [[String: Any]] ?? []
}

/// The finding for `name` in one class, if the report has it.
func inventoryFinding(_ report: [String: Any], _ kind: String, _ name: String) -> [String: Any]? {
  inventoryFindings(report, kind).first { $0["name"] as? String == name }
}

/// Each classified entry of `name` as (root id, class, evidence).
func inventoryEntries(_ report: [String: Any], _ name: String) -> [(String, String, [String])] {
  (report["roots"] as? [[String: Any]] ?? []).flatMap { root in
    (root["entries"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == name }.map {
      (root["id"] as! String, $0["class"] as! String, $0["evidence"] as? [String] ?? [])
    }
  }
}

/// Each entry of `name` as "root class reason lock", from the per-root report.
func describeEntries(_ report: [String: Any], _ name: String) -> [String] {
  (report["roots"] as? [[String: Any]] ?? []).flatMap { root in
    (root["entries"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == name }.map {
      "\(root["id"]!) \($0["class"]!) \($0["reason"] ?? "-") \($0["lock"] ?? "-")"
    }
  }
}
