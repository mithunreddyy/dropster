import SwiftUI
import ImageIO
import DropsterCore
import DropsterEngines

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let item: Item?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(item)
                    if let r = item.result, r.outcome == .written, let out = r.output, item.operation == .unpack {
                        Section("Result") {
                            Row(label: "Unpacked to", value: out.lastPathComponent)
                            Row(label: "Size", value: Fmt.bytes(r.producedBytes))
                            Row(label: "Time", value: Fmt.duration(r.duration))
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }.padding(.top, 4)
                        }
                    } else if let r = item.result, r.outcome == .written, let out = r.output {
                        ResultSection(item: item, result: r, output: out)
                    } else if case .done(let r) = item.state, case .fitSize(let limit) = item.operation {
                        Section("Result") {
                            Text("\(Fmt.bytes(r.inputBytes)) is already under \(SizeTarget.label(limit)). Nothing was re-encoded, so no quality was lost.")
                                .foregroundStyle(.secondary)
                        }
                    } else if case .done(let r) = item.state {
                        Section("Result") {
                            Text("Dropster produced \(Fmt.bytes(r.producedBytes)), which is not smaller than the original \(Fmt.bytes(r.inputBytes)). Nothing was written.")
                                .foregroundStyle(.secondary)
                        }
                    } else if case .failed(let msg) = item.state {
                        Section("Problem") {
                            Text(msg).textSelection(.enabled).foregroundStyle(.secondary)
                            if item.operation != nil { Button("Try Again") { model.retry(item.id) } }
                        }
                    }
                    if let report = item.report {
                        SuggestionsSection(item: item, report: report)
                        DetailsSection(report: report)
                        if report.format?.category == .archive { ArchiveContentsSection(report: report) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label(model.selection.count > 1 ? "\(model.selection.count) Files Selected" : "No Selection", systemImage: "sidebar.trailing")
            } description: {
                Text(model.selection.count > 1 ? "Use the context menu to apply one action to all of them." : "Select a file to see its details and compare the result.")
            }
        }
    }

    private func header(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let img = model.thumbnails[item.url] {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(item.name).font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let r = item.report { Text(Fmt.subtitle(r)).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct Row: View {
    let label: String
    let value: String
    var body: some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .font(.callout)
    }
}

struct ResultSection: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let result: ProcessingResult
    let output: URL
    @State private var ssim: Double?
    @State private var measuring = false
    @State private var showCompare = false

    var isLossyImage: Bool {
        guard let f = result.route.last, f.category == .image else { return false }
        if item.operation == .stripMetadata { return false }
        return f.isLossy || item.options?.maxPixelSize != nil
    }

    var body: some View {
        Section("Result") {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.bytes(result.producedBytes)).font(.title2.weight(.semibold)).monospacedDigit()
                SavingsBadge(fraction: result.savedFraction)
                Spacer()
            }
            SizeBars(original: result.inputBytes, result: result.producedBytes)
            if result.route.count == 2, result.route[0] == result.route[1] {
                Row(label: "Method", value: item.operation == .stripMetadata ? "Metadata removed, image data untouched" : "Re-encoded \(result.route[0].displayName)")
            } else {
                Row(label: "Route", value: result.route.map(\.displayName).joined(separator: " → "))
            }
            if case .fitSize(let limit) = item.operation {
                Row(label: "Limit", value: "Under \(SizeTarget.label(limit))")
                if let w = item.report?.image?.width, let h = item.report?.image?.height, let p = Self.pixelSize(output), p != (w, h) && p != (h, w) {
                    Row(label: "Scaled to", value: "\(p.0) × \(p.1) to fit")
                }
            }
            Row(label: "Time", value: Fmt.duration(result.duration))
            Row(label: "Saved as", value: output.lastPathComponent)
            if isLossyImage {
                LabeledContent("Quality") {
                    if let ssim {
                        Text("\(QualityMeter.Verdict(ssim: ssim).rawValue) · SSIM \(String(format: "%.3f", ssim))")
                    } else if measuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Not measured").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .help("Structural similarity between the original and the result, measured on this Mac. 1.000 means identical.")
            } else if result.route.last?.isLossy == false || item.operation == .stripMetadata {
                Row(label: "Quality", value: "Lossless")
            }
            HStack {
                if result.route.last?.category == .image {
                    Button("Compare…") { showCompare = true }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
            .padding(.top, 4)
        }
        .task(id: output) { await measure() }
        .sheet(isPresented: $showCompare) {
            CompareView(original: item.url, result: output, originalBytes: result.inputBytes, resultBytes: result.producedBytes, ssim: ssim)
        }
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private func measure() async {
        guard isLossyImage, ssim == nil, let meter = QualityMeter() else { return }
        measuring = true
        defer { measuring = false }
        let original = item.url
        ssim = try? await Task.detached(priority: .utility) { try await meter.ssim(original: original, candidate: output) }.value
    }
}

struct SizeBars: View {
    let original: Int64
    let result: Int64

    var body: some View {
        let ratio = original > 0 ? min(1, Double(result) / Double(original)) : 1
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(.quaternary).frame(width: geo.size.width, height: 6)
                    Capsule().fill(Color.accentColor).frame(width: max(4, geo.size.width * ratio), height: 6)
                }
            }
            .frame(height: 15)
            HStack {
                Text("Original \(Fmt.bytes(original))")
                Spacer()
                Text("Result \(Fmt.bytes(result))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SuggestionsSection: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let report: FileReport

    var body: some View {
        let available = Set(model.targets(for: item)).union(model.canOptimize(item) ? [report.format].compactMap { $0 } : [])
        let recs = Advisor.recommendations(for: report, available: available)
        if !recs.isEmpty {
            Section("Suggestions") {
                ForEach(recs) { rec in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(rec.kind)).foregroundStyle(color(rec.kind)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rec.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if let op = rec.operation, op != item.operation, isPossible(op) {
                                Button(op.label) { model.setOperation(op, for: [item.id]) }
                                    .buttonStyle(.link)
                                    .font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }

    func isPossible(_ op: FileOperation) -> Bool {
        switch op {
        case .optimize, .stripMetadata: model.canOptimize(item)
        case .convert(let f): model.targets(for: item).contains(f)
        default: model.canPerform(op, on: item)
        }
    }

    func icon(_ k: Recommendation.Kind) -> String {
        switch k {
        case .saving: "arrow.down.right.circle.fill"
        case .privacy: "hand.raised.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    func color(_ k: Recommendation.Kind) -> Color {
        switch k {
        case .saving: .green
        case .privacy: .blue
        case .warning: .orange
        case .info: .secondary
        }
    }
}

/// What is inside an archive, read without extracting it.
struct ArchiveContentsSection: View {
    let report: FileReport
    @State private var entries: [ArchiveEntry]?
    @State private var problem: String?

    var body: some View {
        Section("Contents") {
            if let entries {
                let files = entries.filter { !$0.isDirectory }
                let total = files.reduce(Int64(0)) { $0 + max(0, $1.size) }
                Row(label: "Items", value: "\(files.count) file\(files.count == 1 ? "" : "s")" + (entries.count > files.count ? " in \(entries.count - files.count) folders" : ""))
                if files.allSatisfy({ $0.size >= 0 }) { Row(label: "Unpacked size", value: Fmt.bytes(total)) }
                if let unsafe = entries.lazy.compactMap({ UnpackEngine.problem(with: $0.path) }).first {
                    Label("Contains \(unsafe). Dropster will refuse to unpack it.", systemImage: "exclamationmark.shield.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(files.prefix(12).enumerated()), id: \.offset) { _, e in
                        HStack {
                            Image(systemName: e.isLink ? "link" : "doc").foregroundStyle(.tertiary).frame(width: 14)
                            Text(e.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if e.size >= 0 { Text(Fmt.bytes(e.size)).foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                    if files.count > 12 { Text("and \(files.count - 12) more").foregroundStyle(.secondary) }
                }
                .font(.callout)
            } else if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: report.url) {
            do { entries = try await UnpackEngine().list(report.url, format: report.format ?? .any) }
            catch { problem = "Can’t read the contents: \(error.localizedDescription)" }
        }
    }
}

struct DetailsSection: View {
    let report: FileReport

    var body: some View {
        Section("Details") {
            Row(label: "Format", value: Fmt.kind(report))
            if report.extensionMismatch, let e = report.extensionFormat { Row(label: "Extension says", value: e.displayName) }
            Row(label: "Size", value: Fmt.bytes(report.byteSize))
            if let i = report.image {
                Row(label: "Dimensions", value: "\(i.width) × \(i.height)")
                Row(label: "Colour", value: [i.colorModel, "\(i.bitsPerComponent)-bit", i.hasAlpha ? "alpha" : nil].compactMap { $0 }.joined(separator: " · "))
                if let p = i.colorProfile { Row(label: "Profile", value: p) }
                if let q = i.estimatedJPEGQuality { Row(label: "JPEG quality", value: "≈\(q)") }
                if i.isAnimated { Row(label: "Frames", value: "\(i.frameCount)") }
                Row(label: "Location", value: i.hasGPS ? "Present" : "None")
            }
            if let m = report.media {
                if let d = m.duration { Row(label: "Duration", value: Fmt.clock(d)) }
                if let v = m.videoCodec { Row(label: "Video", value: [v.uppercased(), m.frameRate.map { String(format: "%.3g fps", $0) }].compactMap { $0 }.joined(separator: " · ")) }
                if let a = m.audioCodec {
                    Row(label: "Audio", value: [a.uppercased(), m.sampleRate.map { "\($0 / 1000) kHz" }, m.channels.map { $0 == 1 ? "mono" : $0 == 2 ? "stereo" : "\($0) ch" }].compactMap { $0 }.joined(separator: " · "))
                }
                if let b = m.bitRate { Row(label: "Bitrate", value: "\(b / 1000) kb/s") }
            }
            if let p = report.pageCount { Row(label: "Pages", value: "\(p)") }
        }
    }
}
