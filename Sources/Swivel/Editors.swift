import AppKit
import AVKit

/// A small editing window (Crop, Trim) opened from the actions wheel. Results go through the app's
/// normal conversion path as a target string ("crop-X-Y-W-H", "trim-START-END"), so progress,
/// notifications, Undo and Recents all work the same.
protocol Editor: AnyObject {
    var onClose: () -> Void { get set }
    func show()
}

// MARK: - Crop

final class CropController: NSObject, Editor, NSWindowDelegate {
    var onClose: () -> Void = {}
    private let files: [URL]
    private let onCrop: (URL, String) -> Void
    private var index = 0
    private let window: NSWindow
    private let cropView = CropView()
    private let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]
    private lazy var ratioControl = NSSegmentedControl(labels: ratios.map(\.0), trackingMode: .selectOne, target: self, action: #selector(ratioChanged))
    private lazy var skipButton = NSButton(title: "Skip", target: self, action: #selector(skip))

    init(files: [URL], onCrop: @escaping (URL, String) -> Void) {
        self.files = files
        self.onCrop = onCrop
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 400)

        ratioControl.selectedSegment = 0
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let crop = NSButton(title: "Crop", target: self, action: #selector(save))
        crop.keyEquivalent = "\r"
        let hint = NSTextField(labelWithString: "Drag the frame or its corners. Drag outside it to start a new one.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [ratioControl, hint, NSView(), skipButton, cancel, crop])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        let stack = NSStackView(views: [cropView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        cropView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
    }

    func show() {
        guard index < files.count else { return window.close() }
        let file = files[index]
        do {
            cropView.setImage(try Converter.loadImage(file))
        } catch {
            index += 1
            return show() // unreadable: move on
        }
        cropView.ratio = ratios[ratioControl.selectedSegment].1
        window.title = files.count > 1 ? "Crop \(file.lastPathComponent) (\(index + 1) of \(files.count))" : "Crop \(file.lastPathComponent)"
        skipButton.isHidden = files.count == 1
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func ratioChanged() { cropView.ratio = ratios[ratioControl.selectedSegment].1 }

    @objc private func save() {
        if let r = cropView.pixelRect {
            onCrop(files[index], "crop-\(Int(r.minX))-\(Int(r.minY))-\(Int(r.width))-\(Int(r.height))")
        }
        next()
    }

    @objc private func skip() { next() }
    @objc private func cancel() { window.close() }

    private func next() {
        index += 1
        index < files.count ? show() : window.close()
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Shows the photo with a crop frame: drag inside to move, drag a corner to resize, drag outside to draw a new frame.
final class CropView: NSView {
    private var image: CGImage?
    private var crop = NSRect.zero // in view coordinates
    private enum Drag { case move(NSPoint), resize(anchor: NSPoint), create(NSPoint) }
    private var drag: Drag?
    var ratio: CGFloat? { didSet { resetCrop() } }

    func setImage(_ image: CGImage) {
        self.image = image
        resetCrop()
    }

    /// The photo, fitted into the view with a margin.
    private var imageRect: NSRect {
        guard let image else { return .zero }
        let area = bounds.insetBy(dx: 20, dy: 20)
        let s = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The crop frame in photo pixels, measured from the top-left.
    var pixelRect: CGRect? {
        guard let image, crop.width > 2, crop.height > 2 else { return nil }
        let img = imageRect, s = CGFloat(image.width) / img.width
        return CGRect(x: ((crop.minX - img.minX) * s).rounded(), y: ((img.maxY - crop.maxY) * s).rounded(),
                      width: (crop.width * s).rounded(), height: (crop.height * s).rounded())
    }

    /// Largest frame of the chosen ratio, centred (the whole photo for Free).
    private func resetCrop() {
        let img = imageRect
        if let ratio {
            let w = min(img.width, img.height * ratio), h = w / ratio
            crop = NSRect(x: img.midX - w / 2, y: img.midY - h / 2, width: w, height: h)
        } else {
            crop = img
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Keep the frame on the same part of the photo when the window resizes.
        let old = imageRect, rel = old.width > 0 ? NSRect(x: (crop.minX - old.minX) / old.width, y: (crop.minY - old.minY) / old.height,
                                                          width: crop.width / old.width, height: crop.height / old.height) : nil
        super.setFrameSize(newSize)
        if let rel {
            let img = imageRect
            crop = NSRect(x: img.minX + rel.minX * img.width, y: img.minY + rel.minY * img.height,
                          width: rel.width * img.width, height: rel.height * img.height)
        } else {
            resetCrop()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let img = imageRect
        ctx.interpolationQuality = .high
        ctx.draw(image, in: img)
        // Dim everything outside the frame.
        let shade = NSBezierPath(rect: img)
        shade.append(NSBezierPath(rect: crop))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        shade.fill()
        // Frame, rule-of-thirds guides, corner handles.
        NSColor.white.withAlphaComponent(0.45).setStroke()
        for i in 1...2 {
            let x = crop.minX + crop.width * CGFloat(i) / 3, y = crop.minY + crop.height * CGFloat(i) / 3
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: crop.minY), to: NSPoint(x: x, y: crop.maxY))
            NSBezierPath.strokeLine(from: NSPoint(x: crop.minX, y: y), to: NSPoint(x: crop.maxX, y: y))
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: crop)
        border.lineWidth = 1.5
        border.stroke()
        NSColor.white.setFill()
        for c in corners { NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10).fill() }
    }

    private var corners: [NSPoint] {
        [NSPoint(x: crop.minX, y: crop.minY), NSPoint(x: crop.maxX, y: crop.minY),
         NSPoint(x: crop.minX, y: crop.maxY), NSPoint(x: crop.maxX, y: crop.maxY)]
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = corners.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 14 }) {
            drag = .resize(anchor: corners[3 - i]) // the opposite corner stays put
        } else if crop.contains(p) {
            drag = .move(NSPoint(x: p.x - crop.minX, y: p.y - crop.minY))
        } else if imageRect.contains(p) {
            drag = .create(p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let img = imageRect
        let p = NSPoint(x: min(max(convert(event.locationInWindow, from: nil).x, img.minX), img.maxX),
                        y: min(max(convert(event.locationInWindow, from: nil).y, img.minY), img.maxY))
        switch drag {
        case .move(let offset):
            crop.origin = NSPoint(x: min(max(p.x - offset.x, img.minX), img.maxX - crop.width),
                                  y: min(max(p.y - offset.y, img.minY), img.maxY - crop.height))
        case .resize(let anchor), .create(let anchor):
            crop = frame(from: anchor, to: p, within: img)
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    /// A frame spanning two points, held to the chosen ratio and kept inside the photo.
    private func frame(from a: NSPoint, to b: NSPoint, within img: NSRect) -> NSRect {
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if let ratio {
            if w / max(h, 1) > ratio { w = h * ratio } else { h = w / ratio }
            let maxW = b.x >= a.x ? img.maxX - a.x : a.x - img.minX, maxH = b.y >= a.y ? img.maxY - a.y : a.y - img.minY
            let s = min(1, maxW / max(w, 1), maxH / max(h, 1))
            w *= s; h *= s
        }
        return NSRect(x: b.x >= a.x ? a.x : a.x - w, y: b.y >= a.y ? a.y : a.y - h, width: max(w, 4), height: max(h, 4))
    }
}

// MARK: - Trim

/// Uses macOS's own trimming bar (as in QuickTime). One video at a time; several are trimmed in turn.
final class TrimController: NSObject, Editor, NSWindowDelegate {
    var onClose: () -> Void = {}
    private let files: [URL]
    private let onTrim: (URL, String) -> Void
    private var index = 0
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private var statusObservation: NSKeyValueObservation?

    init(files: [URL], onTrim: @escaping (URL, String) -> Void) {
        self.files = files
        self.onTrim = onTrim
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        playerView.controlsStyle = .inline
        window.contentView = playerView
    }

    func show() {
        guard index < files.count else { return window.close() }
        let file = files[index]
        window.title = files.count > 1 ? "Trim \(file.lastPathComponent) (\(index + 1) of \(files.count))" : "Trim \(file.lastPathComponent)"
        let item = AVPlayerItem(url: file)
        playerView.player = AVPlayer(playerItem: item)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // The trim bar can only open once the video is ready.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, item.status != .unknown else { return }
                self.statusObservation = nil
                if item.status == .readyToPlay, self.playerView.canBeginTrimming { self.beginTrimming(file, item) } else { self.next() }
            }
        }
    }

    private func beginTrimming(_ file: URL, _ item: AVPlayerItem) {
        playerView.beginTrimming { [weak self] result in
            guard let self else { return }
            if result == .okButton {
                let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
                let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : item.duration.seconds
                if end > start { self.onTrim(file, String(format: "trim-%.3f-%.3f", start, end)) }
                self.next()
            } else {
                self.window.close() // Cancel stops the whole batch
            }
        }
    }

    private func next() {
        playerView.player?.pause()
        index += 1
        index < files.count ? show() : window.close()
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        playerView.player = nil
        onClose()
    }
}
