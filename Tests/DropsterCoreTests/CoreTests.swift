import Testing
import Foundation
@testable import DropsterCore

// MARK: - Helpers

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropster-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A configurable engine for exercising orchestration without real codecs.
struct FakeEngine: Engine {
    var id: String
    var edges: [ConversionEdge]
    var optimizable: Set<FormatID> = []
    var maxConcurrency = 8
    var outputSize: @Sendable (StepContext) -> Int = { _ in 10 }
    var delay: Duration = .zero
    var fail = false
    var onRun: (@Sendable () -> Void)?

    func run(_ ctx: StepContext) async throws {
        onRun?()
        if delay > .zero { try await Task.sleep(for: delay) }
        if fail { throw DropsterError.encodeFailed("boom") }
        try Data(repeating: 0x41, count: outputSize(ctx)).write(to: ctx.output)
    }
}

struct AcceptAll: OutputVerifier { func verify(_ url: URL, expected: FormatID) throws {} }

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

// MARK: - Signatures

@Suite struct SignatureTests {
    @Test func detectsCommonFormats() {
        #expect(FileSignature.detect([0xFF, 0xD8, 0xFF, 0xE0]) == .jpeg)
        #expect(FileSignature.detect([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == .png)
        #expect(FileSignature.detect(Array("GIF89a".utf8)) == .gif)
        #expect(FileSignature.detect(Array("RIFF\0\0\0\0WEBPVP8 ".utf8)) == .webp)
        #expect(FileSignature.detect(Array("RIFF\0\0\0\0WAVEfmt ".utf8)) == .wav)
        #expect(FileSignature.detect(Array("%PDF-1.7".utf8)) == .pdf)
        #expect(FileSignature.detect(Array("fLaC".utf8)) == .flac)
        #expect(FileSignature.detect([0x28, 0xB5, 0x2F, 0xFD, 0]) == .zstd)
        #expect(FileSignature.detect([0x50, 0x4B, 0x03, 0x04]) == .zip)
    }

    @Test func distinguishesISOBMFFBrands() {
        func ftyp(_ major: String, _ compat: [String] = []) -> [UInt8] {
            let body = Array("ftyp".utf8) + Array(major.utf8) + [0, 0, 0, 0] + compat.flatMap { Array($0.utf8) }
            let size = UInt32(body.count + 4)
            return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + body
        }
        #expect(FileSignature.detect(ftyp("heic")) == .heic)
        #expect(FileSignature.detect(ftyp("avif")) == .avif)
        #expect(FileSignature.detect(ftyp("mif1", ["mif1", "avif"])) == .avif)
        #expect(FileSignature.detect(ftyp("mif1", ["mif1", "heic"])) == .heic)
        #expect(FileSignature.detect(ftyp("qt  ")) == .mov)
        #expect(FileSignature.detect(ftyp("M4A ")) == .m4a)
        #expect(FileSignature.detect(ftyp("isom")) == .mp4)
    }

    @Test func rejectsGarbageAndTruncatedInput() {
        #expect(FileSignature.detect([]) == nil)
        #expect(FileSignature.detect([0xFF]) == nil)
        #expect(FileSignature.detect(Array("hello world".utf8)) == nil)
        #expect(FileSignature.detect(Array("BM".utf8)) == nil) // too short to be a BMP
    }

    @Test func flagsExtensionMismatch() {
        let r = FileReport(url: URL(fileURLWithPath: "/x/photo.png"), byteSize: 1, detectedFormat: .jpeg, extensionFormat: .png)
        #expect(r.extensionMismatch)
        let ok = FileReport(url: URL(fileURLWithPath: "/x/a.mp4"), byteSize: 1, detectedFormat: .mov, extensionFormat: .mp4)
        #expect(!ok.extensionMismatch)
    }
}

// MARK: - JPEG quality

@Suite struct JPEGQualityTests {
    /// Builds a minimal JPEG header with a DQT table scaled the way libjpeg does.
    static func jpeg(quality q: Int) -> [UInt8] {
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        let table = JPEGQuality.zigzagStandard.map { UInt8(max(1, min(255, ($0 * scale + 50) / 100))) }
        return [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00] + table + [0xFF, 0xDA, 0x00, 0x02]
    }

    @Test(arguments: [30, 50, 75, 85, 90, 95])
    func estimatesLibjpegQuality(q: Int) throws {
        let est = try #require(JPEGQuality.estimate(Self.jpeg(quality: q)))
        #expect(abs(est - q) <= 1)
    }

