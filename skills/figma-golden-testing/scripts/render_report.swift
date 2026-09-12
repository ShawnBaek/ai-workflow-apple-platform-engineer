#!/usr/bin/env swift

import Foundation

struct Arguments {
  let metrics: URL
  let textResults: URL
  let output: URL
}

enum ReportError: LocalizedError {
  case usage(String)
  case invalidJSON(URL)

  var errorDescription: String? {
    switch self {
    case let .usage(message): return message
    case let .invalidJSON(url): return "Could not read JSON: \(url.path)"
    }
  }
}

func value(after flag: String, in arguments: [String]) throws -> String {
  guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
    throw ReportError.usage("Missing value for \(flag)")
  }
  return arguments[index + 1]
}

func parseArguments() throws -> Arguments {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.contains("--help") {
    throw ReportError.usage("Usage: render_report.swift --metrics <metrics.json> --text <text-results.json> --out <directory>")
  }
  return Arguments(
    metrics: URL(fileURLWithPath: try value(after: "--metrics", in: arguments)),
    textResults: URL(fileURLWithPath: try value(after: "--text", in: arguments)),
    output: URL(fileURLWithPath: try value(after: "--out", in: arguments))
  )
}

func loadJSON(_ url: URL) throws -> [String: Any] {
  let data = try Data(contentsOf: url)
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ReportError.invalidJSON(url)
  }
  return object
}

func escape(_ value: String) -> String {
  value
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&apos;")
}

func text(_ value: String, x: Int, y: Int, size: Int, weight: String = "400", color: String = "#162033") -> String {
  "<text x=\"\(x)\" y=\"\(y)\" font-family=\"-apple-system, BlinkMacSystemFont, sans-serif\" font-size=\"\(size)px\" font-weight=\"\(weight)\" fill=\"\(color)\">\(escape(value))</text>"
}

func document(title: String, width: Int, height: Int, body: [String]) -> String {
  ([
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">",
    "<rect width=\"100%\" height=\"100%\" fill=\"#f7f9fc\"/>",
    text(title, x: 36, y: 52, size: 28, weight: "700"),
    "<line x1=\"36\" y1=\"72\" x2=\"\(width - 36)\" y2=\"72\" stroke=\"#d5dce8\"/>",
  ] + body + ["</svg>"]).joined(separator: "\n")
}

func metricValue(_ metrics: [String: Any], _ key: String) -> String {
  if let value = metrics[key] as? String { return value }
  if let value = metrics[key] as? NSNumber { return value.stringValue }
  if let value = metrics[key] as? [String: Any], let width = value["width"], let height = value["height"] {
    return "\(width) x \(height)"
  }
  return "-"
}

func metricsSVG(_ metrics: [String: Any]) -> String {
  let status = (Double(metricValue(metrics, "matchPercentage")) ?? 0) >= 99 ? "PASS" : "FAIL"
  var body: [String] = [
    text("STATUS", x: 42, y: 116, size: 13, weight: "700", color: "#59667d"),
    text(status, x: 42, y: 158, size: 34, weight: "700", color: status == "PASS" ? "#087f5b" : "#c92a2a"),
    text("CoreGraphics device-RGB decode; no scale/crop/mask", x: 42, y: 194, size: 14, color: "#59667d"),
  ]
  let rows = [
    ("Dimensions", metricValue(metrics, "dimensions")),
    ("Threshold (max RGB delta)", metricValue(metrics, "threshold")),
    ("Matching pixels", "\(metricValue(metrics, "matchingPixels")) / \(metricValue(metrics, "pixelCount"))"),
    ("Match percentage", "\(metricValue(metrics, "matchPercentage"))%"),
    ("Exact pixels", "\(metricValue(metrics, "exactPixels")) (\(metricValue(metrics, "exactPercentage"))%)"),
    ("Mean / max RGB delta", "\(metricValue(metrics, "meanMaxRGBDelta")) / \(metricValue(metrics, "maxRGBDelta"))"),
  ]
  for (index, row) in rows.enumerated() {
    let y = 250 + index * 46
    body.append(text(row.0, x: 42, y: y, size: 15, weight: "600"))
    body.append(text(row.1, x: 390, y: y, size: 15, color: "#33415c"))
    body.append("<line x1=\"42\" y1=\"\(y + 14)\" x2=\"958\" y2=\"\(y + 14)\" stroke=\"#e2e7ef\"/>")
  }
  return document(title: "Figma golden pixel metrics", width: 1000, height: 560, body: body)
}

func textResultsSVG(_ results: [String: Any]) -> String {
  var body: [String] = []
  let sections: [(String, String, String)] = [
    ("Missing", "missing", "#c92a2a"),
    ("Extra", "extra", "#a15c00"),
    ("Changed", "changed", "#9b36a5"),
    ("Matches", "matches", "#087f5b"),
  ]
  var y = 112
  for (title, key, color) in sections {
    guard let values = results[key] as? [[String: Any]], !values.isEmpty else { continue }
    body.append(text(title, x: 42, y: y, size: 20, weight: "700", color: color))
    y += 30
    for value in values {
      let node = value["figmaNodeId"] as? String ?? "-"
      let field = value["field"] as? String ?? "text"
      let expected = value["expected"] as? String
      let actual = value["actual"] as? String
      let detail: String
      if let expected, let actual { detail = "expected \"\(expected)\" -> actual \"\(actual)\"" }
      else if let expected { detail = "expected \"\(expected)\"" }
      else if let actual { detail = "actual \"\(actual)\"" }
      else { detail = "" }
      let line = "\(field): \(detail) [\(node)]"
      body.append(text(line, x: 56, y: y, size: 13, color: "#33415c"))
      y += 23
      if y > 840 { break }
    }
    y += 18
    if y > 840 { break }
  }
  if body.isEmpty { body.append(text("No semantic text differences", x: 42, y: 124, size: 18, color: "#087f5b")) }
  return document(title: "Figma visible-text results", width: 1400, height: 900, body: body)
}

do {
  let arguments = try parseArguments()
  let metrics = try loadJSON(arguments.metrics)
  let textResults = try loadJSON(arguments.textResults)
  try FileManager.default.createDirectory(at: arguments.output, withIntermediateDirectories: true)
  try metricsSVG(metrics).write(to: arguments.output.appendingPathComponent("metrics.svg"), atomically: true, encoding: .utf8)
  try textResultsSVG(textResults).write(to: arguments.output.appendingPathComponent("text-results.svg"), atomically: true, encoding: .utf8)
  print(arguments.output.path)
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(1)
}
