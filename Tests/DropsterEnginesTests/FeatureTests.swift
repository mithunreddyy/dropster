import Testing
import Foundation
import ImageIO
import CoreGraphics
import PDFKit
@testable import DropsterCore
@testable import DropsterEngines

/// RGBA8 pixels of an image, top row first.
func rgba(_ image: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buf
}

/// A 2×1 image: red on the left, blue on the right.
func redBlue() -> CGImage {
    var px: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
    let ctx = CGContext(data: &px, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

@Suite struct EditTests {
    @Test func orientationAlgebra() {
        #expect(ImageEdit.rotateRight.composedOrientation(1) == 6)
        #expect(ImageEdit.rotateLeft.composedOrientation(1) == 8)
        #expect(ImageEdit(quarterTurns: 2).composedOrientation(1) == 3)
        #expect(ImageEdit.flipH.composedOrientation(1) == 2)
        #expect(ImageEdit.flipV.composedOrientation(1) == 4)
        #expect(ImageEdit.rotateRight.composedOrientation(6) == 3)
        #expect(ImageEdit.rotateLeft.composedOrientation(6) == 1)
        #expect(ImageEdit.flipH.composedOrientation(2) == 1)
        // Every orientation composed with four right turns comes back to itself.
        for o in 1...8 {
            var x = o
            for _ in 0..<4 { x = ImageEdit.rotateRight.composedOrientation(x) }
            #expect(x == o)
        }
    }

    @Test func pixelTransformsMoveTheRightPixels() throws {
        let rotated = try ImageEditEngine.apply(.rotateRight, to: redBlue())
        #expect(rotated.width == 1 && rotated.height == 2)
        let r = rgba(rotated)
        #expect(r[0] == 255 && r[2] == 0, "red must end up on top after a clockwise turn")
        #expect(r[4] == 0 && r[6] == 255)
        let left = rgba(try ImageEditEngine.apply(.rotateLeft, to: redBlue()))
        #expect(left[2] == 255, "blue on top after a counter-clockwise turn")
        let flipped = rgba(try ImageEditEngine.apply(.flipH, to: redBlue()))
        #expect(flipped[2] == 255 && flipped[4] == 255, "blue left, red right")
    }

    @Test func cropAndGrayscale() throws {
        let img = makeImage(width: 200, height: 100)
        let cropped = try ImageEditEngine.apply(ImageEdit(crop: CropRect(x: 0.25, y: 0, width: 0.5, height: 0.5)), to: img)
        #expect(cropped.width == 100 && cropped.height == 50)
        let gray = try ImageEditEngine.apply(.toGrayscale, to: img)
        #expect(gray.colorSpace?.model == .monochrome)
    }

    @Test(.enabled(if: JPEGEngine() != nil)) func rotationIsLosslessForJPEG() async throws {
        let dir = try tempDir()
        let u = dir.appendingPathComponent("p.jpg")
        write(makeImage(), to: u, uti: "public.jpeg", props: [kCGImageDestinationLossyCompressionQuality: 0.9])
        let report = await FileAnalyzer().analyze(u)
        let out = dir.appendingPathComponent("o.jpg")
        try await ImageEditEngine().run(StepContext(input: u, output: out, source: report, target: .jpeg, options: .init(),
                                                    isOptimization: false, operation: .edit(.rotateRight), progress: { _ in }))
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
        func scan(_ url: URL) throws -> [UInt8] {
            let b = [UInt8](try Data(contentsOf: url))
            var i = 2
            while i + 4 <= b.count { if b[i] == 0xFF && b[i + 1] == 0xDA { return Array(b[i...]) }; i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3])) }
            return []
        }
        #expect(try scan(out) == scan(u), "compressed image data must be untouched")
    }
}

@Suite struct PageRangeTests {
    @Test func parsesRanges() {
        #expect(PageRange.parse("1-3, 5", count: 10) == [0, 1, 2, 4])
        #expect(PageRange.parse("8-", count: 10) == [7, 8, 9])
        #expect(PageRange.parse("2,2,3", count: 3) == [1, 2])
        #expect(PageRange.parse("3-1", count: 5) == nil)
        #expect(PageRange.parse("x", count: 5) == nil)
        #expect(PageRange.parse("9", count: 5) == nil)
    }
}

