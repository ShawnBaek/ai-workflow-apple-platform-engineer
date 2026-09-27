import Foundation

extension Authorization {
  private static let topLevelFields: Set<String> = [
    "schema_version", "contract_schema_id", "contract_schema_sha256", "run_id", "authorization_id",
    "decision",
    "actor", "selected_writer", "issued_at", "expires_at", "delivery_target", "health_profile",
    "resource_plan",
    "health_attestation", "repository", "spec_kit", "acceptance_ids", "allowed_paths", "limits",
    "github", "apple",
    "action_grants", "forbidden_actions", "auto_merge", "app_review_submit",
    "credential_scope_expansion",
    "signing_resource_mutation", "destructive_cleanup",
  ]

  public static func validateAuthorization(_ envelope: [String: Any], context: RuntimeContext)
    -> [String]
  {
    let local = envelope["delivery_target"] as? String == "local_verified"
    let requiredFields = local ? topLevelFields.union(["local_requirements"]) : topLevelFields
    var errors = objectShape(
      envelope, required: requiredFields,
      allowed: topLevelFields.union(["$schema", "local_requirements"]), label: "authorization")
    if let schemaURL = installedSchemaURL(context),
      let schema = try? HarnessRuntime.object(schemaURL)
    {
      errors += schemaErrors(instance: envelope, schema: schema)
      if envelope["contract_schema_id"] as? String != schema["$id"] as? String {
        errors.append("approved authorization schema identity drifted")
      }
      if envelope["contract_schema_sha256"] as? String != "sha256:"
        + ((try? HarnessRuntime.sha256File(schemaURL)) ?? "")
      {
        errors.append("approved authorization schema content drifted")
      }
    } else {
      errors.append("installed approved authorization schema is unavailable")
    }
    if (envelope["$schema"] as? String)?.isEmpty != false {
      errors.append("authorization schema location must be a non-empty string")
    }
    if envelope["schema_version"] as? String != "1.0.0" {
      errors.append("unsupported authorization schema")
    }
    if envelope["decision"] as? String != "approved" {
      errors.append("authorization is not approved")
    }
    for field in ["run_id", "authorization_id", "actor"]
    where (envelope[field] as? String)?.isEmpty != false {
      errors.append("authorization \(field) must be a non-empty string")
    }
    let writer = envelope["selected_writer"] as? String
    if !["codex", "claude"].contains(writer ?? "") {
      errors.append("authorization selected_writer must be codex or claude")
    }
    let delivery = envelope["delivery_target"] as? String
    if !["local_verified", "pr_ready", "testflight_uploaded", "testflight_distributed"].contains(
      delivery ?? "")
    {
      errors.append("unsupported delivery target")
    }
    let healthProfile = envelope["health_profile"] as? String
    if ![
      "local_verified", "pr_ready", "runtime_ui", "testflight_uploaded", "testflight_distributed",
      "icon_upstream",
    ].contains(healthProfile ?? "") {
      errors.append("authorization health profile is invalid")
    }
    if delivery?.hasPrefix("testflight_") == true, healthProfile != delivery {
      errors.append("TestFlight authorization health profile must match its delivery target")
    }
    errors += validateHealthAttestation(envelope)
    errors += validateRepository(envelope)
    errors += validateSpecKit(envelope)
    errors += validateResourcePlan(envelope, context: context)
    guard uniqueStrings(envelope["acceptance_ids"]) else {
      errors.append("authorization requires unique acceptance IDs")
      return Array(Set(errors)).sorted()
    }
    let paths = envelope["allowed_paths"] as? [String] ?? []
    if !uniqueStrings(paths) {
      errors.append("authorization requires unique allowed paths")
    }
    if paths.contains(where: { !safeRelativePath($0) }) {
      errors.append("authorization allowed paths must be safe repository-relative paths")
    }
    let limits = envelope["limits"] as? [String: Any]
    errors += objectShape(
      limits, required: Set(limitBounds.keys), allowed: Set(limitBounds.keys), label: "limits")
    if limits == nil
      || limitBounds.contains(where: { key, bounds in
        jsonInt(limits?[key]).map { !bounds.contains($0) } ?? true
      })
    {
      errors.append("authorization attempt and time limits are invalid")
    }
    if let issued = try? HarnessRuntime.parseTimestamp(text(envelope["issued_at"])),
      let expires = try? HarnessRuntime.parseTimestamp(text(envelope["expires_at"]))
    {
      if expires <= issued {
        errors.append("authorization expiry must be after issuance")
      } else if expires.timeIntervalSince(issued) > maximumAuthorizationLifetime {
        errors.append("authorization expiry exceeds the 24-hour maximum approval window")
      }
    } else {
      errors.append("authorization issue or expiry time is invalid or lacks timezone")
    }
    let github = envelope["github"] as? [String: Any]
    if delivery == "local_verified" {
      if !(envelope["github"] is NSNull) && envelope["github"] != nil {
        errors.append("local verification cannot bind GitHub authorization")
      }
      if !(envelope["apple"] is NSNull) && envelope["apple"] != nil {
        errors.append("local verification cannot bind Apple authorization")
      }
      let requirements = envelope["local_requirements"] as? [String: Any]
      errors += objectShape(
        requirements, required: ["review_required", "spec_kit_required"],
        allowed: ["review_required", "spec_kit_required"], label: "local verification requirements")
      if requirements?["review_required"] as? Bool == nil
        || requirements?["spec_kit_required"] as? Bool == nil
      {
        errors.append("local verification requirements must be booleans")
      }
      let requiresSpec = requirements?["spec_kit_required"] as? Bool == true
      let hasSpec = !(envelope["spec_kit"] is NSNull) && envelope["spec_kit"] != nil
      if requiresSpec != hasSpec {
        errors.append("local Spec Kit binding must match the accepted plan requirement")
      }
    } else {
      errors += objectShape(
        github, required: ["owner", "repository", "issue_number", "project"],
        allowed: ["owner", "repository", "issue_number", "project"], label: "GitHub authorization")
      if (github?["owner"] as? String)?.isEmpty != false
        || (github?["repository"] as? String)?.isEmpty != false
      {
        errors.append("authorization must bind the GitHub repository")
      }
    }
    let grants = envelope["action_grants"] as? [[String: Any]] ?? []
    if grants.isEmpty && delivery != "local_verified" {
      errors.append("authorization requires at least one action grant")
    }
    errors += validateGrants(envelope, grants: grants)
    if Set(envelope["forbidden_actions"] as? [String] ?? []) != forbiddenActions {
      errors.append("forbidden action boundary drifted")
    }
    for flag in [
      "auto_merge", "app_review_submit", "credential_scope_expansion", "signing_resource_mutation",
      "destructive_cleanup",
    ] where envelope[flag] as? Bool != false { errors.append("\(flag) must remain false") }
    return Array(Set(errors)).sorted()
  }

