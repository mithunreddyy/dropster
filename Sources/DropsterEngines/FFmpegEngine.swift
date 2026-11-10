import Foundation
import DropsterCore

/// Audio and video through FFmpeg. Arguments are built as arrays (never shell strings)
/// and progress is read from `-progress pipe:1`.
public struct FFmpegEngine: Engine {
    public let id = "ffmpeg"
    /// Video encoders already use every core; two at a time keeps the machine responsive.
    public let maxConcurrency = 2
    public let edges: [ConversionEdge]
    public let optimizable: Set<FormatID>
    let ffmpeg: URL
    let encoders: Set<String>

    static let videoSources: [FormatID] = [.mp4, .mov, .mkv, .webm, .avi, .gif]
    static let audioSources: [FormatID] = [.mp3, .m4a, .wav, .aiff, .flac, .ogg, .opus, .mp4, .mov, .mkv, .webm, .avi]

    public init?(ffmpeg: URL? = ToolLocator.find("ffmpeg")) {
        guard let ffmpeg else { return nil }
        self.ffmpeg = ffmpeg
        let enc = Self.listEncoders(ffmpeg)
        self.encoders = enc
        var e: [ConversionEdge] = []
        var videoTargets: [FormatID] = []
        if enc.contains("libx264") || enc.contains("h264_videotoolbox") { videoTargets += [.mp4, .mov, .mkv] }
        if enc.contains("libvpx-vp9") && enc.contains("libopus") { videoTargets.append(.webm) }
        if enc.contains("gif") { videoTargets.append(.gif) }
        for s in Self.videoSources { for t in videoTargets where t != s { e.append(ConversionEdge(from: s, to: t, cost: 3, engineID: "ffmpeg")) } }
        var audioTargets: [FormatID] = [.wav, .aiff, .flac]
        if enc.contains("libmp3lame") { audioTargets.append(.mp3) }
        if enc.contains("aac_at") || enc.contains("aac") { audioTargets.append(.m4a) }
        if enc.contains("libopus") { audioTargets.append(.opus) }
        for s in Self.audioSources { for t in audioTargets where t != s { e.append(ConversionEdge(from: s, to: t, cost: t.isLossy ? 2 : 1, engineID: "ffmpeg")) } }
        // Subtitles (SRT⇄VTT is handled natively by SubtitleEngine at lower cost).
        for (a, b) in [(FormatID.srt, FormatID.ass), (.vtt, .ass), (.ass, .srt), (.ass, .vtt)] {
            e.append(ConversionEdge(from: a, to: b, cost: 2, engineID: "ffmpeg"))
        }
        edges = e
        var opt: Set<FormatID> = [.flac]
        if enc.contains("libx265") || enc.contains("hevc_videotoolbox") { opt.formUnion([.mp4, .mov, .mkv]) }
        if videoTargets.contains(.webm) { opt.insert(.webm) }
        if audioTargets.contains(.mp3) { opt.insert(.mp3) }
        if audioTargets.contains(.m4a) { opt.insert(.m4a) }
        if audioTargets.contains(.opus) { opt.insert(.opus) }
        optimizable = opt
    }

