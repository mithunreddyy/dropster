import Foundation
import AppKit
import CoreText
import PDFKit
import DropsterCore

/// Word, OpenDocument, RTF, HTML, Markdown and plain text through the macOS text system,
/// so no Office suite is needed. PDF output is laid out with Core Text on A4 or US Letter
/// (by region) with 2 cm margins.
///
/// Limits: the text system keeps paragraphs, fonts, colours, lists and simple tables;
/// complex layout (floating images, text boxes, tracked changes) is simplified.
public struct DocumentEngine: Engine {
    public let id = "document"
    public let maxConcurrency = 2
    public let edges: [ConversionEdge]
    public let optimizable: Set<FormatID> = []

    static let readable: [FormatID] = [.docx, .doc, .odt, .rtf, .html, .txt, .md]
    static let writable: [FormatID] = [.docx, .doc, .odt, .rtf, .html, .txt, .pdf]

    public init() {
        var e: [ConversionEdge] = []
        for s in Self.readable {
            for t in Self.writable where t != s {
                e.append(ConversionEdge(from: s, to: t, cost: t == .pdf ? 2 : 1.5, engineID: "document"))
            }
        }
        edges = e
    }

    static func documentType(_ f: FormatID) -> NSAttributedString.DocumentType? {
        switch f {
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .odt: .openDocument
        case .rtf: .rtf
        case .html: .html
        case .txt, .md: .plain
        default: nil
        }
    }

    public func run(_ ctx: StepContext) async throws {
        guard let source = ctx.source.format else { throw DropsterError.unsupported("unknown document") }
        let text = try await Self.read(ctx.input, format: source)
        try Task.checkCancellation()
        if ctx.target == .pdf {
            try Self.writePDF(Self.withExtractableFonts(text), to: ctx.output)
        } else {
            guard let type = Self.documentType(ctx.target) else { throw DropsterError.unsupported(ctx.target.displayName) }
            var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .plain { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
            try data.write(to: ctx.output)
        }
        ctx.progress(1)
    }

    static func read(_ url: URL, format: FormatID) async throws -> NSAttributedString {
        if format == .md {
            let source = try String(contentsOf: url, encoding: .utf8)
            let parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            let base = NSMutableAttributedString(parsed)
            base.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: base.length))
            return base
        }
        guard let type = documentType(format) else { throw DropsterError.unsupported(format.displayName) }
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .plain { opts[.characterEncoding] = String.Encoding.utf8.rawValue }
        if type == .html {
            // HTML import uses WebKit and must run on the main thread. Remote resources are not loaded.
            let data = try Data(contentsOf: url)
            // NSAttributedString isn't Sendable, so it crosses back as RTF data.
            let rtf: Data = try await MainActor.run {
                let s = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                     .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
                return try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            }
            return try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        return try NSAttributedString(url: url, options: opts, documentAttributes: nil)
    }

    nonisolated(unsafe) private static var fontCache: [String: Bool] = [:]
    private static let fontLock = NSLock()

    /// Core Graphics embeds a few legacy faces (e.g. Helvetica Light) without a ToUnicode map,
    /// which makes the PDF's text unsearchable and uncopyable. Each font is probed once; those
    /// that fail are replaced by the same weight and traits in Helvetica Neue, else the system font.
    static func withExtractableFonts(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let font = value as? NSFont, !embedsText(font) else { return }
            let fm = NSFontManager.shared
            var replacement = fm.convert(font, toFamily: "Helvetica Neue")
            if replacement.familyName != "Helvetica Neue" || !embedsText(replacement) {
                let weight: NSFont.Weight = fm.weight(of: font) <= 4 ? .light : (fm.weight(of: font) >= 9 ? .bold : .regular)
                replacement = NSFont.systemFont(ofSize: font.pointSize, weight: weight)
            }
            out.addAttribute(.font, value: replacement, range: range)
        }
        return out
    }

    /// Renders a short sample with `font` and checks PDFKit can read the text back.
    static func embedsText(_ font: NSFont) -> Bool {
        let key = font.fontName
        if let cached = fontLock.withLock({ fontCache[key] }) { return cached }
        let sample = NSAttributedString(string: "Sample text 0123", attributes: [.font: NSFont(name: font.fontName, size: 12) ?? font])
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 400, height: 60)
        var ok = false
        if let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) {
            ctx.beginPDFPage(nil)
            let f = CTFramesetterCreateWithAttributedString(sample)
            CTFrameDraw(CTFramesetterCreateFrame(f, CFRange(), CGPath(rect: media, transform: nil), nil), ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = PDFDocument(data: data as Data)?.string?.contains("Sample text") == true
        }
        fontLock.withLock { fontCache[key] = ok }
        return ok
    }

    /// Paginates with a Core Text framesetter, one frame per page.
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let letter = ["US", "CA", "MX", "PH"].contains(Locale.current.region?.identifier ?? "")
        var media = letter ? CGRect(x: 0, y: 0, width: 612, height: 792) : CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let margin: CGFloat = 56.7
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else { throw DropsterError.encodeFailed("PDF") }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var location = 0
        let frameRect = media.insetBy(dx: margin, dy: margin)
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < text.length
        ctx.closePDF()
    }
}
