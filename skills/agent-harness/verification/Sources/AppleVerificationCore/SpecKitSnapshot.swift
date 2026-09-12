import Darwin
import Foundation

public enum SpecKitSnapshot {
  public static let pinnedRelease = "v1.0.1"
  private static let requiredArtifacts = ["spec.md", "plan.md", "tasks.md"]
  private static let optionalArtifacts = ["research.md", "data-model.md", "quickstart.md"]
  private static let artifactDirectories = ["checklists", "contracts"]

  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    try SpecKitSnapshotCommand.run(arguments: arguments, context: context)
  }

  public static func buildSnapshot(
    root: URL,
    release: String = pinnedRelease,
    runID: String? = nil,
    featureDirectory: String? = nil,
    discovery: Bool = false
  ) throws -> [String: Any] {
    let root = try canonicalDirectory(root, label: "authoritative root")
    guard release == pinnedRelease else {
      throw VerificationError.invalid("Spec Kit release must be pinned to \(pinnedRelease)")
    }
    guard featureDirectory != nil || discovery else {
      throw VerificationError.invalid(
        "approved feature_directory is required; use discovery mode only for read-only discovery")
    }
    guard featureDirectory == nil || !discovery else {
      throw VerificationError.invalid(
        "choose approved feature_directory or discovery mode, not both")
    }
    let (selected, feature) = try resolveFeatureDirectory(root: root, expected: featureDirectory)
    let artifacts = try acceptedArtifacts(root: root, feature: feature)
    guard try readFeaturePointer(root: root) == selected else {
      throw VerificationError.invalid("Spec Kit feature pointer changed while snapshotting")
    }
    let immutable: [String: Any] = [
      "schema_version": "1.0.0", "spec_kit_release": release,
      "feature_id": feature.lastPathComponent, "feature_directory": selected,
      "accepted_artifacts": artifacts,
    ]
    var result = immutable
    var hashes: [String: Any] = [:]
    for artifact in artifacts { hashes[artifact["path"] as! String] = artifact["sha256"]! }
    result["artifact_hashes"] = hashes
    result["snapshot_sha256"] = HarnessRuntime.sha256(try HarnessRuntime.canonicalJSON(immutable))
    result["workflow_checkpoint"] =
      try runID.map { try workflowCheckpoint(root: root, runID: $0) } ?? NSNull()
    return result
  }

  public static func verifySnapshot(expected: [String: Any], current: [String: Any]) -> [String] {
    var errors: [String] = []
    if expected["spec_kit_release"] as? String != pinnedRelease {
      errors.append("expected snapshot does not use the pinned Spec Kit release")
    }
    if !jsonEqual(current["spec_kit_release"], expected["spec_kit_release"]) {
      errors.append("Spec Kit release changed")
    }
    if !jsonEqual(current["feature_directory"], expected["feature_directory"]) {
      errors.append("Spec Kit feature_directory pointer changed or became stale")
    }
    if !jsonEqual(current["feature_id"], expected["feature_id"]) {
      errors.append("Spec Kit feature identity changed")
    }
    if !jsonEqual(current["accepted_artifacts"], expected["accepted_artifacts"]) {
      errors.append("accepted Spec Kit artifact set or content changed")
    }
    if !jsonEqual(current["snapshot_sha256"], expected["snapshot_sha256"]) {
      errors.append("immutable Spec Kit snapshot hash changed")
    }
    let expectedCheckpoint = expected["workflow_checkpoint"] as? [String: Any]
    let currentCheckpoint = current["workflow_checkpoint"] as? [String: Any]
    if (expectedCheckpoint == nil) != (currentCheckpoint == nil) {
      errors.append("Spec Kit workflow checkpoint selection changed")
    } else if let expectedCheckpoint, let currentCheckpoint {
      if !jsonEqual(currentCheckpoint["run_id"], expectedCheckpoint["run_id"]) {
        errors.append("Spec Kit workflow run selection changed")
      }
      let expectedEntries =
        ((expectedCheckpoint["log"] as? [String: Any])?["entry_sha256"] as? [String]) ?? []
      let currentEntries =
        ((currentCheckpoint["log"] as? [String: Any])?["entry_sha256"] as? [String]) ?? []
      if currentEntries.count < expectedEntries.count {
        errors.append("Spec Kit workflow log was truncated")
      } else if Array(currentEntries.prefix(expectedEntries.count)) != expectedEntries {
        errors.append("Spec Kit workflow log was rewritten")
      }
    }
    return Array(Set(errors)).sorted()
  }

  private static func resolveFeatureDirectory(root: URL, expected: String?) throws -> (String, URL)
  {
    let selected = try readFeaturePointer(root: root)
    if let expected {
      let normalized = try normalizeFeatureDirectory(expected)
      guard normalized == selected else {
        throw VerificationError.invalid(
          "Spec Kit feature pointer is stale: expected '\(normalized)', found '\(selected)'")
      }
    }
    let specs = root.appendingPathComponent("specs", isDirectory: true)
    guard !isSymbolicLink(specs) else {
      throw VerificationError.invalid("Spec Kit specs directory must not be a symbolic link")
    }
    let resolvedSpecs = try canonicalDirectory(specs, label: "Spec Kit specs directory")
    guard resolvedSpecs.deletingLastPathComponent() == root else {
      throw VerificationError.invalid("Spec Kit specs directory escaped the authoritative root")
    }
    let feature = root.appendingPathComponent(selected, isDirectory: true)
    guard !isSymbolicLink(feature) else {
      throw VerificationError.invalid(
        "selected Spec Kit feature directory must not be a symbolic link")
    }
    let resolvedFeature = try canonicalDirectory(
      feature, label: "selected Spec Kit feature directory")
    guard resolvedFeature.deletingLastPathComponent() == resolvedSpecs else {
      throw VerificationError.invalid("selected Spec Kit feature directory escaped specs/<feature>")
    }
    return (selected, resolvedFeature)
  }

  private static func readFeaturePointer(root: URL) throws -> String {
    let pointer = try regularFile(
      root: root, path: root.appendingPathComponent(".specify/feature.json"),
      label: "Spec Kit feature pointer")
    guard let document = try HarnessRuntime.loadJSON(pointer) as? [String: Any] else {
      throw VerificationError.invalid("Spec Kit feature pointer must be a JSON object")
    }
    return try normalizeFeatureDirectory(document["feature_directory"])
  }

  private static func normalizeFeatureDirectory(_ value: Any?) throws -> String {
    guard let value = value as? String, !value.isEmpty else {
      throw VerificationError.invalid(
        "feature.json must contain a non-empty feature_directory string")
    }
    guard !value.contains("\\"), !value.contains("\0") else {
      throw VerificationError.invalid("feature_directory contains an unsafe path character")
    }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "specs" else {
      throw VerificationError.invalid("feature_directory must be exactly specs/<feature>")
    }
    let feature = String(parts[1])
    guard feature.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    else {
      throw VerificationError.invalid("feature_directory contains an unsafe feature identifier")
    }
    let canonical = "specs/\(feature)"
    guard value == canonical else {
      throw VerificationError.invalid(
        "feature_directory must use the canonical specs/<feature> form")
    }
    return canonical
  }

  private static func acceptedArtifacts(root: URL, feature: URL) throws -> [[String: Any]] {
    var paths = requiredArtifacts.map {
      (feature.appendingPathComponent($0), "selected feature artifact \($0)")
    }
    let constitution = root.appendingPathComponent(".specify/memory/constitution.md")
    if pathExists(constitution) { paths.append((constitution, "Spec Kit constitution")) }
    for name in optionalArtifacts {
      let path = feature.appendingPathComponent(name)
      if pathExists(path) { paths.append((path, "selected feature artifact \(name)")) }
    }
    for name in artifactDirectories {
      let directory = feature.appendingPathComponent(name, isDirectory: true)
      guard pathExists(directory) else { continue }
      guard !isSymbolicLink(directory), isDirectory(directory) else {
        throw VerificationError.invalid("selected feature artifact directory \(name) is invalid")
      }
      guard
        let enumerator = FileManager.default.enumerator(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
          options: [])
      else {
        throw VerificationError.invalid("cannot enumerate selected feature artifact directory")
      }
      for case let path as URL in enumerator {
        if isSymbolicLink(path) {
          throw VerificationError.invalid("selected feature artifact tree contains a symbolic link")
        }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values.isRegularFile == true {
          paths.append((path, "selected feature artifact"))
        } else if values.isDirectory != true {
          throw VerificationError.invalid(
            "selected feature artifact tree contains a non-file entry")
        }
      }
    }
    return try paths.map { try artifact(root: root, path: $0.0, label: $0.1) }
      .sorted {
        ($0["path"] as! String).utf8.lexicographicallyPrecedes(($1["path"] as! String).utf8)
      }
  }

  private static func artifact(root: URL, path: URL, label: String) throws -> [String: Any] {
    let resolved = try regularFile(root: root, path: path, label: label)
    let data = try Data(contentsOf: resolved)
    return [
      "path": relativePath(path, root), "sha256": HarnessRuntime.sha256(data), "size": data.count,
    ]
  }

  private static func workflowCheckpoint(root: URL, runID: String) throws -> [String: Any] {
    guard runID.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    else { throw VerificationError.invalid("run_id contains unsafe characters") }
    let runs = root.appendingPathComponent(".specify/workflows/runs", isDirectory: true)
    guard !isSymbolicLink(runs) else {
      throw VerificationError.invalid(
        "Spec Kit workflow runs directory must not be a symbolic link")
    }
    let resolvedRuns = try canonicalDirectory(runs, label: "Spec Kit workflow runs directory")
    guard isWithin(resolvedRuns, root) else {
      throw VerificationError.invalid(
        "Spec Kit workflow runs directory escaped the authoritative root")
    }
    let run = runs.appendingPathComponent(runID, isDirectory: true)
    guard !isSymbolicLink(run) else {
      throw VerificationError.invalid("selected Spec Kit workflow run must not be a symbolic link")
    }
    let resolvedRun = try canonicalDirectory(run, label: "selected Spec Kit workflow run")
    guard resolvedRun.deletingLastPathComponent() == resolvedRuns else {
      throw VerificationError.invalid("selected Spec Kit workflow run escaped the runs directory")
    }
    let statePath = run.appendingPathComponent("state.json")
    let inputsPath = run.appendingPathComponent("inputs.json")
    let logPath = run.appendingPathComponent("log.jsonl")
    let state = try jsonCheckpoint(root: root, path: statePath, label: "Spec Kit workflow state")
    let stateDocument = try HarnessRuntime.object(statePath)
    guard stateDocument["run_id"] as? String == runID else {
      throw VerificationError.invalid(
        "Spec Kit workflow state run_id does not match the selected run")
    }
    guard let workflowID = stateDocument["workflow_id"] as? String, !workflowID.isEmpty else {
      throw VerificationError.invalid("Spec Kit workflow state is missing workflow_id")
    }
    guard
      ["created", "running", "completed", "paused", "failed", "aborted"].contains(
        stateDocument["status"] as? String ?? "")
    else { throw VerificationError.invalid("Spec Kit workflow state has an invalid status") }
    let inputs = try jsonCheckpoint(root: root, path: inputsPath, label: "Spec Kit workflow inputs")
    let inputDocument = try HarnessRuntime.object(inputsPath)
    guard inputDocument["inputs"] is [String: Any] else {
      throw VerificationError.invalid("Spec Kit workflow inputs must contain an inputs object")
    }
    return [
      "run_id": runID, "state": state, "inputs": inputs,
      "log": try logCheckpoint(root: root, path: logPath),
    ]
  }

  private static func jsonCheckpoint(root: URL, path: URL, label: String) throws -> [String: Any] {
    let record = try artifact(root: root, path: path, label: label)
    guard try HarnessRuntime.loadJSON(path) is [String: Any] else {
      throw VerificationError.invalid("\(label) must contain a JSON object")
    }
    return record
  }

  private static func logCheckpoint(root: URL, path: URL) throws -> [String: Any] {
    let resolved = try regularFile(root: root, path: path, label: "Spec Kit workflow log")
    let data = try Data(contentsOf: resolved)
    var entries: [String] = []
    var start = data.startIndex
    while start < data.endIndex {
      var end = start
      while end < data.endIndex, data[end] != 10, data[end] != 13 { end += 1 }
      let payload = data[start..<end]
      guard !payload.isEmpty else {
        throw VerificationError.invalid("Spec Kit workflow log line \(entries.count + 1) is empty")
      }
      guard (try? JSONSerialization.jsonObject(with: Data(payload))) is [String: Any] else {
        throw VerificationError.invalid(
          "Spec Kit workflow log line \(entries.count + 1) is not valid JSON object")
      }
      if end < data.endIndex {
        if data[end] == 13, data.index(after: end) < data.endIndex,
          data[data.index(after: end)] == 10
        {
          end = data.index(after: end)
        }
        end = data.index(after: end)
      }
      entries.append(HarnessRuntime.sha256(Data(data[start..<end])))
      start = end
    }
    return [
      "path": relativePath(path, root), "sha256": HarnessRuntime.sha256(data), "size": data.count,
      "entry_sha256": entries, "line_count": entries.count,
      "ends_with_newline": data.isEmpty || data.last == 10 || data.last == 13,
    ]
  }

  private static func canonicalDirectory(_ url: URL, label: String) throws -> URL {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory),
      directory.boolValue
    else { throw VerificationError.invalid("missing \(label)") }
    return resolved
  }

  private static func regularFile(root: URL, path: URL, label: String) throws -> URL {
    guard !isSymbolicLink(path) else {
      throw VerificationError.invalid("\(label) must not be a symbolic link")
    }
    let resolved = path.resolvingSymlinksInPath().standardizedFileURL
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory),
      !directory.boolValue
    else { throw VerificationError.invalid("missing \(label): \(path.path)") }
    guard isWithin(resolved, root) else {
      throw VerificationError.invalid("\(label) escaped the authoritative root")
    }
    return resolved
  }

  private static func isWithin(_ path: URL, _ parent: URL) -> Bool {
    path.path == parent.path || path.path.hasPrefix(parent.path + "/")
  }
  private static func relativePath(_ path: URL, _ root: URL) -> String {
    String(path.standardizedFileURL.path.dropFirst(root.path.count + 1))
  }
  private static func pathExists(_ path: URL) -> Bool {
    var info = stat()
    return lstat(path.path, &info) == 0
  }
  private static func isSymbolicLink(_ path: URL) -> Bool {
    var info = stat()
    return lstat(path.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
  }
  private static func isDirectory(_ path: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path.path, isDirectory: &directory)
      && directory.boolValue
  }
  private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }
}

