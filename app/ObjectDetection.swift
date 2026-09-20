import Foundation
import Combine
import Vision
import CoreML
import ARKit

struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect // normalized 0-1, Vision coords (origin bottom-left)
}

struct EdgeMeasurement {
    let fingertip: CGPoint // index fingertip, normalized 0-1, Vision coords
    let edge: CGPoint    // nearest point on the mask's outer contour, Vision coords
    let distance: Float? // meters, 3D via LiDAR; nil when depth is unavailable
    // Fingertip overlaps the object on screen: distance is then the depth gap to the surface behind it.
    let insideMask: Bool
    // 2D fingertip -> contour distance (normalized), 0 when inside the mask. Used when LiDAR is missing.
    let screenGap: CGFloat
    // Signed depth difference along the camera axis (meters): object minus fingertip, with the same
    // reach correction as `distance`. Positive means the object is still beyond the fingertip, so the
    // hand has to go forward; negative means the hand has overshot past it. `distance` is unsigned and
    // can't tell those apart, which is what forward/back guidance needs. nil without LiDAR depth.
    let depthGap: Float?
}

// Debounced "hand reached the object" state from a noisy distance stream. Measured distance never
// reaches 0 at contact (finger thickness, LiDAR noise), so contact is a small threshold held briefly,
// and letting go needs a larger one (hysteresis) so the state doesn't flicker around the threshold.
struct FoundTracker {
    var contactDistance: Float = 0.025  // meters (≈1 in): counts as touching
    var releaseDistance: Float = 0.05   // meters (≈2 in): counts as clearly let go
    var dwell: TimeInterval = 0.3       // contact must last this long to become found
    var release: TimeInterval = 0.5     // separation must last this long to clear found
    var lostTimeout: TimeInterval = 1.5 // no measurement for this long resets
    private(set) var found = false
    private var pendingSince: TimeInterval? // start of the current run toward flipping `found`
    private var lastMeasurement: TimeInterval?

    // distance: meters, nil when there's no measurement; time: seconds (e.g. ARFrame.timestamp).
    mutating func update(distance: Float?, time: TimeInterval) -> Bool {
        guard let distance else {
            // Grasping often hides the object, so a missing measurement holds the state until it times out.
            if let last = lastMeasurement, time - last >= lostTimeout {
                found = false
                pendingSince = nil
                lastMeasurement = nil
            }
            return found
        }
        lastMeasurement = time

        // Not found: time spent touching. Found: time spent clearly apart.
        let flipping = found ? distance >= releaseDistance : distance <= contactDistance
        if !flipping {
            pendingSince = nil
        } else if let since = pendingSince {
            if time - since >= (found ? release : dwell) {
                found.toggle()
                pendingSince = nil
            }
        } else {
            pendingSince = time
        }
        return found
    }
}

extension VNHumanHandPoseObservation.JointName {
    // Ordered to trace the outer perimeter of the hand
    static var outlineOrder: [VNHumanHandPoseObservation.JointName] {
        [
            .wrist,
            .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip,
            .wrist
        ]
    }
}

