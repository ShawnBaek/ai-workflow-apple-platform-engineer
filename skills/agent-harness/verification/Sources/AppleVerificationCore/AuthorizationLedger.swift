import Foundation

extension Authorization {
  public static func loadLedger(_ path: URL) throws -> [[String: Any]] {
    try ledgerRecords(Data(contentsOf: path))
  }

  static func ledgerRecords(_ data: Data) throws -> [[String: Any]] {
    var records: [[String: Any]] = []
    for line in try ledgerLines(data) {
      guard let record = try JSONSerialization.jsonObject(with: line.bytes) as? [String: Any] else {
        throw VerificationError.invalid("invalid ledger JSON object on line \(line.number)")
      }
      records.append(record)
    }
    return records
  }

  /// The runtime's checkpoint of the ledger bytes it last appended to, kept beside the ledger in
  /// the private run root. The coordinator binds only the ledger's path, inode and first record,
  /// and an in-place truncation or rewrite keeps all three, so every later reservation and
  /// dispatch requires the ledger to still begin with these bytes.
  static func ledgerHeadURL(_ ledgerPath: URL) -> URL {
    ledgerPath.deletingLastPathComponent().appendingPathComponent(
      ledgerPath.lastPathComponent + ".head.json")
  }

  /// `initialize-run` records the head with the approval record, so a missing head means it was
  /// removed and always fails closed.
  static func ledgerHeadErrors(
    _ ledgerData: Data, ledgerPath: URL, runRoot: URL, binding: [String: Any]
  ) -> [String] {
    let head = ledgerHeadURL(ledgerPath)
    var info = stat()
    guard lstat(head.path, &info) == 0 else {
      return ["coordination_required: ledger head checkpoint is missing or unreadable"]
    }
    guard let document = try? loadStablePrivateJSON(head, root: runRoot) as? [String: Any],
      Set(document.keys) == [
        "schema_version", "ledger_identity_sha256", "ledger_approval_sha256", "byte_count",
        "prefix_sha256",
      ], document["schema_version"] as? String == "1.0.0",
      same(document["ledger_identity_sha256"], binding["ledger_identity_sha256"]),
      same(document["ledger_approval_sha256"], binding["ledger_approval_sha256"]),
      let count = jsonInt(document["byte_count"]), count > 0
    else {
      return ["coordination_required: ledger head checkpoint is invalid or not this ledger's"]
    }
    guard count <= ledgerData.count,
      document["prefix_sha256"] as? String == "sha256:"
        + HarnessRuntime.sha256(ledgerData.prefix(count))
    else {
      return ["coordination_required: ledger was truncated or rewritten below its recorded head"]
    }
    return []
  }

  /// Records the current ledger bytes as its head when they still begin with `prefix`. Runtime
  /// writers call it before and after each append, so a failure after the append leaves the
  /// previous head, which the appended ledger still satisfies.
  static func advanceLedgerHead(
    ledgerPath: URL, runRoot: URL, binding: [String: Any], prefix: Data
  ) throws {
    let current = try Data(contentsOf: ledgerPath)
    guard current.starts(with: prefix) else {
      throw VerificationError.invalid("ledger changed below the runtime's append")
    }
    try writeLedgerHead(current, ledgerPath: ledgerPath, runRoot: runRoot, binding: binding)
  }

  /// Writes the head for `ledgerData`. `initialize-run` calls it before it publishes the ledger,
  /// so no published ledger is ever without its head.
  static func writeLedgerHead(
    _ ledgerData: Data, ledgerPath: URL, runRoot: URL, binding: [String: Any]
  ) throws {
    let head = ledgerHeadURL(ledgerPath)
    guard
      head.deletingLastPathComponent().resolvingSymlinksInPath()
        == runRoot.resolvingSymlinksInPath()
    else { throw VerificationError.invalid("ledger head must be directly under the run root") }
    try HarnessRuntime.atomicWriteJSON(
      [
        "schema_version": "1.0.0",
        "ledger_identity_sha256": binding["ledger_identity_sha256"] ?? NSNull(),
        "ledger_approval_sha256": binding["ledger_approval_sha256"] ?? NSNull(),
        "byte_count": ledgerData.count,
        "prefix_sha256": "sha256:" + HarnessRuntime.sha256(ledgerData),
      ], to: head)
  }

