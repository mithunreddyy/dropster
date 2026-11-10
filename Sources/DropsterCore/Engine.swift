import Foundation

/// One directed edge in the conversion graph: an engine can turn `from` into `to`.
public struct ConversionEdge: Sendable, Hashable {
    public var from: FormatID
    public var to: FormatID
    /// Relative cost used by the route planner. Lossy hops cost more so the planner
    /// prefers lossless intermediates when they exist.
    public var cost: Double
    public var engineID: String

    public init(from: FormatID, to: FormatID, cost: Double, engineID: String) {
        self.from = from
        self.to = to
        self.cost = cost
        self.engineID = engineID
    }
}

public struct StepContext: Sendable {
    public var input: URL
    public var output: URL
    public var source: FileReport
    public var target: FormatID
    public var options: ProcessingOptions
    /// `true` when the target equals the source format (re-encode for size).
    public var isOptimization: Bool
    /// False for intermediate hops of a multi-step route, whose output nobody keeps.
    public var isFinalStep: Bool
    /// The user's operation. Engines handling edits, page export etc. read their parameters from it.
    public var operation: FileOperation
    public var progress: @Sendable (Double) -> Void

    public init(input: URL, output: URL, source: FileReport, target: FormatID, options: ProcessingOptions,
                isOptimization: Bool, isFinalStep: Bool = true, operation: FileOperation? = nil,
                progress: @escaping @Sendable (Double) -> Void) {
        self.operation = operation ?? (isOptimization ? .optimize : .convert(target))
        self.input = input
        self.output = output
        self.source = source
        self.target = target
        self.options = options
        self.isOptimization = isOptimization
        self.isFinalStep = isFinalStep
        self.progress = progress
    }
}

public protocol Engine: Sendable {
    var id: String { get }
    /// Edges this engine can execute on this machine right now.
    var edges: [ConversionEdge] { get }
    /// Same-format optimisations this engine supports.
    var optimizable: Set<FormatID> { get }
    /// Engines that drive external processes or GPU encoders limit their own parallelism.
    var maxConcurrency: Int { get }
    func run(_ ctx: StepContext) async throws
    /// Whether this engine performs an operation other than optimize/convert (edits,
    /// page export, splitting) for the given source format.
    func supports(_ operation: FileOperation, source: FormatID) -> Bool
}

public extension Engine {
    func supports(_ operation: FileOperation, source: FormatID) -> Bool { false }
}

public enum DropsterError: Error, LocalizedError, Sendable, Equatable {
    case unsupported(String)
    case noRoute(FormatID, FormatID)
    case decodeFailed(String)
    case encodeFailed(String)
    case toolFailed(tool: String, status: Int32, stderr: String)
    case cancelled
    case unsafePath(String)
    case resourceLimit(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): "Not supported: \(s)"
        case .noRoute(let a, let b): "No way to convert \(a.displayName) to \(b.displayName)."
        case .decodeFailed(let s): "Could not read the file: \(s)"
        case .encodeFailed(let s): "Could not write the result: \(s)"
        case .toolFailed(let tool, let status, let err):
            "\(tool) failed (exit \(status))" + (err.isEmpty ? "" : ": " + err.split(separator: "\n").suffix(2).joined(separator: " "))
        case .cancelled: "Cancelled"
        case .unsafePath(let s): "Refused unsafe path: \(s)"
        case .resourceLimit(let s): "File exceeds safety limits: \(s)"
        case .verificationFailed(let s): "Output failed verification: \(s)"
        }
    }
}
