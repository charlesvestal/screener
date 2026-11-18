// Image fidelity (2026-11-18 investigation, "muted / less sharp"): the YCbCr →
// RGB maths, and the exact 1:1 mapping for Fit Retina (canvas = drawable).
import CoreVideo
import Metal
import XCTest
@testable import Screener

final class YCbCrConversionTests: XCTestCase {
    private let full = YCbCrFormat.of(kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)!
    private let video = YCbCrFormat.of(kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)!

    private func rgb(_ y: UInt8, _ cb: UInt8, _ cr: UInt8, _ f: YCbCrFormat, _ m: YCbCrMatrix = .bt709) -> [Int] {
        let v = YCbCrConversion.rgb8(y: y, cb: cb, cr: cr, format: f, matrix: m)
        return [Int(v.x), Int(v.y), Int(v.z)]
    }

    private func assertNear(_ a: [Int], _ b: [Int], _ tol: Int = 1, _ msg: String = "", line: UInt = #line) {
        for (x, y) in zip(a, b) { XCTAssertLessThanOrEqual(abs(x - y), tol, "\(a) vs \(b) \(msg)", line: line) }
    }

    func testFullRangeLevelsAreNotCompressed() {
        // '444f' is full range: code 0 is black and 255 white (not 16 / 235).
        XCTAssertTrue(full.fullRange)
        XCTAssertEqual(rgb(0, 128, 128, full), [0, 0, 0])
        XCTAssertEqual(rgb(255, 128, 128, full), [255, 255, 255])
        for v in stride(from: 0, through: 255, by: 16) {
            XCTAssertEqual(rgb(UInt8(v), 128, 128, full), [v, v, v], "grey \(v) passes through unchanged")
        }
    }

    func testVideoRangeExpandsToFull() {
        XCTAssertFalse(video.fullRange)
        XCTAssertEqual(rgb(16, 128, 128, video), [0, 0, 0])
        XCTAssertEqual(rgb(235, 128, 128, video), [255, 255, 255])
        assertNear(rgb(126, 128, 128, video), [128, 128, 128])
    }

    /// Y'CbCr code values the Mac's HP encoder produced for the test card's
    /// patches (measured, live session 2026-11-18) → the RGB values the card
    /// drew on the Mac's Display P3 virtual display.
    func testMacEncoderPatchesDecodeToTheMacPixels() {
        let cases: [(ycc: [UInt8], rgb: [Int], name: String)] = [
            ([89, 99, 220], [234, 51, 35], "sRGB red in P3"),
            ([210, 56, 69], [117, 251, 76], "sRGB green in P3"),
            ([18, 251, 117], [0, 0, 245], "sRGB blue in P3"),
            ([54, 99, 255], [255, 0, 0], "P3 red"),
            ([182, 30, 12], [0, 255, 0], "P3 green"),
            ([40, 113, 176], [116, 20, 12], "50% sRGB red in P3"),
            ([180, 109, 150], [214, 173, 145], "skin"),
        ]
        for c in cases { assertNear(rgb(c.ycc[0], c.ycc[1], c.ycc[2], full), c.rgb, 1, c.name) }
    }

    func testMatrixChoiceMatters() {
        // The same chroma through BT.601 is visibly different (a wrong matrix
        // would shift hues / saturation, not just within rounding).
        let a = rgb(89, 99, 220, full, .bt709), b = rgb(89, 99, 220, full, .bt601)
        XCTAssertGreaterThan(zip(a, b).map { abs($0 - $1) }.max()!, 10)
    }
}

final class OneToOneMappingTests: XCTestCase {
    func testPixelAlignedFitRoundsTheLetterboxOrigin() {
        // Same width, 11 px taller target: 1:1 with a 5.5 px offset → 6.
        let fit = CompositeLayout.pixelAlignedFit(CGSize(width: 100, height: 50), in: CGSize(width: 100, height: 61))
        XCTAssertEqual(fit, CGRect(x: 0, y: 6, width: 100, height: 50))
        // Scaled fits keep their size; only the origin snaps.
        let s = CompositeLayout.pixelAlignedFit(CGSize(width: 1920, height: 1080), in: CGSize(width: 2064, height: 2752))
        XCTAssertEqual(s.minX, s.minX.rounded())
        XCTAssertEqual(s.minY, s.minY.rounded())
        XCTAssertEqual(s.width, 2064, accuracy: 1e-9)
    }

    func testFitRetinaIsOneToOne() {
        // iPad Pro 13" landscape, Fit Retina: 4 strips of 2752×528 → 2752×2064.
        let l = CompositeLayout.make(canvas: CGSize(width: 2752, height: 2064), tileCount: 4,
                                     decoded: CGSize(width: 2752, height: 528))
        XCTAssertTrue(l.isOneToOne(in: CGSize(width: 2752, height: 2064)))
        let rects = l.strips.map { l.viewRect(of: $0, in: CGSize(width: 2752, height: 2064)) }
        XCTAssertEqual(rects.map(\.minY), [0, 528, 1056, 1584])
        XCTAssertEqual(rects.last!.maxY, 2064)
        for r in rects { XCTAssertEqual(r.minX, 0); XCTAssertEqual(r.width, 2752) }
        // Portrait (measured in the simulator): 4 × 2064×688.
        let p = CompositeLayout.make(canvas: CGSize(width: 2064, height: 2752), tileCount: 4,
                                     decoded: CGSize(width: 2064, height: 688))
        XCTAssertTrue(p.isOneToOne(in: CGSize(width: 2064, height: 2752)))
    }

