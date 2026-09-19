import SwiftUI

struct BoundingBoxOverlay: View {
    let detections: [Detection]
    let handPoint: CGPoint?
    let leftHandJointPoints: [CGPoint]
    let rightHandJointPoints: [CGPoint]
    let leftHandHoldingObject: Bool
    let rightHandHoldingObject: Bool
    let viewSize: CGSize
    let leftHandDistance: Float?
    let rightHandDistance: Float?
    let selectedPoint: CGPoint?
    let leftHandCenter: CGPoint?
    let rightHandCenter: CGPoint?
    let leftHandToPointDistance: Float?
    let rightHandToPointDistance: Float?
    let leftHandEdge: EdgeMeasurement?
    let rightHandEdge: EdgeMeasurement?
    let objectFound: Bool
    let approaching: Bool
    let objectCenter: CGPoint?
    let cameraDistance: Float?
    let objectClose: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(detections) { detection in
                let rect = convert(detection.boundingBox, to: viewSize)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color.green, lineWidth: 2)
                    Text("\(detection.label) \(Int(detection.confidence * 100))%")
                        .font(.caption)
                        .padding(2)
                        .background(Color.green)
                        .foregroundColor(.black)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }

            if leftHandJointPoints.count > 2 {
                let converted = leftHandJointPoints.map { convertPoint($0, to: viewSize) }
                jointCircles(points: converted, color: .blue)
            }

            if rightHandJointPoints.count > 2 {
                let converted = rightHandJointPoints.map { convertPoint($0, to: viewSize) }
                jointCircles(points: converted, color: rightHandHoldingObject ? .blue : .red)
            }

            // Dot at each hand's center joint: the point where LiDAR depth is sampled.
            ForEach(handCenters(), id: \.label) { hand in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 14, height: 14)
                    .position(hand.center)
            }

            // Line from each hand center to the tapped point.
            if let selectedPoint {
                let target = convertPoint(selectedPoint, to: viewSize)
                ForEach(handCenters(), id: \.label) { hand in
                    Path { path in
                        path.move(to: hand.center)
                        path.addLine(to: target)
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                }
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .background(Circle().fill(Color.yellow))
                    .frame(width: 16, height: 16)
                    .position(target)
            }

            // Closest fingertip -> object, labeled with the LiDAR distance. Green once found. When the fingertip
            // overlaps the object on screen the distance is a depth gap, so there's no edge line to draw.
            // Hidden once found: the camera -> object distance below takes over.
            ForEach(approaching ? [] : edgeMeasurements(), id: \.label) { hand in
                let tint = objectFound ? Color.green : Color.cyan
                let fingertip = convertPoint(hand.measurement.fingertip, to: viewSize)
                let edge = convertPoint(hand.measurement.edge, to: viewSize)
                let inside = hand.measurement.insideMask
                if !inside {
                    Path { path in
                        path.move(to: fingertip)
                        path.addLine(to: edge)
                    }
                    .stroke(tint, lineWidth: 3)
                    Circle()
                        .fill(tint)
                        .frame(width: 10, height: 10)
                        .position(edge)
                }
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .background(Circle().fill(tint))
                    .frame(width: 14, height: 14)
                    .position(fingertip)
                Text(format(hand.measurement.distance))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .position(inside
                        ? CGPoint(x: fingertip.x, y: fingertip.y - 22)
                        : CGPoint(x: (fingertip.x + edge.x) / 2, y: (fingertip.y + edge.y) / 2))
            }

            // Point where the camera -> object distance is measured, labeled with it. Green once close enough to read.
            if approaching, let objectCenter {
                let center = convertPoint(objectCenter, to: viewSize)
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .background(Circle().fill(objectClose ? Color.green : Color.orange))
                    .frame(width: 18, height: 18)
                    .position(center)
                Text(format(cameraDistance))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .position(x: center.x, y: center.y - 24)
            }

            if let pillText {
                Text(pillText)
                    .font(.headline.monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        pillHighlighted ? AnyShapeStyle(Color.green.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial),
                        in: Capsule()
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    private var pillHighlighted: Bool {
        approaching ? objectClose : objectFound
    }

    private var pillText: String? {
        if approaching { return approachText }
        if objectFound { return "Found ✓" }
        let (title, left, right) = pillDistances
        guard left != nil || right != nil else { return nil }
        return "\(title)  L \(format(left)) · R \(format(right))"
    }

    // Too close is checked first: the camera can't focus there, even while still debounced as close.
    private var approachText: String {
        if let cameraDistance, cameraDistance < ObjectDetector.tooCloseDistance {
            return "Too close, move it back · \(format(cameraDistance))"
        }
        if objectClose { return "Close enough to read ✓" }
        let goal = String(format: "%.0f in", ObjectDetector.readDistance * 39.3701)
        return "Bring it closer · \(format(cameraDistance)) → \(goal)"
    }

    // Hand -> tapped point if one is selected, else closest fingertip -> mask edge, else camera -> hand.
    private var pillDistances: (String, Float?, Float?) {
        if selectedPoint != nil {
            return ("Point", leftHandToPointDistance, rightHandToPointDistance)
        }
        if leftHandEdge != nil || rightHandEdge != nil {
            return ("Edge", leftHandEdge?.distance, rightHandEdge?.distance)
        }
        return ("Camera", leftHandDistance, rightHandDistance)
    }

    private func edgeMeasurements() -> [(label: String, measurement: EdgeMeasurement)] {
        [("left_hand", leftHandEdge), ("right_hand", rightHandEdge)].compactMap { label, measurement in
            measurement.map { (label, $0) }
        }
    }

    private func format(_ meters: Float?) -> String {
        guard let meters else { return "—" }
        return String(format: "%.1f in", meters * 39.3701)
    }

    private func handCenters() -> [(label: String, center: CGPoint)] {
        [("left_hand", leftHandCenter), ("right_hand", rightHandCenter)].compactMap { label, center in
            center.map { (label, convertPoint($0, to: viewSize)) }
        }
    }

    private func convert(_ box: CGRect, to size: CGSize) -> CGRect {
        let x = box.minX * size.width
        let y = (1 - box.maxY) * size.height
        let width = box.width * size.width
        let height = box.height * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func convertPoint(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    @ViewBuilder
    private func jointCircles(points: [CGPoint], color: Color) -> some View {
        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .position(point)
        }
    }
}
