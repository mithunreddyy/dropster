import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import DropsterCore

/// PDF compression, page export, split, page ranges, one long image and text extraction.
public struct PDFEngine: Engine {
    public let id = "pdf"
    public let maxConcurrency = 3
    public let edges: [ConversionEdge] = [ConversionEdge(from: .pdf, to: .txt, cost: 2, engineID: "pdf")]
    public let optimizable: Set<FormatID> = [.pdf]
    let ghostscript: URL?
    static let pageFormats: Set<FormatID> = [.png, .jpeg, .heic, .tiff, .webp]

    public init(ghostscript: URL? = ToolLocator.find("gs")) { self.ghostscript = ghostscript }

    public func supports(_ operation: FileOperation, source: FormatID) -> Bool {
        guard source == .pdf else { return false }
        switch operation {
        case .exportPages(let f), .longImage(let f): return Self.pageFormats.contains(f) && (f != .webp || WebPEngine() != nil)
        case .splitPDF, .extractPages: return true
        default: return false
        }
    }

    public func run(_ ctx: StepContext) async throws {
        guard let doc = PDFDocument(url: ctx.input) else { throw DropsterError.decodeFailed("PDF cannot be opened") }
        if doc.isLocked { throw DropsterError.unsupported("password-protected PDF") }
        let dpi = Double(ctx.options.dpi ?? 150)
        switch ctx.operation {
        case .optimize:
            try await compress(doc, ctx: ctx)
        case .stripMetadata:
            doc.documentAttributes = [:]
            guard doc.write(to: ctx.output) else { throw DropsterError.encodeFailed("PDF") }
        case .convert(.txt):
            try (doc.string ?? "").write(to: ctx.output, atomically: true, encoding: .utf8)
        case .exportPages(let f):
            try FileManager.default.createDirectory(at: ctx.output, withIntermediateDirectories: true)
            let digits = max(3, String(doc.pageCount).count)
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: i) else { continue }
                let img = try Self.render(page, dpi: dpi)
                let name = "page-" + String(format: "%0\(digits)d", i + 1) + "." + f.preferredExtension
                try await Self.write(img, format: f, to: ctx.output.appendingPathComponent(name), options: ctx.options)
                ctx.progress(Double(i + 1) / Double(doc.pageCount))
            }
        case .longImage(let f):
            try await Self.write(try Self.longImage(doc, dpi: dpi), format: f, to: ctx.output, options: ctx.options)
        case .splitPDF:
            try FileManager.default.createDirectory(at: ctx.output, withIntermediateDirectories: true)
            let digits = max(3, String(doc.pageCount).count)
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                let one = PDFDocument()
                one.insert(page, at: 0)
                guard one.write(to: ctx.output.appendingPathComponent("page-" + String(format: "%0\(digits)d", i + 1) + ".pdf")) else {
                    throw DropsterError.encodeFailed("page \(i + 1)")
                }
                ctx.progress(Double(i + 1) / Double(doc.pageCount))
            }
        case .extractPages(let range):
            guard let pages = PageRange.parse(range, count: doc.pageCount) else {
                throw DropsterError.unsupported("page range “\(range)” for a \(doc.pageCount)-page PDF")
            }
            let out = PDFDocument()
            for (n, i) in pages.enumerated() {
                if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: n) }
            }
            guard out.write(to: ctx.output) else { throw DropsterError.encodeFailed("PDF") }
        default:
            throw DropsterError.unsupported(ctx.operation.label)
        }
        ctx.progress(1)
    }

    /// Tries PDFKit's image recompression and, if installed, Ghostscript; keeps the smaller.
    private func compress(_ doc: PDFDocument, ctx: StepContext) async throws {
        var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if ctx.options.mode == .smallest { options[.optimizeImagesForScreenOption] = true }
        if ctx.options.metadata != .keep { doc.documentAttributes = [:] }
        guard doc.write(to: ctx.output, withOptions: options) else { throw DropsterError.encodeFailed("PDF") }
        guard let gs = ghostscript else { return }
        let setting = switch ctx.options.mode { case .smallest: "/screen"; case .balanced: "/ebook"; case .fastest: "/printer" }
        let alt = ctx.output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: alt) }
        let result = try await ProcessRunner.run(gs, ["-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite",
                                                      "-dPDFSETTINGS=\(setting)", "-dCompatibilityLevel=1.6",
                                                      "-sOutputFile=\(alt.path)", ctx.input.path])
        let size = { (u: URL) in ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? .max }
        if result.status == 0, PDFDocument(url: alt)?.pageCount == doc.pageCount, size(alt) < size(ctx.output) {
            try FileManager.default.removeItem(at: ctx.output)
            try FileManager.default.moveItem(at: alt, to: ctx.output)
        }
    }

    /// Renders a page on white at `dpi`, honouring the page's rotation and crop box.
    static func render(_ page: PDFPage, dpi: Double) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let k = dpi / 72
        let w = Int((size.width * k).rounded()), h = Int((size.height * k).rounded())
        guard w > 0, h > 0, w * h <= 200_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DropsterError.resourceLimit("page too large to render at \(Int(dpi)) dpi")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: k, y: k)
        page.transform(ctx, for: .cropBox)
        page.draw(with: .cropBox, to: ctx)
        guard let img = ctx.makeImage() else { throw DropsterError.encodeFailed("render") }
        return img
    }

    /// All pages stacked top to bottom. Resolution drops automatically to stay under 300 MP.
    static func longImage(_ doc: PDFDocument, dpi: Double) throws -> CGImage {
        guard doc.pageCount > 0 else { throw DropsterError.decodeFailed("PDF has no pages") }
        var points = CGSize.zero
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let b = p.bounds(for: .cropBox)
            let s = p.rotation % 180 != 0 ? CGSize(width: b.height, height: b.width) : b.size
            points.width = max(points.width, s.width)
            points.height += s.height
        }
        var k = dpi / 72
        while points.width * k * points.height * k > 300_000_000 { k *= 0.8 }
        let w = Int(points.width * k), h = Int(points.height * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DropsterError.resourceLimit("\(w)×\(h) pixels")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var top = Double(h)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let img = try render(page, dpi: k * 72)
            top -= Double(img.height)
            ctx.draw(img, in: CGRect(x: (Double(w) - Double(img.width)) / 2, y: top, width: Double(img.width), height: Double(img.height)))
        }
        guard let out = ctx.makeImage() else { throw DropsterError.encodeFailed("render") }
        return out
    }

    static func write(_ image: CGImage, format: FormatID, to url: URL, options: ProcessingOptions) async throws {
        if format == .webp {
            guard let webp = WebPEngine() else { throw DropsterError.unsupported("WebP output") }
            let png = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: png) }
            try ImageEditEngine.writePNG(image, to: png)
            let r = FileReport(url: png, byteSize: 0, detectedFormat: .png, extensionFormat: .png)
            var o = options
            o.qualityOverride = o.qualityOverride ?? 0.88
            try await webp.run(StepContext(input: png, output: url, source: r, target: .webp, options: o, isOptimization: false, progress: { _ in }))
            return
        }
        guard let uti = ImageIOEngine.writable[format], let dst = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw DropsterError.unsupported("\(format.displayName) pages")
        }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = ImageIOEngine.quality(for: format, mode: options.mode) }
        if let dpi = options.dpi { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw DropsterError.encodeFailed(format.displayName) }
    }
}
