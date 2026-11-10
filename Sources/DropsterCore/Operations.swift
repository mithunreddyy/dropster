import Foundation

/// Pixel edits applied to an image, in this order: orientation (rotate/flip), crop,
/// grayscale, background removal.
public struct ImageEdit: Sendable, Hashable, Codable {
    /// Clockwise quarter turns, 0...3.
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Crop rectangle in the upright image, normalised to 0...1 (origin top-left).
    public var crop: CropRect?
    public var grayscale: Bool
    public var removeBackground: Bool

    public init(quarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false, crop: CropRect? = nil,
                grayscale: Bool = false, removeBackground: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.crop = crop
        self.grayscale = grayscale
        self.removeBackground = removeBackground
    }

    public static let rotateRight = ImageEdit(quarterTurns: 1)
    public static let rotateLeft = ImageEdit(quarterTurns: 3)
    public static let flipH = ImageEdit(flipHorizontal: true)
    public static let flipV = ImageEdit(flipVertical: true)
    public static let toGrayscale = ImageEdit(grayscale: true)
    public static let cutout = ImageEdit(removeBackground: true)

    /// Only orientation changes: JPEG/HEIC/TIFF can do these by rewriting one EXIF tag.
    public var isOrientationOnly: Bool { crop == nil && !grayscale && !removeBackground }

    public var label: String {
        var parts: [String] = []
        switch quarterTurns {
        case 1: parts.append("Rotate Right")
        case 2: parts.append("Rotate 180°")
        case 3: parts.append("Rotate Left")
        default: break
        }
        if flipHorizontal { parts.append("Flip Horizontal") }
        if flipVertical { parts.append("Flip Vertical") }
        if crop != nil { parts.append("Crop") }
        if grayscale { parts.append("Grayscale") }
        if removeBackground { parts.append("Remove Background") }
        return parts.isEmpty ? "Edit" : parts.joined(separator: " + ")
    }

    /// EXIF orientation after applying this edit on top of `orientation` (1...8).
    /// Each orientation is the 2×2 matrix that maps stored pixels to the displayed image
    /// (y pointing down); the edit's matrix is multiplied on the left.
    public func composedOrientation(_ orientation: Int) -> Int {
        let base = Self.matrices[orientation] ?? Self.matrices[1]!
        var m = base
        let r: [Int] = [0, -1, 1, 0] // 90° clockwise
        for _ in 0..<quarterTurns { m = Self.mul(r, m) }
        if flipHorizontal { m = Self.mul([-1, 0, 0, 1], m) }
        if flipVertical { m = Self.mul([1, 0, 0, -1], m) }
        return Self.matrices.first { $0.value == m }!.key
    }

    static let matrices: [Int: [Int]] = [
        1: [1, 0, 0, 1], 2: [-1, 0, 0, 1], 3: [-1, 0, 0, -1], 4: [1, 0, 0, -1],
        5: [0, 1, 1, 0], 6: [0, -1, 1, 0], 7: [0, -1, -1, 0], 8: [0, 1, -1, 0],
    ]

    static func mul(_ a: [Int], _ b: [Int]) -> [Int] {
        [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]
    }
}

public struct CropRect: Sendable, Hashable, Codable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = max(0, min(1, x)); self.y = max(0, min(1, y))
        self.width = max(0.001, min(1 - self.x, width)); self.height = max(0.001, min(1 - self.y, height))
    }
}

/// What the user asked Dropster to do with a file.
public enum FileOperation: Sendable, Hashable, Codable {
    /// Re-encode in the same format to reduce size. Never keeps a larger result.
    case optimize
    /// Produce a file in another format.
    case convert(FormatID)
    /// Rewrite without private metadata, without re-encoding pixels where possible.
    case stripMetadata
    /// Rotate, flip, crop, grayscale or cut out the subject; same format unless transparency needs PNG.
    case edit(ImageEdit)
    /// One file per page (PDF) or per frame (video), in a folder.
    case exportPages(FormatID)
    /// Every PDF page stacked into one tall image.
    case longImage(FormatID)
    /// Split a PDF into single-page PDFs.
    case splitPDF
    /// Keep only the given pages ("1-3, 7").
    case extractPages(String)
    /// Re-encode so the result is at most this many bytes, keeping as much quality as fits.
    case fitSize(Int64)
    /// Unpack an archive into a folder, refusing entries that would escape it.
    case unpack

    public var label: String {
        switch self {
        case .optimize: "Optimize"
        case .convert(let f): "Convert to \(f.displayName)"
        case .stripMetadata: "Remove Metadata"
        case .edit(let e): e.label
        case .exportPages(let f): "Export Pages as \(f.displayName)"
        case .longImage(let f): "One Long \(f.displayName)"
        case .splitPDF: "Split into Pages"
        case .extractPages(let r): "Extract Pages \(r)"
        case .fitSize(let b): "Fit Under \(SizeTarget.label(b))"
        case .unpack: "Unpack"
        }
    }

