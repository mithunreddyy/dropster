import Foundation

/// Private scratch space for intermediate files.
///
/// Lives under the user's Caches directory with mode 0700 instead of the shared
/// `/tmp`, and every job gets its own subdirectory that is removed when the job ends.
public struct Workspace: Sendable {
    public let root: URL

    public init(root: URL? = nil) throws {
        let base = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dropster", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        self.root = base
    }

    public func makeJobDirectory() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    public func remove(_ dir: URL) {
        guard dir.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes job directories left behind by a crash. Called at launch.
    public func purgeStale(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: item) }
        }
    }
}

/// Chooses where outputs go and commits them without ever touching the original.
public enum OutputPlanner {
    /// Default names: `photo-min.jpg` (optimize), `photo.webp` (convert), `photo-clean.jpg`,
    /// `photo-edited.jpg`, `report pages/` (folders). A custom template may use
    /// {name} {ext} {action} {date} and {n}. Collisions get ` 2`, ` 3`, … like Finder.
    public static func destination(for source: URL, target: FormatID, operation: FileOperation,
                                   location: OutputLocation, reserved: Set<String> = [], template: String? = nil) throws -> URL {
        let dir: URL
        switch location {
        case .nextToOriginal: dir = source.deletingLastPathComponent()
        case .folder(let f): dir = f
        }
        var base = source.deletingPathExtension().lastPathComponent
        // "photos.tar.gz" unpacks into "photos", not "photos.tar".
        if operation == .unpack, base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let sourceExt = source.pathExtension
        let defaultTemplate: String = switch operation {
        case .optimize: "{name}-min"
        case .stripMetadata: "{name}-clean"
        case .edit: "{name}-edited"
        case .convert(let f) where f == FormatID.fromExtension(sourceExt): "{name}-converted"
        case .convert: "{name}"
        case .exportPages: target.category == .image && FormatID.fromExtension(sourceExt)?.category == .video ? "{name} frames" : "{name} pages"
        case .splitPDF: "{name} pages"
        case .longImage: "{name}-long"
        case .extractPages: "{name}-extract"
        case .fitSize(let b): "{name}-" + SizeTarget.label(b).replacingOccurrences(of: " ", with: "")
        case .unpack: "{name}"
        }
        let actionToken: String = switch operation {
        case .optimize: "min"
        case .stripMetadata: "clean"
        case .convert(let f): f.preferredExtension
        default: "edited"
        }
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        func render(_ n: Int?) -> String {
            var t = template?.isEmpty == false ? template! : defaultTemplate
            if !t.contains("{n}"), let n { t += " \(n)" }
            t = t.replacingOccurrences(of: "{name}", with: base)
                .replacingOccurrences(of: "{ext}", with: sourceExt)
                .replacingOccurrences(of: "{action}", with: actionToken)
                .replacingOccurrences(of: "{date}", with: date)
                .replacingOccurrences(of: "{n}", with: n.map(String.init) ?? "1")
            return sanitize(t)
        }
        let ext: String
        var archiveSuffix = false
        if operation.producesFolder {
            ext = ""
        } else if [.gzip, .zstd, .xz, .brotli].contains(target), case .convert = operation, template == nil {
            ext = sourceExt.isEmpty ? target.preferredExtension : sourceExt + "." + target.preferredExtension
            archiveSuffix = true
        } else {
            ext = target.preferredExtension
        }
        func url(_ n: Int?) -> URL {
            let stem = archiveSuffix ? (n.map { "\(sanitize(base)) \($0)" } ?? sanitize(base)) : render(n)
            return ext.isEmpty ? dir.appendingPathComponent(stem, isDirectory: true) : dir.appendingPathComponent(stem).appendingPathExtension(ext)
        }
        var candidate = url(nil)
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) || candidate.path == source.path {
            candidate = url(n)
            n += 1
        }
        // The name is sanitised, so the output must sit directly inside `dir`. (Compare raw paths:
        // standardizing resolves symlinks like /private/tmp only for paths that already exist.)
        let name = candidate.lastPathComponent
        guard candidate.deletingLastPathComponent().path == dir.path, !name.contains("/"), name != "..", !name.hasPrefix(".") else {
            throw DropsterError.unsafePath(candidate.path)
        }
        return candidate
    }

    /// `name.ext` in `dir`, or `name 2.ext`, `name 3.ext`… if taken.
    public static func unique(_ fileName: String, in dir: URL) -> URL {
        let clean = sanitize(fileName)
        let ext = (clean as NSString).pathExtension, stem = (clean as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(clean)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Strips path separators and control characters so a crafted name cannot escape the folder.
    public static func sanitize(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":" }
        var s = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "file" : String(s.prefix(200))
    }

    /// Moves a finished temp file into place atomically. Fails rather than overwrite.
    public static func commit(_ temp: URL, to destination: URL, preservingDatesOf source: URL?, quarantineFrom: URL? = nil) throws {
        let fm = FileManager.default
        if let source, let attrs = try? fm.attributesOfItem(atPath: source.path) {
            var copy: [FileAttributeKey: Any] = [:]
            if let m = attrs[.modificationDate] { copy[.modificationDate] = m }
            if let c = attrs[.creationDate] { copy[.creationDate] = c }
            try? fm.setAttributes(copy, ofItemAtPath: temp.path)
        }
        try fm.moveItem(at: temp, to: destination) // moveItem refuses to overwrite.
        // Carry the quarantine flag so downloaded files stay flagged after conversion.
        if let q = quarantineFrom ?? source { copyQuarantine(from: q, to: destination) }
    }

    public static func copyQuarantine(from src: URL, to dst: URL) {
        let name = "com.apple.quarantine"
        let len = getxattr(src.path, name, nil, 0, 0, 0)
        guard len > 0 else { return }
        var buf = [UInt8](repeating: 0, count: len)
        guard getxattr(src.path, name, &buf, len, 0, 0) == len else { return }
        setxattr(dst.path, name, buf, len, 0, 0)
    }
}
