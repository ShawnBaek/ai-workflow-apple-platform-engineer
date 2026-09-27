import Foundation
import Testing

@testable import AppleVerificationCore

private var checkoutRoot: URL { GateRunSupport.repositoryRoot }

private func shipped(_ path: String) throws -> [String: Any] {
  try HarnessRuntime.object(checkoutRoot.appendingPathComponent(path))
}

private func scratchDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func write(_ text: String, to path: String, in root: URL) throws {
  let file = root.appendingPathComponent(path)
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try text.write(to: file, atomically: true, encoding: .utf8)
}

// MARK: - Contract coverage

@Test func everyShippedTemplateAndSchemaIsValidated() throws {
  // The private policy template, the local authorization template and the delivery
  // authorization schema used to ship without any schema pass.
  #expect(ContractValidation.validateContractFiles(root: checkoutRoot) == [])
  for (instance, schema) in ContractValidation.schemaPairs {
    #expect(
      ContractValidation.validatePair(
        root: checkoutRoot, instancePath: instance, schemaPath: schema)
        == [], "\(instance)")
  }

  // A new template, a schema nothing instantiates, a pair that disagrees with the file's own
  // `$schema`, and a contract directory that was never listed are each reported.
  let root = try scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let schema = #"{"type": "object"}"#
  try write(schema, to: "skills/tool/contracts/used.schema.json", in: root)
  try write(schema, to: "skills/tool/contracts/other.schema.json", in: root)
  try write(schema, to: "skills/tool/contracts/unused.schema.json", in: root)
  try write(
    #"{"$schema": "../contracts/other.schema.json"}"#, to: "skills/tool/templates/paired.json",
    in: root)
  try write("{}", to: "skills/tool/templates/unpaired.json", in: root)
  try write("{", to: "skills/new-skill/contracts/broken.json", in: root)
  let errors = ContractValidation.validateContractFiles(
    root: root,
    pairs: [
      (
        "skills/tool/templates/paired.json",
        "skills/tool/contracts/used.schema.json"
      ),
      ("skills/new-skill/contracts/broken.json", "skills/tool/contracts/other.schema.json"),
    ], schemasValidatedElsewhere: [])
  #expect(
    errors.contains(
      "contract instance is not validated against a schema: skills/tool/templates/unpaired.json"))
  #expect(
    errors.contains(
      "contract schema validates no shipped instance or fixture: skills/tool/contracts/unused.schema.json"
    ))
  #expect(
    errors.contains(
      "skills/tool/templates/paired.json declares $schema ../contracts/other.schema.json but is "
        + "validated against skills/tool/contracts/used.schema.json"))
  #expect(errors.contains { $0.hasPrefix("invalid JSON skills/new-skill/contracts/broken.json") })
  #expect(errors.count == 4, "\(errors)")
}

// MARK: - Placeholders

@Test func harnessPathsMustBeAbsoluteSoPlaceholdersFailTheSchema() throws {
  let schema = try shipped("skills/agent-harness/contracts/schemas/harness.schema.json")
  for name in ["harness.json", "harness-local.json"] {
    let template = try shipped("skills/agent-harness/templates/\(name)")
    #expect(JSONSchemaValidator.errors(instance: template, schema: schema) == [], "\(name)")
    // `materialize` validates against this schema, so each of these used to be written into a
    // private harness that only failed later, at the runtime's own absolute-path check.
    for field in [
      "authoritative_root", "xcode_container", "private_policy_overlay", "run_authorization",
      "run_ledger",
    ] {
      for placeholder in ["<absolute-path>", "<local-untracked-path>", "relative/path", "/"] {
        var drifted = template
        drifted[field] = placeholder
        #expect(
          JSONSchemaValidator.errors(instance: drifted, schema: schema).contains {
            $0.hasPrefix("$.\(field):")
          }, "\(name) \(field) \(placeholder)")
      }
    }
  }
}

