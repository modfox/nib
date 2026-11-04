import CoreGraphics

/// Two-point pen calibration, shared by the `calibrate` CLI and the in-app overlay.
///
/// The user holds the pen tip on target 1, lifts, then holds it on target 2. A hold counts
/// once `holdSamples` consecutive tip-down samples stay within `tolerance` raw units. The two
/// captured raw points and the targets' known positions (as fractions of the display) give
/// the raw pen range that spans the display.
public struct CalibrationSolver {
    public enum Event: Equatable {
        case none
        /// Target 1 captured; waiting for the pen to lift.
        case firstCaptured
        /// Pen lifted after target 1; now waiting on target 2.
        case awaitingSecond
        /// Both targets captured and the result is plausible.
        case finished(Calibration)
        /// The two points were too close or in the wrong order; restarted at target 1.
        case rejected
    }

    /// Target positions as fractions of the display (0...1), target 1 before target 2.
    public let target1: CGPoint
    public let target2: CGPoint
    public var holdSamples = 40
    public var tolerance = 1200
    /// The two raw points must be at least this fraction of the logical range apart on
    /// each axis (in the direction of the targets).
    public var minSpanFraction = 0.1
    private let xLogicalMax: Double
    private let yLogicalMax: Double

    private enum Stage { case holdFirst, lift, holdSecond, done }
    private var stage = Stage.holdFirst
    private var buf: [(Int, Int)] = []
    private var raw1 = (0.0, 0.0)

    public init(target1: CGPoint, target2: CGPoint, pen: PenLayout) {
        self.target1 = target1
        self.target2 = target2
        self.xLogicalMax = Double(pen.xLogicalMax)
        self.yLogicalMax = Double(pen.yLogicalMax)
    }

    /// Fraction position of the target currently being asked for.
    public var currentTarget: CGPoint { stage == .holdFirst ? target1 : target2 }

    public mutating func reset() { stage = .holdFirst; buf.removeAll() }

    public mutating func feed(_ s: PenSample) -> Event {
        guard stage != .done else { return .none }
        if !s.tipDown || !s.inRange {
            buf.removeAll()
            if stage == .lift { stage = .holdSecond; return .awaitingSecond }
            return .none
        }
        guard stage == .holdFirst || stage == .holdSecond else { buf.removeAll(); return .none }
        buf.append((s.x, s.y))
        if buf.count > holdSamples { buf.removeFirst() }
        guard buf.count == holdSamples, isSteady() else { return .none }

        let m = mean()
        buf.removeAll()
        if stage == .holdFirst {
            raw1 = m; stage = .lift
            return .firstCaptured
        }
        if let cal = Self.solve(raw1: raw1, raw2: m, target1: target1, target2: target2,
                                xLogicalMax: xLogicalMax, yLogicalMax: yLogicalMax,
                                minSpanFraction: minSpanFraction) {
            stage = .done
            return .finished(cal)
        }
        stage = .holdFirst
        return .rejected
    }

    /// Solve raw = a·fraction + b on each axis and return the raw range at fractions 0 and 1,
    /// or nil if the points are implausible (too close, or ordered against the targets).
    public static func solve(raw1: (Double, Double), raw2: (Double, Double),
                             target1: CGPoint, target2: CGPoint,
                             xLogicalMax: Double, yLogicalMax: Double,
                             minSpanFraction: Double = 0.1) -> Calibration? {
        func axis(_ r1: Double, _ r2: Double, _ f1: Double, _ f2: Double, _ logicalMax: Double) -> (Double, Double)? {
            guard f1 != f2 else { return nil }
            let towardTarget2 = (r2 - r1) * (f2 > f1 ? 1 : -1)
            guard towardTarget2 >= minSpanFraction * logicalMax else { return nil }
            let a = (r2 - r1) / (f2 - f1)
            let b = r1 - a * f1
            return (b, a + b)
        }
        guard let (xMin, xMax) = axis(raw1.0, raw2.0, Double(target1.x), Double(target2.x), xLogicalMax),
              let (yMin, yMax) = axis(raw1.1, raw2.1, Double(target1.y), Double(target2.y), yLogicalMax)
        else { return nil }
        return Calibration(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
    }

    private func isSteady() -> Bool {
        let xs = buf.map { $0.0 }, ys = buf.map { $0.1 }
        return xs.max()! - xs.min()! < tolerance && ys.max()! - ys.min()! < tolerance
    }

    private func mean() -> (Double, Double) {
        (buf.reduce(0.0) { $0 + Double($1.0) } / Double(buf.count),
         buf.reduce(0.0) { $0 + Double($1.1) } / Double(buf.count))
    }
}
