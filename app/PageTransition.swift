import SwiftUI

/// Fills the screen with `color` like water poured into a glass: a stream falls from the top center
/// and necks as it accelerates, splashes where it lands, and the level pumps up glug by glug behind a
/// sloshing, foam-topped surface that climbs the side walls, with droplets flying off the impact and
/// bubbles rising inside. Calls `onFull` once the screen is covered.
struct WaterPour: View {
    var color: Color
    var duration: Double = 1.5
    var onFull: () -> Void = {}

    /// Where the stream lands and the level starts rising.
    private let impact = 0.14
    /// How far past the top the water goes, so the troughs still cover when full.
    private let overfill = 1.12

    @State private var start: Date?
    @State private var reported = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = start.map { timeline.date.timeIntervalSince($0) } ?? 0
            Canvas { context, size in
                draw(&context, size: size, t: t)
            }
            .onChange(of: t >= duration) { _, full in
                if full && !reported {
                    reported = true
                    onFull()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { start = .now }
    }

    // MARK: - Timeline

    /// How full the screen is at `time`, 0–1, pumping a little with each glug.
    private func level(at time: Double) -> Double {
        let p = min(max(time / duration, 0), 1)
        let f = max(0, (p - impact) / (1 - impact))
        // Rushes in once the stream lands, then eases into the brim.
        let base = 1 - pow(1 - f, 2.4)
        return min(1, base + 0.022 * sin(time * 9) * (1 - base))
    }

    /// Resting height of the water surface at `time` (waves are added on top of this).
    private func surfaceY(at time: Double, height: CGFloat) -> CGFloat {
        height * (1 - level(at: time) * overfill)
    }

    /// How far the falling stream's tip has dropped at `time`, before it reaches the water.
    private func tipY(at time: Double, height: CGFloat) -> CGFloat {
        let p = min(max(time / duration, 0), 1)
        return height * min(1, pow(p / impact, 1.8))
    }

    /// Where the stream is hitting water (or floor) at `time`.
    private func impactY(at time: Double, height: CGFloat) -> CGFloat {
        min(tipY(at: time, height: height), surfaceY(at: time, height: height))
    }

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let level = level(at: t)
        let surface = surfaceY(at: t, height: size.height)
        let hit = impactY(at: t, height: size.height)
        let centerX = size.width / 2
        // Everything calms down as the glass fills.
        let energy = 1 - level

        // Sloshing surface: a long swell, a shorter chop, and water climbing the side walls.
        let amp = 9 + 26 * energy
        let climb = 26 * energy
        func waveY(_ x: CGFloat) -> CGFloat {
            let a = Double(x / max(size.width, 1)) * .pi * 2
            let toEdge = abs(Double(x / max(size.width, 1)) * 2 - 1)
            return surface
                + amp * sin(a * 1.3 + t * 4.4)
                + amp * 0.45 * sin(a * 2.7 - t * 7.1)
                + amp * 0.2 * sin(a * 4.3 + t * 9.7)
                - climb * pow(toEdge, 3)
        }

        // Smooth the sampled surface into curves so the crests never look faceted.
        let samples = 28
        let crest = (0...samples).map { i -> CGPoint in
            let x = size.width * Double(i) / Double(samples)
            return CGPoint(x: x, y: waveY(x))
        }
        var top = Path()
        top.move(to: crest[0])
        for i in 1..<crest.count {
            let mid = CGPoint(x: (crest[i - 1].x + crest[i].x) / 2, y: (crest[i - 1].y + crest[i].y) / 2)
            top.addQuadCurve(to: mid, control: crest[i - 1])
        }
        top.addLine(to: crest[crest.count - 1])

        var water = top
        water.addLine(to: CGPoint(x: size.width, y: size.height))
        water.addLine(to: CGPoint(x: 0, y: size.height))
        water.closeSubpath()
        context.fill(water, with: .color(color))

        // Everything below the surface is clipped to the water, so it never spills onto the background.
        var below = context
        below.clip(to: water)

        // Ripple rings spreading out from where the stream keeps hitting.
        for k in 0..<3 {
            let phase = (t * 1.8 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let rx = 30 + phase * size.width * 0.6
            let ry = rx * 0.22
            let y = impactY(at: t - phase / 1.8, height: size.height)
            below.stroke(Path(ellipseIn: CGRect(x: centerX - rx, y: y - ry, width: rx * 2, height: ry * 2)),
                         with: .color(.white.opacity((1 - phase) * 0.3)), lineWidth: 2)
        }

        // Bubbles rising inside the water, popping when they reach the surface.
        for i in 0..<18 {
            let life = 0.5 + rand(i, 1) * 0.5
            let age = (t + rand(i, 2) * life).truncatingRemainder(dividingBy: life)
            let x = size.width * (0.08 + rand(i, 3) * 0.84)
            let y = size.height - (0.1 + 0.9 * (age / life)) * (size.height - surface)
            let r = 2 + rand(i, 4) * 5
            guard y > waveY(x) + r else { continue }
            // Fades out with the rest of the churn, so the full screen of water ends up a flat sheet
            // of `color` with nothing on it to blink out when the overlay goes.
            let fade = (1 - age / life) * 0.45 * energy
            below.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(fade)), lineWidth: 1.5)
        }

