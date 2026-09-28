import Foundation
import Testing

@testable import AppleVerificationCore

/// Runs `body` with a fresh fixture and its in-process report, then removes the fixture.
private func withReport(_ body: (SkillInventoryFixture, [String: Any]) throws -> Void) throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try body(fixture, try fixture.report())
}

@Test func aRetiredLinkIsReportedWithItsReplacement() throws {
  try withReport { _, report in
    #expect(inventoryEntries(report, "native-app-lead").map(\.0) == ["claude-user"])
    #expect(inventoryEntries(report, "native-app-lead").map(\.1) == ["retired"])
    let finding = try #require(inventoryFinding(report, "retired", "native-app-lead"))
    #expect(finding["replacedBy"] as? String == "apple-platform-engineer")
    // The link leaves the collection; only the lock that names iOS Experts (by its HTTPS
    // clone URL) makes it ours.
    #expect(finding["evidence"] as? [String] == ["lock"])
  }
}

@Test func upToDateEntriesAreCurrentByPathLockOrHash() throws {
  try withReport { _, report in
    #expect(
      inventoryEntries(report, "agent-harness").map { "\($0.0) \($0.1) \($0.2)" } == [
        #"claude-user current ["path"]"#, #"agents-user current ["path"]"#,
      ])
    // A byte-identical copy that neither links into the collection nor appears in the lock.
    #expect(
      inventoryEntries(report, "xcodebuild").filter { $0.0 == "agents-user" }.map {
        "\($0.1) \($0.2)"
      } == [#"current ["hash"]"#])
  }
}

@Test func aSkillOnlyOneClientHasIsSplit() throws {
  try withReport { _, report in
    let finding = try #require(inventoryFinding(report, "split", "sketch-design-from-codebase"))
    #expect(finding["presentFor"] as? [String] == ["codex"])
    #expect(finding["missingFor"] as? [String] == ["claude"])
    #expect(finding["occupiedBy"] == nil)
    // Claude Code's root holds another pack's xcodebuild, so installing there would touch it.
    let occupied = try #require(inventoryFinding(report, "split", "xcodebuild"))
    #expect(occupied["missingFor"] as? [String] == ["claude"])
    #expect(occupied["occupiedBy"] as? [String] == ["claude-user"])
    // Both clients have agent-harness, so it is not split.
    #expect(inventoryFinding(report, "split", "agent-harness") == nil)
  }
}

@Test func aSingleClientInstallationIsNotSplit() throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".claude"))
  #expect(inventoryFindings(try fixture.report(), "split").isEmpty)
}

@Test func aDifferingCodexHomeCopyIsADuplicateAndOutdated() throws {
  try withReport { _, report in
    let duplicate = try #require(inventoryFinding(report, "duplicate", "core-simulator-health"))
    #expect(duplicate["client"] as? String == "codex")
    #expect(duplicate["roots"] as? [String] == ["agents-user", "codex-user"])
    #expect(duplicate["equalContent"] as? Bool == false)
    // The copy is the lock's (iOS Experts) but differs from the collection's; Xcode's hosted
    // Codex links to that same stale copy.
    #expect(
      inventoryEntries(report, "core-simulator-health").map { "\($0.0) \($0.1) \($0.2)" } == [
        #"claude-user current ["path", "lock"]"#, #"agents-user current ["path", "lock"]"#,
        #"codex-user outdated ["lock"]"#, #"xcode-codex outdated ["link"]"#,
      ])
  }
}

@Test func duplicatesCompareDifferentFoldersOfOneClient() throws {
  try withReport { _, report in
    // Claude Code runs the personal copy over the project's.
    let personal = try #require(inventoryFinding(report, "duplicate", "deploy"))
    #expect(personal["client"] as? String == "claude")
    #expect(personal["roots"] as? [String] == ["claude-user", "claude-project:."])
    #expect(personal["equalContent"] as? Bool == false)
    // Another pack's skill linked from one Codex root and copied byte for byte into the other.
    let copied = try #require(inventoryFinding(report, "duplicate", "screenshot"))
    #expect(copied["roots"] as? [String] == ["agents-user", "codex-user"])
    #expect(copied["classes"] as? [String] == ["foreign", "foreign"])
    #expect(copied["equalContent"] as? Bool == true)
    // Two links to one folder: Codex loads that SKILL.md once, so it is no duplicate.
    #expect(
      inventoryEntries(report, "find-skills").map { "\($0.0) \($0.1)" } == [
        "agents-user foreign", "codex-user foreign",
      ])
    #expect(inventoryFinding(report, "duplicate", "find-skills") == nil)
  }
}

