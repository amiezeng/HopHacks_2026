import SwiftUI

/// The one thing at the bottom of the camera screen: a blob of water holding whatever the screen has to
/// say. How far away the thing is, big, with a line under it naming what is happening — the step the
/// voice has just announced while guidance has the screen, the conversation's own state after the
/// handoff, when there is no distance left to show and the blob is that line alone.
///
/// It is the only bottom pill here. The frosted `ListeningIndicator` used to sit under it saying the
/// same steps in different words, so the two are one thing, in the same water as `WaterPour` and
/// `GuidanceRipple`.
struct StatusBlob: View {
    /// The big line: what was measured. `nil` while nothing is — the blob is then a single line of text
    /// rather than a readout of "—".
    var measurement: String?
    /// Where that measurement has to get to ("→ 10 in"), on the last step. Smaller, beside it.
    var goal: String?
    /// What is happening, in the same words the voice uses.
    var text: String
    /// Breathes, the way the old pill's microphone did.
    var systemImage: String?
    /// The blob fills out and its foam brightens once the thing it is reporting has been reached. The
    /// screen's other "yes" is a green box, which belongs to the computer-vision overlay rather than
    /// to this.
    var highlighted = false

    /// The MainScreen blue, taken from the layer itself so it can't drift from the rest of the water.
    private let water = MainArt.background.color

    @State private var start = Date()
    @State private var bob = false
    @State private var breathing = false

    /// With a measurement above it the second line is a caption; on its own it is the whole message,
    /// so it is set at the size the pill it replaced used.
    private var alone: Bool { measurement == nil }

    var body: some View {
        VStack(spacing: 3) {
            if let measurement {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(measurement)
                        .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                    if let goal {
                        Text(goal)
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                            .opacity(0.75)
                    }
                }
            }
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: alone ? 17 : 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .scaleEffect(breathing ? 1.12 : 0.92)
                }
                Text(text)
                    .font(.system(size: alone ? 19 : 15, weight: .semibold, design: .rounded))
            }
            .opacity(alone ? 1 : 0.92)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .padding(.horizontal, 34)
        .padding(.vertical, alone ? 17 : 20)
        .background {
            // Only the blob is on a per-frame schedule: the text sits outside it, so a wobble doesn't
            // re-lay-out two strings 120 times a second.
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    let path = blob(in: size, t: t)
                    context.fill(path, with: .color(water.opacity(highlighted ? 0.92 : 0.78)))
                    // A glint, so it reads as a surface and not a flat shape.
                    context.fill(
                        Path(ellipseIn: CGRect(x: size.width * 0.15, y: size.height * 0.17,
                                               width: size.width * 0.2, height: size.height * 0.15)),
                        with: .color(.white.opacity(0.16))
                    )
                    context.stroke(
                        path,
                        with: .color(.white.opacity(highlighted ? 0.95 : 0.55)),
                        style: StrokeStyle(lineWidth: 2.5, lineJoin: .round)
                    )
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            }
        }
        // Buoyancy, as a repeating animation rather than another per-frame schedule: it's a transform
        // on what is already drawn, so it costs nothing to keep running.
        .offset(y: bob ? 3 : -3)
        .padding(.bottom, 32)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .animation(.easeInOut(duration: 0.3), value: highlighted)
        .onAppear {
            start = .now
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { bob = true }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathing = true }
        }
    }

    /// A squircle with a slow swell running around it: round enough to read as a drop of water, square
    /// enough to hold a line of text without wasting its corners the way an ellipse would.
    private func blob(in size: CGSize, t: TimeInterval) -> Path {
        let centerX = size.width / 2
        let centerY = size.height / 2
        // Room for the foam line, which is stroked on the path itself.
        let radiusX = centerX - 3
        let radiusY = centerY - 3
        let steps = 48

        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for step in 0..<steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            // Two swells at different rates, so the surface never repeats a shape you can catch.
            let swell = 1 + 0.035 * sin(3 * angle + t * 0.9) + 0.022 * sin(5 * angle - t * 0.6)
            let cosine = cos(angle), sine = sin(angle)
            points.append(CGPoint(
                x: centerX + radiusX * swell * copysign(pow(abs(cosine), 0.5), cosine),
                y: centerY + radiusY * swell * copysign(pow(abs(sine), 0.5), sine)
            ))
        }

        // Smoothed through the midpoints, the same way the waves and `WaterPour`'s surface are drawn.
        var path = Path()
        path.move(to: CGPoint(x: (points[steps - 1].x + points[0].x) / 2,
                              y: (points[steps - 1].y + points[0].y) / 2))
        for step in 0..<steps {
            let next = points[(step + 1) % steps]
            path.addQuadCurve(
                to: CGPoint(x: (points[step].x + next.x) / 2, y: (points[step].y + next.y) / 2),
                control: points[step]
            )
        }
        path.closeSubpath()
        return path
    }
}

extension StatusBlob {
    /// The conversation half of the screen, in the words `ListeningIndicator` used for it on Analyze —
    /// there is nothing measured here, so this is the one-line blob.
    init(status: AgentSession.Status) {
        switch status {
        case .speaking: self.init(text: "Probe is speaking…", systemImage: "speaker.wave.2.fill")
        case .thinking: self.init(text: "Thinking…", systemImage: "ellipsis")
        case .connecting: self.init(text: "Connecting…", systemImage: "antenna.radiowaves.left.and.right")
        case .listening, .idle: self.init(text: "Listening…", systemImage: "mic.fill")
        }
    }
}
