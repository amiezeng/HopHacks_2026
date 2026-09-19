import SwiftUI

struct ContentView: View {
    var onBack: () -> Void = {}
    @StateObject private var listener = VoiceListener()
    @StateObject private var arController = ARSessionController()
    @StateObject private var detector = ObjectDetector()
    @State private var announcer = InteractionAnnouncer()
    @State private var listenTask: Task<Void, Never>?
    @State private var announcementsEnabled = false

    private let backKeywords = ["go back", "back", "return", "previous", "exit", "leave", "quit", "cancel"]
    // Object names can contain words like "back", so only unambiguous phrases work while the user is naming an object.
    private let captureBackKeywords = ["go back", "return"]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ARCameraPreview(session: arController.session)
                    .ignoresSafeArea()

                BoundingBoxOverlay(
                    detections: detector.detections,
                    handPoint: detector.handPoint,
                    leftHandJointPoints: detector.leftHandJointPoints,
                    rightHandJointPoints: detector.rightHandJointPoints,
                    leftHandHoldingObject: detector.leftHandHoldingObject,
                    rightHandHoldingObject: detector.rightHandHoldingObject,
                    viewSize: geo.size,
                    distance: detector.distance
                )
            }
            .onAppear {
                arController.onFrame = { frame in
                    detector.process(frame: frame)
                }
                arController.start()
            }
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
            .onChange(of: detector.interactionConfidence) { _, confidence in
                guard announcementsEnabled else { return }
                announcer.update(confidence: confidence)
            }
        }
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
        let target = TargetParser.extract(from: text)
        guard !target.isEmpty else {
            Speaker.shared.speak("Sorry, I didn't catch that. What do you want to find?")
            listenTask = Task { await listenForTarget() }
            return
        }

        detector.targetLabel = target
        Speaker.shared.speak("Please place your hand forward, I will guide you to the \(target).")
        listenTask = Task {
            await Speaker.shared.waitUntilIdle()
            guard !Task.isCancelled else { return }
            announcementsEnabled = true
            await listener.start(commands: ["back": backKeywords]) { _ in onBack() }
        }
    }
}

#Preview {
    ContentView()
}
