import Foundation

extension ResourceCoordinator {
  static func blockedResponse(for error: ResourceCoordinatorError) -> [String: Any] {
    var response: [String: Any] = ["status": "blocked", "reason_code": error.code]
    switch error.code {
    case "resource_conflict":
      if error.detail.range(
        of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: [.regularExpression, .caseInsensitive]) != nil
      {
        response["reason_detail"] = ["conflicting_lease_id": error.detail]
      }
    case "capacity_exceeded":
      if ["heavy_jobs", "active_devices", "internal_workers"].contains(error.detail) {
        response["reason_detail"] = ["capacity_dimension": error.detail]
      }
    default:
      break
    }
    return response
  }

  public static func loadExistingRunAuthority(
    authorizationPath: URL, harnessPath: URL, harness: [String: Any], runID: String,
    context: RuntimeContext
  ) throws -> (authorization: [String: Any], authority: [String: Any]) {
    guard authorizationPath.path.hasPrefix("/"), !isSymlink(authorizationPath),
      isRegular(authorizationPath), let harnessAuth = harness["run_authorization"] as? String,
      harnessAuth.hasPrefix("/"),
      authorizationPath.resolvingSymlinksInPath()
        == URL(fileURLWithPath: harnessAuth).resolvingSymlinksInPath()
    else { throw ResourceCoordinatorError("untrusted_authority") }
    let authorization: [String: Any]
    do { authorization = try HarnessRuntime.object(authorizationPath) } catch {
      throw ResourceCoordinatorError("untrusted_authority")
    }
    guard authorization["decision"] as? String == "approved",
      authorization["run_id"] as? String == runID,
      authorization["selected_writer"] as? String == harness["selected_writer"] as? String
    else { throw ResourceCoordinatorError("writer_mismatch") }
    let schemaPath = context.harnessRoot.appendingPathComponent(
      "contracts/schemas/run-authorization.schema.json")
    let schema: [String: Any]
    do { schema = try HarnessRuntime.object(schemaPath) } catch {
      throw ResourceCoordinatorError("untrusted_authority")
    }
    let errors =
      Authorization.schemaErrors(instance: authorization, schema: schema)
      + Authorization.validateAuthorization(authorization, context: context)
    guard errors.isEmpty else {
      throw ResourceCoordinatorError(
        "untrusted_authority", Array(Set(errors)).sorted().joined(separator: "; "))
    }
    let issued = try parse(authorization["issued_at"])
    let expires = try parse(authorization["expires_at"])
    guard expires > issued,
      authorization["contract_schema_id"] as? String == schema["$id"] as? String,
      authorization["contract_schema_sha256"] as? String == "sha256:"
        + (try HarnessRuntime.sha256File(schemaPath))
    else { throw ResourceCoordinatorError("untrusted_authority") }
    let harnessDocument = try loadTrustedHarness(harnessPath: harnessPath, context: context)
    guard let ledger = harnessDocument["run_ledger"] as? String else {
      throw ResourceCoordinatorError("untrusted_authority")
    }
    let authDigest = try portableDocumentSHA256(authorization)
    let ledgerValues = try ledgerBinding(
      URL(fileURLWithPath: ledger), expectedRunID: runID, expectedAuthorizationHash: authDigest)
    let authority: [String: Any] = [
      "authorization_hash": authDigest, "selected_writer": authorization["selected_writer"]!,
      "harness_sha256": try portableDocumentSHA256(harnessDocument),
      "authorization_issued_at": stamp(issued), "authorization_expires_at": stamp(expires),
      "ledger_path": ledgerValues["ledger_path"]!,
      "ledger_identity_sha256": ledgerValues["ledger_identity_sha256"]!,
      "ledger_approval_sha256": ledgerValues["ledger_approval_sha256"]!,
    ]
    return (authorization, authority)
  }

