import Foundation
import DropsterCore

/// SubRip ⇄ WebVTT natively (timing preserved to the millisecond). Other subtitle
/// conversions go through FFmpeg.
public struct SubtitleEngine: Engine {
    public let id = "subtitle"
    public let maxConcurrency = 8
    public let edges: [ConversionEdge] = [
        ConversionEdge(from: .srt, to: .vtt, cost: 1, engineID: "subtitle"),
        ConversionEdge(from: .vtt, to: .srt, cost: 1, engineID: "subtitle"),
        ConversionEdge(from: .srt, to: .txt, cost: 1.5, engineID: "subtitle"),
        ConversionEdge(from: .vtt, to: .txt, cost: 1.5, engineID: "subtitle"),
    ]
    public let optimizable: Set<FormatID> = []

    public init() {}

    public struct Cue: Equatable, Sendable {
        public var start: Int // milliseconds
        public var end: Int
        public var text: String
    }

    public func run(_ ctx: StepContext) async throws {
        let raw = try String(contentsOf: ctx.input, encoding: .utf8)
        let cues = Self.parse(raw)
        guard !cues.isEmpty else { throw DropsterError.decodeFailed("no subtitle cues found") }
        let out: String = switch ctx.target {
        case .vtt: Self.vtt(cues)
        case .srt: Self.srt(cues)
        default: cues.map(\.text).joined(separator: "\n") + "\n"
        }
        try out.write(to: ctx.output, atomically: true, encoding: .utf8)
        ctx.progress(1)
    }

    /// Parses SRT or VTT. Tolerates BOMs, CRLF, missing indices and VTT cue settings.
    public static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let s = time(parts[0]), let e = time(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            cues.append(Cue(start: s, end: e, text: body))
        }
        return cues
    }

    static func time(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let hms = t.split(separator: ":")
        guard hms.count == 2 || hms.count == 3 else { return nil }
        let secParts = hms.last!.split(separator: ".")
        guard let sec = Int(secParts[0]) else { return nil }
        let ms = secParts.count > 1 ? Int(String(secParts[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0 : 0
        let mins = Int(hms[hms.count - 2]) ?? 0
        let hours = hms.count == 3 ? Int(hms[0]) ?? 0 : 0
        return ((hours * 60 + mins) * 60 + sec) * 1000 + ms
    }

    static func stamp(_ ms: Int, separator: Character) -> String {
        String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, String(separator), ms % 1000)
    }

    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start, separator: ",")) --> \(stamp(c.end, separator: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { c in "\(stamp(c.start, separator: ".")) --> \(stamp(c.end, separator: "."))\n\(c.text)\n" }.joined(separator: "\n")
    }
}
