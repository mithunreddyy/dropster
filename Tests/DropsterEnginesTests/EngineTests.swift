import Testing
import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
@testable import DropsterCore
@testable import DropsterEngines

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropster-etests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

let ffmpeg = ToolLocator.find("ffmpeg")

@discardableResult
func sh(_ tool: URL, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = tool
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

/// Draws a test pattern with gradients, flat regions and optional transparency.
func makeImage(width: Int = 256, height: Int = 160, alpha: Bool = false, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    for x in stride(from: 0, to: width, by: 4) {
        ctx.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 1 - CGFloat(x) / CGFloat(width), alpha: alpha ? 0.6 : 1))
        ctx.fill(CGRect(x: x, y: 0, width: 4, height: height / 2))
    }
    ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: width / 2, height: height / 2))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL, uti: String, props: [CFString: Any] = [:]) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, props as CFDictionary)
    CGImageDestinationFinalize(d)
}

// MARK: - PNG

@Suite struct PNGOptimizerTests {
    /// Every PNG colour type and bit depth, produced by an independent encoder (FFmpeg).
    static let pixelFormats = ["rgb24", "rgba", "gray", "gray16be", "ya8", "pal8", "monob", "rgb48be", "rgba64be"]

    @Test(.enabled(if: ffmpeg != nil), arguments: pixelFormats)
    func losslessAcrossColorTypes(pixFmt: String) throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("\(pixFmt).png")
        let filter = pixFmt == "monob" ? "format=gray,lutyuv=y='if(gt(val,128),255,0)'" : "null"
        let status = try sh(ffmpeg!, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=173x91", "-frames:v", "1",
                                      "-vf", filter, "-pix_fmt", pixFmt, "-compression_level", "0", src.path])
        try #require(status == 0)
        let input = try [UInt8](Data(contentsOf: src))
        for mode in CompressionMode.allCases {
            let out = try PNGOptimizer.optimize(input, mode: mode, metadata: .removeAll)
            #expect(try PNGCodec.decode(out).pixels.canonicalRGBA16() == PNGCodec.decode(input).pixels.canonicalRGBA16())
            #expect(out.count < input.count, "uncompressed input must shrink (\(pixFmt), \(mode))")
            // An independent decoder must agree the result is a valid image.
            let u = dir.appendingPathComponent("out-\(mode).png")
            try Data(out).write(to: u)
            let srcImg = CGImageSourceCreateWithURL(u as CFURL, nil)
            #expect(srcImg.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil)
        }
    }

    @Test func reducesLayouts() {
        // Opaque RGBA with only grays → 1 channel.
        let px = PNGPixels(width: 2, height: 1, channels: 4, depth: 8, data: [10, 10, 10, 255, 200, 200, 200, 255])
        let r = PNGOptimizer.reduce(px)
        #expect(r.channels == 1 && r.data == [10, 200])
        // 16-bit samples that are repeated bytes → 8-bit.
        let px16 = PNGPixels(width: 1, height: 1, channels: 3, depth: 16, data: [5, 5, 6, 6, 7, 7])
        #expect(PNGOptimizer.reduce(px16).depth == 8)
        // Two-colour image becomes a 1-bit palette.
        let two = PNGPixels(width: 4, height: 1, channels: 3, depth: 8, data: [255, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0, 255])
        guard case .palette(let depth, let entries)? = PNGOptimizer.paletteEncoding(for: two)?.layout else { Issue.record("no palette"); return }
        #expect(depth == 1 && entries.count == 2)
        // Black/white gray packs to 1 bit.
        guard case .gray(1) = PNGOptimizer.encoding(for: PNGPixels(width: 3, height: 1, channels: 1, depth: 8, data: [0, 255, 0])).layout else {
            Issue.record("expected 1-bit gray"); return
        }
    }

    @Test func handlesInterlacedInput() throws {
        let dir = try tempDir()
        let u = dir.appendingPathComponent("i.png")
        write(makeImage(alpha: true), to: u, uti: "public.png",
              props: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 1]])
        let input = try [UInt8](Data(contentsOf: u))
        #expect(try PNGCodec.decode(input).interlaced)
        let out = try PNGOptimizer.optimize(input, mode: .balanced, metadata: .keep)
        #expect(try !PNGCodec.decode(out).interlaced)
        #expect(try PNGCodec.decode(out).pixels.canonicalRGBA16() == PNGCodec.decode(input).pixels.canonicalRGBA16())
    }

    @Test func metadataPolicyAppliesToChunks() {
        let chunks = [PNGChunk(type: "iCCP", data: [1]), PNGChunk(type: "eXIf", data: [2]), PNGChunk(type: "tEXt", data: [3]),
                      PNGChunk(type: "iTXt", data: Array("XML:com.adobe.xmp\0".utf8)), PNGChunk(type: "bKGD", data: [0])]
        #expect(PNGOptimizer.keepChunks(chunks, policy: .removeAll).map(\.type) == ["iCCP"])
        #expect(PNGOptimizer.keepChunks(chunks, policy: .removePrivate).map(\.type) == ["iCCP", "tEXt"])
        #expect(PNGOptimizer.keepChunks(chunks, policy: .keep).map(\.type) == ["iCCP", "eXIf", "tEXt", "iTXt"])
    }

    @Test func rejectsMalformedInputWithoutCrashing() throws {
        let dir = try tempDir()
        let u = dir.appendingPathComponent("m.png")
        write(makeImage(width: 64, height: 64), to: u, uti: "public.png")
        let good = try [UInt8](Data(contentsOf: u))
        #expect(throws: (any Error).self) { try PNGCodec.decode(Array(good.prefix(good.count / 2))) }
        var badCRC = good
        badCRC[30] ^= 0xFF
        #expect(throws: (any Error).self) { try PNGCodec.decode(badCRC) }
        // Huge declared dimensions must be refused before allocation.
        var huge = good
        huge[16] = 0x7F; huge[20] = 0x7F
        #expect(throws: (any Error).self) { try PNGCodec.decode(huge) }
        // Random corruption: every outcome must be a clean success or a thrown error.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var b = good
            for _ in 0..<4 { b[Int.random(in: 8..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? PNGOptimizer.optimize(b, mode: .fastest, metadata: .keep)
        }
    }

    @Test func parallelDeflateProducesValidZlibStream() throws {
        // 5 MB of semi-compressible data crosses several 1 MB blocks.
        var data = [UInt8](repeating: 0, count: 5 * 1024 * 1024 + 123)
        var x: UInt32 = 2463534242
        for i in data.indices { x ^= x << 13; x ^= x >> 17; x ^= x << 5; data[i] = i % 7 == 0 ? UInt8(x & 0x0F) : UInt8(i / 4096 & 0xFF) }
        let z = try #require(PNGOptimizer.parallelDeflate(data, level: 9, strategy: 0))
        let serial = try #require(PNGOptimizer.serialDeflate(data, level: 9, strategy: 0))
        #expect(try PNGCodec.inflate(z, expected: data.count) == data)
        // Block splitting costs at most a few percent of ratio.
        #expect(Double(z.count) < Double(serial.count) * 1.03)
    }

    @Test func refusesAnimatedPNG() {
        var b = PNGCodec.signature
        func chunk(_ t: String, _ d: [UInt8]) {
            let tb = Array(t.utf8)
            b += [UInt8(d.count >> 24), UInt8(d.count >> 16 & 0xFF), UInt8(d.count >> 8 & 0xFF), UInt8(d.count & 0xFF)] + tb + d
            var c = crc32Bytes(tb + d)
            b += [UInt8(c >> 24), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)]
            c = 0
        }
        chunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0])
        chunk("acTL", [0, 0, 0, 1, 0, 0, 0, 0])
        #expect(throws: PNGError.self) { try PNGCodec.decode(b) }
    }
}

