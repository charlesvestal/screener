import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import Screener

final class VideoDecoderTests: XCTestCase {

    func testAVCCFramingPrefixesEachNALWithBigEndianLength() {
        let a = Data([0x26, 0x01, 0xAA]), b = Data(repeating: 0x5C, count: 0x0102)
        let out = AVCC.sample([a, b])
        XCTAssertEqual(out.prefix(7), Data([0, 0, 0, 3, 0x26, 0x01, 0xAA]))
        XCTAssertEqual(out.dropFirst(7).prefix(4), Data([0, 0, 0x01, 0x02]))
        XCTAssertEqual(out.count, 4 + 3 + 4 + 0x0102)
        XCTAssertEqual(AVCC.sample([]), Data())
    }

    func testFourCC() {
        XCTAssertEqual(kCVPixelFormatType_444YpCbCr8BiPlanarFullRange.fourCC, "444f")
        XCTAssertEqual(OSType(1).fourCC, "0x00000001")
    }

    func testMalformedParameterSetsThrow() {
        XCTAssertThrowsError(try VideoDecoder.makeFormatDescription(vps: Data([0x40, 0x01]), sps: Data([0x42, 0x01]),
                                                                   pps: [Data([0x44, 0x01])]))
    }

    // MARK: - replay of a real capture (local only)

    /// Replays a DEBUG capture through HEVCAssembler → VideoDecoder and checks
    /// that VideoToolbox (in the simulator: the host Mac's) decodes it.
    /// Skipped unless SCREENER_HEVC_CAPTURE points at a capture
    /// (xcodebuild: TEST_RUNNER_SCREENER_HEVC_CAPTURE=<path>). Captures hold
    /// screen images: keep them, and anything decoded from them, out of the repo.
    func testReplayCaptureDecodes() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENER_HEVC_CAPTURE"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no capture (set TEST_RUNNER_SCREENER_HEVC_CAPTURE)")
        }
        let records = try VideoCaptureFile.read(URL(fileURLWithPath: path))
        let base = ContinuousClock.now
        let a = HEVCAssembler(tileSSRCs: Array(Set(records.map(\.ssrc))).sorted())

        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var frames: [Int: Int] = [:]
            var errors: [OSStatus: Int] = [:]
            var sizes: Set<String> = []
            var formats: Set<String> = []
            var matrix: Set<String> = []
            var decodeNanos: Int64 = 0
            func take(_ e: VideoDecoder.Event) {
                lock.lock(); defer { lock.unlock() }
                switch e {
                case .frame(let f):
                    frames[f.tile, default: 0] += 1
                    sizes.insert("\(CVPixelBufferGetWidth(f.pixelBuffer))x\(CVPixelBufferGetHeight(f.pixelBuffer))")
                    formats.insert(CVPixelBufferGetPixelFormatType(f.pixelBuffer).fourCC)
                    let m = CVBufferCopyAttachment(f.pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
                    matrix.insert(m.map { "\($0)" } ?? "-")
                    decodeNanos += f.decodeTime.components.attoseconds / 1_000_000_000
                        + f.decodeTime.components.seconds * 1_000_000_000
                case .error(_, _, let s, _):
                    errors[s, default: 0] += 1
                }
            }
        }
        let sink = Sink()
        let decoder = VideoDecoder { sink.take($0) }
        var fed = 0, submitErrors = 0, spsInfo: HEVCSPSInfo?, formatSize = "-"
        let started = ContinuousClock.now
        for r in records {
            for o in a.ingest(r.packet(base: base)) {
                switch o {
                case .parameterSets(let vps, let sps, let pps):
                    spsInfo = HEVCSPSInfo(sps: sps)
                    try decoder.configure(vps: vps, sps: sps, pps: pps)
                    let d = CMVideoFormatDescriptionGetDimensions(decoder.formatDescription!)
                    formatSize = "\(d.width)x\(d.height)"
                case .accessUnit(let au):
                    fed += 1
                    if decoder.decode(au) != noErr { submitErrors += 1 }
                default: break
                }
            }
        }
        decoder.flush()
        let wall = ContinuousClock.now - started
        sink.lock.lock(); defer { sink.lock.unlock() }
        let decoded = sink.frames.values.reduce(0, +)
        let msg = "replay-decode: fed=\(fed) decoded=\(decoded) perTile=\(sink.frames.sorted { $0.key < $1.key }) "
            + "errors=\(sink.errors) submitErrors=\(submitErrors) mode=\(decoder.mode.map { "\($0)" } ?? "-") "
            + "format=\(formatSize) frames=\(sink.sizes) pixfmt=\(sink.formats) matrix=\(sink.matrix) "
            + "sps=\(spsInfo.map { "profile=\($0.profileIdc) chroma=\($0.chromaFormatIdc) \($0.width)x\($0.height)" } ?? "-") "
            + "avg_decode_ms=\(decoded > 0 ? Double(sink.decodeNanos) / Double(decoded) / 1e6 : 0) wall=\(wall)"
        print(msg)
        add(XCTAttachment(string: msg))
        XCTAssertGreaterThan(fed, 0)
        XCTAssertGreaterThan(decoded, fed * 9 / 10, msg)
        XCTAssertEqual(sink.frames.count, a.tileSSRCs.count, "every tile decodes")
    }
}

