import SwiftUI
import Combine
import AVFoundation
import AudioToolbox
import QuartzCore
import UIKit

/// Hands the tone's level and stereo position to the audio render thread, which can't touch main-actor
/// state. Aligned 32-bit stores, so the render callback takes no lock (where one risks priority
/// inversion).
private final class ToneLevel: @unchecked Sendable {
    var value: Float = 0
    /// -1 hard left, +1 hard right.
    var pan: Float = 0
    /// The ripple cue layered over the tone: one soft drop every `rippleInterval` seconds at this peak
    /// level (0 = off), panned by `ripplePan`. `rippleSweep` bends the drop's pitch up (+1) or down
    /// (-1) as it decays, which is what tells the two axes apart.
    var rippleLevel: Float = 0
    var ripplePan: Float = 0
    var rippleInterval: Float = 1
    var rippleSweep: Float = 0
}

/// Guides the user's hand to the object with a tone that moves between their ears, in two phases:
///
/// 1. **Depth.** The tone sits in the *right* ear while the hand has to go further forward, and in the
///    *left* ear once it has gone past the object. Silent otherwise — no spoken direction on this axis.
/// 2. **Lateral.** Once the depth is right, the tone pans to the side the hand has to travel. The
///    voice only announces the phase once; it does not repeat "left"/"right", the tone does that.
///
/// In both, the volume is the remaining error: louder means closer. Because direction is carried by the
/// stereo image, this needs headphones — the phone's own two speakers are at the top and bottom of the
/// case in portrait, so panning between them says nothing about left and right.
///
/// Under the tone runs a **ripple**: a soft water drop struck from the side to move toward, closing up
/// as the error does. It says the same thing the tone does, in a way you can follow without holding a
/// loudness in your head — the four directions come out as a drop from the left, from the right, one
/// rising in pitch (forward) and one falling (back). It is deliberately quiet and gets out of the way
/// whenever there are words to hear: it's a texture on the tone, not a second signal to listen past.
///
/// Everything here plays on the *shared* audio session (`Speaker.configureAudioSession`). Setting a
/// `.playback` category of its own is what silenced this whole feature once the voice work merged in:
/// `VoiceListener` keeps a microphone session open the whole time this screen is up and re-asserts the
/// shared `.playAndRecord` category every time the recognizer restarts, so the two tore each other's
/// engines down — and the tone engine, started behind a one-shot `isPlaying` flag, never came back.
@MainActor
final class DistanceBeepController: ObservableObject {
    private enum Phase { case idle, depth, lateral, contact }

    /// A repeating spoken cue. Never the word "back": `VoiceListener` is listening for it as the
    /// "go back" command the whole time, and would hear us say it through the speaker. Left/right is
    /// deliberately not here: repeating it was a chant on top of a tone that already says it.
    private enum Cue: String {
        case findHand = "Hold your hand up in front of the camera"
        case findObject = "Move the camera around so I can see it"
        case headphones = "Please connect headphones to use guidance"
    }

    private let audioEngine = AVAudioEngine()
    private let tone = ToneLevel()
    /// The same direction the tone is carrying, for `GuidanceRipple` to draw over the camera feed.
    /// Not `@Published`: see `GuidanceCue`.
    let cue = GuidanceCue()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let directionFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let readReadyFeedback = UINotificationFeedbackGenerator()
    private var sourceNode: AVAudioSourceNode?
    private var startingTone = false
    private var lastToneStart = Date.distantPast
    private var lastHeldBack = Date.distantPast

    private var active = false
    private let greeting = "Move your hand toward the object and follow the tone."
    /// Set when a one-shot line was held back because something else was mid-sentence, so it lands
    /// right after rather than on top of it. Retried on each update until it is spoken.
    private var pendingGreeting = false
    private var pendingPhaseLine: String?
    private var objectName = "object"
    private var lastCue: Cue?
    private var lastSpoken = Date.distantPast

