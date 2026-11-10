import Foundation
import zlib
import DropsterCore

/// Pixels in a normalised form: 1–4 channels (G, GA, RGB, RGBA), 8 or 16 bits,
/// rows packed without padding, 16-bit samples big-endian.
struct PNGPixels: Equatable {
    var width: Int
    var height: Int
    var channels: Int
    var depth: Int
    var data: [UInt8]

    var hasAlpha: Bool { channels == 2 || channels == 4 }
    var bytesPerSample: Int { depth / 8 }
    var sampleCount: Int { width * height * channels }

    func sample(_ i: Int) -> Int {
        depth == 8 ? Int(data[i]) : Int(data[2 * i]) << 8 | Int(data[2 * i + 1])
    }

    /// One pixel as RGBA 16-bit, whatever the stored layout.
    @inline(__always) func rgba16(_ p: Int) -> SIMD4<UInt16> {
        let base = p * channels
        let scale = depth == 8 ? 257 : 1
        let opaque = 65535
        let v: SIMD4<Int> = switch channels {
        case 1: { let g = sample(base) * scale; return SIMD4(g, g, g, opaque) }()
        case 2: { let g = sample(base) * scale; return SIMD4(g, g, g, sample(base + 1) * scale) }()
        case 3: SIMD4(sample(base) * scale, sample(base + 1) * scale, sample(base + 2) * scale, opaque)
        default: SIMD4(sample(base) * scale, sample(base + 1) * scale, sample(base + 2) * scale, sample(base + 3) * scale)
        }
        return SIMD4<UInt16>(truncatingIfNeeded: v)
    }

    /// Expands to RGBA 16-bit so two images can be compared regardless of layout.
    func canonicalRGBA16() -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * height * 4)
        let scale = depth == 8 ? 257 : 1
        for p in 0..<(width * height) {
            let base = p * channels
            let v: (Int, Int, Int, Int)
            switch channels {
            case 1: let g = sample(base); v = (g, g, g, depth == 8 ? 255 : 65535)
            case 2: let g = sample(base); v = (g, g, g, sample(base + 1))
            case 3: v = (sample(base), sample(base + 1), sample(base + 2), depth == 8 ? 255 : 65535)
            default: v = (sample(base), sample(base + 1), sample(base + 2), sample(base + 3))
            }
            out[p * 4] = UInt16(v.0 * scale); out[p * 4 + 1] = UInt16(v.1 * scale)
            out[p * 4 + 2] = UInt16(v.2 * scale); out[p * 4 + 3] = UInt16(v.3 * scale)
        }
        return out
    }
}

struct PNGChunk {
    var type: String
    var data: [UInt8]
}

struct PNGFile {
    var pixels: PNGPixels
    var ancillary: [PNGChunk]
    var colorType: Int
    var bitDepth: Int
    var interlaced: Bool
}

enum PNGError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    var description: String {
        switch self {
        case .malformed(let s): "malformed PNG: \(s)"
        case .unsupported(let s): s
        }
    }
}

enum PNGCodec {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Safety limits for hostile input.
    static let maxPixels = 268_435_456 // 16384 × 16384
    static let maxCompressedBytes = 1 << 30

    // MARK: Decoding

