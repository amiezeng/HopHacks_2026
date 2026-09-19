import SwiftUI

func convexHull(of points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
    guard sorted.count > 2 else { return sorted }

    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    var lower: [CGPoint] = []
    for p in sorted {
        while lower.count >= 2 && cross(lower[lower.count-2], lower[lower.count-1], p) <= 0 {
            lower.removeLast()
        }
        lower.append(p)
    }

    var upper: [CGPoint] = []
    for p in sorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count-2], upper[upper.count-1], p) <= 0 {
            upper.removeLast()
        }
        upper.append(p)
    }

    return lower.dropLast() + upper.dropLast()
}

struct HandHighlight: Shape {
    let points: [CGPoint] // already converted to view coordinates

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}
