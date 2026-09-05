import Darwin
import Foundation

public enum CheckAuthorizationCommand {
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    let options = try CLIOptions(arguments)
    guard let authorizationPath = options.url("authorization"),
      let requestPath = options.url("request"),
      let ledgerPath = options.url("ledger"), let runRoot = options.url("run-root"),
      let overlayPath = options.url("policy-overlay"),
      let authoritativeRoot = options.url("authoritative-root"),
      let harnessPath = options.url("harness"), let statePath = options.url("coordinator-state"),
      let healthPath = options.url("health-report")
    else {
      throw VerificationError.invalid(
        "check-authorization requires authorization, request, ledger, run-root, policy-overlay, authoritative-root, harness, coordinator-state, and health-report"
      )
    }
    do {
      let harness = try ResourceCoordinator.loadTrustedHarness(
        harnessPath: harnessPath, context: context)
      guard let runtime = harness["authorization_runtime"] as? [String: Any],
        let executablePath = runtime["executable_path"] as? String
      else {
        return blocked([
          "Swift authorization runtime binding is absent; rematerialize the private harness at the Swift v1 boundary"
        ])
      }
      guard
        URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
          == URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
          .standardizedFileURL
      else {
        return blocked(["Authorization runtime does not identify the executing binary"])
      }
      let runtimeErrors = Authorization.validateRuntimeBinding(
        runtime, executable: URL(fileURLWithPath: executablePath), sourceBundle: context.harnessRoot
      )
      if !runtimeErrors.isEmpty { return blocked(runtimeErrors) }
      guard let boundAuthorization = absoluteURL(harness["run_authorization"]),
        let boundOverlay = absoluteURL(harness["private_policy_overlay"]),
        samePath(boundAuthorization, authorizationPath), samePath(boundOverlay, overlayPath),
        authorizationPath.path.hasPrefix("/"), overlayPath.path.hasPrefix("/"),
        requestPath.path.hasPrefix("/")
      else {
        return blocked(["untrusted private authorization or policy binding"])
      }
      guard
        let envelope = try Authorization.loadStablePrivateJSON(authorizationPath, root: runRoot)
          as? [String: Any],
        let request = try Authorization.loadStablePrivateJSON(requestPath, root: runRoot)
          as? [String: Any],
        let overlay = try Authorization.loadStablePrivateJSON(overlayPath, root: runRoot)
          as? [String: Any]
      else {
        return blocked(["private authorization, request, or policy must contain a JSON object"])
      }
      if !JSONSchemaValidator.equal(
        harness["local_requirements"] ?? NSNull(), envelope["local_requirements"] ?? NSNull())
      {
        return blocked(["trusted harness local requirements drifted from authorization"])
      }
      let health = Authorization.verifyHealthReport(
        reportPath: healthPath, harnessPath: harnessPath, runRoot: runRoot, policy: overlay,
        authorization: envelope, context: context)
      if !health.errors.isEmpty { return blocked(health.errors) }
      let liveRepository = try Authorization.observeRepository(
        authoritativeRoot,
        expectedBaseSHA: ((envelope["repository"] as? [String: Any])?["base_sha"] as? String) ?? "")
      var liveSpec: [String: Any]?
      if let spec = envelope["spec_kit"] as? [String: Any] {
        liveSpec = try SpecKitSnapshot.buildSnapshot(
          root: authoritativeRoot, release: spec["release"] as? String ?? "",
          runID: spec["workflow_run_id"] as? String,
          featureDirectory: spec["feature_directory"] as? String)
      }
      var liveApple: [String: Any]?
      if (request["action"] as? String)?.hasPrefix("apple.") == true {
        guard let observationPath = options.url("apple-observation"),
          let observation = try Authorization.loadStablePrivateJSON(observationPath, root: runRoot)
            as? [String: Any]
        else { return blocked(["Apple action requires a private --apple-observation file"]) }
        liveApple = observation
      } else if options.url("apple-observation") != nil {
        return blocked(["non-Apple action cannot include --apple-observation"])
      }
      guard let coordinatorBinding = harness["resource_coordinator"] as? [String: Any],
        let writer = harness["selected_writer"] as? String
      else { return blocked(["trusted harness lacks coordinator or writer binding"]) }
      let harnessDigest = try ResourceCoordinator.portableDocumentSHA256(harness)
      let result = Authorization.reserveAction(
        ledgerPath: ledgerPath, envelope: envelope, request: request, runRoot: runRoot,
        policyOverlay: overlay, liveRepository: liveRepository, liveSpecSnapshot: liveSpec,
        liveAppleObservation: liveApple, coordinatorState: statePath,
        coordinatorBinding: coordinatorBinding, selectedWriter: writer,
        trustedHarnessSHA256: harnessDigest, verifiedHealthAttestation: health.attestation,
        context: context)
      printJSON([
        "authorized": result.errors.isEmpty, "errors": result.errors,
        "reservation": (result.reservation ?? NSNull()) as Any,
      ])
      return result.errors.isEmpty ? 0 : 2
    } catch { return blocked([String(describing: error)]) }
  }

  private static func blocked(_ errors: [String]) -> Int32 {
    printJSON(["authorized": false, "errors": errors, "reservation": NSNull()])
    return 2
  }
  private static func absoluteURL(_ value: Any?) -> URL? {
    guard let path = value as? String, path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path)
  }
  private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.resolvingSymlinksInPath().standardizedFileURL
      == rhs.resolvingSymlinksInPath().standardizedFileURL
  }
}