@Test func policyTemplateStartsInertAndIsAcceptedByTheDefaultLocalHarness() throws {
  let policy = try shipped("skills/agent-harness/templates/private-policy-overlay.json")
  let schema = try shipped(
    "skills/agent-harness/contracts/schemas/private-policy-overlay.schema.json")
  var instance = policy
  instance.removeValue(forKey: "$schema")
  #expect(JSONSchemaValidator.errors(instance: instance, schema: schema) == [])
  // The setup guide materializes the local harness by default. A policy that already named a
  // placeholder GitHub owner failed its health gate until the reader nulled it by hand.
  let local = try shipped("skills/agent-harness/templates/harness-local.json")
  #expect(HealthCollection.trustedPolicyErrors(policy: policy, harness: local) == [])
  // A PR harness stays blocked until the approved owner is filled in.
  let pr = try shipped("skills/agent-harness/templates/harness.json")
  #expect(
    HealthCollection.trustedPolicyErrors(policy: policy, harness: pr) == [
      "private policy overlay GitHub boundary is invalid"
    ])
  var approved = policy
  approved["github"] = ["owner": "example"]
  #expect(HealthCollection.trustedPolicyErrors(policy: approved, harness: pr) == [])
}

// MARK: - Local run authorization

@Test func localRunAuthorizationTemplateIsInertAndMatchesTheLocalHarness() throws {
  let local = try shipped("skills/agent-harness/templates/run-authorization-local.json")
  let pending = try shipped(
    "skills/agent-harness/contracts/schemas/run-authorization.pending.schema.json")
  var instance = local
  instance.removeValue(forKey: "$schema")
  #expect(JSONSchemaValidator.errors(instance: instance, schema: pending) == [])
  #expect(ContractValidation.validatePendingAuthorization(local) == [])
  // The runtime blocks an authorization whose requirements differ from its harness.
  let harness = try shipped("skills/agent-harness/templates/harness-local.json")
  #expect(
    JSONSchemaValidator.equal(
      try #require(local["local_requirements"]), try #require(harness["local_requirements"])))
  // Apart from the target, the templates carry the same inert envelope.
  var pr = try shipped("skills/agent-harness/templates/run-authorization.json")
  for field in ["delivery_target", "health_profile", "local_requirements"] {
    pr[field] = local[field]
  }
  #expect(JSONSchemaValidator.equal(pr, local))

  var unbound = local
  unbound["local_requirements"] = NSNull()
  #expect(
    ContractValidation.validatePendingAuthorization(unbound) == [
      "local run authorization template must bind exact local requirements"
    ])
  var widened = local
  widened["local_requirements"] = [
    "review_required": false, "spec_kit_required": false, "github_required": false,
  ]
  #expect(
    ContractValidation.validatePendingAuthorization(widened) == [
      "local run authorization template must bind exact local requirements"
    ])
  var numeric = local
  numeric["local_requirements"] = ["review_required": 0, "spec_kit_required": 0]
  #expect(
    ContractValidation.validatePendingAuthorization(numeric) == [
      "local run authorization template must bind exact local requirements"
    ])
  var mixed = local
  mixed["health_profile"] = "pr_ready"
  #expect(
    ContractValidation.validatePendingAuthorization(mixed) == [
      "run authorization template must retain an inert pr_ready or local_verified profile"
    ])
  var prWithLocal = try shipped("skills/agent-harness/templates/run-authorization.json")
  prWithLocal["local_requirements"] = local["local_requirements"]
  #expect(
    ContractValidation.validatePendingAuthorization(prWithLocal) == [
      "PR run authorization template cannot bind local requirements"
    ])
  var scoped = local
  scoped["github"] = ["owner": "example"]
  #expect(
    ContractValidation.validatePendingAuthorization(scoped) == [
      "run authorization template must not contain executable identity, authority, or time: github"
    ])
}

