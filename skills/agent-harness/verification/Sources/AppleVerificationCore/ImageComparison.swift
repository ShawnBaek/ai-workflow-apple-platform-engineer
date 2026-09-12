import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Produces an exact, coordinate-based visual comparison. It deliberately makes no
/// claim about visual parity and has no tolerance or pass/fail policy.
public enum ImageComparison {
  public static func render(manifest: URL, outputDirectory: URL) throws -> URL {
    try Engine(manifestURL: manifest, outputDirectory: outputDirectory).render()
  }
}

private enum Limits {
  static let manifestBytes = 1_048_576
  static let sourcePixels = 20_000_000
  static let outputPixels = 24_000_000
  static let maxDimension = 16_384
  static let maxLandmarks = 200
  static let maxNameUTF8 = 256
  static let maxOutputScale = 8.0
}

private struct Manifest: Decodable {
  let referencePath: String
  let actualPath: String
  let viewportWidthPoints: Double
  let viewportHeightPoints: Double
  let landmarks: [Landmark]
  let outputScale: Double?
}

private struct Landmark: Decodable {
  let name: String
  let referenceX: Double
  let referenceY: Double
  let actualX: Double
  let actualY: Double
}

private struct Raster {
  let image: CGImage
  let width: Int
  let height: Int
  let scale: Double
  let hash: String
}

private struct Report: Encodable {
  struct Input: Encodable {
    let path: String
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let scalePixelsPerPoint: Double
  }
  struct Transform: Encodable {
    let pointToPixelScale: Double
    let panelOriginXPoints: Double
    let panelOriginYPoints: Double
  }
  struct Delta: Encodable {
    let name: String
    let referenceX: Double
    let referenceY: Double
    let actualX: Double
    let actualY: Double
    let deltaXPoints: Double
    let deltaYPoints: Double
  }
  let schemaVersion = 1
  let viewportWidthPoints: Double
  let viewportHeightPoints: Double
  let outputScale: Double
  let reference: Input
  let actual: Input
  let transforms: [String: Transform]
  let landmarks: [Delta]
  let outputs: [String: String]
  let note =
    "Coordinate evidence only. No tolerance, pass/fail result, or UI-parity verdict is inferred."
}

private final class Engine {
  let manifestURL: URL
  let outputDirectory: URL
  init(manifestURL: URL, outputDirectory: URL) {
    self.manifestURL = manifestURL
    self.outputDirectory = outputDirectory
  }

  func render() throws -> URL {
    let manifest = try loadManifest()
    let viewport = try validate(manifest)
    let base = manifestURL.deletingLastPathComponent()
    let referenceURL = try resolved(manifest.referencePath, relativeTo: base)
    let actualURL = try resolved(manifest.actualPath, relativeTo: base)
    let reference = try loadRaster(referenceURL, viewport: viewport)
    let actual = try loadRaster(actualURL, viewport: viewport)
    let cleanURL = outputDirectory.appendingPathComponent("comparison-clean.png")
    let annotatedURL = outputDirectory.appendingPathComponent("comparison-annotated.png")
    let reportURL = outputDirectory.appendingPathComponent("comparison-report.json")
    try prepareOutput(
      [cleanURL, annotatedURL, reportURL], sources: [referenceURL, actualURL, manifestURL])

    let canvas = try Canvas(
      viewport: viewport, outputScale: manifest.outputScale ?? 2,
      landmarkCount: manifest.landmarks.count)
    try autoreleasepool {
      try writePNG(
        canvas.draw(
          reference: reference, actual: actual, landmarks: manifest.landmarks, annotated: false),
        to: cleanURL)
    }
    try autoreleasepool {
      try writePNG(
        canvas.draw(
          reference: reference, actual: actual, landmarks: manifest.landmarks, annotated: true),
        to: annotatedURL)
    }

    let deltas = manifest.landmarks.map {
      Report.Delta(
        name: $0.name, referenceX: $0.referenceX, referenceY: $0.referenceY, actualX: $0.actualX,
        actualY: $0.actualY, deltaXPoints: $0.actualX - $0.referenceX,
        deltaYPoints: $0.actualY - $0.referenceY)
    }
    let report = Report(
      viewportWidthPoints: viewport.width, viewportHeightPoints: viewport.height,
      outputScale: manifest.outputScale ?? 2,
      reference: .init(
        path: manifest.referencePath, sha256: reference.hash, pixelWidth: reference.width,
        pixelHeight: reference.height, scalePixelsPerPoint: reference.scale),
      actual: .init(
        path: manifest.actualPath, sha256: actual.hash, pixelWidth: actual.width,
        pixelHeight: actual.height, scalePixelsPerPoint: actual.scale),
      transforms: [
        "reference": .init(
          pointToPixelScale: canvas.scale,
          panelOriginXPoints: canvas.referenceOrigin.x / canvas.scale,
          panelOriginYPoints: canvas.panelOriginY / canvas.scale),
        "actual": .init(
          pointToPixelScale: canvas.scale, panelOriginXPoints: canvas.actualOrigin.x / canvas.scale,
          panelOriginYPoints: canvas.panelOriginY / canvas.scale),
      ],
      landmarks: deltas,
      outputs: [
        "cleanPNG": cleanURL.lastPathComponent, "annotatedPNG": annotatedURL.lastPathComponent,
        "reportJSON": reportURL.lastPathComponent,
      ]
    )
    let encoded = try JSONEncoder.pretty.encode(report)
    try encoded.write(to: reportURL, options: [.withoutOverwriting])
    return reportURL
  }

