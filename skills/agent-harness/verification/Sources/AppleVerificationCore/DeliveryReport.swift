import Foundation

/// Validates and renders completion previews. It never transmits a message.
public enum DeliveryReport {
  public static func validateReport(_ report: [String: Any], context: RuntimeContext) throws {
    let schema = try HarnessRuntime.object(
      context.harnessRoot.appendingPathComponent("contracts/schemas/completion-report.schema.json"))
    let errors = JSONSchemaValidator.errors(instance: report, schema: schema)
    guard errors.isEmpty else { throw VerificationError.invalid(errors.joined(separator: "; ")) }
    try validateUsage(report["usage"] as! [String: Any])
  }

  /// Cross-field invariants which JSON Schema cannot express.
  public static func validateUsage(_ usage: [String: Any]) throws {
    guard let status = usage["status"] as? String,
      let missing = usage["missing_sources"] as? [String],
      let sources = usage["source_records"] as? [String: [String: Any]],
      let attribution = usage["attribution"] as? [[String: Any]],
      let cost = usage["cost"] as? [String: Any]
    else { throw VerificationError.invalid("Invalid usage structure") }
    func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw VerificationError.invalid(message) }
    }
    func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }
    func token(_ value: Any?) throws -> Int? {
      if absent(value) { return nil }
      guard let number = value as? NSNumber, !HarnessRuntime.isBoolean(number),
        number.doubleValue.isFinite, number.doubleValue >= 0,
        let integer = Int(number.stringValue)
      else { throw VerificationError.invalid("Token count must be a nonnegative bounded integer") }
      return integer
    }
    switch status {
    case "full":
      try require(
        missing.isEmpty && !sources.isEmpty,
        "Full usage requires source records and no missing sources")
    case "partial":
      try require(
        !missing.isEmpty && !sources.isEmpty, "Partial usage requires reported and missing sources")
    case "not_exposed":
      try require(
        !missing.isEmpty && sources.isEmpty && absent(usage["cross_provider_total"]),
        "Unexposed usage cannot contain records or totals")
    default: throw VerificationError.invalid("Invalid usage status")
    }
    var input = 0
    var output = 0
    var complete = 0
    for source in sources.values {
      let i = try token(source["input_tokens"])
      let o = try token(source["output_tokens"])
      let cached = try token(source["cached_input_tokens"])
      let reasoning = try token(source["reasoning_tokens"])
      try require((i == nil) == (o == nil), "Input and output tokens must be exposed together")
      if let cached {
        try require(i != nil && cached <= i!, "Cached input lacks or exceeds its parent total")
      }
      if let reasoning {
        try require(
          o != nil && reasoning <= o!, "Reasoning tokens lack or exceed their parent total")
      }
      if let i, let o {
        let newInput = input.addingReportingOverflow(i)
        let newOutput = output.addingReportingOverflow(o)
        try require(
          !newInput.overflow && !newOutput.overflow, "Token total exceeds supported integer range")
        input = newInput.partialValue
        output = newOutput.partialValue
        complete += 1
      }
    }
    if status == "full" {
      try require(complete == sources.count, "Full usage cannot contain unknown counts")
    }
    if status == "partial" {
      try require(complete > 0, "Partial usage needs at least one complete source")
    }
    let references = attribution.flatMap { $0["source_ids"] as? [String] ?? [] }
    try require(
      references.count == Set(references).count && Set(references) == Set(sources.keys),
      "Usage source IDs must be attributed exactly once")
    if complete > 0 {
      guard let total = usage["cross_provider_total"] as? [String: Any] else {
        throw VerificationError.invalid("Reported usage requires a total")
      }
      try require(
        try token(total["input_tokens"]) == input && token(total["output_tokens"]) == output,
        "Cross-provider total does not equal unique sources")
      try require(
        total["label"] as? String
          == "informational; cached input and reasoning are subsets, not added",
        "Token subsets must not be added again")
    } else {
      try require(absent(usage["cross_provider_total"]), "Token total requires a complete source")
    }
    switch cost["status"] as? String {
    case "not_exposed":
      try require(
        absent(cost["amount"]) && absent(cost["currency"]),
        "Unexposed cost cannot contain amount or currency")
    case "provider_reported", "client_estimate":
      guard let amount = cost["amount"] as? NSNumber, !HarnessRuntime.isBoolean(amount),
        amount.doubleValue.isFinite, amount.doubleValue >= 0,
        let currency = cost["currency"] as? String, !currency.isEmpty
      else {
        throw VerificationError.invalid("Reported cost requires a nonnegative amount and currency")
      }
    default: throw VerificationError.invalid("Invalid cost status")
    }
  }

  public static func render(
    _ report: [String: Any], channel: String = "markdown", context: RuntimeContext
  ) throws -> String {
    guard ["markdown", "telegram", "whatsapp", "imessage"].contains(channel) else {
      throw VerificationError.invalid("Unknown delivery channel")
    }
    try validateReport(report, context: context)
    let usage = report["usage"] as! [String: Any]
    func heading(_ value: String) -> String { (channel == "markdown" ? "# " : "📌 ") + value }
    func value(_ raw: Any?, fallback: String = "not exposed") -> String {
      guard let raw, !(raw is NSNull) else { return fallback }
      return raw as? String ?? String(describing: raw)
    }
    var lines = [
      heading("Completion Report"), "Status: \(report["status"]!)",
      "Task: \(value(report["task"], fallback: "not recorded"))",
    ]
    func section(_ name: String, _ values: [String]) {
      lines.append(heading(name))
      lines += values.isEmpty ? ["- none recorded"] : values
    }
    section("Changes", (report["changes"] as! [String]).map { "- " + $0 })
    section(
      "PRs",
      (report["pull_requests"] as! [[String: Any]]).map {
        "- \($0["state"]!): \(value($0["url"], fallback: "no link"))"
      })
    section(
      "Checks",
      (report["checks"] as! [[String: Any]]).map {
        "- \($0["name"]!): \($0["result"]!) — \(value($0["summary"], fallback: "no summary"))"
      })
    // All supported evidence kinds remain visible, including sanitized JSON/log proof.
    section(
      "Evidence",
      (report["evidence"] as! [[String: Any]]).map {
        "- \($0["kind"]!): \(value($0["observed_result"], fallback: "no observed result")) (\(value($0["reference"], fallback: "no reference")))"
      })
    section(
      "Omissions / residual risk",
      (report["omissions"] as! [[String: Any]]).map {
        "- \($0["check"]!): \($0["reason"]!) Risk: \($0["residual_risk"]!)"
      })
    let sources = usage["source_records"] as! [String: [String: Any]]
    var owners = [String: String]()
    for attribution in usage["attribution"] as! [[String: Any]] {
      let owner = ["agent_id", "session_id", "model"].map { value(attribution[$0], fallback: "?") }
        .joined(separator: "/")
      for sourceID in attribution["source_ids"] as! [String] { owners[sourceID] = owner }
    }
    section(
      "Resource Usage (\(usage["status"]!))",
      sources.keys.sorted().map { key in
        let item = sources[key]!
        return
          "- \(item["provider"]!)/\(key): input \(value(item["input_tokens"])), output \(value(item["output_tokens"])); cached-input \(value(item["cached_input_tokens"])) and reasoning \(value(item["reasoning_tokens"])) are subsets; \(owners[key]!)"
      })
    let missing = usage["missing_sources"] as! [String]
    if !missing.isEmpty {
      lines.append("Missing usage sources: " + missing.joined(separator: ", "))
    }
    let total = usage["cross_provider_total"] as? [String: Any]
    lines.append(
      "Cross-provider total (informational): "
        + (total.map { "input \($0["input_tokens"]!), output \($0["output_tokens"]!)" }
          ?? "not exposed"))
    let cost = usage["cost"] as! [String: Any]
    lines.append(
      "Cost: \(cost["status"]!); \(value(cost["amount"])) \(value(cost["currency"], fallback: ""))"
        .trimmingCharacters(in: .whitespaces))
    return lines.joined(separator: "\n") + "\n"
  }

  public static func validateAuthorization(
    _ authorization: [String: Any], rendered: String, channel: String, channelID: String,
    destination: String, whatsappRequestSHA256: String? = nil, context: RuntimeContext,
    now: Date = Date()
  ) throws {
    let schema = try HarnessRuntime.object(
      context.harnessRoot.deletingLastPathComponent().appendingPathComponent(
        "delivery-report/contracts/delivery-authorization.schema.json"))
    let errors = JSONSchemaValidator.errors(instance: authorization, schema: schema)
    guard errors.isEmpty else { throw VerificationError.invalid(errors.joined(separator: "; ")) }
    guard authorization["channel_kind"] as? String == channel,
      authorization["channel_id"] as? String == channelID,
      authorization["destination_ref"] as? String == destination
    else { throw VerificationError.invalid("Authorization channel or destination drifted") }
    let transport = authorization["transport_ref"] as! String
    guard
      let prefix = ["telegram": "bot-api", "whatsapp": "cloud-api", "imessage": "shortcuts"][
        channel], transport.hasPrefix(prefix),
      channel == "imessage"
        ? destination.hasPrefix("shortcuts.") : destination.hasPrefix("private.")
    else {
      throw VerificationError.invalid(
        "Authorization transport or private destination does not match channel")
    }
    let issued = try HarnessRuntime.parseTimestamp(authorization["issued_at"] as! String)
    let expires = try HarnessRuntime.parseTimestamp(authorization["expires_at"] as! String)
    guard issued <= now, now < expires else {
      throw VerificationError.invalid("Authorization is not active")
    }
    guard authorization["report_sha256"] as? String == HarnessRuntime.sha256(Data(rendered.utf8))
    else { throw VerificationError.invalid("Rendered report hash drifted from authorization") }
    let media = authorization["media_allowlist"] as! [[String: Any]]
    let refs = media.map { $0["reference"] as! String }
    guard refs.count == Set(refs).count else {
      throw VerificationError.invalid("Media allowlist references must be unique")
    }
    if channel == "whatsapp", authorization["whatsapp_mode"] as? String == "approved_template" {
      guard authorization["whatsapp_request_sha256"] as? String == whatsappRequestSHA256 else {
        throw VerificationError.invalid(
          "Canonical WhatsApp request hash drifted from authorization")
      }
    } else if whatsappRequestSHA256 != nil {
      throw VerificationError.invalid("Template request hash is not applicable to this send")
    }
  }

  public static func run(arguments: [String], context: RuntimeContext) throws -> Int32 {
    guard let path = arguments.first, !path.hasPrefix("--") else {
      throw VerificationError.invalid("delivery-report requires a report path")
    }
    let args = try RuntimeArguments(Array(arguments.dropFirst()))
    try args.allow([
      "--channel", "--authorization", "--channel-id", "--destination-ref",
      "--whatsapp-request-sha256",
    ])
    let channel = args.value("--channel") ?? "markdown"
    let rendered = try render(
      HarnessRuntime.object(URL(fileURLWithPath: path)), channel: channel, context: context)
    if let authPath = args.value("--authorization") {
      try validateAuthorization(
        HarnessRuntime.object(URL(fileURLWithPath: authPath)), rendered: rendered, channel: channel,
        channelID: args.required("--channel-id"), destination: args.required("--destination-ref"),
        whatsappRequestSHA256: args.value("--whatsapp-request-sha256"), context: context)
    } else if ["--channel-id", "--destination-ref", "--whatsapp-request-sha256"].contains(where: {
      args.value($0) != nil
    }) {
      throw VerificationError.invalid("Channel identity requires an authorization file")
    }
    FileHandle.standardOutput.write(Data(rendered.utf8))
    return 0
  }
}
