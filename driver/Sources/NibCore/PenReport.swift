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
    /// HID report ID of the high-resolution pen report.
    public static let reportID: UInt32 = 0x10
    /// Full report length in bytes, including the report-ID byte at index 0.
    public static let reportLength = 27

    // Byte offsets into the full report buffer (index 0 = report ID). Confirmed live.
    private enum Off {
        static let status = 1
        static let x = 2          // 24-bit LE
        static let y = 5          // 24-bit LE
        static let pressure = 8   // 16-bit LE
        static let tiltX = 10     // int8
        static let tiltY = 11     // int8
        static let twist = 12     // 16-bit LE signed
        static let distance = 16  // 8-bit
        static let serial = 17    // 32-bit LE
        static let toolID = 21    // 32-bit LE
    }

    /// Parse a full report-0x10 buffer (as delivered by IOHIDManager, ID byte included).
    public static func parse(_ r: [UInt8]) -> PenSample? {
        guard r.count >= reportLength, UInt32(r[0]) == reportID else { return nil }
        let st = r[Off.status]
        return PenSample(
            tipDown:         (st & 0x01) != 0,
            barrelButton:    (st & 0x02) != 0,
            secondaryBarrel: (st & 0x04) != 0,
            eraser:          (st & 0x08) != 0,
            inverted:        (st & 0x10) != 0,
            inRange:         (st & 0x20) != 0,
            x: int24LE(r, Off.x),
            y: int24LE(r, Off.y),
            pressure: Int(r[Off.pressure]) | (Int(r[Off.pressure + 1]) << 8),
            tiltX: Int(Int8(bitPattern: r[Off.tiltX])),
            tiltY: Int(Int8(bitPattern: r[Off.tiltY])),
            twist: Int(Int16(bitPattern: UInt16(r[Off.twist]) | (UInt16(r[Off.twist + 1]) << 8))),
            distance: Int(r[Off.distance]),
            serial: u32LE(r, Off.serial),
            toolID: u32LE(r, Off.toolID)
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
