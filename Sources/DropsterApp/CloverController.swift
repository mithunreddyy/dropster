import AppKit
import SwiftUI
import Observation
import DropsterCore

/// Everything the clover view draws.
@MainActor @Observable
final class CloverState {
    enum Mode { case drag, click }
    enum Face { case front, back }

    var faces = CloverFaces(front: [], back: [])
    var face: Face = .front
    /// Y-axis rotation used while turning the clover over.
    var flipAngle: Double = 0
    var hovered: CloverLayout.Hit?
    var expandedLeaf: Int?
    var fileCount = 0
    var mode: Mode = .drag
    var isVisible = false
    /// Segment being rested on and how far its bezel arc has filled (0...1).
    var dwellLeaf: Int?
    var dwellProgress: Double = 0
    /// How far the core's turn-over ring has filled (0...1).
    var coreProgress: Double = 0
    let layout = CloverLayout()

    var leaves: [CloverLeaf] { face == .front ? faces.front : faces.back }

    func leafletCount(_ leaf: Int) -> Int { leaves.indices.contains(leaf) ? leaves[leaf].leaflets.count : 0 }

    func action(for hit: CloverLayout.Hit?) -> CloverAction? {
        switch hit {
        case .core: return .suggested
        case .leaf(let i): return leaves.indices.contains(i) ? leaves[i].primary : nil
        case .leaflet(let l, let k): return leaves.indices.contains(l) && leaves[l].leaflets.indices.contains(k) ? leaves[l].leaflets[k].action : nil
        case nil: return nil
        }
    }

    var caption: String {
        if case .core = hovered { return mode == .drag ? "Drop for the suggested action · rest here to flip" : "Suggested action · rest here to flip" }
        if let a = action(for: hovered) { return a.caption(fileCount: fileCount) }
        if case .leaf(let i) = hovered, leaves.indices.contains(i), !leaves[i].isEnabled { return "Not available for these files" }
        return face == .front ? "Rest on a leaf for more · Tab or scroll to flip" : "Tools · Tab or scroll to flip back"
    }
}

/// Shows the clover at the cursor and turns a drop or click into an action.
@MainActor
final class CloverController {
    static let shared = CloverController()

    let state = CloverState()
    private var panel: CloverPanel?
    /// The view that receives drags and clicks (exposed for the self-test).
    private(set) var inputView: CloverInputView?
    /// Set by the self-test so the physical mouse can't interfere.
    var ignoresPhysicalPointer = false
    private weak var model: AppModel?
    private var files: [URL] = []
    private var pasteboard: NSPasteboard?
    private var clipboardMode = false
    private var anchor: NSPoint = .zero
    private var dwellTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var flipping = false
    private var monitors: [Any] = []
    private var didDrop = false

    func attach(_ model: AppModel) {
        self.model = model
        prewarm()
    }

    // MARK: Showing

    /// During a drag: the files are read from the drag pasteboard.
    func showForDrag(pasteboard pb: NSPasteboard, at point: NSPoint) async {
        guard model != nil, !state.isVisible else {
            CloverDiagnostics.shared.log("showForDrag skipped: \(model == nil ? "no model" : "already visible")")
            return
        }
        let local = DropReader.immediateFiles(pb)
        pasteboard = pb
        files = local
        clipboardMode = false
        // Appear immediately from a signature-only look at the files, then refine.
        var quick = Self.quickReports(local)
        if quick.isEmpty {
            // A picture dragged out of a browser: treat it as an image until it is downloaded.
            quick = [FileReport(url: URL(fileURLWithPath: "/web.jpg"), byteSize: 0, detectedFormat: .jpeg, extensionFormat: .jpeg)]
        }
        present(reports: quick, count: max(1, local.count), at: point, mode: .drag)
        if !local.isEmpty { await refine(local) }
    }

    /// From the keyboard shortcut, the Services menu or the clipboard: click to choose.
    func showForFiles(_ urls: [URL], at point: NSPoint, clipboard: Bool = false) async {
        guard model != nil, !urls.isEmpty else { return }
        let quick = Self.quickReports(urls)
        guard !quick.isEmpty else { return }
        hide(immediately: true)
        pasteboard = nil
        files = urls
        clipboardMode = clipboard
        present(reports: quick, count: urls.count, at: point, mode: .click)
        await refine(urls)
    }

