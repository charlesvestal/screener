// TCP-only fallback (Task 19; RFC §11 Profile A, §12 "media negotiation
// failure → framebuffer path"): the classic RFB framebuffer path, used when
// the HP media stream can't be used.
//
// RFB zlib encoding (RFC 6143 §7.7.x "ZlibEncoding", RFC §8.9.3: `0x06` is
// "32-bit pass-through, deflate 1"): every zlib rect's payload is the next
// slice of ONE zlib stream that lives for the whole connection; inflated,
// it is the rect's pixels in raw encoding (w × h pixels in the session's
// pixel format, row-major). The stream can't be resynchronised, so any
// inflate error, short rect or rect we refuse to inflate breaks it for good
// (`isBroken`; the session must be re-established).
//
// Pixels: the format is ServerInit's (or the one we set with SetPixelFormat
// when ServerInit's isn't 32-bit true colour). Each pixel is converted to
// BGRA8 (alpha 255) and written into a framebuffer of the 0x451 backing size;
// rect parts outside the framebuffer are clipped (still inflated, so the
// stream stays in sync).
//
// Caps (hostile input never traps or balloons memory): the framebuffer is at
// most `maxDimension` per side; a rect wider/taller than that is refused
// (stream broken); inflation is streamed through a ≤ 1 MB chunk straight into
// the framebuffer and stopped at exactly w × h × 4 bytes; all index math is
// bounds-checked before any write.
import Foundation

/// RFB PIXEL_FORMAT (RFC 6143 §7.4): 16 bytes.
struct RFBPixelFormat: Equatable, Sendable {
    var bitsPerPixel: Int
    var depth: Int
    var bigEndian: Bool
    var trueColour: Bool
    var redMax: Int
    var greenMax: Int
    var blueMax: Int
    var redShift: Int
    var greenShift: Int
    var blueShift: Int

    /// 32 bpp little-endian, R<<16 | G<<8 | B: the bytes in memory are
    /// B, G, R, X — BGRA8 as-is. What we ask for with SetPixelFormat.
    static let bgra32 = RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
                                       redMax: 255, greenMax: 255, blueMax: 255,
                                       redShift: 16, greenShift: 8, blueShift: 0)

    init(bitsPerPixel: Int, depth: Int, bigEndian: Bool, trueColour: Bool, redMax: Int, greenMax: Int,
         blueMax: Int, redShift: Int, greenShift: Int, blueShift: Int) {
        self.bitsPerPixel = bitsPerPixel; self.depth = depth; self.bigEndian = bigEndian
        self.trueColour = trueColour
        self.redMax = redMax; self.greenMax = greenMax; self.blueMax = blueMax
        self.redShift = redShift; self.greenShift = greenShift; self.blueShift = blueShift
    }

    /// Parses ServerInit's 16-byte PIXEL_FORMAT; nil if short.
    init?(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 16 else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        self.init(bitsPerPixel: Int(b[0]), depth: Int(b[1]), bigEndian: b[2] != 0, trueColour: b[3] != 0,
                  redMax: u16(4), greenMax: u16(6), blueMax: u16(8),
                  redShift: Int(b[10]), greenShift: Int(b[11]), blueShift: Int(b[12]))
    }

    /// The 16-byte wire form (SetPixelFormat).
    var data: Data {
        var w = ByteWriter(capacity: 16)
        w.u8(UInt8(bitsPerPixel)); w.u8(UInt8(depth)); w.u8(bigEndian ? 1 : 0); w.u8(trueColour ? 1 : 0)
        w.u16(UInt16(redMax)); w.u16(UInt16(greenMax)); w.u16(UInt16(blueMax))
        w.u8(UInt8(redShift)); w.u8(UInt8(greenShift)); w.u8(UInt8(blueShift)); w.zeros(3)
        return w.data
    }

    /// 32-bit true colour with usable channels: what ZlibRectDecoder converts.
    var isDecodable: Bool {
        bitsPerPixel == 32 && trueColour
            && [redMax, greenMax, blueMax].allSatisfy { $0 > 0 }
            && [redShift, greenShift, blueShift].allSatisfy { $0 < 32 }
    }

    /// Bytes are already B, G, R, X (a plain copy).
    var isNativeBGRA: Bool {
        bitsPerPixel == 32 && trueColour && !bigEndian && redMax == 255 && greenMax == 255 && blueMax == 255
            && redShift == 16 && greenShift == 8 && blueShift == 0
    }
}