@Test func aFolderTwoClientsShareIsListedOnceForEachClient() throws {
  // ~/.claude/skills linked to ~/.agents/skills: Claude Code and Codex both load every skill
  // there, so nothing is split. ~/.codex/skills linked to the same folder is one Codex folder,
  // listed once.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  for folder in [".claude/skills", ".codex/skills"] {
    try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(folder))
    try fixture.link(
      "home/\(folder)", to: fixture.home.appendingPathComponent(".agents/skills").path)
  }
  let report = try fixture.report()
  let roots = Dictionary(
    uniqueKeysWithValues: (report["roots"] as! [[String: Any]]).map {
      ($0["id"] as! String, $0)
    })
  #expect(roots["claude-user"]?["status"] as? String == "present")
  #expect(roots["agents-user"]?["status"] as? String == "present")
  #expect(roots["agents-user"]?["sameFolderAs"] as? [String] == ["claude-user"])
  #expect(roots["codex-user"]?["status"] as? String == "sameFolder")
  #expect(roots["codex-user"]?["sameFolderAs"] as? [String] == ["claude-user", "agents-user"])
  #expect((roots["codex-user"]?["entries"] as? [Any])?.isEmpty == true)
  #expect(
    inventoryEntries(report, "sketch-design-from-codebase").map { "\($0.0) \($0.1)" } == [
      "claude-user current", "agents-user current",
    ])
  #expect(inventoryFindings(report, "split").isEmpty)
  #expect(inventoryFindings(report, "duplicate").isEmpty)
}

@Test func appleAndClientNamesAreReservedAndNeverOurs() throws {
  try withReport { _, report in
    let reserved = inventoryFindings(report, "reserved")
    #expect(
      reserved.map { "\($0["name"]!) \($0["roots"]!) \($0["reservedBy"]!)" } == [
        "device-interaction [\"codex-user\"] reservedNames.appleSkills",
        "skill-installer [\"codex-user\"] reservedNames.clientBuiltins.codex",
        "swiftui-specialist [\"agents-user\"] reservedNames.appleSkills",
        "swiftui-specialist:swiftui-specialist [\"xcode-plugins\"] reservedNames.appleSkills",
      ])
    // Xcode's own rendered skill is Apple's: listed, never hashed or claimed. A file beside it
    // is no skill.
    #expect(
      inventoryEntries(report, "swiftui-specialist").map { "\($0.0) \($0.1)" } == [
        "agents-user reserved", "xcode-apple apple",
      ])
    #expect(
      inventoryEntries(report, "manifest.json").map { "\($0.0) \($0.1)" } == [
        "xcode-apple ignored"
      ])
    let roots = report["roots"] as! [[String: Any]]
    let xcodeCodex = try #require(roots.first { $0["id"] as? String == "xcode-codex" })
    #expect(xcodeCodex["clientManaged"] as? [String] == ["__xcode"])
  }
}

@Test func staleLockEntriesNameRetiredMissingAndUnlistedSkills() throws {
  try withReport { _, report in
    #expect(
      inventoryFindings(report, "staleLock").map { "\($0["name"]!) \($0["reason"]!)" } == [
        "git-workflow missing", "native-app-lead retired", "swift-testing-expert notInLifecycle",
      ])
    #expect(
      inventoryFinding(report, "staleLock", "native-app-lead")?["replacedBy"] as? String
        == "apple-platform-engineer")
    #expect(
      inventoryFindings(report, "staleLock").allSatisfy { $0["lock"] as? String == "global" })
    // Entries whose evidence makes them the collection's, by the lock or by resolving into the
    // collection's skills folder, with names the lifecycle file does not list.
    #expect(
      inventoryEntries(report, "swift-testing-expert").map { "\($0.0) \($0.1) \($0.2)" } == [
        #"agents-user unlisted ["lock"]"#
      ])
    #expect(
      inventoryEntries(report, "wip").map { "\($0.0) \($0.1) \($0.2)" } == [
        #"claude-user unlisted ["path"]"#
      ])
    let lock = report["lock"] as! [String: Any]
    #expect(lock["status"] as? String == "read")
    #expect(lock["entries"] as? Int == 5)
    #expect(lock["collectionEntries"] as? Int == 4)
    // Every collection entry still names the former repository: installed before the rename.
    #expect(
      lock["legacySource"] as? [String] == [
        "core-simulator-health", "git-workflow", "native-app-lead", "swift-testing-expert",
      ])
    #expect(lock["localSource"] == nil)
  }
}