public enum SpecKitSnapshotCommand {
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    let options = try CLIOptions(arguments)
    guard let command = options.positionals.first, ["snapshot", "verify"].contains(command),
      let root = options.url("root")
    else {
      throw VerificationError.invalid(
        "usage: spec-kit-snapshot snapshot|verify --root PATH (--feature-directory PATH|--discovery)"
      )
    }
    let snapshot = try SpecKitSnapshot.buildSnapshot(
      root: root, release: options.value("release") ?? SpecKitSnapshot.pinnedRelease,
      runID: options.value("run-id"), featureDirectory: options.value("feature-directory"),
      discovery: options.has("discovery"))
    if command == "snapshot" {
      printJSON(snapshot)
      return 0
    }
    guard let expectedURL = options.url("expected") else {
      throw VerificationError.invalid("verify requires --expected")
    }
    let expected = try HarnessRuntime.object(expectedURL)
    let errors = SpecKitSnapshot.verifySnapshot(expected: expected, current: snapshot)
    printJSON(["current": snapshot, "valid": errors.isEmpty, "errors": errors])
    return errors.isEmpty ? 0 : 2
  }
}

struct CLIOptions {
  var positionals: [String] = []
  var values: [String: [String]] = [:]
  init(_ arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument.hasPrefix("--") {
        let key = String(argument.dropFirst(2))
        if ["discovery"].contains(key) {
          values[key, default: []].append("true")
          index += 1
        } else {
          guard index + 1 < arguments.count else {
            throw VerificationError.invalid("missing value for \(argument)")
          }
          values[key, default: []].append(arguments[index + 1])
          index += 2
        }
      } else {
        positionals.append(argument)
        index += 1
      }
    }
  }
  func value(_ key: String) -> String? { values[key]?.last }
  func all(_ key: String) -> [String] { values[key] ?? [] }
  func has(_ key: String) -> Bool { values[key] != nil }
  func url(_ key: String) -> URL? { value(key).map { URL(fileURLWithPath: $0) } }
}

func printJSON(_ value: Any) {
  if let data = try? JSONSerialization.data(
    withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  {
    print(String(decoding: data, as: UTF8.self))
  }
}
