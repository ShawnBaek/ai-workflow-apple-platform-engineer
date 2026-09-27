import Foundation

/// Keeps the skill lifecycle file true to the checkout.
///
/// `skills/agent-harness/lifecycle/skill-lifecycle.json` installs with `agent-harness`: the
/// starter command installs that skill, and `apple-platform-setup`, the lead and the specialists
/// that link its references require it, but a selective installation without it lacks the file.
/// It records which skill IDs are current, which were retired and what replaced them, the
/// repository's former names and legacy plugins, and the names other owners expose to the same
/// agents, so tooling can tell this collection's entries from foreign ones. It stays outside
/// `contracts/`, whose source-bundle digest private harnesses bind, because its `version`
/// changes at every release. Its schema checks the shape; this checks what the schema cannot:
/// - `current` names each folder under `skills/`, and nothing else;
/// - a retired ID never returns to `current`, and each non-null `replacedBy` is current;
/// - a current skill takes a reserved Apple or client name only when `reservedNames.exceptions`
///   gives the reason, and each exception still matches a current reserved name;
/// - every ID list is free of duplicates, and `version` equals `VERSION`.
public enum SkillLifecycleValidation {
  static let path = "skills/agent-harness/lifecycle/skill-lifecycle.json"

  /// Validates the shipped lifecycle file against the skill folders and the `VERSION` value.
  static func validate(root: URL, skillFolders: [String], version: String) -> [String] {
    let lifecycle: [String: Any]
    do {
      lifecycle = try HarnessRuntime.object(root.appendingPathComponent(path))
    } catch {
      return ["skill lifecycle is unavailable or invalid: \(path): \(error)"]
    }
    return validate(lifecycle, skillFolders: skillFolders, version: version)
  }

  static func validate(_ lifecycle: [String: Any], skillFolders: [String], version: String)
    -> [String]
  {
    var errors = [String]()
    func ids(_ value: Any?, _ field: String) -> [String] {
      guard let values = value as? [Any], let ids = values as? [String] else {
        errors.append("skill lifecycle \(field) must be a list of IDs")
        return []
      }
      var seen = Set<String>()
      for id in ids where !seen.insert(id).inserted {
        errors.append("skill lifecycle \(field) lists \(id) more than once")
      }
      return ids
    }

    let current = Set(ids(lifecycle["current"], "current"))
    let folders = Set(skillFolders)
    for id in folders.subtracting(current).sorted() {
      errors.append("skill folder skills/\(id) is missing from skill lifecycle current")
    }
    for id in current.subtracting(folders).sorted() {
      errors.append("skill lifecycle current lists \(id), which has no skills/\(id) folder")
    }

    var retiredIDs = [String]()
    let retired = lifecycle["retired"] as? [Any]
    if retired == nil { errors.append("skill lifecycle retired must be a list") }
    for entry in retired ?? [] {
      guard let entry = entry as? [String: Any], let id = entry["id"] as? String else {
        errors.append("skill lifecycle retired entry has no id")
        continue
      }
      retiredIDs.append(id)
      if current.contains(id) {
        errors.append(
          "retired skill ID \(id) is in current again; never repurpose a retired ID")
      }
      if let successor = entry["replacedBy"] as? String, !current.contains(successor) {
        errors.append("retired skill \(id) is replaced by \(successor), which is not current")
      }
    }
    _ = ids(retiredIDs, "retired")

    let reserved = lifecycle["reservedNames"] as? [String: Any] ?? [:]
    var reservedIn = [String: [String]]()
    for id in ids(reserved["appleSkills"], "reservedNames.appleSkills") {
      reservedIn[id, default: []].append("reservedNames.appleSkills")
    }
    if let namespace = reserved["appleNamespace"] as? String {
      reservedIn[namespace, default: []].append("reservedNames.appleNamespace")
    } else {
      errors.append("skill lifecycle reservedNames.appleNamespace must be a name")
    }
    let builtins = reserved["clientBuiltins"] as? [String: Any]
    if builtins == nil {
      errors.append("skill lifecycle reservedNames.clientBuiltins must map clients to names")
    }
    for client in (builtins ?? [:]).keys.sorted() {
      let field = "reservedNames.clientBuiltins.\(client)"
      for id in ids(builtins?[client], field) { reservedIn[id, default: []].append(field) }
    }

    var excepted = Set<String>()
    var exceptionIDs = [String]()
    for entry in reserved["exceptions"] as? [Any] ?? [] {
      guard let entry = entry as? [String: Any], let id = entry["id"] as? String else {
        errors.append("skill lifecycle reserved-name exception has no id")
        continue
      }
      exceptionIDs.append(id)
      let reason = (entry["reason"] as? String ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines)
      if reason.isEmpty {
        errors.append("reserved-name exception for \(id) needs a reason")
      } else {
        excepted.insert(id)
      }
      if reservedIn[id] == nil || !current.contains(id) {
        errors.append(
          "reserved-name exception for \(id) is stale: \(id) is not a current skill that "
            + "takes a reserved name")
      }
    }
    _ = ids(exceptionIDs, "reservedNames.exceptions")
    for id in current.sorted() where !excepted.contains(id) {
      guard let fields = reservedIn[id] else { continue }
      errors.append(
        "skill \(id) takes a reserved name (\(fields.joined(separator: ", "))); rename it or "
          + "record the reason in reservedNames.exceptions")
    }

    let declared = lifecycle["version"] as? String
    if declared != version {
      errors.append(
        "skill lifecycle version \(declared ?? "(missing)") must equal VERSION \(version)")
    }
    return errors.sorted()
  }
}
