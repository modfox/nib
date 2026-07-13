import XCTest
import CoreGraphics
@testable import NibCore

final class PenReportTests: XCTestCase {
    // Helper: parse a space-separated hex string (a real captured report line).
    func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    // --- Regression tests using REAL reports captured from the DTH2420k0 ---

    func testCenterPress() throws {
        // Center of screen, tip down, moderate pressure.
        let r = hex("10 61 fa c3 00 2d 69 00 51 0b f4 01 00 00 00 00 20 11 22 33 44 42 08 10 00 42 08")
        let s = try XCTUnwrap(PenReport.parse(r))
        XCTAssertEqual(s.x, 0x00c3fa)            // 50170 ≈ half of 105286
        XCTAssertEqual(s.y, 0x00692d)            // 26925 ≈ half of 59574
        XCTAssertEqual(s.pressure, 0x0b51)       // 2897
        XCTAssertTrue(s.tipDown)
        XCTAssertTrue(s.inRange)
        XCTAssertEqual(s.serial, 0x44332211)     // bytes 11 22 33 44 LE
    }

    func testBottomRightHover() throws {
        let r = hex("10 60 26 98 01 87 e5 00 00 00 ff f1 00 00 00 00 2d 11 22 33 44 42 08 10 00 42 08")
        let s = try XCTUnwrap(PenReport.parse(r))
        XCTAssertEqual(s.x, 0x019826)            // 104998 ≈ xMax 105286
        XCTAssertEqual(s.y, 0x00e587)            // 58759 ≈ yMax 59574
        XCTAssertEqual(s.pressure, 0)
        XCTAssertFalse(s.tipDown)
        XCTAssertTrue(s.inRange)
    }

    func testPenLiftedOutOfRange() throws {
        let r = hex("10 00 32 c0 00 b7 66 00 00 00 00 00 00 00 00 00 3f 11 22 33 44 42 08 10 00 42 08")
        let s = try XCTUnwrap(PenReport.parse(r))
        XCTAssertFalse(s.inRange)
        XCTAssertFalse(s.tipDown)
        XCTAssertEqual(s.distance, 0x3f)         // far
    }

    func testRejectsWrongIDOrShort() {
        XCTAssertNil(PenReport.parse([0x01, 0x02, 0x03]))                      // too short
        var wrongID = [UInt8](repeating: 0, count: PenReport.reportLength)
        wrongID[0] = 0x06
        XCTAssertNil(PenReport.parse(wrongID))                                // wrong report ID
    }

    func testMappingCornersAndClamp() {
        let m = DisplayMapping(targetBounds: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        XCTAssertEqual(m.point(x: 0, y: 0), CGPoint(x: 0, y: 0))
        let br = m.point(x: PenSample.xLogicalMax, y: PenSample.yLogicalMax)
        XCTAssertEqual(br.x, 3840, accuracy: 0.5)
        XCTAssertEqual(br.y, 2160, accuracy: 0.5)
        XCTAssertEqual(m.point(x: -100, y: -100), CGPoint(x: 0, y: 0))
    }
}
