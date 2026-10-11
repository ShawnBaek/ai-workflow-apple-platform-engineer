import Foundation

// Claude Code PreToolUse hook for Bash. A simple command that publishes a pull request
// (`gh pr create`, `gh pr ready`, `gh pr edit --base`, or a `git push` of anything but tags or
// deletions) runs only when its own `APE_REVIEWED_HEAD=<sha>` assignment names the commit it
// publishes, or its `APE_REVIEW_OVERRIDE=<decision>` assignment records the user's explicit
// decision. Reads the hook input on stdin; prints a deny decision or nothing.

struct Word {
  var text = ""
  var quoted = false
  /// A quote began before any `=`, so the word cannot be an assignment.
  var quotedName = false
  /// The source of each `$(…)` or backtick substitution inside the word, which runs as its
  /// own command line.
  var substitutions = [String]()
}

/// A here-document waiting for its body: the delimiter, whether the body expands (the
/// delimiter was not quoted), and whether `<<-` strips leading tabs.
struct Heredoc {
  var delimiter: String
  var expands: Bool
  var stripsTabs: Bool
}

/// Reads the delimiter word after `<<` or `<<-`, removing its quotes.
func heredocDelimiter(_ characters: inout ArraySlice<Character>) -> Heredoc {
  let stripsTabs = characters.first == "-"
  if stripsTabs { characters.removeFirst() }
  while let next = characters.first, next == " " || next == "\t" { characters.removeFirst() }
  var delimiter = ""
  var quoted = false
  while let next = characters.first, !" \t\n;&|<>()".contains(next) {
    characters.removeFirst()
    if next == "'" || next == "\"" {
      quoted = true
      while let inner = characters.popFirst(), inner != next { delimiter.append(inner) }
    } else if next == "\\" {
      quoted = true
      if let escaped = characters.popFirst() { delimiter.append(escaped) }
    } else {
      delimiter.append(next)
    }
  }
  return Heredoc(delimiter: delimiter, expands: !quoted, stripsTabs: stripsTabs)
}

/// Reads one here-document body after its command line, through the delimiter line (or the end
/// of the input, as the shell does). Returns the body and the delimiter line as read.
func heredocBody(_ characters: inout ArraySlice<Character>, _ heredoc: Heredoc) -> (
  body: String, end: String
) {
  var body = ""
  while !characters.isEmpty {
    var line = ""
    while let next = characters.popFirst(), next != "\n" { line.append(next) }
    let compared = heredoc.stripsTabs ? String(line.drop(while: { $0 == "\t" })) : line
    if compared == heredoc.delimiter { return (body, line) }
    body += line + "\n"
  }
  return (body, "")
}

/// The command substitutions an expanding here-document body runs.
func expansions(in body: String) -> [String] {
  var found = [String]()
  var characters = Array(body)[...]
  while let next = characters.popFirst() {
    if next == "\\" {
      _ = characters.popFirst()
    } else if next == "$", characters.first == "(" {
      characters.removeFirst()
      found.append(substitution(&characters))
    } else if next == "`" {
      found.append(backtick(&characters))
    }
  }
  return found
}

/// Reads a `$(…)` body after its opening parenthesis, through the matching one. A
/// here-document inside is copied whole, so its text cannot open or close anything.
func substitution(_ characters: inout ArraySlice<Character>) -> String {
  var body = ""
  var depth = 1
  var quote: Character?
  var pending = [Heredoc]()
  while let next = characters.popFirst() {
    if let open = quote {
      if next == open { quote = nil }
    } else if next == "'" || next == "\"" {
      quote = next
    } else if next == "<", characters.first == "<", characters.dropFirst().first != "<" {
      characters.removeFirst()
      let heredoc = heredocDelimiter(&characters)
      pending.append(heredoc)
      body +=
        "<<" + (heredoc.stripsTabs ? "-" : "")
        + (heredoc.expands ? heredoc.delimiter : "'\(heredoc.delimiter)'")
      continue
    } else if next == "\n", !pending.isEmpty {
      body.append(next)
      for heredoc in pending {
        let (text, end) = heredocBody(&characters, heredoc)
        body += text + end + "\n"
      }
      pending = []
      continue
    } else if next == "(" {
      depth += 1
    } else if next == ")" {
      depth -= 1
      if depth == 0 { break }
    }
    body.append(next)
  }
  return body
}

/// Reads a backtick body after its opening backtick, through the closing one.
func backtick(_ characters: inout ArraySlice<Character>) -> String {
  var body = ""
  while let next = characters.popFirst(), next != "`" { body.append(next) }
  return body
}

