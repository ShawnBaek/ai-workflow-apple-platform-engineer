import CoreGraphics
import CoreText
// Synthetic input for the comparison example; this is not a Figma export or app capture.
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let width = 280
let height = 420
let scale = 2
func image(_ name: String, offset: CGFloat) throws {
  let output = directory.appendingPathComponent(name)
  guard !FileManager.default.fileExists(atPath: output.path) else {
    throw CocoaError(.fileWriteFileExists)
  }
  let c = CGContext(
    data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
    bytesPerRow: width * scale * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  c.translateBy(x: 0, y: CGFloat(height))
  c.scaleBy(x: 1, y: -1)
  c.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1))
  c.fill(CGRect(x: 0, y: 0, width: width, height: height))
  func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, color: CGColor) {
    c.saveGState()
    c.translateBy(x: x, y: y)
    c.scaleBy(x: 1, y: -1)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
        "Helvetica" as CFString, size, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    c.textPosition = .zero
    c.textMatrix = .identity
    CTLineDraw(
      CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), c)
    c.restoreGState()
  }
  let ink = CGColor(red: 0.09, green: 0.13, blue: 0.23, alpha: 1)
  label("SYNTHETIC EXAMPLE", 24, 27, 9, color: ink)
  label("Saved places", 24 + offset / 2, 72 + offset, 25, color: ink)
  for (index, title) in ["Morning coffee", "A quiet park", "Weekend reading"].enumerated() {
    let y = 110 + CGFloat(index * 86) + (index == 0 ? offset : 0)
    let x = 24 + (index == 0 ? offset / 2 : 0)
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: x, y: y, width: 232, height: 68))
    c.setFillColor(CGColor(red: 0.1, green: 0.55, blue: 0.65, alpha: 1))
    c.fill(CGRect(x: x, y: y, width: 4, height: 68))
    label(title, x + 16, y + 28, 16, color: ink)
    label("A fixed preview state", x + 16, y + 48, 11, color: ink)
  }
  label("Fixed viewport • no live app data", 24, 392, 10, color: ink)
  let destination = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, c.makeImage()!, nil)
  guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
try image("reference.png", offset: 0)
try image("actual.png", offset: 6)
