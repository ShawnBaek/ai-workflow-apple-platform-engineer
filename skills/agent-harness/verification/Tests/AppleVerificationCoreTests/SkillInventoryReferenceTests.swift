import Foundation
import Testing

@testable import AppleVerificationCore

private final class BundleMarker {}

/// The product beside this test bundle, never an arbitrary older build.
private var executable: String {
  Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("apple-verify").resolvingSymlinksInPath().path
}

private let collectionSource = "ShawnBaek/ai-workflow-apple-platform-engineer"

/// A global Skills CLI install for both clients in `<fixture>/installed-home`, as the CLI lays it
/// out: real folders in `~/.agents/skills`, Claude Code links to them, and a lock entry with a
/// ref and the Git tree of each folder as installed. The verifier is the fixture's current
/// `agent-harness`; `xcodebuild` is an older copy that a later update left behind.
private func installWithStaleSibling(_ fixture: SkillInventoryFixture) throws -> URL {
  let home = fixture.base.appendingPathComponent("installed-home")
  let agents = home.appendingPathComponent(".agents/skills")
  try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
  try FileManager.default.copyItem(
    at: fixture.skills.appendingPathComponent("agent-harness"),
    to: agents.appendingPathComponent("agent-harness"))
  try fixture.skill("installed-home/.agents/skills/xcodebuild", "An older xcodebuild.")
  var entries = [String]()
  for name in ["agent-harness", "xcodebuild"] {
    try fixture.link("installed-home/.claude/skills/\(name)", to: "../../.agents/skills/\(name)")
    let tree = try #require(SkillInventory.gitTreeID(agents.appendingPathComponent(name).path))
    entries.append(
      #""\#(name)": {"source": "\#(collectionSource)", "sourceType": "github", "#
        + #""ref": "v0.9.0", "skillFolderHash": "\#(tree)"}"#)
  }
  try fixture.write(
    "installed-home/.agents/.skill-lock.json",
    #"{"version": 3, "skills": {\#(entries.joined(separator: ", "))}}"#)
  return home
}

/// Runs the built command with `--repository-root <root>` and only `HOME` in its environment.
private func runInventory(home: URL, repositoryRoot: URL) throws -> (Int32, [String: Any]) {
  let result = try HarnessRuntime.run(
    executable: executable,
    arguments: ["--repository-root", repositoryRoot.path, "skill-inventory"],
    environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], timeout: 60,
    maxOutputBytes: 8 * 1_024 * 1_024)
  #expect(result.stderr == "")
  let report = try #require(
    try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
  return (result.exitCode, report)
}

/// Each entry of `name` as "root class lockHash".
private func lockHashes(_ report: [String: Any], _ name: String) -> [String] {
  (report["roots"] as? [[String: Any]] ?? []).flatMap { root in
    (root["entries"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == name }.map {
      "\(root["id"]!) \($0["class"]!) \($0["lockHash"] ?? "-")"
    }
  }
}

@Test func aStaleSiblingOfAnInstalledVerifierIsNeverCurrent() throws {
  // The verifier runs from ~/.agents/skills/agent-harness, a scanned root: its reference copy of
  // xcodebuild is the stale folder itself. Before the fix that self-comparison read `current`
  // and the report came out clean.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let home = try installWithStaleSibling(fixture)
  let (code, report) = try runInventory(
    home: home, repositoryRoot: home.appendingPathComponent(".agents"))
  #expect(code == 1)
  #expect(report["status"] as? String == "attention")
  let itself = noIndependentReference("agents-user", itself: true)
  #expect(
    describeEntries(report, "xcodebuild") == [
      "claude-user unverified \(itself) -", "agents-user unverified \(itself) -",
    ])
  #expect((report["summary"] as? [String: Any])?["current"] == nil)
  // All the lock can say: the folder still has the tree it recorded.
  #expect(
    lockHashes(report, "xcodebuild") == [
      "claude-user unverified matches", "agents-user unverified matches",
    ])
  #expect(inventoryFindings(report, "staleLock").isEmpty)
  let steps = try #require(report["nextSteps"] as? [String: String])
  #expect(steps["unverified"]?.contains("--repository-root <reviewed checkout>") == true)
}

