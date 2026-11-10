import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import DropsterCore

/// Apple ImageIO: hardware-accelerated HEIC/AVIF/JPEG codecs, RAW development and
/// colour management, all in-process.
public struct ImageIOEngine: Engine {
    public let id = "imageio"
    public let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
    public let edges: [ConversionEdge]
    public let optimizable: Set<FormatID>

    static let readable: [FormatID] = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .bmp, .jxl, .jp2, .raw, .psd, .ico, .icns]
    static let writable: [FormatID: String] = [
        .jpeg: "public.jpeg", .png: "public.png", .heic: "public.heic", .avif: "public.avif",
        .tiff: "public.tiff", .gif: "com.compuserve.gif", .bmp: "com.microsoft.bmp", .jp2: "public.jpeg-2000",
        .pdf: "com.adobe.pdf", .ico: "com.microsoft.ico", .icns: "com.apple.icns",
    ]

    public init() {
        let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        // Sorted: dictionary order is randomised per process and would make routing nondeterministic.
        let targets = Self.writable.filter { supported.contains($0.value) }.map(\.key).sorted()
        var edges: [ConversionEdge] = []
        for s in Self.readable {
            for t in targets where t != s {
                // PNG is the preferred lossless intermediate; TIFF/BMP are larger and slower to pass along.
                let cost: Double = switch t {
                case .png: 1
                case .tiff, .bmp: 1.2
                case .pdf: 3
                default: t.isLossy ? 2 : 1.5
                }
                edges.append(ConversionEdge(from: s, to: t, cost: cost, engineID: "imageio"))
            }
        }
        self.edges = edges
        self.optimizable = Set([FormatID.jpeg, .heic, .avif, .tiff].filter { targets.contains($0) })
    }

    // MARK: Quality

    /// ImageIO quality per mode, calibrated so Balanced lands near SSIM 0.97 and Smallest
    /// near 0.95 on photos (sweeps in docs/BENCHMARKS.md). `qualityOverride` takes precedence.
    static func quality(for target: FormatID, mode: CompressionMode) -> Double {
        switch (target, mode) {
        // ImageIO's JPEG scale is not IJG's: 0.6 ≈ SSIM 0.968 on photos; above 0.75 it
        // disables chroma subsampling and sizes jump ~40%.
        case (.jpeg, .smallest): 0.5
        case (.jpeg, _): 0.62
        case (.heic, .smallest): 0.60
        case (.heic, _): 0.70
        // AVIF via ImageIO: 0.82 ≈ SSIM 0.965–0.975 on photos (docs/BENCHMARKS.md).
        case (.avif, .smallest): 0.72
        case (.avif, _): 0.82
        case (.jp2, _): 0.80
        default: 1.0
        }
    }

    public func run(_ ctx: StepContext) async throws {
        try Task.checkCancellation()
        if ctx.source.format == .jpeg, ctx.target == .jpeg, ctx.options.metadata == .removeAll,
           ctx.options.qualityOverride == 1.0, ctx.options.maxPixelSize == nil {
            // Metadata removal: lossless segment rewrite.
            let data = try [UInt8](Data(contentsOf: ctx.input))
            let stripped = try JPEGMetadata.strip(data, orientation: ctx.source.image?.orientation ?? 1)
            try Data(stripped).write(to: ctx.output)
            return
        }
        if ctx.options.metadata == .removeAll, ctx.options.qualityOverride == 1.0, ctx.source.format == ctx.target,
           ctx.options.maxPixelSize == nil, try copyWithoutMetadata(ctx) {
            return
        }
        try encode(ctx)
        if ctx.target == .png && ctx.options.mode != .fastest && ctx.isFinalStep {
            // Squeeze ImageIO's PNG through the lossless optimizer; keep whichever is smaller.
            let data = try [UInt8](Data(contentsOf: ctx.output))
            if let better = try? PNGOptimizer.optimize(data, mode: .balanced, metadata: ctx.options.metadata), better.count < data.count {
                try Data(better).write(to: ctx.output, options: .atomic)
            }
        }
        ctx.progress(1)
    }

    /// Rewrites container metadata without recompressing pixels (HEIC, TIFF, PNG, PSD).
    private func copyWithoutMetadata(_ ctx: StepContext) throws -> Bool {
        guard let uti = Self.writable[ctx.target],
              let src = CGImageSourceCreateWithURL(ctx.input as CFURL, nil),
              let dst = CGImageDestinationCreateWithURL(ctx.output as CFURL, uti as CFString, 1, nil) else { return false }
        let meta = CGImageMetadataCreateMutable()
        if let o = ctx.source.image?.orientation, o != 1 {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, o as CFNumber)
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, &error) { return true }
        try? FileManager.default.removeItem(at: ctx.output)
        return false
    }

    private func encode(_ ctx: StepContext) throws {
        guard let uti = Self.writable[ctx.target] else { throw DropsterError.unsupported("\(ctx.target.displayName) output") }
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(ctx.input as CFURL, srcOpts), CGImageSourceGetCount(src) > 0 else {
            throw DropsterError.decodeFailed("unreadable image")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, srcOpts) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { throw DropsterError.decodeFailed("no dimensions") }
        guard w * h <= 400_000_000 else { throw DropsterError.resourceLimit("\(w)×\(h) pixels") }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let longest = max(w, h)
        let limit = ctx.options.maxPixelSize.map { min($0, longest) }
        var baked = false
        var image: CGImage
        if limit != nil && limit! < longest || orientation != 1 {
            let t: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit ?? longest,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, t as CFDictionary) else { throw DropsterError.decodeFailed("resize failed") }
            image = img
            baked = true
        } else {
            guard let img = CGImageSourceCreateImageAtIndex(src, 0, srcOpts) else { throw DropsterError.decodeFailed("decode failed") }
            image = img
        }
        try Task.checkCancellation()
        if !ctx.target.supportsAlpha && ctx.target != .pdf && Self.hasAlpha(image) {
            image = try Self.flatten(image)
        }

        var quality = ctx.options.qualityOverride ?? Self.quality(for: ctx.target, mode: ctx.options.mode)
        if ctx.target == .jpeg, let q = ctx.source.image?.estimatedJPEGQuality, ctx.source.format == .jpeg {
            // Quality ceiling: never re-encode above the source's own quality.
            quality = min(quality, Double(q) / 100)
        }
        var out = Self.filteredMetadata(props, policy: ctx.options.metadata)
        if baked { out[kCGImagePropertyOrientation] = 1; Self.setTIFFOrientation(&out, 1) }
        if ctx.target.isLossy || ctx.target == .jp2 { out[kCGImageDestinationLossyCompressionQuality] = quality }
        if ctx.target == .tiff {
            var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = ctx.options.tiffCompression.rawValue
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let dpi = ctx.options.dpi { out[kCGImagePropertyDPIWidth] = dpi; out[kCGImagePropertyDPIHeight] = dpi }
        // Icons hold several square sizes in one file.
        let iconSizes: [Int] = switch ctx.target {
        case .ico: ctx.options.icoSizes.filter { $0 <= 256 }.sorted()
        case .icns: [16, 32, 64, 128, 256, 512, 1024]
        default: []
        }
        let frames = iconSizes.isEmpty ? [image] : try iconSizes.map { try Self.squareIcon(image, size: $0) }
        guard let dst = CGImageDestinationCreateWithURL(ctx.output as CFURL, uti as CFString, frames.count, nil) else {
            throw DropsterError.encodeFailed("cannot create \(ctx.target.displayName)")
        }
        for f in frames { CGImageDestinationAddImage(dst, f, (iconSizes.isEmpty ? out : [:]) as CFDictionary) }
        guard CGImageDestinationFinalize(dst) else { throw DropsterError.encodeFailed("\(ctx.target.displayName) encoder failed") }
    }

    /// Fits the image into a transparent square of `size` pixels.
    static func squareIcon(_ image: CGImage, size: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DropsterError.encodeFailed("icon")
        }
        let k = Double(size) / Double(max(image.width, image.height))
        let w = Double(image.width) * k, h = Double(image.height) * k
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(size) - w) / 2, y: (Double(size) - h) / 2, width: w, height: h))
        guard let out = ctx.makeImage() else { throw DropsterError.encodeFailed("icon") }
        return out
    }

    static func setTIFFOrientation(_ d: inout [CFString: Any], _ v: Int) {
        var tiff = d[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = v
        d[kCGImagePropertyTIFFDictionary] = tiff
    }

    /// Applies the metadata policy to ImageIO property dictionaries.
    static func filteredMetadata(_ props: [CFString: Any], policy: MetadataPolicy) -> [CFString: Any] {
        let carried: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
                                   kCGImagePropertyIPTCDictionary, kCGImagePropertyOrientation]
        var out: [CFString: Any] = [:]
        for k in carried { if let v = props[k] { out[k] = v } }
        switch policy {
        case .keep: break
        case .removePrivate:
            out[kCGImagePropertyGPSDictionary] = nil
            if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                for k in [kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
                          kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifUserComment, kCGImagePropertyExifMakerNote] { exif[k] = nil }
                out[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFArtist] = nil
                tiff[kCGImagePropertyTIFFHostComputer] = nil
                out[kCGImagePropertyTIFFDictionary] = tiff
            }
        case .removeAll:
            let o = props[kCGImagePropertyOrientation]
            out = [:]
            if let o { out[kCGImagePropertyOrientation] = o }
        }
        return out
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Composites onto white for formats without transparency (instead of ImageIO's black).
    static func flatten(_ image: CGImage) throws -> CGImage {
        let cs = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DropsterError.encodeFailed("cannot flatten transparency")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw DropsterError.encodeFailed("cannot flatten transparency") }
        return out
    }

    /// Writes an upright, optionally downscaled PNG for tools that ignore EXIF orientation.
    static func renderUprightPNG(_ input: URL, to output: URL, maxPixelSize: Int?) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw DropsterError.decodeFailed("unreadable image") }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let longest = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let t: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? longest, longest),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, t as CFDictionary),
              let dst = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw DropsterError.decodeFailed("cannot render image")
        }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { throw DropsterError.encodeFailed("PNG") }
    }
}

