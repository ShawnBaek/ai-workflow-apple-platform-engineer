import Foundation
import Testing

@testable import AppleVerificationCore

private func deliveryContext() -> RuntimeContext {
  let harness = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  return RuntimeContext(
    repositoryRoot: harness.deletingLastPathComponent().deletingLastPathComponent(),
    harnessRoot: harness)
}

@Test func completionPreviewPreservesFactsAndRejectsFalseUsage() throws {
  let context = deliveryContext()
  var report = try HarnessRuntime.object(
    context.harnessRoot.appendingPathComponent("templates/completion-report.json"))
  report["task"] = "Verify a local preview"
  report["changes"] = ["Fixed the title alignment"]
  report["checks"] = [
    [
      "name": "coordinate fixture", "result": "passed",
      "summary": "2.5 pt horizontal delta remains visible",
    ]
  ]
  let text = try DeliveryReport.render(report, context: context)
  #expect(text.contains("Verify a local preview"))
  #expect(text.contains("Fixed the title alignment"))
  #expect(text.contains("coordinate fixture: passed"))
  #expect(text.contains("not exposed"))
  var usage = report["usage"] as! [String: Any]
  usage["status"] = "full"
  usage["missing_sources"] = []
  usage["source_records"] = [
    "source": [
      "provider": "test", "input_tokens": 0, "output_tokens": 0, "cached_input_tokens": 0,
      "reasoning_tokens": 0,
    ]
  ]
  usage["attribution"] = [
    ["agent_id": "reviewer", "session_id": "session", "model": "fixture", "source_ids": ["source"]]
  ]
  usage["cross_provider_total"] = [
    "input_tokens": 0, "output_tokens": 0,
    "label": "informational; cached input and reasoning are subsets, not added",
  ]
  report["usage"] = usage
  #expect(try DeliveryReport.render(report, context: context).contains("input 0, output 0"))
  usage["cross_provider_total"] = [
    "input_tokens": 1, "output_tokens": 0,
    "label": "informational; cached input and reasoning are subsets, not added",
  ]
  report["usage"] = usage
  #expect(throws: VerificationError.self) { try DeliveryReport.render(report, context: context) }
  usage["attribution"] = [
    [
      "agent_id": "reviewer", "session_id": "session", "model": "fixture",
      "source_ids": ["source", "source"],
    ]
  ]
  report["usage"] = usage
  #expect(throws: VerificationError.self) { try DeliveryReport.render(report, context: context) }
}

@Test func deliveryAuthorizationBindsBytesExpiryAndWhatsAppRequest() throws {
  let context = deliveryContext()
  let now = Date()
  let rendered = "# Fixture completion\n"
  var authorization: [String: Any] = [
    "schema_version": "1.0.0", "decision": "approved", "authorization_id": "auth-123",
    "run_id": "run-123", "issued_at": HarnessRuntime.timestamp(now.addingTimeInterval(-60)),
    "expires_at": HarnessRuntime.timestamp(now.addingTimeInterval(60)), "channel_id": "updates",
    "channel_kind": "telegram", "destination_ref": "private.team",
    "report_sha256": HarnessRuntime.sha256(Data(rendered.utf8)), "media_allowlist": [] as [Any],
    "transport_ref": "bot-api", "idempotency_key": "send-123", "single_use": true,
    "whatsapp_mode": NSNull(), "whatsapp_template_ref": NSNull(),
    "whatsapp_template_language": NSNull(), "whatsapp_request_sha256": NSNull(),
    "cost_approval": "not_applicable",
  ]
  try DeliveryReport.validateAuthorization(
    authorization, rendered: rendered, channel: "telegram", channelID: "updates",
    destination: "private.team", context: context, now: now)
  #expect(throws: VerificationError.self) {
    try DeliveryReport.validateAuthorization(
      authorization, rendered: rendered + "changed", channel: "telegram", channelID: "updates",
      destination: "private.team", context: context, now: now)
  }
  #expect(throws: VerificationError.self) {
    try DeliveryReport.validateAuthorization(
      authorization, rendered: rendered, channel: "telegram", channelID: "updates",
      destination: "private.team", context: context, now: now.addingTimeInterval(120))
  }
  authorization["channel_kind"] = "whatsapp"
  authorization["transport_ref"] = "cloud-api"
  authorization["whatsapp_mode"] = "approved_template"
  authorization["whatsapp_template_ref"] = "private.template"
  authorization["whatsapp_template_language"] = "en_US"
  authorization["whatsapp_request_sha256"] = String(repeating: "a", count: 64)
  authorization["cost_approval"] = "approved_for_this_send"
  #expect(throws: VerificationError.self) {
    try DeliveryReport.validateAuthorization(
      authorization, rendered: rendered, channel: "whatsapp", channelID: "updates",
      destination: "private.team", whatsappRequestSHA256: String(repeating: "b", count: 64),
      context: context, now: now)
  }
  try DeliveryReport.validateAuthorization(
    authorization, rendered: rendered, channel: "whatsapp", channelID: "updates",
    destination: "private.team", whatsappRequestSHA256: String(repeating: "a", count: 64),
    context: context, now: now)
}