    /// Format from the first bytes and the extension only (no decoding, no ffprobe): fast
    /// enough to build the menu before the pointer moves.
    static func quickReports(_ urls: [URL]) -> [FileReport] {
        urls.prefix(200).compactMap { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            var detected = FileSignature.detect(url: url)
            let ext = FormatID.fromExtension(url.pathExtension)
            if detected == .zip, let e = ext, [.docx, .odt].contains(e) { detected = e }
            if detected == .tiff, ext == .raw { detected = .raw }
            return FileReport(url: url, byteSize: 0, detectedFormat: detected, extensionFormat: ext)
        }
    }

    /// Full analysis (media tracks, frame counts) may remove choices that don't apply, such as
    /// audio formats for a silent video. Swapped in only if the menu actually changes.
    private func refine(_ urls: [URL]) async {
        guard let model, let processor = model.processor else { return }
        let reports = await model.reports(for: urls)
        guard state.isVisible, files == urls, !reports.isEmpty else { return }
        let faces = CloverMenuBuilder.build(reports: reports, processor: processor, presets: model.presets.all)
        guard faces.front != state.faces.front || faces.back != state.faces.back else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            state.faces = faces
            if let open = state.expandedLeaf, state.leafletCount(open) < 2 { state.expandedLeaf = nil }
        }
    }

    /// Builds and lays out the panel once at launch so the first drag doesn't pay for it.
    func prewarm() {
        guard panel == nil else { return }
        let p = makePanel()
        panel = p
        p.alphaValue = 0
        p.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        p.orderFrontRegardless()
        p.contentView?.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        p.orderOut(nil)
    }

    private func present(reports: [FileReport], count: Int, at point: NSPoint, mode: CloverState.Mode) {
        guard let model, let processor = model.processor else { return }
        state.faces = CloverMenuBuilder.build(reports: reports, processor: processor, presets: model.presets.all)
        state.face = .front
        state.flipAngle = 0
        state.hovered = nil
        state.expandedLeaf = nil
        state.fileCount = count
        state.mode = mode
        didDrop = false
        anchor = point
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2 - 18)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        if mode == .click {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) { state.isVisible = true }
        CloverHaptics.open()
        CloverDiagnostics.shared.lastShown = Date()
        installMonitors(mode: mode)
    }

    private func makePanel() -> CloverPanel {
        let side = state.layout.extent * 2
        let panel = CloverPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side + 36))
        let host = NSHostingView(rootView: CloverView(state: state))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        let input = CloverInputView(frame: panel.contentView!.bounds, controller: self)
        input.autoresizingMask = [.width, .height]
        inputView = input
        panel.contentView!.addSubview(host)
        panel.contentView!.addSubview(input)
        return panel
    }

    func hide(immediately: Bool = false) {
        dwellTask?.cancel()
        hideTask?.cancel()
        removeMonitors()
        guard state.isVisible else { return }
        withAnimation(.easeIn(duration: immediately ? 0 : 0.14)) { state.isVisible = false }
        let panel = self.panel
        hideTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(160)) }
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    /// The global drag ended. If nothing was dropped on the clover, put it away.
    func dragEnded() {
        guard state.mode == .drag, state.isVisible else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !didDrop { hide() }
        }
    }

    // MARK: Pointer

    /// `p` is relative to the clover's centre, y down.
    static let leafDwell: Duration = .milliseconds(300)
    static let coreDwell: Duration = .milliseconds(700)

    func pointerMoved(_ p: CGPoint) {
        let hit = state.layout.hitTest(p, expandedLeaf: state.expandedLeaf, leafletCount: state.expandedLeaf.map(state.leafletCount) ?? 0)
        guard hit != state.hovered else { return }
        state.hovered = hit
        dwellTask?.cancel()
        resetDwell()
        // A detent tick for every segment, bead or the core the pointer crosses.
        if hit != nil { CloverHaptics.detent() }
        switch hit {
        case .leaf(let i):
            if state.expandedLeaf != nil && state.expandedLeaf != i {
                withAnimation(.easeOut(duration: 0.14)) { state.expandedLeaf = nil }
            }
            if state.leafletCount(i) > 1, state.expandedLeaf != i {
                // The bezel arc fills while resting; when it is full, the beads fan out.
                state.dwellLeaf = i
                withAnimation(.linear(duration: 0.3)) { state.dwellProgress = 1 }
                dwellTask = Task {
                    try? await Task.sleep(for: Self.leafDwell)
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { state.expandedLeaf = i }
                    resetDwell()
                    CloverHaptics.open()
                }
            }
        case .core:
            withAnimation(.easeOut(duration: 0.14)) { state.expandedLeaf = nil }
            withAnimation(.linear(duration: 0.7)) { state.coreProgress = 1 }
            dwellTask = Task {
                try? await Task.sleep(for: Self.coreDwell)
                guard !Task.isCancelled else { return }
                flip()
            }
        case .leaflet, nil:
            break
        }
    }

    private func resetDwell() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            state.dwellLeaf = nil
            state.dwellProgress = 0
            state.coreProgress = 0
        }
    }

    func pointerExited() {
        dwellTask?.cancel()
        resetDwell()
        state.hovered = nil
    }

    /// Turns the clover over in two quarter turns, swapping faces at the edge.
    func flip() {
        guard !flipping else { return }
        flipping = true
        resetDwell()
        CloverHaptics.flip()
        Task {
            withAnimation(.easeIn(duration: 0.13)) { state.flipAngle = 90 }
            try? await Task.sleep(for: .milliseconds(130))
            state.face = state.face == .front ? .back : .front
            state.expandedLeaf = nil
            state.hovered = nil
            state.flipAngle = -90
            withAnimation(.easeOut(duration: 0.16)) { state.flipAngle = 0 }
            try? await Task.sleep(for: .milliseconds(160))
            flipping = false
        }
    }

    // MARK: Choosing

    /// Click mode: run the action under the pointer.
    func click(at p: CGPoint) {
        let hit = state.layout.hitTest(p, expandedLeaf: state.expandedLeaf, leafletCount: state.expandedLeaf.map(state.leafletCount) ?? 0)
        guard hit != nil else { hide(); return }
        if case .leaf(let i) = hit, state.leafletCount(i) > 1, state.expandedLeaf != i {
            // A click on a group opens it rather than guessing.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { state.expandedLeaf = i }
            return
        }
        perform(hit, pasteboard: nil)
    }

    /// Drag mode: the user let go over the clover.
    func drop(at p: CGPoint, pasteboard pb: NSPasteboard) -> Bool {
        let hit = state.layout.hitTest(p, expandedLeaf: state.expandedLeaf, leafletCount: state.expandedLeaf.map(state.leafletCount) ?? 0)
        CloverDiagnostics.shared.log("drop at \(Int(p.x)),\(Int(p.y)) → \(String(describing: hit))")
        guard state.action(for: hit) != nil else { return false }
        didDrop = true
        CloverDiagnostics.shared.lastDrop = Date()
        perform(hit, pasteboard: pb)
        return true
    }

    private func perform(_ hit: CloverLayout.Hit?, pasteboard pb: NSPasteboard?) {
        guard let action = state.action(for: hit), let model else { hide(); return }
        CloverHaptics.commit()
        let point = NSEvent.mouseLocation
        let known = files
        let clipboard = clipboardMode
        hide()
        Task {
            var urls = known
            if let pb, urls.isEmpty {
                // A browser drag: download first, showing speed and progress at the cursor.
                let hud = CursorHUD.shared
                hud.showTransfer(at: point)
                do {
                    urls = try await DropReader.files(from: pb) { p in hud.updateTransfer(p) }
                } catch {
                    hud.showFailure(error.localizedDescription, at: point)
                    return
                }
            }
            guard !urls.isEmpty else { return }
            let ids = model.run(action, on: urls, copyResultToClipboard: clipboard)
            if !ids.isEmpty { CursorHUD.shared.track(ids, model: model, at: point) }
        }
    }

    // MARK: Keyboard and scroll

    private func installMonitors(mode: CloverState.Mode) {
        removeMonitors()
        var lastFlip = Date.distantPast
        let scroll: (NSEvent) -> Void = { [weak self] e in
            // One flip per gesture or wheel notch burst.
            guard e.momentumPhase == [], abs(e.scrollingDeltaY) + abs(e.scrollingDeltaX) > 2,
                  Date().timeIntervalSince(lastFlip) > 0.5 else { return }
            lastFlip = Date()
            self?.flip()
        }
        let key: (NSEvent) -> Void = { [weak self] e in
            switch e.keyCode {
            case 48: self?.flip()          // Tab
            case 53: self?.hide()          // Esc
            default: break
            }
        }
        if mode == .drag {
            // The drag belongs to another app, so these arrive as global events.
            // Key events need Accessibility permission; scrolling works without it.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: scroll) { monitors.append(m) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(m) }
        } else {
            if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { scroll($0); return nil }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
                if [48, 53].contains(e.keyCode) { key(e); return nil }
                return e
            }) { monitors.append(m) }
            // Clicking anywhere else dismisses it.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.hide() }) {
                monitors.append(m)
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}