    private var phase = Phase.idle
    /// `found` here means "the hand is at the object's depth", so phase 1 is `!found` and phase 2 is
    /// `found`. The release threshold is deliberately double the contact one: swinging the arm sideways
    /// pivots at the shoulder and changes depth, so phase 2 constantly nudges phase 1's condition, and
    /// a bare threshold would flap between the two on every lateral correction.
    private static let depthTolerance: Float = 0.06
    private static let depthRelease: Float = 0.12
    private var depthAligned = FoundTracker(
        contactDistance: DistanceBeepController.depthTolerance,
        releaseDistance: DistanceBeepController.depthRelease,
        dwell: 0.3,
        release: 0.5,
        lostTimeout: 2
    )
    private var lastMeasured: TimeInterval = 0
    private var hasHeadphones = false
    private var routeObserver: NSObjectProtocol?

    private var foundSoundPlayed = false
    private var approachPromptPlayed = false
    private var closePromptPlayed = false
    private var readReadyHapticPlayed = false

    /// Lateral offsets below this count as lined up, in normalized image units across the screen.
    private let lateralTolerance: CGFloat = 0.05
    /// The error at which the tone is at its quietest, per axis: meters along the camera axis, and
    /// normalized image units across the screen.
    private let depthRange: Float = 0.5
    private let lateralRange: CGFloat = 0.4
    /// Never hard left or hard right: a blind user should not have an ear closed off. 0.9 still reads
    /// unmistakably as "that side" while leaving a little in the far ear.
    private let panLimit: Float = 0.9
    /// Seconds between ripples at the far end of an axis' range, and once lined up on it. Slow enough
    /// at the top to stay out of the way, and never fast enough to run into the 0.35 s drop and turn
    /// into a buzz.
    private let rippleSlow: Float = 1.1
    private let rippleFast: Float = 0.3
    /// Nothing to measure (no hand, or no object) is nudged much more slowly still.
    private let searchGap: TimeInterval = 5
    private let headphoneGap: TimeInterval = 10
    /// A measurement dropout shorter than this holds the current phase: hand pose is lost near the
    /// camera and a gripping hand hides its fingertips, so phases must not reset on every gap.
    private let idleTimeout: TimeInterval = 2
    /// `update` runs at ~10 Hz, so a tone engine that refuses to start must not be retried on every
    /// one: each attempt is a session activation, and hammering those disrupts playback everywhere.
    private let toneRetryGap: TimeInterval = 2

