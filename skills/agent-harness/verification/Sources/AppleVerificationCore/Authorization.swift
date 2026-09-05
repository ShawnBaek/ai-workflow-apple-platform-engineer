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
  public static let runtimeContract = "apple-verification-core.authorization.v1"

  private static let topLevelFields: Set<String> = [
    "schema_version", "contract_schema_id", "contract_schema_sha256", "run_id", "authorization_id",
    "decision",
    "actor", "selected_writer", "issued_at", "expires_at", "delivery_target", "health_profile",
    "resource_plan",
    "health_attestation", "repository", "spec_kit", "acceptance_ids", "allowed_paths", "limits",
    "github", "apple",
    "action_grants", "forbidden_actions", "auto_merge", "app_review_submit",
    "credential_scope_expansion",
    "signing_resource_mutation", "destructive_cleanup",
  ]
  private static let operationAllowlist: [String: Set<String>] = [
    "git.commit": ["commit_reviewed_patch"], "git.push": ["push_reviewed_commit"],
    "github.issue.create": ["ensure_feature_issue"],
    "github.issue.update": [
      "transition_issue_ready", "transition_issue_in_progress", "transition_issue_in_review",
    ],
    "github.issue.comment": ["publish_exact_issue_comment"],
    "github.project.update": [
      "transition_project_ready", "transition_project_in_progress", "transition_project_in_review",
    ],
    "github.pr.create": ["create_pull_request"], "github.pr.update": ["update_exact_pull_request"],
    "github.pr.comment": ["publish_exact_pr_comment"],
    "github.evidence.publish": [
      "publish_pr_evidence", "publish_testflight_upload_evidence",
      "publish_testflight_distribution_evidence",
    ],
    "github.checks.wait": ["wait_required_checks"],
    "apple.testflight.upload": ["upload_verified_archive"],
    "apple.testflight.processing.wait": ["wait_bounded_processing"],
    "apple.testflight.distribute_internal": ["distribute_named_internal_group"],
    "apple.testflight.readback": ["verify_uploaded_build", "verify_internal_distribution"],
  ]

  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    try CheckAuthorizationCommand.run(arguments: arguments, context: context)
  }

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
      guard jsonEqual(binding, expected) else {
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
        "repository_fingerprint": string(repository["fingerprint"]),
      ]
    }
    if action == "git.push" || action.hasPrefix("github.") {
      return [
        "repository_fingerprint": string(repository["fingerprint"]),
        "remote_repository": boundGitHubSlug(envelope) ?? "<invalid-repository>",
      ]
    }
    if action.hasPrefix("apple.") {
      let apple = envelope["apple"] as? [String: Any] ?? [:]
      return [
        "account_guard": string(apple["account_guard_ref"]),
        "app_or_bundle_scope": string(apple["app_id"] ?? apple["bundle_id"]),
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
        jsonEqual(trusted["account_guard_ref"], apple["account_guard_ref"]),
        jsonEqual(trusted["team_id"], apple["team_id"])
      else {
        errors.append("Apple account or team differs from the private policy boundary")
        return Array(Set(errors)).sorted()
      }
    }
    return Array(Set(errors)).sorted()
  }

  public static func validateAuthorization(_ envelope: [String: Any], context: RuntimeContext)
    -> [String]
  {
    let local = envelope["delivery_target"] as? String == "local_verified"
    let requiredFields = local ? topLevelFields.union(["local_requirements"]) : topLevelFields
    var errors = objectShape(
      envelope, required: requiredFields,
      allowed: topLevelFields.union(["$schema", "local_requirements"]), label: "authorization")
    if let schemaURL = installedSchemaURL(context),
      let schema = try? HarnessRuntime.object(schemaURL)
    {
      errors += schemaErrors(instance: envelope, schema: schema)
      if envelope["contract_schema_id"] as? String != schema["$id"] as? String {
        errors.append("approved authorization schema identity drifted")
      }
      if envelope["contract_schema_sha256"] as? String != "sha256:"
        + ((try? HarnessRuntime.sha256File(schemaURL)) ?? "")
      {
        errors.append("approved authorization schema content drifted")
      }
    } else {
      errors.append("installed approved authorization schema is unavailable")
    }
    if (envelope["$schema"] as? String)?.isEmpty != false {
      errors.append("authorization schema location must be a non-empty string")
    }
    if envelope["schema_version"] as? String != "1.0.0" {
      errors.append("unsupported authorization schema")
    }
    if envelope["decision"] as? String != "approved" {
      errors.append("authorization is not approved")
    }
    for field in ["run_id", "authorization_id", "actor"]
    where (envelope[field] as? String)?.isEmpty != false {
      errors.append("authorization \(field) must be a non-empty string")
    }
    let writer = envelope["selected_writer"] as? String
    if !["codex", "claude"].contains(writer ?? "") {
      errors.append("authorization selected_writer must be codex or claude")
    }
    let delivery = envelope["delivery_target"] as? String
    if !["local_verified", "pr_ready", "testflight_uploaded", "testflight_distributed"].contains(
      delivery ?? "")
    {
      errors.append("unsupported delivery target")
    }
    let healthProfile = envelope["health_profile"] as? String
    if ![
      "local_verified", "pr_ready", "runtime_ui", "testflight_uploaded", "testflight_distributed",
      "icon_upstream",
    ].contains(healthProfile ?? "") {
      errors.append("authorization health profile is invalid")
    }
    if delivery?.hasPrefix("testflight_") == true, healthProfile != delivery {
      errors.append("TestFlight authorization health profile must match its delivery target")
    }
    errors += validateHealthAttestation(envelope)
    errors += validateRepository(envelope)
    errors += validateSpecKit(envelope)
    errors += validateResourcePlan(envelope, context: context)
    guard uniqueNonemptyStrings(envelope["acceptance_ids"]) else {
      errors.append("authorization requires unique acceptance IDs")
      return Array(Set(errors)).sorted()
    }
    let paths = envelope["allowed_paths"] as? [String] ?? []
    if !uniqueNonemptyStrings(paths) {
      errors.append("authorization requires unique allowed paths")
    }
    if paths.contains(where: { !safeRelativePath($0) }) {
      errors.append("authorization allowed paths must be safe repository-relative paths")
    }
    let limits = envelope["limits"] as? [String: Any]
    let minimums = [
      "max_implementation_attempts": 1, "max_review_cycles": 1, "max_transient_retries": 0,
      "active_wall_minutes": 1, "async_wait_minutes": 1,
    ]
    errors += objectShape(
      limits, required: Set(minimums.keys), allowed: Set(minimums.keys), label: "limits")
    if limits == nil
      || minimums.contains(where: {
        int(limits?[$0.key]) == nil || int(limits?[$0.key])! < $0.value
      })
    {
      errors.append("authorization attempt and time limits are invalid")
    }
    if let issued = try? HarnessRuntime.parseTimestamp(string(envelope["issued_at"])),
      let expires = try? HarnessRuntime.parseTimestamp(string(envelope["expires_at"])),
      expires <= issued
    {
      errors.append("authorization expiry must be after issuance")
    } else if (try? HarnessRuntime.parseTimestamp(string(envelope["issued_at"]))) == nil
      || (try? HarnessRuntime.parseTimestamp(string(envelope["expires_at"]))) == nil
    {
      errors.append("authorization issue or expiry time is invalid or lacks timezone")
    }
    let github = envelope["github"] as? [String: Any]
    if delivery == "local_verified" {
      if !(envelope["github"] is NSNull) && envelope["github"] != nil {
        errors.append("local verification cannot bind GitHub authorization")
      }
      if !(envelope["apple"] is NSNull) && envelope["apple"] != nil {
        errors.append("local verification cannot bind Apple authorization")
      }
      let requirements = envelope["local_requirements"] as? [String: Any]
      errors += objectShape(
        requirements, required: ["review_required", "spec_kit_required"],
        allowed: ["review_required", "spec_kit_required"], label: "local verification requirements")
      if requirements?["review_required"] as? Bool == nil
        || requirements?["spec_kit_required"] as? Bool == nil
      {
        errors.append("local verification requirements must be booleans")
      }
      let requiresSpec = requirements?["spec_kit_required"] as? Bool == true
      let hasSpec = !(envelope["spec_kit"] is NSNull) && envelope["spec_kit"] != nil
      if requiresSpec != hasSpec {
        errors.append("local Spec Kit binding must match the accepted plan requirement")
      }
    } else {
      errors += objectShape(
        github, required: ["owner", "repository", "issue_number", "project"],
        allowed: ["owner", "repository", "issue_number", "project"], label: "GitHub authorization")
      if (github?["owner"] as? String)?.isEmpty != false
        || (github?["repository"] as? String)?.isEmpty != false
      {
        errors.append("authorization must bind the GitHub repository")
      }
    }
    let grants = envelope["action_grants"] as? [[String: Any]] ?? []
    if grants.isEmpty && delivery != "local_verified" {
      errors.append("authorization requires at least one action grant")
    }
    errors += validateGrants(envelope, grants: grants)
    if Set(envelope["forbidden_actions"] as? [String] ?? []) != forbiddenActions {
      errors.append("forbidden action boundary drifted")
    }
    for flag in [
      "auto_merge", "app_review_submit", "credential_scope_expansion", "signing_resource_mutation",
      "destructive_cleanup",
    ] where envelope[flag] as? Bool != false { errors.append("\(flag) must remain false") }
    return Array(Set(errors)).sorted()
  }

  public static func appleObservationStateSHA256(_ observation: [String: Any]) throws -> String {
    let fields = [
      "source", "guard_verified", "account_guard_ref", "team_id", "app_id", "bundle_id", "platform",
      "live_build", "internal_group_ids",
    ]
    return try canonicalSHA256(
      Dictionary(uniqueKeysWithValues: fields.map { ($0, observation[$0] ?? NSNull()) }))
  }

  public static func liveAppleErrors(
    envelope: [String: Any], request: [String: Any], observation: Any?, now: Date
  ) -> [String] {
    let fields: Set<String> = [
      "source", "guard_verified", "observed_at", "account_guard_ref", "team_id", "app_id",
      "bundle_id", "platform", "live_build", "internal_group_ids",
    ]
    var errors = objectShape(
      observation, required: fields, allowed: fields, label: "live Apple observation")
    guard let observation = observation as? [String: Any] else { return errors }
    let apple = envelope["apple"] as? [String: Any] ?? [:]
    if observation["source"] as? String != "asc_read_only"
      || observation["guard_verified"] as? Bool != true
    {
      errors.append("live Apple observation must come from the guarded read-only ASC route")
    }
    if ["account_guard_ref", "team_id", "app_id", "bundle_id", "platform"].contains(where: {
      !jsonEqual(observation[$0], apple[$0])
    }) {
      errors.append("live Apple account, team, app, bundle, or platform drifted")
    }
    if !jsonEqual(observation["internal_group_ids"], apple["internal_group_ids"]) {
      errors.append("live TestFlight internal groups drifted from authorization")
    }
    if let observed = try? HarnessRuntime.parseTimestamp(string(observation["observed_at"])) {
      let age = now.timeIntervalSince(observed)
      if age < -60 || age > 300 {
        errors.append("live Apple observation is stale or from the future")
      }
    } else {
      errors.append("live Apple observation time is invalid")
    }
    let build = apple["build_policy"] as? [String: Any] ?? [:]
    if build["mode"] as? String == "next_after_live",
      string(observation["live_build"]) != string(build["baseline"])
    {
      errors.append("authorized live-build baseline drifted from the current ASC observation")
    }
    if request["apple_observation_sha256"] as? String != (try? canonicalSHA256(observation)) {
      errors.append("live Apple observation digest drifted from the action request")
    }
    return Array(Set(errors)).sorted()
  }

  private static func validateHealthAttestation(_ envelope: [String: Any]) -> [String] {
    let fields: Set<String> = [
      "report_sha256", "observed_at", "profile", "overall_status", "authoritative_targets_sha256",
      "agent_skill_bundle_sha256", "coordinator_instance_id", "coordinator_contract_bundle_sha256",
    ]
    let health = envelope["health_attestation"] as? [String: Any]
    var errors = objectShape(
      health, required: fields, allowed: fields, label: "authorization health attestation")
    guard let health else { return errors }
    if health["profile"] as? String != envelope["health_profile"] as? String {
      errors.append("authorization health attestation profile drifted")
    }
    if !["healthy", "degraded"].contains(health["overall_status"] as? String ?? "") {
      errors.append("authorization health attestation is not usable")
    }
    for field in [
      "report_sha256", "authoritative_targets_sha256", "agent_skill_bundle_sha256",
      "coordinator_contract_bundle_sha256",
    ] where !regex(health[field], #"^sha256:[0-9a-f]{64}$"#) {
      errors.append("authorization health attestation \(field) is invalid")
    }
    if (health["coordinator_instance_id"] as? String)?.isEmpty != false {
      errors.append("authorization health coordinator instance is invalid")
    }
    if let observed = try? HarnessRuntime.parseTimestamp(string(health["observed_at"])),
      let issued = try? HarnessRuntime.parseTimestamp(string(envelope["issued_at"])),
      observed <= issued, issued.timeIntervalSince(observed) <= 300
    {
    } else {
      errors.append("authorization health attestation is stale at issuance")
    }
    return errors
  }

  private static func validateRepository(_ envelope: [String: Any]) -> [String] {
    let fields: Set<String> = ["fingerprint", "canonical_root", "remote", "base_sha", "branch"]
    let repository = envelope["repository"] as? [String: Any]
    var errors = objectShape(
      repository, required: fields, allowed: fields, label: "repository authorization")
    guard let repository else { return errors }
    if fields.contains(where: { string(repository[$0]).isEmpty }) {
      errors.append("authorization must bind the exact repository and branch")
    }
    do {
      if try repositoryFingerprint(string(repository["remote"])) != repository["fingerprint"]
        as? String
      {
        errors.append("authorization repository fingerprint does not match its logical remote")
      }
    } catch { errors.append("authorization repository remote is unsafe or unsupported") }
    return errors
  }

  private static func validateSpecKit(_ envelope: [String: Any]) -> [String] {
    guard !(envelope["spec_kit"] is NSNull), envelope["spec_kit"] != nil else { return [] }
    let fields: Set<String> = [
      "release", "feature_id", "feature_directory", "approved_git_branch", "snapshot_sha256",
      "artifact_hashes", "workflow_run_id",
    ]
    let spec = envelope["spec_kit"] as? [String: Any]
    var errors = objectShape(spec, required: fields, allowed: fields, label: "Spec Kit binding")
    guard let spec else { return errors + ["Spec Kit authorization binding is invalid"] }
    if spec["release"] as? String != SpecKitSnapshot.pinnedRelease
      || fields.subtracting(["artifact_hashes"]).contains(where: { string(spec[$0]).isEmpty })
      || (spec["artifact_hashes"] as? [String: Any])?.isEmpty != false
    {
      errors.append("Spec Kit authorization binding is invalid")
    }
    if spec["approved_git_branch"] as? String != (envelope["repository"] as? [String: Any])?[
      "branch"] as? String
    {
      errors.append("Spec Kit accepted branch mapping drifted from repository binding")
    }
    return errors
  }

  private static func validateResourcePlan(_ envelope: [String: Any], context: RuntimeContext)
    -> [String]
  {
    guard let plan = envelope["resource_plan"] as? [[String: Any]] else {
      return ["authorization resource plan must be an array"]
    }
    let resources: Set<String> = [
      "source_checkout_writer", "xcode_project_mutation", "build_tuple", "simulator_or_device",
      "coresimulator_runtime_registry", "macos_gui_session", "signing_or_app_store_connect",
      "github_external_mutation",
    ]
    var errors: [String] = []
    var ids = Set<String>()
    var identities = Set<String>()
    var workflowNodes: [String: [String: Any]] = [:]
    var allowedNodes = Set<String>()
    func nodes(_ file: String) -> [[String: Any]] {
      for path in ["contracts/\(file)", "skills/agent-harness/contracts/\(file)"] {
        if let object = try? HarnessRuntime.object(
          context.harnessRoot.appendingPathComponent(path)),
          let values = object["nodes"] as? [[String: Any]]
        {
          return values
        }
      }
      return []
    }
    let main = nodes("workflow.json")
    let continuation = nodes("testflight-workflow.json")
    let local = nodes("local-workflow.json")
    let selectedMain = envelope["delivery_target"] as? String == "local_verified" ? local : main
    let all =
      envelope["delivery_target"] as? String == "local_verified" ? local : main + continuation
    for node in all {
      guard let id = node["id"] as? String, !id.isEmpty, workflowNodes[id] == nil else {
        errors.append("installed workflow node IDs must be unique and non-empty")
        continue
      }
      workflowNodes[id] = node
    }
    if envelope["delivery_target"] as? String == "local_verified" {
      if let health = selectedMain.firstIndex(where: { $0["id"] as? String == "health" }) {
        allowedNodes.formUnion(
          selectedMain.suffix(from: health + 1).compactMap { $0["id"] as? String })
      }
    } else if let binding = selectedMain.firstIndex(where: {
      $0["id"] as? String == "bind_run_authorization"
    }) {
      allowedNodes.formUnion(
        selectedMain.suffix(from: binding + 1).compactMap { $0["id"] as? String })
    }
    if envelope["delivery_target"] as? String != "pr_ready",
      let start = continuation.firstIndex(where: { $0["id"] as? String == "health_gate" }),
      let end = continuation.firstIndex(where: { $0["id"] as? String == "testflight_uploaded" })
    {
      allowedNodes.formUnion(continuation[(start + 1)...end].compactMap { $0["id"] as? String })
    }
    if envelope["delivery_target"] as? String == "testflight_distributed" {
      allowedNodes.formUnion(continuation.compactMap { $0["id"] as? String })
    }
    for entry in plan {
      let fields: Set<String> = [
        "plan_id", "resource", "resource_key", "descriptor_sha256", "resource_descriptor",
        "owner_actor", "protects",
      ]
      if Set(entry.keys) != fields {
        errors.append("authorization resource plan entry has invalid fields")
        continue
      }
      let id = string(entry["plan_id"])
      let resource = string(entry["resource"])
      let key = string(entry["resource_key"])
      if id.isEmpty || !ids.insert(id).inserted {
        errors.append("authorization resource plan IDs must be unique and non-empty")
      }
      if !resources.contains(resource) {
        errors.append("authorization resource plan uses an unknown resource")
      }
      if !key.hasPrefix(resource + ":sha256:") || !identities.insert(resource + "\0" + key).inserted
      {
        errors.append("authorization resource plan identity is invalid or duplicated")
      }
      if entry["owner_actor"] as? String != envelope["selected_writer"] as? String {
        errors.append("authorization resource plan owner must be the selected writer")
      }
      if !uniqueNonemptyStrings(entry["protects"]) {
        errors.append("authorization resource plan protected nodes are invalid")
      } else if let protects = entry["protects"] as? [String],
        protects.contains(where: { workflowNodes[$0] == nil })
      {
        errors.append("authorization resource plan protects an unknown workflow node")
      } else if let protects = entry["protects"] as? [String],
        protects.contains(where: { !allowedNodes.contains($0) })
      {
        errors.append("authorization resource plan protects a node outside its delivery target")
      } else if let protects = entry["protects"] as? [String],
        protects.contains(where: {
          workflowNodes[$0]?["lease_action"] != nil
            || workflowNodes[$0]?["terminal"] as? Bool == true
        })
      {
        errors.append(
          "authorization resource plan may protect work nodes, not lease or terminal nodes")
      }
      if let descriptor = entry["resource_descriptor"] as? [String: Any],
        let normalized = try? ResourceCoordinator.normalizeDescriptor(
          resource: resource, descriptor: descriptor),
        let digest = try? ResourceCoordinator.descriptorSHA256(
          resource: resource, descriptor: normalized),
        let canonicalKey = try? ResourceCoordinator.canonicalResourceKey(
          resource: resource, descriptor: normalized),
        jsonEqual(descriptor, normalized), entry["descriptor_sha256"] as? String == digest,
        key == canonicalKey
      {
      } else {
        errors.append("authorization resource plan descriptor binding is invalid")
      }
    }
    if envelope["health_profile"] as? String == "runtime_ui" {
      let verificationNodes: Set<String> = ["verify", "reverify", "prepare_evidence"]
      func protectsVerification(_ entry: [String: Any]) -> Bool {
        !Set(entry["protects"] as? [String] ?? []).isDisjoint(with: verificationNodes)
      }
      if !plan.contains(where: {
        $0["resource"] as? String == "build_tuple" && protectsVerification($0)
      }) {
        errors.append(
          "runtime_ui authorization requires a build_tuple resource plan protecting runtime verification"
        )
      }
      if !plan.contains(where: {
        ["simulator_or_device", "macos_gui_session"].contains($0["resource"] as? String ?? "")
          && protectsVerification($0)
      }) {
        errors.append(
          "runtime_ui authorization requires a device or macOS GUI resource plan protecting runtime verification"
        )
      }
    }
    return errors
  }

  private static func validateGrants(_ envelope: [String: Any], grants: [[String: Any]]) -> [String]
  {
    var errors: [String] = []
    var ids = Set<String>()
    var keys = Set<String>()
    for grant in grants {
      let required: Set<String> = [
        "grant_id", "system", "action", "operation", "operation_input", "constraint_sha256",
        "resource_key", "phase", "single_use", "idempotency_key",
      ]
      let allowed = required.union(["target", "target_from_grant_id", "produces_target_kind"])
      errors += objectShape(grant, required: required, allowed: allowed, label: "action grant")
      let id = string(grant["grant_id"])
      let key = string(grant["idempotency_key"])
      let action = string(grant["action"])
      let operation = string(grant["operation"])
      let direct = !(grant["target"] is NSNull) && !string(grant["target"]).isEmpty
      let derived = !string(grant["target_from_grant_id"]).isEmpty
      if direct == derived {
        errors.append("action grant must bind one direct or derived target: \(id)")
      }
      if !allowedActions.contains(action) || forbiddenActions.contains(action) {
        errors.append("action grant is not allowlisted: \(action)")
      }
      if !operationAllowlist[action, default: []].contains(operation) {
        errors.append("action grant operation is not allowlisted for \(action): \(operation)")
      }
      if let input = grant["operation_input"] as? [String: Any], !input.isEmpty {
        if (try? canonicalSHA256(input)) != grant["constraint_sha256"] as? String {
          errors.append("action grant operation input does not match its constraint: \(id)")
        }
        errors += operationInputErrors(envelope, action: action, operation: operation, input: input)
          .map { "action grant \(id): \($0)" }
      } else {
        errors.append("action grant operation input is invalid: \(id)")
      }
      if !regex(grant["constraint_sha256"], #"^[0-9a-f]{64}$"#) {
        errors.append("action grant constraint digest is invalid: \(id)")
      }
      if (try? canonicalLeaseResourceKey(envelope, action: action)) != grant["resource_key"]
        as? String
      {
        errors.append("action grant resource key is not canonical: \(id)")
      }
      if !["git", "github", "apple"].contains(string(grant["system"]))
        || string(grant["system"]) != action.split(separator: ".").first.map(String.init)
      {
        errors.append("action grant system does not match action: \(id)")
      }
      if grant["single_use"] as? Bool != true {
        errors.append("action grant must be single use: \(id)")
      }
      let producedKind = string(grant["produces_target_kind"])
      if !producedKind.isEmpty && !["github.issue.create", "github.pr.create"].contains(action) {
        errors.append("only a GitHub create grant may produce a target: \(id)")
      }
      let phase = string(grant["phase"])
      let local = envelope["delivery_target"] as? String == "local_verified"
      if !["local_delivery", "pr_delivery", "testflight_upload", "testflight_distribution"]
        .contains(phase)
      {
        errors.append("action grant phase is invalid: \(id)")
      }
      if local && action == "git.commit" && phase != "local_delivery" {
        errors.append("local commit action must use the local_delivery phase: \(id)")
      }
      if !local && ["git", "github"].contains(string(grant["system"]))
        && action != "github.evidence.publish" && phase != "pr_delivery"
      {
        errors.append("repository delivery action must use the pr_delivery phase: \(id)")
      }
      if action.hasPrefix("apple.") {
        let expectedPhase =
          action == "apple.testflight.distribute_internal"
            || (action == "apple.testflight.readback"
              && string(grant["target"]).contains(":group:"))
          ? "testflight_distribution" : "testflight_upload"
        if phase != expectedPhase {
          errors.append("Apple action is bound to the wrong continuation phase: \(id)")
        }
      }
      if id.isEmpty || !ids.insert(id).inserted {
        errors.append("action grant IDs must be non-empty and unique: \(id)")
      }
      if key.isEmpty || !keys.insert(key).inserted {
        errors.append("idempotency keys must be non-empty and unique: \(key)")
      }
    }
    var byID: [String: [String: Any]] = [:]
    for grant in grants {
      let id = string(grant["grant_id"])
      if byID[id] == nil { byID[id] = grant }
    }
    for grant in grants {
      let sourceID = string(grant["target_from_grant_id"])
      guard !sourceID.isEmpty else { continue }
      if sourceID == string(grant["grant_id"]) {
        errors.append("action grant cannot derive its own target: \(string(grant["grant_id"]))")
      }
      if byID[sourceID].map({ string($0["produces_target_kind"]) }).map({ !$0.isEmpty }) != true {
        errors.append("derived target has no producing grant: \(string(grant["grant_id"]))")
      }
    }
    errors += repositoryGrantErrors(envelope, grants: grants)
    errors += greenPathGrantErrors(envelope, grants: grants)
    errors += appleGrantErrors(envelope, grants: grants)
    return errors
  }

  private static func operationInputErrors(
    _ envelope: [String: Any], action: String, operation: String, input: [String: Any]
  ) -> [String] {
    let repository = envelope["repository"] as? [String: Any] ?? [:]
    let limits = envelope["limits"] as? [String: Any] ?? [:]
    let apple = envelope["apple"] as? [String: Any] ?? [:]
    var valid = false
    var message = "operation input semantics are unavailable: \(operation)"
    let state: [String: String] = [
      "transition_issue_ready": "Ready", "transition_issue_in_progress": "In Progress",
      "transition_issue_in_review": "In Review",
    ]
    if let expected = state[operation] {
      valid = jsonEqual(input, ["state": expected])
      message = "Issue transition descriptor drifted: \(operation)"
    } else if operation.hasPrefix("transition_project_") {
      let expected =
        operation.hasSuffix("ready")
        ? "Ready" : operation.hasSuffix("progress") ? "In Progress" : "In Review"
      valid =
        Set(input.keys) == ["state", "field_id", "option_id"]
        && input["state"] as? String == expected && !string(input["field_id"]).isEmpty
        && !string(input["option_id"]).isEmpty
      message = "Project transition descriptor has unsupported fields or drifted: \(operation)"
    } else if operation == "commit_reviewed_patch" {
      let paths = input["paths"] as? [String] ?? []
      valid =
        Set(input.keys) == ["message_policy", "paths"]
        && input["message_policy"] as? String == "reviewed_patch" && uniqueNonemptyStrings(paths)
        && paths.allSatisfy { pathAllowed($0, envelope["allowed_paths"] as? [String] ?? []) }
      message = "commit descriptor must bind reviewed_patch and exact authorized paths"
    } else if operation == "push_reviewed_commit" {
      valid = jsonEqual(input, ["branch": repository["branch"] ?? NSNull(), "force": false])
      message = "push descriptor must bind the authorized branch with force false"
    } else if operation == "ensure_feature_issue" {
      valid = jsonEqual(input, ["title_policy": "accepted_plan", "body_policy": "accepted_plan"])
      message = "feature Issue descriptor must use the accepted-plan policy"
    } else if operation == "create_pull_request" {
      valid =
        Set(input.keys) == ["base_ref", "head", "body_policy", "draft"]
        && safeRef(input["base_ref"]) && input["head"] as? String == repository["branch"] as? String
        && input["base_ref"] as? String != input["head"] as? String
        && input["body_policy"] as? String == "evidence_backed_current_run"
        && input["draft"] as? Bool == false
      message =
        "pull-request descriptor must bind a safe base, authorized head, evidence body, and draft false"
    } else if ["publish_exact_issue_comment", "publish_exact_pr_comment"].contains(operation) {
      valid = Set(input.keys) == ["body_sha256"] && regex(input["body_sha256"], #"^[0-9a-f]{64}$"#)
      message = "exact comment descriptor must bind body_sha256: \(operation)"
    } else if operation == "update_exact_pull_request" {
      valid =
        Set(input.keys) == ["title_sha256", "body_sha256"]
        && regex(input["title_sha256"], #"^[0-9a-f]{64}$"#)
        && regex(input["body_sha256"], #"^[0-9a-f]{64}$"#)
      message = "exact pull-request update must bind title and body SHA-256"
    } else if operation.hasPrefix("publish_") && operation.hasSuffix("_evidence") {
      let expected =
        operation == "publish_pr_evidence"
        ? "sanitized_pr_evidence"
        : operation == "publish_testflight_upload_evidence"
          ? "sanitized_testflight_upload_evidence" : "sanitized_testflight_distribution_evidence"
      valid = jsonEqual(input, ["artifact_policy": expected])
      message = "evidence publication descriptor drifted: \(operation)"
    } else if operation == "wait_required_checks" {
      valid = jsonEqual(
        input,
        ["policy": "all_required", "timeout_minutes": limits["async_wait_minutes"] ?? NSNull()])
      message = "required-check wait must use all_required and the authorized async bound"
    } else if operation == "upload_verified_archive" {
      valid = jsonEqual(input, ["artifact_policy": "fresh_archive_from_reviewed_pr_commit"])
      message = "TestFlight upload descriptor drifted"
    } else if operation == "wait_bounded_processing" {
      valid = jsonEqual(
        input,
        [
          "timeout_minutes": limits["async_wait_minutes"] ?? NSNull(),
          "max_transient_retries": limits["max_transient_retries"] ?? NSNull(),
        ])
      message = "processing wait descriptor exceeds or drifts from authorization bounds"
    } else if operation == "verify_uploaded_build" {
      valid = jsonEqual(input, ["readback": "uploaded_build"])
      message = "upload read-back descriptor drifted"
    } else if operation == "distribute_named_internal_group" {
      valid =
        Set(input.keys) == ["group_id"]
        && (apple["internal_group_ids"] as? [String] ?? []).contains(string(input["group_id"]))
      message = "distribution descriptor is outside the named internal group"
    } else if operation == "verify_internal_distribution" {
      valid =
        Set(input.keys) == ["readback", "group_id"]
        && input["readback"] as? String == "internal_group_build"
        && (apple["internal_group_ids"] as? [String] ?? []).contains(string(input["group_id"]))
      message = "distribution read-back descriptor drifted"
    }
    var errors = valid ? [] : [message]
    if !operationAllowlist[action, default: []].contains(operation) {
      errors.append("operation is not allowed for action \(action): \(operation)")
    }
    return errors
  }

  private static func repositoryGrantErrors(_ envelope: [String: Any], grants: [[String: Any]])
    -> [String]
  {
    var errors: [String] = []
    let repository = envelope["repository"] as? [String: Any] ?? [:]
    let github = envelope["github"] as? [String: Any] ?? [:]
    if envelope["delivery_target"] as? String == "local_verified" {
      for grant in grants {
        let action = string(grant["action"])
        if action != "git.commit" {
          errors.append("local verification cannot authorize remote or Apple actions: \(action)")
        }
        if action == "git.commit",
          string(grant["target"])
            != "\(string(repository["fingerprint"])):\(string(repository["branch"]))"
        {
          errors.append("grant target does not match the bound repository: git.commit")
        }
      }
      return errors
    }
    let slug = boundGitHubSlug(envelope) ?? "<invalid-repository>"
    let branch = string(repository["branch"])
    let fingerprint = string(repository["fingerprint"])
    if (try? normalizeGitHubRemote(string(repository["remote"])).replacingOccurrences(
      of: "github.com/", with: "")) != slug
    {
      errors.append("repository remote does not match the bound GitHub owner/repository")
    }
    let canonical = [
      "git.commit": "\(fingerprint):\(branch)", "git.push": "\(slug):\(branch)",
      "github.pr.create": "\(slug):\(branch)", "github.issue.create": "\(slug):feature:\(branch)",
    ]
    var byID: [String: [String: Any]] = [:]
    for grant in grants {
      let id = string(grant["grant_id"])
      if byID[id] == nil { byID[id] = grant }
    }
    for grant in grants {
      let action = string(grant["action"])
      let target = string(grant["target"])
      if let expected = canonical[action], target != expected {
        errors.append("grant target does not match the bound repository: \(action)")
      }
      if action == "github.issue.create", grant["produces_target_kind"] as? String != "github_issue"
      {
        errors.append("Issue create grant must declare a GitHub Issue output")
      }
      if action == "github.pr.create", grant["produces_target_kind"] as? String != "github_pr" {
        errors.append("PR create grant must declare a GitHub PR output")
      }
      let consumers = [
        "github.issue.update": "github_issue", "github.issue.comment": "github_issue",
        "github.pr.update": "github_pr", "github.pr.comment": "github_pr",
        "github.evidence.publish": "github_pr", "github.checks.wait": "github_pr",
      ]
      if let kind = consumers[action], let sourceID = grant["target_from_grant_id"] as? String,
        (byID[sourceID]?["produces_target_kind"] as? String) != kind
      {
        errors.append("derived GitHub target has the wrong object kind: \(action)")
      } else if let kind = consumers[action], grant["target_from_grant_id"] == nil {
        if kind == "github_issue" {
          if let issue = int(github["issue_number"]), target != "\(slug):issue:\(issue)" {
            errors.append(
              "Issue grant must bind a known exact Issue or a derived target: \(action)")
          }
        } else if target.range(
          of: "^" + NSRegularExpression.escapedPattern(for: slug) + #":pr:[1-9][0-9]*$"#,
          options: .regularExpression) == nil
        {
          errors.append("PR grant must bind an exact PR in the authorized repository: \(action)")
        }
      }
      if action == "github.project.update" {
        if let projectID = (github["project"] as? [String: Any])?["id"] as? String,
          target == "\(slug):project:\(projectID)",
          grant["target_from_grant_id"] == nil || grant["target_from_grant_id"] is NSNull
        {
        } else {
          errors.append("Project grant must bind the exact configured Project")
        }
      }
    }
    return errors
  }

  private static func greenPathGrantErrors(_ envelope: [String: Any], grants: [[String: Any]])
    -> [String]
  {
    var errors: [String] = []
    let counts = Dictionary(grouping: grants, by: { string($0["action"]) }).mapValues(\.count)
    if envelope["delivery_target"] as? String == "local_verified" {
      if counts["git.commit", default: 0] > 1 {
        errors.append("local verification permits at most one explicit git.commit grant")
      }
      if grants.contains(where: { $0["action"] as? String != "git.commit" }) {
        errors.append("local verification action grants must remain local")
      }
      return errors
    }
    for action in ["git.commit", "git.push", "github.pr.create", "github.checks.wait"]
    where counts[action] != 1 {
      errors.append("delivery authorization requires exactly one \(action) grant")
    }
    if let pr = grants.first(where: { $0["action"] as? String == "github.pr.create" }) {
      for grant in grants
      where [
        "github.pr.update", "github.pr.comment", "github.evidence.publish", "github.checks.wait",
      ].contains(string(grant["action"]))
        && grant["target_from_grant_id"] as? String != pr["grant_id"] as? String
      {
        errors.append(
          "PR consumer grant must derive the PR created by this run: \(string(grant["grant_id"]))")
      }
    }
    let delivery = envelope["delivery_target"] as? String
    let expectedEvidence = delivery == "pr_ready" ? 1 : delivery == "testflight_uploaded" ? 2 : 3
    if counts["github.evidence.publish"] != expectedEvidence {
      errors.append("delivery authorization has the wrong evidence-publication grant count")
    }
    let observedEvidence = Set(
      grants.filter { $0["action"] as? String == "github.evidence.publish" }.map {
        "\(string($0["operation"]))|\(string($0["phase"]))"
      })
    var expectedOperations: Set<String> = ["publish_pr_evidence|pr_delivery"]
    if delivery == "testflight_uploaded" || delivery == "testflight_distributed" {
      expectedOperations.insert("publish_testflight_upload_evidence|testflight_upload")
    }
    if delivery == "testflight_distributed" {
      expectedOperations.insert("publish_testflight_distribution_evidence|testflight_distribution")
    }
    if observedEvidence != expectedOperations {
      errors.append("evidence grants must bind the exact delivery phase and publication operation")
    }
    let github = envelope["github"] as? [String: Any] ?? [:]
    let creates = grants.filter { $0["action"] as? String == "github.issue.create" }
    let updates = grants.filter { $0["action"] as? String == "github.issue.update" }
    let expectedIssueOperations: Set<String>
    if github["issue_number"] is NSNull || github["issue_number"] == nil {
      if creates.count != 1 || updates.count != 2 {
        errors.append("a new feature Issue requires one create and two state-update grants")
      }
      if creates.count == 1
        && updates.contains(where: {
          $0["target_from_grant_id"] as? String != creates[0]["grant_id"] as? String
        })
      {
        errors.append("new Issue state grants must derive from the Issue create grant")
      }
      expectedIssueOperations = ["transition_issue_in_progress", "transition_issue_in_review"]
    } else {
      if !creates.isEmpty || updates.count != 3 {
        errors.append("an existing feature Issue requires exactly three state-update grants")
      }
      expectedIssueOperations = [
        "transition_issue_ready", "transition_issue_in_progress", "transition_issue_in_review",
      ]
    }
    if Set(updates.compactMap { $0["operation"] as? String }) != expectedIssueOperations {
      errors.append("Issue update grants must bind the exact authorized state transitions")
    }
    let projectUpdates = grants.filter { $0["action"] as? String == "github.project.update" }
    let project = github["project"]
    let projectSelected = project != nil && !(project is NSNull)
    if projectUpdates.count != (projectSelected ? 3 : 0) {
      errors.append("Project tracking grants do not match the selected Project configuration")
    }
    if projectSelected
      && Set(projectUpdates.compactMap { $0["operation"] as? String }) != [
        "transition_project_ready", "transition_project_in_progress",
        "transition_project_in_review",
      ]
    {
      errors.append(
        "Project grants must bind the exact Ready, In Progress, and In Review transitions")
    }
    return errors
  }

  private static func appleGrantErrors(_ envelope: [String: Any], grants: [[String: Any]])
    -> [String]
  {
    let appleGrants = grants.filter { $0["system"] as? String == "apple" }
    let delivery = envelope["delivery_target"] as? String
    if delivery == "pr_ready" || delivery == "local_verified" {
      return (envelope["apple"] is NSNull || envelope["apple"] == nil) && appleGrants.isEmpty
        ? [] : ["\(delivery ?? "local") authorization cannot bind or grant Apple actions"]
    }
    guard let apple = envelope["apple"] as? [String: Any] else {
      return ["TestFlight authorization must bind the exact Apple target"]
    }
    var errors: [String] = []
    let groups = apple["internal_group_ids"] as? [String] ?? []
    if Set(groups).count != groups.count {
      errors.append("TestFlight internal group IDs must be unique")
    }
    if groups.count > 1 {
      errors.append("authorization schema v1 supports one exact internal group per run")
    }
    if delivery == "testflight_uploaded" && !groups.isEmpty {
      errors.append("upload-only authorization cannot bind distribution groups")
    }
    if delivery == "testflight_distributed" && groups.isEmpty {
      errors.append("internal distribution must name at least one exact group ID")
    }
    var expected = [
      "apple.testflight.upload|app:\(string(apple["app_id"]))",
      "apple.testflight.processing.wait|app:\(string(apple["app_id"])):processing",
      "apple.testflight.readback|app:\(string(apple["app_id"])):upload",
    ]
    if delivery == "testflight_distributed" {
      for group in groups {
        expected += [
          "apple.testflight.distribute_internal|app:\(string(apple["app_id"])):group:\(group)",
          "apple.testflight.readback|app:\(string(apple["app_id"])):group:\(group)",
        ]
      }
    }
    let actual = appleGrants.map { string($0["action"]) + "|" + string($0["target"]) }
    if actual.sorted() != expected.sorted() {
      errors.append("TestFlight grants do not exactly match the selected target and groups")
    }
    if appleGrants.contains(where: { $0["target_from_grant_id"] != nil }) {
      errors.append("Apple grants must bind direct app/build/group targets")
    }
    return errors
  }

  private static func sourceBundleSHA256(_ root: URL) throws -> String {
    // One source identity for both safety modules. Exclude build products,
    // tests, caches, and logs; include executable Swift sources and contracts.
    try ResourceCoordinator.sourceBundleSHA256(skillRoot: root)
  }

  private static func installedSchemaURL(_ context: RuntimeContext) -> URL? {
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
  private static func objectShape(
    _ value: Any?, required: Set<String>, allowed: Set<String>, label: String
  ) -> [String] {
    guard let object = value as? [String: Any] else { return ["\(label) must be an object"] }
    var result: [String] = []
    let keys = Set(object.keys)
    let missing = required.subtracting(keys)
    let extra = keys.subtracting(allowed)
    if !missing.isEmpty {
      result.append("\(label) is missing fields: \(missing.sorted().joined(separator: ", "))")
    }
    if !extra.isEmpty {
      result.append("\(label) has unsupported fields: \(extra.sorted().joined(separator: ", "))")
    }
    return result
  }
  private static func safeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/")
      && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
  private static func pathAllowed(_ path: String, _ allowed: [String]) -> Bool {
    safeRelativePath(path)
      && allowed.contains {
        path == $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          || path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
      }
  }
  private static func safeRef(_ value: Any?) -> Bool {
    guard let value = value as? String, !value.isEmpty, !value.hasPrefix("/"),
      !value.hasPrefix("-"), !value.hasSuffix("/"), !value.hasSuffix(".lock"),
      !value.contains(".."), !value.contains("@{")
    else { return false }
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
  }
  private static func uniqueNonemptyStrings(_ value: Any?) -> Bool {
    guard let values = value as? [String], !values.isEmpty else { return false }
    return Set(values).count == values.count && values.allSatisfy { !$0.isEmpty }
  }
  private static func regex(_ value: Any?, _ pattern: String) -> Bool {
    guard let string = value as? String else { return false }
    return string.range(of: pattern, options: .regularExpression) != nil
  }
  private static func int(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let raw = number.stringValue
    guard let value = Int(raw), raw == String(value) || raw == "-0" else { return nil }
    return value
  }
  private static func string(_ value: Any?) -> String {
    if value == nil || value is NSNull { return "" }
    return (value as? String) ?? String(describing: value!)
  }
  private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }
  private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}
