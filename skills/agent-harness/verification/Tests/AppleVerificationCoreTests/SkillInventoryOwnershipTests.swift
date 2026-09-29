import Foundation
import Testing

@testable import AppleVerificationCore

/// Each entry of `name` as "root class evidence installedFrom", from the per-root report.
private func describeCopies(_ report: [String: Any], _ name: String) -> [String] {
  (report["roots"] as? [[String: Any]] ?? []).flatMap { root in
    (root["entries"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == name }.map {
      let copy = ($0["installedFrom"] as? [String: String]).map {
        "\($0["root"] ?? "-")@\($0["version"] ?? "-")"
      }
      return "\(root["id"]!) \($0["class"]!) \($0["evidence"] as? [String] ?? []) \(copy ?? "-")"
    }
  }
}

@Test func anOlderBundleOfTheCollectionIsOursAndComparedWithTheCheckout() throws {
  // A versioned bundle from a release before the lifecycle file: VERSION 2.0.0-beta.9, the
  // harness contracts, no .git. An activation link selects it, and the client roots link into it
  // relatively (as the Skills CLI and the link farm do) and absolutely. A newer bundle with a
  // lifecycle file that names this repository by its clone URL holds one more skill. The
  // verifier runs from a newer checkout, so every one of them is compared with that checkout.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let old = "bundles/ape/04ed737"
  try fixture.write("\(old)/VERSION", "2.0.0-beta.9\n")
  try fixture.write("\(old)/skills/agent-harness/contracts/capabilities.json", "{}")
  try fixture.skill("\(old)/skills/agent-harness", "An older harness.")
  try fixture.skill("\(old)/skills/apple-platform-engineer", "An older lead.")
  try FileManager.default.copyItem(
    at: fixture.skills.appendingPathComponent("xcodebuild"),
    to: fixture.base.appendingPathComponent("\(old)/skills/xcodebuild"))
  try fixture.skill("\(old)/skills/native-app-lead", "The retired lead.")
  let new = "bundles/ape/5d1e2f0"
  try fixture.write("\(new)/VERSION", "2.0.0-beta.11\n")
  try fixture.write(
    "\(new)/skills/agent-harness/lifecycle/skill-lifecycle.json",
    #"{"source": "https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer.git"}"#)
  try FileManager.default.copyItem(
    at: fixture.skills.appendingPathComponent("core-simulator-health"),
    to: fixture.base.appendingPathComponent("\(new)/skills/core-simulator-health"))
  let bundle = { (path: String) in fixture.base.appendingPathComponent(path).path }
  try fixture.link("bundle-home/.agents/ape-active", to: bundle(old))
  let names = ["agent-harness", "apple-platform-engineer", "xcodebuild", "native-app-lead"]
  for name in names {
    try fixture.link("bundle-home/.agents/skills/\(name)", to: "../ape-active/skills/\(name)")
  }
  for name in ["agent-harness", "apple-platform-engineer"] {
    try fixture.link("bundle-home/.claude/skills/\(name)", to: bundle("\(old)/skills/\(name)"))
  }
  for name in ["xcodebuild", "native-app-lead"] {
    try fixture.link("bundle-home/.claude/skills/\(name)", to: "../../.agents/skills/\(name)")
  }
  for root in [".claude", ".codex"] {
    try fixture.link(
      "bundle-home/\(root)/skills/core-simulator-health",
      to: bundle("\(new)/skills/core-simulator-health"))
  }
  let report = try fixture.report(
    SkillInventory.Locations(home: fixture.base.appendingPathComponent("bundle-home")))
  let beta9 = "\(SkillInventory.realPath(bundle(old))!)@2.0.0-beta.9"
  let beta11 = "\(SkillInventory.realPath(bundle(new))!)@2.0.0-beta.11"
  for (name, kind) in [
    ("agent-harness", "outdated"), ("apple-platform-engineer", "outdated"),
    ("xcodebuild", "current"), ("native-app-lead", "retired"),
  ] {
    #expect(
      describeCopies(report, name) == [
        #"claude-user \#(kind) ["copy"] \#(beta9)"#, #"agents-user \#(kind) ["copy"] \#(beta9)"#,
      ])
  }
  #expect(
    describeCopies(report, "core-simulator-health") == [
      #"claude-user current ["copy"] \#(beta11)"#, #"codex-user current ["copy"] \#(beta11)"#,
    ])
  let finding = try #require(inventoryFinding(report, "outdated", "apple-platform-engineer"))
  #expect(
    finding["installedFrom"] as? [String: String] == [
      "root": SkillInventory.realPath(bundle(old))!, "version": "2.0.0-beta.9",
    ])
  #expect(
    inventoryFinding(report, "retired", "native-app-lead")?["replacedBy"] as? String
      == "apple-platform-engineer")
  // Nothing tells the person to rename or remove their own installation; the next step is the
  // approval-gated update.
  #expect(inventoryFindings(report, "foreignSameName").isEmpty)
  let steps = try #require(report["nextSteps"] as? [String: String])
  #expect(steps["foreignSameName"] == nil)
  #expect(steps["outdated"]?.hasPrefix("apple-platform-setup update, after approval") == true)
}

