import Foundation
import Observation
import DropsterCore

/// Watches the folders in `WatchStore` and runs each rule's action on files that arrive.
///
/// Each folder gets a kernel vnode source (no polling while nothing happens). A change
/// triggers a scan; while files are still settling, scans repeat every half second until
/// the files stop growing.
@MainActor @Observable
final class WatchFolderService {
    private(set) var rules: [WatchRule] = []
    /// Files handed to the queue per rule since launch, for the settings list.
    private(set) var processedCount: [UUID: Int] = [:]
    private(set) var problems: [UUID: String] = [:]

    @ObservationIgnored private let store = WatchStore()
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var sources: [UUID: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var trackers: [UUID: ArrivalTracker] = [:]
    @ObservationIgnored private var rescans: [UUID: Task<Void, Never>] = [:]

    static let shared = WatchFolderService()

    func attach(_ model: AppModel) {
        self.model = model
        rules = store.all
        restart()
    }

    // MARK: Editing

    /// Adds a folder. Files already in it are left alone; only new arrivals are processed.
    func add(folder: URL, operation: FileOperation, presetID: UUID? = nil) {
        let names = Set(Self.scan(folder).map(\.name))
        let rule = WatchRule(folder: folder, operation: operation, presetID: presetID, known: names)
        store.save(rule)
        rules = store.all
        restart()
    }

    func update(_ rule: WatchRule) {
        store.save(rule)
        rules = store.all
        restart()
    }

    func remove(_ id: UUID) {
        store.delete(id)
        rules = store.all
        restart()
    }

    // MARK: Watching

    private func restart() {
        for s in sources.values { s.cancel() }
        sources = [:]
        for t in rescans.values { t.cancel() }
        rescans = [:]
        problems = [:]
        for rule in rules where rule.enabled {
            if trackers[rule.id] == nil { trackers[rule.id] = ArrivalTracker(known: rule.known) }
            let fd = open(rule.folder.path, O_EVTONLY)
            guard fd >= 0 else { problems[rule.id] = "The folder can’t be opened. It may have been moved or deleted."; continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            let id = rule.id
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleScan(id) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[id] = source
            // Catch files that arrived while Dropster was not running.
            scheduleScan(id)
        }
        trackers = trackers.filter { id, _ in rules.contains { $0.id == id && $0.enabled } }
    }

    private func scheduleScan(_ id: UUID) {
        guard rescans[id] == nil else { return }
        rescans[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let more = self.scan(id), more else { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // A cancelled scan was already replaced by restart(); don't clear its successor.
            if !Task.isCancelled { self?.rescans[id] = nil }
        }
    }

    /// Scans once; returns whether files are still settling (so another scan should follow).
    private func scan(_ id: UUID) -> Bool? {
        guard var rule = rules.first(where: { $0.id == id }), var tracker = trackers[id] else { return nil }
        let ready = tracker.scan(Self.scan(rule.folder), at: Date())
        trackers[id] = tracker
        if tracker.known != rule.known {
            rule.known = tracker.known
            store.save(rule)
            if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].known = tracker.known }
        }
        if !ready.isEmpty { run(rule, on: ready.map { rule.folder.appendingPathComponent($0) }) }
        return tracker.hasPending
    }

    private func run(_ rule: WatchRule, on files: [URL]) {
        guard let model else { return }
        let out = rule.outputFolder
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            problems[rule.id] = "Can’t create “\(rule.outputSubfolder)”: \(error.localizedDescription)"
            return
        }
        let preset = rule.presetID.flatMap { id in model.presets.all.first { $0.id == id } }
        var options = preset?.options ?? model.preferences.options
        options.output = .folder(out)
        let action = Preset(name: "Watch", category: files.first.flatMap { FormatID.fromExtension($0.pathExtension)?.category } ?? .other,
                            operation: preset?.operation ?? rule.operation, options: options)
        model.runFromWatchFolder(action, on: files)
        processedCount[rule.id, default: 0] += files.count
    }

    nonisolated static func scan(_ folder: URL) -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return ScannedFile(name: u.lastPathComponent, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
    }

    /// Actions a watch folder can run, independent of file type; files a rule can’t handle are skipped.
    static let actions: [FileOperation] = [.optimize, .stripMetadata]
        + [FormatID.webp, .avif, .jpeg, .heic, .png, .pdf, .mp4, .mp3, .m4a].map { .convert($0) }
        + SizeTarget.common.map { .fitSize($0) }
        + [.unpack]
}
