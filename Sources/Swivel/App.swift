import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let wheel = WheelPanel()
    var busy = 0 { didSet { updateIcon() } }
    let prefs = Prefs.shared
    let actions = FileActions()
    var lastResult: String?
    var lastOutput: URL?
    var settingsWindow: NSWindow?
    var welcomeWindow: NSWindow?

    // Drag polling state (no Accessibility permission needed).
    var lastDragChange = NSPasteboard(name: .drag).changeCount
    var dragging = false
    var lastFlags: NSEvent.ModifierFlags = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateIcon()
        NSApp.mainMenu = mainMenu()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        _ = Converter.encoders // runs `ffmpeg -encoders` once, now rather than mid-drag

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        actions.report = { [weak self] title, body in self?.notify(title, body) }
        actions.runTool = { [weak self] urls, preset in self?.convert(urls, to: preset) }
        wheel.wheelView.onPick = { [weak self] id, urls in
            guard let self else { return }
            if self.wheel.mode == .convert { return self.convert(urls, to: id) }
            // Async: the drop handler must return before an action opens a panel or popover.
            DispatchQueue.main.async { self.actions.perform(id, on: urls, at: NSEvent.mouseLocation) }
        }

        // Finder right-click items (Services, declared in Info.plist).
        NSApp.servicesProvider = self
        FinderMenu.sync()

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)

        if !UserDefaults.standard.bool(forKey: "didOnboard") { showWelcome() }
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
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !dragging && pb.changeCount != lastDragChange {
            dragging = true
            lastFlags = flags // keys must be tapped during the drag, not held from before it
        }
        guard dragging else { return }

        let tapped = flags.subtracting(lastFlags)
        lastFlags = flags
        guard !wheel.isVisible else { return }
        let mode: WheelMode
        if prefs.convertDrag && tapped.contains(prefs.convertKey.flag) { mode = .convert }
        else if prefs.actionsDrag && tapped.contains(prefs.actionsKey.flag) { mode = .actions }
        else { return }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let items = self.items(mode, urls)
        if !items.isEmpty { wheel.show(at: NSEvent.mouseLocation, items: items, mode: mode, fileCount: urls.count) }
        else if mode == .convert { explainMissingFFmpeg(urls) }
    }

    func items(_ mode: WheelMode, _ urls: [URL]) -> [WheelItem] {
        guard !urls.isEmpty else { return [] }
        if mode == .actions { return FileActions.items(for: urls) }
        return Converter.targets(for: urls).map { WheelItem(id: $0, label: Converter.label($0)) }
    }

    /// No wheel for audio/video without ffmpeg: say why instead of doing nothing.
    @discardableResult
    func explainMissingFFmpeg(_ urls: [URL]) -> Bool {
        let media = Converter.audioIn.union(Converter.videoIn)
        guard Converter.ffmpegPath == nil, urls.contains(where: { media.contains(Converter.ext($0)) }) else { return false }
        notify("Audio and video need ffmpeg", "Click here to install it from Swivel Settings. It's free.", opensSettings: true)
        return true
    }

    // MARK: - Finder right-click (Services)

    @objc func convertFiles(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        openFromFinder(pboard, .convert)
    }

    @objc func fileActions(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        openFromFinder(pboard, .actions)
    }

    /// No drag here, so the wheel opens in click mode at the pointer.
    func openFromFinder(_ pboard: NSPasteboard, _ mode: WheelMode) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let items = self.items(mode, urls)
        guard !items.isEmpty else {
            if explainMissingFFmpeg(urls) { return }
            return notify("Nothing to convert", "Swivel can't convert \(urls.first?.lastPathComponent ?? "that").")
        }
        wheel.show(at: NSEvent.mouseLocation, items: items, mode: mode, fileCount: urls.count, clickURLs: urls)
    }

    // MARK: - Converting

    func convert(_ urls: [URL], to target: String) {
        busy += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Converter.convertAll(urls, to: target)
            DispatchQueue.main.async { self.finish(target, urls, result.outputs, result.errors) }
        }
    }

    func finish(_ target: String, _ sources: [URL], _ outputs: [URL], _ errors: [String]) {
        busy -= 1
        if let last = outputs.last { lastOutput = last }
        let label = Converter.label(target)
        if errors.isEmpty {
            lastResult = "Last: \(outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files") ✓"
            if Converter.isTool(target) {
                // Show the size change, e.g. "photo compressed.jpg: 4.2 MB → 1.1 MB".
                let size = { (url: URL) in
                    ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                                              countStyle: .file)
                }
                let lines = zip(sources, outputs).map { "\($1.lastPathComponent): \(size($0)) → \(size($1))" }
                notify(label == "Compress" ? "Compressed" : "Resized", lines.joined(separator: "\n"))
            } else {
                notify("Converted to \(label)", outputs.map(\.lastPathComponent).joined(separator: ", "))
            }
        } else {
            lastResult = "Last conversion failed"
            let failed = Converter.isTool(target) ? "\(label) failed" : "\(label) conversion failed"
            let title = outputs.isEmpty ? failed : "\(errors.count) of \(errors.count + outputs.count) failed"
            notify(title, errors.joined(separator: "\n"))
        }
    }

    /// `opensSettings`: clicking the notification opens Settings instead of the last output.
    func notify(_ title: String, _ body: String, opensSettings: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if opensSettings { content.userInfo = ["open": "settings"] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let opensSettings = response.notification.request.content.userInfo["open"] as? String == "settings"
        DispatchQueue.main.async { opensSettings ? self.showSettings() : self.showLastOutput() }
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
        let ready = prefs.convertDrag ? "Ready: tap \(prefs.convertKey.name) while dragging a file"
                                      : "Ready: right-click a file › Convert with Swivel"
        _ = add(busy > 0 ? "Converting…" : lastResult ?? ready)
        if let ff = Converter.ffmpegPath {
            _ = add("ffmpeg: \(ff)")
        } else {
            _ = add("ffmpeg missing: audio, video, WebP, AVIF are off")
            _ = add(FFmpegSetup.brewPath != nil ? "Install ffmpeg…" : "Install Homebrew and ffmpeg…", #selector(installFFmpeg))
        }
        menu.addItem(.separator())
        _ = add("How to Use & Settings…", #selector(showSettings), key: ",")
        add("Launch at Login", #selector(toggleLaunchAtLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("Show Last Output in Finder", lastOutput == nil ? nil : #selector(showLastOutput))
        menu.addItem(.separator())
        _ = add("Quit Swivel", #selector(quit), key: "q")
    }

    @objc func showSettings() {
        present(&settingsWindow, title: "Swivel Settings", SettingsView(onShowWelcome: { [weak self] in self?.showWelcome() }))
    }

    func showWelcome() {
        settingsWindow?.close()
        present(&welcomeWindow, title: "Welcome to Swivel", WelcomeView(onFinish: { [weak self] in
            UserDefaults.standard.set(true, forKey: "didOnboard")
            self?.welcomeWindow?.close()
        }))
    }

    /// Opening Swivel again (Applications, Spotlight, Dock) brings its window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: "didOnboard") { showSettings() } else { showWelcome() }
        return true
    }

    /// Back to menu-bar-only once the last Swivel window closes.
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let others = [settingsWindow, welcomeWindow].contains { $0 != nil && $0 !== closing && $0!.isVisible }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }

    /// Menus shown while a window is open, so ⌘W, ⌘Q, ⌘, and ⌘C work.
    func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Swivel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for submenu in [app, file, edit] { main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = submenu }
        return main
    }

    /// Shows a SwiftUI view in a reusable window, rebuilt each time so its status is fresh.
    func present<V: View>(_ window: inout NSWindow?, title: String, _ view: V) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        window?.title = title
        window?.contentViewController = NSHostingController(rootView: view)
        window?.center()
        // While a window is open, show a Dock icon and a ⌘-Tab entry so it can't get lost behind other apps.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func installFFmpeg() { FFmpegSetup.install() }

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