    static func decode(_ b: [UInt8]) throws -> PNGFile {
        guard b.count > 8, Array(b[0..<8]) == signature else { throw PNGError.malformed("bad signature") }
        var i = 8
        var ihdr: [UInt8]?
        var palette: [UInt8] = []
        var trns: [UInt8]?
        var idat: [UInt8] = []
        var ancillary: [PNGChunk] = []
        var sawIEND = false
        while i + 12 <= b.count {
            let len = Int(be32(b, i))
            guard len <= 0x7FFF_FFFF, i + 12 + len <= b.count else { throw PNGError.malformed("chunk overruns file") }
            let typeBytes = Array(b[(i + 4)..<(i + 8)])
            let type = String(decoding: typeBytes, as: UTF8.self)
            let data = Array(b[(i + 8)..<(i + 8 + len)])
            let crc = be32(b, i + 8 + len)
            var c = crc32(0, typeBytes, 4)
            c = data.withUnsafeBufferPointer { crc32(c, $0.baseAddress, uInt(len)) }
            guard UInt32(c) == crc else { throw PNGError.malformed("CRC mismatch in \(type)") }
            i += 12 + len
            switch type {
            case "IHDR": ihdr = data
            case "PLTE": palette = data
            case "tRNS": trns = data
            case "IDAT":
                idat += data
                guard idat.count <= maxCompressedBytes else { throw PNGError.malformed("image data too large") }
            case "IEND": sawIEND = true
            case "acTL", "fcTL", "fdAT": throw PNGError.unsupported("Animated PNG is not supported by the lossless optimizer")
            default:
                // Lowercase first letter = ancillary. Unknown critical chunks cannot be safely dropped.
                guard typeBytes[0] & 0x20 != 0 else { throw PNGError.unsupported("unknown critical chunk \(type)") }
                ancillary.append(PNGChunk(type: type, data: data))
            }
            if sawIEND { break }
        }
        guard let h = ihdr, h.count == 13 else { throw PNGError.malformed("missing IHDR") }
        let width = Int(be32(h, 0)), height = Int(be32(h, 4))
        let depth = Int(h[8]), colorType = Int(h[9]), interlace = Int(h[12])
        guard width > 0, height > 0, width * height <= maxPixels else { throw PNGError.malformed("dimensions out of range") }
        guard h[10] == 0, h[11] == 0, interlace <= 1 else { throw PNGError.malformed("unknown compression/filter/interlace") }
        let channels: Int
        switch (colorType, depth) {
        case (0, 1), (0, 2), (0, 4), (0, 8), (0, 16): channels = 1
        case (2, 8), (2, 16): channels = 3
        case (3, 1), (3, 2), (3, 4), (3, 8): channels = 1
        case (4, 8), (4, 16): channels = 2
        case (6, 8), (6, 16): channels = 4
        default: throw PNGError.malformed("invalid colour type/bit depth")
        }
        guard !idat.isEmpty else { throw PNGError.malformed("no image data") }

        // Compute expected raw size per Adam7 pass (or the single full pass).
        let passes: [(x0: Int, y0: Int, dx: Int, dy: Int)] = interlace == 1
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        let bitsPerPixel = channels * depth
        var passDims: [(w: Int, h: Int)] = []
        var expected = 0
        for p in passes {
            let pw = (width - p.x0 + p.dx - 1) / p.dx, ph = (height - p.y0 + p.dy - 1) / p.dy
            let w = width > p.x0 ? pw : 0, hh = height > p.y0 ? ph : 0
            passDims.append((w, hh))
            if w > 0 && hh > 0 { expected += hh * (1 + (w * bitsPerPixel + 7) / 8) }
        }
        var raw = try inflate(idat, expected: expected)
        guard raw.count == expected else { throw PNGError.malformed("image data size mismatch") }

        // Unfilter each pass, then scatter into a full-size packed buffer.
        let bpp = max(1, bitsPerPixel / 8)
        let fullRowBytes = (width * bitsPerPixel + 7) / 8
        var packed = [UInt8](repeating: 0, count: interlace == 1 ? fullRowBytes * height : 0)
        var offset = 0
        for (pi, dims) in passDims.enumerated() where dims.w > 0 && dims.h > 0 {
            let rowBytes = (dims.w * bitsPerPixel + 7) / 8
            try unfilter(&raw, offset: offset, rowBytes: rowBytes, rows: dims.h, bpp: bpp)
            if interlace == 1 {
                let p = passes[pi]
                for y in 0..<dims.h {
                    let src = offset + y * (rowBytes + 1) + 1
                    let dy = p.y0 + y * p.dy
                    for x in 0..<dims.w {
                        let dx = p.x0 + x * p.dx
                        copyPixel(from: raw, srcBase: src, srcIndex: x, to: &packed, dstBase: dy * fullRowBytes, dstIndex: dx, bitsPerPixel: bitsPerPixel)
                    }
                }
            }
            offset += dims.h * (rowBytes + 1)
        }
        if interlace == 0 {
            // Strip the filter-type byte from each row.
            packed = [UInt8](repeating: 0, count: fullRowBytes * height)
            raw.withUnsafeBufferPointer { src in
                packed.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<height {
                        let s = y * (fullRowBytes + 1) + 1
                        dst.baseAddress!.advanced(by: y * fullRowBytes).update(from: src.baseAddress!.advanced(by: s), count: fullRowBytes)
                    }
                }
            }
        }
        let pixels = try expand(packed: packed, width: width, height: height, colorType: colorType, depth: depth,
                                rowBytes: fullRowBytes, palette: palette, trns: trns)
        return PNGFile(pixels: pixels, ancillary: ancillary, colorType: colorType, bitDepth: depth, interlaced: interlace == 1)
    }

    private static func copyPixel(from src: [UInt8], srcBase: Int, srcIndex: Int, to dst: inout [UInt8], dstBase: Int, dstIndex: Int, bitsPerPixel: Int) {
        if bitsPerPixel >= 8 {
            let n = bitsPerPixel / 8
            for k in 0..<n { dst[dstBase + dstIndex * n + k] = src[srcBase + srcIndex * n + k] }
        } else {
            let sbit = srcIndex * bitsPerPixel, dbit = dstIndex * bitsPerPixel
            let mask = UInt8((1 << bitsPerPixel) - 1)
            let v = (src[srcBase + sbit / 8] >> UInt8(8 - bitsPerPixel - sbit % 8)) & mask
            dst[dstBase + dbit / 8] |= v << UInt8(8 - bitsPerPixel - dbit % 8)
        }
    }

    private static func unfilter(_ d: inout [UInt8], offset: Int, rowBytes: Int, rows: Int, bpp: Int) throws {
        try d.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            for y in 0..<rows {
                let rowStart = offset + y * (rowBytes + 1)
                let filter = p[rowStart]
                let cur = p + rowStart + 1
                let prev: UnsafeMutablePointer<UInt8>? = y > 0 ? p + rowStart - rowBytes : nil
                switch filter {
                case 0: break
                case 1: if rowBytes > bpp { for x in bpp..<rowBytes { cur[x] &+= cur[x - bpp] } }
                case 2: if let prev { for x in 0..<rowBytes { cur[x] &+= prev[x] } }
                case 3:
                    for x in 0..<rowBytes {
                        let a = x >= bpp ? Int(cur[x - bpp]) : 0
                        let b = prev.map { Int($0[x]) } ?? 0
                        cur[x] &+= UInt8((a + b) >> 1)
                    }
                case 4:
                    for x in 0..<rowBytes {
                        let a = x >= bpp ? Int(cur[x - bpp]) : 0
                        let b = prev.map { Int($0[x]) } ?? 0
                        let c = (x >= bpp ? prev.map { Int($0[x - bpp]) } : nil) ?? 0
                        cur[x] &+= UInt8(paeth(a, b, c))
                    }
                default: throw PNGError.malformed("bad filter type \(filter)")
                }
            }
        }
    }

    @inline(__always) static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
    }

    private static func expand(packed: [UInt8], width: Int, height: Int, colorType: Int, depth: Int, rowBytes: Int,
                               palette: [UInt8], trns: [UInt8]?) throws -> PNGPixels {
        func lowBits(_ y: Int, _ x: Int) -> Int {
            let bit = x * depth
            return Int(packed[y * rowBytes + bit / 8] >> UInt8(8 - depth - bit % 8)) & ((1 << depth) - 1)
        }
        switch colorType {
        case 3:
            guard !palette.isEmpty, palette.count % 3 == 0 else { throw PNGError.malformed("missing palette") }
            let entries = palette.count / 3
            let alpha = trns ?? []
            let withAlpha = alpha.contains { $0 != 255 }
            let ch = withAlpha ? 4 : 3
            var out = [UInt8](repeating: 0, count: width * height * ch)
            for y in 0..<height {
                for x in 0..<width {
                    let idx = depth == 8 ? Int(packed[y * rowBytes + x]) : lowBits(y, x)
                    guard idx < entries else { throw PNGError.malformed("palette index out of range") }
                    let o = (y * width + x) * ch
                    out[o] = palette[idx * 3]; out[o + 1] = palette[idx * 3 + 1]; out[o + 2] = palette[idx * 3 + 2]
                    if withAlpha { out[o + 3] = idx < alpha.count ? alpha[idx] : 255 }
                }
            }
            return PNGPixels(width: width, height: height, channels: ch, depth: 8, data: out)
        case 0:
            let outDepth = depth == 16 ? 16 : 8
            let key: Int? = trns.flatMap { $0.count >= 2 ? Int($0[0]) << 8 | Int($0[1]) : nil }
            let ch = key == nil ? 1 : 2
            let bps = outDepth / 8
            var out = [UInt8](repeating: 0, count: width * height * ch * bps)
            let maxV = (1 << depth) - 1
            for y in 0..<height {
                for x in 0..<width {
                    let rawV: Int = switch depth {
                    case 16: Int(packed[y * rowBytes + 2 * x]) << 8 | Int(packed[y * rowBytes + 2 * x + 1])
                    case 8: Int(packed[y * rowBytes + x])
                    default: lowBits(y, x)
                    }
                    let v = depth < 8 ? rawV * 255 / maxV : rawV
                    let o = (y * width + x) * ch * bps
                    put(&out, o, v, bps)
                    if let key { put(&out, o + bps, rawV == key ? 0 : (outDepth == 16 ? 65535 : 255), bps) }
                }
            }
            return PNGPixels(width: width, height: height, channels: ch, depth: outDepth, data: out)
        case 2:
            let bps = depth / 8
            guard let t = trns, t.count >= 6 else { return PNGPixels(width: width, height: height, channels: 3, depth: depth, data: packed) }
            let key = (Int(t[0]) << 8 | Int(t[1]), Int(t[2]) << 8 | Int(t[3]), Int(t[4]) << 8 | Int(t[5]))
            var out = [UInt8](repeating: 0, count: width * height * 4 * bps)
            let opaque = depth == 16 ? 65535 : 255
            for p in 0..<(width * height) {
                var rgb = [0, 0, 0]
                for c in 0..<3 {
                    let s = (p * 3 + c) * bps
                    rgb[c] = bps == 1 ? Int(packed[s]) : Int(packed[s]) << 8 | Int(packed[s + 1])
                    put(&out, (p * 4 + c) * bps, rgb[c], bps)
                }
                put(&out, (p * 4 + 3) * bps, (rgb[0], rgb[1], rgb[2]) == key ? 0 : opaque, bps)
            }
            return PNGPixels(width: width, height: height, channels: 4, depth: depth, data: out)
        case 4: return PNGPixels(width: width, height: height, channels: 2, depth: depth, data: packed)
        default: return PNGPixels(width: width, height: height, channels: 4, depth: depth, data: packed)
        }
    }

    @inline(__always) private static func put(_ a: inout [UInt8], _ o: Int, _ v: Int, _ bps: Int) {
        if bps == 1 { a[o] = UInt8(v) } else { a[o] = UInt8(v >> 8); a[o + 1] = UInt8(v & 0xFF) }
    }

    static func inflate(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expected)
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw PNGError.malformed("zlib init") }
        defer { inflateEnd(&stream) }
        var status: Int32 = Z_OK
        var produced = 0
        input.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                status = zlib.inflate(&stream, Z_FINISH)
                produced = outBuf.count - Int(stream.avail_out)
            }
        }
        // Z_BUF_ERROR with a full buffer means trailing data beyond the image: tolerated, like libpng.
        guard status == Z_STREAM_END || (status == Z_BUF_ERROR && produced == expected) else {
            throw PNGError.malformed("corrupt image data (zlib \(status))")
        }
        guard produced == expected else { throw PNGError.malformed("truncated image data") }
        return out
    }

    @inline(__always) static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

