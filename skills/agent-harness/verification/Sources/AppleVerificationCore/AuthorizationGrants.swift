import Foundation

extension Authorization {
  private static let operationAllowlist: [String: Set<String>] = [
    "git.commit": ["commit_reviewed_patch"], "git.push": ["push_reviewed_commit"],
    "github.issue.create": ["ensure_feature_issue"],
    "github.issue.update": [
      "transition_issue_ready", "transition_issue_in_progress", "transition_issue_in_review",
    ],
    "github.issue.comment": ["publish_exact_issue_comment"],
    "github.project.update": [
      "transition_project_ready", "transition_project_in_progress", "transition_project_in_review",
    ],
    "github.pr.create": ["create_pull_request"], "github.pr.update": ["update_exact_pull_request"],
    "github.pr.comment": ["publish_exact_pr_comment"],
    "github.evidence.publish": [
      "publish_pr_evidence", "publish_testflight_upload_evidence",
      "publish_testflight_distribution_evidence",
    ],
    "github.checks.wait": ["wait_required_checks"],
    "apple.testflight.upload": ["upload_verified_archive"],
    "apple.testflight.processing.wait": ["wait_bounded_processing"],
    "apple.testflight.distribute_internal": ["distribute_named_internal_group"],
    "apple.testflight.readback": ["verify_uploaded_build", "verify_internal_distribution"],
  ]

  static func validateGrants(_ envelope: [String: Any], grants: [[String: Any]]) -> [String] {
    var errors: [String] = []
    var ids = Set<String>()
    var keys = Set<String>()
    for grant in grants {
      let required: Set<String> = [
        "grant_id", "system", "action", "operation", "operation_input", "constraint_sha256",
        "resource_key", "phase", "single_use", "idempotency_key",
      ]
      let allowed = required.union(["target", "target_from_grant_id", "produces_target_kind"])
      errors += objectShape(grant, required: required, allowed: allowed, label: "action grant")
      let id = text(grant["grant_id"])
      let key = text(grant["idempotency_key"])
      let action = text(grant["action"])
      let operation = text(grant["operation"])
      let direct = !(grant["target"] is NSNull) && !text(grant["target"]).isEmpty
      let derived = !text(grant["target_from_grant_id"]).isEmpty
      if direct == derived {
        errors.append("action grant must bind one direct or derived target: \(id)")
      }
      if !allowedActions.contains(action) || forbiddenActions.contains(action) {
        errors.append("action grant is not allowlisted: \(action)")
      }
      if !operationAllowlist[action, default: []].contains(operation) {
        errors.append("action grant operation is not allowlisted for \(action): \(operation)")
      }
      if let input = grant["operation_input"] as? [String: Any], !input.isEmpty {
        if (try? canonicalSHA256(input)) != grant["constraint_sha256"] as? String {
          errors.append("action grant operation input does not match its constraint: \(id)")
        }
        errors += operationInputErrors(envelope, action: action, operation: operation, input: input)
          .map { "action grant \(id): \($0)" }
      } else {
        errors.append("action grant operation input is invalid: \(id)")
      }
      if !regex(grant["constraint_sha256"], #"^[0-9a-f]{64}$"#) {
        errors.append("action grant constraint digest is invalid: \(id)")
      }
      if (try? canonicalLeaseResourceKey(envelope, action: action)) != grant["resource_key"]
        as? String
      {
        errors.append("action grant resource key is not canonical: \(id)")
      }
      if !["git", "github", "apple"].contains(text(grant["system"]))
        || text(grant["system"]) != action.split(separator: ".").first.map(String.init)
      {
        errors.append("action grant system does not match action: \(id)")
      }
      if grant["single_use"] as? Bool != true {
        errors.append("action grant must be single use: \(id)")
      }
      let producedKind = text(grant["produces_target_kind"])
      if !producedKind.isEmpty && !["github.issue.create", "github.pr.create"].contains(action) {
        errors.append("only a GitHub create grant may produce a target: \(id)")
      }
      let phase = text(grant["phase"])
      let local = envelope["delivery_target"] as? String == "local_verified"
      if !["local_delivery", "pr_delivery", "testflight_upload", "testflight_distribution"]
        .contains(phase)
      {
        errors.append("action grant phase is invalid: \(id)")
      }
      if local && action == "git.commit" && phase != "local_delivery" {
        errors.append("local commit action must use the local_delivery phase: \(id)")
      }
      if !local && ["git", "github"].contains(text(grant["system"]))
        && action != "github.evidence.publish" && phase != "pr_delivery"
      {
        errors.append("repository delivery action must use the pr_delivery phase: \(id)")
      }
      if action.hasPrefix("apple.") {
        let expectedPhase =
          action == "apple.testflight.distribute_internal"
            || (action == "apple.testflight.readback"
              && text(grant["target"]).contains(":group:"))
          ? "testflight_distribution" : "testflight_upload"
        if phase != expectedPhase {
          errors.append("Apple action is bound to the wrong continuation phase: \(id)")
        }
      }
      if id.isEmpty || !ids.insert(id).inserted {
        errors.append("action grant IDs must be non-empty and unique: \(id)")
      }
      if key.isEmpty || !keys.insert(key).inserted {
        errors.append("idempotency keys must be non-empty and unique: \(key)")
      }
    }
    var byID: [String: [String: Any]] = [:]
    for grant in grants {
      let id = text(grant["grant_id"])
      if byID[id] == nil { byID[id] = grant }
    }
    for grant in grants {
      let sourceID = text(grant["target_from_grant_id"])
      guard !sourceID.isEmpty else { continue }
      if sourceID == text(grant["grant_id"]) {
        errors.append("action grant cannot derive its own target: \(text(grant["grant_id"]))")
      }
      if byID[sourceID].map({ text($0["produces_target_kind"]) }).map({ !$0.isEmpty }) != true {
        errors.append("derived target has no producing grant: \(text(grant["grant_id"]))")
      }
    }
    errors += repositoryGrantErrors(envelope, grants: grants)
    errors += greenPathGrantErrors(envelope, grants: grants)
    errors += appleGrantErrors(envelope, grants: grants)
    return errors
  }