    public var shortLabel: String {
        switch self {
        case .convert(let f): "→ \(f.displayName)"
        default: label
        }
    }

    /// Whether "input vs output size" means anything (it does not for unpacking).
    public var measuresSavings: Bool { self != .unpack }

    public var isFitSize: Bool { if case .fitSize = self { true } else { false } }

    /// Operations whose result is a folder of files rather than one file.
    public var producesFolder: Bool {
        switch self {
        case .exportPages, .splitPDF, .unpack: true
        default: false
        }
    }

    /// Format of the produced file(s), given the source format.
    public func outputFormat(source: FormatID) -> FormatID {
        switch self {
        case .optimize, .stripMetadata: source
        case .convert(let f), .exportPages(let f), .longImage(let f): f
        case .edit(let e): e.removeBackground && !source.supportsAlpha ? .png : (source == .raw ? .heic : source)
        case .splitPDF, .extractPages: .pdf
        case .fitSize: SizeTarget.outputFormat(source: source)
        case .unpack: .any
        }
    }
}

/// Size limits for "Fit Under" and the format each kind of file is squeezed into.
public enum SizeTarget {
    /// Common upload and attachment limits, in decimal megabytes like Finder shows.
    public static let common: [Int64] = [1_000_000, 5_000_000, 10_000_000, 25_000_000]

    /// "10 MB", "500 KB", "1.5 MB" (decimal units, matching Finder).
    public static func label(_ bytes: Int64) -> String {
        func trim(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
        if bytes >= 1_000_000_000 { return trim(Double(bytes) / 1_000_000_000) + " GB" }
        if bytes >= 1_000_000 { return trim(Double(bytes) / 1_000_000) + " MB" }
        return trim(Double(bytes) / 1_000) + " KB"
    }

    /// Parses "10MB", "2.5 mb", "800k", "1g" or a plain byte count.
    public static func parse(_ text: String) -> Int64? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("gb", 1e9), ("g", 1e9), ("mb", 1e6), ("m", 1e6), ("kb", 1e3), ("k", 1e3), ("b", 1)]
        for (suffix, k) in units where t.hasSuffix(suffix) {
            guard let v = Double(t.dropLast(suffix.count)), v > 0 else { return nil }
            return Int64(v * k)
        }
        return Int64(t).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Lossy formats keep their format; lossless images become JPEG, videos MP4 (H.264, plays
    /// everywhere), and lossless audio AAC.
    public static func outputFormat(source: FormatID) -> FormatID {
        switch source {
        case .jpeg, .heic, .avif, .webp, .mp3, .m4a, .opus: source
        case _ where source.category == .image: .jpeg
        case _ where source.category == .video: .mp4
        case _ where source.category == .audio: .m4a
        default: source
        }
    }
}

/// Operations that combine several files into one result.
public enum BatchOperation: Sendable, Hashable, Codable {
    case mergePDF
    case zip

    public var label: String {
        switch self {
        case .mergePDF: "Merge into One PDF"
        case .zip: "Pack into One ZIP"
        }
    }
}

public enum CompressionMode: String, Sendable, Hashable, Codable, CaseIterable {
    case smallest, balanced, fastest

    public var displayName: String {
        switch self {
        case .smallest: "Smallest"
        case .balanced: "Balanced"
        case .fastest: "Fastest"
        }
    }

    public var explanation: String {
        switch self {
        case .smallest: "Highest encoder effort and stronger compression. Slower."
        case .balanced: "Visually transparent quality at a sensible speed."
        case .fastest: "Hardware encoders and low effort. Larger files."
        }
    }
}

public enum MetadataPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Keep everything except values that no longer apply (orientation is baked in).
    case keep
    /// Remove location, device serials and owner names; keep capture date and camera.
    case removePrivate
    /// Remove all metadata; keep only the colour profile so colours stay correct.
    case removeAll

    public var displayName: String {
        switch self {
        case .keep: "Keep All Metadata"
        case .removePrivate: "Remove Location & Serials"
        case .removeAll: "Remove All Metadata"
        }
    }
}

public enum VideoCodecChoice: String, Sendable, Hashable, Codable, CaseIterable {
    case automatic, h264, hevc, av1
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        }
    }
}

public enum TIFFCompression: Int, Sendable, Hashable, Codable, CaseIterable {
    case none = 1, lzw = 5, jpeg = 7, deflate = 8
    public var displayName: String {
        switch self {
        case .none: "None"
        case .lzw: "LZW"
        case .jpeg: "JPEG"
        case .deflate: "Deflate"
        }
    }
}

public enum OutputLocation: Sendable, Hashable, Codable {
    case nextToOriginal
    case folder(URL)
}

