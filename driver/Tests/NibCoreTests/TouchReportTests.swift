import XCTest
@testable import NibCore

final class TouchReportTests: XCTestCase {
    func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    // Real captured 1-finger report.
    func testOneFinger() throws {
        let r = hex("81 01 00 ec 25 aa 09 ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 33 00 01")
        let f = try XCTUnwrap(TouchReport.parse(r))
        XCTAssertEqual(f.contactCount, 1)
        XCTAssertEqual(f.contacts.count, 1)
        XCTAssertEqual(f.contacts[0].id, 0)
        XCTAssertTrue(f.contacts[0].down)
        XCTAssertEqual(f.contacts[0].x, 0x25ec)   // 9708
        XCTAssertEqual(f.contacts[0].y, 0x09aa)   // 2474
    }

    // Real captured 2-finger report (padded to the 64-byte report length).
    func testTwoFingers() throws {
        var r = hex("81 01 00 a3 1b af 07 01 01 3d 17 9e 07")
        r += [UInt8](repeating: 0xff, count: 64 - r.count - 3)
        r += [0x9a, 0x00, 0x02]
        let f = try XCTUnwrap(TouchReport.parse(r))
        XCTAssertEqual(f.contactCount, 2)
        XCTAssertEqual(f.contacts.count, 2)
        XCTAssertEqual(f.contacts[0].id, 0); XCTAssertEqual(f.contacts[0].x, 0x1ba3)
        XCTAssertEqual(f.contacts[1].id, 1); XCTAssertEqual(f.contacts[1].x, 0x173d)
    }

    // Real captured 3-finger report.
    func testThreeFingers() throws {
        let r = hex("81 01 00 6d 1c 7e 06 01 01 be 17 bc 05 01 02 fa 19 98 10 ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 6e 17 03")
        let f = try XCTUnwrap(TouchReport.parse(r))
        XCTAssertEqual(f.contactCount, 3)
        XCTAssertEqual(f.contacts.map { $0.id }, [0, 1, 2])
    }

    func testRejectsWrongID() {
        XCTAssertNil(TouchReport.parse([UInt8](repeating: 0x10, count: 64)))
    }
}
