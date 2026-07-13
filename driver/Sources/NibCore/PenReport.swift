import Foundation

/// A decoded pen sample from the DTH2420 high-resolution report (HID report ID 0x10).
///
/// Field offsets were **confirmed against live raw-hex captures** (top-left / center /
/// bottom-right / hard-press / lift gestures) — see recon notes. On macOS, the
/// IOHIDManager input-report buffer for this device **includes the report-ID byte at
/// index 0**, so all data offsets below are into the full 27-byte report.
public struct PenSample: Equatable, Sendable {
    public var tipDown: Bool
    public var barrelButton: Bool       // usage 0x44 (lower side switch)
    public var secondaryBarrel: Bool    // usage 0x5a (upper side switch)
    public var eraser: Bool
    public var inverted: Bool           // eraser end in proximity
    public var inRange: Bool            // proximity

    public var x: Int                   // 0 ... 105286
    public var y: Int                   // 0 ... 59574
    public var pressure: Int            // 0 ... 8191
    public var tiltX: Int               // -64 ... 63
    public var tiltY: Int               // -64 ... 63
    public var twist: Int               // signed; art-pen rotation (0 for most pens)
    public var distance: Int            // hover height (0x3f far → lower approaching)
    public var serial: UInt32           // transducer serial number
    public var toolID: UInt32           // tool/type id field

    public static let xLogicalMax = 105286
    public static let yLogicalMax = 59574
    public static let pressureLogicalMax = 8191
}

public enum PenReport {
    /// HID report ID of the reference (DTH2420) high-resolution pen report.
    public static var reportID: UInt32 { PenLayout.dth2420.reportID }
    /// Full report length of the reference report, including the report-ID byte at index 0.
    public static var reportLength: Int { PenLayout.dth2420.reportLength }

    /// Parse a full high-resolution pen report (as delivered by IOHIDManager, ID byte
    /// included) according to `layout`. Defaults to the DTH2420 layout.
    public static func parse(_ r: [UInt8], _ layout: PenLayout = .dth2420) -> PenSample? {
        let o = layout.offsets
        guard r.count >= layout.reportLength, UInt32(r[0]) == layout.reportID else { return nil }
        let st = r[o.status]
        return PenSample(
            tipDown:         (st & 0x01) != 0,
            barrelButton:    (st & 0x02) != 0,
            secondaryBarrel: (st & 0x04) != 0,
            eraser:          (st & 0x08) != 0,
            inverted:        (st & 0x10) != 0,
            inRange:         (st & 0x20) != 0,
            x: int24LE(r, o.x),
            y: int24LE(r, o.y),
            pressure: Int(r[o.pressure]) | (Int(r[o.pressure + 1]) << 8),
            tiltX: Int(Int8(bitPattern: r[o.tiltX])),
            tiltY: Int(Int8(bitPattern: r[o.tiltY])),
            twist: Int(Int16(bitPattern: UInt16(r[o.twist]) | (UInt16(r[o.twist + 1]) << 8))),
            distance: Int(r[o.distance]),
            serial: u32LE(r, o.serial),
            toolID: u32LE(r, o.toolID)
        )
    }

    @inline(__always)
    private static func int24LE(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i+1]) << 8) | (Int(b[i+2]) << 16)
    }
    @inline(__always)
    private static func u32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i+1]) << 8) | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
    }
}