final class CompositeLayoutTests: XCTestCase {

    func testFourStripsStackedAndLastCutAtCanvas() {
        let l = CompositeLayout.make(canvas: CGSize(width: 1280, height: 1708), tileCount: 4,
                                     decoded: CGSize(width: 1280, height: 432))
        XCTAssertEqual(l.mode, .strips)
        XCTAssertEqual(l.canvas, CGSize(width: 1280, height: 1708))
        XCTAssertEqual(l.strips.map(\.tile), [0, 1, 2, 3])
        XCTAssertEqual(l.strips.map(\.canvasRect.minY), [0, 432, 864, 1296])
        XCTAssertEqual(l.strips.map(\.canvasRect.height), [432, 432, 432, 412])
        XCTAssertEqual(l.strips[3].textureExtent.height, 412.0 / 432.0, accuracy: 1e-9)
        XCTAssertEqual(l.strips[0].textureExtent, CGSize(width: 1, height: 1))
    }

    func testStripsWithoutCanvasUseTheirOwnExtent() {
        let l = CompositeLayout.make(canvas: nil, tileCount: 4, decoded: CGSize(width: 1280, height: 432))
        XCTAssertEqual(l.canvas, CGSize(width: 1280, height: 1728))
        XCTAssertEqual(l.strips.map(\.canvasRect.height), [432, 432, 432, 432])
    }

    func testWiderStripIsCutAtCanvasRightEdge() {
        let l = CompositeLayout.make(canvas: CGSize(width: 1270, height: 1708), tileCount: 4,
                                     decoded: CGSize(width: 1280, height: 432))
        XCTAssertEqual(l.strips[0].canvasRect.width, 1270)
        XCTAssertEqual(l.strips[0].textureExtent.width, 1270.0 / 1280.0, accuracy: 1e-9)
    }

    func testWholePictureIsDrawnAlone() {
        let l = CompositeLayout.make(canvas: CGSize(width: 1280, height: 1708), tileCount: 4,
                                     decoded: CGSize(width: 1280, height: 1712))
        XCTAssertEqual(l.mode, .fullPicture)
        XCTAssertEqual(l.strips.count, 1)
        XCTAssertEqual(l.strips[0].canvasRect, CGRect(x: 0, y: 0, width: 1280, height: 1708))
        XCTAssertEqual(l.strips[0].textureExtent.height, 1708.0 / 1712.0, accuracy: 1e-9)
    }

