import SwiftUI

/// The way the hand has to move, as the guidance is steering it. `nil` is "lined up on this axis".
///
/// Each case is an edge of the screen: the water comes in from the side you are being sent toward,
/// with forward at the top and back at the bottom.
enum GuidanceDirection {
    case left, right, forward, back
}

/// The on-screen half of the guidance cue, written by `DistanceBeepController` and read only by
/// `GuidanceRipple`.
///
/// `@Observable` and held as `@State` rather than `@Published` on the controller: a published change
/// invalidates *every* view observing the object, and this moves ~10 times a second while the camera
/// screen is up — as `@Published` it would rebuild the whole of `ContentView`, camera overlay and all,
/// at that rate. Here only the ripple re-evaluates.
@Observable
final class GuidanceCue {
    var direction: GuidanceDirection?
    /// 0 as far off as the axis measures, 1 lined up. Brightness only.
    var intensity: Double = 0
}

/// Water washing in over the camera feed from the side the hand has to move toward: left, right,
/// forward at the top of the screen, back at the bottom.
///
/// Each wave is a sheet of the MainScreen blue rising in from its edge behind an undulating crest with
/// a white foam line on it — the same water `WaterPour` pours on the way into that screen, which is
/// where the colour comes from rather than a literal of its own. It carries nothing the guidance tone
/// doesn't already say; it exists so a sighted helper, or anyone watching a demo, can see what the
/// person wearing the headphones is hearing.
struct GuidanceRipple: View {
    var cue: GuidanceCue

    /// How far in from its edge a wave reaches: the sides measure across the width, the top and bottom
    /// down the height. Keyed to the short side alone they travelled the same *distance* as the side
    /// waves, which on a tall phone is a sliver next to one running the screen's whole length — so
    /// forward and back get their own, deeper reach.
    private let sideReach: CGFloat = 0.42
    private let endReach: CGFloat = 0.34
    /// Forward and back also cross the screen the narrow way, so they show less of themselves than a
    /// wave running the full height does. This evens the four directions up.
    private let endBoost = 1.35
    /// Fixed, deliberately. The *tone's* ripple quickens as the error closes, but a period that
    /// changes while a wave is in flight jumps its phase, and a rate twitching at 10 Hz on screen is
    /// exactly the restlessness this is meant to stay out of the way of. Closeness is brightness here.
    private let period = 1.7
    private let waves = 3
    /// Points between crests along the edge, and how far the crest swings either way.
    private let wavelength: CGFloat = 190
    private let swell: CGFloat = 14
    /// The MainScreen blue, taken from the layer itself so it can't drift from the previous page.
    private let water = MainArt.background.color

    @State private var start = Date()

    var body: some View {
        let direction = cue.direction
        // No cue, no frames: an empty `Canvas` is cheap to draw but not free to commit, and this sits
        // over a camera feed that wants the main thread.
        TimelineView(.animation(paused: direction == nil)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let peak = 0.20 + 0.22 * cue.intensity
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                guard let direction else { return }
                for wave in 0..<waves {
                    // Staggered, so one is always on its way in.
                    let p = (t / period + Double(wave) / Double(waves))
                        .truncatingRemainder(dividingBy: 1)
                    // Washes in and recedes over the travel, so nothing appears out of nowhere at the
                    // edge or stops dead halfway across.
                    draw(context, size: size, edge: direction, at: p, alpha: sin(p * .pi) * peak, t: t)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { start = .now }
    }

    private func draw(
        _ context: GraphicsContext,
        size: CGSize,
        edge: GuidanceDirection,
        at p: Double,
        alpha: Double,
        t: TimeInterval
    ) {
        let fromSide = edge == .left || edge == .right
        let travel = fromSide ? size.width * sideReach : size.height * endReach
        let depth = travel * p
        let span = fromSide ? size.height : size.width
        let crests = Double(span / wavelength)
        let alpha = fromSide ? alpha : alpha * endBoost

        // Sampled, then smoothed through the midpoints the way `WaterPour` draws its surface: a dozen
        // and a half samples carry a curve that would need far more to look this smooth as segments.
        let samples = 18
        var points: [CGPoint] = []
        points.reserveCapacity(samples + 1)
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples)
            // The crest rides along the edge as the wave comes in, so it undulates rather than
            // holding one frozen shape all the way across.
            let ripple = sin(Double(u) * crests * 2 * .pi + t * 1.1 + p * 2)
            points.append(point(u, depth + CGFloat(ripple) * swell, edge: edge, size: size))
        }

        var crest = Path()
        crest.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2,
                              y: (points[i - 1].y + points[i].y) / 2)
            crest.addQuadCurve(to: mid, control: points[i - 1])
        }
        crest.addLine(to: points[points.count - 1])

        // The sheet behind the crest, closed off along the edge it came in from.
        var sheet = crest
        sheet.addLine(to: point(1, 0, edge: edge, size: size))
        sheet.addLine(to: point(0, 0, edge: edge, size: size))
        sheet.closeSubpath()

        // Thickest just behind the crest and thinning back toward the edge: a wave front, not a slab
        // of blue sitting over the camera.
        context.fill(
            sheet,
            with: .linearGradient(
                Gradient(colors: [water.opacity(alpha * 0.3), water.opacity(alpha)]),
                startPoint: point(0.5, 0, edge: edge, size: size),
                endPoint: point(0.5, depth, edge: edge, size: size)
            )
        )
        // Foam, which is what actually reads as water at this opacity: a soft wide pass for glow
        // with the crisp line over it, rather than one hard stroke that would read as a drawn outline.
        context.stroke(
            crest,
            with: .color(.white.opacity(alpha * 0.3)),
            style: StrokeStyle(lineWidth: 6, lineCap: .round)
        )
        context.stroke(
            crest,
            with: .color(.white.opacity(alpha)),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
        )
    }

    /// Maps a position along an edge (`u`, 0…1) and a depth in from it to a point on screen.
    private func point(_ u: CGFloat, _ depth: CGFloat, edge: GuidanceDirection, size: CGSize) -> CGPoint {
        switch edge {
        case .left:    return CGPoint(x: depth, y: u * size.height)
        case .right:   return CGPoint(x: size.width - depth, y: u * size.height)
        case .forward: return CGPoint(x: u * size.width, y: depth)
        case .back:    return CGPoint(x: u * size.width, y: size.height - depth)
        }
    }
}