public struct ProcessingOptions: Sendable, Hashable, Codable {
    public var mode: CompressionMode
    public var metadata: MetadataPolicy
    /// Longest edge in pixels for image outputs; nil keeps original dimensions.
    public var maxPixelSize: Int?
    /// Overrides the mode's quality (0...1) for lossy encoders.
    public var qualityOverride: Double?
    public var output: OutputLocation
    /// For format conversions: discard the output if it is larger than the source.
    /// Optimize always behaves this way.
    public var discardLargerConversions: Bool

    // Image presets
    /// Pixel density written into image metadata (and used to render PDF pages).
    public var dpi: Int?
    public var tiffCompression: TIFFCompression
    /// Sizes embedded in ICO files.
    public var icoSizes: [Int]

    // Video and audio presets
    /// Caps the shorter side of video (720 = "720p").
    public var maxVideoHeight: Int?
    public var videoCodec: VideoCodecChoice
    public var hardwareEncoding: Bool
    /// Frames per second when exporting video frames as pictures; nil = every frame.
    public var frameRate: Double?
    /// Constant MP3 bitrate in kb/s; nil uses VBR per mode.
    public var mp3Bitrate: Int?

    // Output naming
    /// Tokens: {name} {ext} {action} {date} {n}. nil uses Dropster's defaults.
    public var nameTemplate: String?
    public var keepFileDates: Bool

    public init(mode: CompressionMode = .balanced, metadata: MetadataPolicy = .removePrivate,
                maxPixelSize: Int? = nil, qualityOverride: Double? = nil,
                output: OutputLocation = .nextToOriginal, discardLargerConversions: Bool = false,
                dpi: Int? = nil, tiffCompression: TIFFCompression = .lzw, icoSizes: [Int] = [16, 32, 48, 64, 128, 256],
                maxVideoHeight: Int? = nil, videoCodec: VideoCodecChoice = .automatic, hardwareEncoding: Bool = false,
                frameRate: Double? = nil, mp3Bitrate: Int? = nil, nameTemplate: String? = nil, keepFileDates: Bool = true) {
        self.mode = mode
        self.metadata = metadata
        self.maxPixelSize = maxPixelSize
        self.qualityOverride = qualityOverride
        self.output = output
        self.discardLargerConversions = discardLargerConversions
        self.dpi = dpi
        self.tiffCompression = tiffCompression
        self.icoSizes = icoSizes
        self.maxVideoHeight = maxVideoHeight
        self.videoCodec = videoCodec
        self.hardwareEncoding = hardwareEncoding
        self.frameRate = frameRate
        self.mp3Bitrate = mp3Bitrate
        self.nameTemplate = nameTemplate
        self.keepFileDates = keepFileDates
    }

    /// Tolerates missing keys so presets saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProcessingOptions()
        mode = try c.decodeIfPresent(CompressionMode.self, forKey: .mode) ?? d.mode
        metadata = try c.decodeIfPresent(MetadataPolicy.self, forKey: .metadata) ?? d.metadata
        maxPixelSize = try c.decodeIfPresent(Int.self, forKey: .maxPixelSize)
        qualityOverride = try c.decodeIfPresent(Double.self, forKey: .qualityOverride)
        output = try c.decodeIfPresent(OutputLocation.self, forKey: .output) ?? d.output
        discardLargerConversions = try c.decodeIfPresent(Bool.self, forKey: .discardLargerConversions) ?? false
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi)
        tiffCompression = try c.decodeIfPresent(TIFFCompression.self, forKey: .tiffCompression) ?? d.tiffCompression
        icoSizes = try c.decodeIfPresent([Int].self, forKey: .icoSizes) ?? d.icoSizes
        maxVideoHeight = try c.decodeIfPresent(Int.self, forKey: .maxVideoHeight)
        videoCodec = try c.decodeIfPresent(VideoCodecChoice.self, forKey: .videoCodec) ?? .automatic
        hardwareEncoding = try c.decodeIfPresent(Bool.self, forKey: .hardwareEncoding) ?? false
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate)
        mp3Bitrate = try c.decodeIfPresent(Int.self, forKey: .mp3Bitrate)
        nameTemplate = try c.decodeIfPresent(String.self, forKey: .nameTemplate)
        keepFileDates = try c.decodeIfPresent(Bool.self, forKey: .keepFileDates) ?? true
    }
}

/// Parses page ranges like "1-3, 5, 8-" into zero-based indices, bounded by `count`.
public enum PageRange {
    public static func parse(_ text: String, count: Int) -> [Int]? {
        var out: [Int] = []
        for part in text.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            let bounds = p.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bounds.count <= 2 else { return nil }
            let lo = bounds[0].isEmpty ? 1 : Int(bounds[0])
            let hi = bounds.count == 2 ? (bounds[1].isEmpty ? count : Int(bounds[1])) : lo
            guard let lo, let hi, lo >= 1, hi >= lo else { return nil }
            guard lo <= count else { continue } // pages past the end are ignored
            for i in lo...min(hi, count) where !out.contains(i - 1) { out.append(i - 1) }
        }
        return out.isEmpty ? nil : out
    }
}
