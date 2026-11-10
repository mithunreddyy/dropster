import AppKit
import DropsterCore

/// End-to-end check of the clover without a physical mouse: shows the real panel and drives
/// the real input view with synthetic drag or click events, then waits for the results.
///
///   Dropster --self-test-clover drag|click <leaf> <leaflet> [--back] file…
///
/// Prints one line per result and exits 0 when every file produced an output.
@MainActor
enum CloverSelfTest {
    static func run(mode: String, leaf: Int, leaflet: Int, back: Bool, files: [URL], model: AppModel) async -> Int32 {
        let controller = CloverController.shared
        controller.ignoresPhysicalPointer = true
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let point = NSPoint(x: screen.midX, y: screen.midY)
        let before = Set(model.items.map(\.id))
        let pb = NSPasteboard(name: NSPasteboard.Name("app.dropster.selftest.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(files.map { $0 as NSURL })

        // Time from the trigger to the panel being on screen (before any refinement finishes).
        let started = Date()
        let shown = Task { @MainActor in
            while !(controller.state.isVisible && controller.inputView?.window?.isVisible == true) { await Task.yield() }
            return Date().timeIntervalSince(started)
        }
        if mode == "drag" {
            await controller.showForDrag(pasteboard: pb, at: point)
        } else {
            await controller.showForFiles(files, at: point)
        }
        print(String(format: "clover: on screen in %.1f ms", await shown.value * 1000))
        guard let view = controller.inputView, controller.state.isVisible else { return fail("clover did not appear") }
        try? await Task.sleep(for: .milliseconds(350))
        if back {
            controller.flip()
            try? await Task.sleep(for: .milliseconds(450))
            guard controller.state.face == .back else { return fail("clover did not turn over") }
        }
        let layout = controller.state.layout
        func windowPoint(_ p: CGPoint) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX + p.x, y: view.bounds.midY - 18 + p.y), to: nil)
        }
        let leafPoint = layout.leafCenter(leaf)
        let info = FakeDraggingInfo(pasteboard: pb, window: view.window)

        if mode == "drag" {
            info.location = windowPoint(leafPoint)
            guard view.draggingEntered(info) == .copy else { return fail("leaf \(leaf) refused the drag") }
        } else {
            controller.pointerMoved(leafPoint)
        }
        // Rest on the leaf so it fans out.
        try? await Task.sleep(for: .milliseconds(450))
        let count = controller.state.leafletCount(leaf)
        guard leaflet < count else { return fail("leaf \(leaf) has \(count) leaflets, wanted index \(leaflet)") }
        if count > 1 {
            // In click mode a click opens a closed leaf; clicking an open leaf would run its main action.
            if mode == "click" && controller.state.expandedLeaf != leaf { controller.click(at: leafPoint) }
            guard controller.state.expandedLeaf == leaf else { return fail("leaf \(leaf) did not fan out") }
        }
        let target = count > 1 ? layout.leafletCenters(leaf: leaf, count: count)[leaflet] : leafPoint
        let action = controller.state.leaves[leaf].leaflets[leaflet].action
        print("clover: \(controller.state.face == .front ? "front" : "back") leaf \(controller.state.leaves[leaf].title) → \(action.caption(fileCount: files.count))")

        if mode == "drag" {
            info.location = windowPoint(target)
            guard view.draggingUpdated(info) == .copy else { return fail("leaflet refused the drag") }
            guard view.performDragOperation(info) else { return fail("drop was not accepted") }
        } else {
            controller.click(at: target)
        }

        if case .crop = action { return CropStudioOpen() ? 0 : fail("crop studio did not open") }
        // Wait for the new rows to finish.
        let deadline = Date().addingTimeInterval(120)
        var newItems: [Item] = []
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            newItems = model.items.filter { !before.contains($0.id) }
            if !newItems.isEmpty, newItems.allSatisfy(\.isFinished) { break }
        }
        guard !newItems.isEmpty else { return fail("no work was started") }
        var ok = true
        for item in newItems {
            switch item.state {
            case .done(let r):
                let exists = r.output.map { FileManager.default.fileExists(atPath: $0.path) } ?? (r.outcome == .keptOriginal)
                ok = ok && exists
                print("  \(exists ? "✓" : "✗") \(item.name) → \(r.output?.lastPathComponent ?? "kept original") (\(Fmt.bytes(r.inputBytes)) → \(Fmt.bytes(r.producedBytes)))")
            default:
                ok = false
                print("  ✗ \(item.name): \(item.state)")
            }
        }
        return ok ? 0 : 1
    }

    private static func CropStudioOpen() -> Bool {
        NSApp.windows.contains { $0.title == "Crop" && $0.isVisible }
    }

    private static func fail(_ message: String) -> Int32 {
        print("clover self-test failed: \(message)")
        return 2
    }
}

/// Minimal NSDraggingInfo for driving the clover's drop target.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    var location: NSPoint = .zero
    let pasteboard: NSPasteboard
    weak var window: NSWindow?

    init(pasteboard: NSPasteboard, window: NSWindow?) {
        self.pasteboard = pasteboard
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
