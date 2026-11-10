import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import DropsterCore
import DropsterEngines

/// One row in the window: a file being processed, or a batch (merge/ZIP) of several.
struct Item: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var report: FileReport?
    var operation: FileOperation?
    var jobID: JobID?
    var state: JobState = .analyzing
    /// Options the job ran with (a preset's, or the current preferences).
    var options: ProcessingOptions?
    /// Set when the user picked the action (clover, preset), so analysis must not replace it.
    var requestedOperation: FileOperation?
    var optionsOverride: ProcessingOptions?
    /// Batch rows combine several inputs into one output.
    var batch: BatchOperation?
    var batchInputs: [URL] = []
    /// Clipboard conversions put the result back on the clipboard.
    var copyResultToClipboard = false
    /// Added by a watch folder: files the rule can't handle are dropped quietly instead of failing.
    var fromWatchFolder = false

    var name: String {
        if let batch { return "\(batchInputs.count) files → \(BatchProcessor.defaultName(for: batch, inputs: batchInputs))" }
        return url.lastPathComponent
    }
    var result: ProcessingResult? { if case .done(let r) = state { r } else { nil } }
    var isFinished: Bool { state.isTerminal }
    var canStart: Bool {
        guard batch == nil else { return false }
        switch state {
        case .ready, .failed, .cancelled: return operation != nil
        default: return false
        }
    }
}

/// Aggregate state of a group of items, for the progress ring at the cursor.
struct GroupProgress: Equatable {
    var fraction: Double
    var finished: Int
    var failed: Int
    var total: Int
    var inputBytes: Int64
    var outputBytes: Int64
    var isDone: Bool { finished == total }
}

@MainActor @Observable
final class AppModel {
    private(set) var items: [Item] = []
    var selection: Set<Item.ID> = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var isPaused = false
    private(set) var setupError: String?
    /// Bumped when engines are reloaded so views re-query capabilities.
    private(set) var engineGeneration = 0

    let preferences: Preferences
    let presets = PresetStore()
    private(set) var processor: Processor?
    let history: HistoryStore?
    private var queue: JobQueue?
    private var workspace: Workspace?
    private let analyzer = FileAnalyzer()
    private var eventTask: Task<Void, Never>?
    private var startTime: Date?

    init(preferences: Preferences) {
        self.preferences = preferences
        history = try? HistoryStore(url: HistoryStore.defaultURL())
        do {
            let ws = try Workspace()
            ws.purgeStale()
            workspace = ws
        } catch {
            setupError = error.localizedDescription
        }
        reloadEngines()
    }