    @Test func returnsNilWithoutTable() {
        #expect(JPEGQuality.estimate([0xFF, 0xD8, 0xFF, 0xDA, 0, 2]) == nil)
        #expect(JPEGQuality.estimate([0x00, 0x01]) == nil)
    }
}

// MARK: - Routing

@Suite struct RoutingTests {
    let registry = ConversionRegistry(engines: [
        FakeEngine(id: "img", edges: [
            ConversionEdge(from: .heic, to: .png, cost: 1, engineID: "img"),
            ConversionEdge(from: .png, to: .jpeg, cost: 2, engineID: "img"),
            ConversionEdge(from: .heic, to: .jpeg, cost: 2, engineID: "img"),
            ConversionEdge(from: .gif, to: .mp4, cost: 3, engineID: "img"),
            ConversionEdge(from: .png, to: .gif, cost: 1, engineID: "img"),
        ]),
        FakeEngine(id: "webp", edges: [ConversionEdge(from: .png, to: .webp, cost: 2, engineID: "webp")]),
        FakeEngine(id: "media", edges: [ConversionEdge(from: .mp4, to: .mp3, cost: 2, engineID: "media")]),
        FakeEngine(id: "arc", edges: [ConversionEdge(from: .any, to: .zstd, cost: 1, engineID: "arc")]),
    ])

    @Test func prefersDirectCheapestRoute() throws {
        let r = try #require(registry.route(from: .heic, to: .jpeg))
        #expect(r.formats == [.heic, .jpeg])
    }

    @Test func routesThroughLosslessIntermediate() throws {
        let r = try #require(registry.route(from: .heic, to: .webp))
        #expect(r.formats == [.heic, .png, .webp])
        #expect(r.steps.map(\.engineID) == ["img", "webp"])
    }

    @Test func neverChainsAcrossCategories() {
        // png → gif → mp4 → mp3 would be "valid" in a naive graph.
        #expect(registry.route(from: .png, to: .mp4) == nil)
        #expect(registry.route(from: .png, to: .mp3) == nil)
        #expect(registry.route(from: .gif, to: .mp4) != nil)
    }

    @Test func wildcardEdgesApplyToAnySource() throws {
        #expect(try #require(registry.route(from: .heic, to: .zstd)).formats == [.heic, .zstd])
        #expect(registry.route(from: .any, to: .zstd) != nil)
    }