@Test func aForeignSameNameFolderIsNeverClaimed() throws {
  try withReport { _, report in
    #expect(
      inventoryEntries(report, "xcodebuild").map { "\($0.0) \($0.1) \($0.2)" } == [
        "claude-user foreignSameName []", #"agents-user current ["hash"]"#,
      ])
    // The repository's own code-review and Xcode's stale import are not ours either.
    #expect(
      inventoryFindings(report, "foreignSameName").map { "\($0["name"]!) \($0["roots"]!)" } == [
        "code-review [\"agents-project:.\"]", "git-workflow [\"agents-project:.\"]",
        "xcode-project-workflow:xcode-project-workflow [\"xcode-plugins\"]",
        "xcodebuild [\"claude-user\"]",
      ])
    // The global lock gives git-workflow to iOS Experts, which makes the user root's dangling
    // link ours, but it records no project install: the repository's own folder stays its own.
    #expect(
      inventoryEntries(report, "git-workflow").map { "\($0.0) \($0.1) \($0.2)" } == [
        #"agents-user broken ["lock"]"#, "agents-project:. foreignSameName []",
      ])
    #expect(inventoryFinding(report, "foreignSameName", "git-workflow")?["lock"] == nil)
    // Both Xcode plugin layouts are listed: `<plugin>/<skill>` and `<plugin>/skills/<skill>`.
    #expect(
      inventoryEntries(report, "figma:figma-use").map { "\($0.0) \($0.1)" } == [
        "xcode-plugins foreign"
      ])
  }
}

@Test func aBrokenLinkIsReportedAndHiddenOrManagedEntriesAreSkipped() throws {
  try withReport { _, report in
    let broken = try #require(inventoryFinding(report, "broken", "gone-skill"))
    #expect(broken["roots"] as? [String] == ["claude-user"])
    #expect(broken["evidence"] == nil)
    // A dangling link into the collection's skills folder, and one the lock attributes to
    // iOS Experts: a reconcile may remove these, and only these.
    #expect(
      inventoryEntries(report, "removed-skill").map { "\($0.0) \($0.1) \($0.2)" } == [
        #"claude-user broken ["path"]"#
      ])
    let locked = try #require(inventoryFinding(report, "broken", "git-workflow"))
    #expect(locked["roots"] as? [String] == ["agents-user"])
    #expect(locked["evidence"] as? [String] == ["lock"])
    let roots = report["roots"] as! [[String: Any]]
    let claude = try #require(roots.first { $0["id"] as? String == "claude-user" })
    #expect((claude["counts"] as? [String: Int])?["hidden"] == 1)
    // Claude Code skips its synced folder and the anthropic-skills namespace.
    #expect(claude["clientManaged"] as? [String] == ["anthropic-skills:pdf", "synced"])
    #expect(inventoryEntries(report, "anthropic-skills:pdf").isEmpty)
    // Claude Code skips a project's `synced` folder too, in any capitalization.
    let project = try #require(roots.first { $0["id"] as? String == "claude-project:." })
    #expect(project["clientManaged"] as? [String] == ["Synced"])
    #expect(inventoryEntries(report, "Synced").isEmpty)
    #expect(inventoryEntries(report, "stale").isEmpty)
    #expect(inventoryEntries(report, "account-skill").isEmpty)
  }
}

@Test func theFixtureSummaryIsExact() throws {
  try withReport { _, report in
    #expect(report["status"] as? String == "attention")
    #expect(report["readOnly"] as? Bool == true)
    let summary = try #require(report["summary"] as? [String: [String: Any]])
    #expect(
      summary.mapValues { $0["names"] as! [String] } == [
        "apple": ["swiftui-specialist"],
        "broken": ["git-workflow", "gone-skill", "removed-skill"],
        "current": [
          "agent-harness", "apple-platform-engineer", "core-simulator-health",
          "sketch-design-from-codebase", "xcodebuild",
        ],
        "duplicate": ["core-simulator-health", "deploy", "screenshot"],
        "foreign": ["deploy", "figma:figma-use", "find-skills", "screenshot"],
        "foreignSameName": [
          "code-review", "git-workflow", "xcode-project-workflow:xcode-project-workflow",
          "xcodebuild",
        ],
        "ignored": ["manifest.json"],
        "outdated": ["core-simulator-health"],
        "reserved": [
          "device-interaction", "skill-installer", "swiftui-specialist",
          "swiftui-specialist:swiftui-specialist",
        ],
        "retired": ["native-app-lead"],
        "split": ["sketch-design-from-codebase", "xcodebuild"],
        "staleLock": ["git-workflow", "native-app-lead", "swift-testing-expert"],
        "unlisted": ["swift-testing-expert", "wip"],
      ])
    let steps = try #require(report["nextSteps"] as? [String: String])
    #expect(
      Set(steps.keys)
        == Set(summary.keys).subtracting(["apple", "current", "foreign", "ignored"]))
  }
}

