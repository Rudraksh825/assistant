// Draws the Steward app icon (an open ember ring with a dot resting in the gap) as a 1024px PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size = 1024.0
guard CommandLine.arguments.count == 2,
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.png>\n".utf8))
    exit(2)
}
NSGraphicsContext.current = context

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

// The plate sits inside the canvas with the standard macOS icon margin.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)
NSGradient(colors: [rgb(0x23262F), rgb(0x0C0D11)])!.draw(in: shape, angle: -90)
shape.lineWidth = 3
rgb(0xFFFFFF, 0.10).setStroke()
shape.stroke()

let center = NSPoint(x: size / 2, y: size / 2)
let glow = NSGradient(colors: [rgb(0xF2A65A, 0.22), rgb(0xF2A65A, 0)])!
shape.setClip()
glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 400, options: [])

let ring = NSBezierPath()
ring.appendArc(withCenter: center, radius: 210, startAngle: 78, endAngle: 12, clockwise: false)
ring.lineWidth = 62
ring.lineCapStyle = .round
rgb(0xF2A65A).setStroke()
ring.stroke()

let dot = NSRect(x: center.x + 148 - 52, y: center.y + 148 - 52, width: 104, height: 104)
rgb(0xFFE3BF).setFill()
NSBezierPath(ovalIn: dot).fill()

context.flushGraphics()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