    func testScaledFitIsNotOneToOne() {
        let l = CompositeLayout.make(canvas: CGSize(width: 1920, height: 1080), tileCount: 1,
                                     decoded: CGSize(width: 1920, height: 1080))
        XCTAssertFalse(l.isOneToOne(in: CGSize(width: 2752, height: 2064)))
        XCTAssertFalse(l.isOneToOne(in: CGSize(width: 1919, height: 1080)))
        XCTAssertTrue(l.isOneToOne(in: CGSize(width: 1920, height: 1081)), "1:1 with a snapped half-pixel bar")
    }
}

@MainActor
final class OneToOneRenderTests: XCTestCase {
    /// A '444f' buffer whose luma is `luma(x, y)`, neutral chroma.
    private func buffer(_ w: Int, _ h: Int, cb: UInt8 = 128, cr: UInt8 = 128,
                        _ luma: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                           attrs as CFDictionary, &pb), kCVReturnSuccess)
        let b = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(b, [])
        for y in 0..<h {
            let yp = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(b, 0))
                .assumingMemoryBound(to: UInt8.self)
            let cp = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(b, 1))
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { yp[x] = luma(x, y); cp[2 * x] = cb; cp[2 * x + 1] = cr }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    /// Renders into a `w`×`h` BGRA target cleared to blue; returns BGRA bytes.
    private func render(_ frames: [Int: CVPixelBuffer], tiles: Int, canvas: CGSize, _ w: Int, _ h: Int) throws -> [UInt8] {
        let renderer = try XCTUnwrap(MetalRenderer(store: VideoFrameStore()))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalRenderer.colorPixelFormat,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: desc))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let cmd = try XCTUnwrap(queue.makeCommandBuffer())
        let snap = VideoFrameStore.Snapshot(version: 1, frames: frames, tileCount: tiles, canvas: canvas)
        XCTAssertTrue(renderer.encode(snap, into: pass, size: CGSize(width: w, height: h), commandBuffer: cmd))
        let out = try XCTUnwrap(renderer.device.makeBuffer(length: w * h * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(cmd.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: out, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    func testOneToOneStripsAreBitExact() throws {
        // A 1-px checkerboard over 4 strips of 64×17 (canvas 64×64: the last
        // strip is cut), drawn into a 64×64 target: every pixel exact.
        let W = 64, slot = 17
        var frames: [Int: CVPixelBuffer] = [:]
        for t in 0..<4 {
            frames[t] = try buffer(W, slot) { x, y in ((x + y + t * slot) % 2 == 0) ? 255 : 0 }
        }
        let px = try render(frames, tiles: 4, canvas: CGSize(width: W, height: 64), W, 64)
        for y in 0..<64 { for x in 0..<W {
            let want: UInt8 = (x + y) % 2 == 0 ? 255 : 0
            let i = (y * W + x) * 4
            XCTAssertEqual([px[i + 2], px[i + 1], px[i]], [want, want, want], "pixel \(x),\(y)")
            if px[i] != want { return }
        } }
    }

    func testShaderMatchesCPUConversionAtOneToOne() throws {
        // Every 16th Y with saturated chroma: the GPU and YCbCrConversion agree.
        let pb = try buffer(16, 1, cb: 99, cr: 220) { x, _ in UInt8(x * 16) }
        let px = try render([0: pb], tiles: 1, canvas: CGSize(width: 16, height: 1), 16, 1)
        let fmt = YCbCrFormat.of(kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)!
        for x in 0..<16 {
            let want = YCbCrConversion.rgb8(y: UInt8(x * 16), cb: 99, cr: 220, format: fmt, matrix: .bt709)
            let i = x * 4
            for (got, w) in zip([px[i + 2], px[i + 1], px[i]], [want.x, want.y, want.z]) {
                XCTAssertLessThanOrEqual(abs(Int(got) - Int(w)), 1, "x=\(x)")
            }
        }
    }

    func testHalfPixelLetterboxDoesNotBlur() throws {
        // 8×8 canvas of 1-px horizontal lines in an 8×9 target: the 0.5 px
        // bar would put every row between two source rows (all grey); snapped,
        // the rows stay pure black / white.
        let pb = try buffer(8, 8) { _, y in y % 2 == 0 ? 255 : 0 }
        let px = try render([0: pb], tiles: 1, canvas: CGSize(width: 8, height: 8), 8, 9)
        var values = Set<UInt8>()
        for y in 0..<9 { let i = (y * 8 + 4) * 4; if px[i] != 255 || px[i + 2] != 0 { values.insert(px[i + 2]) } }
        XCTAssertEqual(values.subtracting([0, 255]), [], "no blended rows")
        XCTAssertTrue(values.contains(255) && values.contains(0))
    }
}