    func testAspectFitLetterboxAndPillarbox() {
        // Portrait canvas into a square view: pillarbox.
        let p = CompositeLayout.aspectFit(CGSize(width: 1280, height: 1708), in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(p.height, 1000, accuracy: 1e-9)
        XCTAssertEqual(p.width, 1000 * 1280 / 1708, accuracy: 1e-9)
        XCTAssertEqual(p.midX, 500, accuracy: 1e-9)
        // Wide canvas into a portrait view: letterbox.
        let l = CompositeLayout.aspectFit(CGSize(width: 1920, height: 1080), in: CGSize(width: 1000, height: 2000))
        XCTAssertEqual(l.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(l.height, 562.5, accuracy: 1e-9)
        XCTAssertEqual(l.minY, (2000 - 562.5) / 2, accuracy: 1e-9)
        XCTAssertEqual(CompositeLayout.aspectFit(.zero, in: CGSize(width: 10, height: 10)), .zero)
    }

    func testStripViewRectsTileTheFittedCanvas() {
        let l = CompositeLayout.make(canvas: CGSize(width: 1280, height: 1708), tileCount: 4,
                                     decoded: CGSize(width: 1280, height: 432))
        let bounds = CGSize(width: 2064, height: 2752)          // iPad Pro 13" portrait, pixels
        let fit = CompositeLayout.aspectFit(l.canvas, in: bounds)
        let rects = l.strips.map { l.viewRect(of: $0, in: bounds) }
        XCTAssertEqual(rects.first!.minY, fit.minY, accuracy: 1e-9)
        XCTAssertEqual(rects.last!.maxY, fit.maxY, accuracy: 1e-9)
        for (a, b) in zip(rects, rects.dropFirst()) { XCTAssertEqual(a.maxY, b.minY, accuracy: 1e-9) }
        for r in rects { XCTAssertEqual(r.minX, fit.minX, accuracy: 1e-9); XCTAssertEqual(r.width, fit.width, accuracy: 1e-9) }
    }
}

@MainActor
final class MetalRendererTests: XCTestCase {

    /// A '444f' pixel buffer filled with one Y/Cb/Cr value.
    private func buffer(width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8,
                        matrix: CFString? = nil) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                           kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                           attrs as CFDictionary, &pb), kCVReturnSuccess)
        let b = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(b, [])
        for row in 0..<height {
            let yp = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(b, 0))
            memset(yp, Int32(y), width)
            let cp = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(b, 1))
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { cp[2 * x] = cb; cp[2 * x + 1] = cr }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        if let matrix { CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
        return b
    }

    /// Renders `frames` (canvas `canvas`) into a `size` target; returns BGRA rows.
    private func render(_ frames: [Int: CVPixelBuffer], tileCount: Int, canvas: CGSize?,
                        size: (Int, Int)) throws -> [UInt8] {
        let store = VideoFrameStore()
        let renderer = try XCTUnwrap(MetalRenderer(store: store))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalRenderer.colorPixelFormat,
                                                            width: size.0, height: size.1, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: desc))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)   // blue bars
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let cmd = try XCTUnwrap(queue.makeCommandBuffer())
        let snap = VideoFrameStore.Snapshot(version: 1, frames: frames, tileCount: tileCount, canvas: canvas)
        XCTAssertTrue(renderer.encode(snap, into: pass, size: CGSize(width: size.0, height: size.1), commandBuffer: cmd))
        let out = try XCTUnwrap(renderer.device.makeBuffer(length: size.0 * size.1 * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(cmd.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.0, height: size.1, depth: 1), to: out, destinationOffset: 0,
                  destinationBytesPerRow: size.0 * 4, destinationBytesPerImage: size.0 * size.1 * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: UInt8.self), count: size.0 * size.1 * 4))
    }

    private func pixel(_ px: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(px[i + 2]), Int(px[i + 1]), Int(px[i]))     // BGRA
    }

    func testBT709FullRangeConversion() throws {
        // Y=128, Cb=128, Cr=255 → R = Y + 1.5748·Cr' (clipped), G = Y − 0.468124·Cr', B = Y.
        let px = try render([0: buffer(width: 8, height: 8, y: 128, cb: 128, cr: 255)], tileCount: 1,
                            canvas: nil, size: (8, 8))
        let p = pixel(px, width: 8, x: 4, y: 4)
        let cr = (255.0 - 128) / 255, y = 128.0 / 255
        XCTAssertEqual(p.r, 255)
        XCTAssertEqual(Double(p.g), (y - 0.468124 * cr) * 255, accuracy: 2)
        XCTAssertEqual(Double(p.b), y * 255, accuracy: 2)
    }

    func testBT601AttachmentSwitchesMatrix() throws {
        let px = try render([0: buffer(width: 8, height: 8, y: 128, cb: 128, cr: 200,
                                       matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)],
                            tileCount: 1, canvas: nil, size: (8, 8))
        let p = pixel(px, width: 8, x: 4, y: 4)
        let cr = (200.0 - 128) / 255, y = 128.0 / 255
        XCTAssertEqual(Double(p.g), (y - 0.714136 * cr) * 255, accuracy: 2)
    }

    func testStripsStackInTileOrderAndAspectFit() throws {
        // Two 8×8 strips into an 8×16 canvas, drawn into a 16×16 target:
        // pillarboxed 8 wide (x 4..<12), tile 0 (white) on top, tile 1 (black) below.
        let white = try buffer(width: 8, height: 8, y: 255, cb: 128, cr: 128)
        let black = try buffer(width: 8, height: 8, y: 0, cb: 128, cr: 128)
        let px = try render([0: white, 1: black], tileCount: 2, canvas: CGSize(width: 8, height: 16), size: (16, 16))
        XCTAssertEqual(pixel(px, width: 16, x: 8, y: 3).r, 255)
        XCTAssertEqual(pixel(px, width: 16, x: 8, y: 12).r, 0)
        XCTAssertEqual(pixel(px, width: 16, x: 8, y: 12).b, 0)
        XCTAssertEqual(pixel(px, width: 16, x: 1, y: 8).b, 255, "pillarbox bar (clear colour)")
        XCTAssertEqual(pixel(px, width: 16, x: 14, y: 8).b, 255)
    }
}

