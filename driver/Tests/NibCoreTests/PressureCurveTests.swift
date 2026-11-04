import Foundation
import XCTest
@testable import NibCore

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

final class PressureCurveCodableTests: XCTestCase {
    func testEncodesOnlyPointsAndRoundTrips() throws {
        let curve = PressureCurve(points: [.init(x: 1, y: 1), .init(x: 0, y: 0), .init(x: 0.5, y: 0.8)])
        let data = try JSONEncoder().encode(curve)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Array(json.keys), ["points"])
        let back = try JSONDecoder().decode(PressureCurve.self, from: data)
        XCTAssertEqual(back, curve)
        XCTAssertEqual(back.evaluate(0.25), 0.4, accuracy: 1e-9)   // unsorted input still evaluates
    }

    func testEditingPointsKeepsEvaluationInSync() {
        var curve = PressureCurve.linear
        curve.points[2] = .init(x: 0.5, y: 0.9)
        XCTAssertEqual(curve.evaluate(0.5), 0.9, accuracy: 1e-9)
    }
}

final class NibConfigTests: XCTestCase {
    func testNaturalScrollingOverrideAndSystemFallback() {
        let d = UserDefaults(suiteName: "nib-tests-\(UUID().uuidString)")!
        var c = NibConfig()
        XCTAssertTrue(c.effectiveNaturalScrolling(defaults: d))         // unset → macOS default
        d.set(false, forKey: "com.apple.swipescrolldirection")
        XCTAssertFalse(c.effectiveNaturalScrolling(defaults: d))        // follows the system
        c.naturalScrolling = true
        XCTAssertTrue(c.effectiveNaturalScrolling(defaults: d))         // explicit override wins
    }
}
