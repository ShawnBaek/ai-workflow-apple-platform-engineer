import CryptoKit
import Darwin
import Foundation

public enum Authorization {
  public static let allowedActions: Set<String> = [
    "git.commit", "git.push", "github.issue.create", "github.issue.update", "github.issue.comment",
    "github.project.update", "github.pr.create", "github.pr.update", "github.pr.comment",
    "github.evidence.publish", "github.checks.wait", "apple.testflight.upload",
    "apple.testflight.processing.wait", "apple.testflight.distribute_internal",
    "apple.testflight.readback",
  ]
  public static let forbiddenActions: Set<String> = [
    "git.force_push", "github.auto_merge", "github.ruleset_change", "apple.app_review_submit",
    "apple.production_release", "apple.signing_resource_mutation", "credential.scope_expansion",
    "environment.destructive_cleanup",
  ]
  public static let requestFields: Set<String> = [
    "run_id", "authorization_id", "authorization_hash", "delivery_target", "system", "action",
    "target",
    "grant_id", "idempotency_key", "repository", "spec_snapshot_sha256", "paths", "apple",
    "lease_id",
    "lease_owner", "lease_resource", "lease_resource_key", "resource_descriptor",
    "coordinator_receipt",
    "operation", "operation_input", "constraint_sha256", "phase", "spec_checkpoint_sha256",
    "apple_observation_sha256", "writer_actor", "health_report_sha256",
  ]
  public static let coordinatorReceiptFields: Set<String> = [
    "coordinator_instance_id", "receipt_id", "lease_id", "owner_run_id", "owner_actor", "resource",
    "resource_key", "descriptor_sha256", "fencing_token", "acquired_at", "expires_at",
  ]
  public static let minimumDispatchWindow: TimeInterval = 30
  public static let maximumDispatchWindow: TimeInterval = 60
  /// The longest approval window (`expires_at - issued_at`) one run authorization may carry.
  public static let maximumAuthorizationLifetime: TimeInterval = 24 * 60 * 60
  /// Inclusive bounds of each authorization limit; the approved schema declares the same values.
  public static let limitBounds: [String: ClosedRange<Int>] = [
    "max_implementation_attempts": 1...10, "max_review_cycles": 1...10,
    "max_transient_retries": 0...10, "active_wall_minutes": 1...1_440,
    "async_wait_minutes": 1...1_440,
  ]
  public static let runtimeContract = "apple-verification-core.authorization.v1"

  public static func schemaErrors(
    instance: Any, schema: [String: Any], path: String = "$", root: [String: Any]? = nil
  ) -> [String] {
    JSONSchemaValidator.errors(instance: instance, schema: schema, path: path, root: root)
  }

  public static func installedAuthorizationSchemaBinding(context: RuntimeContext) throws -> (
    id: String, sha256: String
  ) {
    guard let url = installedSchemaURL(context), let schema = try? HarnessRuntime.object(url),
      let id = schema["$id"] as? String, !id.isEmpty
    else {
      throw VerificationError.invalid("installed authorization schema lacks a stable ID")
    }
    return (id, "sha256:" + (try HarnessRuntime.sha256File(url)))
  }

  public static func canonicalSHA256(_ value: Any) throws -> String {
    HarnessRuntime.sha256(try HarnessRuntime.canonicalJSON(value))
  }