@Test func aLookAlikeOrAnotherSourcesCopyIsNeverTheCollections() throws {
  // A skills folder whose agent-harness has neither the lifecycle file nor the contracts; a copy
  // with the contracts whose lifecycle file names another repository, and one whose lifecycle
  // file cannot be read; and an older copy of the harness inside a scanned root, where another
  // owner's same-name skill sits beside it.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try fixture.skill("bundles/lookalike/skills/agent-harness", "Not this collection's harness.")
  try fixture.write("bundles/lookalike/VERSION", "2.0.0-beta.9\n")
  try fixture.skill("bundles/lookalike/skills/git-workflow", "Someone's git workflow.")
  for (fork, lifecycle) in [
    ("fork", #"{"source": "someone/other-skills"}"#), ("broken-fork", #"{"source": "#),
  ] {
    try fixture.write("bundles/\(fork)/VERSION", "1.0.0\n")
    try fixture.write("bundles/\(fork)/skills/agent-harness/contracts/capabilities.json", "{}")
    try fixture.write(
      "bundles/\(fork)/skills/agent-harness/lifecycle/skill-lifecycle.json", lifecycle)
  }
  try fixture.skill("bundles/fork/skills/core-simulator-health", "A fork's copy.")
  try fixture.skill("bundles/broken-fork/skills/sketch-design-from-codebase", "A fork's copy.")
  let target = { (path: String) in fixture.base.appendingPathComponent("bundles/\(path)").path }
  try fixture.link(
    "other-home/.claude/skills/git-workflow", to: target("lookalike/skills/git-workflow"))
  try fixture.link(
    "other-home/.agents/skills/core-simulator-health",
    to: target("fork/skills/core-simulator-health"))
  try fixture.link(
    "other-home/.agents/skills/sketch-design-from-codebase",
    to: target("broken-fork/skills/sketch-design-from-codebase"))
  try fixture.write("other-home/.codex/skills/agent-harness/contracts/capabilities.json", "{}")
  try fixture.skill("other-home/.codex/skills/agent-harness", "An older harness copy.")
  try fixture.skill("other-home/.codex/skills/xcodebuild", "Someone's xcodebuild.")
  let report = try fixture.report(
    SkillInventory.Locations(home: fixture.base.appendingPathComponent("other-home")))
  #expect(describeCopies(report, "git-workflow") == ["claude-user foreignSameName [] -"])
  #expect(describeCopies(report, "core-simulator-health") == ["agents-user foreignSameName [] -"])
  #expect(
    describeCopies(report, "sketch-design-from-codebase") == ["agents-user foreignSameName [] -"])
  #expect(describeCopies(report, "xcodebuild") == ["codex-user foreignSameName [] -"])
}

