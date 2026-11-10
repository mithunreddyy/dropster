import Foundation
import ImageIO
import DropsterCore

/// JPEG re-encoding with standard (Annex K) quantisation tables and optimal Huffman
/// coding via FFmpeg's mjpeg encoder.
///
/// Measured on aerial photos (docs/BENCHMARKS.md), this is 13–34% smaller than Apple's
/// ImageIO JPEG encoder at equal SSIM: ImageIO uses flat quantisation tables and drops
/// chroma subsampling at higher qualities. Colour profiles and metadata are carried over
/// from the source without touching the new image data.
public struct JPEGEngine: Engine {
    public let id = "jpeg"
    public let maxConcurrency: Int
    public let edges: [ConversionEdge] = []
    public let optimizable: Set<FormatID> = [.jpeg]
    let ffmpeg: URL

    public init?(ffmpeg: URL? = ToolLocator.find("ffmpeg")) {
        guard let ffmpeg, FFmpegEngine.listEncoders(ffmpeg).contains("mjpeg") else { return nil }
        self.ffmpeg = ffmpeg
        maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    /// FFmpeg mjpeg qscale ≈ (101 − IJG quality) / 5.
    static func qscale(mode: CompressionMode, qualityOverride: Double?, sourceQuality: Int?) -> Int {
        var q: Int
        if let o = qualityOverride { q = Int(((101 - o * 100) / 5).rounded(.up)) }
        else { q = mode == .smallest ? 5 : 3 }
        // Quality ceiling: never encode finer than the source was saved.
        if let s = sourceQuality { q = max(q, Int((Double(101 - s) / 5).rounded(.up))) }
        return min(31, max(2, q))
    }

    public func run(_ ctx: StepContext) async throws {
        // Metadata removal is a lossless segment rewrite (ImageIOEngine handles it); CMYK and
        // other unusual JPEGs go through ImageIO too, which colour-manages them correctly.
        let metadataOnly = ctx.options.metadata == .removeAll && ctx.options.qualityOverride == 1.0 && ctx.options.maxPixelSize == nil
        if metadataOnly {
            try await ImageIOEngine().run(ctx)
            return
        }
        if let model = ctx.source.image?.colorModel, model != "RGB" && model != "Gray" {
            try await ImageIOEngine().run(ctx)
            return
        }
        let q = Self.qscale(mode: ctx.options.mode, qualityOverride: ctx.options.qualityOverride == 1.0 ? nil : ctx.options.qualityOverride,
                            sourceQuality: ctx.source.image?.estimatedJPEGQuality)
        let encoded = ctx.output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: encoded) }
        try await encode(ctx.input, to: encoded, qscale: q, maxPixelSize: ctx.options.maxPixelSize,
                         gray: ctx.source.image?.colorModel == "Gray")
        try Task.checkCancellation()
        try Self.finish(encoded: encoded, original: ctx.input, output: ctx.output, policy: ctx.options.metadata,
                        orientation: ctx.source.image?.orientation ?? 1)
        ctx.progress(1)
    }

    /// Encodes any image FFmpeg can read as a baseline JPEG with optimal Huffman tables.
    func encode(_ input: URL, to encoded: URL, qscale q: Int, maxPixelSize: Int?, gray: Bool) async throws {
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-noautorotate", "-i", input.path, "-frames:v", "1"]
        if let edge = maxPixelSize {
            args += ["-vf", "scale='if(gt(iw,ih),min(\(edge),iw),-2)':'if(gt(iw,ih),-2,min(\(edge),ih))':flags=lanczos"]
        }
        args += ["-c:v", "mjpeg", "-q:v", String(q), "-huffman", "optimal", "-pix_fmt", gray ? "gray" : "yuvj420p",
                 "-map_metadata", "-1", encoded.path]
        try await ProcessRunner.check(ffmpeg, args)
    }

    /// Splices the original's ICC profile into the new JPEG and transfers metadata per policy,
    /// writing `orientation` as the EXIF orientation of the result.
    static func finish(encoded: URL, original: URL, output: URL, policy: MetadataPolicy, orientation: Int) throws {
        let source = try [UInt8](Data(contentsOf: original))
        let icc = source.starts(with: [0xFF, 0xD8]) ? JPEGMetadata.iccSegments(source) : []
        let encodedBytes = [UInt8](try Data(contentsOf: encoded))
        var out = icc.isEmpty ? encodedBytes : try JPEGMetadata.insert(icc, into: encodedBytes)
        if policy == .removeAll || !source.starts(with: [0xFF, 0xD8]) {
            out = try JPEGMetadata.strip(out, orientation: orientation)
            try Data(out).write(to: output)
        } else {
            try Data(out).write(to: encoded, options: .atomic)
            try applyMetadata(from: original, to: encoded, output: output, policy: policy, orientation: orientation)
        }
    }

    /// Copies EXIF/XMP/IPTC from the original onto the new JPEG without recompressing it.
    private static func applyMetadata(from original: URL, to encoded: URL, output: URL, policy: MetadataPolicy, orientation: Int) throws {
        guard let orig = CGImageSourceCreateWithURL(original as CFURL, nil),
              let enc = CGImageSourceCreateWithURL(encoded as CFURL, nil),
              let dst = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw DropsterError.encodeFailed("metadata transfer")
        }
        let meta = CGImageSourceCopyMetadataAtIndex(orig, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        if policy == .removePrivate {
            for path in ["exifEX:BodySerialNumber", "exifEX:LensSerialNumber", "exifEX:CameraOwnerName", "aux:SerialNumber",
                         "aux:LensSerialNumber", "exif:UserComment", "tiff:Artist"] {
                CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
            }
        }
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        var opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false]
        if policy == .removePrivate { opts[kCGImageMetadataShouldExcludeGPS] = true }
        var err: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(dst, enc, opts as CFDictionary, &err) {
            // Fall back to the encoded image with only orientation preserved.
            try? FileManager.default.removeItem(at: output)
            let bytes = try JPEGMetadata.strip([UInt8](Data(contentsOf: encoded)), orientation: orientation)
            try Data(bytes).write(to: output)
        }
    }
}