  static func readStablePrivateData(_ path: URL, root: URL, maxBytes: Int = 64 * 1_024 * 1_024)
    throws -> Data
  {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    var suppliedRootInfo = stat()
    var rootInfo = stat()
    guard path.path.hasPrefix("/"), lstat(root.standardizedFileURL.path, &suppliedRootInfo) == 0,
      suppliedRootInfo.st_mode & S_IFMT == S_IFDIR,
      lstat(canonicalRoot.path, &rootInfo) == 0,
      rootInfo.st_mode & S_IFMT == S_IFDIR,
      path.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        == canonicalRoot
    else {
      throw VerificationError.invalid("private input must be directly under a non-symlink run root")
    }
    var namedBefore = stat()
    guard lstat(path.path, &namedBefore) == 0, namedBefore.st_mode & S_IFMT == S_IFREG,
      namedBefore.st_nlink == 1
    else {
      throw VerificationError.invalid("private input must be a single-link regular file")
    }
    let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw VerificationError.invalid("private input cannot be opened safely")
    }
    defer { close(descriptor) }
    var openedBefore = stat()
    guard fstat(descriptor, &openedBefore) == 0, openedBefore.st_mode & S_IFMT == S_IFREG,
      openedBefore.st_nlink == 1,
      sameFileIdentity(namedBefore, openedBefore)
    else {
      throw VerificationError.invalid("private input inode changed before read")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        guard data.count + count <= maxBytes else {
          throw VerificationError.invalid("private input exceeds the bounded read limit")
        }
        data.append(contentsOf: buffer.prefix(count))
        continue
      }
      if count < 0 && errno == EINTR { continue }
      guard count == 0 else { throw VerificationError.invalid("private input read failed") }
      break
    }
    var openedAfter = stat()
    var namedAfter = stat()
    guard fstat(descriptor, &openedAfter) == 0, lstat(path.path, &namedAfter) == 0,
      openedAfter.st_mode & S_IFMT == S_IFREG, openedAfter.st_nlink == 1, namedAfter.st_nlink == 1,
      sameFileIdentity(openedBefore, openedAfter), sameFileIdentity(openedAfter, namedAfter),
      stableFileMetadata(openedBefore, openedAfter)
    else {
      throw VerificationError.invalid("private input changed while it was read")
    }
    return data
  }

  static func loadStablePrivateJSON(_ path: URL, root: URL, maxBytes: Int = 64 * 1_024 * 1_024)
    throws -> Any
  {
    do {
      return try JSONSerialization.jsonObject(
        with: readStablePrivateData(path, root: root, maxBytes: maxBytes))
    } catch let error as VerificationError { throw error } catch {
      throw VerificationError.invalid("private input is not valid JSON")
    }
  }

  private static func sameFileIdentity(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
  }

  private static func stableFileMetadata(_ left: stat, _ right: stat) -> Bool {
    left.st_size == right.st_size && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
      && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
      && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
      && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
  }

  public static func authorizationHash(_ envelope: [String: Any]) -> String {
    var portable = envelope
    portable.removeValue(forKey: "$schema")
    guard let digest = try? canonicalSHA256(portable) else {
      return "invalid:non-canonical-authorization"
    }
    return "sha256:" + digest
  }

  public static func runtimeBinding(executable: URL, sourceBundle: URL? = nil) throws -> [String:
    Any]
  {
    var binding: [String: Any] = [
      "runtime_kind": "swift", "runtime_contract": runtimeContract,
      "executable_path": executable.resolvingSymlinksInPath().path,
      "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
    ]
    if let sourceBundle { binding["source_bundle_sha256"] = try sourceBundleSHA256(sourceBundle) }
    return binding
  }

  public static func validateRuntimeBinding(
    _ binding: Any, executable: URL, sourceBundle: URL? = nil
  ) -> [String] {
    guard let binding = binding as? [String: Any] else {
      return ["authorization runtime binding is missing"]
    }
    if binding["script_sha256"] != nil || binding["runtime_kind"] as? String == "python" {
      return [
        "legacy Python authorization runtime binding is unsupported; rematerialize authorization state at the Swift v1 boundary"
      ]
    }
    do {
      let expected = try runtimeBinding(executable: executable, sourceBundle: sourceBundle)
      guard same(binding, expected) else {
        return ["Swift authorization runtime binding drifted"]
      }
      return []
    } catch { return ["Swift authorization runtime identity is unavailable"] }
  }

  public static func patchIdentityV1(_ manifest: Any) throws -> String {
    guard let manifest = manifest as? [String: Any],
      Set(manifest.keys) == ["version", "base_sha", "records"],
      manifest["version"] as? String == "patch_identity_v1",
      regex(manifest["base_sha"], #"^[0-9a-f]{40,64}$"#),
      let records = manifest["records"] as? [[String: Any]], !records.isEmpty
    else {
      throw VerificationError.invalid(
        "patch manifest fields, version, base SHA, or records are invalid")
    }
    var paths: [String] = []
    for record in records {
      guard Set(record.keys) == ["path", "mode", "state", "content_sha256"],
        let path = record["path"] as? String, safeRelativePath(path),
        let mode = record["mode"] as? String,
        ["100644", "100755", "120000", "160000"].contains(mode),
        let state = record["state"] as? String,
        ["added", "modified", "deleted", "symlink"].contains(state)
      else {
        throw VerificationError.invalid("patch manifest record is invalid")
      }
      if state == "deleted" {
        guard record["content_sha256"] as? String == "deleted" else {
          throw VerificationError.invalid("deleted patch record lacks its deletion marker")
        }
      } else if !regex(record["content_sha256"], #"^sha256:[0-9a-f]{64}$"#) {
        throw VerificationError.invalid("patch manifest content digest is invalid")
      }
      paths.append(path)
    }
    guard Set(paths).count == paths.count, paths == paths.sorted(by: utf8Less) else {
      throw VerificationError.invalid("patch manifest paths must be unique and UTF-8 sorted")
    }
    return "sha256:"
      + HarnessRuntime.sha256(try HarnessRuntime.canonicalJSON(manifest, ensureASCII: false))
  }

  public static func sanitizeRemote(_ remote: String) -> String {
    guard var components = URLComponents(string: remote), components.scheme != nil,
      components.host != nil
    else { return remote }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? remote
  }

  public static func normalizeGitHubRemote(_ remote: String) throws -> String {
    try ProjectResolver.normalizeGitHubRemote(remote)
  }

  public static func repositoryFingerprint(_ remote: String) throws -> String {
    try ProjectResolver.remoteFingerprint(remote)
  }

  public static func expectedLeaseResource(_ action: Any?) -> String? {
    guard let action = action as? String else { return nil }
    if action == "git.commit" { return "source_checkout_writer" }
    if action == "git.push" || action.hasPrefix("github.") { return "github_external_mutation" }
    if action.hasPrefix("apple.") { return "signing_or_app_store_connect" }
    return nil
  }

  public static func canonicalResourceDescriptor(_ envelope: [String: Any], action: String) throws
    -> [String: Any]
  {
    let repository = envelope["repository"] as? [String: Any] ?? [:]
    if action == "git.commit" {
      return [
        "identity_version": "github_remote_v2",
        "repository_fingerprint": text(repository["fingerprint"]),
      ]
    }
    if action == "git.push" || action.hasPrefix("github.") {
      return [
        "repository_fingerprint": text(repository["fingerprint"]),
        "remote_repository": boundGitHubSlug(envelope) ?? "<invalid-repository>",
      ]
    }
    if action.hasPrefix("apple.") {
      let apple = envelope["apple"] as? [String: Any] ?? [:]
      return [
        "account_guard": text(apple["account_guard_ref"]),
        "app_or_bundle_scope": text(apple["app_id"] ?? apple["bundle_id"]),
      ]
    }
    throw VerificationError.invalid("cannot derive a resource key for action '\(action)'")
  }

  public static func canonicalLeaseResourceKey(_ envelope: [String: Any], action: String) throws
    -> String
  {
    guard let resource = expectedLeaseResource(action) else {
      throw VerificationError.invalid("cannot derive resource")
    }
    let descriptor = try canonicalResourceDescriptor(envelope, action: action)
    return try ResourceCoordinator.canonicalResourceKey(resource: resource, descriptor: descriptor)
  }

  public static func validatePolicyOverlay(_ envelope: [String: Any], overlay: Any?) -> [String] {
    var errors = objectShape(
      overlay, required: ["schema_version", "decision", "github", "apple"],
      allowed: ["$schema", "schema_version", "decision", "github", "apple"],
      label: "private policy overlay")
    guard let overlay = overlay as? [String: Any] else { return errors }
    if overlay["schema_version"] as? String != "1.0.0"
      || overlay["decision"] as? String != "approved"
    {
      errors.append("private policy overlay is not approved")
    }
    let local = envelope["delivery_target"] as? String == "local_verified"
    let github = overlay["github"] as? [String: Any]
    if local {
      if !(overlay["github"] is NSNull) && overlay["github"] != nil {
        errors.append("local verification policy cannot authorize GitHub access")
      }
      if !(overlay["apple"] is NSNull) && overlay["apple"] != nil {
        errors.append("local verification policy cannot authorize Apple access")
      }
    } else if github == nil || Set(github!.keys) != ["owner"]
      || (github!["owner"] as? String)?.isEmpty != false
    {
      errors.append("private policy overlay must bind one GitHub owner")
    } else if github!["owner"] as? String != (envelope["github"] as? [String: Any])?["owner"]
      as? String
    {
      errors.append("GitHub owner differs from the private policy boundary")
    }
    if let apple = envelope["apple"] as? [String: Any] {
      guard let trusted = overlay["apple"] as? [String: Any],
        Set(trusted.keys) == ["account_guard_ref", "team_id"],
        same(trusted["account_guard_ref"], apple["account_guard_ref"]),
        same(trusted["team_id"], apple["team_id"])
      else {
        errors.append("Apple account or team differs from the private policy boundary")
        return Array(Set(errors)).sorted()
      }
    }
    return Array(Set(errors)).sorted()
  }

  private static func sourceBundleSHA256(_ root: URL) throws -> String {
    // One source identity for both safety modules. Exclude build products,
    // tests, caches, and logs; include executable Swift sources and contracts.
    try ResourceCoordinator.sourceBundleSHA256(skillRoot: root)
  }

  static func installedSchemaURL(_ context: RuntimeContext) -> URL? {
    let direct = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    if FileManager.default.fileExists(atPath: direct.path) { return direct }
    let nested = context.harnessRoot.appendingPathComponent(
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json")
    return FileManager.default.fileExists(atPath: nested.path) ? nested : nil
  }
  static func boundGitHubSlug(_ envelope: [String: Any]) -> String? {
    guard let github = envelope["github"] as? [String: Any], let owner = github["owner"] as? String,
      let repository = github["repository"] as? String
    else { return nil }
    return try? normalizeGitHubRemote("https://github.com/\(owner)/\(repository)")
      .replacingOccurrences(of: "github.com/", with: "")
  }
  static func validProducedTarget(kind: Any?, target: Any?, repository: String?) -> Bool {
    guard let kind = kind as? String, let target = target as? String, let repository,
      !repository.isEmpty
    else { return false }
    let suffix = kind == "github_issue" ? "issue" : kind == "github_pr" ? "pr" : nil
    guard let suffix else { return false }
    return target.range(
      of: "^" + NSRegularExpression.escapedPattern(for: repository) + ":\(suffix):[1-9][0-9]*$",
      options: .regularExpression) != nil
  }

  private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}
