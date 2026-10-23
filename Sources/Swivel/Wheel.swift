import AppKit
import QuickLookThumbnailing

struct WheelItem {
    let id: String
    let label: String
    var symbol: String? = nil
    /// The user's usual choice for this file type: drawn in the accent colour, preselected in click mode.
    var suggested = false
}

/// Transparent, non-activating panel covering the screen under the cursor.
/// The wheel itself is a 320pt disc at the cursor; the rest of the panel is a
/// near-invisible drop zone, so a drop off the wheel is rejected (cancel) instead
/// of landing on Finder underneath and moving the file.
final class WheelPanel: NSPanel {
    let wheelView = WheelView()
    private(set) var mode = WheelMode.convert
    private var clickMode = false
    private var hideToken = 0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu // below the drag image, above normal windows
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = wheelView
    }

    // Key only in click mode, so keys work; a non-activating panel takes keys without activating the app.
    override var canBecomeKey: Bool { clickMode }
    override var canBecomeMain: Bool { false }

    /// `clickMode` false = drag mode (drop on a slice); true = opened from Finder's right-click (click a slice).
    func show(at point: NSPoint, items: [WheelItem], mode: WheelMode, files: [URL], clickMode: Bool = false) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        hideToken += 1
        self.mode = mode
        self.clickMode = clickMode
        setFrame(screen.frame, display: false)
        let r = WheelView.outerRadius(items.count) + 8 // keep the whole wheel on screen near edges
        let local = NSPoint(x: min(max(point.x - screen.frame.minX, r), screen.frame.width - r),
                            y: min(max(point.y - screen.frame.minY, r), screen.frame.height - r))
        wheelView.configure(center: local, items: items, files: files, clickMode: clickMode)
        orderFrontRegardless()
        if clickMode { makeKey() }
        wheelView.animate(in: true)
    }

    /// Fades the wheel out, then hides the panel (unless it was reopened meanwhile).
    func dismiss() {
        hideToken += 1
        let token = hideToken
        wheelView.animate(in: false) { [weak self] in
            if self?.hideToken == token { self?.orderOut(nil) }
        }
    }

    func hide(after delay: TimeInterval) {
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if self?.hideToken == token { self?.dismiss() }
        }
    }
}

final class WheelView: NSView {
    var onPick: ((String, [URL]) -> Void)?
    let inner: CGFloat = 46
    var outer: CGFloat { Self.outerRadius(items.count) }
    /// The wheel grows past 8 slices so labels keep their room.
    static func outerRadius(_ count: Int) -> CGFloat { count > 10 ? 196 : count > 8 ? 178 : 160 }
    private var items: [WheelItem] = []
    private var center = NSPoint.zero
    private var files: [URL] = []
    private var clickMode = false
    private var thumbnail: NSImage?
    private var thumbnailToken = 0
    private var hubHot = false { didSet { if hubHot != oldValue { setNeedsDisplay(wheelRect) } } }
    private var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            setNeedsDisplay(wheelRect)
            if highlighted != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    // Appear / disappear animation state: phase 0 = hidden, 1 = shown.
    private var phase: CGFloat = 1
    private var appearing = true
    private var animationTimer: Timer?

