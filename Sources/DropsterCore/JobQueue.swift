import Foundation

public struct JobID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID
    public init() { raw = UUID() }
    public var description: String { raw.uuidString }
}

public enum JobState: Sendable, Hashable {
    case analyzing
    case ready
    case queued
    case running(progress: Double)
    case paused
    case done(ProcessingResult)
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        default: false
        }
    }
    public var isActive: Bool { if case .running = self { true } else { false } }
}

public struct Job: Sendable, Identifiable, Hashable {
    public let id: JobID
    public var report: FileReport
    public var operation: FileOperation
    public var options: ProcessingOptions
    public var state: JobState
    public var destination: URL?

    public init(id: JobID = JobID(), report: FileReport, operation: FileOperation, options: ProcessingOptions, state: JobState = .queued) {
        self.id = id
        self.report = report
        self.operation = operation
        self.options = options
        self.state = state
    }
}

public enum JobEvent: Sendable {
    case updated(Job)
}

/// Runs jobs with bounded parallelism. A failure never stops the rest of the batch.
///
/// Concurrency adapts to the machine: CPU-bound image work uses most performance cores,
/// while engines that already parallelise internally (video encoders) declare a lower
/// `maxConcurrency` and are throttled per engine.
public actor JobQueue {
    private let processor: Processor
    private var jobs: [JobID: Job] = [:]
    private var order: [JobID] = []
    private var tasks: [JobID: Task<Void, Never>] = [:]
    private var running: [String: Int] = [:]
    private var reservedDestinations: Set<String> = []
    private var isPaused = false
    private var continuations: [UUID: AsyncStream<JobEvent>.Continuation] = [:]
    public let maxParallel: Int

    public init(processor: Processor, maxParallel: Int? = nil) {
        self.processor = processor
        self.maxParallel = maxParallel ?? JobQueue.adaptiveParallelism()
    }

    /// Performance cores minus one (to keep the UI responsive), bounded by memory: allow
    /// roughly one job per 2 GB of RAM so large decodes cannot exhaust memory.
    public static func adaptiveParallelism() -> Int {
        let info = ProcessInfo.processInfo
        let cores = max(1, info.activeProcessorCount - 1)
        let memoryBound = max(1, Int(info.physicalMemory / (2 << 30)))
        return max(1, min(cores, memoryBound, 12))
    }

    public func events() -> AsyncStream<JobEvent> {
        let (stream, cont) = AsyncStream<JobEvent>.makeStream(bufferingPolicy: .unbounded)
        let key = UUID()
        continuations[key] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.dropContinuation(key) } }
        return stream
    }

    private func dropContinuation(_ key: UUID) { continuations[key] = nil }

    private func emit(_ id: JobID) {
        guard let job = jobs[id] else { return }
        for c in continuations.values { c.yield(.updated(job)) }
    }

    @discardableResult
    public func enqueue(_ job: Job) -> JobID {
        var j = job
        j.state = .queued
        jobs[j.id] = j
        order.append(j.id)
        emit(j.id)
        schedule()
        return j.id
    }

    public func job(_ id: JobID) -> Job? { jobs[id] }
    public var allJobs: [Job] { order.compactMap { jobs[$0] } }

    public func pause() {
        isPaused = true
        for id in order where jobs[id]?.state == .queued { jobs[id]?.state = .paused; emit(id) }
    }

    public func resume() {
        isPaused = false
        for id in order where jobs[id]?.state == .paused { jobs[id]?.state = .queued; emit(id) }
        schedule()
    }

    public var paused: Bool { isPaused }

    public func cancel(_ id: JobID) {
        if let t = tasks[id] { t.cancel(); return } // the task reports .cancelled itself
        guard let j = jobs[id], !j.state.isTerminal else { return }
        jobs[id]?.state = .cancelled
        emit(id)
    }

    public func cancelAll() { for id in order { cancel(id) } }

    public func retry(_ id: JobID) {
        guard let j = jobs[id] else { return }
        switch j.state {
        case .failed, .cancelled:
            jobs[id]?.state = isPaused ? .paused : .queued
            emit(id)
            schedule()
        default: break
        }
    }

    public func remove(_ id: JobID) {
        cancel(id)
        guard tasks[id] == nil else { return }
        jobs[id] = nil
        order.removeAll { $0 == id }
    }

    /// Suspends until every job has reached a terminal state.
    public func waitUntilIdle() async {
        while order.contains(where: { jobs[$0].map { !$0.state.isTerminal && $0.state != .paused } ?? false }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func engineKey(for job: Job) -> (String, Int) {
        guard let step = try? processor.plan(job.operation, for: job.report).first,
              let engine = processor.registry.engine(id: step.engineID) else { return ("?", maxParallel) }
        return (engine.id, engine.maxConcurrency)
    }

    private func schedule() {
        guard !isPaused else { return }
        var active = tasks.count
        for id in order where active < maxParallel {
            guard var job = jobs[id], job.state == .queued else { continue }
            let (key, limit) = engineKey(for: job)
            if running[key, default: 0] >= limit { continue }
            let target = job.operation.outputFormat(source: job.report.format ?? .any)
            let dest: URL
            do {
                dest = try OutputPlanner.destination(for: job.report.url, target: target, operation: job.operation,
                                                     location: job.options.output, reserved: reservedDestinations,
                                                     template: job.options.nameTemplate)
            } catch {
                jobs[id]?.state = .failed(error.localizedDescription)
                emit(id)
                continue
            }
            reservedDestinations.insert(dest.path)
            job.destination = dest
            job.state = .running(progress: 0)
            jobs[id] = job
            running[key, default: 0] += 1
            active += 1
            emit(id)
            let processor = self.processor
            tasks[id] = Task.detached(priority: .userInitiated) { [weak self] in
                let result: Result<ProcessingResult, Error>
                do {
                    let r = try await processor.process(job.report, operation: job.operation, options: job.options,
                                                        destination: dest) { [weak self] p in
                        Task { await self?.reportProgress(id, p) }
                    }
                    result = .success(r)
                } catch {
                    result = .failure(error)
                }
                await self?.finish(id, engineKey: key, destination: dest, result: result)
            }
        }
    }

    private var lastProgressEmit: [JobID: Double] = [:]

    private func reportProgress(_ id: JobID, _ p: Double) {
        guard case .running = jobs[id]?.state else { return }
        // Throttle UI updates to 1% steps.
        if let last = lastProgressEmit[id], abs(p - last) < 0.01 { return }
        lastProgressEmit[id] = p
        jobs[id]?.state = .running(progress: p)
        emit(id)
    }

    private func finish(_ id: JobID, engineKey: String, destination: URL, result: Result<ProcessingResult, Error>) {
        tasks[id] = nil
        lastProgressEmit[id] = nil
        running[engineKey, default: 1] -= 1
        reservedDestinations.remove(destination.path)
        switch result {
        case .success(let r): jobs[id]?.state = .done(r)
        case .failure(let e):
            if e is CancellationError || (e as? DropsterError) == .cancelled { jobs[id]?.state = .cancelled }
            else { jobs[id]?.state = .failed(e.localizedDescription) }
        }
        emit(id)
        schedule()
    }
}
