import CoreMedia
import CoreVideo
import XCTest
@testable import Screener

/// Picture in Picture: the compositor (layout, stacking, scaling, colour),
/// timestamps and sample buffers, the feeder's rate limiting, the lifecycle
/// policy with PiP, and the setting.
final class PiPCompositorTests: XCTestCase {
    // MARK: layout

    func testFourStripsAreStackedAtTheirSlotsAndTheLastIsCutAtTheCanvasBottom() throws {
        // 1600 rows in 4 strips of 416 (CTU padding): 4 × 416 = 1664 > 1600.
        let l = try XCTUnwrap(PiPLayout.make(canvas: CGSize(width: 2560, height: 1600), tileCount: 4,
                                             decoded: CGSize(width: 2560, height: 416)))
        XCTAssertEqual(l.output, .init(width: 1280, height: 800))
        XCTAssertEqual(l.scale, 0.5)
        XCTAssertEqual(l.placements.map(\.tile), [0, 1, 2, 3])
        XCTAssertEqual(l.placements.map(\.destY), [0, 208, 416, 624])
        XCTAssertEqual(l.placements.map(\.rows), [208, 208, 208, 176])
        XCTAssertTrue(l.placements.allSatisfy { $0.scaled == .init(width: 1280, height: 208) && $0.cols == 1280 })
    }

    func testASmallCanvasIsNotUpscaled() throws {
        let l = try XCTUnwrap(PiPLayout.make(canvas: CGSize(width: 800, height: 600), tileCount: 1,
                                             decoded: CGSize(width: 800, height: 600)))
        XCTAssertEqual(l.output, .init(width: 800, height: 600))
        XCTAssertEqual(l.placements, [.init(tile: 0, scaled: .init(width: 800, height: 600), destY: 0, rows: 600,
                                            cols: 800)])
    }

    func testAPortraitCanvasIsBoundedByItsHeightAndKeepsItsAspect() throws {
        let l = try XCTUnwrap(PiPLayout.make(canvas: CGSize(width: 1600, height: 2560), tileCount: 4,
                                             decoded: CGSize(width: 1600, height: 640)))
        XCTAssertEqual(l.output, .init(width: 800, height: 1280))
        XCTAssertEqual(l.placements.last.map { $0.destY + $0.rows }, 1280)
    }

    func testPaddingColumnsWiderThanTheCanvasAreCut() throws {
        // A strip coded 1024 wide on a 1000-wide canvas.
        let l = try XCTUnwrap(PiPLayout.make(canvas: CGSize(width: 1000, height: 400), tileCount: 2,
                                             decoded: CGSize(width: 1024, height: 200), maxDimension: 500))
        XCTAssertEqual(l.output, .init(width: 500, height: 200))
        XCTAssertTrue(l.placements.allSatisfy { $0.scaled.width == 512 && $0.cols == 500 })
    }

    func testNoPictureNoLayout() {
        XCTAssertNil(PiPLayout.make(canvas: nil, tileCount: 4, decoded: .zero))
    }

    // MARK: compositing

    private static let colors: [(b: UInt8, g: UInt8, r: UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 255, 255)]

    private func solidBGRA(width: Int, height: Int, _ c: (b: UInt8, g: UInt8, r: UInt8)) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func pixel(_ pb: CVPixelBuffer, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
        return (p[0], p[1], p[2], p[3])
    }

    private func assertColor(_ pb: CVPixelBuffer, x: Int, y: Int, _ c: (b: UInt8, g: UInt8, r: UInt8),
                             file: StaticString = #filePath, line: UInt = #line) {
        let p = pixel(pb, x: x, y: y)
        for (got, want) in [(p.b, c.b), (p.g, c.g), (p.r, c.r)] {
            XCTAssertLessThanOrEqual(abs(Int(got) - Int(want)), 3, "pixel (\(x),\(y)) = \(p), want \(c)",
                                     file: file, line: line)
        }
        XCTAssertEqual(p.a, 255, file: file, line: line)
    }

