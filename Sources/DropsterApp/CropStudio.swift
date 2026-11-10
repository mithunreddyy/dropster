import AppKit
import SwiftUI
import Observation
import DropsterCore
import DropsterEngines

enum AspectChoice: Hashable, CaseIterable {
    case free, original, square, r5x4, r4x3, r3x2, r16x9

    var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .r5x4: "5:4"
        case .r4x3: "4:3"
        case .r3x2: "3:2"
        case .r16x9: "16:9"
        }
    }

    /// Width ÷ height in landscape form.
    func ratio(original: Double) -> Double? {
        switch self {
        case .free: nil
        case .original: original
        case .square: 1
        case .r5x4: 5.0 / 4
        case .r4x3: 4.0 / 3
        case .r3x2: 3.0 / 2
        case .r16x9: 16.0 / 9
        }
    }
}

@MainActor @Observable
final class CropSession {
    enum FileState { case pending, cropped, skipped }

    let urls: [URL]
    var index = 0
    var states: [FileState]
    var image: CGImage?
    var rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    var aspect: AspectChoice = .free
    var portrait = false
    var dialVisible = false
    var dialPoint: CGPoint = .zero
    var thumbnails: [URL: NSImage] = [:]
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var close: () -> Void = {}

    init(urls: [URL], model: AppModel) {
        self.urls = urls
        self.model = model
        states = urls.map { _ in .pending }
        for u in urls { thumbnails[u] = model.thumbnails[u] ?? NSImage(contentsOf: u) }
        load()
    }

    var current: URL { urls[index] }
    var pixelSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1, height: 1) }

    /// Aspect ratio (w/h) of the crop in pixels, or nil for free.
    var targetRatio: Double? {
        let original = pixelSize.width / pixelSize.height
        switch aspect {
        case .free: return nil
        case .original: return original
        default:
            guard let r = aspect.ratio(original: original) else { return nil }
            return portrait ? 1 / r : r
        }
    }

    func load() {
        image = try? ImageEditEngine.uprightImage(current, maxPixelSize: 2400)
        rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        applyAspect()
    }

    /// Fits the largest centred rectangle with the chosen ratio.
    func applyAspect() {
        guard let r = targetRatio else { return }
        let s = pixelSize
        var w = 1.0, h = (s.width / r) / s.height
        if h > 1 { h = 1; w = (s.height * r) / s.width }
        let cx = rect.midX, cy = rect.midY
        rect = CGRect(x: min(max(cx - w / 2, 0), 1 - w), y: min(max(cy - h / 2, 0), 1 - h), width: w, height: h)
    }

    func choose(_ a: AspectChoice) {
        aspect = a
        dialVisible = false
        applyAspect()
    }

    func swapOrientation() {
        portrait.toggle()
        applyAspect()
    }

    var edit: ImageEdit { ImageEdit(crop: CropRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)) }

    func cropAndNext() {
        model?.runEdit(edit, on: current)
        states[index] = .cropped
        advance()
    }

    func skip() {
        states[index] = .skipped
        advance()
    }

    /// Applies the same frame (re-fitted to each picture's shape when a ratio is set) to every remaining file.
    func cropAllRemaining() {
        let normalized = rect
        for i in index..<urls.count where states[i] == .pending {
            index = i
            load()
            rect = normalized
            applyAspect()
            model?.runEdit(edit, on: urls[i])
            states[i] = .cropped
        }
        close()
    }

    private func advance() {
        if let next = (index + 1..<urls.count).first(where: { states[$0] == .pending }) {
            index = next
            load()
        } else {
            close()
        }
    }

    func select(_ i: Int) {
        index = i
        load()
    }
}

@MainActor
final class CropStudioController {
    static let shared = CropStudioController()
    private var window: NSWindow?

    func open(_ urls: [URL], model: AppModel) {
        guard !urls.isEmpty else { return }
        let session = CropSession(urls: urls, model: model)
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 640, height: 480)
            w.center()
            return w
        }()
        window = w
        session.close = { [weak w] in w?.close() }
        w.title = "Crop"
        w.contentView = NSHostingView(rootView: CropStudioView(session: session))
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct CropStudioView: View {
    @Bindable var session: CropSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = session.image {
                    CropCanvas(session: session, image: image)
                        .padding(28)
                } else {
                    ContentUnavailableView("Can’t open this picture", systemImage: "photo.badge.exclamationmark")
                }
                if session.dialVisible {
                    AspectDial(session: session)
                        .position(session.dialPoint)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .coordinateSpace(name: "studio")
            .onContinuousHover(coordinateSpace: .named("studio")) { phase in
                if case .active(let p) = phase, !session.dialVisible { session.dialPoint = p }
            }
            Divider()
            HStack(spacing: 12) {
                Strip(session: session)
                Spacer(minLength: 12)
                Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { session.dialVisible.toggle() } } label: {
                    Label(session.aspect.label + (session.portrait && session.aspect != .free && session.aspect != .square ? " ↕" : ""), systemImage: "aspectratio")
                }
                .help("Aspect ratio (A)")
                Button("Skip") { session.skip() }
                if session.urls.count > 1 {
                    Button("Crop All Remaining") { session.cropAllRemaining() }
                        .help("Apply this frame to every remaining picture")
                }
                Button(session.states.filter { $0 == .pending }.count <= 1 ? "Crop & Save" : "Crop & Next") { session.cropAndNext() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "aAxX1234567")) { press in
            let c = press.characters.lowercased()
            if c == "a" { withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { session.dialVisible.toggle() } }
            else if c == "x" { session.swapOrientation() }
            else if let n = Int(c), n >= 1, n <= AspectChoice.allCases.count { session.choose(AspectChoice.allCases[n - 1]) }
            return .handled
        }
        .onKeyPress(.escape) {
            if session.dialVisible { session.dialVisible = false; return .handled }
            return .ignored
        }
    }
}