@Test func aStaleSiblingIsOutdatedAgainstTheReviewedRepositoryRoot() throws {
  // The same installation, checked by the verifier with `--repository-root` at the reviewed
  // checkout, which lies outside every scanned root.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let home = try installWithStaleSibling(fixture)
  let (code, report) = try runInventory(home: home, repositoryRoot: fixture.collection)
  #expect(code == 1)
  #expect(
    (report["collection"] as? [String: Any])?["reference"] as? String == "verifier skills folder")
  #expect(
    inventoryEntries(report, "xcodebuild").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-user outdated ["lock"]"#, #"agents-user outdated ["lock"]"#,
    ])
  #expect(
    inventoryEntries(report, "agent-harness").map { "\($0.0) \($0.1) \($0.2)" } == [
      #"claude-user current ["lock"]"#, #"agents-user current ["lock"]"#,
    ])
  #expect(
    ((report["lock"] as? [String: Any])?["refs"] as? [String: [String]]) == [
      "v0.9.0": ["agent-harness", "xcodebuild"]
    ])
}

@Test func aFolderReplacedOutsideTheSkillsCLIIsLockDrift() throws {
  // Four global installs, each now holding the reviewed content. The lock was written for older
  // folders of xcodebuild (pinned to v0.9.0) and core-simulator-health (no ref), as a reinstall
  // from a local checkout leaves it. git-workflow was reinstalled pinned to the reviewed commit,
  // so its tree matches. apple-platform-engineer carries the CLI's own SHA-256, which the
  // inventory cannot reproduce, so it proves nothing either way.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let home = fixture.base.appendingPathComponent("drift-home")
  let agents = home.appendingPathComponent(".agents/skills")
  try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
  let names = ["apple-platform-engineer", "core-simulator-health", "git-workflow", "xcodebuild"]
  for name in names {
    try FileManager.default.copyItem(
      at: fixture.skills.appendingPathComponent(name), to: agents.appendingPathComponent(name))
  }
  try fixture.skill("older/xcodebuild", "An older xcodebuild.")
  try fixture.skill("older/core-simulator-health", "An older core-simulator-health.")
  func tree(_ path: String) throws -> String {
    try #require(SkillInventory.gitTreeID(fixture.base.appendingPathComponent(path).path))
  }
  let reviewedCommit = "0123456789abcdef0123456789abcdef01234567"
  let records = [
    ("xcodebuild", #""ref": "v0.9.0", "skillFolderHash": "\#(try tree("older/xcodebuild"))""#),
    (
      "core-simulator-health",
      #""skillFolderHash": "\#(try tree("older/core-simulator-health"))""#
    ),
    (
      "git-workflow",
      #""ref": "\#(reviewedCommit)", "#
        + #""skillFolderHash": "\#(try tree("drift-home/.agents/skills/git-workflow"))""#
    ),
    ("apple-platform-engineer", #""skillFolderHash": "\#(String(repeating: "ab", count: 32))""#),
  ]
  let entries = records.map {
    #""\#($0.0)": {"source": "\#(collectionSource)", "sourceType": "github", \#($0.1)}"#
  }
  try fixture.write(
    "drift-home/.agents/.skill-lock.json",
    #"{"version": 3, "skills": {\#(entries.joined(separator: ", "))}}"#)
  let report = try SkillInventory.inventory(
    locations: SkillInventory.Locations(home: home), collectionSkills: fixture.skills,
    lifecycle: SkillInventoryFixture.lifecycle)
  // The content is the reviewed revision's, so each entry is current; the lock is what drifted.
  #expect(
    names.flatMap { lockHashes(report, $0) } == [
      "agents-user current -", "agents-user current differs", "agents-user current matches",
      "agents-user current differs",
    ])
  #expect(
    inventoryFindings(report, "staleLock").map {
      "\($0["name"]!) \($0["lock"]!) \($0["reason"]!) \($0["ref"] ?? "-") \($0["roots"]!)"
    } == [
      #"core-simulator-health global drift - ["agents-user"]"#,
      #"xcodebuild global drift v0.9.0 ["agents-user"]"#,
    ])
  #expect(report["status"] as? String == "attention")
  #expect(
    ((report["lock"] as? [String: Any])?["refs"] as? [String: [String]]) == [
      "v0.9.0": ["xcodebuild"], reviewedCommit: ["git-workflow"],
    ])
  let steps = try #require(report["nextSteps"] as? [String: String])
  #expect(steps["staleLock"]?.contains("<collection source>#<reviewed tag>") == true)
}

