import Darwin
import Foundation

public enum PrepareActionRequest {
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    try PrepareActionRequestCommand.run(arguments: arguments, context: context)
  }
  public static func prepare(
    authorizationPath: URL, receiptPath: URL, descriptorPath: URL,
    healthReportPath: URL, outputPath: URL, runRoot: URL,
    grantID: String, target: String, paths: [String],
    specCheckpointPath: URL? = nil, appleActionPath: URL? = nil,
    appleObservationPath: URL? = nil, context: RuntimeContext
  ) throws -> [String: Any] {
    let root = runRoot.resolvingSymlinksInPath().standardizedFileURL
    guard !isSymlink(runRoot), isDirectory(root) else {
      throw VerificationError.invalid("run root must be an existing non-symlink directory")
    }
    guard outputPath.path.hasPrefix("/"),
      outputPath.deletingLastPathComponent().resolvingSymlinksInPath() == root,
      !FileManager.default.fileExists(atPath: outputPath.path), !isSymlink(outputPath)
    else {
      throw VerificationError.invalid(
        "output must be a new regular file directly under the run root")
    }
    let authorization = try loadObject(authorizationPath, label: "authorization", root: root)
    let receipt = try loadObject(receiptPath, label: "coordinator receipt", root: root)
    let descriptor = try loadObject(descriptorPath, label: "resource descriptor", root: root)
    let health = try loadObject(healthReportPath, label: "health report", root: root)
    let authErrors = Authorization.validateAuthorization(authorization, context: context)
    guard authErrors.isEmpty else {
      throw VerificationError.invalid(
        "authorization is invalid: \(authErrors.joined(separator: "; "))")
    }
    let grants = (authorization["action_grants"] as? [[String: Any]] ?? []).filter {
      $0["grant_id"] as? String == grantID
    }
    guard grants.count == 1 else {
      throw VerificationError.invalid("grant_id must resolve exactly once")
    }
    let grant = grants[0]
    if let exactTarget = grant["target"] as? String, target != exactTarget {
      throw VerificationError.invalid("target differs from the exact grant target")
    }
    guard Set(receipt.keys) == Authorization.coordinatorReceiptFields else {
      throw VerificationError.invalid("coordinator receipt shape is invalid")
    }
    guard receipt["owner_run_id"] as? String == authorization["run_id"] as? String else {
      throw VerificationError.invalid("coordinator receipt belongs to another run")
    }
    guard receipt["owner_actor"] as? String == authorization["selected_writer"] as? String else {
      throw VerificationError.invalid("coordinator receipt belongs to another writer")
    }
    guard receipt["resource_key"] as? String == grant["resource_key"] as? String else {
      throw VerificationError.invalid("coordinator receipt resource differs from the grant")
    }
    guard !descriptor.isEmpty else {
      throw VerificationError.invalid("resource descriptor must be a non-empty object")
    }
    let normalizedDescriptor = try ResourceCoordinator.normalizeDescriptor(
      resource: receipt["resource"] as? String ?? "", descriptor: descriptor)
    let descriptorDigest = try ResourceCoordinator.descriptorSHA256(
      resource: receipt["resource"] as? String ?? "", descriptor: normalizedDescriptor)
    guard receipt["descriptor_sha256"] as? String == descriptorDigest else {
      throw VerificationError.invalid("resource descriptor digest differs from the receipt")
    }
    guard !paths.isEmpty, Set(paths).count == paths.count, paths.allSatisfy({ !$0.isEmpty }) else {
      throw VerificationError.invalid("paths must be non-empty unique strings")
    }
    let checkpointDigest = try specCheckpointPath.map {
      try Authorization.canonicalSHA256(loadAny($0, label: "Spec Kit checkpoint", root: root))
    }
    let observationDigest = try appleObservationPath.map {
      try Authorization.canonicalSHA256(loadAny($0, label: "Apple observation", root: root))
    }
    let appleAction = try appleActionPath.map {
      try loadObject($0, label: "Apple action", root: root)
    }
    let isApple = (grant["action"] as? String)?.hasPrefix("apple.") == true
    if isApple && appleAction == nil {
      throw VerificationError.invalid("Apple grants require --apple-action")
    }
    if !isApple && appleAction != nil {
      throw VerificationError.invalid("non-Apple grants cannot include --apple-action")
    }
    let spec = authorization["spec_kit"] as? [String: Any]
    let request: [String: Any] = [
      "run_id": authorization["run_id"]!, "authorization_id": authorization["authorization_id"]!,
      "authorization_hash": Authorization.authorizationHash(authorization),
      "delivery_target": authorization["delivery_target"]!,
      "system": grant["system"]!, "action": grant["action"]!, "target": target,
      "grant_id": grant["grant_id"]!,
      "idempotency_key": grant["idempotency_key"]!, "repository": authorization["repository"]!,
      "spec_snapshot_sha256": spec?["snapshot_sha256"] ?? NSNull(), "paths": paths,
      "apple": appleAction ?? NSNull(), "lease_id": receipt["lease_id"]!,
      "lease_owner": receipt["owner_actor"]!,
      "lease_resource": receipt["resource"]!, "lease_resource_key": receipt["resource_key"]!,
      "resource_descriptor": normalizedDescriptor, "coordinator_receipt": receipt,
      "operation": grant["operation"]!, "operation_input": grant["operation_input"]!,
      "constraint_sha256": grant["constraint_sha256"]!,
      "phase": grant["phase"]!, "spec_checkpoint_sha256": checkpointDigest ?? NSNull(),
      "apple_observation_sha256": observationDigest ?? NSNull(),
      "writer_actor": authorization["selected_writer"]!,
      "health_report_sha256": "sha256:" + (try Authorization.canonicalSHA256(health)),
    ]
    guard Set(request.keys) == Authorization.requestFields else {
      throw VerificationError.invalid(
        "generated request field set drifted from the installed contract")
    }
    try createExclusiveJSON(request, output: outputPath)
    return request
  }

  private static func loadAny(_ path: URL, label: String, root: URL) throws -> Any {
    do { return try Authorization.loadStablePrivateJSON(path, root: root) } catch {
      throw VerificationError.invalid("\(label) is not a stable private JSON file: \(error)")
    }
  }
  private static func loadObject(_ path: URL, label: String, root: URL) throws -> [String: Any] {
    guard let result = try loadAny(path, label: label, root: root) as? [String: Any] else {
      throw VerificationError.invalid("\(label) must contain an object")
    }
    return result
  }
  private static func createExclusiveJSON(_ value: Any, output: URL) throws {
    let data =
      try JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      + Data("\n".utf8)
    let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw VerificationError.invalid(
        "output must be a new regular file directly under the run root")
    }
    var succeeded = false
    defer {
      close(descriptor)
      if !succeeded { unlink(output.path) }
    }
    try data.withUnsafeBytes { bytes in
      var pointer = bytes.baseAddress!
      var remaining = bytes.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        guard written > 0 else { throw VerificationError.invalid("cannot write action request") }
        pointer += written
        remaining -= written
      }
    }
    guard fsync(descriptor) == 0 else {
      throw VerificationError.invalid("cannot sync action request")
    }
    succeeded = true
  }
  private static func isSymlink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
  }
  private static func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
      && directory.boolValue
  }
}

public enum PrepareActionRequestCommand {
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    let options = try CLIOptions(arguments)
    guard let authorization = options.url("authorization"), let receipt = options.url("receipt"),
      let descriptor = options.url("resource-descriptor"),
      let health = options.url("health-report"), let output = options.url("output"),
      let runRoot = options.url("run-root"),
      let grantID = options.value("grant-id"), let target = options.value("target")
    else { throw VerificationError.invalid("missing required prepare-action-request argument") }
    do {
      let request = try PrepareActionRequest.prepare(
        authorizationPath: authorization, receiptPath: receipt, descriptorPath: descriptor,
        healthReportPath: health, outputPath: output, runRoot: runRoot, grantID: grantID,
        target: target, paths: options.all("path"),
        specCheckpointPath: options.url("spec-checkpoint"),
        appleActionPath: options.url("apple-action"),
        appleObservationPath: options.url("apple-observation"), context: context)
      printJSON([
        "status": "ok", "output": output.resolvingSymlinksInPath().path,
        "grant_id": request["grant_id"]!, "authorization_hash": request["authorization_hash"]!,
      ])
      return 0
    } catch {
      printJSON(["status": "blocked", "reason": String(describing: error)])
      return 2
    }
  }
}
