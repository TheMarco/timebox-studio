import XCTest
import TimeboxKit

final class PixelFrameTests: XCTestCase {
    func testDefaultFrameIsSixteenBySixteenBlack() {
        let frame = PixelFrame()
        XCTAssertEqual(frame.pixels.count, 256)
        XCTAssertEqual(frame.pixels.first, PixelRGB(red: 0, green: 0, blue: 0))
    }

    func testRejectsInvalidPixelCount() {
        XCTAssertThrowsError(try PixelFrame(pixels: [])) { error in
            XCTAssertEqual(error as? PixelFrameError, .invalidPixelCount(expected: 256, actual: 0))
        }
    }
}
