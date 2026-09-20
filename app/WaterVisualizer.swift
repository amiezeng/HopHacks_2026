import SwiftUI

/// The open water above the buttons, with three patches of it listening to the microphone — one for
/// each band `AudioLevels` hears (bass on the left, mids up the middle, highs on the right). Speaking
/// shakes drops loose over those patches: each one lands somewhere random, splashes, and sends rings
/// spreading out until they fade back into the surface. Silence leaves the water still.
struct WaterVisualizer: View {
    var drops: [WaterDrop]

    /// Middle of each band's patch, as a fraction of the view — off a straight line, so the drops don't
    /// fall along an obvious row. A band only leans towards its patch: `scatter` throws its drops far
    /// enough that the three patches overlap.
    private static let patches: [CGPoint] = [CGPoint(x: 0.2, y: 0.58),
                                             CGPoint(x: 0.5, y: 0.3),
                                             CGPoint(x: 0.8, y: 0.58)]

    /// How far past the view's frame the canvas extends on every side, so rings spreading out of the
    /// patches aren't cut off at its edge. Everything is still laid out against the view's own frame.
    private static let bleed: CGFloat = 2000

    var body: some View {
        // Paused while the water is still: an empty `Canvas` is cheap to draw but not free to commit,
        // and a screen-sized one asking for a frame 60 (or 120) times a second next to the buttons'
        // animations is main-thread time spent drawing nothing at all.
        TimelineView(.animation(paused: drops.isEmpty)) { timeline in
            // Drawn off the main thread: it's decorative, and a screenful of rings every frame is work
            // the buttons' animations need the main thread for.
            Canvas(rendersAsynchronously: true) { context, canvasSize in
                let size = CGSize(width: canvasSize.width - 2 * Self.bleed,
                                  height: canvasSize.height - 2 * Self.bleed)
                context.translateBy(x: Self.bleed, y: Self.bleed)
                let now = timeline.date.timeIntervalSinceReferenceDate
                // How far from its patch's middle a drop can land, and how wide the rings it throws
                // can grow. Between them the water gets rained on all over, not tapped in three spots.
                let scatter = CGSize(width: size.width * 0.5, height: size.height * 0.55)
                let widest = size.width * 0.42
                for drop in drops where drop.band < Self.patches.count {
                    let age = CGFloat((now - drop.born) / drop.life)
                    guard age >= 0, age <= 1 else { continue }
                    let middle = Self.patches[drop.band]
                    let spot = CGPoint(x: middle.x * size.width + (drop.at.x - 0.5) * scatter.width,
                                       y: middle.y * size.height + (drop.at.y - 0.5) * scatter.height)
                    let fade = 1 - age
                    // Rings pull away quickly and slow as they widen.
                    let spread = 1 - pow(1 - age, 2)
                    let radius = widest * drop.reach * spread
                    let weight = 0.4 + 0.6 * drop.strength

                    // The splash where it lands: a fat drop of water that sinks away at once.
                    if age < 0.35 {
                        let pop = 1 - age / 0.35
                        context.fill(Self.disc(spot, widest * 0.2 * weight * (0.3 + 0.7 * pop)),
                                     with: .color(.white.opacity(0.8 * pop * weight)))
                    }
                    // The ring it throws out, with a fainter one trailing behind it. Both hold their
                    // weight for most of the way out and thin down as they go under.
                    let ink = pow(fade, 0.7)
                    context.stroke(Self.disc(spot, radius),
                                   with: .color(.white.opacity(0.9 * weight * ink)),
                                   lineWidth: 2 + 11 * weight * ink)
                    if spread > 0.25 {
                        context.stroke(Self.disc(spot, radius * 0.58),
                                       with: .color(.white.opacity(0.4 * weight * ink)),
                                       lineWidth: 1 + 5 * weight * ink)
                    }
                }
            }
            .padding(-Self.bleed)
        }
        .allowsHitTesting(false)
    }

    private static func disc(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
    }
}