    @Test func noRouteToSelf() { #expect(registry.route(from: .png, to: .png) == nil) }
}

// MARK: - Output planning & safety

@Suite struct OutputPlannerTests {
    @Test func namesOutputsAndAvoidsCollisions() throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: src)
        let a = try OutputPlanner.destination(for: src, target: .jpeg, operation: .optimize, location: .nextToOriginal)
        #expect(a.lastPathComponent == "photo-min.jpg")
        try Data([1]).write(to: a)
        let b = try OutputPlanner.destination(for: src, target: .jpeg, operation: .optimize, location: .nextToOriginal)
        #expect(b.lastPathComponent == "photo-min 2.jpg")
        let reserved = try OutputPlanner.destination(for: src, target: .jpeg, operation: .optimize, location: .nextToOriginal, reserved: [b.path])
        #expect(reserved.lastPathComponent == "photo-min 3.jpg")
        #expect(try OutputPlanner.destination(for: src, target: .webp, operation: .convert(.webp), location: .nextToOriginal).lastPathComponent == "photo.webp")
        #expect(try OutputPlanner.destination(for: src, target: .zstd, operation: .convert(.zstd), location: .nextToOriginal).lastPathComponent == "photo.jpg.zst")
    }

    @Test func sanitizesHostileNames() {
        #expect(OutputPlanner.sanitize("../../etc/passwd") == "etcpasswd")
        #expect(OutputPlanner.sanitize("..") == "file")
        #expect(OutputPlanner.sanitize("a\u{0}b\nc") == "abc")
        #expect(OutputPlanner.sanitize(".hidden") == "hidden")
    }

    @Test func commitNeverOverwrites() throws {
        let dir = try tempDir()
        let temp = dir.appendingPathComponent("t"), dest = dir.appendingPathComponent("d")
        try Data([1]).write(to: temp)
        try Data([2]).write(to: dest)
        #expect(throws: (any Error).self) { try OutputPlanner.commit(temp, to: dest, preservingDatesOf: nil) }
        #expect(try Data(contentsOf: dest) == Data([2]))
    }

    @Test func workspaceIsPrivate() throws {
        let ws = try Workspace(root: try tempDir().appendingPathComponent("ws"))
        let attrs = try FileManager.default.attributesOfItem(atPath: ws.root.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
        let job = try ws.makeJobDirectory()
        ws.remove(job)
        #expect(!FileManager.default.fileExists(atPath: job.path))
        // Refuses to delete outside its root.
        let outside = try tempDir()
        ws.remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

// MARK: - Processing & queue

@Suite struct QueueTests {
    func setup(_ engines: [any Engine]) throws -> (Processor, URL, Workspace) {
        let dir = try tempDir()
        let ws = try Workspace(root: dir.appendingPathComponent("ws"))
        return (Processor(registry: ConversionRegistry(engines: engines), workspace: ws, verifier: AcceptAll()), dir, ws)
    }

    func file(_ dir: URL, _ name: String, size: Int = 100, format: FormatID = .png) throws -> FileReport {
        let u = dir.appendingPathComponent(name)
        try Data(repeating: 7, count: size).write(to: u)
        return FileReport(url: u, byteSize: Int64(size), detectedFormat: format, extensionFormat: format)
    }

    @Test func optimizeKeepsOriginalWhenNotSmaller() async throws {
        let engine = FakeEngine(id: "e", edges: [], optimizable: [.png], outputSize: { _ in 150 })
        let (p, dir, ws) = try setup([engine])
        let r = try file(dir, "a.png")
        let before = try Data(contentsOf: r.url)
        let dest = dir.appendingPathComponent("a-min.png")
        let res = try await p.process(r, operation: .optimize, options: .init(), destination: dest) { _ in }
        #expect(res.outcome == .keptOriginal)
        #expect(res.producedBytes == 150)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: r.url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ws.root.path).isEmpty)
    }

    @Test func multiHopRouteWritesFinalOutput() async throws {
        let a = FakeEngine(id: "a", edges: [ConversionEdge(from: .heic, to: .png, cost: 1, engineID: "a")])
        let b = FakeEngine(id: "b", edges: [ConversionEdge(from: .png, to: .webp, cost: 1, engineID: "b")], outputSize: { _ in 42 })
        let (p, dir, _) = try setup([a, b])
        let r = try file(dir, "x.heic", format: .heic)
        let dest = dir.appendingPathComponent("x.webp")
        let res = try await p.process(r, operation: .convert(.webp), options: .init(), destination: dest) { _ in }
        #expect(res.route == [.heic, .png, .webp])
        #expect(try Data(contentsOf: dest).count == 42)
    }

    @Test func failuresDoNotStopTheBatchAndRetryWorks() async throws {
        let good = FakeEngine(id: "good", edges: [ConversionEdge(from: .png, to: .webp, cost: 1, engineID: "good")], outputSize: { _ in 5 })
        let bad = FakeEngine(id: "bad", edges: [ConversionEdge(from: .jpeg, to: .webp, cost: 1, engineID: "bad")], fail: true)
        let (p, dir, ws) = try setup([good, bad])
        let q = JobQueue(processor: p, maxParallel: 4)
        var ids: [JobID] = []
        for i in 0..<6 {
            let r = try file(dir, "f\(i).\(i == 2 ? "jpg" : "png")", format: i == 2 ? .jpeg : .png)
            ids.append(await q.enqueue(Job(report: r, operation: .convert(.webp), options: .init())))
        }
        await q.waitUntilIdle()
        let jobs = await q.allJobs
        #expect(jobs.filter { if case .done = $0.state { true } else { false } }.count == 5)
        guard case .failed = await q.job(ids[2])!.state else { Issue.record("expected failure"); return }
        await q.retry(ids[2])
        await q.waitUntilIdle()
        guard case .failed = await q.job(ids[2])!.state else { Issue.record("expected failure again"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: ws.root.path).isEmpty)
    }

    @Test func respectsPerEngineConcurrency() async throws {
        let counter = Counter()
        struct Slow: Engine {
            let id = "slow"; let maxConcurrency = 2
            let edges = [ConversionEdge(from: .png, to: .webp, cost: 1, engineID: "slow")]
            let optimizable: Set<FormatID> = []
            let counter: Counter
            func run(_ ctx: StepContext) async throws {
                counter.enter(); defer { counter.leave() }
                try await Task.sleep(for: .milliseconds(40))
                try Data([1]).write(to: ctx.output)
            }
        }
        let (p, dir, _) = try setup([Slow(counter: counter)])
        let q = JobQueue(processor: p, maxParallel: 8)
        for i in 0..<8 { await q.enqueue(Job(report: try file(dir, "s\(i).png"), operation: .convert(.webp), options: .init())) }
        await q.waitUntilIdle()
        #expect(counter.peak == 2)
    }

    @Test func cancelStopsRunningJobAndCleansUp() async throws {
        let slow = FakeEngine(id: "s", edges: [ConversionEdge(from: .png, to: .webp, cost: 1, engineID: "s")], delay: .seconds(5))
        let (p, dir, ws) = try setup([slow])
        let q = JobQueue(processor: p, maxParallel: 2)
        let r = try file(dir, "c.png")
        let id = await q.enqueue(Job(report: r, operation: .convert(.webp), options: .init()))
        try await Task.sleep(for: .milliseconds(50))
        await q.cancel(id)
        await q.waitUntilIdle()
        #expect(await q.job(id)!.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.webp").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: ws.root.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: r.url.path))
    }

    @Test func pauseHoldsQueuedJobsUntilResume() async throws {
        let e = FakeEngine(id: "e", edges: [ConversionEdge(from: .png, to: .webp, cost: 1, engineID: "e")])
        let (p, dir, _) = try setup([e])
        let q = JobQueue(processor: p, maxParallel: 2)
        await q.pause()
        let id = await q.enqueue(Job(report: try file(dir, "p.png"), operation: .convert(.webp), options: .init()))
        await q.pause()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await q.job(id)!.state == .paused)
        await q.resume()
        await q.waitUntilIdle()
        guard case .done = await q.job(id)!.state else { Issue.record("expected done"); return }
    }

    @Test func eventsStreamReportsCompletion() async throws {
        let e = FakeEngine(id: "e", edges: [ConversionEdge(from: .png, to: .webp, cost: 1, engineID: "e")])
        let (p, dir, _) = try setup([e])
        let q = JobQueue(processor: p)
        let stream = await q.events()
        await q.enqueue(Job(report: try file(dir, "e.png"), operation: .convert(.webp), options: .init()))
        var sawDone = false
        for await case .updated(let job) in stream {
            if case .done = job.state { sawDone = true; break }
        }
        #expect(sawDone)
    }
}

// MARK: - Advisor & history

@Suite struct AdvisorTests {
    func image(_ f: FormatID, alpha: Bool = false, gps: Bool = false, q: Int? = nil, frames: Int = 1) -> FileReport {
        var r = FileReport(url: URL(fileURLWithPath: "/a"), byteSize: 1000, detectedFormat: f, extensionFormat: f)
        r.image = ImageTraits(width: 2000, height: 1000, hasAlpha: alpha, bitsPerComponent: 8, colorModel: "RGB", colorProfile: nil,
                              frameCount: frames, orientation: 1, hasEXIF: gps, hasGPS: gps, estimatedJPEGQuality: q)
        return r
    }

    @Test func recommendsPrivacyCleaningForGPS() {
        let recs = Advisor.recommendations(for: image(.jpeg, gps: true, q: 92), available: [.heic])
        #expect(recs.contains { $0.kind == .privacy && $0.operation == .stripMetadata })
        #expect(recs.contains { $0.operation == .optimize })
    }

    @Test func defaultOperations() {
        #expect(Advisor.defaultOperation(for: image(.bmp), optimizable: []) == .convert(.png))
        #expect(Advisor.defaultOperation(for: image(.png), optimizable: [.png]) == .optimize)
        #expect(Advisor.defaultOperation(for: image(.gif, frames: 20), optimizable: [.mp4]) == .convert(.mp4))
    }
}

@Suite struct HistoryTests {
    @Test func recordsAndTotals() throws {
        let store = try HistoryStore(url: try tempDir().appendingPathComponent("h.sqlite"))
        let r = ProcessingResult(outcome: .written, output: URL(fileURLWithPath: "/o"), inputBytes: 1000, producedBytes: 400, duration: 0.5, route: [.png])
        store.record(source: URL(fileURLWithPath: "/i"), operation: .optimize, result: r)
        store.record(source: URL(fileURLWithPath: "/j"), operation: .optimize,
                     result: ProcessingResult(outcome: .keptOriginal, output: nil, inputBytes: 10, producedBytes: 20, duration: 0, route: []))
        #expect(store.recent().count == 2)
        #expect(store.totals() == HistoryTotals(files: 1, savedBytes: 600))
        store.clear()
        #expect(store.recent().isEmpty)
    }
}

@Suite struct NamingTests {
    @Test func templatesAndFolders() throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("trip.jpg")
        try Data([1]).write(to: src)
        #expect(try OutputPlanner.destination(for: src, target: .webp, operation: .convert(.webp), location: .nextToOriginal,
                                              template: "{name}-{action}").lastPathComponent == "trip-webp.webp")
        #expect(try OutputPlanner.destination(for: src, target: .jpeg, operation: .edit(.rotateRight), location: .nextToOriginal)
                    .lastPathComponent == "trip-edited.jpg")
        let pdf = dir.appendingPathComponent("report.pdf")
        let folder = try OutputPlanner.destination(for: pdf, target: .png, operation: .exportPages(.png), location: .nextToOriginal)
        #expect(folder.lastPathComponent == "report pages" && folder.pathExtension.isEmpty)
        // A template can't escape the folder.
        let evil = try OutputPlanner.destination(for: src, target: .png, operation: .convert(.png), location: .nextToOriginal, template: "../../{name}")
        #expect(evil.deletingLastPathComponent().path == dir.path)
        #expect(OutputPlanner.unique("x.pdf", in: dir).lastPathComponent == "x.pdf")
    }

    @Test func optionsDecodeFromOlderPresets() throws {
        let old = #"{"mode":"smallest","metadata":"keep","output":{"nextToOriginal":{}},"discardLargerConversions":false}"#
        let o = try JSONDecoder().decode(ProcessingOptions.self, from: Data(old.utf8))
        #expect(o.mode == .smallest && o.keepFileDates && o.icoSizes.count == 6)
    }
}

