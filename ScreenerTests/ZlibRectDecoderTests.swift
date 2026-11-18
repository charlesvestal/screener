import Compression
import CoreVideo
import XCTest
@testable import Screener

/// TCP-only fallback (Task 19): RFB zlib / raw rects → BGRA framebuffer.
final class ZlibRectDecoderTests: XCTestCase {

    /// `n` BGRX pixels whose bytes identify their index (native BGRA format).
    private func pixels(_ n: Int, seed: UInt8 = 0) -> Data {
        var d = Data()
        for i in 0..<n { d.append(contentsOf: [UInt8(truncatingIfNeeded: i) &+ seed, UInt8(i >> 8), 0x40 &+ seed, 0]) }
        return d
    }

    /// The expected BGRA bytes of `pixels` (alpha forced to 255).
    private func opaque(_ d: Data) -> [UInt8] {
        var b = [UInt8](d)
        for i in stride(from: 3, to: b.count, by: 4) { b[i] = 255 }
        return b
    }

    private func row(_ dec: ZlibRectDecoder, _ y: Int, x: Int, count: Int) -> [UInt8] {
        let o = (y * dec.width + x) * 4
        return Array(dec.pixels[o..<o + count * 4])
    }

    /// Compression framework raw deflate with a zlib header (78 01), as the
    /// task asks: a one-shot stream (final block, no Adler-32 needed).
    private func compressionFrameworkZlib(_ raw: Data) -> Data {
        let cap = raw.count + 1024
        var out = [UInt8](repeating: 0, count: cap)
        let n = raw.withUnsafeBytes { src in
            compression_encode_buffer(&out, cap, src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil,
                                      COMPRESSION_ZLIB)
        }
        XCTAssertGreaterThan(n, 0)
        return Data([0x78, 0x01]) + Data(out[0..<n])
    }

    // MARK: decoding

    func testDecodes4x2RectAtItsOffset() throws {
        let dec = try ZlibRectDecoder(width: 10, height: 6, format: .bgra32)
        let raw = pixels(8, seed: 7)
        try dec.decodeZlib(x: 3, y: 2, w: 4, h: 2, payload: compressionFrameworkZlib(raw))
        let want = opaque(raw)
        XCTAssertEqual(row(dec, 2, x: 3, count: 4), Array(want[0..<16]))
        XCTAssertEqual(row(dec, 3, x: 3, count: 4), Array(want[16..<32]))
        // Untouched pixels stay opaque black.
        XCTAssertEqual(row(dec, 2, x: 2, count: 1), [0, 0, 0, 255])
        XCTAssertEqual(row(dec, 4, x: 3, count: 1), [0, 0, 0, 255])
        XCTAssertTrue(dec.takeDirty())
        XCTAssertFalse(dec.takeDirty())
    }

    /// ONE zlib stream for the whole connection: the second rect's payload
    /// refers back into the first's window, so it only decodes on the same
    /// inflater (a fresh one fails).
    func testPersistentStreamAcrossRects() throws {
        let deflater = try Zlib.Deflater()
        let raw = pixels(64, seed: 3)
        let first = try deflater.compress(raw)
        let second = try deflater.compress(raw)          // back-reference to the first
        XCTAssertLessThan(second.count, first.count)

        let dec = try ZlibRectDecoder(width: 16, height: 8, format: .bgra32)
        try dec.decodeZlib(x: 0, y: 0, w: 16, h: 4, payload: first)
        try dec.decodeZlib(x: 0, y: 4, w: 16, h: 4, payload: second)
        XCTAssertEqual(row(dec, 0, x: 0, count: 16), Array(opaque(raw)[0..<64]))
        XCTAssertEqual(row(dec, 7, x: 0, count: 16), Array(opaque(raw)[192..<256]))
        XCTAssertEqual(dec.rectsDecoded, 2)

        let fresh = try ZlibRectDecoder(width: 16, height: 8, format: .bgra32)
        XCTAssertThrowsError(try fresh.decodeZlib(x: 0, y: 0, w: 16, h: 4, payload: second))
    }

    /// A rect bigger than one inflate chunk decodes exactly.
    func testLargeRectSpanningManyChunks() throws {
        let deflater = try Zlib.Deflater()
        let (w, h) = (300, 200)
        let raw = pixels(w * h, seed: 1)
        let dec = try ZlibRectDecoder(width: w, height: h, format: .bgra32)
        try dec.decodeZlib(x: 0, y: 0, w: w, h: h, payload: try deflater.compress(raw))
        XCTAssertEqual(dec.pixels, opaque(raw))
    }

    // MARK: pixel formats

    func testServerInitPixelFormatRoundTrip() throws {
        let f = RFBPixelFormat.bgra32
        XCTAssertEqual(f.data.count, 16)
        XCTAssertEqual(RFBPixelFormat(f.data), f)
        XCTAssertEqual(f.data.hex, "2018000100ff00ff00ff100800000000")
        XCTAssertNil(RFBPixelFormat(Data(count: 15)))
        XCTAssertFalse(RFBPixelFormat(Data(count: 16))!.isDecodable)   // bpp 0
    }