    /// Rebuilds the engine registry (after installing a tool). Running jobs keep their old engines.
    func reloadEngines() {
        guard let workspace else { return }
        let p = Processor(registry: Engines.makeRegistry(), workspace: workspace, verifier: DefaultVerifier())
        let q = JobQueue(processor: p)
        processor = p
        queue = q
        engineGeneration += 1
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in await q.events() {
                guard case .updated(let job) = event else { continue }
                self?.apply(job)
            }
        }
    }

    // MARK: Adding files

    /// Files dropped on the window: each gets its suggested action.
    func add(_ urls: [URL]) {
        let files = expand(urls)
        let existing = Set(items.map(\.url))
        let fresh = files.filter { !existing.contains($0) }
        guard !fresh.isEmpty else { return }
        insert(fresh.map { Item(url: $0) })
    }

    /// Runs an explicit action (from the clover, a preset or the clipboard). Returns the new rows.
    @discardableResult
    func run(_ action: CloverAction, on urls: [URL], copyResultToClipboard: Bool = false) -> [Item.ID] {
        let files = expand(urls)
        guard !files.isEmpty else { return [] }
        switch action {
        case .batch(let b):
            return [runBatch(b, inputs: files)]
        case .crop:
            CropStudioController.shared.open(files, model: self)
            return []
        case .suggested, .operation, .preset:
            let new: [Item] = files.map { url in
                var item = Item(url: url)
                item.copyResultToClipboard = copyResultToClipboard
                switch action {
                case .operation(let op, let mode):
                    item.requestedOperation = op
                    if let mode { var o = preferences.options; o.mode = mode; item.optionsOverride = o }
                case .preset(let p):
                    item.requestedOperation = p.operation
                    item.optionsOverride = p.options
                default: break
                }
                return item
            }
            insert(new, forceStart: true)
            return new.map(\.id)
        }
    }

    /// Files that arrived in a watch folder. Each runs the rule's action with the rule's options.
    func runFromWatchFolder(_ preset: Preset, on urls: [URL]) {
        let new: [Item] = urls.map { url in
            var item = Item(url: url)
            item.requestedOperation = preset.operation
            item.optionsOverride = preset.options
            item.fromWatchFolder = true
            return item
        }
        insert(new, forceStart: true)
    }

    /// Crop results come back per file with each file's own rectangle.
    func runEdit(_ edit: ImageEdit, on url: URL) {
        var item = Item(url: url)
        item.requestedOperation = .edit(edit)
        insert([item], forceStart: true)
    }

    private func insert(_ new: [Item], forceStart: Bool = false) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        items.append(contentsOf: new)
        if selection.isEmpty, let first = new.first { selection = [first.id] }
        for item in new { analyze(item.id, url: item.url, forceStart: forceStart) }
        loadThumbnails(new.map(\.url))
    }

    /// Folders are expanded to their files (skipping hidden files and app bundles).
    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { out.append(u); continue }
            let opts: FileManager.DirectoryEnumerationOptions = preferences.includeSubfolders
                ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: opts) else { continue }
            for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(f)
                if out.count >= 10_000 { return out }
            }
        }
        return out
    }

    /// Analyses files for the clover without adding them to the list.
    func reports(for urls: [URL]) async -> [FileReport] {
        let files = expand(urls)
        let analyzer = self.analyzer
        return await withTaskGroup(of: (Int, FileReport).self) { group in
            for (i, f) in files.prefix(200).enumerated() { group.addTask { (i, await analyzer.analyze(f)) } }
            var out: [(Int, FileReport)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func analyze(_ id: Item.ID, url: URL, forceStart: Bool) {
        let analyzer = self.analyzer
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = await analyzer.analyze(url)
            await self?.finishAnalysis(id, report: report, forceStart: forceStart)
        }
    }

    private func finishAnalysis(_ id: Item.ID, report: FileReport, forceStart: Bool) {
        guard let i = index(id) else { return }
        items[i].report = report
        if let requested = items[i].requestedOperation {
            items[i].operation = requested
            if let processor, !processor.canPerform(requested, on: report) {
                if items[i].fromWatchFolder {
                    let gone = items.remove(at: i)
                    selection.remove(gone.id)
                    return
                }
                items[i].state = .failed("\(requested.label) isn’t available for \(Fmt.kind(report))")
                return
            }
        } else {
            let optimizable = processor?.registry.optimizableFormats ?? []
            var op = Advisor.defaultOperation(for: report, optimizable: optimizable)
            if let o = op, let processor, !processor.canPerform(o, on: report) { op = nil }
            items[i].operation = op
        }
        items[i].state = .ready
        if (forceStart || preferences.startAutomatically), items[i].operation != nil { start(id) }
    }

    private func loadThumbnails(_ urls: [URL]) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for url in urls where thumbnails[url] == nil {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                guard let image = rep?.nsImage else { return }
                Task { @MainActor in self?.thumbnails[url] = image }
            }
        }
    }

    // MARK: Running

    func start(_ id: Item.ID) {
        guard let queue, let i = index(id), let report = items[i].report, let op = items[i].operation else { return }
        let options = items[i].optionsOverride ?? preferences.options
        let job = Job(report: report, operation: op, options: options)
        items[i].jobID = job.id
        items[i].options = options
        items[i].state = .queued
        if startTime == nil { startTime = Date() }
        Task { await queue.enqueue(job) }
    }

    func startAll() {
        for item in items where item.canStart && (item.state == .ready || selection.contains(item.id)) { start(item.id) }
    }

    func setOperation(_ op: FileOperation, for ids: Set<Item.ID>, options: ProcessingOptions? = nil) {
        for id in ids {
            guard let i = index(id), items[i].report != nil, items[i].batch == nil else { continue }
            if items[i].state.isActive || items[i].state == .queued { continue }
            items[i].operation = op
            items[i].requestedOperation = op
            items[i].optionsOverride = options
            items[i].state = .ready
            if preferences.startAutomatically { start(id) }
        }
    }

    func apply(_ preset: Preset, to ids: Set<Item.ID>) {
        setOperation(preset.operation, for: ids, options: preset.options)
    }

    func retry(_ id: Item.ID) {
        guard let i = index(id), items[i].batch == nil, items[i].operation != nil else { return }
        start(items[i].id)
    }

    func cancel(_ id: Item.ID) {
        guard let queue, let i = index(id), let job = items[i].jobID else { return }
        Task { await queue.cancel(job) }
    }

    func remove(_ ids: Set<Item.ID>) {
        for id in ids {
            if let i = index(id), let job = items[i].jobID, let queue { Task { await queue.remove(job) } }
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        updateDockBadge()
    }

    func clearFinished() {
        remove(Set(items.filter { $0.isFinished }.map(\.id)))
        if items.isEmpty { startTime = nil }
    }

    func togglePause() {
        guard let queue else { return }
        isPaused.toggle()
        let paused = isPaused
        Task { if paused { await queue.pause() } else { await queue.resume() } }
    }

    func cancelAll() {
        guard let queue else { return }
        Task { await queue.cancelAll() }
    }

    /// Merge or ZIP several files into one result, shown as a single row.
    @discardableResult
    func runBatch(_ op: BatchOperation, inputs: [URL]) -> Item.ID {
        var item = Item(url: inputs[0])
        item.batch = op
        item.batchInputs = inputs
        item.state = .running(progress: 0)
        items.append(item)
        let id = item.id
        guard let workspace else {
            items[items.count - 1].state = .failed("Workspace unavailable")
            return id
        }
        var folder: URL?
        if let f = preferences.outputFolder { folder = f }
        let batch = BatchProcessor(workspace: workspace)
        let inputBytes = inputs.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? NSNumber ?? 0).int64Value }
        Task.detached(priority: .userInitiated) { [weak self] in
            let start = Date()
            do {
                let out = try await batch.run(op, inputs: inputs, folder: folder) { p in
                    Task { @MainActor in self?.setBatchProgress(id, p) }
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
                let r = ProcessingResult(outcome: .written, output: out, inputBytes: inputBytes, producedBytes: size,
                                         duration: Date().timeIntervalSince(start), route: [op == .mergePDF ? .pdf : .zip])
                await self?.finishBatch(id, .done(r), op: op)
            } catch {
                await self?.finishBatch(id, .failed(error.localizedDescription), op: op)
            }
        }
        return id
    }

    private func setBatchProgress(_ id: Item.ID, _ p: Double) {
        guard let i = index(id), case .running = items[i].state else { return }
        items[i].state = .running(progress: p)
    }

    private func finishBatch(_ id: Item.ID, _ state: JobState, op: BatchOperation) {
        guard let i = index(id) else { return }
        items[i].state = state
        if case .done(let r) = state { history?.record(source: items[i].url, operation: .convert(op == .mergePDF ? .pdf : .zip), result: r) }
        finishedFeedback()
    }

    private func apply(_ job: Job) {
        guard let i = items.firstIndex(where: { $0.jobID == job.id }) else { return }
        let wasTerminal = items[i].state.isTerminal
        items[i].state = job.state
        if case .done(let r) = job.state, !wasTerminal {
            history?.record(source: job.report.url, operation: job.operation, result: r)
            if items[i].copyResultToClipboard, let out = r.output { Clipboard.put(out) }
        }
        if job.state.isTerminal && !wasTerminal { finishedFeedback() }
        updateDockBadge()
    }

    private func finishedFeedback() {
        guard activeCount == 0 else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        startTime = nil
        updateDockBadge()
    }

    private func updateDockBadge() {
        let n = activeCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: Derived state

    func index(_ id: Item.ID) -> Int? { items.firstIndex { $0.id == id } }
    func item(_ id: Item.ID?) -> Item? { id.flatMap { id in items.first { $0.id == id } } }

    var activeCount: Int {
        items.count { item in
            switch item.state {
            case .queued, .running, .paused, .analyzing: true
            default: false
            }
        }
    }

    var finishedCount: Int { items.count { $0.isFinished } }

    var totals: (input: Int64, output: Int64) {
        items.reduce((Int64(0), Int64(0))) { acc, item in
            guard let r = item.result, r.outcome == .written, item.batch == nil, item.operation?.measuresSavings ?? true else { return acc }
            return (acc.0 + r.inputBytes, acc.1 + r.producedBytes)
        }
    }

    func progress(of ids: [Item.ID]) -> GroupProgress {
        var g = GroupProgress(fraction: 0, finished: 0, failed: 0, total: ids.count, inputBytes: 0, outputBytes: 0)
        var sum = 0.0
        for id in ids {
            guard let item = item(id) else { g.finished += 1; sum += 1; continue }
            switch item.state {
            case .running(let p): sum += p
            case .done(let r):
                g.finished += 1; sum += 1
                if r.outcome == .written { g.inputBytes += r.inputBytes; g.outputBytes += r.producedBytes }
            case .failed, .cancelled: g.finished += 1; g.failed += 1; sum += 1
            default: break
            }
        }
        g.fraction = ids.isEmpty ? 1 : sum / Double(ids.count)
        return g
    }

    /// Remaining time from measured throughput of this batch. Nil until there is data.
    var estimatedRemaining: TimeInterval? {
        guard let start = startTime else { return nil }
        let done = items.compactMap(\.result)
        guard !done.isEmpty else { return nil }
        let doneBytes = done.reduce(Int64(0)) { $0 + $1.inputBytes }
        let elapsed = Date().timeIntervalSince(start)
        guard doneBytes > 0, elapsed > 0.5 else { return nil }
        let pendingBytes = items.reduce(Int64(0)) { acc, item in
            let size = item.report?.byteSize ?? 0
            switch item.state {
            case .running(let p): return acc + Int64(Double(size) * (1 - p))
            case .queued, .paused: return acc + size
            default: return acc
            }
        }
        return Double(pendingBytes) / (Double(doneBytes) / elapsed)
    }

    func targets(for item: Item) -> [FormatID] {
        guard let report = item.report, let processor else { return [] }
        return processor.targets(for: report)
    }

    func canPerform(_ op: FileOperation, on item: Item) -> Bool {
        guard let r = item.report, let processor else { return false }
        return processor.canPerform(op, on: r)
    }

    var selectedURLs: [URL] { items.filter { selection.contains($0.id) && $0.batch == nil }.map(\.url) }
    var selectedImageURLs: [URL] {
        items.filter { selection.contains($0.id) && $0.batch == nil && ($0.report?.format).map { $0.category == .image && $0 != .svg } == true }.map(\.url)
    }

    func canOptimize(_ item: Item) -> Bool {
        guard let f = item.report?.format else { return false }
        return processor?.registry.optimizableFormats.contains(f) ?? false
    }
}

/// Puts a result back on the general pasteboard: the file, plus its pixels for images.
enum Clipboard {
    @MainActor static func put(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = [url as NSURL]
        if FormatID.fromExtension(url.pathExtension)?.category == .image, let image = NSImage(contentsOf: url) { objects.append(image) }
        pb.writeObjects(objects)
    }

    /// Files (or a picture) currently on the clipboard, as local files.
    @MainActor static func files() -> [URL] {
        let pb = NSPasteboard.general
        let urls = DropReader.immediateFiles(pb)
        if !urls.isEmpty { return urls }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            if let data = pb.data(forType: type) {
                let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Dropster/clipboard", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = OutputPlanner.unique("Clipboard Image.\(ext)", in: dir)
                if (try? data.write(to: url)) != nil { return [url] }
            }
        }
        return []
    }
}
