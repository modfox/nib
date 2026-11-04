import Foundation
import CoreGraphics
@testable import NibCore

/// Captures synthesized events instead of posting them, so state machines can be
/// asserted without Accessibility permission.
final class RecordingSink: EventSink {
    private(set) var events: [CGEvent] = []
    func post(_ event: CGEvent) { events.append(event) }

    var types: [CGEventType] { events.map { $0.type } }
    /// Mouse button events only (moves/drags/proximity filtered out).
    var clicks: [CGEvent] {
        events.filter {
            [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp].contains($0.type)
        }
    }
    func clear() { events.removeAll() }
}

/// A manually advanced clock for time-dependent gesture logic.
final class TestClock {
    var t: TimeInterval = 100
    func advance(_ dt: TimeInterval) { t += dt }
}

func frame(_ points: [(Int, Int)]) -> TouchFrame {
    TouchFrame(contacts: points.enumerated().map {
        TouchContact(id: $0.offset, down: true, x: $0.element.0, y: $0.element.1)
    }, contactCount: points.count)
}
