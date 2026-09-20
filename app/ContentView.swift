import SwiftUI
import Combine
import AVFoundation
import AudioToolbox
import UIKit

final class DistanceBeepController: ObservableObject {
    private let audioEngine = AVAudioEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let directionFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let readReadyFeedback = UINotificationFeedbackGenerator()
    private var sourceNode: AVAudioSourceNode?
    private var toneVolume: Float = 0.08
    private var isPlaying = false
    private var promptStarted = false
    private var isHorizontallyAligned = false
    private var foundSoundPlayed = false
    private var approachPromptPlayed = false
    private var closePromptPlayed = false
    private var readReadyHapticPlayed = false
    private let samePlaneDistance: Float = 0.08
    private let coordinateTolerance: CGFloat = 0.08

    func startPrompt() {
        guard !promptStarted else { return }
        promptStarted = true
        configureSpeechAudioSession()
        speak("Move your hand forward until the tone gets louder.")
    }

    func update(
        leftEdge: EdgeMeasurement?,
        rightEdge: EdgeMeasurement?,
        objectFound: Bool,
        approaching: Bool,
        objectClose: Bool
    ) {
        if objectFound {
            if !foundSoundPlayed {
                foundSoundPlayed = true
                AudioServicesPlaySystemSound(1057)
            }
            stopTone()

            if approaching && !objectClose && !approachPromptPlayed {
                approachPromptPlayed = true
                speak("Hold the bottle closer to the screen until it is close enough to read.")
            } else if objectClose && !closePromptPlayed {
                closePromptPlayed = true
                if !readReadyHapticPlayed {
                    readReadyHapticPlayed = true
                    readReadyFeedback.prepare()
                    readReadyFeedback.notificationOccurred(.success)
                }
                speak("The object is close enough to read.")
            }
            return
        }

        approachPromptPlayed = false
        closePromptPlayed = false
        readReadyHapticPlayed = false

        let measurements: [EdgeMeasurement] = [leftEdge, rightEdge].compactMap { $0 }
        guard let measurement = measurements
            .filter({ $0.distance != nil })
            .min(by: { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }),
              let distance = measurement.distance else {
            stopTone()
            return
        }

        if speechSynthesizer.isSpeaking {
            stopTone()
            return
        }

        let xGap = measurement.edge.x - measurement.fingertip.x
        let yGap = abs(measurement.edge.y - measurement.fingertip.y)
        if distance <= samePlaneDistance {
            if !isHorizontallyAligned {
                isHorizontallyAligned = true
                if abs(xGap) > coordinateTolerance || yGap <= coordinateTolerance {
                    directionFeedback.prepare()
                    directionFeedback.impactOccurred()
                    let direction = xGap < 0 ? "left" : "right"
                    speak("Move your hand \(direction) until you have the object.")
                }
            }
            toneVolume = 0
            return
        }

        if distance > samePlaneDistance + 0.04 {
            isHorizontallyAligned = false
        }

        let closeness = max(0, min(1, 1 - distance / 0.8))
        toneVolume = 0.04 + closeness * 0.16
        startToneIfNeeded()
    }

    func stop() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        promptStarted = false
        isHorizontallyAligned = false
        foundSoundPlayed = false
        approachPromptPlayed = false
        closePromptPlayed = false
        readReadyHapticPlayed = false
        stopTone()
    }

    func shutdown() {
        stop()
        tearDownAudio()
    }

    private func stopTone() {
        toneVolume = 0
    }

    private func tearDownAudio() {
        guard isPlaying else { return }
        audioEngine.stop()
        if let sourceNode {
            audioEngine.detach(sourceNode)
            self.sourceNode = nil
        }
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        utterance.volume = 1.0
        speechSynthesizer.speak(utterance)
    }

    private func configureSpeechAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audioSession.setActive(true)
    }

    private func startToneIfNeeded() {
        guard !isPlaying else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)

            let sampleRate = 44_100.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                return
            }
            var phase = 0.0
            var renderedVolume = 0.0
            let phaseIncrement = 2.0 * Double.pi * 220.0 / sampleRate

            let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for frame in 0..<Int(frameCount) {
                    let targetVolume = Double(self?.toneVolume ?? 0)
                    renderedVolume += (targetVolume - renderedVolume) * 0.002
                    let sample = Float(sin(phase) * renderedVolume)
                    phase += phaseIncrement
                    if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                    if buffers.count > 0 { buffers[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
                }
                return noErr
            }

            audioEngine.attach(node)
            audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
            audioEngine.prepare()
            try audioEngine.start()
            sourceNode = node
            isPlaying = true
        } catch {
            print("Unable to start directional proximity buzz: \(error)")
            stop()
        }
    }

    deinit {
        shutdown()
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
                ARCameraPreview(session: arController.session)
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

                Text(segmenter.status)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
                    .padding(6)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
            }
            .onAppear {
                beepController.startPrompt()
                arController.onFrame = { frame in
                    detector.process(frame: frame)
                    segmenter.process(frame: frame)
                }
                arController.start()
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
                    objectClose: objectClose
                )
            }
            .onDisappear {
                beepController.shutdown()
            }
            // Haptic tap when the hand reaches the object (`approaching` latches the first found, so grip
            // flicker while bringing it closer doesn't re-fire), and again once it's close enough to read.
            .sensoryFeedback(.success, trigger: detector.approaching) { _, active in active }
            .sensoryFeedback(.success, trigger: detector.objectClose) { _, close in close }
            .overlay(alignment: .bottom) {
                if listener.isListening {
                    ListeningIndicator()
                }
            }
            .animation(.easeInOut, value: listener.isListening)
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
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color(cgColor: segment.color), lineWidth: 2)
                    Text("\(segment.label) \(Int(segment.confidence * 100))%")
                        .font(.caption)
                        .padding(2)
                        .background(Color(cgColor: segment.color))
                        .foregroundColor(.black)
                }
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