class ObjectDetector: ObservableObject {
    @Published var detections: [Detection] = []
    @Published var handPoint: CGPoint? = nil   // normalized 0-1, Vision coords
    @Published var handJointPoints: [CGPoint] = []
    @Published var leftHandJointPoints: [CGPoint] = []
    @Published var rightHandJointPoints: [CGPoint] = []
    @Published var leftHandHoldingObject = false
    @Published var rightHandHoldingObject = false
    @Published var distance: Float? = nil
    @Published var leftHandDistance: Float? = nil   // meters, LiDAR depth at left_hand box center
    @Published var rightHandDistance: Float? = nil  // meters, LiDAR depth at right_hand box center
    // User-tapped point, normalized 0-1, Vision coords. Distances below are 3D, hand center -> point.
    @Published var selectedPoint: CGPoint? = nil {
        didSet { tryComputeDistance() }
    }
    // Center joint (middle-finger knuckle, .middleMCP) of each hand from Vision pose, Vision coords.
    @Published var leftHandCenter: CGPoint? = nil
    @Published var rightHandCenter: CGPoint? = nil
    @Published var leftHandToPointDistance: Float? = nil
    @Published var rightHandToPointDistance: Float? = nil
    // Closest fingertip (of all five) -> nearest point on the segmentation mask's outer edge.
    @Published var leftHandEdge: EdgeMeasurement? = nil
    @Published var rightHandEdge: EdgeMeasurement? = nil
    // True while any fingertip of either hand is touching the object (see FoundTracker).
    @Published var objectFound = false
    private var foundTracker = FoundTracker()
    // After `found`, the user brings the object to the camera until its label is close enough to read.
    // Latched on the first `found`: a hand near the camera often loses pose tracking, which would drop
    // `found` mid-approach. Cleared once the object has been out of view for `approachLostTimeout`.
    @Published var approaching = false
    // Mask center (Vision coords) and straight-line camera -> center distance (meters, LiDAR), while approaching.
    @Published var objectCenter: CGPoint? = nil
    @Published var cameraDistance: Float? = nil
    // Debounced cameraDistance <= readDistance.
    @Published var objectClose = false
    // At 25 cm a 1920x1440 frame resolves ~2 mm label text at ~10 px (enough for OCR) and a ~20 cm bottle
    // still fits in frame. Much nearer than that the wide camera can't focus.
    static let readDistance: Float = 0.25     // meters (≈10 in)
    static let tooCloseDistance: Float = 0.15 // meters (≈6 in)
    // Everything measured here is in meters and everything shown to the user is in inches, so the
    // conversion lives in one place: the labels on the overlay and the blob at the bottom of the screen
    // are the same numbers and must not be able to round differently.
    static func inches(_ meters: Float?) -> String {
        guard let meters else { return "—" }
        return String(format: "%.1f in", meters * 39.3701)
    }
    // Same debounce as `found`, on the camera distance with read-range thresholds.
    private static func makeCloseTracker() -> FoundTracker {
        var tracker = FoundTracker()
        tracker.contactDistance = readDistance
        tracker.releaseDistance = 0.30 // ≈12 in
        return tracker
    }
    private var closeTracker = ObjectDetector.makeCloseTracker()
    private var lastObjectSeen: TimeInterval = 0
    private let approachLostTimeout: TimeInterval = 2
    // 2D fallback when no fingertip has LiDAR depth. A finger touching a can's side sits just outside
    // its mask, so contact allows a small margin; a finger merely in front of the object is also
    // "inside" on screen, so contact needs several fingertips of one hand (a grasp).
    private let screenContactMargin: CGFloat = 0.02 // normalized image units
    private let screenReleaseMargin: CGFloat = 0.06 // every fingertip farther than this = clearly apart
    private let screenContactFingers = 2
    // A fingertip plus the joint below it (DIP, or IP for the thumb), Vision coords.
    private struct Finger {
        let tip: CGPoint
        let dip: CGPoint?
        // Meters from the joint used as `tip` out to the real fingertip (0 when the tip itself was detected).
        // Subtracted from measured distances so a stand-in knuckle can still register contact.
        let reach: Float
    }
    // Approximate joint -> fingertip length for each position in a fingerJoints chain.
    private static let jointReach: [Float] = [0, 0.012, 0.03, 0.05]
    // Every confident hand joint (no forearm points), per hand; used to hold `found` through a grip.
    private var leftJoints: [CGPoint] = []
    private var rightJoints: [CGPoint] = []
    // Each finger's joints, fingertip first down to the knuckle. Vision often misses the tip when it's
    // pressed against or hidden behind the object, so the most distal confident joint stands in for it.
    private static let fingerJoints: [[VNHumanHandPoseObservation.JointName]] = [
        [.thumbTip, .thumbIP, .thumbMP, .thumbCMC],
        [.indexTip, .indexDIP, .indexPIP, .indexMCP],
        [.middleTip, .middleDIP, .middlePIP, .middleMCP],
        [.ringTip, .ringDIP, .ringPIP, .ringMCP],
        [.littleTip, .littleDIP, .littlePIP, .littleMCP],
    ]
    // All confidently-detected fingertips per hand; LiDAR can drop out on any single one.
    private var leftFingers: [Finger] = []
    private var rightFingers: [Finger] = []
    // Latest mask from SegmentationDetector (set by ContentView).
    var objectMask: ObjectMask? = nil {
        didSet { tryComputeDistance() }
    }

