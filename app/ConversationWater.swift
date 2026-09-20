import SwiftUI

/// What the conversation is doing, as the water draws it.
enum WaterMood {
    /// Nothing to say: before the handoff, and after the conversation has gone.
    case still
    /// Reading the label off the object — the only mood whose rings run *inward*.
    case drawingIn
    case thinking
    case listening
    case speaking
}

/// The water that closes around the object once guidance has run out of steps.
///
/// `GuidanceRipple` washes the MainScreen blue in from the edge the hand has to move toward, so while
/// the three steps are running the water is always *a direction*. When the last one is done there is
/// nowhere left to send anyone — so the water comes in from all four edges at once and stays, a pool
/// with the thing the user is holding in the middle of it.
///
/// After that the pool breathes with the conversation: rings out of the centre, brisk and bright while
/// Probe is talking, one slow one while it is listening, and running the other way — drawn inward, onto
/// the object — while the label is being read. A single bright ring breaks the surface at the moment
/// the reading turns into a conversation.
///
/// Same rules as every other per-frame thing in this app: one `Canvas`, rendered asynchronously off the
/// main thread (this sits over a camera feed that needs it), and no frames asked for at all until there
/// is a pool. Nothing here is animated with `withAnimation` either — a `Canvas` reads its state raw, so
/// an animated `@State` would arrive at its final value on the first frame and the pool would snap
/// shut. Every value below is a function of the timeline's own clock instead.
struct ConversationWater: View {
    var mood: WaterMood

    /// How far in from its edge the pool's rim reaches, as a fraction of the screen. The sides measure
    /// across the width and the ends down the height, so the four are the same *depth* of water rather
    /// than the same fraction of a tall phone.
    private let sideReach: CGFloat = 0.16
    private let endReach: CGFloat = 0.12
    /// Points between crests along an edge, and how far the crest swings either way. Long and shallow
    /// next to `GuidanceRipple`'s: this is a pool sitting still, not a wave on its way somewhere.
    private let wavelength: CGFloat = 240
    private let swell: CGFloat = 8
    /// How fast the crests travel along the rim, in radians a second.
    private let drift = 0.45
    /// The MainScreen blue, taken from the layer itself so the pool can't drift from the water poured
    /// on the way into that screen, or from the waves the guidance was drawing a moment ago.
    private let water = MainArt.background.color

    /// How long the rim takes to sweep in. The same as the water pouring into MainScreen, and for the
    /// same reason: long enough to be watched arriving, short enough not to be waited on.
    private let closing: TimeInterval = 1.2
    /// Seconds between rings and how long one takes to cross. Fixed across every mood on purpose: a
    /// cadence that changed with the agent's state would jump the phase of every ring in flight each
    /// time it started or stopped talking, which reads as a glitch rather than as a change of mood.
    /// What the mood changes is how bright and how heavy they are (`glow`), which crossfades.
    private let ringGap = 0.62
    private let ringLife = 2.2
    private let splashLife = 0.95
    private let glowFade: TimeInterval = 0.45

    @State private var start = Date()
    /// When the rim started sweeping in. `nil` until the handoff, which is also what keeps this view
    /// from asking for a single frame for the whole of guidance.
    @State private var openedAt: Date?
    /// The glow crossfade in flight: where it came from, where it is going, and when it set off.
    @State private var glowWas = 0.0
    @State private var glowGoal = 0.0
    @State private var glowAt = Date.distantPast
    /// When the surface was last broken: the handoff into the conversation, and each rescan that comes
    /// back with something. `nil` until the first one.
    @State private var splashAt: Date?

