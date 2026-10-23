import Foundation

/// "Convert new files in this folder to that format", e.g. Desktop screenshots → JPG.
struct WatchRule: Codable, Equatable, Hashable {
    var path: String
    var target: String

    /// Targets offered for watch folders (formats, plus a few one-click tools).
    static let choices: [(id: String, title: String)] = [
        ("jpg", "JPG"), ("png", "PNG"), ("heic", "HEIC"), ("webp", "WebP"), ("pdf", "PDF"), ("mp4", "MP4"), ("mp3", "MP3"),
        ("compress-balanced", "Compress (Balanced)"), ("strip", "Remove location"), ("send-10", "Send · under 10 MB"),
    ]
}

/// Watches folders for new files and hands each finished one to `onFile`. Never touches originals
/// (conversions write new files) and skips Swivel's own results so a rule can't loop on itself.
final class FolderWatcher {
    private let onFile: (URL, String) -> Void
    private let isOwnOutput: (String) -> Bool
    private var rules: [WatchRule] = []
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var known: [String: Set<String>] = [:]
    private var pending: Set<String> = []

    /// Names Swivel gives its results, so watched folders ignore them.
    static let ownSuffixes = [" compressed", " resized", " no location", " (under ", " cropped", " trimmed", " combined", " merged"]
    static let partialExtensions: Set = ["download", "crdownload", "part", "partial", "tmp"]

    init(onFile: @escaping (URL, String) -> Void, isOwnOutput: @escaping (String) -> Bool) {
        self.onFile = onFile
        self.isOwnOutput = isOwnOutput
    }

    func update(_ newRules: [WatchRule]) {
        rules = newRules
        let folders = Set(newRules.map(\.path))
        for (path, source) in sources where !folders.contains(path) {
            source.cancel()
            sources[path] = nil
            known[path] = nil
        }
        for path in folders where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            known[path] = listing(path) // only files that arrive from now on
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.scan(path) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    private func listing(_ path: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
    }

    private func scan(_ path: String) {
        let now = listing(path)
        let arrived = now.subtracting(known[path] ?? [])
        known[path] = now
        for name in arrived where !name.hasPrefix(".") {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            waitUntilFinished(url, lastSize: -1)
        }
    }

    /// A file still being written (download, export) grows; act once its size holds for a second.
    private func waitUntilFinished(_ url: URL, lastSize: Int) {
        guard !pending.contains(url.path) || lastSize >= 0 else { return }
        pending.insert(url.path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
                self.pending.remove(url.path) // gone (renamed or deleted)
                return
            }
            if size != lastSize || size == 0 { return self.waitUntilFinished(url, lastSize: size) }
            self.pending.remove(url.path)
            self.handle(url)
        }
    }

    private func handle(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        guard !Self.partialExtensions.contains(url.pathExtension.lowercased()), !isOwnOutput(url.path),
              !Self.ownSuffixes.contains(where: { name.contains($0) }) else { return }
        let folder = url.deletingLastPathComponent().path
        for rule in rules where rule.path == folder && Self.applies(rule.target, to: url) {
            onFile(url, rule.target)
        }
    }

    static func applies(_ target: String, to url: URL) -> Bool {
        let e = Converter.ext(url)
        if target.hasPrefix("compress-") && e == "pdf" { return true }
        if Converter.isTool(target) { return Converter.canUseTools(url) }
        return Converter.targets(forExt: e).contains(target)
    }
}
