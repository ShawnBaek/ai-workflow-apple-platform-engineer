import Darwin
import Foundation

public protocol HealthProbeRunning {
  func run(
    executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
    timeout: TimeInterval, maxOutputBytes: Int
  ) -> ProcessResult
}

public struct HealthMCPProbeResult {
  public let passed: Bool
  public let material: [String: Any]
  public init(passed: Bool, material: [String: Any]) {
    self.passed = passed
    self.material = material
  }
}

/// The transport is injectable so tests never need a live MCP server. The system
/// implementation performs only initialize, notifications/initialized, tools/list,
/// and AppleSampleCode get_status.
public protocol HealthMCPProbing {
  func probeXcode(timeout: TimeInterval) -> HealthMCPProbeResult
  func probeAppleSampleCode(endpoint: URL, timeout: TimeInterval) -> HealthMCPProbeResult
}

enum HealthMCPResponseValidation {
  static func hasResponseID(_ value: [String: Any], _ expected: Int) -> Bool {
    guard let number = value["id"] as? NSNumber, !HarnessRuntime.isBoolean(number) else {
      return false
    }
    return number.stringValue == String(expected)
  }
  static func hasUsableToolResult(_ value: [String: Any]) -> Bool {
    guard value["error"] == nil, let result = value["result"] as? [String: Any],
      result["isError"] as? Bool != true
    else { return false }
    if let structured = result["structuredContent"] as? [String: Any], !structured.isEmpty {
      return true
    }
    guard let content = result["content"] as? [[String: Any]], !content.isEmpty else {
      return false
    }
    return content.contains { item in
      if let text = item["text"] as? String {
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return item["data"] != nil || item["resource"] != nil
    }
  }
}

/// The coordinator must execute the inventory while its CoreSimulator registry lease is live.
/// A health evaluator never falls back to an uncoordinated runtime inventory.
public protocol RuntimeRegistryCoordinating {
  func withRuntimeRegistryAdmission<T>(scope: RuntimeProbeScope, body: ([String: Any]) throws -> T)
    throws -> T
}

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
  private static let xcodeContainer = try! NSRegularExpression(
    pattern:
      #"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[^\u{0000}-\u{001f}\u{007f}]+\.(?:xcodeproj|xcworkspace)$"#)
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

  /// Replaces caller-written results for high-risk checks. The injected runner makes this
  /// function testable without a live account, MCP service, or Simulator.
  public static func collectLiveObservations(
    report: [String: Any], harness: [String: Any], policy: [String: Any],
    authorization: [String: Any]?, runner: HealthProbeRunning,
    runtimeCoordinator: RuntimeRegistryCoordinating? = nil, runtimeScope: RuntimeProbeScope? = nil,
    mcpProbe: HealthMCPProbing = SystemHealthMCPProbe(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: [String: Any]] {
    let required = Set(report["required_check_ids"] as? [String] ?? []).intersection(
      evaluatorOwnedChecks)
    var observations: [String: [String: Any]] = [:]
    func record(_ id: String, _ passed: Bool, _ reason: String, _ material: Any) {
      observations[id] = liveObservation(
        id, status: passed ? "healthy" : "blocked", reason: passed ? reason : "\(reason)_blocked",
        material: material,
        summary: passed
          ? "Evaluator confirmed \(id)." : "Required live \(id) observation failed closed.")
    }
    if required.contains("simulator.runtime") {
      if let coordinator = runtimeCoordinator, let scope = runtimeScope, scope.isWellFormed {
        do {
          try coordinator.withRuntimeRegistryAdmission(scope: scope) { receipt in
            let result = runner.run(
              executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "runtimes", "--json"],
              directory: nil, environment: nil, timeout: 30, maxOutputBytes: 1_048_576)
            guard result.exitCode == 0, !result.timedOut, !result.truncated,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)),
              let body = json as? [String: Any], let runtimes = body["runtimes"] as? [[String: Any]]
            else {
              record(
                "simulator.runtime", false, "simulator_inventory",
                ["receipt": receipt, "malformed": true])
              return
            }
            let identifier = scope.descriptor["runtime_identifier"] as! String
            let platform = scope.descriptor["platform"] as! String
            let destination = scope.descriptor["destination_id"] as! String
            let exact = runtimes.filter { runtime in
              runtime["identifier"] as? String == identifier
                && runtime["isAvailable"] as? Bool != false
                && ((runtime["platform"] as? String == platform)
                  || (runtime["identifier"] as? String)?.localizedCaseInsensitiveContains(platform)
                    == true)
            }
            guard exact.count == 1 else {
              record(
                "simulator.runtime", false, "selected_runtime_not_resolved",
                ["receipt": receipt, "platform": platform, "destination_sha256": sha(destination)])
              return
            }
            let devicesResult = runner.run(
              executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "--json"],
              directory: nil, environment: nil, timeout: 30, maxOutputBytes: 1_048_576)
            guard devicesResult.exitCode == 0, !devicesResult.timedOut, !devicesResult.truncated,
              let devicesJSON = try? JSONSerialization.jsonObject(
                with: Data(devicesResult.stdout.utf8)) as? [String: Any],
              let byRuntime = devicesJSON["devices"] as? [String: Any],
              let devices = byRuntime[identifier] as? [[String: Any]],
              devices.filter({
                $0["udid"] as? String == destination && $0["isAvailable"] as? Bool != false
              }).count == 1
            else {
              record(
                "simulator.runtime", false, "selected_destination_not_resolved",
                ["receipt": receipt, "platform": platform, "destination_sha256": sha(destination)])
              return
            }
            record(
              "simulator.runtime", true, "coordinated_exact_runtime_inventory",
              [
                "receipt": receipt, "runtime_sha256": sha(identifier), "platform": platform,
                "destination_sha256": sha(destination),
              ])
          }
        } catch {
          record(
            "simulator.runtime", false, "runtime_registry_ownership",
            ["error": String(describing: type(of: error))])
        }
      } else {
        record(
          "simulator.runtime", false, "runtime_registry_ownership",
          ["reason": "missing_or_invalid_trusted_scope"])
      }
    }
    let githubChecks = required.intersection(["github.issue_pr", "github.project"])
    if !githubChecks.isEmpty {
      let remote = (report["authoritative_targets"] as? [String: Any])?["remote"] as? String ?? ""
      let owner = ((policy["github"] as? [String: Any])?["owner"] as? String ?? "").lowercased()
      do {
        let repository = try githubRepository(remote)
        guard repository.split(separator: "/", maxSplits: 1).first?.lowercased() == owner,
          !owner.isEmpty
        else { throw ProbeError.invalid }
        let identity = try successful(
          runner.run(
            executable: "gh", arguments: ["api", "user", "--jq", ".login"], directory: nil,
            environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
        let repositoryResult = try successful(
          runner.run(
            executable: "gh",
            arguments: [
              "repo", "view", repository, "--json",
              "nameWithOwner,viewerPermission,hasIssuesEnabled",
            ], directory: nil, environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
        let repositoryValue = try jsonObject(repositoryResult.stdout)
        guard identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == owner,
          (repositoryValue["nameWithOwner"] as? String)?.lowercased() == repository.lowercased(),
          repositoryValue["hasIssuesEnabled"] as? Bool == true,
          ["WRITE", "MAINTAIN", "ADMIN"].contains(
            repositoryValue["viewerPermission"] as? String ?? "")
        else { throw ProbeError.mismatch }
        if githubChecks.contains("github.issue_pr") {
          record(
            "github.issue_pr", true, "exact_repository_access",
            [
              "owner_match": true, "repository_match": true, "issues": true,
              "permission": repositoryValue["viewerPermission"]!,
            ])
        }
        if githubChecks.contains("github.project") {
          let project = (harness["github_tracking"] as? [String: Any])?["project"] as? [String: Any]
          guard let number = strictPositiveInteger(project?["number"]),
            let projectOwner = (project?["owner"] as? String) ?? (owner.isEmpty ? nil : owner)
          else { throw ProbeError.invalid }
          let result = try successful(
            runner.run(
              executable: "gh",
              arguments: [
                "project", "view", String(number), "--owner", projectOwner, "--format", "json",
              ], directory: nil, environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
          let value = try jsonObject(result.stdout)
          guard strictPositiveInteger(value["number"]) == number else { throw ProbeError.mismatch }
          record(
            "github.project", true, "exact_project_access",
            ["owner": projectOwner.lowercased(), "number": number])
        }
      } catch {
        for id in githubChecks where observations[id] == nil {
          record(id, false, "github_probe", ["error_class": probeErrorClass(error)])
        }
      }
    }
    let xcode = required.intersection(["xcode.authoritative_container", "apple.execution_path"])
    if !xcode.isEmpty {
      do {
        let selected = try successful(
          runner.run(
            executable: "/usr/bin/xcode-select", arguments: ["-p"], directory: nil,
            environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
        let found = try successful(
          runner.run(
            executable: "/usr/bin/xcrun", arguments: ["--find", "xcodebuild"], directory: nil,
            environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
        let developer = selected.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !developer.isEmpty, !executable.isEmpty,
          executable.hasPrefix(developer.hasSuffix("/") ? developer : developer + "/")
        else { throw ProbeError.mismatch }
        let version = try successful(
          runner.run(
            executable: executable, arguments: ["-version"], directory: nil, environment: nil,
            timeout: 15, maxOutputBytes: 1_048_576))
        guard !version.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw ProbeError.invalid
        }
        let material = [
          "developer_sha256": sha(developer), "xcodebuild_sha256": sha(executable),
          "version_sha256": sha(version.stdout),
        ]
        xcode.forEach { record($0, true, "selected_xcode_toolchain", material) }
      } catch {
        xcode.forEach { record($0, false, "xcode_probe", ["error_class": probeErrorClass(error)]) }
      }
    }
    let appleChecks: Set<String> = [
      "apple.account_guard", "cli.asc", "testflight.upload_target", "testflight.internal_groups",
    ]
    let selectedApple = required.intersection(appleChecks)
    if !selectedApple.isEmpty {
      do {
        guard let policyApple = policy["apple"] as? [String: Any],
          let authorizedApple = authorization?["apple"] as? [String: Any],
          let profile = policyApple["account_guard_ref"] as? String, !profile.isEmpty,
          authorizedApple["account_guard_ref"] as? String == profile,
          authorizedApple["team_id"] as? String == policyApple["team_id"] as? String
        else { throw ProbeError.mismatch }
        if selectedApple.contains("apple.account_guard") {
          record(
            "apple.account_guard", true, "private_guard_match",
            ["team_match": true, "profile_sha256": sha(profile)])
        }
        let auth = try successful(
          runner.run(
            executable: "asc", arguments: ["--profile", profile, "auth", "status", "--validate"],
            directory: nil, environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
        if selectedApple.contains("cli.asc") {
          record("cli.asc", true, "guarded_auth_validation", ["status_sha256": sha(auth.stdout)])
        }
        if !selectedApple.intersection(["testflight.upload_target", "testflight.internal_groups"])
          .isEmpty
        {
          guard let appID = authorizedApple["app_id"] as? String, !appID.isEmpty,
            let bundle = authorizedApple["bundle_id"] as? String, !bundle.isEmpty
          else { throw ProbeError.invalid }
          let apps = try successful(
            runner.run(
              executable: "asc",
              arguments: ["--profile", profile, "apps", "list", "--paginate", "--output", "json"],
              directory: nil, environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
          let rows = try jsonObject(apps.stdout)["data"] as? [[String: Any]] ?? []
          guard
            rows.filter({
              ($0["id"] as? String) == appID
                && (($0["attributes"] as? [String: Any])?["bundleId"] as? String) == bundle
            }).count == 1
          else { throw ProbeError.mismatch }
          if selectedApple.contains("testflight.upload_target") {
            record(
              "testflight.upload_target", true, "exact_app_target",
              ["app_id": appID, "bundle_match": true])
          }
          if selectedApple.contains("testflight.internal_groups") {
            let groups = try successful(
              runner.run(
                executable: "asc",
                arguments: [
                  "--profile", profile, "testflight", "beta-groups", "list", "--app", appID,
                  "--paginate", "--output", "json",
                ], directory: nil, environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
            let live = Set(
              (try jsonObject(groups.stdout)["data"] as? [[String: Any]] ?? []).compactMap {
                $0["id"] as? String
              })
            let expected = Set(authorizedApple["internal_group_ids"] as? [String] ?? [])
            guard !expected.isEmpty, expected.isSubset(of: live) else { throw ProbeError.mismatch }
            record(
              "testflight.internal_groups", true, "exact_internal_groups",
              ["group_ids": expected.sorted()])
          }
        }
      } catch {
        for id in selectedApple where observations[id] == nil {
          record(id, false, "apple_probe", ["error_class": probeErrorClass(error)])
        }
      }
    }

    if required.contains("mcp.xcode") {
      let registration = probeRegistration(
        harness: harness, name: "xcode", expectedFragments: ["xcrun", "mcpbridge"], runner: runner)
      let connection =
        registration.passed
        ? mcpProbe.probeXcode(timeout: 15)
        : .init(passed: false, material: ["failure": "registration_blocked"])
      record(
        "mcp.xcode", registration.passed && connection.passed, "registration_and_read_only_tools",
        ["registration": registration.material, "connection": connection.material])
    }
    if required.contains("mcp.apple_sample_code") {
      let endpoint = URL(string: "https://mcp.applesamplecode.com/mcp")!
      let registration = probeRegistration(
        harness: harness, name: "apple-sample-code", expectedFragments: [endpoint.absoluteString],
        runner: runner)
      let connection =
        registration.passed
        ? mcpProbe.probeAppleSampleCode(endpoint: endpoint, timeout: 15)
        : .init(passed: false, material: ["failure": "registration_blocked"])
      record(
        "mcp.apple_sample_code", registration.passed && connection.passed,
        "registration_tools_and_get_status",
        ["registration": registration.material, "connection": connection.material])
    }
    if required.contains("spec_kit.snapshot") {
      do {
        let result = try collectSpecKitSnapshot(
          report: report, harness: harness, authorization: authorization)
        record("spec_kit.snapshot", result.passed, "approved_snapshot_readback", result.material)
      } catch {
        record(
          "spec_kit.snapshot", false, "spec_kit_snapshot", ["error_class": probeErrorClass(error)])
      }
    }
    if required.contains("local_llm") {
      do {
        let material = try collectLocalLLM(runner: runner, environment: environment)
        record("local_llm", true, "local_model_inventory", material)
      } catch {
        record("local_llm", false, "local_llm_inventory", ["error_class": probeErrorClass(error)])
      }
    }
    if required.contains("companion_upstream.provenance") {
      do {
        let result = try collectCompanionUpstream(harness: harness, runner: runner)
        record(
          "companion_upstream.provenance", result.passed, "public_provenance_readback",
          result.material)
      } catch {
        record(
          "companion_upstream.provenance", false, "companion_upstream",
          ["error_class": probeErrorClass(error)])
      }
    }
    return observations
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
    mcpProbe: HealthMCPProbing = SystemHealthMCPProbe(),
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
      mcpProbe: mcpProbe, environment: environment)
    return evaluate(
      reconcile(report: report, observations: observations), now: now,
      evaluatorObservedCheckIDs: Set(observations.keys))
  }

  /// Command entrypoint. It reads only explicitly named regular JSON files and prints one
  /// redacted result object; it never repairs an installation or creates a runtime scope.
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    var values: [String: String] = [:]
    var positionals: [String] = []
    var observeSkills = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--observe-agent-skills" {
        guard !observeSkills else {
          throw VerificationError.invalid("duplicate --observe-agent-skills")
        }
        observeSkills = true
        index += 1
        continue
      }
      if ["--report", "--harness", "--expected-report-bytes-sha256"].contains(argument) {
        guard values[argument] == nil, index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--")
        else { throw VerificationError.invalid("missing or duplicate value for \(argument)") }
        values[argument] = arguments[index + 1]
        index += 2
        continue
      }
      if argument.hasPrefix("--") {
        throw VerificationError.invalid("unknown health option: \(argument)")
      }
      positionals.append(argument)
      index += 1
    }
    guard positionals.count <= 1, values["--report"] == nil || positionals.isEmpty,
      let harnessPath = values["--harness"]
    else { throw VerificationError.invalid("health requires one report and --harness") }
    let harnessURL = URL(fileURLWithPath: harnessPath)
    let harness = try ResourceCoordinator.loadTrustedHarness(
      harnessPath: harnessURL, context: context)
    if observeSkills {
      guard values["--report"] == nil, positionals.isEmpty else {
        throw VerificationError.invalid("--observe-agent-skills does not accept a report")
      }
      do {
        _ = try HealthCollection.observeResourceCoordinator(harness: harness, context: context)
        print(
          String(
            data: try HarnessRuntime.canonicalJSON([
              "manifest": try HealthCollection.observeAgentSkills(
                harness: harness, enforceExpected: false), "valid": true, "errors": [] as [String],
            ]), encoding: .utf8)!)
        return 0
      } catch {
        print(
          String(
            data: try HarnessRuntime.canonicalJSON([
              "manifest": NSNull(), "valid": false,
              "errors": ["live installed agent skill observation failed"],
            ]), encoding: .utf8)!)
        return 2
      }
    }
    guard let reportPath = values["--report"] ?? positionals.first else {
      throw VerificationError.invalid("health requires one report")
    }
    let reportURL = URL(fileURLWithPath: reportPath)
    guard let policyPath = harness["private_policy_overlay"] as? String else {
      throw VerificationError.invalid("trusted policy path is unavailable")
    }
    let privateRoot = harnessURL.deletingLastPathComponent().resolvingSymlinksInPath()
    func privateObject(_ path: String, label: String) throws -> [String: Any] {
      let url = URL(fileURLWithPath: path)
      guard path.hasPrefix("/"),
        url.deletingLastPathComponent().resolvingSymlinksInPath() == privateRoot
      else { throw VerificationError.invalid("trusted \(label) path is unsafe") }
      return try boundedJSONObject(url, maximumBytes: 8 * 1_024 * 1_024, requireSingleLink: true)
    }
    let policy = try privateObject(policyPath, label: "policy")
    guard HealthCollection.trustedPolicyErrors(policy: policy, harness: harness).isEmpty else {
      throw VerificationError.invalid("private policy overlay is not approved or bounded")
    }
    var authorization: [String: Any]?
    if let authorizationPath = harness["run_authorization"] as? String {
      let url = URL(fileURLWithPath: authorizationPath)
      if FileManager.default.fileExists(atPath: url.path) {
        authorization = try privateObject(authorizationPath, label: "authorization")
      }
    }
    let expected = values["--expected-report-bytes-sha256"]
    let scope: RuntimeProbeScope? = {
      guard let value = harness["runtime_probe_scope"] as? [String: Any],
        let state = value["state_path"] as? String,
        let descriptor = value["descriptor"] as? [String: Any],
        let run = value["owner_run_id"] as? String,
        let actor = value["owner_actor"] as? String,
        let authority = value["run_authority"] as? [String: Any],
        let ttl = strictPositiveInteger(value["ttl_seconds"])
      else { return nil }
      return RuntimeProbeScope(
        statePath: URL(fileURLWithPath: state), descriptor: descriptor, ownerRunID: run,
        ownerActor: actor, ttlSeconds: ttl, runAuthority: authority)
    }()
    let result = revalidate(
      reportBytes: try boundedRegularFile(
        reportURL, maximumBytes: 32 * 1_024 * 1_024, requireSingleLink: false),
      expectedBytesSHA256: expected, harness: harness, policy: policy, authorization: authorization,
      runner: SystemHealthRunner(),
      runtimeCoordinator: scope == nil ? nil : ResourceCoordinatorRuntimeAdmission(),
      runtimeScope: scope, context: context)
    let output: [String: Any] = [
      "report": result.report, "valid": result.valid, "errors": result.errors,
    ]
    print(String(data: try HarnessRuntime.canonicalJSON(output), encoding: .utf8)!)
    return result.valid ? 0 : 2
  }

  private enum ProbeError: Error { case timeout, unavailable, failed, truncated, invalid, mismatch }

  private static func successful(_ result: ProcessResult) throws -> ProcessResult {
    if result.timedOut { throw ProbeError.timeout }
    if result.truncated { throw ProbeError.truncated }
    guard result.exitCode == 0 else { throw ProbeError.failed }
    return result
  }

  private static func probeErrorClass(_ error: Error) -> String {
    if let error = error as? ProbeError {
      switch error {
      case .timeout: return "timeout"
      case .unavailable: return "command_unavailable"
      case .failed: return "command_failed"
      case .truncated: return "output_truncated"
      case .invalid: return "invalid_response"
      case .mismatch: return "identity_mismatch"
      }
    }
    return String(describing: type(of: error))
  }

  private static func jsonObject(_ text: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { throw ProbeError.invalid }
    return value
  }

  private static func strictPositiveInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !HarnessRuntime.isBoolean(number) else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double, double >= 1, double <= Double(Int.max) else {
      return nil
    }
    return Int(double)
  }

  private static func githubRepository(_ remote: String) throws -> String {
    guard !remote.isEmpty, !remote.contains(where: { $0.isWhitespace }), !remote.contains("?"),
      !remote.contains("#")
    else { throw ProbeError.invalid }
    let path: String
    if remote.hasPrefix("git@github.com:") {
      path = String(remote.dropFirst("git@github.com:".count))
    } else {
      guard let components = URLComponents(string: remote),
        ["https", "ssh"].contains(components.scheme ?? ""), components.host == "github.com",
        components.password == nil,
        components.scheme != "https" || components.user == nil,
        components.scheme != "ssh" || components.user == nil || components.user == "git",
        components.port == nil || (components.scheme == "https" && components.port == 443)
          || (components.scheme == "ssh" && components.port == 22)
      else { throw ProbeError.invalid }
      path = String(components.path.drop(while: { $0 == "/" }))
    }
    let normalized = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
    guard
      normalized.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression)
        != nil
    else { throw ProbeError.invalid }
    return normalized
  }

  private static func probeRegistration(
    harness: [String: Any], name: String, expectedFragments: [String], runner: HealthProbeRunning
  ) -> HealthMCPProbeResult {
    let installations =
      (harness["agent_skills"] as? [String: Any])?["installations"] as? [String: Any] ?? [:]
    var material: [[String: Any]] = []
    for client in ["codex", "claude"]
    where installations[client] != nil && !(installations[client] is NSNull) {
      let executable = client == "codex" ? "codex" : "claude"
      let arguments = client == "codex" ? ["mcp", "get", name, "--json"] : ["mcp", "get", name]
      do {
        let result = try successful(
          runner.run(
            executable: executable, arguments: arguments, directory: nil, environment: nil,
            timeout: 15, maxOutputBytes: 1_048_576))
        let combined = result.stdout + "\n" + result.stderr
        guard expectedFragments.allSatisfy(combined.contains) else {
          return .init(
            passed: false, material: ["client": client, "failure": "registration_drift"])
        }
        material.append(["client": client, "registration_sha256": sha(combined)])
      } catch {
        return .init(
          passed: false, material: ["client": client, "failure": probeErrorClass(error)])
      }
    }
    return material.isEmpty
      ? .init(passed: false, material: ["failure": "no_selected_client"])
      : .init(passed: true, material: ["clients": material])
  }

  private static func selectedWriterSkillPath(harness: [String: Any], name: String) throws -> URL {
    guard let writer = harness["selected_writer"] as? String, ["codex", "claude"].contains(writer),
      let installations = (harness["agent_skills"] as? [String: Any])?["installations"]
        as? [String: Any],
      let installation = installations[writer] as? [String: Any]
    else { throw ProbeError.invalid }
    let roots: [String]
    if let root = installation["collection_root"] as? String {
      roots = [root]
    } else {
      roots = installation["search_roots"] as? [String] ?? []
    }
    let candidates = roots.map {
      URL(fileURLWithPath: $0).appendingPathComponent(name, isDirectory: true)
    }.filter {
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    guard candidates.count == 1 else { throw ProbeError.mismatch }
    return candidates[0].resolvingSymlinksInPath()
  }

  private static func collectSpecKitSnapshot(
    report: [String: Any], harness: [String: Any], authorization: [String: Any]?
  ) throws -> HealthMCPProbeResult {
    guard ((harness["spec_kit"] as? [String: Any])?["enabled"] as? Bool) == true,
      let binding = authorization?["spec_kit"] as? [String: Any],
      let root = (report["authoritative_targets"] as? [String: Any])?["repository"] as? String,
      root.hasPrefix("/"),
      let featureDirectory = binding["feature_directory"] as? String,
      let release = binding["release"] as? String
    else { throw ProbeError.invalid }
    let current = try SpecKitSnapshot.buildSnapshot(
      root: URL(fileURLWithPath: root, isDirectory: true), release: release,
      runID: binding["workflow_run_id"] as? String, featureDirectory: featureDirectory)
    let expectedKeys = [
      "spec_kit_release": "release", "feature_id": "feature_id",
      "feature_directory": "feature_directory", "artifact_hashes": "artifact_hashes",
      "snapshot_sha256": "snapshot_sha256",
    ]
    let matches = expectedKeys.allSatisfy { currentKey, bindingKey in
      guard let currentValue = current[currentKey], let expectedValue = binding[bindingKey] else {
        return false
      }
      return JSONSchemaValidator.equal(currentValue, expectedValue)
    }
    return .init(
      passed: matches,
      material: [
        "feature_id": current["feature_id"] ?? NSNull(),
        "feature_directory": current["feature_directory"] ?? NSNull(),
        "snapshot_sha256": current["snapshot_sha256"] ?? NSNull(),
        "workflow_run_id": binding["workflow_run_id"] ?? NSNull(), "matches_authorization": matches,
      ])
  }

  private static func collectLocalLLM(runner: HealthProbeRunning, environment: [String: String])
    throws -> [String: Any]
  {
    var candidate = environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
    if !candidate.contains("://") { candidate = "http://" + candidate }
    guard let endpoint = URLComponents(string: candidate),
      ["http", "https"].contains(endpoint.scheme ?? ""), endpoint.user == nil,
      endpoint.password == nil,
      endpoint.query == nil, endpoint.fragment == nil,
      endpoint.path.isEmpty || endpoint.path == "/", let host = endpoint.host, isLoopback(host)
    else { throw ProbeError.invalid }
    let result = try successful(
      runner.run(
        executable: "ollama", arguments: ["list"], directory: nil, environment: nil, timeout: 15,
        maxOutputBytes: 1_048_576))
    let lines = result.stdout.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard lines.first?.split(whereSeparator: \.isWhitespace).first?.uppercased() == "NAME" else {
      throw ProbeError.invalid
    }
    let models = lines.dropFirst().compactMap {
      $0.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
    guard !models.isEmpty else { throw ProbeError.invalid }
    return [
      "provider": "ollama", "endpoint_scope": "loopback", "model_count": models.count,
      "model_names_sha256": sha(models.sorted().joined(separator: ",")),
    ]
  }

  private static func isLoopback(_ host: String) -> Bool {
    let host =
      host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    if host.lowercased() == "localhost" { return true }
    var address4 = in_addr()
    var address6 = in6_addr()
    if inet_pton(AF_INET, host, &address4) == 1 {
      return (UInt32(bigEndian: address4.s_addr) >> 24) == 127
    }
    if inet_pton(AF_INET6, host, &address6) == 1 {
      return withUnsafeBytes(of: &address6) { bytes in
        bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
      }
    }
    return false
  }

  private static func collectCompanionUpstream(harness: [String: Any], runner: HealthProbeRunning)
    throws -> HealthMCPProbeResult
  {
    let manifestURL = try selectedWriterSkillPath(harness: harness, name: "icon-composer")
      .appendingPathComponent("contracts/companion-upstream.json")
    let schemaURL = manifestURL.deletingLastPathComponent().appendingPathComponent(
      "companion-upstream.schema.json")
    let info = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let schemaInfo = try schemaURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard info.isRegularFile == true, info.isSymbolicLink != true, schemaInfo.isRegularFile == true,
      schemaInfo.isSymbolicLink != true,
      let manifest = try? boundedJSONObject(
        manifestURL, maximumBytes: 1_048_576, requireSingleLink: false),
      let schema = try? boundedJSONObject(
        schemaURL, maximumBytes: 1_048_576, requireSingleLink: false),
      JSONSchemaValidator.errors(instance: manifest, schema: schema, path: "$", root: nil).isEmpty,
      let upstream = manifest["upstream"] as? [String: Any],
      let sources = manifest["sources"] as? [[String: Any]],
      let repository = upstream["repository"] as? String, !repository.isEmpty,
      let reviewed = upstream["reviewed_revision"] as? String, !reviewed.isEmpty,
      let reviewedTree = upstream["reviewed_tree"] as? String, !reviewedTree.isEmpty,
      let branch = upstream["default_branch"] as? String, !branch.isEmpty
    else { throw ProbeError.invalid }
    func gh(_ route: String) throws -> [String: Any] {
      try jsonObject(
        successful(
          runner.run(
            executable: "gh", arguments: ["api", route], directory: nil, environment: nil,
            timeout: 15, maxOutputBytes: 1_048_576)
        ).stdout)
    }
    let metadata = try gh("repos/\(repository)")
    let commit = try gh("repos/\(repository)/commits/\(reviewed)")
    let tree = try gh("repos/\(repository)/git/trees/\(reviewedTree)?recursive=1")
    let head = try gh("repos/\(repository)/commits/\(branch)")
    var blobs: [String: String] = [:]
    for item in tree["tree"] as? [[String: Any]] ?? [] where item["type"] as? String == "blob" {
      guard let path = item["path"] as? String, let digest = item["sha"] as? String,
        blobs[path] == nil
      else { throw ProbeError.invalid }
      blobs[path] = digest
    }
    let sourcesMatch =
      !sources.isEmpty
      && sources.allSatisfy { source in
        guard let path = source["path"] as? String, let digest = source["blob_sha"] as? String
        else { return false }
        return blobs[path] == digest
      }
    let commitTree =
      ((commit["commit"] as? [String: Any])?["tree"] as? [String: Any])?["sha"] as? String
    let valid =
      metadata["private"] as? Bool == false && metadata["visibility"] as? String == "public"
      && metadata["default_branch"] as? String == branch && commit["sha"] as? String == reviewed
      && commitTree == reviewedTree && (head["sha"] as? String)?.isEmpty == false && sourcesMatch
    return .init(
      passed: valid,
      material: [
        "repository": repository, "reviewed_revision": reviewed, "reviewed_tree": reviewedTree,
        "observed_head": head["sha"] ?? NSNull(), "sources_match": sourcesMatch,
      ])
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
  private static func boundedJSONObject(_ url: URL, maximumBytes: Int, requireSingleLink: Bool)
    throws -> [String: Any]
  {
    let data = try boundedRegularFile(
      url, maximumBytes: maximumBytes, requireSingleLink: requireSingleLink)
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw VerificationError.invalid("bounded JSON input must contain an object")
    }
    return value
  }
  private static func boundedRegularFile(_ url: URL, maximumBytes: Int, requireSingleLink: Bool)
    throws -> Data
  {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw VerificationError.invalid("bounded input cannot be opened safely")
    }
    defer { close(descriptor) }
    var opened = stat()
    var named = stat()
    guard fstat(descriptor, &opened) == 0, lstat(url.path, &named) == 0,
      opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
      !requireSingleLink || (opened.st_nlink == 1 && named.st_nlink == 1),
      opened.st_size >= 0, opened.st_size <= maximumBytes
    else { throw VerificationError.invalid("bounded input is not a safe regular file") }
    var output = Data()
    output.reserveCapacity(Int(opened.st_size))
    var buffer = [UInt8](repeating: 0, count: min(maximumBytes + 1, 1_048_576))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw VerificationError.invalid("bounded input read failed") }
      if count == 0 { break }
      guard output.count <= maximumBytes - count else {
        throw VerificationError.invalid("bounded input exceeds its read limit")
      }
      output.append(contentsOf: buffer.prefix(count))
    }
    guard output.count == Int(opened.st_size), lstat(url.path, &named) == 0,
      named.st_dev == opened.st_dev, named.st_ino == opened.st_ino
    else { throw VerificationError.invalid("bounded input changed while reading") }
    return output
  }
  private static func liveObservation(
    _ id: String, status: String, reason: String, material: Any, summary: String
  ) -> [String: Any] {
    let encoded =
      (try? HarnessRuntime.canonicalJSON(redact(material)))
      ?? Data("health-observation-encoding-failed".utf8)
    let digest = HarnessRuntime.sha256(encoded)
    var observation: [String: Any] = [
      "id": id, "status": status, "reason_code": reason, "summary": summary,
      "evidence": ["evaluator-live:\(id):\(reason):sha256:\(digest)"],
    ]
    if status != "healthy" {
      observation["next_action"] =
        "Repair or reconnect only this exact required surface, then run the bounded read-only health probe again."
    }
    return observation
  }
  private static func sha(_ value: String) -> String {
    "sha256:\(HarnessRuntime.sha256(Data(value.utf8)))"
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

public struct SystemHealthRunner: HealthProbeRunning {
  public init() {}
  public func run(
    executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
    timeout: TimeInterval, maxOutputBytes: Int
  ) -> ProcessResult {
    (try? HarnessRuntime.run(
      executable: executable, arguments: arguments, directory: directory, environment: environment,
      timeout: timeout, maxOutputBytes: maxOutputBytes))
      ?? ProcessResult(
        stdout: "", stderr: "probe invocation failed", exitCode: 127, timedOut: false,
        truncated: false)
  }
}

public struct SystemHealthMCPProbe: HealthMCPProbing {
  public init() {}

  public func probeXcode(timeout: TimeInterval) -> HealthMCPProbeResult {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["mcpbridge"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do {
      try process.run()
      let messages: [[String: Any]] = [
        [
          "jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "ios-experts-health", "version": "1.0.0"],
          ],
        ],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()],
      ]
      var request = Data()
      for message in messages {
        request.append(try HarnessRuntime.canonicalJSON(message))
        request.append(10)
      }
      try input.fileHandleForWriting.write(contentsOf: request)
      let descriptor = output.fileHandleForReading.fileDescriptor
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
      let deadline = Date().addingTimeInterval(timeout)
      var pending = Data()
      var responses: [[String: Any]] = []
      while responses.count < 2, Date() < deadline, process.isRunning {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
          pending.append(contentsOf: bytes.prefix(count))
          guard pending.count <= 1_048_576 else { throw MCPFailure.response }
          while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              value["id"] != nil
            {
              responses.append(value)
            }
          }
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
          throw MCPFailure.io
        }
        if responses.count < 2 { usleep(10_000) }
      }
      guard responses.count == 2 else { throw MCPFailure.timeout }
      let initialized = responses[0]
      let listed = responses[1]
      guard HealthMCPResponseValidation.hasResponseID(initialized, 1),
        HealthMCPResponseValidation.hasResponseID(listed, 2), initialized["error"] == nil,
        listed["error"] == nil,
        let tools = (listed["result"] as? [String: Any])?["tools"] as? [[String: Any]],
        !tools.isEmpty
      else { throw MCPFailure.response }
      stop(process)
      return .init(
        passed: true,
        material: [
          "server": (initialized["result"] as? [String: Any])?["serverInfo"] ?? NSNull(),
          "tool_count": tools.count,
        ])
    } catch {
      stop(process)
      return .init(passed: false, material: ["error_class": errorClass(error)])
    }
  }

  public func probeAppleSampleCode(endpoint: URL, timeout: TimeInterval) -> HealthMCPProbeResult {
    do {
      let initialized = try post(
        endpoint: endpoint,
        payload: [
          "jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "ios-experts-health", "version": "1.0.0"],
          ],
        ], sessionID: nil, timeout: timeout)
      guard HealthMCPResponseValidation.hasResponseID(initialized.value, 1),
        initialized.value["error"] == nil, initialized.value["result"] != nil
      else { throw MCPFailure.response }
      _ = try post(
        endpoint: endpoint, payload: ["jsonrpc": "2.0", "method": "notifications/initialized"],
        sessionID: initialized.sessionID, timeout: timeout)
      let listed = try post(
        endpoint: endpoint,
        payload: ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()],
        sessionID: initialized.sessionID, timeout: timeout)
      let names = Set(
        ((listed.value["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap
        { $0["name"] as? String })
      let required = Set(["search_samples", "get_sample", "compare_samples", "get_status"])
      guard HealthMCPResponseValidation.hasResponseID(listed.value, 2),
        listed.value["error"] == nil, required.isSubset(of: names)
      else { throw MCPFailure.response }
      let status = try post(
        endpoint: endpoint,
        payload: [
          "jsonrpc": "2.0", "id": 3, "method": "tools/call",
          "params": ["name": "get_status", "arguments": ["refresh": false]],
        ], sessionID: listed.sessionID, timeout: timeout)
      guard HealthMCPResponseValidation.hasResponseID(status.value, 3),
        HealthMCPResponseValidation.hasUsableToolResult(status.value)
      else { throw MCPFailure.response }
      return .init(
        passed: true,
        material: [
          "endpoint": endpoint.absoluteString,
          "server": (initialized.value["result"] as? [String: Any])?["serverInfo"] ?? NSNull(),
          "tools": required.sorted(), "status": status.value["result"] ?? NSNull(),
        ])
    } catch { return .init(passed: false, material: ["error_class": errorClass(error)]) }
  }

  private enum MCPFailure: Error { case timeout, io, response }
  private final class HTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0), limit: Int
    let lock = NSLock()
    var data = Data()
    var response: HTTPURLResponse?
    var error: Error?
    init(limit: Int) { self.limit = limit }
    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      lock.lock()
      self.response = response as? HTTPURLResponse
      lock.unlock()
      completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
      lock.lock()
      if data.count + bytes.count > limit {
        error = MCPFailure.response
        lock.unlock()
        dataTask.cancel()
        return
      }
      data.append(bytes)
      lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      lock.lock()
      if self.error == nil { self.error = error }
      lock.unlock()
      semaphore.signal()
    }
  }
  private func post(
    endpoint: URL, payload: [String: Any], sessionID: String?, timeout: TimeInterval
  ) throws -> (value: [String: Any], sessionID: String?) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    request.httpBody = try HarnessRuntime.canonicalJSON(payload)
    let delegate = HTTPDelegate(limit: 2_000_000)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    task.resume()
    guard delegate.semaphore.wait(timeout: .now() + timeout + 1) == .success else {
      task.cancel()
      session.invalidateAndCancel()
      throw MCPFailure.timeout
    }
    session.finishTasksAndInvalidate()
    guard delegate.error == nil, let response = delegate.response,
      (200..<300).contains(response.statusCode), delegate.data.count <= 2_000_000,
      !task.progress.isCancelled,
      let body = String(data: delegate.data, encoding: .utf8), let value = extractJSONRPC(body)
    else { throw MCPFailure.response }
    return (value, response.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID)
  }
  private func extractJSONRPC(_ body: String) -> [String: Any]? {
    let stripped = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if stripped.isEmpty { return [:] }
    let lines = stripped.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
      var value = raw.trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("data:") {
        value = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      }
      return value.hasPrefix("{") ? value : nil
    }
    for candidate in (lines.isEmpty ? [stripped] : lines).reversed() {
      if let value = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any]
      {
        return value
      }
    }
    return nil
  }
  private func stop(_ process: Process) {
    if process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(2)
      while process.isRunning, Date() < deadline { usleep(10_000) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
  }
  private func errorClass(_ error: Error) -> String {
    guard let failure = error as? MCPFailure else { return String(describing: type(of: error)) }
    switch failure {
    case .timeout: return "timeout"
    case .io: return "io_error"
    case .response: return "invalid_response"
    }
  }
}

public struct ResourceCoordinatorRuntimeAdmission: RuntimeRegistryCoordinating {
  public init() {}
  public func withRuntimeRegistryAdmission<T>(
    scope: RuntimeProbeScope, body: ([String: Any]) throws -> T
  ) throws -> T {
    try ResourceCoordinator.withRuntimeRegistryAdmission(
      statePath: scope.statePath, descriptor: scope.descriptor, ownerRunID: scope.ownerRunID,
      ownerActor: scope.ownerActor, ttlSeconds: scope.ttlSeconds, runAuthority: scope.runAuthority,
      body: body
    )
  }
}
