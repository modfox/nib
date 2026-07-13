import XCTest
@testable import WacomDriverCore

final class PressureCurveTests: XCTestCase {
    func testLinearIsIdentity() {
        let c = PressureCurve.linear
        for v in [0.0, 0.1, 0.5, 0.9, 1.0] {
            XCTAssertEqual(c.evaluate(v), v, accuracy: 0.0001)
        }
    }

    func testClampsInput() {
        let c = PressureCurve.linear
        XCTAssertEqual(c.evaluate(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(c.evaluate(2), 1, accuracy: 0.0001)
    }

    func testSoftCurveRaisesLowEnd() {
        // A curve that outputs more pressure for light input (soft feel).
        let c = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.75), .init(x: 1, y: 1)])
        XCTAssertEqual(c.evaluate(0.25), 0.375, accuracy: 0.0001)  // halfway up the first segment
        XCTAssertEqual(c.evaluate(0.5), 0.75, accuracy: 0.0001)
        XCTAssertGreaterThan(c.evaluate(0.25), 0.25)               // more output than linear
    }
}