enum FramebufferDecodeError: Error, Equatable {
    /// The pixel format isn't 32-bit true colour.
    case unsupportedPixelFormat
    /// A framebuffer side outside 1…maxDimension.
    case framebufferTooLarge(width: Int, height: Int)
    /// A rect side above maxDimension: refused un-inflated (stream broken).
    case rectTooLarge(width: Int, height: Int)
    /// zlib failed or the rect inflated to the wrong size (stream broken).
    case corruptStream(String)
    /// A raw rect's byte count doesn't match w × h × 4 (dropped).
    case shortRaw(expected: Int, got: Int)
    /// An earlier error broke the persistent stream.
    case streamBroken
}

/// Not thread-safe: owned by one serial queue (FramebufferPipeline).
final class ZlibRectDecoder {
    static let maxDimension = 8192
    static let bytesPerPixel = 4

    let format: RFBPixelFormat
    private(set) var width: Int
    private(set) var height: Int
    /// BGRA8, `width * 4` bytes per row, alpha 255.
    private(set) var pixels: [UInt8]
    /// Something was written since the last `takeDirty()`.
    private(set) var isDirty = false
    private(set) var isBroken = false
    private(set) var rectsDecoded = 0
    private let inflater: Zlib.Inflater

    init(width: Int, height: Int, format: RFBPixelFormat) throws {
        guard format.isDecodable else { throw FramebufferDecodeError.unsupportedPixelFormat }
        guard Self.validSize(width, height) else {
            throw FramebufferDecodeError.framebufferTooLarge(width: width, height: height)
        }
        self.format = format
        self.width = width
        self.height = height
        pixels = Self.blank(width, height)
        inflater = try Zlib.Inflater()
    }

    static func validSize(_ w: Int, _ h: Int) -> Bool { (1...maxDimension).contains(w) && (1...maxDimension).contains(h) }

    private static func blank(_ w: Int, _ h: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        p.withUnsafeMutableBufferPointer { b in
            var i = 3
            while i < b.count { b[i] = 255; i += 4 }   // opaque black
        }
        return p
    }

    /// A new backing size (0x451): keeps the overlapping top-left content,
    /// the rest black. Same size: no-op.
    func resize(width w: Int, height h: Int) throws {
        guard Self.validSize(w, h) else { throw FramebufferDecodeError.framebufferTooLarge(width: w, height: h) }
        guard w != width || h != height else { return }
        var next = Self.blank(w, h)
        let rows = min(h, height), cols = min(w, width) * Self.bytesPerPixel
        for r in 0..<rows {
            let src = r * width * Self.bytesPerPixel, dst = r * w * Self.bytesPerPixel
            next.replaceSubrange(dst..<dst + cols, with: pixels[src..<src + cols])
        }
        pixels = next
        width = w; height = h
        isDirty = true
    }

    /// Clears and returns the dirty flag.
    func takeDirty() -> Bool { defer { isDirty = false }; return isDirty }

    // MARK: rects

    /// One zlib rect (encoding 6): `payload` is the next slice of the
    /// connection's zlib stream and must inflate to exactly w × h × 4 bytes.
    func decodeZlib(x: Int, y: Int, w: Int, h: Int, payload: Data) throws {
        guard !isBroken else { throw FramebufferDecodeError.streamBroken }
        guard w <= Self.maxDimension, h <= Self.maxDimension, w >= 0, h >= 0 else {
            isBroken = true
            throw FramebufferDecodeError.rectTooLarge(width: w, height: h)
        }
        let expected = w * h * Self.bytesPerPixel
        var writer = RectWriter(x: x, y: y, w: w, h: h)
        do {
            let produced = try inflater.inflate(payload, maxOutput: expected) { chunk in
                writer.consume(chunk, into: self)
            }
            guard produced == expected, writer.carryCount == 0 else {
                throw FramebufferDecodeError.corruptStream("rect \(w)x\(h) inflated to \(produced) of \(expected) bytes")
            }
        } catch let e as FramebufferDecodeError {
            isBroken = true
            throw e
        } catch {
            isBroken = true
            throw FramebufferDecodeError.corruptStream("\(error)")
        }
        rectsDecoded += 1
    }

    /// One raw rect (encoding 0): exactly w × h × 4 bytes.
    func decodeRaw(x: Int, y: Int, w: Int, h: Int, data: Data) throws {
        guard w >= 0, h >= 0, w <= Self.maxDimension, h <= Self.maxDimension else {
            throw FramebufferDecodeError.rectTooLarge(width: w, height: h)
        }
        let expected = w * h * Self.bytesPerPixel
        guard data.count == expected else { throw FramebufferDecodeError.shortRaw(expected: expected, got: data.count) }
        var writer = RectWriter(x: x, y: y, w: w, h: h)
        data.withUnsafeBytes { writer.consume($0, into: self) }
        rectsDecoded += 1
    }