@Test func aCopyBesideAnInstalledVerifierIsOursOnlyWhenTheLockAgrees() throws {
  // A Skills CLI copy: the verifier runs from ~/.agents/skills/agent-harness, so its reference
  // folder is a scanned root that also holds other owners' skills. The CLI records each global
  // install in the lock, so there only the verifier's own folder and the entries the lock gives
  // this repository are ours, or references that make an identical copy elsewhere ours.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let agents = fixture.home.appendingPathComponent(".agents/skills")
  let manager = FileManager.default
  for name in ["agent-harness", "apple-platform-engineer"] {
    try manager.removeItem(at: agents.appendingPathComponent(name))
    try manager.copyItem(
      at: fixture.skills.appendingPathComponent(name), to: agents.appendingPathComponent(name))
  }
  try manager.copyItem(
    at: agents.appendingPathComponent("xcodebuild"),
    to: fixture.home.appendingPathComponent(".codex/skills/xcodebuild"))
  // The user's own skill, linked for Claude Code too; a dangling Claude link into the folder;
  // and a Claude Code builtin name the lock gives this repository.
  try fixture.skill("home/.agents/skills/my-own-skill", "The user's own skill.")
  try fixture.link(
    "home/.claude/skills/my-own-skill", to: agents.appendingPathComponent("my-own-skill").path)
  try fixture.link(
    "home/.claude/skills/gone-own-skill", to: agents.appendingPathComponent("gone-own-skill").path)
  try fixture.skill("home/.agents/skills/simplify", "A copy of a Claude Code builtin.")
  let collection = "ShawnBaek/ai-workflow-apple-platform-engineer"
  try fixture.write(
    "home/.agents/.skill-lock.json",
    """
    {"version": 3, "skills": {"apple-platform-engineer": {"source": "\(collection)"},
      "simplify": {"source": "\(collection)"}, "xcodebuild": {"source": "another/pack"}}}
    """)
  let report = try SkillInventory.inventory(
    locations: fixture.locations, collectionSkills: agents,
    lifecycle: SkillInventoryFixture.lifecycle)
  #expect(
    (report["collection"] as? [String: Any])?["reference"] as? String
      == "scanned root agents-user")
  // The verifier's own folder is the reference without a lock entry. Claude's links reach the
  // fixture's checkout, another copy of the collection, whose content matches. A locked copy is
  // ours, and the lock covers Claude's user root too.
  #expect(
    inventoryEntries(report, "agent-harness").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-user current ["copy"]"#, #"agents-user current ["path"]"#,
    ])
  #expect(
    inventoryEntries(report, "apple-platform-engineer").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-user current ["copy", "lock"]"#, #"agents-user current ["path", "lock"]"#,
    ])
  // Unlocked entries beside the verifier are not ours, even through a Claude Code link.
  #expect(
    inventoryEntries(report, "my-own-skill").map { "\($0.0) \($0.1) \($0.2)" } == [
      "claude-user foreign []", "agents-user foreign []",
    ])
  #expect(
    inventoryEntries(report, "gone-own-skill").map { "\($0.0) \($0.1) \($0.2)" } == [
      "claude-user broken []"
    ])
  // A client's builtin name stays reserved whatever the lock says; the lock entry is stale.
  #expect(
    inventoryEntries(report, "simplify").map { "\($0.0) \($0.1) \($0.2)" } == [
      "agents-user reserved []"
    ])
  #expect(
    inventoryFinding(report, "staleLock", "simplify")?["reason"] as? String == "notInLifecycle")
  #expect(
    inventoryEntries(report, "xcodebuild").map { "\($0.0) \($0.1)" } == [
      "claude-user foreignSameName", "agents-user foreignSameName",
      "codex-user foreignSameName",
    ])
  #expect(
    inventoryFinding(report, "foreignSameName", "xcodebuild")?["lock"] as? String == "foreign")
  // A retired collection name no lock or path attributes to the collection is not claimed.
  #expect(
    inventoryEntries(report, "native-app-lead").map { "\($0.0) \($0.1) \($0.2)" } == [
      "claude-user foreignSameName []"
    ])
}

