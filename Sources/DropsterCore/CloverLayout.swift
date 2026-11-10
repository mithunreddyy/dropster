import Foundation
import CoreGraphics

/// Geometry of the clover dial: a round core, a disc of four quadrant segments ("leaves")
/// centred on the diagonals, a bezel ring, and, for the segment being rested on, a fan of
/// round beads ("leaflets") on an orbit beyond the bezel.
///
/// Coordinates are relative to the clover's centre, y pointing down (SwiftUI/AppKit-flipped).
/// Kept free of UI code so hit testing is unit-tested.
public struct CloverLayout: Sendable, Equatable {
    public var coreRadius: CGFloat = 32
    /// Outer radius of the segment disc.
    public var discRadius: CGFloat = 104
    /// Distance from the centre to a segment's label.
    public var leafDistance: CGFloat = 70
    /// Segments are hit within this distance of the centre (disc plus bezel).
    public var leafReach: CGFloat = 116
    public var leafletRadius: CGFloat = 23
    /// Orbit radius on which leaflets sit.
    public var leafletArc: CGFloat = 150
    /// Gap between neighbouring leaflets.
    public var leafletGap: CGFloat = 8

    public init() {}

    /// Leaf i (0...3) points to the upper-left, upper-right, lower-right, lower-left.
    public static func leafAngle(_ i: Int) -> CGFloat {
        // Angles in radians, measured clockwise from +x with y down.
        [-3 * .pi / 4, -.pi / 4, .pi / 4, 3 * .pi / 4][i % 4]
    }

    public func leafCenter(_ i: Int) -> CGPoint {
        let a = Self.leafAngle(i)
        return CGPoint(x: cos(a) * leafDistance, y: sin(a) * leafDistance)
    }

    /// Centres of `count` leaflets fanned around leaf `leaf`.
    public func leafletCenters(leaf: Int, count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let step = (2 * leafletRadius + leafletGap) / leafletArc
        let mid = Self.leafAngle(leaf)
        let start = mid - step * CGFloat(count - 1) / 2
        return (0..<count).map { k in
            let a = start + step * CGFloat(k)
            return CGPoint(x: cos(a) * leafletArc, y: sin(a) * leafletArc)
        }
    }

    /// Half-size of a square that contains the fully fanned clover.
    public var extent: CGFloat { leafletArc + leafletRadius + 12 }

    public enum Hit: Equatable, Sendable {
        case core
        case leaf(Int)
        case leaflet(leaf: Int, index: Int)
    }

    /// What lies under `p`. Leaflets of the expanded leaf win over everything else.
    public func hitTest(_ p: CGPoint, expandedLeaf: Int?, leafletCount: Int) -> Hit? {
        if let leaf = expandedLeaf {
            for (k, c) in leafletCenters(leaf: leaf, count: leafletCount).enumerated() {
                if hypot(p.x - c.x, p.y - c.y) <= leafletRadius + 4 { return .leaflet(leaf: leaf, index: k) }
            }
        }
        let d = hypot(p.x, p.y)
        if d <= coreRadius { return .core }
        guard d <= leafReach else { return nil }
        // The four quadrants map to the four diagonal leaves.
        switch (p.x < 0, p.y < 0) {
        case (true, true): return .leaf(0)
        case (false, true): return .leaf(1)
        case (false, false): return .leaf(2)
        case (true, false): return .leaf(3)
        }
    }
}
