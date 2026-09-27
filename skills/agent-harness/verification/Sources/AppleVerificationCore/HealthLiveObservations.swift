import Foundation

extension HealthEvaluation {
  /// Replaces caller-written results for high-risk checks. The injected runner makes this
  /// function testable without a live account, MCP service, or Simulator.
  public static func collectLiveObservations(
    report: [String: Any], harness: [String: Any], policy: [String: Any],
    authorization: [String: Any]?, runner: HealthProbeRunning,
    runtimeCoordinator: RuntimeRegistryCoordinating? = nil, runtimeScope: RuntimeProbeScope? = nil,
    mcpProbe: HealthMCPProbing = SystemHealthMCPProbe(), liveXcodeBridgeProbe: Bool = false,
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
      if let scope = runtimeScope, scope.isWellFormed,
        scope.ttlSeconds < minimumRuntimeProbeTTLSeconds
      {
        record(
          "simulator.runtime", false, "runtime_probe_lease_too_short",
          ["ttl_seconds": scope.ttlSeconds, "minimum_ttl_seconds": minimumRuntimeProbeTTLSeconds])
      } else if let coordinator = runtimeCoordinator, let scope = runtimeScope, scope.isWellFormed {
        do {
          try coordinator.withRuntimeRegistryAdmission(scope: scope) { receipt in
            let result = runner.run(
              executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "runtimes", "--json"],
              directory: nil, environment: nil, timeout: runtimeProbeCommandTimeout,
              maxOutputBytes: 1_048_576)
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
              directory: nil, environment: nil, timeout: runtimeProbeCommandTimeout,
              maxOutputBytes: 1_048_576)
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
        } catch let error as ResourceCoordinatorError
          where error.code == "runtime_registry_release_failed"
        {
          record("simulator.runtime", false, "runtime_registry_release", ["error": error.detail])
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
        // The policy owner may be an organization, which is never the authenticated login, so
        // the viewer's permission on the exact repository is the authority test.
        let repositoryResult = try successful(
          runner.run(
            executable: "gh",
            arguments: [
              "repo", "view", repository, "--json",
              "nameWithOwner,viewerPermission,hasIssuesEnabled",
            ], directory: nil, environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
        let repositoryValue = try jsonObject(repositoryResult.stdout)
        guard
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
                  "--profile", profile, "testflight", "groups", "list", "--app", appID,
                  "--paginate", "--output", "json",
                ], directory: nil, environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
            let live = try jsonObject(groups.stdout)["data"] as? [[String: Any]] ?? []
            let expected = Set(authorizedApple["internal_group_ids"] as? [String] ?? [])
            // Distribution is internal-groups-only. asc omits a false isInternalGroup, so each
            // authorized ID needs exactly one live group whose attribute is the JSON boolean true.
            guard !expected.isEmpty,
              expected.allSatisfy({ id in
                let matches = live.filter { $0["id"] as? String == id }
                guard matches.count == 1,
                  let flag = (matches[0]["attributes"] as? [String: Any])?["isInternalGroup"]
                else { return false }
                return HarnessRuntime.isBoolean(flag) && flag as? Bool == true
              })
            else { throw ProbeError.mismatch }
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
      // By default only the registrations are read: a bridge started here would be one more
      // external agent for Xcode to alert about. Current-task exposure and the one read-only
      // tool call stay with the task's own client.
      let registration = probeRegistration(
        harness: harness, name: "xcode", expectedFragments: ["xcrun", "mcpbridge"], runner: runner,
        environment: environment)
      let connection: HealthMCPProbeResult =
        !registration.passed
        ? .init(passed: false, material: ["failure": "registration_blocked"])
        : liveXcodeBridgeProbe
          ? mcpProbe.probeXcode(timeout: 15)
          : .init(passed: true, material: ["probe": "not_requested"])
      record(
        "mcp.xcode", registration.passed && connection.passed,
        liveXcodeBridgeProbe ? "registration_and_read_only_tools" : "registration_read_only",
        ["registration": registration.material, "connection": connection.material])
    }
    if required.contains("mcp.apple_sample_code") {
      let endpoint = URL(string: "https://mcp.applesamplecode.com/mcp")!
      let registration = probeRegistration(
        harness: harness, name: "apple-sample-code", expectedFragments: [endpoint.absoluteString],
        runner: runner, environment: environment)
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

  /// Reads each selected client's registration for the app at the harness's authoritative root,
  /// wherever the evaluator was launched from, and never starts the server. `codex mcp get`
  /// reads configuration without starting a stdio server, and its working directory selects a
  /// trusted project's `.codex/config.toml`. `claude mcp get` and `list` health-check approved
  /// servers, so Claude Code's configuration files are read instead.
  private static func probeRegistration(
    harness: [String: Any], name: String, expectedFragments: [String], runner: HealthProbeRunning,
    environment: [String: String]
  ) -> HealthMCPProbeResult {
    let installations =
      (harness["agent_skills"] as? [String: Any])?["installations"] as? [String: Any] ?? [:]
    guard let rootValue = harness["authoritative_root"] as? String, rootValue.hasPrefix("/") else {
      return .init(passed: false, material: ["failure": "app_root_unavailable"])
    }
    let appRoot = URL(fileURLWithPath: rootValue)
    var material: [[String: Any]] = []
    for client in ["codex", "claude"]
    where installations[client] != nil && !(installations[client] is NSNull) {
      do {
        var observed: [String: Any] = ["client": client]
        let registration: String
        if client == "codex" {
          let result = try successful(
            runner.run(
              executable: "codex", arguments: ["mcp", "get", name, "--json"], directory: appRoot,
              environment: nil, timeout: 15, maxOutputBytes: 1_048_576))
          // `--json` prints the entry with `enabled`; a disabled server is not started.
          guard
            let entry = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
              as? [String: Any]
          else { throw ProbeError.invalid }
          guard let enabled = entry["enabled"], HarnessRuntime.isBoolean(enabled),
            enabled as? Bool == true
          else {
            return .init(passed: false, material: ["client": client, "failure": "disabled"])
          }
          registration = String(decoding: try HarnessRuntime.canonicalJSON(entry), as: UTF8.self)
        } else {
          guard
            let entry = try claudeRegistration(
              name: name, appRoot: appRoot, environment: environment)
          else {
            return .init(
              passed: false, material: ["client": client, "failure": "registration_missing"])
          }
          observed["scope"] = entry.scope
          registration = String(
            decoding: try HarnessRuntime.canonicalJSON(entry.server), as: UTF8.self)
        }
        guard expectedFragments.allSatisfy(registration.contains) else {
          return .init(
            passed: false, material: ["client": client, "failure": "registration_drift"])
        }
        observed["registration_sha256"] = sha(registration)
        material.append(observed)
      } catch {
        return .init(
          passed: false, material: ["client": client, "failure": probeErrorClass(error)])
      }
    }
    return material.isEmpty
      ? .init(passed: false, material: ["failure": "no_selected_client"])
      : .init(passed: true, material: ["clients": material])
  }

  /// The Claude Code entry that applies in `appRoot`, by the client's precedence: local scope,
  /// then project scope, then user scope. It reads, without starting any server:
  /// - `.claude.json` in `CLAUDE_CONFIG_DIR` when that is set, else in `HOME`: user-scope
  ///   `mcpServers`, and under `projects[<app root>]` the local-scope `mcpServers` and the `/mcp`
  ///   toggle's `disabledMcpServers`, which disables the named server for this app whatever
  ///   its scope (and the legacy `disabledMcpjsonServers`);
  /// - the app's `.mcp.json` for project scope;
  /// - `disabledMcpjsonServers`, a settings key honoured from any settings file, from the user's
  ///   `settings.json` (`CLAUDE_CONFIG_DIR`, else `~/.claude`), the app's `.claude/settings.json`
  ///   and `.claude/settings.local.json`, and `managed-settings.json`; it rejects a project
  ///   entry, which leaves a same-named user entry in effect.
  /// Not read: `managed-settings.d` drop-ins, MDM or plist managed preferences, server-delivered
  /// managed settings and a `--settings` file. Plugin, claude.ai and managed-only servers are
  /// not read either and so fail closed as missing. Approval of a project server is not
  /// checked; the task's own tool list proves exposure.
  private static func claudeRegistration(
    name: String, appRoot: URL, environment: [String: String]
  ) throws -> (scope: String, server: [String: Any])? {
    guard let home = environment["HOME"].flatMap({ $0.hasPrefix("/") ? $0 : nil }) else {
      throw ProbeError.unavailable
    }
    let homeURL = URL(fileURLWithPath: home)
    let custom = environment["CLAUDE_CONFIG_DIR"].flatMap {
      $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
    }
    func optionalObject(_ url: URL) throws -> [String: Any]? {
      let resolved = url.resolvingSymlinksInPath()
      var info = stat()
      guard lstat(resolved.path, &info) == 0 else {
        if errno == ENOENT { return nil }
        throw ProbeError.unavailable
      }
      return try boundedJSONObject(
        resolved, maximumBytes: 64 * 1_024 * 1_024, requireSingleLink: false)
    }
    // With CLAUDE_CONFIG_DIR set the client keeps `.claude.json` there, so the home directory's
    // is another configuration's; a missing file reads as no registration and fails closed.
    let global =
      try optionalObject((custom ?? homeURL).appendingPathComponent(".claude.json")) ?? [:]
    let projects = global["projects"] as? [String: Any] ?? [:]
    var spellings = [appRoot.path, appRoot.standardizedFileURL.path]
    if let real = realpath(appRoot.path, nil) {
      spellings.append(String(cString: real))
      free(real)
    }
    let project = spellings.lazy.compactMap { projects[$0] as? [String: Any] }.first ?? [:]
    // The `/mcp` toggle disables the named server for this app in every scope.
    if (project["disabledMcpServers"] as? [String] ?? []).contains(name) { return nil }
    if let local = (project["mcpServers"] as? [String: Any])?[name] as? [String: Any] {
      return ("local", local)
    }
    let settingsFiles = [
      (custom ?? homeURL.appendingPathComponent(".claude")).appendingPathComponent(
        "settings.json"),
      appRoot.appendingPathComponent(".claude/settings.json"),
      appRoot.appendingPathComponent(".claude/settings.local.json"),
      URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
    ]
    var rejected = Set(project["disabledMcpjsonServers"] as? [String] ?? [])
    for file in settingsFiles {
      rejected.formUnion(try optionalObject(file)?["disabledMcpjsonServers"] as? [String] ?? [])
    }
    if let shared =
      (try optionalObject(appRoot.appendingPathComponent(".mcp.json"))?[
        "mcpServers"] as? [String: Any])?[name] as? [String: Any]
    {
      if !rejected.contains(name) { return ("project", shared) }
    }
    if let user = (global["mcpServers"] as? [String: Any])?[name] as? [String: Any] {
      return ("user", user)
    }
    return nil
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
      let repository = upstream["repository"] as? String, !repository.isEmpty,
      let reviewed = upstream["reviewed_revision"] as? String, !reviewed.isEmpty,
      let reviewedTree = upstream["reviewed_tree"] as? String, !reviewedTree.isEmpty
    else { throw ProbeError.invalid }
    var material: [String: Any] = [
      "repository": repository, "reviewed_revision": reviewed, "reviewed_tree": reviewedTree,
    ]
    do {
      // The watcher judges provenance with these same rules through its own transport; only
      // the schema check above is health's alone.
      material["observed_head"] = try CompanionProvenance.verify(manifest) { route in
        try jsonObject(
          successful(
            runner.run(
              executable: "gh", arguments: ["api", route], directory: nil, environment: nil,
              timeout: 15, maxOutputBytes: CompanionProvenance.maxResponseBytes)
          ).stdout)
      }
      material["sources_match"] = true
      return .init(passed: true, material: material)
    } catch let failure as VerificationError {
      // The manifest or an upstream answer failed provenance. A failed read propagates as before.
      material["provenance_failure"] = failure.description
      return .init(passed: false, material: material)
    }
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
}
