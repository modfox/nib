import Foundation
import CoreGraphics

/// Computes the click count (`.mouseEventClickState`) for synthesized mouse-downs. The
/// window server does not derive it for posted events, so without this every click is a
/// single click and apps never see a double-click.
public struct ClickCounter: Sendable {
    /// Max time between downs to continue a multi-click (set from NSEvent.doubleClickInterval).
    public var interval: TimeInterval
    /// Max distance (points) between downs to continue a multi-click.
    public var maxDistance: Double

    private var lastDown: (time: TimeInterval, point: CGPoint)?
    private var count = 0

    public init(interval: TimeInterval = 0.5, maxDistance: Double = 6) {
        self.interval = interval
        self.maxDistance = maxDistance
    }

    /// Register a mouse-down and return its click count (1 = single, 2 = double, …).
    public mutating func down(at point: CGPoint, time: TimeInterval) -> Int {
        if let last = lastDown, time - last.time <= interval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= maxDistance {
            count += 1
        } else {
            count = 1
        }
        lastDown = (time, point)
        return count
    }
}
