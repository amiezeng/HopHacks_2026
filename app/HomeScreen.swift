import SwiftUI

struct HomeScreen: View {
    private static let titleLetters = HomeArt.title.pieces
    /// Sits under "PROBE", a third of its height, in artboard points.
    private static let subtitleBounds = CGRect(
        x: HomeArt.title.bounds.minX,
        y: HomeArt.title.bounds.maxY + 28,
        width: HomeArt.title.bounds.width,
        height: HomeArt.title.bounds.height / 3
    )
    /// Low on the monster's body, clear of the eye, in artboard points.
    private static let hintBounds = CGRect(
        x: HomeArt.artboard.midX - 170,
        y: 1285,
        width: 340,
        height: 150
    )

    @State private var showMainScreen = false
    @State private var pouring = false
    /// Set once the main screen has taken over underneath, to fade the water off it.
    @State private var waterCleared = false
    @StateObject private var eyes = EyeMotion()

    /// The main screen *replaces* this one as the stack's root rather than being pushed onto it.
    /// A push animates the new screen in from the side, and `disablesAnimations` doesn't stop it
    /// (the push is run by UIKit), so the seam between the two screens slid across mid-transition
    /// no matter how long the water was held over it. Swapping the root has no animation to suppress.
    var body: some View {
        NavigationStack {
            ZStack {
                if showMainScreen {
                    MainScreen(onBack: { swap(toMain: false) })
                } else {
                    home
                }
                // Main screen's blue pours in over the home screen, then the main screen takes its
                // place underneath and the water fades off it.
                if pouring {
                    WaterPour(color: MainArt.background.color) {
                        swap(toMain: true)
                        // By now the water is a flat sheet of the main screen's own color (its bubbles
                        // fade out as it tops up), so the fade only uncovers the buttons falling in.
                        withAnimation(.easeOut(duration: 0.4).delay(0.2)) { waterCleared = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                            pouring = false
                            waterCleared = false
                        }
                    }
                    .opacity(waterCleared ? 0 : 1)
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Swaps the stack's root without any animation.
    private func swap(toMain: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showMainScreen = toMain }
    }

    private var home: some View {
            // Layers of design/ProbeHome.ai; the background layer is the full-screen color.
            Artboard(rect: HomeArt.artboard) {
                HomeArt.monster
                    .lookOffset(eyes.look, amount: 0.03, tilt: 3)
                HomeArt.eyeWhite
                    .blink(eyes.blinks)
                    .lookOffset(eyes.look, amount: 0.15, tilt: 8)
                HomeArt.iris
                    .lookOffset(eyes.look, amount: 0.9)
                    .blink(eyes.blinks)
                HomeArt.pupil
                    .lookOffset(eyes.look, amount: 1.35)
                    .blink(eyes.blinks)
                // "PROBE", one letter at a time so they hop in a wave.
                ForEach(Array(Self.titleLetters.enumerated()), id: \.offset) { i, letter in
                    letter
                        .modifier(Bubbly(delay: Double(i) * 0.1))
                        .artFrame(letter.bounds)
                }
                // Hops in after the last letter, then pulses with them.
                Text("Reach with confidence")
                    .font(.system(size: 500, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.001)
                    .lineLimit(1)
                    .foregroundStyle(HomeArt.title.color)
                    .modifier(Bubbly(delay: Double(Self.titleLetters.count) * 0.1, hop: 8, pulse: 0.03))
                    .artFrame(Self.subtitleBounds)
                ScrollHint(color: HomeArt.background.color)
                    .artFrame(Self.hintBounds)
            }
            .background(HomeArt.background.color)
            .clipped()
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onEnded { value in
                        let isVerticalSwipe = abs(value.translation.height) > abs(value.translation.width)
                        if isVerticalSwipe && value.translation.height < -80 {
                            pouring = true
                        }
                    }
            )
            .onAppear { eyes.start() }
            .onDisappear { eyes.stop() }
    }
}

/// "Swipe up" nudge: after `delay` it fades in and then keeps drifting up and back down, with the
/// upper chevron trailing the lower one so the pair reads as a flow upward.
private struct ScrollHint: View {
    var color: Color
    var delay: Double = 1.5

    @State private var shown = false
    @State private var rising = false

    var body: some View {
        VStack(spacing: 4) {
            chevron(opacity: 0.45, lag: 0.18)
            chevron(opacity: 1, lag: 0)
            Text("swipe up")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(delay)) { shown = true }
            rising = true
        }
        .onDisappear {
            shown = false
            rising = false
        }
    }

    private func chevron(opacity: Double, lag: Double) -> some View {
        Chevron()
            .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            .frame(width: 30, height: 15)
            .offset(y: rising ? -9 : 0)
            .animation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(delay + lag),
                value: rising
            )
    }
}

private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// Bubbles in with one jelly hop (crouch, jump while stretched, squash on landing and wobble back),
/// then keeps gently growing and shrinking by `pulse`. `delay` staggers it so a row of them goes in a wave.
/// Replays each time the view appears.
private struct Bubbly: ViewModifier {
    var delay: Double
    var hop: CGFloat = 16
    var pulse: CGFloat = 0.05
    /// Seconds to grow, then again to shrink.
    var pulseDuration = 1.0

    struct Pose {
        var y: CGFloat = 0
        /// > 1 is tall and thin, < 1 short and wide.
        var stretch: CGFloat = 1
    }

    @State private var hops = 0
    @State private var pulsing = false

    /// When the crouch starts.
    private var start: Double { 0.3 + delay }

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1 + pulse : 1)
            .keyframeAnimator(initialValue: Pose(), trigger: hops) { view, pose in
                view
                    .scaleEffect(x: 1 / pose.stretch.squareRoot(), y: pose.stretch, anchor: .bottom)
                    .offset(y: pose.y)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    LinearKeyframe(0, duration: start + 0.12)
                    CubicKeyframe(-hop, duration: 0.26)
                    CubicKeyframe(0, duration: 0.22)
                }
                KeyframeTrack(\.stretch) {
                    LinearKeyframe(1, duration: start)
                    CubicKeyframe(0.8, duration: 0.12)  // crouch
                    CubicKeyframe(1.15, duration: 0.12) // take off
                    CubicKeyframe(1, duration: 0.14)    // top
                    CubicKeyframe(1.08, duration: 0.22) // fall
                    CubicKeyframe(0.8, duration: 0.08)  // land
                    SpringKeyframe(1, duration: 0.9, spring: .bouncy(duration: 0.4, extraBounce: 0.2))
                }
            }
            .onAppear {
                hops += 1
                // Starts once the landing wobble has settled.
                withAnimation(.easeInOut(duration: pulseDuration).repeatForever().delay(start + 1.2)) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
    }
}

#Preview {
    HomeScreen()
}