  private func loadManifest() throws -> Manifest {
    let info = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= Limits.manifestBytes else {
      throw ComparisonError.invalid("manifest must be a bounded regular file")
    }
    let data = try HarnessRuntime.readRegularFile(manifestURL, maximumBytes: Limits.manifestBytes)
    guard data.count <= Limits.manifestBytes else {
      throw ComparisonError.invalid("manifest exceeds \(Limits.manifestBytes) bytes")
    }
    do { return try JSONDecoder().decode(Manifest.self, from: data) } catch {
      throw ComparisonError.invalid("malformed manifest: \(error.localizedDescription)")
    }
  }

  private func validate(_ m: Manifest) throws -> CGSize {
    guard finitePositive(m.viewportWidthPoints), finitePositive(m.viewportHeightPoints),
      m.viewportWidthPoints <= Double(Limits.maxDimension),
      m.viewportHeightPoints <= Double(Limits.maxDimension)
    else {
      throw ComparisonError.invalid("viewport dimensions must be finite, positive, and bounded")
    }
    let scale = m.outputScale ?? 2
    guard finitePositive(scale), scale <= Limits.maxOutputScale else {
      throw ComparisonError.invalid(
        "outputScale must be finite, positive, and at most \(Limits.maxOutputScale)")
    }
    guard m.landmarks.count <= Limits.maxLandmarks else {
      throw ComparisonError.invalid("too many landmarks")
    }
    for mark in m.landmarks {
      guard !mark.name.isEmpty, mark.name.lengthOfBytes(using: .utf8) <= Limits.maxNameUTF8 else {
        throw ComparisonError.invalid("landmark names must be nonempty and bounded")
      }
      for value in [mark.referenceX, mark.referenceY, mark.actualX, mark.actualY]
      where !value.isFinite {
        throw ComparisonError.invalid("landmark \(mark.name) has a non-finite coordinate")
      }
      guard
        inBounds(
          mark.referenceX, mark.referenceY, width: m.viewportWidthPoints,
          height: m.viewportHeightPoints),
        inBounds(
          mark.actualX, mark.actualY, width: m.viewportWidthPoints, height: m.viewportHeightPoints)
      else {
        throw ComparisonError.invalid("landmark \(mark.name) is outside the declared viewport")
      }
    }
    return CGSize(width: m.viewportWidthPoints, height: m.viewportHeightPoints)
  }

