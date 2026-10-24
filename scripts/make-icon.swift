import AppKit
import Foundation

let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(red: 0.08, green: 0.34, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
        NSColor(red: 0.92, green: 0.97, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 285, y: 220, width: 460, height: 610), xRadius: 38, yRadius: 38).fill()
        NSColor(red: 0.27, green: 0.65, blue: 0.52, alpha: 1).setFill()
        for (y, width) in [(680, 280), (600, 200), (520, 280)] {
            NSBezierPath(roundedRect: NSRect(x: 375, y: y, width: width, height: 28), xRadius: 14, yRadius: 14).fill()
        }
        NSColor(red: 0.08, green: 0.34, blue: 0.31, alpha: 1).setStroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: 435, y: 385)); check.line(to: NSPoint(x: 500, y: 320)); check.line(to: NSPoint(x: 620, y: 430))
        check.lineWidth = 35; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: iconset)
