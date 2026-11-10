import Foundation
import DropsterCore

/// Something the clover can do with the files it was given.
enum CloverAction: Hashable {
    /// Each file's suggested action (dropping on the core).
    case suggested
    case operation(FileOperation, mode: CompressionMode? = nil)
    case preset(Preset)
    case batch(BatchOperation)
    case crop

    func caption(fileCount: Int) -> String {
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        switch self {
        case .suggested: return "Suggested action · \(files)"
        case .operation(let op, let mode): return op.label + (mode.map { " · \($0.displayName)" } ?? "") + " · \(files)"
        case .preset(let p): return "\(p.name) · \(files)"
        case .batch(let b): return "\(b.label) · \(files)"
        case .crop: return "Crop · \(files)"
        }
    }
}

struct CloverLeaflet: Hashable, Identifiable {
    var id: String { title + "|" + (symbol ?? "") }
    /// Short label drawn inside the leaflet ("WEBP"), or empty when a symbol is shown.
    var title: String
    var symbol: String?
    var action: CloverAction
}

struct CloverLeaf: Hashable, Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var leaflets: [CloverLeaflet]
    /// Dropping on the leaf itself runs this.
    var primary: CloverAction? { leaflets.first?.action }
    var isEnabled: Bool { !leaflets.isEmpty }
}

/// The two faces of the clover for a set of files.
struct CloverFaces: Equatable {
    var front: [CloverLeaf]
    var back: [CloverLeaf]
}

enum FileKind {
    case image, video, audio, pdf, document, subtitle, archive, mixed

    init(_ reports: [FileReport]) {
        let formats = reports.map(\.format)
        func all(_ test: (FormatID) -> Bool) -> Bool { !formats.isEmpty && formats.allSatisfy { $0.map(test) ?? false } }
        if all({ $0.category == .image && $0 != .svg }) { self = .image }
        else if all({ $0.category == .video || $0 == .gif }) { self = .video }
        else if all({ $0.category == .audio }) { self = .audio }
        else if all({ $0 == .pdf }) { self = .pdf }
        else if all({ $0.category == .document }) { self = .document }
        else if all({ $0.category == .subtitle }) { self = .subtitle }
        else if all({ $0.category == .archive }) { self = .archive }
        else { self = .mixed }
    }

    var presetCategory: FormatCategory? {
        switch self {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .pdf, .document: .document
        case .subtitle: .subtitle
        case .archive, .mixed: nil
        }
    }
}

enum CloverMenuBuilder {
    static let maxLeaflets = 9

