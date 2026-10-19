import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let wheel = WheelPanel()
    var busy = 0 { didSet { updateIcon() } }
    var status = "Ready: tap Shift while dragging a file"
    var lastOutput: URL?

    // Drag polling state (no Accessibility permission needed).
    var lastDragChange = NSPasteboard(name: .drag).changeCount
    var dragging = false
    var shiftWasDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        _ = Converter.encoders // runs `ffmpeg -encoders` once, now rather than mid-drag

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        wheel.wheelView.onPick = { [weak self] target, urls in self?.convert(urls, to: target) }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Drag detection

    func poll() {
        let pb = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            if dragging {
                dragging = false
                wheel.hide(after: 0.3) // give the drop time to land on the wheel first
            }
            lastDragChange = pb.changeCount
            return
        }
        if !dragging && pb.changeCount != lastDragChange {
            dragging = true
            shiftWasDown = NSEvent.modifierFlags.contains(.shift) // Shift must be tapped during the drag
        }
        guard dragging else { return }

        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift && !shiftWasDown && !wheel.isVisible {
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let targets = Converter.targets(for: urls)
            if !targets.isEmpty { wheel.show(at: NSEvent.mouseLocation, targets: targets, fileCount: urls.count) }
        }
        shiftWasDown = shift
    }

    // MARK: - Converting

    func convert(_ urls: [URL], to target: String) {
        busy += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Converter.convertAll(urls, to: target)
            DispatchQueue.main.async { self.finish(target, result.outputs, result.errors) }
        }
    }

    func finish(_ target: String, _ outputs: [URL], _ errors: [String]) {
        busy -= 1
        if let last = outputs.last { lastOutput = last }
        let label = Converter.label(target)
        if errors.isEmpty {
            status = "Last: \(outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files") ✓"
            notify("Converted to \(label)", outputs.map(\.lastPathComponent).joined(separator: ", "))
        } else {
            status = "Last conversion failed"
            let title = outputs.isEmpty ? "\(label) conversion failed" : "\(errors.count) of \(errors.count + outputs.count) failed"
            notify(title, errors.joined(separator: "\n"))
        }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.showLastOutput() }
        completionHandler()
    }

    // MARK: - Menu

    func updateIcon() {
        statusItem.button?.image = NSImage(systemSymbolName: busy > 0 ? "hourglass" : "chart.pie",
                                           accessibilityDescription: busy > 0 ? "Swivel (converting)" : "Swivel")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, key: String = "") -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        _ = add(busy > 0 ? "Converting…" : status)
        if let ff = Converter.ffmpegPath {
            _ = add("ffmpeg: \(ff)")
        } else {
            _ = add("ffmpeg missing: audio, video, WebP, AVIF are off")
            _ = add("Copy “brew install ffmpeg”", #selector(copyInstallCommand))
        }
        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLaunchAtLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("Show Last Output in Finder", lastOutput == nil ? nil : #selector(showLastOutput))
        menu.addItem(.separator())
        _ = add("Quit Swivel", #selector(quit), key: "q")
    }

    @objc func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            notify("Launch at Login failed", error.localizedDescription)
        }
    }

    @objc func showLastOutput() {
        if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) }
    }

    @objc func quit() { NSApp.terminate(nil) }
}
