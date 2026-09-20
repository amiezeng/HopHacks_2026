import SwiftUI

/// Takes `HomeScreen`'s place as the root of its NavigationStack (don't nest another one here) once
/// its water fill covers the screen; the buttons then fall in like leaves on water (`LeafFall`)
/// and float there, drifting with the phone's tilt (`Floating`).
///
/// It replaces the home screen rather than being pushed over it, so going back is `onBack` rather
/// than `dismiss()` — see `HomeScreen.body` for why the push had to go.
struct MainScreen: View {
    var onBack: () -> Void = {}

    private static let magnifierBounds = MainArt.magnifier.bounds.union(MainArt.magnifierLens.bounds)

    private static let analyzeCardBounds = MainArt.analyzeCard.bounds
    /// Where the upright ANALYZE text sits: the artwork's (sideways) label rect turned on its side,
    /// scaled to span the button with a margin, and centered on it.
    private static let analyzeLabelFrame: CGRect = {
        let card = MainArt.analyzeCard.bounds, label = MainArt.analyzeLabel.bounds
        let scale = card.width * 0.86 / label.height
        let size = CGSize(width: label.height * scale, height: label.width * scale)
        return CGRect(x: card.midX - size.width / 2, y: card.midY - size.height / 2,
                      width: size.width, height: size.height)
    }()
    private static let lensZoom: CGFloat = 1.7
    /// How far the glass drifts with the eyes' look, as a fraction of its own height.
    private static let lensDrift: CGFloat = 0.12
    /// When the Analyze button has stopped tumbling: `LeafFall(delay: 0.25)` lands at 1.55 s and the
    /// touch-down squash springs out by ~2.2 s.
    private static let analyzeSettles: Double = 2.0
    /// How far down the artboard both buttons sit from where they were drawn, clearing the water above
    /// them for `WaterVisualizer`.
    private static let buttonDrop: CGFloat = 180
    /// That open water, in artboard points (clear of the notch above and the Find button below).
    private static let visualizerFrame = CGRect(x: 60, y: 130, width: 600, height: 570)

    /// When the back button has landed: `LeafFall(delay: 0.5)` lands at 1.8 s and its squash springs out
    /// shortly after (see `analyzeSettles`).
    private static let backSettles: Double = 2.25

    @StateObject private var eyes = EyeMotion()
    @StateObject private var motion = MotionTilt()
    @StateObject private var audio = AudioLevels()
    /// Set once the Analyze button has landed; until then its lens is a plain disc (see `LiquidGlassLens`).
    @State private var lensSettled = false
    /// Same for the back button's glass (see `LiquidGlassLens`).
    @State private var backSettled = false
    @State private var optionChosen = false
    @State private var showFind = false
    @State private var showAnalyze = false
    @State private var listenTask: Task<Void, Never>?
    @StateObject private var listener = VoiceListener()

    private let question = "Are you looking for something, or do you want help analyzing something?"
    private let commands: [String: [String]] = [
        "find": ["find", "locate", "position", "pinpoint", "looking for", "search"],
        "understand": ["understand", "analyze", "analyse", "analyzing", "interpret"],
        "repeat": ["repeat", "say that again", "one more time", "again", "pardon"]
    ]

