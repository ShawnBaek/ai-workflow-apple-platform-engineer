import Foundation
import Testing

@testable import AppleVerificationCore

private let hook = GateRunSupport.repositoryRoot.appendingPathComponent(
  "plugin/hooks/pr-gate.sh")

/// Runs the plugin's PreToolUse hook on one Bash command from `cwd` and returns whether it
/// denied the command.
private func denies(_ command: String, cwd: URL) throws -> Bool {
  let input = try JSONSerialization.data(withJSONObject: [
    "cwd": cwd.path, "tool_name": "Bash", "tool_input": ["command": command],
  ])
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [hook.path]
  let stdin = Pipe()
  let stdout = Pipe()
  process.standardInput = stdin
  process.standardOutput = stdout
  try process.run()
  stdin.fileHandleForWriting.write(input)
  try stdin.fileHandleForWriting.close()
  let output = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  return String(decoding: output, as: UTF8.self).contains(#""permissionDecision":"deny""#)
}

/// A repository with one commit, and its HEAD.
private func repository() throws -> (URL, String) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  func git(_ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  _ = try git("init", "-q")
  _ = try git(
    "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-q",
    "--allow-empty", "-m", "fixture")
  return (root, try git("rev-parse", "HEAD"))
}

@Test func publishingAPullRequestNeedsTheReviewedHead() throws {
  let (root, head) = try repository()
  defer { try? FileManager.default.removeItem(at: root) }
  let short = String(head.prefix(7))
  for command in [
    "gh pr create --base main",
    "FOO=1 gh pr edit 3 --body x",
    "git add .\ngh pr ready 5",
    "git commit -m x && git push",
    "git -C \(root.path) push",
    "APE_REVIEWED_HEAD=deadbeef gh pr create",
    "APE_REVIEW_OVERRIDE= gh pr create",
    "cd /tmp && APE_REVIEWED_HEAD=\(short) git push",
  ] {
    #expect(try denies(command, cwd: root), "\(command)")
  }
  for command in [
    "APE_REVIEWED_HEAD=\(short) gh pr create --base main",
    "APE_REVIEWED_HEAD=\(head) git push -u origin feature/x",
    "cd \"\(root.path)\" && APE_REVIEWED_HEAD=\(short) gh pr ready 5",
    "APE_REVIEWED_HEAD=\(short) git -C \(root.path) push -u origin x",
    "APE_REVIEW_OVERRIDE='the user chose to publish without review' gh pr create",
  ] {
    #expect(try !denies(command, cwd: root), "\(command)")
  }
}

@Test func otherCommandsPassTheGate() throws {
  let (root, _) = try repository()
  defer { try? FileManager.default.removeItem(at: root) }
  for command in [
    "ls -la", "gh pr view 5", "gh pr checks 5", "git push origin refs/tags/v2.0",
    "git push --tags", "echo 'how to gh pr create'", "grep -n \"gh pr create\" README.md",
  ] {
    #expect(try !denies(command, cwd: root), "\(command)")
  }
}
