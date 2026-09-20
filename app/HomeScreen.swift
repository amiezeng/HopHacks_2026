import SwiftUI

struct HomeScreen: View {
    /// Not private, and off the main actor, so `Preloader` can build the split before the screen is shown.
    nonisolated static let titleLetters = HomeArt.title.pieces
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
    /// Where "PROBE" is centered (in artboard points) while `LoadingScreen` is up. It rises from there.
    static let loadingTitleCenter: CGFloat = 720
    /// How far below its place here that is, as a fraction of the artboard's height (`artboardShift`).
    static let loadingTitleDrop = (loadingTitleCenter - HomeArt.title.bounds.midY) / HomeArt.artboard.height
    /// The title glides up; the monster follows a beat later with a little give, and comes up from
    /// below the whole artboard (a shift of `1`), further than any part of him is on screen.
    private static let titleRise = Animation.smooth(duration: 0.9)
    private static let monsterRise = Animation.spring(duration: 1.0, bounce: 0.2).delay(0.15)
    /// How long after the rise starts the title is close enough to its place for the letters to start
    /// hopping and the subtitle and hint to come in.
    private static let landingDelay = Duration.milliseconds(550)

    /// False while the loading screen is still up over this one (so it can lay out and draw unseen).
    /// Turning it true plays the entrance: the title rises from where `LoadingScreen` drew it and the
    /// monster slides in from below. It isn't replayed when coming back from the main screen.
    var introStarted = true

    @State private var hasIntroduced = false
    @StateObject private var listener = VoiceListener()

    /// The entrance has started: title and monster are on their way to their places.
    @State private var risen = false
    /// ...and the title has all but arrived: the letters can hop, the rest can fade in.
    @State private var landed = false

    @State private var showMainScreen = false
    @State private var pouring = false
    @State private var eyes = EyeMotion()

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
                // place underneath and the water comes straight off it.
                if pouring {
                    WaterPour(color: MainArt.background.color) {
                        swap(toMain: true)
                        // By the time it's full the water is a flat sheet of the main screen's own color
                        // (the bubbles and foam fade out as it tops up), so it can be cut rather than
                        // faded: a fade kept the buttons hidden through the first half of their fall,
                        // which is what made them look like they started late. The couple of frames
                        // held here are for the main screen's first frame, and are invisible.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pouring = false }
                    }
                }
            }
            .ignoresSafeArea()
            .task(id: introStarted) {
                guard introStarted, !risen else { return }
                risen = true
                try? await Task.sleep(for: Self.landingDelay)
                guard !Task.isCancelled else { return }
                landed = true
            }
        }
        .background(VolumeHUDHider())
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
                // Nested over the whole artboard (which places its layers exactly where this one would)
                // so that the eyes moving redraws only the monster — not the title's letters and the
                // subtitle, whose text has to be measured and fitted again on every pass.
                Monster(eyes: eyes)
                    .artboardShift(risen ? 0 : 1, animation: Self.monsterRise)
                    .artFrame(HomeArt.artboard)
                // "PROBE", one letter at a time so they hop in a wave once they've risen into place.
                // Grouped over the whole artboard so the group can be shifted as one.
                Artboard(rect: HomeArt.artboard) {
                    ForEach(Array(Self.titleLetters.enumerated()), id: \.offset) { i, letter in
                        letter
                            .modifier(Bubbly(delay: Double(i) * 0.1, isActive: landed))
                            .artFrame(letter.bounds)
                    }
                }
                .artboardShift(risen ? 0 : Self.loadingTitleDrop, animation: Self.titleRise)
                .artFrame(HomeArt.artboard)
                // Fades in under the title once it has landed, hops in after the last letter, then
                // pulses with them.
                SubtitleLetters(text: "Reach with confidence", color: HomeArt.title.color,
                                delay: Double(Self.titleLetters.count) * 0.1, isActive: landed)
                    .opacity(landed ? 1 : 0)
                    .animation(.easeOut(duration: 0.3).delay(0.4), value: landed)
                    .artFrame(Self.subtitleBounds)
                if landed {
                    ScrollHint(color: HomeArt.background.color)
                        .artFrame(Self.hintBounds)
                }
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
            .overlay(alignment: .bottom) {
                if listener.isListening {
                    ListeningIndicator()
                }
            }
            .animation(.easeInOut, value: listener.isListening)
            .task(id: introStarted) {
                guard introStarted else { return }
                if !hasIntroduced {
                    try? await Task.sleep(for: .seconds(0.25))
                    guard !Task.isCancelled else { return }
                    hasIntroduced = true
                    Speaker.shared.speak("Hello, this is Probe. I can help you find things around you, or help you understand an item you're holding!")
                }
                await Speaker.shared.waitUntilIdle()
                guard !Task.isCancelled else { return }
                await listener.start(
                    commands: ["continue": ["continue", "okay", "next", "start", "begin", "go", "yes", "ready"]]
                ) { _ in pouring = true }
            }
            .onAppear { eyes.start() }
            .onDisappear { eyes.stop(); listener.stop() }
    }
}

/// The subtitle, one letter at a time like the title, scaled as a whole to fit its frame.
private struct SubtitleLetters: View {
    var text: String
    var color: Color
    var delay: Double
    var isActive = true

    /// The row's size at the reference font size, measured once laid out.
    @State private var natural = CGSize(width: 1, height: 1)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / natural.width, geo.size.height / natural.height)
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch))
                        .font(.system(size: 500, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .modifier(Bubbly(delay: delay + Double(i) * 0.04, hop: 8, pulse: 0.03, isActive: isActive))
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
            .scaleEffect(scale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The monster and his eye, which follow the phone (`EyeMotion`).
private struct Monster: View {
    var eyes: EyeMotion

    var body: some View {
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
        }
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
/// Replays each time the view appears (once `isActive`).
private struct Bubbly: ViewModifier {
    var delay: Double
    var hop: CGFloat = 16
    var pulse: CGFloat = 0.05
    /// Seconds to grow, then again to shrink.
    var pulseDuration = 1.0
    /// Held still until this is true (the view can be on screen, at rest, well before it should hop).
    var isActive = true

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
            .onChange(of: isActive, initial: true) { _, active in
                guard active else { return }
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