    var body: some View {
        // Layers of design/MainScreen.ai; each button nests its layers in an Artboard over its card.
        Artboard(rect: MainArt.artboard) {
            WaterVisualizer(drops: audio.drops)
                .artFrame(Self.visualizerFrame)

            Button(action: chooseFind) {
                Artboard(rect: MainArt.findCard.bounds) {
                    MainArt.findCard
                    MainArt.findLabel
                    MainArt.findEyes
                        .moodScale(eyes.mood, white: true)
                        .blink(eyes.blinks)
                        .lookOffset(eyes.look, amount: 0.35, tilt: 12)
                    MainArt.findPupils
                        .moodScale(eyes.mood, white: false)
                        .lookOffset(eyes.look, amount: 1.1, tilt: 12)
                        .blink(eyes.blinks)
                    Eyelids(eye: MainArt.findEyes, color: MainArt.findCard.color, mood: eyes.mood, pair: true)
                        .moodScale(eyes.mood, white: true)
                        .blink(eyes.blinks)
                        .lookOffset(eyes.look, amount: 0.35, tilt: 12)
                }
            }
            .buttonStyle(.plain)
            .modifier(Floating(tilt: motion.tilt, startAfter: 1.3))
            .modifier(LeafFall(delay: 0))
            .artFrame(MainArt.findCard.bounds.offsetBy(dx: 0, dy: Self.buttonDrop))

            Button(action: chooseUnderstand) {
                Artboard(rect: MainArt.analyzeCard.bounds) {
                    analyzeFace
                    magnifier
                }
            }
            .modifier(Floating(tilt: motion.tilt, startAfter: 1.55, phase: 0.5))
            .modifier(LeafFall(delay: 0.25, sway: -45))
            .task {
                lensSettled = false
                try? await Task.sleep(for: .seconds(Self.analyzeSettles))
                withAnimation(.easeOut(duration: 0.45)) { lensSettled = true }
            }
            .artFrame(MainArt.analyzeCard.bounds.offsetBy(dx: 0, dy: Self.buttonDrop))
        }
        .background(MainArt.background.color)
        .clipped()
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { backButton }
        .overlay(alignment: .bottom) {
            if listener.isListening {
                ListeningIndicator()
            }
        }
        .animation(.easeInOut, value: listener.isListening)
        .navigationDestination(isPresented: $showFind) {
            ContentView(onBack: { showFind = false })
        }
        .navigationDestination(isPresented: $showAnalyze) {
            AnalyzeView(onBack: { showAnalyze = false })
        }
        .onChange(of: showFind) { _, isShowing in
            if !isShowing { Speaker.shared.stop() }
        }
        .onChange(of: showAnalyze) { _, isShowing in
            if !isShowing { Speaker.shared.stop() }
        }
        .task {
            optionChosen = false
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, !optionChosen else { return }
            Speaker.shared.speak(question)
            await listenForCommands()
        }
        .navigationBarBackButtonHidden(true)
        .onAppear { eyes.start(); motion.start(); audio.start() }
        .onDisappear {
            eyes.stop(); motion.stop(); audio.stop()
            listenTask?.cancel()
            listener.stop()
            Speaker.shared.stop()
        }
    }
}

extension MainScreen {
    /// Back to the home screen. It falls in like the two buttons (`LeafFall`) and then floats with the
    /// phone's tilt; like the magnifier's lens it rides the fall as a plain disc and cross-fades into
    /// real liquid glass once it has landed, because the system composites the glass effect outside the
    /// view's own transform.
    private var backButton: some View {
        Button { onBack() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(LiquidGlassLens(glass: backSettled))
                .contentShape(Circle())
        }
        .modifier(Floating(tilt: motion.tilt, startAfter: Self.backSettles, phase: 0.25))
        .modifier(LeafFall(delay: 0.5, sway: 30))
        .padding(.leading, 24)
        .padding(.top, 60)
        .task {
            backSettled = false
            try? await Task.sleep(for: .seconds(Self.backSettles))
            withAnimation(.easeOut(duration: 0.45)) { backSettled = true }
        }
    }

    /// Card + text, the part of the Analyze button the lens magnifies.
    private var analyzeFace: some View {
        Artboard(rect: Self.analyzeCardBounds) {
            MainArt.analyzeCard
            // ANALYZE is drawn sideways in the artwork, so it's turned a quarter turn to read across the
            // button. Nesting it in its own Artboard is what lets `.artFrame` move it off the spot it was
            // drawn at (an ArtLayer on its own always places itself at its artwork bounds).
            Artboard(rect: MainArt.analyzeLabel.bounds) { MainArt.analyzeLabel }
                .rotationEffect(.degrees(90))
                .artFrame(Self.analyzeLabelFrame.turned)
        }
    }