    private var wheelRect: NSRect { NSRect(x: center.x - outer - 30, y: center.y - outer - 36, width: outer * 2 + 60, height: outer * 2 + 66) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(center: NSPoint, items: [WheelItem], files: [URL], clickMode: Bool) {
        self.center = center
        self.items = items
        self.files = files
        self.clickMode = clickMode
        hubHot = false
        highlighted = clickMode ? items.firstIndex(where: \.suggested) : nil
        phase = 0
        loadThumbnail(files.first)
        needsDisplay = true
    }

    /// Slice index under `p`, counting clockwise from 12 o'clock; nil in the centre or outside.
    func slice(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y, d = hypot(dx, dy)
        guard d > inner, d < outer, !items.isEmpty else { return nil }
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        return min(Int(angle / (2 * .pi) * CGFloat(items.count)), items.count - 1)
    }

    private func track(_ p: NSPoint) {
        highlighted = slice(at: p)
        hubHot = hypot(p.x - center.x, p.y - center.y) <= inner
    }

    // MARK: - Animation

    /// Opens with a short spring (slight overshoot), closes with a quicker fade. Reduce Motion: fade only.
    func animate(in: Bool, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()
        appearing = `in`
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = `in` ? (reduceMotion ? 0.12 : 0.3) : 0.12
        let from = phase, to: CGFloat = `in` ? 1 : 0
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            self.phase = from + (to - from) * CGFloat(t)
            self.setNeedsDisplay(self.wheelRect)
            if t >= 1 { timer.invalidate(); completion?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    // MARK: - Thumbnail

    private func loadThumbnail(_ url: URL?) {
        thumbnailToken += 1
        let token = thumbnailToken
        thumbnail = url.map { NSWorkspace.shared.icon(forFile: $0.path) } // instant fallback
        guard let url else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 112, height: 112),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                guard let self, self.thumbnailToken == token else { return }
                self.thumbnail = rep.nsImage
                self.setNeedsDisplay(self.wheelRect)
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Alpha 0 would let drops and clicks fall through to the window below.
        NSColor.black.withAlphaComponent(0.01).setFill()
        dirtyRect.fill()
        guard !items.isEmpty, phase > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale = reduceMotion ? 1 : appearing ? 0.82 + 0.18 * easeOutBack(phase) : 0.94 + 0.06 * phase
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -center.x, y: -center.y)
        ctx.setAlpha(appearing ? min(1, phase * 2.2) : phase)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawWheel()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawWheel() {
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        disc.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        disc.stroke()

        let step = 360 / CGFloat(items.count)
        for (i, item) in items.enumerated() {
            let a0 = CGFloat(i) * step, a1 = a0 + step // degrees clockwise from top
            let wedge = NSBezierPath()
            wedge.appendArc(withCenter: center, radius: outer - 6, startAngle: 90 - a0, endAngle: 90 - a1, clockwise: true)
            wedge.appendArc(withCenter: center, radius: inner + 6, startAngle: 90 - a1, endAngle: 90 - a0, clockwise: false)
            wedge.close()
            let isOn = i == highlighted
            (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
            wedge.fill()
            NSColor.windowBackgroundColor.setStroke()
            wedge.lineWidth = 3
            wedge.stroke()

            let mid = (a0 + a1) / 2 * .pi / 180, r = (outer + inner) / 2
            let color = isOn ? NSColor.white : item.suggested ? NSColor.controlAccentColor : NSColor.labelColor
            let text = NSAttributedString(string: item.label, attributes: [
                .font: NSFont.systemFont(ofSize: item.symbol == nil ? 13 : 11, weight: item.suggested ? .bold : .semibold),
                .foregroundColor: color,
            ])
            let size = text.size()
            let p = NSPoint(x: center.x + r * sin(mid), y: center.y + r * cos(mid))
            if let symbol = item.symbol, let icon = tinted(symbol, color) {
                icon.draw(in: NSRect(x: p.x - icon.size.width / 2, y: p.y + 1, width: icon.size.width, height: icon.size.height))
                text.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height - 1))
            } else {
                text.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
            }

            // Keyboard numbers, only where the keyboard works (click mode).
            if clickMode && i < 9 {
                let number = NSAttributedString(string: "\(i + 1)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: isOn ? NSColor.white.withAlphaComponent(0.75) : NSColor.tertiaryLabelColor,
                ])
                let ns = number.size(), nr = outer - 17
                number.draw(at: NSPoint(x: center.x + nr * sin(mid) - ns.width / 2, y: center.y + nr * cos(mid) - ns.height / 2))
            }
        }
        drawHub()
    }

    /// Centre: a thumbnail of the file (with a count for several), turning into ✕ (cancel) when pointed at.
    private func drawHub() {
        var thumbRect = NSRect.zero
        if let thumb = thumbnail, thumb.size.width > 0, thumb.size.height > 0 {
            let side: CGFloat = 54, aspect = thumb.size.width / thumb.size.height
            let size = aspect >= 1 ? NSSize(width: side, height: side / aspect) : NSSize(width: side * aspect, height: side)
            thumbRect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: thumbRect, xRadius: 6, yRadius: 6).addClip()
            thumb.draw(in: thumbRect, from: .zero, operation: .sourceOver, fraction: hubHot ? 0.2 : 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        if hubHot || thumbnail == nil {
            let x = NSAttributedString(string: "✕", attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            let s = x.size()
            x.draw(at: NSPoint(x: center.x - s.width / 2, y: center.y - s.height / 2))
        }
        if files.count > 1 {
            let count = NSAttributedString(string: "\(files.count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white])
            let s = count.size()
            let w = max(s.width + 8, 16)
            let anchor = thumbRect == .zero ? NSPoint(x: center.x + 20, y: center.y + 20) : NSPoint(x: thumbRect.maxX, y: thumbRect.maxY)
            let pill = NSRect(x: anchor.x - w / 2, y: anchor.y - 8, width: w, height: 16)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            count.draw(at: NSPoint(x: pill.midX - s.width / 2, y: pill.midY - s.height / 2))
        }
    }

    private func tinted(_ symbol: String, _ color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: - Click mode (opened from Finder's right-click menu)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        guard clickMode else { return }
        track(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard clickMode else { return }
        pick(slice(at: convert(event.locationInWindow, from: nil))) // a click off the slices cancels
    }

    /// 1–9 pick a slice, ←/→ move around the wheel, Return picks, Esc cancels.
    override func keyDown(with event: NSEvent) {
        guard clickMode, !items.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: pick(nil)                                            // Esc
        case 36, 76: if let h = highlighted { pick(h) }               // Return, Enter
        case 124, 125: highlighted = ((highlighted ?? -1) + 1) % items.count               // → ↓
        case 123, 126: highlighted = ((highlighted ?? items.count) - 1 + items.count) % items.count // ← ↑
        default:
            if let n = Int(event.charactersIgnoringModifiers ?? ""), (1...min(9, items.count)).contains(n) { pick(n - 1) }
            else { super.keyDown(with: event) }
        }
    }

    private func pick(_ index: Int?) {
        let urls = files
        (window as? WheelPanel)?.dismiss()
        if let index { onPick?(items[index].id, urls) }
    }

    // MARK: - Drop destination (drag mode)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !clickMode else { return [] }
        track(convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy // .copy, so Finder never moves the original
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil; hubHot = false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { highlighted != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = highlighted,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onPick?(items[i].id, urls)
        return true
    }
}