  public static func loadRunAuthority(
    authorizationPath: URL, harnessPath: URL, harness: [String: Any], runID: String,
    resource: String, descriptor: [String: Any], planID: String? = nil, context: RuntimeContext
  ) throws -> [String: Any] {
    let (authorization, authority) = try loadExistingRunAuthority(
      authorizationPath: authorizationPath, harnessPath: harnessPath, harness: harness,
      runID: runID, context: context)
    let now = Date()
    let issued = try parse(authority["authorization_issued_at"])
    let expires = try parse(authority["authorization_expires_at"])
    guard issued <= now, now < expires else {
      throw ResourceCoordinatorError("authorization_inactive")
    }
    let normalized = try normalizeDescriptor(resource: resource, descriptor: descriptor)
    let resourceKey = try canonicalResourceKey(resource: resource, descriptor: normalized)
    let repositoryFingerprint =
      (authorization["repository"] as? [String: Any])?["fingerprint"] as? String
    if [sourceWriter, xcodeProject, buildTuple, github].contains(resource),
      normalized["repository_fingerprint"] as? String != repositoryFingerprint
    {
      throw ResourceCoordinatorError("authorization_scope_mismatch")
    }
    if resource == github {
      let githubScope = authorization["github"] as? [String: Any]
      let expected =
        "\(githubScope?["owner"] as? String ?? "")/\(githubScope?["repository"] as? String ?? "")"
        .lowercased()
      guard normalized["remote_repository"] as? String == expected else {
        throw ResourceCoordinatorError("authorization_scope_mismatch")
      }
    }
    guard let plans = authorization["resource_plan"] as? [[String: Any]] else {
      throw ResourceCoordinatorError("authorization_scope_mismatch")
    }
    let exact = plans.filter {
      $0["resource"] as? String == resource && $0["resource_key"] as? String == resourceKey
        && jsonEqual($0["resource_descriptor"], normalized)
        && $0["owner_actor"] as? String == authorization["selected_writer"] as? String
    }
    if [xcodeProject, buildTuple, simulator, coreSimulator, macOSGUI].contains(resource) {
      guard let planID, exact.count == 1, exact[0]["plan_id"] as? String == planID else {
        throw ResourceCoordinatorError("authorization_scope_mismatch")
      }
    } else {
      let grants = authorization["action_grants"] as? [[String: Any]] ?? []
      let grantKeys = Set(grants.compactMap { $0["resource_key"] as? String })
      guard grantKeys.contains(resourceKey) || exact.count == 1 else {
        throw ResourceCoordinatorError("authorization_scope_mismatch")
      }
    }
    return authority
  }
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    guard arguments.count >= 2 else { throw ResourceCoordinatorError("invalid_request") }
    let statePath = URL(fileURLWithPath: arguments[0])
    let command = arguments[1]
    var parsedOptions: [String: String] = [:]
    var parsedFlags = Set<String>()
    func option(_ key: String) -> String? { parsedOptions[key] }
    let result: [String: Any]
    do {
      let valuesByCommand: [String: Set<String>] = [
        "bootstrap": [], "status": [], "bundle-digest": [], "configure-host-policy": ["--policy"],
        "acquire": [
          "--harness", "--authorization", "--resource", "--descriptor", "--plan-id", "--run-id",
          "--actor", "--ttl-seconds", "--admission",
        ],
        "verify": ["--harness", "--receipt"],
        "heartbeat": ["--harness", "--receipt", "--ttl-seconds"],
        "release": ["--harness", "--receipt"],
        "recover": [
          "--harness", "--receipt", "--evidence", "--observer-harness", "--observer-authorization",
          "--replacement", "--replacement-harness", "--replacement-authorization",
          "--replacement-plan-id",
        ],
      ]
      let flagsByCommand: [String: Set<String>] = [
        "bootstrap": ["--legacy-leases-quiesced"],
        "configure-host-policy": ["--operator-confirmed"],
      ]
      guard let allowedValues = valuesByCommand[command] else {
        throw ResourceCoordinatorError("invalid_request")
      }
      let allowedFlags = flagsByCommand[command] ?? []
      var index = 2
      while index < arguments.count {
        let token = arguments[index]
        if allowedFlags.contains(token) {
          guard parsedFlags.insert(token).inserted else {
            throw ResourceCoordinatorError("invalid_request")
          }
          index += 1
          continue
        }
        guard allowedValues.contains(token), parsedOptions[token] == nil,
          index + 1 < arguments.count
        else { throw ResourceCoordinatorError("invalid_request") }
        parsedOptions[token] = arguments[index + 1]
        index += 2
      }
      switch command {
      case "bootstrap":
        result = try bootstrap(
          statePath: statePath,
          legacyLeasesQuiesced: parsedFlags.contains("--legacy-leases-quiesced"))
      case "status": result = try status(statePath: statePath)
      case "bundle-digest":
        result = ["source_bundle_sha256": try sourceBundleSHA256(skillRoot: context.harnessRoot)]
      case "configure-host-policy":
        guard let raw = option("--policy"), let data = raw.data(using: .utf8),
          let policy = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ResourceCoordinatorError("invalid_host_policy") }
        result = try configureHostPolicy(
          statePath: statePath, policy: policy,
          operatorConfirmed: parsedFlags.contains("--operator-confirmed"))
      default:
        guard let harnessRaw = option("--harness") else {
          throw ResourceCoordinatorError("invalid_request")
        }
        let harnessURL = URL(fileURLWithPath: harnessRaw)
        let harness = try loadTrustedHarness(harnessPath: harnessURL, context: context)
        _ = try validateTrustedBinding(
          statePath: statePath, binding: harness["resource_coordinator"] as! [String: Any],
          context: context)
        let writer = harness["selected_writer"] as! String
        if command == "acquire" {
          guard let resource = option("--resource"), let descriptorRaw = option("--descriptor"),
            let descriptorData = descriptorRaw.data(using: .utf8),
            let descriptor = try JSONSerialization.jsonObject(with: descriptorData)
              as? [String: Any], let runID = option("--run-id"), let actor = option("--actor"),
            let ttl = option("--ttl-seconds").flatMap(Int.init),
            let authorization = option("--authorization")
          else { throw ResourceCoordinatorError("invalid_request") }
          guard actor == writer else { throw ResourceCoordinatorError("writer_mismatch") }
          let authority = try loadRunAuthority(
            authorizationPath: URL(fileURLWithPath: authorization), harnessPath: harnessURL,
            harness: harness, runID: runID, resource: resource, descriptor: descriptor,
            planID: option("--plan-id"), context: context)
          var admission: [String: Any]?
          if let raw = option("--admission") {
            guard let data = raw.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ResourceCoordinatorError("invalid_admission") }
            admission = parsed
          }
          result = try acquire(
            statePath: statePath, resource: resource, descriptor: descriptor, ownerRunID: runID,
            ownerActor: actor, ttlSeconds: ttl, admission: admission, runAuthority: authority)
        } else {
          guard let receiptRaw = option("--receipt"), let data = receiptRaw.data(using: .utf8),
            let supplied = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            supplied["owner_actor"] as? String == writer
          else { throw ResourceCoordinatorError("writer_mismatch") }
          if command == "verify" {
            result = try verify(statePath: statePath, receipt: supplied)
          } else {
            let (_, authority) = try loadExistingRunAuthority(
              authorizationPath: URL(fileURLWithPath: harness["run_authorization"] as! String),
              harnessPath: harnessURL, harness: harness, runID: supplied["owner_run_id"] as! String,
              context: context)
            if command == "heartbeat", let ttl = option("--ttl-seconds").flatMap(Int.init) {
              result = try heartbeat(
                statePath: statePath, receipt: supplied, ttlSeconds: ttl, runAuthority: authority)
            } else if command == "release" {
              result = try release(statePath: statePath, receipt: supplied, runAuthority: authority)
            } else if command == "recover" {
              guard let evidenceRaw = option("--evidence"),
                let evidenceData = evidenceRaw.data(using: .utf8),
                let evidence = try JSONSerialization.jsonObject(with: evidenceData)
                  as? [String: Any], let observerHarnessRaw = option("--observer-harness"),
                let observerAuthorizationRaw = option("--observer-authorization"),
                let observer = evidence["observer"] as? [String: Any],
                let observerRunID = observer["observer_run_id"] as? String
              else { throw ResourceCoordinatorError("invalid_request") }
              let observerHarnessURL = URL(fileURLWithPath: observerHarnessRaw)
              let observerHarness = try loadTrustedHarness(
                harnessPath: observerHarnessURL, context: context)
              _ = try validateTrustedBinding(
                statePath: statePath,
                binding: observerHarness["resource_coordinator"] as! [String: Any], context: context
              )
              let (_, observerAuthority) = try loadExistingRunAuthority(
                authorizationPath: URL(fileURLWithPath: observerAuthorizationRaw),
                harnessPath: observerHarnessURL, harness: observerHarness, runID: observerRunID,
                context: context)
              var replacementRequest: [String: Any]?
              var replacementAuthority: [String: Any]?
              if let replacementRaw = option("--replacement") {
                guard let replacementData = replacementRaw.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: replacementData)
                    as? [String: Any], let replacementHarnessRaw = option("--replacement-harness"),
                  let replacementAuthorizationRaw = option("--replacement-authorization"),
                  let replacementRunID = parsed["owner_run_id"] as? String,
                  let replacementResource = parsed["resource"] as? String,
                  let replacementDescriptor = parsed["descriptor"] as? [String: Any]
                else { throw ResourceCoordinatorError("invalid_request") }
                let replacementHarnessURL = URL(fileURLWithPath: replacementHarnessRaw)
                let replacementHarness = try loadTrustedHarness(
                  harnessPath: replacementHarnessURL, context: context)
                _ = try validateTrustedBinding(
                  statePath: statePath,
                  binding: replacementHarness["resource_coordinator"] as! [String: Any],
                  context: context)
                guard
                  parsed["owner_actor"] as? String == replacementHarness["selected_writer"]
                    as? String
                else { throw ResourceCoordinatorError("writer_mismatch") }
                replacementAuthority = try loadRunAuthority(
                  authorizationPath: URL(fileURLWithPath: replacementAuthorizationRaw),
                  harnessPath: replacementHarnessURL, harness: replacementHarness,
                  runID: replacementRunID, resource: replacementResource,
                  descriptor: replacementDescriptor, planID: option("--replacement-plan-id"),
                  context: context)
                replacementRequest = parsed
              }
              result = try recover(
                statePath: statePath, receipt: supplied, evidence: evidence,
                runAuthority: authority, observerAuthority: observerAuthority,
                replacement: replacementRequest, replacementAuthority: replacementAuthority)
            } else {
              throw ResourceCoordinatorError("invalid_request")
            }
          }
        }
      }
      let wrapper: [String: Any] = ["status": "ok", "result": result]
      FileHandle.standardOutput.write(
        try HarnessRuntime.canonicalJSON(wrapper, ensureASCII: true) + Data([0x0a]))
      return 0
    } catch let error as ResourceCoordinatorError {
      let wrapper = blockedResponse(for: error)
      FileHandle.standardOutput.write(
        try HarnessRuntime.canonicalJSON(wrapper, ensureASCII: true) + Data([0x0a]))
      return 2
    } catch {
      let wrapper: [String: Any] = ["status": "blocked", "reason_code": "invalid_request"]
      FileHandle.standardOutput.write(
        try HarnessRuntime.canonicalJSON(wrapper, ensureASCII: true) + Data([0x0a]))
      return 2
    }
  }
}