  /// A JSONL record ends at a 0x0A byte and nowhere else. U+2028, U+2029 and U+0085 are legal
  /// raw inside a JSON string, and every appender and the ledger binding delimit by 0x0A alone.
  static func ledgerLines(_ data: Data) throws -> [(number: Int, bytes: Data)] {
    guard String(data: data, encoding: .utf8) != nil else {
      throw VerificationError.invalid("ledger is not UTF-8")
    }
    return data.split(separator: 0x0a, omittingEmptySubsequences: false).enumerated()
      .compactMap { offset, line in
        line.allSatisfy { [0x20, 0x09, 0x0d].contains($0) } ? nil : (offset + 1, Data(line))
      }
  }

  /// The instant a runtime writer judges authority at and stamps its record with: the current
  /// clock, but never earlier than the latest record, so the append-only ledger stays monotonic
  /// even after a writer whose clock runs ahead.
  static func ledgerClock(_ records: [[String: Any]], now: Date) -> Date {
    records.compactMap { try? HarnessRuntime.parseTimestamp(text($0["recorded_at"])) }
      .reduce(now, max)
  }

  public static func ledgerContractErrors(
    _ records: [[String: Any]], coordinatorState: URL? = nil, context: RuntimeContext
  ) -> [String] {
    let candidates = [
      context.harnessRoot.appendingPathComponent("contracts/schemas/ledger-record.schema.json"),
      context.harnessRoot.appendingPathComponent(
        "skills/agent-harness/contracts/schemas/ledger-record.schema.json"),
    ]
    guard
      let schemaURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let schema = try? HarnessRuntime.object(schemaURL)
    else {
      return ["installed ledger schema is unavailable; refusing authorization"]
    }
    var errors: [String] = []
    for (index, record) in records.enumerated() {
      errors += schemaErrors(instance: record, schema: schema).map {
        "ledger schema line \(index + 1): \($0)"
      }
    }
    if !errors.isEmpty { return Array(Set(errors)).sorted() }
    return standaloneLedgerLifecycleErrors(
      records, coordinatorState: coordinatorState, context: context)
  }

  /// What `standaloneLedgerLifecycleErrors` has established so far while it replays one run's
  /// ledger in order: its approved authorizations, lease, reservation and dispatch state, passed
  /// workflow nodes and evidence, and every error found. Each record handler reads and advances
  /// it exactly as the single replay loop did.
  struct LedgerReplayState {
    let workflow:
      (
        main: [String], continuation: [String], nodes: [String: [String: Any]],
        patchBound: Set<String>
      )
    var errors: [String] = []
    var authorizations: [String: [String: Any]] = [:]
    var active: [String: [String: Any]] = [:]
    var reservations: [String: [String: Any]] = [:]
    var dispatches: [String: [String: Any]] = [:]
    var claimed = Set<String>()
    var consumedReservations = Set<String>()
    var consumedDispatches = Set<String>()
    var usedGrants = Set<String>()
    var usedKeys = Set<String>()
    var producedTargets: [String: String] = [:]
    var passedNodes = Set<String>()
    var terminallyFailedNodes = Set<String>()
    var successfulOperations = Set<String>()
    var evidenceIDs = Set<String>()
    var resourcePlans: [String: [String: Any]] = [:]
    var planBindings: [String: String] = [:]
    var releasedPlans = Set<String>()
    var passingEvidence: [[String: Any]] = []
    var releasedLeases: [String: [String: Any]] = [:]
    var workflowLeaseBindings: [String: [String: Any]] = [:]
    var releaseToAcquire: [String: String] = [:]
    var protectedBy: [String: [String]] = [:]
    var feedbackIDs = Set<String>()
    var staticLeaseSignatures = Set<String>()
    var stopped = false
  }