// MARK: - Optimizing encoder

/// Lossless PNG optimizer.
///
/// 1. Reduce the pixel layout without losing information: 16→8 bit when every sample
///    is a repeated byte, drop an all-opaque alpha channel, RGB→gray when R=G=B,
///    truecolor→palette when ≤256 colours, and pack gray/palette into 1/2/4 bits.
/// 2. For each layout, try several scanline filter strategies (none, per-row minimum
///    sum of absolute differences, fixed Paeth) and zlib strategies, in parallel.
/// 3. Keep the smallest stream, then decode it again and compare every pixel.
enum PNGOptimizer {
    struct Encoding {
        enum Layout: Equatable { case gray(Int), grayAlpha(Int), rgb(Int), rgba(Int), palette(Int, [UInt32]) }
        var layout: Layout
        var rows: [UInt8]   // packed scanlines without filter bytes
        var rowBytes: Int
        var bpp: Int
    }

    enum FilterStrategy: CaseIterable { case none, minSum, paeth }

    struct Attempt { var filter: FilterStrategy; var zStrategy: Int32 }

    static func attempts(for mode: CompressionMode, palettised: Bool) -> [Attempt] {
        switch mode {
        case .fastest: return [Attempt(filter: palettised ? .none : .minSum, zStrategy: Z_DEFAULT_STRATEGY)]
        case .balanced:
            return [Attempt(filter: .none, zStrategy: Z_DEFAULT_STRATEGY), Attempt(filter: .minSum, zStrategy: Z_DEFAULT_STRATEGY),
                    Attempt(filter: .minSum, zStrategy: Z_FILTERED)]
        case .smallest:
            return FilterStrategy.allCases.flatMap { f in
                [Z_DEFAULT_STRATEGY, Z_FILTERED, Z_RLE].map { Attempt(filter: f, zStrategy: $0) }
            }
        }
    }

