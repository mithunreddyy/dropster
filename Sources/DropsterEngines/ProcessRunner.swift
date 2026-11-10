import Foundation
import DropsterCore

/// Finds command-line tools without depending on the user's shell PATH,
/// which GUI apps launched from Finder do not inherit.
public enum ToolLocator {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    public static func find(_ name: String) -> URL? {
        var dirs = searchPaths
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path { dirs.insert(bundled, at: 0) }
        if let path = ProcessInfo.processInfo.environment["PATH"] { dirs += path.split(separator: ":").map(String.init) }
        for d in dirs {
            let url = URL(fileURLWithPath: d).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Runs a child process with an argument array (never a shell string), streams
/// stdout lines to a handler, and terminates the child when the task is cancelled.
public enum ProcessRunner {
    public struct Output: Sendable { public var status: Int32; public var stdout: Data; public var stderr: String }

    public static func run(_ tool: URL, _ args: [String], stdin: URL? = nil, stdout: URL? = nil, currentDirectory: URL? = nil,
                           environment: [String: String]? = nil,
                           onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = tool
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.arguments = args
        process.environment = environment ?? ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let errPipe = Pipe()
        process.standardError = errPipe
        let outPipe = Pipe()
        let outHandle: FileHandle?
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
            outHandle = try FileHandle(forWritingTo: stdout)
            process.standardOutput = outHandle
        } else {
            outHandle = nil
            process.standardOutput = outPipe
        }
        if let stdin { process.standardInput = try FileHandle(forReadingFrom: stdin) } else { process.standardInput = FileHandle.nullDevice }

        let collector = Collector()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collector.appendErr(d) }
        }
        if stdout == nil {
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                for line in collector.appendOut(d) { onLine?(line) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? errPipe.fileHandleForReading.readToEnd() { collector.appendErr(rest) }
                    if stdout == nil, let rest = try? outPipe.fileHandleForReading.readToEnd() {
                        for line in collector.appendOut(rest) { onLine?(line) }
                    }
                    try? outHandle?.close()
                    if p.terminationReason == .uncaughtSignal && collector.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: Output(status: p.terminationStatus, stdout: collector.out, stderr: collector.errString))
                    }
                }
                do {
                    try process.run()
                    collector.process = process
                    if Task.isCancelled { collector.cancel() }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            collector.cancel()
        }
    }

    /// Runs and throws `toolFailed` on a non-zero exit.
    @discardableResult
    public static func check(_ tool: URL, _ args: [String], stdin: URL? = nil, stdout: URL? = nil, currentDirectory: URL? = nil,
                             onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let o = try await run(tool, args, stdin: stdin, stdout: stdout, currentDirectory: currentDirectory, onLine: onLine)
        guard o.status == 0 else {
            throw DropsterError.toolFailed(tool: tool.lastPathComponent, status: o.status, stderr: String(o.stderr.suffix(600)))
        }
        return o
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _out = Data()
        private var _err = Data()
        private var pending = Data()
        private var _cancelled = false
        private var _process: Process?

        var process: Process? {
            get { lock.withLock { _process } }
            set { lock.withLock { _process = newValue } }
        }
        var cancelled: Bool { lock.withLock { _cancelled } }
        var out: Data { lock.withLock { _out } }
        var errString: String { lock.withLock { String(decoding: _err.suffix(64 * 1024), as: UTF8.self) } }

        func appendErr(_ d: Data) { lock.withLock { _err.append(d); if _err.count > 256 * 1024 { _err = _err.suffix(64 * 1024) } } }

        func appendOut(_ d: Data) -> [String] {
            lock.withLock {
                if _out.count < 8 * 1024 * 1024 { _out.append(d) }
                pending.append(d)
                var lines: [String] = []
                while let nl = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                    pending = Data(pending[pending.index(after: nl)...])
                }
                return lines
            }
        }

        func cancel() {
            let p: Process? = lock.withLock { _cancelled = true; return _process }
            if let p, p.isRunning { p.terminate() }
        }
    }
}
