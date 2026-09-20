import SwiftUI

/// Takes `HomeScreen`'s place as the root of its NavigationStack (don't nest another one here) once
/// its water fill covers the screen; the buttons then fall in like leaves on water (`LeafFall`)
/// and float there, drifting with the phone's tilt (`Floating`).
///
/// It replaces the home screen rather than being pushed over it, so going back is `onBack` rather
/// than `dismiss()` — see `HomeScreen.body` for why the push had to go.
struct MainScreen: View {
    var onBack: () -> Void = {}

    /// How much the magnifier's lens blows up the Analyze face. `Preloader` rasterizes that face at
    /// this much over the display's resolution, so the letters under the glass stay sharp — off the
    /// main actor, hence `nonisolated`.
    nonisolated static let lensZoom: CGFloat = 1.7
    /// How far down the artboard both buttons sit from where they were drawn, clearing the water above
    /// them for `WaterVisualizer`.
    private static let buttonDrop: CGFloat = 110
    /// That open water, in artboard points (clear of the notch above and the Find button below).
    private static let visualizerFrame = CGRect(x: 60, y: 410, width: 600, height: 290)
    /// Where "How can PROBE help you" bubbles up, above the water.
    private static let titleFrame = CGRect(x: 20, y: 235, width: 680, height: 175)

    /// How far above its resting place each button falls from (`LeafFall`), in points: just enough to
    /// start off the top of the screen on the largest phone, so the whole fall is on screen. Analyze
    /// rests lowest, so it comes from highest up and — every leaf falling at the same speed — lands last.
    private static let findDrop: CGFloat = 700
    private static let analyzeDrop: CGFloat = 980
    private static let backDrop: CGFloat = 220

    /// When each button touches down, measured from this screen appearing.
    private static let findLands = LeafFall.landing(height: findDrop)
    private static let analyzeLands = LeafFall.landing(height: analyzeDrop)
    private static let backLands = LeafFall.landing(height: backDrop)
    /// How long after a landing its touch-down squash has sprung out, and the glass can cross-fade in
    /// (see `LiquidGlassLens`).
    private static let glassSettles = 0.45

    @State private var eyes = EyeMotion()
    @State private var motion = MotionTilt()
    @State private var audio = AudioLevels()
    /// Set once the back button has landed; until then its glass is a plain disc (see `LiquidGlassLens`).
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
            WaterWell(audio: audio)
                .artFrame(Self.visualizerFrame)

            BubbleTitle()
                .artFrame(Self.titleFrame)

            Button(action: chooseFind) { FindFace(eyes: eyes) }
                .buttonStyle(.plain)
                .modifier(Floating(motion: motion, startAfter: Self.findLands))
                .modifier(LeafFall(height: Self.findDrop))
                .artFrame(MainArt.findCard.bounds.offsetBy(dx: 0, dy: Self.buttonDrop))

            Button(action: chooseUnderstand) {
                AnalyzeFace(eyes: eyes, glassSettlesAfter: Self.analyzeLands + Self.glassSettles)
            }
            .modifier(Floating(motion: motion, startAfter: Self.analyzeLands, phase: 0.5))
            .modifier(LeafFall(height: Self.analyzeDrop, sway: -45))
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
            // Held until the last button has landed. Starting to speak still costs the main thread a
            // little (see `Speaker.play`), and mid-fall that shows as the leaves hitching.
            try? await Task.sleep(for: .seconds(Self.analyzeLands + 0.15))
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
            // Not when this screen is leaving because it pushed Find or Analyze. A push fires this
            // *after* the destination has appeared and started talking, so it cut the announcement
            // off mid-word and emptied the queue under the line the new screen had just put in it —
            // which is why Find asked nothing and went straight to listening. Coming back from
            // either is the `onChange` pair above; this is for going home.
            if !showFind, !showAnalyze { Speaker.shared.stop() }
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
        .modifier(Floating(motion: motion, startAfter: Self.backLands, phase: 0.25))
        .modifier(LeafFall(height: Self.backDrop, sway: 30))
        .padding(.leading, 24)
        .padding(.top, 60)
        .task {
            backSettled = false
            try? await Task.sleep(for: .seconds(Self.backLands + Self.glassSettles))
            withAnimation(.easeOut(duration: 0.45)) { backSettled = true }
        }
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
}

