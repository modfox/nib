import XCTest
import CoreGraphics
@testable import NibCore

final class EventEmitterTests: XCTestCase {
    private func sample(tip: Bool = false, barrel: Bool = false, secondary: Bool = false,
                        inRange: Bool = true, x: Int = 52643, y: Int = 29787) -> PenSample {
        PenSample(tipDown: tip, barrelButton: barrel, secondaryBarrel: secondary, eraser: false,
                  inverted: false, inRange: inRange, x: x, y: y, pressure: tip ? 4000 : 0,
                  tiltX: 0, tiltY: 0, twist: 0, distance: 0, serial: 0, toolID: 0)
    }
    private func makeEmitter(_ sink: RecordingSink) -> EventEmitter {
        EventEmitter(mapping: DisplayMapping(targetBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                     sink: sink)
    }

    func testLeavingProximityWithTipDownReleasesTip() {
        let sink = RecordingSink(), em = makeEmitter(sink)
        em.handle(sample(tip: true))
        em.handle(sample(inRange: false, x: 0, y: 0))
        XCTAssertEqual(sink.clicks.map { $0.type }, [.leftMouseDown, .leftMouseUp])
        // Released where the pen last was, not at the out-of-range sample's (0,0).
        XCTAssertEqual(sink.clicks.last!.location, sink.clicks.first!.location)
        XCTAssertEqual(sink.types.last, .tabletProximity)
    }

    func testResetMidStrokeReleasesEverything() {
        let sink = RecordingSink(), em = makeEmitter(sink)
        em.handle(sample(tip: true, barrel: true, secondary: true))
        sink.clear()
        em.reset()
        XCTAssertEqual(Set(sink.clicks.map { $0.type.rawValue }),
                       Set([CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp].map { $0.rawValue }))
        XCTAssertEqual(sink.types.last, .tabletProximity)
        sink.clear()
        em.reset()                       // idempotent: nothing left to release
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testPenDoubleTapIsADoubleClick() {
        let sink = RecordingSink(), clock = TestClock()
        let em = EventEmitter(mapping: DisplayMapping(targetBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                              sink: sink, now: { clock.t })
        em.handle(sample(tip: true)); em.handle(sample())
        clock.advance(0.2)
        em.handle(sample(tip: true)); em.handle(sample())
        let states = sink.clicks.map { $0.getIntegerValueField(.mouseEventClickState) }
        XCTAssertEqual(states, [1, 1, 2, 2])
    }
}