    static func optimize(_ input: [UInt8], mode: CompressionMode, metadata: MetadataPolicy) throws -> [UInt8] {
        let file = try PNGCodec.decode(input)
        let reduced = reduce(file.pixels)
        var encodings = [encoding(for: reduced)]
        if let pal = paletteEncoding(for: reduced) { encodings.append(pal) }

        let level: Int32 = mode == .fastest ? 6 : 9
        var jobs: [(Encoding, Attempt)] = []
        for e in encodings {
            if case .palette = e.layout { jobs += attempts(for: mode, palettised: true).map { (e, $0) } }
            else { jobs += attempts(for: mode, palettised: false).map { (e, $0) } }
        }
        // Large images: score every candidate on three sample bands, then compress only the
        // two most promising at full size. Rankings on samples track full-image rankings
        // closely, and this cuts work on a 34 MP image from nine full passes to two.
        let rawSize = encodings.map(\.rows.count).max() ?? 0
        if rawSize > 8 * 1024 * 1024 && jobs.count > 2 {
            let sampled = jobs.map { (sample($0.0, bandRows: 128, bands: 3), $0.1) }
            let scores = compress(sampled, level: level)
            let ranked = scores.indices.sorted { (scores[$0]?.count ?? .max) < (scores[$1]?.count ?? .max) }
            jobs = ranked.prefix(2).map { jobs[$0] }
        }
        let results = compress(jobs, level: level)
        var bestIndex = -1
        for i in 0..<jobs.count {
            guard let r = results[i] else { continue }
            if bestIndex < 0 || r.count < results[bestIndex]!.count { bestIndex = i }
        }
        guard bestIndex >= 0, let idat = results[bestIndex] else { throw PNGError.malformed("compression failed") }
        let output = assemble(jobs[bestIndex].0, idat: idat, width: reduced.width, height: reduced.height,
                              ancillary: keepChunks(file.ancillary, policy: metadata))

        // Prove the optimisation was lossless before anyone sees it.
        let check = try PNGCodec.decode(output)
        guard samePixels(check.pixels, file.pixels) else {
            throw DropsterError.verificationFailed("optimized PNG pixels differ from the original")
        }
        return output
    }

