import Foundation

/// One touch contact decoded from the touch digitizer report (HID report ID 0x81).
/// Fields per the touch HID descriptor (PID 0x0355): TipSwitch(1b)+pad, ContactID(u8),
/// X(u16 LE, max 15360), Y(u16 LE, max 8640).
public struct TouchContact: Equatable, Sendable {
    public var id: Int
    public var down: Bool
    public var x: Int          // 0 ... 15360
    public var y: Int          // 0 ... 8640

    public static let xLogicalMax = 15360   // 0x3c00
    public static let yLogicalMax = 8640    // 0x21c0
}

public struct TouchFrame: Equatable, Sendable {
    public var contacts: [TouchContact]     // only the ones currently down
    public var contactCount: Int            // reported active-contact count
}

public enum TouchReport {
    /// HID report ID of the reference (DTH2420) multitouch report.
    public static var reportID: UInt32 { TouchLayout.dth2420.reportID }
    /// Bytes per finger record in the reference report.
    public static var fingerRecordSize: Int { TouchLayout.dth2420.fingerRecordSize }

    /// Parse a multitouch report (report-ID byte at index 0) according to `layout`.
    /// Defaults to the DTH2420 layout. Confirmed against live 1/2/3-finger captures:
    /// 64-byte report,
    ///   [0]=id 0x81, [1..]=contactCount contiguous 6-byte finger records, empty slots 0xFF,
    ///   [61..62]=scanTime u16 LE, [63]=contactCount.
    /// Finger record: [0]=TipSwitch(bit0), [1]=ContactID, [2..3]=X LE, [4..5]=Y LE.
    public static func parse(_ r: [UInt8], _ layout: TouchLayout = .dth2420) -> TouchFrame? {
        guard r.count >= layout.minReportLength, UInt32(r[0]) == layout.reportID else { return nil }
        let maxSlots = (r.count - 1 - layout.trailerSize) / layout.fingerRecordSize
        let count = Int(r[r.count - 1])
        let n = min(count, maxSlots)
        var contacts: [TouchContact] = []
        contacts.reserveCapacity(n)
        for i in 0..<n {
            let o = 1 + i * layout.fingerRecordSize
            let state = r[o]
            guard state != 0xFF else { continue }             // empty slot
            let down = (state & 0x01) != 0
            let id = Int(r[o + 1])
            let x = Int(r[o + 2]) | (Int(r[o + 3]) << 8)
            let y = Int(r[o + 4]) | (Int(r[o + 5]) << 8)
            contacts.append(TouchContact(id: id, down: down, x: x, y: y))
        }
        return TouchFrame(contacts: contacts, contactCount: count)
    }
}