  private func resolved(_ path: String, relativeTo base: URL) throws -> URL {
    guard !path.isEmpty else { throw ComparisonError.invalid("image path is empty") }
    let candidate = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
      .resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: candidate.path) else {
      throw ComparisonError.invalid("image does not exist: \(path)")
    }
    return candidate
  }

  private func loadRaster(_ url: URL, viewport: CGSize) throws -> Raster {
    let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 32 * 1_024 * 1_024 else {
      throw ComparisonError.invalid("source file exceeds 32 MiB")
    }
    let bytes = try HarnessRuntime.readRegularFile(url, maximumBytes: 32 * 1_024 * 1_024)
    guard bytes.count <= 32 * 1_024 * 1_024 else {
      throw ComparisonError.invalid("source file grew beyond limit")
    }
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      throw ComparisonError.invalid(
        "could not read a single raster image: \(url.lastPathComponent)")
    }
    guard width > 0, height > 0, width <= Limits.maxDimension, height <= Limits.maxDimension,
      width <= Limits.sourcePixels / height
    else {
      throw ComparisonError.invalid("image dimensions exceed limits: \(url.lastPathComponent)")
    }
    guard (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else {
      throw ComparisonError.invalid(
        "source orientation must be upright; preserve and explicitly normalize a copy before comparing"
      )
    }
    let sx = Double(width) / viewport.width
    let sy = Double(height) / viewport.height
    guard sx.isFinite, sy.isFinite, abs(sx - sy) <= max(1e-9, sx * 1e-9) else {
      throw ComparisonError.invalid(
        "image aspect ratio or scale is inconsistent with the declared viewport: \(url.lastPathComponent)"
      )
    }
    guard
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw ComparisonError.invalid("could not decode image: \(url.lastPathComponent)") }
    return Raster(
      image: image, width: width, height: height, scale: sx, hash: HarnessRuntime.sha256(bytes))
  }

  private func prepareOutput(_ outputs: [URL], sources: [URL]) throws {
    let manager = FileManager.default
    let canonicalSources = Set(
      sources.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
    for output in outputs {
      let path = output.standardizedFileURL.resolvingSymlinksInPath().path
      guard !canonicalSources.contains(path) else {
        throw ComparisonError.invalid("refusing to overwrite a source file")
      }
      guard !manager.fileExists(atPath: output.path) else {
        throw ComparisonError.invalid("output collision: \(output.lastPathComponent)")
      }
    }
    // Claim one new private output directory atomically. Existing directories,
    // including symlinks and competing renders, are never reused.
    guard mkdir(outputDirectory.path, 0o700) == 0 else {
      throw ComparisonError.invalid("output directory must be new and have an existing parent")
    }
  }
}

private struct Canvas {
  let viewport: CGSize
  let scale: Double
  let panelWidth: Int
  let panelHeight: Int
  let gutter: Int
  let captionHeight: Int = 52
  let legendHeight: Int
  let panelOriginY: Double
  let referenceOrigin: CGPoint
  let actualOrigin: CGPoint

  init(viewport: CGSize, outputScale: Double, landmarkCount: Int) throws {
    self.viewport = viewport
    self.scale = outputScale
    panelWidth = try pixels(viewport.width, scale: outputScale)
    panelHeight = try pixels(viewport.height, scale: outputScale)
    gutter = max(24, Int((12 * outputScale).rounded(.up)))
    // One independent legend line per landmark; no clipping or elision hides a measured offset.
    let legendPoints = 20.0 + Double(landmarkCount) * 16.0
    let legendPixels = Int((legendPoints * outputScale).rounded(.up))
    legendHeight = max(80, legendPixels)
    panelOriginY = Double(captionHeight)
    referenceOrigin = CGPoint(x: 0, y: Double(captionHeight))
    actualOrigin = CGPoint(x: Double(panelWidth + gutter), y: Double(captionHeight))
    let totalWidth = 2 * panelWidth + gutter
    let totalHeight = captionHeight + panelHeight + legendHeight
    guard totalWidth > 0, totalHeight > 0, totalWidth <= Limits.maxDimension,
      totalHeight <= Limits.maxDimension, totalWidth <= Limits.outputPixels / totalHeight
    else { throw ComparisonError.invalid("requested output image exceeds pixel limits") }
  }

