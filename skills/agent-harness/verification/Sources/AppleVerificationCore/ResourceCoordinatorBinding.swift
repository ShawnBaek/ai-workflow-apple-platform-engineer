import Darwin
import Foundation

/// Runtime identity and the trusted bindings a protected command checks before it touches state:
/// the running executable, the installed source bundle, the run ledger and the private harness.
extension ResourceCoordinator {
  /// The binary this process runs, in the form `runtime-identity` reports: absolute, standardized
  /// and with symlinks resolved. It comes from the loader's record of the executed image, never
  /// from `argv[0]`, which a PATH lookup leaves as a bare name and a caller can set freely. Every
  /// executable-identity check uses this one resolution.
  public static func runningExecutableURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
      throw ResourceCoordinatorError(
        "untrusted_binding", "the running executable cannot be located")
    }
    let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  }

  public static func portableDocumentSHA256(_ document: [String: Any]) throws -> String {
    var portable = document
    portable.removeValue(forKey: "$schema")
    return try digest(portable)
  }

  public static func sourceBundleSHA256(skillRoot: URL) throws -> String {
    let fm = FileManager.default
    var files: [URL] = []
    for directory in [
      skillRoot.appendingPathComponent("contracts"),
      skillRoot.appendingPathComponent("verification/Sources"),
    ] {
      if let enumerator = fm.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      {
        for case let url as URL in enumerator {
          guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          else {
            throw ResourceCoordinatorError(
              "untrusted_binding", "installed contract bundle cannot be enumerated")
          }
          if values.isRegularFile == true, values.isSymbolicLink != true,
            ["json", "swift"].contains(url.pathExtension)
          {
            files.append(url)
          }
        }
      }
    }
    guard !files.isEmpty, let root = HarnessRuntime.physicalPathComponents(skillRoot) else {
      throw ResourceCoordinatorError("untrusted_binding", "installed contract bundle is empty")
    }
    // Enumeration reports physical paths whatever alias spelled the root (`/tmp`, a linked
    // checkout), so names come from physical components and never carry a location.
    let named = try files.map { file in
      guard let relative = HarnessRuntime.relativePath(of: file, belowPhysicalRoot: root) else {
        throw ResourceCoordinatorError(
          "untrusted_binding", "installed contract bundle file is outside its root")
      }
      return (relative, file)
    }
    var bytes = Data()
    for (relative, file) in named.sorted(by: { $0.0 < $1.0 }) {
      let name = Data(relative.utf8)
      let count = UInt32(name.count).bigEndian
      withUnsafeBytes(of: count) { bytes.append(contentsOf: $0) }
      bytes.append(name)
      guard let hash = Data(hex: try sha256File(file, failure: "untrusted_binding")) else {
        throw ResourceCoordinatorError("untrusted_binding")
      }
      bytes.append(hash)
    }
    return "sha256:" + HarnessRuntime.sha256(bytes)
  }

  /// A bound file that cannot be opened or read cannot prove its binding; report that instead
  /// of letting the I/O error surface as a malformed request.
  static func sha256File(_ url: URL, failure code: String) throws -> String {
    do { return try HarnessRuntime.sha256File(url) } catch {
      throw ResourceCoordinatorError(code, "\(url.lastPathComponent) cannot be hashed")
    }
  }

  @available(*, deprecated, message: "Use sourceBundleSHA256(skillRoot:)")
  public static func contractBundleSHA256(skillRoot: URL) throws -> String {
    try sourceBundleSHA256(skillRoot: skillRoot)
  }

  public static func ledgerBinding(
    _ ledgerPath: URL, descriptor: Int32? = nil, expectedRunID: String? = nil,
    expectedAuthorizationHash: String? = nil
  ) throws -> [String: Any] {
    guard spelledAbsolute(ledgerPath), !isSymlink(ledgerPath) else {
      throw ResourceCoordinatorError("untrusted_ledger", "ledger path is unsafe")
    }
    let openedHere = descriptor == nil
    let fd = descriptor ?? open(ledgerPath.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else {
      throw ResourceCoordinatorError("untrusted_ledger", "ledger cannot be opened")
    }
    defer { if openedHere { close(fd) } }
    var opened = Darwin.stat()
    var named = Darwin.stat()
    guard fstat(fd, &opened) == 0, lstat(ledgerPath.path, &named) == 0,
      (opened.st_mode & S_IFMT) == S_IFREG, (named.st_mode & S_IFMT) == S_IFREG,
      opened.st_nlink == 1, named.st_nlink == 1, opened.st_dev == named.st_dev,
      opened.st_ino == named.st_ino
    else { throw ResourceCoordinatorError("untrusted_ledger", "ledger inode drifted") }
    var buffer = [UInt8](repeating: 0, count: min(1_048_576, max(1, Int(opened.st_size))))
    let readCount = pread(fd, &buffer, buffer.count, 0)
    guard readCount > 0 else {
      throw ResourceCoordinatorError("untrusted_ledger", "ledger approval record is unavailable")
    }
    let prefix = Data(buffer.prefix(readCount))
    let newline = prefix.firstIndex(of: 0x0a)
    guard let end = newline ?? (opened.st_size <= readCount ? prefix.endIndex : nil),
      end > prefix.startIndex,
      let approval = try? JSONSerialization.jsonObject(with: prefix[..<end]) as? [String: Any],
      let payload = approval["payload"] as? [String: Any],
      approval["record_type"] as? String == "approval", integer(approval["sequence"]) == 1,
      payload["kind"] as? String == "run_authorization",
      payload["decision"] as? String == "approved",
      expectedRunID == nil || approval["run_id"] as? String == expectedRunID,
      expectedAuthorizationHash == nil
        || payload["authorization_hash"] as? String == expectedAuthorizationHash
    else { throw ResourceCoordinatorError("untrusted_ledger", "ledger approval binding drifted") }
    let canonical = ledgerPath.resolvingSymlinksInPath().standardizedFileURL
    let identity: [String: Any] = [
      "path": canonical.path, "device": NSNumber(value: opened.st_dev),
      "inode": NSNumber(value: opened.st_ino),
    ]
    return [
      "ledger_path": canonical.path, "ledger_identity_sha256": try digest(identity),
      "ledger_approval_sha256": try digest(approval),
    ]
  }

  public static func loadTrustedHarness(harnessPath: URL, context: RuntimeContext) throws
    -> [String: Any]
  {
    guard spelledAbsolute(harnessPath), !isSymlink(harnessPath), isRegular(harnessPath) else {
      throw ResourceCoordinatorError(
        "untrusted_binding", "harness must be an absolute regular file")
    }
    let document: [String: Any]
    do { document = try HarnessRuntime.object(harnessPath) } catch {
      throw ResourceCoordinatorError("untrusted_binding", "harness cannot be read")
    }
    let schemaURL = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/harness.schema.json")
    do {
      let schema = try HarnessRuntime.object(schemaURL)
      let errors = JSONSchemaValidator.errors(
        instance: document, schema: schema, path: "$", root: nil)
      if !errors.isEmpty {
        throw ResourceCoordinatorError(
          "untrusted_binding", Array(Set(errors)).sorted().joined(separator: "; "))
      }
    } catch let error as ResourceCoordinatorError { throw error } catch {
      throw ResourceCoordinatorError("untrusted_binding", "harness schema is unavailable")
    }
    let mode = document["mode"] as? String
    let writer = document["selected_writer"] as? String
    let reviewer = document["reviewer"] is NSNull ? nil : document["reviewer"] as? String
    let roles =
      (mode == "codex" && writer == "codex" && reviewer == nil)
      || (mode == "claude" && writer == "claude" && reviewer == nil)
      || (mode == "collaborative"
        && ((writer == "codex" && reviewer == "claude")
          || (writer == "claude" && reviewer == "codex")))
    guard roles, document["resource_coordinator"] is [String: Any] else {
      throw ResourceCoordinatorError(
        "untrusted_binding", "harness writer and reviewer roles are invalid")
    }
    for field in [
      "authoritative_root", "private_policy_overlay", "run_authorization", "run_ledger",
    ] {
      guard let path = document[field] as? String, path.hasPrefix("/") else {
        throw ResourceCoordinatorError(
          "untrusted_binding", "harness \(field) must be an absolute path")
      }
    }
    if !(document["xcode_container"] is NSNull), let path = document["xcode_container"] as? String,
      !path.hasPrefix("/")
    {
      throw ResourceCoordinatorError(
        "untrusted_binding", "harness xcode_container must be an absolute path")
    }
    return document
  }

  public static func loadHarnessBinding(harnessPath: URL, context: RuntimeContext) throws
    -> [String: Any]
  {
    try loadTrustedHarness(harnessPath: harnessPath, context: context)["resource_coordinator"]
      as! [String: Any]
  }

  public static func validateTrustedBinding(
    statePath: URL, binding: [String: Any], context: RuntimeContext
  ) throws -> [String: Any] {
    guard
      Set(binding.keys) == [
        "runtime_kind", "runtime_contract", "state_path", "coordinator_instance_id",
        "executable_sha256", "source_bundle_sha256",
      ], binding["runtime_kind"] as? String == runtimeKind,
      binding["runtime_contract"] as? String == runtimeContract,
      let expected = binding["state_path"] as? String, expected.hasPrefix("/")
    else {
      throw ResourceCoordinatorError(
        "untrusted_binding", "binding fields are incomplete or legacy runtime-bound")
    }
    let path = try self.statePath(statePath)
    let expectedURL = URL(fileURLWithPath: expected)
    guard !isSymlink(path), !isSymlink(expectedURL),
      path.resolvingSymlinksInPath() == expectedURL.resolvingSymlinksInPath()
    else { throw ResourceCoordinatorError("untrusted_binding", "state path drifted") }
    let executable = try runningExecutableURL()
    guard FileManager.default.fileExists(atPath: executable.path),
      binding["executable_sha256"] as? String == "sha256:"
        + (try sha256File(executable, failure: "untrusted_binding"))
    else {
      throw ResourceCoordinatorError("untrusted_binding", "coordinator executable hash drifted")
    }
    guard
      binding["source_bundle_sha256"] as? String
        == (try sourceBundleSHA256(skillRoot: context.harnessRoot))
    else {
      throw ResourceCoordinatorError("untrusted_binding", "installed source bundle hash drifted")
    }
    let live = try status(statePath: path)
    guard
      live["coordinator_instance_id"] as? String == binding["coordinator_instance_id"] as? String
    else { throw ResourceCoordinatorError("untrusted_binding", "coordinator instance drifted") }
    return live
  }
}

extension Data {
  fileprivate init?(hex: String) {
    let hex = hex.hasPrefix("sha256:") ? String(hex.dropFirst(7)) : hex
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    self = data
  }
}
