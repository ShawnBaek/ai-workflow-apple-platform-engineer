import Foundation

// Claude Code PreToolUse hook for Bash. A simple command that publishes a pull request
// (`gh pr create`, `gh pr ready`, `gh pr edit --base`, or a `git push` of anything but tags or
// deletions) runs only when its own `APE_REVIEWED_HEAD=<sha>` assignment names the commit it
// publishes, or its `APE_REVIEW_OVERRIDE=<decision>` assignment records the user's explicit
// decision. Reads the hook input on stdin; prints a deny decision or nothing.

struct Word {
  var text = ""
  var quoted = false
}

/// Splits `source` into simple commands of words, honouring quotes and backslashes. Unquoted
/// `&&`, `||`, `;`, `|`, `&`, newlines, parentheses and braces end a command.
func simpleCommands(_ source: String) -> [[Word]] {
  var commands = [[Word]]()
  var words = [Word]()
  var word: Word?
  var characters = Array(source)[...]
  func endWord() {
    if let finished = word { words.append(finished) }
    word = nil
  }
  func endCommand() {
    endWord()
    if !words.isEmpty { commands.append(words) }
    words = []
  }
  while let character = characters.popFirst() {
    switch character {
    case "\\":
      if let next = characters.popFirst(), next != "\n" {
        word = word ?? Word()
        word!.text.append(next)
      }
    case "'":
      word = word ?? Word()
      word!.quoted = true
      while let next = characters.popFirst(), next != "'" { word!.text.append(next) }
    case "\"":
      word = word ?? Word()
      word!.quoted = true
      while let next = characters.popFirst(), next != "\"" {
        if next == "\\", let escaped = characters.popFirst() {
          if !"\"\\$`".contains(escaped) { word!.text.append(next) }
          word!.text.append(escaped)
        } else {
          word!.text.append(next)
        }
      }
    case " ", "\t":
      endWord()
    case "\n", ";", "&", "|", "(", ")", "{", "}":
      endCommand()
    default:
      word = word ?? Word()
      word!.text.append(character)
    }
  }
  endCommand()
  return commands
}

