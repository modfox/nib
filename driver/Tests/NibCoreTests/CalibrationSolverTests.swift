import XCTest
import CoreGraphics
@testable import NibCore

final class CalibrationSolverTests: XCTestCase {
    private let t1 = CGPoint(x: 0.1, y: 0.1), t2 = CGPoint(x: 0.9, y: 0.9)

    private func pen(tip: Bool, x: Int = 0, y: Int = 0) -> PenSample {
        PenSample(tipDown: tip, barrelButton: false, secondaryBarrel: false, eraser: false,
                  inverted: false, inRange: true, x: x, y: y, pressure: tip ? 3000 : 0,
                  tiltX: 0, tiltY: 0, twist: 0, distance: 0, serial: 0, toolID: 0)
    }

    func testSolveRecoversTheRange() {
        // Raw range 1000...101000 (x) and 2000...52000 (y) → targets at 10% / 90%.
        let cal = CalibrationSolver.solve(raw1: (11000, 7000), raw2: (91000, 47000),
                                          target1: t1, target2: t2,
                                          xLogicalMax: 105286, yLogicalMax: 59574)
        XCTAssertEqual(cal!.xMin, 1000, accuracy: 1e-6)
        XCTAssertEqual(cal!.xMax, 101000, accuracy: 1e-6)
        XCTAssertEqual(cal!.yMin, 2000, accuracy: 1e-6)
        XCTAssertEqual(cal!.yMax, 52000, accuracy: 1e-6)
    }

    func testRejectsPointsTooClose() {
        XCTAssertNil(CalibrationSolver.solve(raw1: (50000, 30000), raw2: (50500, 30500),
                                             target1: t1, target2: t2,
                                             xLogicalMax: 105286, yLogicalMax: 59574))
    }

    func testRejectsReversedPoints() {
        XCTAssertNil(CalibrationSolver.solve(raw1: (91000, 47000), raw2: (11000, 7000),
                                             target1: t1, target2: t2,
                                             xLogicalMax: 105286, yLogicalMax: 59574))
    }

    func testStateMachineNeedsASteadyHoldThenLift() {
        var s = CalibrationSolver(target1: t1, target2: t2, pen: .dth2420)
        for _ in 0..<39 { XCTAssertEqual(s.feed(pen(tip: true, x: 11000, y: 7000)), .none) }
        XCTAssertEqual(s.feed(pen(tip: true, x: 11000, y: 7000)), .firstCaptured)
        XCTAssertEqual(s.feed(pen(tip: true, x: 11000, y: 7000)), .none)     // still down: ignored
        XCTAssertEqual(s.feed(pen(tip: false)), .awaitingSecond)
        for _ in 0..<39 { _ = s.feed(pen(tip: true, x: 91000, y: 47000)) }
        guard case .finished = s.feed(pen(tip: true, x: 91000, y: 47000)) else {
            return XCTFail("expected a finished calibration")
        }
    }

    func testSamePointTwiceIsRejectedAndRestarts() {
        var s = CalibrationSolver(target1: t1, target2: t2, pen: .dth2420)
        for _ in 0..<40 { _ = s.feed(pen(tip: true, x: 50000, y: 30000)) }
        _ = s.feed(pen(tip: false))
        var last = CalibrationSolver.Event.none
        for _ in 0..<40 { last = s.feed(pen(tip: true, x: 50000, y: 30000)) }
        XCTAssertEqual(last, .rejected)
        XCTAssertEqual(s.currentTarget, t1)
    }

    func testDegenerateMappingDoesNotProduceNaN() {
        let m = DisplayMapping(targetBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                               xMin: 500, xMax: 500, yMin: 0, yMax: 1000)
        let p = m.point(x: 700, y: 500)
        XCTAssertFalse(p.x.isNaN)
        XCTAssertEqual(p.y, 50, accuracy: 1e-9)
    }
}
