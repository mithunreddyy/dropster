import Foundation
import DropsterCore

/// Measures how close an output image is to its original with SSIM (structural
/// similarity, 1.0 = identical), so the app can report quality instead of asserting it.
public struct QualityMeter: Sendable {
    let ffmpeg: URL

    public init?(ffmpeg: URL? = ToolLocator.find("ffmpeg")) {
        guard let ffmpeg else { return nil }
        self.ffmpeg = ffmpeg
    }

    public enum Verdict: String, Sendable {
        case identical = "Visually identical"
        case excellent = "Excellent"
        case good = "Good"
        case noticeable = "Visible differences"

        public init(ssim: Double) {
            self = ssim >= 0.99 ? .identical : ssim >= 0.97 ? .excellent : ssim >= 0.95 ? .good : .noticeable
        }
    }

    /// Both images are first rendered upright to PNG by ImageIO, so formats FFmpeg cannot
    /// decode (HEIC grids, RAW) still compare, and orientation differences don't count.
    public func ssim(original: URL, candidate: URL) async throws -> Double {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropster-ssim-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
        try ImageIOEngine.renderUprightPNG(original, to: a, maxPixelSize: nil)
        try ImageIOEngine.renderUprightPNG(candidate, to: b, maxPixelSize: nil)
        // Scale the original to the candidate's size in case the output was resized.
        let graph = "[1:v]format=rgb24[c];[0:v]format=rgb24[o];[o][c]scale2ref=flags=bicubic[o2][c2];[o2][c2]ssim"
        let out = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", a.path, "-i", b.path,
                                                       "-filter_complex", graph, "-f", "null", "-"])
        guard let range = out.stderr.range(of: "All:") else { throw DropsterError.verificationFailed("SSIM unavailable") }
        let tail = out.stderr[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        guard let v = Double(tail) else { throw DropsterError.verificationFailed("SSIM unreadable") }
        return v
    }
}
