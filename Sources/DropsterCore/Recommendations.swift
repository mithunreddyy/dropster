import Foundation

public struct Recommendation: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case saving, privacy, warning, info }
    public var id: String { message }
    public var kind: Kind
    public var message: String
    /// The operation the recommendation suggests, if any.
    public var operation: FileOperation?

    public init(kind: Kind, message: String, operation: FileOperation? = nil) {
        self.kind = kind
        self.message = message
        self.operation = operation
    }
}

/// Turns a `FileReport` into plain-language suggestions. Wording is deliberately
/// hedged ("may", "likely"): measured savings are only shown after processing.
public enum Advisor {
    public static func recommendations(for r: FileReport, available: Set<FormatID>) -> [Recommendation] {
        var out: [Recommendation] = []
        guard let format = r.format else {
            return [Recommendation(kind: .warning, message: "Unrecognised file type. Dropster can still compress it as a generic file.")]
        }
        if r.extensionMismatch, let d = r.detectedFormat, let e = r.extensionFormat {
            out.append(Recommendation(kind: .warning, message: "Content is \(d.displayName), but the extension says \(e.displayName)."))
        }
        if let img = r.image {
            if img.hasGPS {
                out.append(Recommendation(kind: .privacy, message: "Contains location data. Remove it before sharing.", operation: .stripMetadata))
            }
            if img.isAnimated {
                out.append(Recommendation(kind: .info, message: "Animated image with \(img.frameCount) frames."))
                if available.contains(.mp4) {
                    out.append(Recommendation(kind: .saving, message: "Animations are usually far smaller as MP4 video.", operation: .convert(.mp4)))
                }
                return out
            }
            switch format {
            case .jpeg:
                if let q = img.estimatedJPEGQuality, q >= 88 {
                    out.append(Recommendation(kind: .saving, message: "Saved at high quality (≈\(q)). Optimizing will likely save space.", operation: .optimize))
                } else if let q = img.estimatedJPEGQuality {
                    out.append(Recommendation(kind: .info, message: "Already compressed (quality ≈\(q)). Gains from re-encoding may be small."))
                }
                if available.contains(.heic) {
                    out.append(Recommendation(kind: .saving, message: "HEIC typically stores the same detail in less space.", operation: .convert(.heic)))
                }
            case .png:
                out.append(Recommendation(kind: .saving, message: "Lossless optimization available.", operation: .optimize))
                if !img.hasAlpha && img.megapixels > 0.5 && available.contains(.jpeg) {
                    out.append(Recommendation(kind: .saving, message: "No transparency. A photo like this may be much smaller as JPEG or WebP.", operation: .convert(available.contains(.webp) ? .webp : .jpeg)))
                }
            case .bmp, .tiff, .psd:
                out.append(Recommendation(kind: .saving, message: "Lossless PNG would store the same pixels in less space.", operation: .convert(.png)))
            case .heic, .avif, .webp, .jxl:
                if !available.isEmpty {
                    out.append(Recommendation(kind: .info, message: "Modern format. Convert to JPEG for compatibility with older apps.", operation: .convert(.jpeg)))
                }
            case .raw:
                out.append(Recommendation(kind: .info, message: "Camera RAW. Convert to HEIC or JPEG for sharing.", operation: .convert(.heic)))
            default: break
            }
        }
        if let m = r.media {
            if m.hasVideo {
                if let codec = m.videoCodec?.lowercased(), !["hevc", "h265", "av1"].contains(codec) {
                    out.append(Recommendation(kind: .saving, message: "HEVC encoding may roughly halve the size at similar quality.", operation: .optimize))
                }
            } else {
                switch format {
                case .wav, .aiff:
                    out.append(Recommendation(kind: .saving, message: "Uncompressed audio. FLAC is lossless and usually 40–60% smaller.", operation: .convert(.flac)))
                default: break
                }
            }
        }
        if format.category == .archive {
            out.append(Recommendation(kind: .info, message: "Compressed archive. Recompressing rarely helps."))
        }
        return out
    }

    /// The operation Dropster applies when the user drops a file without choosing one.
    public static func defaultOperation(for r: FileReport, optimizable: Set<FormatID>) -> FileOperation? {
        guard let format = r.format else { return .convert(.zstd) }
        if let img = r.image, img.isAnimated { return optimizable.contains(.mp4) ? .convert(.mp4) : nil }
        switch format {
        case .bmp, .tiff, .psd: return .convert(.png)
        case .wav, .aiff: return .convert(.flac)
        case .raw: return .convert(.heic)
        case .zip, .sevenZip, .tar, .gzip, .xz, .zstd, .brotli: return .unpack
        default: return optimizable.contains(format) ? .optimize : nil
        }
    }
}
