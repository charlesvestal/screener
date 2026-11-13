import XCTest
@testable import Screener

final class SmokeTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(Data(hex: "00ff10").hex, "00ff10")
    }
}
