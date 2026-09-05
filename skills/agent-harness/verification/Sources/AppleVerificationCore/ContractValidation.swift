import Foundation

/// Semantic repository validation for executable contracts. Documentation layout, links,
/// and health probes are validated by their owning modules.
public enum ContractValidation {
  public static let controlSpine = [
    "intake", "guard", "health", "discover", "discover_spec_kit", "plan", "approve_plan",
    "branch_approval", "bind_spec_kit_snapshot", "bind_run_authorization",
    "claim_implementation_writer", "prepare_and_verify_branch", "claim_github_tracking",
    "ensure_issue_ready", "release_github_tracking", "claim_github_in_progress",
    "mark_issue_in_progress", "release_github_in_progress", "implement",
    "release_implementation_writer", "verify", "freeze_review", "review", "converge", "reverify",
    "prepare_evidence", "prepare_pr", "repository_confirmation", "claim_delivery_writer", "commit",
    "claim_github_mutation", "push", "verify_remote_sha", "release_delivery_writer", "create_pr",
    "mark_issue_in_review", "publish_evidence", "verify_published_evidence", "checks",
    "release_github_mutation", "pr_ready",
  ]
  public static let localSpine = [
    "intake", "guard", "health", "claim_implementation_writer", "implement",
    "release_implementation_writer", "verify", "local_verified",
  ]
  public static let testFlightSpine = [
    "bind_pr_ready", "verify_run_authorization", "health_gate", "claim_archive_build",
    "claim_testflight_upload", "archive", "verify_artifact", "release_archive_build", "upload",
    "wait_processing", "read_back_upload", "release_testflight_upload",
    "claim_upload_evidence_publication", "publish_upload_evidence", "verify_upload_evidence",
    "release_upload_evidence_publication", "testflight_uploaded", "claim_testflight_distribution",
    "verify_internal_groups", "distribute_internal", "read_back_distribution",
    "release_testflight_distribution", "claim_distribution_evidence_publication",
    "publish_distribution_evidence", "verify_distribution_evidence",
    "release_distribution_evidence_publication", "testflight_distributed",
  ]
  static let resources = [
    "source_checkout_writer", "xcode_project_mutation", "build_tuple", "simulator_or_device",
    "coresimulator_runtime_registry", "macos_gui_session", "signing_or_app_store_connect",
    "github_external_mutation",
  ]
  static let forbiddenActions = [
    "git.force_push", "github.auto_merge", "github.ruleset_change", "apple.app_review_submit",
    "apple.production_release", "apple.signing_resource_mutation", "credential.scope_expansion",
    "environment.destructive_cleanup",
  ]
  static var attemptPolicy: [String: Any] {
    [
      "max_implementation_attempts": 3, "max_review_cycles": 2, "max_transient_retries": 1,
      "identical_failure_stop_count": 2, "default_active_wall_minutes": 45,
      "pause_while_awaiting_human_or_ci": true,
    ]
  }
  static let edgeTypes = [
    "attempt_of", "supersedes", "produced_by", "validates", "invalidates", "feedback_on",
    "promoted_to", "authorized_by", "tracks", "continues_from", "derived_from",
  ]
  static var identityPolicy: [String: Any] {
    [
      "algorithm": "patch_identity_v1", "digest": "sha256", "base": "base_sha",
      "path_order": "utf8_bytewise",
      "path_record_fields": ["path", "mode", "state", "content_sha256_or_deletion"],
      "commit_equivalence": "commit_tree_and_changed_paths_match_reviewed_identity",
    ]
  }
  static let cleanupTriggers = ["blocked", "failed_terminal", "cancelled", "success_terminal"]