  public static func standaloneLedgerLifecycleErrors(
    _ records: [[String: Any]], coordinatorState: URL? = nil, context: RuntimeContext
  ) -> [String] {
    var previousSequence = 0
    var previousDate: Date?
    var runID: String?
    let ledgerDelivery = records.lazy.compactMap { record -> String? in
      guard record["record_type"] as? String == "approval",
        let payload = record["payload"] as? [String: Any],
        payload["kind"] as? String == "run_authorization"
      else { return nil }
      return payload["delivery_target"] as? String
    }.first
    var state = LedgerReplayState(
      workflow: loadWorkflow(context, deliveryTarget: ledgerDelivery))
    if state.workflow.nodes.isEmpty {
      state.errors.append("installed workflow contracts are unavailable; refusing authorization")
    }
    var pendingAcquires: [String: [String]] = [:]
    for nodeID in state.workflow.main + state.workflow.continuation {
      guard let node = state.workflow.nodes[nodeID] else {
        state.errors.append("installed workflow node lookup is incomplete")
        continue
      }
      guard let action = node["lease_action"] as? String else { continue }
      guard ["acquire", "release"].contains(action), let resource = node["resource"] as? String,
        let protects = node["protects"] as? [String], !protects.isEmpty
      else {
        state.errors.append("installed workflow lease contract is invalid")
        continue
      }
      let signature = resource + "\0" + protects.joined(separator: "\0")
      if action == "acquire" {
        pendingAcquires[signature, default: []].append(nodeID)
        state.staticLeaseSignatures.insert(signature)
        for protected in protects { state.protectedBy[protected, default: []].append(nodeID) }
      } else if var candidates = pendingAcquires[signature], !candidates.isEmpty {
        state.releaseToAcquire[nodeID] = candidates.removeFirst()
        pendingAcquires[signature] = candidates
      } else {
        state.errors.append("installed workflow lease pair is unbalanced")
      }
    }
    if pendingAcquires.values.contains(where: { !$0.isEmpty }) {
      state.errors.append("installed workflow lease pair is unbalanced")
    }
    for (index, record) in records.enumerated() {
      let line = index + 1
      let currentRun = record["run_id"] as? String
      if runID == nil {
        runID = currentRun
      } else if currentRun != runID {
        state.errors.append("ledger cannot mix run IDs")
      }
      guard
        Set(record.keys) == [
          "schema_version", "run_id", "sequence", "recorded_at", "record_type", "payload",
        ], record["schema_version"] as? String == "1.0.0",
        let payload = record["payload"] as? [String: Any]
      else {
        state.errors.append("ledger record fields are invalid at line \(line)")
        continue
      }
      guard let sequence = jsonInt(record["sequence"]), sequence > previousSequence else {
        state.errors.append("ledger sequence must strictly increase at line \(line)")
        continue
      }
      // Each record is one above the last, from 1, so a removed record leaves a visible gap.
      if sequence != previousSequence + 1 {
        state.errors.append("ledger sequence skips a record before line \(line)")
      }
      previousSequence = sequence
      let recorded = try? HarnessRuntime.parseTimestamp(text(record["recorded_at"]))
      if let recorded, let previousDate, recorded < previousDate {
        state.errors.append("ledger recorded_at must be monotonic at line \(line)")
      }
      if recorded == nil { state.errors.append("ledger recorded_at is invalid at line \(line)") }
      previousDate = recorded ?? previousDate
      let recordType = record["record_type"] as? String
      // A terminal stop ends the run's authority: nothing after it may take or extend a lease,
      // reserve, claim, or perform an external write. Lease releases and audit records may follow.
      if state.stopped,
        ["grant_reservation", "grant_dispatch", "external_write"].contains(recordType)
          || (recordType == "lease" && payload["action"] as? String != "release")
      {
        state.errors.append("ledger grants authority at line \(line) after its terminal stop")
      }
      switch recordType {
      case "approval" where payload["kind"] as? String == "run_authorization":
        recordRunAuthorization(payload, context: context, into: &state)
      case "time_interval":
        if state.authorizations[text(payload["authorization_hash"])] == nil {
          state.errors.append("time interval must follow its run authorization")
        }
        if let start = try? HarnessRuntime.parseTimestamp(text(payload["started_at"])),
          let end = try? HarnessRuntime.parseTimestamp(text(payload["ended_at"])), end > start
        {
        } else {
          state.errors.append("time interval must have positive duration")
        }
      case "evidence":
        recordEvidence(payload, recorded: recorded, into: &state)
      case "lease":
        recordLease(
          payload, currentRun: currentRun, recorded: recorded,
          coordinatorState: coordinatorState, into: &state)
      case "grant_reservation":
        recordGrantReservation(payload, recorded: recorded, into: &state)
      case "grant_dispatch":
        recordGrantDispatch(payload, recorded: recorded, into: &state)
      case "external_write":
        recordExternalWrite(payload, recorded: recorded, into: &state)
      case "node" where payload["status"] as? String == "passed":
        recordPassedNode(payload, recorded: recorded, into: &state)
      case "node":
        // Non-passed states record progress only; every gate in recordPassedNode reads passedNodes.
        let node = text(payload["node_id"])
        let status = text(payload["status"])
        if state.workflow.nodes[node] == nil {
          state.errors.append("node record is not present in the installed workflow contracts")
        }
        if ![
          "pending", "ready", "leased", "acting", "verifying", "failed_retryable",
          "failed_terminal", "awaiting_approval", "blocked", "skipped", "superseded",
        ].contains(status) {
          state.errors.append("workflow node status is unsupported at line \(line)")
        } else if status == "failed_terminal" {
          state.terminallyFailedNodes.insert(node)
        }
      case "stop":
        if !state.active.isEmpty {
          state.errors.append("terminal stop cannot leave an active lease")
        }
        state.stopped = true
      case "knowledge":
        if Set(payload.keys) != ["source_id", "authority", "content_hash", "provenance"]
          || payload.values.contains(where: { text($0).isEmpty })
        {
          state.errors.append("knowledge record must bind exact non-empty provenance")
        }
      case "feedback":
        let required: Set<String> = [
          "feedback_id", "actor", "scope", "target", "summary", "disposition",
        ]
        let allowed = required.union(["invalidates"])
        let id = text(payload["feedback_id"])
        if !required.isSubset(of: Set(payload.keys)) || !Set(payload.keys).isSubset(of: allowed)
          || required.contains(where: { text(payload[$0]).isEmpty })
          || !["current_run", "project_candidate", "repository_candidate"].contains(
            text(payload["scope"]))
          || !["accepted", "rejected", "needs_clarification"].contains(text(payload["disposition"]))
          || id.isEmpty || !state.feedbackIDs.insert(id).inserted
        {
          state.errors.append("feedback record must bind one unique valid disposition")
        }
        if let invalidates = payload["invalidates"], !(invalidates is NSNull),
          !uniqueStringArrayAllowEmpty(invalidates)
        {
          state.errors.append("feedback invalidates must be unique strings")
        }
      case "improvement":
        // A candidate is a reviewed proposal; recording it grants no run authority.
        let required: Set<String> = [
          "candidate_id", "derived_from_feedback_ids", "scope", "proposal_hash", "status",
          "validation_evidence_ids",
        ]
        var strings = ["candidate_id", "proposal_hash"]
        if payload["rollback_ref"] != nil { strings.append("rollback_ref") }
        if !required.isSubset(of: Set(payload.keys))
          || !Set(payload.keys).isSubset(of: required.union(["rollback_ref"]))
          || strings.contains(where: { (payload[$0] as? String)?.isEmpty != false })
          || !uniqueStrings(payload["derived_from_feedback_ids"])
          || !uniqueStringArrayAllowEmpty(payload["validation_evidence_ids"])
          || !["private_project_overlay", "ios_experts_repository"].contains(text(payload["scope"]))
          || !["proposed", "approved", "rejected", "applied", "rolled_back"].contains(
            text(payload["status"]))
        {
          state.errors.append("improvement record must bind one sourced candidate and valid status")
        }
      case "attempt", "approval": break
      default: state.errors.append("ledger record type is unsupported at line \(line)")
      }
    }
    return Array(Set(state.errors)).sorted()
  }

