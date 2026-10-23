import AppKit
import CryptoKit

/// Checks the GitHub repo for a newer Swivel and installs it in place.
/// make-dmg.sh publishes dist/latest.json (version, DMG link, SHA-256, notes); nothing about the user is sent.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let bundleID = "com.local.swivel"

    struct Release: Decodable, Equatable {
        let version: String
        let url: URL
        let sha256: String
        let notes: String
    }

    enum State: Equatable { case idle, checking, upToDate, available, downloading(Double), installing, failed(String) }

    @Published var state = State.idle
    @Published var release: Release?
    private var observation: NSKeyValueObservation?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var homepage: URL? { (Bundle.main.infoDictionary?["SwivelHomepage"] as? String).flatMap(URL.init(string:)) }

    /// From Info.plist (set by build.sh); `defaults write com.local.swivel updateFeed <url>` overrides it for testing.
    static var feed: URL? {
        (UserDefaults.standard.string(forKey: "updateFeed") ?? Bundle.main.infoDictionary?["SwivelUpdateFeed"] as? String)
            .flatMap(URL.init(string:))
    }

    /// "2.10" > "2.9", "2.1.1" > "2.1".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Calls back on the main thread with the newer release, or nil.
    func check(completion: ((Release?) -> Void)? = nil) {
        guard let feed = Self.feed else { state = .failed("No update address is set."); return }
        state = .checking
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: request) { data, _, error in
            let latest = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                if let latest, Self.isNewer(latest.version, than: Self.currentVersion) {
                    self.release = latest
                    self.state = .available
                } else if latest != nil {
                    self.release = nil
                    self.state = .upToDate
                } else {
                    self.state = .failed(error?.localizedDescription ?? "Couldn't read the update information.")
                }
                completion?(self.state == .available ? latest : nil)
            }
        }.resume()
    }

    func install() {
        guard let release else { return }
        let app = Bundle.main.bundleURL
        // A translocated or read-only copy (e.g. still inside the DMG) can't replace itself.
        guard !app.path.contains("/AppTranslocation/"), app.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            state = .failed("Swivel can't update itself from where it is. Move it to Applications first, or download the new version from GitHub.")
            return
        }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: release.url) { file, _, error in
            do {
                guard let file else { throw ConvertError(error?.localizedDescription ?? "The download failed.") }
                let staged = try Self.stage(dmg: file, release: release) // before the handler returns: `file` is then deleted
                DispatchQueue.main.async {
                    self.state = .installing
                    Self.relaunch(replacing: app, with: staged)
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.state { self?.state = .downloading(progress.fractionCompleted) }
            }
        }
        task.resume()
    }

    /// Checks the download (SHA-256, bundle ID, version, code signature) and copies Swivel.app out of the DMG.
    static func stage(dmg: URL, release: Release) throws -> URL {
        let digest = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else {
            throw ConvertError("The download didn't match the published checksum. Try again in a few minutes.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt"), staged = work.appendingPathComponent("Swivel.app")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Converter.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? Converter.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let app = mount.appendingPathComponent("Swivel.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            throw ConvertError("The download isn't the expected Swivel \(release.version).")
        }
        try Converter.run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        try Converter.run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Shell script run after Swivel quits: swap the app, keep the old one until the copy succeeds, reopen.
    static func installScript(app: URL, staged: URL, pid: Int32) -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = q(app.path), new = q(staged.path), backup = q(app.path + ".previous")
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(backup)
        if mv \(old) \(backup); then
          if ditto \(new) \(old); then rm -rf \(backup); else rm -rf \(old); mv \(backup) \(old); fi
        fi
        xattr -dr com.apple.quarantine \(old) 2>/dev/null
        rm -rf \(q(staged.deletingLastPathComponent().path))
        open \(old)
        """
    }

    static func relaunch(replacing app: URL, with staged: URL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = ["-c", installScript(app: app, staged: staged, pid: ProcessInfo.processInfo.processIdentifier)]
        do { try helper.run() } catch { return Updater.shared.state = .failed("Couldn't start the installer: \(error.localizedDescription)") }
        UserDefaults.standard.set(currentVersion, forKey: "updatedFrom")
        NSApp.terminate(nil)
    }
}
