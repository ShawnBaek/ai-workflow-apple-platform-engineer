import Foundation

/// The capability policy read from an installed `contracts/capabilities.json`.
///
/// `capabilities.json` is the one place a capability value is declared. Its schema checks only
/// shape (closed objects, required keys and value types) and `reviewedSHA256` pins every value.
/// Authorization reads the plannable resources from a loaded policy instead of repeating them in
/// Swift. Other declared values are implemented in Swift too, and a change to one must change
/// that implementation in the same commit. `errors` compares only three of them with the
/// declaration: `max_ttl_seconds` with the coordinator's lease ceiling, the Spec Kit
/// `pinned_release` with the snapshot's release, and `resource_scopes` with the resources the
/// coordinator can lease. The rest, for example `resource_key_fields` and the build tuple's
/// cache roles and package resolution modes in `ResourceCoordinator`, are not compared; only the
/// review behind `reviewedSHA256` keeps them in step.
struct CapabilityPolicy {
  /// SHA-256 of capabilities.json as canonical JSON (keys in Unicode scalar order, no
  /// insignificant whitespace, non-ASCII escaped), without its `$schema` editor hint.
  ///
  /// It keeps the policy from being changed through contract data alone. The runtime refuses an
  /// installed file with another digest and the repository validator refuses a checkout with
  /// one, so changing any value, including the runtime registry, Xcode MCP, resource overlap and
  /// cross-run coordination policies, also takes a reviewed change to this Swift source. After an
  /// intended change, copy the observed digest that the validator reports into this constant in
  /// the same commit as any Swift that implements the changed value.
  static let reviewedSHA256 = "5d3270e8320798d78621989b93513144929bedc6323102f0850be4bb0934deb2"

  /// Resources an approved run authorization may plan to lease.
  let resourceScopes: [String]
  /// The longest lease or heartbeat extension, declared for the coordinator's ceiling.
  let maxLeaseTTLSeconds: Int
  /// The Spec Kit release, declared for the snapshot's pinned release.
  let specKitRelease: String

  private init?(_ document: [String: Any]) {
    guard let scopes = document["resource_scopes"] as? [String],
      let ttl = ContractValidation.integer(
        (document["cross_run_coordination_policy"] as? [String: Any])?["max_ttl_seconds"]),
      let release = (document["spec_kit_policy"] as? [String: Any])?["pinned_release"] as? String
    else { return nil }
    resourceScopes = scopes
    maxLeaseTTLSeconds = ttl
    specKitRelease = release
  }

  /// Reads the policy installed under the context's harness root and accepts it only when it
  /// matches its schema, the reviewed digest and the runtime's implemented values.
  static func load(context: RuntimeContext) throws -> CapabilityPolicy {
    // Accept a skill root or a repository root, as the installed authorization schema does.
    let direct = context.harnessRoot.appendingPathComponent("contracts")
    let contracts =
      FileManager.default.fileExists(atPath: direct.path)
      ? direct : context.harnessRoot.appendingPathComponent("skills/agent-harness/contracts")
    let document: [String: Any]
    let schema: [String: Any]
    do {
      document = try HarnessRuntime.object(contracts.appendingPathComponent("capabilities.json"))
      schema = try HarnessRuntime.object(
        contracts.appendingPathComponent("schemas/capabilities.schema.json"))
    } catch {
      throw VerificationError.invalid("installed capability policy is unavailable: \(error)")
    }
    var instance = document
    instance.removeValue(forKey: "$schema")
    let problems =
      JSONSchemaValidator.errors(instance: instance, schema: schema).map {
        "capability policy schema violation: \($0)"
      } + errors(document, reviewedSHA256: context.reviewedCapabilitySHA256)
    guard problems.isEmpty, let policy = CapabilityPolicy(document) else {
      throw VerificationError.invalid(
        "installed capability policy is rejected: " + problems.joined(separator: "; "))
    }
    return policy
  }

  /// Why `document` is not the reviewed policy that this runtime honors. The repository
  /// validator and the runtime loader share these rules; each checks the shape against
  /// capabilities.schema.json as well.
  static func errors(_ document: [String: Any], reviewedSHA256: String) -> [String] {
    var errors: [String] = []
    let observed = canonicalSHA256(document) ?? "unavailable"
    if observed != reviewedSHA256 {
      errors.append(
        "capability policy is not the reviewed policy (expected sha256 \(reviewedSHA256), observed sha256 \(observed)); after an intended change, set CapabilityPolicy.reviewedSHA256 to the observed digest in the same commit"
      )
    }
    guard let policy = CapabilityPolicy(document) else {
      return errors + [
        "capability policy lacks resource_scopes, max_ttl_seconds or a Spec Kit pinned_release"
      ]
    }
    if policy.maxLeaseTTLSeconds != ResourceCoordinator.maxTTLSeconds {
      errors.append(
        "capability max_ttl_seconds \(policy.maxLeaseTTLSeconds) differs from the coordinator's lease ceiling \(ResourceCoordinator.maxTTLSeconds)"
      )
    }
    if policy.specKitRelease != SpecKitSnapshot.pinnedRelease {
      errors.append(
        "capability Spec Kit pinned_release \(policy.specKitRelease) differs from the snapshot's release \(SpecKitSnapshot.pinnedRelease)"
      )
    }
    let unleasable = policy.resourceScopes.filter { !ResourceCoordinator.resources.contains($0) }
    if !unleasable.isEmpty {
      errors.append(
        "capability resource_scopes name resources the coordinator cannot lease: "
          + unleasable.joined(separator: ", "))
    }
    return errors
  }

  static func canonicalSHA256(_ document: [String: Any]) -> String? {
    var value = document
    value.removeValue(forKey: "$schema")
    return ContractValidation.hash(value)
  }
}
