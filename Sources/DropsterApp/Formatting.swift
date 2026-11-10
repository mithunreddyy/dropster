import Foundation
import UniformTypeIdentifiers
import DropsterCore

enum Fmt {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func percent(_ fraction: Double) -> String {
        let v = fraction * 100
        if abs(v) < 0.1 { return "0%" }
        return String(format: abs(v) < 10 ? "%.1f%%" : "%.0f%%", v)
    }

    static func duration(_ s: Double) -> String {
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        if s < 60 { return String(format: "%.1f s", s) }
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }

    static func remaining(_ s: TimeInterval) -> String {
        if s < 5 { return "a few seconds left" }
        if s < 60 { return "about \(Int((s / 5).rounded()) * 5) s left" }
        return "about \(Int((s / 60).rounded(.up))) min left"
    }

    static func subtitle(_ r: FileReport) -> String {
        var parts: [String] = [kind(r)]
        if let i = r.image { parts.append("\(i.width) × \(i.height)") }
        if let m = r.media {
            if let w = m.width, let h = m.height { parts.append("\(w) × \(h)") }
            if let d = m.duration { parts.append(clock(d)) }
        }
        if let p = r.pageCount { parts.append(p == 1 ? "1 page" : "\(p) pages") }
        parts.append(bytes(r.byteSize))
        return parts.joined(separator: " · ")
    }

    /// Dropster's format name, or the system's description for files it doesn't model.
    static func kind(_ r: FileReport) -> String {
        if let f = r.format { return f.displayName }
        return UTType(filenameExtension: r.url.pathExtension)?.localizedDescription?.capitalized ?? "File"
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