    /// Called as the screen appears. Guidance does not wait for the user to name a target: the object
    /// detector is already running, and the screen going quiet until someone has spoken is the whole
    /// problem this feature exists to solve.
    func begin() {
        guard !active else { return }
        active = true
        lastCue = nil
        lastSpoken = Date()
        lastMeasured = CACurrentMediaTime()
        hasHeadphones = Self.routeHasHeadphones()
        print("Guidance: on, headphones \(hasHeadphones ? "connected" : "not connected")")
        // The per-update check reads a cached flag rather than the route itself, so plugging in has to
        // come through here to take effect without leaving the screen.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRoute() }
        }
        startToneIfNeeded()
        // Spoken here rather than from `update`: that only runs once the detector starts publishing,
        // which needs the AR session up, and the screen must not be silent if the camera is slow.
        pendingGreeting = !speak(greeting)
    }

    /// The target, once the user has said it. Only changes the wording of the prompts.
    func setTarget(_ name: String) {
        objectName = name
        print("Guidance: target is \(name)")
    }

    func update(
        leftEdge: EdgeMeasurement?,
        rightEdge: EdgeMeasurement?,
        objectFound: Bool,
        approaching: Bool,
        objectClose: Bool,
        objectCenter: CGPoint?
    ) {
        guard active else { return }
        // An audio-session interruption (a route change, or the recognizer restarting under us) stops
        // the engine; this is where it comes back, rather than staying dead for the rest of the screen.
        startToneIfNeeded()

        if pendingGreeting {
            pendingGreeting = !speak(greeting)
            if !pendingGreeting { lastSpoken = Date() }
            return
        }

        // Tied to `approaching`, not to `objectFound`: the grip hides the fingertips, so `objectFound`
        // flickers while the object is being carried to the camera, and re-arming on each flicker
        // repeated the prompts.
        if !approaching {
            foundSoundPlayed = false
            approachPromptPlayed = false
            closePromptPlayed = false
            readReadyHapticPlayed = false
        }

        if objectFound || approaching {
            setPhase(.contact)
            if !foundSoundPlayed {
                foundSoundPlayed = true
                AudioServicesPlaySystemSound(1057)
            }
            silence()

            if !objectClose && !approachPromptPlayed {
                approachPromptPlayed = speak("Hold the \(objectName) closer to the screen until it is close enough to read.")
            } else if objectClose && !closePromptPlayed {
                if !readReadyHapticPlayed {
                    readReadyHapticPlayed = true
                    readReadyFeedback.prepare()
                    readReadyFeedback.notificationOccurred(.success)
                }
                closePromptPlayed = speak("The \(objectName) is close enough to read.")
            }
            return
        }

        let now = CACurrentMediaTime()
        guard let measurement = nearest(leftEdge, rightEdge), let objectCenter else {
            silence()
            _ = depthAligned.update(distance: nil, time: now)
            if now - lastMeasured >= idleTimeout { setPhase(.idle) }
            say(objectCenter == nil ? .findObject : .findHand, after: searchGap)
            return
        }
        lastMeasured = now

        // The tone's direction lives entirely in the stereo image, so without headphones there is
        // nothing to hear: the phone's own two speakers are at the top and bottom of the case in
        // portrait, and panning between them says nothing about left and right. The guidance still
        // runs, because the ripple is on the screen rather than in the ears — `drive` just leaves the
        // tone silent. The nag to plug something in stays, since the ripple is the lesser half of it.
        if !hasHeadphones { say(.headphones, after: headphoneGap) }

        let aligned = depthAligned.update(distance: measurement.depthGap.map { abs($0) }, time: now)
        setPhase(aligned ? .lateral : .depth)
        if let line = pendingPhaseLine, speak(line) {
            pendingPhaseLine = nil
            lastSpoken = Date()
        }

        switch phase {
        case .depth:
            // Phase 1: forward is the right ear, past the object is the left. No spoken direction.
            guard let depthGap = measurement.depthGap else {
                silence()
                return
            }
            drive(
                pan: pan(for: Double(depthGap), easingBelow: Double(Self.depthTolerance)),
                closeness: 1 - min(1, Double(abs(depthGap) / depthRange)),
                // A positive gap is the object still out beyond the fingertip, so the drop rises —
                // something coming up toward the surface. Overshot, it falls back down.
                sweep: depthGap >= 0 ? 1 : -1,
                // Inside the tolerance there is nothing left to correct on this axis, so the screen
                // goes quiet a moment before the phase flips.
                direction: abs(depthGap) <= Self.depthTolerance ? nil : (depthGap > 0 ? .forward : .back)
            )
        case .lateral:
            // Phase 2: steer to the mask's centre, not to `measurement.edge` — the nearest contour
            // point slides along the silhouette as the hand moves, so it isn't a fixed goal.
            let dx = Double(objectCenter.x - measurement.fingertip.x)
            drive(
                pan: pan(for: dx, easingBelow: Double(lateralTolerance)),
                closeness: 1 - min(1, abs(dx) / Double(lateralRange)),
                // Flat: on this axis the side it comes from is the whole message, and a drop that also
                // slid in pitch would be heard as the forward/back one.
                sweep: 0,
                direction: abs(dx) <= Double(lateralTolerance) ? nil : (dx > 0 ? .right : .left)
            )
        case .idle, .contact:
            silence()
        }
    }

    func stop() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        active = false
        phase = .idle
        pendingPhaseLine = nil
        lastCue = nil
        lastSpoken = .distantPast
        foundSoundPlayed = false
        approachPromptPlayed = false
        closePromptPlayed = false
        readReadyHapticPlayed = false
        silence()
    }

    func shutdown() {
        stop()
        audioEngine.stop()
        if let sourceNode {
            audioEngine.detach(sourceNode)
            self.sourceNode = nil
        }
        // No `setActive(false)` here: the session is shared with `Speaker` and `VoiceListener`, and
        // tearing it down took the microphone with it.
    }

    private func silence() {
        silenceTone()
        if cue.direction != nil { cue.direction = nil }
    }

    private func silenceTone() {
        tone.value = 0
        tone.pan = 0
        tone.rippleLevel = 0
    }

    /// Which ear, and how far over. Full `panLimit` once the error is past `easingBelow`, easing to
    /// centre inside it — a signal jittering around zero would otherwise flap the tone between the
    /// ears on every update, which is unreadable and unpleasant. Collapsing to the middle also gives
    /// "you are lined up on this axis" a sound of its own.
    private func pan(for error: Double, easingBelow: Double) -> Float {
        let magnitude = min(1, abs(error) / max(easingBelow, 0.0001))
        return Float(magnitude) * panLimit * (error < 0 ? -1 : 1)
    }

    /// `pan` is -1…1, `closeness` is 0 (as far off as this axis measures) to 1 (lined up). `sweep`
    /// bends the ripple's pitch: +1 rising (forward), -1 falling (back), 0 flat (lateral).
    /// `direction` is the same steer for the screen, and `nil` once this axis is lined up.
    private func drive(pan: Float, closeness: Double, sweep: Float, direction: GuidanceDirection?) {
        let eased = max(0, min(1, closeness))
        let level = Float(0.06 + eased * 0.24)
        if hasHeadphones {
            // Ducked, not muted, while something is talking: in phase 2 the voice and the panned tone
            // play together by design, so the tone has to drop under the words rather than cut out.
            tone.value = isTalking ? level * 0.25 : level
            tone.pan = pan
            // The ripple *is* muted under speech, where the tone is only ducked: a transient cuts
            // through a sentence in a way a steady tone behind it doesn't, and there is nothing in it
            // the tone isn't already saying. Kept to under half the tone otherwise — a short drop reads
            // far louder than its amplitude suggests, so matching the tone would put the ripple on top.
            tone.rippleLevel = isTalking ? 0 : level * 0.45
            tone.ripplePan = pan
            tone.rippleSweep = sweep
            tone.rippleInterval = rippleSlow + (rippleFast - rippleSlow) * Float(eased)
        } else {
            silenceTone()
        }
        // Both guarded: `@Observable` invalidates on the *write*, so assigning the same value still
        // redraws, and this runs ~10 times a second. The intensity is only the ripple's brightness,
        // so a step too small to see isn't worth a frame.
        if cue.direction != direction { cue.direction = direction }
        if abs(cue.intensity - eased) > 0.01 { cue.intensity = eased }
    }

    private func setPhase(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        lastCue = nil
        print("Guidance: phase \(next)")
        // Said once on arrival. Both phases can put the tone in the same ear for different reasons, so
        // this is the only thing telling the user which axis they are on.
        switch next {
        case .depth: pendingPhaseLine = hasHeadphones
            ? "Move your hand forward or back, and follow the tone."
            : "Move your hand forward or back."
        case .lateral: pendingPhaseLine = "Good. Now move left or right."
        case .idle, .contact: pendingPhaseLine = nil
        }
    }

    private static let headphonePorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothLE, .airPlay, .usbAudio
    ]

    private static func routeHasHeadphones() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            headphonePorts.contains($0.portType)
        }
    }

    private func refreshRoute() {
        let connected = Self.routeHasHeadphones()
        guard connected != hasHeadphones else { return }
        hasHeadphones = connected
        print("Guidance: headphones \(connected ? "connected" : "disconnected")")
        if !connected {
            silence()
            setPhase(.idle)
        }
        // Whichever way it went, the next thing to say is about the change, so don't sit out the
        // cooldown left over from before it.
        lastSpoken = .distantPast
    }

    /// The fingertip to steer: the one with a LiDAR reading if either has one, otherwise the one
    /// closest to the outline on screen. `distance` and `depthGap` are set together, so this also
    /// picks the fingertip that phase 1 can measure.
    private func nearest(_ left: EdgeMeasurement?, _ right: EdgeMeasurement?) -> EdgeMeasurement? {
        let all = [left, right].compactMap { $0 }
        if let best = all.filter({ $0.distance != nil }).min(by: { $0.distance! < $1.distance! }) {
            return best
        }
        return all.min { $0.screenGap < $1.screenGap }
    }

    private func say(_ cue: Cue, after wait: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastSpoken) >= wait else { return }
        let changed = cue != lastCue
        guard speak(cue.rawValue) else {
            if now.timeIntervalSince(lastHeldBack) >= 2 {
                lastHeldBack = now
                print("Guidance: held back \"\(cue.rawValue)\" — something else is talking")
            }
            return
        }
        print("Guidance: \(cue.rawValue)")
        lastSpoken = now
        lastCue = cue
        if changed {
            directionFeedback.prepare()
            directionFeedback.impactOccurred()
        }
    }

    /// Returns false when something else is already talking, so a one-shot prompt can be held back and
    /// tried again on the next update instead of being swallowed.
    @discardableResult
    private func speak(_ text: String) -> Bool {
        guard !isTalking else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        utterance.volume = 1.0
        speechSynthesizer.speak(utterance)
        return true
    }

    private var isTalking: Bool { speechSynthesizer.isSpeaking || Speaker.shared.isSpeaking }

    /// `AVAudioEngine` isn't `Sendable`; it's carried off the actor only to be started, and only one
    /// start is ever in flight (`startingTone` guards it).
    private struct Engine: @unchecked Sendable {
        let engine: AVAudioEngine
    }

    private func startToneIfNeeded() {
        guard !startingTone, !audioEngine.isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastToneStart) >= toneRetryGap else { return }
        lastToneStart = now
        startingTone = true
        if sourceNode == nil { buildToneGraph() }
        let box = Engine(engine: audioEngine)
        // Asking for the shared session and starting the engine are both synchronous IPC to the media
        // server, long enough to drop frames on the main actor — same reason `Speaker` does it here.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Speaker.configureAudioSession()
                box.engine.prepare()
                try box.engine.start()
                print("Guidance: proximity tone running")
            } catch {
                print("Guidance: unable to start the proximity tone: \(error)")
            }
            await MainActor.run { self?.startingTone = false }
        }
    }

    private func buildToneGraph() {
        let sampleRate = 44_100.0
        // Stereo, and the standard format is non-interleaved, so buffer 0 is left and buffer 1 right.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        var phase = 0.0
        var renderedVolume = 0.0
        var renderedPan = 0.0
        // 1 kHz, not the 220 Hz this used to be. Panning by amplitude is heard as a level difference
        // between the ears, and that cue is weak below ~500 Hz (low frequencies are placed by phase
        // instead) — a panned 220 Hz tone reads as "slightly louder on one side", not as coming from it.
        let phaseIncrement = 2.0 * Double.pi * 1_000.0 / sampleRate
        let tone = self.tone

        // The ripple: a drop struck every `rippleInterval`, each one an envelope on a sine that glides
        // to its swept pitch. Attack, decay and glide are all one-poles like the pan and level above,
        // so a drop costs a multiply per sample instead of the three `exp` calls the same curves
        // written out would want — this runs 44,100 times a second on the render thread.
        var rippleTimer = 0.0
        var ripplePhase = 0.0
        var rippleOpen = 0.0      // attack, 0 -> 1
        var rippleDecay = 0.0     // tail, 1 -> 0, and 0 between drops
        var rippleFrequency = 0.0
        var rippleTarget = 0.0
        var rippleGain = 0.0
        var rippleSide = 0.0
        // Low enough against the 1 kHz tone to be heard as a separate thing, high enough that panning
        // it still places it: amplitude panning stops carrying direction below ~500 Hz, and the falling
        // drop has to stay above that at the bottom of its bend.
        let rippleBase = 620.0
        let rippleBend = 0.4
        // Struck in ~3 ms (any faster is a click), down to silence in ~0.35 s, and the bend lands in
        // ~80 ms while the drop is still loud enough for the movement to be heard.
        let rippleAttack = 1 - pow(0.02, 1 / (0.003 * sampleRate))
        let rippleFade = pow(0.001, 1 / (0.35 * sampleRate))
        let rippleGlide = 1 - pow(0.02, 1 / (0.08 * sampleRate))

        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                return noErr
            }
            let targetVolume = Double(tone.value)
            let targetPan = Double(tone.pan)
            let rippleLevel = Double(tone.rippleLevel)
            let ripplePan = Double(tone.ripplePan)
            let rippleSweep = Double(tone.rippleSweep)
            // Floored: a zero would strike a drop on every sample, which is a square wave, not a cue.
            let rippleInterval = max(Double(tone.rippleInterval), 0.05)
            for frame in 0..<Int(frameCount) {
                // The pan gets the same one-pole as the level, so crossing between the ears slides
                // across instead of clicking.
                renderedVolume += (targetVolume - renderedVolume) * 0.002
                renderedPan += (targetPan - renderedPan) * 0.002
                // Constant power, so the pair holds its loudness as it crosses the head.
                let theta = (renderedPan + 1) * Double.pi / 4
                let sample = sin(phase) * renderedVolume
                var mixLeft = sample * cos(theta)
                var mixRight = sample * sin(theta)
                phase += phaseIncrement
                if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }

                rippleTimer += 1 / sampleRate
                if rippleLevel <= 0 {
                    // Held at the interval while the cue is off, so the first drop after a silence
                    // lands as guidance resumes rather than up to a second into it.
                    rippleTimer = min(rippleTimer, rippleInterval)
                } else if rippleTimer >= rippleInterval {
                    rippleTimer = 0
                    ripplePhase = 0
                    rippleOpen = 0
                    rippleDecay = 1
                    // Latched for the length of the drop. A direction that changed mid-drop would be
                    // heard as one ripple sliding across the head, which reads as neither side.
                    rippleGain = rippleLevel
                    rippleSide = ripplePan
                    rippleFrequency = rippleBase
                    rippleTarget = rippleBase * (1 + rippleSweep * rippleBend)
                }

                if rippleDecay > 0.0005 {
                    rippleOpen += (1 - rippleOpen) * rippleAttack
                    rippleDecay *= rippleFade
                    rippleFrequency += (rippleTarget - rippleFrequency) * rippleGlide
                    let drop = sin(ripplePhase) * rippleOpen * rippleDecay * rippleGain
                    let side = (rippleSide + 1) * Double.pi / 4
                    mixLeft += drop * cos(side)
                    mixRight += drop * sin(side)
                    ripplePhase += 2.0 * Double.pi * rippleFrequency / sampleRate
                    if ripplePhase >= 2.0 * Double.pi { ripplePhase -= 2.0 * Double.pi }
                } else {
                    rippleDecay = 0
                }

                left[frame] = Float(mixLeft)
                right[frame] = Float(mixRight)
            }
            return noErr
        }

        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        sourceNode = node
    }
}


