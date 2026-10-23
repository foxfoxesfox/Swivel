import SwiftUI
import ServiceManagement

// Views use ObservableObject models rather than @State: the @State macro needs full Xcode to compile.

/// Finder lists Swivel's items at the bottom of the right-click menu, or inside Services when there are many.
let finderMenuPath = "right-click a file ›"
let finderMenuHint = "It's at the bottom of the menu, or inside Services."

final class LoginItem: ObservableObject {
    @Published var status = SMAppService.mainApp.status
    @Published var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

final class Pager: ObservableObject { @Published var page = 0 }

// MARK: - First-launch welcome (4 pages)

struct WelcomeView: View {
    let onFinish: () -> Void
    @ObservedObject var pager = Pager()
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var login = LoginItem()
    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch pager.page {
                case 0: welcomePage
                case 1: convertPage
                case 2: actionsPage
                default: settingsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == pager.page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(pager.page + 1) of \(pageCount)")
                Spacer()
                if pager.page > 0 {
                    Button("Back") { pager.page -= 1 }
                }
                Button(pager.page == pageCount - 1 ? "Start Using Swivel" : "Continue") {
                    if pager.page == pageCount - 1 { onFinish() } else { pager.page += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pager.page == 1 && !prefs.convertDrag && !prefs.convertFinder)
            }
            .padding(16)
        }
        .frame(width: 540, height: 700)
    }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                .padding(.top, 28)
            VStack(spacing: 6) {
                Text("Welcome to Swivel").font(.largeTitle.bold())
                Text("A file converter that lives in your menu bar.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                feature("arrow.triangle.2.circlepath", "Convert without opening an app",
                        "Turn photos, audio, videos and PDFs into other formats right from Finder.")
                feature("square.and.arrow.up", "Share and move files fast",
                        "AirDrop, share, compress, or shrink a video to fit Discord, WhatsApp or email.")
                feature("lock.shield", "Private and offline",
                        "Everything happens on your Mac. Nothing is ever uploaded.")
            }
            .padding(.horizontal, 48)
            .padding(.top, 8)
        }
    }

    private var convertPage: some View {
        page("How do you want to convert files?", "Pick one or both. You can change this later in Settings.") {
            Section { ConvertRows(prefs: prefs) }
            if prefs.convertDrag {
                Section("Drag, then tap a key") {
                    Flow(steps: [.icon("doc", "Start dragging a file"), .key(prefs.convertKey.glyph, "Tap \(prefs.convertKey.name)"),
                                 .icon("chart.pie", "Let go on a format")])
                }
            }
            if prefs.convertFinder {
                Section("Right-click in Finder") {
                    Flow(steps: [.icon("cursorarrow.click.2", "Right-click a file"), .icon("list.bullet", "Choose Convert with Swivel"),
                                 .icon("chart.pie", "Click a format")])
                }
            }
            if !prefs.convertDrag && !prefs.convertFinder {
                Label("Choose at least one way to convert.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var actionsPage: some View {
        page("Share and file actions", "AirDrop, Share, Copy, Move, Compress, Resize and more.") {
            Section { ActionsRows(prefs: prefs) }
            if prefs.actionsDrag {
                Section("Drag, then tap a key") {
                    Flow(steps: [.icon("doc", "Start dragging a file"), .key(prefs.actionsKey.glyph, "Tap \(prefs.actionsKey.name)"),
                                 .icon("square.and.arrow.up", "Let go on an action")])
                }
            }
            if prefs.actionsFinder {
                Section("Right-click in Finder") {
                    Flow(steps: [.icon("cursorarrow.click.2", "Right-click a file"), .icon("list.bullet", "Choose Share with Swivel"),
                                 .icon("square.and.arrow.up", "Click an action")])
                }
            }
        }
    }

    private var settingsPage: some View {
        page("A few more settings", "That's it. Swivel is in your menu bar whenever you need it.") {
            Section { GeneralRows(login: login) }
            Section("ffmpeg") { FFmpegRows() }
        }
    }

    private func page<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title.bold())
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            Form { content() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    let onShowWelcome: () -> Void
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var login = LoginItem()

    var body: some View {
        Form {
            Section("How to use") { HowTo(prefs: prefs) }
            Section("Converting") { ConvertRows(prefs: prefs) }
            Section("Share and file actions") { ActionsRows(prefs: prefs) }
            Section {
                WheelRows(prefs: prefs)
            } header: {
                Text("Wheel")
            } footer: {
                Text("Slices only appear when they fit the files you drag; e.g. Trim only for videos.").foregroundStyle(.secondary)
            }
            Section {
                WatchRows(prefs: prefs)
            } header: {
                Text("Watch folders")
            } footer: {
                Text("New files in these folders are converted automatically, e.g. Desktop screenshots → JPG. Originals are kept, and Swivel ignores its own results. macOS may ask once for permission to see a folder.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("General") {
                GeneralRows(login: login)
                HStack {
                    Text("Welcome tour")
                    Spacer()
                    Button("Show Again", action: onShowWelcome)
                }
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            }
            Section("ffmpeg") { FFmpegRows() }
            Section {
                formats("Images", "JPG, PNG, HEIC, TIFF, BMP, GIF, PDF, ICO, ICNS, WebP*, AVIF*; camera RAW in; several → one PDF")
                formats("Audio", "MP3, M4A, WAV, FLAC, OGG, Opus, AIFF; WMA, AAC in")
                formats("Video", "MP4, MOV, MKV, WebM, GIF, MP3; AVI, WMV, FLV, MPG and more in")
                formats("PDF", "PNG, JPG, TXT, Split, Merge (2+ PDFs)")
                formats("Documents", "Word, RTF, ODT, HTML, TXT ↔ each other; Markdown, EPUB in; all → PDF")
                formats("Archives", "ZIP, TAR, GZ → Extract; anything → Zip (actions wheel)")
                formats("Subtitles", "SRT, VTT, ASS ↔ each other*")
            } header: {
                Text("What converts to what")
            } footer: {
                Text("* needs ffmpeg, as do all audio and video conversions.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 760)
    }

    private func formats(_ kind: String, _ list: String) -> some View {
        LabeledContent(kind) { Text(list).multilineTextAlignment(.trailing) }
    }
}

// MARK: - Shared rows

/// Steps that match the user's current settings.
struct HowTo: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        if prefs.convertDrag {
            step("hand.point.up.left", "Convert: drag, then tap \(prefs.convertKey.title)",
                 "Start dragging a file and keep holding. Tap \(prefs.convertKey.name), then let go on a format. The copy appears next to the original.")
        }
        if prefs.convertFinder {
            step("cursorarrow.click.2", "Convert: \(finderMenuPath) Convert with Swivel",
                 "\(finderMenuHint) Then click a format on the wheel. Press Esc to cancel.")
        }
        if prefs.actionsDrag {
            step("square.and.arrow.up", "Share: drag, then tap \(prefs.actionsKey.title)",
                 "Let go on AirDrop, Share, Copy, Move, Copy Path, Terminal or Zip. Photos and videos also get Compress, Resize, Send (fit under 10, 16 or 25 MB), No Location, and Crop or Trim; PDFs get Compress.")
        }
        if prefs.actionsFinder {
            step("cursorarrow.click.2", "Share: \(finderMenuPath) Share with Swivel",
                 "\(finderMenuHint) Then click an action on the wheel.")
        }
        step("xmark.circle", "Changed your mind?", "Let go or click in the centre, or anywhere off the wheel.")
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ConvertRows: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        TriggerRows(dragOn: $prefs.convertDrag, key: $prefs.convertKey, finderOn: $prefs.convertFinder,
                    keys: prefs.keys(for: .convert), finderItem: "Convert with Swivel",
                    dragHelp: "Start dragging a file, tap the key, let go on a format.")
    }
}

struct ActionsRows: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        TriggerRows(dragOn: $prefs.actionsDrag, key: $prefs.actionsKey, finderOn: $prefs.actionsFinder,
                    keys: prefs.keys(for: .actions), finderItem: "Share with Swivel",
                    dragHelp: "Start dragging a file, tap the key, let go on an action.")
    }
}

private struct TriggerRows: View {
    @Binding var dragOn: Bool
    @Binding var key: TriggerKey
    @Binding var finderOn: Bool
    let keys: [TriggerKey]
    let finderItem: String
    let dragHelp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Drag, then tap a key", isOn: $dragOn)
            Text(dragHelp).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if dragOn {
            Picker("Key", selection: $key) {
                ForEach(keys, id: \.self) { Text($0.title).tag($0) }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Right-click in Finder", isOn: $finderOn)
            Text("\(finderMenuPath.prefix(1).uppercased() + finderMenuPath.dropFirst()) \(finderItem). \(finderMenuHint)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GeneralRows: View {
    @ObservedObject var login: LoginItem
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Check for updates automatically", isOn: $prefs.autoUpdate)
                Spacer()
                Button("Check Now") { (NSApp.delegate as? AppDelegate)?.showUpdates(check: true) }
            }
            Text("Once a day Swivel asks GitHub if there's a newer version, then lets you install it with one click. Nothing about you or your files is sent.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Launch at Login", isOn: Binding(
            get: { login.status == .enabled || login.status == .requiresApproval },
            set: login.set))
        if login.status == .requiresApproval {
            HStack {
                Text("Allow Swivel in Login Items to finish turning this on.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error = login.error {
            Text(error).foregroundStyle(.red)
        }
        HStack {
            Text("Notifications")
            Spacer()
            Button("Open Notification Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
    }
}

struct FFmpegRows: View {
    @ObservedObject var setup = FFmpegSetup.shared
    // Parameter (defaulting to the live state) so the "missing" layout can be previewed.
    var path = Converter.ffmpegPath

    var body: some View {
        if let path {
            Label(path.hasPrefix(Converter.ownFFmpegDir.path) ? "Installed (downloaded by Swivel)" : "Installed at \(path)",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Audio, video, WebP, AVIF and subtitles need ffmpeg, a free converter. Photos, PDFs, documents and archives work without it.",
                  systemImage: "info.circle.fill")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch setup.state {
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading ffmpeg… \(Int(fraction * 100))%") }
            case .installing:
                ProgressView { Text("Installing. Swivel will restart in a moment.") }
            default:
                HStack(alignment: .center) {
                    Text("One click, about \(FFmpegSetup.downloadMB) MB from \(FFmpegSetup.source). No Terminal or password needed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Download ffmpeg") { setup.install() }.buttonStyle(.borderedProminent)
                }
                if case .failed(let message) = setup.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A row of pictures showing the steps, e.g. file → ⇧ → wheel.
struct Flow: View {
    enum Step {
        case icon(String, String)
        case key(String, String)
    }
    let steps: [Step]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                if i > 0 {
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 20).accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    switch steps[i] {
                    case .icon(let symbol, _):
                        Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Color.accentColor)
                            .frame(width: 56, height: 56).accessibilityHidden(true)
                    case .key(let glyph, _):
                        Text(glyph).font(.system(size: 24, weight: .medium))
                            .frame(width: 56, height: 56)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            .accessibilityHidden(true)
                    }
                    Text(caption(steps[i])).font(.callout).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 118)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func caption(_ step: Step) -> String {
        switch step { case .icon(_, let c), .key(_, let c): return c }
    }
}

// MARK: - Updates

struct UpdateView: View {
    @ObservedObject var updater = Updater.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.bold())
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let release = updater.release, !release.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's new").font(.headline)
                    ScrollView {
                        Text(notes(release.notes)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(height: 200)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                }
            }
            status
            HStack {
                if case .failed = updater.state, let page = Updater.homepage {
                    Link("Open GitHub page", destination: page)
                }
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        switch updater.state {
        case .checking: return "Checking for updates…"
        case .upToDate: return "Swivel is up to date"
        case .failed where updater.release == nil: return "Couldn't check for updates"
        default: return updater.release.map { "Swivel \($0.version) is available" } ?? "Updates"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .upToDate: return "You have the latest version, \(Updater.currentVersion)."
        case .checking: return "Asking GitHub for the latest version."
        default:
            if updater.release == nil { return "Check your internet connection and try again." }
            return "You have \(Updater.currentVersion). Updating takes a few seconds and keeps your settings."
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading… \(Int(fraction * 100))%") }
        case .installing:
            ProgressView { Text("Installing. Swivel will reopen in a moment.") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.state {
        case .available:
            Button("Later", action: onClose).keyboardShortcut(.cancelAction)
            Button("Install and Relaunch") { updater.install() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            Button("Try Again") { updater.release == nil ? updater.check() : updater.install() }.keyboardShortcut(.defaultAction)
        case .downloading, .installing, .checking:
            Button("Close", action: onClose).disabled(updater.state == .installing)
        default:
            Button("OK", action: onClose).keyboardShortcut(.defaultAction)
        }
    }

    /// CHANGELOG markdown: headings in bold, bullets as •, bold/links inline, line breaks kept.
    private func notes(_ text: String) -> AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("### ") { return "**\(line.dropFirst(4))**" }
            if line.hasPrefix("  - ") { return "    ◦ " + line.dropFirst(4) }
            if line.hasPrefix("- ") { return "• " + line.dropFirst(2) }
            return String(line)
        }
        let cleaned = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }
}

/// Reorder and hide action slices; hide formats from the convert wheel.
struct WheelRows: View {
    @ObservedObject var prefs: Prefs
    static let formats = ["jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif", "ico", "icns", "pdf", "combine",
                          "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "mp4", "mov", "mkv", "webm",
                          "docx", "rtf", "html", "txt", "odt", "srt", "vtt", "ass", "split", "merge", "extract"]

    var body: some View {
        Text("Actions wheel: order and visibility").font(.headline)
        ForEach(prefs.actionOrder, id: \.self) { id in
            if let item = FileActions.allItems.first(where: { $0.id == id }) {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { !prefs.hiddenActions.contains(id) },
                                         set: { show in prefs.hiddenActions.removeAll { $0 == id }; if !show { prefs.hiddenActions.append(id) } })) {
                        Label(item.label, systemImage: item.symbol ?? "circle")
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button { prefs.moveAction(id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(prefs.actionOrder.first == id)
                        .accessibilityLabel("Move \(item.label) up")
                    Button { prefs.moveAction(id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(prefs.actionOrder.last == id)
                        .accessibilityLabel("Move \(item.label) down")
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Convert wheel: formats to show").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 6) {
                ForEach(Self.formats, id: \.self) { id in
                    Toggle(Converter.label(id), isOn: Binding(get: { !prefs.hiddenFormats.contains(id) },
                                                             set: { show in prefs.hiddenFormats.removeAll { $0 == id }; if !show { prefs.hiddenFormats.append(id) } }))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(.vertical, 4)
        HStack {
            Spacer()
            Button("Reset Wheel to Defaults") { prefs.resetWheel() }
        }
    }
}

struct WatchRows: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        ForEach(prefs.watchRules, id: \.self) { rule in
            HStack {
                Label((rule.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Picker("Convert to", selection: Binding(get: { rule.target }, set: { new in
                    if let i = prefs.watchRules.firstIndex(of: rule) { prefs.watchRules[i].target = new }
                })) {
                    ForEach(WatchRule.choices, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 190)
                Button { prefs.watchRules.removeAll { $0 == rule } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop watching \((rule.path as NSString).lastPathComponent)")
            }
        }
        Button("Add Watch Folder…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Watch"
            panel.message = "New files in this folder will be converted automatically."
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url, !prefs.watchRules.contains(where: { $0.path == url.path }) {
                prefs.watchRules.append(WatchRule(path: url.path, target: "jpg"))
            }
        }
    }
}
