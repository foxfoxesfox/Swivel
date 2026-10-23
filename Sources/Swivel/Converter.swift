import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The conversion engine. No UI here: the app and the `--convert` CLI both call `convertAll`.
/// A "target" is an output extension ("jpg", "mp3"…) or an action ("split", "merge").
enum Converter {
    /// Camera RAW files: read by macOS itself; saved as JPG when a tool keeps "the same format".
    static let rawIn: Set = ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"]
    static let imageIn = Set(["jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif"]).union(rawIn)
    static let audioIn: Set = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac"]
    static let videoIn: Set = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "m4v", "3gp", "ts"]
    static let docIn: Set = ["docx", "doc", "rtf", "odt", "html", "txt", "md", "epub"]
    /// Videos macOS can play and cut losslessly (Trim).
    static let trimIn: Set = ["mp4", "mov", "m4v"]
    static let archiveIn: Set = ["zip", "tar", "gz", "tgz", "bz2", "xz"]
    static let subtitleIn: Set = ["srt", "vtt", "ass"]
    /// Everything that needs ffmpeg to convert at all.
    static var needsFFmpeg: Set<String> { audioIn.union(videoIn).union(subtitleIn) }

    /// ffmpeg encoder used for each audio output (also video -> mp3).
    static let audioCodec = ["mp3": "libmp3lame", "m4a": "aac", "wav": "pcm_s16le", "flac": "flac",
                             "ogg": "libvorbis", "opus": "libopus", "aiff": "pcm_s16be"]
    static let audioQuality = ["mp3": ["-q:a", "2"], "m4a": ["-b:a", "256k"], "ogg": ["-q:a", "5"], "opus": ["-b:a", "160k"]]

    /// Where Swivel keeps the ffmpeg it downloads itself (FFmpegSetup).
    static let ownFFmpegDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Swivel/bin")

    // GUI apps don't get the shell PATH: look where Homebrew installs, then Swivel's own copy.
    static let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", ownFFmpegDir.appendingPathComponent("ffmpeg").path]
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
        return ["jpeg": "jpg", "tif": "tiff", "heif": "heic", "aif": "aiff", "htm": "html", "mpeg": "mpg", "mts": "ts", "markdown": "md"][e] ?? e
    }

    static func label(_ target: String) -> String {
        if target.hasPrefix("compress-") { return "Compress" }
        if target.hasPrefix("send-") { return "Send-ready" }
        if target == "strip" { return "Remove location" }
        if target.hasPrefix("crop-") { return "Crop" }
        if target.hasPrefix("trim-") { return "Trim" }
        if target == "combine" { return "One PDF" }
        if isTool(target) { return "Resize" }
        return ["split", "merge", "extract"].contains(target) ? target.capitalized : target.uppercased()
    }

    // MARK: - Compress / resize (actions wheel)

    /// Tool targets: "compress-high|balanced|small", "scale-<percent>", "fit-<longest side px>".
    static func isTool(_ target: String) -> Bool {
        target.hasPrefix("compress-") || target.hasPrefix("scale-") || target.hasPrefix("fit-") || target.hasPrefix("send-") || target == "strip"
            || target.hasPrefix("crop-") || target.hasPrefix("trim-")
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
        let outExt = rawIn.contains(e) ? "jpg" : e
        let out = output(for: src, suffix: " resized", ext: outExt)
        try save(resized, to: out, ext: outExt)
        return out
    }

    /// A copy without GPS location. Photos: a lossless copy where macOS can, otherwise re-encoded (which drops all metadata).
    /// Videos: streams copied as-is, metadata dropped.
    static func stripLocation(_ src: URL) throws -> URL {
        let e = ext(src)
        if videoIn.contains(e) {
            let out = output(for: src, suffix: " no location", ext: e)
            try ffmpeg(["-i", src.path, "-map", "0:v", "-map", "0:a?", "-c", "copy", "-map_metadata", "-1"], out)
            return out
        }
        let outExt = rawIn.contains(e) ? "jpg" : e
        let out = output(for: src, suffix: " no location", ext: outExt)
        if !rawIn.contains(e), let source = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(source),
           let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil),
           CGImageDestinationCopyImageSource(dest, source, [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, nil) {
            return out
        }
        try? FileManager.default.removeItem(at: out)
        try save(try loadImage(src), to: out, ext: outExt)
        return out
    }

    /// Preview's "Reduce File Size" filter; kept only if it actually got smaller.
    static func compressPDF(_ src: URL) throws -> URL {
        guard let doc = PDFDocument(url: src), !doc.isLocked else { throw ConvertError("Can't open this PDF (password-protected?)") }
        guard let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) else {
            throw ConvertError("This Mac's Reduce File Size filter is missing")
        }
        let out = output(for: src, suffix: " compressed", ext: "pdf")
        guard doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            throw ConvertError("Failed to write the compressed PDF")
        }
        return try keepIfSmaller(out, than: src)
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
            list = ["jpg", "png", "heic", "tiff", "bmp", "gif", "pdf", "ico", "icns"]
            if has("libwebp") { list.append("webp") }
            if has("libaom-av1") || has("libsvtav1") { list.append("avif") }
        } else if docIn.contains(e) {
            list = ["pdf", "docx", "rtf", "html", "txt", "odt"]
        } else if archiveIn.contains(e) {
            list = ["extract"]
        } else if subtitleIn.contains(e) {
            list = ["srt", "vtt", "ass"].filter { has(["srt": "srt", "vtt": "webvtt", "ass": "ass"][$0]!) }
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
        if urls.count > 1 && urls.allSatisfy({ imageIn.contains(ext($0)) }) { result.append("combine") }
        return result
    }

    // MARK: - Convert

    static func convertAll(_ urls: [URL], to target: String, job: Job? = nil) -> (outputs: [URL], errors: [String]) {
        Job.current = job
        defer { Job.current = nil }
        // These make one file out of all the dragged ones.
        if let together = ["merge": merge, "combine": combineImages, "zip": zip][target] {
            do { return ([try together(urls)], []) } catch { return ([], [error.localizedDescription]) }
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
        if target.hasPrefix("compress-") && e == "pdf" { return try compressPDF(src) }
        if target.hasPrefix("crop-") {
            guard imageIn.contains(e) else { throw ConvertError("Crop works on photos") }
            return try crop(src, target)
        }
        if target.hasPrefix("trim-") {
            guard trimIn.contains(e) else { throw ConvertError("Trim works on MP4, MOV and M4V videos") }
            return try trim(src, target)
        }
        if isTool(target) {
            guard canUseTools(src) else { throw ConvertError("Compress and Resize work on photos and videos") }
            if target == "strip" { return try stripLocation(src) }
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
        if docIn.contains(e) { return try convertDocument(src, to: target) }
        if archiveIn.contains(e) { return try extract(src) }
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
        case "ico":
            // Icons are square: fit the picture on a transparent square (ICO tops out at 256 px).
            try write(try squared(image, side: 256), to: out, ext: "ico")
        case "icns":
            // ImageIO can't write ICNS, so build the standard iconset (16–1024 px) and pack it like Apple's tools do.
            let set = tempURL("iconset")
            defer { try? FileManager.default.removeItem(at: set) }
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            for size in [16, 32, 128, 256, 512] {
                try write(try squared(image, side: size), to: set.appendingPathComponent("icon_\(size)x\(size).png"), ext: "png")
                try write(try squared(image, side: size * 2), to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"), ext: "png")
            }
            try run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", out.path])
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
    static func squared(_ image: CGImage, side: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError("Couldn't make the icon") }
        let s = Double(side) / Double(max(image.width, image.height))
        let w = Double(image.width) * s, h = Double(image.height) * s
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return ctx.makeImage()!
    }

    // MARK: - Documents, archives

    /// Word, RTF, ODT, HTML and text via macOS's own converter (textutil); PDF by laying the text out on pages.
    static func convertDocument(_ src: URL, to target: String) throws -> URL {
        let out = output(for: src, ext: target)
        let (input, cleanup) = try documentInput(src) // Markdown and EPUB become HTML first
        defer { cleanup() }
        do {
            if target == "pdf" { try documentToPDF(input, out) }
            else { try run("/usr/bin/textutil", ["-convert", target, "-output", out.path, input.path]) }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        guard FileManager.default.fileExists(atPath: out.path) else { throw ConvertError("Couldn't convert this document") }
        return out
    }

    /// The file the document converters read: the source itself, or an HTML version of Markdown/EPUB.
    static func documentInput(_ src: URL) throws -> (URL, () -> Void) {
        switch ext(src) {
        case "md":
            let dir = tempURL("md")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let text = try (try? String(contentsOf: src, encoding: .utf8)) ?? String(contentsOf: src, encoding: .isoLatin1)
            let html = dir.appendingPathComponent(baseName(src) + ".html")
            try markdownToHTML(text).write(to: html, atomically: true, encoding: .utf8)
            return (html, { try? FileManager.default.removeItem(at: dir) })
        case "epub":
            let book = try epubToHTML(src)
            return (book.html, { try? FileManager.default.removeItem(at: book.dir) })
        default:
            return (src, {})
        }
    }

    /// A small Markdown → HTML converter: headings, paragraphs, lists, quotes, code, rules, bold, italic, links.
    static func markdownToHTML(_ markdown: String) -> String {
        func escape<S: StringProtocol>(_ s: S) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func inline<S: StringProtocol>(_ s: S) -> String {
            var t = escape(s)
            for (pattern, template) in [
                (#"`([^`]+)`"#, "<code>$1</code>"),
                (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">"),
                (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
                (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
                (#"__([^_]+)__"#, "<b>$1</b>"),
                (#"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, "<i>$1</i>"),
                (#"(?<![_\w])_([^_\n]+)_(?![_\w])"#, "<i>$1</i>"),
            ] { t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
            return t
        }
        var html = [#"<html><head><meta charset="utf-8"><style>body{font-family:-apple-system,Helvetica;font-size:12pt;line-height:1.4}code,pre{font-family:Menlo,monospace;font-size:10.5pt}pre{background:#f4f4f4;padding:8px}blockquote{color:#555;border-left:3px solid #ccc;padding-left:10px}</style></head><body>"#]
        var paragraph: [String] = [], list: String?, code: [Substring]?
        func flushParagraph() { if !paragraph.isEmpty { html.append("<p>" + paragraph.joined(separator: " ") + "</p>"); paragraph = [] } }
        func closeList() { if let l = list { html.append("</\(l)>"); list = nil } }
        func openList(_ kind: String) { flushParagraph(); if list != kind { closeList(); html.append("<\(kind)>"); list = kind } }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if let lines = code { html.append("<pre><code>" + lines.map(escape).joined(separator: "\n") + "</code></pre>"); code = nil }
                else { flushParagraph(); closeList(); code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            if t.isEmpty { flushParagraph(); closeList(); continue }
            if let m = t.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushParagraph(); closeList()
                let level = t[m].count - 1
                html.append("<h\(level)>\(inline(t[m.upperBound...]))</h\(level)>")
            } else if t.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph(); closeList(); html.append("<hr>")
            } else if let m = t.range(of: #"^[-*+] "#, options: .regularExpression) {
                openList("ul"); html.append("<li>\(inline(t[m.upperBound...]))</li>")
            } else if let m = t.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                openList("ol"); html.append("<li>\(inline(t[m.upperBound...]))</li>")
            } else if t.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>\(inline(t.dropFirst().drop(while: { $0 == " " })))</blockquote>")
            } else {
                closeList(); paragraph.append(inline(t))
            }
        }
        if let lines = code { html.append("<pre><code>" + lines.map(escape).joined(separator: "\n") + "</code></pre>") }
        flushParagraph(); closeList()
        return html.joined(separator: "\n") + "</body></html>"
    }

    /// An EPUB's chapters, in reading (spine) order, joined into one HTML file next to the first chapter
    /// so relative image paths still resolve. `dir` is the unpacked book, to delete afterwards.
    static func epubToHTML(_ src: URL) throws -> (html: URL, dir: URL) {
        let dir = tempURL("epub")
        try run("/usr/bin/ditto", ["-x", "-k", src.path, dir.path])
        func read(_ url: URL) throws -> String {
            try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
        }
        func firstMatch(_ pattern: String, in text: String) -> String? {
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            return String(text[r])
        }
        func attribute(_ name: String, in tag: String) -> String? {
            firstMatch(#"\b\#(name)\s*=\s*"[^"]*""#, in: tag).flatMap { $0.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init) }
        }
        do {
            let container = try read(dir.appendingPathComponent("META-INF/container.xml"))
            guard let opfPath = firstMatch(#"<rootfile\b[^>]*>"#, in: container).flatMap({ attribute("full-path", in: $0) }) else {
                throw ConvertError("This EPUB has no table of contents file")
            }
            let opf = dir.appendingPathComponent(opfPath)
            let opfText = try read(opf)
            var manifest: [String: String] = [:]
            for match in opfText.matches(#"<item\b[^>]*>"#) {
                if let id = attribute("id", in: match), let href = attribute("href", in: match) { manifest[id] = href }
            }
            let chapters = opfText.matches(#"<itemref\b[^>]*>"#).compactMap { attribute("idref", in: $0) }
                .compactMap { manifest[$0] }
                .map { opf.deletingLastPathComponent().appendingPathComponent($0.removingPercentEncoding ?? $0) }
            var bodies: [String] = []
            for chapter in chapters {
                let text = try read(chapter)
                bodies.append(firstMatch(#"(?s)<body[^>]*>.*</body>"#, in: text) ?? text)
            }
            guard let first = chapters.first, !bodies.isEmpty else { throw ConvertError("No chapters found in this EPUB") }
            let html = first.deletingLastPathComponent().appendingPathComponent("swivel-book.html")
            try (#"<html><head><meta charset="utf-8"></head>"# + bodies.joined(separator: "<hr>") + "</html>")
                .write(to: html, atomically: true, encoding: .utf8)
            return (html, dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    // MARK: - Crop, trim

    /// "crop-X-Y-W-H": a rectangle in pixels from the top-left of the (upright) photo.
    static func crop(_ src: URL, _ target: String) throws -> URL {
        let n = target.split(separator: "-").dropFirst().compactMap { Int($0) }
        let image = try loadImage(src)
        guard n.count == 4, n[2] > 0, n[3] > 0 else { throw ConvertError("That crop area isn't valid") }
        let rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            throw ConvertError("That crop area is outside the photo")
        }
        let e = ext(src), outExt = rawIn.contains(e) ? "jpg" : e
        let out = output(for: src, suffix: " cropped", ext: outExt)
        try save(cropped, to: out, ext: outExt)
        return out
    }

    /// "trim-START-END" in seconds. Lossless and fast: macOS copies the streams and marks the exact start.
    static func trim(_ src: URL, _ target: String) throws -> URL {
        let n = target.split(separator: "-").dropFirst().compactMap { Double($0) }
        guard n.count == 2, n[0] >= 0, n[1] > n[0] else { throw ConvertError("That trim range isn't valid") }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough) else {
            throw ConvertError("This video can't be trimmed")
        }
        let e = ext(src)
        let out = output(for: src, suffix: " trimmed", ext: e)
        export.outputURL = out
        export.outputFileType = e == "mp4" ? .mp4 : e == "m4v" ? .m4v : .mov
        export.timeRange = CMTimeRange(start: CMTime(seconds: n[0], preferredTimescale: 600),
                                       end: CMTime(seconds: n[1], preferredTimescale: 600))
        export.shouldOptimizeForNetworkUse = true
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            Job.current?.report(Double(export.progress))
            if Job.current?.isCancelled == true { export.cancelExport() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError(export.status == .cancelled ? "Cancelled" : export.error?.localizedDescription ?? "Trim failed")
        }
        return out
    }

    /// Lays the document's text out on pages (system paper size, 0.75" margins) and draws them into a PDF.
    /// Runs on the main thread: HTML import uses WebKit, which requires it.
    static func documentToPDF(_ src: URL, _ out: URL) throws {
        func render() throws {
            let storage = NSTextStorage(attributedString: try NSAttributedString(url: src, options: [:], documentAttributes: nil))
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            var paper = NSPrintInfo.shared.paperSize
            if paper.width < 100 || paper.height < 100 { paper = NSSize(width: 612, height: 792) }
            let margin: CGFloat = 54
            let textSize = NSSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)
            var pages: [NSTextContainer] = []
            repeat { // one text container per page until all text is placed
                let page = NSTextContainer(size: textSize)
                layout.addTextContainer(page)
                pages.append(page)
                if layout.glyphRange(for: page).length == 0 && pages.count > 1 { break } // nothing fits: stop, don't loop
            } while NSMaxRange(layout.glyphRange(for: pages.last!)) < layout.numberOfGlyphs && pages.count < 2000

            var box = CGRect(origin: .zero, size: paper)
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConvertError("Can't create PDF") }
            for page in pages {
                ctx.beginPDFPage(nil)
                ctx.translateBy(x: 0, y: paper.height) // text draws top-down
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                let range = layout.glyphRange(for: page)
                layout.drawBackground(forGlyphRange: range, at: NSPoint(x: margin, y: margin))
                layout.drawGlyphs(forGlyphRange: range, at: NSPoint(x: margin, y: margin))
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
        if Thread.isMainThread { return try render() }
        var failure: Error?
        DispatchQueue.main.sync { do { try render() } catch { failure = error } }
        if let failure { throw failure }
    }

    /// Unpacks ZIP (ditto) or tar/gz/bz2/xz (tar) into a new folder named after the archive.
    static func extract(_ src: URL) throws -> URL {
        var base = baseName(src)
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let dir = uniqueURL(in: src.deletingLastPathComponent(), base: base, ext: nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        do {
            if ext(src) == "zip" { try run("/usr/bin/ditto", ["-x", "-k", src.path, dir.path]) }
            else { try run("/usr/bin/tar", ["-xf", src.path, "-C", dir.path]) } // bsdtar refuses absolute and ../ paths
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }

    /// One ZIP of everything dragged: "<name>.zip" for one item, "Archive.zip" for several (like Finder).
    static func zip(_ urls: [URL]) throws -> URL {
        let parent = urls[0].deletingLastPathComponent().standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
            throw ConvertError("Pick files from one folder to zip them together")
        }
        let out = uniqueURL(in: parent, base: urls.count == 1 ? urls[0].lastPathComponent : "Archive", ext: "zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = parent // relative names, so the archive holds just the items
        process.arguments = ["-r", "-y", "-q", out.path] + urls.map(\.lastPathComponent) + ["-x", "*.DS_Store", "__MACOSX/*"]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).ifEmpty("zip failed"))
        }
        return out
    }

    /// Several photos as one PDF, a page each, in name order. Pages are at most A4-sized; pictures keep full resolution.
    static func combineImages(_ urls: [URL]) throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let out = uniqueURL(in: sorted[0].deletingLastPathComponent(), base: baseName(sorted[0]) + " combined", ext: "pdf")
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw ConvertError("Can't create PDF") }
        do {
            for (i, url) in sorted.enumerated() {
                Job.current?.report(Double(i) / Double(sorted.count))
                let image = try loadImage(url)
                let s = min(1, 842 / Double(max(image.width, image.height)))
                var box = CGRect(x: 0, y: 0, width: Double(image.width) * s, height: Double(image.height) * s)
                let page = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
                ctx.beginPDFPage(page as CFDictionary)
                ctx.draw(image, in: box)
                ctx.endPDFPage()
            }
            ctx.closePDF()
        } catch {
            ctx.closePDF()
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

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
        if subtitleIn.contains(target) {
            // Subtitles: ffmpeg converts between SRT, WebVTT and ASS by extension.
        } else if let codec = audioCodec[target] {
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

private extension String {
    func ifEmpty(_ fallback: String) -> String { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self }

    /// Every match of a regular expression, in order.
    func matches(_ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { Range($0.range, in: self).map { String(self[$0]) } }
    }
}
