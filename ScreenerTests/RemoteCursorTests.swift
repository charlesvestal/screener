import XCTest
@testable import Screener

/// The 0x450 cursor cache (RFC §8.3, session._handle_cursor_rect): BGRA
/// pixmap + separate alpha plane → premultiplied RGBA; STORE / SELECT.
@MainActor
final class RemoteCursorTests: XCTestCase {
    func testAlphaPlaneBecomesPremultipliedRGBA() throws {
        // 3 pixels BGRA (4th byte ignored) + 3 alpha bytes.
        let bgra = Data([0x10, 0x20, 0x30, 0x00,   0xff, 0x80, 0x00, 0x77,   0xff, 0xff, 0xff, 0xff])
        let alpha = Data([0xff, 0x80, 0x00])
        let rgba = try XCTUnwrap(CursorImage.premultipliedRGBA(bgra: bgra, alpha: alpha, pixels: 3))
        XCTAssertEqual([UInt8](rgba), [
            0x30, 0x20, 0x10, 0xff,                 // opaque: R,G,B swapped from B,G,R
            0x00, 0x40, 0x80, 0x80,                 // 50%: (0,128,255)·128/255 rounded
            0x00, 0x00, 0x00, 0x00,                 // transparent
        ])
        XCTAssertNil(CursorImage.premultipliedRGBA(bgra: bgra, alpha: Data([1]), pixels: 3))
    }

    func testStoreSelectAndCacheMiss() {
        let c = RemoteCursor()
        var changes = 0
        c.onChange = { changes += 1 }
        let px = Data(repeating: 0xff, count: 4)
        c.store(id: 7, hotspot: PixelPoint(x: 1, y: 2), size: PixelSize(width: 1, height: 1), bgra: px, alpha: Data([0xff]))
        XCTAssertEqual(c.image?.hotspot, PixelPoint(x: 1, y: 2))
        let first = c.image
        c.store(id: 8, hotspot: PixelPoint(x: 0, y: 0), size: PixelSize(width: 1, height: 1), bgra: px, alpha: Data([0x80]))
        XCTAssertNotEqual(c.image, first)
        c.select(id: 7)
        XCTAssertEqual(c.image, first)
        c.select(id: 99)                 // unknown id: the reference notifies None
        XCTAssertNil(c.image)
        XCTAssertEqual(changes, 4)
    }

    func testCacheIsBoundedTo64Entries() {
        let c = RemoteCursor()
        let px = Data(repeating: 0, count: 4)
        for id in 0..<65 {
            c.store(id: UInt32(id), hotspot: PixelPoint(x: 0, y: 0), size: PixelSize(width: 1, height: 1),
                    bgra: px, alpha: Data([0]))
        }
        c.select(id: 0)
        XCTAssertNil(c.image)            // oldest dropped
        c.select(id: 1)
        XCTAssertNotNil(c.image)
    }

    func testPremultipliedStoreEnforcesTheSizeCapAndLength() {
        let c = RemoteCursor()
        let m = CursorImage.maxDimension
        c.store(id: 1, hotspot: PixelPoint(x: 0, y: 0), size: PixelSize(width: m + 1, height: 1),
                rgba: Data(count: (m + 1) * 4))
        XCTAssertNil(c.image, "wider than maxDimension")
        c.store(id: 2, hotspot: PixelPoint(x: 0, y: 0), size: PixelSize(width: 2, height: 2), rgba: Data(count: 15))
        XCTAssertNil(c.image, "length mismatch")
        c.store(id: 3, hotspot: PixelPoint(x: 0, y: 0), size: PixelSize(width: m, height: m), rgba: Data(count: m * m * 4))
        XCTAssertEqual(c.image?.width, m)
    }

    func testPositionAndVisibility() {
        let c = RemoteCursor()
        var changes = 0
        c.onChange = { changes += 1 }
        c.move(toHostX: 10, y: 20, hostWidth: 100, hostHeight: 50)
        XCTAssertEqual(c.position, CGPoint(x: 10, y: 20))
        c.move(toHostX: 10, y: 20, hostWidth: 100, hostHeight: 50)    // unchanged: no redraw
        XCTAssertEqual(changes, 1)
        c.hide()
        XCTAssertNil(c.position)
        XCTAssertEqual(changes, 2)
        c.reset()
        XCTAssertNil(c.image)
    }
}