func crc32Bytes(_ d: [UInt8]) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; table[i] = c }
    var c: UInt32 = 0xFFFFFFFF
    for x in d { c = table[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

// MARK: - JPEG

@Suite struct JPEGTests {
    func photoWithMetadata(_ dir: URL, orientation: Int = 6) -> URL {
        let u = dir.appendingPathComponent("p.jpg")
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SN123", kCGImagePropertyExifLensModel: "Test Lens"],
        ]
        write(makeImage(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!), to: u, uti: "public.jpeg", props: props)
        return u
    }

    func props(_ u: URL) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil) as! [CFString: Any]
    }

    func scan(_ b: [UInt8]) -> [UInt8] {
        // Bytes from the SOS marker to the end.
        var i = 2
        while i + 4 <= b.count { if b[i] == 0xFF && b[i + 1] == 0xDA { return Array(b[i...]) }; i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3])) }
        return []
    }

    @Test func stripIsLosslessAndKeepsOrientationAndProfile() throws {
        let dir = try tempDir()
        let u = photoWithMetadata(dir)
        let input = try [UInt8](Data(contentsOf: u))
        let out = try JPEGMetadata.strip(input, orientation: 6)
        #expect(scan(out) == scan(input))
        let o = dir.appendingPathComponent("o.jpg")
        try Data(out).write(to: o)
        let p = props(o)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(p[kCGImagePropertyOrientation] as? Int == 6)
        #expect((p[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)
    }

    @Test func qscaleRespectsQualityCeiling() {
        #expect(JPEGEngine.qscale(mode: .balanced, qualityOverride: nil, sourceQuality: 95) == 3)
        #expect(JPEGEngine.qscale(mode: .balanced, qualityOverride: nil, sourceQuality: 70) == 7)
        #expect(JPEGEngine.qscale(mode: .smallest, qualityOverride: nil, sourceQuality: nil) == 5)
        #expect(JPEGEngine.qscale(mode: .balanced, qualityOverride: 1.0, sourceQuality: nil) == 2)
    }

    @Test(.enabled(if: JPEGEngine() != nil))
    func optimizeKeepsProfileOrientationAndRespectsPrivacy() async throws {
        let dir = try tempDir()
        let u = photoWithMetadata(dir)
        let analyzer = FileAnalyzer()
        let report = await analyzer.analyze(u)
        let out = dir.appendingPathComponent("o.jpg")
        let ctx = StepContext(input: u, output: out, source: report, target: .jpeg, options: ProcessingOptions(metadata: .removePrivate),
                              isOptimization: true, progress: { _ in })
        try await JPEGEngine()!.run(ctx)
        let p = props(out)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect(p[kCGImagePropertyOrientation] as? Int == 6)
        #expect((p[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)
        #expect(((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] as? String) == "Test Lens")
    }
}

