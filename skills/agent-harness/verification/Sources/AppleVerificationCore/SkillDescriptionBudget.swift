import Foundation

/// Keeps skill descriptions inside the listing that clients load before any skill is chosen.
///
/// Every installed skill's name and description enters the agent's context up front. The
/// Agent Skills specification caps one description at 1024 characters. Claude Code budgets
/// that listing at 1% of the context window and drops the descriptions of the least-used
/// skills when it overflows; Codex budgets 2% and shortens descriptions, then omits skills.
/// Both fall back to 8,000 characters when the window is unknown. A description dropped or
/// cut from the listing loses the "Use when" clause that routes a request to its skill, so
/// this collection keeps each description short and leaves room for the user's other skills.
public enum SkillDescriptionBudget {
  /// The Agent Skills specification's limit for one description.
  static let specificationLimit = 1024
  /// This collection's limit for one description: what the skill does, one "Use when"
  /// clause and, where a neighbor is easily confused, one "Not for ... (use X)" route.
  static let skillLimit = 300
  /// This collection's limit for all descriptions together.
  static let totalLimit = 9000

  /// Returns an error for each description over its limit and for a total over the budget.
  /// A missing description is reported by `RepositoryValidation`, not here.
  public static func validate(texts: [String: String]) -> [String] {
    let measured = descriptions(in: texts)
    var errors = [String]()
    for (path, description) in measured.sorted(by: { $0.key < $1.key }) {
      if description.count > specificationLimit {
        errors.append(
          "Skill description has \(description.count) characters, over the Agent Skills "
            + "limit of \(specificationLimit): \(path)")
      } else if description.count > skillLimit {
        errors.append(
          "Skill description has \(description.count) characters, over \(skillLimit); keep "
            + "what it does, one 'Use when' clause and any 'Not for' route: \(path)")
      }
    }
    let total = measured.values.reduce(0) { $0 + $1.count }
    if total > totalLimit {
      errors.append(
        "Skill descriptions total \(total) characters, over the \(totalLimit)-character "
          + "listing budget")
    }
    return errors
  }

  /// The description of each `skills/<name>/SKILL.md` entry point, keyed by path.
  static func descriptions(in texts: [String: String]) -> [String: String] {
    var result = [String: String]()
    for (path, text) in texts {
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0] == "skills", parts[2] == "SKILL.md",
        let description = description(in: text)
      else { continue }
      result[path] = description
    }
    return result
  }

  /// Reads the frontmatter description as the listing shows it. A folded (`>`) or literal
  /// (`|`) block scalar is measured by its indented text, not by its one-character indicator
  /// line, and a plain scalar includes its indented continuation lines.
  private static func description(in text: String) -> String? {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"),
      let start = lines[1..<end].firstIndex(where: { $0.hasPrefix("description:") })
    else { return nil }
    let head = lines[start].dropFirst("description:".count)
      .trimmingCharacters(in: .whitespaces)
    let continuation = lines[(start + 1)..<end]
      .prefix(while: { $0.isEmpty || $0.hasPrefix(" ") })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let value: String
    if let indicator = head.first, indicator == ">" || indicator == "|" {
      value = continuation.joined(separator: indicator == ">" ? " " : "\n")
    } else {
      value = ([head] + continuation).filter { !$0.isEmpty }.joined(separator: " ")
    }
    return value.isEmpty ? nil : value
  }
}
