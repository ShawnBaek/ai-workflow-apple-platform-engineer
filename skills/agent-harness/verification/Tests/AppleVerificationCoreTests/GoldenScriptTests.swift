import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppleVerificationCore

private func goldenRoot() -> URL {
  var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  for _ in 0..<5 { url.deleteLastPathComponent() }
  return url
}

private func goldenPNG(_ url: URL, color: (UInt8, UInt8, UInt8)) throws {
  let pixels: [UInt8] = [color.0, color.1, color.2, 255]
  let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
  let image = try #require(
    CGImage(
      width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
}

private func goldenRun(_ script: String, _ arguments: [String], root: URL) throws -> ProcessResult {
  try HarnessRuntime.run(
    executable: "/usr/bin/swift",
    arguments: [
      goldenRoot().appendingPathComponent("skills/figma-golden-testing/scripts/\(script)").path
    ] + arguments, directory: root, timeout: 30)
}

@Test func goldenComparatorReportsAndEnforcesOnlyAnExplicitMinimum() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let reference = root.appendingPathComponent("reference.png")
  let same = root.appendingPathComponent("same.png")
  let different = root.appendingPathComponent("different.png")
  try goldenPNG(reference, color: (0, 0, 0))
  try goldenPNG(same, color: (0, 0, 0))
  try goldenPNG(different, color: (255, 255, 255))
  let passed = try goldenRun(
    "overlay_diff.swift",
    [
      "--figma", reference.path, "--actual", same.path, "--out",
      root.appendingPathComponent("pass").path, "--minimum-match", "100",
    ], root: root)
  #expect(passed.exitCode == 0)
  #expect(
    try HarnessRuntime.object(root.appendingPathComponent("pass/metrics.json"))["status"] as? String
      == "passed")
  let mismatchOut = root.appendingPathComponent("fail")
  let failed = try goldenRun(
    "overlay_diff.swift",
    [
      "--figma", reference.path, "--actual", different.path, "--out", mismatchOut.path,
      "--minimum-match", "100",
    ], root: root)
  #expect(failed.exitCode == 2)
  #expect(
    FileManager.default.fileExists(atPath: mismatchOut.appendingPathComponent("metrics.json").path))
  #expect(
    try HarnessRuntime.object(mismatchOut.appendingPathComponent("metrics.json"))["status"]
      as? String == "failed")
  for artifact in ["overlay.png", "diff.png", "side-by-side.png"] {
    #expect(
      FileManager.default.fileExists(atPath: mismatchOut.appendingPathComponent(artifact).path))
  }
  let reportOnlyOut = root.appendingPathComponent("report")
  let reportOnly = try goldenRun(
    "overlay_diff.swift",
    ["--figma", reference.path, "--actual", different.path, "--out", reportOnlyOut.path], root: root
  )
  #expect(reportOnly.exitCode == 0)
  #expect(
    try HarnessRuntime.object(reportOnlyOut.appendingPathComponent("metrics.json"))["status"]
      as? String == "not_evaluated")
  let invalid = try goldenRun(
    "overlay_diff.swift",
    [
      "--figma", reference.path, "--actual", same.path, "--out",
      root.appendingPathComponent("invalid").path, "--minimum-match", "nan",
    ], root: root)
  #expect(invalid.exitCode == 1)
  #expect(
    try goldenRun(
      "overlay_diff.swift",
      [
        "--figma", reference.path, "--actual", same.path, "--out",
        root.appendingPathComponent("invalid-rgb").path, "--threshold", "bad",
      ], root: root
    ).exitCode == 1)
}

@Test func goldenRendererRequiresValidEvidenceAndEscapesText() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let metrics = root.appendingPathComponent("metrics.json")
  let text = root.appendingPathComponent("text.json")
  let output = root.appendingPathComponent("rendered")
  try JSONSerialization.data(withJSONObject: [
    "matchPercentage": 0, "threshold": 0, "matchingPixels": 0, "pixelCount": 1,
    "status": "not_evaluated",
  ]).write(to: metrics)
  try JSONSerialization.data(withJSONObject: [
    "missing": [["field": "<field>", "figmaNodeId": "<node>", "expected": "<expected>"]],
    "extra": [], "changed": [], "matches": [],
  ]).write(to: text)
  let rendered = try goldenRun(
    "render_report.swift", ["--metrics", metrics.path, "--text", text.path, "--out", output.path],
    root: root)
  #expect(rendered.exitCode == 0)
  let svg = try String(contentsOf: output.appendingPathComponent("metrics.svg"), encoding: .utf8)
  #expect(svg.contains("NOT EVALUATED"))
  #expect(!(svg.contains("PASS")))
  #expect(
    try String(contentsOf: output.appendingPathComponent("text-results.svg"), encoding: .utf8)
      .contains("&lt;field&gt;"))
  try Data("{}".utf8).write(to: text)
  #expect(
    try goldenRun(
      "render_report.swift",
      [
        "--metrics", metrics.path, "--text", text.path, "--out",
        root.appendingPathComponent("bad").path,
      ], root: root
    ).exitCode == 1)
}
