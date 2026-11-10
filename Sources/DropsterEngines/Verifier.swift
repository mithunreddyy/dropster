import Foundation
import ImageIO
import CoreGraphics
import DropsterCore

/// Confirms every output actually opens as the expected format before it is committed.
public struct DefaultVerifier: OutputVerifier {
    let ffprobe: URL?
    let archive: ArchiveEngine?

    public init(ffprobe: URL? = ToolLocator.find("ffprobe"), archive: ArchiveEngine? = ArchiveEngine()) {
        self.ffprobe = ffprobe
        self.archive = archive
    }

    static let equivalent: [FormatID: Set<FormatID>] = [
        .mp4: [.mp4, .mov, .m4a], .mov: [.mov, .mp4], .m4a: [.m4a, .mp4], .mkv: [.mkv, .webm], .webm: [.webm, .mkv],
        .heic: [.heic, .avif], .avif: [.avif, .heic],
        .docx: [.zip], .odt: [.zip], .zip: [.zip],
    ]
    /// Text formats have no magic number; they are validated by content instead.
    static let textual: Set<FormatID> = [.txt, .md, .srt, .html, .opus, .brotli, .svg, .vtt, .ass]

    public func verify(_ url: URL, expected: FormatID) throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw DropsterError.verificationFailed("empty file") }
        if let sig = FileSignature.detect(url: url) {
            let ok = Self.equivalent[expected]?.contains(sig) ?? (sig == expected)
            guard ok || expected == .raw else {
                throw DropsterError.verificationFailed("expected \(expected.displayName), found \(sig.displayName)")
            }
        } else if !Self.textual.contains(expected) {
            // Brotli streams have no magic number; everything else should be recognisable.
            throw DropsterError.verificationFailed("unrecognised output")
        }
        switch expected.category {
        case .image where expected == .svg:
            let data = try Data(contentsOf: url)
            let ok = String(decoding: data.prefix(512), as: UTF8.self).contains("<svg") && XMLParser(data: data).parse()
            guard ok else { throw DropsterError.verificationFailed("SVG is not valid XML") }
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
                  CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  (p[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0 else {
                throw DropsterError.verificationFailed("image does not decode")
            }
        case .document where expected == .pdf:
            guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw DropsterError.verificationFailed("PDF does not open") }
        case .document, .subtitle:
            if [.txt, .md, .html, .srt, .vtt, .ass].contains(expected) {
                guard String(data: try Data(contentsOf: url), encoding: .utf8) != nil else {
                    throw DropsterError.verificationFailed("text is not valid UTF-8")
                }
            }
            if expected == .srt || expected == .vtt {
                guard !SubtitleEngine.parse(try String(contentsOf: url, encoding: .utf8)).isEmpty else {
                    throw DropsterError.verificationFailed("no subtitle cues")
                }
            }
        case .video, .audio:
            guard let ffprobe else { return }
            let p = Process()
            p.executableURL = ffprobe
            p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let d = Double(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard p.terminationStatus == 0, d > 0 else { throw DropsterError.verificationFailed("media does not play") }
        case .archive:
            guard let (tool, args) = archive?.testArguments(expected, file: url) else { return }
            let p = Process()
            p.executableURL = tool
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw DropsterError.verificationFailed("archive integrity test failed") }
        case .other: break
        }
    }
}

public enum Engines {
    /// Every engine that can run on this machine, in priority order.
    public static func available() -> [any Engine] {
        var list: [any Engine] = [PNGEngine()]
        if let j = JPEGEngine() { list.append(j) }
        list += [ImageEditEngine(), ImageIOEngine(), TraceEngine(), PDFEngine(), DocumentEngine(), SubtitleEngine()]
        if let w = WebPEngine() { list.append(w) }
        if let f = FFmpegEngine() { list.append(f) }
        list += [FitSizeEngine(), UnpackEngine(), ArchiveEngine()]
        return list
    }

    public static func makeRegistry() -> ConversionRegistry { ConversionRegistry(engines: available()) }

    public static func makeProcessor(workspace: Workspace? = nil) throws -> Processor {
        try Processor(registry: makeRegistry(), workspace: workspace ?? Workspace(), verifier: DefaultVerifier())
    }
}