    /// Runs filter + deflate for each job, as many in parallel as fit a 512 MB budget
    /// (each attempt holds a filtered copy plus a deflate buffer, ~2.2× the raw rows).
    static func compress(_ jobs: [(Encoding, Attempt)], level: Int32) -> [[UInt8]?] {
        let results = UnsafeMutableBufferPointer<[UInt8]?>.allocate(capacity: jobs.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        let perAttempt = max(1, (jobs.map(\.0.rows.count).max() ?? 0) * 22 / 10)
        let width = max(1, min(jobs.count, 512 * 1024 * 1024 / perAttempt))
        var start = 0
        while start < jobs.count {
            let batch = min(width, jobs.count - start)
            let base = start
            DispatchQueue.concurrentPerform(iterations: batch) { k in
                let (e, a) = jobs[base + k]
                results[base + k] = deflate(filter(e, strategy: a.filter), level: level, strategy: a.zStrategy)
            }
            start += batch
        }
        return Array(results)
    }

    /// Evenly spaced horizontal bands of an encoding, for cheap trial compression.
    static func sample(_ e: Encoding, bandRows: Int, bands: Int) -> Encoding {
        let height = e.rows.count / max(e.rowBytes, 1)
        guard height > bandRows * bands else { return e }
        var rows: [UInt8] = []
        rows.reserveCapacity(bandRows * bands * e.rowBytes)
        for b in 0..<bands {
            let y0 = (height - bandRows) * b / max(1, bands - 1)
            rows += e.rows[(y0 * e.rowBytes)..<((y0 + bandRows) * e.rowBytes)]
        }
        var s = e
        s.rows = rows
        return s
    }

    /// Pixel equality across layouts, compared one pixel at a time (no RGBA16 copies).
    static func samePixels(_ a: PNGPixels, _ b: PNGPixels) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        for p in 0..<(a.width * a.height) where a.rgba16(p) != b.rgba16(p) { return false }
        return true
    }

    // MARK: Reduction

    static func reduce(_ p: PNGPixels) -> PNGPixels {
        var px = p
        // 16 → 8 bit when every sample is v * 257.
        if px.depth == 16 {
            var ok = true
            px.data.withUnsafeBufferPointer { d in
                var i = 0
                while i < d.count { if d[i] != d[i + 1] { ok = false; break }; i += 2 }
            }
            if ok {
                px.data = stride(from: 0, to: px.data.count, by: 2).map { px.data[$0] }
                px.depth = 8
            }
        }
        // Drop an alpha channel that is fully opaque everywhere.
        if px.hasAlpha {
            let maxA = px.depth == 8 ? 255 : 65535
            let n = px.width * px.height
            var opaque = true
            for i in 0..<n where px.sample(i * px.channels + px.channels - 1) != maxA { opaque = false; break }
            if opaque { px = dropChannel(px, index: px.channels - 1) }
        }
        // RGB(A) → Gray(A) when every pixel is neutral.
        if px.channels >= 3 {
            let n = px.width * px.height
            var neutral = true
            for i in 0..<n {
                let b = i * px.channels
                let r = px.sample(b)
                if px.sample(b + 1) != r || px.sample(b + 2) != r { neutral = false; break }
            }
            if neutral {
                px = dropChannel(px, index: 2)
                px = dropChannel(px, index: 1)
            }
        }
        return px
    }