    /// Builds both faces, keeping only actions at least one of the files supports.
    static func build(reports: [FileReport], processor: Processor, presets: [Preset]) -> CloverFaces {
        let kind = FileKind(reports)
        func can(_ op: FileOperation) -> Bool { reports.contains { processor.canPerform(op, on: $0) } }
        // A file's own format is never offered as a conversion (it would only remux or re-encode).
        let sourceFormats = Set(reports.compactMap(\.format))
        func convert(_ formats: [FormatID]) -> [CloverLeaflet] {
            formats.filter { !(sourceFormats.count == 1 && sourceFormats.contains($0)) && can(.convert($0)) }.map { CloverLeaflet(title: $0.preferredExtension.uppercased(), action: .operation(.convert($0))) }
        }
        func ops(_ items: [(String, String?, FileOperation)]) -> [CloverLeaflet] {
            items.filter { can($0.2) }.map { CloverLeaflet(title: $0.0, symbol: $0.1, action: .operation($0.2)) }
        }
        let optimizeLeaflets: [CloverLeaflet] = {
            guard can(.optimize) else { return ops([("", "eye.slash", .stripMetadata)]) }
            return [CloverLeaflet(title: "", symbol: "sparkles", action: .operation(.optimize))]
                + CompressionMode.allCases.map { CloverLeaflet(title: String($0.displayName.prefix(4)).uppercased(), action: .operation(.optimize, mode: $0)) }
                + ops([("", "eye.slash", .stripMetadata)])
        }()
        let presetLeaflets: [CloverLeaflet] = kind.presetCategory.map { cat in
            presets.filter { $0.category == cat && can($0.operation) }.map { p in
                CloverLeaflet(title: abbreviation(p.name), action: .preset(p))
            }
        } ?? []
        let combine: [CloverLeaflet] = {
            var l: [CloverLeaflet] = []
            let mergeable = reports.allSatisfy { r in r.format == .pdf || (r.format?.category == .image && r.format != .svg) }
            if mergeable { l.append(CloverLeaflet(title: "", symbol: "doc.on.doc", action: .batch(.mergePDF))) }
            l.append(CloverLeaflet(title: "", symbol: "archivebox", action: .batch(.zip)))
            return l
        }()
        let compress = convert([.zstd, .xz, .gzip, .brotli, .zip])
        let fit: [CloverLeaflet] = SizeTarget.common.filter { can(.fitSize($0)) }.map {
            CloverLeaflet(title: SizeTarget.label($0).replacingOccurrences(of: " ", with: ""), action: .operation(.fitSize($0)))
        }

        var front: [CloverLeaf]
        var back: [CloverLeaf]
        switch kind {
        case .image:
            front = [
                CloverLeaf(title: "Optimize", symbol: "sparkles", leaflets: optimizeLeaflets),
                CloverLeaf(title: "Web", symbol: "globe", leaflets: convert([.webp, .avif, .jpeg, .png])),
                CloverLeaf(title: "Formats", symbol: "square.stack.3d.up", leaflets: convert([.heic, .tiff, .pdf, .svg, .gif, .ico, .icns, .bmp, .jp2])),
                CloverLeaf(title: "Presets", symbol: "slider.horizontal.3", leaflets: presetLeaflets),
            ]
            back = [
                CloverLeaf(title: "Fit Size", symbol: "arrow.down.right.and.arrow.up.left", leaflets: fit),
                CloverLeaf(title: "Transform", symbol: "rotate.right", leaflets: ops([
                    ("", "rotate.right", .edit(.rotateRight)), ("", "rotate.left", .edit(.rotateLeft)),
                    ("180°", nil, .edit(ImageEdit(quarterTurns: 2))),
                    ("", "arrow.left.and.right.righttriangle.left.righttriangle.right", .edit(.flipH)),
                    ("", "arrow.up.and.down.righttriangle.up.righttriangle.down", .edit(.flipV)),
                ]) + [CloverLeaflet(title: "", symbol: "crop", action: .crop)]),
                CloverLeaf(title: "Colour", symbol: "circle.lefthalf.filled", leaflets: ops([
                    ("", "circle.lefthalf.filled", .edit(.toGrayscale)), ("", "person.crop.rectangle", .edit(.cutout)),
                ])),
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
            ]
        case .video:
            front = [
                CloverLeaf(title: "Optimize", symbol: "sparkles", leaflets: optimizeLeaflets),
                CloverLeaf(title: "Video", symbol: "film", leaflets: convert([.mp4, .mov, .webm, .mkv, .gif])),
                CloverLeaf(title: "Audio", symbol: "waveform", leaflets: convert([.mp3, .m4a, .opus, .flac, .wav])),
                CloverLeaf(title: "Presets", symbol: "slider.horizontal.3", leaflets: presetLeaflets),
            ]
            back = [
                CloverLeaf(title: "Frames", symbol: "photo.stack", leaflets: ops([("PNG", nil, .exportPages(.png)), ("JPG", nil, .exportPages(.jpeg))])),
                CloverLeaf(title: "Fit Size", symbol: "arrow.down.right.and.arrow.up.left", leaflets: fit),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
            ]
        case .audio:
            front = [
                CloverLeaf(title: "Optimize", symbol: "sparkles", leaflets: can(.optimize) ? optimizeLeaflets : []),
                CloverLeaf(title: "Compact", symbol: "waveform.path", leaflets: convert([.mp3, .m4a, .opus])),
                CloverLeaf(title: "Lossless", symbol: "waveform", leaflets: convert([.flac, .wav, .aiff])),
                CloverLeaf(title: "Presets", symbol: "slider.horizontal.3", leaflets: presetLeaflets),
            ]
            back = [
                CloverLeaf(title: "Clean", symbol: "eye.slash", leaflets: ops([("", "eye.slash", .stripMetadata)])),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "Fit Size", symbol: "arrow.down.right.and.arrow.up.left", leaflets: fit),
            ]
        case .pdf:
            front = [
                CloverLeaf(title: "Compress", symbol: "sparkles", leaflets: optimizeLeaflets),
                CloverLeaf(title: "Pictures", symbol: "photo.on.rectangle", leaflets: ops([
                    ("PNG", nil, .exportPages(.png)), ("JPG", nil, .exportPages(.jpeg)), ("HEIC", nil, .exportPages(.heic)),
                    ("", "rectangle.portrait.arrowtriangle.2.outward", .longImage(.png)),
                ])),
                CloverLeaf(title: "Pages", symbol: "doc.on.doc", leaflets: ops([("", "scissors", .splitPDF), ("TXT", nil, .convert(.txt))])),
                CloverLeaf(title: "Presets", symbol: "slider.horizontal.3", leaflets: presetLeaflets),
            ]
            back = [
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "Clean", symbol: "eye.slash", leaflets: ops([("", "eye.slash", .stripMetadata)])),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "", symbol: "", leaflets: []),
            ]
        case .document:
            front = [
                CloverLeaf(title: "PDF", symbol: "doc.richtext", leaflets: convert([.pdf])),
                CloverLeaf(title: "Word", symbol: "doc.text", leaflets: convert([.docx, .odt, .rtf, .doc])),
                CloverLeaf(title: "Web & Text", symbol: "text.alignleft", leaflets: convert([.html, .txt])),
                CloverLeaf(title: "Presets", symbol: "slider.horizontal.3", leaflets: presetLeaflets),
            ]
            back = [
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "", symbol: "", leaflets: []),
                CloverLeaf(title: "", symbol: "", leaflets: []),
            ]
        case .subtitle:
            front = [
                CloverLeaf(title: "SubRip", symbol: "captions.bubble", leaflets: convert([.srt])),
                CloverLeaf(title: "WebVTT", symbol: "captions.bubble", leaflets: convert([.vtt])),
                CloverLeaf(title: "Styled", symbol: "textformat", leaflets: convert([.ass])),
                CloverLeaf(title: "Text", symbol: "text.alignleft", leaflets: convert([.txt])),
            ]
            back = [
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "", symbol: "", leaflets: []),
                CloverLeaf(title: "", symbol: "", leaflets: []),
            ]
        case .archive:
            front = [
                CloverLeaf(title: "Unpack", symbol: "shippingbox.and.arrow.backward", leaflets: ops([("", "shippingbox.and.arrow.backward", .unpack)])),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "", symbol: "", leaflets: []),
            ]
            back = [
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "", symbol: "", leaflets: []),
                CloverLeaf(title: "", symbol: "", leaflets: []),
                CloverLeaf(title: "", symbol: "", leaflets: []),
            ]
        case .mixed:
            front = [
                CloverLeaf(title: "Optimize", symbol: "sparkles", leaflets: can(.optimize) ? [CloverLeaflet(title: "", symbol: "sparkles", action: .suggested)] : []),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "Clean", symbol: "eye.slash", leaflets: ops([("", "eye.slash", .stripMetadata)])),
            ]
            back = [
                CloverLeaf(title: "Combine", symbol: "square.on.square", leaflets: combine),
                CloverLeaf(title: "Compress", symbol: "archivebox", leaflets: compress),
                CloverLeaf(title: "", symbol: "", leaflets: []),
                CloverLeaf(title: "", symbol: "", leaflets: []),
            ]
        }
        func cap(_ leaves: [CloverLeaf]) -> [CloverLeaf] {
            leaves.map { var l = $0; l.leaflets = Array(l.leaflets.prefix(maxLeaflets)); return l }
        }
        return CloverFaces(front: cap(front), back: cap(back))
    }

    /// Two to four letters for a preset leaflet: "Web 1920 · WebP" → "1920".
    static func abbreviation(_ name: String) -> String {
        if let number = name.split(whereSeparator: { !$0.isNumber }).first, number.count <= 4 { return String(number) }
        let words = name.split(whereSeparator: { !$0.isLetter })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}
