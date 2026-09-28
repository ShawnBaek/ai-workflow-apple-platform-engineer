import Foundation
import Testing

@testable import AppleVerificationCore

private var checkoutRoot: URL { GateRunSupport.repositoryRoot }
private let schemaPath = "skills/agent-harness/lifecycle/skill-lifecycle.schema.json"

private func shippedLifecycle() throws -> [String: Any] {
  try HarnessRuntime.object(checkoutRoot.appendingPathComponent(SkillLifecycleValidation.path))
}

private func shippedFolders() throws -> [String] {
  let skills = checkoutRoot.appendingPathComponent("skills")
  return try FileManager.default.contentsOfDirectory(
    at: skills, includingPropertiesForKeys: [.isDirectoryKey]
  ).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    .map(\.lastPathComponent).sorted()
}

private func shippedVersion() throws -> String {
  try String(contentsOf: checkoutRoot.appendingPathComponent("VERSION"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Validates the shipped lifecycle after `change` edits it, against `folders` (the shipped skill
/// folders by default).
private func errors(
  folders: [String]? = nil, version: String? = nil,
  _ change: (inout [String: Any]) -> Void = { _ in }
) throws -> [String] {
  var lifecycle = try shippedLifecycle()
  change(&lifecycle)
  return SkillLifecycleValidation.validate(
    lifecycle, skillFolders: try folders ?? shippedFolders(),
    version: try version ?? shippedVersion())
}

private func reserved(_ lifecycle: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
  var names = lifecycle["reservedNames"] as! [String: Any]
  edit(&names)
  lifecycle["reservedNames"] = names
}

@Test func shippedSkillLifecycleMatchesTheCheckout() throws {
  #expect(try errors() == [])
  #expect(
    ContractValidation.validatePair(
      root: checkoutRoot, instancePath: SkillLifecycleValidation.path, schemaPath: schemaPath)
      == [])
  let lifecycle = try shippedLifecycle()
  #expect((lifecycle["current"] as? [String])?.count == (try shippedFolders()).count)
  let retired = lifecycle["retired"] as? [[String: Any]] ?? []
  #expect(
    retired.contains {
      $0["id"] as? String == "native-app-lead"
        && $0["replacedBy"] as? String == "apple-platform-engineer"
    })
}

@Test func aRetiredSkillIDCannotReturnToCurrent() throws {
  let found = try errors(folders: shippedFolders() + ["native-app-lead"]) {
    $0["current"] = ($0["current"] as! [String]) + ["native-app-lead"]
  }
  #expect(
    found == ["retired skill ID native-app-lead is in current again; never repurpose a retired ID"])
}

@Test func aRetiredSkillMustNameACurrentSuccessorOrNone() throws {
  #expect(
    try errors {
      $0["retired"] = [
        ["id": "native-app-lead", "replacedBy": "platform-lead", "since": "2.0.0-beta.10"]
      ]
    } == ["retired skill native-app-lead is replaced by platform-lead, which is not current"])
  #expect(
    try errors {
      $0["retired"] = [
        ["id": "native-app-lead", "replacedBy": NSNull(), "since": "2.0.0-beta.10"]
      ]
    } == [])
}

@Test func currentMustListExactlyTheSkillFolders() throws {
  // A new skill folder that the lifecycle file does not list.
  #expect(
    try errors(folders: shippedFolders() + ["new-skill"]) == [
      "skill folder skills/new-skill is missing from skill lifecycle current"
    ])
  // A deleted or renamed folder whose ID the file still lists as current.
  #expect(
    try errors(folders: shippedFolders().filter { $0 != "xcode-storage" }) == [
      "skill lifecycle current lists xcode-storage, which has no skills/xcode-storage folder"
    ])
  #expect(
    try errors { $0["current"] = ($0["current"] as! [String]) + ["xcodebuild"] } == [
      "skill lifecycle current lists xcodebuild more than once"
    ])
}

