import XCTest
import CoreGraphics
@testable import NibCore

final class ClickCounterTests: XCTestCase {
    func testDoubleAndTripleClickWithinInterval() {
        var c = ClickCounter(interval: 0.5)
        XCTAssertEqual(c.down(at: .zero, time: 0), 1)
        XCTAssertEqual(c.down(at: CGPoint(x: 2, y: 2), time: 0.3), 2)
        XCTAssertEqual(c.down(at: .zero, time: 0.6), 3)
    }

    func testResetsAfterTimeout() {
        var c = ClickCounter(interval: 0.5)
        _ = c.down(at: .zero, time: 0)
        XCTAssertEqual(c.down(at: .zero, time: 0.8), 1)
    }

    func testResetsWhenTooFarApart() {
        var c = ClickCounter(interval: 0.5, maxDistance: 6)
        _ = c.down(at: .zero, time: 0)
        XCTAssertEqual(c.down(at: CGPoint(x: 50, y: 0), time: 0.1), 1)
    }
}