struct ContentView: View {
    var onBack: () -> Void = {}
    @StateObject private var listener = VoiceListener()
    @StateObject private var arController = ARSessionController()
    // ObjectDetector runs Vision hand pose plus LiDAR distances (YOLO EGOHOS is disabled).
    @StateObject private var detector = ObjectDetector()
    @State private var announcer = InteractionAnnouncer()
    @State private var listenTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var announcementsEnabled = false

    private let backKeywords = ["go back", "back", "return", "previous", "exit", "leave", "quit", "cancel"]
    // Object names can contain words like "back", so only unambiguous phrases work while the user is naming an object.
    private let captureBackKeywords = ["go back", "return"]
    @State private var targetObject: String?
    @StateObject private var segmenter = SegmentationDetector()
    @StateObject private var beepController = DistanceBeepController()

    var body: some View {
        // Full-screen geometry so the overlay covers the same area as the camera preview.
        GeometryReader { geo in
            ZStack {
                MainArt.background.color
                    .ignoresSafeArea()
                ARCameraPreview(session: arController.session)
                    .ignoresSafeArea()

                // Over the camera feed but under the detection overlay: it's a hint at the edges of
                // the screen, not something to read through.
                GuidanceRipple(cue: beepController.cue)
                    .ignoresSafeArea()

                SegmentationOverlay(
                    segments: segmenter.segments,
                    maskImage: segmenter.maskImage,
                    imageSize: segmenter.uprightImageSize,
                    viewSize: geo.size
                ) { contentSize in
                    BoundingBoxOverlay(
                        detections: detector.detections,
                        handPoint: detector.handPoint,
                        leftHandJointPoints: detector.leftHandJointPoints,
                        rightHandJointPoints: detector.rightHandJointPoints,
                        leftHandHoldingObject: detector.leftHandHoldingObject,
                        rightHandHoldingObject: detector.rightHandHoldingObject,
                        viewSize: contentSize,
                        leftHandDistance: detector.leftHandDistance,
                        rightHandDistance: detector.rightHandDistance,
                        selectedPoint: detector.selectedPoint,
                        leftHandCenter: detector.leftHandCenter,
                        rightHandCenter: detector.rightHandCenter,
                        leftHandToPointDistance: detector.leftHandToPointDistance,
                        rightHandToPointDistance: detector.rightHandToPointDistance,
                        leftHandEdge: detector.leftHandEdge,
                        rightHandEdge: detector.rightHandEdge,
                        objectFound: detector.objectFound,
                        approaching: detector.approaching,
                        objectCenter: detector.objectCenter,
                        cameraDistance: detector.cameraDistance,
                        objectClose: detector.objectClose
                    )
                }
            }
            .onAppear {
                beepController.begin()
                arController.onFrame = { frame in
                    detector.process(frame: frame)
                    segmenter.process(frame: frame)
                }
                // `session.run` is heavy and the navigation push is still animating; starting it on top
                // of the push is what made the way in here stutter.
                startTask = Task {
                    try? await Task.sleep(for: .seconds(0.3))
                    guard !Task.isCancelled else { return }
                    arController.start()
                }
            }
            .onReceive(segmenter.$objectMask) { detector.objectMask = $0 }
            .onReceive(
                detector.$leftHandEdge
                    .combineLatest(detector.$rightHandEdge, detector.$objectFound)
                    .combineLatest(detector.$approaching, detector.$objectClose)
            ) { measurements, approaching, objectClose in
                let (leftEdge, rightEdge, objectFound) = measurements
                beepController.update(
                    leftEdge: leftEdge,
                    rightEdge: rightEdge,
                    objectFound: objectFound,
                    approaching: approaching,
                    objectClose: objectClose,
                    objectCenter: segmenter.objectMask?.center
                )
            }
            .onDisappear {
                beepController.shutdown()
                startTask?.cancel()
                arController.pause()
            }
            // Haptic tap when the hand reaches the object (`approaching` latches the first found, so grip
            // flicker while bringing it closer doesn't re-fire), and again once it's close enough to read.
            .sensoryFeedback(.success, trigger: detector.approaching) { _, active in active }
            .sensoryFeedback(.success, trigger: detector.objectClose) { _, close in close }
            .task {
                Speaker.shared.speak("What do you want to find?")
                await listenForTarget()
            }
            .onDisappear {
                listenTask?.cancel()
                listener.stop()
            }
            .onChange(of: detector.objectFound) { _, found in
                guard announcementsEnabled else { return }
                announcer.update(confidence: found ? 1 : 0)
            }
        }
        .ignoresSafeArea()
    }