/// Leading `NAME=value` assignments, and the words after them.
func assignments(_ words: [Word]) -> ([String: String], ArraySlice<Word>) {
  var values = [String: String]()
  var rest = words[...]
  while let first = rest.first, !first.text.hasPrefix("="),
    let equals = first.text.firstIndex(of: "="),
    first.text[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
  {
    values[String(first.text[..<equals])] = String(first.text[first.text.index(after: equals)...])
    rest = rest.dropFirst()
  }
  return (values, rest)
}

struct Gate {
  var directory: String
  var reasons = [String]()

  func expand(_ path: String) -> String {
    let home = NSHomeDirectory()
    let expanded =
      path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
    return expanded.hasPrefix("/") ? expanded : directory + "/" + expanded
  }

  func git(_ arguments: [String], in directory: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Checks one publishing command against its own markers; `published` is the revision it
  /// sends, resolved in `directory`.
  mutating func require(
    _ marker: [String: String], publishing published: String, in directory: String,
    _ label: String
  ) {
    if let decision = marker["APE_REVIEW_OVERRIDE"], !decision.isEmpty { return }
    guard let reviewed = marker["APE_REVIEWED_HEAD"]?.lowercased(),
      reviewed.count >= 7, reviewed.allSatisfy(\.isHexDigit)
    else {
      reasons.append("\(label) names no reviewed head.")
      return
    }
    guard let commit = git(["rev-parse", "--verify", "\(published)^{commit}"], in: directory)
    else {
      reasons.append("\(label): \(published) could not be resolved in \(directory).")
      return
    }
    if !commit.lowercased().hasPrefix(reviewed) {
      reasons.append(
        "\(label) publishes \(commit), not the reviewed head \(reviewed); any later commit, "
          + "amend, rebase or retarget needs re-review.")
    }
  }

  mutating func check(_ command: [Word], depth: Int = 0) {
    var (marker, rest) = assignments(command)
    // Wrappers that run the next word as the command.
    while let first = rest.first?.text {
      if first == "env" {
        let (more, after) = assignments(Array(rest.dropFirst()))
        marker.merge(more) { _, new in new }
        rest = after
      } else if ["command", "time", "nohup", "exec", "builtin", "then", "do", "else", "!"]
        .contains(first)
      {
        rest = rest.dropFirst()
      } else {
        break
      }
    }
    guard let program = rest.first?.text else { return }
    let arguments = rest.dropFirst().map(\.text)
    let name = (program as NSString).lastPathComponent
    if ["sh", "bash", "zsh", "dash"].contains(name), depth < 4,
      let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }),
      flag + 1 < arguments.count
    {
      var inner = Gate(directory: directory)
      for nested in simpleCommands(arguments[flag + 1]) {
        inner.check(marker.isEmpty ? nested : prefixed(nested, marker), depth: depth + 1)
      }
      reasons += inner.reasons
      return
    }
    switch name {
    case "cd":
      if let target = arguments.first(where: { !$0.hasPrefix("-") }) {
        directory = expand(target)
      } else {
        directory = NSHomeDirectory()
      }
    case "gh":
      checkGitHub(arguments, marker)
    case "git":
      checkGit(arguments, marker)
    default:
      break
    }
  }

  func prefixed(_ words: [Word], _ marker: [String: String]) -> [Word] {
    marker.map { Word(text: "\($0.key)=\($0.value)") } + words
  }

  mutating func checkGitHub(_ arguments: [String], _ marker: [String: String]) {
    var index = 0
    while index < arguments.count, arguments[index].hasPrefix("-") {
      index += ["-R", "--repo", "--hostname"].contains(arguments[index]) ? 2 : 1
    }
    guard index + 1 < arguments.count, arguments[index] == "pr" else { return }
    let action = arguments[index + 1]
    let options = arguments[(index + 2)...]
    let retarget = options.contains { $0 == "--base" || $0 == "-B" || $0.hasPrefix("--base=") }
    guard action == "create" || action == "ready" || (action == "edit" && retarget) else {
      return
    }
    require(marker, publishing: "HEAD", in: directory, "gh pr \(action)")
  }

  mutating func checkGit(_ arguments: [String], _ marker: [String: String]) {
    var repository = directory
    var index = 0
    while index < arguments.count, arguments[index].hasPrefix("-") {
      let option = arguments[index]
      if option == "-C", index + 1 < arguments.count {
        repository = expand(arguments[index + 1])
        index += 2
      } else if ["-c", "--git-dir", "--work-tree", "--namespace"].contains(option) {
        index += 2
      } else {
        index += 1
      }
    }
    guard index < arguments.count, arguments[index] == "push" else { return }
    var positional = [String]()
    var tagsOnly = false
    var options = arguments[(index + 1)...].makeIterator()
    while let argument = options.next() {
      switch argument {
      case "--delete", "-d", "--prune", "--dry-run", "-n":
        return
      case "--tags":
        tagsOnly = true
      case "--repo", "--receive-pack", "--exec", "-o", "--push-option":
        _ = options.next()
      default:
        if !argument.hasPrefix("-") { positional.append(argument) }
      }
    }
    let refspecs = positional.dropFirst()
    if refspecs.isEmpty {
      if tagsOnly { return }
      require(marker, publishing: "HEAD", in: repository, "git push")
      return
    }
    for refspec in refspecs {
      var source = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
      if let colon = source.firstIndex(of: ":") { source = String(source[..<colon]) }
      if source.isEmpty { continue }  // `:branch` deletes a remote ref.
      if source.hasPrefix("refs/tags/")
        || (git(["show-ref", "--verify", "--quiet", "refs/tags/\(source)"], in: repository) != nil
          && git(["show-ref", "--verify", "--quiet", "refs/heads/\(source)"], in: repository)
            == nil)
      {
        continue
      }
      require(marker, publishing: source, in: repository, "git push \(refspec)")
    }
  }
}

func deny(_ reason: String) {
  let message =
    "apple-platform-engineer PR gate: \(reason) Publishing needs an independent code-review "
    + "approve for the exact head. Load apple-platform-engineer:git-workflow "
    + "(references/pr-delivery.md) and run apple-platform-engineer:code-review on that head "
    + "until it returns approve, then rerun the publishing command with the assignment "
    + "APE_REVIEWED_HEAD=<approved sha> in front of it. Only if the user explicitly decides to "
    + "publish without approve, put APE_REVIEW_OVERRIDE='<the user decision>' in front instead "
    + "and disclose it in the PR."
  let output: [String: Any] = [
    "hookSpecificOutput": [
      "hookEventName": "PreToolUse", "permissionDecision": "deny",
      "permissionDecisionReason": message,
    ]
  ]
  if let data = try? JSONSerialization.data(withJSONObject: output) {
    FileHandle.standardOutput.write(data + Data("\n".utf8))
  }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
  let command = (event["tool_input"] as? [String: Any])?["command"] as? String
else {
  deny("the hook input could not be read, so publication cannot be checked.")
  exit(0)
}
var gate = Gate(directory: event["cwd"] as? String ?? FileManager.default.currentDirectoryPath)
for simple in simpleCommands(command) { gate.check(simple) }
if !gate.reasons.isEmpty { deny(gate.reasons.joined(separator: " ")) }