@Test func anOwnedCopyThatCannotBeHashedIsUnverified() throws {
  // The collection's hash refuses a nested link, so the lock-owned Codex copy cannot be
  // compared: neither current nor outdated, and its duplicate's equality is unknown.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try fixture.link("home/.codex/skills/core-simulator-health/notes.md", to: "SKILL.md")
  let report = try fixture.report()
  let finding = try #require(inventoryFinding(report, "unverified", "core-simulator-health"))
  #expect(finding["roots"] as? [String] == ["codex-user", "xcode-codex"])
  #expect(finding["reason"] as? String == "installed skill contains an unsupported nested symlink")
  #expect(inventoryFinding(report, "outdated", "core-simulator-health") == nil)
  let duplicate = try #require(inventoryFinding(report, "duplicate", "core-simulator-health"))
  #expect(duplicate["equalContent"] is NSNull)
}

@Test func aProjectScopeInstallIsOursByItsProjectLock() throws {
  // `npx skills add` without -g: copies in the project's .agents/skills, relative Claude Code
  // links to them, and a skills-lock.json beside them; the global lock records none of it. The
  // installation's own verifier runs with the project's skills folder as its reference.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let manager = FileManager.default
  let app = fixture.base.appendingPathComponent("app")
  let agents = app.appendingPathComponent(".agents/skills")
  try manager.createDirectory(
    at: app.appendingPathComponent(".git"), withIntermediateDirectories: true)
  try manager.createDirectory(at: agents, withIntermediateDirectories: true)
  let installed = [
    "agent-harness", "apple-platform-engineer", "core-simulator-health", "xcodebuild",
  ]
  for name in installed {
    try manager.copyItem(
      at: fixture.skills.appendingPathComponent(name), to: agents.appendingPathComponent(name))
    try fixture.link("app/.claude/skills/\(name)", to: "../../.agents/skills/\(name)")
  }
  // The team's own skill beside the collection's.
  try fixture.skill("app/.agents/skills/team-deploy", "The team's deploy skill.")
  try fixture.link("app/.claude/skills/team-deploy", to: "../../.agents/skills/team-deploy")
  func writeLock(_ names: [String]) throws {
    let entries = names.map {
      #""\#($0)": {"source": "ShawnBaek/ai-workflow-apple-platform-engineer", "#
        + #""sourceType": "github", "computedHash": "0"}"#
    }
    try fixture.write(
      "app/skills-lock.json", #"{"version": 1, "skills": {\#(entries.joined(separator: ", "))}}"#)
  }
  try writeLock(installed)
  let locations = SkillInventory.Locations(
    home: fixture.base.appendingPathComponent("empty-home"), project: app)
  func report() throws -> [String: Any] {
    try SkillInventory.inventory(
      locations: locations, collectionSkills: agents, lifecycle: SkillInventoryFixture.lifecycle)
  }
  let clean = try report()
  #expect(clean["status"] as? String == "clean")
  #expect(
    (clean["collection"] as? [String: Any])?["reference"] as? String
      == "scanned root agents-project:.")
  #expect((clean["lock"] as? [String: Any])?["status"] as? String == "absent")
  let projectLocks = try #require(clean["projectLocks"] as? [[String: Any]])
  #expect(
    projectLocks.map { "\($0["id"]!) \($0["location"]!) \($0["status"]!) \($0["entries"]!)" }
      == ["project:. ./skills-lock.json read 4"])
  for name in installed {
    #expect(
      inventoryEntries(clean, name).map { "\($0.0) \($0.1) \($0.2)" } == [
        #"claude-project:. current ["path", "lock"]"#,
        #"agents-project:. current ["path", "lock"]"#,
      ])
  }
  #expect(
    inventoryEntries(clean, "team-deploy").map { "\($0.0) \($0.1)" } == [
      "claude-project:. foreign", "agents-project:. foreign",
    ])
  // A collection name beside the verifier that the lock does not record is unverified, even
  // though the lock records this installation: one installation can mix sources (a skill added
  // later from a local checkout gets no entry). A retired lock entry is stale in the project lock.
  try fixture.skill("app/.agents/skills/git-workflow", "A git workflow no lock records.")
  try writeLock(installed + ["native-app-lead"])
  let edited = try report()
  #expect(
    inventoryEntries(edited, "git-workflow").map { "\($0.0) \($0.1) \($0.2)" } == [
      "agents-project:. unverified []"
    ])
  #expect(
    inventoryFinding(edited, "unverified", "git-workflow")?["reason"] as? String
      == "beside the verifier; no lock records it")
  #expect(
    inventoryFindings(edited, "staleLock").map { "\($0["name"]!) \($0["lock"]!) \($0["reason"]!)" }
      == ["native-app-lead project:. retired"])
}

