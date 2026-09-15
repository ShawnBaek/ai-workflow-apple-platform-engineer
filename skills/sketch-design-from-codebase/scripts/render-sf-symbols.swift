import AppKit
// usage: swift render-sf-symbols.swift <outDir> <scale> name:pointSize:weight:#RRGGBB ...
// Renders each SF Symbol with NSImage(systemSymbolName:), tints it, crops to the visible alpha box, writes <name>_<size>_<weight>_<hex>.png. Prints "OK <name> <w>x<h>px".
let a = CommandLine.arguments
let outDir = a[1]; let scale = CGFloat(Double(a[2])!)
func weight(_ s: String) -> NSFont.Weight { switch s { case "medium": return .medium; case "semibold": return .semibold; case "bold": return .bold; case "heavy": return .heavy; default: return .regular } }
func color(_ hex: String) -> NSColor { var h = hex; if h.hasPrefix("#") { h.removeFirst() }; let v = UInt32(h, radix: 16)!; return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF)/255, green: CGFloat((v >> 8) & 0xFF)/255, blue: CGFloat(v & 0xFF)/255, alpha: 1) }
for spec in a.dropFirst(3) {
  let p = spec.split(separator: ":").map(String.init)
  let name = p[0]; let size = CGFloat(Double(p[1])!); let w = weight(p[2]); let c = color(p[3])
  guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { print("MISSING \(name)"); continue }
  let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: w).applying(NSImage.SymbolConfiguration(paletteColors: [c]))
  guard let img = base.withSymbolConfiguration(cfg) else { print("CFGFAIL \(name)"); continue }
  let sz = img.size
  let pw = Int(ceil(sz.width*scale)), ph = Int(ceil(sz.height*scale))
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = sz
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  img.draw(in: NSRect(origin: .zero, size: sz)); NSGraphicsContext.restoreGraphicsState()
  var minX = pw, minY = ph, maxX = -1, maxY = -1
  for y in 0..<ph { for x in 0..<pw { if let px = rep.colorAt(x: x, y: y), px.alphaComponent > 0.02 { if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y } } } }
  if maxX < 0 { print("EMPTY \(name)"); continue }
  let cw = maxX - minX + 1, ch = maxY - minY + 1
  let crop = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: crop)
  let full = NSImage(size: NSSize(width: pw, height: ph)); full.addRepresentation(rep)
  full.draw(in: NSRect(x: 0, y: 0, width: cw, height: ch), from: NSRect(x: minX, y: ph - maxY - 1, width: cw, height: ch), operation: .copy, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  let file = "\(outDir)/\(name)_\(Int(size))_\(p[2])_\(p[3].replacingOccurrences(of: "#", with: "")).png"
  try! crop.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
  print("OK \(name) \(cw)x\(ch)px")
}
