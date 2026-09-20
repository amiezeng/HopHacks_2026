import CoreMotion
import SwiftUI

/// Publishes how the phone is tilted (gravity x/y, each about -1…1, smoothed) for views to drift with.
final class MotionTilt: ObservableObject {
    @Published var tilt: CGSize = .zero

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            // Upright portrait is gravity y ≈ -1; measure forward/back tilt from a ~45° hold.
            let target = CGSize(width: g.x, height: g.y + 0.7)
            let k = 0.12 // low-pass so it glides like it's on water
            tilt = CGSize(width: tilt.width + (target.width - tilt.width) * k,
                          height: tilt.height + (target.height - tilt.height) * k)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Makes a view float on water: it drifts downhill as the phone tilts (`tilt` from `MotionTilt`),
/// bobs and rocks gently, and keeps sending out ripple rings that stay put on the surface.
/// `startAfter` holds the ripples back until the view has landed (e.g. after `LeafFall`);
/// `phase` desyncs several floaters.
struct Floating: ViewModifier {
    var tilt: CGSize
    var startAfter: Double = 0
    var phase: Double = 0
    var drift: CGFloat = 14
    var cornerRadius: CGFloat = 40

    @State private var start = Date()

    func body(content: Content) -> some View {
        TimelineView(.animation) { timeline in
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
                                .stroke(.white.opacity(0.35 * (1 - p) * settled), lineWidth: 2 * (1 - p) + 0.5)
                                .scaleEffect(x: 1 + p * 0.25, y: 1 + p * 0.4)
                        }
                    }
                }
        }
        .onAppear { start = .now }
    }
}
