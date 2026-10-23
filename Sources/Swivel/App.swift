import AppKit
import Combine
import QuickLookThumbnailing
import ServiceManagement
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let wheel = WheelPanel()
    let prefs = Prefs.shared
    let actions = FileActions()
    var lastResult: String?
    var lastOutput: URL? { Recents.all.first }

    // Running conversions, their progress (0…1, once known) and their live menu lines.
    var jobs: [Job] = [] { didSet { updateIcon() } }
    var progress: [ObjectIdentifier: Double] = [:]
    var jobMenuItems: [ObjectIdentifier: NSMenuItem] = [:]
    var thumbnails: [String: NSImage] = [:] // small previews for the Recent menu
    var settingsWindow: NSWindow?
    var welcomeWindow: NSWindow?
    var updateWindow: NSWindow?
    var editors: [Editor] = [] // open Crop/Trim windows
    var pendingWebDrop: WebDrop? // what a browser drag carries, while its wheel is open
    var produced: Set<String> = [] // files Swivel made this run, so watch folders skip them
    lazy var watcher = FolderWatcher(onFile: { [weak self] url, target in self?.convert([url], to: target) },
                                     isOwnOutput: { [weak self] path in self?.produced.contains(path) ?? false })
    var watchSubscription: AnyCancellable?
    let updater = Updater.shared

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
        center.setNotificationCategories([UNNotificationCategory(identifier: "result", actions: [
            UNNotificationAction(identifier: "show", title: "Show in Finder"),
            UNNotificationAction(identifier: "undo", title: "Undo", options: [.destructive]),
        ], intentIdentifiers: [])])
        Recents.all.forEach(cacheThumbnail)

        actions.report = { [weak self] title, body in self?.notify(title, body) }
        actions.runTool = { [weak self] urls, preset in self?.convert(urls, to: preset) }
        actions.openEditor = { [weak self] id, urls in self?.openEditor(id, urls) }
        wheel.wheelView.onPick = { [weak self] id, urls in
            guard let self else { return }
            if urls.isEmpty, let web = self.pendingWebDrop { // browser drag: save to Downloads, then convert
                return self.convert([], to: id, name: web.name + "." + web.ext, prepare: { [try web.save()] })
            }
            guard !urls.isEmpty else { return }
            if self.wheel.mode == .convert { return self.convert(urls, to: id) }
            // Async: the drop handler must return before an action opens a panel or popover.
            DispatchQueue.main.async { self.actions.perform(id, on: urls, at: NSEvent.mouseLocation) }
        }

        watchSubscription = prefs.$watchRules.sink { [weak self] rules in self?.watcher.update(rules) }

        // Finder right-click items (Services, declared in Info.plist).
        NSApp.servicesProvider = self
        FinderMenu.sync()

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)

        if !UserDefaults.standard.bool(forKey: "didOnboard") { showWelcome() }

        if let from = UserDefaults.standard.string(forKey: "updatedFrom") {
            UserDefaults.standard.removeObject(forKey: "updatedFrom")
            notify("Swivel updated to \(Updater.currentVersion)", "You were on \(from). Click to see what's new.", opens: "changelog")
        }
        // Automatic update check: shortly after launch, then every few hours, at most once a day.
        let updates = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.autoCheckForUpdates() }
        RunLoop.main.add(updates, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.autoCheckForUpdates() }
    }

    // MARK: - Updates

    func autoCheckForUpdates() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard prefs.autoUpdate, Date().timeIntervalSince(last) > 20 * 3600, updateWindow?.isVisible != true else { return }
        updater.check { [weak self] release in
            guard let release, UserDefaults.standard.string(forKey: "notifiedVersion") != release.version else { return }
            UserDefaults.standard.set(release.version, forKey: "notifiedVersion") // one notification per version
            self?.notify("Swivel \(release.version) is available", "Click to see what's new and update.", opens: "update")
        }
    }

    /// The update window; `check` asks GitHub first (the menu's "Check for Updates…").
    @objc func checkForUpdatesNow() { showUpdates(check: true) }

    func showUpdates(check: Bool) {
        if check { updater.check() }
        present(&updateWindow, title: "Software Update", UpdateView(onClose: { [weak self] in self?.updateWindow?.close() }))
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
        pendingWebDrop = nil
        if urls.isEmpty, mode == .convert, let web = WebDrop.read(pb) { // dragged out of a browser
            let items = Converter.targets(forExt: web.ext).filter { !prefs.hiddenFormats.contains($0) }
                .map { WheelItem(id: $0, label: Converter.label($0)) }
            guard !items.isEmpty else { return }
            pendingWebDrop = web
            return wheel.show(at: NSEvent.mouseLocation, items: items, mode: mode, files: [])
        }
        let items = self.items(mode, urls)
        if !items.isEmpty { wheel.show(at: NSEvent.mouseLocation, items: items, mode: mode, files: urls) }
        else if mode == .convert { explainMissingFFmpeg(urls) }
    }

    func items(_ mode: WheelMode, _ urls: [URL]) -> [WheelItem] {
        guard !urls.isEmpty else { return [] }
        if mode == .actions { return FileActions.items(for: urls) }
        // Smart wheel: the usual format for this file type goes first (top slice) and is highlighted.
        let targets = Converter.targets(for: urls).filter { !prefs.hiddenFormats.contains($0) }
        let favorite = Usage.favorite(Converter.ext(urls[0])).flatMap { targets.contains($0) ? $0 : nil }
        let ordered = favorite.map { fav in [fav] + targets.filter { $0 != fav } } ?? targets
        return ordered.map { WheelItem(id: $0, label: Converter.label($0), suggested: $0 == favorite) }
    }

    /// No wheel for audio/video without ffmpeg: say why instead of doing nothing.
    @discardableResult
    func explainMissingFFmpeg(_ urls: [URL]) -> Bool {
        guard Converter.ffmpegPath == nil, urls.contains(where: { Converter.needsFFmpeg.contains(Converter.ext($0)) }) else { return false }
        notify("Audio and video need ffmpeg", "Click to download it in Settings. It's free and takes one click.", opensSettings: true)
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
        wheel.show(at: NSEvent.mouseLocation, items: items, mode: mode, files: urls, clickMode: true)
    }

    // MARK: - Converting

    /// `prepare` fetches the files first (browser drags), inside the job so it shows progress and can be cancelled.
    func convert(_ urls: [URL], to target: String, name: String? = nil, prepare: (() throws -> [URL])? = nil) {
        if !Converter.isTool(target) { Set(urls.map(Converter.ext)).forEach { Usage.record($0, target) } }
        let job = Job(name: name ?? (urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"))
        let id = ObjectIdentifier(job)
        var lastSent = -1.0 // only touched on the job's background thread
        job.onProgress = { [weak self] fraction in
            guard fraction - lastSent >= 0.01 || fraction >= 1 else { return } // ~100 UI updates max
            lastSent = fraction
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress[id] = fraction
                self.updateIcon()
                self.jobMenuItems[id]?.title = self.jobTitle(job)
            }
        }
        jobs.append(job)
        DispatchQueue.global(qos: .userInitiated).async {
            var files = urls, result: (outputs: [URL], errors: [String])
            do {
                if let prepare {
                    Job.current = job
                    files = try prepare()
                    Job.current = nil
                }
                result = Converter.convertAll(files, to: target, job: job)
            } catch {
                Job.current = nil
                result = ([], ["\(name ?? "Download"): \(error.localizedDescription)"])
            }
            DispatchQueue.main.async { self.finish(job, target, files, result.outputs, result.errors) }
        }
    }

    func jobTitle(_ job: Job) -> String {
        "Converting \(job.name)" + (progress[ObjectIdentifier(job)].map { " — \(Int($0 * 100))%" } ?? "…")
    }

    @objc func cancelJob(_ item: NSMenuItem) { (item.representedObject as? Job)?.cancel() }

    func finish(_ job: Job, _ target: String, _ sources: [URL], _ outputs: [URL], _ errors: [String]) {
        progress[ObjectIdentifier(job)] = nil
        jobs.removeAll { $0 === job }
        Recents.add(outputs)
        produced.formUnion(outputs.map(\.path))
        outputs.forEach(cacheThumbnail)
        if job.isCancelled {
            lastResult = "Last conversion cancelled"
            return notify("Cancelled", outputs.isEmpty ? "Nothing was saved." : "\(outputs.count) finished before you cancelled.", outputs: outputs)
        }
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
                let done = ["Compress": "Compressed", "Resize": "Resized", "Send-ready": "Ready to send", "Remove location": "Location removed",
                            "Crop": "Cropped", "Trim": "Trimmed"][label] ?? label
                notify(done, lines.joined(separator: "\n"), outputs: outputs)
            } else {
                let title = ["zip": "Zipped", "extract": "Extracted", "combine": "Combined into one PDF"][target] ?? "Converted to \(label)"
                notify(title, outputs.map(\.lastPathComponent).joined(separator: ", "), outputs: outputs)
            }
        } else {
            lastResult = "Last conversion failed"
            let failed = Converter.isTool(target) ? "\(label) failed" : "\(label) conversion failed"
            let title = outputs.isEmpty ? failed : "\(errors.count) of \(errors.count + outputs.count) failed"
            notify(title, errors.joined(separator: "\n"), outputs: outputs)
        }
    }

    /// `opens`: what a click opens ("settings", "update", "changelog"). `outputs`: adds Show in Finder / Undo for the files Swivel made.
    func notify(_ title: String, _ body: String, opensSettings: Bool = false, opens: String? = nil, outputs: [URL] = []) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let target = opens ?? (opensSettings ? "settings" : nil) { content.userInfo = ["open": target] }
        if !outputs.isEmpty {
            content.categoryIdentifier = "result"
            content.userInfo = ["outputs": outputs.map(\.path)]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let outputs = (info["outputs"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if action == "undo" { self.undo(outputs) }
            else if info["open"] as? String == "settings" { self.showSettings() }
            else if info["open"] as? String == "update" { self.showUpdates(check: self.updater.release == nil) }
            else if info["open"] as? String == "changelog", let page = Updater.homepage {
                NSWorkspace.shared.open(page.appendingPathComponent("blob/main/CHANGELOG.md"))
            }
            else if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            else { self.showLastOutput() }
        }
        completionHandler()
    }

    /// Moves the files a conversion made (never the originals) to the Trash, so Undo can itself be undone.
    func undo(_ outputs: [URL]) {
        let trashed = outputs.filter { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }
        if trashed.isEmpty { return notify("Nothing to undo", "Those files were already moved or deleted.") }
        notify("Moved \(trashed.count == 1 ? trashed[0].lastPathComponent : "\(trashed.count) files") to the Trash",
               "Use Put Back in the Trash if you change your mind.")
    }

    func cacheThumbnail(_ url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 32, height: 32), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnails[url.path] = image }
        }
    }

    // MARK: - Menu

    /// Pie when idle; a filling ring while converting (the slowest job); hourglass until progress is known.
    func updateIcon() {
        guard let button = statusItem.button else { return }
        if jobs.isEmpty {
            button.image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "Swivel")
        } else if let fraction = jobs.compactMap({ progress[ObjectIdentifier($0)] }).min() {
            button.image = ring(fraction)
            button.setAccessibilityLabel("Swivel, converting, \(Int(fraction * 100)) percent")
        } else {
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Swivel, converting")
        }
    }

    func ring(_ fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY), radius: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(fraction, 0.03)), clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true // menu bar tints it for light/dark
        return image
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
        jobMenuItems = [:]
        if jobs.isEmpty { _ = add(lastResult ?? ready) }
        for job in jobs {
            jobMenuItems[ObjectIdentifier(job)] = add(jobTitle(job))
            let cancel = add("Cancel", #selector(cancelJob(_:)))
            cancel.representedObject = job
            cancel.indentationLevel = 1
        }
        if let ff = Converter.ffmpegPath {
            _ = add("ffmpeg: \(ff)")
        } else {
            _ = add("ffmpeg missing: audio, video, WebP, AVIF are off")
            _ = add("Download ffmpeg (free, \(FFmpegSetup.downloadMB) MB)…", #selector(installFFmpeg))
        }
        menu.addItem(.separator())
        if let release = updater.release {
            let item = add("Update to Swivel \(release.version)…", #selector(showUpdateWindow))
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        }
        _ = add("How to Use & Settings…", #selector(showSettings), key: ",")
        _ = add("Check for Updates…", #selector(checkForUpdatesNow))
        add("Launch at Login", #selector(toggleLaunchAtLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("Show Last Output in Finder", lastOutput == nil ? nil : #selector(showLastOutput))
        let recents = Recents.all
        let recentItem = add("Recent Conversions")
        if !recents.isEmpty {
            let sub = NSMenu()
            for url in recents {
                let item = sub.addItem(withTitle: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.toolTip = url.path
                let icon = thumbnails[url.path] ?? NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            sub.addItem(.separator())
            sub.addItem(withTitle: "Clear Recents", action: #selector(clearRecents), keyEquivalent: "").target = self
            recentItem.submenu = sub
        }
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

    func openEditor(_ id: String, _ urls: [URL]) {
        let done: (URL, String) -> Void = { [weak self] file, target in self?.convert([file], to: target) }
        let editor: Editor = id == "crop" ? CropController(files: urls, onCrop: done) : TrimController(files: urls, onTrim: done)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
            self?.dropDockIconIfNoWindows()
        }
        editors.append(editor)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        editor.show()
    }

    /// Opening Swivel again (Applications, Spotlight, Dock) brings its window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: "didOnboard") { showSettings() } else { showWelcome() }
        return true
    }

    /// Back to menu-bar-only once the last Swivel window closes.
    func windowWillClose(_ notification: Notification) { dropDockIconIfNoWindows(closing: notification.object as? NSWindow) }

    func dropDockIconIfNoWindows(closing: NSWindow? = nil) {
        DispatchQueue.main.async { // after the closing window is gone
            let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
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

    /// Opens Settings, where the download shows its progress.
    @objc func installFFmpeg() {
        showSettings()
        FFmpegSetup.shared.install()
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

    @objc func revealRecent(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func clearRecents() { Recents.clear() }

    @objc func showUpdateWindow() { showUpdates(check: false) }

    @objc func quit() { NSApp.terminate(nil) }
}
