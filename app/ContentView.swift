import SwiftUI

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
                arController.onFrame = { frame in
                    detector.process(frame: frame)
                    segmenter.process(frame: frame)
                }
                arController.start()
            }
            .onReceive(segmenter.$objectMask) { detector.objectMask = $0 }
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
