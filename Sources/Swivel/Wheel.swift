import AppKit

struct WheelItem {
    let id: String
    let label: String
    var symbol: String? = nil
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

    // Key only in click mode, so Esc works; a non-activating panel takes keys without activating the app.
    override var canBecomeKey: Bool { clickMode }
    override var canBecomeMain: Bool { false }

    /// `clickURLs` nil = drag mode (drop on a slice); non-nil = click mode (Finder right-click).
    func show(at point: NSPoint, items: [WheelItem], mode: WheelMode, fileCount: Int, clickURLs: [URL]? = nil) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        hideToken += 1
        self.mode = mode
        clickMode = clickURLs != nil
        setFrame(screen.frame, display: false)
        let r = wheelView.outer + 8 // keep the whole wheel on screen near edges
        let local = NSPoint(x: min(max(point.x - screen.frame.minX, r), screen.frame.width - r),
                            y: min(max(point.y - screen.frame.minY, r), screen.frame.height - r))
        wheelView.configure(center: local, items: items, fileCount: fileCount, clickURLs: clickURLs)
        orderFrontRegardless()
        if clickMode { makeKey() }
    }

    func hide(after delay: TimeInterval) {
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if self?.hideToken == token { self?.orderOut(nil) }
        }
    }
}

final class WheelView: NSView {
    var onPick: ((String, [URL]) -> Void)?
    let outer: CGFloat = 160, inner: CGFloat = 46
    private var items: [WheelItem] = []
    private var center = NSPoint.zero
    private var fileCount = 0
    private var clickURLs: [URL]?
    private var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            needsDisplay = true
            if highlighted != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(center: NSPoint, items: [WheelItem], fileCount: Int, clickURLs: [URL]?) {
        self.center = center
        self.items = items
        self.fileCount = fileCount
        self.clickURLs = clickURLs
        highlighted = clickURLs == nil ? nil : slice(at: center)
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

    override func draw(_ dirtyRect: NSRect) {
        // Alpha 0 would let drops and clicks fall through to the window below.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        guard !items.isEmpty else { return }

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
            let color = isOn ? NSColor.white : NSColor.labelColor
            let text = NSAttributedString(string: item.label, attributes: [
                .font: NSFont.systemFont(ofSize: item.symbol == nil ? 13 : 11, weight: .semibold),
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
        }

        // Centre: drop or click here to cancel.
        let hub = NSAttributedString(string: fileCount > 1 ? "✕\n\(fileCount) files" : "✕", attributes: [
            .font: NSFont.systemFont(ofSize: fileCount > 1 ? 11 : 16, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
        ])
        let size = hub.size()
        hub.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
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
        guard clickURLs != nil else { return }
        highlighted = slice(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard let urls = clickURLs else { return }
        let picked = slice(at: convert(event.locationInWindow, from: nil))
        window?.orderOut(nil)
        if let picked { onPick?(items[picked].id, urls) } // a click off the slices cancels
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.orderOut(nil) } else { super.keyDown(with: event) } // Esc
    }

    // MARK: - Drop destination (drag mode)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard clickURLs == nil else { return [] }
        highlighted = slice(at: convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy // .copy, so Finder never moves the original
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }

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
