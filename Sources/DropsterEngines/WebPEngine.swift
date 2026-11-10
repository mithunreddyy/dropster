import Foundation
import DropsterCore

/// libwebp's reference encoder. ImageIO can read WebP but not write it.
public struct WebPEngine: Engine {
    public let id = "cwebp"
    public let maxConcurrency: Int
    public let edges: [ConversionEdge]
    public let optimizable: Set<FormatID> = [.webp]
    let tool: URL

    public init?(tool: URL? = ToolLocator.find("cwebp")) {
        guard let tool else { return nil }
        self.tool = tool
        // cwebp -mt uses a couple of threads per file.
        maxConcurrency = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        edges = [FormatID.png, .jpeg, .tiff].map { ConversionEdge(from: $0, to: .webp, cost: 2, engineID: "cwebp") }
    }

    static func quality(_ mode: CompressionMode) -> Int {
        // q88 ≈ SSIM 0.96–0.975 on photos; q80 ≈ 0.95 (docs/BENCHMARKS.md).
        switch mode { case .smallest: 80; case .balanced: 88; case .fastest: 88 }
    }

    public func run(_ ctx: StepContext) async throws {
        var input = ctx.input
        let needsPrep = (ctx.source.image?.orientation ?? 1) != 1 || ctx.options.maxPixelSize != nil
        if needsPrep {
            input = ctx.output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
            try ImageIOEngine.renderUprightPNG(ctx.input, to: input, maxPixelSize: ctx.options.maxPixelSize)
        }
        defer { if needsPrep { try? FileManager.default.removeItem(at: input) } }

        let mode = ctx.options.mode
        let method = switch mode { case .smallest: "6"; case .balanced: "4"; case .fastest: "2" }
        var args = ["-quiet", "-mt"]
        let lossless = ctx.source.format == .png && ctx.options.qualityOverride == nil
            || ctx.options.qualityOverride == 1.0
        if lossless {
            let z = switch mode { case .smallest: "9"; case .balanced: "6"; case .fastest: "2" }
            args += ["-lossless", "-z", z]
        } else {
            let q = ctx.options.qualityOverride.map { Int(($0 * 100).rounded()) } ?? Self.quality(mode)
            args += ["-q", String(q), "-m", method]
            // Sharp RGB→YUV avoids colour bleeding on edges; worth its cost except in fastest mode.
            if mode != .fastest { args.append("-sharp_yuv") }
            // Source quality ceiling for JPEG input.
            if let est = ctx.source.image?.estimatedJPEGQuality, ctx.source.format == .jpeg, ctx.options.qualityOverride == nil {
                args[args.firstIndex(of: "-q")! + 1] = String(min(q, est))
            }
        }
        let meta = switch ctx.options.metadata { case .keep: "all"; case .removePrivate, .removeAll: "icc" }
        args += ["-metadata", meta, input.path, "-o", ctx.output.path]
        try await ProcessRunner.check(tool, args)
        ctx.progress(1)
    }
}