@Test func aFolderWhoseHarnessMarkerIsALinkIsNotACopy() throws {
  // Folders of the person's own skills outside the scanned roots (a link farm, a dotfiles
  // folder) whose agent-harness, its lifecycle folder or file, its contracts folder or its
  // capabilities file is a link to a real one, the checkout's included. None of them is a copy
  // of the collection, so the same-name skill beside each is another owner's, never outdated
  // with copy evidence. The same layout with real folders is a copy.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let harness = fixture.skills.appendingPathComponent("agent-harness").path
  try fixture.write("real-contracts/capabilities.json", "{}")
  let contracts = fixture.base.appendingPathComponent("real-contracts").path
  let farms = [
    ("harness", "apple-platform-engineer", "agent-harness", harness),
    ("lifecycle", "git-workflow", "agent-harness/lifecycle", "\(harness)/lifecycle"),
    (
      "lifecycle-file", "xcodebuild", "agent-harness/lifecycle/skill-lifecycle.json",
      "\(harness)/lifecycle/skill-lifecycle.json"
    ),
    ("contracts", "sketch-design-from-codebase", "agent-harness/contracts", contracts),
    (
      "capabilities", "core-simulator-health", "agent-harness/contracts/capabilities.json",
      "\(contracts)/capabilities.json"
    ),
  ]
  for (farm, name, marker, target) in farms {
    try fixture.write("farms/\(farm)/VERSION", "2.0.0-beta.9\n")
    try fixture.link("farms/\(farm)/skills/\(marker)", to: target)
    try fixture.skill("farms/\(farm)/skills/\(name)", "The person's own \(name).")
    try fixture.link(
      "farm-home/.claude/skills/\(name)",
      to: fixture.base.appendingPathComponent("farms/\(farm)/skills/\(name)").path)
  }
  try fixture.write(
    "farms/real/skills/agent-harness/lifecycle/skill-lifecycle.json",
    #"{"source": "ShawnBaek/ai-workflow-apple-platform-engineer"}"#)
  try fixture.skill("farms/real/skills/xcode-project-workflow", "An older workflow.")
  try fixture.link(
    "farm-home/.claude/skills/xcode-project-workflow",
    to: fixture.base.appendingPathComponent("farms/real/skills/xcode-project-workflow").path)
  let report = try fixture.report(
    SkillInventory.Locations(home: fixture.base.appendingPathComponent("farm-home")))
  for (_, name, _, _) in farms {
    #expect(describeCopies(report, name) == ["claude-user foreignSameName [] -"])
  }
  let real = SkillInventory.realPath(fixture.base.appendingPathComponent("farms/real").path)!
  #expect(
    describeCopies(report, "xcode-project-workflow") == [
      #"claude-user outdated ["copy"] \#(real)@-"#
    ])
  #expect(
    inventoryFindings(report, "outdated").map { $0["name"] as! String } == [
      "xcode-project-workflow"
    ])
}

@Test func anUnreadableLockLeavesWhatOnlyItCouldProveUnverified() throws {
  // With the global lock unreadable, nothing proves or disproves the entries only it attributed:
  // the retired lead's link, the differing Codex copy and Xcode's link to it, and a same-name
  // folder the lock never named. Entries with other evidence keep it, and a root the global lock
  // does not cover keeps its own lock's answer.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let lockPath = fixture.home.appendingPathComponent(".agents/.skill-lock.json")
  let valid = try Data(contentsOf: lockPath)
  try Data(#"{"version": 3, "skills": {"#.utf8).write(to: lockPath)
  let unreadable = "the lock covering its root is unreadable"
  let linked = "resolves to the folder of an entry whose lock is unreadable"
  func check(_ report: [String: Any], reason: String?) throws {
    let lock = try #require(report["lock"] as? [String: Any])
    #expect(lock["status"] as? String == "unreadable")
    #expect(lock["reason"] is String)
    if let reason { #expect(lock["reason"] as? String == reason) }
    #expect(
      describeEntries(report, "native-app-lead") == [
        "claude-user unverified \(unreadable) unreadable"
      ])
    #expect(
      inventoryFinding(report, "unverified", "native-app-lead")?["replacedBy"] as? String
        == "apple-platform-engineer")
    #expect(
      describeEntries(report, "core-simulator-health") == [
        "claude-user current - -", "agents-user current - -",
        "codex-user unverified \(unreadable) unreadable", "xcode-codex unverified \(linked) -",
      ])
    #expect(
      describeEntries(report, "xcodebuild") == [
        "claude-user unverified \(unreadable) unreadable", "agents-user current - -",
      ])
    // The dangling link it attributed loses that evidence; the project roots keep their lock.
    #expect(
      inventoryEntries(report, "git-workflow").map { "\($0.0) \($0.1) \($0.2)" } == [
        "agents-user broken []", "agents-project:. foreignSameName []",
      ])
    #expect(
      inventoryFindings(report, "foreignSameName").map { $0["name"] as! String } == [
        "code-review", "git-workflow", "xcode-project-workflow:xcode-project-workflow",
      ])
    #expect(inventoryFindings(report, "staleLock").isEmpty)
  }
  try check(try fixture.report(), reason: nil)
  // A lock that is a link (a dotfiles checkout, say) is not opened either.
  let elsewhere = fixture.base.appendingPathComponent("dotfiles-lock.json")
  try valid.write(to: elsewhere)
  try FileManager.default.removeItem(at: lockPath)
  try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: elsewhere)
  try check(try fixture.report(), reason: "not a regular file")
}