@Suite struct SubtitleTests {
    @Test func srtVttRoundTrip() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\nthere\r\n\r\n2\r\n01:02:03,004 --> 01:02:04,000\r\nWorld\r\n"
        let cues = SubtitleEngine.parse(srt)
        #expect(cues == [SubtitleEngine.Cue(start: 1000, end: 2500, text: "Hello\nthere"),
                         SubtitleEngine.Cue(start: 3_723_004, end: 3_724_000, text: "World")])
        let vtt = SubtitleEngine.vtt(cues)
        #expect(vtt.hasPrefix("WEBVTT") && vtt.contains("01:02:03.004 --> 01:02:04.000"))
        #expect(SubtitleEngine.parse(vtt) == cues)
        #expect(SubtitleEngine.parse(SubtitleEngine.srt(cues)) == cues)
    }

    @Test func vttWithCueSettings() {
        let cues = SubtitleEngine.parse("WEBVTT\n\n00:01.500 --> 00:02.000 align:start\nHi\n")
        #expect(cues == [SubtitleEngine.Cue(start: 1500, end: 2000, text: "Hi")])
    }
}

@Suite(.serialized) struct DocumentAndPDFTests {
    let processor = try! Engines.makeProcessor(workspace: Workspace(root: try! tempDir().appendingPathComponent("ws")))

    func run(_ url: URL, _ op: FileOperation, _ options: ProcessingOptions = .init()) async throws -> ProcessingResult {
        let r = await FileAnalyzer().analyze(url)
        let target = op.outputFormat(source: r.format!)
        let dest = try OutputPlanner.destination(for: url, target: target, operation: op, location: .nextToOriginal)
        return try await processor.process(r, operation: op, options: options, destination: dest) { _ in }
    }

    @Test func markdownToWordToPDF() async throws {
        let dir = try tempDir()
        let md = dir.appendingPathComponent("notes.md")
        try String(repeating: "Some **bold** words in a paragraph that wraps.\n\n", count: 200).write(to: md, atomically: true, encoding: .utf8)
        let docx = try #require(try await run(md, .convert(.docx)).output)
        #expect(FileSignature.detect(url: docx) == .zip)
        let back = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(back.string.contains("Some bold words"))
        let pdf = try #require(try await run(docx, .convert(.pdf)).output)
        let doc = try #require(PDFDocument(url: pdf))
        #expect(doc.pageCount > 1, "long text must paginate")
        #expect(doc.string?.contains("bold words") == true)
    }

    @Test func pdfToolsProduceTheRightPages() async throws {
        let dir = try tempDir()
        var images: [URL] = []
        for i in 0..<3 {
            let u = dir.appendingPathComponent("img\(i).png")
            write(makeImage(width: 300 + i * 10, height: 200), to: u, uti: "public.png")
            images.append(u)
        }
        let merged = try await BatchProcessor(workspace: Workspace(root: dir.appendingPathComponent("ws"))).run(.mergePDF, inputs: images)
        #expect(merged.lastPathComponent == "Combined.pdf")
        #expect(PDFDocument(url: merged)?.pageCount == 3)

        let split = try #require(try await run(merged, .splitPDF).output)
        #expect(try FileManager.default.contentsOfDirectory(atPath: split.path).sorted() == ["page-001.pdf", "page-002.pdf", "page-003.pdf"])
        let extracted = try #require(try await run(merged, .extractPages("2-3")).output)
        #expect(PDFDocument(url: extracted)?.pageCount == 2)
        let pages = try #require(try await run(merged, .exportPages(.png), ProcessingOptions(dpi: 72)).output)
        let first = CGImageSourceCreateWithURL(pages.appendingPathComponent("page-001.png") as CFURL, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(first, 0, nil) as! [CFString: Any]
        #expect(p[kCGImagePropertyPixelWidth] as? Int == 842 || p[kCGImagePropertyPixelWidth] as? Int == 792, "landscape A4/Letter at 72 dpi")
        let long = try #require(try await run(merged, .longImage(.png), ProcessingOptions(dpi: 72)).output)
        let lp = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(long as CFURL, nil)!, 0, nil) as! [CFString: Any]
        #expect((lp[kCGImagePropertyPixelHeight] as? Int ?? 0) >= 3 * 590)
        await #expect(throws: (any Error).self) { _ = try await run(merged, .extractPages("7-9")) }
    }

    @Test func zipContainsEveryInputOnce() async throws {
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.txt"), b = try tempDir().appendingPathComponent("a.txt")
        try "one".write(to: a, atomically: true, encoding: .utf8)
        try "two".write(to: b, atomically: true, encoding: .utf8)
        let zip = try await BatchProcessor(workspace: Workspace(root: dir.appendingPathComponent("ws"))).run(.zip, inputs: [a, b], folder: dir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").sorted()
        #expect(names == ["a 2.txt", "a.txt"])
    }

    @Test func traceProducesValidSVG() throws {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 40, y: 40, width: 120, height: 120))
        let svg = try TraceEngine.trace(ctx.makeImage()!, detail: .balanced)
        #expect(svg.contains("<path") && svg.contains("fill-rule=\"evenodd\""))
        #expect(XMLParser(data: Data(svg.utf8)).parse())
    }

    @Test func icoContainsEverySize() async throws {
        let dir = try tempDir()
        let png = dir.appendingPathComponent("logo.png")
        write(makeImage(width: 300, height: 200, alpha: true), to: png, uti: "public.png")
        let ico = try #require(try await run(png, .convert(.ico), ProcessingOptions(icoSizes: [16, 32, 256])).output)
        let src = try #require(CGImageSourceCreateWithURL(ico as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 3)
    }
}

