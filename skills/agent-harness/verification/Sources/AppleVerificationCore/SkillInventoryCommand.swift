import Foundation

extension SkillInventory {
  /// `skill-inventory [--home <dir>] [--codex-home <dir>] [--claude-config-dir <dir>]
  /// [--xdg-state-home <dir>] [--project <dir>] [--output <new-report.json>]`
  ///
  /// Prints one JSON report. Exit 0 when nothing needs a decision, 1 when a finding does. The
  /// lifecycle file and the reference copies come from the verifier's own installation
  /// (`context`), never from the scanned roots. `--output` writes only a new file, never at a
  /// Skills CLI lock path, and never inside a scanned root, the collection or a folder a scanned
  /// entry links to.
  public static func run(
    arguments: [String], context: RuntimeContext, environment: [String: String]
  )
    throws -> Int32
  {
    let options = try RuntimeArguments(arguments)
    try options.allow([
      "--home", "--codex-home", "--claude-config-dir", "--xdg-state-home", "--project", "--output",
    ])
    let locations = try Locations.resolve(options: options, environment: environment)
    let collection = context.harnessRoot.deletingLastPathComponent()
    let output = try options.value("--output").map { path in
      guard path.hasPrefix("/") else {
        throw VerificationError.invalid("--output must be an absolute path")
      }
      let output = URL(fileURLWithPath: path).standardizedFileURL
      try checkOutput(
        output, roots: try roots(locations), locks: try lockFiles(locations).map(\.url),
        collection: collection.path)
      return output
    }
    let lifecycle = try HarnessRuntime.object(
      context.harnessRoot.appendingPathComponent("lifecycle/skill-lifecycle.json"))
    let report = try inventory(
      locations: locations, collectionSkills: collection,
      verifier: context.harnessRoot.lastPathComponent, lifecycle: lifecycle)
    var data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    if let output { try data.write(to: output, options: [.withoutOverwriting]) }
    FileHandle.standardOutput.write(data)
    return report["status"] as? String == "clean" ? 0 : 1
  }

  /// Refuses an output path at a lock path (absent locks included: a report there would be read
  /// as the lock), or inside a scanned root, the collection folder or a folder a scanned entry
  /// resolves to, compared by the path as given (a link inside a skill folder still leads out of
  /// it) and by its resolved parent.
  static func checkOutput(_ output: URL, roots: [Root], locks: [URL], collection: String) throws {
    var protected = Set<String>()
    for folder in roots.map(\.path) + [collection] {
      protected.insert(URL(fileURLWithPath: folder).standardizedFileURL.path)
      guard let physical = realPath(folder), isDirectory(physical) else { continue }
      protected.insert(physical)
      // Every top-level entry's target, hidden and client-managed ones included.
      for name in (try? FileManager.default.contentsOfDirectory(atPath: physical)) ?? [] {
        if let target = realPath((physical as NSString).appendingPathComponent(name)) {
          protected.insert(target)
        }
      }
    }
    for root in roots {
      for entry in scan(root).entries {
        if let physical = entry.physical { protected.insert(physical) }
      }
    }
    func resolved(_ url: URL) -> String? {
      realPath(url.deletingLastPathComponent().path).map {
        ($0 as NSString).appendingPathComponent(url.lastPathComponent)
      }
    }
    let candidates = [output.path, resolved(output)].compactMap { $0 }
    // Compared without case: the default APFS volume would serve either spelling as the lock.
    let lockPaths = Set(
      locks.flatMap { [$0.standardizedFileURL.path, resolved($0)] }.compactMap { $0?.lowercased() })
    guard lockPaths.isDisjoint(with: candidates.map { $0.lowercased() }) else {
      throw VerificationError.invalid("--output must not be a Skills CLI lock path")
    }
    for candidate in candidates {
      for folder in protected where candidate == folder || candidate.hasPrefix(folder + "/") {
        throw VerificationError.invalid(
          "--output must not be inside a scanned or collection skill folder or a folder a "
            + "scanned entry links to")
      }
    }
  }
}
