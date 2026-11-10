import Foundation

public enum FormatCategory: String, Codable, Sendable, CaseIterable {
    case image, video, audio, document, subtitle, archive, other

    public var displayName: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .subtitle: "Subtitles"
        case .archive: "Archive"
        case .other: "File"
        }
    }
}

/// Every format Dropster knows how to identify. Whether it can be *produced*
/// depends on which engines are available at runtime (see `ConversionRegistry`).
public enum FormatID: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    // Images
    case jpeg, png, heic, avif, webp, tiff, gif, bmp, jxl, jp2, raw, psd, ico, icns, svg
    // Video
    case mp4, mov, mkv, webm, avi
    // Audio
    case mp3, m4a, wav, aiff, flac, ogg, opus
    // Documents
    case pdf, docx, doc, odt, rtf, html, txt, md
    // Subtitles
    case srt, vtt, ass
    // Archives / single-stream compression
    case zip, gzip, zstd, xz, brotli, sevenZip, tar
    /// Wildcard source used by engines that accept any file (e.g. generic compressors).
    case any

    public static func < (lhs: FormatID, rhs: FormatID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var category: FormatCategory {
        switch self {
        case .jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .bmp, .jxl, .jp2, .raw, .psd, .ico, .icns, .svg: .image
        case .mp4, .mov, .mkv, .webm, .avi: .video
        case .mp3, .m4a, .wav, .aiff, .flac, .ogg, .opus: .audio
        case .pdf, .docx, .doc, .odt, .rtf, .html, .txt, .md: .document
        case .srt, .vtt, .ass: .subtitle
        case .zip, .gzip, .zstd, .xz, .brotli, .sevenZip, .tar: .archive
        case .any: .other
        }
    }

    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .jxl: "JPEG XL"
        case .jp2: "JPEG 2000"
        case .raw: "Camera RAW"
        case .psd: "Photoshop"
        case .ico: "ICO"
        case .icns: "macOS Icon"
        case .svg: "SVG"
        case .mp4: "MP4"
        case .mov: "QuickTime"
        case .mkv: "Matroska"
        case .webm: "WebM"
        case .avi: "AVI"
        case .mp3: "MP3"
        case .m4a: "AAC (M4A)"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .ogg: "Ogg Vorbis"
        case .opus: "Opus"
        case .pdf: "PDF"
        case .docx: "Word"
        case .doc: "Word 97"
        case .odt: "OpenDocument Text"
        case .rtf: "Rich Text"
        case .html: "HTML"
        case .txt: "Plain Text"
        case .md: "Markdown"
        case .srt: "SubRip"
        case .vtt: "WebVTT"
        case .ass: "SubStation Alpha"
        case .zip: "ZIP"
        case .gzip: "Gzip"
        case .zstd: "Zstandard"
        case .xz: "XZ"
        case .brotli: "Brotli"
        case .sevenZip: "7-Zip"
        case .tar: "Tar"
        case .any: "Any File"
        }
    }

    /// Preferred extension for files Dropster writes.
    public var preferredExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .sevenZip: "7z"
        case .gzip: "gz"
        case .zstd: "zst"
        case .brotli: "br"
        case .raw: "dng"
        case .any: "bin"
        default: rawValue
        }
    }

    public var knownExtensions: Set<String> {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]
        case .png: ["png"]
        case .heic: ["heic", "heif", "hif"]
        case .avif: ["avif"]
        case .webp: ["webp"]
        case .tiff: ["tif", "tiff"]
        case .gif: ["gif"]
        case .bmp: ["bmp", "dib"]
        case .jxl: ["jxl"]
        case .jp2: ["jp2", "j2k", "jpf"]
        case .raw: ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"]
        case .psd: ["psd"]
        case .ico: ["ico"]
        case .icns: ["icns"]
        case .svg: ["svg"]
        case .mp4: ["mp4", "m4v"]
        case .mov: ["mov", "qt"]
        case .mkv: ["mkv"]
        case .webm: ["webm"]
        case .avi: ["avi"]
        case .mp3: ["mp3"]
        case .m4a: ["m4a", "aac"]
        case .wav: ["wav", "wave"]
        case .aiff: ["aif", "aiff", "aifc"]
        case .flac: ["flac"]
        case .ogg: ["ogg", "oga"]
        case .opus: ["opus"]
        case .pdf: ["pdf"]
        case .docx: ["docx"]
        case .doc: ["doc"]
        case .odt: ["odt"]
        case .rtf: ["rtf"]
        case .html: ["html", "htm"]
        case .txt: ["txt", "text", "log"]
        case .md: ["md", "markdown"]
        case .srt: ["srt"]
        case .vtt: ["vtt"]
        case .ass: ["ass", "ssa"]
        case .zip: ["zip"]
        case .gzip: ["gz", "gzip", "tgz"]
        case .zstd: ["zst", "zstd"]
        case .xz: ["xz"]
        case .brotli: ["br"]
        case .sevenZip: ["7z"]
        case .tar: ["tar"]
        case .any: []
        }
    }

    public static func fromExtension(_ ext: String) -> FormatID? {
        let e = ext.lowercased()
        return allCases.first { $0.knownExtensions.contains(e) }
    }

    /// Formats whose standard encoding discards information.
    public var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp, .mp4, .mov, .mkv, .webm, .avi, .mp3, .m4a, .ogg, .opus: true
        default: false
        }
    }

    public var supportsAlpha: Bool {
        switch self {
        case .png, .heic, .avif, .webp, .tiff, .gif, .jxl, .ico, .icns, .psd, .svg: true
        default: false
        }
    }
}
