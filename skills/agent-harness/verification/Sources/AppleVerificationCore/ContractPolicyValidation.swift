import Foundation

extension ContractValidation {
  /// Why `capabilities` is not the reviewed policy this runtime honors. Its shape is checked
  /// against capabilities.schema.json with the other contract pairs; `CapabilityPolicy` explains
  /// the digest and the runtime loader applies the same rules.
  public static func validateCapabilities(_ capabilities: [String: Any]) -> [String] {
    Array(
      Set(CapabilityPolicy.errors(capabilities, reviewedSHA256: CapabilityPolicy.reviewedSHA256))
    ).sorted()
  }

  public static func validatePendingAuthorization(_ pending: [String: Any]) -> [String] {
    var errors: [String] = []
    if pending["schema_version"] as? String != "1.0.0" {
      errors.append("run authorization template schema version drifted")
    }
    if pending["decision"] as? String != "pending" {
      errors.append("run authorization template must remain pending until instantiated")
    }
    for field in ["action_grants", "allowed_paths", "resource_plan", "acceptance_ids"]
    where !((pending[field] as? [Any])?.isEmpty == true) {
      errors.append("run authorization template \(field) must remain empty")
    }
    for field in [
      "run_id", "authorization_id", "actor", "selected_writer", "issued_at", "expires_at",
      "repository", "github", "apple", "health_attestation", "contract_schema_id",
      "contract_schema_sha256", "spec_kit", "local_requirements",
    ] where present(pending[field]) {
      errors.append(
        "run authorization template must not contain executable identity, authority, or time: \(field)"
      )
    }
    if pending["delivery_target"] as? String != "pr_ready"
      || pending["health_profile"] as? String != "pr_ready"
    {
      errors.append("run authorization template must retain the inert pr_ready profile")
    }
    let limits: [String: Any] = [
      "active_wall_minutes": 45, "async_wait_minutes": 45, "max_implementation_attempts": 3,
      "max_review_cycles": 2, "max_transient_retries": 1,
    ]
    if !equal(pending["limits"], limits) {
      errors.append("run authorization pending limits drifted")
    }
    if pending["forbidden_actions"] as? [String] != forbiddenActions {
      errors.append("run authorization pending forbidden action boundary drifted")
    }
    for field in [
      "auto_merge", "app_review_submit", "credential_scope_expansion", "signing_resource_mutation",
      "destructive_cleanup",
    ] where pending[field] as? Bool != false {
      errors.append("run authorization pending \(field) must remain false")
    }
    return Array(Set(errors)).sorted()
  }

  public static func validateApprovedAuthorization(
    _ authorization: [String: Any], schemaURL: URL, context: RuntimeContext
  ) -> [String] {
    var errors = Authorization.validateAuthorization(authorization, context: context)
    if let schema = try? HarnessRuntime.object(schemaURL),
      authorization["contract_schema_id"] as? String != schema["$id"] as? String
    {
      errors.append("approved authorization schema ID drifted")
    }
    if let digest = try? HarnessRuntime.sha256File(schemaURL),
      authorization["contract_schema_sha256"] as? String != "sha256:" + digest
    {
      errors.append("approved authorization schema content binding drifted")
    }
    return Array(Set(errors)).sorted()
  }

  public static func validateHarnessTemplate(_ template: [String: Any], workflow: [String: Any])
    -> [String]
  {
    var errors: [String] = []
    if integer(template["max_active_repository_writers"]) != 1 {
      errors.append("harness must allow exactly one active repository writer")
    }
    let policy = workflow["attempt_policy"] as? [String: Any] ?? [:]
    for key in ["max_implementation_attempts", "max_review_cycles"]
    where !equal(template[key], policy[key]) {
      errors.append("harness template \(key) drifted from workflow")
    }
    let components = Set(template["health_components"] as? [String] ?? [])
    let spec = template["spec_kit"] as? [String: Any]
    if spec?["enabled"] as? Bool == true && !components.contains("spec_kit") {
      errors.append("harness enabled Spec Kit must select the Spec Kit health component")
    }
    if let project = (template["github_tracking"] as? [String: Any])?["project"], present(project),
      !components.contains("github_project")
    {
      errors.append("harness configured Project must select the Project health component")
    }
    guard let runtime = template["authorization_runtime"] as? [String: Any] else {
      return errors + ["harness must bind the Swift authorization runtime"]
    }
    errors += validateSwiftRuntimeBinding(
      runtime, contract: Authorization.runtimeContract, requireExecutablePath: true)
    if template["delivery_target"] as? String == "local_verified" {
      guard let requirements = template["local_requirements"] as? [String: Any],
        Set(requirements.keys) == ["review_required", "spec_kit_required"],
        requirements.values.allSatisfy({ $0 is Bool })
      else {
        errors.append("local harness must bind exact local requirements")
        return errors
      }
    } else if present(template["local_requirements"]) {
      errors.append("non-local harness cannot bind local requirements")
    }
    return errors
  }

  public static func validateSwiftRuntimeBinding(
    _ binding: [String: Any], contract: String, requireExecutablePath: Bool = false
  ) -> [String] {
    var exact: Set<String> = [
      "runtime_kind", "runtime_contract", "executable_sha256", "source_bundle_sha256",
    ]
    if requireExecutablePath { exact.insert("executable_path") }
    guard Set(binding.keys) == exact else {
      return ["runtime binding fields are invalid or legacy"]
    }
    guard binding["runtime_kind"] as? String == "swift",
      binding["runtime_contract"] as? String == contract
    else { return ["runtime binding must name the installed Swift contract"] }
    if requireExecutablePath && !(binding["executable_path"] as? String ?? "").hasPrefix("/") {
      return ["runtime binding executable path must be absolute"]
    }
    for key in ["executable_sha256", "source_bundle_sha256"]
    where !matches(binding[key], #"^sha256:[0-9a-f]{64}$"#) {
      return ["runtime binding \(key) is invalid"]
    }
    return []
  }

