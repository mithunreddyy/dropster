import Foundation
import DropsterCore

/// "Fit Under 10 MB": finds the best quality that fits a size limit.
///
/// - Images: binary search on encoder quality (never below `minQuality`, where artefacts
///   become obvious); if even that is too big, the image is scaled down by the square root
///   of the overshoot and searched again. The largest result that fits wins.
/// - Video: two-pass H.264 at the bitrate the limit allows, with the resolution chosen so
///   each pixel still gets enough bits; re-run with a lower bitrate if the muxer overshoots.
/// - Audio: constant bitrate computed from the duration.
///
/// The engine reuses the regular encoders, so metadata, colour profiles and quality ceilings
/// behave exactly as in a normal conversion.
public struct FitSizeEngine: Engine {
    public let id = "fitsize"
    public let maxConcurrency = 2
    public let edges: [ConversionEdge] = []
    public let optimizable: Set<FormatID> = []
    let jpeg: JPEGEngine?
    let imageio = ImageIOEngine()
    let webp: WebPEngine?
    let ffmpeg: URL?
    let encoders: Set<String>

    static let minQuality = 0.45
    static let maxQuality = 0.92
    static let imageSources: Set<FormatID> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .bmp, .jxl, .jp2, .raw, .psd]
    static let videoSources: Set<FormatID> = [.mp4, .mov, .mkv, .webm, .avi]
    static let audioSources: Set<FormatID> = [.mp3, .m4a, .wav, .aiff, .flac, .ogg, .opus]

    public init(ffmpeg: URL? = ToolLocator.find("ffmpeg")) {
        self.ffmpeg = ffmpeg
        encoders = ffmpeg.map(FFmpegEngine.listEncoders) ?? []
        jpeg = JPEGEngine(ffmpeg: ffmpeg)
        webp = WebPEngine()
    }

    public func supports(_ operation: FileOperation, source: FormatID) -> Bool {
        guard case .fitSize = operation else { return false }
        let target = SizeTarget.outputFormat(source: source)
        if Self.imageSources.contains(source) {
            return target == .webp ? webp != nil : ImageIOEngine.writable[target] != nil
        }
        if Self.videoSources.contains(source) { return encoders.contains("libx264") || encoders.contains("h264_videotoolbox") }
        if Self.audioSources.contains(source) {
            switch target {
            case .mp3: return encoders.contains("libmp3lame")
            case .opus: return encoders.contains("libopus")
            default: return encoders.contains("aac_at") || encoders.contains("aac")
            }
        }
        return false
    }

    public func run(_ ctx: StepContext) async throws {
        guard case .fitSize(let limit) = ctx.operation else { throw DropsterError.unsupported("fit size") }
        guard let source = ctx.source.format else { throw DropsterError.unsupported("unknown file type") }
        if Self.imageSources.contains(source) { try await fitImage(ctx, limit: limit) }
        else if Self.videoSources.contains(source) { try await fitVideo(ctx, limit: limit) }
        else { try await fitAudio(ctx, limit: limit) }
    }

    // MARK: Images

    func fitImage(_ ctx: StepContext, limit: Int64) async throws {
        let target = ctx.target
        let dir = ctx.output.deletingLastPathComponent()
        let w = ctx.source.image?.width ?? 0, h = ctx.source.image?.height ?? 0
        var edge = max(w, h)
        if let cap = ctx.options.maxPixelSize, cap > 0 { edge = edge > 0 ? min(edge, cap) : cap }
        var best: (url: URL, size: Int64)?
        var attempts = 0
        defer { if let b = best, FileManager.default.fileExists(atPath: b.url.path) { try? FileManager.default.removeItem(at: b.url) } }

        func encode(quality: Double, edge: Int) async throws -> (URL, Int64) {
            attempts += 1
            let out = dir.appendingPathComponent("fit-\(attempts).\(target.preferredExtension)")
            var o = ctx.options
            o.qualityOverride = quality
            o.maxPixelSize = edge > 0 ? edge : nil
            let step = StepContext(input: ctx.input, output: out, source: ctx.source, target: target, options: o,
                                   isOptimization: false, isFinalStep: true, operation: .convert(target), progress: { _ in })
            switch target {
            case .jpeg: try await (jpeg.map { $0 as any Engine } ?? (imageio as any Engine)).run(step)
            case .webp: guard let webp else { throw DropsterError.unsupported("WebP") }; try await webp.run(step)
            default: try await imageio.run(step)
            }
            try Task.checkCancellation()
            return (out, Self.size(out))
        }
        func keep(_ url: URL, _ size: Int64) {
            if let b = best, b.size >= size { try? FileManager.default.removeItem(at: url); return }
            if let b = best { try? FileManager.default.removeItem(at: b.url) }
            best = (url, size)
        }

        // Up to five scale rounds; each round is a 6-step binary search on quality.
        for round in 0..<5 {
            ctx.progress(Double(round) / 5)
            let (hiURL, hiSize) = try await encode(quality: Self.maxQuality, edge: edge)
            if hiSize <= limit { keep(hiURL, hiSize); break }
            let (loURL, loSize) = try await encode(quality: Self.minQuality, edge: edge)
            try? FileManager.default.removeItem(at: hiURL)
            if loSize > limit {
                try? FileManager.default.removeItem(at: loURL)
                // Bytes scale roughly with pixel count, so shrink the edge by √(limit / size).
                let factor = (Double(limit) / Double(loSize)).squareRoot() * 0.97
                let next = Int(Double(edge > 0 ? edge : 4000) * factor)
                guard next >= 64 else { break }
                edge = next
                continue
            }
            keep(loURL, loSize)
            var lo = Self.minQuality, hi = Self.maxQuality
            for _ in 0..<6 {
                let mid = (lo + hi) / 2
                let (u, s) = try await encode(quality: mid, edge: edge)
                if s <= limit { lo = mid; keep(u, s) } else { hi = mid; try? FileManager.default.removeItem(at: u) }
            }
            break
        }
        guard let b = best else {
            throw DropsterError.encodeFailed("cannot fit this image under \(SizeTarget.label(limit))")
        }
        try FileManager.default.moveItem(at: b.url, to: ctx.output)
        best = nil
        ctx.progress(1)
    }

    // MARK: Video

    /// Bitrate plan for a clip: total kb/s the limit allows, split into video and audio.
    public struct VideoPlan: Sendable, Equatable {
        public var videoKbps: Int
        public var audioKbps: Int
        /// Shorter side to scale to; nil keeps the source resolution.
        public var height: Int?
        public var capFrameRate: Bool
    }

    /// Pure planning step, unit-tested. `width`/`height` are the source's display size.
    public static func planVideo(limit: Int64, duration: Double, width: Int, height: Int, frameRate: Double,
                                 hasAudio: Bool, maxHeight: Int? = nil) -> VideoPlan? {
        guard duration > 0 else { return nil }
        // 3% for container overhead (MP4 boxes, interleaving) plus the muxer's index.
        let totalKbps = Double(limit) * 8 * 0.97 / duration / 1000
        let audio: Int = !hasAudio ? 0 : totalKbps > 1200 ? 128 : totalKbps > 500 ? 96 : totalKbps > 160 ? 64 : 32
        let video = Int(totalKbps) - audio
        guard video >= 40 else { return nil }
        let fps = frameRate > 0 ? min(frameRate, 60) : 30
        let short = Double(min(width, height) > 0 ? min(width, height) : 1080)
        let aspect = width > 0 && height > 0 ? Double(max(width, height)) / Double(min(width, height)) : 16.0 / 9
        // 0.06 bits per pixel per frame is where 2-pass H.264 stays clean on typical footage.
        func fits(_ h: Double, _ f: Double) -> Bool { h * h * aspect * f * 0.06 <= Double(video) * 1000 }
        // The largest standard size (or the source's own) that gets enough bits; above 30 fps,
        // halving the frame rate is tried before dropping resolution.
        let cap = min(short, Double(maxHeight ?? Int.max))
        let ladder = [cap] + [2160.0, 1440, 1080, 720, 540, 480, 360, 270, 240, 180].filter { $0 < cap }
        var chosen = ladder.last!
        var capFPS = fps > 30
        for h in ladder {
            if fits(h, fps) { chosen = h; capFPS = false; break }
            if fps > 30 && fits(h, 30) { chosen = h; capFPS = true; break }
        }
        let even = Int(chosen) / 2 * 2
        return VideoPlan(videoKbps: video, audioKbps: audio, height: Double(even) < short ? even : nil, capFrameRate: capFPS)
    }

    func fitVideo(_ ctx: StepContext, limit: Int64) async throws {
        guard let ffmpeg else { throw DropsterError.unsupported("video") }
        let m = ctx.source.media ?? MediaTraits()
        guard let duration = m.duration, duration > 0 else { throw DropsterError.decodeFailed("unknown duration") }
        guard var plan = Self.planVideo(limit: limit, duration: duration, width: m.width ?? 0, height: m.height ?? 0,
                                        frameRate: m.frameRate ?? 30, hasAudio: m.audioCodec != nil,
                                        maxHeight: ctx.options.maxVideoHeight) else {
            throw DropsterError.unsupported("\(SizeTarget.label(limit)) is too small for \(Int(duration.rounded())) seconds of video")
        }
        let dir = ctx.output.deletingLastPathComponent()
        let log = dir.appendingPathComponent("x264pass").path
        let twoPass = encoders.contains("libx264")
        for attempt in 0..<3 {
            var filters: [String] = []
            if let h = plan.height { filters.append("scale='if(gt(iw,ih),-2,\(h))':'if(gt(iw,ih),\(h),-2)':flags=lanczos") }
            if plan.capFrameRate { filters.append("fps=30") }
            filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
            let common = ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1", "-loglevel", "error", "-i", ctx.input.path,
                          "-map", "0:v:0", "-vf", filters.joined(separator: ","), "-pix_fmt", "yuv420p"]
            let v = "\(plan.videoKbps)k"
            let progress: @Sendable (Double, Double) -> @Sendable (String) -> Void = { base, span in
                { line in
                    if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                        ctx.progress((Double(attempt) + base + span * min(1, us / 1e6 / duration)) / 3)
                    }
                }
            }
            if twoPass {
                try await ProcessRunner.check(ffmpeg, common + ["-c:v", "libx264", "-preset", "medium", "-b:v", v, "-pass", "1",
                                                                "-passlogfile", log, "-an", "-f", "null", "/dev/null"],
                                              currentDirectory: dir, onLine: progress(0, 0.4))
            }
            var second = common
            second += twoPass
                ? ["-c:v", "libx264", "-preset", "medium", "-b:v", v, "-pass", "2", "-passlogfile", log]
                : ["-c:v", "h264_videotoolbox", "-b:v", v, "-maxrate", "\(plan.videoKbps * 12 / 10)k"]
            if plan.audioKbps > 0 {
                second += ["-map", "0:a:0", "-c:a", encoders.contains("aac_at") ? "aac_at" : "aac", "-b:a", "\(plan.audioKbps)k"]
                if plan.audioKbps <= 64 { second += ["-ac", "1"] }
            }
            second += metadataArgs(ctx.options.metadata) + ["-movflags", "+faststart", ctx.output.path]
            try await ProcessRunner.check(ffmpeg, second, currentDirectory: dir, onLine: progress(twoPass ? 0.4 : 0, twoPass ? 0.6 : 1))
            let size = Self.size(ctx.output)
            if size <= limit { ctx.progress(1); return }
            // Overshoot: scale the video bitrate by the miss, with a little extra margin.
            try? FileManager.default.removeItem(at: ctx.output)
            let total = Double(plan.videoKbps + plan.audioKbps) * Double(limit) / Double(size) * 0.96
            plan.videoKbps = Int(total) - plan.audioKbps
            guard plan.videoKbps >= 40, attempt < 2 else { break }
        }
        throw DropsterError.encodeFailed("cannot fit this video under \(SizeTarget.label(limit))")
    }

    // MARK: Audio

    static let mp3Rates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]

    /// The audio bitrate (kb/s) a limit allows, snapped to what the codec supports.
    public static func audioBitrate(limit: Int64, duration: Double, target: FormatID) -> Int? {
        guard duration > 0 else { return nil }
        let kbps = Int(Double(limit) * 8 * 0.97 / duration / 1000)
        switch target {
        case .mp3: return mp3Rates.last { $0 <= kbps }
        case .opus: return kbps >= 6 ? min(kbps, 256) : nil
        default: return kbps >= 16 ? min(kbps, 256) : nil
        }
    }

    func fitAudio(_ ctx: StepContext, limit: Int64) async throws {
        guard let ffmpeg else { throw DropsterError.unsupported("audio") }
        guard let duration = ctx.source.media?.duration, duration > 0 else { throw DropsterError.decodeFailed("unknown duration") }
        let target = ctx.target
        guard var kbps = Self.audioBitrate(limit: limit, duration: duration, target: target) else {
            throw DropsterError.unsupported("\(SizeTarget.label(limit)) is too small for \(Int(duration.rounded())) seconds of audio")
        }
        for _ in 0..<3 {
            var a = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", ctx.input.path, "-vn", "-sn", "-dn"]
            switch target {
            case .mp3: a += ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
            case .opus: a += ["-c:a", "libopus", "-b:a", "\(kbps)k", "-vbr", "constrained"]
            default: a += ["-c:a", encoders.contains("aac_at") ? "aac_at" : "aac", "-b:a", "\(kbps)k", "-movflags", "+faststart"]
            }
            if kbps < 64 { a += ["-ac", "1"] }
            a += metadataArgs(ctx.options.metadata) + [ctx.output.path]
            try await ProcessRunner.check(ffmpeg, a)
            let size = Self.size(ctx.output)
            if size <= limit { ctx.progress(1); return }
            try? FileManager.default.removeItem(at: ctx.output)
            let next = Int(Double(kbps) * Double(limit) / Double(size) * 0.97)
            guard let snapped = target == .mp3 ? Self.mp3Rates.last(where: { $0 <= next }) : (next >= 8 ? next : nil), snapped < kbps else { break }
            kbps = snapped
        }
        throw DropsterError.encodeFailed("cannot fit this audio under \(SizeTarget.label(limit))")
    }

    func metadataArgs(_ policy: MetadataPolicy) -> [String] {
        switch policy {
        case .keep: ["-map_metadata", "0"]
        case .removePrivate: ["-map_metadata", "0", "-metadata", "location=", "-metadata", "location-eng=",
                              "-metadata", "com.apple.quicktime.location.ISO6709=", "-metadata", "encoder="]
        case .removeAll: ["-map_metadata", "-1", "-map_chapters", "-1"]
        }
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
