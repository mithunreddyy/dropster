import Foundation

/// A folder Dropster watches: every new file that lands in it gets `operation`, and results
/// go to a subfolder so they are never picked up again.
public struct WatchRule: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var folder: URL
    public var operation: FileOperation
    /// When set, the preset's settings are used; otherwise the current preferences.
    public var presetID: UUID?
    public var enabled: Bool
    /// Name of the results subfolder inside the watched folder.
    public var outputSubfolder: String
    /// Names already present in the folder, so files that arrived while Dropster was not
    /// running are still noticed at the next launch, and old files never are.
    public var known: Set<String>

    public init(id: UUID = UUID(), folder: URL, operation: FileOperation, presetID: UUID? = nil, enabled: Bool = true,
                outputSubfolder: String = "Dropster", known: Set<String> = []) {
        self.id = id
        self.folder = folder
        self.operation = operation
        self.presetID = presetID
        self.enabled = enabled
        self.outputSubfolder = outputSubfolder
        self.known = known
    }

    public var outputFolder: URL { folder.appendingPathComponent(OutputPlanner.sanitize(outputSubfolder), isDirectory: true) }
}

/// One file seen during a scan.
public struct ScannedFile: Sendable, Hashable {
    public var name: String
    public var size: Int64
    public var modified: Date
    public init(name: String, size: Int64, modified: Date) { self.name = name; self.size = size; self.modified = modified }
}

/// Decides when a new file is complete enough to process.
///
/// Downloads and copies grow over time, so a file is only handed out once two scans at least
/// `settleTime` apart saw the same size and date, and it is not a known partial-download name.
public struct ArrivalTracker: Sendable {
    public var known: Set<String>
    public let settleTime: TimeInterval
    private var pending: [String: (file: ScannedFile, since: Date)] = [:]

    /// Extensions browsers and copy tools use while a file is still being written.
    public static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload", "filepart"]

    public init(known: Set<String>, settleTime: TimeInterval = 1.5) {
        self.known = known
        self.settleTime = settleTime
    }

    public var hasPending: Bool { !pending.isEmpty }

    public static func isCandidate(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !partialExtensions.contains(ext)
    }

    /// Feeds one scan of the folder; returns the names that just became ready.
    public mutating func scan(_ files: [ScannedFile], at now: Date) -> [String] {
        let present = Set(files.map(\.name))
        // Forget files that disappeared, so a re-added file with the same name counts again.
        known.formIntersection(present)
        pending = pending.filter { present.contains($0.key) }
        var ready: [String] = []
        for f in files where Self.isCandidate(f.name) && !known.contains(f.name) {
            if let p = pending[f.name], p.file.size == f.size, p.file.modified == f.modified {
                if now.timeIntervalSince(p.since) >= settleTime && f.size > 0 {
                    pending[f.name] = nil
                    known.insert(f.name)
                    ready.append(f.name)
                }
            } else {
                pending[f.name] = (f, now)
            }
        }
        return ready.sorted()
    }
}

/// Watch rules persisted as JSON in Application Support.
public final class WatchStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var rules: [WatchRule]

    public init(url: URL = WatchStore.defaultURL()) {
        self.url = url
        rules = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([WatchRule].self, from: $0) } ?? []
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dropster/watch.json")
    }

    public var all: [WatchRule] { lock.withLock { rules } }

    public func save(_ rule: WatchRule) {
        lock.withLock {
            if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        }
        persist()
    }

    public func delete(_ id: UUID) {
        lock.withLock { rules.removeAll { $0.id == id } }
        persist()
    }

    private func persist() {
        let snapshot = all
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}