@Test func aRetiredOrExceptedIDIsRecordedOnce() throws {
  // The schema cannot refuse these repeats: entries that differ in replacedBy, since or reason
  // are distinct objects, so two contradictory records for one ID would pass it.
  #expect(
    try errors {
      $0["retired"] = [
        [
          "id": "native-app-lead", "replacedBy": "apple-platform-engineer",
          "since": "2.0.0-beta.10",
        ],
        ["id": "native-app-lead", "replacedBy": NSNull(), "since": "2.0.0-beta.11"],
      ]
    } == ["skill lifecycle retired lists native-app-lead more than once"])
  #expect(
    try errors {
      reserved(&$0) {
        $0["exceptions"] = [
          ["id": "code-review", "reason": "Recorded collision."],
          ["id": "code-review", "reason": "Another reason."],
        ]
      }
    } == ["skill lifecycle reservedNames.exceptions lists code-review more than once"])
}

@Test func aSkillCannotTakeAnAppleOrClientNameWithoutAReason() throws {
  for name in ["swiftui-specialist", "xcode-integration", "skill-installer"] {
    let found = try errors(folders: shippedFolders() + [name]) {
      $0["current"] = ($0["current"] as! [String]) + [name]
    }
    #expect(found.count == 1, "\(name)")
    #expect(found.first?.hasPrefix("skill \(name) takes a reserved name") == true, "\(name)")
  }
  let found = try errors { reserved(&$0) { $0["exceptions"] = [] as [Any] } }
  #expect(
    found == [
      "skill code-review takes a reserved name (reservedNames.clientBuiltins.claudeCode); "
        + "rename it or record the reason in reservedNames.exceptions"
    ])
}

@Test func aReservedNameExceptionNeedsAReasonAndACurrentCollision() throws {
  let blank = try errors {
    reserved(&$0) { $0["exceptions"] = [["id": "code-review", "reason": " \n"]] }
  }
  #expect(blank.contains("reserved-name exception for code-review needs a reason"))
  #expect(blank.contains { $0.hasPrefix("skill code-review takes a reserved name") })
  #expect(blank.count == 2)
  // The schema refuses a blank reason too, so the shipped file cannot carry one.
  var lifecycle = try shippedLifecycle()
  reserved(&lifecycle) { $0["exceptions"] = [["id": "code-review", "reason": " \n"]] }
  let schema = try HarnessRuntime.object(checkoutRoot.appendingPathComponent(schemaPath))
  #expect(!JSONSchemaValidator.errors(instance: lifecycle, schema: schema).isEmpty)
  let stale = try errors {
    reserved(&$0) {
      $0["exceptions"] = [
        ["id": "code-review", "reason": "Recorded collision."],
        ["id": "swiftui-specialist", "reason": "No skill takes this name."],
      ]
    }
  }
  #expect(
    stale == [
      "reserved-name exception for swiftui-specialist is stale: swiftui-specialist is not a "
        + "current skill that takes a reserved name"
    ])
}

@Test func theLifecycleVersionFollowsVERSION() throws {
  #expect(
    try errors(version: "9.9.9") == [
      "skill lifecycle version \(try shippedVersion()) must equal VERSION 9.9.9"
    ])
}