/// The in-house lossless PNG optimizer, exposed as an engine.
public struct PNGEngine: Engine {
    public let id = "png"
    /// Each job already uses every core (parallel trials + parallel deflate) and up to
    /// ~1 GB for 30+ MP images, so only a few run at once.
    public let maxConcurrency = 3
    public let edges: [ConversionEdge] = []
    public let optimizable: Set<FormatID> = [.png]

    public init() {}

    public func run(_ ctx: StepContext) async throws {
        var input = ctx.input
        if ctx.options.maxPixelSize != nil {
            input = ctx.output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
            try ImageIOEngine.renderUprightPNG(ctx.input, to: input, maxPixelSize: ctx.options.maxPixelSize)
        }
        defer { if input != ctx.input { try? FileManager.default.removeItem(at: input) } }
        let data = try [UInt8](Data(contentsOf: input))
        let mode = ctx.options.mode
        let policy = ctx.options.metadata
        let out: [UInt8] = try await Task.detached(priority: .userInitiated) {
            do { return try PNGOptimizer.optimize(data, mode: mode, metadata: policy) }
            catch let e as PNGError { throw DropsterError.unsupported(e.description) }
        }.value
        try Task.checkCancellation()
        try Data(out).write(to: ctx.output)
        ctx.progress(1)
    }
}
