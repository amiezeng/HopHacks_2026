import CoreMotion
import os
import SwiftUI

/// How the Find button's eyes feel, picked from how the phone is moving (see `EyeMotion.updateMood`).
enum Mood: String {
    case neutral, happy, sleepy, angry, surprised, dizzy
}

/// Drives the eyes from device motion: pupils follow the phone's tilt (gravity), the eyes blink
/// on a quick jolt of the phone or at random every few seconds, and `mood` follows how it's moved.
@MainActor
@Observable
final class EyeMotion {
    /// Where the pupils look, -1…1 on each axis (+x right, +y down).
    private(set) var look: CGPoint = .zero
    /// Bumped on every blink; use as an animation trigger.
    private(set) var blinks = 0
    private(set) var mood = Mood.neutral

    private var surprisedUntil = Date.distantPast
    private var dizzyUntil = Date.distantPast
    private var spin = 0.0
    private var flatSince: Date?

    private let manager = CMMotionManager()
    /// Sampled at 60 Hz. At 30 the pupils crossed the eye in visible steps, and on the Analyze button
    /// the magnifier drifts with the same value across most of the card, where half-rate is obvious.
    /// What a publish re-evaluates is kept small instead: only the views that read `look` (`Monster`,
    /// `FindFace`, `AnalyzeFace`), never a screen's own body.
    private static let rate = 1.0 / 60
    private var blinkTask: Task<Void, Never>?
    private var lastBlink = Date.distantPast

    func start() {
        guard manager.isDeviceMotionAvailable else {
            Logger().error("EyeMotion: device motion unavailable")
            return
        }
        guard !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = Self.rate
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Tilting the phone ~15° moves the eyes all the way over.
            let g = motion.gravity
            var target = CGPoint(x: clamp(g.x / 0.25), y: clamp((-g.z - 0.5) / 0.3))
            updateMood(motion)
            if mood == .dizzy {
                // Pupils roll around in circles.
                let t = Date().timeIntervalSinceReferenceDate * 9
                target = CGPoint(x: cos(t) * 0.6, y: sin(t) * 0.6)
            }
            // Low-pass so the eyes glide instead of jittering. Paired with `rate`: halving the interval
            // takes the coefficient that settles in the same time to 1 - 0.5^0.5.
            let k = 0.293
            let next = CGPoint(x: look.x + (target.x - look.x) * k,
                               y: look.y + (target.y - look.y) * k)
            // Publishing redraws every layer that follows the eyes, so a held-still phone — which
            // converges on a value and then republishes it every frame — stops here instead.
            // Halved with `k`, so a smaller step per tick doesn't stop the look short of its target.
            if abs(next.x - look.x) > 0.001 || abs(next.y - look.y) > 0.001 { look = next }
            // A quick flick or shake makes him blink.
            let r = motion.rotationRate
            if (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() > 3, mood != .dizzy { blink() }
        }
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5)))
                self?.blink()
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        blinkTask?.cancel()
        blinkTask = nil
    }

    /// Picks the mood, strongest first:
    /// - dizzy: spinning the phone around for a moment
    /// - surprised: a sudden jolt (shove it or jerk it)
    /// - angry: turning the phone upside down
    /// - sleepy: laying it flat, screen up, for a second
    /// - happy: tilting it far to either side
    private func updateMood(_ motion: CMDeviceMotion) {
        let now = Date()
        let g = motion.gravity, r = motion.rotationRate, a = motion.userAcceleration

        // Only a real twirl of the phone in its own plane counts, not everyday handling, and it has
        // to keep going: dizzy overrides the tilt, so a false one looks like the eyes spinning at random.
        spin = abs(r.z) > 4 ? spin + Self.rate : max(0, spin - 3 * Self.rate)
        if spin > 0.7 { dizzyUntil = now.addingTimeInterval(1.5) }
        if (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() > 0.35 { surprisedUntil = now.addingTimeInterval(1.2) }
        if g.z < -0.7 { flatSince = flatSince ?? now } else { flatSince = nil }

        let next: Mood
        if now < dizzyUntil { next = .dizzy }
        else if now < surprisedUntil { next = .surprised }
        else if g.y > 0 { next = .angry }
        else if let flatSince, now.timeIntervalSince(flatSince) > 0.3 { next = .sleepy }
        else if abs(g.x) > 0.25 { next = .happy }
        else { next = .neutral }
        if next != mood {
            mood = next
            if next == .surprised || next == .angry { blink() }
        }
    }

    private func blink() {
        guard Date().timeIntervalSince(lastBlink) > 0.4 else { return }
        lastBlink = Date()
        blinks += 1
    }
}

