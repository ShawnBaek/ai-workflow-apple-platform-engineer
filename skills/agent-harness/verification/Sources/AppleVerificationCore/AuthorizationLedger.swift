import Foundation

extension Authorization {
  public static func loadLedger(_ path: URL) throws -> [[String: Any]] {
    let text = try String(contentsOf: path, encoding: .utf8)
    var records: [[String: Any]] = []
    for (offset, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty
    {
      guard let data = line.data(using: .utf8),
        let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw VerificationError.invalid("invalid ledger JSON object on line \(offset + 1)")
      }
      records.append(record)
    }
    return records
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

  public static func standaloneLedgerLifecycleErrors(
    _ records: [[String: Any]], coordinatorState: URL? = nil, context: RuntimeContext
  ) -> [String] {
    var errors: [String] = []
    var previousSequence = 0
    var previousDate: Date?
    var runID: String?
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
    let ledgerDelivery = records.lazy.compactMap { record -> String? in
      guard record["record_type"] as? String == "approval",
        let payload = record["payload"] as? [String: Any],
        payload["kind"] as? String == "run_authorization"
      else { return nil }
      return payload["delivery_target"] as? String
    }.first
    let workflow = loadWorkflow(context, deliveryTarget: ledgerDelivery)
    if workflow.nodes.isEmpty {
      errors.append("installed workflow contracts are unavailable; refusing authorization")
    }
    var pendingAcquires: [String: [String]] = [:]
    for nodeID in workflow.main + workflow.continuation {
      guard let node = workflow.nodes[nodeID] else {
        errors.append("installed workflow node lookup is incomplete")
        continue
      }
      guard let action = node["lease_action"] as? String else { continue }
      guard ["acquire", "release"].contains(action), let resource = node["resource"] as? String,
        let protects = node["protects"] as? [String], !protects.isEmpty
      else {
        errors.append("installed workflow lease contract is invalid")
        continue
      }
      let signature = resource + "\0" + protects.joined(separator: "\0")
      if action == "acquire" {
        pendingAcquires[signature, default: []].append(nodeID)
        staticLeaseSignatures.insert(signature)
        for protected in protects { protectedBy[protected, default: []].append(nodeID) }
      } else if var candidates = pendingAcquires[signature], !candidates.isEmpty {
        releaseToAcquire[nodeID] = candidates.removeFirst()
        pendingAcquires[signature] = candidates
      } else {
        errors.append("installed workflow lease pair is unbalanced")
      }
    }
    if pendingAcquires.values.contains(where: { !$0.isEmpty }) {
      errors.append("installed workflow lease pair is unbalanced")
    }
    for (index, record) in records.enumerated() {
      let line = index + 1
      let currentRun = record["run_id"] as? String
      if runID == nil {
        runID = currentRun
      } else if currentRun != runID {
        errors.append("ledger cannot mix run IDs")
      }
      guard
        Set(record.keys) == [
          "schema_version", "run_id", "sequence", "recorded_at", "record_type", "payload",
        ], record["schema_version"] as? String == "1.0.0",
        let payload = record["payload"] as? [String: Any]
      else {
        errors.append("ledger record fields are invalid at line \(line)")
        continue
      }
      guard let sequence = jsonInt(record["sequence"]), sequence > previousSequence else {
        errors.append("ledger sequence must strictly increase at line \(line)")
        continue
      }
      previousSequence = sequence
      let recorded = try? HarnessRuntime.parseTimestamp(text(record["recorded_at"]))
      if let recorded, let previousDate, recorded < previousDate {
        errors.append("ledger recorded_at must be monotonic at line \(line)")
      }
      if recorded == nil { errors.append("ledger recorded_at is invalid at line \(line)") }
      previousDate = recorded ?? previousDate
      switch record["record_type"] as? String {
      case "approval" where payload["kind"] as? String == "run_authorization":
        let digest = text(payload["authorization_hash"])
        if payload["decision"] as? String != "approved" || digest.isEmpty
          || authorizations[digest] != nil
        {
          errors.append("run authorization approval must be unique and approved")
        } else {
          authorizations[digest] = payload
          if !["codex", "claude"].contains(payload["selected_writer"] as? String ?? "") {
            errors.append("run authorization approval has an invalid selected writer")
          }
          if !hash(payload["repository_fingerprint"]) || !sha(payload["repository_base_sha"]) {
            errors.append(
              "run authorization approval must bind repository fingerprint and base SHA")
          }
          if !uniqueStrings(payload["allowed_paths"]) || !uniqueStrings(payload["acceptance_ids"]) {
            errors.append("run authorization approval must bind allowed paths and acceptance IDs")
          }
          if let schema = installedAuthorizationSchema(context),
            payload["contract_schema_id"] as? String == schema.id,
            payload["contract_schema_sha256"] as? String == schema.digest
          {
          } else {
            errors.append("run authorization approval schema binding drifted")
          }
          guard let plans = payload["resource_plan"] as? [[String: Any]] else {
            errors.append("run authorization approval must bind its resource plan")
            continue
          }
          for plan in plans {
            let id = text(plan["plan_id"])
            let identity = text(plan["resource"]) + "\0" + text(plan["resource_key"])
            if id.isEmpty || resourcePlans[id] != nil
              || resourcePlans.values.contains(where: {
                text($0["resource"]) + "\0" + text($0["resource_key"]) == identity
              })
            {
              errors.append("run authorization resource plan IDs and identities must be unique")
            } else {
              resourcePlans[id] = plan
            }
          }
        }
      case "time_interval":
        if authorizations[text(payload["authorization_hash"])] == nil {
          errors.append("time interval must follow its run authorization")
        }
        if let start = try? HarnessRuntime.parseTimestamp(text(payload["started_at"])),
          let end = try? HarnessRuntime.parseTimestamp(text(payload["ended_at"])), end > start
        {
        } else {
          errors.append("time interval must have positive duration")
        }
      case "evidence":
        let id = text(payload["evidence_id"])
        if id.isEmpty || !evidenceIDs.insert(id).inserted {
          errors.append("evidence IDs must be unique and non-empty")
        }
        do {
          if try patchIdentityV1(payload["patch_manifest"] as Any) != payload["patch_identity"]
            as? String
          {
            errors.append("evidence patch identity drifted from its manifest")
          }
        } catch { errors.append("evidence must bind one valid patch_identity_v1 manifest") }
        if payload["outcome"] as? String == "passed" {
          let kind = payload["evidence_kind"] as? String ?? ""
          if ![
            "acceptance", "review", "commit_equivalence", "spec_kit_checkpoint",
            "testflight_artifact", "publication", "checks_readback",
          ].contains(kind) {
            errors.append("passed evidence kind is unsupported")
          } else {
            passingEvidence.append(payload)
          }
          errors += evidenceTupleErrors(payload, recordedAt: recorded)
        }
      case "lease":
        let resource = text(payload["resource"])
        let key = text(payload["resource_key"])
        let leaseKey = resource + "\0" + key
        errors += coordinatorReceiptErrors(
          runID: currentRun, leaseID: payload["lease_id"], owner: payload["owner"],
          resource: payload["resource"], resourceKey: payload["resource_key"],
          descriptor: payload["resource_descriptor"], receipt: payload["coordinator_receipt"],
          now: payload["action"] as? String == "release" ? nil : recorded)
        switch payload["action"] as? String {
        case "acquire":
          let protects = payload["protects"] as? [String] ?? []
          let signature = resource + "\0" + protects.joined(separator: "\0")
          let protectsRequired: Set<String> = [
            "xcode_project_mutation", "build_tuple", "simulator_or_device",
            "coresimulator_runtime_registry", "macos_gui_session",
          ]
          if protectsRequired.contains(resource) {
            if protects.isEmpty {
              errors.append("extension-scoped lease must declare protected workflow nodes")
            } else if protects.contains(where: { workflow.nodes[$0] == nil }) {
              errors.append("extension-scoped lease protects an unknown workflow node")
            } else if !Set(protects).isDisjoint(with: passedNodes) {
              errors.append("extension-scoped lease was acquired after its protected workflow node")
            }
          }
          let approvedWriters = Set(
            authorizations.values.compactMap { $0["selected_writer"] as? String })
          if !approvedWriters.isEmpty
            && (approvedWriters.count != 1 || !approvedWriters.contains(text(payload["owner"])))
          {
            errors.append("lease owner is not the approved selected writer")
          }
          let approvalIDs = Set(authorizations.values.compactMap { $0["approval_id"] as? String })
          if approvalIDs.count != 1 || !approvalIDs.contains(text(payload["approval_id"])) {
            errors.append("lease approval binding does not match the run authorization")
          }
          let fingerprints = Set(
            authorizations.values.compactMap { $0["repository_fingerprint"] as? String })
          if fingerprints.count == 1,
            let descriptor = payload["resource_descriptor"] as? [String: Any],
            descriptor["repository_fingerprint"] != nil,
            !same(descriptor["repository_fingerprint"], fingerprints.first!)
          {
            errors.append("lease repository fingerprint drifted from run authorization")
          }
          let conflicts = active.values.contains { other in
            guard let left = payload["resource_descriptor"] as? [String: Any],
              let right = other["resource_descriptor"] as? [String: Any]
            else { return true }
            let conflict = ResourceCoordinator.descriptorsConflict(
              resource: resource, descriptor: left, otherResource: text(other["resource"]),
              other: right)
            return conflict
              && !ResourceCoordinator.sameOwnerNestedCompatible(
                resource: resource, otherResource: text(other["resource"]),
                ownerRunID: text(currentRun), ownerActor: text(payload["owner"]),
                otherOwnerRunID: text(currentRun), otherOwnerActor: text(other["owner"]),
                descriptor: left, otherDescriptor: right)
          }
          let receipt = payload["coordinator_receipt"] as? [String: Any] ?? [:]
          let matchingPlans = resourcePlans.filter { _, plan in
            text(plan["resource"]) == resource && text(plan["resource_key"]) == key
              && same(plan["descriptor_sha256"], receipt["descriptor_sha256"])
              && same(plan["resource_descriptor"], payload["resource_descriptor"])
              && same(plan["owner_actor"], payload["owner"])
              && same(plan["protects"], payload["protects"])
          }
          if matchingPlans.count == 1 {
            let id = matchingPlans.first!.key
            if planBindings[id] != nil {
              errors.append("authorization resource plan cannot bind more than one lease")
            } else {
              planBindings[id] = text(payload["lease_id"])
            }
          } else if matchingPlans.count > 1 {
            errors.append("lease matches multiple authorization resource plans")
          } else if resourcePlans.values.contains(where: {
            text($0["resource"]) == resource && text($0["resource_key"]) == key
          }) {
            errors.append("lease drifted from its authorization resource plan")
          } else if !authorizations.isEmpty && !protects.isEmpty
            && !staticLeaseSignatures.contains(signature)
          {
            errors.append("dynamic workflow lease lacks an exact authorized resource plan")
          }
          if !same(payload["acquired_at"], receipt["acquired_at"])
            || !same(payload["expires_at"], receipt["expires_at"])
          {
            errors.append("lease acquisition times drifted from its coordinator receipt")
          }
          if let acquired = try? HarnessRuntime.parseTimestamp(text(payload["acquired_at"])),
            let expiry = try? HarnessRuntime.parseTimestamp(text(payload["expires_at"])),
            expiry > acquired, recorded == nil || acquired <= recorded!
          {
          } else {
            errors.append("lease acquisition time range is invalid")
          }
          if active[leaseKey] != nil || conflicts {
            errors.append("ledger lease acquire conflicts with an active lease")
          } else {
            active[leaseKey] = payload
          }
        case "heartbeat":
          guard var current = active[leaseKey], same(current["lease_id"], payload["lease_id"]),
            same(current["owner"], payload["owner"])
          else {
            errors.append("lease heartbeat does not match its active lease")
            continue
          }
          guard same(current["protects"], payload["protects"]),
            receiptLineage(
              current["coordinator_receipt"], payload["coordinator_receipt"],
              extensionRequired: true),
            let heartbeat = try? HarnessRuntime.parseTimestamp(text(payload["heartbeat_at"])),
            let old = try? HarnessRuntime.parseTimestamp(text(current["expires_at"])),
            heartbeat < old
          else {
            errors.append("lease heartbeat must be timely, extend expiry, and preserve its binding")
            continue
          }
          current["expires_at"] = payload["expires_at"]
          current["coordinator_receipt"] = payload["coordinator_receipt"]
          active[leaseKey] = current
        case "release":
          guard let releasedAt = try? HarnessRuntime.parseTimestamp(text(payload["released_at"])),
            let recorded, releasedAt <= recorded
          else {
            errors.append("lease release record precedes coordinator transition")
            continue
          }
          guard let current = active[leaseKey], same(current["lease_id"], payload["lease_id"]),
            same(current["owner"], payload["owner"]),
            same(current["resource_descriptor"], payload["resource_descriptor"]),
            receiptLineage(current["coordinator_receipt"], payload["coordinator_receipt"])
          else {
            errors.append("ledger lease release does not match an active lease")
            continue
          }
          let unmet = Set(current["protects"] as? [String] ?? []).subtracting(passedNodes)
          if !unmet.isEmpty {
            errors.append(
              "lease release preceded protected workflow nodes: \(unmet.sorted().joined(separator: ", "))"
            )
            continue
          }
          let recovery = releaseRecoveryErrors(
            current: current, release: payload, coordinatorState: coordinatorState)
          errors += recovery
          if recovery.isEmpty {
            for (id, leaseID) in planBindings where leaseID == text(payload["lease_id"]) {
              releasedPlans.insert(id)
            }
            releasedLeases[resource + "\0" + key + "\0" + text(payload["lease_id"])] = payload
            active.removeValue(forKey: leaseKey)
          }
        default: errors.append("ledger lease action is invalid")
        }
      case "grant_reservation":
        let digest = text(payload["authorization_hash"])
        let id = text(payload["reservation_id"])
        let authorization = authorizations[digest]
        if id.isEmpty || reservations[id] != nil {
          errors.append("grant reservation ID must be unique")
        }
        if let input = payload["operation_input"],
          (try? canonicalSHA256(input)) != payload["constraint_sha256"] as? String
        {
          errors.append("grant reservation operation input drifted from its constraint")
        }
        if !hash(payload["health_report_sha256"]) {
          errors.append("grant reservation must bind its evaluated health report")
        }
        if authorization == nil {
          errors.append("grant reservation must follow its run authorization")
        } else {
          if payload["writer_actor"] as? String != authorization?["selected_writer"] as? String
            || payload["lease_owner"] as? String != authorization?["selected_writer"] as? String
          {
            errors.append("grant reservation writer drifted from authorization")
          }
          let candidates = (authorization!["action_grants"] as? [[String: Any]] ?? []).filter {
            grant in
            [
              "grant_id", "idempotency_key", "system", "action", "operation", "operation_input",
              "constraint_sha256", "resource_key", "phase",
            ].allSatisfy { same(grant[$0], payload[$0]) }
          }
          if candidates.count != 1 {
            errors.append("grant reservation does not match one exact grant")
          } else {
            var target = candidates[0]["target"]
            if let source = candidates[0]["target_from_grant_id"] as? String {
              target = producedTargets[digest + "\0" + source]
            }
            if target == nil || !same(target, payload["target"]) {
              errors.append("grant reservation target is unavailable or drifted")
            }
          }
          if let issued = try? HarnessRuntime.parseTimestamp(text(authorization!["issued_at"])),
            let expiry = try? HarnessRuntime.parseTimestamp(text(authorization!["expires_at"])),
            let recorded, issued <= recorded, recorded < expiry
          {
          } else {
            errors.append("grant reservation occurred outside authorization time bounds")
          }
        }
        let leaseKey = text(payload["resource"]) + "\0" + text(payload["resource_key"])
        let lease = active[leaseKey]
        if lease == nil || !same(lease?["lease_id"], payload["lease_id"])
          || !same(lease?["owner"], payload["lease_owner"])
          || !(lease?["allowed_actions"] as? [String] ?? []).contains(text(payload["action"]))
          || !same(lease?["resource_descriptor"], payload["resource_descriptor"])
          || !same(lease?["coordinator_receipt"], payload["coordinator_receipt"])
          || text(payload["resource"]) != expectedLeaseResource(payload["action"])
        {
          errors.append("grant reservation lacks its exact active lease")
        } else {
          if let recorded,
            let expiry = try? HarnessRuntime.parseTimestamp(text(lease?["expires_at"])),
            recorded < expiry
          {
          } else {
            errors.append("grant reservation cannot use an expired lease")
          }
          if !same(lease?["approval_id"], authorization?["approval_id"]) {
            errors.append("grant reservation lease is not bound to the authorization")
          }
        }
        let grantKey = digest + "\0" + text(payload["grant_id"])
        let idempotency = digest + "\0" + text(payload["idempotency_key"])
        if !usedGrants.insert(grantKey).inserted || !usedKeys.insert(idempotency).inserted {
          errors.append("grant or idempotency key is already reserved")
        }
        if !id.isEmpty { reservations[id] = payload }
      case "grant_dispatch":
        let reservationID = text(payload["reservation_id"])
        let dispatchID = text(payload["dispatch_id"])
        let reservation = reservations[reservationID]
        if reservation == nil || claimed.contains(reservationID) || dispatchID.isEmpty
          || dispatches[dispatchID] != nil
        {
          errors.append("grant dispatch requires one unclaimed exact reservation")
        } else if !receiptLineage(
          reservation?["coordinator_receipt"], payload["coordinator_receipt"])
          || !same(reservation?["health_report_sha256"], payload["health_report_sha256"])
        {
          errors.append("grant dispatch drifted from its reservation fence or health report")
        } else {
          let leaseKey = text(reservation?["resource"]) + "\0" + text(reservation?["resource_key"])
          let lease = active[leaseKey]
          if lease == nil || !same(lease?["lease_id"], reservation?["lease_id"])
            || !same(lease?["owner"], reservation?["lease_owner"])
            || !same(lease?["coordinator_receipt"], payload["coordinator_receipt"])
          {
            errors.append("grant dispatch requires its exact active reservation lease")
          }
          let authorization = authorizations[text(reservation?["authorization_hash"])]
          if let recorded,
            let deadline = try? HarnessRuntime.parseTimestamp(text(payload["dispatch_deadline"])),
            let leaseExpiry = try? HarnessRuntime.parseTimestamp(
              text((payload["coordinator_receipt"] as? [String: Any])?["expires_at"])),
            let authorizationExpiry = try? HarnessRuntime.parseTimestamp(
              text(authorization?["expires_at"])), deadline > recorded,
            deadline.timeIntervalSince(recorded) <= maximumDispatchWindow, deadline <= leaseExpiry,
            deadline <= authorizationExpiry
          {
          } else {
            errors.append(
              "grant dispatch deadline is invalid or exceeds lease/authorization authority")
          }
        }
        claimed.insert(reservationID)
        if !dispatchID.isEmpty { dispatches[dispatchID] = payload }
      case "external_write":
        let reservationID = text(payload["reservation_id"])
        let dispatchID = text(payload["dispatch_id"])
        let reservation = reservations[reservationID]
        let dispatch = dispatches[dispatchID]
        if reservation == nil || !consumedReservations.insert(reservationID).inserted {
          errors.append("external write requires one unconsumed exact reservation")
        } else {
          for field in [
            "authorization_hash", "grant_id", "idempotency_key", "system", "action", "operation",
            "operation_input", "constraint_sha256", "resource_key", "phase", "lease_id",
            "lease_owner", "resource", "resource_descriptor", "target", "spec_checkpoint_sha256",
            "apple_observation_sha256", "writer_actor", "health_report_sha256",
          ] where !same(reservation?[field], payload[field]) {
            errors.append("external write drifted from its reservation")
            break
          }
          if !receiptLineage(reservation?["coordinator_receipt"], payload["coordinator_receipt"]) {
            errors.append("external write drifted from its reservation receipt lineage")
          }
        }
        if dispatch == nil || !consumedDispatches.insert(dispatchID).inserted
          || !same(dispatch?["reservation_id"], reservationID)
          || !receiptLineage(dispatch?["coordinator_receipt"], payload["coordinator_receipt"])
        {
          errors.append("external write requires one unconsumed matching dispatch claim")
        }
        if let recorded,
          let deadline = try? HarnessRuntime.parseTimestamp(text(dispatch?["dispatch_deadline"])),
          recorded < deadline
        {
        } else {
          errors.append("external write occurred outside its dispatch deadline")
        }
        let leaseKey = text(payload["resource"]) + "\0" + text(payload["resource_key"])
        let lease = active[leaseKey]
        if lease == nil || !same(lease?["lease_id"], payload["lease_id"])
          || !same(lease?["owner"], payload["lease_owner"])
          || !(lease?["allowed_actions"] as? [String] ?? []).contains(text(payload["action"]))
          || !same(lease?["resource_descriptor"], payload["resource_descriptor"])
          || !same(lease?["coordinator_receipt"], payload["coordinator_receipt"])
        {
          errors.append("external write requires its exact active reservation lease")
        }
        let digest = text(payload["authorization_hash"])
        let authorization = authorizations[digest]
        if authorization == nil {
          errors.append("external write must follow its run authorization")
        } else if let recorded,
          let issued = try? HarnessRuntime.parseTimestamp(text(authorization?["issued_at"])),
          let expiry = try? HarnessRuntime.parseTimestamp(text(authorization?["expires_at"])),
          issued <= recorded, recorded < expiry
        {
        } else {
          errors.append("external write occurred outside authorization time bounds")
        }
        if let recorded,
          let leaseExpiry = try? HarnessRuntime.parseTimestamp(text(lease?["expires_at"])),
          recorded < leaseExpiry
        {
        } else {
          errors.append("external write cannot use an expired lease")
        }
        if payload["outcome"] as? String == "succeeded" {
          successfulOperations.insert(
            text(payload["phase"]) + "\0" + text(payload["action"]) + "\0"
              + text(payload["operation"]))
          if let grant = (authorization?["action_grants"] as? [[String: Any]])?.first(where: {
            $0["grant_id"] as? String == payload["grant_id"] as? String
          }), let kind = grant["produces_target_kind"], !(kind is NSNull) {
            if validProducedTarget(
              kind: kind, target: payload["output_target"],
              repository: stringRepository(from: grant["target"]))
            {
              producedTargets[digest + "\0" + text(payload["grant_id"])] = text(
                payload["output_target"])
            } else {
              errors.append("external write produced an invalid GitHub target")
            }
          }
        }
      case "node" where payload["status"] as? String == "passed":
        let node = text(payload["node_id"])
        guard let definition = workflow.nodes[node] else {
          errors.append("passed node is not present in the installed workflow contracts")
          continue
        }
        if node == "bind_pr_ready" && !passedNodes.contains("pr_ready") {
          errors.append("TestFlight continuation cannot bind before pr_ready")
        }
        if passedNodes.contains(node) {
          errors.append("workflow node cannot pass more than once: \(node)")
        }
        let dependencies = Set(definition["requires"] as? [String] ?? [])
        if !dependencies.isSubset(of: passedNodes) {
          errors.append(
            "workflow node \(node) passed before dependencies: \(dependencies.subtracting(passedNodes).sorted().joined(separator: ", "))"
          )
        }
        let authorization = authorizations.count == 1 ? authorizations.values.first : nil
        if workflow.patchBound.contains(node) || protectedBy[node] != nil {
          if let authorization, let recorded,
            let issued = try? HarnessRuntime.parseTimestamp(text(authorization["issued_at"])),
            let expiry = try? HarnessRuntime.parseTimestamp(text(authorization["expires_at"])),
            issued <= recorded, recorded < expiry
          {
          } else {
            errors.append("workflow node \(node) is outside run authorization time bounds")
          }
        }
        if workflow.patchBound.contains(node) {
          do {
            guard let manifest = payload["patch_manifest"] as? [String: Any],
              try patchIdentityV1(manifest) == payload["patch_identity"] as? String,
              same(manifest["base_sha"], authorization?["repository_base_sha"]),
              (manifest["records"] as? [[String: Any]] ?? []).allSatisfy({ record in
                pathAllowed(
                  text(record["path"]), authorization?["allowed_paths"] as? [String] ?? [])
              })
            else { throw VerificationError.invalid("drift") }
          } catch {
            errors.append(
              "workflow node \(node) must recompute one authorized patch_identity_v1 manifest")
          }
        }
        let patchIdentity = payload["patch_identity"] as? String
        let repositoryFingerprint = authorization?["repository_fingerprint"] as? String
        let currentEvidence = passingEvidence.filter {
          $0["patch_identity"] as? String == patchIdentity
            && $0["repository_fingerprint"] as? String == repositoryFingerprint
        }
        let acceptanceCoverage = Set(
          currentEvidence.filter { $0["evidence_kind"] as? String == "acceptance" }.flatMap {
            $0["acceptance_ids"] as? [String] ?? []
          })
        let requiredAcceptance = Set(authorization?["acceptance_ids"] as? [String] ?? [])
        let acceptanceNodes: Set<String> = [
          "verify", "reverify", "prepare_evidence", "prepare_pr", "repository_confirmation",
          "commit", "push", "verify_remote_sha", "create_pr", "publish_evidence",
          "verify_published_evidence", "checks", "pr_ready", "local_verified",
        ]
        let reviewNodes: Set<String> = [
          "review", "prepare_evidence", "prepare_pr", "repository_confirmation", "commit", "push",
          "verify_remote_sha", "create_pr", "publish_evidence", "verify_published_evidence",
          "checks", "pr_ready",
        ]
        let commitNodes: Set<String> = [
          "verify_remote_sha", "create_pr", "publish_evidence", "verify_published_evidence",
          "checks", "pr_ready",
        ]
        let publicationNodes: Set<String> = ["verify_published_evidence", "checks", "pr_ready"]
        if acceptanceNodes.contains(node),
          authorization == nil || requiredAcceptance.isEmpty
            || !requiredAcceptance.isSubset(of: acceptanceCoverage)
        {
          errors.append("workflow node \(node) lacks current complete acceptance evidence")
        }
        if node == "local_verified",
          let local = authorization?["local_requirements"] as? [String: Any]
        {
          if local["review_required"] as? Bool == true {
            if !currentEvidence.contains(where: { $0["evidence_kind"] as? String == "review" }) {
              errors.append("local_verified lacks the review required by its accepted plan")
            }
          } else if !currentEvidence.contains(where: { evidence in
            evidence["evidence_kind"] as? String == "acceptance"
              && ((evidence["tool_tuple"] as? [String: Any])?["omitted_checks"] as? [String] ?? [])
                .contains("independent_review:not_required_by_accepted_plan")
          }) {
            errors.append("local_verified must record why independent review was omitted")
          }
          if local["spec_kit_required"] as? Bool == true {
            let checkpoints = currentEvidence.filter {
              $0["evidence_kind"] as? String == "spec_kit_checkpoint"
            }
            if checkpoints.count == 1,
              let snapshot = (checkpoints[0]["tool_tuple"] as? [String: Any])?["spec_kit_snapshot"]
                as? [String: Any], let expected = authorization?["spec_kit"] as? [String: Any]
            {
              errors += specKitCheckpointErrors(snapshot: snapshot, expected: expected)
            } else {
              errors.append(
                "local_verified requires one current Spec Kit checkpoint matching its authorization"
              )
            }
          }
        }
        if reviewNodes.contains(node),
          !currentEvidence.contains(where: { $0["evidence_kind"] as? String == "review" })
        {
          errors.append("workflow node \(node) lacks current review evidence")
        }
        if commitNodes.contains(node),
          !currentEvidence.contains(where: {
            $0["evidence_kind"] as? String == "commit_equivalence"
              && same($0["local_sha"], $0["remote_sha"])
          })
        {
          errors.append("workflow node \(node) lacks current commit equivalence evidence")
        }
        if publicationNodes.contains(node),
          !currentEvidence.contains(where: {
            $0["evidence_kind"] as? String == "publication"
              && ($0["tool_tuple"] as? [String: Any])?["viewable"] as? Bool == true
          })
        {
          errors.append("workflow node \(node) lacks current viewable publication evidence")
        }
        if ["checks", "pr_ready"].contains(node),
          !currentEvidence.contains(where: {
            $0["evidence_kind"] as? String == "checks_readback"
              && ($0["tool_tuple"] as? [String: Any])?["required_checks_satisfied"] as? Bool == true
          })
        {
          errors.append("workflow node \(node) lacks current required-checks read-back evidence")
        }

        for (planID, plan) in resourcePlans
        where (plan["protects"] as? [String] ?? []).contains(node) {
          guard let leaseID = planBindings[planID],
            let lease = active.values.first(where: { text($0["lease_id"]) == leaseID })
          else {
            errors.append("workflow node \(node) passed without planned resource lease \(planID)")
            continue
          }
          if let recorded,
            let acquired = try? HarnessRuntime.parseTimestamp(text(lease["acquired_at"])),
            let expires = try? HarnessRuntime.parseTimestamp(text(lease["expires_at"])),
            acquired <= recorded, recorded < expires
          {
          } else {
            errors.append(
              "workflow node \(node) passed outside planned resource lease \(planID) time bounds")
          }
        }
        for acquireNode in protectedBy[node] ?? [] {
          guard let binding = workflowLeaseBindings[acquireNode],
            let lease = active[text(binding["resource"]) + "\0" + text(binding["resource_key"])],
            same(lease["lease_id"], binding["lease_id"])
          else {
            errors.append("workflow node \(node) passed without its bound active lease")
            continue
          }
          if let recorded,
            let acquired = try? HarnessRuntime.parseTimestamp(text(lease["acquired_at"])),
            let expires = try? HarnessRuntime.parseTimestamp(text(lease["expires_at"])),
            acquired <= recorded, recorded < expires
          {
          } else {
            errors.append("workflow node \(node) passed outside its bound lease time interval")
          }
        }
        if definition["lease_action"] as? String == "acquire" {
          let binding: [String: Any] = [
            "resource": payload["lease_resource"] as Any,
            "resource_key": payload["lease_resource_key"] as Any,
            "lease_id": payload["lease_id"] as Any,
          ]
          let lease = active[text(binding["resource"]) + "\0" + text(binding["resource_key"])]
          if text(binding["resource"]) != text(definition["resource"])
            || ["resource", "resource_key", "lease_id"].contains(where: {
              text(binding[$0]).isEmpty
            }) || lease == nil || !same(lease?["lease_id"], binding["lease_id"])
            || !same(lease?["protects"], definition["protects"])
          {
            errors.append(
              "workflow lease-acquire node \(node) lacks its exact active lease binding")
          } else if workflowLeaseBindings.values.contains(where: { same($0, binding) }) {
            errors.append("one lease cannot satisfy multiple workflow acquire nodes")
          } else {
            workflowLeaseBindings[node] = binding
          }
        } else if definition["lease_action"] as? String == "release" {
          let binding: [String: Any] = [
            "resource": payload["lease_resource"] as Any,
            "resource_key": payload["lease_resource_key"] as Any,
            "lease_id": payload["lease_id"] as Any,
          ]
          guard let acquire = releaseToAcquire[node], let expected = workflowLeaseBindings[acquire],
            same(binding, expected),
            releasedLeases[
              text(binding["resource"]) + "\0" + text(binding["resource_key"]) + "\0"
                + text(binding["lease_id"])] != nil
          else {
            errors.append(
              "workflow lease-release node \(node) lacks its exact released lease binding")
            passedNodes.insert(node)
            continue
          }
        }
        passedNodes.insert(node)
        if ["local_verified", "pr_ready", "testflight_uploaded", "testflight_distributed"].contains(
          node), !active.isEmpty
        {
          errors.append("terminal node cannot pass with an active lease")
        }
        if ["local_verified", "pr_ready", "testflight_uploaded", "testflight_distributed"].contains(
          node)
        {
          let applicable = resourcePlans.filter { _, plan in
            Set(plan["protects"] as? [String] ?? []).isSubset(of: passedNodes)
          }.keys
          let unreleased = Set(applicable).subtracting(releasedPlans)
          if !unreleased.isEmpty {
            errors.append(
              "terminal node requires every applicable resource plan to be released: \(unreleased.sorted().joined(separator: ", "))"
            )
          }
        }
        if node == "pr_ready", !Set(workflow.main).isSubset(of: passedNodes) {
          errors.append("pr_ready requires every installed main-workflow node")
        }
        if node == "pr_ready", let authorization = authorizations.values.first {
          let required = Set(
            (authorization["action_grants"] as? [[String: Any]] ?? []).filter {
              $0["phase"] as? String == "pr_delivery"
            }.map { "pr_delivery\0\(text($0["action"]))\0\(text($0["operation"]))" })
          if !required.isSubset(of: successfulOperations) {
            errors.append("pr_ready requires every authorized delivery operation")
          }
        }
        if node == "testflight_uploaded",
          let cutoff = workflow.continuation.firstIndex(of: "testflight_uploaded"),
          !Set(workflow.continuation[...cutoff]).isSubset(of: passedNodes)
        {
          errors.append("testflight_uploaded requires every upload-continuation node")
        }
        if node == "testflight_distributed", !Set(workflow.continuation).isSubset(of: passedNodes) {
          errors.append("testflight_distributed requires every continuation node")
        }
        if node == "local_verified", !Set(workflow.main).isSubset(of: passedNodes) {
          errors.append("local_verified requires every installed local-workflow node")
        }
      case "stop":
        if !active.isEmpty { errors.append("terminal stop cannot leave an active lease") }
      case "knowledge":
        if Set(payload.keys) != ["source_id", "authority", "content_hash", "provenance"]
          || payload.values.contains(where: { text($0).isEmpty })
        {
          errors.append("knowledge record must bind exact non-empty provenance")
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
          || id.isEmpty || !feedbackIDs.insert(id).inserted
        {
          errors.append("feedback record must bind one unique valid disposition")
        }
        if let invalidates = payload["invalidates"], !(invalidates is NSNull),
          !uniqueStringArrayAllowEmpty(invalidates)
        {
          errors.append("feedback invalidates must be unique strings")
        }
      case "attempt", "approval": break
      default: errors.append("ledger record type is unsupported at line \(line)")
      }
    }
    return Array(Set(errors)).sorted()
  }

  public static func activeLeases(_ records: [[String: Any]], coordinatorState: URL? = nil) -> (
    leases: [String: [String: Any]], errors: [String]
  ) {
    var active: [String: [String: Any]] = [:]
    var errors: [String] = []
    for record in records where record["record_type"] as? String == "lease" {
      guard let payload = record["payload"] as? [String: Any] else { continue }
      let key = text(payload["resource"]) + "\0" + text(payload["resource_key"])
      if payload["action"] as? String == "acquire" {
        if active[key] != nil {
          errors.append("ledger contains overlapping lease acquisitions")
        } else {
          active[key] = payload
        }
      } else if payload["action"] as? String == "heartbeat" {
        guard var value = active[key], same(value["lease_id"], payload["lease_id"]),
          receiptLineage(
            value["coordinator_receipt"], payload["coordinator_receipt"], extensionRequired: true)
        else {
          errors.append("ledger lease heartbeat does not match an active lease")
          continue
        }
        value["expires_at"] = payload["expires_at"]
        value["coordinator_receipt"] = payload["coordinator_receipt"]
        active[key] = value
      } else if payload["action"] as? String == "release" {
        guard let value = active[key], same(value["lease_id"], payload["lease_id"]),
          same(value["owner"], payload["owner"])
        else {
          errors.append("ledger lease release does not match an active lease")
          continue
        }
        active.removeValue(forKey: key)
      }
    }
    return (active, errors)
  }

  private static func coordinatorReceiptErrors(
    runID: Any?, leaseID: Any?, owner: Any?, resource: Any?, resourceKey: Any?, descriptor: Any?,
    receipt: Any?, now: Date?
  ) -> [String] {
    guard let receipt = receipt as? [String: Any], Set(receipt.keys) == coordinatorReceiptFields
    else { return ["lease lacks an exact coordinator receipt"] }
    var errors: [String] = []
    if !same(receipt["owner_run_id"], runID) || !same(receipt["lease_id"], leaseID)
      || !same(receipt["owner_actor"], owner) || !same(receipt["resource"], resource)
      || !same(receipt["resource_key"], resourceKey)
    {
      errors.append("lease coordinator receipt identity drifted")
    }
    if let descriptor = descriptor as? [String: Any], let resource = resource as? String {
      if let normalized = try? ResourceCoordinator.normalizeDescriptor(
        resource: resource, descriptor: descriptor),
        let digest = try? ResourceCoordinator.descriptorSHA256(
          resource: resource, descriptor: normalized),
        let key = try? ResourceCoordinator.canonicalResourceKey(
          resource: resource, descriptor: normalized)
      {
        if !same(descriptor, normalized) {
          errors.append("resource lease descriptor is not canonical")
        }
        if receipt["descriptor_sha256"] as? String != digest || resourceKey as? String != key {
          errors.append("lease coordinator descriptor digest or key drifted")
        }
      } else {
        errors.append("resource lease descriptor is invalid")
      }
    }
    if let now, let expiry = try? HarnessRuntime.parseTimestamp(text(receipt["expires_at"])),
      now >= expiry
    {
      errors.append("lease coordinator receipt is expired")
    }
    return errors
  }

  private static func receiptLineage(_ lhs: Any?, _ rhs: Any?, extensionRequired: Bool = false)
    -> Bool
  {
    guard let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any],
      Set(lhs.keys) == coordinatorReceiptFields, Set(rhs.keys) == coordinatorReceiptFields
    else { return false }
    for key in coordinatorReceiptFields.subtracting(["expires_at"]) where !same(lhs[key], rhs[key])
    { return false }
    guard let left = try? HarnessRuntime.parseTimestamp(text(lhs["expires_at"])),
      let right = try? HarnessRuntime.parseTimestamp(text(rhs["expires_at"]))
    else { return false }
    return extensionRequired ? right > left : right >= left
  }

  private static func releaseRecoveryErrors(
    current: [String: Any], release: [String: Any], coordinatorState: URL?
  ) -> [String] {
    guard let released = try? HarnessRuntime.parseTimestamp(text(release["released_at"])),
      let expires = try? HarnessRuntime.parseTimestamp(text(current["expires_at"])),
      let receipt = current["coordinator_receipt"] as? [String: Any]
    else { return ["lease release or expiry timestamp is invalid"] }
    if released < expires {
      if !(release["recovery_evidence"] is NSNull) && release["recovery_evidence"] != nil {
        return ["unexpired lease release cannot claim coordinator recovery"]
      }
      guard let confirmation = release["coordinator_release_confirmation"] as? [String: Any],
        ResourceCoordinator.validateReleaseConfirmation(
          receipt: receipt, confirmation: confirmation, statePath: coordinatorState),
        confirmation["released_at"] as? String == release["released_at"] as? String
      else { return ["lease release confirmation is invalid or not live"] }
      return []
    }
    if !(release["coordinator_release_confirmation"] is NSNull)
      && release["coordinator_release_confirmation"] != nil
    {
      return ["expired lease recovery cannot carry a normal release confirmation"]
    }
    guard let evidence = release["recovery_evidence"] as? [String: Any],
      let confirmation = release["recovery_confirmation"] as? [String: Any],
      ResourceCoordinator.validateRecoveryConfirmation(
        receipt: receipt, evidence: evidence, confirmation: confirmation,
        statePath: coordinatorState),
      same(confirmation["recovered_at"], release["released_at"])
    else { return ["expired lease release requires valid coordinator recovery evidence"] }
    return []
  }

  private static func evidenceTupleErrors(_ payload: [String: Any], recordedAt: Date?) -> [String] {
    guard let tuple = payload["tool_tuple"] as? [String: Any] else {
      return ["passed evidence requires its exact evidence-kind tool tuple"]
    }
    let common: Set<String> = [
      "provider", "tool", "tool_version", "command_or_call", "started_at", "ended_at",
      "exit_status",
    ]
    let kindFields: [String: Set<String>] = [
      "acceptance": [
        "verification_scope", "evidence_layer", "platform", "destination", "coverage", "artifacts",
        "omitted_checks",
      ],
      "review": ["staged_diff_sha256"], "commit_equivalence": ["comparison"],
      "spec_kit_checkpoint": ["spec_kit_snapshot"], "testflight_artifact": [],
      "publication": ["viewable", "readback_sha256"],
      "checks_readback": ["required_checks_satisfied", "readback_sha256"],
    ]
    guard let kind = payload["evidence_kind"] as? String, let specific = kindFields[kind],
      Set(tuple.keys) == common.union(specific)
    else { return ["passed evidence requires its exact evidence-kind tool tuple"] }
    var errors: [String] = []
    for field in ["provider", "tool", "tool_version", "command_or_call"]
    where (tuple[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      != false
    { errors.append("passed evidence tool tuple requires \(field)") }
    if jsonInt(tuple["exit_status"]) != 0 {
      errors.append("passed evidence requires zero tool exit status")
    }
    if let start = try? HarnessRuntime.parseTimestamp(text(tuple["started_at"])),
      let end = try? HarnessRuntime.parseTimestamp(text(tuple["ended_at"])), end >= start,
      recordedAt == nil || end <= recordedAt!
    {
    } else {
      errors.append("passed evidence tool time range is invalid")
    }
    if kind == "review", !sha256(tuple["staged_diff_sha256"]) {
      errors.append("passed review evidence must bind the staged diff digest")
    }
    if kind == "commit_equivalence",
      !same(payload["local_sha"], payload["remote_sha"]) || !sha(text(payload["local_sha"]))
    {
      errors.append("passed commit evidence requires equal local and remote SHAs")
    }
    if kind == "publication", tuple["viewable"] as? Bool != true || !hash(tuple["readback_sha256"])
    {
      errors.append("passed publication evidence requires a viewable read-back digest")
    }
    if kind == "checks_readback",
      tuple["required_checks_satisfied"] as? Bool != true || !hash(tuple["readback_sha256"])
    {
      errors.append("passed checks evidence requires a satisfied read-back digest")
    }
    if kind == "acceptance" {
      if tuple["verification_scope"] as? String != "minimum-sufficient" {
        errors.append("acceptance evidence must use minimum-sufficient scope")
      }
      let layer = tuple["evidence_layer"] as? String
      if !["repository_contract", "build", "runtime_ui", "motion"].contains(layer ?? "") {
        errors.append("acceptance evidence layer is invalid")
      }
      if !["repository", "ios", "ipados", "watchos", "macos", "multi-platform"].contains(
        tuple["platform"] as? String ?? "")
      {
        errors.append("acceptance evidence platform is invalid")
      }
      if (tuple["destination"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        != false
      {
        errors.append("acceptance evidence destination is required")
      }
      let coverage = tuple["coverage"] as? [[String: Any]] ?? []
      let coverageIDs = coverage.compactMap { $0["acceptance_id"] as? String }
      let coverageFields: Set<String> = [
        "acceptance_id", "observable_contract", "prevented_failure", "unique_path", "result",
      ]
      if coverage.isEmpty
        || coverage.contains(where: { item in
          Set(item.keys) != coverageFields
            || ["acceptance_id", "observable_contract", "prevented_failure", "unique_path"]
              .contains(where: { field in
                (item[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  != false
              })
            || item["result"] as? String != "passed"
        })
      {
        errors.append("acceptance coverage fields are invalid or did not pass")
      }
      if Set(coverageIDs) != Set(payload["acceptance_ids"] as? [String] ?? [])
        || Set(coverageIDs).count != coverageIDs.count
      {
        errors.append("acceptance coverage must exactly match evidence acceptance IDs")
      }
      if let omissions = tuple["omitted_checks"] as? [String],
        Set(omissions).count == omissions.count, omissions.allSatisfy({ !$0.isEmpty })
      {
      } else {
        errors.append("acceptance evidence omissions must be unique strings")
      }
      let artifacts = tuple["artifacts"] as? [[String: Any]] ?? []
      let kinds = Set(artifacts.compactMap { $0["kind"] as? String })
      let artifactFields: Set<String> = ["kind", "reference", "content_sha256"]
      if artifacts.contains(where: {
        Set($0.keys) != artifactFields
          || !["screenshot", "video", "xcresult", "log", "report"].contains(
            $0["kind"] as? String ?? "")
          || ($0["reference"] as? String)?.isEmpty != false || !hash($0["content_sha256"])
      }) {
        errors.append("acceptance evidence artifact is invalid")
      }
      if layer == "runtime_ui" && !kinds.contains("screenshot") {
        errors.append("runtime UI acceptance requires screenshot evidence")
      }
      if layer == "motion" && !kinds.contains("video") {
        errors.append("motion acceptance requires video evidence")
      }
    }
    return errors
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

  private static func specKitCheckpointErrors(snapshot: [String: Any], expected: [String: Any])
    -> [String]
  {
    var errors: [String] = []
    let mappings = [
      ("spec_kit_release", "release"), ("feature_id", "feature_id"),
      ("feature_directory", "feature_directory"), ("snapshot_sha256", "snapshot_sha256"),
      ("artifact_hashes", "artifact_hashes"),
    ]
    if mappings.contains(where: { !same(snapshot[$0.0], expected[$0.1]) }) {
      errors.append("local_verified Spec Kit checkpoint drifted from authorization")
    }
    let immutableKeys: Set<String> = [
      "schema_version", "spec_kit_release", "feature_id", "feature_directory", "accepted_artifacts",
    ]
    guard immutableKeys.isSubset(of: Set(snapshot.keys)),
      let expectedHash = snapshot["snapshot_sha256"] as? String
    else { return errors + ["local_verified Spec Kit checkpoint shape is invalid"] }
    let immutable = Dictionary(
      uniqueKeysWithValues: immutableKeys.map { ($0, snapshot[$0] ?? NSNull()) })
    if (try? canonicalSHA256(immutable)) != expectedHash {
      errors.append("local_verified Spec Kit checkpoint hash is not canonical")
    }
    return errors
  }

  private static func stringRepository(from value: Any?) -> String? {
    guard let value = value as? String, let part = value.split(separator: ":", maxSplits: 1).first,
      !part.isEmpty
    else { return nil }
    return String(part)
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

  private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }
  private static func text(_ value: Any?) -> String {
    value is NSNull || value == nil ? "" : ((value as? String) ?? String(describing: value!))
  }
  private static func jsonInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !HarnessRuntime.isBoolean(number) else { return nil }
    let raw = number.stringValue
    guard let value = Int(raw), raw == String(value) || raw == "-0" else { return nil }
    return value
  }
  private static func hash(_ value: Any?) -> Bool {
    (value as? String)?.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }
  private static func sha256(_ value: Any?) -> Bool {
    (value as? String)?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }
  private static func sha(_ value: Any?) -> Bool {
    (value as? String)?.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil
  }
  private static func uniqueStrings(_ value: Any?) -> Bool {
    guard let values = value as? [String], !values.isEmpty else { return false }
    return Set(values).count == values.count && values.allSatisfy { !$0.isEmpty }
  }
  private static func pathAllowed(_ path: String, _ allowed: [String]) -> Bool {
    !path.isEmpty && !path.hasPrefix("/")
      && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
      && allowed.contains {
        path == $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          || path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
      }
  }
}
