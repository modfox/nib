import Foundation
import CoreGraphics

/// Per-device description: everything that differs between one pen display and another,
/// collected in one place so support for a new model is *data*, not code.
///
/// Today Nib ships a single profile (`.dth2420`). The parsers, mode-switch, touch-enable
/// and display match all read from a profile rather than hardcoded constants, so adding a
/// model means adding a `DeviceProfile` literal (ideally derived from a submitted HID
/// report-descriptor capture — see `ROADMAP.md`), not editing the decode path.
public struct DeviceProfile: Sendable {
    /// Human-readable model name (for logs / UI).
    public var name: String
    /// USB vendor ID (0x056a = Wacom).
    public var vendorID: UInt16
    /// Product ID of the pen (digitizer) HID interface.
    public var penPID: UInt16
    /// Product ID of the touch HID interface.
    public var touchPID: UInt16
    /// Byte layout of the high-resolution pen report.
    public var pen: PenLayout
    /// Byte layout of the multitouch report.
    public var touch: TouchLayout
    /// Feature reports that switch the pen into its native high-resolution mode.
    public var initSequence: [FeatureWrite]
    /// Output reports that enable the multitouch sensor.
    public var touchEnable: [OutputWrite]
    /// Native panel resolution in pixels, used to locate the tablet's own display for 1:1
    /// pen mapping. `nil` = no built-in display (map to the main display instead).
    public var panelSize: CGSize?
    /// EDID vendor / model of the built-in display (`CGDisplayVendorNumber` /
    /// `CGDisplayModelNumber`). Preferred over `panelSize` for locating the tablet's screen,
    /// since another monitor may share its resolution. `nil` = unknown; match by size.
    public var displayVendor: UInt32?
    public var displayModel: UInt32?

    public init(name: String, vendorID: UInt16, penPID: UInt16, touchPID: UInt16,
                pen: PenLayout, touch: TouchLayout,
                initSequence: [FeatureWrite], touchEnable: [OutputWrite],
                panelSize: CGSize?, displayVendor: UInt32? = nil, displayModel: UInt32? = nil) {
        self.name = name
        self.vendorID = vendorID
        self.penPID = penPID
        self.touchPID = touchPID
        self.pen = pen
        self.touch = touch
        self.initSequence = initSequence
        self.touchEnable = touchEnable
        self.panelSize = panelSize
        self.displayVendor = displayVendor
        self.displayModel = displayModel
    }
}

/// A HID SET_FEATURE write. `bytes[0]` is the report-ID byte (Wacom's convention).
public struct FeatureWrite: Sendable {
    public var reportID: UInt32
    public var bytes: [UInt8]
    public init(reportID: UInt32, _ bytes: [UInt8]) {
        self.reportID = reportID; self.bytes = bytes
    }
}

/// A HID output-report write. `bytes[0]` is the report-ID byte.
public struct OutputWrite: Sendable {
    public var reportID: UInt32
    public var bytes: [UInt8]
    public init(reportID: UInt32, _ bytes: [UInt8]) {
        self.reportID = reportID; self.bytes = bytes
    }
}

/// Byte layout of the high-resolution pen report (default: DTH2420 report 0x10).
/// Offsets are into the full report buffer (index 0 = report-ID byte).
public struct PenLayout: Sendable {
    public struct Offsets: Sendable {
        public var status, x, y, pressure, tiltX, tiltY, twist, distance, serial, toolID: Int
        public init(status: Int, x: Int, y: Int, pressure: Int, tiltX: Int, tiltY: Int,
                    twist: Int, distance: Int, serial: Int, toolID: Int) {
            self.status = status; self.x = x; self.y = y; self.pressure = pressure
            self.tiltX = tiltX; self.tiltY = tiltY; self.twist = twist
            self.distance = distance; self.serial = serial; self.toolID = toolID
        }
    }

    public var reportID: UInt32
    public var reportLength: Int
    public var offsets: Offsets
    public var xLogicalMax: Int
    public var yLogicalMax: Int
    public var pressureLogicalMax: Int

    public init(reportID: UInt32, reportLength: Int, offsets: Offsets,
                xLogicalMax: Int, yLogicalMax: Int, pressureLogicalMax: Int) {
        self.reportID = reportID; self.reportLength = reportLength; self.offsets = offsets
        self.xLogicalMax = xLogicalMax; self.yLogicalMax = yLogicalMax
        self.pressureLogicalMax = pressureLogicalMax
    }
}

/// Byte layout of the Windows-Precision-Touchpad-style multitouch report
/// (default: DTH2420 report 0x81).
public struct TouchLayout: Sendable {
    public var reportID: UInt32
    /// Minimum full report length (below this, reject).
    public var minReportLength: Int
    /// Bytes per finger record (TipSwitch+pad, ContactID, X, Y).
    public var fingerRecordSize: Int
    /// Trailer bytes after the finger records (ScanTime u16 + ContactCount u8).
    public var trailerSize: Int
    public var xLogicalMax: Int
    public var yLogicalMax: Int