// MARK: - FFmpeg arguments

@Suite(.enabled(if: FFmpegEngine() != nil)) struct FFmpegArgumentTests {
    let engine = FFmpegEngine()!

    func ctx(_ target: FormatID, media: MediaTraits, optimize: Bool = false, source: FormatID = .mov) -> StepContext {
        let r = FileReport(url: URL(fileURLWithPath: "/in.mov"), byteSize: 1, detectedFormat: source, extensionFormat: source, media: media)
        return StepContext(input: r.url, output: URL(fileURLWithPath: "/out"), source: r, target: target,
                           options: ProcessingOptions(metadata: .removeAll), isOptimization: optimize, progress: { _ in })
    }

    @Test func remuxesWhenCodecsFit() {
        let a = engine.arguments(ctx(.mp4, media: MediaTraits(videoCodec: "h264", audioCodec: "aac")))
        #expect(a.contains("copy") && !a.contains("libx264"))
        #expect(a.contains("+faststart"))
    }

    @Test func optimizeUsesHEVCWithAppleTag() {
        let a = engine.arguments(ctx(.mp4, media: MediaTraits(videoCodec: "h264", audioCodec: "aac"), optimize: true))
        #expect(a.contains("hvc1"))
        #expect(!a.contains("-c") || a[a.firstIndex(of: "-c")! + 1] != "copy")
    }

    @Test func stripsAllMetadataWhenAsked() {
        let a = engine.arguments(ctx(.mp3, media: MediaTraits(audioCodec: "pcm_s16le")))
        #expect(a.contains("-map_metadata") && a[a.firstIndex(of: "-map_metadata")! + 1] == "-1")
        #expect(a.contains("libmp3lame") && a.contains("-vn"))
    }

    @Test func gifUsesGeneratedPalette() {
        let a = engine.arguments(ctx(.gif, media: MediaTraits(videoCodec: "h264")))
        #expect(a.contains { $0.contains("palettegen") && $0.contains("paletteuse") })
    }
}