    func testStripsAreStackedAndDownscaledIntoOneBGRAPicture() throws {
        // Canvas 256 × 200 in 4 strips of 52 rows (208 coded); PiP at most 128 px.
        var frames: [Int: CVPixelBuffer] = [:]
        for i in 0..<4 { frames[i] = try solidBGRA(width: 256, height: 52, Self.colors[i]) }
        let snap = VideoFrameStore.Snapshot(version: 1, frames: frames, tileCount: 4,
                                            canvas: CGSize(width: 256, height: 200))
        let out = try XCTUnwrap(PiPCompositor(maxDimension: 128).composite(snap))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 100)
        // Strip i covers rows [26 i, 26 i + 26); the last one ends at row 100.
        for (i, y) in [13, 39, 65, 90].enumerated() {
            for x in [0, 64, 127] { assertColor(out, x: x, y: y, Self.colors[i]) }
        }
        assertColor(out, x: 64, y: 0, Self.colors[0])
        assertColor(out, x: 64, y: 99, Self.colors[3])
    }

    func testAMissingTileStaysBlack() throws {
        var frames: [Int: CVPixelBuffer] = [:]
        for i in [0, 1, 3] { frames[i] = try solidBGRA(width: 256, height: 50, Self.colors[i]) }
        let snap = VideoFrameStore.Snapshot(version: 1, frames: frames, tileCount: 4,
                                            canvas: CGSize(width: 256, height: 200))
        let out = try XCTUnwrap(PiPCompositor(maxDimension: 256).composite(snap))
        assertColor(out, x: 10, y: 125, (0, 0, 0))
        assertColor(out, x: 10, y: 175, Self.colors[3])
    }

    func testTheFallbackFramebufferIsOneFullPicture() throws {
        let fb = try solidBGRA(width: 3000, height: 2000, (10, 200, 30))
        let snap = VideoFrameStore.Snapshot(version: 1, frames: [0: fb], tileCount: 1,
                                            canvas: CGSize(width: 3000, height: 2000))
        let out = try XCTUnwrap(PiPCompositor().composite(snap))
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 852)   // 2000 × 1280 / 3000 = 853.3 → even
        assertColor(out, x: 640, y: 426, (10, 200, 30))
    }

    func testA444fStripConvertsToBGRA() throws {
        // Full-range Y = 128, Cb = Cr = 128: mid grey.
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, attrs, &pb),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let snap = VideoFrameStore.Snapshot(version: 1, frames: [0: buffer], tileCount: 1,
                                            canvas: CGSize(width: 64, height: 64))
        let out = try XCTUnwrap(PiPCompositor().composite(snap))
        let p = pixel(out, x: 32, y: 32)
        XCTAssertLessThanOrEqual(abs(Int(p.r) - Int(p.g)), 3)
        XCTAssertLessThanOrEqual(abs(Int(p.b) - Int(p.g)), 3)
        XCTAssertTrue((100...156).contains(Int(p.g)), "grey, got \(p)")
    }

    func testAResizeChangesTheOutputSize() throws {
        let c = PiPCompositor(maxDimension: 1280)
        let a = try solidBGRA(width: 1000, height: 500, (0, 0, 0))
        let b = try solidBGRA(width: 600, height: 600, (0, 0, 0))
        let outA = try XCTUnwrap(c.composite(.init(version: 1, frames: [0: a], tileCount: 1,
                                                   canvas: CGSize(width: 1000, height: 500))))
        let outB = try XCTUnwrap(c.composite(.init(version: 2, frames: [0: b], tileCount: 1,
                                                   canvas: CGSize(width: 600, height: 600))))
        XCTAssertEqual(CVPixelBufferGetWidth(outA), 1000)
        XCTAssertEqual(CVPixelBufferGetWidth(outB), 600)
        XCTAssertEqual(CVPixelBufferGetHeight(outB), 600)
    }

    func testAnEmptySnapshotGivesNothing() {
        XCTAssertNil(PiPCompositor().composite(.init(version: 1, frames: [:], tileCount: 4, canvas: nil)))
    }

    // MARK: timestamps / sample buffers

    func testTimestampsStrictlyIncreaseEvenWhenTheClockDoesNot() {
        var ts = PiPTimestamps()
        let t0 = CMTime(value: 1000, timescale: 1000)
        let a = ts.next(now: t0)
        let b = ts.next(now: t0)
        let c = ts.next(now: CMTime(value: 500, timescale: 1000))
        let d = ts.next(now: CMTime(value: 2000, timescale: 1000))
        XCTAssertEqual(a, t0)
        XCTAssertTrue(CMTimeCompare(b, a) > 0)
        XCTAssertTrue(CMTimeCompare(c, b) > 0)
        XCTAssertEqual(d, CMTime(value: 2000, timescale: 1000))
        var live = PiPTimestamps()
        var last = CMTime.negativeInfinity
        for _ in 0..<1000 {
            let t = live.next()
            XCTAssertTrue(CMTimeCompare(t, last) > 0)
            last = t
        }
    }

    func testSampleBuffersDisplayImmediately() throws {
        let pb = try solidBGRA(width: 16, height: 16, (1, 2, 3))
        let pts = CMTime(value: 42, timescale: 600)
        let s = try XCTUnwrap(PiPSampleBuffer.make(pb, pts: pts))
        XCTAssertTrue(PiPSampleBuffer.displaysImmediately(s))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(s), pts)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(s) === pb)
    }

    // MARK: feeder

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _pts: [CMTime] = []
        func add(_ s: CMSampleBuffer) { lock.withLock { _pts.append(CMSampleBufferGetPresentationTimeStamp(s)) } }
        var pts: [CMTime] { lock.withLock { _pts } }
    }

    private func publish(_ store: VideoFrameStore, seq: Int) throws {
        let pb = try solidBGRA(width: 64, height: 64, (UInt8(seq % 256), 0, 0))
        store.publish(DecodedFrame(tile: 0, pixelBuffer: pb, decodeTime: .zero, don: 0, seq: seq),
                      epoch: store.currentEpoch)
    }

    func testTheFeederSendsOnlyChangedPicturesAndNothingWhenOff() throws {
        let store = VideoFrameStore()
        store.configure(tileCount: 1, canvas: CGSize(width: 64, height: 64))
        let sink = Sink()
        let feeder = PiPFrameFeeder(store: store, intervals: .init(inline: .zero, live: .zero)) { sink.add($0) }
        try publish(store, seq: 1)
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 0, "off: nothing")

        feeder.setRate(.live)              // entering live sends the current picture
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 1)
        try publish(store, seq: 2)
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 2)
        // A change notification without a new picture (static screen): no work.
        store.configure(canvas: CGSize(width: 64, height: 64))
        store.flushStaged()
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 2)

        feeder.setRate(.frozen)            // paused in the PiP window
        try publish(store, seq: 3)
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 2)

        // A reconnect resets the store: the layer keeps the last picture.
        feeder.setRate(.live)
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 3)
        store.reset()
        feeder.refresh()
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 3)

        let pts = sink.pts
        XCTAssertTrue(zip(pts, pts.dropFirst()).allSatisfy { CMTimeCompare($1, $0) > 0 }, "monotonic")
        feeder.stop()
        store.configure(canvas: CGSize(width: 64, height: 64))
        try publish(store, seq: 4)
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 3)
    }

    func testTheInlineRateIsLimited() throws {
        let store = VideoFrameStore()
        store.configure(tileCount: 1, canvas: CGSize(width: 64, height: 64))
        let sink = Sink()
        let feeder = PiPFrameFeeder(store: store, intervals: .init(inline: .seconds(10), live: .zero)) { sink.add($0) }
        try publish(store, seq: 1)
        feeder.setRate(.inline)
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 1)
        for seq in 2...5 { try publish(store, seq: seq) }
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 1, "held until the next inline slot")
        feeder.setRate(.live)              // PiP starts: the newest picture at once
        feeder.drain()
        XCTAssertEqual(sink.pts.count, 2)
        feeder.stop()
    }
}

