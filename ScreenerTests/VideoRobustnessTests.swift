import CoreVideo
import VideoToolbox
import XCTest
@testable import Screener

/// Task 14 review items: store epochs, decoder recovery decisions, on-demand
/// redraw coalescing, layer colorspace.
final class VideoRobustnessTests: XCTestCase {
    private func pixelBuffer() throws -> CVPixelBuffer {
        var b: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                           nil, &b), kCVReturnSuccess)
        return try XCTUnwrap(b)
    }

    private func frame(tile: Int = 0, seq: Int, ts: UInt32? = nil) throws -> DecodedFrame {
        DecodedFrame(tile: tile, pixelBuffer: try pixelBuffer(), decodeTime: .milliseconds(1), don: 0, seq: seq,
                     rtpTimestamp: ts)
    }

    // MARK: VideoFrameStore coherent pictures

    /// The four strips of one RTP timestamp become visible together: nothing
    /// changes (and no redraw is asked for) until the last strip is in.
    func testStripsOfAPictureAreCommittedTogether() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        let changes = Counter()
        store.onChange = { changes.bump() }
        let before = store.currentVersion
        for t in 0..<3 { store.publish(try frame(tile: t, seq: 10 + t, ts: 900), epoch: e) }
        XCTAssertEqual(changes.value, 0)
        XCTAssertEqual(store.currentVersion, before)
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 0, "partial picture is not presentable")
        XCTAssertTrue(store.hasDecoded)
        let last = try frame(tile: 3, seq: 13, ts: 900)
        store.publish(last, epoch: e)
        XCTAssertEqual(changes.value, 1)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: before))
        XCTAssertEqual(snap.frames.count, 4)
        XCTAssertTrue(snap.frames[3] === last.pixelBuffer)
        XCTAssertEqual(store.takePartialCommits(), 0)
        XCTAssertEqual(store.takeCounters().frames, [0: 1, 1: 1, 2: 1, 3: 1], "fps counts every decoded strip")
    }

    /// A strip that never comes (its tile is gated) does not hold the picture
    /// back past the next picture's first strip, which stays staged.
    func testANewerPictureCommitsTheIncompleteOne() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        let t0 = try frame(tile: 0, seq: 20, ts: 1000)
        store.publish(t0, epoch: e)
        store.publish(try frame(tile: 1, seq: 21, ts: 1000), epoch: e)   // tiles 2 and 3 missing
        let next = try frame(tile: 0, seq: 22, ts: 2500)
        store.publish(next, epoch: e)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(snap.frames.count, 2)
        XCTAssertTrue(snap.frames[0] === t0.pixelBuffer, "the newer picture's strip is still staged")
        XCTAssertEqual(store.takePartialCommits(), 1)
    }

    /// The ticker commits the last picture before the screen goes static.
    func testFlushCommitsAStalledPictureAfterTheTimeout() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        let start = ContinuousClock.now
        store.publish(try frame(tile: 0, seq: 30, ts: 7), epoch: e, now: start)
        store.flushStaged(now: start.advanced(by: .milliseconds(20)))
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 0)
        store.flushStaged(now: start + VideoFrameStore.stagingTimeout)
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 1)
        // A stale strip (older seq than the committed one) is ignored.
        store.publish(try frame(tile: 0, seq: 29, ts: 8), epoch: e)
        store.flushStaged(now: .now + .seconds(1))
        XCTAssertEqual(store.takePartialCommits(), 1)
    }

    /// Single-tile streams (and frames without a timestamp) commit at once.
    func testSingleTileCommitsImmediately() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 1)
        store.publish(try frame(tile: 0, seq: 40, ts: 1), epoch: e)
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 1)
    }

    func testIntervalStatsSummary() {
        var s = IntervalStats()
        func au(_ tile: Int, _ n: Int, idr: Bool = false) -> AccessUnit {
            AccessUnit(nalUnits: [Data(count: n)], isIDR: idr, tile: tile, rtpTimestamp: 0, ssrc: 1, don: 0)
        }
        s.note(au(0, 1000, idr: true)); s.note(au(0, 3000)); s.note(au(1, 500))
        XCTAssertEqual(s.summary(seconds: 2, tiles: 2), "kbps=18 au_avg=[2000,500] au_max=[3000,500] idr=1")
    }

    // MARK: VideoFrameStore epochs

    /// A late VideoToolbox callback from the previous session (higher seq,
    /// old epoch) must not replace the new session's picture.
    func testFramesFromAPreviousEpochAreDropped() throws {
        let store = VideoFrameStore()
        let old = store.reset()
        store.publish(try frame(seq: 100), epoch: old)
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 1)

        let new = store.reset()
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 0, "reset frees the old pictures")
        let fresh = try frame(seq: 1)
        store.publish(fresh, epoch: new)
        store.publish(try frame(seq: 101), epoch: old)   // late, from the old session
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertTrue(snap.frames[0] === fresh.pixelBuffer)
        XCTAssertEqual(store.staleFramesDropped, 1)
        XCTAssertTrue(store.hasDecoded)
    }

    func testFirstFrameCallbackIgnoresStaleEpochs() throws {
        let store = VideoFrameStore()
        let old = store.reset()
        _ = store.reset()
        let calls = Counter()
        store.onFirstFrame = { _ in calls.bump() }
        store.publish(try frame(seq: 5), epoch: old)
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(store.hasDecoded)
    }

    func testDecoderSequenceNumbersAreProcessGlobal() {
        let a = VideoDecoder.nextSequence()
        let b = VideoDecoder.nextSequence()
        XCTAssertGreaterThan(b, a)
    }

    func testOnChangeFiresForPublishResetAndConfigure() throws {
        let store = VideoFrameStore()
        let changes = Counter()
        store.onChange = { changes.bump() }
        let e = store.reset()
        store.publish(try frame(seq: VideoDecoder.nextSequence()), epoch: e)
        store.configure(tileCount: 2)
        store.configure(tileCount: 2)                     // no change: no callback
        store.publish(try frame(seq: 1), epoch: e - 1)    // stale: no callback
        XCTAssertEqual(changes.value, 3)
    }

    func testOnlyTheOwnerCanClearOnChange() throws {
        let store = VideoFrameStore()
        let a = NSObject(), b = NSObject()
        let changes = Counter()
        store.setOnChange(owner: a) { changes.bump() }
        store.setOnChange(owner: b) { changes.bump() }   // the next view's renderer
        store.clearOnChange(owner: a)                    // the old view is dismantled late
        store.reset()
        XCTAssertEqual(changes.value, 1)
        store.clearOnChange(owner: b)
        store.reset()
        XCTAssertEqual(changes.value, 1)
    }

    // MARK: DecoderRecoveryPolicy

    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }
    private let badData: OSStatus = kVTVideoDecoderBadDataErr

    func testASingleIRAPFailureRebuildsWithoutFallingBack() {
        var p = DecoderRecoveryPolicy()
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(0)), .rebuild)
        // The other tiles' IRAPs queued on the same session fail with it: ignored, not counted.
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(10)), .ignore)
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(20)), .ignore)
        XCTAssertEqual(p.consecutiveIRAPFailures, 1)
    }

    func testThreeIRAPFailuresInARowWithNothingDecodedFallBack() {
        var p = DecoderRecoveryPolicy()
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(0)), .rebuild)
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(600)), .rebuild)
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(1200)), .fallBack)
        XCTAssertEqual(p.consecutiveIRAPFailures, 0)
    }

    func testADecodedPictureBetweenIRAPFailuresResetsTheCount() {
        var p = DecoderRecoveryPolicy()
        _ = p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(0))
        _ = p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(600))
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: true, now: at(1200)), .rebuild)
        XCTAssertEqual(p.consecutiveIRAPFailures, 1)
    }

    func testFormatUnsupportedFallsBackAtOnce() {
        for s in [kVTCouldNotFindVideoDecoderErr, kVTVideoDecoderUnsupportedDataFormatErr] {
            var p = DecoderRecoveryPolicy()
            XCTAssertEqual(p.decide(status: s, isIRAP: false, decodedSinceLastFailure: false, now: at(0)), .fallBack, "\(s)")
        }
    }

    /// Invalid session (backgrounding), malfunction and not-available-now
    /// rebuild in the same mode, never count toward a fallback, even on IRAPs.
    func testSessionLevelErrorsRebuildAndNeverFallBack() {
        for s in [kVTInvalidSessionErr, kVTVideoDecoderMalfunctionErr, kVTVideoDecoderNotAvailableNowErr] {
            var p = DecoderRecoveryPolicy()
            for i in 0..<6 {
                XCTAssertEqual(p.decide(status: s, isIRAP: i % 2 == 0, decodedSinceLastFailure: false, now: at(600 * i)),
                               .rebuild, "\(s) #\(i)")
            }
            XCTAssertEqual(p.consecutiveIRAPFailures, 0)
        }
    }

    func testConcealmentErrorsRequestKeyframesThrottled() {
        var p = DecoderRecoveryPolicy()
        XCTAssertEqual(p.decide(status: badData, isIRAP: false, decodedSinceLastFailure: true, now: at(0)), .requestKeyframe)
        XCTAssertEqual(p.decide(status: badData, isIRAP: false, decodedSinceLastFailure: false, now: at(100)), .ignore)
        XCTAssertEqual(p.decide(status: badData, isIRAP: false, decodedSinceLastFailure: false, now: at(600)), .requestKeyframe)
    }

    func testModeChangeResetsTheIRAPCount() {
        var p = DecoderRecoveryPolicy()
        _ = p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(0))
        _ = p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(600))
        p.noteModeChanged()
        XCTAssertEqual(p.decide(status: badData, isIRAP: true, decodedSinceLastFailure: false, now: at(1200)), .rebuild)
    }

    /// An empty AU is a bad AU (kVTParameterErr), not an invalid session.
    func testEmptyAccessUnitIsNotReportedAsAnInvalidSession() {
        func au(_ nals: [Data]) -> AccessUnit {
            AccessUnit(nalUnits: nals, isIDR: false, tile: 0, rtpTimestamp: 0, ssrc: 1, don: 0)
        }
        XCTAssertEqual(VideoDecoder.precheck(hasSession: true, au: au([])), kVTParameterErr)
        XCTAssertEqual(VideoDecoder.precheck(hasSession: false, au: au([])), kVTParameterErr)
        XCTAssertEqual(VideoDecoder.precheck(hasSession: false, au: au([Data([0x26, 0x01])])), kVTInvalidSessionErr)
        XCTAssertNil(VideoDecoder.precheck(hasSession: true, au: au([Data([0x26, 0x01])])))
        XCTAssertFalse(DecoderRecoveryPolicy.isSessionLevel(kVTParameterErr))
        // Through the decoder with no session: still a bad AU.
        let d = VideoDecoder { _ in }
        XCTAssertEqual(d.decode(au([])), kVTParameterErr)
    }

    // MARK: rendering

    /// Signals from one main-queue turn (here: the test, on the main actor)
    /// coalesce into a single redraw.
    @MainActor
    func testRedrawCoalescerFiresOncePerBurst() async throws {
        let fired = Counter()
        let c = RedrawCoalescer { fired.bump() }
        for _ in 0..<50 { c.signal() }
        try await waitMain { fired.value >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fired.value, 1)
        c.signal()
        try await waitMain { fired.value == 2 }
    }

    func testLayerColorSpaceFollowsThePrimariesAttachment() {
        XCTAssertEqual(MetalRenderer.colorSpaceName(primaries: nil), CGColorSpace.sRGB)
        XCTAssertEqual(MetalRenderer.colorSpaceName(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String),
                       CGColorSpace.sRGB)
        XCTAssertEqual(MetalRenderer.colorSpaceName(primaries: kCVImageBufferColorPrimaries_P3_D65 as String),
                       CGColorSpace.displayP3)
        XCTAssertEqual(MetalRenderer.colorSpaceName(primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String),
                       CGColorSpace.itur_2020)
    }

    @MainActor
    private func waitMain(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !cond() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cond())
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
