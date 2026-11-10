import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import Vision
import DropsterCore

/// Rotate, flip, crop, grayscale and background removal.
///
/// Rotations and flips of JPEG, HEIC and TIFF only rewrite the EXIF orientation tag, so
/// they are instant and lossless. Everything else renders pixels and re-encodes in the
/// source format (PNG when transparency is needed and the format has none).
public struct ImageEditEngine: Engine {
    public let id = "edit"
    public let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    public let edges: [ConversionEdge] = []
    public let optimizable: Set<FormatID> = []
    let jpeg: JPEGEngine?
    let webp: WebPEngine?

    static let editable: Set<FormatID> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .bmp, .jxl, .jp2, .raw, .psd]
    static let orientationTagFormats: Set<FormatID> = [.jpeg, .heic, .tiff]

    public init(jpeg: JPEGEngine? = JPEGEngine(), webp: WebPEngine? = WebPEngine()) {
        self.jpeg = jpeg
        self.webp = webp
    }

    public func supports(_ operation: FileOperation, source: FormatID) -> Bool {
        guard case .edit = operation, Self.editable.contains(source) else { return false }
        return source != .webp || webp != nil
    }

    public func run(_ ctx: StepContext) async throws {
        guard case .edit(let edit) = ctx.operation, let format = ctx.source.format else {
            throw DropsterError.unsupported("edit")
        }
        let orientation = ctx.source.image?.orientation ?? 1
        if edit.isOrientationOnly, Self.orientationTagFormats.contains(format), ctx.target == format, ctx.options.maxPixelSize == nil,
           try rewriteOrientation(ctx, to: edit.composedOrientation(orientation)) {
            ctx.progress(1)
            return
        }
        var image = try Self.uprightImage(ctx.input, maxPixelSize: ctx.options.maxPixelSize)
        ctx.progress(0.2)
        image = try Self.apply(edit, to: image)
        try Task.checkCancellation()
        ctx.progress(0.6)
        try await encode(image, ctx: ctx)
        ctx.progress(1)
    }

    /// Lossless: copies the compressed image and changes only the orientation tag.
    /// Verified by reading the result back; JPEGs without an EXIF block get a minimal one.
    private func rewriteOrientation(_ ctx: StepContext, to newOrientation: Int) throws -> Bool {
        // A JPEG without EXIF gets a standard EXIF orientation tag. (ImageIO would store it only
        // in XMP, which browsers and most other software ignore.)
        if ctx.source.format == .jpeg {
            let bytes = try [UInt8](Data(contentsOf: ctx.input))
            if !Self.hasEXIF(bytes) {
                try Data(JPEGMetadata.insertAfterAPP0(JPEGMetadata.orientationSegment(newOrientation), into: bytes)).write(to: ctx.output)
                if Self.orientation(of: ctx.output) == newOrientation { return true }
                try? FileManager.default.removeItem(at: ctx.output)
                return false
            }
        }
        guard let src = CGImageSourceCreateWithURL(ctx.input as CFURL, nil), let uti = CGImageSourceGetType(src),
              let dst = CGImageDestinationCreateWithURL(ctx.output as CFURL, uti, 1, nil) else { return false }
        let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, newOrientation as CFNumber)
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false,
                                     kCGImageMetadataShouldExcludeGPS: ctx.options.metadata != .keep]
        var err: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, &err), Self.orientation(of: ctx.output) == newOrientation {
            return true
        }
        try? FileManager.default.removeItem(at: ctx.output)
        return false
    }

    static func orientation(of url: URL) -> Int {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return 0 }
        return p[kCGImagePropertyOrientation] as? Int ?? 1
    }

    static func hasEXIF(_ b: [UInt8]) -> Bool {
        var i = 2
        while i + 10 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if b[i + 1] == 0xE1, b[(i + 4)..<min(i + 10, b.count)].elementsEqual(Array("Exif\0\0".utf8)) { return true }
            i += 2 + len
        }
        return false
    }

    // MARK: Pixels

    public static func uprightImage(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DropsterError.decodeFailed("unreadable image")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0, w * h <= 400_000_000 else { throw DropsterError.resourceLimit("\(w)×\(h) pixels") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? max(w, h), max(w, h)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw DropsterError.decodeFailed("decode failed") }
        return img
    }

    /// Applies orientation edits, crop, grayscale and background removal, in that order.
    public static func apply(_ edit: ImageEdit, to input: CGImage) throws -> CGImage {
        var image = input
        if edit.quarterTurns != 0 || edit.flipHorizontal || edit.flipVertical {
            image = try transform(image, edit: edit)
        }
        if let c = edit.crop {
            let r = CGRect(x: (c.x * Double(image.width)).rounded(), y: (c.y * Double(image.height)).rounded(),
                           width: max(1, (c.width * Double(image.width)).rounded()), height: max(1, (c.height * Double(image.height)).rounded()))
            guard let cropped = image.cropping(to: r.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else {
                throw DropsterError.encodeFailed("crop is outside the image")
            }
            image = cropped
        }
        if edit.grayscale { image = try grayscale(image) }
        if edit.removeBackground { image = try removeBackground(image) }
        return image
    }

    static func transform(_ image: CGImage, edit: ImageEdit) throws -> CGImage {
        let swap = edit.quarterTurns % 2 == 1
        let w = swap ? image.height : image.width, h = swap ? image.width : image.height
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = ImageIOEngine.hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let bpc = image.bitsPerComponent > 8 ? 16 : 8
        let space = cs.model == .rgb ? cs : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bpc, bytesPerRow: 0, space: space,
                                  bitmapInfo: info.rawValue | (bpc == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)) else {
            throw DropsterError.encodeFailed("cannot allocate \(w)×\(h) image")
        }
        // CoreGraphics' origin is bottom-left, so clockwise on screen is a negative angle here.
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        if edit.flipVertical { ctx.scaleBy(x: 1, y: -1) }
        if edit.flipHorizontal { ctx.scaleBy(x: -1, y: 1) }
        ctx.rotate(by: -CGFloat(edit.quarterTurns) * .pi / 2)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let out = ctx.makeImage() else { throw DropsterError.encodeFailed("transform failed") }
        return out
    }

    /// Luminance with Rec. 709 weights. Opaque images become true single-channel gray.
    static func grayscale(_ image: CGImage) throws -> CGImage {
        if !ImageIOEngine.hasAlpha(image),
           let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let out = ctx.makeImage() { return out }
        }
        let ci = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let out = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw DropsterError.encodeFailed("grayscale failed")
        }
        return out
    }

    /// Subject lift with Apple's on-device Vision model (no network).
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw DropsterError.encodeFailed("no subject was found to keep")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw DropsterError.encodeFailed("background removal failed")
        }
        return out
    }

    // MARK: Encoding

    private func encode(_ image: CGImage, ctx: StepContext) async throws {
        let dir = ctx.output.deletingLastPathComponent()
        let props = ImageIOEngine.filteredMetadata(
            (CGImageSourceCreateWithURL(ctx.input as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]) ?? [:],
            policy: ctx.options.metadata)
        switch ctx.target {
        case .jpeg where jpeg != nil:
            let png = dir.appendingPathComponent(UUID().uuidString + ".png")
            let enc = dir.appendingPathComponent(UUID().uuidString + ".jpg")
            defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: enc) }
            try Self.writePNG(image, to: png)
            // Edits keep the source's quality (never higher), defaulting to IJG ≈86.
            let q = JPEGEngine.qscale(mode: .balanced, qualityOverride: ctx.options.qualityOverride,
                                      sourceQuality: ctx.source.image?.estimatedJPEGQuality)
            try await jpeg!.encode(png, to: enc, qscale: q, maxPixelSize: nil, gray: image.colorSpace?.model == .monochrome)
            try JPEGEngine.finish(encoded: enc, original: ctx.input, output: ctx.output, policy: ctx.options.metadata, orientation: 1)
        case .webp:
            guard let webp else { throw DropsterError.unsupported("WebP output") }
            let png = dir.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: png) }
            try Self.writePNG(image, to: png)
            var opts = ctx.options
            opts.qualityOverride = opts.qualityOverride ?? 0.9
            var src = ctx.source
            src.image?.orientation = 1
            src.image?.estimatedJPEGQuality = nil
            try await webp.run(StepContext(input: png, output: ctx.output, source: src, target: .webp, options: opts,
                                           isOptimization: false, progress: { _ in }))
        default:
            guard let uti = ImageIOEngine.writable[ctx.target],
                  let dst = CGImageDestinationCreateWithURL(ctx.output as CFURL, uti as CFString, 1, nil) else {
                throw DropsterError.unsupported("\(ctx.target.displayName) output")
            }
            var p = props
            p[kCGImagePropertyOrientation] = 1
            ImageIOEngine.setTIFFOrientation(&p, 1)
            if ctx.target.isLossy { p[kCGImageDestinationLossyCompressionQuality] = ctx.options.qualityOverride ?? 0.8 }
            CGImageDestinationAddImage(dst, image, p as CFDictionary)
            guard CGImageDestinationFinalize(dst) else { throw DropsterError.encodeFailed("\(ctx.target.displayName) encoder failed") }
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw DropsterError.encodeFailed("PNG")
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { throw DropsterError.encodeFailed("PNG") }
    }
}