    static func listEncoders(_ ffmpeg: URL) -> Set<String> {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: Set<String> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 2, cols[0].count == 6 { out.insert(String(cols[1])) }
        }
        return out
    }

    public func supports(_ operation: FileOperation, source: FormatID) -> Bool {
        guard case .exportPages(let f) = operation, Self.videoSources.contains(source) else { return false }
        return [.png, .jpeg].contains(f)
    }

    public func run(_ ctx: StepContext) async throws {
        if case .exportPages = ctx.operation {
            try FileManager.default.createDirectory(at: ctx.output, withIntermediateDirectories: true)
        }
        let args = arguments(ctx)
        let duration = ctx.source.media?.duration ?? 0
        try await ProcessRunner.check(ffmpeg, args) { line in
            // out_time_us=12345678
            if duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                ctx.progress(us / 1_000_000 / duration)
            }
        }
    }

    /// Pure function so the exact command lines are unit-testable.
    public func arguments(_ ctx: StepContext) -> [String] {
        let m = ctx.source.media ?? MediaTraits()
        let mode = ctx.options.mode
        var a = ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1", "-loglevel", "error", "-i", ctx.input.path]

        switch ctx.options.metadata {
        case .keep: a += ["-map_metadata", "0"]
        case .removePrivate: a += ["-map_metadata", "0", "-metadata", "location=", "-metadata", "location-eng=",
                                   "-metadata", "com.apple.quicktime.location.ISO6709=", "-metadata", "encoder="]
        case .removeAll: a += ["-map_metadata", "-1", "-map_chapters", "-1"]
        }

        let target = ctx.target
        if target.category == .subtitle {
            a.append(ctx.output.path)
            return a
        }
        if case .exportPages(let f) = ctx.operation {
            var filters: [String] = []
            if let r = ctx.options.frameRate { filters.append("fps=\(r)") }
            if let edge = ctx.options.maxPixelSize { filters.append(scaleFilter(edge)) }
            if !filters.isEmpty { a += ["-vf", filters.joined(separator: ",")] }
            a += ["-an", "-sn", "-fps_mode", "passthrough"]
            if f == .jpeg { a += ["-q:v", "2"] }
            a.append(ctx.output.appendingPathComponent("frame-%05d.\(f.preferredExtension)").path)
            return a
        }
        if target.category == .audio {
            a += ["-vn", "-sn", "-dn"]
            a += audioArgs(target, mode: mode, source: m, mp3Bitrate: ctx.options.mp3Bitrate)
            a += container(target)
            a.append(ctx.output.path)
            return a
        }
        if target == .gif {
            let fps = switch mode { case .smallest: 10; case .balanced: 15; case .fastest: 12 }
            let edge = ctx.options.maxPixelSize ?? 720
            // One pass: generate an optimal palette from the clip, then dither with it.
            let vf = "fps=\(fps),\(scaleFilter(edge)),split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle"
            a += ["-filter_complex", vf, "-an", "-loop", "0", ctx.output.path]
            return a
        }

        let o = ctx.options
        let canCopy = !ctx.isOptimization && o.maxPixelSize == nil && o.maxVideoHeight == nil && o.videoCodec == .automatic
            && streamCopyCompatible(m, into: target)
        if canCopy {
            a += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        } else {
            a += ["-map", "0:v:0", "-map", "0:a?", "-sn"]
            var filters: [String] = []
            if let edge = o.maxPixelSize { filters.append(scaleFilter(edge)) }
            if let h = o.maxVideoHeight { filters.append(heightFilter(h)) }
            if ctx.source.format == .gif || target != .webm { filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2") }
            if !filters.isEmpty { a += ["-vf", filters.joined(separator: ",")] }
            a += videoArgs(target, mode: mode, optimize: ctx.isOptimization, codec: o.videoCodec, hardware: o.hardwareEncoding)
            if m.audioCodec != nil {
                if target == .webm {
                    a += ["-c:a", "libopus", "-b:a", "128k"]
                } else if ["aac"].contains(m.audioCodec ?? "") && target != .webm {
                    a += ["-c:a", "copy"]
                } else {
                    a += ["-c:a", encoders.contains("aac_at") ? "aac_at" : "aac", "-b:a", "160k"]
                }
            }
        }
        a += container(target)
        a.append(ctx.output.path)
        return a
    }

    /// Caps the shorter side, so 720 gives 1280×720 landscape and 720×1280 portrait.
    func heightFilter(_ h: Int) -> String {
        "scale='if(gt(iw,ih),-2,min(\(h),iw))':'if(gt(iw,ih),min(\(h),ih),-2)'"
    }

    func scaleFilter(_ edge: Int) -> String {
        "scale='if(gt(iw,ih),min(\(edge),iw),-2)':'if(gt(iw,ih),-2,min(\(edge),ih))'"
    }

    func container(_ t: FormatID) -> [String] {
        switch t {
        case .mp4, .mov, .m4a: ["-movflags", "+faststart"]
        default: []
        }
    }

    /// Remux without re-encoding when the target container accepts the source codecs.
    func streamCopyCompatible(_ m: MediaTraits, into target: FormatID) -> Bool {
        guard let v = m.videoCodec else { return false }
        let a = m.audioCodec
        switch target {
        case .mp4, .mov: return ["h264", "hevc", "av1"].contains(v) && (a == nil || ["aac", "alac", "mp3"].contains(a!))
        case .mkv: return true
        case .webm: return ["vp8", "vp9", "av1"].contains(v) && (a == nil || ["opus", "vorbis"].contains(a!))
        default: return false
        }
    }

    func videoArgs(_ target: FormatID, mode: CompressionMode, optimize: Bool, codec: VideoCodecChoice = .automatic,
                   hardware: Bool = false) -> [String] {
        // Explicit codec choices from presets.
        switch codec {
        case .av1 where encoders.contains("libsvtav1") && target != .mov:
            let preset = switch mode { case .smallest: "5"; case .balanced: "8"; case .fastest: "11" }
            return ["-c:v", "libsvtav1", "-crf", mode == .smallest ? "38" : "34", "-preset", preset, "-pix_fmt", "yuv420p"]
        case .hevc where target != .webm:
            if hardware || mode == .fastest, encoders.contains("hevc_videotoolbox") {
                return ["-c:v", "hevc_videotoolbox", "-q:v", "58", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
            }
            return ["-c:v", "libx265", "-crf", mode == .smallest ? "26" : "25", "-preset", mode == .smallest ? "slow" : "fast",
                    "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-x265-params", "log-level=error"]
        case .h264 where target != .webm:
            if hardware, encoders.contains("h264_videotoolbox") {
                return ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
            }
            return ["-c:v", "libx264", "-crf", mode == .smallest ? "22" : "20", "-preset", mode == .smallest ? "slow" : "medium", "-pix_fmt", "yuv420p"]
        default: break
        }
        if hardware && target != .webm {
            if optimize, encoders.contains("hevc_videotoolbox") {
                return ["-c:v", "hevc_videotoolbox", "-q:v", "58", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
            }
            if encoders.contains("h264_videotoolbox") { return ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"] }
        }
        if target == .webm {
            let cpu = switch mode { case .smallest: "1"; case .balanced: "3"; case .fastest: "6" }
            let crf = mode == .smallest ? "36" : "32"
            return ["-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", cpu, "-pix_fmt", "yuv420p"]
        }
        // Optimizing targets HEVC (≈40–50% smaller than H.264 at equal quality);
        // conversions target H.264 for maximum compatibility.
        if optimize {
            switch mode {
            case .smallest where encoders.contains("libx265"):
                return ["-c:v", "libx265", "-crf", "26", "-preset", "slow", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-x265-params", "log-level=error"]
            case .balanced where encoders.contains("libx265"):
                return ["-c:v", "libx265", "-crf", "25", "-preset", "fast", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-x265-params", "log-level=error"]
            default:
                if encoders.contains("hevc_videotoolbox") {
                    return ["-c:v", "hevc_videotoolbox", "-q:v", "58", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
                }
                return ["-c:v", "libx265", "-crf", "26", "-preset", "veryfast", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
            }
        }
        switch mode {
        case .smallest where encoders.contains("libx264"):
            return ["-c:v", "libx264", "-crf", "22", "-preset", "slow", "-pix_fmt", "yuv420p"]
        case .balanced where encoders.contains("libx264"):
            return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p"]
        default:
            if encoders.contains("h264_videotoolbox") {
                return ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
            }
            return ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast", "-pix_fmt", "yuv420p"]
        }
    }

    func audioArgs(_ target: FormatID, mode: CompressionMode, source m: MediaTraits, mp3Bitrate: Int? = nil) -> [String] {
        let hiRes = (m.bitsPerSample ?? 16) > 16
        switch target {
        case .mp3 where mp3Bitrate != nil:
            return ["-c:a", "libmp3lame", "-b:a", "\(mp3Bitrate!)k"]
        case .mp3:
            // LAME VBR: V5 ≈130 kb/s, V2 ≈190 kb/s (transparent for most listeners).
            return ["-c:a", "libmp3lame", "-q:a", mode == .smallest ? "5" : "2"]
        case .m4a:
            let br = mode == .smallest ? "128k" : "192k"
            return encoders.contains("aac_at") ? ["-c:a", "aac_at", "-b:a", br] : ["-c:a", "aac", "-b:a", br]
        case .opus:
            return ["-c:a", "libopus", "-b:a", mode == .smallest ? "96k" : "128k", "-vbr", "on"]
        case .flac:
            let level = switch mode { case .smallest: "12"; case .balanced: "8"; case .fastest: "5" }
            return ["-c:a", "flac", "-compression_level", level]
        case .wav: return ["-c:a", hiRes ? "pcm_s24le" : "pcm_s16le"]
        case .aiff: return ["-c:a", hiRes ? "pcm_s24be" : "pcm_s16be"]
        default: return []
        }
    }
}
