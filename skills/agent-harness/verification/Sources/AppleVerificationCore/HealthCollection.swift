import CryptoKit
import Darwin
import Foundation

public enum HealthCollection {
  public static func registryResolution(
    registry: Any?, harness: [String: Any], context: RuntimeContext
  ) -> [String: Any] {
    ProjectResolver.resolveProject(
      registry: registry, explicitPath: harness["authoritative_root"] as? String,
      openedXcodeContainer: harness["xcode_container"] as? String, allowWorktree: false,
      context: context)
  }
  public static func skillSHA256(_ path: URL) throws -> String {
    let fm = FileManager.default
    let root = path.resolvingSymlinksInPath()
    let excludedDirectories: Set<String> = [".git", ".build", ".swiftpm", "__pycache__"]
    let maximumFiles = 10_000
    let maximumPathBytes = 4_096
    let maximumFileBytes: Int64 = 64 * 1_024 * 1_024
    let maximumBundleBytes: Int64 = 256 * 1_024 * 1_024
    var info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard info.isDirectory == true, info.isSymbolicLink != true,
      fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path)
    else { throw VerificationError.invalid("installed skill lacks a regular SKILL.md") }
    guard
      let iterator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [])
    else { throw VerificationError.invalid("installed skill bundle is unavailable") }
    var files: [URL] = []
    for case let candidate as URL in iterator {
      let relative = candidate.path.replacingOccurrences(of: root.path + "/", with: "")
      if excludedDirectories.contains(candidate.lastPathComponent) {
        iterator.skipDescendants()
        continue
      }
      if relative.split(separator: "/").contains(where: { excludedDirectories.contains(String($0)) }
      ) || candidate.pathExtension == "pyc" || candidate.lastPathComponent == ".DS_Store" {
        continue
      }
      guard relative.utf8.count <= maximumPathBytes else {
        throw VerificationError.invalid("installed skill contains an oversized path")
      }
      info = try candidate.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      if info.isSymbolicLink == true {
        throw VerificationError.invalid("installed skill contains an unsupported nested symlink")
      }
      if info.isRegularFile == true {
        files.append(candidate)
        if files.count > maximumFiles {
          throw VerificationError.invalid("installed skill bundle contains too many files")
        }
      }
    }
    guard !files.isEmpty else { throw VerificationError.invalid("installed skill bundle is empty") }
    func fileDigest(_ file: URL, expectedSize: Int64) throws -> Data {
      let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw VerificationError.invalid("installed skill file cannot be opened safely")
      }
      defer { close(descriptor) }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_nlink == 1,
        metadata.st_size == expectedSize
      else { throw VerificationError.invalid("installed skill changed during hashing") }
      var hasher = SHA256()
      var total: Int64 = 0
      var buffer = [UInt8](repeating: 0, count: 1_048_576)
      while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else {
          throw VerificationError.invalid("installed skill file read failed")
        }
        if count == 0 { break }
        total += Int64(count)
        guard total <= expectedSize else {
          throw VerificationError.invalid("installed skill changed during hashing")
        }
        hasher.update(data: Data(buffer.prefix(count)))
      }
      guard total == expectedSize else {
        throw VerificationError.invalid("installed skill changed during hashing")
      }
      return Data(hasher.finalize())
    }
    var bundleHasher = SHA256()
    var totalBytes: Int64 = 0
    for file in files.sorted(by: { $0.path < $1.path }) {
      let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
      let name = Data(relative.utf8)
      var length = UInt32(name.count).bigEndian
      bundleHasher.update(data: Data(bytes: &length, count: 4))
      bundleHasher.update(data: name)
      let size = Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1)
      guard size >= 0, size <= maximumFileBytes, totalBytes <= maximumBundleBytes - size else {
        throw VerificationError.invalid("installed skill bundle exceeds its bounded read limit")
      }
      totalBytes += size
      bundleHasher.update(data: try fileDigest(file, expectedSize: size))
    }
    return "sha256:" + Data(bundleHasher.finalize()).map { String(format: "%02x", $0) }.joined()
  }

  public static func installedSkillManifest(
    searchRoots: [URL], requiredSkills: [String], client: String
  ) throws -> [String: Any] {
    guard ["codex", "claude"].contains(client), !searchRoots.isEmpty,
      requiredSkills == Array(Set(requiredSkills)).sorted()
    else { throw VerificationError.invalid("installed skill request is invalid") }
    var entries: [[String: Any]] = []
    var bundle = Data()
    for name in requiredSkills {
      let candidates = searchRoots.map { $0.appendingPathComponent(name) }
      let hits = candidates.filter { candidate in
        var statValue = stat()
        return lstat(candidate.path, &statValue) == 0
      }
      guard hits.count == 1 else {
        throw VerificationError.invalid(
          hits.isEmpty
            ? "required skill is missing from configured search roots: \(name)"
            : "duplicate shadowing skill copies are configured: \(name)")
      }
      let visible = hits[0]
      var visibleStat = stat()
      _ = lstat(visible.path, &visibleStat)
      if visibleStat.st_mode & S_IFMT == S_IFLNK
        && !FileManager.default.fileExists(atPath: visible.path)
      {
        throw VerificationError.invalid("required skill is a broken top-level symlink: \(name)")
      }
      let resolved = visible.resolvingSymlinksInPath()
      let digest = try skillSHA256(visible)
      entries.append([
        "name": name,
        "entry_kind": visibleStat.st_mode & S_IFMT == S_IFLNK ? "symlink" : "directory",
        "resolved_path_sha256": "sha256:" + HarnessRuntime.sha256(Data(resolved.path.utf8)),
        "sha256": digest,
      ])
      let nameBytes = Data(name.utf8)
      var length = UInt32(nameBytes.count).bigEndian
      bundle.append(Data(bytes: &length, count: 4))
      bundle.append(nameBytes)
      bundle.append(Data(hex: String(digest.dropFirst(7))))
    }
    let paths = searchRoots.map(\.path)
    let rootIdentity =
      paths.count == 1 ? Data(paths[0].utf8) : try HarnessRuntime.canonicalJSON(paths)
    return [
      "client": client, "root_path_sha256": "sha256:" + HarnessRuntime.sha256(rootIdentity),
      "bundle_sha256": "sha256:" + HarnessRuntime.sha256(bundle), "skills": entries,
    ]
  }

  public static func requiredAgentSkills(harness: [String: Any]) throws -> [String] {
    let base: Set<String> = [
      "agent-harness", "apple-development-health", "git-workflow", "github-projects",
    ]
    let profiles: [String: Set<String>] = [
      "local_verified": [],
      "pr_ready": [],
      "runtime_ui": [
        "xcode-project-workflow", "xcodebuild", "apple-platform-testing", "core-simulator-health",
      ],
      "testflight_uploaded": [
        "xcode-project-workflow", "xcodebuild", "app-store-connect", "app-versioning",
      ],
      "testflight_distributed": [
        "xcode-project-workflow", "xcodebuild", "app-store-connect", "app-versioning",
      ],
      "icon_upstream": ["icon-composer"],
    ]
    let components: [String: Set<String>] = [
      "project_registry": ["agent-harness"], "spec_kit": ["agent-harness"],
      "xcode_mcp": ["xcode-project-workflow", "xcodebuild"],
      "apple_sample_code_mcp": ["agent-harness"],
      "github_project": ["github-projects"], "local_llm": ["agent-harness"],
    ]
    guard let profile = harness["health_profile"] as? String, let profileSkills = profiles[profile],
      let selected = harness["health_components"] as? [String],
      selected.count == Set(selected).count,
      selected.allSatisfy({ components[$0] != nil }),
      let configured = harness["agent_skills"] as? [String: Any],
      let taskSkills = configured["task_skills"] as? [String],
      taskSkills.count == Set(taskSkills).count,
      taskSkills.allSatisfy({
        $0.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
      })
    else { throw VerificationError.invalid("harness skill selection is invalid") }
    var required = base.union(profileSkills).union(taskSkills)
    selected.forEach { required.formUnion(components[$0]!) }
    return required.sorted()
  }

  /// Computes the installed client manifests. `enforceExpected` may be disabled only by the
  /// explicit bootstrap observation command so an operator can replace the template hash;
  /// live health and authorization paths always use the default exact binding check.
  public static func observeAgentSkills(harness: [String: Any], enforceExpected: Bool = true) throws
    -> [String: Any]
  {
    let required = try requiredAgentSkills(harness: harness)
    guard let configured = harness["agent_skills"] as? [String: Any],
      Set(configured.keys) == ["task_skills", "expected_bundle_sha256", "installations"],
      let expected = configured["expected_bundle_sha256"] as? String,
      expected.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil,
      let installations = configured["installations"] as? [String: Any],
      Set(installations.keys) == ["codex", "claude"],
      let mode = harness["mode"] as? String
    else { throw VerificationError.invalid("harness agent skill binding is invalid") }
    let expectedClients: Set<String>
    switch mode {
    case "codex": expectedClients = ["codex"]
    case "claude": expectedClients = ["claude"]
    case "collaborative": expectedClients = ["codex", "claude"]
    default:
      throw VerificationError.invalid("harness mode is invalid for agent skill installations")
    }
    var clients: [[String: Any]] = []
    for client in ["codex", "claude"] {
      let raw = installations[client]
      if !expectedClients.contains(client) {
        guard raw == nil || raw is NSNull else {
          throw VerificationError.invalid("unselected \(client) skill installation must be null")
        }
        continue
      }
      guard let installation = raw as? [String: Any],
        Set(installation.keys) == ["collection_root"] || Set(installation.keys) == ["search_roots"]
      else { throw VerificationError.invalid("selected \(client) skill installation is invalid") }
      let values =
        (installation["collection_root"] as? String).map { [$0] } ?? installation["search_roots"]
        as? [String] ?? []
      guard !values.isEmpty, values.count == Set(values).count,
        values.allSatisfy({ $0.hasPrefix("/") })
      else {
        throw VerificationError.invalid(
          "selected \(client) skill search roots must be unique absolute paths")
      }
      let roots = values.map(URL.init(fileURLWithPath:))
      for root in roots {
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else {
          throw VerificationError.invalid("selected \(client) skill search root is invalid")
        }
      }
      clients.append(
        try installedSkillManifest(searchRoots: roots, requiredSkills: required, client: client))
    }
    let observedBundles = Set(clients.compactMap { $0["bundle_sha256"] as? String })
    guard !clients.isEmpty, observedBundles.count == 1, let observed = observedBundles.first else {
      throw VerificationError.invalid(
        "installed agent skill bundles differ across selected clients")
    }
    if enforceExpected, clients.contains(where: { $0["bundle_sha256"] as? String != expected }) {
      throw VerificationError.invalid("installed agent skill bundle drifted from the harness")
    }
    return [
      "required_skills": required, "expected_bundle_sha256": enforceExpected ? expected : observed,
      "clients": clients,
    ]
  }

  public static func observeResourceCoordinator(
    harness: [String: Any], context: RuntimeContext,
    executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
  ) throws -> [String: Any] {
    guard let binding = harness["resource_coordinator"] as? [String: Any],
      Set(binding.keys) == [
        "runtime_kind", "runtime_contract", "state_path", "coordinator_instance_id",
        "executable_sha256", "source_bundle_sha256",
      ],
      binding["runtime_kind"] as? String == "swift",
      binding["runtime_contract"] as? String == "apple-verification-core.resources.v1",
      let stateValue = binding["state_path"] as? String, stateValue.hasPrefix("/")
    else { throw VerificationError.invalid("harness resource coordinator binding is invalid") }
    let statePath = URL(fileURLWithPath: stateValue)
    let stateInfo = try statePath.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard stateInfo.isRegularFile == true, stateInfo.isSymbolicLink != true else {
      throw VerificationError.invalid("harness resource coordinator state is unavailable")
    }
    let executable = executableURL.resolvingSymlinksInPath()
    let executableInfo = try executable.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard executableInfo.isRegularFile == true, executableInfo.isSymbolicLink != true,
      binding["executable_sha256"] as? String == "sha256:"
        + (try HarnessRuntime.sha256File(executable)),
      binding["source_bundle_sha256"] as? String
        == (try ResourceCoordinator.sourceBundleSHA256(skillRoot: context.harnessRoot))
    else { throw VerificationError.invalid("installed coordinator runtime binding drifted") }
    let status = try ResourceCoordinator.status(statePath: statePath)
    guard status["schema_version"] as? Int == 2, status["runtime_kind"] as? String == "swift",
      status["runtime_contract"] as? String == "apple-verification-core.resources.v1",
      status["coordinator_instance_id"] as? String == binding["coordinator_instance_id"] as? String,
      ((status["migration_bootstrap"] as? [String: Any])?["legacy_leases_quiesced"] as? Bool)
        == true,
      let count = status["active_lease_count"] as? Int, count >= 0
    else {
      throw VerificationError.invalid("resource coordinator state is not bootstrapped or valid")
    }
    return [
      "state_path_sha256": "sha256:"
        + HarnessRuntime.sha256(Data(statePath.resolvingSymlinksInPath().path.utf8)),
      "coordinator_instance_id": status["coordinator_instance_id"]!, "state_schema_version": 2,
      "migration_bootstrap_confirmed": true, "runtime_kind": "swift",
      "runtime_contract": "apple-verification-core.resources.v1",
      "executable_sha256": binding["executable_sha256"]!,
      "source_bundle_sha256": binding["source_bundle_sha256"]!, "active_lease_count": count,
    ]
  }

  public static func validateHarnessBinding(
    report: [String: Any], harness: [String: Any], context: RuntimeContext,
    runner: HealthProbeRunning, executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
  ) -> [String] {
    var errors: [String] = []
    guard let rootValue = harness["authoritative_root"] as? String, rootValue.hasPrefix("/") else {
      return ["harness authoritative_root is invalid"]
    }
    let root = URL(fileURLWithPath: rootValue)
    do {
      let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard info.isDirectory == true, info.isSymbolicLink != true else {
        throw VerificationError.invalid("unsafe root")
      }
      let canonical = root.resolvingSymlinksInPath()
      if context.repositoryRoot.resolvingSymlinksInPath() != canonical {
        errors.append("trusted runtime repository root drifted from the harness")
      }
      func git(_ arguments: [String]) throws -> String {
        let result = runner.run(
          executable: "git", arguments: ["-C", canonical.path] + arguments, directory: nil,
          environment: nil, timeout: 15, maxOutputBytes: 1_048_576)
        guard result.exitCode == 0, !result.timedOut, !result.truncated else {
          throw VerificationError.invalid("git probe failed")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let top = URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"]))
        .resolvingSymlinksInPath()
      if top != canonical {
        errors.append("harness authoritative_root is not the exact Git top level")
      }
      let rawRemote = try git(["remote", "get-url", "origin"])
      let remote = sanitizedRemote(rawRemote)
      let branch = try git(["branch", "--show-current"])
      let gitValue = try git(["rev-parse", "--git-dir"])
      let commonValue = try git(["rev-parse", "--git-common-dir"])
      let gitDirectory = canonicalURL(gitValue, relativeTo: canonical)
      let commonDirectory = canonicalURL(commonValue, relativeTo: canonical)
      var expected: [String: Any] = [
        "repository": canonical.path, "remote": remote, "branch": branch,
      ]
      let components = report["selected_components"] as? [String] ?? []
      let profile = report["profile"] as? String ?? ""
      let requiresContainer =
        ["runtime_ui", "testflight_uploaded", "testflight_distributed"].contains(profile)
        || components.contains("xcode_mcp")
      var relativeContainer: String?
      if requiresContainer {
        guard let containerValue = harness["xcode_container"] as? String else {
          throw VerificationError.invalid("harness xcode_container is invalid")
        }
        let container = URL(fileURLWithPath: containerValue)
        let containerInfo = try container.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard containerInfo.isDirectory == true, containerInfo.isSymbolicLink != true,
          ["xcodeproj", "xcworkspace"].contains(container.pathExtension),
          container.path.hasPrefix(canonical.path + "/")
        else { throw VerificationError.invalid("harness xcode_container is invalid") }
        let canonicalContainer = container.resolvingSymlinksInPath()
        expected["xcode_container"] = canonicalContainer.path
        relativeContainer = String(canonicalContainer.path.dropFirst(canonical.path.count + 1))
      }
      if !JSONSchemaValidator.equal(report["authoritative_targets"] ?? NSNull(), expected) {
        errors.append("health authoritative targets drifted from the harness and live repository")
      }
      if let resolution = report["project_registry_resolution"] as? [String: Any],
        components.contains("project_registry"), resolution["status"] as? String == "resolved",
        let candidate = resolution["candidate"] as? [String: Any]
      {
        if candidate["canonical_root"] as? String != canonical.path {
          errors.append("project registry candidate root drifted from the harness")
        }
        if candidate["remote_fingerprint"] as? String != (try remoteFingerprint(rawRemote)) {
          errors.append(
            "project registry candidate remote fingerprint drifted from the live repository")
        }
        let liveKind = gitDirectory == commonDirectory ? "primary" : "worktree"
        if candidate["kind"] as? String != liveKind {
          errors.append("project registry candidate checkout kind drifted from live Git metadata")
        }
        if liveKind == "worktree", resolution["worktree_authorized"] as? Bool != true {
          errors.append("project registry selected an unapproved worktree")
        }
        if requiresContainer, let relativeContainer,
          !(candidate["xcode_containers"] as? [String] ?? []).contains(relativeContainer)
        {
          errors.append(
            "project registry candidate does not bind the authoritative Xcode container")
        }
      }
      do {
        if !JSONSchemaValidator.equal(
          report["agent_skill_manifest"] ?? NSNull(), try observeAgentSkills(harness: harness))
        {
          errors.append("agent skill manifest drifted from live installed skills")
        }
      } catch { errors.append("live installed agent skill observation failed") }
      do {
        let observed = try observeResourceCoordinator(
          harness: harness, context: context, executableURL: executableURL)
        let stable = [
          "state_path_sha256", "coordinator_instance_id", "state_schema_version",
          "migration_bootstrap_confirmed", "runtime_kind", "runtime_contract", "executable_sha256",
          "source_bundle_sha256",
        ]
        let reported = report["resource_coordinator_observation"] as? [String: Any] ?? [:]
        if stable.contains(where: { key in
          guard let lhs = reported[key], let rhs = observed[key] else { return true }
          return !JSONSchemaValidator.equal(lhs, rhs)
        }) {
          errors.append("resource coordinator identity drifted from live harness state")
        }
      } catch { errors.append("live resource coordinator observation failed") }
    } catch { errors.append("live repository health binding failed") }
    return Array(Set(errors)).sorted()
  }

  public static func trustedSelectionErrors(report: [String: Any], harness: [String: Any])
    -> [String]
  {
    var errors: [String] = []
    if harness["health_profile"] as? String != report["profile"] as? String {
      errors.append("health report profile drifted from harness")
    }
    guard let configured = harness["health_components"] as? [String],
      configured.count == Set(configured).count,
      configured.allSatisfy({ HealthEvaluation.componentRequirements[$0] != nil })
    else { return errors + ["harness health_components are invalid"] }
    let observed = report["selected_components"] as? [String] ?? []
    if Set(observed) != Set(configured) {
      errors.append("health report selected_components drifted from trusted harness")
    }
    if ((harness["spec_kit"] as? [String: Any])?["enabled"] as? Bool) == true,
      !configured.contains("spec_kit")
    {
      errors.append("enabled Spec Kit is missing from harness health_components")
    }
    if let tracking = harness["github_tracking"] as? [String: Any], tracking["project"] != nil,
      !(tracking["project"] is NSNull), !configured.contains("github_project")
    {
      errors.append("configured GitHub Project is missing from harness health_components")
    }
    return errors
  }

  public static func trustedPolicyErrors(policy: [String: Any], harness: [String: Any]) -> [String]
  {
    var errors: [String] = []
    let required: Set<String> = ["schema_version", "decision", "github", "apple"]
    guard required.isSubset(of: Set(policy.keys)),
      Set(policy.keys).isSubset(of: required.union(["$schema"])),
      policy["schema_version"] as? String == "1.0.0", policy["decision"] as? String == "approved"
    else { return ["private policy overlay is not approved or bounded"] }
    let local = harness["delivery_target"] as? String == "local_verified"
    if local {
      if !(policy["github"] is NSNull) || !(policy["apple"] is NSNull) {
        errors.append("local verification policy must not authorize GitHub or Apple access")
      }
    } else {
      guard let github = policy["github"] as? [String: Any], Set(github.keys) == ["owner"],
        (github["owner"] as? String)?.isEmpty == false
      else { return ["private policy overlay GitHub boundary is invalid"] }
      if !(policy["apple"] is NSNull) {
        guard let apple = policy["apple"] as? [String: Any],
          Set(apple.keys) == ["account_guard_ref", "team_id"],
          ["account_guard_ref", "team_id"].allSatisfy({ (apple[$0] as? String)?.isEmpty == false })
        else {
          errors.append("private policy overlay Apple boundary is invalid")
          return errors
        }
      }
    }
    return errors
  }

  private static func canonicalURL(_ path: String, relativeTo root: URL) -> URL {
    (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
      .resolvingSymlinksInPath()
  }
  private static func sanitizedRemote(_ remote: String) -> String {
    guard remote.contains("://"), var components = URLComponents(string: remote),
      let host = components.host
    else { return remote }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    components.host = host
    return components.string ?? remote
  }
  private static func remoteFingerprint(_ remote: String) throws -> String {
    guard !remote.isEmpty, remote == remote.trimmingCharacters(in: .whitespacesAndNewlines),
      !remote.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      !remote.contains("?"), !remote.contains("#")
    else { throw VerificationError.invalid("invalid GitHub remote") }
    let path: String
    if remote.hasPrefix("git@github.com:") {
      path = String(remote.dropFirst("git@github.com:".count))
    } else {
      guard let components = URLComponents(string: sanitizedRemote(remote)),
        ["https", "ssh"].contains(components.scheme ?? ""), components.host == "github.com",
        components.password == nil,
        components.scheme != "https" || components.user == nil,
        components.scheme != "ssh" || components.user == nil || components.user == "git",
        components.port == nil || (components.scheme == "https" && components.port == 443)
          || (components.scheme == "ssh" && components.port == 22)
      else { throw VerificationError.invalid("invalid GitHub remote") }
      path = String(components.path.drop(while: { $0 == "/" }))
    }
    let clean = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
    guard clean.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    else { throw VerificationError.invalid("invalid GitHub remote") }
    return "sha256:" + HarnessRuntime.sha256(Data("github.com/\(clean.lowercased())".utf8))
  }
}

extension Data {
  fileprivate init(hex: String) {
    self.init()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      append(UInt8(hex[index..<next], radix: 16) ?? 0)
      index = next
    }
  }
}