@Test func aDanglingProjectLinkGetsNoEvidenceFromTheGlobalLock() throws {
  // The global lock gives core-simulator-health to a former name of this repository, but it
  // records only global installs: a dangling link in the project's .agents/skills, which only
  // the project's own lock covers, is left to its owner.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try fixture.link(
    "project/.agents/skills/core-simulator-health", to: "../../gone/core-simulator-health")
  let report = try fixture.report()
  #expect(
    inventoryEntries(report, "core-simulator-health").filter { $0.0 == "agents-project:." }.map {
      "\($0.1) \($0.2)"
    } == ["broken []"])
}

@Test func aRelativeDanglingLinkIntoTheCollectionHasPathEvidence() throws {
  // The Skills CLI links relatively. A dangling relative link resolves against the folder that
  // holds the link, which here names a folder directly inside the collection's skills/.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try fixture.link(
    "home/.claude/skills/relative-removed", to: "../../../collection/skills/relative-removed")
  let report = try fixture.report()
  #expect(
    inventoryEntries(report, "relative-removed").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-user broken ["path"]"#
    ])
}

@Test func onlyTheProjectDirectoryIsListedOutsideARepository() throws {
  // Inside a repository every directory from its root down to the project is listed; outside
  // one only the project directory is, never its parents (a parent's skills are not the
  // project's).
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let repository = try #require(SkillInventory.realPath(fixture.base.path))
  #expect(
    try SkillInventory.projectDirectories(fixture.project).map { "\($0.0) \($0.1)" } == [
      ". \(repository)/project", "app \(repository)/project/app",
    ])
  try fixture.skill("loose/.claude/skills/parent-skill", "A parent directory's skill.")
  let loose = fixture.base.appendingPathComponent("loose/app")
  try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
  try #require(
    try SkillInventory.projectDirectories(loose).map { "\($0.0) \($0.1)" } == [
      ". \(repository)/loose/app"
    ])
  let report = try fixture.report(SkillInventory.Locations(home: fixture.home, project: loose))
  #expect(inventoryEntries(report, "parent-skill").isEmpty)
  #expect(
    (report["roots"] as! [[String: Any]]).compactMap { $0["id"] as? String }.filter {
      $0.contains("-project:")
    } == ["claude-project:.", "agents-project:.", "codex-project:."])
}

@Test func theForeignLockDetailComesFromTheEntrysOwnLock() throws {
  // The project's lock gives code-review to another repository, which the report names; the
  // global lock gives xcode-project-workflow to another package, which says nothing about the
  // project's folder of that name or Xcode's imported plugin.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  try fixture.write(
    "project/skills-lock.json",
    #"{"version": 1, "skills": {"code-review": {"source": "someone/review-skills"}}}"#)
  try fixture.write(
    "home/.agents/.skill-lock.json",
    #"{"version": 3, "skills": {"xcode-project-workflow": {"source": "another/pack"}}}"#)
  try fixture.skill("project/.claude/skills/xcode-project-workflow", "The team's workflow.")
  let report = try fixture.report()
  #expect(describeEntries(report, "code-review") == ["agents-project:. foreignSameName - foreign"])
  #expect(
    describeEntries(report, "xcode-project-workflow") == [
      "claude-project:. foreignSameName - -"
    ])
  #expect(
    describeEntries(report, "xcode-project-workflow:xcode-project-workflow") == [
      "xcode-plugins foreignSameName - -"
    ])
}
