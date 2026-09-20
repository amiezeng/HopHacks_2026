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
    /// This layer's own key in `ArtRaster`'s cache. Layers are built once, as statics, so a serial
    /// number is stable for as long as the app runs — and can't collide the way the Illustrator names
    /// do (both artboards have a "Layer 2").
    let id: Int
    /// Path elements across all the fills; `ArtRaster` uses it to tell a flat rectangle, which is
    /// cheaper to just fill, from artwork worth holding as an image.
    let elements: Int

    init(name: String, fills: [ArtFill]) {
        self.name = name
        self.fills = fills
        // `.null` (what an empty path unions to) has an infinite origin, which makes `Artboard`'s
        // layout maths NaN, so an empty layer gets an empty rect at the origin instead.
        let union = fills.reduce(CGRect.null) { $0.union($1.path.boundingRect) }
        bounds = union.isNull || union.isInfinite ? .zero : union
        id = ArtLayerIDs.shared.take()
        var count = 0
        for fill in fills {
            fill.path.forEach { _ in count += 1 }
        }
        elements = count
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
        RasterizedLayer(layer: self)
            .artFrame(bounds)
    }
}

/// Hands out `ArtLayer.id`. Layers are built lazily, and from more than one thread (`Preloader` warms
/// them off the main one), so the counter is locked.
private final class ArtLayerIDs {
    static let shared = ArtLayerIDs()

    private let lock = NSLock()
    private var last = 0

    func take() -> Int {
        lock.lock()
        defer { lock.unlock() }
        last += 1
        return last
    }
}

/// Draws a layer as its cached image (see `ArtRaster`) and its paths until that image exists. The
/// render runs off the main thread, so the first sight of a layer that wasn't warmed at launch costs a
/// frame of paths rather than a stall.
private struct RasterizedLayer: View {
    let layer: ArtLayer

    @Environment(\.displayScale) private var displayScale
    @Environment(\.artOversample) private var oversample
    @State private var image: CGImage?

    /// The image wanted here: a new size or scale needs its own render.
    private struct Ask: Equatable {
        let size: CGSize
        let scale: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            let ask = Ask(size: geo.size, scale: displayScale * oversample)
            content(ask)
                .task(id: ask) {
                    let made = await Task.detached(priority: .userInitiated) {
                        ArtRaster.image(of: layer, size: ask.size, scale: ask.scale)
                    }.value
                    guard !Task.isCancelled else { return }
                    image = made
                }
        }
    }

    @ViewBuilder private func content(_ ask: Ask) -> some View {
        if let image {
            Image(decorative: image, scale: ask.scale)
                .resizable()
        } else {
            ZStack {
                ForEach(layer.fills.indices, id: \.self) { i in
                    ArtShape(path: layer.fills[i].path, frame: layer.bounds)
                        .fill(layer.fills[i].color, style: FillStyle(eoFill: layer.fills[i].evenOdd))
                }
            }
        }
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

    /// For a view that fills the artboard (a nested `Artboard` tagged `.artFrame(artboard)`): shifts it
    /// down by `fraction` of the artboard's height, whatever that comes to on this screen, so a shift
    /// can be written in artboard terms. A change to `fraction` animates with `animation`.
    func artboardShift(_ fraction: CGFloat, animation: Animation? = nil) -> some View {
        GeometryReader { geo in
            self
                .offset(y: geo.size.height * fraction)
                .animation(animation, value: fraction)
        }
    }
}

/// Lays out `ArtLayer`s (and views tagged with `.artFrame`) at their artboard positions, with the
/// `rect` region of the artboard scaled to fill the space (centered, like `scaledToFill`, not clipped).
/// Untagged subviews get the whole `rect`. Nest one inside a view placed at a sub-rect to group layers,
/// e.g. as a button label.
struct Artboard: Layout {
    var rect: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // `replacingUnspecifiedDimensions` only fills in nil, so an infinite proposal would pass
        // straight through and we'd be placed at an infinite size — `placeSubviews` then works out
        // `inf - inf` origins. Fall back to the artboard's own size for any dimension that isn't real.
        let size = proposal.replacingUnspecifiedDimensions(by: rect.size)
        return CGSize(width: size.width.isFinite ? size.width : rect.width,
                      height: size.height.isFinite ? size.height : rect.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let scale = max(bounds.width / rect.width, bounds.height / rect.height)
        let origin = CGPoint(x: bounds.midX - rect.midX * scale, y: bounds.midY - rect.midY * scale)
        // An empty `rect` divides by zero and an infinite `bounds` makes `origin` NaN; SwiftUI traps
        // on either ("view origin is invalid"), so lay out over the plain bounds instead of crashing.
        guard scale.isFinite, origin.x.isFinite, origin.y.isFinite else {
            let fallback = CGRect(x: bounds.minX.isFinite ? bounds.minX : 0,
                                  y: bounds.minY.isFinite ? bounds.minY : 0,
                                  width: bounds.width.isFinite ? bounds.width : rect.width,
                                  height: bounds.height.isFinite ? bounds.height : rect.height)
            for subview in subviews {
                subview.place(at: fallback.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(fallback.size))
            }
            return
        }
        for subview in subviews {
            // A layer with no fills has `.null` bounds (infinite origin); give it the whole artboard.
            let tagged = subview[ArtFrameKey.self] ?? rect
            let frame = tagged.isNull || tagged.isInfinite ? rect : tagged
            subview.place(
                at: CGPoint(x: origin.x + frame.minX * scale, y: origin.y + frame.minY * scale),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width * scale, height: frame.height * scale)
            )
        }
    }
}
