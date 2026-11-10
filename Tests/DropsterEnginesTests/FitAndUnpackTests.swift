import Testing
import Foundation
import ImageIO
@testable import DropsterCore
@testable import DropsterEngines

private func process(_ processor: Processor, _ url: URL, _ op: FileOperation, _ options: ProcessingOptions = .init()) async throws -> ProcessingResult {
    let r = await FileAnalyzer().analyze(url)
    let target = op.outputFormat(source: r.format!)
    let dest = try OutputPlanner.destination(for: url, target: target, operation: op, location: .nextToOriginal)
    return try await processor.process(r, operation: op, options: options, destination: dest) { _ in }
}

private func size(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }

@Suite(.serialized) struct FitSizeTests {
    let processor = try! Engines.makeProcessor(workspace: Workspace(root: try! tempDir().appendingPathComponent("ws")))

    @Test func imageFitsUnderTheLimitAndScalesWhenItMust() async throws {
        let dir = try tempDir()
        let png = dir.appendingPathComponent("noise.png")
        // Random pixels barely compress, so 120 KB forces both a quality search and a downscale.
        var rng = SystemRandomNumberGenerator()
        let w = 1600, h = 1200
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = rng.next(); px[i + 1] = rng.next(); px[i + 2] = rng.next() }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        write(ctx.makeImage()!, to: png, uti: "public.png")
        let r = try await process(processor, png, .fitSize(120_000))
        let out = try #require(r.output)
        #expect(out.pathExtension == "jpg")
        #expect(size(out) <= 120_000)
        #expect(size(out) > 60_000, "the search should use most of the budget, not undershoot wildly")
        let src = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyPixelWidth] as? Int ?? 0) < w, "noise can't fit at full size")
    }

    @Test func fileAlreadyUnderTheLimitIsLeftAlone() async throws {
        let dir = try tempDir()
        let png = dir.appendingPathComponent("small.png")
        write(makeImage(), to: png, uti: "public.png")
        let r = try await process(processor, png, .fitSize(10_000_000))
        #expect(r.outcome == .keptOriginal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["small.png"])
    }

    @Test func videoPlanRespectsTheBudget() throws {
        let plan = try #require(FitSizeEngine.planVideo(limit: 10_000_000, duration: 60, width: 3840, height: 2160, frameRate: 60, hasAudio: true))
        let kbps = Double(plan.videoKbps + plan.audioKbps)
        #expect(kbps * 60 / 8 * 1000 <= 10_000_000)
        #expect(plan.height != nil && plan.height! < 2160, "1.3 Mb/s can't carry 4K")
        #expect(plan.capFrameRate || plan.height! <= 720)
        // A short clip with lots of budget keeps its resolution.
        let roomy = try #require(FitSizeEngine.planVideo(limit: 100_000_000, duration: 10, width: 1920, height: 1080, frameRate: 30, hasAudio: false))
        #expect(roomy.height == nil && roomy.audioKbps == 0 && !roomy.capFrameRate)
        // Impossible budgets are refused instead of producing mush.
        #expect(FitSizeEngine.planVideo(limit: 100_000, duration: 600, width: 1920, height: 1080, frameRate: 30, hasAudio: true) == nil)
        #expect(FitSizeEngine.audioBitrate(limit: 1_000_000, duration: 120, target: .mp3) == 64)
    }

    @Test(.enabled(if: ffmpeg != nil)) func videoAndAudioFit() async throws {
        let dir = try tempDir()
        let mp4 = dir.appendingPathComponent("clip.mp4")
        try sh(ffmpeg!, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=frequency=440",
                         "-t", "8", "-c:v", "libx264", "-crf", "8", "-c:a", "aac", "-b:a", "256k", mp4.path])
        let v = try await process(processor, mp4, .fitSize(800_000))
        #expect(size(try #require(v.output)) <= 800_000)
        let wav = dir.appendingPathComponent("tone.wav")
        try sh(ffmpeg!, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "30", "-c:a", "pcm_s16le", wav.path])
        let a = try await process(processor, wav, .fitSize(300_000))
        let out = try #require(a.output)
        #expect(out.pathExtension == "m4a" && size(out) <= 300_000)
    }
}

