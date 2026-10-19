import AppKit

/// Installs ffmpeg (and Homebrew if needed) in a visible Terminal window, never silently.
enum FFmpegSetup {
    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The script Terminal runs. Ends by restarting Swivel so it picks up the new ffmpeg.
    static func script(appPath: String) -> String {
        let app = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/bash
        echo "Installing ffmpeg for Swivel. This can take a few minutes."
        echo
        find_brew() { for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && echo "$b" && return; done; }
        BREW=$(find_brew)
        if [ -z "$BREW" ]; then
          echo "Homebrew isn't installed yet. Installing it first with Homebrew's official installer (https://brew.sh)."
          echo "It will ask for your Mac password. Nothing shows while you type it; press Return when done."
          echo
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { echo; echo "Homebrew install failed. See the messages above."; exit 1; }
          BREW=$(find_brew)
        fi
        "$BREW" install ffmpeg || { echo; echo "ffmpeg install failed. See the messages above."; exit 1; }
        echo
        echo "Done! Restarting Swivel. You can close this window."
        osascript -e 'quit app "Swivel"' >/dev/null 2>&1
        sleep 1
        open \(app)
        """
    }

    static func install() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Install ffmpeg for Swivel.command")
        do {
            try script(appPath: Bundle.main.bundlePath).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            NSWorkspace.shared.open(URL(string: "https://formulae.brew.sh/formula/ffmpeg")!)
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// ffmpeg is looked up at launch, so a restart picks up a fresh install.
    static func restart() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