/// The picture with the crop frame on top.
private struct CropCanvas: View {
    @Bindable var session: CropSession
    let image: CGImage
    @State private var dragging = false
    @State private var dragStart: CGRect?
    @State private var grab: Grab?
    @State private var snapX = false
    @State private var snapY = false

    enum Grab { case move, create(CGPoint), handle(x: Int, y: Int) } // x/y: -1 min edge, 0 none, 1 max edge

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(in: geo.size)
            let frame = CGRect(x: fit.minX + session.rect.minX * fit.width, y: fit.minY + session.rect.minY * fit.height,
                               width: session.rect.width * fit.width, height: session.rect.height * fit.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                // Frosted veil outside the frame.
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Rectangle().fill(Color.black.opacity(0.25)))
                    .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                    .mask {
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: geo.size))
                            p.addRect(frame)
                        }.fill(style: FillStyle(eoFill: true))
                    }
                    .allowsHitTesting(false)
                if dragging {
                    Path { p in
                        for k in 1...2 {
                            let x = frame.minX + frame.width * CGFloat(k) / 3, y = frame.minY + frame.height * CGFloat(k) / 3
                            p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                            p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
                        }
                    }.stroke(Color.white.opacity(0.6), lineWidth: 0.75)
                }
                if snapX { Path { p in p.move(to: CGPoint(x: fit.midX, y: fit.minY)); p.addLine(to: CGPoint(x: fit.midX, y: fit.maxY)) }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                if snapY { Path { p in p.move(to: CGPoint(x: fit.minX, y: fit.midY)); p.addLine(to: CGPoint(x: fit.maxX, y: fit.midY)) }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                ForEach(handles(frame), id: \.0) { _, pt in
                    Circle().fill(.white).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 11, height: 11).offset(x: pt.x - 5.5, y: pt.y - 5.5)
                        .allowsHitTesting(false)
                }
                Text(verbatim: "\(Int((session.rect.width * session.pixelSize.width).rounded())) × \(Int((session.rect.height * session.pixelSize.height).rounded()))")
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: frame.midX, y: min(frame.maxY + 16, geo.size.height - 10))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in changed(v, fit: fit, frame: frame) }.onEnded { _ in
                dragging = false; dragStart = nil; grab = nil; snapX = false; snapY = false
            })
        }
    }

    private func fitted(in size: CGSize) -> CGRect {
        let s = session.pixelSize
        let k = min(size.width / s.width, size.height / s.height)
        let w = s.width * k, h = s.height * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func handles(_ f: CGRect) -> [(Int, CGPoint)] {
        [(0, CGPoint(x: f.minX, y: f.minY)), (1, CGPoint(x: f.midX, y: f.minY)), (2, CGPoint(x: f.maxX, y: f.minY)),
         (3, CGPoint(x: f.maxX, y: f.midY)), (4, CGPoint(x: f.maxX, y: f.maxY)), (5, CGPoint(x: f.midX, y: f.maxY)),
         (6, CGPoint(x: f.minX, y: f.maxY)), (7, CGPoint(x: f.minX, y: f.midY))]
    }

    private func changed(_ v: DragGesture.Value, fit: CGRect, frame: CGRect) {
        if grab == nil {
            dragStart = session.rect
            dragging = true
            let p = v.startLocation
            let near: (CGFloat, CGFloat) -> Bool = { a, b in abs(a - b) <= 12 }
            let hx = near(p.x, frame.minX) ? -1 : near(p.x, frame.maxX) ? 1 : 0
            let hy = near(p.y, frame.minY) ? -1 : near(p.y, frame.maxY) ? 1 : 0
            let withinX = p.x >= frame.minX - 12 && p.x <= frame.maxX + 12, withinY = p.y >= frame.minY - 12 && p.y <= frame.maxY + 12
            if (hx != 0 || hy != 0) && withinX && withinY { grab = .handle(x: hx, y: hy) }
            else if frame.contains(p) { grab = .move }
            else { grab = .create(CGPoint(x: (p.x - fit.minX) / fit.width, y: (p.y - fit.minY) / fit.height)) }
        }
        guard let start = dragStart, let grab else { return }
        let dx = v.translation.width / fit.width, dy = v.translation.height / fit.height
        var r = start
        switch grab {
        case .move:
            r.origin.x = min(max(start.minX + dx, 0), 1 - start.width)
            r.origin.y = min(max(start.minY + dy, 0), 1 - start.height)
            // Snap the frame's centre to the picture's centre lines within 8 pt.
            snapX = abs((r.midX - 0.5) * fit.width) < 8
            snapY = abs((r.midY - 0.5) * fit.height) < 8
            if snapX { r.origin.x = 0.5 - r.width / 2 }
            if snapY { r.origin.y = 0.5 - r.height / 2 }
        case .create(let a):
            let b = CGPoint(x: min(max(a.x + dx, 0), 1), y: min(max(a.y + dy, 0), 1))
            r = constrained(anchor: a, to: b)
        case .handle(let hx, let hy):
            let ax = hx == -1 ? start.maxX : start.minX, ay = hy == -1 ? start.maxY : start.minY
            var bx = hx == 0 ? start.maxX : (hx == -1 ? start.minX : start.maxX) + dx
            var by = hy == 0 ? start.maxY : (hy == -1 ? start.minY : start.maxY) + dy
            bx = min(max(bx, 0), 1); by = min(max(by, 0), 1)
            if hx == 0 {
                r = constrained(anchor: CGPoint(x: start.minX, y: ay), to: CGPoint(x: start.maxX, y: by), keepWidth: true)
            } else if hy == 0 {
                r = constrained(anchor: CGPoint(x: ax, y: start.minY), to: CGPoint(x: bx, y: start.maxY), keepHeight: true)
            } else {
                r = constrained(anchor: CGPoint(x: ax, y: ay), to: CGPoint(x: bx, y: by))
            }
        }
        if r.width > 0.01 && r.height > 0.01 { session.rect = r }
    }

    /// Rectangle between two normalised points, honouring the aspect ratio and the image bounds.
    private func constrained(anchor a: CGPoint, to b: CGPoint, keepWidth: Bool = false, keepHeight: Bool = false) -> CGRect {
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if let ratio = session.targetRatio {
            let s = session.pixelSize
            let k = s.width / s.height / ratio // normalised h = w * k
            if keepHeight { w = h / k } else if keepWidth { h = w * k } else if h > w * k { w = h / k } else { h = w * k }
        }
        let sx: CGFloat = b.x >= a.x ? 1 : -1, sy: CGFloat = b.y >= a.y ? 1 : -1
        var x = sx > 0 ? a.x : a.x - w, y = sy > 0 ? a.y : a.y - h
        // Scale down rather than spill outside the picture.
        let overX = max(0, -x, x + w - 1), overY = max(0, -y, y + h - 1)
        if overX > 0 || overY > 0 {
            let f = min(w > 0 ? (w - overX) / w : 1, h > 0 ? (h - overY) / h : 1)
            w *= f; h *= f
            x = sx > 0 ? a.x : a.x - w; y = sy > 0 ? a.y : a.y - h
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Aspect presets on a ring around a centre button that swaps portrait/landscape.
private struct AspectDial: View {
    @Bindable var session: CropSession
    @State private var hovered: AspectChoice?

    var body: some View {
        let choices = AspectChoice.allCases
        ZStack {
            Circle().fill(.regularMaterial).frame(width: 196, height: 196).shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            ForEach(Array(choices.enumerated()), id: \.element) { i, c in
                let a = -Double.pi / 2 + Double(i) / Double(choices.count) * 2 * .pi
                let selected = session.aspect == c
                Button { session.choose(c) } label: {
                    Text(c.label).font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(selected || hovered == c ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary)))
                        .foregroundStyle(selected || hovered == c ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? c : nil }
                .offset(x: cos(a) * 70, y: sin(a) * 70)
                .help("\(c.label) (\(i + 1))")
            }
            Button { session.swapOrientation() } label: {
                Image(systemName: "rectangle.portrait.rotate").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                    .background(Circle().fill(.thickMaterial))
            }
            .buttonStyle(.plain)
            .help("Swap portrait and landscape (X)")
        }
        .frame(width: 200, height: 200)
    }
}

private struct Strip: View {
    @Bindable var session: CropSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(session.urls.enumerated()), id: \.offset) { i, u in
                    Button { session.select(i) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let t = session.thumbnails[u] { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                                else { Color.secondary.opacity(0.2) }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(i == session.index ? Color.accentColor : Color.clear, lineWidth: 2))
                            switch session.states[i] {
                            case .cropped: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).offset(x: 4, y: 4)
                            case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.white, .gray).offset(x: 4, y: 4)
                            case .pending: EmptyView()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(u.lastPathComponent)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: 520)
    }
}
