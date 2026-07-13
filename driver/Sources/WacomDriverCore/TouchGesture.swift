import Foundation
import CoreGraphics

/// Turns touch frames into gestures. v1: two-finger scroll (pan) via CGScrollWheel.
/// One-finger touch is intentionally ignored so it doesn't fight the pen for the cursor.
public final class TouchGestureEngine {
    private var lastCentroid: (x: Double, y: Double)?
    private var lastCount = 0

    /// Gain converting raw touch units to scroll pixels. Touch space is ~15360x8640.
    public var scrollGain = 0.35
    /// Natural scrolling: content follows the fingers (macOS default). When true,
    /// moving fingers down reveals content above (scrolls toward the top).
    public var naturalScrolling = true

    public init() {}

    public func handle(_ frame: TouchFrame) {
        let down = frame.contacts.filter { $0.down }
        defer { lastCount = down.count }

        guard down.count == 2 else { lastCentroid = nil; return }

        let cx = down.reduce(0.0) { $0 + Double($1.x) } / 2.0
        let cy = down.reduce(0.0) { $0 + Double($1.y) } / 2.0

        // Only scroll once we have a previous 2-finger centroid (avoids a jump on touch-down).
        if let last = lastCentroid, lastCount == 2 {
            // Raw deltas: touch Y increases downward, X increases rightward.
            let rawDx = (cx - last.x) * scrollGain
            let rawDy = (cy - last.y) * scrollGain
            // Natural: content follows fingers (positive wheel1 scrolls toward top).
            let sign = naturalScrolling ? 1.0 : -1.0
            postScroll(dx: rawDx * sign, dy: rawDy * sign)
        }
        lastCentroid = (cx, cy)
    }

    private func postScroll(dx: Double, dy: Double) {
        // Skip sub-pixel noise.
        guard abs(dx) >= 1 || abs(dy) >= 1 else { return }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                              wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { return }
        e.post(tap: .cghidEventTap)
    }
}