    /// Big-endian 32-bit, R at shift 0, B at shift 16 (RGBX in memory reversed).
    func testConvertsBigEndianSwappedShifts() throws {
        let f = RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: true, trueColour: true, redMax: 255,
                               greenMax: 255, blueMax: 255, redShift: 0, greenShift: 8, blueShift: 16)
        XCTAssertTrue(f.isDecodable)
        XCTAssertFalse(f.isNativeBGRA)
        // v = B<<16 | G<<8 | R = 0x00_30_20_10 big-endian → bytes 00 30 20 10.
        let raw = Data([0x00, 0x30, 0x20, 0x10])
        let dec = try ZlibRectDecoder(width: 1, height: 1, format: f)
        try dec.decodeRaw(x: 0, y: 0, w: 1, h: 1, data: raw)
        XCTAssertEqual(dec.pixels, [0x30, 0x20, 0x10, 255])   // B, G, R, A
    }

    /// 5-bit channels are scaled to 0…255.
    func testScalesNarrowChannels() throws {
        let f = RFBPixelFormat(bitsPerPixel: 32, depth: 15, bigEndian: false, trueColour: true, redMax: 31,
                               greenMax: 31, blueMax: 31, redShift: 10, greenShift: 5, blueShift: 0)
        let v: UInt32 = 31 << 10 | 0 << 5 | 16   // R max, G 0, B ~half
        var raw = Data(); withUnsafeBytes(of: v.littleEndian) { raw.append(contentsOf: $0) }
        let dec = try ZlibRectDecoder(width: 1, height: 1, format: f)
        let z = try Zlib.Deflater().compress(raw)
        try dec.decodeZlib(x: 0, y: 0, w: 1, h: 1, payload: z)
        XCTAssertEqual(dec.pixels, [132, 0, 255, 255])
    }

    func testUnsupportedPixelFormatIsRefused() {
        let f = RFBPixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: false, trueColour: true, redMax: 31,
                               greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
        XCTAssertThrowsError(try ZlibRectDecoder(width: 4, height: 4, format: f)) {
            XCTAssertEqual($0 as? FramebufferDecodeError, .unsupportedPixelFormat)
        }
        // ControlSession then asks for BGRA with SetPixelFormat.
        let pick = ControlSession.framebufferPixelFormat(serverInit: f.data)
        XCTAssertEqual(pick.format, .bgra32)
        XCTAssertTrue(pick.needsSet)
        let native = ControlSession.framebufferPixelFormat(serverInit: RFBPixelFormat.bgra32.data)
        XCTAssertFalse(native.needsSet)
    }

    // MARK: bounds / hostile input (never traps)

    func testRectPartlyOutsideIsClippedAndStreamStaysInSync() throws {
        let deflater = try Zlib.Deflater()
        let dec = try ZlibRectDecoder(width: 4, height: 4, format: .bgra32)
        let raw = pixels(16, seed: 9)
        try dec.decodeZlib(x: 2, y: 2, w: 4, h: 4, payload: try deflater.compress(raw))   // 2×2 visible
        XCTAssertEqual(row(dec, 2, x: 2, count: 2), Array(opaque(raw)[0..<8]))
        XCTAssertEqual(row(dec, 3, x: 2, count: 2), Array(opaque(raw)[16..<24]))
        // Entirely outside: inflated (stream in sync), nothing written.
        try dec.decodeZlib(x: 100, y: 100, w: 4, h: 4, payload: try deflater.compress(raw))
        // The next rect still decodes.
        try dec.decodeZlib(x: 0, y: 0, w: 2, h: 1, payload: try deflater.compress(pixels(2, seed: 5)))
        XCTAssertEqual(row(dec, 0, x: 0, count: 2), opaque(pixels(2, seed: 5)))
        XCTAssertFalse(dec.isBroken)
    }

    func testHostileRectSizesAreRefusedWithoutTrapping() throws {
        let dec = try ZlibRectDecoder(width: 8, height: 8, format: .bgra32)
        XCTAssertThrowsError(try dec.decodeZlib(x: 0, y: 0, w: 65535, h: 65535, payload: Data([0x78, 0x01]))) {
            XCTAssertEqual($0 as? FramebufferDecodeError, .rectTooLarge(width: 65535, height: 65535))
        }
        XCTAssertTrue(dec.isBroken)
        XCTAssertThrowsError(try dec.decodeZlib(x: 0, y: 0, w: 1, h: 1, payload: Data())) {
            XCTAssertEqual($0 as? FramebufferDecodeError, .streamBroken)
        }
        // Raw rects carry their own bytes: a mismatch is dropped, never written.
        let raw = try ZlibRectDecoder(width: 8, height: 8, format: .bgra32)
        XCTAssertThrowsError(try raw.decodeRaw(x: 0, y: 0, w: 4, h: 4, data: Data(count: 10)))
        XCTAssertThrowsError(try raw.decodeRaw(x: 0, y: 0, w: 9000, h: 1, data: Data()))
        try raw.decodeRaw(x: 65535, y: 65535, w: 1, h: 1, data: Data(count: 4))   // clipped away
        XCTAssertFalse(raw.takeDirty())
    }

    /// A payload that inflates to more than w×h×4 (a zlib bomb or a lying
    /// rect) stops at the cap and breaks the stream; less is corrupt too.
    func testInflateSizeMismatchBreaksTheStream() throws {
        let big = try Zlib.Deflater().compress(Data(count: 1 << 20))
        let dec = try ZlibRectDecoder(width: 8, height: 8, format: .bgra32)
        XCTAssertThrowsError(try dec.decodeZlib(x: 0, y: 0, w: 2, h: 2, payload: big))
        XCTAssertTrue(dec.isBroken)

        let short = try Zlib.Deflater().compress(Data(count: 8))
        let dec2 = try ZlibRectDecoder(width: 8, height: 8, format: .bgra32)
        XCTAssertThrowsError(try dec2.decodeZlib(x: 0, y: 0, w: 2, h: 2, payload: short)) {
            guard case .corruptStream = $0 as? FramebufferDecodeError else { return XCTFail("\($0)") }
        }

        let dec3 = try ZlibRectDecoder(width: 8, height: 8, format: .bgra32)
        XCTAssertThrowsError(try dec3.decodeZlib(x: 0, y: 0, w: 2, h: 2, payload: Data((0..<64).map { UInt8($0) })))
        XCTAssertTrue(dec3.isBroken)
    }

    func testFramebufferSizeCaps() throws {
        XCTAssertThrowsError(try ZlibRectDecoder(width: 0, height: 10, format: .bgra32))
        XCTAssertThrowsError(try ZlibRectDecoder(width: 10, height: ZlibRectDecoder.maxDimension + 1, format: .bgra32))
        let dec = try ZlibRectDecoder(width: 2, height: 2, format: .bgra32)
        XCTAssertThrowsError(try dec.resize(width: 70000, height: 2))
        XCTAssertEqual(dec.width, 2)
    }

    func testResizeKeepsOverlap() throws {
        let dec = try ZlibRectDecoder(width: 2, height: 2, format: .bgra32)
        try dec.decodeRaw(x: 0, y: 0, w: 2, h: 2, data: pixels(4, seed: 2))
        try dec.resize(width: 3, height: 1)
        XCTAssertEqual(dec.pixels, Array(opaque(pixels(4, seed: 2))[0..<8]) + [0, 0, 0, 255])
    }

    // MARK: pipeline → frame store

    func testPipelinePublishesBGRAPictureAtUpdateEnd() throws {
        let store = VideoFrameStore()
        let consumed = LockedValue(0)
        let failed = LockedValue(false)
        let pipeline = FramebufferPipeline(store: store, format: .bgra32, size: (4, 2), hooks: .init(
            updateConsumed: { consumed.value += 1 }, failed: { _ in failed.value = true }))
        let raw = pixels(8, seed: 11)
        pipeline.submit(.zlibRect(x: 0, y: 0, w: 4, h: 2, payload: try Zlib.Deflater().compress(raw)))
        pipeline.drain()
        XCTAssertNil(store.snapshot(ifNewerThan: nil)?.frames[0], "published only at the update end")
        pipeline.submit(.framebufferUpdateEnd)
        pipeline.drain()
        XCTAssertEqual(consumed.value, 1)
        XCTAssertFalse(failed.value)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(snap.tileCount, 1)
        XCTAssertEqual(snap.canvas, CGSize(width: 4, height: 2))
        let pb = try XCTUnwrap(snap.frames[0])
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: base, count: 16)), Array(opaque(raw)[0..<16]))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: base + stride, count: 16)), Array(opaque(raw)[16..<32]))
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        // A layout resizes the store's canvas; an empty update still asks for the next.
        pipeline.submit(.displayLayout(DisplayLayout(payload: Data(hex: "0000" + "0002" + "0001" + "0006" + "0003"))))
        pipeline.submit(.framebufferUpdateEnd)
        pipeline.drain()
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.canvas, CGSize(width: 6, height: 3))
        XCTAssertEqual(consumed.value, 2)
    }

    func testPipelineReportsACorruptStreamOnce() {
        let store = VideoFrameStore()
        let failures = LockedValue(0)
        let pipeline = FramebufferPipeline(store: store, format: .bgra32, size: (4, 4), hooks: .init(
            updateConsumed: {}, failed: { _ in failures.value += 1 }))
        pipeline.submit(.zlibRect(x: 0, y: 0, w: 2, h: 2, payload: Data([1, 2, 3, 4, 5])))
        pipeline.submit(.zlibRect(x: 0, y: 0, w: 2, h: 2, payload: Data([1, 2, 3, 4, 5])))
        pipeline.submit(.framebufferUpdateEnd)
        pipeline.drain()
        XCTAssertEqual(failures.value, 1)
    }
}