    private static func dropChannel(_ p: PNGPixels, index: Int) -> PNGPixels {
        let bps = p.bytesPerSample
        let n = p.width * p.height
        var out = [UInt8](repeating: 0, count: n * (p.channels - 1) * bps)
        var o = 0
        for i in 0..<n {
            for c in 0..<p.channels where c != index {
                let s = (i * p.channels + c) * bps
                for k in 0..<bps { out[o + k] = p.data[s + k] }
                o += bps
            }
        }
        return PNGPixels(width: p.width, height: p.height, channels: p.channels - 1, depth: p.depth, data: out)
    }

    static func encoding(for p: PNGPixels) -> Encoding {
        if p.channels == 1 && p.depth == 8 {
            // Smallest gray depth that represents every value exactly.
            var depth = 1
            for v in p.data {
                if depth == 1 && v != 0 && v != 255 { depth = 2 }
                if depth == 2 && v % 85 != 0 { depth = 4 }
                if depth == 4 && v % 17 != 0 { depth = 8; break }
            }
            if depth < 8 {
                let maxV = (1 << depth) - 1
                let rows = pack(p.data.map { Int($0) * maxV / 255 }, width: p.width, height: p.height, depth: depth)
                return Encoding(layout: .gray(depth), rows: rows, rowBytes: (p.width * depth + 7) / 8, bpp: 1)
            }
        }
        let bpp = p.channels * p.bytesPerSample
        let layout: Encoding.Layout = switch p.channels {
        case 1: .gray(p.depth)
        case 2: .grayAlpha(p.depth)
        case 3: .rgb(p.depth)
        default: .rgba(p.depth)
        }
        return Encoding(layout: layout, rows: p.data, rowBytes: p.width * bpp, bpp: bpp)
    }

