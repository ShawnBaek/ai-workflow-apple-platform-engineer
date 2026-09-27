import Darwin
import Foundation

extension HealthEvaluation {
  /// Command entrypoint. It reads only explicitly named regular JSON files and prints one
  /// redacted result object; it never repairs an installation or creates a runtime scope.
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    var values: [String: String] = [:]
    var positionals: [String] = []
    var observeSkills = false
    var probeXcodeBridge = false
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
      // Explicit opt-in: starts one `xcrun mcpbridge` for a bounded tools/list, which Xcode
      // reports as another external agent.
      if argument == "--probe-xcode-mcp-bridge" {
        guard !probeXcodeBridge else {
          throw VerificationError.invalid("duplicate --probe-xcode-mcp-bridge")
        }
        probeXcodeBridge = true
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
    if observeSkills && probeXcodeBridge {
      throw VerificationError.invalid(
        "--observe-agent-skills does not accept a report or --probe-xcode-mcp-bridge")
    }
    guard positionals.count <= 1, values["--report"] == nil || positionals.isEmpty,
      let harnessPath = values["--harness"]
    else { throw VerificationError.invalid("health requires one report and --harness") }
    let harnessURL = URL(fileURLWithPath: harnessPath)
    let harness = try ResourceCoordinator.loadTrustedHarness(
      harnessPath: harnessURL, context: context)
    if observeSkills {
      guard values["--report"] == nil, positionals.isEmpty else {
        throw VerificationError.invalid(
          "--observe-agent-skills does not accept a report or --probe-xcode-mcp-bridge")
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
    // An unusable scope blocks simulator.runtime when that check is required, and only then.
    let scope =
      (try? ResourceCoordinator.runtimeProbeScope(trustedHarness: harness, context: context))
      ?? nil
    let result = revalidate(
      reportBytes: try boundedRegularFile(
        reportURL, maximumBytes: 32 * 1_024 * 1_024, requireSingleLink: false),
      expectedBytesSHA256: expected, harness: harness, policy: policy, authorization: authorization,
      runner: SystemHealthRunner(),
      runtimeCoordinator: scope == nil ? nil : ResourceCoordinatorRuntimeAdmission(),
      runtimeScope: scope, liveXcodeBridgeProbe: probeXcodeBridge, context: context)
    let output: [String: Any] = [
      "report": result.report, "valid": result.valid, "errors": result.errors,
    ]
    print(String(data: try HarnessRuntime.canonicalJSON(output), encoding: .utf8)!)
    return result.valid ? 0 : 2
  }

  static func boundedJSONObject(_ url: URL, maximumBytes: Int, requireSingleLink: Bool)
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
}
