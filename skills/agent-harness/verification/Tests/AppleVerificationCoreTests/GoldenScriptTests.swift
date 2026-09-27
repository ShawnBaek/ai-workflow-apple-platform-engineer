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
  try goldenPNG(url, width: 1, height: 1) { _, _ in color }
}

private func goldenPNG(
  _ url: URL, width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)
) throws {
  var pixels: [UInt8] = []
  for y in 0..<height {
    for x in 0..<width {
      let value = color(x, y)
      pixels += [value.0, value.1, value.2, 255]
    }
  }
  let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
  let image = try #require(
    CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
}

/// Decodes a PNG the way the comparator does and returns each pixel's RGB, row-major.
private func goldenRGB(_ url: URL) throws -> (width: Int, pixels: [[UInt8]]) {
  let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
  let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
    guard
      let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return true
  }
  try #require(drawn)
  let pixels = stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0..<($0 + 3)]) }
  return (image.width, pixels)
}

/// Compiles a golden script once for the calling test with the active toolchain's `swiftc`
/// (`xcrun` honors `DEVELOPER_DIR`) and returns a runner for the binary. Run through the
/// `/usr/bin/swift` interpreter, every invocation recompiled the script within its own 30-second
/// budget while the other suites ran in parallel; the compile now gets a generous bound of its
/// own and each run only executes the script, still from an unrelated working directory.
private func goldenScript(_ script: String, root: URL) throws -> ([String]) throws -> ProcessResult
{
  let source = goldenRoot().appendingPathComponent("skills/figma-golden-testing/scripts/\(script)")
  let binary = root.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
  let build = try HarnessRuntime.run(
    executable: "/usr/bin/xcrun", arguments: ["swiftc", source.path, "-o", binary.path],
    timeout: 600)
  try #require(build.exitCode == 0, "\(script) did not compile: \(build.stderr)")
  return { arguments in
    try HarnessRuntime.run(
      executable: binary.path, arguments: arguments, directory: root, timeout: 60)
  }
}

@Test func goldenComparatorReportsAndEnforcesOnlyAnExplicitMinimum() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let overlayDiff = try goldenScript("overlay_diff.swift", root: root)
  let reference = root.appendingPathComponent("reference.png")
  let same = root.appendingPathComponent("same.png")
  let different = root.appendingPathComponent("different.png")
  try goldenPNG(reference, color: (0, 0, 0))
  try goldenPNG(same, color: (0, 0, 0))
  try goldenPNG(different, color: (255, 255, 255))
  let passed = try overlayDiff(
    [
      "--figma", reference.path, "--actual", same.path, "--out",
      root.appendingPathComponent("pass").path, "--minimum-match", "100",
    ])
  #expect(passed.exitCode == 0)
  #expect(
    try HarnessRuntime.object(root.appendingPathComponent("pass/metrics.json"))["status"] as? String
      == "passed")
  let mismatchOut = root.appendingPathComponent("fail")
  let failed = try overlayDiff(
    [
      "--figma", reference.path, "--actual", different.path, "--out", mismatchOut.path,
      "--minimum-match", "100",
    ])
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
  let reportOnly = try overlayDiff(
    ["--figma", reference.path, "--actual", different.path, "--out", reportOnlyOut.path])
  #expect(reportOnly.exitCode == 0)
  #expect(
    try HarnessRuntime.object(reportOnlyOut.appendingPathComponent("metrics.json"))["status"]
      as? String == "not_evaluated")
  let invalid = try overlayDiff(
    [
      "--figma", reference.path, "--actual", same.path, "--out",
      root.appendingPathComponent("invalid").path, "--minimum-match", "nan",
    ])
  #expect(invalid.exitCode == 1)
  #expect(
    try overlayDiff(
      [
        "--figma", reference.path, "--actual", same.path, "--out",
        root.appendingPathComponent("invalid-rgb").path, "--threshold", "bad",
      ]).exitCode == 1)
}