  private static func recordRunAuthorization(
    _ payload: [String: Any], context: RuntimeContext, into state: inout LedgerReplayState
  ) {
    let digest = text(payload["authorization_hash"])
    if payload["decision"] as? String != "approved" || digest.isEmpty
      || state.authorizations[digest] != nil
    {
      state.errors.append("run authorization approval must be unique and approved")
    } else {
      state.authorizations[digest] = payload
      if !["codex", "claude"].contains(payload["selected_writer"] as? String ?? "") {
        state.errors.append("run authorization approval has an invalid selected writer")
      }
      if !hash(payload["repository_fingerprint"]) || !sha(payload["repository_base_sha"]) {
        state.errors.append(
          "run authorization approval must bind repository fingerprint and base SHA")
      }
      if !uniqueStrings(payload["allowed_paths"]) || !uniqueStrings(payload["acceptance_ids"]) {
        state.errors.append("run authorization approval must bind allowed paths and acceptance IDs")
      }
      if let schema = installedAuthorizationSchema(context),
        payload["contract_schema_id"] as? String == schema.id,
        payload["contract_schema_sha256"] as? String == schema.digest
      {
      } else {
        state.errors.append("run authorization approval schema binding drifted")
      }
      guard let plans = payload["resource_plan"] as? [[String: Any]] else {
        state.errors.append("run authorization approval must bind its resource plan")
        return
      }
      for plan in plans {
        let id = text(plan["plan_id"])
        let identity = text(plan["resource"]) + "\0" + text(plan["resource_key"])
        if id.isEmpty || state.resourcePlans[id] != nil
          || state.resourcePlans.values.contains(where: {
            text($0["resource"]) + "\0" + text($0["resource_key"]) == identity
          })
        {
          state.errors.append("run authorization resource plan IDs and identities must be unique")
        } else {
          state.resourcePlans[id] = plan
        }
      }
    }
  }