@Test func repositoryKeepsEachRunAuthorizationTemplateOnItsOwnTarget() throws {
  let templates = "skills/agent-harness/templates"
  let pr = try shipped("\(templates)/run-authorization.json")
  let local = try shipped("\(templates)/run-authorization-local.json")
  let harness = try shipped("\(templates)/harness-local.json")
  let root = try scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  func errors(pr: [String: Any], local: [String: Any]) throws -> [String] {
    for (name, value) in [
      ("run-authorization.json", pr), ("run-authorization-local.json", local),
      ("harness-local.json", harness),
    ] {
      let data = try JSONSerialization.data(withJSONObject: value)
      try write(String(decoding: data, as: UTF8.self), to: "\(templates)/\(name)", in: root)
    }
    return ContractValidation.validateRunAuthorizationTemplates(root: root).sorted()
  }
  #expect(try errors(pr: pr, local: local) == [])

  // The documented PR template, switched to an otherwise valid local profile, used to pass.
  var drifted = pr
  for field in ["delivery_target", "health_profile", "local_requirements"] {
    drifted[field] = local[field]
  }
  #expect(
    try errors(pr: drifted, local: local) == [
      "PR run authorization template must target pr_ready"
    ])

  // The local template switched to the PR profile.
  var prShaped = local
  for field in ["delivery_target", "health_profile", "local_requirements"] {
    prShaped[field] = pr[field]
  }
  #expect(
    try errors(pr: pr, local: prShaped) == [
      "local run authorization and harness templates bind different requirements",
      "local run authorization template must target local_verified",
    ])

  // The local template requires a review that the local harness template does not.
  var stricter = local
  stricter["local_requirements"] = ["review_required": true, "spec_kit_required": false]
  #expect(
    try errors(pr: pr, local: stricter) == [
      "local run authorization and harness templates bind different requirements"
    ])
}

// MARK: - Digest spelling

