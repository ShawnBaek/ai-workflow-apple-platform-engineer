import Foundation

/// Checks the two instruction properties that repository linting cannot see: that a
/// capability stays reachable from the skills a request plausibly starts in, and that
/// a rule carrying an exception states that exception everywhere it is stated.
///
/// Both are deterministic text contracts over the shipped instructions. Neither runs a
/// model, so neither proves that an agent routes correctly — they prove that the
/// cross-references and qualifiers a correct routing decision depends on still exist.
public enum SkillRoutingValidation {
  static let fixturePath = "tests/fixtures/skill-routing.json"

  /// Returns validation errors for the fixture, or an empty array when it is absent.
  public static func validate(texts: [String: String]) -> [String] {
    guard let source = texts[fixturePath] else { return [] }
    guard
      let parsed = try? JSONSerialization.jsonObject(with: Data(source.utf8)),
      let fixture = parsed as? [String: Any]
    else {
      return ["Invalid routing fixture: \(fixturePath)"]
    }
    var errors = [String]()
    errors += checkCapabilityRouting(fixture["capabilityRouting"], texts: texts)
    errors += checkRuleConsistency(fixture["ruleConsistency"], texts: texts)
    return errors
  }

  /// Documents belonging to one skill, so a reference may live in a sub-doc.
  private static func documents(of skill: String, in texts: [String: String]) -> [String: String] {
    texts.filter { $0.key.hasPrefix("skills/\(skill)/") }
  }

  private static func checkCapabilityRouting(_ raw: Any?, texts: [String: String]) -> [String] {
    guard let cases = raw as? [[String: Any]] else { return [] }
    var errors = [String]()
    for entry in cases {
      guard
        let id = entry["id"] as? String,
        let owner = entry["owner"] as? String,
        let sources = entry["referencedFrom"] as? [String]
      else {
        errors.append("Invalid routing case: missing id, owner or referencedFrom")
        continue
      }
      if documents(of: owner, in: texts).isEmpty {
        errors.append("Routing case \(id): owner skill not found: \(owner)")
      }
      for source in sources {
        let docs = documents(of: source, in: texts)
        if docs.isEmpty {
          errors.append("Routing case \(id): referencing skill not found: \(source)")
          continue
        }
        if !docs.values.contains(where: { $0.contains(owner) }) {
          errors.append(
            "Routing case \(id): \(source) no longer routes to \(owner); "
              + "a request starting there cannot reach the owning skill")
        }
      }
    }
    return errors
  }

  private static func checkRuleConsistency(_ raw: Any?, texts: [String: String]) -> [String] {
    guard let cases = raw as? [[String: Any]] else { return [] }
    var errors = [String]()
    for entry in cases {
      guard
        let id = entry["id"] as? String,
        let rulePattern = entry["statesRule"] as? String,
        let qualifierPattern = entry["requiresQualifier"] as? String,
        let skills = entry["appliesTo"] as? [String]
      else {
        errors.append("Invalid rule case: missing id, statesRule, requiresQualifier or appliesTo")
        continue
      }
      guard
        let rule = try? NSRegularExpression(pattern: rulePattern, options: [.caseInsensitive]),
        let qualifier = try? NSRegularExpression(
          pattern: qualifierPattern, options: [.caseInsensitive])
      else {
        errors.append("Rule case \(id): invalid regular expression")
        continue
      }
      for skill in skills {
        let docs = documents(of: skill, in: texts)
        if docs.isEmpty {
          errors.append("Rule case \(id): skill not found: \(skill)")
          continue
        }
        for (path, text) in docs.sorted(by: { $0.key < $1.key })
        where matches(rule, text) && !matches(qualifier, text) {
          errors.append(
            "Rule case \(id): \(path) states the rule without its exception; "
              + "the rule and its carve-out must travel together")
        }
      }
    }
    return errors
  }

  private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
  }
}
