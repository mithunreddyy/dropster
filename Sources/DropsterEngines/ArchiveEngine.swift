import Foundation
import DropsterCore

/// Single-file compression with the best general-purpose codecs.
/// Accepts any input (`.any` edges); extraction is intentionally not offered yet.
public struct ArchiveEngine: Engine {
    public let id = "archive"
    public let maxConcurrency: Int = 2 // each codec runs multi-threaded
    public let edges: [ConversionEdge]
    public let optimizable: Set<FormatID> = []
    let tools: [FormatID: URL]

    public init() {
        var t: [FormatID: URL] = [:]
        if let u = ToolLocator.find("zstd") { t[.zstd] = u }
        if let u = ToolLocator.find("xz") { t[.xz] = u }
        if let u = ToolLocator.find("brotli") { t[.brotli] = u }
        if let u = ToolLocator.find("gzip") { t[.gzip] = u }
        if let u = ToolLocator.find("zip") { t[.zip] = u }
        tools = t
        // Zstandard first: near-xz ratios at a fraction of the time.
        let cost: [FormatID: Double] = [.zstd: 1, .xz: 1.2, .brotli: 1.3, .gzip: 1.5, .zip: 1.4]
        edges = t.keys.map { ConversionEdge(from: .any, to: $0, cost: cost[$0] ?? 2, engineID: "archive") }
    }

    public func run(_ ctx: StepContext) async throws {
        guard let tool = tools[ctx.target] else { throw DropsterError.unsupported(ctx.target.displayName) }
        let m = ctx.options.mode
        let input = ctx.input.path
        switch ctx.target {
        case .zstd:
            let level: [String] = switch m { case .smallest: ["-19", "--long=27"]; case .balanced: ["-9"]; case .fastest: ["-3"] }
            try await ProcessRunner.check(tool, ["-q", "-T0"] + level + ["-o", ctx.output.path, input])
        case .xz:
            let level = switch m { case .smallest: "-9e"; case .balanced: "-6"; case .fastest: "-1" }
            try await ProcessRunner.check(tool, ["-c", "-T0", level, input], stdout: ctx.output)
        case .brotli:
            let q = switch m { case .smallest: "11"; case .balanced: "9"; case .fastest: "4" }
            try await ProcessRunner.check(tool, ["-q", q, "-o", ctx.output.path, input])
        case .gzip:
            let level = switch m { case .smallest: "-9"; case .balanced: "-6"; case .fastest: "-1" }
            try await ProcessRunner.check(tool, ["-c", "-n", level, input], stdout: ctx.output)
        case .zip:
            let level = switch m { case .smallest: "-9"; case .balanced: "-6"; case .fastest: "-1" }
            try await ProcessRunner.check(tool, ["-q", "-X", "-j", level, ctx.output.path, input])
        default:
            throw DropsterError.unsupported(ctx.target.displayName)
        }
        ctx.progress(1)
    }

    /// Integrity test commands used by the verifier.
    func testArguments(_ format: FormatID, file: URL) -> (URL, [String])? {
        switch format {
        case .zstd: tools[.zstd].map { ($0, ["-q", "-t", file.path]) }
        case .xz: tools[.xz].map { ($0, ["-t", file.path]) }
        case .brotli: tools[.brotli].map { ($0, ["-t", file.path]) }
        case .gzip: tools[.gzip].map { ($0, ["-t", file.path]) }
        case .zip: ToolLocator.find("unzip").map { ($0, ["-tqq", file.path]) }
        default: nil
        }
    }
}
