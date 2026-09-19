import SwiftUI

/// One filled path of an Illustrator layer, in artboard points (origin top-left, y down).
struct ArtFill {
    let color: Color
    let evenOdd: Bool
    let path: Path
}

/// An Illustrator layer exported by `design/ai_to_swift.py` (see `HomeArt`, `MainArt`).
///
/// Put layers in an `Artboard` and each is laid out at its own bounds, so animation modifiers
/// (`.offset`, `.scaleEffect`, `.rotationEffect`, `.opacity`, …) act on that layer alone and
/// scale/rotate around the layer's own center by default.
///
/// Those bounds win over an `.artFrame` put on the layer, so to place one somewhere else, wrap it:
/// `Artboard(rect: layer.bounds) { layer }.artFrame(someRect)`.
struct ArtLayer: View {
    let name: String
    let fills: [ArtFill]
    /// Union of the fills, in artboard points.
    let bounds: CGRect

    init(name: String, fills: [ArtFill]) {
        self.name = name
        self.fills = fills
        bounds = fills.reduce(CGRect.null) { $0.union($1.path.boundingRect) }
    }

    /// Color of the first fill (handy for single-color layers like backgrounds).
    var color: Color { fills[0].color }

    /// This layer split into its separate shapes, left to right, e.g. the letters of a text layer so
    /// each can be animated on its own. Subpaths whose bounds overlap stay together, so letters keep their holes.
    var pieces: [ArtLayer] {
        fills.flatMap { fill in
            var groups: [Path] = []
            for subpath in fill.path.subpaths {
                let box = subpath.boundingRect
                var merged = Path()
                groups.removeAll { group in
                    guard group.boundingRect.intersects(box) else { return false }
                    merged.addPath(group)
                    return true
                }
                merged.addPath(subpath)
                groups.append(merged)
            }
            return groups.map { ArtFill(color: fill.color, evenOdd: fill.evenOdd, path: $0) }
        }
        .sorted { $0.path.boundingRect.minX < $1.path.boundingRect.minX }
        .enumerated()
        .map { ArtLayer(name: "\(name) \($0.offset + 1)", fills: [$0.element]) }
    }

    var body: some View {
        ZStack {
            ForEach(fills.indices, id: \.self) { i in
                ArtShape(path: fills[i].path, frame: bounds)
                    .fill(fills[i].color, style: FillStyle(eoFill: fills[i].evenOdd))
            }
        }
        .artFrame(bounds)
    }
}

/// `path` (artboard points) scaled so `frame` maps onto the rect it's drawn in.
private struct ArtShape: Shape {
    let path: Path
    let frame: CGRect

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / frame.width
        let sy = rect.height / frame.height
        return path.applying(CGAffineTransform(
            a: sx, b: 0, c: 0, d: sy,
            tx: rect.minX - frame.minX * sx, ty: rect.minY - frame.minY * sy
        ))
    }
}

private extension Path {
    /// Each `move(to:)`-started subpath as its own path.
    var subpaths: [Path] {
        var subpaths: [Path] = []
        forEach { element in
            if case .move = element { subpaths.append(Path()) }
            guard !subpaths.isEmpty else { return }
            switch element {
            case .move(let to): subpaths[subpaths.count - 1].move(to: to)
            case .line(let to): subpaths[subpaths.count - 1].addLine(to: to)
            case .quadCurve(let to, let control): subpaths[subpaths.count - 1].addQuadCurve(to: to, control: control)
            case .curve(let to, let control1, let control2):
                subpaths[subpaths.count - 1].addCurve(to: to, control1: control1, control2: control2)
            case .closeSubpath: subpaths[subpaths.count - 1].closeSubpath()
            }
        }
        return subpaths
    }
}

private struct ArtFrameKey: LayoutValueKey {
    static let defaultValue: CGRect? = nil
}

extension View {
    /// Where an `Artboard` places this view, in artboard points (`ArtLayer`s set their own bounds).
    func artFrame(_ rect: CGRect) -> some View {
        layoutValue(key: ArtFrameKey.self, value: rect)
    }
}

/// Lays out `ArtLayer`s (and views tagged with `.artFrame`) at their artboard positions, with the
/// `rect` region of the artboard scaled to fill the space (centered, like `scaledToFill`, not clipped).
/// Untagged subviews get the whole `rect`. Nest one inside a view placed at a sub-rect to group layers,
/// e.g. as a button label.
struct Artboard: Layout {
    var rect: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: rect.size)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let scale = max(bounds.width / rect.width, bounds.height / rect.height)
        let origin = CGPoint(x: bounds.midX - rect.midX * scale, y: bounds.midY - rect.midY * scale)
        for subview in subviews {
            let frame = subview[ArtFrameKey.self] ?? rect
            subview.place(
                at: CGPoint(x: origin.x + frame.minX * scale, y: origin.y + frame.minY * scale),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width * scale, height: frame.height * scale)
            )
        }
    }
}
