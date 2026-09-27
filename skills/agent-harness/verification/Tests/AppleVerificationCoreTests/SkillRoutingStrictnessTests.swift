import Foundation
import Testing

@testable import AppleVerificationCore

private let repositoryRoot: URL = {
  var root = URL(fileURLWithPath: #filePath)
  for _ in 0..<6 { root.deleteLastPathComponent() }
  return root.standardizedFileURL
}()

private func routingErrors(_ fixture: String, _ documents: [String: String]) -> [String] {
  var texts = documents
  texts[SkillRoutingValidation.fixturePath] = fixture
  return SkillRoutingValidation.validate(texts: texts)
}

/// Every Markdown document of the named shipped skills, keyed as the repository validator keys it.
private func shippedDocuments(_ skills: [String]) throws -> [String: String] {
  var texts = [String: String]()
  for skill in skills {
    let folder = repositoryRoot.appendingPathComponent("skills/\(skill)")
    let files = try #require(FileManager.default.enumerator(atPath: folder.path))
    for case let file as String in files where file.hasSuffix(".md") {
      texts["skills/\(skill)/\(file)"] = try String(
        contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
    }
  }
  return texts
}

@Test func routingFixtureSectionsThatCannotBeCheckedFailInsteadOfPassing() {
  let route = #"{"id": "r", "owner": "o", "referencedFrom": ["s"]}"#
  let rule = #"{"id": "q", "statesRule": "a", "requiresQualifier": "b", "appliesTo": ["s"]}"#
  func fixture(routes: String? = nil, rules: String? = nil) -> String {
    let routes = routes ?? "[\(route)]"
    return #"{"capabilityRouting": \#(routes), "ruleConsistency": \#(rules ?? "[\(rule)]")}"#
  }
  let documents = ["skills/o/SKILL.md": "# Owner", "skills/s/SKILL.md": "Use `o`. a b"]
  #expect(routingErrors(fixture(), documents).isEmpty)

  let unreadable = [
    // A renamed or missing section.
    fixture().replacingOccurrences(of: "capabilityRouting", with: "capabilityRoutes"),
    #"{"capabilityRouting": [\#(route)]}"#,
    // A section that is not an array of cases.
    fixture(routes: route), fixture(rules: "null"),
    // One entry that is not a case object.
    fixture(routes: #"[\#(route), "r2"]"#), fixture(rules: "[\(rule), 7]"),
    // A case whose list is empty checks nothing.
    fixture(routes: #"[{"id": "r", "owner": "o", "referencedFrom": []}]"#),
    fixture(rules: #"[{"id": "q", "statesRule": "a", "requiresQualifier": "b", "appliesTo": []}]"#),
  ]
  for body in unreadable {
    let errors = routingErrors(body, documents)
    #expect(errors.count == 1, "\(body): \(errors)")
    #expect(errors.allSatisfy { $0.hasPrefix("Invalid") }, "\(body): \(errors)")
  }
}

@Test func ownerNamedOnlyInProseOrInsideALongerSkillNameIsNotARoute() {
  let fixture = #"""
    {"capabilityRouting": [{"id": "capture", "owner": "screenshot", "referencedFrom": ["testing"]}],
     "ruleConsistency": []}
    """#
  var documents = [
    "skills/screenshot/SKILL.md": "# Screenshot",
    "skills/testing/SKILL.md": """
    A screenshot alone is not an assertion; keep screenshots/videos as supporting evidence.
    Listing media belongs to `app-store-screenshots`, see ../app-store-screenshots/SKILL.md.
    """,
  ]
  let unrouted = routingErrors(fixture, documents)
  #expect(unrouted.count == 1)
  #expect(unrouted.first?.contains("testing no longer routes to screenshot") == true)

  // An explicit reference in any document of the starting skill is a route.
  for reference in [
    "Route capture to `screenshot`.", "Invoke `$screenshot`.",
    "See [capture](../../screenshot/SKILL.md).",
  ] {
    documents["skills/testing/references/evidence.md"] = reference
    #expect(routingErrors(fixture, documents).isEmpty, "\(reference)")
  }
}

@Test func shippedScreenshotCaseFailsWhenTheTestingSkillDropsItsRoute() throws {
  let source = try String(
    contentsOf: repositoryRoot.appendingPathComponent(SkillRoutingValidation.fixturePath),
    encoding: .utf8)
  let shipped = try #require(
    try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
  let cases = try #require(shipped["capabilityRouting"] as? [[String: Any]]).filter {
    $0["id"] as? String == "qa-screenshot-capture"
  }
  #expect(cases.count == 1)
  let fixture = String(
    decoding: try JSONSerialization.data(
      withJSONObject: ["capabilityRouting": cases, "ruleConsistency": []]), as: UTF8.self)
  var documents = try shippedDocuments(["apple-platform-testing", "screenshot"])
  #expect(routingErrors(fixture, documents).isEmpty)

  // Remove the one routing sentence; the skill still uses the word throughout its prose.
  let entry = "skills/apple-platform-testing/SKILL.md"
  let text = try #require(documents[entry])
  #expect(text.contains("to `screenshot`."))
  documents[entry] = text.replacingOccurrences(of: "to `screenshot`.", with: "elsewhere.")
  #expect(
    documents.contains {
      $0.key.hasPrefix("skills/apple-platform-testing/") && $0.value.contains("screenshot")
    })
  let errors = routingErrors(fixture, documents)
  #expect(errors.count == 1)
  #expect(
    errors.first?.contains(
      "Routing case qa-screenshot-capture: apple-platform-testing no longer routes to screenshot")
      == true)
}