    var body: some View {
        // No pool, no frames. An empty `Canvas` is cheap to draw but not free to commit, and for the
        // whole of guidance this view is exactly that.
        TimelineView(.animation(paused: openedAt == nil)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let now = timeline.date
                let closed = closed(at: now)
                guard closed > 0 else { return }
                let glow = glow(at: now)
                let t = now.timeIntervalSince(start)
                drawRim(context, size: size, t: t, closed: closed, glow: glow)
                drawRings(context, size: size, t: t, glow: glow)
                drawSplash(context, size: size, now: now)
            }
        }
        .allowsHitTesting(false)
        .onAppear { start = .now }
        .onChange(of: mood) { was, now in
            let at = Date()
            if now != .still, openedAt == nil { openedAt = at }
            // Reading has just turned into talking, or a rescan has come back.
            if was == .drawingIn, now != .drawingIn, now != .still { splashAt = at }
            glowWas = glow(at: at)
            glowGoal = now.glow
            glowAt = at
        }
    }

    // MARK: - The clock

    /// How far the rim has swept in, 0 to 1. Eased out, so the water arrives rather than stopping dead.
    private func closed(at now: Date) -> CGFloat {
        guard let openedAt else { return 0 }
        let p = min(1, max(0, now.timeIntervalSince(openedAt) / closing))
        return CGFloat(1 - pow(1 - p, 3))
    }

    /// How brightly the pool is answering, part way through its crossfade onto the current mood.
    private func glow(at now: Date) -> Double {
        let p = min(1, max(0, now.timeIntervalSince(glowAt) / glowFade))
        // Smoothstep: no kink at either end of the fade.
        return glowWas + (glowGoal - glowWas) * (p * p * (3 - 2 * p))
    }

    // MARK: - The rim

    private enum Side: CaseIterable { case left, right, top, bottom }

    private func drawRim(_ context: GraphicsContext, size: CGSize, t: TimeInterval, closed: CGFloat, glow: Double) {
        // The pool rises a little while Probe is talking — the same swell the rings carry, so the whole
        // surface moves together rather than the middle of it moving on its own.
        let rise = 0.92 + 0.16 * glow
        for side in Side.allCases {
            let acrossWidth = side == .left || side == .right
            let reach = acrossWidth ? size.width * sideReach : size.height * endReach
            draw(context, size: size, side: side, depth: reach * closed * rise, closed: closed, glow: glow, t: t)
        }
    }

    private func draw(
        _ context: GraphicsContext,
        size: CGSize,
        side: Side,
        depth: CGFloat,
        closed: CGFloat,
        glow: Double,
        t: TimeInterval
    ) {
        let acrossWidth = side == .left || side == .right
        let span = acrossWidth ? size.height : size.width
        let crests = Double(span / wavelength)
        // Each side is offset along the wave, or the four crests would rise and fall together and the
        // pool would read as a box closing rather than as water.
        let offset = Double(Side.allCases.firstIndex(of: side) ?? 0) * 1.7

        // Sampled and then smoothed through the midpoints, the way `WaterPour` and `GuidanceRipple`
        // draw their surfaces: eighteen samples carry a curve that would need far more as segments.
        let samples = 18
        var points: [CGPoint] = []
        points.reserveCapacity(samples + 1)
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples)
            let ripple = sin(Double(u) * crests * 2 * .pi + t * drift + offset)
            points.append(point(u, depth + CGFloat(ripple) * swell * closed, side: side, size: size))
        }

        var crest = Path()
        crest.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2,
                              y: (points[i - 1].y + points[i].y) / 2)
            crest.addQuadCurve(to: mid, control: points[i - 1])
        }
        crest.addLine(to: points[points.count - 1])

        var sheet = crest
        sheet.addLine(to: point(1, 0, side: side, size: size))
        sheet.addLine(to: point(0, 0, side: side, size: size))
        sheet.closeSubpath()

        // Deepest at the screen edge and thinning to nothing at the crest, so the camera is looking out
        // of the middle of a pool rather than through a blue frame.
        context.fill(
            sheet,
            with: .linearGradient(
                Gradient(colors: [water.opacity(Double(closed) * 0.5), water.opacity(0)]),
                startPoint: point(0.5, 0, side: side, size: size),
                endPoint: point(0.5, max(depth, 1), side: side, size: size)
            )
        )
        // Foam, which is what actually reads as water at this opacity: a soft wide pass for the glow
        // with the crisp line over it, rather than one hard stroke that would read as a drawn outline.
        let foam = Double(closed) * (0.3 + 0.25 * glow)
        context.stroke(crest, with: .color(.white.opacity(foam * 0.3)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))
        context.stroke(crest, with: .color(.white.opacity(foam)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// Maps a position along an edge (`u`, 0…1) and a depth in from it to a point on screen.
    private func point(_ u: CGFloat, _ depth: CGFloat, side: Side, size: CGSize) -> CGPoint {
        switch side {
        case .left:   return CGPoint(x: depth, y: u * size.height)
        case .right:  return CGPoint(x: size.width - depth, y: u * size.height)
        case .top:    return CGPoint(x: u * size.width, y: depth)
        case .bottom: return CGPoint(x: u * size.width, y: size.height - depth)
        }
    }

    // MARK: - The rings

    private func drawRings(_ context: GraphicsContext, size: CGSize, t: TimeInterval, glow: Double) {
        guard glow > 0.02 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let near = min(size.width, size.height) * 0.09
        let far = max(size.width, size.height) * 0.6
        let inward = mood == .drawingIn
        let newest = Int(floor(t / ringGap))
        let live = Int((ringLife / ringGap).rounded(.up))

        for n in stride(from: newest, through: newest - live, by: -1) {
            let p = (t - Double(n) * ringGap) / ringLife
            guard p >= 0, p <= 1 else { continue }
            // Out of the middle fast and slowing as it widens, the way a ring on water does — or the
            // other way about while the label is being read: the water closing in on what is being
            // taken in, quickening as it goes.
            let travel = inward ? 1 - pow(p, 1.7) : 1 - pow(1 - p, 2)
            let radius = near + (far - near) * travel
            // Fades in and back out over its life, so nothing appears or stops dead mid-screen.
            let ink = sin(Double.pi * p) * glow
            guard ink > 0.01, radius > 1 else { continue }
            context.stroke(Self.disc(centre, radius), with: .color(.white.opacity(ink * 0.22)),
                           lineWidth: 3 + 9 * glow)
            context.stroke(Self.disc(centre, radius), with: .color(.white.opacity(ink * 0.55)),
                           lineWidth: 1 + 2.5 * glow)
        }
    }

    /// One bright ring as the surface breaks: the label has been read, and there is a conversation now.
    private func drawSplash(_ context: GraphicsContext, size: CGSize, now: Date) {
        guard let splashAt else { return }
        let p = now.timeIntervalSince(splashAt) / splashLife
        guard p >= 0, p <= 1 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * (0.05 + 0.8 * (1 - pow(1 - p, 3)))
        let ink = pow(1 - p, 0.9)
        context.stroke(Self.disc(centre, radius), with: .color(.white.opacity(ink * 0.3)),
                       lineWidth: 16 * ink)
        context.stroke(Self.disc(centre, radius), with: .color(.white.opacity(ink * 0.9)),
                       lineWidth: 3 * ink)
        // The drop it was struck by, sinking away where the ring came from.
        if p < 0.3 {
            let pop = 1 - p / 0.3
            context.fill(Self.disc(centre, min(size.width, size.height) * 0.06 * pop),
                         with: .color(.white.opacity(0.7 * pop)))
        }
    }

    private static func disc(_ centre: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                               width: radius * 2, height: radius * 2))
    }
}

private extension WaterMood {
    /// How brightly the pool answers, 0–1. Crossfaded on every change; see `ConversationWater.glow`.
    var glow: Double {
        switch self {
        case .still: return 0.08
        case .drawingIn: return 0.5
        case .thinking: return 0.2
        case .listening: return 0.33
        case .speaking: return 0.75
        }
    }
}