private func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v, -1), 1)) }

extension View {
    /// Squashes the view vertically for a quick blink each time `trigger` changes.
    func blink(_ trigger: Int) -> some View {
        keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scaleY in
            view.scaleEffect(x: 1, y: scaleY)
        } keyframes: { _ in
            CubicKeyframe(0.05, duration: 0.07)
            CubicKeyframe(0.05, duration: 0.04)
            SpringKeyframe(1, duration: 0.18)
        }
    }

    /// Offsets the layer by `look` times `amount` of its own rendered height, tilting it with the look.
    func lookOffset(_ look: CGPoint, amount: CGFloat, tilt: Double = 0) -> some View {
        visualEffect { content, proxy in
            content
                .offset(x: look.x * proxy.size.height * amount,
                        y: look.y * proxy.size.height * amount * 0.6)
                .rotationEffect(.degrees(look.x * tilt))
        }
    }
}

/// Eyelids in the skin color over an eye, shaped by `mood`. Put it above the pupil and give it the
/// same modifiers as the eye white; `eye` is the eye-white layer, used to clip the lids to the eye.
/// With `pair`, `eye` holds two eyes side by side and each gets its own top lid, slanted in mirror.
struct Eyelids: View {
    let eye: ArtLayer
    let color: Color
    let mood: Mood
    var pair = false

    /// (top lid coverage 0–1, top lid angle in degrees, bottom lid coverage 0–1)
    private var lids: (top: CGFloat, angle: Double, bottom: CGFloat) {
        switch mood {
        case .neutral: (0, 0, 0)
        case .happy: (0, 0, 0.25)       // cheeks push up: ^ ^
        case .sleepy: (0.35, 0, 0)       // heavy lids
        case .angry: (0.25, 12, 0)          // slanted brow
        case .surprised: (0, 0, 0)         // wide open (see `moodScale`)
        case .dizzy: (0.1, -6, 0.1)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            ZStack {
                if pair {
                    // Left lid tilts down toward the middle, right lid the other way.
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Rectangle()
                            .fill(color)
                            .frame(width: w * 0.8, height: h)
                            .rotationEffect(.degrees(-side * lids.angle))
                            .offset(x: side * w / 4, y: -h + h * lids.top)
                    }
                } else {
                    Rectangle()
                        .fill(color)
                        .frame(width: w * 1.6, height: h)
                        .rotationEffect(.degrees(lids.angle))
                        .offset(y: -h + h * lids.top)
                }
                Ellipse()
                    .fill(color)
                    .frame(width: geo.size.width * 1.4, height: h * 1.2)
                    .offset(y: h * 1.1 - h * 1.2 * lids.bottom)
            }
            .frame(width: geo.size.width, height: h)
        }
        .mask(eye)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: mood)
        .artFrame(eye.bounds)
    }
}

extension View {
    /// Scales an eye part for `mood`: `white` for the eye white, otherwise an iris/pupil.
    func moodScale(_ mood: Mood, white: Bool) -> some View {
        let scale: CGFloat = switch mood {
        case .surprised: white ? 1.07 : 0.8   // wide eyes, tiny pupils
        case .angry: white ? 1 : 0.9
        case .dizzy: white ? 1.02 : 0.93
        default: 1
        }
        return scaleEffect(scale)
            .animation(.spring(duration: 0.3, bounce: 0.45), value: mood)
    }
}
