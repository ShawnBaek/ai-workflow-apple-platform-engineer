#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Arguments {
  let figma: URL
  let actual: URL
  let output: URL
  let threshold: Int
}

struct RGBAImage {
  let width: Int
  let height: Int
  var pixels: [UInt8]
}

enum ScriptError: LocalizedError {
  case usage(String)
  case invalidImage(URL)
  case dimensionsDiffer(CGSize, CGSize)
  case couldNotWrite(URL)

  var errorDescription: String? {
    switch self {
    case let .usage(message): return message
    case let .invalidImage(url): return "Could not read PNG: \(url.path)"
    case let .dimensionsDiffer(figma, actual):
      return "input dimensions differ: figma=\(Int(figma.width))x\(Int(figma.height)), actual=\(Int(actual.width))x\(Int(actual.height))"
    case let .couldNotWrite(url): return "Could not write PNG: \(url.path)"
    }
  }
}

func value(after flag: String, in arguments: [String]) throws -> String {
  guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
    throw ScriptError.usage("Missing value for \(flag)")
  }
  return arguments[index + 1]
}

func parseArguments() throws -> Arguments {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard !arguments.contains("--help") else {
    throw ScriptError.usage("Usage: overlay_diff.swift --figma <PNG> --actual <PNG> --out <directory> [--threshold <0...255>]")
  }
  let figma = URL(fileURLWithPath: try value(after: "--figma", in: arguments))
  let actual = URL(fileURLWithPath: try value(after: "--actual", in: arguments))
  let output = URL(fileURLWithPath: try value(after: "--out", in: arguments))
  let threshold = arguments.contains("--threshold")
    ? (Int(try value(after: "--threshold", in: arguments)) ?? 16)
    : 16
  guard (0...255).contains(threshold) else {
    throw ScriptError.usage("--threshold must be between 0 and 255")
  }
  return Arguments(figma: figma, actual: actual, output: output, threshold: threshold)
}

func loadImage(_ url: URL) throws -> RGBAImage {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { throw ScriptError.invalidImage(url) }

  let width = image.width
  let height = image.height
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
  let rendered = pixels.withUnsafeMutableBytes { bytes in
    guard let baseAddress = bytes.baseAddress,
          let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
          )
    else { return false }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }
  guard rendered else { throw ScriptError.invalidImage(url) }
  return RGBAImage(width: width, height: height, pixels: pixels)
}

func makeCGImage(_ image: RGBAImage) -> CGImage? {
  let data = Data(image.pixels) as CFData
  guard let provider = CGDataProvider(data: data) else { return nil }
  return CGImage(
    width: image.width,
    height: image.height,
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: image.width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent
  )
}

func writePNG(_ image: RGBAImage, to url: URL) throws {
  guard let cgImage = makeCGImage(image),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw ScriptError.couldNotWrite(url) }
  CGImageDestinationAddImage(destination, cgImage, nil)
  guard CGImageDestinationFinalize(destination) else { throw ScriptError.couldNotWrite(url) }
}

func blend(_ lhs: RGBAImage, _ rhs: RGBAImage) -> RGBAImage {
  var pixels = lhs.pixels
  for index in stride(from: 0, to: pixels.count, by: 4) {
    for channel in 0..<4 {
      pixels[index + channel] = UInt8((Int(lhs.pixels[index + channel]) + Int(rhs.pixels[index + channel])) / 2)
    }
  }
  return RGBAImage(width: lhs.width, height: lhs.height, pixels: pixels)
}

func heatmap(_ lhs: RGBAImage, _ rhs: RGBAImage) -> RGBAImage {
  var pixels = lhs.pixels
  for index in stride(from: 0, to: pixels.count, by: 4) {
    for channel in 0..<3 {
      let delta = abs(Int(lhs.pixels[index + channel]) - Int(rhs.pixels[index + channel]))
      let contrasted = max(0, min(255, (delta - 128) * 3 + 128))
      pixels[index + channel] = UInt8(contrasted)
    }
    pixels[index + 3] = 255
  }
  return RGBAImage(width: lhs.width, height: lhs.height, pixels: pixels)
}

func sideBySide(_ lhs: RGBAImage, _ rhs: RGBAImage) -> RGBAImage {
  var pixels = [UInt8](repeating: 255, count: lhs.width * 2 * lhs.height * 4)
  for y in 0..<lhs.height {
    for x in 0..<lhs.width {
      let source = (y * lhs.width + x) * 4
      let left = (y * lhs.width * 2 + x) * 4
      let right = (y * lhs.width * 2 + lhs.width + x) * 4
      pixels.replaceSubrange(left..<(left + 4), with: lhs.pixels[source..<(source + 4)])
      pixels.replaceSubrange(right..<(right + 4), with: rhs.pixels[source..<(source + 4)])
    }
  }
  return RGBAImage(width: lhs.width * 2, height: lhs.height, pixels: pixels)
}

func writeMetrics(figma: RGBAImage, actual: RGBAImage, threshold: Int, to url: URL) throws {
  var exact = 0
  var matching = 0
  var sumDelta = 0
  var maxDelta = 0
  for index in stride(from: 0, to: figma.pixels.count, by: 4) {
    let delta = (0..<3).map { abs(Int(figma.pixels[index + $0]) - Int(actual.pixels[index + $0])) }.max() ?? 0
    exact += delta == 0 ? 1 : 0
    matching += delta <= threshold ? 1 : 0
    sumDelta += delta
    maxDelta = max(maxDelta, delta)
  }
  let count = figma.width * figma.height
  let metrics: [String: Any] = [
    "comparison": "raw pixel agreement; not perceptual correctness",
    "dimensions": ["width": figma.width, "height": figma.height],
    "threshold": threshold,
    "exactPixels": exact,
    "matchingPixels": matching,
    "pixelCount": count,
    "exactPercentage": Double(exact) * 100 / Double(count),
    "matchPercentage": Double(matching) * 100 / Double(count),
    "meanMaxRGBDelta": Double(sumDelta) / Double(count),
    "maxRGBDelta": maxDelta,
    "transformations": "CoreGraphics device-RGB decode; no scaling, cropping, or masking"
  ]
  let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: url)
}

do {
  let arguments = try parseArguments()
  let figma = try loadImage(arguments.figma)
  let actual = try loadImage(arguments.actual)
  guard figma.width == actual.width, figma.height == actual.height else {
    throw ScriptError.dimensionsDiffer(
      CGSize(width: figma.width, height: figma.height),
      CGSize(width: actual.width, height: actual.height)
    )
  }
  try FileManager.default.createDirectory(at: arguments.output, withIntermediateDirectories: true)
  try writePNG(blend(figma, actual), to: arguments.output.appendingPathComponent("overlay.png"))
  try writePNG(heatmap(figma, actual), to: arguments.output.appendingPathComponent("diff.png"))
  try writePNG(sideBySide(figma, actual), to: arguments.output.appendingPathComponent("side-by-side.png"))
  try writeMetrics(figma: figma, actual: actual, threshold: arguments.threshold, to: arguments.output.appendingPathComponent("metrics.json"))
  print(arguments.output.path)
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(1)
}