  private static func installedAuthorizationSchema(_ context: RuntimeContext) -> (
    id: String, digest: String
  )? {
    for path in [
      "contracts/schemas/run-authorization.schema.json",
      "skills/agent-harness/contracts/schemas/run-authorization.schema.json",
    ] {
      let url = context.harnessRoot.appendingPathComponent(path)
      if let object = try? HarnessRuntime.object(url), let id = object["$id"] as? String,
        let digest = try? HarnessRuntime.sha256File(url)
      {
        return (id, "sha256:" + digest)
      }
    }
    return nil
  }

  private static func uniqueStringArrayAllowEmpty(_ value: Any?) -> Bool {
    guard let values = value as? [String] else { return false }
    return Set(values).count == values.count && values.allSatisfy { !$0.isEmpty }
  }

  private static func loadWorkflow(_ context: RuntimeContext, deliveryTarget: String?) -> (
    main: [String], continuation: [String], nodes: [String: [String: Any]], patchBound: Set<String>
  ) {
    func load(_ name: String) -> [[String: Any]] {
      for relative in ["contracts/\(name)", "skills/agent-harness/contracts/\(name)"] {
        if let object = try? HarnessRuntime.object(
          context.harnessRoot.appendingPathComponent(relative)),
          let nodes = object["nodes"] as? [[String: Any]]
        {
          return nodes
        }
      }
      return []
    }
    let mainNodes =
      deliveryTarget == "local_verified" ? load("local-workflow.json") : load("workflow.json")
    let continuationNodes =
      deliveryTarget == "local_verified" ? [] : load("testflight-workflow.json")
    let all = mainNodes + continuationNodes
    let patchBound: Set<String> =
      deliveryTarget == "local_verified"
      ? ["verify", "local_verified"]
      : [
        "verify", "freeze_review", "review", "converge", "reverify", "prepare_evidence",
        "prepare_pr", "repository_confirmation", "commit", "push", "verify_remote_sha", "create_pr",
        "publish_evidence", "verify_published_evidence", "checks", "pr_ready",
      ]
    var byID: [String: [String: Any]] = [:]
    for node in all {
      guard let id = node["id"] as? String, !id.isEmpty, byID[id] == nil else { continue }
      byID[id] = node
    }
    return (
      mainNodes.compactMap { $0["id"] as? String },
      continuationNodes.compactMap { $0["id"] as? String }, byID, patchBound
    )
  }
}