        // Foam line riding the crest.
        context.stroke(top, with: .color(.white.opacity(0.25 + 0.3 * energy)), style:
                        StrokeStyle(lineWidth: 3 + 2 * energy, lineCap: .round))

        // The falling stream: it necks as it speeds up, wobbles, and pulses with each glug.
        let width = 40 * (1 - smoothstep(min(max(t / duration, 0), 1), 0.55, 1)) * (1 + 0.14 * sin(t * 9))
        if width > 0.5 && hit > 2 {
            var stream = Path()
            var rightEdge: [CGPoint] = []
            for i in 0...20 {
                let f = Double(i) / 20
                let y = hit * f
                // Thins as it speeds up, with glugs travelling down it and a slow side-to-side wander.
                let w = width * (1 - 0.45 * f) * (1 + 0.3 * sin(f * 9 - t * 16))
                let wob = sin(f * 3 - t * 4.5) * 11 * f * energy
                let point = CGPoint(x: centerX - w / 2 + wob, y: y)
                if i == 0 { stream.move(to: point) } else { stream.addLine(to: point) }
                rightEdge.append(CGPoint(x: centerX + w / 2 + wob, y: y))
            }
            for point in rightEdge.reversed() { stream.addLine(to: point) }
            stream.closeSubpath()
            context.fill(stream, with: .color(color))

            // Mound heaping up where it lands, pumping with the glugs.
            let mound = width * (0.85 + 0.3 * sin(t * 16))
            context.fill(Path(ellipseIn: CGRect(x: centerX - mound, y: hit - width * 0.65,
                                                width: mound * 2, height: width * 1.3)),
                         with: .color(color))
        }

