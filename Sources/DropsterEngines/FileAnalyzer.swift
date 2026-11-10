import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import DropsterCore

/// Inspects a file's content (never just its name) and produces a `FileReport`.
public struct FileAnalyzer: Sendable {
    let ffprobe: URL?

    public init(ffprobe: URL? = ToolLocator.find("ffprobe")) { self.ffprobe = ffprobe }

    public func analyze(_ url: URL) async -> FileReport {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let extFormat = FormatID.fromExtension(url.pathExtension)
        var detected = FileSignature.detect(url: url)
        // Office Open XML and OpenDocument files are ZIP containers; text formats have no magic.
        if detected == .zip, let e = extFormat, [.docx, .odt].contains(e) { detected = e }
        if detected == .html && extFormat == .svg { detected = .svg }
        var report = FileReport(url: url, byteSize: size, detectedFormat: detected, extensionFormat: extFormat)

        let imageCandidate = detected.map { $0.category == .image } ?? (extFormat?.category == .image)
        if imageCandidate || detected == nil, let (fmt, traits) = Self.imageTraits(url) {
            if let fmt { detected = fmt }
            report.image = traits
            report.detectedFormat = detected
        }
        if let d = report.detectedFormat, d.category == .video || d.category == .audio {
            if let media = await probe(url) {
                report.media = media
                // An MP4 container with only an audio track is really an M4A.
                if !media.hasVideo, d == .mp4 || d == .mov { report.detectedFormat = .m4a }
            }
        }
        if report.detectedFormat == .pdf, let doc = CGPDFDocument(url as CFURL) {
            report.pageCount = doc.numberOfPages
        }
        return report
    }

    static func format(forUTI uti: String) -> FormatID? {
        if uti.contains("raw-image") || uti == "com.adobe.raw-image" { return .raw }
        return switch uti {
        case "public.jpeg": .jpeg
        case "public.png": .png
        case "public.heic", "public.heif", "public.heics": .heic
        case "public.avif", "public.avis": .avif
        case "org.webmproject.webp": .webp
        case "public.tiff": .tiff
        case "com.compuserve.gif": .gif
        case "com.microsoft.bmp": .bmp
        case "public.jpeg-xl": .jxl
        case "public.jpeg-2000": .jp2
        case "com.adobe.photoshop-image": .psd
        case "com.microsoft.ico": .ico
        default: nil
        }
    }

    static func imageTraits(_ url: URL) -> (FormatID?, ImageTraits)? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let uti = CGImageSourceGetType(src) as String?
        var fmt = uti.flatMap(format(forUTI:))
        // DNG/NEF/ARW start with a TIFF header; trust the extension to tell them apart.
        if fmt == .tiff, FormatID.fromExtension(url.pathExtension) == .raw { fmt = .raw }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let traits = ImageTraits(
            width: w, height: h,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            bitsPerComponent: props[kCGImagePropertyDepth] as? Int ?? 8,
            colorModel: props[kCGImagePropertyColorModel] as? String,
            colorProfile: props[kCGImagePropertyProfileName] as? String,
            frameCount: CGImageSourceGetCount(src),
            orientation: props[kCGImagePropertyOrientation] as? Int ?? 1,
            hasEXIF: !(exif?.isEmpty ?? true),
            hasGPS: !(gps?.isEmpty ?? true),
            estimatedJPEGQuality: fmt == .jpeg ? JPEGQuality.estimate(url: url) : nil)
        return (fmt, traits)
    }

    func probe(_ url: URL) async -> MediaTraits? {
        guard let ffprobe else { return nil }
        let args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        guard let out = try? await ProcessRunner.run(ffprobe, args), out.status == 0,
              let json = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else { return nil }
        return Self.parseProbe(json)
    }

    static func parseProbe(_ json: [String: Any]) -> MediaTraits {
        var m = MediaTraits()
        let format = json["format"] as? [String: Any] ?? [:]
        m.duration = (format["duration"] as? String).flatMap(Double.init)
        m.bitRate = (format["bit_rate"] as? String).flatMap(Int.init)
        for s in json["streams"] as? [[String: Any]] ?? [] {
            let type = s["codec_type"] as? String
            let disposition = s["disposition"] as? [String: Any]
            if type == "video", m.videoCodec == nil, (disposition?["attached_pic"] as? Int ?? 0) == 0 {
                m.videoCodec = s["codec_name"] as? String
                m.width = s["width"] as? Int
                m.height = s["height"] as? Int
                if let r = s["avg_frame_rate"] as? String {
                    let parts = r.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0 { m.frameRate = parts[0] / parts[1] }
                }
            } else if type == "audio", m.audioCodec == nil {
                m.audioCodec = s["codec_name"] as? String
                m.sampleRate = (s["sample_rate"] as? String).flatMap(Int.init)
                m.channels = s["channels"] as? Int
                m.bitsPerSample = (s["bits_per_raw_sample"] as? String).flatMap(Int.init)
                    ?? (s["bits_per_sample"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            }
        }
        return m
    }
}
