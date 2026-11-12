// Builds AppIcon.iconset from Resources/AppIcon-source.png.
//
// The source art is already a square icon, so this only reshapes it to Apple's
// macOS grid: the art occupies 824/1024 of the canvas and is masked with a
// continuous-corner "squircle" (CALayer's own cornerCurve, so the curve matches
// the system exactly), with a soft drop shadow underneath.
//
// Usage: swift make-icon.swift <source.png> <output iconset dir>
import AppKit
import QuartzCore

let args = CommandLine.arguments
let sourcePath = args.count > 1 ? args[1] : "Resources/AppIcon-source.png"
let outDir = args.count > 2 ? args[2] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

guard let source = NSImage(contentsOfFile: sourcePath),
      let srcCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("make-icon: cannot read \(sourcePath)\n".utf8))
    exit(1)
}

// Apple's macOS icon grid, as fractions of the full canvas.
let contentFraction: CGFloat = 824.0 / 1024.0   // art square inside the canvas
let radiusFraction: CGFloat = 0.2237            // corner radius / art side

func render(_ px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let side = (s * contentFraction).rounded()
    let origin = ((s - side) / 2).rounded()
    let rect = CGRect(x: origin, y: origin, width: side, height: side)

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high

    // The squircle, drawn by CALayer so the corner curve is Apple's own.
    let layer = CALayer()
    layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
    layer.contents = srcCG
    layer.contentsGravity = .resizeAspectFill
    // Below ~32 px the whole figure turns to mush, so crop in on the hat, glasses
    // and raised finger, which stay recognisable as a silhouette.
    if px <= 32 {
        // contentsRect runs bottom-up here, so this trims the coat and keeps the hat.
        layer.contentsRect = CGRect(x: 0.060, y: 0.120, width: 0.880, height: 0.880)
    }
    layer.cornerRadius = side * radiusFraction
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    layer.isGeometryFlipped = false
    layer.contentsScale = 1

    // Render the layer to its own bitmap, then composite it with a shadow.
    let art = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    art.size = NSSize(width: side, height: side)
    let artGC = NSGraphicsContext(bitmapImageRep: art)!
    artGC.cgContext.interpolationQuality = .high
    layer.render(in: artGC.cgContext)
    artGC.flushGraphics()

    ctx.saveGState()
    // Shadow scaled to the canvas, so it looks the same at every size.
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.014), blur: s * 0.030,
                  color: NSColor.black.withAlphaComponent(0.42).cgColor)
    if let artCG = art.cgImage { ctx.draw(artCG, in: rect) }
    ctx.restoreGState()

    gc.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = render(px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("make-icon: wrote \(sizes.count) PNGs to \(outDir) from \(sourcePath)")