    public init(reportID: UInt32, minReportLength: Int, fingerRecordSize: Int,
                trailerSize: Int, xLogicalMax: Int, yLogicalMax: Int) {
        self.reportID = reportID; self.minReportLength = minReportLength
        self.fingerRecordSize = fingerRecordSize; self.trailerSize = trailerSize
        self.xLogicalMax = xLogicalMax; self.yLogicalMax = yLogicalMax
    }
}

// MARK: - Wacom Cintiq Pro 24 Touch (DTH2420)

public extension PenLayout {
    /// DTH2420 report 0x10 — offsets confirmed against live captures (see `PenReport`).
    static let dth2420 = PenLayout(
        reportID: 0x10,
        reportLength: 27,
        offsets: Offsets(status: 1, x: 2, y: 5, pressure: 8, tiltX: 10, tiltY: 11,
                         twist: 12, distance: 16, serial: 17, toolID: 21),
        xLogicalMax: PenSample.xLogicalMax,
        yLogicalMax: PenSample.yLogicalMax,
        pressureLogicalMax: PenSample.pressureLogicalMax)
}

public extension TouchLayout {
    /// DTH2420 report 0x81 — confirmed against live 1/2/3-finger captures (see `TouchReport`).
    static let dth2420 = TouchLayout(
        reportID: 0x81,
        minReportLength: 64,
        fingerRecordSize: 6,
        trailerSize: 3,
        xLogicalMax: TouchContact.xLogicalMax,
        yLogicalMax: TouchContact.yLogicalMax)
}

public extension DeviceProfile {
    /// Wacom Cintiq Pro 24 Touch (model DTH2420) — the reference device Nib was built on.
    ///
    /// Mode-switch recovered from `CGD16GraphicsTablet::DeviceStart`
    /// (`recon/decompile-CDTH2420.md`); touch-enable from `CHIDInterface::SendConfigCommand`
    /// (`recon/decompile-touch-enable.md`). Buffers include the report-ID byte as `bytes[0]`.
    static let dth2420 = DeviceProfile(
        name: "Wacom Cintiq Pro 24 Touch (DTH2420)",
        vendorID: 0x056a,
        penPID: 0x0351,
        touchPID: 0x0355,
        pen: .dth2420,
        touch: .dth2420,
        initSequence: [
            FeatureWrite(reportID: 0x02, [0x02, 0x02]),   // -> native high-res tablet mode
            FeatureWrite(reportID: 0x04, [0x04, 0x00]),   // -> data-rate mode
        ],
        touchEnable: [
            OutputWrite(reportID: 0x06, touchConfigBuffer(sub: 0x06, val: 0x02)),  // enable multitouch
            OutputWrite(reportID: 0x06, touchConfigBuffer(sub: 0x01, val: 0x03)),  // HID+touch configure
        ],
        panelSize: CGSize(width: 3840, height: 2160),
        displayVendor: 0x5c23,   // "WAC"
        displayModel: 0x1056)

    /// Build a 64-byte Wacom vendor touch-config OUTPUT report:
    ///   [0]=0x06 id, [1]=0x06, [2]=0x00, [3]=sub-cmd, [4]=value, rest 0.
    private static func touchConfigBuffer(sub: UInt8, val: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = 0x06; b[1] = 0x06; b[2] = 0x00; b[3] = sub; b[4] = val
        return b
    }
}

public extension DeviceProfile {
    /// All profiles Nib knows about. Look up an attached device here by (vendorID, PID).
    static let all: [DeviceProfile] = [.dth2420]

    /// Find the profile whose pen or touch interface matches this USB identity.
    static func match(vendorID: UInt16, productID: UInt16) -> DeviceProfile? {
        all.first { $0.vendorID == vendorID && ($0.penPID == productID || $0.touchPID == productID) }
    }

    /// Inspect currently-connected HID hardware and return the known profiles present,
    /// most-specific first (a profile whose *pen* interface is attached ranks first).
    /// Empty if nothing recognized is plugged in.
    static func detectConnected() -> [DeviceProfile] {
        let vendors = Set(all.map { $0.vendorID })
        let connected = vendors.flatMap { HIDTransport.enumerate(vendorID: $0) }
        var seen = Set<String>()
        var result: [DeviceProfile] = []
        // Prefer matching on the pen interface, then touch, so we key off the digitizer.
        for connectedInfo in connected {
            guard let p = match(vendorID: connectedInfo.vendorID, productID: connectedInfo.productID),
                  p.penPID == connectedInfo.productID,
                  !seen.contains(p.name) else { continue }
            seen.insert(p.name); result.append(p)
        }
        for connectedInfo in connected {
            guard let p = match(vendorID: connectedInfo.vendorID, productID: connectedInfo.productID),
                  !seen.contains(p.name) else { continue }
            seen.insert(p.name); result.append(p)
        }
        return result
    }
}
