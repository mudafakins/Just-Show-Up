// Draws the app icon (✦✦ on a dark rounded square) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the project root)
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// macOS icon grid: an 824pt rounded square centred on a 1024pt canvas, with a soft shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1),
])!.draw(in: shape, angle: -90)

// The mark, centred.
let text = NSAttributedString(string: "✦✦", attributes: [
    .font: NSFont.systemFont(ofSize: 380, weight: .regular),
    .foregroundColor: NSColor.white,
    .kern: 14,
])
let line = CTLineCreateWithAttributedString(text)
let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let origin = NSPoint(
    x: tile.midX - glyphs.width / 2 - glyphs.minX,
    y: tile.midY - glyphs.height / 2 - glyphs.minY
)
let context = NSGraphicsContext.current!.cgContext
context.textPosition = origin
CTLineDraw(line, context)

image.unlockFocus()

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try png(points * scale).write(to: iconset.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
