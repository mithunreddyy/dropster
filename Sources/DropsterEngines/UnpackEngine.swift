import Foundation
import DropsterCore

/// One entry of an archive listing, read without extracting anything.
public struct ArchiveEntry: Sendable, Hashable {
    public var path: String
    public var size: Int64
    public var isDirectory: Bool
    public var isLink: Bool
}

/// Safe archive extraction with libarchive (`bsdtar`) and the stream decompressors.
///
/// Defences, in order:
/// 1. The listing is read first; absolute paths, `..` components and control characters
///    reject the whole archive before a byte is written.
/// 2. Declared sizes and entry counts must stay under limits derived from the archive size
///    and the free disk space.
/// 3. While extracting, the output is measured continuously and the extractor is stopped
///    if it grows past the limit (headers can lie about sizes).
/// 4. Afterwards, links that point outside the folder and special files are removed, and
///    downloaded archives pass their quarantine flag on to every extracted file.
public struct UnpackEngine: Engine {
    public let id = "unpack"
    public let maxConcurrency = 2
    public let edges: [ConversionEdge] = []
    public let optimizable: Set<FormatID> = []
    let bsdtar: URL?
    let streams: [FormatID: URL]
    /// Tests use a small ceiling to exercise the expansion guard without gigabytes of data.
    let limitOverride: Int64?

    public static let maxEntries = 200_000
    /// Unpacked size may be at most this multiple of the archive size (with a 4 GB floor).
    public static let maxExpansion: Int64 = 1000

    public init(limitOverride: Int64? = nil) {
        self.limitOverride = limitOverride
        bsdtar = ToolLocator.find("bsdtar") ?? ToolLocator.find("tar")
        var s: [FormatID: URL] = [:]
        for (f, tool) in [(FormatID.gzip, "gzip"), (.xz, "xz"), (.zstd, "zstd"), (.brotli, "brotli")] {
            if let u = ToolLocator.find(tool) { s[f] = u }
        }
        streams = s
    }

    public func supports(_ operation: FileOperation, source: FormatID) -> Bool {
        guard operation == .unpack else { return false }
        if [.zip, .sevenZip, .tar].contains(source) { return bsdtar != nil }
        return streams[source] != nil
    }

    // MARK: Listing

    /// Lists an archive's entries without extracting. Single-stream files (.gz, .xz…) that do
    /// not contain a tar report one entry.
    public func list(_ url: URL, format: FormatID) async throws -> [ArchiveEntry] {
        guard let bsdtar else { throw DropsterError.unsupported("archive listing") }
        if [.gzip, .xz, .zstd, .brotli].contains(format) {
            // libarchive reads compressed tars directly; a failure means a plain compressed file.
            if let entries = try? await listTar(bsdtar, url), !entries.isEmpty { return entries }
            return [ArchiveEntry(path: Self.innerName(of: url), size: -1, isDirectory: false, isLink: false)]
        }
        return try await listTar(bsdtar, url)
    }

