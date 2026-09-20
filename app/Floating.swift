import CoreMotion
import SwiftUI

/// Publishes how the phone is tilted (gravity x/y, each about -1…1, smoothed) for views to drift with.
@Observable
final class MotionTilt {
    var tilt: CGSize = .zero

    private let manager = CMMotionManager()
    /// Sampled at 60 Hz. It used to run at 30 to spare the bodies it re-evaluates, but the drift is a
    /// slow, wide movement of a whole button, and stepping it 30 times a second was visible as exactly
    /// that — the floating read as half-rate next to everything else on the screen.
    private static let rate = 1.0 / 60

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = Self.rate
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            // Upright portrait is gravity y ≈ -1; measure forward/back tilt from a ~45° hold.
            let target = CGSize(width: g.x, height: g.y + 0.7)
            // Low-pass so it glides like it's on water. Paired with `rate`: halving the interval halves
            // the coefficient that settles in the same time ((1 - k) per tick, so k = 1 - 0.78^0.5).
            let k = 0.117
            let next = CGSize(width: tilt.width + (target.width - tilt.width) * k,
                              height: tilt.height + (target.height - tilt.height) * k)
            // A still phone converges on a value and then republishes it forever; at `drift` points of
            // travel this much is a small fraction of a point, so stop rather than redraw for nothing.
            // Halved with `k`, so that a smaller step per tick doesn't stop the drift short of where
            // it was heading.
            guard abs(next.width - tilt.width) > 0.001 || abs(next.height - tilt.height) > 0.001 else { return }
            tilt = next
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Makes a view float on water: it drifts downhill as the phone tilts (`tilt` from `MotionTilt`),
/// bobs and rocks gently, and keeps sending out ripple rings that stay put on the surface.
/// `startAfter` holds the ripples back until the view has landed (e.g. after `LeafFall`);
/// `phase` desyncs several floaters.
struct Floating: ViewModifier {
    /// The tilt is read here rather than passed in, so a tilt update redraws only the views that are
    /// floating — not the screen that placed them, whose body would otherwise be rebuilt 30 times a
    /// second (on `MainScreen` that means the whole artboard).
    var motion: MotionTilt
    var startAfter: Double = 0
    var phase: Double = 0
    var drift: CGFloat = 14
    var cornerRadius: CGFloat = 40

    @State private var start = Date()

    func body(content: Content) -> some View {
        let tilt = motion.tilt
        return TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let settled = min(max((t - startAfter) / 0.8, 0), 1)
            content
                .rotationEffect(.degrees(sin(t * 1.3 + phase) * 1.5 * settled - tilt.width * 4))
                .offset(x: tilt.width * drift,
                        y: tilt.height * drift + sin(t * 1.8 + phase) * 3 * settled)
                .background {
                    // Ripples: rings spread out and fade, one every `period / count` seconds.
                    let period = 3.0, count = 3
                    ZStack {
                        ForEach(0..<count, id: \.self) { i in
                            let p = (t / period + Double(i) / Double(count) + phase).truncatingRemainder(dividingBy: 1)
                            RoundedRectangle(cornerRadius: cornerRadius)
                                // The width is stepped in half points: a ring thinning smoothly is a new
                                // stroke to rasterize every frame, where the scale and the fade are just
                                // the ring it already has, moved and faded.
                                .stroke(.white, lineWidth: ((2 * (1 - p) + 0.5) * 2).rounded() / 2)
                                // The fade has to be a modifier, not `.white.opacity(…)` in the stroke:
                                // a stroke color is part of what gets rasterized, so fading it there
                                // redrew the ring every frame and undid the stepping above. As a
                                // modifier it is the layer's own alpha, which costs nothing to change.
                                .opacity(0.35 * (1 - p) * settled)
                                .scaleEffect(x: 1 + p * 0.25, y: 1 + p * 0.4)
                        }
                    }
                }
        }
        .onAppear { start = .now }
    }
}
