import Foundation

/// Removes metadata segments from a JPEG without decoding or re-encoding the image.
/// The entropy-coded scan is copied byte for byte, so the result is pixel-identical.
enum JPEGMetadata {
    /// Keeps APP0 (JFIF), APP2 ICC_PROFILE (colour) and APP14 (Adobe colour transform).
    /// Drops APP1 (EXIF/XMP), APP13 (IPTC/Photoshop), COM and all other APPn.
    /// If the image had a non-default EXIF orientation, a minimal EXIF block carrying
    /// only that tag is written so the photo still displays upright.
    static func strip(_ b: [UInt8], orientation: Int) throws -> [UInt8] {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw PNGError.malformed("not a JPEG") }
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        var insertedOrientation = orientation == 1
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { throw PNGError.malformed("JPEG marker expected at \(i)") }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { out += [0xFF, marker]; i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { throw PNGError.malformed("segment overruns file") }
            let segment = b[i..<(i + 2 + len)]
            let payload = b[(i + 4)..<(i + 2 + len)]
            var keep: Bool
            switch marker {
            case 0xE0: keep = true
            case 0xE2: keep = payload.starts(with: Array("ICC_PROFILE\0".utf8))
            case 0xEE: keep = true
            case 0xE1...0xEF, 0xFE: keep = false
            default: keep = true
            }
            if !insertedOrientation && marker != 0xE0 {
                out += orientationSegment(orientation)
                insertedOrientation = true
            }
            if keep { out += segment }
            i += 2 + len
            if marker == 0xDA {
                // Start of scan: everything after the header is image data, copy verbatim.
                out += b[i...]
                return out
            }
        }
        throw PNGError.malformed("no image data in JPEG")
    }

    static func orientationSegment(_ o: Int) -> [UInt8] {
        // "Exif\0\0" + big-endian TIFF header + one IFD entry (0x0112 SHORT 1 = o) + no next IFD.
        let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
                             0x00, 0x01,
                             0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, UInt8(o), 0x00, 0x00,
                             0x00, 0x00, 0x00, 0x00]
        let payload = Array("Exif".utf8) + [0, 0] + tiff
        let len = payload.count + 2
        return [0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
    }

    /// APP2 ICC_PROFILE segments (a profile may span several) in file order.
    static func iccSegments(_ b: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { break }
            if marker == 0xE2, b[(i + 4)..<(i + 2 + len)].starts(with: Array("ICC_PROFILE\0".utf8)) {
                out.append(Array(b[i..<(i + 2 + len)]))
            }
            i += 2 + len
        }
        return out
    }

    /// Inserts segments right after SOI/APP0 of `jpeg`, replacing any ICC segments it had.
    static func insert(_ segments: [[UInt8]], into jpeg: [UInt8]) throws -> [UInt8] {
        guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { throw PNGError.malformed("not a JPEG") }
        var i = 2
        var head: [UInt8] = [0xFF, 0xD8]
        if jpeg[2] == 0xFF, jpeg[3] == 0xE0 {
            let len = Int(jpeg[4]) << 8 | Int(jpeg[5])
            head += jpeg[2..<(4 + len)]
            i = 4 + len
        }
        var body: [UInt8] = []
        // Drop existing ICC segments from the encoder's output.
        var j = i
        while j + 4 <= jpeg.count, jpeg[j] == 0xFF, jpeg[j + 1] != 0xDA {
            let len = Int(jpeg[j + 2]) << 8 | Int(jpeg[j + 3])
            guard j + 2 + len <= jpeg.count else { throw PNGError.malformed("segment overruns file") }
            let isICC = jpeg[j + 1] == 0xE2 && jpeg[(j + 4)..<(j + 2 + len)].starts(with: Array("ICC_PROFILE\0".utf8))
            if !isICC { body += jpeg[j..<(j + 2 + len)] }
            j += 2 + len
        }
        body += jpeg[j...]
        return head + segments.flatMap { $0 } + body
    }

    /// Inserts one segment after SOI (and APP0 when present), leaving everything else as is.
    static func insertAfterAPP0(_ segment: [UInt8], into b: [UInt8]) throws -> [UInt8] {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw PNGError.malformed("not a JPEG") }
        var at = 2
        if b[2] == 0xFF, b[3] == 0xE0 { at = 4 + (Int(b[4]) << 8 | Int(b[5])) }
        guard at <= b.count else { throw PNGError.malformed("segment overruns file") }
        return Array(b[..<at]) + segment + Array(b[at...])
    }
}
