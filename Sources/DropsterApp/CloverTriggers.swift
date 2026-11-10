import AppKit
import Carbon.HIToolbox
import Observation
import DropsterCore

/// What the clover's triggers have seen, shown live in Settings › Clover and written to
/// ~/Library/Logs/Dropster/clover.log so a failing gesture can be diagnosed.
@MainActor @Observable
final class CloverDiagnostics {
    static let shared = CloverDiagnostics()
    var monitorsInstalled = false
    var lastMouseDown: Date?
    var lastDragWithFiles: Date?
    var lastDragModifierHeld: Bool?
    var lastShown: Date?
    var lastDrop: Date?
    var lastNote = ""

    @ObservationIgnored private lazy var logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dropster", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clover.log")
    }()

    func log(_ message: String) {
        lastNote = message
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + message + "\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 512 * 1024 {
            try? FileManager.default.removeItem(at: logURL)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    var logFile: URL { logURL }
}

/// Notices when the user drags files anywhere on screen while holding the clover key.
///
/// Global left-mouse-down and left-mouse-dragged monitors (no permission needed for mouse
/// events) start a 60 Hz poll of the global button and modifier state that runs until the
/// button is released. A drag is real when the shared drag pasteboard changed since the
/// pointer was last idle and holds something readable.
@MainActor
final class DragWatcher {
    var modifier: NSEvent.ModifierFlags = .option
    var isEnabled = true
    private var monitors: [Any] = []
    private var timer: Timer?
    /// Drag-pasteboard change count while no button was down.
    private var idleCount = 0
    private var fired = false
    private var reportedDrag = false
    private let dragPasteboard = NSPasteboard(name: .drag)
    private let diag = CloverDiagnostics.shared

    func start() {
        guard monitors.isEmpty else { return }
        idleCount = dragPasteboard.changeCount
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.mouseActivity(e.type) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: handler) { monitors.append(m) }
        diag.monitorsInstalled = monitors.count == 2
        diag.log("watcher started: \(monitors.count) global monitors, modifier \(modifier.rawValue)")
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        timer?.invalidate()
        timer = nil
        diag.monitorsInstalled = false
        diag.log("watcher stopped")
    }

    private func mouseActivity(_ type: NSEvent.EventType) {
        guard isEnabled, timer == nil else { return }
        if type == .leftMouseDown { diag.lastMouseDown = Date() }
        fired = false
        reportedDrag = false
        // 60 Hz: the dial should appear within one frame of the key being held.
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Common modes, so polling continues while menus or other tracking loops run.
        RunLoop.main.add(timer!, forMode: .common)
        poll()
    }

    private func poll() {
        let changed = dragPasteboard.changeCount != idleCount
        if NSEvent.pressedMouseButtons & 1 == 0 {
            timer?.invalidate()
            timer = nil
            idleCount = dragPasteboard.changeCount
            if fired { CloverController.shared.dragEnded() }
            return
        }
        guard !fired, changed, DropReader.canRead(dragPasteboard) else { return }
        let held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(modifier)
        if !reportedDrag {
            reportedDrag = true
            diag.lastDragWithFiles = Date()
            diag.lastDragModifierHeld = held
            diag.log("drag with \(dragPasteboard.types?.count ?? 0) types; modifier held: \(held)")
        }
        guard held else { return }
        fired = true
        let point = NSEvent.mouseLocation
        let pb = dragPasteboard
        diag.log("showing clover at \(Int(point.x)),\(Int(point.y))")
        Task { await CloverController.shared.showForDrag(pasteboard: pb, at: point) }
    }
}

/// A system-wide keyboard shortcut via Carbon's hot-key API (no Accessibility permission).
@MainActor
final class HotKey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        self.id = id
        Self.installHandlerOnce()
        Self.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x4452_5053), id: id) // "DRPS"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let handler = HotKey.handlers[hk.id]
            DispatchQueue.main.async { handler?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Where the shortcut takes its files from.
@MainActor
enum ShortcutSource {
    /// Finder's selection when Finder is in front; otherwise the clipboard.
    static func files() -> (urls: [URL], clipboard: Bool) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            let urls = finderSelection()
            if !urls.isEmpty { return (urls, false) }
        }
        return (Clipboard.files(), true)
    }

    /// Asks Finder for its selection (macOS asks the user once for permission).
    static func finderSelection() -> [URL] {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with f in (selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            CloverDiagnostics.shared.log("Finder selection unavailable: \(error?[NSAppleScript.errorMessage] ?? "no result")")
            return []
        }
        return result.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// "Convert with Dropster" in Finder's right-click menu (Services / Quick Actions).
final class ServiceProvider: NSObject {
    @objc func convertWithDropster(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let point = NSEvent.mouseLocation
        MainActor.assumeIsolated {
            Task { await CloverController.shared.showForFiles(urls, at: point) }
        }
    }
}