  private static func operationInputErrors(
    _ envelope: [String: Any], action: String, operation: String, input: [String: Any]
  ) -> [String] {
    let repository = envelope["repository"] as? [String: Any] ?? [:]
    let limits = envelope["limits"] as? [String: Any] ?? [:]
    let apple = envelope["apple"] as? [String: Any] ?? [:]
    var valid = false
    var message = "operation input semantics are unavailable: \(operation)"
    let state: [String: String] = [
      "transition_issue_ready": "Ready", "transition_issue_in_progress": "In Progress",
      "transition_issue_in_review": "In Review",
    ]
    if let expected = state[operation] {
      valid = same(input, ["state": expected])
      message = "Issue transition descriptor drifted: \(operation)"
    } else if operation.hasPrefix("transition_project_") {
      let expected =
        operation.hasSuffix("ready")
        ? "Ready" : operation.hasSuffix("progress") ? "In Progress" : "In Review"
      valid =
        Set(input.keys) == ["state", "field_id", "option_id"]
        && input["state"] as? String == expected && !text(input["field_id"]).isEmpty
        && !text(input["option_id"]).isEmpty
      message = "Project transition descriptor has unsupported fields or drifted: \(operation)"
    } else if operation == "commit_reviewed_patch" {
      let paths = input["paths"] as? [String] ?? []
      valid =
        Set(input.keys) == ["message_policy", "paths"]
        && input["message_policy"] as? String == "reviewed_patch" && uniqueStrings(paths)
        && paths.allSatisfy { pathAllowed($0, envelope["allowed_paths"] as? [String] ?? []) }
      message = "commit descriptor must bind reviewed_patch and exact authorized paths"
    } else if operation == "push_reviewed_commit" {
      valid = same(input, ["branch": repository["branch"] ?? NSNull(), "force": false])
      message = "push descriptor must bind the authorized branch with force false"
    } else if operation == "ensure_feature_issue" {
      valid = same(input, ["title_policy": "accepted_plan", "body_policy": "accepted_plan"])
      message = "feature Issue descriptor must use the accepted-plan policy"
    } else if operation == "create_pull_request" {
      valid =
        Set(input.keys) == ["base_ref", "head", "body_policy", "draft"]
        && safeRef(input["base_ref"]) && input["head"] as? String == repository["branch"] as? String
        && input["base_ref"] as? String != input["head"] as? String
        && input["body_policy"] as? String == "evidence_backed_current_run"
        && input["draft"] as? Bool == false
      message =
        "pull-request descriptor must bind a safe base, authorized head, evidence body, and draft false"
    } else if ["publish_exact_issue_comment", "publish_exact_pr_comment"].contains(operation) {
      valid = Set(input.keys) == ["body_sha256"] && regex(input["body_sha256"], #"^[0-9a-f]{64}$"#)
      message = "exact comment descriptor must bind body_sha256: \(operation)"
    } else if operation == "update_exact_pull_request" {
      valid =
        Set(input.keys) == ["title_sha256", "body_sha256"]
        && regex(input["title_sha256"], #"^[0-9a-f]{64}$"#)
        && regex(input["body_sha256"], #"^[0-9a-f]{64}$"#)
      message = "exact pull-request update must bind title and body SHA-256"
    } else if operation.hasPrefix("publish_") && operation.hasSuffix("_evidence") {
      let expected =
        operation == "publish_pr_evidence"
        ? "sanitized_pr_evidence"
        : operation == "publish_testflight_upload_evidence"
          ? "sanitized_testflight_upload_evidence" : "sanitized_testflight_distribution_evidence"
      valid = same(input, ["artifact_policy": expected])
      message = "evidence publication descriptor drifted: \(operation)"
    } else if operation == "wait_required_checks" {
      valid = same(
        input,
        ["policy": "all_required", "timeout_minutes": limits["async_wait_minutes"] ?? NSNull()])
      message = "required-check wait must use all_required and the authorized async bound"
    } else if operation == "upload_verified_archive" {
      valid = same(input, ["artifact_policy": "fresh_archive_from_reviewed_pr_commit"])
      message = "TestFlight upload descriptor drifted"
    } else if operation == "wait_bounded_processing" {
      valid = same(
        input,
        [
          "timeout_minutes": limits["async_wait_minutes"] ?? NSNull(),
          "max_transient_retries": limits["max_transient_retries"] ?? NSNull(),
        ])
      message = "processing wait descriptor exceeds or drifts from authorization bounds"
    } else if operation == "verify_uploaded_build" {
      valid = same(input, ["readback": "uploaded_build"])
      message = "upload read-back descriptor drifted"
    } else if operation == "distribute_named_internal_group" {
      valid =
        Set(input.keys) == ["group_id"]
        && (apple["internal_group_ids"] as? [String] ?? []).contains(text(input["group_id"]))
      message = "distribution descriptor is outside the named internal group"
    } else if operation == "verify_internal_distribution" {
      valid =
        Set(input.keys) == ["readback", "group_id"]
        && input["readback"] as? String == "internal_group_build"
        && (apple["internal_group_ids"] as? [String] ?? []).contains(text(input["group_id"]))
      message = "distribution read-back descriptor drifted"
    }
    var errors = valid ? [] : [message]
    if !operationAllowlist[action, default: []].contains(operation) {
      errors.append("operation is not allowed for action \(action): \(operation)")
    }
    return errors
  }

  private static func repositoryGrantErrors(_ envelope: [String: Any], grants: [[String: Any]])
    -> [String]
  {
    var errors: [String] = []
    let repository = envelope["repository"] as? [String: Any] ?? [:]
    let github = envelope["github"] as? [String: Any] ?? [:]
    if envelope["delivery_target"] as? String == "local_verified" {
      for grant in grants {
        let action = text(grant["action"])
        if action != "git.commit" {
          errors.append("local verification cannot authorize remote or Apple actions: \(action)")
        }
        if action == "git.commit",
          text(grant["target"])
            != "\(text(repository["fingerprint"])):\(text(repository["branch"]))"
        {
          errors.append("grant target does not match the bound repository: git.commit")
        }
      }
      return errors
    }
    let slug = boundGitHubSlug(envelope) ?? "<invalid-repository>"
    let branch = text(repository["branch"])
    let fingerprint = text(repository["fingerprint"])
    if (try? normalizeGitHubRemote(text(repository["remote"])).replacingOccurrences(
      of: "github.com/", with: "")) != slug
    {
      errors.append("repository remote does not match the bound GitHub owner/repository")
    }
    let canonical = [
      "git.commit": "\(fingerprint):\(branch)", "git.push": "\(slug):\(branch)",
      "github.pr.create": "\(slug):\(branch)", "github.issue.create": "\(slug):feature:\(branch)",
    ]
    var byID: [String: [String: Any]] = [:]
    for grant in grants {
      let id = text(grant["grant_id"])
      if byID[id] == nil { byID[id] = grant }
    }
    for grant in grants {
      let action = text(grant["action"])
      let target = text(grant["target"])
      if let expected = canonical[action], target != expected {
        errors.append("grant target does not match the bound repository: \(action)")
      }
      if action == "github.issue.create", grant["produces_target_kind"] as? String != "github_issue"
      {
        errors.append("Issue create grant must declare a GitHub Issue output")
      }
      if action == "github.pr.create", grant["produces_target_kind"] as? String != "github_pr" {
        errors.append("PR create grant must declare a GitHub PR output")
      }
      let consumers = [
        "github.issue.update": "github_issue", "github.issue.comment": "github_issue",
        "github.pr.update": "github_pr", "github.pr.comment": "github_pr",
        "github.evidence.publish": "github_pr", "github.checks.wait": "github_pr",
      ]
      if let kind = consumers[action], let sourceID = grant["target_from_grant_id"] as? String,
        (byID[sourceID]?["produces_target_kind"] as? String) != kind
      {
        errors.append("derived GitHub target has the wrong object kind: \(action)")
      } else if let kind = consumers[action], grant["target_from_grant_id"] == nil {
        if kind == "github_issue" {
          // The bound Issue is the only direct target. A new feature Issue has no number until
          // its create grant succeeds, so its consumers must derive their target from that grant.
          if jsonInt(github["issue_number"]).map({ target != "\(slug):issue:\($0)" }) ?? true {
            errors.append(
              "Issue grant must bind a known exact Issue or a derived target: \(action)")
          }
        } else if target.range(
          of: "^" + NSRegularExpression.escapedPattern(for: slug) + #":pr:[1-9][0-9]*$"#,
          options: .regularExpression) == nil
        {
          errors.append("PR grant must bind an exact PR in the authorized repository: \(action)")
        }
      }
      if action == "github.project.update" {
        if let projectID = (github["project"] as? [String: Any])?["id"] as? String,
          target == "\(slug):project:\(projectID)",
          grant["target_from_grant_id"] == nil || grant["target_from_grant_id"] is NSNull
        {
        } else {
          errors.append("Project grant must bind the exact configured Project")
        }
      }
    }
    return errors
  }

  private static func greenPathGrantErrors(_ envelope: [String: Any], grants: [[String: Any]])
    -> [String]
  {
    var errors: [String] = []
    let counts = Dictionary(grouping: grants, by: { text($0["action"]) }).mapValues(\.count)
    if envelope["delivery_target"] as? String == "local_verified" {
      if counts["git.commit", default: 0] > 1 {
        errors.append("local verification permits at most one explicit git.commit grant")
      }
      if grants.contains(where: { $0["action"] as? String != "git.commit" }) {
        errors.append("local verification action grants must remain local")
      }
      return errors
    }
    for action in ["git.commit", "git.push", "github.pr.create", "github.checks.wait"]
    where counts[action] != 1 {
      errors.append("delivery authorization requires exactly one \(action) grant")
    }
    if let pr = grants.first(where: { $0["action"] as? String == "github.pr.create" }) {
      for grant in grants
      where [
        "github.pr.update", "github.pr.comment", "github.evidence.publish", "github.checks.wait",
      ].contains(text(grant["action"]))
        && grant["target_from_grant_id"] as? String != pr["grant_id"] as? String
      {
        errors.append(
          "PR consumer grant must derive the PR created by this run: \(text(grant["grant_id"]))")
      }
    }
    let delivery = envelope["delivery_target"] as? String
    let expectedEvidence = delivery == "pr_ready" ? 1 : delivery == "testflight_uploaded" ? 2 : 3
    if counts["github.evidence.publish"] != expectedEvidence {
      errors.append("delivery authorization has the wrong evidence-publication grant count")
    }
    let observedEvidence = Set(
      grants.filter { $0["action"] as? String == "github.evidence.publish" }.map {
        "\(text($0["operation"]))|\(text($0["phase"]))"
      })
    var expectedOperations: Set<String> = ["publish_pr_evidence|pr_delivery"]
    if delivery == "testflight_uploaded" || delivery == "testflight_distributed" {
      expectedOperations.insert("publish_testflight_upload_evidence|testflight_upload")
    }
    if delivery == "testflight_distributed" {
      expectedOperations.insert("publish_testflight_distribution_evidence|testflight_distribution")
    }
    if observedEvidence != expectedOperations {
      errors.append("evidence grants must bind the exact delivery phase and publication operation")
    }
    let github = envelope["github"] as? [String: Any] ?? [:]
    let creates = grants.filter { $0["action"] as? String == "github.issue.create" }
    let updates = grants.filter { $0["action"] as? String == "github.issue.update" }
    let expectedIssueOperations: Set<String>
    if github["issue_number"] is NSNull || github["issue_number"] == nil {
      if creates.count != 1 || updates.count != 2 {
        errors.append("a new feature Issue requires one create and two state-update grants")
      }
      if creates.count == 1
        && updates.contains(where: {
          $0["target_from_grant_id"] as? String != creates[0]["grant_id"] as? String
        })
      {
        errors.append("new Issue state grants must derive from the Issue create grant")
      }
      expectedIssueOperations = ["transition_issue_in_progress", "transition_issue_in_review"]
    } else {
      if !creates.isEmpty || updates.count != 3 {
        errors.append("an existing feature Issue requires exactly three state-update grants")
      }
      expectedIssueOperations = [
        "transition_issue_ready", "transition_issue_in_progress", "transition_issue_in_review",
      ]
    }
    if Set(updates.compactMap { $0["operation"] as? String }) != expectedIssueOperations {
      errors.append("Issue update grants must bind the exact authorized state transitions")
    }
    let projectUpdates = grants.filter { $0["action"] as? String == "github.project.update" }
    let project = github["project"]
    let projectSelected = project != nil && !(project is NSNull)
    if projectUpdates.count != (projectSelected ? 3 : 0) {
      errors.append("Project tracking grants do not match the selected Project configuration")
    }
    if projectSelected
      && Set(projectUpdates.compactMap { $0["operation"] as? String }) != [
        "transition_project_ready", "transition_project_in_progress",
        "transition_project_in_review",
      ]
    {
      errors.append(
        "Project grants must bind the exact Ready, In Progress, and In Review transitions")
    }
    return errors
  }

  private static func appleGrantErrors(_ envelope: [String: Any], grants: [[String: Any]])
    -> [String]
  {
    let appleGrants = grants.filter { $0["system"] as? String == "apple" }
    let delivery = envelope["delivery_target"] as? String
    if delivery == "pr_ready" || delivery == "local_verified" {
      return (envelope["apple"] is NSNull || envelope["apple"] == nil) && appleGrants.isEmpty
        ? [] : ["\(delivery ?? "local") authorization cannot bind or grant Apple actions"]
    }
    guard let apple = envelope["apple"] as? [String: Any] else {
      return ["TestFlight authorization must bind the exact Apple target"]
    }
    var errors: [String] = []
    let groups = apple["internal_group_ids"] as? [String] ?? []
    if Set(groups).count != groups.count {
      errors.append("TestFlight internal group IDs must be unique")
    }
    if groups.count > 1 {
      errors.append("authorization schema v1 supports one exact internal group per run")
    }
    if delivery == "testflight_uploaded" && !groups.isEmpty {
      errors.append("upload-only authorization cannot bind distribution groups")
    }
    if delivery == "testflight_distributed" && groups.isEmpty {
      errors.append("internal distribution must name at least one exact group ID")
    }
    var expected = [
      "apple.testflight.upload|app:\(text(apple["app_id"]))",
      "apple.testflight.processing.wait|app:\(text(apple["app_id"])):processing",
      "apple.testflight.readback|app:\(text(apple["app_id"])):upload",
    ]
    if delivery == "testflight_distributed" {
      for group in groups {
        expected += [
          "apple.testflight.distribute_internal|app:\(text(apple["app_id"])):group:\(group)",
          "apple.testflight.readback|app:\(text(apple["app_id"])):group:\(group)",
        ]
      }
    }
    let actual = appleGrants.map { text($0["action"]) + "|" + text($0["target"]) }
    if actual.sorted() != expected.sorted() {
      errors.append("TestFlight grants do not exactly match the selected target and groups")
    }
    if appleGrants.contains(where: { $0["target_from_grant_id"] != nil }) {
      errors.append("Apple grants must bind direct app/build/group targets")
    }
    return errors
  }

  private static func safeRef(_ value: Any?) -> Bool {
    guard let value = value as? String, !value.isEmpty, !value.hasPrefix("/"),
      !value.hasPrefix("-"), !value.hasSuffix("/"), !value.hasSuffix(".lock"),
      !value.contains(".."), !value.contains("@{")
    else { return false }
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
  }
}
