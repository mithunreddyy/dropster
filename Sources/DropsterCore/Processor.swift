import Foundation

public struct ProcessingResult: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Codable {
        /// A new file was written.
        case written
        /// The result was not smaller than the original, so nothing was kept.
        case keptOriginal
    }
    public var outcome: Outcome
    public var output: URL?
    public var inputBytes: Int64
    /// Size of the produced file (even when discarded), for honest reporting.
    public var producedBytes: Int64
    public var duration: TimeInterval
    public var route: [FormatID]

    public init(outcome: Outcome, output: URL?, inputBytes: Int64, producedBytes: Int64, duration: TimeInterval, route: [FormatID]) {
        self.outcome = outcome
        self.output = output
        self.inputBytes = inputBytes
        self.producedBytes = producedBytes
        self.duration = duration
        self.route = route
    }

    /// Positive when the output is smaller.
    public var savedFraction: Double {
        guard inputBytes > 0 else { return 0 }
        return 1 - Double(producedBytes) / Double(inputBytes)
    }
}

/// Validates that a produced file is a real file of the expected type.
public protocol OutputVerifier: Sendable {
    func verify(_ url: URL, expected: FormatID) throws
}

/// Executes a single file operation end to end. Stateless; safe to call concurrently.
public struct Processor: Sendable {
    public let registry: ConversionRegistry
    public let workspace: Workspace
    public let verifier: any OutputVerifier

    public init(registry: ConversionRegistry, workspace: Workspace, verifier: any OutputVerifier) {
        self.registry = registry
        self.workspace = workspace
        self.verifier = verifier
    }

    /// Conversion targets that make sense for this particular file: no audio formats for
    /// a silent video, no video formats for a still image.
    public func targets(for report: FileReport) -> [FormatID] {
        guard let f = report.format else { return registry.targets(for: .any) }
        return registry.targets(for: f).filter { isMeaningful($0, for: report) }
    }

    func isMeaningful(_ target: FormatID, for r: FileReport) -> Bool {
        if let m = r.media {
            if target.category == .audio && m.audioCodec == nil { return false }
            if target.category == .video && !m.hasVideo { return false }
        }
        if r.format?.category == .image && target.category == .video { return r.image?.isAnimated ?? false }
        return true
    }

    public func plan(_ op: FileOperation, for report: FileReport) throws -> [ConversionEdge] {
        guard let format = report.format else {
            if case .convert(let t) = op, let r = registry.route(from: .any, to: t) { return r.steps }
            throw DropsterError.unsupported("unknown file type")
        }
        switch op {
        case .optimize, .stripMetadata:
            guard let e = registry.optimizer(for: format) else {
                throw DropsterError.unsupported("\(op.label) for \(format.displayName)")
            }
            return [ConversionEdge(from: format, to: format, cost: 0, engineID: e.id)]
        case .convert(let target) where target == format:
            // Same-format conversion = re-encode with the chosen presets (size, codec, quality).
            guard let e = registry.optimizer(for: format) else { throw DropsterError.noRoute(format, target) }
            return [ConversionEdge(from: format, to: format, cost: 0, engineID: e.id)]
        case .convert(let target):
            guard isMeaningful(target, for: report) else {
                throw DropsterError.unsupported(target.category == .audio ? "this file has no audio track" : "\(target.displayName) for this file")
            }
            guard let r = registry.route(from: format, to: target) else { throw DropsterError.noRoute(format, target) }
            return r.steps
        default:
            guard let e = registry.engine(for: op, source: format) else {
                throw DropsterError.unsupported("\(op.label) for \(format.displayName)")
            }
            return [ConversionEdge(from: format, to: op.outputFormat(source: format), cost: 0, engineID: e.id)]
        }
    }

    /// Whether `op` can run on this file at all (used to build menus).
    public func canPerform(_ op: FileOperation, on report: FileReport) -> Bool {
        (try? plan(op, for: report)) != nil
    }

