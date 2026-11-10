import SwiftUI
import DropsterCore

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(image: model.thumbnails[item.url], format: item.report?.format)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.report.map(Fmt.subtitle) ?? "Analyzing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            OperationChip(item: item)
            StatusView(item: item)
                .frame(width: 190, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct Thumbnail: View {
    let image: NSImage?
    let format: FormatID?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.6))
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    var symbol: String {
        switch format?.category {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.richtext"
        case .archive: "archivebox"
        default: "doc"
        }
    }
}

struct OperationChip: View {
    let item: Item

    var body: some View {
        if item.report != nil {
            Menu {
                OperationMenuItems(item: item)
            } label: {
                Text(item.operation?.shortLabel ?? "Choose…")
                    .font(.callout)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(item.state.isActive || item.state == .queued)
            .help(item.operation?.label ?? "Choose what to do with this file")
            .accessibilityLabel("Action: \(item.operation?.label ?? "none")")
        }
    }
}

struct StatusView: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        switch item.state {
        case .analyzing:
            ProgressView().controlSize(.small)
        case .ready:
            Text(model.preferences.startAutomatically ? "" : "Ready").foregroundStyle(.secondary)
        case .queued:
            Text("Waiting").foregroundStyle(.secondary)
        case .paused:
            Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .running(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 110)
                Text(Fmt.percent(p)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Button { model.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Cancel")
                    .accessibilityLabel("Cancel")
            }
        case .done(let r) where r.outcome == .written && item.operation == .unpack:
            Text("Unpacked · \(Fmt.bytes(r.producedBytes))").foregroundStyle(.secondary).monospacedDigit()
        case .done(let r) where r.outcome == .written:
            ResultSummary(result: r)
        case .done(let r) where item.operation?.isFitSize == true:
            Text("Already fits")
                .foregroundStyle(.secondary)
                .help("\(Fmt.bytes(r.inputBytes)) is already under the limit, so nothing was re-encoded.")
        case .done(let r):
            Text("Already optimal")
                .foregroundStyle(.secondary)
                .help("The result was \(Fmt.bytes(r.producedBytes)), not smaller than \(Fmt.bytes(r.inputBytes)). The original was kept and nothing was written.")
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
            }
            .help(message)
        case .cancelled:
            Text("Cancelled").foregroundStyle(.secondary)
        }
    }
}

struct ResultSummary: View {
    let result: ProcessingResult

    var body: some View {
        HStack(spacing: 8) {
            Text("\(Fmt.bytes(result.inputBytes)) → \(Fmt.bytes(result.producedBytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SavingsBadge(fraction: result.savedFraction)
        }
    }
}

struct SavingsBadge: View {
    let fraction: Double

    var body: some View {
        let saved = fraction > 0.0005
        Text(saved ? "−\(Fmt.percent(fraction))" : "+\(Fmt.percent(-fraction))")
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(saved ? Color.green : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((saved ? Color.green : Color.orange).opacity(0.12), in: Capsule())
            .accessibilityLabel(saved ? "\(Fmt.percent(fraction)) smaller" : "\(Fmt.percent(-fraction)) larger")
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            let t = model.totals
            Text("\(model.finishedCount) of \(model.items.count) done")
            if t.input > 0 {
                Text("Saved \(Fmt.bytes(t.input - t.output)) (\(Fmt.percent(1 - Double(t.output) / Double(t.input))))")
                    .foregroundStyle(.primary)
            }
            Spacer()
            if model.isPaused {
                Label("Paused", systemImage: "pause.fill")
            } else if model.activeCount > 0, let eta = model.estimatedRemaining {
                Text(Fmt.remaining(eta))
            }
            Label("Local only", systemImage: "lock.fill").labelStyle(.titleAndIcon).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
