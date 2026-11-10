import Foundation

/// A named, reusable action with its own settings, offered for one kind of file.
public struct Preset: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var category: FormatCategory
    public var operation: FileOperation
    public var options: ProcessingOptions

    public init(id: UUID = UUID(), name: String, category: FormatCategory, operation: FileOperation, options: ProcessingOptions) {
        self.id = id
        self.name = name
        self.category = category
        self.operation = operation
        self.options = options
    }

    /// Presets shipped with Dropster. Users can edit or delete them and restore them later.
    public static let builtIns: [Preset] = {
        func p(_ id: String, _ name: String, _ c: FormatCategory, _ op: FileOperation, _ o: ProcessingOptions) -> Preset {
            Preset(id: UUID(uuidString: id)!, name: name, category: c, operation: op, options: o)
        }
        return [
            p("00000000-0000-0000-0000-000000000101", "Web 1920 · WebP", .image, .convert(.webp), ProcessingOptions(maxPixelSize: 1920)),
            p("00000000-0000-0000-0000-000000000102", "Social 1080 · JPEG", .image, .convert(.jpeg), ProcessingOptions(metadata: .removeAll, maxPixelSize: 1080)),
            p("00000000-0000-0000-0000-000000000103", "Print 300 dpi · TIFF", .image, .convert(.tiff), ProcessingOptions(metadata: .keep, dpi: 300, tiffCompression: .lzw)),
            p("00000000-0000-0000-0000-000000000104", "Favicon · ICO", .image, .convert(.ico), ProcessingOptions(icoSizes: [16, 32, 48])),
            p("00000000-0000-0000-0000-000000000105", "Trace · SVG", .image, .convert(.svg), ProcessingOptions()),
            p("00000000-0000-0000-0000-000000000201", "720p · MP4", .video, .convert(.mp4), ProcessingOptions(maxVideoHeight: 720)),
            p("00000000-0000-0000-0000-000000000202", "HEVC · Hardware", .video, .convert(.mp4), ProcessingOptions(videoCodec: .hevc, hardwareEncoding: true)),
            p("00000000-0000-0000-0000-000000000203", "AV1 · Smallest", .video, .convert(.mp4), ProcessingOptions(mode: .smallest, videoCodec: .av1)),
            p("00000000-0000-0000-0000-000000000204", "Frames · 1 per second", .video, .exportPages(.jpeg), ProcessingOptions(frameRate: 1)),
            p("00000000-0000-0000-0000-000000000205", "GIF · 480 px", .video, .convert(.gif), ProcessingOptions(maxPixelSize: 480)),
            p("00000000-0000-0000-0000-000000000301", "MP3 · 320 kb/s", .audio, .convert(.mp3), ProcessingOptions(mp3Bitrate: 320)),
            p("00000000-0000-0000-0000-000000000302", "MP3 · 128 kb/s", .audio, .convert(.mp3), ProcessingOptions(mp3Bitrate: 128)),
            p("00000000-0000-0000-0000-000000000401", "PDF · Screen", .document, .optimize, ProcessingOptions(mode: .smallest)),
            p("00000000-0000-0000-0000-000000000402", "Pages · PNG 150 dpi", .document, .exportPages(.png), ProcessingOptions(dpi: 150)),
            p("00000000-0000-0000-0000-000000000403", "One Long Image", .document, .longImage(.jpeg), ProcessingOptions(dpi: 110)),
        ]
    }()
}

/// Presets persisted as JSON in Application Support.
public final class PresetStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var presets: [Preset]

    public init(url: URL = PresetStore.defaultURL()) {
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = list
        } else {
            presets = Preset.builtIns
        }
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dropster/presets.json")
    }

    public var all: [Preset] { lock.withLock { presets } }

    public func presets(for category: FormatCategory) -> [Preset] { all.filter { $0.category == category } }

    public func save(_ preset: Preset) {
        lock.withLock {
            if let i = presets.firstIndex(where: { $0.id == preset.id }) { presets[i] = preset } else { presets.append(preset) }
        }
        persist()
    }

    public func delete(_ id: UUID) {
        lock.withLock { presets.removeAll { $0.id == id } }
        persist()
    }

    public func move(_ id: UUID, by offset: Int) {
        lock.withLock {
            guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
            let j = max(0, min(presets.count - 1, i + offset))
            presets.swapAt(i, j)
        }
        persist()
    }

    public func restoreBuiltIns() {
        lock.withLock {
            for b in Preset.builtIns where !presets.contains(where: { $0.id == b.id }) { presets.append(b) }
        }
        persist()
    }

    private func persist() {
        let snapshot = all
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}
