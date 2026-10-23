import AppKit

/// Something dragged out of a web browser: a link to a file Swivel can convert, or just picture data.
/// It's saved to Downloads first (like the browser would), then converted from there.
struct WebDrop {
    let url: URL?
    let imageData: Data?
    let ext: String
    let name: String

    /// Reads a drag that has no local files. Prefers a link with a convertible extension (the original bytes),
    /// then picture data (saved as PNG).
    static func read(_ pb: NSPasteboard) -> WebDrop? {
        let links = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        if let link = links.first(where: { !Converter.targets(forExt: Converter.ext($0)).isEmpty }) {
            return WebDrop(url: link, imageData: nil, ext: Converter.ext(link), name: safeName(link.deletingPathExtension().lastPathComponent))
        }
        if let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let png = NSBitmapImageRep(data: raw)?.representation(using: .png, properties: [:]) {
            let name = links.first.map { safeName($0.deletingPathExtension().lastPathComponent) } ?? ""
            return WebDrop(url: nil, imageData: png, ext: "png", name: name.isEmpty ? "Dragged image" : name)
        }
        return nil
    }

    /// File names come from the web: no path separators, no hidden-file dot, not empty.
    static func safeName(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        let cleaned = decoded.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return String(cleaned.prefix(120)).isEmpty ? "Download" : String(cleaned.prefix(120))
    }

    /// Saves into Downloads (or `dir`) and returns the local file. Runs on the conversion's background thread.
    func save(into dir: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) throws -> URL {
        let dest = Converter.uniqueURL(in: dir, base: name, ext: ext)
        if let data = imageData {
            try data.write(to: dest, options: .withoutOverwriting)
            return dest
        }
        guard let url else { throw ConvertError("Nothing to save") }
        let job = Job.current
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: url) { file, response, error in
            defer { done.signal() }
            do {
                if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                    throw ConvertError("The website answered with error \(status)")
                }
                guard let file else { throw error ?? ConvertError("The download failed") }
                try FileManager.default.moveItem(at: file, to: dest) // before returning: the temp file is then deleted
            } catch { failure = error }
        }
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in job?.report(progress.fractionCompleted) }
        task.resume()
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if job?.isCancelled == true { task.cancel() }
        }
        observation.invalidate()
        if job?.isCancelled == true { throw ConvertError("Cancelled") }
        if let failure { throw failure }
        return dest
    }
}