private final class CompanionFixture: CompanionGitHubClient {
  var calls = [(String, String)]()
  var observed = String(repeating: "a", count: 40)
  var publicRepository = true
  var duplicateIssues = false
  var writeCount = 0
  var consumerRepository = "example/consumer"
  func request(method: String, path: String, body: [String: Any]?) throws -> Any {
    calls.append((method, path))
    if method != "GET" {
      writeCount += 1
      return ["html_url": "https://github.com/\(consumerRepository)/issues/1"]
    }
    if path == "repos/example/upstream" {
      return [
        "private": !publicRepository, "visibility": publicRepository ? "public" : "private",
        "default_branch": "main",
      ]
    }
    if path.hasSuffix("/commits/main") { return ["sha": observed] }
    if path.contains("/commits/") {
      return [
        "sha": String(repeating: "a", count: 40),
        "commit": ["tree": ["sha": String(repeating: "b", count: 40)]],
      ]
    }
    if path.contains("/git/trees/") {
      return [
        "truncated": false,
        "tree": [["type": "blob", "path": "README.md", "sha": String(repeating: "c", count: 40)]],
      ]
    }
    if path.contains("/issues?") {
      let issue: [String: Any] = [
        "number": 1, "body": "<!-- ios-experts-companion-upstream:example/upstream -->",
      ]
      return duplicateIssues ? [issue, issue] : [] as [[String: Any]]
    }
    throw VerificationError.invalid("Unexpected fixture operation")
  }
}

@Test func companionWatcherChecksProvenanceBeforeAnyIssueWrite() throws {
  let manifest: [String: Any] = [
    "upstream": [
      "repository": "example/upstream", "visibility": "public", "default_branch": "main",
      "reviewed_revision": String(repeating: "a", count: 40),
      "reviewed_tree": String(repeating: "b", count: 40),
    ],
    "integration": [
      "consumer_repository": "example/consumer", "consumer_skill": "icon-composer",
      "mode": "reference-only", "execute_upstream": false, "auto_merge": false,
      "vendored_files": [],
    ], "sources": [["path": "README.md", "blob_sha": String(repeating: "c", count: 40)]],
    "license": ["status": "review_required"],
  ]
  let fixture = CompanionFixture()
  let unchanged = try CompanionWatcher.reconcileIssue(
    manifest, targetRepository: "example/consumer", client: fixture)
  #expect(unchanged["issue_action"] as? String == "none")
  #expect(fixture.writeCount == 0)
  fixture.publicRepository = false
  fixture.observed = String(repeating: "d", count: 40)
  #expect(throws: VerificationError.self) {
    try CompanionWatcher.reconcileIssue(
      manifest, targetRepository: "example/consumer", client: fixture)
  }
  #expect(fixture.writeCount == 0)
  fixture.publicRepository = true
  let changed = try CompanionWatcher.reconcileIssue(
    manifest, targetRepository: "example/consumer", client: fixture)
  #expect(changed["issue_action"] as? String == "created")
  #expect(fixture.writeCount == 1)
  fixture.duplicateIssues = true
  #expect(throws: VerificationError.self) {
    try CompanionWatcher.reconcileIssue(
      manifest, targetRepository: "example/consumer", client: fixture)
  }
  #expect(fixture.writeCount == 1)
}

@Test func shippedCompanionTargetsRenamedRepositoryAndRejectsOldTarget() throws {
  var manifest = try HarnessRuntime.object(
    deliveryContext().repositoryRoot.appendingPathComponent(
      "skills/icon-composer/contracts/companion-upstream.json"))
  #expect(ContractValidation.validateCompanionUpstream(manifest).isEmpty)
  // Keep the shipped consumer binding; upstream responses are isolated fixtures.
  manifest["upstream"] = [
    "repository": "example/upstream", "visibility": "public", "default_branch": "main",
    "reviewed_revision": String(repeating: "a", count: 40),
    "reviewed_tree": String(repeating: "b", count: 40),
  ]
  manifest["sources"] = [["path": "README.md", "blob_sha": String(repeating: "c", count: 40)]]
  let fixture = CompanionFixture()
  fixture.consumerRepository = "ShawnBaek/ai-workflow-apple-platform-engineer"
  fixture.observed = String(repeating: "d", count: 40)
  let result = try CompanionWatcher.reconcileIssue(
    manifest, targetRepository: fixture.consumerRepository, client: fixture)
  #expect(result["issue_action"] as? String == "created")
  #expect(result["issue_url"] as? String == "https://github.com/\(fixture.consumerRepository)/issues/1")
  #expect(fixture.calls.contains { $0 == ("POST", "repos/\(fixture.consumerRepository)/issues") })
  #expect(fixture.writeCount == 1)
  fixture.calls.removeAll()
  #expect(throws: VerificationError.self) {
    try CompanionWatcher.reconcileIssue(
      manifest, targetRepository: "ShawnBaek/iOS-experts", client: fixture)
  }
  #expect(fixture.calls.isEmpty)
  #expect(fixture.writeCount == 1)
}
