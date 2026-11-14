import XCTest
@testable import Screener

final class RecordLayerTests: XCTestCase {
    func testMatchesReference() throws {
        let f = try Fixture.load("record_layer")
        let blob = Data(hex: f["key_blob_36"] as! String)
        let wrap = Data(hex: f["ecb_key"] as! String)
        let records = f["client_records"] as! [[String: String]]
        let tx = try RecordLayer(rekeyBody: blob, wrapKey: wrap)
        XCTAssertEqual(tx.contentKey.hex, f["cbc_key"] as! String)
        let rx = try RecordLayer(rekeyBody: blob, wrapKey: wrap)
        for r in records {
            let wire = try tx.seal(Data(hex: r["plaintext"]!))
            XCTAssertEqual(wire.hex, r["wire"]!)
            XCTAssertEqual(try rx.open(ciphertext: wire.dropFirst(2)).hex, r["plaintext"]!, "sender CBC == receiver CBC")
        }
    }

    func testIntegrityFailure() throws {
        let tx = try RecordLayer(rekeyBody: Data(count: 36), wrapKey: Data(count: 16))
        let rx = try RecordLayer(rekeyBody: Data(count: 36), wrapKey: Data(count: 16))
        var wire = try tx.seal(Data([0x03, 0x00]))
        wire[5] ^= 0xff
        XCTAssertThrowsError(try rx.open(ciphertext: wire.dropFirst(2)))
    }

    func testFrameSplitter() throws {
        var s = FrameSplitter()
        let frame = Data([0x00, 0x20]) + Data(count: 32)
        XCTAssertEqual(try s.push(frame.prefix(10)).count, 0)
        XCTAssertEqual(try s.push(frame.dropFirst(10) + frame).count, 2)
        XCTAssertThrowsError(try s.push(Data([0x00, 0x11])))
    }
}
