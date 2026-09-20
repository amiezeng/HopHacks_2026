import SwiftUI

/// "How can PROBE help you": each word floats up from below like a bubble rising through water —
/// swaying side to side, fading in as it climbs — and settles in its place, where it stays. Plays once
/// when the view appears; the words set off one after another.
///
/// Everything is offset/scale/opacity on text drawn once, so nothing is re-rasterized per frame
/// (see **Keeping the screens smooth**).
struct BubbleTitle: View {
    private static let words = ["How", "can", "PROBE", "help", "you?"]
    /// Seconds between one word setting off and the next.
    private static let stagger = 0.22
    private static let riseTime = 1.6
    private static let startDelay = 0.25

    /// Two lines: indices into `words` (which keep one stagger/phase sequence across both).
    private static let lines = [0..<3, 3..<5]

    var body: some View {
        GeometryReader { geo in
            // Sized so the longer line ("How can PROBE", ~9.8 sizes wide with its gaps) fits the
            // width and both lines fit the height, so nothing is cut off.
            let size = min(geo.size.width / 9.8, geo.size.height / 2.4)
            VStack(spacing: size * 0.1) {
                ForEach(Self.lines, id: \.lowerBound) { range in
                    HStack(spacing: size * 0.3) {
                        ForEach(Array(range), id: \.self) { i in
                            FloatingWord(text: Self.words[i], size: size,
                                         delay: Self.startDelay + Double(i) * Self.stagger,
                                         rise: Self.riseTime,
                                         phase: i)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }
}

private struct FloatingWord: View {
    let text: String
    let size: CGFloat
    let delay: Double
    let rise: Double
    let phase: Int

    /// Set once the word has floated up; it is state, not a keyframe track's end value, so the word
    /// stays put afterwards by construction.
    @State private var risen = false
    /// The ±5% grow and shrink the home title's letters use, started once the word has settled.
    @State private var pulsing = false

    var body: some View {
        // Alternate the first sway direction so neighbouring words don't drift in step.
        let dir: Double = phase.isMultiple(of: 2) ? 1 : -1

        Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .fixedSize()
            .scaleEffect(pulsing ? 1.05 : 1)
            .keyframeAnimator(initialValue: 0.0, trigger: risen) { view, x in
                view.offset(x: x * size * 0.35)
            } keyframes: { _ in
                // Side to side on the way up, damping to nothing at the top.
                KeyframeTrack {
                    LinearKeyframe(0, duration: delay)
                    CubicKeyframe(dir, duration: rise * 0.3)
                    CubicKeyframe(-dir * 0.7, duration: rise * 0.3)
                    CubicKeyframe(dir * 0.3, duration: rise * 0.25)
                    CubicKeyframe(0, duration: rise * 0.15)
                }
            }
            .offset(y: risen ? 0 : size * 6)
            .opacity(risen ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: rise).delay(delay)) { risen = true }
                withAnimation(.easeInOut(duration: 1).repeatForever().delay(delay + rise + 0.3)) {
                    pulsing = true
                }
            }
            .onDisappear { risen = false; pulsing = false }
    }
}
