import XCTest

@testable import AppleVerificationCore

/// `authorizeAction` checks a request's paths in three places: against the authorization's
/// `allowed_paths`, against the active lease's `allowed_paths`, and, for `git.commit`, against the
/// commit descriptor's path scope. All three apply the one shared `Authorization.pathAllowed`
/// rule, so an entry written as `dir/` admits `dir` itself at every site while every escape stays
/// denied. These tests drive each site through a real `authorizeAction` request.
final class PathAllowedUnificationTests: XCTestCase {
  private enum Site: CaseIterable {
    case authorization, lease, commitScope

    var denial: String {
      switch self {
      case .authorization: "requested path is outside authorization"
      case .lease: "requested path is outside the active lease allowance"
      case .commitScope:
        "git.commit path is outside the structured operation descriptor path scope"
      }
    }
  }

  private let ownershipError = "action request does not own the exact active ledger lease"

  /// Paths an allowed entry `dir/` must never admit at any site.
  private let escapes = ["dir-evil", "direvil", "../dir", "/dir", "", "dir/../x"]

  func testEachSiteAdmitsTheDirectoryNamedByAnEntryWithATrailingSlash() throws {
    for site in Site.allCases {
      XCTAssertFalse(try denied("dir", by: ["dir/"], at: site), "\(site)")
      XCTAssertFalse(try denied("dir/x.swift", by: ["dir/"], at: site), "\(site)")
      XCTAssertFalse(try denied("dir", by: ["dir"], at: site), "\(site)")
      XCTAssertFalse(try denied("dir/x.swift", by: ["dir"], at: site), "\(site)")
    }
  }

  func testEachSiteKeepsDenyingEscapesAndSiblingPrefixes() throws {
    for site in Site.allCases {
      for path in escapes {
        XCTAssertTrue(try denied(path, by: ["dir/"], at: site), "\(site): \(path)")
        XCTAssertTrue(try denied(path, by: ["dir"], at: site), "\(site): \(path)")
      }
    }
  }

  func testEachSiteDeniesEveryPathWhenNothingIsAllowed() throws {
    for site in Site.allCases {
      for path in ["dir", "dir/x.swift"] {
        XCTAssertTrue(try denied(path, by: [], at: site), "\(site): \(path)")
      }
    }
  }

  func testSharedRuleTrimsSlashesFromEntriesButRejectsEveryEscape() {
    for entry in ["dir", "dir/", "dir//"] {
      XCTAssertTrue(Authorization.pathAllowed("dir", [entry]), entry)
      XCTAssertTrue(Authorization.pathAllowed("dir/x.swift", [entry]), entry)
      for path in escapes {
        XCTAssertFalse(Authorization.pathAllowed(path, [entry]), "\(entry): \(path)")
      }
    }
    // An entry that trims to nothing admits nothing rather than the whole repository.
    for entry in ["/", "//", ""] {
      XCTAssertFalse(Authorization.pathAllowed("dir", [entry]), entry)
      XCTAssertFalse(Authorization.pathAllowed("x.swift", [entry]), entry)
    }
    XCTAssertFalse(Authorization.pathAllowed("dir", []))
  }

  /// Whether `authorizeAction` rejects a git.commit request for `path` at `site` when that site
  /// allows exactly `allowed`. The other two sites allow `dir/`, and only the site's own error is
  /// read, so each site is judged on its own.
  private func denied(_ path: String, by allowed: [String], at site: Site) throws -> Bool {
    let others = ["dir/"]
    let errors = try authorizeCommit(
      paths: [path], authorization: site == .authorization ? allowed : others,
      lease: site == .lease ? allowed : others,
      commitScope: site == .commitScope ? allowed : others)
    // The lease path check runs only for a request that owns the active lease; without that
    // ownership an allowed result would not prove the lease check admitted the path.
    XCTAssertFalse(errors.contains(ownershipError), "\(site): \(path)")
    return errors.contains(site.denial)
  }

  private func authorizeCommit(
    paths: [String], authorization: [String], lease: [String], commitScope: [String]
  ) throws -> [String] {
    let now = Date()
    let action = "git.commit"
    var envelope = try GateRunSupport.approvedEnvelope()
    envelope["allowed_paths"] = authorization
    var grants = envelope["action_grants"] as! [[String: Any]]
    let index = grants.firstIndex { $0["action"] as? String == action }!
    let operationInput: [String: Any] = [
      "message_policy": "reviewed_patch", "paths": commitScope,
    ]
    grants[index]["operation_input"] = operationInput
    grants[index]["constraint_sha256"] = try Authorization.canonicalSHA256(operationInput)
    envelope["action_grants"] = grants
    let grant = grants[index]

    let resource = Authorization.expectedLeaseResource(action)!
    let descriptor = try Authorization.canonicalResourceDescriptor(envelope, action: action)
    let key = try Authorization.canonicalLeaseResourceKey(envelope, action: action)
    let repository = envelope["repository"] as! [String: Any]
    let acquiredAt = HarnessRuntime.timestamp(now)
    let expiresAt = HarnessRuntime.timestamp(now.addingTimeInterval(600))
    let receipt: [String: Any] = [
      "coordinator_instance_id": "fixture-coordinator", "receipt_id": "receipt-dir",
      "lease_id": "lease-dir", "owner_run_id": envelope["run_id"]!, "owner_actor": "codex",
      "resource": resource, "resource_key": key,
      "descriptor_sha256": try ResourceCoordinator.descriptorSHA256(
        resource: resource, descriptor: descriptor),
      "fencing_token": 1, "acquired_at": acquiredAt, "expires_at": expiresAt,
    ]
    let acquire: [String: Any] = [
      "lease_id": "lease-dir", "action": "acquire", "owner": "codex", "resource": resource,
      "resource_key": key, "resource_descriptor": descriptor, "coordinator_receipt": receipt,
      "branch": repository["branch"]!, "base_sha": repository["base_sha"]!,
      "pre_state_hash": "sha256:" + String(repeating: "f", count: 64), "allowed_paths": lease,
      "allowed_actions": [action], "approval_id": envelope["authorization_id"]!,
      "acquired_at": acquiredAt, "expires_at": expiresAt,
    ]
    let ledger: [[String: Any]] = [
      [
        "schema_version": "1.0.0", "run_id": envelope["run_id"]!, "sequence": 1,
        "record_type": "lease", "recorded_at": acquiredAt, "payload": acquire,
      ]
    ]

    var request: [String: Any] = [:]
    for field in Authorization.requestFields { request[field] = NSNull() }
    for field in [
      "system", "action", "operation", "operation_input", "constraint_sha256", "phase", "grant_id",
      "idempotency_key", "target",
    ] {
      request[field] = grant[field]
    }
    request["paths"] = paths
    request["lease_id"] = "lease-dir"
    request["lease_owner"] = "codex"
    request["lease_resource"] = resource
    request["lease_resource_key"] = key
    request["resource_descriptor"] = descriptor
    request["coordinator_receipt"] = receipt
    return Authorization.authorizeAction(
      envelope: envelope, request: request, now: now, ledgerRecords: ledger, policyOverlay: [:],
      liveRepository: ["staged_paths": paths], verifiedCoordinatorReceipt: receipt,
      selectedWriter: "codex", verifiedHealthAttestation: nil, context: GateRunSupport.context)
  }
}