@Suite(.enabled(if: FFmpegEngine() != nil)) struct VideoPresetTests {
    let engine = FFmpegEngine()!

    func args(_ target: FormatID, _ op: FileOperation? = nil, _ o: ProcessingOptions) -> [String] {
        let r = FileReport(url: URL(fileURLWithPath: "/in.mp4"), byteSize: 1, detectedFormat: .mp4, extensionFormat: .mp4,
                           media: MediaTraits(videoCodec: "h264", audioCodec: "aac"))
        return engine.arguments(StepContext(input: r.url, output: URL(fileURLWithPath: "/out"), source: r, target: target, options: o,
                                            isOptimization: false, operation: op, progress: { _ in }))
    }

    @Test func heightCapDisablesStreamCopy() {
        let a = args(.mp4, nil, ProcessingOptions(maxVideoHeight: 720))
        #expect(!a.contains("copy") || a[a.firstIndex(of: "-c:a")! + 1] == "copy")
        #expect(a.contains { $0.contains("min(720") })
    }

    @Test func av1AndHardwareChoices() {
        if engine.encoders.contains("libsvtav1") { #expect(args(.mp4, nil, ProcessingOptions(videoCodec: .av1)).contains("libsvtav1")) }
        if engine.encoders.contains("h264_videotoolbox") {
            #expect(args(.mp4, nil, ProcessingOptions(videoCodec: .h264, hardwareEncoding: true)).contains("h264_videotoolbox"))
        }
    }

    @Test func mp3BitrateAndFrames() {
        #expect(args(.mp3, nil, ProcessingOptions(mp3Bitrate: 192)).contains("192k"))
        let f = args(.png, .exportPages(.png), ProcessingOptions(frameRate: 2))
        #expect(f.contains("fps=2.0") && f.last!.hasSuffix("frame-%05d.png"))
    }
}

@Suite struct RegressionTests {
    /// A JPEG with no EXIF block (as FFmpeg writes them) must still rotate losslessly.
    @Test(.enabled(if: ffmpeg != nil)) func rotatesJPEGWithoutEXIF() async throws {
        let dir = try tempDir()
        let u = dir.appendingPathComponent("plain.jpg")
        try sh(ffmpeg!, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x200", "-frames:v", "1", u.path])
        let report = await FileAnalyzer().analyze(u)
        let out = dir.appendingPathComponent("o.jpg")
        try await ImageEditEngine().run(StepContext(input: u, output: out, source: report, target: .jpeg, options: .init(),
                                                    isOptimization: false, operation: .edit(.rotateRight), progress: { _ in }))
        #expect(ImageEditEngine.orientation(of: out) == 6)
        // Must be a real EXIF tag that other software reads, not only XMP.
        #expect(ImageEditEngine.hasEXIF([UInt8](try Data(contentsOf: out))))
        func scan(_ url: URL) throws -> [UInt8] {
            let b = [UInt8](try Data(contentsOf: url))
            var i = 2
            while i + 4 <= b.count { if b[i] == 0xFF && b[i + 1] == 0xDA { return Array(b[i...]) }; i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3])) }
            return []
        }
        #expect(try scan(out) == scan(u), "compressed image data must be untouched")
        #expect(try !scan(u).isEmpty)
    }

    /// Text in generated PDFs must stay searchable even for fonts Core Graphics embeds badly.
    @Test func documentPDFKeepsSearchableText() async throws {
        let dir = try tempDir()
        let rtf = dir.appendingPathComponent("light.rtf")
        let s = NSAttributedString(string: "Searchable words here", attributes: [.font: NSFont(name: "Helvetica-Light", size: 13) ?? NSFont.systemFont(ofSize: 13)])
        try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        let r = await FileAnalyzer().analyze(rtf)
        let out = dir.appendingPathComponent("light.pdf")
        try await DocumentEngine().run(StepContext(input: rtf, output: out, source: r, target: .pdf, options: .init(), isOptimization: false, progress: { _ in }))
        #expect(PDFDocument(url: out)?.string?.contains("Searchable words here") == true)
    }
}
