import CoreGraphics

/// Where synthesized input events go. Production posts them to the HID event tap; tests
/// substitute a recorder so emitter / gesture state machines can be checked without
/// Accessibility permission or moving the real cursor.
public protocol EventSink: AnyObject {
    func post(_ event: CGEvent)
}

/// Posts events into the system at the HID tap (requires Accessibility permission).
public final class SystemEventSink: EventSink {
    public init() {}
    public func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }
}
