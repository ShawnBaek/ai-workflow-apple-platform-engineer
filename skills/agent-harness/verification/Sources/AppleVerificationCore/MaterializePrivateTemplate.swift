import Darwin
import Foundation

public struct MaterializeError: Error, Equatable, CustomStringConvertible {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
}

public enum MaterializePrivateTemplate {
  private static func regularJSON(_ path: URL, label: String) throws -> [String: Any] {
    guard path.path.hasPrefix("/"), !isSymlink(path), isRegular(path) else {
      throw MaterializeError("\(label) must be an absolute regular non-symlink file")
    }
    do { return try HarnessRuntime.object(path) } catch {
      throw MaterializeError("\(label) is not readable JSON")
    }
  }

  private static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
  private static func isRegular(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }

  public static func materialize(
    templatePath: URL, schemaPath: URL, outputPath: URL, replace: Bool = false
  ) throws -> [String: Any] {
    let template = try regularJSON(templatePath, label: "template")
    let schema = try regularJSON(schemaPath, label: "schema")
    guard outputPath.path.hasPrefix("/") else {
      throw MaterializeError("output must be an absolute path")
    }
    let parent = outputPath.deletingLastPathComponent()
    guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      !isSymlink(parent)
    else { throw MaterializeError("output parent must exist and must not be a symlink") }
    let exists = FileManager.default.fileExists(atPath: outputPath.path)
    guard !isSymlink(outputPath), !exists || isRegular(outputPath) else {
      throw MaterializeError("output must be a regular non-symlink file")
    }
    guard !exists || replace else {
      throw MaterializeError("output already exists; pass --replace for an explicit update")
    }
    let canonicalSchema = schemaPath.resolvingSymlinksInPath().standardizedFileURL
    var document = template
    document["$schema"] = canonicalSchema.absoluteString
    if document["contract_schema_id"] != nil {
      guard let schemaID = schema["$id"] as? String, !schemaID.isEmpty else {
        throw MaterializeError("schema must provide a stable non-empty $id")
      }
      document["contract_schema_id"] = schemaID
    }
    let schemaDigest = "sha256:" + (try HarnessRuntime.sha256File(canonicalSchema))
    if document["contract_schema_sha256"] != nil {
      document["contract_schema_sha256"] = schemaDigest
    }
    let errors = JSONSchemaValidator.errors(
      instance: document, schema: schema, path: "$", root: nil)
    guard errors.isEmpty else {
      throw MaterializeError(
        "materialized document failed its installed schema: "
          + Array(Set(errors)).sorted().joined(separator: "; "))
    }
    do {
      try HarnessRuntime.atomicWriteJSON(document, to: outputPath)
      guard chmod(outputPath.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EACCES) }
    } catch { throw MaterializeError("output cannot be written atomically") }
    return [
      "output_path": outputPath.resolvingSymlinksInPath().path,
      "schema_uri": canonicalSchema.absoluteString,
      "contract_schema_id": schema["$id"] as? String ?? "", "contract_schema_sha256": schemaDigest,
    ]
  }

  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    var options: [String: String] = [:]
    var replace = false
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      if key == "--replace" {
        guard !replace else { throw MaterializeError("invalid arguments") }
        replace = true
        index += 1
        continue
      }
      guard ["--template", "--schema", "--output"].contains(key), options[key] == nil,
        index + 1 < arguments.count
      else { throw MaterializeError("invalid arguments") }
      options[key] = arguments[index + 1]
      index += 2
    }
    guard let template = options["--template"], let schema = options["--schema"],
      let output = options["--output"]
    else { throw MaterializeError("invalid arguments") }
    do {
      let result = try materialize(
        templatePath: URL(fileURLWithPath: template), schemaPath: URL(fileURLWithPath: schema),
        outputPath: URL(fileURLWithPath: output), replace: replace)
      var response = result
      response["status"] = "ok"
      FileHandle.standardOutput.write(
        try HarnessRuntime.canonicalJSON(response, ensureASCII: true) + Data([0x0a]))
      return 0
    } catch let error as MaterializeError {
      let response: [String: Any] = ["status": "blocked", "reason": error.message]
      FileHandle.standardOutput.write(
        try HarnessRuntime.canonicalJSON(response, ensureASCII: true) + Data([0x0a]))
      return 2
    }
  }
}
