// Draws Swivel's app icon (an original design: a format wheel on a rounded square).
// Usage: swift scripts/icon.swift out.png   (1024x1024)
import AppKit

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824pt rounded square centred on a 1024 canvas, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x1B2A4A)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x2E5BFF), rgb(0x1A2F7A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// The wheel: 6 slices, one lit, with even gaps cut out of a transparency layer.
let c = CGPoint(x: 512, y: 512), outer: CGFloat = 300, inner: CGFloat = 105, n = 6
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
for i in 0..<n {
    let a0 = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / CGFloat(n), a1 = a0 - 2 * .pi / CGFloat(n)
    let p = CGMutablePath()
    p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: true)
    p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: false)
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(i == 0 ? rgb(0xFFFFFF) : rgb(0xFFFFFF, 0.22))
    ctx.fillPath()
}
ctx.setBlendMode(.clear); ctx.setLineWidth(22)
for i in 0..<n {
    let a = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / CGFloat(n)
    ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + (outer + 10) * cos(a), y: c.y + (outer + 10) * sin(a)))
}
ctx.strokePath()
ctx.fillEllipse(in: CGRect(x: c.x - inner + 8, y: c.y - inner + 8, width: 2 * inner - 16, height: 2 * inner - 16))
ctx.endTransparencyLayer()
ctx.setBlendMode(.normal)

// Hub: a clockwise "turn into" arrow.
ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setFillColor(rgb(0xFFFFFF))
let r: CGFloat = 46, start = CGFloat.pi * 1.0, end = CGFloat.pi * 0.22
ctx.setLineWidth(18); ctx.setLineCap(.round)
ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end + 0.25, clockwise: true); ctx.strokePath()
let pt = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
let t = CGPoint(x: sin(end), y: -cos(end)), nrm = CGPoint(x: cos(end), y: sin(end)) // travel direction, outward normal
ctx.move(to: CGPoint(x: pt.x + t.x * 30, y: pt.y + t.y * 30))
ctx.addLine(to: CGPoint(x: pt.x + nrm.x * 28 - t.x * 10, y: pt.y + nrm.y * 28 - t.y * 10))
ctx.addLine(to: CGPoint(x: pt.x - nrm.x * 28 - t.x * 10, y: pt.y - nrm.y * 28 - t.y * 10))
ctx.fillPath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