  public static func appleObservationStateSHA256(_ observation: [String: Any]) throws -> String {
    let fields = [
      "source", "guard_verified", "account_guard_ref", "team_id", "app_id", "bundle_id", "platform",
      "live_build", "internal_group_ids",
    ]
    return try canonicalSHA256(
      Dictionary(uniqueKeysWithValues: fields.map { ($0, observation[$0] ?? NSNull()) }))
  }

  public static func liveAppleErrors(
    envelope: [String: Any], request: [String: Any], observation: Any?, now: Date
  ) -> [String] {
    let fields: Set<String> = [
      "source", "guard_verified", "observed_at", "account_guard_ref", "team_id", "app_id",
      "bundle_id", "platform", "live_build", "internal_group_ids",
    ]
    var errors = objectShape(
      observation, required: fields, allowed: fields, label: "live Apple observation")
    guard let observation = observation as? [String: Any] else { return errors }
    let apple = envelope["apple"] as? [String: Any] ?? [:]
    if observation["source"] as? String != "asc_read_only"
      || observation["guard_verified"] as? Bool != true
    {
      errors.append("live Apple observation must come from the guarded read-only ASC route")
    }
    if ["account_guard_ref", "team_id", "app_id", "bundle_id", "platform"].contains(where: {
      !same(observation[$0], apple[$0])
    }) {
      errors.append("live Apple account, team, app, bundle, or platform drifted")
    }
    if !same(observation["internal_group_ids"], apple["internal_group_ids"]) {
      errors.append("live TestFlight internal groups drifted from authorization")
    }
    if let observed = try? HarnessRuntime.parseTimestamp(text(observation["observed_at"])) {
      let age = now.timeIntervalSince(observed)
      if age < -60 || age > 300 {
        errors.append("live Apple observation is stale or from the future")
      }
    } else {
      errors.append("live Apple observation time is invalid")
    }
    let build = apple["build_policy"] as? [String: Any] ?? [:]
    if build["mode"] as? String == "next_after_live",
      text(observation["live_build"]) != text(build["baseline"])
    {
      errors.append("authorized live-build baseline drifted from the current ASC observation")
    }
    if request["apple_observation_sha256"] as? String != (try? canonicalSHA256(observation)) {
      errors.append("live Apple observation digest drifted from the action request")
    }
    return Array(Set(errors)).sorted()
  }

