import SwiftUI
import DropsterCore

// MARK: - Palette

/// Each quadrant keeps its colour on both faces, so position and colour mean the same
/// thing every time: mint upper-left, sky upper-right, violet lower-right, amber lower-left.
enum CloverPalette {
    static func hue(_ leaf: Int) -> Color {
        switch leaf % 4 {
        case 0: Color(hue: 0.43, saturation: 0.60, brightness: 0.80)   // mint
        case 1: Color(hue: 0.57, saturation: 0.68, brightness: 0.92)   // sky
        case 2: Color(hue: 0.74, saturation: 0.52, brightness: 0.88)   // violet
        default: Color(hue: 0.09, saturation: 0.74, brightness: 0.96)  // amber
        }
    }

    /// A lighter companion for gradients.
    static func glow(_ leaf: Int) -> Color {
        switch leaf % 4 {
        case 0: Color(hue: 0.43, saturation: 0.35, brightness: 0.97)
        case 1: Color(hue: 0.56, saturation: 0.38, brightness: 1.0)
        case 2: Color(hue: 0.74, saturation: 0.30, brightness: 1.0)
        default: Color(hue: 0.11, saturation: 0.42, brightness: 1.0)
        }
    }
}

// MARK: - Shapes

/// A pie wedge from the centre, `span` degrees wide, centred on `angle` (degrees, clockwise from +x, y down).
struct Wedge: Shape {
    var angle: Double
    var span: Double = 90
    var radius: CGFloat

    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        var p = Path()
        p.move(to: c)
        p.addArc(center: c, radius: radius, startAngle: .degrees(angle - span / 2), endAngle: .degrees(angle + span / 2), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// One petal of the dial: the quadrant of an annulus centred on `angle`, with every corner
/// rounded and a constant-width gap to its neighbours.
///
/// Built as the exactly inset quadrant (annulus ∩ quadrant, shifted off both axes), then grown
/// back by the corner radius with a round-joined stroke, so all four corners round evenly.
struct Petal: Shape {
    var angle: Double        // degrees, clockwise from +x, y down
    var inner: CGFloat
    var outer: CGFloat
    var gap: CGFloat = 5
    var corner: CGFloat = 13

    func path(in r: CGRect) -> Path {
        let c = gap / 2 + corner                 // inset of the straight edges from the axes
        let ro = outer - corner, ri = inner + corner
        guard ro > c, ri > c else { return Path() }
        // Lower-right quadrant (angle 45°), then rotate into place.
        let o1 = atan2(c, sqrt(ro * ro - c * c)), o2 = atan2(sqrt(ro * ro - c * c), c)
        let i1 = atan2(c, sqrt(ri * ri - c * c)), i2 = atan2(sqrt(ri * ri - c * c), c)
        var core = Path()
        core.move(to: CGPoint(x: cos(o1) * ro, y: sin(o1) * ro))
        core.addArc(center: .zero, radius: ro, startAngle: .radians(o1), endAngle: .radians(o2), clockwise: false)
        core.addLine(to: CGPoint(x: cos(i2) * ri, y: sin(i2) * ri))
        core.addArc(center: .zero, radius: ri, startAngle: .radians(i2), endAngle: .radians(i1), clockwise: true)
        core.closeSubpath()
        let grown = core.union(core.strokedPath(StrokeStyle(lineWidth: corner * 2, lineJoin: .round)))
        let t = CGAffineTransform(translationX: r.midX, y: r.midY).rotated(by: (angle - 45) * .pi / 180)
        return grown.applying(t)
    }
}

// MARK: - Dial

struct CloverView: View {
    let state: CloverState

    var body: some View {
        let layout = state.layout
        let side = layout.extent * 2
        VStack(spacing: 0) {
            ZStack {
                OrbitTrack(state: state)
                Dial(state: state)
                if let open = state.expandedLeaf, state.leaves.indices.contains(open) {
                    let leaflets = state.leaves[open].leaflets
                    let centers = layout.leafletCenters(leaf: open, count: leaflets.count)
                    ForEach(Array(leaflets.enumerated()), id: \.element.id) { k, leaflet in
                        Bead(leaflet: leaflet, leaf: open, index: k, center: centers[k], origin: layout.leafCenter(open),
                             hovered: state.hovered == .leaflet(leaf: open, index: k))
                    }
                }
            }
            .frame(width: side, height: side)
            .rotation3DEffect(.degrees(state.flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            Text(state.caption)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .frame(height: 36)
                .offset(y: -10)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.12), value: state.caption)
        }
        // Pops open with a quick, slight twist (no blur: it is the expensive part of a first frame).
        .scaleEffect(state.isVisible ? 1 : 0.86)
        .rotationEffect(.degrees(state.isVisible ? 0 : -12))
        .opacity(state.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dropster clover dial")
    }
}

private struct Dial: View {
    let state: CloverState

    var body: some View {
        let l = state.layout
        let disc = l.discRadius
        ZStack {
            // Body: a glass coin with a soft shadow.
            Circle()
                .fill(.regularMaterial)
                .frame(width: (disc + 12) * 2, height: (disc + 12) * 2)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            Bezel(radius: disc + 7)

            // Four rounded petals around the core: the clover, drawn as a circle.
            ForEach(0..<4, id: \.self) { i in
                Segment(state: state, index: i)
            }
            .frame(width: disc * 2, height: disc * 2)

            ForEach(0..<4, id: \.self) { i in SegmentLabel(state: state, index: i) }
            DwellArc(state: state, radius: disc + 7)
            Core(state: state)
        }
    }
}

/// Fine ticks on the rim, longer where the clover's gaps meet it, like a watch bezel.
private struct Bezel: View {
    let radius: CGFloat

    var body: some View {
        ZStack {
            Circle().strokeBorder(.primary.opacity(0.10), lineWidth: 0.75)
                .frame(width: radius * 2 + 10, height: radius * 2 + 10)
            ForEach(0..<64, id: \.self) { k in
                let major = k % 16 == 0
                Capsule()
                    .fill(.primary.opacity(major ? 0.35 : 0.13))
                    .frame(width: major ? 1.6 : 1, height: major ? 7 : 3.5)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(k) * 360 / 64))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct Segment: View {
    let state: CloverState
    let index: Int

    var body: some View {
        let l = state.layout
        let leaf = state.leaves.indices.contains(index) ? state.leaves[index] : nil
        let enabled = leaf?.isEnabled ?? false
        let hovered = state.hovered == .leaf(index)
        let expanded = state.expandedLeaf == index
        let dimmed = state.expandedLeaf != nil && !expanded
        let angle = Double(CloverLayout.leafAngle(index)) * 180 / .pi
        let lift: CGFloat = hovered || expanded ? 5 : 0
        let shape = Petal(angle: angle, inner: l.coreRadius + 5, outer: l.discRadius)
        shape
            .fill(fill(enabled: enabled, active: hovered || expanded))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(hovered ? 0.22 : 0.08), .clear],
                                               startPoint: .top, endPoint: .bottom)))
            .opacity(dimmed ? 0.35 : 1)
            .scaleEffect(hovered ? 1.025 : 1)
            .offset(x: cos(angle * .pi / 180) * lift, y: sin(angle * .pi / 180) * lift)
            .shadow(color: hovered ? CloverPalette.hue(index).opacity(0.45) : .clear, radius: 12)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovered)
            .animation(.easeOut(duration: 0.18), value: dimmed)
    }

