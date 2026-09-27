import Darwin
import Foundation

extension Authorization {
  public static func observeRepository(_ root: URL, expectedBaseSHA: String) throws -> [String: Any]
  {
    guard !isSymlink(root) else {
      throw VerificationError.invalid("authoritative repository root cannot be a symlink")
    }
    let canonical = root.resolvingSymlinksInPath().standardizedFileURL
    func git(_ arguments: [String]) throws -> String {
      let result = try HarnessRuntime.run(
        executable: "/usr/bin/git", arguments: ["-C", canonical.path] + arguments, timeout: 15)
      guard result.exitCode == 0, !result.timedOut, !result.truncated else {
        throw VerificationError.invalid("Git observation failed: \(arguments.first ?? "command")")
      }
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard
      URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"])).resolvingSymlinksInPath()
        == canonical
    else { throw VerificationError.invalid("authoritative root is not the exact Git top level") }
    let rawRemote = try git(["remote", "get-url", "origin"])
    _ = try normalizeGitHubRemote(rawRemote)
    let branch = try git(["branch", "--show-current"])
    guard !branch.isEmpty else {
      throw VerificationError.invalid("authoritative repository is in detached HEAD state")
    }
    guard
      (try? HarnessRuntime.run(
        executable: "/usr/bin/git",
        arguments: ["-C", canonical.path, "cat-file", "-e", "\(expectedBaseSHA)^{commit}"],
        timeout: 15
      ).exitCode) == 0
    else { throw VerificationError.invalid("authorized base SHA is unavailable") }
    guard
      (try? HarnessRuntime.run(
        executable: "/usr/bin/git",
        arguments: ["-C", canonical.path, "merge-base", "--is-ancestor", expectedBaseSHA, "HEAD"],
        timeout: 15
      ).exitCode) == 0
    else {
      throw VerificationError.invalid("authorized base SHA is not an ancestor of current HEAD")
    }
    // Rename detection would report only the destination, hiding the source path from the
    // path checks; list both sides, as the patch manifest below already does.
    let stagedPaths = try nulList(
      canonical, ["diff", "--cached", "--name-only", "-z", "--no-renames"])
    let outgoingPaths = try nulList(
      canonical, ["diff", "--name-only", "-z", "--no-renames", "\(expectedBaseSHA)..HEAD"])
    let stagedManifest = try gitPatchManifest(
      root: canonical, baseSHA: expectedBaseSHA, revision: "INDEX", staged: true)
    let headManifest = try gitPatchManifest(
      root: canonical, baseSHA: expectedBaseSHA, revision: "HEAD", staged: false)
    let stagedDiff = try gitData(canonical, ["diff", "--cached", "--binary"])
    return [
      "fingerprint": try repositoryFingerprint(rawRemote), "canonical_root": canonical.path,
      "remote": sanitizeRemote(rawRemote),
      "base_sha": expectedBaseSHA, "branch": branch, "head_sha": try git(["rev-parse", "HEAD"]),
      "staged_paths": stagedPaths, "staged_diff_sha256": HarnessRuntime.sha256(stagedDiff),
      "outgoing_paths": outgoingPaths,
      "staged_patch_manifest": stagedManifest,
      "staged_patch_identity": (stagedManifest["records"] as? [Any])?.isEmpty == false
        ? try patchIdentityV1(stagedManifest) : NSNull(),
      "head_patch_manifest": headManifest,
      "head_patch_identity": (headManifest["records"] as? [Any])?.isEmpty == false
        ? try patchIdentityV1(headManifest) : NSNull(),
    ]
  }

  private static func gitPatchManifest(root: URL, baseSHA: String, revision: String, staged: Bool)
    throws -> [String: Any]
  {
    guard sha(baseSHA) else {
      throw VerificationError.invalid("patch base must be one exact full commit SHA")
    }
    let tokens = try nulList(
      root,
      staged
        ? ["diff", "--cached", "--name-status", "-z", "--no-renames", baseSHA]
        : ["diff", "--name-status", "-z", "--no-renames", "\(baseSHA)..\(revision)"])
    guard tokens.count % 2 == 0 else {
      throw VerificationError.invalid("Git patch name-status stream is malformed")
    }
    var records: [[String: Any]] = []
    for index in stride(from: 0, to: tokens.count, by: 2) {
      let status = tokens[index]
      let path = tokens[index + 1]
      guard ["A", "D", "M", "T"].contains(status), safeRelativePath(path) else {
        throw VerificationError.invalid("Git patch contains an unsupported status or path")
      }
      if status == "D" {
        records.append([
          "path": path, "mode": try gitMode(root, revision: baseSHA, path: path, staged: false).0,
          "state": "deleted", "content_sha256": "deleted",
        ])
        continue
      }
      let (mode, object) = try gitMode(root, revision: revision, path: path, staged: staged)
      let content =
        mode == "160000" ? Data(object.utf8) : try gitData(root, ["cat-file", "blob", object])
      records.append([
        "path": path, "mode": mode,
        "state": mode == "120000" ? "symlink" : status == "A" ? "added" : "modified",
        "content_sha256": "sha256:" + HarnessRuntime.sha256(content),
      ])
    }
    let sortedRecords = records.sorted { lhs, rhs in
      (lhs["path"] as! String).utf8.lexicographicallyPrecedes((rhs["path"] as! String).utf8)
    }
    return ["version": "patch_identity_v1", "base_sha": baseSHA, "records": sortedRecords]
  }

  private static func gitMode(_ root: URL, revision: String, path: String, staged: Bool) throws -> (
    String, String
  ) {
    let data = try gitData(
      root,
      staged ? ["ls-files", "--stage", "-z", "--", path] : ["ls-tree", "-z", revision, "--", path])
    let entries = data.split(separator: 0)
    guard entries.count == 1, let line = String(data: entries[0], encoding: .utf8),
      let tab = line.firstIndex(of: "\t")
    else { throw VerificationError.invalid("Git patch path has no unique entry") }
    let metadata = line[..<tab].split(separator: " ").map(String.init)
    guard metadata.count >= 3 else {
      throw VerificationError.invalid("Git patch metadata is malformed")
    }
    return (metadata[0], staged ? metadata[1] : metadata[2])
  }
  private static func nulList(_ root: URL, _ arguments: [String]) throws -> [String] {
    try gitData(root, arguments).split(separator: 0).map {
      guard let value = String(data: $0, encoding: .utf8) else { return "\0" }
      return value
    }
  }
  private static func gitData(_ root: URL, _ arguments: [String]) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    process.standardOutput = pipe
    process.standardError = errorPipe
    try process.run()
    let outputFD = pipe.fileHandleForReading.fileDescriptor
    let errorFD = errorPipe.fileHandleForReading.fileDescriptor
    _ = fcntl(outputFD, F_SETFL, O_NONBLOCK)
    _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
    var output = Data()
    var errors = Data()
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    let limit = 64 * 1024 * 1024
    func drain(_ descriptor: Int32, into data: inout Data) throws {
      while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
          guard data.count + count <= limit else {
            throw VerificationError.invalid("Git output exceeded 64 MiB")
          }
          data.append(contentsOf: buffer.prefix(count))
          continue
        }
        if count < 0 && errno == EINTR { continue }
        break
      }
    }
    while process.isRunning {
      try drain(outputFD, into: &output)
      try drain(errorFD, into: &errors)
      if ProcessInfo.processInfo.systemUptime >= deadline {
        process.terminate()
        process.waitUntilExit()
        throw VerificationError.invalid("Git command timed out")
      }
      usleep(10_000)
    }
    process.waitUntilExit()
    try drain(outputFD, into: &output)
    try drain(errorFD, into: &errors)
    guard process.terminationStatus == 0 else {
      throw VerificationError.invalid("Git command failed")
    }
    return output
  }
}
