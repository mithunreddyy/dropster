import SwiftUI
import DropsterCore
import DropsterEngines

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CloverSettings().tabItem { Label("Clover", systemImage: "leaf") }
            PresetSettings().tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            WatchSettings().tabItem { Label("Watch", systemImage: "eye") }
            EnginesSettings().tabItem { Label("Engines", systemImage: "cpu") }
        }
        .frame(width: 620)
    }
}

struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var loginError: String?

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                Picker("Save results", selection: Binding(
                    get: { p.outputFolder == nil ? 0 : 1 },
                    set: { v in
                        if v == 0 { p.outputFolder = nil }
                        else if let f = FilePicker.chooseFolder() { p.outputFolder = f }
                    })) {
                    Text("Next to the original").tag(0)
                    Text(p.outputFolder?.lastPathComponent ?? "In a folder…").tag(1)
                }
                TextField("File names", text: $p.nameTemplate, prompt: Text("Automatic"))
                Toggle("Keep the original’s creation and modification dates", isOn: $p.keepFileDates)
                Toggle("Start as soon as files are added", isOn: $p.startAutomatically)
                Toggle("Include files in subfolders", isOn: $p.includeSubfolders)
                Toggle("Open at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { on in
                    do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            } footer: {
                Text("Names can use {name}, {ext}, {action}, {date} and {n}. Leave empty for “photo-min.jpg”, “photo.webp”. Originals are never modified.")
            }
            Section("Quality") {
                Picker("Compression", selection: $p.mode) {
                    ForEach(CompressionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text(p.mode.explanation).font(.callout).foregroundStyle(.secondary)
                Picker("Resize images", selection: $p.maxPixelSize) {
                    Text("Keep original size").tag(0)
                    Text("Longest edge 4096 px").tag(4096)
                    Text("Longest edge 2560 px").tag(2560)
                    Text("Longest edge 1920 px").tag(1920)
                    Text("Longest edge 1080 px").tag(1080)
                }
                Toggle("Discard conversions larger than the original", isOn: $p.discardLargerConversions)
            }
            Section {
                Picker("Metadata", selection: $p.metadata) {
                    ForEach(MetadataPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: { Text("Privacy") } footer: {
                Text("Colour profiles and orientation are always kept. Dropster only uses the network to download a picture you drag in from a web page.")
            }
        }
        .formStyle(.grouped)
    }
}

struct CloverSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                Toggle("Show the clover when dragging files", isOn: $p.cloverOnDrag)
                Picker("While holding", selection: $p.cloverModifier) {
                    ForEach(CloverModifier.allCases, id: \.self) { Text($0.symbol).tag($0) }
                }
                .disabled(!p.cloverOnDrag)
            } header: { Text("Drag") } footer: {
                Text("Drag files in Finder, Photos or a browser and hold the key: the formats that fit open as a clover at your cursor. Drop on a leaf, or rest on it to fan out more choices.")
            }
            Section {
                Toggle("⌥⌘D opens the clover for the Finder selection or the clipboard", isOn: $p.cloverShortcut)
            } header: { Text("Keyboard") } footer: {
                Text("From the clipboard, the result is put back on the clipboard. The first use asks for permission to read Finder’s selection.")
            }
            Section("Using the clover") {
                LabeledContent("Drop on a leaf") { Text("Its main action") }
                LabeledContent("Rest on a leaf") { Text("Fan out every choice") }
                LabeledContent("Drop on the centre") { Text("Each file’s suggested action") }
                LabeledContent("Rest on the centre, Tab or scroll") { Text("Turn over to crop, rotate, colour and combine") }
                LabeledContent("Finder right-click") { Text("Services › Convert with Dropster") }
            }
            .foregroundStyle(.secondary)
            CloverStatusSection()
            Section {
                LabeledContent("Tab while dragging") {
                    Text(AXIsProcessTrusted() ? "Enabled" : "Needs Accessibility permission (scrolling works without it)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Presets

struct PresetSettings: View {
    @Environment(AppModel.self) private var model
    @State private var presets: [Preset] = []
    @State private var selection: Preset.ID?
    @State private var category: FormatCategory = .image

    static let categories: [FormatCategory] = [.image, .video, .audio, .document]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Kind", selection: $category) {
                    ForEach(Self.categories, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(8)
                List(selection: $selection) {
                    ForEach(presets.filter { $0.category == category }) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.operation.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(p.id)
                    }
                }
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }.help("New preset")
                    Button { if let s = selection { model.presets.delete(s); reload() } } label: { Image(systemName: "minus") }
                        .disabled(selection == nil).help("Delete preset")
                    Spacer()
                    Button("Restore Built-ins") { model.presets.restoreBuiltIns(); reload() }
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 210, maxWidth: 240)
            Group {
                if let id = selection, let preset = presets.first(where: { $0.id == id }) {
                    PresetEditor(preset: preset) { model.presets.save($0); reload() }
                        .id(id)
                } else {
                    ContentUnavailableView("Select a Preset", systemImage: "slider.horizontal.3",
                                           description: Text("Presets appear on the clover’s Presets leaf and in each file’s menu."))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity)
        }
        .frame(height: 480)
        .onAppear(perform: reload)
    }

    private func reload() { presets = model.presets.all }

    private func add() {
        let op: FileOperation = switch category {
        case .video: .convert(.mp4)
        case .audio: .convert(.mp3)
        case .document: .optimize
        default: .convert(.webp)
        }
        let p = Preset(name: "New Preset", category: category, operation: op, options: ProcessingOptions())
        model.presets.save(p)
        reload()
        selection = p.id
    }
}

/// The actions a preset can perform for its kind of file.
enum PresetActions {
    static func actions(for c: FormatCategory) -> [FileOperation] {
        switch c {
        case .image:
            [.optimize, .stripMetadata] + [FormatID.webp, .avif, .jpeg, .png, .heic, .tiff, .gif, .pdf, .svg, .ico, .icns, .bmp, .jp2].map { .convert($0) }
                + [.edit(.toGrayscale), .edit(.cutout), .edit(.rotateRight), .edit(.rotateLeft)] + SizeTarget.common.map { .fitSize($0) }
        case .video:
            [.optimize, .stripMetadata] + [FormatID.mp4, .mov, .webm, .mkv, .gif, .mp3, .m4a, .flac].map { .convert($0) }
                + [.exportPages(.jpeg), .exportPages(.png)] + SizeTarget.common.map { .fitSize($0) }
        case .audio:
            [.optimize, .stripMetadata] + [FormatID.mp3, .m4a, .opus, .flac, .wav, .aiff].map { .convert($0) } + SizeTarget.common.map { .fitSize($0) }
        case .document:
            [.optimize, .stripMetadata, .exportPages(.png), .exportPages(.jpeg), .longImage(.png), .longImage(.jpeg), .splitPDF, .convert(.txt)]
                + [FormatID.pdf, .docx, .odt, .rtf, .html].map { .convert($0) }
        default: [.optimize]
        }
    }
}

struct PresetEditor: View {
    @State var preset: Preset
    let save: (Preset) -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                Picker("Action", selection: $preset.operation) {
                    ForEach(PresetActions.actions(for: preset.category), id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Compression", selection: $preset.options.mode) {
                    ForEach(CompressionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Metadata", selection: $preset.options.metadata) {
                    ForEach(MetadataPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            switch preset.category {
            case .image:
                Section("Image") {
                    OptionalIntField("Longest edge (px)", value: $preset.options.maxPixelSize)
                    OptionalIntField("Resolution (dpi)", value: $preset.options.dpi)
                    Slider(value: Binding(get: { preset.options.qualityOverride ?? 0 }, set: { preset.options.qualityOverride = $0 < 0.05 ? nil : $0 }), in: 0...1) {
                        Text("Quality")
                    } minimumValueLabel: { Text("Auto").font(.caption) } maximumValueLabel: { Text("100").font(.caption) }
                    Picker("TIFF compression", selection: $preset.options.tiffCompression) {
                        ForEach(TIFFCompression.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField("ICO sizes", text: Binding(get: { preset.options.icoSizes.map(String.init).joined(separator: ", ") },
                                                         set: { preset.options.icoSizes = $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...256).contains($0) } }))
                }
            case .video:
                Section("Video") {
                    Picker("Height", selection: $preset.options.maxVideoHeight) {
                        Text("Original").tag(Int?.none)
                        ForEach([2160, 1080, 720, 480], id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
                    }
                    Picker("Codec", selection: $preset.options.videoCodec) {
                        ForEach(VideoCodecChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Hardware encoding (faster, larger)", isOn: $preset.options.hardwareEncoding)
                    OptionalIntField("Frames per second (pictures)", value: Binding(get: { preset.options.frameRate.map { Int($0) } }, set: { preset.options.frameRate = $0.map(Double.init) }))
                    OptionalIntField("Longest edge (px, GIF)", value: $preset.options.maxPixelSize)
                }
            case .audio:
                Section("Audio") {
                    Picker("MP3 bitrate", selection: $preset.options.mp3Bitrate) {
                        Text("Variable (by compression)").tag(Int?.none)
                        ForEach([96, 128, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag(Int?.some($0)) }
                    }
                }
            case .document:
                Section("PDF") { OptionalIntField("Page image resolution (dpi)", value: $preset.options.dpi) }
            default: EmptyView()
            }
            Section("Output") {
                Picker("Save to", selection: Binding(
                    get: { if case .folder = preset.options.output { 1 } else { 0 } },
                    set: { v in
                        if v == 0 { preset.options.output = .nextToOriginal }
                        else if let f = FilePicker.chooseFolder() { preset.options.output = .folder(f) }
                    })) {
                    Text("Next to the original").tag(0)
                    if case .folder(let f) = preset.options.output { Text(f.lastPathComponent).tag(1) } else { Text("Folder…").tag(1) }
                }
                TextField("File names", text: Binding(get: { preset.options.nameTemplate ?? "" }, set: { preset.options.nameTemplate = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Automatic"))
                Toggle("Keep original file dates", isOn: $preset.options.keepFileDates)
            }
        }
        .formStyle(.grouped)
        .onChange(of: preset) { _, new in save(new) }
    }
}

private struct OptionalIntField: View {
    let title: String
    @Binding var value: Int?
    init(_ title: String, value: Binding<Int?>) { self.title = title; _value = value }

    var body: some View {
        TextField(title, text: Binding(get: { value.map(String.init) ?? "" }, set: { value = Int($0.filter(\.isNumber)) }), prompt: Text("Original"))
    }
}

// MARK: - Engines

struct EnginesSettings: View {
    @Environment(AppModel.self) private var model
    struct Tool: Identifiable {
        let id: String
        let formula: String
        let purpose: String
        let versionArgs: [String]
    }
    static let tools = [
        Tool(id: "ffmpeg", formula: "ffmpeg", purpose: "Video, audio, JPEG optimization, frames, quality measurement", versionArgs: ["-version"]),
        Tool(id: "cwebp", formula: "webp", purpose: "WebP output", versionArgs: ["-version"]),
        Tool(id: "gs", formula: "ghostscript", purpose: "Stronger PDF compression", versionArgs: ["--version"]),
        Tool(id: "zstd", formula: "zstd", purpose: "Zstandard", versionArgs: ["--version"]),
        Tool(id: "xz", formula: "xz", purpose: "XZ", versionArgs: ["--version"]),
        Tool(id: "brotli", formula: "brotli", purpose: "Brotli", versionArgs: ["--version"]),
    ]
    @State private var versions: [String: String] = [:]
    @State private var installing: String?
    @State private var log = ""
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Apple ImageIO, Vision, PDFKit") { Text("Built in").foregroundStyle(.secondary) }
                LabeledContent("PNG optimizer, subtitles, documents") { Text("Built in").foregroundStyle(.secondary) }
                ForEach(Self.tools) { t in
                    LabeledContent {
                        if let v = versions[t.id] {
                            Text(v).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                        } else if installing == t.id {
                            ProgressView().controlSize(.small)
                        } else if Homebrew.path != nil {
                            Button("Install") { Task { await install(t) } }.disabled(installing != nil)
                        } else {
                            Text("brew install \(t.formula)").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(t.id)
                            Text(t.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text(Homebrew.path == nil
                     ? "Optional tools are installed with Homebrew (brew.sh). Dropster finds copies you already have and never downloads them itself."
                     : "Optional tools are installed with Homebrew. Dropster finds copies you already have; missing tools only hide the formats they provide.")
            }
            if installing != nil || failure != nil {
                Section("Homebrew") {
                    if let failure { Text(failure).foregroundStyle(.orange) }
                    ScrollView {
                        Text(log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(height: 120)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        var found: [String: String] = [:]
        for t in Self.tools {
            guard let url = ToolLocator.find(t.id) else { continue }
            let out = try? await ProcessRunner.run(url, t.versionArgs)
            let text = (out.map { String(decoding: $0.stdout, as: UTF8.self) + $0.stderr } ?? "")
            let line = text.split(separator: "\n").first.map(String.init) ?? url.path
            found[t.id] = String(line.prefix(60))
        }
        versions = found
    }

    private func install(_ t: Tool) async {
        guard let brew = Homebrew.path else { return }
        installing = t.id
        failure = nil
        log = "brew install \(t.formula)\n"
        do {
            let out = try await ProcessRunner.run(brew, ["install", t.formula],
                                                  environment: Homebrew.environment(brew)) { line in
                Task { @MainActor in log += line + "\n" }
            }
            if out.status != 0 { failure = "Installation failed (exit \(out.status)). " + out.stderr.split(separator: "\n").suffix(2).joined(separator: " ") }
        } catch {
            failure = error.localizedDescription
        }
        installing = nil
        await refresh()
        model.reloadEngines()
    }
}

enum Homebrew {
    static var path: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func environment(_ brew: URL) -> [String: String] {
        let bin = brew.deletingLastPathComponent().path
        return ["PATH": "\(bin):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "HOMEBREW_NO_ENV_HINTS": "1", "LC_ALL": "en_US.UTF-8"]
    }
}

/// Live view of what the clover's triggers have seen, to make a failing gesture diagnosable.
struct CloverStatusSection: View {
    @Environment(Preferences.self) private var preferences
    let diag = CloverDiagnostics.shared

    var body: some View {
        Section {
            LabeledContent("Listening for drags") {
                Text(preferences.cloverOnDrag ? (diag.monitorsInstalled ? "Yes" : "No: monitors could not be installed") : "Off")
            }
            LabeledContent("Last drag of files seen") { Text(ago(diag.lastDragWithFiles)) }
            if let held = diag.lastDragModifierHeld {
                LabeledContent("\(preferences.cloverModifier.symbol) held during it") { Text(held ? "Yes" : "No: hold it while the files are moving") }
            }
            LabeledContent("Clover last shown") { Text(ago(diag.lastShown)) }
            LabeledContent("Last drop on the clover") { Text(ago(diag.lastDrop)) }
            HStack {
                Button("Show Clover Now") {
                    let files = ShortcutSource.files().urls
                    let p = NSEvent.mouseLocation
                    if files.isEmpty { NSSound.beep() } else { Task { await CloverController.shared.showForFiles(files, at: p) } }
                }
                .help("Opens the clover for the Finder selection or the clipboard")
                Button("Open Log") { NSWorkspace.shared.open(diag.logFile) }
            }
        } header: { Text("Status") } footer: {
            Text("Start dragging a file, then press and hold the key while it moves. The clover appears under the pointer; drop onto it.")
        }
        .foregroundStyle(.secondary)
    }

    private func ago(_ d: Date?) -> String {
        guard let d else { return "Not yet" }
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}

/// Folders whose new files are processed automatically.
struct WatchSettings: View {
    @Environment(AppModel.self) private var model
    private var service: WatchFolderService { .shared }

    var body: some View {
        Form {
            Section {
                if service.rules.isEmpty {
                    Text("No folders yet. Add your Downloads or Screenshots folder and every new file gets the action you choose.")
                        .foregroundStyle(.secondary)
                }
                ForEach(service.rules) { rule in WatchRuleRow(rule: rule) }
            } header: {
                HStack {
                    Text("Watch Folders")
                    Spacer()
                    Button("Add Folder…") {
                        if let f = FilePicker.chooseFolder() { service.add(folder: f, operation: .optimize) }
                    }
                }
            } footer: {
                Text("Only files added after a folder is watched are processed, including ones that arrive while Dropster is closed. Results go to a subfolder inside the watched folder; originals are never changed. Files an action doesn’t apply to are skipped.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }
}

private struct WatchRuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: WatchRule
    private var service: WatchFolderService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(rule.folder.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                    .help(rule.folder.path(percentEncoded: false))
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; service.update(r) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                Button { service.remove(rule.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Stop watching this folder").accessibilityLabel("Remove")
            }
            Picker("Action", selection: Binding(get: { rule.presetID.map { "p:" + $0.uuidString } ?? "o:" + rule.operation.label },
                                                set: { tag in
                var r = rule
                if tag.hasPrefix("p:"), let id = UUID(uuidString: String(tag.dropFirst(2))) { r.presetID = id }
                else if let op = WatchFolderService.actions.first(where: { "o:" + $0.label == tag }) { r.presetID = nil; r.operation = op }
                service.update(r)
            })) {
                ForEach(WatchFolderService.actions, id: \.self) { Text($0.label).tag("o:" + $0.label) }
                if !model.presets.all.isEmpty {
                    Divider()
                    ForEach(model.presets.all) { p in Text("Preset: \(p.name)").tag("p:" + p.id.uuidString) }
                }
            }
            TextField("Results folder", text: Binding(get: { rule.outputSubfolder },
                                                      set: { var r = rule; r.outputSubfolder = $0.isEmpty ? "Dropster" : $0; service.update(r) }))
            HStack {
                if let problem = service.problems[rule.id] {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let n = service.processedCount[rule.id], n > 0 {
                    Text("\(n) file\(n == 1 ? "" : "s") processed since Dropster started").foregroundStyle(.secondary)
                } else {
                    Text(rule.enabled ? "Waiting for new files" : "Paused").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show Results") {
                    let out = rule.outputFolder
                    if FileManager.default.fileExists(atPath: out.path) { NSWorkspace.shared.open(out) } else { NSWorkspace.shared.open(rule.folder) }
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}
