// Draws the DMG window background: an arrow from the app to Applications.
// Usage: swift scripts/dmg-background.swift out.png scale   (600x400 points)
import AppKit

let scale = CGFloat(Double(CommandLine.arguments[2])!)
let w: CGFloat = 600, h: CGFloat = 400
let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
// Mid-tone, so Finder's icon labels stay readable in both light (black text) and dark mode (white text).
let g = CGGradient(colorsSpace: nil, colors: [rgb(0xA9B6CC), rgb(0x8394B2)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: .zero, options: [])

// Arrow between the icons (icons sit at x=150 and x=450, y=190 from the top).
let y = h - 190
ctx.setStrokeColor(rgb(0xFFFFFF, 0.9)); ctx.setFillColor(rgb(0xFFFFFF, 0.9))
ctx.setLineWidth(8); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 245, y: y)); ctx.addLine(to: CGPoint(x: 340, y: y)); ctx.strokePath()
ctx.move(to: CGPoint(x: 362, y: y)); ctx.addLine(to: CGPoint(x: 334, y: y + 20)); ctx.addLine(to: CGPoint(x: 334, y: y - 20)); ctx.fillPath()

NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let text = NSAttributedString(string: "Drag Swivel into Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
text.draw(at: NSPoint(x: (w - text.size().width) / 2, y: 62))

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
