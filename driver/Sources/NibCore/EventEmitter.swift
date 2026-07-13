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

    public init(mapping: DisplayMapping, deviceID: UInt16 = 1) {
        self.mapping = mapping
        self.deviceID = deviceID
    }

    public func setMapping(_ m: DisplayMapping) { self.mapping = m }

    public func handle(_ s: PenSample) {
        // Proximity transitions -> tablet proximity events.
        if s.inRange && !wasInProximity {
            postProximity(entering: true, sample: s)
            wasInProximity = true
        }

        if s.inRange {
            postPointer(s)
            handleButtons(s)
        }

        if !s.inRange && wasInProximity {
            // Release any held side buttons before leaving proximity.
            let pt = mapping.point(x: s.x, y: s.y)
            if wasBarrel { postButton(lowerBarrelAction, down: false, at: pt); wasBarrel = false }
            if wasSecondary { postButton(upperBarrelAction, down: false, at: pt); wasSecondary = false }
            postProximity(entering: false, sample: s)
            wasInProximity = false
            wasTipDown = false
        }
    }

    // MARK: - Side buttons

    private func handleButtons(_ s: PenSample) {
        let pt = mapping.point(x: s.x, y: s.y)
        if s.barrelButton != wasBarrel {
            postButton(lowerBarrelAction, down: s.barrelButton, at: pt)
            wasBarrel = s.barrelButton
        }
        if s.secondaryBarrel != wasSecondary {
            postButton(upperBarrelAction, down: s.secondaryBarrel, at: pt)
            wasSecondary = s.secondaryBarrel
        }
    }

    private func postButton(_ action: PenButtonAction, down: Bool, at pt: CGPoint) {
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
        e.post(tap: .cghidEventTap)
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

        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: .left) else { return }

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
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Proximity

    private func postProximity(entering: Bool, sample s: PenSample) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletProximity
        e.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(vendorID))
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: Int64(deviceID))
        e.setIntegerValueField(.tabletProximityEventPointerType,
                               value: s.inverted ? 3 /*eraser*/ : 1 /*pen*/)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        // Advertise capabilities so apps enable pressure/tilt. Bits (NX_TABLET_CAPABILITY_*):
        // deviceID 0x01 | absX 0x02 | absY 0x04 | pressure 0x40 | orientation/tilt 0x100.
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0147)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: Int64(deviceID))
        e.post(tap: .cghidEventTap)
    }
}
