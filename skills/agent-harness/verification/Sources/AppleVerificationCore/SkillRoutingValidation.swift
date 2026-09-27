import Foundation

/// Checks the two instruction properties that repository linting cannot see: that a
/// capability stays reachable from the skills a request plausibly starts in, and that
/// a rule carrying an exception states that exception everywhere it is stated.
///
/// Both are deterministic text contracts over the shipped instructions. Neither runs a
/// model, so neither proves that an agent routes correctly — they prove that the
/// cross-references and qualifiers a correct routing decision depends on still exist.
/// Each case exists so that undoing a shipped fix fails validation, so a fixture section
/// or case that cannot be checked is an error rather than an empty pass.
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
    let routing = cases(in: fixture, section: "capabilityRouting")
    let rules = cases(in: fixture, section: "ruleConsistency")
    return routing.errors + checkCapabilityRouting(routing.cases, texts: texts) + rules.errors
      + checkRuleConsistency(rules.cases, texts: texts)
  }

  /// The case objects of one required section, with an error for a missing or non-array
  /// section and for each entry that is not an object.
  private static func cases(in fixture: [String: Any], section: String) -> (
    cases: [[String: Any]], errors: [String]
  ) {
    guard let entries = fixture[section] as? [Any] else {
      return ([], ["Invalid routing fixture: \(section) must be an array of case objects"])
    }
    var cases = [[String: Any]]()
    var errors = [String]()
    for (index, entry) in entries.enumerated() {
      if let entry = entry as? [String: Any] {
        cases.append(entry)
      } else {
        errors.append("Invalid routing fixture: \(section)[\(index)] is not a case object")
      }
    }
    return (cases, errors)
  }

  /// A non-empty list of non-empty names, or nil; an empty list would check nothing.
  private static func names(_ value: Any?) -> [String]? {
    guard let names = value as? [String], !names.isEmpty, !names.contains(where: \.isEmpty) else {
      return nil
    }
    return names
  }

  /// Documents belonging to one skill, so a reference may live in a sub-doc.
  private static func documents(of skill: String, in texts: [String: String]) -> [String: String] {
    texts.filter { $0.key.hasPrefix("skills/\(skill)/") }
  }

  /// An explicit reference to a skill: its whole name as a code span, optionally invoked as
  /// `$name` or `/name`, or a relative path into its folder such as `../name/SKILL.md`. A name
  /// made of ordinary words, like `screenshot`, also appears in prose and inside longer skill
  /// names (`app-store-screenshots`); neither routes a request to that skill.
  private static func reference(to skill: String) -> NSRegularExpression? {
    let name = NSRegularExpression.escapedPattern(for: skill)
    return try? NSRegularExpression(pattern: "`[$/]?\(name)`|\\.\\./\(name)/")
  }

  private static func checkCapabilityRouting(_ cases: [[String: Any]], texts: [String: String])
    -> [String]
  {
    var errors = [String]()
    for entry in cases {
      guard
        let id = entry["id"] as? String, !id.isEmpty,
        let owner = entry["owner"] as? String, !owner.isEmpty,
        let sources = names(entry["referencedFrom"]),
        let route = reference(to: owner)
      else {
        errors.append("Invalid routing case: missing or empty id, owner or referencedFrom")
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
        if !docs.values.contains(where: { matches(route, $0) }) {
          errors.append(
            "Routing case \(id): \(source) no longer routes to \(owner); "
              + "a request starting there cannot reach the owning skill "
              + "(name it as `\(owner)` or link ../\(owner)/SKILL.md)")
        }
      }
    }
    return errors
  }

  private static func checkRuleConsistency(_ cases: [[String: Any]], texts: [String: String])
    -> [String]
  {
    var errors = [String]()
    for entry in cases {
      guard
        let id = entry["id"] as? String, !id.isEmpty,
        let rulePattern = entry["statesRule"] as? String, !rulePattern.isEmpty,
        let qualifierPattern = entry["requiresQualifier"] as? String, !qualifierPattern.isEmpty,
        let skills = names(entry["appliesTo"])
      else {
        errors.append(
          "Invalid rule case: missing or empty id, statesRule, requiresQualifier or appliesTo")
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
    regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
      != nil
  }
}
