import AppKit

/// Downloads ffmpeg + ffprobe into Swivel's own folder with one click: no Homebrew, Terminal or password.
/// The build is pinned (exact URL + SHA-256) and must carry its maker's Apple Developer ID signature.
final class FFmpegSetup: ObservableObject {
    static let shared = FFmpegSetup()

    enum State: Equatable { case idle, downloading(Double), installing, failed(String) }
    @Published var state = State.idle

    // Martin Riedl's Apple-silicon release build of ffmpeg 9.0.2 (open-source build script, Developer ID signed).
    // To move to a newer build: change the URLs and checksums together.
    static let source = "ffmpeg.martin-riedl.de"
    static let files: [(name: String, url: URL, sha256: String)] = [
        ("ffmpeg", URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip")!,
         "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"),
        ("ffprobe", URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffprobe.zip")!,
         "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6"),
    ]
    static let downloadMB = 57
    /// Apple Developer ID team of the build's maker; anything signed by someone else is refused.
    static let signingTeam = "KU3N25YGLU"

    private var observation: NSKeyValueObservation?

    func install() {
        state = .downloading(0)
        download(index: 0, staged: [])
    }

    /// Downloads the files one after another, verifying each, then installs them together.
    private func download(index: Int, staged: [URL]) {
        guard index < Self.files.count else { return finish(staged) }
        let file = Self.files[index]
        let task = URLSession.shared.downloadTask(with: file.url) { [weak self] zip, _, error in
            do {
                guard let zip else { throw ConvertError(error?.localizedDescription ?? "The download failed.") }
                let binary = try Self.verifyAndUnpack(zip: zip, name: file.name, sha256: file.sha256)
                DispatchQueue.main.async { self?.download(index: index + 1, staged: staged + [binary]) }
            } catch {
                DispatchQueue.main.async { self?.state = .failed(error.localizedDescription) }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let overall = (Double(index) + progress.fractionCompleted) / Double(Self.files.count)
            DispatchQueue.main.async {
                if case .downloading = self?.state { self?.state = .downloading(overall) }
            }
        }
        task.resume()
    }

    /// Checksum, unzip to a temp folder, and check the binary's Developer ID signature.
    static func verifyAndUnpack(zip: URL, name: String, sha256: String) throws -> URL {
        let digest = try Converter.run("/usr/bin/shasum", ["-a", "256", zip.path]).prefix(64)
        guard digest == sha256 else { throw ConvertError("The \(name) download didn't match its checksum. Try again later.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-ffmpeg-\(UUID().uuidString)")
        try Converter.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let binary = dir.appendingPathComponent(name)
        // "-R=" (with the =) passes the requirement inline; without it codesign reads it as a file path.
        try Converter.run("/usr/bin/codesign", ["--verify", "--strict",
                                                "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(signingTeam)\"", binary.path])
        return binary
    }

    private func finish(_ binaries: [URL]) {
        state = .installing
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Converter.ownFFmpegDir, withIntermediateDirectories: true)
            for binary in binaries {
                let dest = Converter.ownFFmpegDir.appendingPathComponent(binary.lastPathComponent)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: binary, to: dest)
                try? fm.removeItem(at: binary.deletingLastPathComponent())
            }
            Self.restart()
        } catch {
            state = .failed("Couldn't install ffmpeg: \(error.localizedDescription)")
        }
    }

    /// ffmpeg is looked up at launch, so a restart picks up the new install.
    static func restart() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
