import AppKit
import UniformTypeIdentifiers
import DropsterCore

/// Download state for pictures dragged out of a web page.
struct TransferProgress: Sendable, Equatable {
    var received: Int64
    var expected: Int64?
    var bytesPerSecond: Double

    var fraction: Double? { expected.map { $0 > 0 ? Double(received) / Double($0) : 0 } }

    var label: String {
        let speed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        if let e = expected { return "\(speed) · \(got) / \(ByteCountFormatter.string(fromByteCount: e, countStyle: .file))" }
        return "\(speed) · \(got)"
    }
}

/// Turns whatever was dropped into local files: file URLs, file promises (Photos, Mail,
/// Safari), web URLs (downloaded into Downloads) or raw image data.
@MainActor
enum DropReader {
    static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// True when the pasteboard holds something Dropster can turn into files.
    static func canRead(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: pasteboardTypes) != nil
    }

    /// Local file URLs available right now, without downloading anything.
    static func immediateFiles(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    static func files(from pb: NSPasteboard, progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> [URL] {
        let local = immediateFiles(pb)
        if !local.isEmpty { return local }

        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            var urls: [URL] = []
            for p in promises { urls += try await receive(p) }
            if !urls.isEmpty { return urls }
        }
        if let web = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) {
            return [try await Downloader.download(web, progress: progress)]
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"), (.tiff, "tiff")] {
            if let data = pb.data(forType: type) {
                let url = OutputPlanner.unique("Dropped Image.\(ext)", in: downloads)
                try data.write(to: url, options: .withoutOverwriting)
                return [url]
            }
        }
        return []
    }

    private static func receive(_ promise: NSFilePromiseReceiver) async throws -> [URL] {
        let dest = downloads
        let queue = OperationQueue()
        return try await withCheckedThrowingContinuation { cont in
            var urls: [URL] = []
            var remaining = max(1, promise.fileNames.count)
            var finished = false
            promise.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { url, error in
                guard !finished else { return }
                if let error { finished = true; cont.resume(throwing: error); return }
                urls.append(url)
                remaining -= 1
                if remaining == 0 { finished = true; cont.resume(returning: urls) }
            }
        }
    }
}

/// Downloads one web resource into Downloads, reporting speed and progress.
/// Only runs when the user drags something from a web page; Dropster makes no other network requests.
final class Downloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxBytes: Int64 = 2 << 30

    private var file: FileHandle?
    private var temp: URL
    private var received: Int64 = 0
    private var expected: Int64?
    private let start = Date()
    private var lastReport = Date.distantPast
    private var suggestedName = "Download"
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @MainActor (TransferProgress) -> Void

    private init(progress: @escaping @MainActor (TransferProgress) -> Void) {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("dropster-dl-" + UUID().uuidString)
        self.progress = progress
    }

    @MainActor
    static func download(_ url: URL, progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            d.continuation = cont
            session.dataTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(DropsterError.decodeFailed("the server answered \(http.statusCode)")))
            return
        }
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let e = expected, e > Self.maxBytes {
            completionHandler(.cancel)
            finish(.failure(DropsterError.resourceLimit("download larger than 2 GB")))
            return
        }
        var name = response.suggestedFilename ?? "Download"
        if (name as NSString).pathExtension.isEmpty, let mime = response.mimeType, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += "." + ext
        }
        suggestedName = name
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        file = try? FileHandle(forWritingTo: temp)
        completionHandler(file == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        file?.write(data)
        received += Int64(data.count)
        if received > Self.maxBytes {
            dataTask.cancel()
            finish(.failure(DropsterError.resourceLimit("download larger than 2 GB")))
            return
        }
        // Four updates a second.
        if Date().timeIntervalSince(lastReport) >= 0.25 {
            lastReport = Date()
            let p = TransferProgress(received: received, expected: expected, bytesPerSecond: Double(received) / max(0.001, Date().timeIntervalSince(start)))
            let report = progress
            Task { @MainActor in report(p) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        if let error { finish(.failure(error)); return }
        do {
            let dest = OutputPlanner.unique(suggestedName, in: DropReader.downloadsPath)
            try FileManager.default.moveItem(at: temp, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        if case .failure = result { try? FileManager.default.removeItem(at: temp) }
        c.resume(with: result)
    }
}

extension DropReader {
    nonisolated static var downloadsPath: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