@Suite(.serialized) struct UnpackTests {
    let processor = try! Engines.makeProcessor(workspace: Workspace(root: try! tempDir().appendingPathComponent("ws")))
    let zipTool = URL(fileURLWithPath: "/usr/bin/zip")
    let python = URL(fileURLWithPath: "/usr/bin/python3")

    func evilZip(_ dir: URL, entry: String) throws -> URL {
        let url = dir.appendingPathComponent("evil-\(UUID().uuidString.prefix(4)).zip")
        try sh(python, ["-I", "-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr(sys.argv[2],'x'); z.close()", url.path, entry])
        return url
    }

    @Test func unpacksNestedFoldersAndHoistsASingleTopFolder() async throws {
        let dir = try tempDir()
        let tree = dir.appendingPathComponent("tree/album/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try "one".write(to: tree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: tree.deletingLastPathComponent().appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("photos.zip")
        let p = Process()
        p.executableURL = zipTool
        p.currentDirectoryURL = dir.appendingPathComponent("tree")
        p.arguments = ["-qr", zip.path, "album"]
        try p.run(); p.waitUntilExit()
        let r = try await process(processor, zip, .unpack)
        let out = try #require(r.output)
        #expect(out.lastPathComponent == "album", "a single top-level folder is unpacked as itself, not nested")
        #expect(try String(contentsOf: out.appendingPathComponent("inner/a.txt"), encoding: .utf8) == "one")
        #expect(try String(contentsOf: out.appendingPathComponent("b.txt"), encoding: .utf8) == "two")
    }

    @Test(arguments: ["../../escape.txt", "/tmp/dropster-abs-escape.txt", "a/../../escape.txt"])
    func refusesEntriesThatEscape(_ entry: String) async throws {
        let dir = try tempDir().appendingPathComponent("deep/er", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = try evilZip(dir, entry: entry)
        await #expect(throws: DropsterError.self) { try await process(processor, zip, .unpack) }
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("escape.txt").path))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/dropster-abs-escape.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1, "nothing is written next to the archive")
    }

    @Test func stopsAnArchiveThatExpandsPastTheLimit() async throws {
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("bomb.zip")
        // 64 MB of zeros compresses to ~64 KB; the engine is limited to 8 MB here.
        try sh(python, ["-I", "-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w',zipfile.ZIP_DEFLATED); z.writestr('zeros.bin', bytes(64*1024*1024)); z.close()", zip.path])
        let engine = UnpackEngine(limitOverride: 8_000_000)
        let report = await FileAnalyzer().analyze(zip)
        let out = dir.appendingPathComponent("work/result", isDirectory: true)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = StepContext(input: zip, output: out, source: report, target: .any, options: .init(), isOptimization: false, operation: .unpack) { _ in }
        await #expect(throws: DropsterError.self) { try await engine.run(ctx) }
    }

    @Test func singleStreamsAndListing() async throws {
        let dir = try tempDir()
        let txt = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        let gz = dir.appendingPathComponent("notes.txt.gz")
        try sh(URL(fileURLWithPath: "/usr/bin/gzip"), ["-k", txt.path])
        try FileManager.default.removeItem(at: txt)
        let r = try await process(processor, gz, .unpack)
        #expect(try #require(r.output).lastPathComponent == "notes.txt")
        #expect(try String(contentsOf: r.output!, encoding: .utf8) == "hello")
        let listed = try await UnpackEngine().list(gz, format: .gzip)
        #expect(listed.map(\.path) == ["notes.txt"])
        #expect(UnpackEngine.problem(with: "ok/file.txt") == nil)
        #expect(UnpackEngine.problem(with: "../x") != nil)
        #expect(UnpackEngine.problem(with: "/etc/x") != nil)
        #expect(UnpackEngine.problem(with: "bad\nname") != nil)
    }
}
