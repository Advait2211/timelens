// Draws the TimeLens app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift <output-dir>
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Drawn on a 1024 canvas following the macOS icon grid (824pt body, 100pt margin).
func drawIcon(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x12123A).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep indigo to night blue.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x3B3FB8).cgColor, color(0x0E1640).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 720, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.20).cgColor, color(0xFFFFFF, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0, endCenter: CGPoint(x: 330, y: 820), endRadius: 600, options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 268
    let width: CGFloat = 78

    // Track.
    ctx.setLineWidth(width)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12).cgColor)
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.strokePath()

    // The day as category arcs: development blue, productivity aqua, entertainment yellow,
    // social orange — clockwise from the top, with gaps between.
    let arcs: [(fraction: CGFloat, hex: UInt32)] = [(0.30, 0x3987E5), (0.20, 0x1BAF7A), (0.17, 0xEDA100), (0.11, 0xEB6834)]
    var angle = CGFloat.pi / 2
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: color(0x000000, 0.3).cgColor)
    ctx.setLineCap(.round)
    for arc in arcs {
        let sweep = arc.fraction * 2 * .pi
        let gap: CGFloat = 0.46
        ctx.setStrokeColor(color(arc.hex).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: angle - gap / 2, endAngle: angle - sweep + gap / 2, clockwise: true)
        ctx.strokePath()
        angle -= sweep
    }
    ctx.restoreGState()

    // Clock hands.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: color(0x000000, 0.3).cgColor)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xF4F6FF).cgColor)
    ctx.setLineWidth(46)
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + 150))
    ctx.strokePath()
    ctx.setLineWidth(40)
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x + 112, y: center.y - 64))
    ctx.strokePath()
    ctx.setFillColor(color(0xF4F6FF).cgColor)
    ctx.addEllipse(in: CGRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76))
    ctx.fillPath()
    ctx.setFillColor(color(0x3B3FB8).cgColor)
    ctx.addEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
    ctx.fillPath()
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.interpolationQuality = .high
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("TimeLensIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: outputDirectory.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(outputDirectory.path)/AppIcon.icns" : "iconutil failed")