@Suite struct CloverLayoutTests {
    let layout = CloverLayout()

    @Test func coreAndLeavesByQuadrant() {
        #expect(layout.hitTest(.zero, expandedLeaf: nil, leafletCount: 0) == .core)
        #expect(layout.hitTest(CGPoint(x: -50, y: -50), expandedLeaf: nil, leafletCount: 0) == .leaf(0))
        #expect(layout.hitTest(CGPoint(x: 50, y: -50), expandedLeaf: nil, leafletCount: 0) == .leaf(1))
        #expect(layout.hitTest(CGPoint(x: 50, y: 50), expandedLeaf: nil, leafletCount: 0) == .leaf(2))
        #expect(layout.hitTest(CGPoint(x: -50, y: 50), expandedLeaf: nil, leafletCount: 0) == .leaf(3))
        #expect(layout.hitTest(CGPoint(x: 300, y: 0), expandedLeaf: nil, leafletCount: 0) == nil)
    }

    @Test func leafletsFanAroundTheirLeafWithoutOverlap() {
        for leaf in 0..<4 {
            let centers = layout.leafletCenters(leaf: leaf, count: 6)
            for (k, c) in centers.enumerated() {
                #expect(layout.hitTest(c, expandedLeaf: leaf, leafletCount: 6) == .leaflet(leaf: leaf, index: k))
                if k > 0 {
                    let prev = centers[k - 1]
                    #expect(hypot(c.x - prev.x, c.y - prev.y) >= 2 * layout.leafletRadius)
                }
                #expect(hypot(c.x, c.y) + layout.leafletRadius <= layout.extent)
            }
        }
        // Leaflets are only hit for the expanded leaf.
        let c = layout.leafletCenters(leaf: 1, count: 3)[0]
        #expect(layout.hitTest(c, expandedLeaf: nil, leafletCount: 3) == nil)
    }
}

@Suite struct PresetTests {
    @Test func persistsAndRestores() throws {
        let url = try tempDir().appendingPathComponent("p.json")
        let store = PresetStore(url: url)
        #expect(store.all.count == Preset.builtIns.count)
        let custom = Preset(name: "Tiny", category: .image, operation: .convert(.avif), options: ProcessingOptions(maxPixelSize: 640))
        store.save(custom)
        store.delete(Preset.builtIns[0].id)
        let reloaded = PresetStore(url: url)
        #expect(reloaded.all.contains(custom))
        #expect(!reloaded.all.contains { $0.id == Preset.builtIns[0].id })
        reloaded.restoreBuiltIns()
        #expect(reloaded.presets(for: .image).count == Preset.builtIns.filter { $0.category == .image }.count + 1)
    }
}