  private static func validateHealthAttestation(_ envelope: [String: Any]) -> [String] {
    let fields: Set<String> = [
      "report_sha256", "observed_at", "profile", "overall_status", "authoritative_targets_sha256",
      "agent_skill_bundle_sha256", "coordinator_instance_id", "coordinator_contract_bundle_sha256",
    ]
    let health = envelope["health_attestation"] as? [String: Any]
    var errors = objectShape(
      health, required: fields, allowed: fields, label: "authorization health attestation")
    guard let health else { return errors }
    if health["profile"] as? String != envelope["health_profile"] as? String {
      errors.append("authorization health attestation profile drifted")
    }
    if !["healthy", "degraded"].contains(health["overall_status"] as? String ?? "") {
      errors.append("authorization health attestation is not usable")
    }
    for field in [
      "report_sha256", "authoritative_targets_sha256", "agent_skill_bundle_sha256",
      "coordinator_contract_bundle_sha256",
    ] where !regex(health[field], #"^sha256:[0-9a-f]{64}$"#) {
      errors.append("authorization health attestation \(field) is invalid")
    }
    if (health["coordinator_instance_id"] as? String)?.isEmpty != false {
      errors.append("authorization health coordinator instance is invalid")
    }
    if let observed = try? HarnessRuntime.parseTimestamp(text(health["observed_at"])),
      let issued = try? HarnessRuntime.parseTimestamp(text(envelope["issued_at"])),
      observed <= issued, issued.timeIntervalSince(observed) <= 300
    {
    } else {
      errors.append("authorization health attestation is stale at issuance")
    }
    return errors
  }

  private static func validateRepository(_ envelope: [String: Any]) -> [String] {
    let fields: Set<String> = ["fingerprint", "canonical_root", "remote", "base_sha", "branch"]
    let repository = envelope["repository"] as? [String: Any]
    var errors = objectShape(
      repository, required: fields, allowed: fields, label: "repository authorization")
    guard let repository else { return errors }
    if fields.contains(where: { text(repository[$0]).isEmpty }) {
      errors.append("authorization must bind the exact repository and branch")
    }
    do {
      if try repositoryFingerprint(text(repository["remote"])) != repository["fingerprint"]
        as? String
      {
        errors.append("authorization repository fingerprint does not match its logical remote")
      }
    } catch { errors.append("authorization repository remote is unsafe or unsupported") }
    return errors
  }

  private static func validateSpecKit(_ envelope: [String: Any]) -> [String] {
    guard !(envelope["spec_kit"] is NSNull), envelope["spec_kit"] != nil else { return [] }
    let fields: Set<String> = [
      "release", "feature_id", "feature_directory", "approved_git_branch", "snapshot_sha256",
      "artifact_hashes", "workflow_run_id",
    ]
    let spec = envelope["spec_kit"] as? [String: Any]
    var errors = objectShape(spec, required: fields, allowed: fields, label: "Spec Kit binding")
    guard let spec else { return errors + ["Spec Kit authorization binding is invalid"] }
    if spec["release"] as? String != SpecKitSnapshot.pinnedRelease
      || fields.subtracting(["artifact_hashes"]).contains(where: { text(spec[$0]).isEmpty })
      || (spec["artifact_hashes"] as? [String: Any])?.isEmpty != false
    {
      errors.append("Spec Kit authorization binding is invalid")
    }
    if spec["approved_git_branch"] as? String != (envelope["repository"] as? [String: Any])?[
      "branch"] as? String
    {
      errors.append("Spec Kit accepted branch mapping drifted from repository binding")
    }
    return errors
  }

