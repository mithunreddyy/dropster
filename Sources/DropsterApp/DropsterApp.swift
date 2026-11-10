import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import DropsterCore

@main
struct DropsterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var preferences: Preferences
    @State private var model: AppModel

    init() {
        let p = Preferences()
        let m = AppModel(preferences: p)
        _preferences = State(initialValue: p)
        _model = State(initialValue: m)
        AppDelegate.pendingModel = m
    }

    var body: some Scene {
        Window("Dropster", id: "main") {
            ContentView()
                .environment(model)
                .environment(preferences)
                .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 980, height: 620)
        .commands { DropsterCommands(model: model) }

        Window("History", id: "history") {
            HistoryView(store: model.history)
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 640, height: 480)
        .keyboardShortcut("y", modifiers: [.command, .shift])

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(preferences)
        } label: {
            MenuBarMark()
        }

        Settings {
            SettingsView()
                .environment(preferences)
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingModel: AppModel?
    var model: AppModel?
    private let dragWatcher = DragWatcher()
    private var hotKey: HotKey?
    private let services = ServiceProvider()

    /// Started by the system at login (as opposed to by the user).
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Login launches start as a menu bar utility: no window, no Dock icon.
        NSApp.setActivationPolicy(launchedAtLogin ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchedAtLogin || CommandLine.arguments.contains("--background") {
            // SwiftUI opens the main window on launch; put it away again before it is seen.
            DispatchQueue.main.async { DockPresence.closeMainWindows() }
        } else {
            NSApp.activate()
            // SwiftUI restores the last window state: if the window was closed when Dropster
            // last quit, a launch by the user would otherwise show nothing at all.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !NSApp.windows.contains(where: { DockPresence.isAppWindow($0) && $0.isVisible }) { WindowOpener.openMain() }
            }
        }
        DockPresence.start()
        LoginItem.enableOnFirstRun()
        model = Self.pendingModel
        guard let model else { return }
        CloverController.shared.attach(model)
        WatchFolderService.shared.attach(model)
        CursorHUD.shared.model = model
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        model.preferences.onCloverChange = { [weak self] in self?.configureClover() }
        configureClover()
        // Developer aids for screenshots and manual testing:
        //   --show-clover file… [--back] [--expand N]   clover at the screen centre
        //   --crop file…                                 Crop Studio
        //   --run-preset N file…                         run built-in preset N with the cursor ring
        let args = CommandLine.arguments
        func files(after flag: String, skip: Int = 0) -> [URL] {
            guard let i = args.firstIndex(of: flag) else { return [] }
            return args[(i + 1 + skip)...].filter { !$0.hasPrefix("--") && FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }
        if let i = args.firstIndex(of: "--self-test-clover"), args.count > i + 3, let leaf = Int(args[i + 2]), let leaflet = Int(args[i + 3]) {
            let mode = args[i + 1]
            let urls = files(after: "--self-test-clover", skip: 3)
            Task {
                let code = await CloverSelfTest.run(mode: mode, leaf: leaf, leaflet: leaflet, back: args.contains("--back"), files: urls, model: model)
                fflush(stdout)
                exit(code)
            }
            return
        }
        if args.contains("--self-test-dock") {
            // Closing the last window must take Dropster out of the Dock but keep it running.
            Task {
                @MainActor func appWindows() -> [NSWindow] { NSApp.windows.filter { DockPresence.isAppWindow($0) && $0.isVisible } }
                var waited = 0
                while appWindows().isEmpty && waited < 100 { try? await Task.sleep(for: .milliseconds(50)); waited += 1 }
                let before = NSApp.activationPolicy()
                let windows = appWindows()
                print("dock: \(windows.count) window(s) open")
                for w in windows { w.performClose(nil) }
                waited = 0
                while NSApp.activationPolicy() != .accessory && waited < 40 { try? await Task.sleep(for: .milliseconds(50)); waited += 1 }
                let after = NSApp.activationPolicy()
                let watching = CloverDiagnostics.shared.monitorsInstalled
                print("dock: before \(before == .regular ? "regular" : "accessory"), after close \(after == .accessory ? "accessory" : "regular"), dial listening: \(watching)")
                fflush(stdout)
                exit(before == .regular && after == .accessory && watching ? 0 : 1)
            }
        }
        if args.contains("--crop") { CropStudioController.shared.open(files(after: "--crop"), model: model) }
        if let i = args.firstIndex(of: "--run-preset"), let n = Int(args[i + 1]), Preset.builtIns.indices.contains(n) {
            let f = NSScreen.main?.frame ?? .zero
            let ids = model.run(.preset(Preset.builtIns[n]), on: files(after: "--run-preset", skip: 1))
            CursorHUD.shared.track(ids, model: model, at: NSPoint(x: f.midX, y: f.midY))
        }
        if let i = args.firstIndex(of: "--show-clover") {
            CloverController.shared.ignoresPhysicalPointer = true
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            let f = NSScreen.main?.frame ?? .zero
            let flip = args.contains("--back")
            Task {
                await CloverController.shared.showForFiles(files.filter { !$0.path.hasPrefix("--") }, at: NSPoint(x: f.midX, y: f.midY))
                if let leaf = args.firstIndex(of: "--expand").flatMap({ Int(args[$0 + 1]) }) {
                    try? await Task.sleep(for: .milliseconds(300))
                    if flip { CloverController.shared.flip(); try? await Task.sleep(for: .milliseconds(400)) }
                    CloverController.shared.pointerMoved(CloverController.shared.state.layout.leafCenter(leaf))
                } else if flip { CloverController.shared.flip() }
            }
        }
    }

    /// Applies the clover settings: drag-with-modifier and the ⌥⌘D shortcut.
    func configureClover() {
        guard let p = model?.preferences else { return }
        dragWatcher.modifier = p.cloverModifier.flag
        dragWatcher.isEnabled = p.cloverOnDrag
        if p.cloverOnDrag { dragWatcher.start() } else { dragWatcher.stop() }
        hotKey?.unregister()
        hotKey = nil
        if p.cloverShortcut {
            hotKey = HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey), id: 1) {
                MainActor.assumeIsolated {
                    let (urls, clipboard) = ShortcutSource.files()
                    let point = NSEvent.mouseLocation
                    if urls.isEmpty { NSSound.beep(); return }
                    Task { await CloverController.shared.showForFiles(urls, at: point, clipboard: clipboard) }
                }
            }
        }
    }

    /// Dropster keeps running in the menu bar so the clover works with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.openMain() }
        return true
    }

    /// Files dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        model?.add(urls)
        WindowOpener.openMain()
    }
}