@Test func anUntrackedCopyBesideTheVerifierIsUnverifiedNotForeign() throws {
  // Skill folders copied into ~/.agents/skills without the Skills CLI, the verifier among them,
  // and Claude Code given a link to one and a copy of another. No lock records any of it, so
  // nothing says whether a collection name beside the verifier is this installation's.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let manager = FileManager.default
  let home = fixture.base.appendingPathComponent("untracked-home")
  let agents = home.appendingPathComponent(".agents/skills")
  try manager.createDirectory(at: agents, withIntermediateDirectories: true)
  for name in ["agent-harness", "apple-platform-engineer", "xcodebuild"] {
    try manager.copyItem(
      at: fixture.skills.appendingPathComponent(name), to: agents.appendingPathComponent(name))
  }
  try manager.copyItem(
    at: fixture.base.appendingPathComponent("old-bundle/skills/native-app-lead"),
    to: agents.appendingPathComponent("native-app-lead"))
  try fixture.skill("untracked-home/.agents/skills/my-own-skill", "The user's own skill.")
  for name in ["agent-harness", "apple-platform-engineer"] {
    try fixture.link(
      "untracked-home/.claude/skills/\(name)", to: agents.appendingPathComponent(name).path)
  }
  try manager.copyItem(
    at: agents.appendingPathComponent("xcodebuild"),
    to: home.appendingPathComponent(".claude/skills/xcodebuild"))
  // A differing copy has nothing to match: no evidence at all.
  try fixture.skill("untracked-home/.claude/skills/git-workflow", "Someone's git workflow.")
  let report = try SkillInventory.inventory(
    locations: SkillInventory.Locations(home: home), collectionSkills: agents,
    lifecycle: SkillInventoryFixture.lifecycle)
  func describe(_ name: String) -> [String] {
    let roots = (report["roots"] as? [[String: Any]]) ?? []
    return roots.flatMap { root in
      ((root["entries"] as? [[String: Any]]) ?? []).filter { $0["name"] as? String == name }.map {
        "\(root["id"]!) \($0["class"]!) \($0["reason"] ?? "-")"
      }
    }
  }
  let beside = "beside the verifier; no lock records it"
  #expect(describe("agent-harness") == ["claude-user current -", "agents-user current -"])
  #expect(
    describe("apple-platform-engineer") == [
      "claude-user unverified \(beside)", "agents-user unverified \(beside)",
    ])
  #expect(
    describe("xcodebuild") == [
      "claude-user unverified same content as the copy beside the verifier, which no lock "
        + "attributes",
      "agents-user unverified \(beside)",
    ])
  #expect(describe("native-app-lead") == ["agents-user unverified \(beside)"])
  #expect(
    inventoryFinding(report, "unverified", "native-app-lead")?["replacedBy"] as? String
      == "apple-platform-engineer")
  #expect(describe("my-own-skill") == ["agents-user foreign -"])
  #expect(describe("git-workflow") == ["claude-user foreignSameName -"])
  // A retired name is never split; the current ones each client has are not either.
  #expect(inventoryFindings(report, "split").isEmpty)
}

@Test func aClientWhoseOnlyCopyIsOutdatedOrUnverifiedIsNotSplit() throws {
  // Claude Code holds only an outdated sketch-design-from-codebase and an xcodebuild that cannot
  // be hashed; both are the collection's by the lock, so neither client lacks them.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let claude = fixture.home.appendingPathComponent(".claude/skills")
  try FileManager.default.removeItem(at: claude.appendingPathComponent("xcodebuild"))
  try FileManager.default.copyItem(
    at: fixture.skills.appendingPathComponent("xcodebuild"),
    to: claude.appendingPathComponent("xcodebuild"))
  try fixture.link("home/.claude/skills/xcodebuild/notes.md", to: "SKILL.md")
  try fixture.skill("home/.claude/skills/sketch-design-from-codebase", "An older copy.")
  let collection = "ShawnBaek/ai-workflow-apple-platform-engineer"
  try fixture.write(
    "home/.agents/.skill-lock.json",
    """
    {"version": 3, "skills": {"xcodebuild": {"source": "\(collection)"},
      "sketch-design-from-codebase": {"source": "\(collection)"}}}
    """)
  let report = try fixture.report()
  #expect(
    inventoryEntries(report, "sketch-design-from-codebase").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-user outdated ["lock"]"#, #"agents-user current ["path", "lock"]"#,
    ])
  #expect(
    inventoryEntries(report, "xcodebuild").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-user unverified ["lock"]"#, #"agents-user current ["lock"]"#,
    ])
  #expect(inventoryFinding(report, "split", "sketch-design-from-codebase") == nil)
  #expect(inventoryFinding(report, "split", "xcodebuild") == nil)
}

