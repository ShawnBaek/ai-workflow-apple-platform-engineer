import Foundation
import Testing

@testable import AppleVerificationCore

private let hook = GateRunSupport.repositoryRoot.appendingPathComponent(
  "plugin/hooks/pr-gate.sh")

/// A compile cache shared by the tests, so the gate is built once.
private let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
  "pr-gate-tests-\(ProcessInfo.processInfo.processIdentifier)")

/// Runs the plugin's PreToolUse hook on one Bash command from `cwd` and returns whether it
/// denied the command.
private func denies(_ command: String, cwd: URL) throws -> Bool {
  try denies(
    input: try JSONSerialization.data(withJSONObject: [
      "cwd": cwd.path, "tool_name": "Bash", "tool_input": ["command": command],
    ]))
}

private func denies(input: Data) throws -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [hook.path]
  var environment = ProcessInfo.processInfo.environment
  environment["CLAUDE_PLUGIN_DATA"] = cache.path
  process.environment = environment
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

/// A repository whose path has a space: tag `v2.0` and branch `other` on the first commit,
/// HEAD on a second. Returns the folder, HEAD and `other`.
private func repository() throws -> (URL, String, String) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(UUID().uuidString)/repo with space"
  ).resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  @discardableResult
  func git(_ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      ["-C", root.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com"]
      + arguments
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  try git("init", "-q")
  try git("commit", "-q", "--allow-empty", "-m", "one")
  try git("tag", "v2.0")
  try git("branch", "other")
  try git("commit", "-q", "--allow-empty", "-m", "two")
  try git("branch", "feature")
  return (root, try git("rev-parse", "HEAD"), try git("rev-parse", "other"))
}

@Test func publishingAPullRequestNeedsTheReviewedHead() throws {
  let (root, head, other) = try repository()
  defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
  let short = String(head.prefix(7))
  let path = root.path
  for command in [
    "gh pr create --base main",
    "FOO=1 gh pr ready 3",
    "gh pr edit 3 --base main",
    "git add .\ngh pr ready 5",
    "git commit -m x && git push",
    "git -C \"\(path)\" push",
    "git push origin feature && git push --tags",
    "git push --follow-tags",
    "APE_REVIEWED_HEAD=deadbeef gh pr create",
    "APE_REVIEWED_HEAD=\(short) git push origin other",
    "cd /tmp && APE_REVIEWED_HEAD=\(short) git push",
    "APE_REVIEW_OVERRIDE= gh pr create",
    "gh pr create --body \"APE_REVIEW_OVERRIDE=none was not used\"",
    "sh -c \"gh pr create\"", "bash -c 'git push'", "{ git push; }",
    "if true; then gh pr create; fi", "env gh pr create", "command git push",
    "gh -R owner/repo pr create", "git -c key=value push", "git --no-pager push",
    "git push -u origin feature 2>&1", "URL=\"$(gh pr create --fill)\"", "echo `gh pr create`",
    "URL=$(gh pr create)", "if git push origin feature; then echo ok; fi",
    "while ! git push; do sleep 1; done", "eval \"git push origin feature\"", "xargs git push",
    "timeout 60 git push", "sudo git push", "env -i gh pr create", "time -p git push",
    "git push origin v2.0:refs/heads/feature",
    "git push --prune origin 'refs/heads/*:refs/heads/*'",
    "git push --all", "gh pr create --title 'x' # comment", "gh pr create --title 'x",
    "cat > body.md <<'X'\nWe don't need a migration.\nX\ngh pr create --body-file body.md",
    "APE_REVIEWED_HEAD=\(short) gh pr create --body \"$(cat <<'X'\nIt's done\nX\n)\" && git push origin other",
    "cat > b.md <<'X'\nIt's ready\nX\ngit push origin feature",
    "cat <<EOF\n$(gh pr create)\nEOF", "cat <<-X\n\ttext\n\tX\ngit push", "cat <<< x && git push",
    "sh <<'X'\ngit push origin other\nX", "cat <<X | bash\ngit push origin other\nX",
    "bash -s <<X\ngh pr create\nX",
    "env FOO=1 bash <<'X'\necho \"it's fine\"\ngit push origin other\nX",
    "((n = 1<<2))\ngit push origin other", "echo $((1<<2)) && git push origin other",
  ] {
    #expect(try denies(command, cwd: root), "\(command)")
  }
  for command in [
    "APE_REVIEWED_HEAD=\(short) gh pr create --base main",
    "APE_REVIEWED_HEAD=\(short.uppercased()) gh pr create",
    "APE_REVIEWED_HEAD=\(head) git push -u origin HEAD",
    "APE_REVIEWED_HEAD=\(short) git -C \"\(path)\" push -u origin HEAD",
    "APE_REVIEWED_HEAD=\(other.prefix(7)) git push origin other",
    "cd \"\(path)\"; APE_REVIEWED_HEAD=\(short) git push",
    "env APE_REVIEWED_HEAD=\(short) gh pr create",
    "APE_REVIEW_OVERRIDE='the user chose to publish without review' gh pr create",
    "APE_REVIEWED_HEAD=\(short) git push -u origin feature 2>&1",
    "APE_REVIEWED_HEAD=\(short) git push -u origin feature > /dev/null",
    "APE_REVIEWED_HEAD=\(short) git push -u origin feature &> /tmp/log # push",
    "APE_REVIEWED_HEAD=\(short) URL=\"$(gh pr create --fill)\"",
    "APE_REVIEWED_HEAD=\(short) gh pr create --body \"$(cat <<'X'\nit's done; git push later\nX\n)\"",
    "APE_REVIEW_OVERRIDE='the user chose to' git push --all",
    "APE_REVIEWED_HEAD=\(short) gh pr create --body-file - <<'X'\nRun `git push` later, it's fine\nX",
    "APE_REVIEWED_HEAD=\(short) bash <<'X'\ngit push -u origin feature\nX",
    "bash -c 'echo hi' <<X\ngit push origin other\nX",
  ] {
    #expect(try !denies(command, cwd: root), "\(command)")
  }
}

@Test func tagsDeletionsAndOtherCommandsPassTheGate() throws {
  let (root, _, _) = try repository()
  defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
  for command in [
    "ls -la", "gh pr view 5", "gh pr checks 5", "gh pr edit 3 --add-label docs",
    "git push origin v2.0", "git push origin refs/tags/v2.0", "git push --tags",
    "git push --delete origin old", "git push origin :old",
    "echo 'how to gh pr create'", "grep -n \"git push\" README.md",
    "git log --oneline | grep push", "\"APE_REVIEW_OVERRIDE=x\" gh pr create",
    "cat <<'EOF'\n$(gh pr create)\nEOF", "cat <<< \"don't\" && echo ok",
  ] {
    #expect(try !denies(command, cwd: root), "\(command)")
  }
}

@Test func unreadableHookInputIsDenied() throws {
  #expect(try denies(input: Data(#"{"tool_input": {"command": "gh pr create"#.utf8)))
}

@Test func aTagCreatedEarlierInTheSameCommandPassesTheGate() throws {
  let (root, _, _) = try repository()
  defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
  // The hook runs before the line, so these tags do not exist yet when it checks the push.
  for command in [
    "git tag -a v9.9 -m 'Release 9.9' HEAD && git push origin v9.9",
    "git tag v9.9 && git tag -a rel--v9.9 -m \"rel 9.9\" && git push origin v9.9 rel--v9.9",
    "git tag -s -u KEY v9.9 && git push origin v9.9",
    "git tag -am 'Release 9.9' v9.9 && git push origin v9.9",
    "git tag -m'Release' -f v9.9 && git push origin v9.9",
    "git tag --message=Release v9.9 && git push origin v9.9",
    "git tag -- v9.9 && git push origin v9.9:refs/tags/v9.9",
    "git -C . tag v9.9 && git push origin v9.9",
  ] {
    #expect(try !denies(command, cwd: root), "\(command)")
  }
  // Still reviewed: a name no tag will have, a listing or deletion, a branch beside the tag, a
  // tag pushed to a branch, a name that already reaches a branch or commit by another spelling,
  // and a tag created in another repository.
  let other = root.deletingLastPathComponent().appendingPathComponent("other")
  for command in [
    "git push origin v9.9", "git tag -d v9.9 && git push origin v9.9",
    "git tag -l v9.9 && git push origin v9.9", "git tag --merged HEAD v9.9 && git push origin v9.9",
    "git tag v9.9 && git push origin v9.9 feature",
    "git tag v9.9 && git push origin v9.9:refs/heads/v9.9",
    "git tag other && git push origin other", "git tag v9.9; git tag -d v9.9; git push origin v9.9",
    "git tag refs/heads/feature && git push origin refs/heads/feature",
    "git tag heads/feature && git push origin heads/feature",
    "git tag HEAD && git push origin HEAD", "git tag @ && git push origin @",
    "git -C '\(other.path)' tag v9.9 && git push origin v9.9",
    // Anything between the tag and the push could replace it with a branch of the same name.
    "git tag x no-such-rev 2>/dev/null; git switch -c x; git commit -qam wip; git push -u origin x",
    "git tag x && git tag -d x && git checkout -b x && git push origin x",
    "git tag v9.9 && echo ok && git push origin v9.9",
  ] {
    #expect(try denies(command, cwd: root), "\(command)")
  }
}
