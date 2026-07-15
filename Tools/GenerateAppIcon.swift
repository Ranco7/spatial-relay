import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift GenerateAppIcon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let pixelSize = 1_024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create the app-icon canvas")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
NSColor.clear.setFill()
canvas.fill()

let tile = canvas.insetBy(dx: 58, dy: 58)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 215, yRadius: 215)
tilePath.addClip()

let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.055, green: 0.77, blue: 0.48, alpha: 1),
    NSColor(calibratedRed: 0.035, green: 0.55, blue: 0.88, alpha: 1),
    NSColor(calibratedRed: 0.19, green: 0.23, blue: 0.72, alpha: 1)
])!
background.draw(in: tilePath, angle: -42)

let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.28),
                      ending: NSColor.white.withAlphaComponent(0))!
glow.draw(fromCenter: NSPoint(x: 340, y: 760),
          radius: 10,
          toCenter: NSPoint(x: 340, y: 760),
          radius: 520,
          options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])

func strokedArc(radius: CGFloat, start: CGFloat, end: CGFloat, alpha: CGFloat, width: CGFloat) {
    let path = NSBezierPath()
    path.appendArc(
        withCenter: NSPoint(x: 512, y: 510),
        radius: radius,
        startAngle: start,
        endAngle: end
    )
    path.lineWidth = width
    path.lineCapStyle = .round
    NSColor.white.withAlphaComponent(alpha).setStroke()
    path.stroke()
}

// Offset arcs suggest a sound field without depending on an Apple-owned symbol.
strokedArc(radius: 324, start: 37, end: 143, alpha: 0.25, width: 30)
strokedArc(radius: 324, start: 217, end: 323, alpha: 0.25, width: 30)
strokedArc(radius: 246, start: 42, end: 138, alpha: 0.43, width: 34)
strokedArc(radius: 246, start: 222, end: 318, alpha: 0.43, width: 34)

let barHeights: [CGFloat] = [152, 248, 330, 248, 152]
let barWidth: CGFloat = 62
let gap: CGFloat = 29
let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
var x = (CGFloat(pixelSize) - totalWidth) / 2

NSColor.white.setFill()
for height in barHeights {
    let rect = NSRect(x: x, y: 510 - height / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

for point in [NSPoint(x: 512, y: 834), NSPoint(x: 512, y: 186)] {
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x - 21, y: point.y - 21, width: 42, height: 42)).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode the app icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