/// Borderless, transparent, non-activating: the app you are dragging from stays in front.
final class CloverPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // A non-opaque window passes events through fully transparent pixels by default,
        // which would hand the drag back to Finder in the gaps between leaves.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Receives drags and mouse events over the clover and forwards positions to the controller.
final class CloverInputView: NSView {
    private weak var controller: CloverController?

    init(frame: NSRect, controller: CloverController) {
        self.controller = controller
        super.init(frame: frame)
        registerForDraggedTypes(DropReader.pasteboardTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The clover's centre sits 18 pt above the view's centre, leaving room for the caption.
    private func centred(_ windowPoint: NSPoint) -> CGPoint {
        let p = convert(windowPoint, from: nil)
        return CGPoint(x: p.x - bounds.midX, y: p.y - (bounds.midY - 18))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated { if controller?.ignoresPhysicalPointer == false { controller?.pointerMoved(centred(event.locationInWindow)) } }
    }
    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { if controller?.ignoresPhysicalPointer == false { controller?.pointerExited() } }
    }
    override func mouseDown(with event: NSEvent) { MainActor.assumeIsolated { controller?.click(at: centred(event.locationInWindow)) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = centred(sender.draggingLocation)
        return MainActor.assumeIsolated {
            controller?.pointerMoved(p)
            return controller?.state.action(for: controller?.state.hovered) == nil ? [] : .copy
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { MainActor.assumeIsolated { controller?.pointerExited() } }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = centred(sender.draggingLocation)
        let pb = sender.draggingPasteboard
        return MainActor.assumeIsolated { controller?.drop(at: p, pasteboard: pb) ?? false }
    }
}

/// The clover's tactile vocabulary on Force Touch trackpads. Detent ticks are throttled so a
/// fast sweep across the dial feels like a rotary click, not a buzz.
@MainActor
enum CloverHaptics {
    private static var lastDetent = Date.distantPast
    private static var performer: NSHapticFeedbackPerformer { NSHapticFeedbackManager.defaultPerformer }

    /// Crossing into a segment, bead or the core.
    static func detent() {
        guard Date().timeIntervalSince(lastDetent) > 0.045 else { return }
        lastDetent = Date()
        performer.perform(.alignment, performanceTime: .now)
    }

    /// The dial appears, or a segment fans out its beads.
    static func open() { performer.perform(.generic, performanceTime: .now) }

    /// Turning the dial over.
    static func flip() { performer.perform(.levelChange, performanceTime: .now) }

    /// A drop or click that starts work: two quick pulses.
    static func commit() {
        performer.perform(.levelChange, performanceTime: .now)
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            performer.perform(.alignment, performanceTime: .now)
        }
    }
}
