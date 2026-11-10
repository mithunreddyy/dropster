import SwiftUI
import AppKit
import DropsterEngines

/// Side-by-side comparison with a draggable divider. "Actual Size" shows pixels 1:1
/// so compression artefacts are visible instead of hidden by downscaling.
struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    let original: URL
    let result: URL
    let originalBytes: Int64
    let resultBytes: Int64
    let ssim: Double?

    @State private var split: CGFloat = 0.5
    @State private var actualSize = false
    @State private var before: NSImage?
    @State private var after: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Original · \(Fmt.bytes(originalBytes))").foregroundStyle(.secondary)
                Spacer()
                Picker("Zoom", selection: $actualSize) {
                    Text("Fit").tag(false)
                    Text("Actual Size").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                Text("Result · \(Fmt.bytes(resultBytes))").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(12)
            Divider()
            GeometryReader { geo in
                if let before, let after {
                    let size = actualSize ? pixelSize(before) : fit(pixelSize(before), in: geo.size)
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .leading) {
                            Image(nsImage: before).resizable().interpolation(actualSize ? .none : .high)
                            Image(nsImage: after).resizable().interpolation(actualSize ? .none : .high)
                                .mask(alignment: .trailing) { Rectangle().frame(width: size.width * (1 - split)) }
                            Rectangle().fill(.white).frame(width: 1.5).shadow(radius: 1)
                                .offset(x: size.width * split)
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            split = min(1, max(0, v.location.x / size.width))
                        })
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .accessibilityLabel("Comparison. Drag to move the divider.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack {
                if let ssim {
                    Text("\(QualityMeter.Verdict(ssim: ssim).rawValue) · SSIM \(String(format: "%.3f", ssim))").foregroundStyle(.secondary)
                }
                Spacer()
                Slider(value: $split, in: 0...1) { Text("Divider") }.labelsHidden().frame(width: 200)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .font(.callout)
            .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .task {
            before = NSImage(contentsOf: original)
            after = NSImage(contentsOf: result)
        }
    }

    private func pixelSize(_ image: NSImage) -> CGSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0 else { return image.size }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
    }

    private func fit(_ s: CGSize, in bounds: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return bounds }
        let k = min(bounds.width / s.width, bounds.height / s.height, 1)
        return CGSize(width: s.width * k, height: s.height * k)
    }
}
