import Foundation
import Testing

@testable import AppleVerificationCore

private func entryPoint(_ name: String, _ frontmatterDescription: String) -> String {
  "---\nname: \(name)\ndescription: \(frontmatterDescription)\n---\n# \(name)\n"
}

@Test func shippedSkillDescriptionsFitTheListingBudget() throws {
  // Before the trim, apple-platform-ui alone had 971 characters and the 41 descriptions
  // totaled about 15,700, twice the 8,000-character listing fallback.
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  var texts = [String: String]()
  for folder in try FileManager.default.contentsOfDirectory(
    atPath: root.appendingPathComponent("skills").path)
  {
    let path = "skills/\(folder)/SKILL.md"
    if let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) {
      texts[path] = text
    }
  }
  #expect(!texts.isEmpty)
  // Every shipped frontmatter form is read, so none escapes the budget unmeasured.
  #expect(SkillDescriptionBudget.descriptions(in: texts).count == texts.count)
  #expect(SkillDescriptionBudget.validate(texts: texts) == [])
}

@Test func repositoryRejectsAFoldedDescriptionOverTheSkillLimit() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? manager.removeItem(at: root) }
  try manager.createDirectory(
    at: root.appendingPathComponent("skills/example"), withIntermediateDirectories: true)
  try manager.createDirectory(
    at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
  func write(_ path: String, _ value: String) throws {
    try value.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
  }
  try write("VERSION", "1.0.0\n")
  try write("README.md", "**Version:** 1.0.0\n")
  try write("docs/skills.md", "[Example](../skills/example/SKILL.md)\n")
  let line = String(repeating: "a", count: 150)

  // The indicator line `>-` is two characters; the folded text it introduces is what counts.
  try write("skills/example/SKILL.md", entryPoint("example", ">-\n  \(line)\n  \(line)"))
  let over = try RepositoryValidation.validate(root: root, includeContracts: false)
  #expect(over.status == "failed")
  #expect(
    over.errors == [
      "Skill description has 301 characters, over 300; keep what it does, one 'Use when' "
        + "clause and any 'Not for' route: skills/example/SKILL.md"
    ])

  try write(
    "skills/example/SKILL.md", entryPoint("example", ">-\n  \(line)\n  \(line.dropFirst())"))
  #expect(try RepositoryValidation.validate(root: root, includeContracts: false).errors == [])

  try write("skills/example/SKILL.md", entryPoint("example", String(repeating: "a", count: 1025)))
  #expect(
    try RepositoryValidation.validate(root: root, includeContracts: false).errors == [
      "Skill description has 1025 characters, over the Agent Skills limit of 1024: "
        + "skills/example/SKILL.md"
    ])
}

@Test func totalBudgetFailsEvenWhenEverySkillIsWithinItsLimit() {
  var texts = [String: String]()
  for index in 0..<30 {
    texts["skills/s\(index)/SKILL.md"] = entryPoint("s\(index)", String(repeating: "a", count: 300))
  }
  #expect(SkillDescriptionBudget.validate(texts: texts) == [])

  texts["skills/extra/SKILL.md"] = entryPoint("extra", "An.")
  #expect(
    SkillDescriptionBudget.validate(texts: texts) == [
      "Skill descriptions total 9003 characters, over the 9000-character listing budget"
    ])
}
