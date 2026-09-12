import Foundation

public protocol CompanionGitHubClient {
  func request(method: String, path: String, body: [String: Any]?) throws -> Any
}

/// Reference-only provenance tracking; never fetches or executes upstream source.
public enum CompanionWatcher {
  private static let markerPrefix = "<!-- ios-experts-companion-upstream:"
  public static func loadManifest(_ url: URL) throws -> [String: Any] {
    let manifest = try HarnessRuntime.object(url)
    try validateManifest(manifest)
    return manifest
  }
  private static func validateManifest(_ manifest: [String: Any]) throws {
    guard let upstream = manifest["upstream"] as? [String: Any],
      upstream["visibility"] as? String == "public",
      let repository = upstream["repository"] as? String, validRepository(repository),
      let integration = manifest["integration"] as? [String: Any],
      integration["mode"] as? String == "reference-only",
      JSONSchemaValidator.equal(integration["execute_upstream"] ?? NSNull(), false),
      JSONSchemaValidator.equal(integration["auto_merge"] ?? NSNull(), false),
      (integration["vendored_files"] as? [Any])?.isEmpty == true,
      let consumer = integration["consumer_repository"] as? String, validRepository(consumer),
      validSHA(upstream["reviewed_revision"]), validSHA(upstream["reviewed_tree"]),
      let branch = upstream["default_branch"] as? String, !branch.isEmpty,
      let sources = manifest["sources"] as? [[String: Any]], !sources.isEmpty,
      sources.allSatisfy({ ($0["path"] as? String)?.isEmpty == false && validSHA($0["blob_sha"]) }),
      manifest["license"] is [String: Any]
    else {
      throw VerificationError.invalid(
        "Companion manifest requires public reference-only provenance and exact revisions; execution, vendoring, and auto-merge are forbidden"
      )
    }
  }
  public static func compare(_ manifest: [String: Any], observedRevision: String) throws -> [String:
    Any]
  {
    try validateManifest(manifest)
    guard validSHA(observedRevision), let upstream = manifest["upstream"] as? [String: Any],
      let reviewed = upstream["reviewed_revision"] as? String,
      let repository = upstream["repository"] as? String
    else {
      throw VerificationError.invalid("Companion comparison requires exact commit identities")
    }
    let changed = reviewed != observedRevision
    return [
      "repository": repository, "reviewed_revision": reviewed,
      "observed_revision": observedRevision, "changed": changed,
      "action": changed ? "create_or_update_review_issue" : "none",
      "copy_or_execute_upstream": false, "auto_merge": false,
    ]
  }
  public static func reconcileIssue(
    _ manifest: [String: Any], targetRepository: String, client: any CompanionGitHubClient
  ) throws -> [String: Any] {
    try validateManifest(manifest)
    guard let upstream = manifest["upstream"] as? [String: Any],
      let repository = upstream["repository"] as? String, validRepository(repository),
      let integration = manifest["integration"] as? [String: Any],
      targetRepository == integration["consumer_repository"] as? String,
      validRepository(targetRepository)
    else { throw VerificationError.invalid("Issue target does not match pinned consumer") }
    func object(_ path: String) throws -> [String: Any] {
      guard let value = try client.request(method: "GET", path: path, body: nil) as? [String: Any]
      else { throw VerificationError.invalid("GitHub response must be an object") }
      return value
    }
    let metadata = try object("repos/\(repository)")
    guard JSONSchemaValidator.equal(metadata["private"] ?? NSNull(), false),
      metadata["visibility"] as? String == "public",
      metadata["default_branch"] as? String == upstream["default_branch"] as? String
    else { throw VerificationError.invalid("Upstream visibility or default branch drifted") }
    let reviewed = upstream["reviewed_revision"] as! String
    let reviewedTree = upstream["reviewed_tree"] as! String
    let commit = try object("repos/\(repository)/commits/\(reviewed)")
    guard commit["sha"] as? String == reviewed,
      ((commit["commit"] as? [String: Any])?["tree"] as? [String: Any])?["sha"] as? String
        == reviewedTree
    else { throw VerificationError.invalid("Reviewed upstream commit/tree drifted") }
    let tree = try object("repos/\(repository)/git/trees/\(reviewedTree)?recursive=1")
    guard JSONSchemaValidator.equal(tree["truncated"] ?? NSNull(), false),
      let entries = tree["tree"] as? [[String: Any]],
      entries.count == Set(entries.compactMap { $0["path"] as? String }).count
    else { throw VerificationError.invalid("Reviewed upstream tree is incomplete") }
    for source in manifest["sources"] as! [[String: Any]] {
      let matches = entries.filter {
        $0["type"] as? String == "blob" && $0["path"] as? String == source["path"] as? String
          && $0["sha"] as? String == source["blob_sha"] as? String
      }
      guard matches.count == 1 else {
        throw VerificationError.invalid("Reviewed source blob drifted")
      }
    }
    let branch = upstream["default_branch"] as! String
    let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let current = try object("repos/\(repository)/commits/\(encodedBranch)")
    guard let observed = current["sha"] as? String, validSHA(observed) else {
      throw VerificationError.invalid("Upstream HEAD did not resolve to a full SHA")
    }
    var result = try compare(manifest, observedRevision: observed)
    guard result["changed"] as? Bool == true else {
      result["issue_action"] = "none"
      return result
    }
    var issues = [[String: Any]]()
    var finished = false
    for page in 1...10 {
      guard
        let batch = try client.request(
          method: "GET",
          path: "repos/\(targetRepository)/issues?state=open&per_page=100&page=\(page)", body: nil)
          as? [[String: Any]]
      else { throw VerificationError.invalid("GitHub issue page is malformed") }
      issues += batch
      if batch.count < 100 {
        finished = true
        break
      }
    }
    guard finished else {
      throw VerificationError.invalid("Too many open issues to reconcile safely")
    }
    let marker = "\(markerPrefix)\(repository) -->"
    let existing = issues.filter {
      $0["pull_request"] == nil && ($0["body"] as? String ?? "").contains(marker)
    }
    guard existing.count <= 1 else {
      throw VerificationError.invalid(
        "Multiple issues match the companion marker; resolve the duplicate before retrying")
    }
    let sources = (manifest["sources"] as! [[String: Any]]).map { "- `\($0["path"]!)`" }.joined(
      separator: "\n")
    let body = """
      \(marker)

      The public reference-only companion upstream changed.

      - Upstream: `https://github.com/\(repository)`
      - Branch: `\(branch)`
      - Last reviewed: `\(reviewed)`
      - Observed: `\(observed)`
      - Compare: `https://github.com/\(repository)/compare/\(reviewed)...\(observed)`
      - License state: `\((manifest["license"] as! [String: Any])["status"] ?? "unknown")`
      - Consumer: `\(integration["consumer_skill"] ?? "unknown")`

      Review surface:
      \(sources)

      Review the exact commit and re-express only general Apple-icon guidance.
      Do not copy or execute upstream code, assets, or prose. Update provenance,
      run focused contract checks, and use the normal PR workflow. Auto-merge
      and changes to the upstream repository are out of scope.
      """
    let payload: [String: Any] = [
      "title": "Review IconGen upstream \(observed.prefix(12))", "body": body,
    ]
    let response: Any
    if let existing = existing.first {
      guard let number = existing["number"] as? Int, number > 0 else {
        throw VerificationError.invalid("Existing issue number is malformed")
      }
      response = try client.request(
        method: "PATCH", path: "repos/\(targetRepository)/issues/\(number)", body: payload)
      result["issue_action"] = "updated"
    } else {
      response = try client.request(
        method: "POST", path: "repos/\(targetRepository)/issues", body: payload)
      result["issue_action"] = "created"
    }
    guard let response = response as? [String: Any], let url = response["html_url"] as? String,
      url.hasPrefix("https://github.com/\(targetRepository)/issues/")
    else {
      throw VerificationError.invalid(
        "Issue mutation returned an uncertain result; inspect the marker before retrying")
    }
    result["issue_url"] = url
    return result
  }
  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    // Preserve the legacy ordering: --manifest <file> check|sync-issue ...
    guard arguments.count >= 3, arguments[0] == "--manifest" else {
      throw VerificationError.invalid("companion requires --manifest <file> check|sync-issue")
    }
    let manifest = try loadManifest(URL(fileURLWithPath: arguments[1]))
    let command = arguments[2]
    let args = try RuntimeArguments(Array(arguments.dropFirst(3)))
    let result: [String: Any]
    switch command {
    case "check":
      try args.allow(["--observed-revision"])
      result = try compare(manifest, observedRevision: args.required("--observed-revision"))
    case "sync-issue":
      try args.allow(["--target-repository"])
      result = try reconcileIssue(
        manifest, targetRepository: args.required("--target-repository"),
        client: GitHubCLICompanionClient())
    default: throw VerificationError.invalid("Unknown companion command")
    }
    FileHandle.standardOutput.write(try HarnessRuntime.canonicalJSON(result))
    print()
    return 0
  }
  private static func validRepository(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression)
      != nil
  }
  private static func validSHA(_ raw: Any?) -> Bool {
    (raw as? String)?.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
  }
}

