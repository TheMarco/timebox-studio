import XCTest
import TimeboxUtilities

final class HexStringParserTests: XCTestCase {
    func testParsesCommonHexFormats() throws {
        XCTAssertEqual(try HexStringParser.data(from: "AA BB CC"), Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(try HexStringParser.data(from: "0xAA,0xbb:CC"), Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(try HexStringParser.data(from: "aa-bb_cc"), Data([0xAA, 0xBB, 0xCC]))
    }

    func testRejectsOddDigitCount() {
        XCTAssertThrowsError(try HexStringParser.data(from: "ABC")) { error in
            XCTAssertEqual(error as? HexStringParserError, .oddNibbleCount(3))
        }
    }
}
