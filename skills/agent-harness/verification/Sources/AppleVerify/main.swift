import AppleVerificationCore
import Foundation

let usage = """
  apple-verify [--repository-root <skills-repository>] [--app-root <app-repository>] <command> [arguments]

    repository --root <repository> [--output <new-report.json>]
    compare --manifest <comparison.json> --output-dir <new-directory>
    runtime-identity
    health <report.json> --harness <private-harness.json>
    authorize, verify-reservation, prepare-action, initialize-run
    resources <state.json> bootstrap|status|acquire|verify|heartbeat|release|recover|configure-host-policy|bundle-digest
    resolve-project, materialize, spec-snapshot
    knowledge index|query|status
    delivery-report <completion-report.json> [--channel <channel>]
    companion --manifest <manifest.json> check|sync-issue

  See docs/verification.md and each skill's reference for command arguments.
  The runtime uses Swift and Apple's tools; it does not prove app behavior by itself.
  """

func runtimeContext(repositoryRoot: String?) throws -> RuntimeContext {
  if let repositoryRoot {
    let root = URL(fileURLWithPath: repositoryRoot).standardizedFileURL.resolvingSymlinksInPath()
    return RuntimeContext(
      repositoryRoot: root, harnessRoot: root.appendingPathComponent("skills/agent-harness"))
  }
  // A build stays inside its installed skill. Resolve this location, never search
  // the user's home directory or silently select another installed copy.
  var candidate = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    .resolvingSymlinksInPath().deletingLastPathComponent()
  while candidate.path != "/" {
    if candidate.lastPathComponent == "agent-harness",
      FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent("contracts/capabilities.json").path)
    {
      return RuntimeContext(
        repositoryRoot: candidate.deletingLastPathComponent().deletingLastPathComponent(),
        harnessRoot: candidate)
    }
    candidate.deleteLastPathComponent()
  }
  throw VerificationError.invalid(
    "Cannot locate the installed contracts; use --repository-root before the command")
}

do {
  var arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.isEmpty || arguments == ["--help"] {
    print(usage)
    exit(0)
  }
  var explicitRoot: String?
  var appRoot: String?
  while let option = arguments.first, ["--repository-root", "--app-root"].contains(option) {
    guard arguments.count >= 3, !arguments[1].hasPrefix("--") else {
      throw VerificationError.invalid("\(option) requires a path and command")
    }
    if option == "--repository-root" {
      guard explicitRoot == nil else {
        throw VerificationError.invalid("duplicate --repository-root")
      }
      explicitRoot = arguments[1]
    } else {
      guard appRoot == nil else { throw VerificationError.invalid("duplicate --app-root") }
      guard arguments[1].hasPrefix("/") else {
        throw VerificationError.invalid("--app-root requires an absolute app repository path")
      }
      appRoot = arguments[1]
    }
    arguments.removeFirst(2)
  }
  let command = arguments.removeFirst()
  let installedContext = try runtimeContext(repositoryRoot: explicitRoot)
  let context = appRoot.map {
    RuntimeContext(
      repositoryRoot: URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath(),
      harnessRoot: installedContext.harnessRoot)
  } ?? installedContext
  let code: Int32
  switch command {
  case "repository":
    let options = try RuntimeArguments(arguments)
    try options.allow(["--root", "--output"])
    let report = try RepositoryValidation.validate(
      root: URL(fileURLWithPath: options.required("--root")))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(report)
    data.append(10)
    if let path = options.value("--output") {
      try data.write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
    }
    FileHandle.standardOutput.write(data)
    code = report.status == "passed" ? 0 : 1
  case "compare":
    let options = try RuntimeArguments(arguments)
    try options.allow(["--manifest", "--output-dir"])
    print(
      try ImageComparison.render(
        manifest: URL(fileURLWithPath: options.required("--manifest")),
        outputDirectory: URL(fileURLWithPath: options.required("--output-dir"))
      ).path)
    code = 0
  case "runtime-identity":
    guard arguments.isEmpty else {
      throw VerificationError.invalid("runtime-identity takes no arguments")
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .resolvingSymlinksInPath()
    let identity: [String: Any] = [
      "runtime_kind": "swift", "runtime_contract": "apple-verification-core.authorization.v1",
      "executable_path": executable.path,
      "executable_sha256": "sha256:" + (try HarnessRuntime.sha256File(executable)),
      "source_bundle_sha256": try ResourceCoordinator.sourceBundleSHA256(
        skillRoot: context.harnessRoot),
    ]
    FileHandle.standardOutput.write(try HarnessRuntime.canonicalJSON(identity) + Data([10]))
    code = 0
  case "authorize": code = try CheckAuthorizationCommand.run(arguments: arguments, context: context)
  case "verify-reservation":
    code = try VerifyReservationCommand.run(arguments: arguments, context: context)
  case "prepare-action":
    code = try PrepareActionRequestCommand.run(arguments: arguments, context: context)
  case "initialize-run": code = try InitializeRun.run(arguments: arguments, context: context)
  case "resources": code = try ResourceCoordinator.run(arguments: arguments, context: context)
  case "resolve-project": code = try ProjectResolver.run(arguments: arguments, context: context)
  case "materialize":
    code = try MaterializePrivateTemplate.run(arguments: arguments, context: context)
  case "spec-snapshot":
    code = try SpecKitSnapshotCommand.run(arguments: arguments, context: context)
  case "health": code = try HealthEvaluation.run(arguments: arguments, context: context)
  case "knowledge": code = try KnowledgeIndex.run(arguments: arguments, context: context)
  case "delivery-report": code = try DeliveryReport.run(arguments: arguments, context: context)
  case "companion": code = try CompanionWatcher.run(arguments: arguments, context: context)
  default: throw VerificationError.invalid("Unknown command: \(command)")
  }
  exit(code)
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