  public static func validateRepository(context: RuntimeContext) -> [String] {
    let root = context.repositoryRoot.standardizedFileURL
    let harness = context.harnessRoot.standardizedFileURL
    let skills = root.appendingPathComponent("skills")
    let contracts = harness.appendingPathComponent("contracts")
    let schemas = contracts.appendingPathComponent("schemas")
    var errors: [String] = []
    for directory in [
      contracts, skills.appendingPathComponent("delivery-report/contracts"),
      skills.appendingPathComponent("icon-composer/contracts"),
    ] { errors += validateJSONFiles(in: directory, relativeTo: root) }
    let pairs = [
      (
        "skills/agent-harness/contracts/capabilities.json",
        "skills/agent-harness/contracts/schemas/capabilities.schema.json"
      ),
      (
        "skills/agent-harness/contracts/workflow.json",
        "skills/agent-harness/contracts/schemas/workflow.schema.json"
      ),
      (
        "skills/agent-harness/contracts/local-workflow.json",
        "skills/agent-harness/contracts/schemas/local-workflow.schema.json"
      ),
      (
        "skills/agent-harness/contracts/testflight-workflow.json",
        "skills/agent-harness/contracts/schemas/testflight-workflow.schema.json"
      ),
      (
        "skills/agent-harness/templates/project-registry.local.example.json",
        "skills/agent-harness/contracts/schemas/project-registry.schema.json"
      ),
      (
        "skills/agent-harness/templates/completion-report.json",
        "skills/agent-harness/contracts/schemas/completion-report.schema.json"
      ),
      (
        "skills/agent-harness/templates/run-authorization.json",
        "skills/agent-harness/contracts/schemas/run-authorization.pending.schema.json"
      ),
      (
        "tests/fixtures/run-authorization-approved.json",
        "skills/agent-harness/contracts/schemas/run-authorization.schema.json"
      ),
      (
        "tests/fixtures/private-policy-overlay-approved.json",
        "skills/agent-harness/contracts/schemas/private-policy-overlay.schema.json"
      ),
      (
        "skills/agent-harness/templates/harness.json",
        "skills/agent-harness/contracts/schemas/harness.schema.json"
      ),
      (
        "skills/agent-harness/templates/harness-local.json",
        "skills/agent-harness/contracts/schemas/harness.schema.json"
      ),
      (
        "skills/apple-development-health/templates/health-observations.json",
        "skills/apple-development-health/contracts/health-report.schema.json"
      ),
      (
        "skills/icon-composer/contracts/companion-upstream.json",
        "skills/icon-composer/contracts/companion-upstream.schema.json"
      ),
      (
        "skills/delivery-report/templates/channel-config.json",
        "skills/delivery-report/contracts/channel-config.schema.json"
      ),
    ]
    for (instance, schema) in pairs {
      errors += validatePair(root: root, instancePath: instance, schemaPath: schema)
    }
    if let value = object(root, "skills/agent-harness/contracts/capabilities.json", errors: &errors)
    {
      errors += validateCapabilities(value)
    }
    if let value = object(root, "skills/agent-harness/contracts/workflow.json", errors: &errors) {
      errors += validateWorkflowSemantics(value, resources: Set(resources))
    }
    if let value = object(
      root, "skills/agent-harness/contracts/local-workflow.json", errors: &errors)
    {
      errors += validateLocalWorkflow(value, resources: Set(resources))
    }
    if let value = object(
      root, "skills/agent-harness/contracts/testflight-workflow.json", errors: &errors)
    {
      errors += validateTestFlightWorkflow(value, resources: Set(resources))
    }
    if let value = object(
      root, "skills/agent-harness/templates/completion-report.json", errors: &errors)
    {
      errors += validateCompletionReport(value)
    }
    if let value = object(
      root, "skills/delivery-report/templates/channel-config.json", errors: &errors)
    {
      errors += validateDeliveryChannelConfig(value)
    }
    if let value = object(
      root, "skills/agent-harness/templates/run-authorization.json", errors: &errors)
    {
      errors += validatePendingAuthorization(value)
    }
    if let value = object(root, "tests/fixtures/run-authorization-approved.json", errors: &errors) {
      errors += validateApprovedAuthorization(
        value, schemaURL: schemas.appendingPathComponent("run-authorization.schema.json"),
        context: context)
    }
    if let value = object(
      root, "skills/icon-composer/contracts/companion-upstream.json", errors: &errors)
    {
      errors += validateCompanionUpstream(value)
    }
    if let value = object(root, "tests/fixtures/rag-prompt-injection.json", errors: &errors) {
      errors += validatePromptInjectionFixture(value)
    }
    if let template = object(root, "skills/agent-harness/templates/harness.json", errors: &errors),
      let workflow = object(root, "skills/agent-harness/contracts/workflow.json", errors: &errors)
    {
      errors += validateHarnessTemplate(template, workflow: workflow)
    }
    if let template = object(root, "skills/agent-harness/templates/harness-local.json", errors: &errors),
      let workflow = object(root, "skills/agent-harness/contracts/local-workflow.json", errors: &errors)
    {
      errors += validateHarnessTemplate(template, workflow: workflow)
    }
    errors += validateIconGenWorkflow(
      at: root.appendingPathComponent(".github/workflows/icongen-upstream-watch.yml"))
    errors += validateExampleLedger(
      path: contracts.appendingPathComponent("example-ledger.jsonl"),
      schemaPath: schemas.appendingPathComponent("ledger-record.schema.json"), context: context)
    return Array(Set(errors)).sorted()
  }