@Test func aGitTreeIDMatchesGitForAnInstalledFolder() throws {
  // The expected ID is `git write-tree` for these six files, one of them executable; the names
  // `a`, `a-b` and `a.md` check Git's order, which sorts a folder as if its name ended in `/`.
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  let folder = fixture.base.appendingPathComponent("tree/f")
  for (path, text) in [
    ("SKILL.md", "---\nname: f\ndescription: Fixture.\n---\nBody.\n"),
    ("references/notes.md", "notes"), ("scripts/run.sh", "#!/bin/sh\necho hi\n"),
    ("a/x.md", "x"), ("a-b", "dash"), ("a.md", "dot"),
  ] {
    try fixture.write("tree/f/\(path)", text)
  }
  let script = folder.appendingPathComponent("scripts/run.sh").path
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
  let expected = "4bc9f0b7c046b3e70eab4e066a97525f5997bfbf"
  #expect(SkillInventory.gitTreeID(folder.path) == expected)
  // What the repository never tracks, and a folder with no file, which Git does not record.
  for path in [
    "verification/.build/debug/apple-verify", ".DS_Store", "__pycache__/m.cpython-313.pyc",
    "scripts/c.pyc", ".git/HEAD",
  ] {
    try fixture.write("tree/f/\(path)", "untracked")
  }
  try FileManager.default.createDirectory(
    at: folder.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
  #expect(SkillInventory.gitTreeID(folder.path) == expected)
  // The execute bit is part of the tree; a link is never in an installed copy.
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script)
  #expect(SkillInventory.gitTreeID(folder.path).map { $0 != expected } == true)
  try fixture.link("tree/f/references/link.md", to: "notes.md")
  #expect(SkillInventory.gitTreeID(folder.path) == nil)
}

@Test func anAppleExportPointsToItsRetirementAndAPlugInToXcode() throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  // A Claude Code link into an export no record lists.
  try fixture.skill("old-export/device-interaction", "An exported Apple skill.")
  try fixture.link(
    "home/.claude/skills/device-interaction",
    to: fixture.base.appendingPathComponent("old-export/device-interaction").path)
  let report = try fixture.report()
  let reserved = (report["roots"] as? [[String: Any]] ?? []).flatMap { root in
    (root["entries"] as? [[String: Any]] ?? []).filter { $0["class"] as? String == "reserved" }
      .map { "\(root["id"]!) \($0["name"]!) \($0["appleExposure"] ?? "-")" }
  }
  #expect(
    reserved == [
      "claude-user device-interaction export", "agents-user swiftui-specialist export",
      "codex-user device-interaction export", "codex-user skill-installer -",
      "xcode-plugins swiftui-specialist:swiftui-specialist plugin",
    ])
  let step = try #require((report["nextSteps"] as? [String: String])?["reserved"])
  for phrase in [
    "apple-skill-exposure.md#retire-an-old-export", "only on your answer for that entry",
    "Xcode Settings > Intelligence > Plug-ins", "Xcode's own copies are never touched",
  ] {
    #expect(step.contains(phrase), "\(phrase)")
  }
}

@Test func theReferenceCheckoutsHeadCommitIsReported() throws {
  let fixture = try SkillInventoryFixture.make()
  defer { fixture.remove() }
  func headCommit() throws -> String? {
    (try fixture.report()["collection"] as? [String: Any])?["headCommit"] as? String
  }
  #expect(try headCommit() == nil)
  let packed = "1111111111111111111111111111111111111111"
  let loose = "2222222222222222222222222222222222222222"
  let worktree = "3333333333333333333333333333333333333333"
  try fixture.write("collection/.git/HEAD", "ref: refs/heads/main\n")
  try fixture.write(
    "collection/.git/packed-refs",
    "# pack-refs with: peeled fully-peeled sorted\n\(packed) refs/heads/main\n")
  #expect(try headCommit() == packed)
  try fixture.write("collection/.git/refs/heads/main", "\(loose)\n")
  #expect(try headCommit() == loose)
  // A detached HEAD holds the commit itself.
  let detached = "4444444444444444444444444444444444444444"
  try fixture.write("collection/.git/HEAD", "\(detached)\n")
  #expect(try headCommit() == detached)
  // A linked worktree: `.git` is a file naming its folder, whose `commondir` holds the refs.
  try FileManager.default.removeItem(at: fixture.collection.appendingPathComponent(".git"))
  try fixture.write("main/.git/worktrees/review/HEAD", "ref: refs/heads/review\n")
  try fixture.write("main/.git/worktrees/review/commondir", "../..\n")
  try fixture.write("main/.git/refs/heads/review", "\(worktree)\n")
  try fixture.write(
    "collection/.git",
    "gitdir: \(fixture.base.appendingPathComponent("main/.git/worktrees/review").path)\n")
  #expect(try headCommit() == worktree)
}
