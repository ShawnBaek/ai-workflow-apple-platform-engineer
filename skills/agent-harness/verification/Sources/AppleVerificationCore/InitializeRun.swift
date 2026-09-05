import Darwin
import Foundation

public struct InitializeError: Error, Equatable, CustomStringConvertible {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
}

public enum InitializeRun {
  private static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
  private static func isRegular(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }
  private static func loadObject(_ path: URL, label: String) throws -> [String: Any] {
    guard path.path.hasPrefix("/"), !isSymlink(path), isRegular(path) else {
      throw InitializeError("\(label) must be an absolute regular non-symlink file")
    }
    do { return try HarnessRuntime.object(path) } catch {
      throw InitializeError("\(label) is not readable JSON")
    }
  }

  public static func approvalRecord(
    authorization: [String: Any], recordedAt: Date, context: RuntimeContext
  ) throws -> [String: Any] {
    let schemaPath = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    let schema: [String: Any]
    do { schema = try HarnessRuntime.object(schemaPath) } catch {
      throw InitializeError("installed authorization schema is unavailable")
    }
    let errors =
      Authorization.schemaErrors(instance: authorization, schema: schema)
      + Authorization.validateAuthorization(authorization, context: context)
    guard errors.isEmpty else {
      throw InitializeError(
        "approved authorization is invalid: " + Array(Set(errors)).sorted().joined(separator: "; "))
    }
    guard let issuedRaw = authorization["issued_at"] as? String,
      let expiresRaw = authorization["expires_at"] as? String,
      let issued = try? HarnessRuntime.parseTimestamp(issuedRaw),
      let expires = try? HarnessRuntime.parseTimestamp(expiresRaw), issued <= recordedAt,
      recordedAt < expires
    else { throw InitializeError("ledger approval time is outside authorization bounds") }
    guard let repository = authorization["repository"] as? [String: Any] else {
      throw InitializeError("approved authorization is invalid: repository missing")
    }
    let payload: [String: Any] = [
      "approval_id": authorization["authorization_id"]!, "kind": "run_authorization",
      "actor": authorization["actor"]!, "decision": "approved",
      "scope":
        "run:\(authorization["run_id"] as! String):\(authorization["delivery_target"] as! String)",
      "authorization_hash": Authorization.authorizationHash(authorization),
      "delivery_target": authorization["delivery_target"]!,
      "selected_writer": authorization["selected_writer"]!,
      "contract_schema_id": authorization["contract_schema_id"]!,
      "contract_schema_sha256": authorization["contract_schema_sha256"]!,
      "health_profile": authorization["health_profile"]!,
      "health_attestation": authorization["health_attestation"]!,
      "local_requirements": authorization["local_requirements"] ?? NSNull(),
      "spec_kit": authorization["spec_kit"] ?? NSNull(),
      "resource_plan": authorization["resource_plan"]!,
      "repository_fingerprint": repository["fingerprint"]!,
      "repository_base_sha": repository["base_sha"]!,
      "allowed_paths": authorization["allowed_paths"]!,
      "acceptance_ids": authorization["acceptance_ids"]!, "issued_at": authorization["issued_at"]!,
      "expires_at": authorization["expires_at"]!, "action_grants": authorization["action_grants"]!,
    ]
    return [
      "schema_version": "1.0.0", "run_id": authorization["run_id"]!, "sequence": 1,
      "recorded_at": HarnessRuntime.timestamp(recordedAt), "record_type": "approval",
      "payload": payload,
    ]
  }

