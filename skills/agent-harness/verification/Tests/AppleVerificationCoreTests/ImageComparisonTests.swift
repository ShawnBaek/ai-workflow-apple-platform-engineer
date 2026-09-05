import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppleVerificationCore

private func fixtureImage(_ url: URL, width: Int, height: Int) throws {
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  for y in 0..<height {
    for x in 0..<width {
      let i = (y * width + x) * 4
      pixels[i] = y < height / 2 ? 240 : 20
      pixels[i + 1] = x < width / 2 ? 200 : 30
      pixels[i + 2] = y < height / 2 ? 10 : 230
      pixels[i + 3] = 255
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

private func pixel(_ url: URL, x: Int, y: Int) throws -> [UInt8] {
  let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  let context = try #require(
    CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
  return (0..<4).map { data[(y * image.width + x) * 4 + $0] }
}

@Test func alignedImagesKeepOrientationAndSignedPointDeltas() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let reference = root.appendingPathComponent("reference.png")
  let actual = root.appendingPathComponent("actual.png")
  try fixtureImage(reference, width: 100, height: 200)
  try fixtureImage(actual, width: 200, height: 400)
  let referenceHash = try HarnessRuntime.sha256File(reference)
  let manifest = root.appendingPathComponent("manifest.json")
  let output = root.appendingPathComponent("comparison")
  try HarnessRuntime.atomicWriteJSON(
    [
      "referencePath": "reference.png", "actualPath": "actual.png", "viewportWidthPoints": 100,
      "viewportHeightPoints": 200, "outputScale": 1,
      "landmarks": [
        ["name": "anchor", "referenceX": 20, "referenceY": 30, "actualX": 22.5, "actualY": 27]
      ],
    ], to: manifest)
  let report = try HarnessRuntime.object(
    ImageComparison.render(manifest: manifest, outputDirectory: output))
  let deltas = try #require(report["landmarks"] as? [[String: Any]])
  #expect(deltas[0]["deltaXPoints"] as? Double == 2.5)
  #expect(deltas[0]["deltaYPoints"] as? Double == -3)
  let transforms = try #require(report["transforms"] as? [String: [String: Any]])
  #expect(transforms["actual"]?["pointToPixelScale"] as? Double == 1)
  #expect(transforms["actual"]?["panelOriginXPoints"] as? Double == 124)
  let clean = output.appendingPathComponent("comparison-clean.png")
  #expect(try pixel(clean, x: 10, y: 62) == pixel(reference, x: 10, y: 10))
  #expect(try pixel(clean, x: 10, y: 232) == pixel(reference, x: 10, y: 180))
  #expect(try pixel(clean, x: 134, y: 62) == pixel(reference, x: 10, y: 10))
  #expect(try HarnessRuntime.sha256File(reference) == referenceHash)
  #expect(throws: (any Error).self) {
    try ImageComparison.render(manifest: manifest, outputDirectory: output)
  }
  try fixtureImage(actual, width: 200, height: 300)
  #expect(throws: (any Error).self) {
    try ImageComparison.render(
      manifest: manifest, outputDirectory: root.appendingPathComponent("mismatched"))
  }
}
