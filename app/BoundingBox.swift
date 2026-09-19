import SwiftUI

struct BoundingBoxOverlay: View {
    let detections: [Detection]
    let handPoint: CGPoint?
    let leftHandJointPoints: [CGPoint]
    let rightHandJointPoints: [CGPoint]
    let leftHandHoldingObject: Bool
    let rightHandHoldingObject: Bool
    let viewSize: CGSize
    let distance: Float?

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

            if let distance = distance {
                Text(String(format: "Distance: %.2f m", distance))
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.yellow)
                    .padding(.top, 40)
            }
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
