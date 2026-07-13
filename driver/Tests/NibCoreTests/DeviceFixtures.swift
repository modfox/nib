import NibCore

// Device fixture registry — the heart of the "add a tablet" contribution pipeline.
//
// Each supported device contributes one `DeviceFixtureBundle`: its `DeviceProfile` plus a
// handful of REAL, hand-labeled captured reports (grab them with `nib capture` — see
// docs/ADDING-A-DEVICE.md). `ProfileConformanceTests` then asserts the profile decodes
// every fixture correctly, so a new profile is validated against actual hardware output
// without the maintainer ever needing the device.
//
// To add a device: append a `DeviceFixtureBundle` to `DeviceFixtures.all`. Fill in only
// the expected fields you can label with confidence (leave the rest nil).

/// One captured pen report and the decoded values it should produce. Optional fields are
/// asserted only when non-nil, so you assert exactly what you labeled.
struct PenFixture {
    let name: String
    let hex: String            // space-separated hex bytes, report-ID byte first
    var tipDown: Bool?
    var inRange: Bool?
    var x: Int?
    var y: Int?
    var pressure: Int?
    var serial: UInt32?
}

/// One captured touch report and the decoded values it should produce.
struct TouchFixture {
    let name: String
    let hex: String
    var contactCount: Int?
    var firstX: Int?
    var firstY: Int?
    var contactIDs: [Int]?
}

/// A device's profile plus the captured gestures that validate it.
struct DeviceFixtureBundle {
    let profile: DeviceProfile
    let pen: [PenFixture]
    let touch: [TouchFixture]
}

enum DeviceFixtures {
    /// Every device the test suite validates. Append new bundles here.
    static let all: [DeviceFixtureBundle] = [dth2420]

    /// Wacom Cintiq Pro 24 Touch (DTH2420) — the reference device. Captures are the same
    /// real reports used elsewhere in the suite (corners, press, hover, lift, N-finger).
    static let dth2420 = DeviceFixtureBundle(
        profile: .dth2420,
        pen: [
            PenFixture(name: "center press",
                       hex: "10 61 fa c3 00 2d 69 00 51 0b f4 01 00 00 00 00 20 11 22 33 44 42 08 10 00 42 08",
                       tipDown: true, inRange: true, x: 0x00c3fa, y: 0x00692d, pressure: 0x0b51,
                       serial: 0x44332211),
            PenFixture(name: "bottom-right hover",
                       hex: "10 60 26 98 01 87 e5 00 00 00 ff f1 00 00 00 00 2d 11 22 33 44 42 08 10 00 42 08",
                       tipDown: false, inRange: true, x: 0x019826, y: 0x00e587, pressure: 0),
            PenFixture(name: "lifted out of range",
                       hex: "10 00 32 c0 00 b7 66 00 00 00 00 00 00 00 00 00 3f 11 22 33 44 42 08 10 00 42 08",
                       tipDown: false, inRange: false),
        ],
        touch: [
            TouchFixture(name: "one finger",
                         hex: "81 01 00 ec 25 aa 09 ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 33 00 01",
                         contactCount: 1, firstX: 0x25ec, firstY: 0x09aa, contactIDs: [0]),
            TouchFixture(name: "three fingers",
                         hex: "81 01 00 6d 1c 7e 06 01 01 be 17 bc 05 01 02 fa 19 98 10 ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 6e 17 03",
                         contactCount: 3, contactIDs: [0, 1, 2]),
        ])
}
