import AppKit

/// A modifier key the user taps mid-drag to open a wheel.
enum TriggerKey: String, CaseIterable {
    case shift, control, option, command

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }

    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        }
    }

    var name: String { rawValue.capitalized }
    var glyph: String { String(title.prefix(1)) }
}

/// The two wheels: change the format, or do something with the file.
enum WheelMode { case convert, actions }

/// User settings, stored in UserDefaults. (ObservableObject, not @State/@AppStorage macros: those need full Xcode.)
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var convertDrag: Bool { didSet { d.set(convertDrag, forKey: "convertDrag") } }
    @Published var convertKey: TriggerKey { didSet { d.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var convertFinder: Bool {
        didSet { d.set(convertFinder, forKey: "convertFinder"); FinderMenu.set(.convert, enabled: convertFinder) }
    }
    @Published var actionsDrag: Bool { didSet { d.set(actionsDrag, forKey: "actionsDrag") } }
    @Published var actionsKey: TriggerKey { didSet { d.set(actionsKey.rawValue, forKey: "actionsKey") } }
    @Published var actionsFinder: Bool {
        didSet { d.set(actionsFinder, forKey: "actionsFinder"); FinderMenu.set(.actions, enabled: actionsFinder) }
    }

    private init() {
        d.register(defaults: ["convertDrag": true, "convertKey": "shift", "convertFinder": true,
                              "actionsDrag": true, "actionsKey": "control", "actionsFinder": true])
        convertDrag = d.bool(forKey: "convertDrag")
        convertKey = TriggerKey(rawValue: d.string(forKey: "convertKey") ?? "") ?? .shift
        convertFinder = d.bool(forKey: "convertFinder")
        actionsDrag = d.bool(forKey: "actionsDrag")
        actionsKey = TriggerKey(rawValue: d.string(forKey: "actionsKey") ?? "") ?? .control
        actionsFinder = d.bool(forKey: "actionsFinder")
        if actionsKey == convertKey { actionsKey = TriggerKey.allCases.first { $0 != convertKey }! }
    }

    /// Keys a wheel may use: anything except the key the other wheel already uses.
    func keys(for mode: WheelMode) -> [TriggerKey] {
        TriggerKey.allCases.filter { $0 != (mode == .convert ? actionsKey : convertKey) }
    }
}

/// Swivel's Finder right-click items are macOS Services declared in Info.plist (build.sh).
/// Turning one off writes the same per-service switch as System Settings > Keyboard > Keyboard Shortcuts > Services.
enum FinderMenu {
    static let titles: [WheelMode: (title: String, message: String)] = [
        .convert: ("Convert with Swivel", "convertFiles"),
        .actions: ("Share with Swivel", "fileActions"),
    ]

    static func set(_ mode: WheelMode, enabled: Bool) {
        let item = titles[mode]!
        let key = "com.local.swivel - \(item.title) - \(item.message)"
        var status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, "pbs" as CFString) as? [String: Any] ?? [:]
        status[key] = ["enabled_context_menu": enabled, "enabled_services_menu": enabled,
                       "presentation_modes": ["ContextMenu": enabled, "ServicesMenu": enabled]]
        CFPreferencesSetAppValue("NSServicesStatus" as CFString, status as CFDictionary, "pbs" as CFString)
        CFPreferencesAppSynchronize("pbs" as CFString)
        NSUpdateDynamicServices()
    }

    /// Re-applies the saved switches (e.g. after the app moved, so macOS re-read its services).
    static func sync() {
        set(.convert, enabled: Prefs.shared.convertFinder)
        set(.actions, enabled: Prefs.shared.actionsFinder)
    }
}

/// Counts which format each file type gets converted to, so the wheel can put the usual one first.
enum Usage {
    private static let key = "usage"
    private static var all: [String: [String: Int]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
    }

    static func record(_ ext: String, _ target: String) {
        var counts = all
        counts[ext, default: [:]][target, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }

    /// The format picked most for this type, once it has been picked at least twice (ties: alphabetical, so it's stable).
    static func favorite(_ ext: String) -> String? {
        guard let best = all[ext]?.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= 2 else { return nil }
        return best.key
    }
}

/// The last 10 files Swivel made, newest first; files that were since moved or deleted drop out.
enum Recents {
    private static let key = "recents"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ urls: [URL]) {
        let new = urls.map(\.path)
        let kept = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { !new.contains($0) }
        UserDefaults.standard.set(Array((new + kept).prefix(10)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
