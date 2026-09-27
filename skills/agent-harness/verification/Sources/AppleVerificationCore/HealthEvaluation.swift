import Foundation

public struct RuntimeProbeScope {
  public let statePath: URL
  public let descriptor: [String: Any]
  public let ownerRunID: String
  public let ownerActor: String
  public let ttlSeconds: Int
  public let runAuthority: [String: Any]
  public init(
    statePath: URL, descriptor: [String: Any], ownerRunID: String, ownerActor: String,
    ttlSeconds: Int = 120, runAuthority: [String: Any]
  ) {
    self.statePath = statePath
    self.descriptor = descriptor
    self.ownerRunID = ownerRunID
    self.ownerActor = ownerActor
    self.ttlSeconds = ttlSeconds
    self.runAuthority = runAuthority
  }
  public var isWellFormed: Bool {
    !ownerRunID.isEmpty && !ownerActor.isEmpty && ttlSeconds > 0 && !runAuthority.isEmpty
      && Set(descriptor.keys)
        == Set([
          "coordinator_instance_id", "registry_scope", "platform", "destination_id",
          "runtime_identifier",
        ])
      && [
        "coordinator_instance_id", "registry_scope", "platform", "destination_id",
        "runtime_identifier",
      ].allSatisfy { (descriptor[$0] as? String)?.isEmpty == false }
  }
}

public struct HealthEvaluationResult {
  public let report: [String: Any]
  public let errors: [String]
  public var valid: Bool { errors.isEmpty && report["overall_status"] as? String != "blocked" }
}

