import XCTest
@testable import Screener

final class ZlibTests: XCTestCase {
    private var compressed = Data()
    private var inner = Data()

    override func setUpWithError() throws {
        let c = try Fixture.load("clipboard")
        compressed = Data(hex: c["build_clipboard_send"] as! String).dropFirst(16)
        compressed = Data(compressed)
        inner = Data(hex: (c["roundtrip"] as! [String: Any])["decompressed"] as! String)
    }

    func testInflateReferenceSyncFlushBlob() throws {
        // Reference zlib output ends with Z_SYNC_FLUSH (00 00 ff ff), no Z_FINISH.
        XCTAssertEqual(compressed.suffix(4).hex, "0000ffff")
        XCTAssertEqual(try Zlib.inflate(compressed), inner)
    }

    func testInflaterAcceptsArbitraryChunks() throws {
        let inflater = try Zlib.Inflater()
        var out = Data()
        for start in stride(from: 0, to: compressed.count, by: 7) {
            out += try inflater.inflate(compressed[start..<min(start + 7, compressed.count)])
        }
        XCTAssertEqual(out, inner)
    }

    func testPersistentStreamAcrossMessages() throws {
        // RFB zlib keeps one deflate stream across rectangles: the second
        // message may back-reference the first, so it only inflates on the
        // same stream.
        let deflater = try Zlib.Deflater()
        let a = Data(String(repeating: "screener ", count: 40).utf8)
        let b = Data(String(repeating: "screener ", count: 40).utf8) + Data("tail".utf8)
        let za = try deflater.compress(a)
        let zb = try deflater.compress(b)
        XCTAssertLessThan(zb.count, 20, "second chunk is mostly back-references")
        let inflater = try Zlib.Inflater()
        XCTAssertEqual(try inflater.inflate(za), a)
        XCTAssertEqual(try inflater.inflate(zb), b)
        XCTAssertThrowsError(try Zlib.inflate(zb), "a fresh stream can't decode a mid-stream chunk")
    }

    func testDeflaterMatchesReferenceClipboardBytes() throws {
        // clipboard.build_clipboard_send: compressobj(Z_DEFAULT_COMPRESSION, DEFLATED, 15) + Z_SYNC_FLUSH
        XCTAssertEqual(try Zlib.Deflater().compress(inner).hex, compressed.hex)
    }

    func testInflateRejectsGarbage() {
        XCTAssertThrowsError(try Zlib.inflate(Data([0x12, 0x34, 0x56, 0x78])))
    }
}
