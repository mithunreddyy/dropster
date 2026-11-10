import Foundation
import ImageIO
import CoreGraphics
import Vision
import DropsterCore

/// Bitmap → SVG tracing with Vision's contour detector: outlines of the dark shapes,
/// filled with the even-odd rule so holes stay open. Best for logos, signatures, icons
/// and line art; photos become posterised silhouettes.
public struct TraceEngine: Engine {
    public let id = "trace"
    public let maxConcurrency = 4
    public let edges: [ConversionEdge]
    public let optimizable: Set<FormatID> = []

    public init() {
        edges = [FormatID.png, .jpeg, .heic, .tiff, .bmp, .gif, .webp, .avif].map {
            ConversionEdge(from: $0, to: .svg, cost: 4, engineID: "trace")
        }
    }

    public func run(_ ctx: StepContext) async throws {
        // Contour detection time grows quickly with size; 1024 px keeps logos crisp in about a second.
        let image = try ImageEditEngine.uprightImage(ctx.input, maxPixelSize: min(ctx.options.maxPixelSize ?? 1024, 2048))
        let svg = try Self.trace(image, detail: ctx.options.mode)
        try Data(svg.utf8).write(to: ctx.output)
        ctx.progress(1)
    }

    static func trace(_ image: CGImage, detail: CompressionMode) throws -> String {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = true
        request.contrastAdjustment = 1.5
        request.maximumImageDimension = min(2048, max(image.width, image.height))
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let obs = request.results?.first, obs.contourCount > 0 else {
            throw DropsterError.encodeFailed("no shapes were found to trace")
        }
        let w = Double(image.width), h = Double(image.height)
        // Smallest = fewest points; Balanced keeps more detail.
        let epsilon: Float = switch detail { case .smallest: 0.002; case .balanced: 0.0007; case .fastest: 0.001 }
        var d = ""
        func emit(_ c: VNContour) {
            let simplified = (try? c.polygonApproximation(epsilon: epsilon)) ?? c
            let pts = simplified.normalizedPoints
            guard pts.count >= 3 else { return }
            for (i, p) in pts.enumerated() {
                let x = Double(p.x) * w, y = (1 - Double(p.y)) * h
                d += (i == 0 ? "M" : "L") + String(format: "%.1f %.1f", x, y)
            }
            d += "Z"
            for child in c.childContours { emit(child) }
        }
        for c in obs.topLevelContours { emit(c) }
        guard !d.isEmpty else { throw DropsterError.encodeFailed("no shapes were found to trace") }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(w))" height="\(Int(h))" viewBox="0 0 \(Int(w)) \(Int(h))">
        <path fill="#000" fill-rule="evenodd" d="\(d)"/>
        </svg>

        """
    }
}
