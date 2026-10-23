import AppKit

/// The share / file actions wheel. Works on any files or folders.
final class FileActions: NSObject, NSSharingServicePickerDelegate {
    static let items = [
        WheelItem(id: "airdrop", label: "AirDrop", symbol: "dot.radiowaves.left.and.right"),
        WheelItem(id: "share", label: "Share", symbol: "square.and.arrow.up"),
        WheelItem(id: "copy", label: "Copy", symbol: "doc.on.doc"),
        WheelItem(id: "move", label: "Move", symbol: "folder"),
        WheelItem(id: "path", label: "Copy Path", symbol: "link"),
        WheelItem(id: "terminal", label: "Terminal", symbol: "terminal"),
    ]
    static let mediaItems = [
        WheelItem(id: "compress", label: "Compress", symbol: "arrow.down.right.and.arrow.up.left"),
        WheelItem(id: "resize", label: "Resize", symbol: "aspectratio"),
        WheelItem(id: "send", label: "Send", symbol: "paperplane"),
    ]

    /// Compress and Resize join the wheel when every file is a photo or video.
    static func items(for urls: [URL]) -> [WheelItem] {
        !urls.isEmpty && urls.allSatisfy(Converter.canUseTools) ? items + mediaItems : items
    }

    static let presets: [String: [(id: String, title: String)]] = [
        "compress": [("compress-high", "Best quality"), ("compress-balanced", "Balanced"), ("compress-small", "Smallest file")],
        "resize": [("scale-50", "Half size (50%)"), ("scale-25", "Quarter size (25%)"),
                   ("fit-1920", "Fit within 1920 px"), ("fit-1280", "Fit within 1280 px"), ("fit-640", "Fit within 640 px")],
        // Upload limits change over time; the MB figure in each title is what Swivel actually targets.
        "send": [("send-10", "Discord · under 10 MB"), ("send-16", "WhatsApp · under 16 MB"), ("send-25", "Email · under 25 MB")],
    ]

    /// Shows a result to the user (the app posts it as a notification).
    var report: (String, String) -> Void = { _, _ in }
    /// Runs a compress/resize preset through the app's normal conversion path.
    var runTool: ([URL], String) -> Void = { _, _ in }
    private var anchor: NSPanel?
    private var presetURLs: [URL] = []

    func perform(_ id: String, on urls: [URL], at point: NSPoint) {
        let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        switch id {
        case "airdrop":
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                return report("AirDrop isn't available", "Turn on Wi-Fi and Bluetooth, then try again.")
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case "share":
            share(urls, at: point)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            report("Copied \(what)", "Paste in Finder to make a copy.")
        case "move":
            move(urls, what)
        case "path":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            report(urls.count == 1 ? "Copied path" : "Copied \(urls.count) paths", urls.map(\.path).joined(separator: "\n"))
        case "compress", "resize", "send":
            showPresets(id, urls, what, at: point)
        case "terminal":
            let folders = Set(urls.map { $0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent() })
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open(Array(folders), withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        default:
            break
        }
    }

    /// A small menu at the pointer to pick how much to compress or how big to resize.
    private func showPresets(_ id: String, _ urls: [URL], _ what: String, at point: NSPoint) {
        presetURLs = urls
        let menu = NSMenu()
        menu.addItem(withTitle: "\(["compress": "Compress", "resize": "Resize", "send": "Make sendable:"][id]!) \(what)", action: nil, keyEquivalent: "")
        for preset in Self.presets[id]! {
            let item = menu.addItem(withTitle: preset.title, action: #selector(pickPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.indentationLevel = 1
        }
        if id == "compress", urls.contains(where: { ["png", "tiff", "bmp", "gif"].contains(Converter.ext($0)) }) {
            menu.addItem(.separator())
            menu.addItem(withTitle: "PNG, TIFF, BMP and GIF are saved as JPG", action: nil, keyEquivalent: "")
        }
        if id == "send" {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Saved as JPG or MP4, with location data removed", action: nil, keyEquivalent: "")
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func pickPreset(_ item: NSMenuItem) {
        if let preset = item.representedObject as? String { runTool(presetURLs, preset) }
    }

    /// The system share popover needs a visible view to point at, so use a 1pt invisible panel at the pointer.
    private func share(_ urls: [URL], at point: NSPoint) {
        let panel = NSPanel(contentRect: NSRect(x: point.x, y: point.y, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.orderFrontRegardless()
        anchor = panel
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        picker.show(relativeTo: panel.contentView!.bounds, of: panel.contentView!, preferredEdge: .minY)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        anchor?.orderOut(nil) // also called with nil when the popover is dismissed
        anchor = nil
    }

    /// Moves the originals into a chosen folder, never overwriting ("name 2" on clashes).
    private func move(_ urls: [URL], _ what: String) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Move \(what) to…"
        panel.directoryURL = urls[0].deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var failed: [String] = []
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL {
            let ext = url.pathExtension
            let dest = Converter.uniqueURL(in: dir, base: url.deletingPathExtension().lastPathComponent, ext: ext.isEmpty ? nil : ext)
            do { try FileManager.default.moveItem(at: url, to: dest) }
            catch { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if failed.isEmpty { report("Moved \(what)", "to \(dir.lastPathComponent)") }
        else { report("Couldn't move \(failed.count) item(s)", failed.joined(separator: "\n")) }
    }
}
