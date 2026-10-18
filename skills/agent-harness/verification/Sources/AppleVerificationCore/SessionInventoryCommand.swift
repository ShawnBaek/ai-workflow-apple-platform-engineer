import Foundation

/// The same metadata discovery used by the Claude hook, available read-only to either client.
public enum SessionInventoryCommand {
  public static func run(arguments: [String]) throws -> Int32 {
    guard arguments.first == "list" else {
      throw VerificationError.invalid("sessions requires list")
    }
    let options = try RuntimeArguments(Array(arguments.dropFirst()), flags: ["--json"])
    try options.allow(["--repo", "--own-client", "--own-session", "--json"])
    let client = try options.value("--own-client").map { try SessionHandoff.agent($0) }
    guard options.value("--own-session") == nil || client != nil else {
      throw VerificationError.invalid("--own-session requires --own-client")
    }
    let environment = ProcessInfo.processInfo.environment
    let deadline = Date().addingTimeInterval(8)
    let scan = SessionInventory.scan(
      home: environment["HOME"] ?? NSHomeDirectory(), environment: environment,
      ownClient: client, ownID: options.value("--own-session"),
      deadline: deadline)
    let place = try options.value("--repo").map { try SessionHandoff.place($0) }
    var rows = [[String: Any]]()
    var warnings = scan.warnings
    for session in scan.sessions {
      var relation = "unfiltered"
      if let place {
        guard deadline.timeIntervalSinceNow > 0 else {
          warnings.append("Repository matching deadline reached; results are partial")
          break
        }
        let result = try HarnessRuntime.run(
          executable: "/usr/bin/git",
          arguments: [
            "--no-optional-locks", "-C", session.cwd, "rev-parse", "--path-format=absolute",
            "--git-common-dir", "--show-toplevel",
          ], timeout: min(2, deadline.timeIntervalSinceNow))
        guard result.exitCode == 0, !result.timedOut, !result.truncated else {
          warnings.append(
            "A session's repository could not be identified; repository results may be incomplete")
          continue
        }
        let parts = result.stdout.split(separator: "\n").map(String.init)
        guard parts.count == 2, canonical(parts[0]) == canonical(place.common) else { continue }
        relation = canonical(parts[1]) == canonical(place.top) ? "same-checkout" : "same-repository"
      }
      rows.append([
        "client": session.client, "id": session.id, "cwd": session.cwd,
        "branch": session.branch as Any? ?? NSNull(),
        "modified": ISO8601DateFormatter().string(from: session.modified), "relation": relation,
      ])
    }
    if options.flag("--json") {
      let data = try JSONSerialization.data(
        withJSONObject: [
          "sessions": rows, "warnings": Array(Set(warnings)).sorted(),
          "complete": warnings.isEmpty,
          "observation": "Recent local transcript activity; not live execution or writer ownership",
        ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
      print("Recent local sessions (30 min): \(rows.count). Activity is not writer ownership.")
      for row in rows {
        print(
          SessionHandoff.oneLine(
            "\(row["client"]!) \(row["id"]!) · \(row["cwd"]!) · \(row["relation"]!)"))
      }
      for warning in Set(warnings).sorted() {
        print("Unknown/partial: \(SessionHandoff.oneLine(warning))")
      }
    }
    return 0
  }

  private static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
}
