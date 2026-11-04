import Foundation
import CoreGraphics

/// Turns decoded `PenSample`s into macOS tablet pointer events via CoreGraphics.
///
/// This mirrors the injection path the stock driver uses (observed as
/// NXTabletPointData / kCGEventTabletProximity in the binary). Posting these events
/// requires the process to be granted Accessibility / Input-Monitoring permission.
/// What a pen side button does. Remappable (exposed later via settings).
public enum PenButtonAction: String, Codable, Sendable {
    case none, rightClick, middleClick, leftClick
}

public final class EventEmitter {
    private var mapping: DisplayMapping
    private var wasInProximity = false
    private var wasTipDown = false
    private var wasBarrel = false
    private var wasSecondary = false
    private var lastPoint = CGPoint.zero
    private var lastInverted = false
    private let deviceID: UInt16
    private let vendorID: UInt16 = 0x056a
    private let pressureMax = Double(PenSample.pressureLogicalMax)

    /// Verified: lower side button = `barrelButton`, upper = `secondaryBarrel`.
    public var lowerBarrelAction: PenButtonAction = .rightClick
    public var upperBarrelAction: PenButtonAction = .middleClick
    /// Response curve applied to normalized pen pressure before emission.
    public var pressureCurve: PressureCurve = .linear
    /// Reports raw normalized pressure [0,1] each pointer event (for the prefs preview).
    public var pressureObserver: ((Double) -> Void)?

    /// Multi-click detection for the tip and each side button.
    private var tipClicks = ClickCounter(), lowerClicks = ClickCounter(), upperClicks = ClickCounter()
    /// Click state of the current tip press / held side buttons (carried on drags and ups).
    private var tipClickState = 1, lowerClickState = 1, upperClickState = 1
    /// System double-click interval (the app sets it from NSEvent.doubleClickInterval).
    public var doubleClickInterval: TimeInterval = 0.5 {
        didSet {
            tipClicks.interval = doubleClickInterval
            lowerClicks.interval = doubleClickInterval
            upperClicks.interval = doubleClickInterval
        }
    }

    private let sink: EventSink
    private let now: () -> TimeInterval

    public init(mapping: DisplayMapping, deviceID: UInt16 = 1,
                sink: EventSink = SystemEventSink(),
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.mapping = mapping
        self.deviceID = deviceID
        self.sink = sink
        self.now = now
    }

    public func setMapping(_ m: DisplayMapping) { self.mapping = m }

    public func handle(_ s: PenSample) {
        // Proximity transitions -> tablet proximity events.
        if s.inRange && !wasInProximity {
            postProximity(entering: true, inverted: s.inverted)
            wasInProximity = true
        }

        if s.inRange {
            lastPoint = mapping.point(x: s.x, y: s.y)
            lastInverted = s.inverted
            postPointer(s)
            handleButtons(s)
        }

        if !s.inRange && wasInProximity {
            reset()
        }
    }

    /// Release everything currently held (tip, side buttons) and leave proximity, at the
    /// last in-range position. Called on proximity exit, and by the app when the tablet
    /// detaches or calibration takes over the pen stream, so no button is left "stuck".
    public func reset() {
        let pt = lastPoint
        if wasTipDown, let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                       mouseCursorPosition: pt, mouseButton: .left) {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(tipClickState))
            sink.post(e)
        }
        if wasBarrel { postButton(lowerBarrelAction, down: false, at: pt, clicks: lowerClickState) }
        if wasSecondary { postButton(upperBarrelAction, down: false, at: pt, clicks: upperClickState) }
        if wasInProximity { postProximity(entering: false, inverted: lastInverted) }
        wasTipDown = false; wasBarrel = false; wasSecondary = false; wasInProximity = false
    }

    // MARK: - Side buttons

    private func handleButtons(_ s: PenSample) {
        let pt = mapping.point(x: s.x, y: s.y)
        if s.barrelButton != wasBarrel {
            if s.barrelButton { lowerClickState = lowerClicks.down(at: pt, time: now()) }
            postButton(lowerBarrelAction, down: s.barrelButton, at: pt, clicks: lowerClickState)
            wasBarrel = s.barrelButton
        }
        if s.secondaryBarrel != wasSecondary {
            if s.secondaryBarrel { upperClickState = upperClicks.down(at: pt, time: now()) }
            postButton(upperBarrelAction, down: s.secondaryBarrel, at: pt, clicks: upperClickState)
            wasSecondary = s.secondaryBarrel
        }
    }

    private func postButton(_ action: PenButtonAction, down: Bool, at pt: CGPoint, clicks: Int) {
        let type: CGEventType
        let button: CGMouseButton
        switch action {
        case .none: return
        case .rightClick:  type = down ? .rightMouseDown : .rightMouseUp;  button = .right
        case .middleClick: type = down ? .otherMouseDown : .otherMouseUp;  button = .center
        case .leftClick:   type = down ? .leftMouseDown  : .leftMouseUp;   button = .left
        }
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        sink.post(e)
    }

    // MARK: - Pointer

    private func postPointer(_ s: PenSample) {
        let pt = mapping.point(x: s.x, y: s.y)

        let type: CGEventType
        if s.tipDown && !wasTipDown { type = .leftMouseDown }
        else if !s.tipDown && wasTipDown { type = .leftMouseUp }
        else if s.tipDown { type = .leftMouseDragged }
        else { type = .mouseMoved }
        wasTipDown = s.tipDown
        if type == .leftMouseDown { tipClickState = tipClicks.down(at: pt, time: now()) }

        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: .left) else { return }
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(tipClickState))
        }

        let rawPressure = Double(s.pressure) / pressureMax     // 0.0 ... 1.0
        pressureObserver?(rawPressure)
        let normPressure = pressureCurve.evaluate(rawPressure) // shaped by the response curve

        // Tag as a tablet-pointer subtype and fill tablet fields.
        e.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        // General mouse pressure: what NSEvent.pressure returns (apps like Notes/Preview).
        e.setDoubleValueField(.mouseEventPressure, value: normPressure)
        // Tablet-specific pressure: what pro apps (Photoshop/Krita) read.
        e.setDoubleValueField(.tabletEventPointPressure, value: normPressure)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(s.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(s.y))
        e.setDoubleValueField(.tabletEventTiltX, value: Double(s.tiltX) / 64.0)
        e.setDoubleValueField(.tabletEventTiltY, value: Double(s.tiltY) / 64.0)
        e.setIntegerValueField(.tabletEventDeviceID, value: Int64(deviceID))
        // Button mask: bit0 tip, bit1 barrel, bit2 secondary barrel.
        var buttons: Int64 = 0
        if s.tipDown { buttons |= 0x1 }
        if s.barrelButton { buttons |= 0x2 }
        if s.secondaryBarrel { buttons |= 0x4 }
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        sink.post(e)
    }

    // MARK: - Proximity

    private func postProximity(entering: Bool, inverted: Bool) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletProximity
        e.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(vendorID))
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: Int64(deviceID))
        e.setIntegerValueField(.tabletProximityEventPointerType,
                               value: inverted ? 3 /*eraser*/ : 1 /*pen*/)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        // Advertise capabilities so apps enable pressure/tilt. Bits (NX_TABLET_CAPABILITY_*):
        // deviceID 0x01 | absX 0x02 | absY 0x04 | pressure 0x40 | orientation/tilt 0x100.
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0147)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: Int64(deviceID))
        sink.post(e)
    }
}
