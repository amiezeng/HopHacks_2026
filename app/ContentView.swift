import SwiftUI

struct ContentView: View {
    var onBack: () -> Void = {}
    @StateObject private var listener = VoiceListener()
    @StateObject private var arController = ARSessionController()
    @StateObject private var detector = ObjectDetector()
    @State private var announcer = InteractionAnnouncer()

    private let backKeywords = ["go back", "back", "return", "previous", "exit", "leave", "quit", "cancel"]

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
                await Speaker.shared.waitUntilIdle()
                guard !Task.isCancelled else { return }
                await listener.start(commands: ["back": backKeywords]) { _ in onBack() }
            }
            .onDisappear { listener.stop() }
            .onChange(of: detector.interactionConfidence) { _, confidence in
                announcer.update(confidence: confidence)
            }
        }
    }
}

#Preview {
    ContentView()
}