  public static func validateDAG(_ nodes: [[String: Any]]) -> [String] {
    let ids = nodes.compactMap { $0["id"] as? String }
    guard ids.count == nodes.count, ids.allSatisfy({ !$0.isEmpty }) else {
      return ["every workflow node needs a non-empty string id"]
    }
    guard Set(ids).count == ids.count else { return ["workflow node ids must be unique"] }
    let known = Set(ids)
    var dependencies: [String: [String]] = [:]
    var errors = Set<String>()
    for node in nodes {
      let id = node["id"] as! String
      guard let requires = node["requires"] as? [String], Set(requires).count == requires.count
      else {
        errors.insert("node \(id) requires must be a unique string array")
        continue
      }
      dependencies[id] = requires
      for dependency in requires {
        if dependency == id {
          errors.insert("node \(id) cannot depend on itself")
        } else if !known.contains(dependency) {
          errors.insert("node \(id) references missing dependency \(dependency)")
        }
      }
    }
    var visiting = Set<String>()
    var visited = Set<String>()
    func visit(_ id: String) {
      if visiting.contains(id) {
        errors.insert("workflow contains a cycle at \(id)")
        return
      }
      guard !visited.contains(id) else { return }
      visiting.insert(id)
      for dependency in dependencies[id] ?? [] where dependencies[dependency] != nil {
        visit(dependency)
      }
      visiting.remove(id)
      visited.insert(id)
    }
    ids.forEach(visit)
    return errors.sorted()
  }

  public static func validateCompletionReport(_ report: [String: Any]) -> [String] {
    guard let usage = report["usage"] as? [String: Any] else {
      return ["completion report requires usage"]
    }
    do {
      try DeliveryReport.validateUsage(usage)
      return []
    } catch { return [String(describing: error)] }
  }

  public static func validateDeliveryChannelConfig(_ config: [String: Any]) -> [String] {
    let channels = config["channels"] as? [[String: Any]] ?? []
    let ids = channels.compactMap { $0["id"] as? String }
    let active = channels.filter { $0["enabled"] as? Bool == true }
    var errors: [String] = []
    if ids.count != channels.count || Set(ids).count != ids.count
      || ids.contains(where: { $0.isEmpty })
    {
      errors.append("delivery channel IDs must be unique non-empty strings")
    }
    if config["enabled"] as? Bool == true && active.isEmpty {
      errors.append("enabled delivery config requires one enabled channel")
    }
    if config["enabled"] as? Bool == false && !active.isEmpty {
      errors.append("disabled delivery config cannot contain enabled channels")
    }
    let prefixes = ["telegram": "bot-api", "whatsapp": "cloud-api", "imessage": "shortcuts"]
    for item in channels {
      let kind = item["kind"] as? String ?? ""
      let destination = item["destination_ref"] as? String ?? ""
      if ["telegram", "whatsapp"].contains(kind) && !present(item["credential_ref"]) {
        errors.append("\(kind) channel requires a private credential reference")
      }
      if kind == "imessage"
        && (present(item["credential_ref"]) || !destination.hasPrefix("shortcuts."))
      {
        errors.append("iMessage channel must keep its recipient only inside a Shortcut")
      }
      if kind != "imessage" && !destination.hasPrefix("private.") {
        errors.append("\(kind) channel destination must be a private alias")
      }
      if let prefix = prefixes[kind], !(item["transport_ref"] as? String ?? "").hasPrefix(prefix) {
        errors.append("\(kind) channel transport alias does not match its provider")
      }
      if kind != "whatsapp" && present(item["whatsapp_template_ref"]) {
        errors.append("only WhatsApp channels may reference a WhatsApp template")
      }
    }
    return Array(Set(errors)).sorted()
  }