public enum HealthEvaluation {
  /// Bound for each of the two registry inventory commands the runtime probe runs under its lease.
  public static let runtimeProbeCommandTimeout: TimeInterval = 30
  /// The lease must outlive both commands plus the coordinator's own lock wait and process
  /// teardown; nothing heartbeats it, and an expired lease blocks the host until recovery.
  public static let minimumRuntimeProbeTTLSeconds = Int(2 * runtimeProbeCommandTimeout) + 30
  public static let profiles: Set<String> = [
    "local_verified", "pr_ready", "runtime_ui", "testflight_uploaded", "testflight_distributed",
    "icon_upstream",
  ]
  public static let profileRequirements: [String: Set<String>] = [
    "local_verified": [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
    ],
    "pr_ready": [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      "github.issue_pr",
    ],
    "runtime_ui": [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      "xcode.authoritative_container", "apple.execution_path", "simulator.runtime",
    ],
    "testflight_uploaded": [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      "github.issue_pr", "xcode.authoritative_container", "apple.execution_path",
      "apple.account_guard", "cli.asc", "testflight.upload_target",
    ],
    "testflight_distributed": [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      "github.issue_pr", "xcode.authoritative_container", "apple.execution_path",
      "apple.account_guard", "cli.asc", "testflight.upload_target", "testflight.internal_groups",
    ],
    "icon_upstream": [
      "repository.identity", "agent.skills", "agent.resource_coordinator", "cli.git",
      "github.issue_pr", "companion_upstream.provenance",
    ],
  ]
  public static let componentRequirements = [
    "project_registry": "repository.project_registry", "spec_kit": "spec_kit.snapshot",
    "xcode_mcp": "mcp.xcode", "apple_sample_code_mcp": "mcp.apple_sample_code",
    "github_project": "github.project", "local_llm": "local_llm",
  ]
  public static let evaluatorOwnedChecks: Set<String> = [
    "github.issue_pr", "github.project", "xcode.authoritative_container", "apple.execution_path",
    "simulator.runtime", "apple.account_guard", "cli.asc", "testflight.upload_target",
    "testflight.internal_groups", "mcp.xcode", "mcp.apple_sample_code", "spec_kit.snapshot",
    "local_llm", "companion_upstream.provenance",
  ]
  private static let categories: Set<String> = [
    "repository", "agent", "cli", "mcp", "github", "spec_kit", "xcode", "simulator",
    "apple_account", "testflight", "local_llm", "companion_upstream",
  ]
  private static let sensitiveKeys: Set<String> = [
    "token", "password", "secret", "authorization", "private_key", "otp",
  ]
  private static let fingerprint = try! NSRegularExpression(pattern: "^sha256:[0-9a-f]{64}$")
  private static let identifier = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$")
  // ICU spells a code point `\x{hh}`; the Swift-style `\u{hhhh}` made this pattern trap on its
  // first use, which is the first resolved candidate that lists an Xcode container. The `..`
  // lookahead spans every code point: ICU's `.` stops at U+0085, U+2028 and U+2029, which the
  // path class admits, so `App<U+2028>/../x.xcodeproj` would otherwise pass.
  static let xcodeContainer = try! NSRegularExpression(
    pattern:
      #"^(?!/)(?![\s\S]*(?:^|/)\.\.(?:/|$))[^\x{0}-\x{1f}\x{7f}]+\.(?:xcodeproj|xcworkspace)$"#)
  private static let staleRegistryReasons: Set<String> = [
    "missing_path", "not_git_root", "missing_xcode_container", "remote_fingerprint_mismatch",
  ]

  public static func evaluate(
    _ report: [String: Any], now: Date = Date(), evaluatorObservedCheckIDs: Set<String> = []
  ) -> HealthEvaluationResult {
    var errors: Set<String> = []
    let allowed: Set<String> = [
      "$schema", "schema_version", "profile", "observed_at", "authoritative_targets",
      "agent_skill_manifest", "resource_coordinator_observation", "project_registry_resolution",
      "selected_components", "required_check_ids", "checks",
    ]
    if !Set(report.keys).isSubset(of: allowed) {
      errors.insert("health report contains unsupported top-level fields")
    }
    guard report["schema_version"] as? String == "1.0.0" else {
      return blocked(report, ["unsupported health report schema"])
    }
    guard let profile = report["profile"] as? String, profiles.contains(profile) else {
      return blocked(report, ["unsupported health profile"])
    }
    guard let observed = report["observed_at"] as? String,
      let observedAt = try? HarnessRuntime.parseTimestamp(observed),
      now.timeIntervalSince(observedAt) >= -60, now.timeIntervalSince(observedAt) <= 600
    else {
      errors.insert("health report is stale or from the future")
      return blocked(report, Array(errors))
    }
    if (report["authoritative_targets"] as? [String: Any])?.isEmpty != false {
      errors.insert("health report requires authoritative targets")
    }
    validateSkillManifest(report["agent_skill_manifest"], errors: &errors)
    let components = report["selected_components"] as? [String] ?? []
    if components.count != Set(components).count
      || components.contains(where: { componentRequirements[$0] == nil })
    {
      errors.insert("health report selected_components are invalid")
    }
    let required = report["required_check_ids"] as? [String] ?? []
    if required.isEmpty || required.count != Set(required).count
      || required.contains(where: { $0.isEmpty })
    {
      errors.insert("health report requires unique required_check_ids")
    }
    var expected = profileRequirements[profile] ?? []
    components.forEach { if let check = componentRequirements[$0] { expected.insert(check) } }
    if Set(required) != expected {
      let missing = expected.subtracting(required)
      let extra = Set(required).subtracting(expected)
      if !missing.isEmpty {
        errors.insert(
          "health profile is missing required check IDs: \(missing.sorted().joined(separator: ", "))"
        )
      }
      if !extra.isEmpty {
        errors.insert(
          "health report has unbound required check IDs: \(extra.sorted().joined(separator: ", "))")
      }
    }
    let checks = report["checks"] as? [[String: Any]] ?? []
    if checks.isEmpty { errors.insert("health report requires at least one check") }
    var byID: [String: [String: Any]] = [:]
    let statuses: Set<String> = ["healthy", "degraded", "blocked", "not_applicable"]
    for check in checks {
      let allowedFields: Set<String> = [
        "id", "category", "required", "status", "summary", "evidence", "next_action",
      ]
      if !Set(check.keys).isSubset(of: allowedFields) {
        errors.insert("health check contains unsupported fields")
      }
      guard let id = check["id"] as? String, !id.isEmpty, byID[id] == nil else {
        errors.insert("health check IDs must be non-empty and unique")
        continue
      }
      byID[id] = check
      guard let category = check["category"] as? String, categories.contains(category),
        let requiredFlag = check["required"] as? Bool, let status = check["status"] as? String,
        statuses.contains(status), let summary = check["summary"] as? String, !summary.isEmpty,
        let evidence = check["evidence"] as? [String], evidence.allSatisfy({ !$0.isEmpty })
      else {
        errors.insert("health check is malformed: \(id)")
        continue
      }
      if requiredFlag && status == "not_applicable" {
        errors.insert("required health check cannot be not_applicable: \(id)")
      }
      if status != "not_applicable" && evidence.isEmpty {
        errors.insert("applicable health check requires evidence: \(id)")
      }
      if ["degraded", "blocked"].contains(status)
        && (check["next_action"] as? String)?.isEmpty != false
      {
        errors.insert("non-healthy check requires a next action: \(id)")
      }
      if evaluatorOwnedChecks.contains(id), !required.contains(id),
        ["healthy", "degraded"].contains(status)
      {
        errors.insert("unselected evaluator-owned check cannot claim success: \(id)")
      }
    }
    for id in required {
      guard let check = byID[id] else {
        errors.insert("required health check is missing: \(id)")
        continue
      }
      if check["required"] as? Bool != true {
        errors.insert("required health check must set required true: \(id)")
      }
      if evaluatorOwnedChecks.contains(id),
        ["healthy", "degraded"].contains(check["status"] as? String),
        !evaluatorObservedCheckIDs.contains(id)
      {
        errors.insert("required health check needs evaluator-owned live observation: \(id)")
      }
    }
    validateCoordinator(report["resource_coordinator_observation"], errors: &errors)
    if byID["agent.resource_coordinator"]?["status"] as? String != "healthy" {
      errors.insert("required resource coordinator health check must be healthy")
    }
    validateProjectRegistry(
      report["project_registry_resolution"], selected: components.contains("project_registry"),
      checks: byID, errors: &errors)
    let overall: String
    if !errors.isEmpty
      || checks.contains(where: {
        ($0["required"] as? Bool == true) && ($0["status"] as? String == "blocked")
      })
    {
      overall = "blocked"
    } else if checks.contains(where: { ["degraded", "blocked"].contains($0["status"] as? String) })
    {
      overall = "degraded"
    } else {
      overall = "healthy"
    }
    var sanitized = redact(report) as! [String: Any]
    sanitized["overall_status"] = overall
    return HealthEvaluationResult(report: sanitized, errors: errors.sorted())
  }

  public static func reconcile(report: [String: Any], observations: [String: [String: Any]])
    -> [String: Any]
  {
    var value = report
    guard var checks = value["checks"] as? [[String: Any]] else { return value }
    for index in checks.indices {
      if let observation = observations[checks[index]["id"] as? String ?? ""] {
        checks[index]["status"] = observation["status"]
        checks[index]["summary"] = observation["summary"]
        checks[index]["evidence"] = observation["evidence"]
        if let action = observation["next_action"] {
          checks[index]["next_action"] = action
        } else {
          checks[index].removeValue(forKey: "next_action")
        }
      }
    }
    value["checks"] = checks
    return value
  }

  /// Re-observes every evaluator-owned required check from the exact supplied bytes.  A
  /// reservation or dispatch caller must use this rather than accepting a cached report.
  public static func revalidate(
    reportBytes: Data, expectedBytesSHA256: String? = nil, harness: [String: Any],
    policy: [String: Any], authorization: [String: Any]?, runner: HealthProbeRunning,
    runtimeCoordinator: RuntimeRegistryCoordinating? = nil, runtimeScope: RuntimeProbeScope? = nil,
    mcpProbe: HealthMCPProbing = SystemHealthMCPProbe(), liveXcodeBridgeProbe: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    context: RuntimeContext? = nil,
    executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]), now: Date = Date()
  ) -> HealthEvaluationResult {
    let observedDigest = "sha256:" + HarnessRuntime.sha256(reportBytes)
    guard expectedBytesSHA256 == nil || expectedBytesSHA256 == observedDigest else {
      return HealthEvaluationResult(
        report: ["overall_status": "blocked"],
        errors: ["health report bytes drifted before evaluator read"])
    }
    guard let value = try? JSONSerialization.jsonObject(with: reportBytes),
      let report = value as? [String: Any]
    else {
      return HealthEvaluationResult(
        report: ["overall_status": "blocked"], errors: ["health report must contain an object"])
    }
    guard let context else {
      return blocked(report, ["trusted runtime context is required for live health binding"])
    }
    let bindingErrors =
      HealthCollection.trustedPolicyErrors(policy: policy, harness: harness)
      + HealthCollection.trustedSelectionErrors(report: report, harness: harness)
      + HealthCollection.validateHarnessBinding(
        report: report, harness: harness, context: context, runner: runner,
        executableURL: executableURL)
    guard bindingErrors.isEmpty else { return blocked(report, Array(Set(bindingErrors)).sorted()) }
    let observations = collectLiveObservations(
      report: report, harness: harness, policy: policy, authorization: authorization,
      runner: runner, runtimeCoordinator: runtimeCoordinator, runtimeScope: runtimeScope,
      mcpProbe: mcpProbe, liveXcodeBridgeProbe: liveXcodeBridgeProbe, environment: environment)
    return evaluate(
      reconcile(report: report, observations: observations), now: now,
      evaluatorObservedCheckIDs: Set(observations.keys))
  }

  private static func validateCoordinator(_ observation: Any?, errors: inout Set<String>) {
    guard let value = observation as? [String: Any] else {
      errors.insert("resource coordinator observation is invalid")
      return
    }
    let fields: Set<String> = [
      "state_path_sha256", "coordinator_instance_id", "state_schema_version",
      "migration_bootstrap_confirmed", "runtime_kind", "runtime_contract", "executable_sha256",
      "source_bundle_sha256", "active_lease_count",
    ]
    guard Set(value.keys) == fields, strictInteger(value["state_schema_version"], minimum: 0) == 2,
      value["migration_bootstrap_confirmed"] as? Bool == true,
      value["runtime_kind"] as? String == "swift",
      value["runtime_contract"] as? String == "apple-verification-core.resources.v1",
      (value["coordinator_instance_id"] as? String)?.isEmpty == false,
      strictInteger(value["active_lease_count"], minimum: 0) != nil
    else {
      errors.insert("resource coordinator observation is invalid")
      return
    }
    for key in ["state_path_sha256", "executable_sha256", "source_bundle_sha256"] {
      let string = value[key] as? String ?? ""
      if fingerprint.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil
      {
        errors.insert("resource coordinator observation is invalid")
      }
    }
  }
  private static func validateSkillManifest(_ manifest: Any?, errors: inout Set<String>) {
    let manifestFields: Set<String> = ["required_skills", "expected_bundle_sha256", "clients"]
    guard let value = manifest as? [String: Any], Set(value.keys) == manifestFields,
      let required = value["required_skills"] as? [String], !required.isEmpty,
      required == Array(Set(required)).sorted(),
      required.allSatisfy({
        $0.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
      }), let expected = value["expected_bundle_sha256"] as? String,
      fingerprint.firstMatch(in: expected, range: NSRange(expected.startIndex..., in: expected))
        != nil, let clients = value["clients"] as? [[String: Any]], !clients.isEmpty,
      clients.count <= 2
    else {
      errors.insert("agent skill manifest is invalid")
      return
    }
    var names: Set<String> = []
    for client in clients {
      let clientFields: Set<String> = ["client", "root_path_sha256", "bundle_sha256", "skills"]
      guard Set(client.keys) == clientFields, let name = client["client"] as? String,
        ["codex", "claude"].contains(name), names.insert(name).inserted,
        let root = client["root_path_sha256"] as? String,
        let bundle = client["bundle_sha256"] as? String,
        fingerprint.firstMatch(in: root, range: NSRange(root.startIndex..., in: root)) != nil,
        fingerprint.firstMatch(in: bundle, range: NSRange(bundle.startIndex..., in: bundle)) != nil,
        let skills = client["skills"] as? [[String: Any]],
        skills.map({ $0["name"] as? String ?? "" }) == required
      else {
        errors.insert("agent skill manifest per-client skills are invalid")
        continue
      }
      for skill in skills {
        let skillFields: Set<String> = ["name", "entry_kind", "resolved_path_sha256", "sha256"]
        guard Set(skill.keys) == skillFields,
          ["directory", "symlink"].contains(skill["entry_kind"] as? String),
          let resolved = skill["resolved_path_sha256"] as? String,
          let digest = skill["sha256"] as? String,
          fingerprint.firstMatch(in: resolved, range: NSRange(resolved.startIndex..., in: resolved))
            != nil,
          fingerprint.firstMatch(in: digest, range: NSRange(digest.startIndex..., in: digest))
            != nil
        else {
          errors.insert("agent skill manifest per-client skills are invalid")
          break
        }
      }
    }
    if names.count != clients.count {
      errors.insert("agent skill manifest clients must be unique and known")
    }
  }
  private static func validateProjectRegistry(
    _ raw: Any?, selected: Bool, checks: [String: [String: Any]], errors: inout Set<String>
  ) {
    if !selected {
      if raw != nil, !(raw is NSNull) {
        errors.insert("unselected project registry must not include a resolution")
      }
      return
    }
    guard let value = raw as? [String: Any] else {
      errors.insert("selected project registry requires a structured resolution")
      return
    }
    let fields: Set<String> = [
      "status", "reason_code", "resolver_version", "registry_sha256", "worktree_authorized",
      "candidate", "warnings",
    ]
    if Set(value.keys) != fields { errors.insert("project registry resolution fields are invalid") }
    let status = value["status"] as? String
    if !["resolved", "blocked", "needs_selection", "unavailable"].contains(status ?? "") {
      errors.insert("project registry resolution status is invalid")
    }
    let reason = value["reason_code"] as? String
    if reason?.isEmpty != false { errors.insert("project registry resolution reason is invalid") }
    if value["resolver_version"] as? String != "1.0.0" {
      errors.insert("project registry resolver version is unsupported")
    }
    if !isFingerprint(value["registry_sha256"]) {
      errors.insert("project registry resolution hash is invalid")
    }
    guard let worktreeAuthorized = value["worktree_authorized"] as? Bool else {
      errors.insert("project registry worktree authorization must be boolean")
      return
    }
    var warnings: [[String: Any]] = []
    if let values = value["warnings"] as? [[String: Any]] {
      warnings = values
      var seen: Set<String> = []
      for warning in warnings {
        guard Set(warning.keys) == ["project_id", "checkout_id", "reason_code"],
          let projectID = warning["project_id"] as? String, matches(projectID, identifier),
          let checkoutID = warning["checkout_id"] as? String, matches(checkoutID, identifier),
          let warningReason = warning["reason_code"] as? String,
          staleRegistryReasons.contains(warningReason)
        else {
          errors.insert("project registry warning is invalid")
          break
        }
        if !seen.insert("\(projectID)\u{0}\(checkoutID)\u{0}\(warningReason)").inserted {
          errors.insert("project registry warnings must be unique")
          break
        }
      }
    } else {
      errors.insert("project registry warnings must be an array")
    }
    var expectedStatus = "blocked"
    if status == "resolved" {
      let candidateFields: Set<String> = [
        "project_id", "checkout_id", "canonical_root", "remote_fingerprint", "kind",
        "xcode_containers",
      ]
      if let candidate = value["candidate"] as? [String: Any],
        Set(candidate.keys) == candidateFields
      {
        for key in ["project_id", "checkout_id"]
        where !matches(candidate[key] as? String ?? "", identifier) {
          errors.insert("project registry candidate \(key) is invalid")
        }
        if !safeAbsolutePath(candidate["canonical_root"] as? String) {
          errors.insert("project registry candidate root is invalid")
        }
        if !isFingerprint(candidate["remote_fingerprint"]) {
          errors.insert("project registry candidate remote fingerprint is invalid")
        }
        let kind = candidate["kind"] as? String
        if !["primary", "worktree"].contains(kind ?? "") {
          errors.insert("project registry candidate checkout kind is invalid")
        }
        if let containers = candidate["xcode_containers"] as? [String],
          containers.count == Set(containers).count,
          containers.allSatisfy({ matches($0, xcodeContainer) })
        {
        } else {
          errors.insert("project registry candidate Xcode containers are invalid")
        }
        if kind == "worktree" && !worktreeAuthorized {
          expectedStatus = "blocked"
        } else if !warnings.isEmpty {
          expectedStatus = "degraded"
        } else {
          expectedStatus = "healthy"
        }
      } else {
        errors.insert("resolved project registry requires one exact candidate")
      }
      if reason != "registry_candidate" {
        errors.insert("resolved project registry reason must identify a registry candidate")
      }
    } else if value["candidate"] != nil, !(value["candidate"] is NSNull) {
      errors.insert("unresolved project registry must not select a candidate")
    }
    if let check = checks["repository.project_registry"],
      check["status"] as? String != expectedStatus
    {
      errors.insert("project registry health status does not match its structured resolution")
    }
  }
  private static func strictInteger(_ value: Any?, minimum: Int) -> Int? {
    guard let number = value as? NSNumber, !HarnessRuntime.isBoolean(number) else { return nil }
    let raw = number.stringValue
    guard let integer = Int(raw), raw == String(integer) || raw == "-0", integer >= minimum else {
      return nil
    }
    return integer
  }
  private static func isFingerprint(_ value: Any?) -> Bool {
    guard let string = value as? String else { return false }
    return matches(string, fingerprint)
  }
  private static func matches(_ value: String, _ expression: NSRegularExpression) -> Bool {
    expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
  }
  private static func safeAbsolutePath(_ value: String?) -> Bool {
    guard let value, value.hasPrefix("/"),
      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return false }
    return !URL(fileURLWithPath: value).pathComponents.contains("..")
  }

  private static func blocked(_ report: [String: Any], _ errors: [String]) -> HealthEvaluationResult
  {
    var output = redact(report) as? [String: Any] ?? [:]
    output["overall_status"] = "blocked"
    return .init(report: output, errors: errors.sorted())
  }
  public static func redact(_ value: Any, key: String = "") -> Any {
    if sensitiveKeys.contains(where: { key.lowercased().contains($0) }) { return "[REDACTED]" }
    if let dictionary = value as? [String: Any] {
      return Dictionary(
        uniqueKeysWithValues: dictionary.map { ($0.key, redact($0.value, key: $0.key)) })
    }
    if let array = value as? [Any] { return array.map { redact($0, key: key) } }
    if let string = value as? String {
      return [
        #"\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{8,}\b"#, #"(?i)\bBearer\s+\S+"#,
        #"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----"#,
        #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
      ].reduce(string) {
        $0.replacingOccurrences(of: $1, with: "[REDACTED]", options: .regularExpression)
      }
    }
    return value
  }
}
