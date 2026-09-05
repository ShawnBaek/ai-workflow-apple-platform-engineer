import Foundation
import Testing

@testable import AppleVerificationCore

@Test func repositoryRejectsBrokenInputsAndAcceptsCompactReadme() throws {
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
  try write("README.md", "# Example\n\n**Version:** 1.0.0\n")
  try write("docs/skills.md", "[Example](../skills/example/SKILL.md)\n")
  try write(
    "skills/example/SKILL.md", "---\nname: example\ndescription: An example.\n---\n# Example\n")
  let valid = try RepositoryValidation.validate(root: root, includeContracts: false)
  #expect(valid.status == "passed")
  #expect(valid.skillNames == ["example"])
  try write(
    "skills/example/SKILL.md",
    "---\nname: example\ndescription: An example.\n---\n[Missing](missing.md)\n")
  try write("docs/invalid.json", "{invalid}")
  let broken = try RepositoryValidation.validate(root: root, includeContracts: false)
  #expect(broken.status == "failed")
  #expect(broken.errors.contains(where: { $0.contains("Missing local link") }))
  #expect(broken.errors.contains(where: { $0.contains("Invalid JSON") }))
  #expect(broken.validatedDocumentDigest != valid.validatedDocumentDigest)
}

@Test func repositoryRejectsEscapingLinksAndMismatchedSkillNames() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? manager.removeItem(at: root) }
  try manager.createDirectory(
    at: root.appendingPathComponent("skills/example"), withIntermediateDirectories: true)
  try manager.createDirectory(
    at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
  for (path, content) in [
    "VERSION": "1.0.0", "README.md": "**Version:** 1.0.0",
    "docs/skills.md": "[Example](../skills/example/SKILL.md)",
    "skills/example/SKILL.md":
      "---\nname: wrong\ndescription: Example.\n---\n[Escape](../../../outside.md)\n",
  ] { try content.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
  let report = try RepositoryValidation.validate(root: root, includeContracts: false)
  #expect(report.errors.contains(where: { $0.contains("escapes repository") }))
  #expect(report.errors.contains(where: { $0.contains("Invalid skill name/folder") }))
}