    private func fill(enabled: Bool, active: Bool) -> AnyShapeStyle {
        guard enabled else { return AnyShapeStyle(Color.primary.opacity(0.05)) }
        let hue = CloverPalette.hue(index), glow = CloverPalette.glow(index)
        if active {
            return AnyShapeStyle(RadialGradient(colors: [glow, hue], center: .center, startRadius: 30, endRadius: state.layout.discRadius))
        }
        // At rest: a diagonal wash of the petal's colour, brighter towards the rim.
        let angle = Double(CloverLayout.leafAngle(index))
        let outward = UnitPoint(x: 0.5 + cos(angle) * 0.5, y: 0.5 + sin(angle) * 0.5)
        return AnyShapeStyle(LinearGradient(colors: [hue.opacity(0.30), hue.opacity(0.55)], startPoint: .center, endPoint: outward))
    }
}

private struct SegmentLabel: View {
    let state: CloverState
    let index: Int

    var body: some View {
        let leaf = state.leaves.indices.contains(index) ? state.leaves[index] : nil
        let c = state.layout.leafCenter(index)
        let active = state.hovered == .leaf(index) || state.expandedLeaf == index
        if let leaf, !leaf.title.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: leaf.symbol).font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce, value: active)
                Text(leaf.title.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 70)
            .foregroundStyle(active ? Color.white : (leaf.isEnabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.5)))
            .offset(x: c.x, y: c.y)
            .opacity(state.expandedLeaf != nil && state.expandedLeaf != index ? 0.4 : 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(leaf.isEnabled ? leaf.title : "\(leaf.title), unavailable")
        }
    }
}