  private static func readLedger(_ path: URL) throws -> [[String: Any]] {
    let content = try String(contentsOf: path, encoding: .utf8)
    return try content.split(whereSeparator: \.isNewline).map { line in
      guard let data = line.data(using: .utf8),
        let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw InitializeError("existing ledger cannot be adopted") }
      return record
    }
  }

  public static func initialize(
    authorizationPath: URL, ledgerPath: URL, runRoot: URL, harnessPath: URL, coordinatorState: URL,
    recordedAt: Date = Date(), context: RuntimeContext
  ) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: runRoot.path) else {
      throw InitializeError("run root must already exist")
    }
    let canonicalRoot = runRoot.resolvingSymlinksInPath().standardizedFileURL
    guard !isSymlink(runRoot),
      (try? canonicalRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else { throw InitializeError("run root must be a non-symlink directory") }
    let harness: [String: Any]
    do {
      harness = try ResourceCoordinator.loadTrustedHarness(
        harnessPath: harnessPath, context: context)
      _ = try ResourceCoordinator.validateTrustedBinding(
        statePath: coordinatorState, binding: harness["resource_coordinator"] as! [String: Any],
        context: context)
    } catch let error as ResourceCoordinatorError {
      throw InitializeError("trusted harness is invalid: \(error.code)")
    }
    for (candidate, label) in [
      (harnessPath, "harness"), (authorizationPath, "authorization"),
      (URL(fileURLWithPath: harness["private_policy_overlay"] as? String ?? ""), "private policy"),
    ] {
      guard candidate.path.hasPrefix("/"), !isSymlink(candidate),
        candidate.deletingLastPathComponent().resolvingSymlinksInPath() == canonicalRoot
      else {
        throw InitializeError(
          "\(label) must be a non-symlink file directly under the private run root")
      }
    }
    guard
      authorizationPath.resolvingSymlinksInPath()
        == URL(fileURLWithPath: harness["run_authorization"] as! String).resolvingSymlinksInPath()
    else { throw InitializeError("authorization drifted from the trusted harness") }
    guard ledgerPath.path.hasPrefix("/"),
      ledgerPath.deletingLastPathComponent().resolvingSymlinksInPath() == canonicalRoot
    else { throw InitializeError("ledger must be directly under the private run root") }
    let harnessLedger = URL(fileURLWithPath: harness["run_ledger"] as? String ?? "")
    guard harnessLedger.path.hasPrefix("/"),
      harnessLedger.deletingLastPathComponent().resolvingSymlinksInPath() == canonicalRoot,
      harnessLedger.standardizedFileURL == ledgerPath.standardizedFileURL
    else { throw InitializeError("ledger drifted from the trusted harness") }
    guard !isSymlink(ledgerPath) else { throw InitializeError("ledger must not be a symlink") }
    let authorization = try loadObject(authorizationPath, label: "authorization")
    let expected = try approvalRecord(
      authorization: authorization, recordedAt: recordedAt, context: context)
    let ledgerSchema = try loadObject(
      context.harnessRoot.appendingPathComponent("contracts/schemas/ledger-record.schema.json"),
      label: "installed ledger schema")
    let contractErrors =
      Authorization.schemaErrors(instance: expected, schema: ledgerSchema)
      + Authorization.standaloneLedgerLifecycleErrors([expected], context: context)
    guard contractErrors.isEmpty else {
      throw InitializeError(
        "initial ledger record failed installed contracts: "
          + Array(Set(contractErrors)).sorted().joined(separator: "; "))
    }
    var record = expected
    var created = false
    if FileManager.default.fileExists(atPath: ledgerPath.path) {
      var st = Darwin.stat()
      guard lstat(ledgerPath.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
        (st.st_mode & 0o077) == 0
      else { throw InitializeError("existing ledger identity or permissions are unsafe") }
      let records = try readLedger(ledgerPath)
      guard records.count == 1, let time = records[0]["recorded_at"] as? String,
        let date = try? HarnessRuntime.parseTimestamp(time),
        NSDictionary(dictionary: records[0]).isEqual(
          to: try approvalRecord(authorization: authorization, recordedAt: date, context: context))
      else { throw InitializeError("existing ledger approval drifted") }
      record = records[0]
    } else {
      let fd = open(ledgerPath.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
      guard fd >= 0 else { throw InitializeError("ledger could not be created") }
      created = true
      do {
        let line = try HarnessRuntime.canonicalJSON(record, ensureASCII: true) + Data([0x0a])
        try line.withUnsafeBytes { buffer in
          var offset = 0
          while offset < buffer.count {
            let count = Darwin.write(
              fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw InitializeError("ledger could not be created") }
            offset += count
          }
        }
        guard fsync(fd) == 0 else { throw InitializeError("ledger could not be created") }
        close(fd)
      } catch {
        close(fd)
        unlink(ledgerPath.path)
        throw error
      }
      let dfd = open(canonicalRoot.path, O_RDONLY)
      if dfd >= 0 {
        _ = fsync(dfd)
        close(dfd)
      }
    }
    let authority: [String: Any]
    do {
      (_, authority) = try ResourceCoordinator.loadExistingRunAuthority(
        authorizationPath: authorizationPath, harnessPath: harnessPath, harness: harness,
        runID: authorization["run_id"] as! String, context: context)
    } catch let error as ResourceCoordinatorError {
      throw InitializeError("coordinator refused run registration: \(error.code)")
    }
    let registration: [String: Any]
    do {
      registration = try ResourceCoordinator.registerRunAuthority(
        statePath: coordinatorState, runID: authorization["run_id"] as! String,
        runAuthority: authority,
        now: try HarnessRuntime.parseTimestamp(record["recorded_at"] as! String))
    } catch let error as ResourceCoordinatorError {
      throw InitializeError("coordinator refused run registration: \(error.code)")
    }
    return [
      "ledger": ledgerPath.resolvingSymlinksInPath().path, "run_id": authorization["run_id"]!,
      "sequence": 1,
      "authorization_hash": (record["payload"] as! [String: Any])["authorization_hash"]!,
      "created": created, "registered": registration["registered"]!,
      "ledger_identity_sha256": registration["ledger_identity_sha256"]!,
    ]
  }

  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    var options: [String: String] = [:]
    var index = 0
    let allowed: Set<String> = [
      "--authorization", "--ledger", "--run-root", "--harness", "--coordinator-state",
    ]
    while index < arguments.count {
      let key = arguments[index]
      guard allowed.contains(key), options[key] == nil, index + 1 < arguments.count else {
        throw InitializeError("invalid arguments")
      }
      options[key] = arguments[index + 1]
      index += 2
    }
    guard let authorization = options["--authorization"], let ledger = options["--ledger"],
      let root = options["--run-root"], let harness = options["--harness"],
      let state = options["--coordinator-state"]
    else { throw InitializeError("invalid arguments") }
    do {
      var response = try initialize(
        authorizationPath: URL(fileURLWithPath: authorization),
        ledgerPath: URL(fileURLWithPath: ledger), runRoot: URL(fileURLWithPath: root),
        harnessPath: URL(fileURLWithPath: harness), coordinatorState: URL(fileURLWithPath: state),
        context: context)
      response["status"] = "ok"
      FileHandle.standardOutput.write(
        try HarnessRuntime.canonicalJSON(response, ensureASCII: true) + Data([0x0a]))
      return 0
    } catch {
      let response: [String: Any] = ["status": "blocked", "reason": String(describing: error)]
      FileHandle.standardOutput.write(
        try HarnessRuntime.canonicalJSON(response, ensureASCII: true) + Data([0x0a]))
      return 2
    }
  }
}
