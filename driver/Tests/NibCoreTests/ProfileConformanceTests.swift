import XCTest
@testable import NibCore

/// Data-driven validation: every registered device profile must decode its real captured
/// gestures (see DeviceFixtures.swift). Adding a device with fixtures automatically adds
/// its coverage here — no per-device test code. This is what lets a maintainer accept a
/// new profile with confidence without owning the hardware.
final class ProfileConformanceTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    func testEveryProfileIsRegistered() {
        // Each fixture bundle's profile should also be in DeviceProfile.all, so detection
        // and decoding stay in sync.
        for bundle in DeviceFixtures.all {
            XCTAssertTrue(DeviceProfile.all.contains { $0.name == bundle.profile.name },
                          "\(bundle.profile.name) has fixtures but is not in DeviceProfile.all")
        }
    }

    func testPenFixturesDecode() {
        for bundle in DeviceFixtures.all {
            let p = bundle.profile
            for f in bundle.pen {
                let label = "\(p.name) / pen '\(f.name)'"
                guard let s = PenReport.parse(hex(f.hex), p.pen) else {
                    XCTFail("\(label): failed to parse"); continue
                }
                if let v = f.tipDown  { XCTAssertEqual(s.tipDown, v, "\(label): tipDown") }
                if let v = f.inRange  { XCTAssertEqual(s.inRange, v, "\(label): inRange") }
                if let v = f.x        { XCTAssertEqual(s.x, v, "\(label): x") }
                if let v = f.y        { XCTAssertEqual(s.y, v, "\(label): y") }
                if let v = f.pressure { XCTAssertEqual(s.pressure, v, "\(label): pressure") }
                if let v = f.serial   { XCTAssertEqual(s.serial, v, "\(label): serial") }
            }
        }
    }

    func testTouchFixturesDecode() {
        for bundle in DeviceFixtures.all {
            let p = bundle.profile
            for f in bundle.touch {
                let label = "\(p.name) / touch '\(f.name)'"
                guard let frame = TouchReport.parse(hex(f.hex), p.touch) else {
                    XCTFail("\(label): failed to parse"); continue
                }
                if let v = f.contactCount { XCTAssertEqual(frame.contactCount, v, "\(label): contactCount") }
                if let v = f.contactIDs   { XCTAssertEqual(frame.contacts.map { $0.id }, v, "\(label): contact IDs") }
                if let v = f.firstX { XCTAssertEqual(frame.contacts.first?.x, v, "\(label): first contact x") }
                if let v = f.firstY { XCTAssertEqual(frame.contacts.first?.y, v, "\(label): first contact y") }
            }
        }
    }
}