  public static func validateLedgerLifecycle(
    _ records: [[String: Any]], coordinatorState: URL? = nil, context: RuntimeContext
  ) -> [String] {
    Array(
      Set(
        Authorization.ledgerContractErrors(
          records, coordinatorState: coordinatorState, context: context)
          + validateTestFlightLedgerTransitions(records))
    ).sorted()
  }

  public static func validatePromptInjectionFixture(_ fixture: [String: Any]) -> [String] {
    guard let expected = fixture["expected"] as? [String: Any] else {
      return ["RAG injection fixture must bind expected behavior"]
    }
    var errors: [String] = []
    if integer(expected["tool_calls"]) != 0 {
      errors.append("RAG injection fixture must expect zero tool calls")
    }
    if expected["authority"] as? String != "immutable_policy" {
      errors.append("RAG injection fixture must keep immutable policy authoritative")
    }
    return errors
  }

  public static func validateTestFlightLedgerTransitions(_ records: [[String: Any]]) -> [String] {
    var errors: [String] = []
    var states: [String: Set<String>] = [:]
    var artifacts: [String: [String]] = [:]
    for record in records {
      guard let payload = record["payload"] as? [String: Any] else { continue }
      if record["record_type"] as? String == "external_write",
        payload["system"] as? String == "apple"
      {
        let authorization = payload["authorization_hash"] as? String ?? ""
        let action = payload["action"] as? String ?? ""
        let target = payload["target"] as? String ?? ""
        let identity = ["artifact_sha256", "artifact_source_commit", "version", "build"].map {
          payload[$0] as? String ?? ""
        }
        if identity.contains(where: { $0.isEmpty }) {
          errors.append(
            "Apple external writes must record exact artifact, source, version, and build")
        } else if let previous = artifacts[authorization], previous != identity {
          errors.append("Apple external write artifact identity drifted within authorization")
        } else {
          artifacts[authorization] = identity
        }
        guard payload["outcome"] as? String == "succeeded" else { continue }
        var current = states[authorization, default: []]
        if action == "apple.testflight.upload" {
          current.insert("upload_accepted")
        } else if action == "apple.testflight.processing.wait" {
          if !current.contains("upload_accepted") {
            errors.append("processing wait requires a prior accepted upload")
          }
          current.insert("processing_waited")
        } else if action == "apple.testflight.readback" && target.hasSuffix(":upload") {
          if !current.contains("processing_waited")
            || payload["external_state"] as? String != "completed"
          {
            errors.append("upload read-back must follow bounded processing and be completed")
          } else {
            current.insert("upload_completed")
          }
        } else if action == "apple.testflight.distribute_internal" {
          if !current.contains("upload_completed") {
            errors.append("internal distribution requires completed upload read-back")
          }
          current.insert("distributed:\(target)")
        } else if action == "apple.testflight.readback" && target.contains(":group:") {
          if !current.contains("distributed:\(target)")
            || payload["external_state"] as? String != "completed"
          {
            errors.append("distribution read-back must follow exact distribution and be completed")
          } else {
            current.insert("distribution_completed:\(target)")
          }
        }
        states[authorization] = current
      }
      if record["record_type"] as? String == "node", payload["status"] as? String == "passed" {
        if payload["node_id"] as? String == "testflight_uploaded"
          && !states.values.contains(where: { $0.contains("upload_completed") })
        {
          errors.append("testflight_uploaded requires completed upload read-back")
        }
        if payload["node_id"] as? String == "testflight_distributed"
          && !states.values.contains(where: { values in
            values.contains(where: { $0.hasPrefix("distribution_completed:") })
          })
        {
          errors.append("testflight_distributed requires completed distribution read-back")
        }
      }
    }
    return Array(Set(errors)).sorted()
  }

