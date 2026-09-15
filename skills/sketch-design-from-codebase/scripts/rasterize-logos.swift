import AppKit
// usage: swift rasterize-logos.swift <outDir> <scale> <heightPt> file...
// Rasterizes SVG/PNG/PDF logos to <name>_h<heightPt>.png at the given scale, preserving aspect ratio.
let a = CommandLine.arguments
let outDir = a[1]; let scale = CGFloat(Double(a[2])!); let hPt = CGFloat(Double(a[3])!)
for path in a.dropFirst(4) {
  guard let img = NSImage(contentsOfFile: path), img.size.height > 0 else { print("FAIL \(path)"); continue }
  let ratio = img.size.width / img.size.height
  let sz = NSSize(width: (hPt * ratio).rounded(), height: hPt)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sz.width*scale), pixelsHigh: Int(sz.height*scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = sz
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  img.draw(in: NSRect(origin: .zero, size: sz), from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  let name = (path as NSString).lastPathComponent.components(separatedBy: ".")[0].lowercased().replacingOccurrences(of: " ", with: "_")
  let file = "\(outDir)/\(name)_h\(Int(hPt)).png"
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
  print("OK \(name) \(Int(sz.width))x\(Int(sz.height))pt -> \(file)")
}