final class PiPPolicyTests: XCTestCase {
    func testBackgroundWithPiPKeepsTheSession() {
        var p = LifecyclePolicy()
        p.pipStarted()
        XCTAssertEqual(p.didEnterBackground(session: .connected), .none)
        XCTAssertFalse(p.isForeground)
        XCTAssertTrue(p.sessionMayRun)
        XCTAssertFalse(p.pendingReconnect)
        // Back via "return to app": nothing to resume, the session carried on.
        XCTAssertEqual(p.pipStopped(restoring: true, session: .connected), .none)
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .none)
    }

    func testPiPClosedInTheBackgroundClosesTheSessionAndActiveReconnects() {
        var p = LifecyclePolicy()
        p.pipStarted()
        _ = p.didEnterBackground(session: .connected)
        XCTAssertEqual(p.pipStopped(restoring: false, session: .connected), .suspend)
        XCTAssertFalse(p.sessionMayRun)
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .reconnect)
    }

    func testPiPStoppedInTheForegroundChangesNothing() {
        var p = LifecyclePolicy()
        p.pipStarted()
        XCTAssertEqual(p.pipStopped(restoring: false, session: .connected), .none)
        XCTAssertEqual(p.didEnterBackground(session: .connected), .suspend, "no PiP: the usual close")
    }

    func testALostConnectionUnderPiPReconnectsInTheBackground() {
        var p = LifecyclePolicy()
        p.pipStarted()
        _ = p.didEnterBackground(session: .connected)
        XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: true, canReconnect: true), .reconnect)
        // Anything else ends it (the error shows when the user comes back).
        XCTAssertEqual(p.sessionFailed(kind: .peerEnded, wasConnected: true, canReconnect: true), .none)
    }

    func testWithoutPiPABackgroundFailureStaysQuiet() {
        var p = LifecyclePolicy()
        _ = p.didEnterBackground(session: .none)
        XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: true, canReconnect: true), .suspend)
    }

    func testTheSettingDefaultsToOn() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "pip-test-\(UUID().uuidString)"))
        XCTAssertTrue(ScreenerSettings.pipAutoStart(d))
        d.set(false, forKey: ScreenerSettings.pipAutoStartKey)
        XCTAssertFalse(ScreenerSettings.pipAutoStart(d))
    }

    func testTheAudioSessionStaysActiveUntilTheLastClaimGoes() {
        final class Calls: @unchecked Sendable {
            let lock = NSLock(); var on = 0, off = 0
        }
        let calls = Calls()
        let a = AudioSessionArbiter(backend: .init(activate: { calls.lock.withLock { calls.on += 1 } },
                                                   deactivate: { calls.lock.withLock { calls.off += 1 } }))
        a.acquire(.pictureInPicture)
        XCTAssertNoThrow(try a.acquireOrThrow(.remoteAudio))
        a.release(.remoteAudio)                 // mute: PiP still needs it
        XCTAssertEqual(calls.off, 0)
        a.release(.remoteAudio)                 // idempotent
        XCTAssertEqual(calls.off, 0)
        a.release(.pictureInPicture)
        XCTAssertEqual(calls.off, 1)
        XCTAssertEqual(calls.on, 2)
        XCTAssertTrue(a.claims.isEmpty)
    }
}

