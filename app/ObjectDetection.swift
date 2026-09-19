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

    private var objectRequest: VNCoreMLRequest?
    private var handRequest: VNDetectHumanHandPoseRequest?
    private var latestFrame: ARFrame?
    private let detectionQueue = DispatchQueue(label: "com.hophacks.objectdetector.detectionQueue", qos: .userInitiated)
    private let minDetectionInterval: TimeInterval = 0.1
    private var lastDetectionTimestamp: TimeInterval = 0
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

    // Which object label to measure distance to
    var targetLabel: String = "bottle"

    init() {
        setupObjectDetection()
        setupHandDetection()
    }

    private func setupObjectDetection() {
        do {
            let config = MLModelConfiguration()
            let vnModel = try loadVNCoreMLModel(config: config)

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

    private func loadVNCoreMLModel(config: MLModelConfiguration) throws -> VNCoreMLModel {
        let modelNames = ["YOLOv10n_EGOHOS", "YOLOv10n_EGOHO", "YOLOv10nEGOHO", "yolo11n", "yolo11n_EGOHO"]
        let modelExtensions = ["mlpackage", "mlmodel", "mlmodelc"]

        for name in modelNames {
            for ext in modelExtensions {
                if let modelURL = Bundle.main.url(forResource: name, withExtension: ext) {
                    let model = try MLModel(contentsOf: modelURL, configuration: config)
                    return try VNCoreMLModel(for: model)
                }
            }
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

            let centerX = CGFloat(output[candidateIndex].floatValue) / 640
            let centerY = CGFloat(output[candidateCount + candidateIndex].floatValue) / 640
            let width = CGFloat(output[(2 * candidateCount) + candidateIndex].floatValue) / 640
            let height = CGFloat(output[(3 * candidateCount) + candidateIndex].floatValue) / 640

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
                }
                return
            }

            var leftPoints: [CGPoint] = []
            var rightPoints: [CGPoint] = []
            var firstWrist: CGPoint?

            for observation in results {
                let outline = self?.handOutlinePoints(from: observation) ?? []
                guard outline.count > 2 else { continue }

                if observation.chirality == .left {
                    leftPoints = outline
                } else {
                    rightPoints = outline
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
                if let firstWrist {
                    self?.handPoint = firstWrist
                    self?.tryComputeDistance()
                } else {
                    self?.handPoint = nil
                }
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
            self.detectObjects(in: frame.capturedImage)
            self.detectHand(in: frame.capturedImage)
        }
    }

    private func detectObjects(in pixelBuffer: CVPixelBuffer) {
        guard let request = objectRequest else {
            print("Object detection request is not available because the CoreML model could not be loaded.")
            return
        }
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

    // Runs after EITHER object detection or hand detection updates,
    // so it always uses whatever the latest values are for both.
    private func tryComputeDistance() {
        guard let frame = latestFrame else { return }

        guard let target = detections.first(where: { $0.label == targetLabel }) else {
            distance = nil
            return
        }
        guard let handPoint = handPoint else {
            distance = nil
            return
        }

        let targetCenter = CGPoint(x: target.boundingBox.midX, y: target.boundingBox.midY)

        guard let targetDepth = depthValue(at: targetCenter, frame: frame) else {
            distance = nil
            return
        }
        guard let handDepth = depthValue(at: handPoint, frame: frame) else {
            distance = nil
            return
        }

        // Simplified: difference in depth from camera, not true 3D straight-line distance
        distance = abs(targetDepth - handDepth)
    }

    // point is normalized (0-1), Vision coords (origin bottom-left)
    private func depthValue(at point: CGPoint, frame: ARFrame) -> Float? {
        guard let depthMap = frame.sceneDepth?.depthMap else {
            return nil
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        let x = Int(point.x * CGFloat(width))
        let y = Int((1 - point.y) * CGFloat(height))

        guard x >= 0, x < width, y >= 0, y < height,
              let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
        return floatBuffer[y * (bytesPerRow / MemoryLayout<Float32>.size) + x]
    }
}