@Test func aFolderReachedThroughALinkedRootInheritsOwnership() throws {
  // The project's .claude/skills links to ~/.agents/skills, where the lock makes an outdated
  // real folder ours. Claude Code lists that same folder as a project entry, which no lock
  // covers; it is ours because it is the folder the user root proved ours.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let manager = FileManager.default
  try manager.removeItem(
    at: fixture.home.appendingPathComponent(".agents/skills/core-simulator-health"))
  try fixture.skill("home/.agents/skills/core-simulator-health", "An older copy.")
  try manager.removeItem(at: fixture.project.appendingPathComponent(".claude/skills"))
  try fixture.link(
    "project/app/.claude/skills", to: fixture.home.appendingPathComponent(".agents/skills").path)
  let report = try fixture.report()
  #expect(
    inventoryEntries(report, "core-simulator-health").filter {
      ["agents-user", "claude-project:app"].contains($0.0)
    }.map { "\($0.0) \($0.1) \($0.2)" } == [
      #"agents-user outdated ["lock"]"#, #"claude-project:app outdated ["link"]"#,
    ])
}

@Test func aGlobalInstallAddedFromALocalCheckoutIsUnverified() throws {
  // agent-harness and xcodebuild installed globally from GitHub, then two more skills added with
  // -g from a local reviewed checkout, as the update reference documents: the CLI records no
  // global lock entry for a local source, so the lock names only the first two.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let manager = FileManager.default
  let home = fixture.base.appendingPathComponent("local-home")
  let agents = home.appendingPathComponent(".agents/skills")
  try manager.createDirectory(at: agents, withIntermediateDirectories: true)
  for name in ["agent-harness", "xcodebuild", "apple-platform-engineer", "core-simulator-health"] {
    try manager.copyItem(
      at: fixture.skills.appendingPathComponent(name), to: agents.appendingPathComponent(name))
  }
  try fixture.link(
    "local-home/.claude/skills/apple-platform-engineer",
    to: agents.appendingPathComponent("apple-platform-engineer").path)
  let collection = "ShawnBaek/ai-workflow-apple-platform-engineer"
  try fixture.write(
    "local-home/.agents/.skill-lock.json",
    """
    {"version": 3, "skills": {
      "agent-harness": {"source": "\(collection)", "sourceType": "github"},
      "xcodebuild": {"source": "\(collection)", "sourceType": "github"}}}
    """)
  let report = try SkillInventory.inventory(
    locations: SkillInventory.Locations(home: home), collectionSkills: agents,
    lifecycle: SkillInventoryFixture.lifecycle)
  #expect(
    inventoryEntries(report, "xcodebuild").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"agents-user current ["path", "lock"]"#
    ])
  // The lock records the verifier, which says nothing about the skills added later.
  let beside = "beside the verifier; no lock records it"
  #expect(
    describeEntries(report, "apple-platform-engineer") == [
      "claude-user unverified \(beside) -", "agents-user unverified \(beside) -",
    ])
  #expect(
    describeEntries(report, "core-simulator-health") == ["agents-user unverified \(beside) -"])
  #expect(inventoryFindings(report, "foreignSameName").isEmpty)
  // Both entries name the current repository, so none is a former name's.
  let lock = try #require(report["lock"] as? [String: Any])
  #expect(lock["collectionEntries"] as? Int == 2)
  #expect(lock["legacySource"] == nil)
}