@Test func repositoryValidationRunsTheLifecycleCheckWithTheContracts() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? manager.removeItem(at: root) }
  func write(_ path: String, _ value: String) throws {
    let file = root.appendingPathComponent(path)
    try manager.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.write(to: file, atomically: true, encoding: .utf8)
  }
  try write("VERSION", "1.0.0\n")
  try write("README.md", "**Version:** 1.0.0\n")
  try write("docs/skills.md", "[Example](../skills/example/SKILL.md)\n")
  try write("skills/example/SKILL.md", "---\nname: example\ndescription: An example.\n---\n")
  try write(
    SkillLifecycleValidation.path,
    #"{"current": ["example"], "retired": [], "version": "0.9.0", "reservedNames": {"#
      + #""appleSkills": [], "appleNamespace": "xcode-integration", "clientBuiltins": {},"#
      + #""exceptions": []}}"#)
  let lifecycleErrors = [
    "skill folder skills/agent-harness is missing from skill lifecycle current",
    "skill lifecycle version 0.9.0 must equal VERSION 1.0.0",
  ]
  let full = try RepositoryValidation.validate(root: root)
  for error in lifecycleErrors { #expect(full.errors.contains(error), "\(error)") }
  let withoutContracts = try RepositoryValidation.validate(root: root, includeContracts: false)
  for error in lifecycleErrors { #expect(!withoutContracts.errors.contains(error), "\(error)") }
}

@Test func theLifecycleFolderIsCheckedLikeTheContracts() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? manager.removeItem(at: root) }
  for path in [SkillLifecycleValidation.path, schemaPath] {
    let file = root.appendingPathComponent(path)
    try manager.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.copyItem(at: checkoutRoot.appendingPathComponent(path), to: file)
  }
  #expect(
    ContractValidation.validateContractFiles(
      root: root, pairs: [(SkillLifecycleValidation.path, schemaPath)],
      schemasValidatedElsewhere: []) == [])
  // Without its schemaPairs entry, neither file ships unchecked.
  #expect(
    ContractValidation.validateContractFiles(
      root: root, pairs: [], schemasValidatedElsewhere: []) == [
        "contract instance is not validated against a schema: \(SkillLifecycleValidation.path)",
        "contract schema validates no shipped instance or fixture: \(schemaPath)",
      ])
}

@Test func aReleaseBumpLeavesTheRuntimeSourceBundleDigestUnchanged() throws {
  // Private harnesses bind the source-bundle digest of agent-harness/contracts and
  // verification/Sources. The lifecycle version changes at every release, so the file stays
  // outside both, and a release that changes only it does not make every harness rebind.
  let manager = FileManager.default
  let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .resolvingSymlinksInPath()
  defer { try? manager.removeItem(at: base) }
  let prefix = "skills/agent-harness/"
  #expect(SkillLifecycleValidation.path.hasPrefix(prefix))
  let installed = checkoutRoot.appendingPathComponent(prefix)
  let skill = base.appendingPathComponent("agent-harness")
  let lifecycle = skill.appendingPathComponent(
    String(SkillLifecycleValidation.path.dropFirst(prefix.count)))
  for folder in ["contracts", "verification/Sources"] {
    let copy = skill.appendingPathComponent(folder)
    try manager.createDirectory(
      at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.copyItem(at: installed.appendingPathComponent(folder), to: copy)
  }
  try manager.createDirectory(
    at: lifecycle.deletingLastPathComponent(), withIntermediateDirectories: true)
  try manager.copyItem(
    at: checkoutRoot.appendingPathComponent(SkillLifecycleValidation.path), to: lifecycle)
  func release(_ version: String, at file: URL) throws {
    var value = try HarnessRuntime.object(file)
    value["version"] = version
    try JSONSerialization.data(withJSONObject: value).write(to: file)
  }

  let before = try ResourceCoordinator.sourceBundleSHA256(skillRoot: skill)
  try release("99.0.0", at: lifecycle)
  #expect(try ResourceCoordinator.sourceBundleSHA256(skillRoot: skill) == before)
  // Control: under contracts/, the same bump changes the digest a harness binds.
  let underContracts = skill.appendingPathComponent("contracts/skill-lifecycle.json")
  try manager.copyItem(at: lifecycle, to: underContracts)
  let bound = try ResourceCoordinator.sourceBundleSHA256(skillRoot: skill)
  try release("99.0.1", at: underContracts)
  #expect(try ResourceCoordinator.sourceBundleSHA256(skillRoot: skill) != bound)
}