public struct GitHubCLICompanionClient: CompanionGitHubClient {
  private let environment: [String: String]
  public init() throws {
    var environment = ProcessInfo.processInfo.environment
    guard let token = environment["GITHUB_TOKEN"], !token.isEmpty else {
      throw VerificationError.invalid("GITHUB_TOKEN is required for issue reconciliation")
    }
    environment["GH_TOKEN"] = token
    self.environment = environment
  }
  public func request(method: String, path: String, body: [String: Any]?) throws -> Any {
    guard ["GET", "POST", "PATCH"].contains(method), path.hasPrefix("repos/"), !path.contains(".."),
      !path.contains("://")
    else { throw VerificationError.invalid("Invalid companion API operation") }
    var args = [
      "api", "--hostname", "github.com", "--method", method, path, "-H",
      "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28",
    ]
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "apple-companion-\(UUID().uuidString).json")
    defer { if body != nil { try? FileManager.default.removeItem(at: file) } }
    if let body {
      try HarnessRuntime.atomicWriteJSON(body, to: file)
      args += ["--input", file.path]
    }
    let result = try HarnessRuntime.run(
      executable: "gh", arguments: args, environment: environment, timeout: 20,
      maxOutputBytes: 8 * 1_024 * 1_024)
    guard result.exitCode == 0, !result.timedOut, !result.truncated else {
      throw VerificationError.invalid(
        "GitHub companion request failed or returned incomplete data; inspect remote state before retrying a mutation"
      )
    }
    return try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
  }
}