@Test func aProjectInstallFromALocalPathIsUnverifiedNeverAnotherOwners() throws {
  // `npx skills add <path>` without -g: the project's skills-lock.json records each skill with
  // `sourceType` `local` and a path relative to the lock, or an absolute one from another drive
  // of a Windows teammate. An entry without `sourceType` whose source is a path counts as local
  // too. None of them names a repository, so none is another owner's.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let manager = FileManager.default
  let app = fixture.base.appendingPathComponent("local-app")
  let agents = app.appendingPathComponent(".agents/skills")
  try manager.createDirectory(
    at: app.appendingPathComponent(".git"), withIntermediateDirectories: true)
  try manager.createDirectory(at: agents, withIntermediateDirectories: true)
  for name in ["agent-harness", "apple-platform-engineer", "core-simulator-health"] {
    try manager.copyItem(
      at: fixture.skills.appendingPathComponent(name), to: agents.appendingPathComponent(name))
  }
  // Installed from an older checkout: its content differs from every collection copy.
  try fixture.skill("local-app/.agents/skills/git-workflow", "An older git workflow.")
  for name in ["agent-harness", "apple-platform-engineer", "core-simulator-health", "git-workflow"]
  {
    try fixture.link("local-app/.claude/skills/\(name)", to: "../../.agents/skills/\(name)")
  }
  try fixture.write(
    "local-app/skills-lock.json",
    """
    {"version": 1, "skills": {
      "agent-harness": {"source": "./vendor/ape", "sourceType": "local", "computedHash": "0"},
      "apple-platform-engineer": {
        "source": "../src/ape", "sourceType": "local", "computedHash": "0"},
      "core-simulator-health": {"source": "\(fixture.base.path)/src/ape", "computedHash": "0"},
      "git-workflow": {"source": "C:/src/ape", "sourceType": "local", "computedHash": "0"}}}
    """)
  let locations = SkillInventory.Locations(
    home: fixture.base.appendingPathComponent("empty-home"), project: app)
  // The installation's own verifier: its skills folder is the project's .agents/skills.
  let installed = try SkillInventory.inventory(
    locations: locations, collectionSkills: agents, lifecycle: SkillInventoryFixture.lifecycle)
  let projectLocks = try #require(installed["projectLocks"] as? [[String: Any]])
  #expect(projectLocks.first?["entries"] as? Int == 4)
  #expect(projectLocks.first?["collectionEntries"] as? Int == 0)
  #expect(
    projectLocks.first?["localSource"] as? [String] == [
      "agent-harness", "apple-platform-engineer", "core-simulator-health", "git-workflow",
    ])
  #expect(
    inventoryEntries(installed, "agent-harness").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-project:. current ["path"]"#, #"agents-project:. current ["path"]"#,
    ])
  let beside = "beside the verifier; its lock records a local path, which names no repository"
  for name in ["apple-platform-engineer", "core-simulator-health", "git-workflow"] {
    #expect(
      describeEntries(installed, name) == [
        "claude-project:. unverified \(beside) local",
        "agents-project:. unverified \(beside) local",
      ])
  }
  #expect(inventoryFindings(installed, "foreignSameName").isEmpty)
  // A checkout's verifier: identical copies are current by hash, and the older copy the lock
  // records from a local path is unverified, not another owner's.
  let checkout = try SkillInventory.inventory(
    locations: locations, collectionSkills: fixture.skills,
    lifecycle: SkillInventoryFixture.lifecycle)
  #expect(
    inventoryEntries(checkout, "apple-platform-engineer").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-project:. current ["hash"]"#, #"agents-project:. current ["hash"]"#,
    ])
  let local = "its lock records a local path, which names no repository"
  #expect(
    describeEntries(checkout, "git-workflow") == [
      "claude-project:. unverified \(local) local", "agents-project:. unverified \(local) local",
    ])
  #expect(inventoryFindings(checkout, "foreignSameName").isEmpty)
}

@Test func aProjectCodexRootIsCoveredByNoLock() throws {
  // The Skills CLI installs Codex skills into .agents/skills and never into .codex/skills, so
  // the project's skills-lock.json says nothing about a repository's own .codex/skills folder,
  // even for a name it gives this repository.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try fixture.skill("project/.codex/skills/xcodebuild", "The repository's own xcodebuild.")
  try fixture.write(
    "project/skills-lock.json",
    """
    {"version": 1, "skills": {"xcodebuild": {
      "source": "ShawnBaek/ai-workflow-apple-platform-engineer", "sourceType": "github",
      "computedHash": "0"}}}
    """)
  let report = try fixture.report()
  #expect(
    inventoryEntries(report, "xcodebuild").filter { $0.0 == "codex-project:." }.map {
      "\($0.1) \($0.2)"
    } == ["foreignSameName []"])
  #expect(
    describeEntries(report, "xcodebuild").filter { $0.hasPrefix("codex-project:.") } == [
      "codex-project:. foreignSameName - -"
    ])
  // The lock covers only the project's .agents/skills and .claude/skills, which lack it.
  #expect(
    inventoryFindings(report, "staleLock").filter { $0["lock"] as? String == "project:." }.map {
      "\($0["name"]!) \($0["reason"]!)"
    } == ["xcodebuild missing"])
}
