import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The conversion engine. No UI here: the app and the `--convert` CLI both call `convertAll`.
/// A "target" is an output extension ("jpg", "mp3"…) or an action ("split", "merge").
enum Converter {
    static let imageIn: Set = ["jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif"]
    static let audioIn: Set = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"]
    static let videoIn: Set = ["mp4", "mov", "mkv", "webm"]

    /// ffmpeg encoder used for each audio output (also video -> mp3).
    static let audioCodec = ["mp3": "libmp3lame", "m4a": "aac", "wav": "pcm_s16le", "flac": "flac",
                             "ogg": "libvorbis", "opus": "libopus", "aiff": "pcm_s16be"]
    static let audioQuality = ["mp3": ["-q:a", "2"], "m4a": ["-b:a", "256k"], "ogg": ["-q:a", "5"], "opus": ["-b:a", "160k"]]

    // GUI apps don't get the shell PATH, so look where Homebrew installs.
    static let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static let encoders: Set<String> = {
        guard let ff = ffmpegPath, let out = try? run(ff, ["-hide_banner", "-encoders"]) else { return [] }
        // Lines look like " V....D libx264   libx264 H.264 ..."
        return Set(out.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ")
            return cols.count >= 2 && cols[0].count == 6 ? String(cols[1]) : nil
        })
    }()

    static var h264: String? {
        encoders.contains("libx264") ? "libx264" : encoders.contains("h264_videotoolbox") ? "h264_videotoolbox" : nil
    }

    static func ext(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return ["jpeg": "jpg", "tif": "tiff", "heif": "heic", "aif": "aiff"][e] ?? e
    }

    static func label(_ target: String) -> String {
        if target.hasPrefix("compress-") { return "Compress" }
        if target.hasPrefix("send-") { return "Send-ready" }
        if isTool(target) { return "Resize" }
        return target == "split" || target == "merge" ? target.capitalized : target.uppercased()
    }

    // MARK: - Compress / resize (actions wheel)

    /// Tool targets: "compress-high|balanced|small", "scale-<percent>", "fit-<longest side px>".
    static func isTool(_ target: String) -> Bool {
        target.hasPrefix("compress-") || target.hasPrefix("scale-") || target.hasPrefix("fit-") || target.hasPrefix("send-")
    }

    /// Lossy image quality (0–1) and H.264 CRF for each compress level.
    static let compressLevels: [String: (quality: Double, crf: Int)] = [
        "compress-high": (0.8, 23), "compress-balanced": (0.6, 28), "compress-small": (0.4, 32),
    ]

    /// Photos always; videos only when ffmpeg can encode H.264.
    static func canUseTools(_ url: URL) -> Bool {
        imageIn.contains(ext(url)) || (videoIn.contains(ext(url)) && h264 != nil)
    }

    static func imageTool(_ src: URL, _ target: String) throws -> URL {
        let image = try loadImage(src)
        let e = ext(src)
        if let level = compressLevels[target] {
            // Lossless formats only shrink much as JPG.
            let outExt = ["jpg", "heic", "webp", "avif"].contains(e) ? e : "jpg"
            let out = output(for: src, suffix: " compressed", ext: outExt)
            try save(image, to: out, ext: outExt, quality: level.quality)
            return try keepIfSmaller(out, than: src)
        }
        let resized = try scaled(image, by: try scale(for: target, longest: max(image.width, image.height)))
        let out = output(for: src, suffix: " resized", ext: e)
        try save(resized, to: out, ext: e)
        return out
    }

    static func scaled(_ image: CGImage, by s: Double) throws -> CGImage {
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError("Image too large") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    // MARK: - Send-ready: fit under a size limit (Discord, WhatsApp, email)

    /// Limit in bytes for "under N MB", with a little headroom for how apps count MB.
    static func sendLimit(_ mb: Int) -> Int { Int(Double(mb) * 1_000_000 * 0.96) }

    /// JPG under the limit: lowers quality, then size, until it fits. Writing a fresh JPG drops location and other metadata.
    static func sendImage(_ src: URL, mb: Int) throws -> URL {
        var image = try flattened(try loadImage(src))
        let limit = sendLimit(mb)
        for _ in 0..<10 {
            for quality in [0.85, 0.7, 0.55] {
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { break }
                if data.length <= limit {
                    let out = output(for: src, suffix: " (under \(mb) MB)", ext: "jpg")
                    try (data as Data).write(to: out, options: .withoutOverwriting)
                    return out
                }
            }
            image = try scaled(image, by: 0.75)
        }
        throw ConvertError("Couldn't get this image under \(mb) MB")
    }

    /// MP4 under the limit: picks a bitrate from the length, lowers resolution when the bitrate is low,
    /// encodes in two passes for an accurate size, and drops location metadata.
    static func sendVideo(_ src: URL, mb: Int) throws -> URL {
        guard ffmpegPath != nil, let seconds = duration(src.path), seconds > 0 else {
            throw ConvertError("Couldn't read how long this video is")
        }
        let limit = sendLimit(mb)
        let budget = Double(limit) * 8 / 1000 / seconds // kbit/s for everything
        let audio = budget > 1000 ? 128.0 : 64.0
        var video = budget * 0.97 - audio
        guard video >= 100 else {
            throw ConvertError("Too long to fit under \(mb) MB (\(Int(seconds / 60)) min). Try trimming it first.")
        }
        let out = output(for: src, suffix: " (under \(mb) MB)", ext: "mp4")
        for attempt in 0..<2 { // a second, leaner try if the first lands just over
            let longest = video < 600 ? 854 : video < 1800 ? 1280 : 1920
            let filter = "scale=w='if(gte(iw,ih),trunc(min(iw,\(longest))/2)*2,-2)':h='if(gte(iw,ih),-2,trunc(min(ih,\(longest))/2)*2)'"
            let rate = ["-b:v", "\(Int(video))k"]
            let common = ["-i", src.path, "-map", "0:v:0", "-vf", filter, "-pix_fmt", "yuv420p"]
            let finish = ["-map", "0:a:0?", "-map_metadata", "-1", "-c:a", "aac", "-b:a", "\(Int(audio))k", "-movflags", "+faststart"]
            if h264 == "libx264" {
                let log = tempURL("pass").deletingPathExtension().path
                defer { ["-0.log", "-0.log.mbtree"].forEach { try? FileManager.default.removeItem(atPath: log + $0) } }
                try ffmpegPass(common + ["-c:v", "libx264", "-preset", "medium"] + rate + ["-pass", "1", "-passlogfile", log, "-an", "-f", "null"],
                               span: 0...0.5)
                try ffmpeg(common + ["-c:v", "libx264", "-preset", "medium"] + rate + ["-pass", "2", "-passlogfile", log] + finish,
                           out, span: 0.5...1)
            } else {
                try ffmpeg(common + ["-c:v", "h264_videotoolbox"] + rate + ["-maxrate", "\(Int(video * 1.2))k"] + finish, out)
            }
            let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= limit { return out }
            try? FileManager.default.removeItem(at: out)
            if attempt == 0 { video *= 0.85 }
        }
        throw ConvertError("Couldn't get this video under \(mb) MB")
    }

    static func videoTool(_ src: URL, _ target: String) throws -> URL {
        let e = ext(src)
        var filter = "scale=trunc(iw/2)*2:trunc(ih/2)*2", crf = 20
        if let level = compressLevels[target] {
            crf = level.crf
        } else if target.hasPrefix("scale-") {
            let p = try scale(for: target, longest: Int.max)
            filter = "scale=trunc(iw*\(p)/2)*2:-2"
        } else {
            let n = Int(target.dropFirst(4)) ?? 1280 // fit-<n>: longest side, never enlarged, even sizes for H.264
            filter = "scale=w='if(gte(iw,ih),trunc(min(iw,\(n))/2)*2,-2)':h='if(gte(iw,ih),-2,trunc(min(ih,\(n))/2)*2)'"
        }
        let out = output(for: src, suffix: compressLevels[target] == nil ? " resized" : " compressed", ext: e)
        try ffmpeg(["-i", src.path] + videoArgs(e, filter: filter, crf: crf), out)
        return compressLevels[target] == nil ? out : try keepIfSmaller(out, than: src)
    }

    /// Scale factor for "scale-50" (50%) or "fit-1280" (longest side 1280px).
    static func scale(for target: String, longest: Int) throws -> Double {
        let n = Double(target.split(separator: "-").last.flatMap { Int($0) } ?? 100)
        if target.hasPrefix("scale-") { return n / 100 }
        guard Double(longest) > n else { throw ConvertError("Already \(Int(n)) px or smaller, so it wasn't resized") }
        return n / Double(longest)
    }

    /// Deletes `out` if compressing didn't make it smaller.
    static func keepIfSmaller(_ out: URL, than src: URL) throws -> URL {
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard size(out) < size(src) else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError("Already well compressed, so no smaller copy was made")
        }
        return out
    }

    // MARK: - What can this become?

    static func targets(forExt e: String) -> [String] {
        let has = encoders.contains
        var list: [String] = []
        if imageIn.contains(e) {
            list = ["jpg", "png", "heic", "tiff", "bmp", "gif", "pdf"]
            if has("libwebp") { list.append("webp") }
            if has("libaom-av1") || has("libsvtav1") { list.append("avif") }
        } else if audioIn.contains(e) {
            list = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"].filter { has(audioCodec[$0]!) }
        } else if videoIn.contains(e) {
            if h264 != nil && has("aac") { list += ["mp4", "mov", "mkv"] }
            if has("libvpx-vp9") && has("libopus") { list.append("webm") }
            if has("gif") { list.append("gif") }
            if has("libmp3lame") { list.append("mp3") }
        } else if e == "pdf" {
            list = ["png", "jpg", "txt", "split"]
        }
        return list.filter { $0 != e }
    }

    /// Targets valid for every dragged file, plus Merge for 2+ PDFs.
    static func targets(for urls: [URL]) -> [String] {
        guard let first = urls.first else { return [] }
        var result = targets(forExt: ext(first))
        for url in urls.dropFirst() {
            let other = Set(targets(forExt: ext(url)))
            result = result.filter(other.contains)
        }
        if urls.count > 1 && urls.allSatisfy({ ext($0) == "pdf" }) { result.append("merge") }
        return result
    }

    // MARK: - Convert

    static func convertAll(_ urls: [URL], to target: String, job: Job? = nil) -> (outputs: [URL], errors: [String]) {
        Job.current = job
        defer { Job.current = nil }
        if target == "merge" {
            do { return ([try merge(urls)], []) } catch { return ([], [error.localizedDescription]) }
        }
        var outputs: [URL] = [], errors: [String] = []
        for (i, url) in urls.enumerated() {
            if job?.isCancelled == true { errors.append("Cancelled"); break }
            job?.startFile(i, of: urls.count)
            do { outputs.append(try convert(url, to: target)) }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (outputs, errors)
    }

    /// Writes a new file (or folder) next to `src`. Never touches `src`.
    static func convert(_ src: URL, to target: String) throws -> URL {
        let e = ext(src)
        if isTool(target) {
            guard canUseTools(src) else { throw ConvertError("Compress and Resize work on photos and videos") }
            if let mb = Int(target.dropFirst(5)), target.hasPrefix("send-") {
                return imageIn.contains(e) ? try sendImage(src, mb: mb) : try sendVideo(src, mb: mb)
            }
            return imageIn.contains(e) ? try imageTool(src, target) : try videoTool(src, target)
        }
        guard targets(forExt: e).contains(target) else {
            throw ConvertError("Can't convert .\(e) to \(label(target))")
        }
        if e == "pdf" { return try convertPDF(src, to: target) }
        if imageIn.contains(e) { return try convertImage(src, to: target) }
        return try convertMedia(src, to: target)
    }

    // MARK: - Naming

    /// "photo.jpg", then "photo 2.jpg", "photo 3.jpg"… `ext == nil` means a folder.
    static func uniqueURL(in dir: URL, base: String, ext: String?) -> URL {
        for n in 1... {
            let name = n == 1 ? base : "\(base) \(n)"
            let url = ext.map { dir.appendingPathComponent(name).appendingPathExtension($0) }
                ?? dir.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        fatalError("unreachable")
    }

    static func baseName(_ src: URL) -> String { src.deletingPathExtension().lastPathComponent }

    static func output(for src: URL, suffix: String = "", ext: String) -> URL {
        uniqueURL(in: src.deletingLastPathComponent(), base: baseName(src) + suffix, ext: ext)
    }

    /// Creates "<name> pages" next to `src` and fills it; removes it again if `fill` throws.
    static func pagesFolder(for src: URL, fill: (URL) throws -> Void) throws -> URL {
        let dir = uniqueURL(in: src.deletingLastPathComponent(), base: baseName(src) + " pages", ext: nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        do { try fill(dir) } catch { try? FileManager.default.removeItem(at: dir); throw error }
        return dir
    }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swivel-\(UUID().uuidString).\(ext)")
    }

    // MARK: - Images

    static func convertImage(_ src: URL, to target: String) throws -> URL {
        let out = output(for: src, ext: target)
        try save(try loadImage(src), to: out, ext: target)
        return out
    }

    /// Writes `image` in any image output format; `quality` applies to lossy formats.
    static func save(_ image: CGImage, to out: URL, ext target: String, quality: Double = 0.9) throws {
        switch target {
        case "pdf":
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConvertError("Can't create PDF") }
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            ctx.closePDF()
        case "jpg":
            try write(try flattened(image), to: out, ext: "jpg", quality: quality)
        case "webp", "avif":
            // Go through a temp PNG so anything ImageIO reads (HEIC etc.) works as ffmpeg input.
            let png = tempURL("png")
            defer { try? FileManager.default.removeItem(at: png) }
            // shortcut: AVIF is flattened onto white; ffmpeg's AV1 encoders need a second stream for alpha.
            try write(target == "avif" ? try flattened(image) : image, to: png, ext: "png")
            let codec: [String]
            let crf = String(Int((1 - quality) * 50 + 18)) // quality 0.9 → 23, 0.4 → 48
            if target == "webp" {
                codec = ["-c:v", "libwebp", "-quality", String(Int(quality * 100))]
            } else if encoders.contains("libaom-av1") {
                codec = ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", crf, "-cpu-used", "6", "-pix_fmt", "yuv420p"]
            } else {
                codec = ["-c:v", "libsvtav1", "-crf", crf, "-pix_fmt", "yuv420p"]
            }
            try ffmpeg(["-i", png.path] + codec, out)
        default:
            try write(image, to: out, ext: target, quality: quality)
        }
    }

    static func loadImage(_ src: URL) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(src as CFURL, nil), let image = orientedImage(source) {
            return image
        }
        // ImageIO couldn't decode it (some WebP/AVIF variants): let ffmpeg make a PNG first.
        guard let ff = ffmpegPath else { throw ConvertError("Can't read this image") }
        let png = tempURL("png")
        defer { try? FileManager.default.removeItem(at: png) }
        try run(ff, ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", src.path, "-frames:v", "1", png.path])
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = orientedImage(source) else {
            throw ConvertError("Can't read this image")
        }
        return image
    }

    /// First frame with EXIF orientation baked in (a full-size "thumbnail" applies the transform).
    static func orientedImage(_ source: CGImageSource) -> CGImage? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Draws onto white, dropping alpha (for JPG).
    static func flattened(_ image: CGImage) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConvertError("Image too large") }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, ext: String, quality: Double = 0.9, extra: [CFString: Any] = [:]) throws {
        guard let type = UTType(filenameExtension: ext)?.identifier,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)
        else { throw ConvertError("This Mac can't write \(label(ext))") }
        var props = extra
        if ext == "jpg" || ext == "heic" { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw ConvertError("Failed to write \(label(ext))")
        }
    }

    // MARK: - PDF

    static func convertPDF(_ src: URL, to target: String) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ConvertError("Can't open PDF") }
        guard !doc.isLocked else { throw ConvertError("PDF is password-protected") }
        let base = baseName(src)
        switch target {
        case "txt":
            let text = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw ConvertError("No text found (scanned PDF?)") }
            let out = output(for: src, ext: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        case "split":
            return try pagesFolder(for: src) { dir in
                for i in 0..<doc.pageCount {
                    let single = PDFDocument()
                    single.insert(doc.page(at: i)!.copy() as! PDFPage, at: 0)
                    guard single.write(to: dir.appendingPathComponent("\(base) page \(i + 1).pdf")) else {
                        throw ConvertError("Failed to write page \(i + 1)")
                    }
                }
            }
        default: // png, jpg
            guard let cg = CGPDFDocument(src as CFURL), cg.numberOfPages > 0 else { throw ConvertError("Can't open PDF") }
            if cg.numberOfPages == 1 {
                let out = output(for: src, ext: target)
                try render(cg.page(at: 1)!, to: out, ext: target)
                return out
            }
            return try pagesFolder(for: src) { dir in
                for i in 1...cg.numberOfPages {
                    try render(cg.page(at: i)!, to: dir.appendingPathComponent("\(base) page \(i).\(target)"), ext: target)
                }
            }
        }
    }

    /// Renders a page at 300 DPI on white, honouring the page's rotation.
    static func render(_ page: CGPDFPage, to url: URL, ext: String) throws {
        let dpi: CGFloat = 300, scale = dpi / 72
        let box = page.getBoxRect(.cropBox)
        let size = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConvertError("Page too large to render") }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // getDrawingTransform only scales down, so scale first and fit into the page's point size.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        try write(ctx.makeImage()!, to: url, ext: ext, extra: [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi])
    }

    /// Joins PDFs in Finder name order into "<first> merged.pdf".
    static func merge(_ urls: [URL]) throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let merged = PDFDocument()
        for url in sorted {
            guard let doc = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
            guard !doc.isLocked else { throw ConvertError("\(url.lastPathComponent) is password-protected") }
            for i in 0..<doc.pageCount { merged.insert(doc.page(at: i)!.copy() as! PDFPage, at: merged.pageCount) }
        }
        let out = uniqueURL(in: sorted[0].deletingLastPathComponent(), base: baseName(sorted[0]) + " merged", ext: "pdf")
        guard merged.write(to: out) else { throw ConvertError("Failed to write merged PDF") }
        return out
    }

    // MARK: - Audio / video (ffmpeg)

    static func convertMedia(_ src: URL, to target: String) throws -> URL {
        var args = ["-i", src.path]
        if let codec = audioCodec[target] {
            args += ["-map", "0:a:0", "-map_metadata", "0", "-c:a", codec] + (audioQuality[target] ?? [])
        } else if target == "gif" {
            // One filtergraph, two passes: build a palette from the clip, then map frames onto it.
            args += ["-an", "-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]
        } else { // mp4, mov, mkv, webm
            args += videoArgs(target, filter: "scale=trunc(iw/2)*2:trunc(ih/2)*2", crf: 20)
        }
        let out = output(for: src, ext: target)
        try ffmpeg(args, out)
        return out
    }

    /// Video + audio encoding for a container. `crf` is on the H.264 scale (lower = better); VP9 gets crf + 12.
    static func videoArgs(_ container: String, filter: String, crf: Int) -> [String] {
        var args = ["-map", "0:v:0", "-map", "0:a:0?", "-vf", filter]
        if container == "webm" {
            return args + ["-c:v", "libvpx-vp9", "-crf", String(crf + 12), "-b:v", "0", "-row-mt", "1",
                           "-c:a", "libopus", "-b:a", "128k"]
        }
        args += ["-pix_fmt", "yuv420p"]
        args += h264 == "libx264" ? ["-c:v", "libx264", "-crf", String(crf), "-preset", "medium"]
                                  : ["-c:v", "h264_videotoolbox", "-q:v", String(Int(100 - Double(crf) * 1.5))]
        args += ["-c:a", "aac", "-b:a", "192k"]
        if container != "mkv" { args += ["-movflags", "+faststart"] }
        return args
    }

    /// Runs ffmpeg writing to `out`; deletes a half-written `out` on failure.
    static func ffmpeg(_ args: [String], _ out: URL, span: ClosedRange<Double> = 0...1) throws {
        do {
            try ffmpegRun(args + [out.path], span: span)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// An ffmpeg run with no output file (two-pass encoding's first pass).
    static func ffmpegPass(_ args: [String], span: ClosedRange<Double>) throws {
        try ffmpegRun(args + ["-"], span: span)
    }

    private static func ffmpegRun(_ args: [String], span: ClosedRange<Double>) throws {
        guard let ff = ffmpegPath else { throw ConvertError("ffmpeg not found. Install it with: brew install ffmpeg") }
        var progress: ((Double) -> Void)?
        if let job = Job.current, let i = args.firstIndex(of: "-i"), i + 1 < args.count, let total = duration(args[i + 1]) {
            progress = { seconds in job.report(span.lowerBound + (span.upperBound - span.lowerBound) * seconds / total) }
        }
        let report = progress == nil ? [] : ["-progress", "pipe:1", "-nostats"]
        try run(ff, ["-nostdin", "-hide_banner", "-loglevel", "error", "-n"] + report + args, progress: progress)
    }

    /// Media length in seconds, via ffprobe (installed alongside ffmpeg).
    static func duration(_ path: String) -> Double? {
        guard let ff = ffmpegPath else { return nil }
        let probe = URL(fileURLWithPath: ff).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        guard FileManager.default.isExecutableFile(atPath: probe),
              let out = try? run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
        else { return nil }
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a tool, returns stdout+stderr; throws the last lines of output on a non-zero exit.
    /// With `progress`, ffmpeg's `-progress` lines are parsed (seconds encoded so far) and kept out of the error text.
    @discardableResult
    static func run(_ exe: String, _ args: [String], progress: ((Double) -> Void)? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe() // one pipe for both streams, so a chatty stderr can't deadlock us
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let job = progress == nil ? nil : Job.current // only long ffmpeg runs are cancellable
        try job?.attach(process)
        defer { try? job?.attach(nil) }
        try process.run()
        var text = "", pending = ""
        while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
            guard let progress else { text += String(decoding: chunk, as: UTF8.self); continue }
            pending += String(decoding: chunk, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) { progress(us / 1_000_000) }
                else if line.range(of: #"^[a-z0-9_]+="#, options: .regularExpression) == nil { text += line + "\n" }
            }
        }
        process.waitUntilExit()
        if job?.isCancelled == true { throw ConvertError("Cancelled") }
        guard process.terminationStatus == 0 else {
            let tail = text.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw ConvertError(tail.isEmpty ? "\(URL(fileURLWithPath: exe).lastPathComponent) exited with \(process.terminationStatus)" : tail)
        }
        return text
    }
}
