import Foundation

/// Everything Dropster learned about a file during analysis.
public struct FileReport: Sendable, Hashable, Codable {
    public var url: URL
    public var byteSize: Int64
    /// Format detected from content (signature + decoder probe).
    public var detectedFormat: FormatID?
    /// Format implied by the extension alone.
    public var extensionFormat: FormatID?
    public var image: ImageTraits?
    public var media: MediaTraits?
    public var pageCount: Int?

    public init(url: URL, byteSize: Int64, detectedFormat: FormatID?, extensionFormat: FormatID?,
                image: ImageTraits? = nil, media: MediaTraits? = nil, pageCount: Int? = nil) {
        self.url = url
        self.byteSize = byteSize
        self.detectedFormat = detectedFormat
        self.extensionFormat = extensionFormat
        self.image = image
        self.media = media
        self.pageCount = pageCount
    }

    /// The format Dropster will treat the file as.
    public var format: FormatID? { detectedFormat ?? extensionFormat }

    public var extensionMismatch: Bool {
        guard let d = detectedFormat, let e = extensionFormat else { return false }
        if d == e { return false }
        // Container families that legitimately share extensions.
        let equivalent: Set<Set<FormatID>> = [[.mp4, .mov], [.mp4, .m4a], [.mkv, .webm], [.heic, .avif]]
        return !equivalent.contains([d, e])
    }
}

public struct ImageTraits: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var hasAlpha: Bool
    public var bitsPerComponent: Int
    public var colorModel: String?
    public var colorProfile: String?
    public var frameCount: Int
    public var orientation: Int
    public var hasEXIF: Bool
    public var hasGPS: Bool
    public var estimatedJPEGQuality: Int?

    public init(width: Int, height: Int, hasAlpha: Bool, bitsPerComponent: Int, colorModel: String?,
                colorProfile: String?, frameCount: Int, orientation: Int, hasEXIF: Bool, hasGPS: Bool,
                estimatedJPEGQuality: Int?) {
        self.width = width
        self.height = height
        self.hasAlpha = hasAlpha
        self.bitsPerComponent = bitsPerComponent
        self.colorModel = colorModel
        self.colorProfile = colorProfile
        self.frameCount = frameCount
        self.orientation = orientation
        self.hasEXIF = hasEXIF
        self.hasGPS = hasGPS
        self.estimatedJPEGQuality = estimatedJPEGQuality
    }

    public var megapixels: Double { Double(width * height) / 1_000_000 }
    public var isAnimated: Bool { frameCount > 1 }
}

public struct MediaTraits: Sendable, Hashable, Codable {
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var bitRate: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var bitsPerSample: Int?

    public init(duration: Double? = nil, videoCodec: String? = nil, audioCodec: String? = nil, width: Int? = nil,
                height: Int? = nil, frameRate: Double? = nil, bitRate: Int? = nil, sampleRate: Int? = nil,
                channels: Int? = nil, bitsPerSample: Int? = nil) {
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    public var hasVideo: Bool { videoCodec != nil }
}