/// The Find button's face. Its own view so that the eyes moving redraws just this, not the whole
/// screen: `MainScreen` never reads `eyes`, so an update doesn't reach its body.
private struct FindFace: View {
    var eyes: EyeMotion

    var body: some View {
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
}

/// The Analyze button's face, under its magnifying glass. Its own view for the same reason as
/// `FindFace` — and it matters more here, because the face is drawn twice (once plain, once
/// magnified through the lens), so every redraw of it costs double.
private struct AnalyzeFace: View {
    var eyes: EyeMotion
    /// When the lens can stop being a plain disc and cross-fade into real glass (see `LiquidGlassLens`).
    var glassSettlesAfter: Double

    private static let magnifierBounds = MainArt.magnifier.bounds.union(MainArt.magnifierLens.bounds)
    private static let cardBounds = MainArt.analyzeCard.bounds
    /// Where the upright ANALYZE text sits: the artwork's (sideways) label rect turned on its side,
    /// scaled to span the button with a margin, and centered on it.
    private static let labelFrame: CGRect = {
        let card = MainArt.analyzeCard.bounds, label = MainArt.analyzeLabel.bounds
        let scale = card.width * 0.86 / label.height
        let size = CGSize(width: label.height * scale, height: label.width * scale)
        return CGRect(x: card.midX - size.width / 2, y: card.midY - size.height / 2,
                      width: size.width, height: size.height)
    }()
    /// How far the glass drifts with the eyes' look, as a fraction of its own height.
    private static let lensDrift: CGFloat = 0.12

    /// Set once the button has landed; until then its lens is a plain disc (see `LiquidGlassLens`).
    @State private var lensSettled = false

    var body: some View {
        Artboard(rect: MainArt.analyzeCard.bounds) {
            face
            magnifier
        }
        .task {
            lensSettled = false
            try? await Task.sleep(for: .seconds(glassSettlesAfter))
            withAnimation(.easeOut(duration: 0.45)) { lensSettled = true }
        }
    }

    /// Card + text, the part of the button the lens magnifies.
    private var face: some View {
        Artboard(rect: Self.cardBounds) {
            MainArt.analyzeCard
            // ANALYZE is drawn sideways in the artwork, so it's turned a quarter turn to read across the
            // button. Nesting it in its own Artboard is what lets `.artFrame` move it off the spot it was
            // drawn at (an ArtLayer on its own always places itself at its artwork bounds).
            Artboard(rect: MainArt.analyzeLabel.bounds) { MainArt.analyzeLabel }
                .rotationEffect(.degrees(90))
                .artFrame(Self.labelFrame.turned)
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
            face
                .environment(\.artOversample, MainScreen.lensZoom)
                .scaleEffect(MainScreen.lensZoom, anchor: Self.anchor(lens.center, in: Self.cardBounds))
                .clipShape(LensClip(card: Self.cardBounds, lens: lens))
                .artFrame(Self.cardBounds)
            LiquidGlassLens(glass: lensSettled)
                .artFrame(lens)
        }
        .artFrame(Self.magnifierBounds)
    }

    /// `point` (artboard points) as a fraction of `rect`, for a scale/rotation anchor.
    private static func anchor(_ point: CGPoint, in rect: CGRect) -> UnitPoint {
        UnitPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    private static let lensPin = anchor(MainArt.magnifierLens.bounds.center, in: MainArt.magnifier.bounds)
}

/// The open water, listening. Its own view so the drops arriving (a few dozen times a second while
/// there is any sound) redraw only the water and not the buttons over it.
private struct WaterWell: View {
    var audio: AudioLevels

    var body: some View {
        WaterVisualizer(drops: audio.drops)
    }
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
