import XCTest
import CoreGraphics
@testable import NibCore

final class TouchGestureTests: XCTestCase {
    private var sink: RecordingSink!
    private var clock: TestClock!
    private var engine: TouchGestureEngine!
    private var swipes: [Int] = []

    override func setUp() {
        sink = RecordingSink(); clock = TestClock(); swipes = []
        let clock = self.clock!
        engine = TouchGestureEngine(sink: sink, now: { clock.t })
        engine.tapMapping = DisplayMapping(targetBounds: CGRect(x: 0, y: 0, width: 1536, height: 864),
                                           xMax: 15360, yMax: 8640)
        engine.onSwipe = { [unowned self] in self.swipes.append($0) }
    }

    func testQuickTapClicksAtMappedPoint() {
        engine.handle(frame([(7680, 4320)]))
        clock.advance(0.1)
        engine.handle(frame([]))
        XCTAssertEqual(sink.types, [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(sink.events[0].location, CGPoint(x: 768, y: 432))
    }

    func testSlowTouchIsNotATap() {
        engine.handle(frame([(7680, 4320)]))
        clock.advance(0.5)
        engine.handle(frame([]))
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testTwoFingerMoveScrollsAfterSettle() {
        engine.handle(frame([(5000, 4000), (6000, 4000)]))   // landing: not yet settled
        clock.advance(0.1)
        engine.handle(frame([(5000, 4000), (6000, 4000)]))   // settled: records centroid
        XCTAssertTrue(sink.events.isEmpty)
        clock.advance(0.01)
        engine.handle(frame([(5000, 4100), (6000, 4100)]))   // move → scroll
        XCTAssertEqual(sink.types, [.scrollWheel])
    }

    func testThreeFingerSwipeFiresOnce() {
        engine.handle(frame([(4000, 4000), (5000, 4000), (6000, 4000)]))
        clock.advance(0.05)
        engine.handle(frame([(6000, 4000), (7000, 4000), (8000, 4000)]))   // +2000 right
        clock.advance(0.05)
        engine.handle(frame([(8000, 4000), (9000, 4000), (10000, 4000)]))
        XCTAssertEqual(swipes, [123])
        XCTAssertFalse(sink.types.contains(.scrollWheel))
    }

    func testPenProximityBlocksTouch() {
        engine.setPenInProximity(true)
        engine.handle(frame([(7680, 4320)]))
        clock.advance(0.1)
        engine.handle(frame([]))
        XCTAssertTrue(sink.events.isEmpty)
    }
}