@Test func digestFieldsKeepOneSpellingEachAndNewFieldsTakeThePrefix() throws {
  let shippedSchemas = Set(ContractValidation.schemaPairs.map(\.schema))
    .union(ContractValidation.schemasValidatedElsewhere)
  #expect(
    ContractValidation.validateDigestSpelling(root: checkoutRoot, schemas: shippedSchemas.sorted())
      == [])

  let root = try scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let path = "skills/tool/contracts/record.schema.json"
  try write(
    #"""
    {"type": "object", "properties": {
      "report_sha256": {"type": "string", "pattern": "^sha256:[0-9a-f]{64}$"},
      "file_sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
      "new_sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
      "items": {"type": "array", "items": {"type": "object", "properties": {
        "upper_sha256": {"type": "string", "pattern": "^[0-9A-Fa-f]{64}$"}}}},
      "hashes": {"type": "object", "additionalProperties": {"pattern": "^sha256-[0-9a-f]{64}$"}},
      "commit": {"type": "string", "pattern": "^[0-9a-f]{40,64}$"}
    }}
    """#, to: path, in: root)
  let errors = ContractValidation.validateDigestSpelling(
    root: root, schemas: [path], bareHex: [path: ["file_sha256", "retired_sha256"]])
  #expect(
    errors.sorted() == [
      "bare-hex digest exception is stale: retired_sha256 in \(path)",
      "digest field hashes in \(path) has a non-canonical pattern ^sha256-[0-9a-f]{64}$",
      "digest field new_sha256 in \(path) must use the sha256: prefix",
      "digest field upper_sha256 in \(path) has a non-canonical pattern ^[0-9A-Fa-f]{64}$",
    ])
}

// MARK: - IconGen watcher workflow

@Test func watcherAcceptsAReviewedImageOrCheckoutBumpButNoWiderAction() throws {
  let shippedWorkflow = checkoutRoot.appendingPathComponent(
    ".github/workflows/icongen-upstream-watch.yml")
  let text = try String(contentsOf: shippedWorkflow, encoding: .utf8)
  let root = try scratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  func errors(_ replacements: [(String, String)]) throws -> [String] {
    var drifted = text
    for (old, new) in replacements {
      #expect(drifted.contains(old), "\(old)")
      drifted = drifted.replacingOccurrences(of: old, with: new)
    }
    let workflow = root.appendingPathComponent("\(UUID().uuidString).yml")
    try drifted.write(to: workflow, atomically: true, encoding: .utf8)
    return ContractValidation.validateIconGenWorkflow(at: workflow)
  }
  let checkout = try #require(
    ContractValidation.captures(text, #"uses: actions/checkout@([0-9a-f]{40})"#).first)
  let bumped = String(repeating: "c", count: 40)

  // A runner-image, timeout or checkout-commit bump is a reviewed workflow change, not a
  // Swift edit; before, each of these failed repository validation.
  #expect(
    try errors([
      ("runs-on: macos-15", "runs-on: macos-26"), ("timeout-minutes: 15", "timeout-minutes: 20"),
      (checkout, bumped),
    ]) == [])

  let runner = ["IconGen watcher must run on one named hosted macOS image"]
  #expect(try errors([("runs-on: macos-15", "runs-on: macos-latest")]) == runner)
  #expect(try errors([("runs-on: macos-15", "runs-on: [self-hosted, macOS]")]) == runner)
  let timeout = ["IconGen watcher job needs one timeout of at most 30 minutes"]
  #expect(try errors([("    timeout-minutes: 15\n", "")]) == timeout)
  #expect(try errors([("timeout-minutes: 15", "timeout-minutes: 360")]) == timeout)
  let action = ["IconGen watcher may use only actions/checkout pinned to a full commit SHA"]
  #expect(try errors([(checkout, "v4")]) == action)
  // A step spelled `- uses:` used to escape the action allowlist entirely.
  #expect(
    try errors([
      (
        "      - name: Build the Swift verifier\n",
        "      - uses: example/other-action@\(bumped)\n      - name: Build the Swift verifier\n"
      )
    ]) == action)
}

// MARK: - Skill description budget

private func entryPoint(_ description: String, lineBreak: String = "\n") -> String {
  ["---", "name: example", "description: \(description)", "---", "# Example", ""]
    .joined(separator: lineBreak)
}

@Test func descriptionBudgetMeasuresCRLFFilesAndQuotedScalarsAsListed() {
  let path = "skills/example/SKILL.md"
  func measured(_ text: String) -> String? {
    SkillDescriptionBudget.descriptions(in: [path: text])[path]
  }
  let over = String(repeating: "a", count: 301)
  // A CRLF file was skipped unmeasured, so an over-long description passed.
  #expect(measured(entryPoint(over, lineBreak: "\r\n")) == over)
  #expect(
    SkillDescriptionBudget.validate(texts: [path: entryPoint(over, lineBreak: "\r\n")]) == [
      "Skill description has 301 characters, over 300; keep what it does, one 'Use when' "
        + "clause and any 'Not for' route: \(path)"
    ])
  #expect(
    measured(entryPoint(">-\r\n  Folded\r\n  text", lineBreak: "\r\n")) == "Folded text")

  // Quotes are YAML syntax, not listed text; a 300-character quoted description fits.
  let limit = String(repeating: "b", count: 300)
  #expect(measured(entryPoint("\"\(limit)\"")) == limit)
  #expect(SkillDescriptionBudget.validate(texts: [path: entryPoint("'\(limit)'")]) == [])
  #expect(measured(entryPoint("'It''s quoted' # note")) == "It's quoted")
  #expect(
    measured(entryPoint(#""Say \"hi\"\tthen é and \\ end""#)) == "Say \"hi\"\tthen é and \\ end")
  #expect(measured(entryPoint("\"Folded across\n  two lines\"")) == "Folded across two lines")
  // Unquoted text and an unterminated quote are measured as written.
  #expect(measured(entryPoint("Plain 'inner' text")) == "Plain 'inner' text")
  #expect(measured(entryPoint("\"Unterminated")) == "\"Unterminated")
}
