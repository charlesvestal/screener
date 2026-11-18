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

    func testInflaterGrowsOutputForHighRatioInput() throws {
        // 1 MB of zeros compresses to ~1 KB, so a single inflate call has to
        // loop over many output chunks.
        let raw = Data(count: 1 << 20)
        let z = try Zlib.Deflater().compress(raw)
        XCTAssertLessThan(z.count, 4096)
        let out = try Zlib.Inflater().inflate(z)
        XCTAssertEqual(out.count, raw.count)
        XCTAssertEqual(out, raw)
    }

    func testInputAfterStreamEndIsIgnored() throws {
        // Final stored block + Adler-32 trailer (Z_STREAM_END), then junk.
        let raw = Data("hello".utf8)
        var z = Data([0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff]) + raw
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        z += Data([UInt8(adler >> 24), UInt8(adler >> 16 & 0xff), UInt8(adler >> 8 & 0xff), UInt8(adler & 0xff)])
        let inflater = try Zlib.Inflater()
        XCTAssertEqual(try inflater.inflate(z + Data([0xde, 0xad, 0xbe, 0xef])), raw)
        XCTAssertEqual(try inflater.inflate(Data([1, 2, 3])), Data(), "stream already ended")
    }

    func testInflateRejectsGarbage() {
        XCTAssertThrowsError(try Zlib.inflate(Data([0x12, 0x34, 0x56, 0x78])))
    }

    // MARK: output cap (security review M1)

    /// A zlib bomb: `megabytes` MB of zeros, deflated (~1 KB per MB).
    static func bomb(megabytes: Int) throws -> Data {
        let d = try Zlib.Deflater()
        let mb = Data(count: 1 << 20)
        var z = Data()
        for _ in 0..<megabytes { z += try d.compress(mb) }
        return z
    }

    /// Peak physical footprint of this process so far (bytes).
    static func peakFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(max(0, info.ledger_phys_footprint_peak)) : 0
    }

    func testInflateStopsAtTheOutputCap() throws {
        let raw = Data((0..<5000).map { UInt8($0 & 0xff) })
        let z = try Zlib.Deflater().compress(raw)
        XCTAssertEqual(try Zlib.inflate(z, maxOutput: 5000), raw, "exactly at the cap is fine")
        XCTAssertThrowsError(try Zlib.inflate(z, maxOutput: 4999)) {
            XCTAssertEqual($0 as? ZlibError, .outputLimit(4999))
        }
    }

    func testZlibBombIsRejectedWithoutABigAllocation() throws {
        let z = try Self.bomb(megabytes: 512)        // ~512 KB in, 512 MB out
        XCTAssertLessThan(z.count, 1 << 20)
        let before = Self.peakFootprint()
        XCTAssertThrowsError(try Zlib.inflate(z, maxOutput: 1 << 20)) {
            XCTAssertEqual($0 as? ZlibError, .outputLimit(1 << 20))
        }
        let grew = Self.peakFootprint() &- before
        XCTAssertLessThan(grew, 64 << 20, "peak footprint grew \(grew >> 20) MB; the cap must stop inflation early")
    }
}
