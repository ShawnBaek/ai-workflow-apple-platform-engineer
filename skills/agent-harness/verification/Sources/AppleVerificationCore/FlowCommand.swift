import Foundation

/// `apple-verify flow record|render`. Neither needs the installed contracts or a harness.
public enum FlowCommand {
  static let maximumFileBytes = 256 * 1_024 * 1_024

  public static func run(arguments: [String]) throws -> Int32 {
    switch arguments.first {
    case "record": return record(arguments: Array(arguments.dropFirst()))
    case "render":
      FileHandle.standardOutput.write(
        Data(try render(arguments: Array(arguments.dropFirst())).utf8))
      return 0
    default: throw VerificationError.invalid("flow requires record or render")
    }
  }

  /// The hook command: drains stdin, appends at most one redacted line and always returns 0
  /// with nothing on stdout, whatever the arguments or input.
  public static func record(arguments: [String]) -> Int32 {
    let input = FlowStore.readStandardInput()
    guard let input, let options = try? RuntimeArguments(arguments, flags: ["--include-labels"]),
      (try? options.allow(["--client", "--store", "--include-labels"])) != nil,
      let client = options.value("--client"), let store = options.value("--store")
    else { return 0 }
    FlowStore.record(
      input: input, client: client, store: store, includeLabels: options.flag("--include-labels"))
    return 0
  }

  public static func render(arguments: [String]) throws -> String {
    let options = try RuntimeArguments(arguments, flags: ["--include-labels"])
    try options.allow([
      "--store", "--session", "--ledger", "--format", "--max-steps", "--include-labels",
    ])
    guard let format = FlowRenderFormat(rawValue: try options.required("--format")) else {
      throw VerificationError.invalid("--format must be mermaid or tree")
    }
    var maxSteps = 500
    if let value = options.value("--max-steps") {
      guard let parsed = Int(value), (1...100_000).contains(parsed) else {
        throw VerificationError.invalid("--max-steps must be an integer from 1 to 100000")
      }
      maxSteps = parsed
    }
    let file = try FlowStore.sessionFile(
      store: try options.required("--store"), session: try options.required("--session"))
    let ledger = try options.value("--ledger").map { try lines(URL(fileURLWithPath: $0)) }
    return FlowRenderer.render(
      eventLines: try lines(file), ledgerLines: ledger,
      options: FlowRenderOptions(
        format: format, maxSteps: maxSteps, includeLabels: options.flag("--include-labels")))
  }

  static func lines(_ url: URL) throws -> [String] {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maximumFileBytes else {
      throw VerificationError.invalid("File exceeds 256 MiB: \(url.path)")
    }
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self).split(
      separator: "\n", omittingEmptySubsequences: true
    ).map(String.init)
  }
}
