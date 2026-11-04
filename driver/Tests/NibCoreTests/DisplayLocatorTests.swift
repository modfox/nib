import XCTest
import CoreGraphics
@testable import NibCore

final class DisplayLocatorTests: XCTestCase {
    private let k4 = CGSize(width: 3840, height: 2160)

    func testEDIDMatchWinsOverAnotherDisplayWithTheSameSize() {
        let other4K = DisplayLocator.Candidate(id: 2, vendor: 0x1e6d, model: 0x1, nativePixelSize: k4)
        let cintiq = DisplayLocator.Candidate(id: 4, vendor: 0x5c23, model: 0x1056, nativePixelSize: k4)
        XCTAssertEqual(DisplayLocator.choose([other4K, cintiq], for: .dth2420), 4)
    }

    func testFallsBackToNativeSize() {
        var p = DeviceProfile.dth2420
        p.displayModel = 0xdead        // EDID doesn't match anything
        let small = DisplayLocator.Candidate(id: 1, vendor: 0x0610, model: 0xa04f,
                                             nativePixelSize: CGSize(width: 3024, height: 1964))
        let panel = DisplayLocator.Candidate(id: 7, vendor: 0x5c23, model: 0x1056, nativePixelSize: k4)
        XCTAssertEqual(DisplayLocator.choose([small, panel], for: p), 7)
    }

    func testNoMatchReturnsNil() {
        let small = DisplayLocator.Candidate(id: 1, vendor: 0x0610, model: 0xa04f,
                                             nativePixelSize: CGSize(width: 3024, height: 1964))
        XCTAssertNil(DisplayLocator.choose([small], for: .dth2420))
    }
}