@Test func goldenDiffShowsSmallDeltasThatTheThresholdCounts() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let reference = root.appendingPathComponent("reference.png")
  let actual = root.appendingPathComponent("actual.png")
  let output = root.appendingPathComponent("report")
  let overlayDiff = try goldenScript("overlay_diff.swift", root: root)
  // An 8x8 gray frame: a 3x3 patch 20 per channel lighter (over threshold 16) and a
  // 2x2 patch 8 lighter (under it). Both deltas used to render black in diff.png.
  let failing = { (x: Int, y: Int) in (1...3).contains(x) && (1...3).contains(y) }
  let tolerated = { (x: Int, y: Int) in (5...6).contains(x) && (5...6).contains(y) }
  try goldenPNG(reference, width: 8, height: 8) { _, _ in (100, 100, 100) }
  try goldenPNG(actual, width: 8, height: 8) { x, y in
    failing(x, y) ? (120, 120, 120) : tolerated(x, y) ? (108, 108, 108) : (100, 100, 100)
  }
  let result = try overlayDiff(
    [
      "--figma", reference.path, "--actual", actual.path, "--out", output.path,
      "--threshold", "16",
    ])
  #expect(result.exitCode == 0)
  let metrics = try HarnessRuntime.object(output.appendingPathComponent("metrics.json"))
  #expect(metrics["matchingPixels"] as? Int == 64 - 9)
  let diff = try goldenRGB(output.appendingPathComponent("diff.png"))
  #expect(diff.pixels.count == 64)
  let red: [UInt8] = [255, 0, 0]
  let unchanged = diff.pixels[7 * diff.width + 7]
  #expect(unchanged[0] == unchanged[1] && unchanged[1] == unchanged[2])
  for y in 0..<8 {
    for x in 0..<8 {
      let pixel = diff.pixels[y * diff.width + x]
      if failing(x, y) {
        #expect(pixel == red, "over-threshold pixel (\(x), \(y)) must be solid red")
      } else if tolerated(x, y) {
        #expect(
          pixel != red && pixel != unchanged, "sub-threshold pixel (\(x), \(y)) must stay visible")
        #expect(pixel[0] > unchanged[0])
      } else {
        #expect(pixel == unchanged, "unchanged pixel (\(x), \(y)) must show the dimmed reference")
      }
    }
  }
}

@Test func goldenRendererRequiresValidEvidenceAndEscapesText() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let metrics = root.appendingPathComponent("metrics.json")
  let text = root.appendingPathComponent("text.json")
  let output = root.appendingPathComponent("rendered")
  let renderReport = try goldenScript("render_report.swift", root: root)
  try JSONSerialization.data(withJSONObject: [
    "matchPercentage": 0, "threshold": 0, "matchingPixels": 0, "pixelCount": 1,
    "status": "not_evaluated",
  ]).write(to: metrics)
  try JSONSerialization.data(withJSONObject: [
    "missing": [["field": "<field>", "figmaNodeId": "<node>", "expected": "<expected>"]],
    "extra": [], "changed": [], "matches": [],
  ]).write(to: text)
  let rendered = try renderReport(
    ["--metrics", metrics.path, "--text", text.path, "--out", output.path])
  #expect(rendered.exitCode == 0)
  let svg = try String(contentsOf: output.appendingPathComponent("metrics.svg"), encoding: .utf8)
  #expect(svg.contains("NOT EVALUATED"))
  #expect(!(svg.contains("PASS")))
  #expect(
    try String(contentsOf: output.appendingPathComponent("text-results.svg"), encoding: .utf8)
      .contains("&lt;field&gt;"))
  // The schema example shipped inside the skill must stay valid renderer input.
  let example = goldenRoot().appendingPathComponent(
    "skills/figma-golden-testing/references/text-results.example.json")
  let exampleOutput = root.appendingPathComponent("example")
  let exampleRun = try renderReport(
    ["--metrics", metrics.path, "--text", example.path, "--out", exampleOutput.path])
  #expect(exampleRun.exitCode == 0)
  let exampleSVG = try String(
    contentsOf: exampleOutput.appendingPathComponent("text-results.svg"), encoding: .utf8)
  for section in ["Missing", "Extra", "Changed", "Matches"] {
    #expect(exampleSVG.contains(">\(section)</text>"))
  }
  try Data("{}".utf8).write(to: text)
  #expect(
    try renderReport(
      [
        "--metrics", metrics.path, "--text", text.path, "--out",
        root.appendingPathComponent("bad").path,
      ]).exitCode == 1)
}