  func draw(reference: Raster, actual: Raster, landmarks: [Landmark], annotated: Bool) throws
    -> CGImage
  {
    let width = 2 * panelWidth + gutter
    let height = captionHeight + panelHeight + legendHeight
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ComparisonError.invalid("could not create output canvas") }
    // All public coordinates are top-left-origin points.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 0.10, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawImage(
      reference.image, in: CGRect(x: 0, y: captionHeight, width: panelWidth, height: panelHeight),
      context: context)
    drawImage(
      actual.image,
      in: CGRect(x: panelWidth + gutter, y: captionHeight, width: panelWidth, height: panelHeight),
      context: context)
    text(
      annotated
        ? "ANNOTATED — exact point offsets" : "CLEAN — source pixels resampled to output scale",
      at: CGPoint(x: 12, y: 15), color: .white, context: context, size: 15)
    text("Reference", at: CGPoint(x: 0, y: 34), color: .white, context: context, size: 12)
    text(
      "Actual", at: CGPoint(x: panelWidth + gutter, y: 34), color: .white, context: context,
      size: 12)
    if annotated {
      drawAnnotations(landmarks, context: context, width: width)
    } else {
      text(
        "No guides or coordinate annotations",
        at: CGPoint(x: 12, y: captionHeight + panelHeight + 18),
        color: CGColor(gray: 0.75, alpha: 1), context: context, size: 12)
    }
    guard let image = context.makeImage() else {
      throw ComparisonError.invalid("could not finalize output canvas")
    }
    return image
  }

  private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }
  private func drawAnnotations(_ landmarks: [Landmark], context: CGContext, width: Int) {
    let colors: [CGColor] = [
      CGColor(red: 0.95, green: 0.20, blue: 0.20, alpha: 1),
      CGColor(red: 0.20, green: 0.85, blue: 0.35, alpha: 1),
      CGColor(red: 0.25, green: 0.55, blue: 1.00, alpha: 1),
      CGColor(red: 1.00, green: 0.55, blue: 0.10, alpha: 1),
      CGColor(red: 0.70, green: 0.35, blue: 0.90, alpha: 1),
      CGColor(red: 0.10, green: 0.80, blue: 0.78, alpha: 1),
    ]
    let bottom = Double(captionHeight + panelHeight)
    for (index, mark) in landmarks.enumerated() {
      let color = colors[index % colors.count]
      let ref = point(mark.referenceX, mark.referenceY, origin: referenceOrigin)
      let act = point(mark.actualX, mark.actualY, origin: actualOrigin)
      // The shared line marks reference y in both panels; actual markers show signed vertical offset from it.
      line(
        from: CGPoint(x: 0, y: ref.y), to: CGPoint(x: Double(width), y: ref.y), color: color,
        alpha: 0.52, context: context)
      line(
        from: CGPoint(x: ref.x, y: panelOriginY), to: CGPoint(x: ref.x, y: bottom), color: color,
        alpha: 0.75, context: context)
      let referenceXInActualPanel = actualOrigin.x + mark.referenceX * scale
      line(
        from: CGPoint(x: referenceXInActualPanel, y: panelOriginY),
        to: CGPoint(x: referenceXInActualPanel, y: bottom), color: color, alpha: 0.75,
        context: context)
      context.setLineDash(phase: 0, lengths: [3, 3])
      line(
        from: CGPoint(x: act.x, y: panelOriginY), to: CGPoint(x: act.x, y: bottom), color: color,
        alpha: 0.75, context: context)
      context.setLineDash(phase: 0, lengths: [])
      marker(ref, color: color, context: context)
      marker(act, color: color, context: context)
      text(
        mark.name, at: CGPoint(x: act.x + 5, y: act.y + 4), color: color, context: context, size: 11
      )
    }
    var y = captionHeight + panelHeight + 14
    for mark in landmarks {
      text(
        "\(mark.name): Δx \(signed(mark.actualX - mark.referenceX)) pt, Δy \(signed(mark.actualY - mark.referenceY)) pt",
        at: CGPoint(x: 12, y: y), color: .white, context: context, size: 12)
      y += 16
    }
  }
  private func point(_ x: Double, _ y: Double, origin: CGPoint) -> CGPoint {
    CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
  }
  private func line(from: CGPoint, to: CGPoint, color: CGColor, alpha: CGFloat, context: CGContext)
  {
    context.setStrokeColor(color.copy(alpha: alpha)!)
    context.setLineWidth(1)
    context.move(to: from)
    context.addLine(to: to)
    context.strokePath()
  }
  private func marker(_ point: CGPoint, color: CGColor, context: CGContext) {
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
  }
}

private enum ComparisonError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    if case .invalid(let text) = self { return text }
    return nil
  }
}
private func finitePositive(_ value: Double) -> Bool { value.isFinite && value > 0 }
private func inBounds(_ x: Double, _ y: Double, width: Double, height: Double) -> Bool {
  x >= 0 && x <= width && y >= 0 && y <= height
}
private func pixels(_ points: Double, scale: Double) throws -> Int {
  let value = (points * scale).rounded(.up)
  guard value.isFinite, value > 0, value <= Double(Int.max) else {
    throw ComparisonError.invalid("output dimension is invalid")
  }
  return Int(value)
}
private func signed(_ value: Double) -> String { String(format: "%+.3f", value) }
private func text(
  _ string: String, at point: CGPoint, color: CGColor, context: CGContext, size: CGFloat
) {
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
      "SF Pro Text" as CFString, size, nil),
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
  ]
  let line = CTLineCreateWithAttributedString(
    NSAttributedString(string: string, attributes: attributes))
  context.saveGState()
  context.translateBy(x: point.x, y: point.y + size)
  context.scaleBy(x: 1, y: -1)
  context.textPosition = .zero
  CTLineDraw(line, context)
  context.restoreGState()
}
private func writePNG(_ image: CGImage, to url: URL) throws {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw ComparisonError.invalid("could not create PNG output") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw ComparisonError.invalid("could not write PNG output")
  }
}
extension JSONEncoder {
  fileprivate static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
