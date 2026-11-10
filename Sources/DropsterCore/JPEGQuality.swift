import Foundation

/// Estimates the IJG-equivalent quality (1...100) a JPEG was saved at by comparing
/// its luminance quantisation table to the standard Annex K table.
///
/// This lets Dropster enforce a *quality ceiling*: re-encoding a q=75 phone photo
/// at q=85 only makes it bigger without restoring detail.
public enum JPEGQuality {
    static let standardLuminance: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]

    public static func estimate(url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // DQT segments precede the scan data; 256 KiB covers large EXIF/ICC blocks.
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        return estimate(Array(data))
    }

    public static func estimate(_ bytes: [UInt8]) -> Int? {
        guard let table = luminanceTable(bytes) else { return nil }
        // Table entries are stored in zig-zag order; the standard table above is too
        // when compared element-wise, because libjpeg scales each entry independently.
        // Average the per-coefficient scale factor, ignoring clamped entries.
        var total = 0.0
        var count = 0.0
        for (q, s) in zip(table, zigzagStandard) where q > 1 && q < 255 {
            total += Double(q) * 100.0 / Double(s)
            count += 1
        }
        if count == 0 {
            // Every entry clamped to 1 means quality 100.
            return table.allSatisfy { $0 <= 1 } ? 100 : nil
        }
        let scale = total / count
        let quality = scale <= 100 ? (200 - scale) / 2 : 5000 / scale
        return max(1, min(100, Int(quality.rounded())))
    }

    /// Standard table rearranged into zig-zag order to match DQT storage.
    static let zigzagStandard: [Int] = {
        let zigzag: [Int] = [
            0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
            12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
            35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
            58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
        ]
        return zigzag.map { standardLuminance[$0] }
    }()

    static func luminanceTable(_ b: [UInt8]) -> [Int]? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD9 || marker == 0xDA { return nil } // EOI / SOS: no DQT found
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { return nil }
            if marker == 0xDB {
                var p = i + 4
                let end = min(i + 2 + length, b.count)
                while p < end {
                    let pq = b[p] >> 4
                    let tq = b[p] & 0x0F
                    let entrySize = pq == 0 ? 1 : 2
                    let tableEnd = p + 1 + 64 * entrySize
                    guard tableEnd <= b.count else { return nil }
                    if tq == 0 {
                        return (0..<64).map { k in
                            entrySize == 1 ? Int(b[p + 1 + k]) : Int(b[p + 1 + 2 * k]) << 8 | Int(b[p + 2 + 2 * k])
                        }
                    }
                    p = tableEnd
                }
            }
            i += 2 + length
        }
        return nil
    }
}
