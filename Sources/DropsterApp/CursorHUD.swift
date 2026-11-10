import AppKit
import SwiftUI
import Observation
import DropsterCore

/// A small ring at the cursor that follows the files just dropped on the clover:
/// download speed for web pictures, then progress, then the result.
@MainActor @Observable
final class CursorHUD {
    static let shared = CursorHUD()

    enum Phase: Equatable {
        case transfer(TransferProgress?)
        case processing([Item.ID])
        case failed(String)
    }

    var phase: Phase = .transfer(nil)
    var visible = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func showTransfer(at point: NSPoint) {
        phase = .transfer(nil)
        present(at: point)
    }

    func updateTransfer(_ p: TransferProgress) { phase = .transfer(p) }

    func showFailure(_ message: String, at point: NSPoint) {
        phase = .failed(message)
        present(at: point)
        scheduleDismiss(after: 3)
    }

    func track(_ ids: [Item.ID], model: AppModel, at point: NSPoint) {
        self.model = model
        phase = .processing(ids)
        present(at: point)
        dismissTask?.cancel()
        dismissTask = Task {
            // Poll the model until everything is finished, then linger briefly.
            while !Task.isCancelled {
                if model.progress(of: ids).isDone { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func present(at point: NSPoint) {
        let size = NSSize(width: 220, height: 132)
        let panel = self.panel ?? {
            let p = CloverPanel(contentRect: NSRect(origin: .zero, size: size))
            p.level = .floating
            p.contentView = NSHostingView(rootView: HUDView(hud: self))
            self.panel = p
            return p
        }()
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let f = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { visible = true }
    }

    func hide() {
        withAnimation(.easeIn(duration: 0.18)) { visible = false }
        let panel = self.panel
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if !self.visible { panel?.orderOut(nil) }
        }
    }

    /// Clicking the ring opens the main window on these files.
    func open() {
        if case .processing(let ids) = phase, let model { model.selection = Set(ids) }
        WindowOpener.openMain()
        hide()
    }
}

private struct HUDView: View {
    let hud: CursorHUD

    var body: some View {
        VStack(spacing: 6) {
            content
        }
        .padding(10)
        .frame(width: 220, height: 132)
        .scaleEffect(hud.visible ? 1 : 0.6)
        .opacity(hud.visible ? 1 : 0)
        .onTapGesture { hud.open() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch hud.phase {
        case .transfer(let p):
            Ring(fraction: p?.fraction, symbol: "arrow.down", tint: .accentColor)
            Caption(p?.label ?? "Downloading…")
        case .failed(let msg):
            Ring(fraction: 1, symbol: "exclamationmark", tint: .orange)
            Caption(msg)
        case .processing(let ids):
            if let model = hud.model {
                let g = model.progress(of: ids)
                if g.isDone {
                    let saved = g.inputBytes - g.outputBytes
                    Ring(fraction: 1, symbol: g.failed == g.total ? "exclamationmark" : "checkmark", tint: g.failed > 0 ? .orange : .green)
                    Caption(g.failed > 0 ? "\(g.failed) of \(g.total) failed" :
                            saved > 0 ? "Saved \(Fmt.bytes(saved)) (\(Fmt.percent(Double(saved) / Double(max(1, g.inputBytes)))))" :
                            g.total == 1 ? "Done" : "\(g.total) files done")
                } else {
                    Ring(fraction: g.fraction, symbol: nil, tint: .accentColor, label: Fmt.percent(g.fraction))
                    Caption(g.total == 1 ? "Working…" : "\(g.finished) of \(g.total)")
                }
            }
        }
    }
}

private struct Ring: View {
    let fraction: Double?
    let symbol: String?
    let tint: Color
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial).shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            Circle().stroke(.quaternary, lineWidth: 5).padding(5)
            if let fraction {
                Circle().trim(from: 0, to: max(0.02, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
                    .animation(.easeOut(duration: 0.2), value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            if let symbol {
                Image(systemName: symbol).font(.system(size: 22, weight: .bold)).foregroundStyle(tint)
            } else if let label {
                Text(label).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
        .frame(width: 70, height: 70)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
    }
}

/// Lets non-view code open SwiftUI windows.
@MainActor
enum WindowOpener {
    static var open: OpenWindowAction?

    /// Called from SwiftUI bodies to keep a handle on the environment's window opener.
    static func register(_ action: OpenWindowAction) -> Bool {
        if open == nil { open = action }
        return true
    }

    static func openMain() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            open?(id: "main")
        }
    }
}