    // MARK: pixel writing

    /// Streams one rect's pixels (any chunking) into the framebuffer.
    private struct RectWriter {
        let x: Int, y: Int, w: Int, h: Int
        /// Pixels of the rect consumed so far.
        var next = 0
        /// The start of a pixel split across chunks (< 4 bytes).
        var carry: [UInt8] = []
        var carryCount: Int { carry.count }

        init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }

        mutating func consume(_ bytes: UnsafeRawBufferPointer, into d: ZlibRectDecoder) {
            guard w > 0, h > 0, let base = bytes.baseAddress else { return }
            let total = w * h
            var p = 0
            let n = bytes.count
            // Finish a pixel split across chunks.
            if !carry.isEmpty {
                while carry.count < 4 && p < n { carry.append(bytes[p]); p += 1 }
                guard carry.count == 4 else { return }
                if next < total {
                    let px = carry
                    let (row, col) = (next / w, next % w)
                    px.withUnsafeBytes { d.writeRun($0.baseAddress!, count: 1, row: row, col: col, rect: self) }
                    next += 1
                }
                carry.removeAll(keepingCapacity: true)
            }
            while n - p >= 4, next < total {
                let col = next % w
                let count = min(w - col, (n - p) / 4)
                d.writeRun(base + p, count: count, row: next / w, col: col, rect: self)
                next += count
                p += count * 4
            }
            if p < n, next < total {
                while p < n { carry.append(bytes[p]); p += 1 }
            }
        }
    }

    /// `count` source pixels (server format) for rect row `row` from column
    /// `col`, clipped to the framebuffer.
    private func writeRun(_ src: UnsafeRawPointer, count: Int, row: Int, col: Int, rect r: RectWriter) {
        let py = r.y + row, px = r.x + col
        guard py >= 0, py < height, px < width, count > 0 else { return }
        // Clip on the left (x is ≥ 0 on the wire; kept for safety) and right.
        let skip = max(0, -px)
        let visible = min(count, width - px) - skip
        guard visible > 0 else { return }
        let dstOffset = (py * width + px + skip) * Self.bytesPerPixel
        let s = src + skip * Self.bytesPerPixel
        let f = format
        pixels.withUnsafeMutableBytes { dstBuf in
            let dst = dstBuf.baseAddress! + dstOffset
            if f.isNativeBGRA {
                dst.copyMemory(from: s, byteCount: visible * Self.bytesPerPixel)
                var i = 3
                while i < visible * 4 { dst.storeBytes(of: 255, toByteOffset: i, as: UInt8.self); i += 4 }
            } else {
                for i in 0..<visible {
                    let b0 = UInt32(s.load(fromByteOffset: i * 4, as: UInt8.self))
                    let b1 = UInt32(s.load(fromByteOffset: i * 4 + 1, as: UInt8.self))
                    let b2 = UInt32(s.load(fromByteOffset: i * 4 + 2, as: UInt8.self))
                    let b3 = UInt32(s.load(fromByteOffset: i * 4 + 3, as: UInt8.self))
                    let v = f.bigEndian ? b0 << 24 | b1 << 16 | b2 << 8 | b3 : b3 << 24 | b2 << 16 | b1 << 8 | b0
                    dst.storeBytes(of: Self.channel(v, f.blueShift, f.blueMax), toByteOffset: i * 4, as: UInt8.self)
                    dst.storeBytes(of: Self.channel(v, f.greenShift, f.greenMax), toByteOffset: i * 4 + 1, as: UInt8.self)
                    dst.storeBytes(of: Self.channel(v, f.redShift, f.redMax), toByteOffset: i * 4 + 2, as: UInt8.self)
                    dst.storeBytes(of: 255, toByteOffset: i * 4 + 3, as: UInt8.self)
                }
            }
        }
        isDirty = true
    }

    /// One channel scaled to 0…255.
    private static func channel(_ v: UInt32, _ shift: Int, _ max: Int) -> UInt8 {
        let raw = Int((v >> UInt32(shift)) & UInt32(max & 0xFFFF))
        if max == 255 { return UInt8(raw) }
        return UInt8(min(255, (raw * 255 + max / 2) / max))
    }
}
