import Foundation

/// A planned sequence of engine steps from a source format to a target.
public struct Route: Sendable, Hashable {
    public var steps: [ConversionEdge]
    public var cost: Double { steps.reduce(0) { $0 + $1.cost } }
    public var formats: [FormatID] { steps.isEmpty ? [] : [steps[0].from] + steps.map(\.to) }
}

/// Holds every available engine and plans multi-hop conversions with Dijkstra's
/// algorithm over the format graph (bounded to `maxHops`, ties broken by engine order).
/// Multi-hop routes stay within one category, e.g. HEIC → PNG → WebP.
public final class ConversionRegistry: Sendable {
    public let engines: [any Engine]
    public let maxHops: Int
    private let edgesByFormat: [FormatID: [ConversionEdge]]

    public init(engines: [any Engine], maxHops: Int = 3) {
        self.engines = engines
        self.maxHops = maxHops
        var map: [FormatID: [ConversionEdge]] = [:]
        for e in engines { for edge in e.edges { map[edge.from, default: []].append(edge) } }
        edgesByFormat = map
    }

    public func engine(id: String) -> (any Engine)? { engines.first { $0.id == id } }

    public var optimizableFormats: Set<FormatID> { engines.reduce(into: []) { $0.formUnion($1.optimizable) } }

    public func optimizer(for format: FormatID) -> (any Engine)? { engines.first { $0.optimizable.contains(format) } }

    /// First engine that performs a non-conversion operation (edit, page export, split) for `source`.
    public func engine(for operation: FileOperation, source: FormatID) -> (any Engine)? {
        engines.first { $0.supports(operation, source: source) }
    }

    /// Every format reachable from `source` within `maxHops`, with the best route to each.
    public func reachable(from source: FormatID) -> [FormatID: Route] {
        var best: [FormatID: Route] = [:]
        for target in FormatID.allCases where target != source && target != .any {
            if let r = route(from: source, to: target) { best[target] = r }
        }
        return best
    }

    public func targets(for source: FormatID) -> [FormatID] {
        reachable(from: source).keys.sorted { a, b in
            a.category == b.category ? a.displayName < b.displayName : a.category.rawValue < b.category.rawValue
        }
    }

    public func route(from source: FormatID, to target: FormatID) -> Route? {
        guard source != target else { return nil }
        struct State { var cost: Double; var path: [ConversionEdge] }
        var frontier: [State] = [State(cost: 0, path: [])]
        var settled: [FormatID: Double] = [:]
        while !frontier.isEmpty {
            // Formats number in the dozens: a linear-scan priority queue is faster than a heap here.
            let idx = frontier.indices.min { frontier[$0].cost < frontier[$1].cost }!
            let state = frontier.remove(at: idx)
            let node = state.path.last?.to ?? source
            if node == target { return Route(steps: state.path) }
            if let c = settled[node], c <= state.cost { continue }
            settled[node] = state.cost
            guard state.path.count < maxHops else { continue }
            let outgoing = edgesByFormat[node] ?? []
            let wildcard = edgesByFormat[.any] ?? []
            for edge in outgoing + wildcard {
                var e = edge
                if e.from == .any { e.from = node }
                if e.to == source || state.path.contains(where: { $0.from == e.to }) { continue }
                // A hop that changes category (image→video, video→audio, file→archive) must be the
                // entire route: chaining through one produces nonsense like JPEG→GIF→MP4→MP3.
                let crossesCategory = edge.from == .any || e.from.category != e.to.category
                if crossesCategory && (!state.path.isEmpty || e.to != target) { continue }
                frontier.append(State(cost: state.cost + e.cost, path: state.path + [e]))
            }
        }
        return nil
    }
}
