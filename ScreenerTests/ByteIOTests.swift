import XCTest
@testable import Screener

final class ByteIOTests: XCTestCase {
    func testWriterBigEndian() {
        var w = ByteWriter()
        w.u8(0x1d); w.u8(0); w.u16(304); w.u32(0x01020304); w.f64(60.0); w.u32le(7); w.zeros(2)
        XCTAssertEqual(w.data.hex, "1d00013001020304404e000000000000070000000000")
    }
    func testReaderRoundTripAndUnderflow() throws {
        var r = ByteReader(Data(hex: "0001000000020304"))
        XCTAssertEqual(try r.u16(), 1)
        XCTAssertEqual(try r.u32(), 2)
        XCTAssertEqual(try r.bytes(2).hex, "0304")
        XCTAssertThrowsError(try r.u8())
    }
}