  public static func validateCompanionUpstream(_ manifest: [String: Any]) -> [String] {
    var errors: [String] = []
    let upstream = manifest["upstream"] as? [String: Any] ?? [:]
    let integration = manifest["integration"] as? [String: Any] ?? [:]
    let license = manifest["license"] as? [String: Any] ?? [:]
    if upstream["repository"] as? String != "ShawnBaek/IconGen"
      || upstream["visibility"] as? String != "public"
      || upstream["default_branch"] as? String != "main"
    {
      errors.append("IconGen companion upstream identity, visibility, or branch drifted")
    }
    for field in ["reviewed_revision", "reviewed_tree"]
    where !matches(upstream[field], #"^[0-9a-f]{40}$"#) {
      errors.append("IconGen companion \(field) must be a full Git object identity")
    }
    if (try? HarnessRuntime.parseTimestamp(upstream["observed_at"] as? String ?? "")) == nil {
      errors.append("IconGen companion observation timestamp is invalid")
    }
    let expected: [String: Any] = [
      "mode": "reference-only", "execute_upstream": false, "vendored_files": [],
      "consumer_skill": "icon-composer",
      "consumer_repository": "ShawnBaek/ai-workflow-apple-platform-engineer",
      "drift_action": "create_or_update_review_issue", "auto_merge": false,
    ]
    if !equal(integration, expected) {
      errors.append("IconGen companion upstream safety boundary drifted")
    }
    if license["status"] as? String == "absent"
      && !((integration["vendored_files"] as? [Any])?.isEmpty ?? false)
    {
      errors.append("unlicensed companion upstream cannot have vendored files")
    }
    let sources = manifest["sources"] as? [[String: Any]] ?? []
    let paths = sources.compactMap { $0["path"] as? String }
    if sources.isEmpty || paths.count != sources.count || Set(paths).count != paths.count
      || sources.contains(where: {
        Set($0.keys) != ["path", "blob_sha", "purpose"]
          || !matches($0["blob_sha"], #"^[0-9a-f]{40}$"#)
          || ($0["purpose"] as? String)?.isEmpty != false
          || !safeRelative($0["path"] as? String ?? "")
      })
    {
      errors.append("IconGen reviewed source provenance is incomplete or unsafe")
    }
    return Array(Set(errors)).sorted()
  }

  static func validateIconGenWorkflow(at path: URL) -> [String] {
    guard let text = try? String(contentsOf: path, encoding: .utf8) else {
      return ["IconGen watcher workflow is unavailable"]
    }
    var errors: [String] = []
    guard let trigger = capture(text, #"(?ms)^on:\n(?<body>.*?)^permissions:\n"#, name: "body")
    else { return ["IconGen watcher trigger block is missing"] }
    if captures(trigger, #"(?m)^  ([A-Za-z_][A-Za-z0-9_-]*):?\s*$"#) != [
      "schedule", "workflow_dispatch",
    ] {
      errors.append("IconGen watcher triggers must be exactly schedule and workflow_dispatch")
    }
    let permissions =
      capture(text, #"(?ms)^permissions:\n(?<body>.*?)^concurrency:\n"#, name: "body")?.split(
        separator: "\n"
      ).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    if permissions != ["contents: read", "issues: write"] {
      errors.append("IconGen watcher permissions must remain contents read and issues write only")
    }
    if captures(text, #"(?m)^\s*uses:\s*(\S+)"#) != [
      "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
    ] {
      errors.append("IconGen watcher may use only the pinned checkout action")
    }
    // By default actions/checkout stores the job's issue-write token in .git/config, where every
    // later step, including the Swift build, can read it. gh receives the token through env.
    if text.range(
      of:
        #"(?m)^\s*uses:\s*actions/checkout@\S+[^\n]*\n\s+with:\n\s+persist-credentials: false\s*$"#,
      options: .regularExpression) == nil
    {
      errors.append("IconGen watcher checkout must set persist-credentials: false")
    }
    guard let jobs = capture(text, #"(?ms)^jobs:\n(?<body>.*)\z"#, name: "body") else {
      return errors + ["IconGen watcher jobs block is missing"]
    }
    if captures(jobs, #"(?m)^  ([A-Za-z_][A-Za-z0-9_-]*):\s*$"#) != ["compare"] {
      errors.append("IconGen watcher must contain exactly one compare job")
    }
    for required in [
      "runs-on: macos-15", "timeout-minutes: 15", "\"$APE_BIN_DIR/apple-verify\" companion",
      "if: github.repository == 'ShawnBaek/ai-workflow-apple-platform-engineer'",
      "--show-bin-path",
      "--target-repository \"$GITHUB_REPOSITORY\"",
    ] where !text.contains(required) { errors.append("IconGen watcher execution contract drifted") }
    for forbidden in [
      "pull_request_target", "auto-merge", "write-all", "contents: write", "pull-requests: write",
      "id-token: write",
    ] where text.contains(forbidden) {
      errors.append("IconGen watcher gained a forbidden privilege or action: \(forbidden)")
    }
    return Array(Set(errors)).sorted()
  }
  static func capture(_ text: String, _ pattern: String, name: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(withName: name), in: text)
    else { return nil }
    return String(text[range])
  }
  static func captures(_ text: String, _ pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      match in
      guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else {
        return nil
      }
      return String(text[range])
    }
  }
}