final class VideoPipelineTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var notHEVC = 0
        var keyframes: [UInt32] = []
    }

    private func pipeline(_ r: Recorder, ssrcs: [UInt32]) -> VideoPipeline {
        VideoPipeline(store: VideoFrameStore(), hooks: .init(
            activeSSRCs: { ssrcs },
            requestKeyframe: { s in r.lock.withLock { r.keyframes.append(s) } },
            notePublished: {},
            onNotHEVC: { r.lock.withLock { r.notHEVC += 1 } }))
    }

    private func packet(ssrc: UInt32, seq: UInt16, _ payload: [UInt8]) -> MediaPacket {
        MediaPacket(ssrc: ssrc, seq: seq, timestamp: UInt32(seq), marker: true, payloadType: 100,
                    payload: Data(payload), arrival: .now)
    }

    func testH264StreamReportsNotHEVC() async {
        let r = Recorder()
        let p = pipeline(r, ssrcs: [1, 2, 3, 4])
        // H.264 IDR (0x65) / FU-A (0x7C) first bytes: no HEVC payload starts so.
        for i in 0..<4 { await p.ingest(packet(ssrc: 1, seq: UInt16(i), [0x65, 0x88, 0x84])) }
        XCTAssertEqual(r.lock.withLock { r.notHEVC }, 1)
    }

    func testPacketsFromUnadoptedSSRCsAreIgnored() async {
        let r = Recorder()
        let p = pipeline(r, ssrcs: [1, 2, 3, 4])
        for i in 0..<4 { await p.ingest(packet(ssrc: 99, seq: UInt16(i), [0x65, 0x88])) }
        XCTAssertEqual(r.lock.withLock { r.notHEVC }, 0)
    }

    /// The same capture replay as VideoDecoderTests, through the whole
    /// pipeline (adoption, tick, decoder) into the frame store.
    func testReplayCaptureThroughPipeline() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENER_HEVC_CAPTURE"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no capture (set TEST_RUNNER_SCREENER_HEVC_CAPTURE)")
        }
        let records = try VideoCaptureFile.read(URL(fileURLWithPath: path))
        let ssrcs = Array(Set(records.map(\.ssrc))).sorted()
        let r = Recorder()
        let store = VideoFrameStore()
        let p = VideoPipeline(store: store, hooks: .init(
            activeSSRCs: { ssrcs }, requestKeyframe: { s in r.lock.withLock { r.keyframes.append(s) } },
            notePublished: {}, onNotHEVC: { r.lock.withLock { r.notHEVC += 1 } }))
        let base = ContinuousClock.now
        for rec in records { await p.ingest(rec.packet(base: base)) }
        try await Task.sleep(for: .milliseconds(500))
        let c = store.takeCounters()        // before any tick: tick's 2 s stats log takes them
        await p.tick(now: base.advanced(by: .seconds(60)))
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        await p.stop()
        print("pipeline-replay: frames=\(c.frames.sorted { $0.key < $1.key }) errors=\(c.errors)")
        XCTAssertEqual(snap.frames.count, ssrcs.count)
        XCTAssertEqual(c.errors, 0)
        XCTAssertGreaterThan(c.frames.values.reduce(0, +), 1100)
        XCTAssertTrue(store.hasDecoded)
    }
}