// MARK: - End to end with real codecs

@Suite(.serialized) struct IntegrationTests {
    let processor = try! Engines.makeProcessor(workspace: Workspace(root: try! tempDir().appendingPathComponent("ws")))

    func run(_ url: URL, _ op: FileOperation, _ options: ProcessingOptions = .init()) async throws -> ProcessingResult {
        let r = await FileAnalyzer().analyze(url)
        let target: FormatID = if case .convert(let f) = op { f } else { r.format! }
        let dest = try OutputPlanner.destination(for: url, target: target, operation: op, location: .nextToOriginal)
        return try await processor.process(r, operation: op, options: options, destination: dest) { _ in }
    }

    @Test(.enabled(if: ffmpeg != nil)) func wavToFlacIsBitExact() async throws {
        let dir = try tempDir()
        let wav = dir.appendingPathComponent("t.wav")
        try sh(ffmpeg!, ["-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=330:duration=2", "-ar", "48000", wav.path])
        let before = try sha(wav)
        let res = try await run(wav, .convert(.flac))
        #expect(res.outcome == .written && res.savedFraction > 0.3)
        func pcmHash(_ u: URL) throws -> String {
            let o = dir.appendingPathComponent(UUID().uuidString + ".raw")
            try sh(ffmpeg!, ["-loglevel", "error", "-i", u.path, "-f", "s16le", o.path])
            return try sha(o)
        }
        #expect(try pcmHash(wav) == pcmHash(res.output!))
        #expect(try sha(wav) == before, "original must be untouched")
    }

    @Test func pngConversionAndOptimizeAreLossless() async throws {
        let dir = try tempDir()
        let tiff = dir.appendingPathComponent("a.tiff")
        write(makeImage(alpha: true), to: tiff, uti: "public.tiff")
        let res = try await run(tiff, .convert(.png))
        let png = try #require(res.output)
        func pixels(_ u: URL) -> Data {
            let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil)!
            let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return Data(bytes: ctx.data!, count: img.width * img.height * 4)
        }
        #expect(pixels(png) == pixels(tiff))
        let opt = try await run(png, .optimize)
        if opt.outcome == .written { #expect(pixels(opt.output!) == pixels(png)) }
    }

    @Test(.enabled(if: WebPEngine() != nil)) func heicToWebPRoutesThroughPNG() async throws {
        let dir = try tempDir()
        let heic = dir.appendingPathComponent("a.heic")
        write(makeImage(width: 640, height: 400), to: heic, uti: "public.heic", props: [kCGImageDestinationLossyCompressionQuality: 0.9])
        let res = try await run(heic, .convert(.webp))
        #expect(res.route == [.heic, .png, .webp])
        #expect(FileSignature.detect(url: res.output!) == .webp)
    }

    @Test func archiveRoundTrips() async throws {
        guard let zstd = ToolLocator.find("zstd") else { return }
        let dir = try tempDir()
        let txt = dir.appendingPathComponent("log.txt")
        try String(repeating: "dropster line of text 12345\n", count: 20_000).write(to: txt, atomically: true, encoding: .utf8)
        let res = try await run(txt, .convert(.zstd))
        #expect(res.savedFraction > 0.9)
        let back = dir.appendingPathComponent("back.txt")
        try sh(zstd, ["-q", "-d", res.output!.path, "-o", back.path])
        #expect(try sha(back) == sha(txt))
    }

    @Test func corruptInputFailsWithoutSideEffects() async throws {
        let dir = try tempDir()
        let bad = dir.appendingPathComponent("broken.png")
        try Data(PNGCodec.signature + [0, 0, 0, 13] + Array("IHDR".utf8) + [1, 2, 3]).write(to: bad)
        let before = try sha(bad)
        await #expect(throws: (any Error).self) { _ = try await run(bad, .optimize) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["broken.png"])
        #expect(try sha(bad) == before)
    }

    @Test func verifierRejectsMislabelledOutput() throws {
        let dir = try tempDir()
        let u = dir.appendingPathComponent("x.jpg")
        try Data("not an image".utf8).write(to: u)
        #expect(throws: DropsterError.self) { try DefaultVerifier().verify(u, expected: .jpeg) }
    }
}