    /// The magnifying glass. It drifts around the button as the eyes look about — the glass keeps its
    /// size, only its position moves — and what it magnifies is worked out from where it has drifted
    /// to, so the letters swell as it passes over them.
    private var magnifier: some View {
        let drift = CGSize(width: eyes.look.x * Self.magnifierBounds.height * Self.lensDrift,
                           height: eyes.look.y * Self.magnifierBounds.height * Self.lensDrift * 0.6)
        let lens = MainArt.magnifierLens.bounds.offsetBy(dx: drift.width, dy: drift.height)
        return Artboard(rect: Self.magnifierBounds) {
            // Nested so `.artFrame` can move the layer off the spot it was drawn at; the tilt is
            // anchored on the lens, so the handle swings while the lens stays under the glass.
            Artboard(rect: MainArt.magnifier.bounds) { MainArt.magnifier }
                .rotationEffect(.degrees(eyes.look.x * 12), anchor: Self.lensPin)
                .artFrame(MainArt.magnifier.bounds.offsetBy(dx: drift.width, dy: drift.height))
            // Magnified copy of the button face: it stays put under the glass, blown up about
            // wherever the lens now is and clipped to it.
            analyzeFace
                .scaleEffect(Self.lensZoom, anchor: Self.anchor(lens.center, in: Self.analyzeCardBounds))
                .clipShape(LensClip(card: Self.analyzeCardBounds, lens: lens))
                .artFrame(Self.analyzeCardBounds)
            LiquidGlassLens(glass: lensSettled)
                .artFrame(lens)
        }
        .artFrame(Self.magnifierBounds)
    }

    private func choose(announcing message: String) {
        optionChosen = true
        listener.stop()
        Speaker.shared.stop()
        Speaker.shared.speak(message)
    }

    private func chooseFind() {
        choose(announcing: "Find object selected")
        showFind = true
    }

    private func chooseUnderstand() {
        choose(announcing: "Analyze object selected")
        showAnalyze = true
    }

    private func listenForCommands() async {
        await Speaker.shared.waitUntilIdle()
        guard !Task.isCancelled, !optionChosen else { return }
        await listener.start(commands: commands) { command in
            switch command {
            case "find":
                chooseFind()
            case "understand":
                chooseUnderstand()
            default:
                Speaker.shared.speak(question)
                listenTask = Task { await listenForCommands() }
            }
        }
    }

    /// `point` (artboard points) as a fraction of `rect`, for a scale/rotation anchor.
    private static func anchor(_ point: CGPoint, in rect: CGRect) -> UnitPoint {
        UnitPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    private static let lensPin = anchor(MainArt.magnifierLens.bounds.center, in: MainArt.magnifier.bounds)
}

private extension CGRect {
    /// Turned a quarter turn about its own center: the frame to place a view in so that it lands on
    /// this rect after `.rotationEffect(.degrees(90))`.
    var turned: CGRect {
        CGRect(x: midX - height / 2, y: midY - width / 2, width: height, height: width)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Circle of `lens` (artboard points) inside a view that covers `card`.
private struct LensClip: Shape {
    let card: CGRect
    let lens: CGRect

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / card.width, sy = rect.height / card.height
        return Path(ellipseIn: CGRect(x: rect.minX + (lens.minX - card.minX) * sx,
                                      y: rect.minY + (lens.minY - card.minY) * sy,
                                      width: lens.width * sx, height: lens.height * sy))
    }
}

/// Clear liquid glass disc (iOS 26+), a frosted-material disc with a rim highlight before that.
///
/// With `glass` off it draws a plain tinted disc instead: the system composites the glass effect outside
/// the view's own transform, so while the button is tumbling in (`LeafFall`) the glass slides away from
/// the magnifier it belongs to. The plain disc rides the fall and cross-fades into the real glass.
private struct LiquidGlassLens: View {
    var glass = true

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.14))
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 2))
                .opacity(glass ? 0 : 1)
            realGlass.opacity(glass ? 1 : 0)
        }
    }

    @ViewBuilder private var realGlass: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.clear, in: Circle())
        } else {
            Circle()
                .fill(.ultraThinMaterial.opacity(0.35))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 2))
        }
    }
}

#Preview {
    NavigationStack { MainScreen() }
}
