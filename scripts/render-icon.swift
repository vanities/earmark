// Renders the 1024×1024 app icon: warm amber gradient, white headphones, dark bookmark ribbon.
//   swift scripts/render-icon.swift Earmark/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let pixels = 1024

guard let cgContext = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: false)
let size = CGFloat(pixels)
let canvas = NSRect(x: 0, y: 0, width: size, height: size)

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.98, green: 0.74, blue: 0.36, alpha: 1),
    NSColor(srgbRed: 0.86, green: 0.50, blue: 0.16, alpha: 1),
    NSColor(srgbRed: 0.62, green: 0.31, blue: 0.09, alpha: 1),
])!
gradient.draw(in: canvas, angle: -65)

// Soft highlight circle behind the glyph.
let glow = NSBezierPath(ovalIn: NSRect(x: size * 0.12, y: size * 0.10, width: size * 0.76, height: size * 0.76))
NSColor(white: 1, alpha: 0.10).setFill()
glow.fill()

// Headphones glyph (SF Symbol), tinted white.
if let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 560, weight: .medium)) {
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let scale = (size * 0.62) / max(tinted.size.width, tinted.size.height)
    let drawSize = NSSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
    let origin = NSPoint(x: (size - drawSize.width) / 2 - size * 0.03, y: (size - drawSize.height) / 2 - size * 0.04)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    tinted.draw(in: NSRect(origin: origin, size: drawSize))
    NSShadow().set()
}

// Bookmark ribbon tucked over the top-right edge.
let ribbon = NSBezierPath()
let rx = size * 0.68, rw = size * 0.15, rh = size * 0.40
ribbon.move(to: NSPoint(x: rx, y: size))
ribbon.line(to: NSPoint(x: rx + rw, y: size))
ribbon.line(to: NSPoint(x: rx + rw, y: size - rh))
ribbon.line(to: NSPoint(x: rx + rw / 2, y: size - rh + rw * 0.55))
ribbon.line(to: NSPoint(x: rx, y: size - rh))
ribbon.close()
let ribbonShadow = NSShadow()
ribbonShadow.shadowColor = NSColor(white: 0, alpha: 0.35)
ribbonShadow.shadowBlurRadius = 24
ribbonShadow.shadowOffset = NSSize(width: 0, height: -10)
ribbonShadow.set()
NSColor(srgbRed: 0.17, green: 0.12, blue: 0.10, alpha: 1).setFill()
ribbon.fill()

NSGraphicsContext.restoreGraphicsState()
guard let cgImage = cgContext.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
do {
    try png.write(to: URL(fileURLWithPath: output))
    print("wrote \(output) \(pixels)x\(pixels)")
} catch {
    FileHandle.standardError.write(Data("failed to write \(output): \(error)\n".utf8))
    exit(1)
}