    /// Builds a palette when the image has at most 256 distinct colours.
    /// Translucent entries go first so the tRNS chunk stays short.
    static func paletteEncoding(for p: PNGPixels) -> Encoding? {
        guard p.depth == 8 else { return nil }
        let n = p.width * p.height
        var counts: [UInt32: Int] = [:]
        counts.reserveCapacity(257)
        var keys = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let b = i * p.channels
            let key: UInt32
            switch p.channels {
            case 1: let g = UInt32(p.data[b]); key = g << 24 | g << 16 | g << 8 | 0xFF
            case 2: let g = UInt32(p.data[b]); key = g << 24 | g << 16 | g << 8 | UInt32(p.data[b + 1])
            case 3: key = UInt32(p.data[b]) << 24 | UInt32(p.data[b + 1]) << 16 | UInt32(p.data[b + 2]) << 8 | 0xFF
            default: key = UInt32(p.data[b]) << 24 | UInt32(p.data[b + 1]) << 16 | UInt32(p.data[b + 2]) << 8 | UInt32(p.data[b + 3])
            }
            keys[i] = key
            counts[key, default: 0] += 1
            if counts.count > 256 { return nil }
        }
        let entries = counts.keys.sorted { a, b in
            let aa = a & 0xFF, ba = b & 0xFF
            if (aa == 255) != (ba == 255) { return aa != 255 }
            let ca = counts[a]!, cb = counts[b]!
            return ca != cb ? ca > cb : a < b
        }
        var index: [UInt32: Int] = [:]
        for (i, e) in entries.enumerated() { index[e] = i }
        let depth = entries.count <= 2 ? 1 : entries.count <= 4 ? 2 : entries.count <= 16 ? 4 : 8
        let rows = pack(keys.map { index[$0]! }, width: p.width, height: p.height, depth: depth)
        return Encoding(layout: .palette(depth, entries), rows: rows, rowBytes: (p.width * depth + 7) / 8, bpp: 1)
    }

    private static func pack(_ values: [Int], width: Int, height: Int, depth: Int) -> [UInt8] {
        if depth == 8 { return values.map { UInt8($0) } }
        let rowBytes = (width * depth + 7) / 8
        var out = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let bit = x * depth
                out[y * rowBytes + bit / 8] |= UInt8(values[y * width + x]) << UInt8(8 - depth - bit % 8)
            }
        }
        return out
    }

    // MARK: Filtering & deflate

    static func filter(_ e: Encoding, strategy: FilterStrategy) -> [UInt8] {
        let rb = e.rowBytes, bpp = e.bpp
        let height = e.rows.count / max(rb, 1)
        var out = [UInt8](repeating: 0, count: height * (rb + 1))
        let zero = [UInt8](repeating: 0, count: rb)
        var scratch = [UInt8](repeating: 0, count: rb * 5)
        e.rows.withUnsafeBufferPointer { rows in
            zero.withUnsafeBufferPointer { z in
                scratch.withUnsafeMutableBufferPointer { sc in
                    out.withUnsafeMutableBufferPointer { o in
                        for y in 0..<height {
                            let cur = rows.baseAddress! + y * rb
                            let prev = y > 0 ? rows.baseAddress! + (y - 1) * rb : z.baseAddress!
                            let filters: ClosedRange<Int> = switch strategy {
                            case .none: 0...0
                            case .paeth: 4...4
                            case .minSum: 0...4
                            }
                            var best = filters.lowerBound
                            var bestSum = Int.max
                            for f in filters {
                                let dst = sc.baseAddress! + f * rb
                                applyFilter(f, cur: cur, prev: prev, count: rb, bpp: bpp, into: dst)
                                if filters.count == 1 { break }
                                var sum = 0
                                for x in 0..<rb { sum += Int(Int8(bitPattern: dst[x]).magnitude) }
                                if sum < bestSum { bestSum = sum; best = f }
                            }
                            let row = o.baseAddress! + y * (rb + 1)
                            row[0] = UInt8(best)
                            (row + 1).update(from: sc.baseAddress! + best * rb, count: rb)
                        }
                    }
                }
            }
        }
        return out
    }

    @inline(__always)
    static func applyFilter(_ f: Int, cur: UnsafePointer<UInt8>, prev: UnsafePointer<UInt8>, count rb: Int, bpp: Int,
                            into d: UnsafeMutablePointer<UInt8>) {
        let lead = min(bpp, rb)
        switch f {
        case 0: d.update(from: cur, count: rb)
        case 1:
            for x in 0..<lead { d[x] = cur[x] }
            if rb > bpp { for x in bpp..<rb { d[x] = cur[x] &- cur[x - bpp] } }
        case 2:
            for x in 0..<rb { d[x] = cur[x] &- prev[x] }
        case 3:
            for x in 0..<lead { d[x] = cur[x] &- prev[x] >> 1 }
            if rb > bpp { for x in bpp..<rb { d[x] = cur[x] &- UInt8((Int(cur[x - bpp]) + Int(prev[x])) >> 1) } }
        default:
            for x in 0..<lead { d[x] = cur[x] &- prev[x] }
            if rb > bpp {
                for x in bpp..<rb {
                    d[x] = cur[x] &- UInt8(PNGCodec.paeth(Int(cur[x - bpp]), Int(prev[x]), Int(prev[x - bpp])))
                }
            }
        }
    }

    /// Blocks above this size are compressed in parallel.
    static let parallelBlock = 1 << 20

    static func deflate(_ data: [UInt8], level: Int32, strategy: Int32) -> [UInt8]? {
        data.count > parallelBlock * 2 ? parallelDeflate(data, level: level, strategy: strategy) : serialDeflate(data, level: level, strategy: strategy)
    }

    /// pigz-style parallel zlib: 1 MB blocks compressed concurrently, each primed with the
    /// previous 32 KB as a preset dictionary so matches can still reach back across the
    /// boundary. Blocks end with a sync flush (byte-aligned), so their raw deflate output
    /// concatenates into one valid stream; a single Adler-32 covers all of it.
    static func parallelDeflate(_ data: [UInt8], level: Int32, strategy: Int32) -> [UInt8]? {
        let count = (data.count + parallelBlock - 1) / parallelBlock
        let parts = UnsafeMutableBufferPointer<[UInt8]?>.allocate(capacity: count)
        parts.initialize(repeating: nil)
        defer { parts.deallocate() }
        data.withUnsafeBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let lo = i * parallelBlock, hi = min(data.count, lo + parallelBlock)
                var stream = z_stream()
                guard deflateInit2_(&stream, level, Z_DEFLATED, -15, 9, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                defer { deflateEnd(&stream) }
                if i > 0 {
                    let dictStart = max(0, lo - 32768)
                    _ = deflateSetDictionary(&stream, buf.baseAddress! + dictStart, uInt(lo - dictStart))
                }
                var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(hi - lo))) + 16)
                let last = i == count - 1
                var produced = 0
                var status: Int32 = Z_OK
                out.withUnsafeMutableBufferPointer { o in
                    stream.next_in = UnsafeMutablePointer(mutating: buf.baseAddress! + lo)
                    stream.avail_in = uInt(hi - lo)
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    status = zlib.deflate(&stream, last ? Z_FINISH : Z_SYNC_FLUSH)
                    produced = o.count - Int(stream.avail_out)
                }
                guard last ? status == Z_STREAM_END : (status == Z_OK && stream.avail_in == 0) else { return }
                out.removeSubrange(produced...)
                parts[i] = out
            }
        }
        var result: [UInt8] = [0x78, 0xDA]
        for i in 0..<count {
            guard let p = parts[i] else { return nil }
            result += p
        }
        let a = data.withUnsafeBufferPointer { adler32(adler32(0, nil, 0), $0.baseAddress, uInt($0.count)) }
        result += [UInt8(a >> 24 & 0xFF), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)]
        return result
    }

    static func serialDeflate(_ data: [UInt8], level: Int32, strategy: Int32) -> [UInt8]? {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15, 9, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(data.count)))
        var out = [UInt8](repeating: 0, count: bound)
        var ok = false
        var written = 0
        data.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                ok = zlib.deflate(&stream, Z_FINISH) == Z_STREAM_END
                written = outBuf.count - Int(stream.avail_out)
            }
        }
        guard ok else { return nil }
        out.removeSubrange(written...)
        return out
    }

    // MARK: Container

    /// Colour-management and resolution chunks are always kept; descriptive metadata follows the policy.
    /// bKGD/sBIT/hIST/sPLT depend on the original colour type, so they are dropped when re-encoding.
    static func keepChunks(_ chunks: [PNGChunk], policy: MetadataPolicy) -> [PNGChunk] {
        let colour: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI", "pHYs"]
        return chunks.filter { c in
            if colour.contains(c.type) { return true }
            switch policy {
            case .keep: return ["tEXt", "zTXt", "iTXt", "eXIf", "tIME"].contains(c.type)
            case .removePrivate:
                if c.type == "tEXt" || c.type == "zTXt" { return true }
                if c.type == "iTXt" { return !c.data.starts(with: Array("XML:com.adobe.xmp".utf8)) }
                return false
            case .removeAll: return false
            }
        }
    }

    static func assemble(_ e: Encoding, idat: [UInt8], width: Int, height: Int, ancillary: [PNGChunk]) -> [UInt8] {
        var out = PNGCodec.signature
        func chunk(_ type: String, _ data: [UInt8]) {
            let t = Array(type.utf8)
            appendBE32(&out, UInt32(data.count))
            out += t
            out += data
            var c = crc32(0, t, 4)
            c = data.withUnsafeBufferPointer { crc32(c, $0.baseAddress, uInt(data.count)) }
            appendBE32(&out, UInt32(c))
        }
        let (colorType, depth): (UInt8, Int) = switch e.layout {
        case .gray(let d): (0, d)
        case .grayAlpha(let d): (4, d)
        case .rgb(let d): (2, d)
        case .rgba(let d): (6, d)
        case .palette(let d, _): (3, d)
        }
        var ihdr: [UInt8] = []
        appendBE32(&ihdr, UInt32(width)); appendBE32(&ihdr, UInt32(height))
        ihdr += [UInt8(depth), colorType, 0, 0, 0]
        chunk("IHDR", ihdr)
        let beforePLTE: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI"]
        for c in ancillary where beforePLTE.contains(c.type) { chunk(c.type, c.data) }
        if case .palette(_, let entries) = e.layout {
            chunk("PLTE", entries.flatMap { [UInt8($0 >> 24 & 0xFF), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF)] })
            let alphas = entries.map { UInt8($0 & 0xFF) }
            if let last = alphas.lastIndex(where: { $0 != 255 }) { chunk("tRNS", Array(alphas[...last])) }
        }
        for c in ancillary where c.type == "pHYs" { chunk(c.type, c.data) }
        var i = 0
        let maxChunk = 1 << 23
        repeat {
            let end = min(i + maxChunk, idat.count)
            chunk("IDAT", Array(idat[i..<end]))
            i = end
        } while i < idat.count
        for c in ancillary where !beforePLTE.contains(c.type) && c.type != "pHYs" { chunk(c.type, c.data) }
        chunk("IEND", [])
        return out
    }

    private static func appendBE32(_ a: inout [UInt8], _ v: UInt32) {
        a += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}
