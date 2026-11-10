import Foundation

/// Identifies a file from its leading bytes rather than trusting its extension.
public enum FileSignature {
    /// Number of bytes callers should read for reliable detection (tar's magic sits at 257).
    public static let headerLength = 512

    public static func detect(url: URL) -> FormatID? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength) else { return nil }
        return detect(Array(data))
    }

    public static func detect(_ b: [UInt8]) -> FormatID? {
        func has(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            guard b.count >= offset + sig.count else { return false }
            return Array(b[offset..<offset + sig.count]) == sig
        }
        func ascii(_ s: String, at offset: Int = 0) -> Bool { has(Array(s.utf8), at: offset) }

        if has([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if ascii("RIFF") {
            if ascii("WEBP", at: 8) { return .webp }
            if ascii("WAVE", at: 8) { return .wav }
            if ascii("AVI ", at: 8) { return .avi }
        }
        if ascii("FORM"), ascii("AIFF", at: 8) || ascii("AIFC", at: 8) { return .aiff }
        if ascii("8BPS") { return .psd }
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if ascii("BM"), b.count >= 26 {
            // BITMAPFILEHEADER: reserved fields at 6..9 must be zero; header size at 14 is 12/40/56/108/124.
            let reservedZero = b[6] == 0 && b[7] == 0 && b[8] == 0 && b[9] == 0
            let dib = Int(b[14]) | Int(b[15]) << 8
            if reservedZero && [12, 40, 52, 56, 64, 108, 124].contains(dib) { return .bmp }
        }
        if has([0x00, 0x00, 0x01, 0x00]), b.count > 4, b[4] > 0 { return .ico }
        if has([0xFF, 0x0A]) || has([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) { return .jxl }
        if has([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) { return .jp2 }
        if ascii("ftyp", at: 4) { return isoBMFF(b) }
        if has([0x1A, 0x45, 0xDF, 0xA3]) {
            // EBML: look for the DocType string in the header.
            let text = String(decoding: b, as: UTF8.self)
            return text.contains("webm") ? .webm : .mkv
        }
        if ascii("fLaC") { return .flac }
        if ascii("OggS") {
            return ascii("OpusHead", at: 28) ? .opus : .ogg
        }
        if ascii("ID3") { return .mp3 }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 {
            // MPEG audio frame sync. Layer bits 01 = layer III; ADTS AAC uses layer 00.
            let layer = (b[1] >> 1) & 0x03
            if layer == 0x01 { return .mp3 }
            if layer == 0x00 { return .m4a }
        }
        if ascii("%PDF-") { return .pdf }
        if ascii("{\\rtf") { return .rtf }
        if ascii("icns") { return .icns }
        if has([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .doc } // OLE2 compound file
        if ascii("WEBVTT") || has([0xEF, 0xBB, 0xBF] + Array("WEBVTT".utf8)) { return .vtt }
        let text = String(decoding: b.prefix(64), as: UTF8.self).lowercased()
        if text.hasPrefix("<svg") || (text.hasPrefix("<?xml") && text.contains("<svg")) { return .svg }
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") { return .html }
        if text.hasPrefix("[script info]") { return .ass }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if has([0x1F, 0x8B]) { return .gzip }
        if has([0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if has([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if has([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if ascii("ustar", at: 257) { return .tar }
        return nil
    }

    private static func isoBMFF(_ b: [UInt8]) -> FormatID? {
        guard b.count >= 12 else { return nil }
        let boxSize = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        var brands: [String] = []
        func brand(at i: Int) -> String? {
            guard i + 4 <= b.count else { return nil }
            return String(bytes: b[i..<i + 4], encoding: .ascii)
        }
        if let major = brand(at: 8) { brands.append(major) }
        var i = 16
        while i + 4 <= min(boxSize, b.count) {
            if let c = brand(at: i) { brands.append(c) }
            i += 4
        }
        let major = brands.first ?? ""
        if ["avif", "avis"].contains(major) { return .avif }
        if ["heic", "heix", "heim", "heis", "hevc", "hevx"].contains(major) { return .heic }
        if ["mif1", "msf1"].contains(major) {
            return brands.contains("avif") || brands.contains("avis") ? .avif : .heic
        }
        if major == "qt  " { return .mov }
        if ["M4A ", "M4B ", "M4P "].contains(major) { return .m4a }
        if major == "crx " { return .raw }
        return .mp4
    }
}
