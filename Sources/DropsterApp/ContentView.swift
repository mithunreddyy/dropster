import SwiftUI
import DropsterCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @State private var isTargeted = false
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        @Bindable var preferences = preferences
        Group {
            if let error = model.setupError {
                ContentUnavailableView("Dropster couldn’t start", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.items.isEmpty {
                EmptyStateView(isTargeted: isTargeted)
            } else {
                FileList()
                    .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
            }
        }
        .overlay {
            if isTargeted && !model.items.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .inspector(isPresented: $showInspector) {
            InspectorView(item: model.selection.count == 1 ? model.item(model.selection.first) : nil)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { FilePicker.present(model) } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add files or folders (⌘O)")
            }
            ToolbarItem(placement: .principal) {
                Picker("Compression", selection: $preferences.mode) {
                    ForEach(CompressionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .help(preferences.mode.explanation)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !preferences.startAutomatically {
                    Button { model.startAll() } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(!model.items.contains { $0.canStart })
                        .help("Process files (⌘↩)")
                }
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(model.activeCount == 0 && !model.isPaused)
                .help(model.isPaused ? "Resume the queue" : "Pause after current files finish")
                Button { model.clearFinished() } label: { Label("Clear Finished", systemImage: "checklist.checked") }
                    .disabled(model.finishedCount == 0)
                    .help("Remove finished files from the list (⌘K)")
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide details")
            }
        }
        .navigationTitle("Dropster")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        if model.items.isEmpty { return "" }
        if model.activeCount > 0 { return "Processing \(model.activeCount) of \(model.items.count)" }
        return model.items.count == 1 ? "1 file" : "\(model.items.count) files"
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    var isTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(isTargeted ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                    .frame(width: 112, height: 112)
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.doc")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .scaleEffect(isTargeted ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
            VStack(spacing: 6) {
                Text(isTargeted ? "Release to add" : "Drop files or folders")
                    .font(.title2.weight(.semibold))
                Text("Images, video, audio and any file to compress. \(preferences.mode.displayName) mode.")
                    .foregroundStyle(.secondary)
            }
            Button("Choose Files…") { FilePicker.present(model) }
                .controlSize(.large)
                .keyboardShortcut("o")
            Label("Processed on this Mac. Nothing is uploaded.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 5]))
                .padding(18)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop files here to process them")
    }
}

struct FileList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                FileRow(item: item)
                    .tag(item.id)
                    .contextMenu { RowMenu(item: item) }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand { model.remove(model.selection) }
    }
}

struct RowMenu: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        if let out = item.result?.output {
            Button("Show Result in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            Button("Open Result") { NSWorkspace.shared.open(out) }
        }
        Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        OperationMenuItems(item: item)
        Divider()
        if item.state.isActive || item.state == .queued {
            Button("Cancel") { model.cancel(item.id) }
        }
        if item.canStart || item.isFinished {
            Button("Run Again") { model.retry(item.id) }.disabled(item.operation == nil)
        }
        Button("Remove from List") { model.remove(model.selection.contains(item.id) ? model.selection : [item.id]) }
    }
}

/// The operations offered for a file: only those an available engine can actually perform.
struct OperationMenuItems: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        let ids = model.selection.contains(item.id) ? model.selection : [item.id]
        let _ = model.engineGeneration
        if model.canOptimize(item) {
            Button("Optimize") { model.setOperation(.optimize, for: ids) }
        }
        if model.canPerform(.stripMetadata, on: item) {
            Button("Remove Metadata") { model.setOperation(.stripMetadata, for: ids) }
        }
        let targets = model.targets(for: item)
        let groups = Dictionary(grouping: targets, by: \.category)
        Menu("Convert To") {
            ForEach(FormatCategory.allCases, id: \.self) { cat in
                if let formats = groups[cat], !formats.isEmpty {
                    Section(cat.displayName) {
                        ForEach(formats, id: \.self) { f in
                            Button(f.displayName) { model.setOperation(.convert(f), for: ids) }
                        }
                    }
                }
            }
        }
        .disabled(targets.isEmpty)
        let edits: [FileOperation] = [.edit(.rotateLeft), .edit(.rotateRight), .edit(ImageEdit(quarterTurns: 2)), .edit(.flipH), .edit(.flipV),
                                      .edit(.toGrayscale), .edit(.cutout)].filter { model.canPerform($0, on: item) }
        if !edits.isEmpty {
            Menu("Edit") {
                Button("Crop…") { CropStudioController.shared.open(model.items.filter { ids.contains($0.id) }.map(\.url), model: model) }
                Divider()
                ForEach(edits, id: \.self) { op in Button(op.label) { model.setOperation(op, for: ids) } }
            }
        }
        let pageOps: [FileOperation] = [.exportPages(.png), .exportPages(.jpeg), .longImage(.png), .longImage(.jpeg), .splitPDF]
            .filter { model.canPerform($0, on: item) }
        if !pageOps.isEmpty {
            Menu(item.report?.format == .pdf ? "Pages" : "Frames") {
                ForEach(pageOps, id: \.self) { op in Button(op.label) { model.setOperation(op, for: ids) } }
                if item.report?.format == .pdf { Button("Extract Pages…") { PageRangePrompt.ask { r in model.setOperation(.extractPages(r), for: ids) } } }
            }
        }
        if model.canPerform(.fitSize(SizeTarget.common[0]), on: item) {
            Menu("Fit Under") {
                ForEach(SizeTarget.common, id: \.self) { b in
                    Button(SizeTarget.label(b)) { model.setOperation(.fitSize(b), for: ids) }
                }
                Divider()
                Button("Other Size…") { SizePrompt.ask { b in model.setOperation(.fitSize(b), for: ids) } }
            }
        }
        if model.canPerform(.unpack, on: item) {
            Button("Unpack") { model.setOperation(.unpack, for: ids) }
        }
        let presets = model.presets.all.filter { p in item.report.map { model.processor?.canPerform(p.operation, on: $0) ?? false } ?? false
            && p.category == (item.report?.format == .gif ? .image : item.report?.format?.category) }
        if !presets.isEmpty {
            Menu("Presets") {
                ForEach(presets) { p in Button(p.name) { model.apply(p, to: ids) } }
            }
        }
    }
}

/// Asks for a size limit such as "8 MB".
@MainActor
enum SizePrompt {
    static func ask(_ completion: (Int64) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Fit Under a Size"
        alert.informativeText = "The largest the result may be, for example 8 MB or 750 KB. Dropster keeps as much quality as fits."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "8 MB"
        alert.accessoryView = field
        alert.addButton(withTitle: "Fit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let b = SizeTarget.parse(field.stringValue) { completion(b) } else { NSSound.beep() }
    }
}

/// Asks for a page range such as "1-3, 7".
@MainActor
enum PageRangePrompt {
    static func ask(_ completion: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Extract Pages"
        alert.informativeText = "Pages to keep, for example 1-3, 7 or 10-"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "1-3, 7"
        alert.accessoryView = field
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            completion(field.stringValue)
        }
    }
}