/// Skips an arithmetic `((…))` body after its opening `((`, through the matching `))`.
func arithmetic(_ characters: inout ArraySlice<Character>) {
  var depth = 2
  while let next = characters.popFirst() {
    if next == "(" { depth += 1 }
    if next == ")" {
      depth -= 1
      if depth == 0 { return }
    }
  }
}

/// Whether a simple command is a shell that reads its script from standard input: `sh`,
/// `bash`, `zsh` or `dash`, possibly behind assignments and `env`, `command`, `exec` or
/// `sudo`, with no `-c` script and no script file.
func readsScriptFromInput(_ words: [Word]) -> Bool {
  var rest = assignments(words).1
  while let first = rest.first?.text,
    ["env", "command", "exec", "sudo", "nohup", "time", "nice"].contains(first)
      || assignments([rest.first!]).0.count == 1
  {
    rest = rest.dropFirst()
  }
  guard let program = rest.first?.text,
    ["sh", "bash", "zsh", "dash"].contains((program as NSString).lastPathComponent)
  else { return false }
  for argument in rest.dropFirst().map(\.text) {
    if argument == "-s" || argument == "--" { return true }
    if argument.hasPrefix("-") {
      if !argument.hasPrefix("--"), argument.contains("c") { return false }
      continue
    }
    return false  // a script file
  }
  return true
}

/// Splits `source` into simple commands of words, honouring quotes, backslashes, `#` comments,
/// redirections (dropped with their targets) and command substitutions. Unquoted `&&`, `||`,
/// `;`, `|`, `&`, newlines, parentheses and braces end a command.
func simpleCommands(_ source: String) -> [[Word]] {
  var commands = [[Word]]()
  var words = [Word]()
  var word: Word?
  var dropNextWord = false
  var pending = [Heredoc]()
  var lineStart = 0
  var characters = Array(source)[...]
  func endWord() {
    if let finished = word {
      if dropNextWord {
        dropNextWord = false
        // A redirection target is not an argument, but a substitution in it still runs.
        if !finished.substitutions.isEmpty {
          words.append(Word(text: "", quoted: true, substitutions: finished.substitutions))
        }
      } else {
        words.append(finished)
      }
    }
    word = nil
  }
  func endCommand() {
    endWord()
    dropNextWord = false
    if !words.isEmpty { commands.append(words) }
    words = []
  }
  func redirect() {
    // A file descriptor number written right before the operator belongs to it.
    if let current = word, !current.quoted, current.text.allSatisfy(\.isNumber) { word = nil }
    endWord()
    while let next = characters.first, next == ">" || next == "<" || next == "|" {
      characters.removeFirst()
    }
    if characters.first == "&" {
      characters.removeFirst()
      // `>&2` or `>&-` duplicates a descriptor; `>& file` names a file.
      if let next = characters.first, next.isNumber || next == "-" {
        while let digit = characters.first, digit.isNumber || digit == "-" {
          characters.removeFirst()
        }
        return
      }
    }
    dropNextWord = true
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
      if !word!.text.contains("=") { word!.quotedName = true }
      while let next = characters.popFirst(), next != "'" { word!.text.append(next) }
    case "\"":
      word = word ?? Word()
      word!.quoted = true
      if !word!.text.contains("=") { word!.quotedName = true }
      while let next = characters.popFirst(), next != "\"" {
        if next == "\\", let escaped = characters.popFirst() {
          if !"\"\\$`".contains(escaped) { word!.text.append(next) }
          word!.text.append(escaped)
        } else if next == "$", characters.first == "(" {
          characters.removeFirst()
          if characters.first == "(" {
            characters.removeFirst()
            arithmetic(&characters)
          } else {
            word!.substitutions.append(substitution(&characters))
          }
        } else if next == "`" {
          word!.substitutions.append(backtick(&characters))
        } else {
          word!.text.append(next)
        }
      }
    case "$" where characters.first == "(":
      characters.removeFirst()
      word = word ?? Word()
      if characters.first == "(" {
        characters.removeFirst()
        arithmetic(&characters)
      } else {
        word!.substitutions.append(substitution(&characters))
      }
    case "`":
      word = word ?? Word()
      word!.substitutions.append(backtick(&characters))
    case "#" where word == nil:
      while let next = characters.first, next != "\n" { characters.removeFirst() }
    case "<" where characters.first == "<" && characters.dropFirst().first != "<":
      characters.removeFirst()
      if let current = word, !current.quoted, current.text.allSatisfy(\.isNumber) { word = nil }
      endWord()
      pending.append(heredocDelimiter(&characters))
    case ">", "<":
      redirect()
    case "&" where characters.first == ">":
      characters.removeFirst()
      redirect()
    case " ", "\t":
      endWord()
    case "\n" where !pending.isEmpty:
      // The bodies follow this line. They are data; only an expanding body's command
      // substitutions run, as part of this command.
      endWord()
      // A shell on this line that reads its input runs the body as its script.
      let shellReads = (commands[lineStart...] + [words]).contains(where: readsScriptFromInput)
      var runs = [String]()
      for heredoc in pending {
        let (body, _) = heredocBody(&characters, heredoc)
        if shellReads {
          runs.append(body)
        } else if heredoc.expands {
          runs += expansions(in: body)
        }
      }
      pending = []
      if !runs.isEmpty {
        words.append(Word(text: "", quoted: true, quotedName: true, substitutions: runs))
      }
      endCommand()
      lineStart = commands.count
    case "(" where characters.first == "(" && word == nil:
      characters.removeFirst()
      arithmetic(&characters)
    case "\n":
      endCommand()
      lineStart = commands.count
    case ";", "&", "|", "(", ")", "{", "}":
      endCommand()
    default:
      word = word ?? Word()
      word!.text.append(character)
    }
  }
  endCommand()
  return commands
}