  static func validatePair(root: URL, instancePath: String, schemaPath: String) -> [String] {
    do {
      var instance = try HarnessRuntime.loadJSON(root.appendingPathComponent(instancePath))
      let schema = try HarnessRuntime.object(root.appendingPathComponent(schemaPath))
      if let object = instance as? [String: Any],
        (schema["properties"] as? [String: Any])?["$schema"] == nil
      {
        var copy = object
        copy.removeValue(forKey: "$schema")
        instance = copy
      }
      return JSONSchemaValidator.errors(instance: instance, schema: schema).map {
        "schema violation \(instancePath): \($0)"
      }
    } catch { return ["cannot validate \(instancePath) against \(schemaPath): \(error)"] }
  }
  static func validateJSONFiles(in directory: URL, relativeTo root: URL) -> [String] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return ["contract directory is unavailable: \(directory.path)"] }
    var errors: [String] = []
    for case let file as URL in enumerator where file.pathExtension == "json" {
      do {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          errors.append("contract JSON must be a regular non-symlink file: \(relative(file,root))")
          continue
        }
        _ = try HarnessRuntime.loadJSON(file)
      } catch { errors.append("invalid JSON \(relative(file,root)): \(error)") }
    }
    return errors
  }
  static func validateExampleLedger(path: URL, schemaPath: URL, context: RuntimeContext) -> [String]
  {
    do {
      let schema = try HarnessRuntime.object(schemaPath)
      let text = try String(contentsOf: path, encoding: .utf8)
      var records: [[String: Any]] = []
      var errors: [String] = []
      for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty
      {
        guard let data = line.data(using: .utf8),
          let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          errors.append("invalid example ledger JSON at line \(index+1)")
          continue
        }
        records.append(record)
        errors += JSONSchemaValidator.errors(instance: record, schema: schema).map {
          "example ledger schema line \(index+1): \($0)"
        }
      }
      errors += validateLedgerLifecycle(records, context: context)
      return errors
    } catch { return ["example ledger is unavailable or invalid: \(error)"] }
  }

  static func object(_ root: URL, _ relative: String, errors: inout [String]) -> [String: Any]? {
    do { return try HarnessRuntime.object(root.appendingPathComponent(relative)) } catch {
      errors.append("invalid object \(relative): \(error)")
      return nil
    }
  }
  static func keyed(_ nodes: [[String: Any]]) -> [String: [String: Any]] {
    var result: [String: [String: Any]] = [:]
    for node in nodes { if let id = node["id"] as? String, result[id] == nil { result[id] = node } }
    return result
  }
  static func dependencies(of node: String, byID: [String: [String: Any]]) -> Set<String> {
    var result = Set<String>()
    var pending = byID[node]?["requires"] as? [String] ?? []
    while let next = pending.popLast() {
      if result.insert(next).inserted { pending += byID[next]?["requires"] as? [String] ?? [] }
    }
    return result
  }
  static func cleanup(_ values: [String]) -> [String: Any] {
    ["mode": "finally", "triggers": cleanupTriggers, "release_active_resources": values]
  }
  static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }
  static func present(_ value: Any?) -> Bool { value != nil && !(value is NSNull) }
  static func integer(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, !HarnessRuntime.isBoolean(n) else { return nil }
    let raw = n.stringValue
    guard let result = Int(raw), raw == String(result) || raw == "-0" else { return nil }
    return result
  }
  static func hash(_ value: Any?) -> String? {
    guard let value, let data = try? HarnessRuntime.canonicalJSON(value) else { return nil }
    return HarnessRuntime.sha256(data)
  }
  static func matches(_ value: Any?, _ pattern: String) -> Bool {
    guard let value = value as? String else { return false }
    return value.range(of: pattern, options: .regularExpression) != nil
  }
  static func safeRelative(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/")
      && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
  static func relative(_ file: URL, _ root: URL) -> String {
    file.path.hasPrefix(root.path + "/")
      ? String(file.path.dropFirst(root.path.count + 1)) : file.path
  }
}