    private func listenForTarget() async {
        await Speaker.shared.waitUntilIdle()
        guard !Task.isCancelled else { return }
        await listener.start(
            commands: ["back": captureBackKeywords],
            onCommand: { _ in onBack() },
            onUtterance: handleTarget
        )
    }

    private func handleTarget(_ text: String) {
        let objectName = TargetParser.extract(from: text)
        guard !objectName.isEmpty else {
            Speaker.shared.speak("Sorry, I didn't catch that. What do you want to find?")
            listenTask = Task { await listenForTarget() }
            return
        }

        targetObject = objectName
        Speaker.shared.speak("Please place your hand forward, I will guide you to the \(objectName).")
        listenTask = Task {
            await Speaker.shared.waitUntilIdle()
            guard !Task.isCancelled else { return }
            announcementsEnabled = true
            beepController.setTarget(objectName)
            await listener.start(commands: ["back": backKeywords]) { _ in onBack() }
        }
    }
}

struct SegmentationOverlay<Extra: View>: View {
    let segments: [Segment]
    let maskImage: CGImage?
    let imageSize: CGSize
    let viewSize: CGSize
    // Extra layers drawn in the same aspect-filled image canvas (e.g. hand pose joints).
    @ViewBuilder var extra: (CGSize) -> Extra

    // ARSCNView shows the camera image aspect-filled (cropped to fill the screen), so draw
    // everything in an image-sized canvas scaled the same way, then clip to the view.
    private var contentSize: CGSize {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    var body: some View {
        let size = contentSize
        ZStack {
            if let maskImage {
                Image(decorative: maskImage, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .opacity(0.45)
            }

            ForEach(segments) { segment in
                let rect = CGRect(
                    x: segment.boundingBox.minX * size.width,
                    y: (1 - segment.boundingBox.maxY) * size.height,
                    width: segment.boundingBox.width * size.width,
                    height: segment.boundingBox.height * size.height
                )
                // Box only: the class name rides in the debug readout at the top of the screen, where
                // it isn't sitting on top of the object, the waves and the distance labels.
                Rectangle()
                    .stroke(Color(cgColor: segment.color), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

            extra(size)
        }
        .frame(width: size.width, height: size.height)
        .frame(width: viewSize.width, height: viewSize.height)
        .clipped()
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