    private var objectRequest: VNCoreMLRequest?
    private var handRequest: VNDetectHumanHandPoseRequest?
    private var latestFrame: ARFrame?
    private let detectionQueue = DispatchQueue(label: "com.hophacks.objectdetector.detectionQueue", qos: .userInitiated)
    private let minDetectionInterval: TimeInterval = 0.1
    private var lastDetectionTimestamp: TimeInterval = 0
    // Upright (portrait) size of the image last sent to YOLO, used to undo scaleFit letterboxing.
    private var uprightImageSize = CGSize(width: 1440, height: 1920)
    private let modelInputSize: CGFloat = 640
    private let yoloClassNames = [
        "left_hand",
        "right_hand",
        "1st_order_interacting_object_left",
        "1st_order_interacting_object_right",
        "1st_order_interacting_object_both",
        "2nd_order_interacting_object_left",
        "2nd_order_interacting_object_right",
        "2nd_order_interacting_object_both"
    ]

    /// Candidates for the hand/object model, in order; the first one bundled is used.
    static let objectModelNames = ["YOLOv10n_EGOHOS", "YOLOv10n_EGOHO", "YOLOv10nEGOHO", "yolo11n", "yolo11n_EGOHO"]

    // YOLO is off; Vision hand pose drives the hand positions. Flip these to switch back.
    var yoloEnabled = false
    var handPoseEnabled = true

    init() {
        setupObjectDetection()
        setupHandDetection()
    }

    private func setupObjectDetection() {
        do {
            let vnModel = try loadVNCoreMLModel()

            let req = VNCoreMLRequest(model: vnModel) { [weak self] request, error in
                if let error = error {
                    print("Detection error: \(error)")
                    return
                }
                guard let feature = request.results?.first as? VNCoreMLFeatureValueObservation,
                      let output = feature.featureValue.multiArrayValue else {
                    return
                }
                let mapped = self?.decodeYOLOOutput(output) ?? []

                DispatchQueue.main.async {
                    self?.detections = mapped
                    self?.updateHoldingHands(from: mapped)
                    self?.tryComputeDistance()
                }
            }
            req.imageCropAndScaleOption = .scaleFit
            self.objectRequest = req
        } catch {
            print("Failed to load model: \(error)")
        }
    }