/// While resting on a segment, its stretch of the bezel fills with colour; when full, the beads fan out.
private struct DwellArc: View {
    let state: CloverState
    let radius: CGFloat

    var body: some View {
        if let i = state.dwellLeaf {
            let start = Double(CloverLayout.leafAngle(i)) * 180 / .pi - 42
            Circle()
                .trim(from: 0, to: 84.0 / 360 * state.dwellProgress)
                .stroke(CloverPalette.hue(i), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(start))
                .frame(width: radius * 2, height: radius * 2)
                .shadow(color: CloverPalette.hue(i).opacity(0.6), radius: 4)
                .allowsHitTesting(false)
        }
    }
}

private struct Core: View {
    let state: CloverState

    var body: some View {
        let r = state.layout.coreRadius
        let hovered = state.hovered == .core
        ZStack {
            Circle()
                .fill(.thickMaterial)
                .overlay(Circle().strokeBorder(.primary.opacity(hovered ? 0.3 : 0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
            // Resting here winds a ring around the core; when it closes, the dial turns over.
            Circle()
                .trim(from: 0, to: state.coreProgress)
                .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            if hovered {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17, weight: .semibold))
                    .transition(.scale.combined(with: .opacity))
            } else if state.face == .back {
                VStack(spacing: 1) {
                    Image(systemName: "wand.and.stars").font(.system(size: 15, weight: .semibold))
                    Text("TOOLS").font(.system(size: 7.5, weight: .bold, design: .rounded)).tracking(0.8).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: -2) {
                    Text("\(state.fileCount)").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(state.fileCount == 1 ? "FILE" : "FILES").font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .tracking(0.8).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: r * 2, height: r * 2)
        .scaleEffect(hovered ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
    }
}

/// The orbit the beads ride on, drawn only while a segment is open.
private struct OrbitTrack: View {
    let state: CloverState

    var body: some View {
        if let open = state.expandedLeaf, state.leaves.indices.contains(open) {
            let l = state.layout
            let n = state.leaves[open].leaflets.count
            let step = Double((2 * l.leafletRadius + l.leafletGap) / l.leafletArc) * 180 / .pi
            let span = step * Double(max(n - 1, 0))
            let mid = Double(CloverLayout.leafAngle(open)) * 180 / .pi
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [1.5, 5]))
                Circle()
                    .trim(from: 0, to: span / 360)
                    .stroke(CloverPalette.hue(open).opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(mid - span / 2))
            }
            .frame(width: l.leafletArc * 2, height: l.leafletArc * 2)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
            .allowsHitTesting(false)
        }
    }
}

private struct Bead: View {
    let leaflet: CloverLeaflet
    let leaf: Int
    let index: Int
    let center: CGPoint
    let origin: CGPoint
    let hovered: Bool
    @State private var appeared = false

    var body: some View {
        let hue = CloverPalette.hue(leaf)
        ZStack {
            Circle()
                .fill(hovered ? AnyShapeStyle(RadialGradient(colors: [CloverPalette.glow(leaf), hue], center: .topLeading, startRadius: 2, endRadius: 46))
                              : AnyShapeStyle(.regularMaterial))
            Circle().strokeBorder(hue.opacity(hovered ? 0 : 0.85), lineWidth: 1.5)
            if let s = leaflet.symbol {
                Image(systemName: s).font(.system(size: 15, weight: .semibold))
            } else {
                Text(leaflet.title)
                    .font(.system(size: leaflet.title.count > 4 ? 8.5 : 10, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 3)
            }
        }
        .foregroundStyle(hovered ? Color.white : Color.primary)
        .frame(width: 46, height: 46)
        .shadow(color: hovered ? hue.opacity(0.6) : .black.opacity(0.18), radius: hovered ? 10 : 4, y: hovered ? 0 : 1.5)
        .scaleEffect(hovered ? 1.16 : (appeared ? 1 : 0.3))
        .offset(x: appeared ? center.x : origin.x, y: appeared ? center.y : origin.y)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.66).delay(Double(index) * 0.022)) { appeared = true }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hovered)
        .accessibilityLabel(leaflet.action.caption(fileCount: 1))
    }
}