/// Leading `NAME=value` assignments, and the words after them. A word written in quotes is
/// never an assignment: the shell runs it as the command name.
func assignments(_ words: [Word]) -> ([String: String], ArraySlice<Word>) {
  var values = [String: String]()
  var rest = words[...]
  while let first = rest.first, !first.quotedName, !first.text.hasPrefix("="),
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

  /// Checks a nested command line (`sh -c`, `eval`, a substitution) with the outer command's
  /// assignments in front of each of its commands.
  mutating func checkLine(_ source: String, _ marker: [String: String], depth: Int) {
    var inner = Gate(directory: directory)
    for nested in simpleCommands(source) {
      inner.check(prefixed(nested, marker), depth: depth + 1)
    }
    reasons += inner.reasons
  }

  mutating func check(_ command: [Word], depth: Int = 0) {
    guard depth < 6 else {
      reasons.append("The command nests too deeply to check.")
      return
    }
    var (marker, rest) = assignments(command)
    for word in command {
      for source in word.substitutions { checkLine(source, marker, depth: depth) }
    }
    // Keywords and wrappers that run the following words as the command.
    let optionArguments: Set = ["-u", "-g", "-n", "-s", "-k", "-I", "-L", "-P", "-E", "-d"]
    while let first = rest.first?.text {
      if first == "env" {
        rest = rest.dropFirst()
        while let option = rest.first?.text, option.hasPrefix("-") {
          rest = rest.dropFirst(option == "-u" || option == "-S" ? 2 : 1)
        }
        let (more, after) = assignments(Array(rest))
        marker.merge(more) { _, new in new }
        rest = after
      } else if first == "eval" {
        checkLine(rest.dropFirst().map(\.text).joined(separator: " "), marker, depth: depth)
        return
      } else if [
        "command", "time", "nohup", "exec", "builtin", "then", "do", "else", "!", "if", "elif",
        "while", "until", "sudo", "nice", "xargs", "timeout",
      ].contains(first) {
        rest = rest.dropFirst()
        while let option = rest.first?.text, option.hasPrefix("-") {
          rest = rest.dropFirst(optionArguments.contains(option) ? 2 : 1)
        }
        if first == "timeout" { rest = rest.dropFirst() }  // the duration
      } else {
        break
      }
    }
    guard let program = rest.first?.text else { return }
    let arguments = rest.dropFirst().map(\.text)
    let name = (program as NSString).lastPathComponent
    if ["sh", "bash", "zsh", "dash"].contains(name),
      let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }),
      flag + 1 < arguments.count
    {
      checkLine(arguments[flag + 1], marker, depth: depth)
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
      case "--delete", "-d", "--dry-run", "-n":
        return
      case "--tags":
        tagsOnly = true
      case "--all", "--branches", "--mirror":
        if marker["APE_REVIEW_OVERRIDE"]?.isEmpty == false { return }
        reasons.append(
          "git push \(argument) publishes every branch; push each reviewed branch by name.")
        return
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
      var destination = source
      if let colon = source.firstIndex(of: ":") {
        destination = String(source[source.index(after: colon)...])
        source = String(source[..<colon])
      }
      if source.isEmpty { continue }  // `:branch` deletes a remote ref.
      if source.contains("*") {
        if marker["APE_REVIEW_OVERRIDE"]?.isEmpty == false { continue }
        reasons.append(
          "git push \(refspec) publishes a pattern; push each reviewed branch by name.")
        continue
      }
      let toTag = destination.hasPrefix("refs/tags/") || destination == source
      let isTag =
        source.hasPrefix("refs/tags/")
        || (git(["show-ref", "--verify", "--quiet", "refs/tags/\(source)"], in: repository) != nil
          && git(["show-ref", "--verify", "--quiet", "refs/heads/\(source)"], in: repository)
            == nil)
      if toTag && isTag {
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
