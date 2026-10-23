// Draws Resources/social-preview.png (1280×640): the GitHub social preview / README banner, with the real wheel.
// Run from the repo root (compiled as main.swift, since it has top-level code):
//   mkdir -p /tmp/poster && cp scripts/poster.swift /tmp/poster/main.swift &&
//   swiftc -O /tmp/poster/main.swift Sources/Swivel/{Wheel,Converter,Prefs,Actions,Job,Watch}.swift -o /tmp/poster/run && /tmp/poster/run
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let W: CGFloat = 1280, H: CGFloat = 640

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// A photo-like picture for the wheel's centre: a sunset over the sea.
func samplePhoto() -> URL {
    let size = 600
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let sky = CGGradient(colorsSpace: nil, colors: [rgb(0x2B1B5A).cgColor, rgb(0xE8546B).cgColor, rgb(0xFFB45A).cgColor] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: CGFloat(size) * 0.38), options: [.drawsAfterEndLocation])
    ctx.setFillColor(rgb(0xFFE29A).cgColor)
    ctx.fillEllipse(in: CGRect(x: 210, y: 170, width: 180, height: 180))
    let sea = CGGradient(colorsSpace: nil, colors: [rgb(0x1E3A6E).cgColor, rgb(0x0E1D3D).cgColor] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: size, height: 230))
    ctx.drawLinearGradient(sea, start: CGPoint(x: 0, y: 230), end: .zero, options: [])
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xFFE29A, 0.55).cgColor)
    for i in 0..<6 { ctx.fill(CGRect(x: 240 + i % 2 * 20, y: 200 - i * 30, width: 120 - i * 14, height: 6)) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-poster-sunset.png")
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    return url
}

// The real wheel, as Swivel draws it, rendered offscreen.
func renderWheel(photo: URL) -> NSImage {
    let targets = ["jpg", "png", "heic", "webp", "pdf", "tiff", "avif", "gif"]
    let items = targets.enumerated().map { WheelItem(id: $1, label: Converter.label($1), suggested: $0 == 0) }
    let side = 2 * WheelView.outerRadius(items.count) + 80
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: side, height: side), styleMask: .borderless, backing: .buffered, defer: false)
    let view = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    view.appearance = NSAppearance(named: .aqua)
    window.contentView = view
    window.orderFront(nil)
    view.configure(center: NSPoint(x: side / 2, y: side / 2), items: items, files: [photo], clickMode: true)
    view.animate(in: true)
    RunLoop.main.run(until: Date().addingTimeInterval(1.2)) // animation + Quick Look thumbnail
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.appearance!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rep)
    return image
}

let wheel = renderWheel(photo: samplePhoto())
let poster = NSImage(size: NSSize(width: W, height: H), flipped: false) { _ in
    // Background: the icon's blue, with a soft glow behind the wheel.
    let bg = NSGradient(colors: [rgb(0x1A2F7A), rgb(0x0E1640)])!
    bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -70)
    NSGradient(colors: [rgb(0x3E6BFF, 0.55), rgb(0x3E6BFF, 0)])!.draw(fromCenter: NSPoint(x: 930, y: 320), radius: 0,
                                                                       toCenter: NSPoint(x: 930, y: 320), radius: 360, options: [])
    // Wheel on the right (its PNG carries its own shadow).
    let ws: CGFloat = 520
    wheel.draw(in: NSRect(x: 930 - ws / 2, y: 320 - ws / 2, width: ws, height: ws))
    // Pointer resting on the highlighted slice, as if mid-drag.
    let cursor = NSCursor.arrow.image
    cursor.draw(in: NSRect(x: 990, y: 410, width: cursor.size.width * 1.6, height: cursor.size.height * 1.6))

    // Text on the left.
    let icon = NSImage(contentsOfFile: "Resources/icon-1024.png")!
    icon.draw(in: NSRect(x: 72, y: 430, width: 120, height: 120))
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: NSPoint, width: CGFloat = 560) {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 4
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
        // `p` is the bottom-left of the text block: measure it so wrapped lines grow upwards from there.
        let h = ceil(a.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height)
        a.draw(with: NSRect(x: p.x, y: p.y, width: width, height: h), options: [.usesLineFragmentOrigin])
    }
    text("Swivel", 76, .heavy, .white, at: NSPoint(x: 210, y: 446))
    text("Convert any file while you drag it.", 36, .bold, .white, at: NSPoint(x: 76, y: 350))
    text("Drag, tap ⇧ Shift, let go on a format. A free, offline converter for the Mac menu bar.", 22, .regular,
         rgb(0xFFFFFF, 0.78), at: NSPoint(x: 76, y: 268), width: 600)

    // Feature pills.
    var x: CGFloat = 76, y: CGFloat = 182
    for label in ["Images", "Video", "Audio", "PDF", "Docs", "Crop & Trim", "Fit for Discord", "Watch folders"] {
        let a = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
        let w = a.size().width + 28
        if x + w > 700 { x = 76; y -= 48 }
        rgb(0xFFFFFF, 0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 36), xRadius: 18, yRadius: 18).fill()
        a.draw(at: NSPoint(x: x + 14, y: y + 8))
        x += w + 10
    }
    text("Free  ·  Offline  ·  Native macOS  ·  github.com/foxfoxesfox/Swivel", 16, .medium, rgb(0xFFFFFF, 0.55), at: NSPoint(x: 76, y: 40), width: 800)
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
poster.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/social-preview.png"))
print("Wrote Resources/social-preview.png")