struct DropsterCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = WindowOpener.register(openWindow)
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { FilePicker.present(model) }
                .keyboardShortcut("o")
        }
        CommandMenu("Queue") {
            Button("Start") { model.startAll() }
                .keyboardShortcut(.return, modifiers: .command)
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Cancel All") { model.cancelAll() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Merge Selected into One PDF") { model.runBatch(.mergePDF, inputs: model.selectedURLs) }
                .disabled(model.selectedURLs.count < 1)
            Button("Pack Selected into One ZIP") { model.runBatch(.zip, inputs: model.selectedURLs) }
                .disabled(model.selectedURLs.isEmpty)
            Button("Crop Selected…") { CropStudioController.shared.open(model.selectedImageURLs, model: model) }
                .disabled(model.selectedImageURLs.isEmpty)
            Divider()
            Button("Clear Finished") { model.clearFinished() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Remove Selected") { model.remove(model.selection) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
        }
        CommandGroup(after: .windowArrangement) {
            Button("History") { openWindow(id: "history") }
        }
    }
}

/// The menu bar utility: the clover's home when no window is open.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = WindowOpener.register(openWindow)
        Button("Open Dropster") { WindowOpener.openMain() }
        Button("Convert Clipboard…") {
            let files = Clipboard.files()
            if files.isEmpty { NSSound.beep() } else {
                let p = NSEvent.mouseLocation
                Task { await CloverController.shared.showForFiles(files, at: p, clipboard: true) }
            }
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
        Divider()
        let watching = WatchFolderService.shared.rules.filter(\.enabled)
        if !watching.isEmpty {
            Text("Watching \(watching.count == 1 ? "“\(watching[0].folder.lastPathComponent)”" : "\(watching.count) folders")")
        }
        if model.activeCount > 0 {
            Text("Processing \(model.activeCount) files")
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
            Divider()
        }
        let recent = model.items.filter { $0.result?.output != nil }.suffix(5)
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(Array(recent)) { item in
                    Button(item.result!.output!.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([item.result!.output!]) }
                }
            }
            Divider()
        }
        Text(preferences.cloverOnDrag ? "Hold \(preferences.cloverModifier.symbol) while dragging files for the clover" : "Clover on drag is off")
        Divider()
        Button("History") { openWindow(id: "history") }
        SettingsLink { Text("Settings…") }
        Button("Quit Dropster") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
enum FilePicker {
    static func present(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// "Open at Login" through the system's login item service.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// The dial only exists while Dropster runs, so it starts at login unless the user opted out.
    /// Done once; turning it off in Settings is respected afterwards.
    static func enableOnFirstRun() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" else { return }
        UserDefaults.standard.set(true, forKey: key)
        do { try set(true) } catch { CloverDiagnostics.shared.log("could not add login item: \(error.localizedDescription)") }
    }
}

/// Dropster shows in the Dock only while one of its windows is open; otherwise it lives in
/// the menu bar and keeps the dial ready.
@MainActor
enum DockPresence {
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                // Wait for the window to finish closing, then check what is left.
                DispatchQueue.main.async { update(ignoring: closing) }
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window, isAppWindow(window), NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
            }
        })
    }

    /// Real windows: titled, not panels (the dial, the cursor ring and menus don't count).
    static func isAppWindow(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && !(w is NSPanel) && w.className != "NSStatusBarWindow"
    }

    static func update(ignoring closing: NSWindow? = nil) {
        let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && isAppWindow($0) }
        if !open && NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    static func closeMainWindows() {
        for w in NSApp.windows where isAppWindow(w) { w.close() }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The petals-and-drop mark as a template image (macOS tints it for the menu bar).
/// Falls back to an SF Symbol when running outside the app bundle (`swift run`).
struct MenuBarMark: View {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).accessibilityLabel("Dropster")
        } else {
            Image(systemName: "drop.circle").accessibilityLabel("Dropster")
        }
    }
}