/// The coordinator with PiP: background keeps the session, closing PiP in
/// the background closes it, "return to app" keeps it.
@MainActor
final class SessionCoordinatorPiPTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _auth = 0
        private var _channels: [FakeDatagramChannel] = []
        func noteAuth() { lock.withLock { _auth += 1 } }
        var authCalls: Int { lock.withLock { _auth } }
        func make() -> FakeDatagramChannel {
            let c = FakeDatagramChannel()
            lock.withLock { _channels.append(c) }
            return c
        }
        var channels: [FakeDatagramChannel] { lock.withLock { _channels } }
    }

    private func coordinator(_ rec: Recorder, ip: String, grace: Duration = .zero) -> SessionCoordinator {
        var policy = SessionCoordinator.Policy()
        policy.pipStartGrace = grace
        return SessionCoordinator(policy: policy, seams: SessionCoordinator.Seams(
            resolveIPv4: { _ in ip },
            controlSeams: { _ in
                ControlSession.Seams(
                    connect: { _, _ in throw TransportError.closed },
                    authenticate: { _, _, _, _ in
                        rec.noteAuth()
                        try await Task.sleep(for: .seconds(60))   // parked until cancelled
                        throw TransportError.closed
                    })
            },
            channelFactory: { _, _ in rec.make() }))
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
        for _ in 0..<600 where !cond() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testBackgroundWithPiPKeepsTheSessionAndClosingPiPThereClosesIt() async throws {
        let rec = Recorder()
        let c = coordinator(rec, ip: "192.0.2.110")
        var stops = 0
        c.stopPictureInPicture = { stops += 1 }
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        let control = c.control

        c.pictureInPictureWillStart()
        XCTAssertTrue(c.pipActive)
        await c.enterBackground()
        XCTAssertEqual(c.state, .connecting, "PiP keeps the session")
        XCTAssertTrue(c.control === control)
        XCTAssertFalse(rec.channels.contains(where: \.cancelled))

        await c.pictureInPictureDidStop(restoring: false)
        await t.value
        XCTAssertFalse(c.pipActive)
        XCTAssertEqual(c.state, .suspended)
        XCTAssertNil(c.control)
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled), "sockets closed once PiP is gone")

        let resumed = Task { await c.becomeActive() }
        try await waitUntil("reconnect handshake") { rec.authCalls == 2 }
        await c.disconnect()
        await resumed.value
        XCTAssertGreaterThanOrEqual(stops, 1, "a disconnect stops PiP")
    }

    func testReturningFromPiPKeepsTheSameSession() async throws {
        let rec = Recorder()
        let c = coordinator(rec, ip: "192.0.2.111")
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        let control = c.control
        c.pictureInPictureWillStart()
        await c.enterBackground()
        await c.pictureInPictureDidStop(restoring: true)
        await c.becomeActive()
        XCTAssertEqual(c.state, .connecting)
        XCTAssertTrue(c.control === control, "no reconnect")
        XCTAssertEqual(rec.authCalls, 1)
        await c.disconnect()
        await t.value
    }

    func testAutomaticPiPStartingJustAfterBackgroundingStillKeepsTheSession() async throws {
        let rec = Recorder()
        let c = coordinator(rec, ip: "192.0.2.112", grace: .seconds(2))
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        c.pipAutoStartArmed = true
        let bg = Task { await c.enterBackground() }
        try await Task.sleep(for: .milliseconds(50))
        c.pictureInPictureWillStart()
        await bg.value
        XCTAssertEqual(c.state, .connecting)
        XCTAssertNotNil(c.control)
        await c.disconnect()
        await t.value
    }

    func testArmedButPiPNeverStartsClosesAfterTheGrace() async throws {
        let rec = Recorder()
        let c = coordinator(rec, ip: "192.0.2.113", grace: .milliseconds(100))
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        c.pipAutoStartArmed = true
        await c.enterBackground()
        await t.value
        XCTAssertEqual(c.state, .suspended)
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled))
        await c.disconnect()
    }
}
