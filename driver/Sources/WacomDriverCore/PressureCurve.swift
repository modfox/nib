import Foundation

/// A pressure response curve mapping normalized input pressure [0,1] → output [0,1].
/// Piecewise-linear through editable control points (endpoints fixed at 0,0 and 1,1).
public struct PressureCurve: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public var points: [Point]

    public init(points: [Point]) { self.points = points }

    /// Identity curve (input == output).
    public static var linear: PressureCurve {
        .init(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.25),
                       .init(x: 0.5, y: 0.5), .init(x: 0.75, y: 0.75), .init(x: 1, y: 1)])
    }

    /// Evaluate the curve, clamped to [0,1].
    public func evaluate(_ x: Double) -> Double {
        let cx = clamp(x)
        let pts = points.sorted { $0.x < $1.x }
        guard let first = pts.first else { return cx }
        if cx <= first.x { return clamp(first.y) }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            if cx <= b.x {
                let span = b.x - a.x
                let t = span == 0 ? 0 : (cx - a.x) / span
                return clamp(a.y + t * (b.y - a.y))
            }
        }
        return clamp(pts.last!.y)
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}
