import Foundation
import Testing

@testable import AppleVerificationCore

private func fixture(_ body: String) -> [String: String] {
  [SkillRoutingValidation.fixturePath: body]
}

@Test func routingFixtureIsOptionalAndRejectsUnparseableContent() {
  #expect(SkillRoutingValidation.validate(texts: [:]).isEmpty)
  let broken = SkillRoutingValidation.validate(texts: fixture("{not json"))
  #expect(broken.count == 1)
  #expect(broken[0].contains("Invalid routing fixture"))
}

@Test func routingRequiresEveryStartingSkillToNameTheOwner() {
  var texts = fixture(
    """
    {"capabilityRouting": [
      {"id": "parity", "owner": "golden-testing", "referencedFrom": ["bridge", "generic-testing"]}
    ]}
    """)
  texts["skills/golden-testing/SKILL.md"] = "# Golden testing"
  texts["skills/bridge/SKILL.md"] = "Route parity work to golden-testing."
  texts["skills/generic-testing/SKILL.md"] = "Plan and run tests."

  let errors = SkillRoutingValidation.validate(texts: texts)
  #expect(errors.count == 1)
  #expect(errors[0].contains("generic-testing no longer routes to golden-testing"))

  // A reference in any document of the skill, not only its entry point, counts.
  texts["skills/generic-testing/references/evidence.md"] =
    "For Figma-contract parity use golden-testing."
  #expect(SkillRoutingValidation.validate(texts: texts).isEmpty)
}

@Test func routingReportsSkillsThatDoNotExist() {
  var texts = fixture(
    """
    {"capabilityRouting": [
      {"id": "parity", "owner": "absent-owner", "referencedFrom": ["absent-source"]}
    ]}
    """)
  texts["skills/other/SKILL.md"] = "# Other"
  let errors = SkillRoutingValidation.validate(texts: texts).sorted()
  #expect(errors.count == 2)
  #expect(errors.contains(where: { $0.contains("owner skill not found: absent-owner") }))
  #expect(errors.contains(where: { $0.contains("referencing skill not found: absent-source") }))
}

@Test func ruleConsistencyRequiresTheCarveOutWhereverTheRuleIsStated() {
  var texts = fixture(
    """
    {"ruleConsistency": [
      {"id": "color", "statesRule": "semantic colors?",
       "requiresQualifier": "design leaves the color open",
       "appliesTo": ["bridge", "ui"]}
    ]}
    """)
  texts["skills/bridge/SKILL.md"] = "Prefer semantic color where the design leaves the color open."
  texts["skills/ui/SKILL.md"] = "Always prefer a semantic color."

  let errors = SkillRoutingValidation.validate(texts: texts)
  #expect(errors.count == 1)
  #expect(errors[0].contains("skills/ui/SKILL.md states the rule without its exception"))

  // A document that never states the rule is not required to carry the carve-out.
  texts["skills/ui/SKILL.md"] = "Use the asset catalog."
  #expect(SkillRoutingValidation.validate(texts: texts).isEmpty)
}

@Test func ruleConsistencyReportsMalformedCasesInsteadOfPassingSilently() {
  let missingFields = SkillRoutingValidation.validate(
    texts: fixture(#"{"ruleConsistency": [{"id": "x", "statesRule": "a"}]}"#))
  #expect(missingFields.count == 1)
  #expect(missingFields[0].contains("Invalid rule case"))

  var texts = fixture(
    """
    {"ruleConsistency": [
      {"id": "x", "statesRule": "([", "requiresQualifier": "b", "appliesTo": ["s"]}
    ]}
    """)
  texts["skills/s/SKILL.md"] = "text"
  let badRegex = SkillRoutingValidation.validate(texts: texts)
  #expect(badRegex.count == 1)
  #expect(badRegex[0].contains("invalid regular expression"))
}