    public func process(_ report: FileReport, operation: FileOperation, options: ProcessingOptions,
                        destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ProcessingResult {
        let start = Date()
        let steps = try plan(operation, for: report)
        if case .fitSize(let limit) = operation, report.byteSize <= limit {
            // Already small enough: nothing to do, and re-encoding would only lose quality.
            return ProcessingResult(outcome: .keptOriginal, output: nil, inputBytes: report.byteSize, producedBytes: report.byteSize,
                                    duration: Date().timeIntervalSince(start), route: [])
        }
        let jobDir = try workspace.makeJobDirectory()
        defer { workspace.remove(jobDir) }

        var current = report.url
        var currentReport = report
        let stepCount = Double(steps.count)
        for (i, step) in steps.enumerated() {
            try Task.checkCancellation()
            guard let engine = registry.engine(id: step.engineID) else { throw DropsterError.unsupported(step.engineID) }
            let isLast = i == steps.count - 1
            let out = isLast && operation.producesFolder
                ? jobDir.appendingPathComponent("result", isDirectory: true)
                : jobDir.appendingPathComponent("step\(i).\(step.to.preferredExtension)")
            var stepOptions = options
            if case .stripMetadata = operation { stepOptions.metadata = .removeAll; stepOptions.qualityOverride = stepOptions.qualityOverride ?? 1.0 }
            // Intermediate hops are lossless where the format allows it, so only the last hop decides quality.
            if i < steps.count - 1 { stepOptions.qualityOverride = 1.0 }
            let ctx = StepContext(input: current, output: out, source: currentReport, target: step.to, options: stepOptions,
                                  isOptimization: step.from == step.to && operation == .optimize,
                                  isFinalStep: isLast, operation: operation,
                                  progress: { p in progress((Double(i) + min(max(p, 0), 1)) / stepCount) })
            do {
                try await engine.run(ctx)
            } catch is CancellationError {
                throw DropsterError.cancelled
            }
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: out.path) else {
                throw DropsterError.encodeFailed("\(engine.id) produced no output")
            }
            if isLast && operation.producesFolder {
                let files = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
                guard !files.isEmpty else { throw DropsterError.encodeFailed(operation == .unpack ? "the archive is empty" : "no pages were produced") }
                // Unpacked files can be anything; the extractor's own integrity checks stand in.
                if operation != .unpack { for f in files { try verifier.verify(f, expected: step.to) } }
            } else {
                try verifier.verify(out, expected: step.to)
            }
            current = out
            currentReport = FileReport(url: out, byteSize: fileSize(out), detectedFormat: step.to, extensionFormat: step.to,
                                       image: report.image, media: report.media, pageCount: report.pageCount)
        }

        let produced = fileSize(current)
        let route = steps.isEmpty ? [] : [steps[0].from] + steps.map(\.to)
        let mustShrink: Bool = switch operation {
        case .optimize: true
        case .stripMetadata: false
        case .convert: options.discardLargerConversions
        default: false
        }
        if mustShrink && produced >= report.byteSize {
            return ProcessingResult(outcome: .keptOriginal, output: nil, inputBytes: report.byteSize, producedBytes: produced,
                                    duration: Date().timeIntervalSince(start), route: route)
        }
        if case .fitSize(let limit) = operation, produced > limit {
            throw DropsterError.encodeFailed("the result is \(SizeTarget.label(produced)), over the \(SizeTarget.label(limit)) limit")
        }
        try Task.checkCancellation()
        var destination = destination
        if operation == .unpack {
            // Like Archive Utility: an archive holding one folder or file unpacks to just that item.
            let top = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
            if top.count == 1 {
                current = top[0]
                destination = OutputPlanner.unique(top[0].lastPathComponent, in: destination.deletingLastPathComponent())
            }
        }
        try OutputPlanner.commit(current, to: destination, preservingDatesOf: options.keepFileDates ? report.url : nil,
                                 quarantineFrom: report.url)
        progress(1)
        return ProcessingResult(outcome: .written, output: destination, inputBytes: report.byteSize, producedBytes: produced,
                                duration: Date().timeIntervalSince(start), route: route)
    }

    /// Size of a file, or the total of a folder's files.
    func fileSize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return items.reduce(0) { $0 + fileSize($1) }
    }
}