    // Loaded through ModelStore, which `Preloader` fills at launch, so this init doesn't read weights
    // off disk while the screen it belongs to is being pushed.
    private func loadVNCoreMLModel() throws -> VNCoreMLModel {
        if let model = try ModelStore.model(names: Self.objectModelNames) {
            return try VNCoreMLModel(for: model)
        }

        let ptFileExists = Bundle.main.url(forResource: "YOLOv10n_EGOHOS", withExtension: "pt") != nil
        let message = ptFileExists
            ? "A YOLO .pt checkpoint was found, but CoreML requires a converted .mlpackage or .mlmodel in the app bundle. Convert the model before running the app."
            : "No YOLO CoreML model was found in the app bundle. Add a converted model such as YOLOv10n_EGOHOS.mlpackage or YOLOv10n_EGOHOS.mlmodel to the app target."

        throw NSError(
            domain: "ObjectDetection",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func decodeYOLOOutput(_ output: MLMultiArray) -> [Detection] {
        guard output.shape.count == 3 else { return [] }

        let channels = output.shape[1].intValue
        let candidateCount = output.shape[2].intValue
        let classCount = min(yoloClassNames.count, channels - 4)
        guard classCount > 0 else { return [] }

        let scale = min(modelInputSize / uprightImageSize.width, modelInputSize / uprightImageSize.height)
        let scaledWidth = uprightImageSize.width * scale
        let scaledHeight = uprightImageSize.height * scale
        let padX = (modelInputSize - scaledWidth) / 2
        let padY = (modelInputSize - scaledHeight) / 2

        var candidates: [Detection] = []
        candidates.reserveCapacity(candidateCount / 10)

        for candidateIndex in 0..<candidateCount {
            var bestClass = 0
            var bestConfidence: Float = 0

            for classIndex in 0..<classCount {
                let confidence = output[(4 + classIndex) * candidateCount + candidateIndex].floatValue
                if confidence > bestConfidence {
                    bestConfidence = confidence
                    bestClass = classIndex
                }
            }

            guard bestConfidence >= 0.35 else { continue }

            // Undo .scaleFit letterboxing: the image is centered inside the square model input.
            let centerX = (CGFloat(output[candidateIndex].floatValue) - padX) / scaledWidth
            let centerY = (CGFloat(output[candidateCount + candidateIndex].floatValue) - padY) / scaledHeight
            let width = CGFloat(output[(2 * candidateCount) + candidateIndex].floatValue) / scaledWidth
            let height = CGFloat(output[(3 * candidateCount) + candidateIndex].floatValue) / scaledHeight

            let minX = max(0, centerX - width / 2)
            let maxX = min(1, centerX + width / 2)
            let minY = max(0, centerY - height / 2)
            let maxY = min(1, centerY + height / 2)
            guard maxX > minX, maxY > minY else { continue }

            candidates.append(
                Detection(
                    label: displayLabel(for: yoloClassNames[bestClass]),
                    confidence: bestConfidence,
                    boundingBox: CGRect(
                        x: minX,
                        y: 1 - maxY,
                        width: maxX - minX,
                        height: maxY - minY
                    )
                )
            )
        }

        return nonMaximumSuppression(candidates)
    }

    private func updateHoldingHands(from detections: [Detection]) {
        let interactionLabels = detections.map(\.label).filter { $0.contains("interacting_object") }
        leftHandHoldingObject = interactionLabels.contains { $0.hasSuffix("_left") || $0.hasSuffix("_both") }
        rightHandHoldingObject = interactionLabels.contains { $0.hasSuffix("_right") || $0.hasSuffix("_both") }
    }

    private func displayLabel(for label: String) -> String {
        switch label {
        case "left_hand":
            return "right_hand"
        case "right_hand":
            return "left_hand"
        case let label where label.hasSuffix("_left"):
            return String(label.dropLast(5)) + "_right"
        case let label where label.hasSuffix("_right"):
            return String(label.dropLast(6)) + "_left"
        default:
            return label
        }
    }

    private func nonMaximumSuppression(_ candidates: [Detection]) -> [Detection] {
        var remaining = candidates.sorted { $0.confidence > $1.confidence }
        var kept: [Detection] = []

        while let candidate = remaining.first {
            remaining.removeFirst()
            kept.append(candidate)
            remaining.removeAll { other in
                other.label == candidate.label && intersectionOverUnion(candidate.boundingBox, other.boundingBox) > 0.45
            }
        }

        return kept
    }

    private func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = first.width * first.height + second.width * second.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private func setupHandDetection() {
        let request = VNDetectHumanHandPoseRequest { [weak self] request, error in
            if let error = error {
                print("Hand detection error: \(error)")
                return
            }
            guard let results = request.results as? [VNHumanHandPoseObservation],
                  !results.isEmpty else {
                DispatchQueue.main.async {
                    self?.handPoint = nil
                    self?.handJointPoints = []
                    self?.leftHandJointPoints = []
                    self?.rightHandJointPoints = []
                    self?.leftHandCenter = nil
                    self?.rightHandCenter = nil
                    self?.leftFingers = []
                    self?.rightFingers = []
                    self?.leftJoints = []
                    self?.rightJoints = []
                    self?.tryComputeDistance()
                }
                return
            }

            var leftPoints: [CGPoint] = []
            var rightPoints: [CGPoint] = []
            var firstWrist: CGPoint?
            var leftCenter: CGPoint?
            var rightCenter: CGPoint?
            var leftFingers: [Finger] = []
            var rightFingers: [Finger] = []
            var leftJoints: [CGPoint] = []
            var rightJoints: [CGPoint] = []

            for observation in results {
                let outline = self?.handOutlinePoints(from: observation) ?? []
                guard outline.count > 2 else { continue }

                var center: CGPoint?
                if let joint = try? observation.recognizedPoint(.middleMCP), joint.confidence > 0.3 {
                    center = CGPoint(x: joint.location.x, y: joint.location.y)
                }

                let joints = ((try? observation.recognizedPoints(.all)) ?? [:]).values
                    .filter { $0.confidence > 0.3 }.map(\.location)
                let fingers: [Finger] = ObjectDetector.fingerJoints.compactMap { joints in
                    let points = joints.map { name -> CGPoint? in
                        guard let p = try? observation.recognizedPoint(name), p.confidence > 0.3 else { return nil }
                        return p.location
                    }
                    // Most distal detected joint acts as the "tip"; the next detected joint below it anchors depth.
                    guard let tipIndex = points.firstIndex(where: { $0 != nil }), let tip = points[tipIndex] else { return nil }
                    let below = points[(tipIndex + 1)...].first { $0 != nil } ?? nil
                    return Finger(tip: tip, dip: below, reach: ObjectDetector.jointReach[tipIndex])
                }

                if observation.chirality == .left {
                    leftPoints = outline
                    leftCenter = center
                    leftFingers = fingers
                    leftJoints = joints
                } else {
                    rightPoints = outline
                    rightCenter = center
                    rightFingers = fingers
                    rightJoints = joints
                }

                if firstWrist == nil,
                   let wrist = try? observation.recognizedPoint(.wrist),
                   wrist.confidence > 0.5 {
                    firstWrist = CGPoint(x: wrist.location.x, y: wrist.location.y)
                }
            }

            DispatchQueue.main.async {
                self?.leftHandJointPoints = leftPoints
                self?.rightHandJointPoints = rightPoints
                self?.handJointPoints = leftPoints.isEmpty ? rightPoints : leftPoints
                self?.handPoint = firstWrist
                self?.leftHandCenter = leftCenter
                self?.rightHandCenter = rightCenter
                self?.leftFingers = leftFingers
                self?.rightFingers = rightFingers
                self?.leftJoints = leftJoints
                self?.rightJoints = rightJoints
                self?.tryComputeDistance()
            }
        }
        request.maximumHandCount = 2
        self.handRequest = request
    }

    private func handOutlinePoints(from observation: VNHumanHandPoseObservation) -> [CGPoint] {
        var points: [CGPoint] = []
        for joint in VNHumanHandPoseObservation.JointName.outlineOrder {
            if let point = try? observation.recognizedPoint(joint), point.confidence > 0.3 {
                points.append(CGPoint(x: point.location.x, y: point.location.y))
            }
        }

        if let wrist = try? observation.recognizedPoint(.wrist),
           let middleMCP = try? observation.recognizedPoint(.middleMCP),
           wrist.confidence > 0.3,
           middleMCP.confidence > 0.3 {
            let direction = CGPoint(
                x: wrist.location.x - middleMCP.location.x,
                y: wrist.location.y - middleMCP.location.y
            )
            let length = max(sqrt(direction.x * direction.x + direction.y * direction.y), 0.001)
            let unit = CGPoint(x: direction.x / length, y: direction.y / length)
            let perpendicular = CGPoint(x: -unit.y * 0.05, y: unit.x * 0.05)
            let forearmCenter = CGPoint(
                x: wrist.location.x + unit.x * 0.12,
                y: wrist.location.y + unit.y * 0.12
            )

            points.append(CGPoint(x: forearmCenter.x + perpendicular.x, y: forearmCenter.y + perpendicular.y))
            points.append(CGPoint(x: forearmCenter.x - perpendicular.x, y: forearmCenter.y - perpendicular.y))
        }

        return points
    }

    // Called once per ARFrame update, but throttled so the UI stays responsive.
    func process(frame: ARFrame) {
        latestFrame = frame

        let now = Date().timeIntervalSince1970
        guard now - lastDetectionTimestamp >= minDetectionInterval else {
            return
        }
        lastDetectionTimestamp = now

        detectionQueue.async { [weak self] in
            guard let self else { return }
            if self.yoloEnabled {
                self.detectObjects(in: frame.capturedImage)
            }
            if self.handPoseEnabled {
                self.detectHand(in: frame.capturedImage)
            }
        }
    }

    private func detectObjects(in pixelBuffer: CVPixelBuffer) {
        guard let request = objectRequest else {
            print("Object detection request is not available because the CoreML model could not be loaded.")
            return
        }
        // .right rotates the landscape sensor buffer to portrait, so width/height swap.
        uprightImageSize = CGSize(
            width: CVPixelBufferGetHeight(pixelBuffer),
            height: CVPixelBufferGetWidth(pixelBuffer)
        )
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        do {
            try handler.perform([request])
        } catch {
            print("Failed to perform object detection: \(error)")
        }
    }

    private func detectHand(in pixelBuffer: CVPixelBuffer) {
        guard let request = handRequest else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        do {
            try handler.perform([request])
        } catch {
            print("Failed to perform hand detection: \(error)")
        }
    }

    // Samples LiDAR depth at the center of each hand's YOLO bounding box.
    private func tryComputeDistance() {
        guard let frame = latestFrame else { return }

        leftHandDistance = handDepth(label: "left_hand", frame: frame)
        rightHandDistance = handDepth(label: "right_hand", frame: frame)
        distance = [leftHandDistance, rightHandDistance].compactMap { $0 }.min()

        if let selectedPoint, let target = cameraSpacePoint(at: selectedPoint, frame: frame) {
            leftHandToPointDistance = handToPoint(label: "left_hand", target: target, frame: frame)
            rightHandToPointDistance = handToPoint(label: "right_hand", target: target, frame: frame)
        } else {
            leftHandToPointDistance = nil
            rightHandToPointDistance = nil
        }

        let leftMeasurements = leftFingers.compactMap { edgeMeasurement(from: $0, frame: frame) }
        let rightMeasurements = rightFingers.compactMap { edgeMeasurement(from: $0, frame: frame) }
        leftHandEdge = closestEdgeMeasurement(leftMeasurements)
        rightHandEdge = closestEdgeMeasurement(rightMeasurements)

        var closest = [leftHandEdge?.distance, rightHandEdge?.distance].compactMap { $0 }.min()
        if closest == nil {
            closest = screenContactDistance(hands: [leftMeasurements, rightMeasurements])
        }
        // A gripping hand hides its fingertips and blocks LiDAR, so with nothing else to go on, a hand
        // still overlapping the object keeps an existing `found`. It never starts one: a hand merely in
        // front of the object looks the same on screen.
        if closest == nil, objectFound, handOverlapsObject() {
            closest = 0
        }
        let found = foundTracker.update(distance: closest, time: frame.timestamp)
        if found != objectFound { objectFound = found }
        updateApproach(frame: frame)
    }

    // Once found: camera -> object distance at the mask center, debounced into `objectClose`.
    private func updateApproach(frame: ARFrame) {
        let time = frame.timestamp
        if objectFound && !approaching {
            approaching = true
            lastObjectSeen = time
        }
        guard approaching else { return }

        guard let mask = objectMask else {
            if time - lastObjectSeen >= approachLostTimeout {
                approaching = false
                objectCenter = nil
                cameraDistance = nil
                objectClose = false
                closeTracker = ObjectDetector.makeCloseTracker()
            }
            return
        }
        lastObjectSeen = time

        objectCenter = mask.center
        // Wide patch, object pixels only: the hand holding it may cover part of the center.
        cameraDistance = cameraSpacePoint(at: mask.center, frame: frame, radius: 4, include: { mask.contains($0) })
            .map { simd_length($0) }
        let close = closeTracker.update(distance: cameraDistance, time: time)
        if close != objectClose { objectClose = close }
    }

    // LiDAR-free stand-in distance for FoundTracker from 2D fingertip/mask overlap: 0 when one hand has
    // enough fingertips on the mask, the release distance when every fingertip is clearly away, and nil
    // (hold the current state) in between or when there's nothing to measure.
    private func handOverlapsObject() -> Bool {
        guard let mask = objectMask else { return false }
        return (leftJoints + rightJoints).contains { joint in
            if mask.contains(joint) { return true }
            guard let edge = mask.nearestEdgePoint(to: joint) else { return false }
            return hypot(joint.x - edge.x, joint.y - edge.y) <= screenContactMargin
        }
    }

    private func screenContactDistance(hands: [[EdgeMeasurement]]) -> Float? {
        let all = hands.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        if hands.contains(where: { $0.filter { $0.screenGap <= screenContactMargin }.count >= screenContactFingers }) {
            return 0
        }
        if all.allSatisfy({ $0.screenGap > screenReleaseMargin }) {
            return foundTracker.releaseDistance
        }
        return nil
    }

    // Keeps the closest fingertip with a LiDAR reading. If none has depth, falls back to the
    // fingertip nearest the mask edge on screen so the overlay still shows something.
    private func closestEdgeMeasurement(_ measurements: [EdgeMeasurement]) -> EdgeMeasurement? {
        if let best = measurements.filter({ $0.distance != nil }).min(by: { $0.distance! < $1.distance! }) {
            return best
        }
        return measurements.min { hypot($0.fingertip.x - $0.edge.x, $0.fingertip.y - $0.edge.y)
                                < hypot($1.fingertip.x - $1.edge.x, $1.fingertip.y - $1.edge.y) }
    }

    // Fingertip -> object distance with LiDAR. Outside the mask: 3D distance to the nearest point on the
    // mask's outer contour. Inside it (hand overlapping the object on screen): the nearest contour point
    // would measure sideways to the silhouette, so use the depth gap to the surface behind the fingertip.
    private func edgeMeasurement(from finger: Finger, frame: ARFrame) -> EdgeMeasurement? {
        guard let mask = objectMask,
              let edge = mask.nearestEdgePoint(to: finger.tip) else { return nil }
        let insideMask = mask.contains(finger.tip)

        // The tip sits at the very end of a thin finger, so a patch centered on it is half background.
        // Read its depth halfway down to the DIP joint instead, where a small patch is all finger.
        let depthPoint = finger.dip.map { CGPoint(x: (finger.tip.x + $0.x) / 2, y: (finger.tip.y + $0.y) / 2) } ?? finger.tip

        var distance: Float?
        var depthGap: Float?
        if let tipDepth = depthValue(at: depthPoint, frame: frame, radius: 1) {
            // Object depth comes only from pixels inside the mask: on the contour itself, depth mixes the
            // object with the background behind it. Inside the mask a wide patch is used so the object
            // outweighs any finger pixels the mask includes.
            if insideMask {
                if let objectDepth = depthValue(at: finger.tip, frame: frame, radius: 6, include: { mask.contains($0) }) {
                    depthGap = objectDepth - tipDepth - finger.reach
                    distance = max(0, depthGap!)
                }
            } else if let target = cameraSpacePoint(at: edge, frame: frame, radius: 3, include: { mask.contains($0) }) {
                let hand = cameraSpacePoint(at: finger.tip, depth: tipDepth, frame: frame)
                distance = max(0, simd_distance(hand, target) - finger.reach)
                depthGap = target.z - hand.z - finger.reach
            }
        }
        let screenGap = insideMask ? 0 : hypot(finger.tip.x - edge.x, finger.tip.y - edge.y)
        return EdgeMeasurement(
            fingertip: finger.tip,
            edge: edge,
            distance: distance,
            insideMask: insideMask,
            screenGap: screenGap,
            depthGap: depthGap
        )
    }

    private func handCenter(label: String) -> CGPoint? {
        label == "left_hand" ? leftHandCenter : rightHandCenter
    }

    private func handDepth(label: String, frame: ARFrame) -> Float? {
        guard let center = handCenter(label: label) else { return nil }
        return depthValue(at: center, frame: frame)
    }

    private func handToPoint(label: String, target: SIMD3<Float>, frame: ARFrame) -> Float? {
        guard let center = handCenter(label: label),
              let hand = cameraSpacePoint(at: center, frame: frame) else { return nil }
        return simd_distance(hand, target)
    }

    // Unprojects a Vision-coords point into 3D camera space (meters) using LiDAR depth
    // and the camera intrinsics, so two points give a true straight-line distance.
    private func cameraSpacePoint(
        at point: CGPoint,
        frame: ARFrame,
        radius: Int = 2,
        include: ((CGPoint) -> Bool)? = nil
    ) -> SIMD3<Float>? {
        guard let depth = depthValue(at: point, frame: frame, radius: radius, include: include) else { return nil }
        return cameraSpacePoint(at: point, depth: depth, frame: frame)
    }

    private func cameraSpacePoint(at point: CGPoint, depth: Float, frame: ARFrame) -> SIMD3<Float> {
        let imageSize = frame.camera.imageResolution // landscape sensor resolution
        let intrinsics = frame.camera.intrinsics
        // Same portrait -> sensor mapping as depthValue(at:frame:).
        let u = Float((1 - point.y) * imageSize.width)
        let v = Float((1 - point.x) * imageSize.height)

        let x = (u - intrinsics[2][0]) * depth / intrinsics[0][0]
        let y = (v - intrinsics[2][1]) * depth / intrinsics[1][1]
        return SIMD3<Float>(x, y, depth)
    }

    // point is normalized (0-1), Vision coords (origin bottom-left) of the upright portrait image.
    // Returns the median depth (meters) of a small patch, ignoring invalid and low-confidence pixels,
    // and pixels whose Vision-coords position `include` rejects.
    private func depthValue(
        at point: CGPoint,
        frame: ARFrame,
        radius: Int = 2,
        include: ((CGPoint) -> Bool)? = nil
    ) -> Float? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        // Detection ran with orientation .right, but the depth map is in landscape sensor
        // orientation: sensor x runs down the portrait image, sensor y runs right-to-left.
        let sensorX = 1 - point.y
        let sensorY = 1 - point.x
        let cx = Int(sensorX * CGFloat(width))
        let cy = Int(sensorY * CGFloat(height))

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let depthBuffer = depthBase.assumingMemoryBound(to: Float32.self)

        let confidenceBuffer = confidenceMap
            .flatMap { CVPixelBufferGetBaseAddress($0) }?
            .assumingMemoryBound(to: UInt8.self)
        let confidenceStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        var samples: [Float] = []
        samples.reserveCapacity((2 * radius + 1) * (2 * radius + 1))

        for y in (cy - radius)...(cy + radius) where y >= 0 && y < height {
            for x in (cx - radius)...(cx + radius) where x >= 0 && x < width {
                // Inverse of the sensorX/sensorY mapping above, at the depth pixel's center.
                if let include, !include(CGPoint(
                    x: 1 - (CGFloat(y) + 0.5) / CGFloat(height),
                    y: 1 - (CGFloat(x) + 0.5) / CGFloat(width)
                )) {
                    continue
                }
                if let confidenceBuffer,
                   confidenceBuffer[y * confidenceStride + x] == UInt8(ARConfidenceLevel.low.rawValue) {
                    continue
                }
                let depth = depthBuffer[y * depthStride + x]
                if depth.isFinite && depth > 0 {
                    samples.append(depth)
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}