    private func listTar(_ tool: URL, _ url: URL) async throws -> [ArchiveEntry] {
        // Names and verbose lines are read separately so names containing spaces stay intact.
        async let namesOut = ProcessRunner.check(tool, ["-tf", url.path])
        async let verboseOut = ProcessRunner.check(tool, ["-tvf", url.path])
        let names = String(decoding: try await namesOut.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let lines = String(decoding: try await verboseOut.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard names.count == lines.count else {
            throw DropsterError.unsafePath("archive entry names contain line breaks")
        }
        return zip(names, lines).map { name, line in
            let cols = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            let type = line.first ?? "-"
            let size = cols.count > 4 ? Int64(cols[4]) ?? 0 : 0
            return ArchiveEntry(path: String(name), size: size, isDirectory: type == "d" || name.hasSuffix("/"),
                                isLink: type == "l" || type == "h")
        }
    }

    /// Why an entry name is unsafe, or nil when it is fine.
    public static func problem(with path: String) -> String? {
        if path.isEmpty { return "an empty name" }
        if path.hasPrefix("/") || path.hasPrefix("~") { return "an absolute path (\(path))" }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "control characters in a name" }
        if path.split(separator: "/").contains("..") { return "a path that leaves the folder (\(path))" }
        return nil
    }

    // MARK: Extraction

    public func run(_ ctx: StepContext) async throws {
        let source = ctx.source.format ?? .any
        let out = ctx.output
        let work = out.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let limit = try limitOverride ?? Self.sizeLimit(archiveBytes: ctx.source.byteSize, workDir: work)

        var archive = ctx.input
        var archiveFormat = source
        if let tool = streams[source] {
            // Decompress the stream first; if it holds a tar, that is unpacked next.
            let inner = work.appendingPathComponent("stream-" + UUID().uuidString)
            try await guarded(limit: limit, measuring: inner) {
                try await ProcessRunner.check(tool, ["-d", "-c", ctx.input.path], stdout: inner)
            }
            ctx.progress(0.5)
            if FileSignature.detect(url: inner) == .tar {
                archive = inner
                archiveFormat = .tar
            } else {
                try FileManager.default.moveItem(at: inner, to: out.appendingPathComponent(OutputPlanner.sanitize(Self.innerName(of: ctx.input))))
                try finish(out, source: ctx.input)
                ctx.progress(1)
                return
            }
        }

        guard let bsdtar else { throw DropsterError.unsupported("\(archiveFormat.displayName) extraction") }
        let entries = try await listTar(bsdtar, archive)
        guard !entries.isEmpty else { throw DropsterError.decodeFailed("the archive is empty") }
        guard entries.count <= Self.maxEntries else { throw DropsterError.resourceLimit("\(entries.count) entries") }
        for e in entries { if let p = Self.problem(with: e.path) { throw DropsterError.unsafePath("archive contains \(p)") } }
        let declared = entries.reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard declared <= limit else {
            throw DropsterError.resourceLimit("unpacks to \(SizeTarget.label(declared)), more than the \(SizeTarget.label(limit)) allowed")
        }
        ctx.progress(archive == ctx.input ? 0.1 : 0.6)

        // bsdtar refuses `..` and absolute paths unless -P is given, and never follows
        // symlinks while extracting; -o and --no-same-permissions drop ownership and setuid bits.
        let args = ["-x", "-f", archive.path, "-C", out.path, "-o", "--no-same-permissions", "--no-fflags", "--no-acls"]
        try await guarded(limit: limit, measuring: out) {
            try await ProcessRunner.check(bsdtar, args)
        }
        try finish(out, source: ctx.input)
        ctx.progress(1)
    }

    /// Runs `body` while measuring `url`; stops it if the output grows past `limit`.
    private func guarded(limit: Int64, measuring url: URL, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await body(); return true }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    if Self.diskUsage(url) > limit {
                        throw DropsterError.resourceLimit("the archive expands past \(SizeTarget.label(limit)); extraction stopped")
                    }
                }
            }
            // The first child to finish decides: extraction done, or the monitor tripped.
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Removes links that resolve outside `root` and anything that is not a file, folder or
    /// link, then passes the archive's quarantine flag to every file.
    func finish(_ root: URL, source: URL) throws {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return }
        var files: [URL] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true {
                let target = url.resolvingSymlinksInPath().path
                if target != rootPath && !target.hasPrefix(rootPath + "/") { try? fm.removeItem(at: url) }
                continue
            }
            if v?.isDirectory == true { continue }
            if v?.isRegularFile != true { try? fm.removeItem(at: url); continue }
            files.append(url)
        }
        for f in files { OutputPlanner.copyQuarantine(from: source, to: f) }
    }

    /// The safe ceiling for unpacked bytes: 1000× the archive (at least 4 GB), and never
    /// more than the free space minus 1 GB.
    static func sizeLimit(archiveBytes: Int64, workDir: URL) throws -> Int64 {
        let ratio = max(4_000_000_000, archiveBytes.multipliedReportingOverflow(by: maxExpansion).partialValue)
        let free = (try? workDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        let room = free - 1_000_000_000
        guard room > 0 else { throw DropsterError.resourceLimit("not enough free disk space") }
        return min(ratio, room)
    }

    static func diskUsage(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: keys)
            return Int64(max(v?.totalFileAllocatedSize ?? 0, v?.fileSize ?? 0))
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        while let f = e?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: keys)
            total += Int64(max(v?.totalFileAllocatedSize ?? 0, v?.fileSize ?? 0))
        }
        return total
    }

    /// "notes.txt.gz" → "notes.txt", "backup.tgz" → "backup.tar", "data.zst" → "data".
    static func innerName(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent
        return ext == "tgz" ? stem + ".tar" : stem
    }
}