        // Droplets thrown off the impact, each looping its own ballistic arc on its own beat.
        // Gravity is heavy so an arc peaks ~100 pt up in a third of a second, which outruns the
        // rising surface — a lazier arc just gets swallowed as soon as it is thrown.
        let gravity = 2400.0
        for i in 0..<26 {
            let period = 0.42 + rand(i, 5) * 0.3
            let launch = floor((t - rand(i, 6) * period) / period) * period + rand(i, 6) * period
            let age = t - launch
            let life = 0.4 + rand(i, 7) * 0.3
            guard age >= 0, age < life, launch > impact * duration * 0.7 else { continue }
            let dir: Double = i % 2 == 0 ? 1 : -1
            let vx = dir * (140 + rand(i, 8) * 320)
            let vy = -(600 + rand(i, 9) * 350)
            let x = centerX + (rand(i, 10) - 0.5) * 30 + vx * age
            let y = impactY(at: launch, height: size.height) + vy * age + gravity * age * age
            // Gone once it falls back into the water or leaves the screen.
            guard y > -20, y < waveY(min(max(x, 0), size.width)) else { continue }
            let r = (2 + rand(i, 11) * 4) * (1 - pow(age / life, 2))
            guard r > 0.3 else { continue }
            context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(color))
        }
    }

    /// Stable per-droplet/bubble randomness, so each keeps the same arc from frame to frame.
    private func rand(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - floor(x)
    }

    private func smoothstep(_ x: Double, _ from: Double, _ to: Double) -> Double {
        let t = min(max((x - from) / (to - from), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Drops a view in like a leaf onto a lake: it drifts down from above the screen swaying side to side
/// and tilting, touches the surface, bobs, and sends out a ripple ring. `delay` staggers several.
/// Replays each time the view appears.
struct LeafFall: ViewModifier {
    var delay: Double = 0
    /// How far above its resting place the view starts. It has to clear the top of the screen from
    /// wherever the view sits, so this is sized for the lowest one (MainScreen's Analyze button,
    /// which rests about two thirds of the way down) rather than for a screen height.
    var height: CGFloat = 1000
    var sway: CGFloat = 45

    struct Pose {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var angle: Double = 0
        var scale: CGFloat = 1
        var ripple: CGFloat = 0
    }

    @State private var drops = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: start, trigger: drops) { view, pose in
                view
                    .scaleEffect(pose.scale)
                    .rotationEffect(.degrees(pose.angle))
                    .offset(x: pose.x, y: pose.y)
                    .background {
                        // Ripple spreading out from where it landed.
                        RoundedRectangle(cornerRadius: 40)
                            .stroke(.white.opacity(0.6 * (1 - pose.ripple)), lineWidth: 3)
                            .scaleEffect(1 + pose.ripple * 0.35)
                            .opacity(pose.ripple > 0 ? 1 : 0)
                    }
            } keyframes: { _ in
                // Falling: ~1.3 s, swinging like a pendulum while it drifts down.
                KeyframeTrack(\.y) {
                    LinearKeyframe(-height, duration: delay)
                    CubicKeyframe(-height * 0.55, duration: 0.35)
                    CubicKeyframe(-height * 0.2, duration: 0.45)
                    CubicKeyframe(0, duration: 0.5)
                    // Bob on the water.
                    CubicKeyframe(8, duration: 0.25)
                    CubicKeyframe(-3, duration: 0.3)
                    CubicKeyframe(0, duration: 0.4)
                }
                KeyframeTrack(\.x) {
                    LinearKeyframe(sway, duration: delay)
                    CubicKeyframe(-sway, duration: 0.35)
                    CubicKeyframe(sway * 0.6, duration: 0.45)
                    CubicKeyframe(-sway * 0.2, duration: 0.4)
                    SpringKeyframe(0, duration: 0.6, spring: .bouncy)
                }
                KeyframeTrack(\.angle) {
                    LinearKeyframe(-18, duration: delay)
                    CubicKeyframe(16, duration: 0.35)
                    CubicKeyframe(-10, duration: 0.45)
                    CubicKeyframe(4, duration: 0.4)
                    SpringKeyframe(0, duration: 0.7, spring: .bouncy)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1.08, duration: delay + 1.2)
                    CubicKeyframe(0.94, duration: 0.15) // touch down
                    SpringKeyframe(1, duration: 0.6, spring: .bouncy(extraBounce: 0.2))
                }
                KeyframeTrack(\.ripple) {
                    LinearKeyframe(0, duration: delay + 1.25)
                    LinearKeyframe(1, duration: 0.8)
                }
            }
            .onAppear {
                // MainScreen is pushed inside a transaction with animations disabled (so the navigation
                // slide doesn't show under the water). That transaction is still ambient here and would
                // swallow the fall, leaving the view sitting in its resting place. Triggering on the next
                // runloop turn, with a transaction of our own, puts the fall outside it.
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.disablesAnimations = false
                    withTransaction(transaction) { drops += 1 }
                }
            }
    }

    private var start: Pose { Pose(x: sway, y: -height, angle: -18, scale: 1.08) }
}
