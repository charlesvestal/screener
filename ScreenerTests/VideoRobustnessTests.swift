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

    private func frame(tile: Int = 0, seq: Int) throws -> DecodedFrame {
        DecodedFrame(tile: tile, pixelBuffer: try pixelBuffer(), decodeTime: .milliseconds(1), don: 0, seq: seq)
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