  private static func validateResourcePlan(_ envelope: [String: Any], context: RuntimeContext)
    -> [String]
  {
    guard let plan = envelope["resource_plan"] as? [[String: Any]] else {
      return ["authorization resource plan must be an array"]
    }
    var errors: [String] = []
    // Plannable resources come from the installed capability policy; a policy that is missing,
    // malformed or not the reviewed one admits no planned lease. That one error already rejects
    // the plan, so `nil` skips the per-entry resource check that would repeat it.
    var resources: Set<String>? = []
    if !plan.isEmpty {
      do {
        resources = Set(try CapabilityPolicy.load(context: context).resourceScopes)
      } catch {
        errors.append(String(describing: error))
        resources = nil
      }
    }
    var ids = Set<String>()
    var identities = Set<String>()
    var workflowNodes: [String: [String: Any]] = [:]
    var allowedNodes = Set<String>()
    func nodes(_ file: String) -> [[String: Any]] {
      for path in ["contracts/\(file)", "skills/agent-harness/contracts/\(file)"] {
        if let object = try? HarnessRuntime.object(
          context.harnessRoot.appendingPathComponent(path)),
          let values = object["nodes"] as? [[String: Any]]
        {
          return values
        }
      }
      return []
    }
    let main = nodes("workflow.json")
    let continuation = nodes("testflight-workflow.json")
    let local = nodes("local-workflow.json")
    let selectedMain = envelope["delivery_target"] as? String == "local_verified" ? local : main
    let all =
      envelope["delivery_target"] as? String == "local_verified" ? local : main + continuation
    for node in all {
      guard let id = node["id"] as? String, !id.isEmpty, workflowNodes[id] == nil else {
        errors.append("installed workflow node IDs must be unique and non-empty")
        continue
      }
      workflowNodes[id] = node
    }
    if envelope["delivery_target"] as? String == "local_verified" {
      if let health = selectedMain.firstIndex(where: { $0["id"] as? String == "health" }) {
        allowedNodes.formUnion(
          selectedMain.suffix(from: health + 1).compactMap { $0["id"] as? String })
      }
    } else if let binding = selectedMain.firstIndex(where: {
      $0["id"] as? String == "bind_run_authorization"
    }) {
      allowedNodes.formUnion(
        selectedMain.suffix(from: binding + 1).compactMap { $0["id"] as? String })
    }
    if envelope["delivery_target"] as? String != "pr_ready",
      let start = continuation.firstIndex(where: { $0["id"] as? String == "health_gate" }),
      let end = continuation.firstIndex(where: { $0["id"] as? String == "testflight_uploaded" })
    {
      allowedNodes.formUnion(continuation[(start + 1)...end].compactMap { $0["id"] as? String })
    }
    if envelope["delivery_target"] as? String == "testflight_distributed" {
      allowedNodes.formUnion(continuation.compactMap { $0["id"] as? String })
    }
    for entry in plan {
      let fields: Set<String> = [
        "plan_id", "resource", "resource_key", "descriptor_sha256", "resource_descriptor",
        "owner_actor", "protects",
      ]
      if Set(entry.keys) != fields {
        errors.append("authorization resource plan entry has invalid fields")
        continue
      }
      let id = text(entry["plan_id"])
      let resource = text(entry["resource"])
      let key = text(entry["resource_key"])
      if id.isEmpty || !ids.insert(id).inserted {
        errors.append("authorization resource plan IDs must be unique and non-empty")
      }
      if let resources, !resources.contains(resource) {
        errors.append("authorization resource plan uses an unknown resource")
      }
      if !key.hasPrefix(resource + ":sha256:") || !identities.insert(resource + "\0" + key).inserted
      {
        errors.append("authorization resource plan identity is invalid or duplicated")
      }
      if entry["owner_actor"] as? String != envelope["selected_writer"] as? String {
        errors.append("authorization resource plan owner must be the selected writer")
      }
      if !uniqueStrings(entry["protects"]) {
        errors.append("authorization resource plan protected nodes are invalid")
      } else if let protects = entry["protects"] as? [String],
        protects.contains(where: { workflowNodes[$0] == nil })
      {
        errors.append("authorization resource plan protects an unknown workflow node")
      } else if let protects = entry["protects"] as? [String],
        protects.contains(where: { !allowedNodes.contains($0) })
      {
        errors.append("authorization resource plan protects a node outside its delivery target")
      } else if let protects = entry["protects"] as? [String],
        protects.contains(where: {
          workflowNodes[$0]?["lease_action"] != nil
            || workflowNodes[$0]?["terminal"] as? Bool == true
        })
      {
        errors.append(
          "authorization resource plan may protect work nodes, not lease or terminal nodes")
      }
      if let descriptor = entry["resource_descriptor"] as? [String: Any],
        let normalized = try? ResourceCoordinator.normalizeDescriptor(
          resource: resource, descriptor: descriptor),
        let digest = try? ResourceCoordinator.descriptorSHA256(
          resource: resource, descriptor: normalized),
        let canonicalKey = try? ResourceCoordinator.canonicalResourceKey(
          resource: resource, descriptor: normalized),
        same(descriptor, normalized), entry["descriptor_sha256"] as? String == digest,
        key == canonicalKey
      {
      } else {
        errors.append("authorization resource plan descriptor binding is invalid")
      }
    }
    if envelope["health_profile"] as? String == "runtime_ui" {
      let verificationNodes: Set<String> = ["verify", "reverify", "prepare_evidence"]
      func protectsVerification(_ entry: [String: Any]) -> Bool {
        !Set(entry["protects"] as? [String] ?? []).isDisjoint(with: verificationNodes)
      }
      if !plan.contains(where: {
        $0["resource"] as? String == "build_tuple" && protectsVerification($0)
      }) {
        errors.append(
          "runtime_ui authorization requires a build_tuple resource plan protecting runtime verification"
        )
      }
      if !plan.contains(where: {
        ["simulator_or_device", "macos_gui_session"].contains($0["resource"] as? String ?? "")
          && protectsVerification($0)
      }) {
        errors.append(
          "runtime_ui authorization requires a device or macOS GUI resource plan protecting runtime verification"
        )
      }
    }
    return errors
  }
}
