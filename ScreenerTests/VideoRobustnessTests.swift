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

    /// A strip that never comes (its tile is gated, or the encoder skipped
    /// it) does not hold the picture back: once a strip of the next picture
    /// decodes (decoding order is picture order), the older picture is final
    /// and shown as it is; the newer one stays staged.
    func testAGatedTileCommitsThePictureWhenTheNextOneStarts() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        let t0 = try frame(tile: 0, seq: 20, ts: 1000)
        store.publish(t0, epoch: e)
        store.publish(try frame(tile: 1, seq: 21, ts: 1000), epoch: e)   // tiles 2 and 3 never come
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 0)
        let next = try frame(tile: 0, seq: 22, ts: 1400)
        store.publish(next, epoch: e)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(snap.frames.count, 2)
        XCTAssertTrue(snap.frames[0] === t0.pixelBuffer, "the newer picture is still staged")
        XCTAssertEqual(store.takePartialCommits(), 0, "not a stall")
        XCTAssertEqual(store.takePresentStats().skips, 1)
    }

    /// Motion in one corner (tiles {0,1}, the others skipped as unchanged):
    /// each picture is shown as soon as its last changing strip decodes, not
    /// one or two pictures later. Only the first picture without tiles 2 and
    /// 3 (the previous one had them) waits, for the next picture to start.
    func testSkippedStaticTilesDoNotDelayPictures() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        var seq = 100
        for t in 0..<4 { store.publish(try frame(tile: t, seq: seq, ts: 0), epoch: e); seq += 1 }
        var shownAtOnce = 0
        let pictures = 12
        for k in 1...pictures {
            let ts = UInt32(400 * k)
            store.publish(try frame(tile: 0, seq: seq, ts: ts), epoch: e); seq += 1
            let last = try frame(tile: 1, seq: seq, ts: ts); seq += 1
            store.publish(last, epoch: e)
            if store.snapshot(ifNewerThan: nil)?.frames[1] === last.pixelBuffer { shownAtOnce += 1 }
        }
        XCTAssertEqual(shownAtOnce, pictures - 1)
        let stats = store.takePresentStats()
        XCTAssertEqual(stats.shown, 1 + pictures)
        XCTAssertEqual(stats.merged, 0)
        XCTAssertEqual(stats.held, 1, "only the first picture without tiles 2 and 3 waited")
        XCTAssertEqual(store.takePartialCommits(), 0)
    }

    /// The user's case (2026-11-19: a window dragged in two strips while
    /// another tile changes now and then, `tiles=[2,60,9,56]`): a tile that
    /// changed once no longer makes the following pictures wait. With the
    /// pipeline's arrival reports a picture is shown on its last strip, or on
    /// the next picture's first packet when the previous picture had a tile
    /// after its last strip — never on the next picture's decode or timeout.
    func testAnOccasionalTileDoesNotHoldTheFollowingPictures() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        var seq = 0
        let sets: [[Int]] = [[0, 1, 2, 3], [1, 3], [1, 3], [1, 2, 3], [1, 3], [1], [1], [0, 1], [1, 3], [1, 3]]
        var lastStrips: [DecodedFrame] = []
        for (k, tiles) in sets.enumerated() {
            let ts = UInt32(400 * k)
            for t in tiles { store.noteArrival(rtpTimestamp: ts, tile: t) }
            for t in tiles {
                let f = try frame(tile: t, seq: seq, ts: ts); seq += 1
                store.publish(f, epoch: e)
                if t == tiles.last { lastStrips.append(f) }
            }
        }
        store.noteArrival(rtpTimestamp: UInt32(400 * sets.count), tile: 1)
        let stats = store.takePresentStats()
        XCTAssertEqual(stats.shown, sets.count)
        XCTAssertEqual(stats.held, 0)
        XCTAssertEqual(stats.fills, 0)
        XCTAssertTrue(store.snapshot(ifNewerThan: nil)?.frames[3] === lastStrips.last?.pixelBuffer)
    }

    /// A strip whose first packet has arrived is waited for even when the
    /// previous picture predicts the picture complete without it (no fill).
    func testAStripOnTheWireIsWaitedFor() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        var seq = 0
        for (k, tiles) in [[0, 1, 2, 3], [1]].enumerated() {
            for t in tiles { store.publish(try frame(tile: t, seq: seq, ts: UInt32(400 * k)), epoch: e); seq += 1 }
        }
        store.noteArrival(rtpTimestamp: 800, tile: 1)
        store.noteArrival(rtpTimestamp: 800, tile: 2)
        let one = try frame(tile: 1, seq: seq, ts: 800)
        store.publish(one, epoch: e)
        XCTAssertFalse(store.snapshot(ifNewerThan: nil)?.frames[1] === one.pixelBuffer, "tile 2 is on its way")
        let two = try frame(tile: 2, seq: seq + 1, ts: 800)
        store.publish(two, epoch: e)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertTrue(snap.frames[1] === one.pixelBuffer)
        XCTAssertTrue(snap.frames[2] === two.pixelBuffer)
        XCTAssertEqual(store.takePresentStats().fills, 0)
    }

    /// A picture that may still get a strip (the previous one had a tile after
    /// its last strip) is shown as soon as a packet of a newer picture
    /// arrives — before that picture decodes — but not on a packet of its own.
    func testANewerPictureOnTheWireFinalizesTheStagedOne() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        var seq = 0
        for t in 0..<4 { store.publish(try frame(tile: t, seq: seq, ts: 0), epoch: e); seq += 1 }
        store.noteArrival(rtpTimestamp: 400, tile: 0)
        let f = try frame(tile: 0, seq: seq, ts: 400)
        store.publish(f, epoch: e)
        let changes = Counter()
        store.onChange = { changes.bump() }
        store.noteArrival(rtpTimestamp: 400, tile: 0)
        XCTAssertFalse(store.snapshot(ifNewerThan: nil)?.frames[0] === f.pixelBuffer)
        store.noteArrival(rtpTimestamp: 800, tile: 1)
        XCTAssertTrue(store.snapshot(ifNewerThan: nil)?.frames[0] === f.pixelBuffer)
        XCTAssertEqual(changes.value, 1)
        let stats = store.takePresentStats()
        XCTAssertEqual(stats.skips, 1)
        XCTAssertEqual(stats.held, 0)
    }

    /// With pacing, a strip that fills a picture shown without it before
    /// that picture is due replaces it in the queue: the viewer never sees
    /// the incomplete picture.
    func testAFillBeforeTheDueTimeIsNeverSeen() throws {
        let store = VideoFrameStore()
        store.setPacing(.init(delay: .milliseconds(10), window: .seconds(1), maxHold: .milliseconds(40)))
        let e = store.reset()
        store.configure(tileCount: 2)
        _ = store.snapshot(ifNewerThan: nil)
        let start = ContinuousClock.now
        var seq = 0
        for (k, tiles) in [[0, 1], [0]].enumerated() {
            for t in tiles {
                store.publish(try frame(tile: t, seq: seq, ts: UInt32(400 * k)), epoch: e,
                              now: start + .microseconds(Int64(16_667 * k)))
                seq += 1
            }
        }
        // Picture 800's tile 0 is predicted complete (picture 400 had tile 0
        // only), so it is queued at once; its tile 1 then comes after all.
        let t0 = try frame(tile: 0, seq: seq, ts: 800)
        store.publish(t0, epoch: e, now: start + .milliseconds(34))
        let t1 = try frame(tile: 1, seq: seq + 1, ts: 800)
        XCTAssertEqual(store.takePresentStats().shown, 3)
        store.publish(t1, epoch: e, now: start + .milliseconds(36))
        let shown = try XCTUnwrap(store.snapshot(ifNewerThan: nil, now: start + .milliseconds(60)))
        XCTAssertTrue(shown.frames[0] === t0.pixelBuffer)
        XCTAssertTrue(shown.frames[1] === t1.pixelBuffer)
        let stats = store.takePresentStats()
        XCTAssertEqual(stats.fills, 1)
        XCTAssertEqual(stats.queued, 0, "the fill replaced the queued picture")
    }

    /// A static tile that starts changing (a window moving into it) after the
    /// picture was shown without it fills that picture in at once.
    func testATileThatStartsMovingFillsTheShownPicture() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 2)
        var seq = 0
        func pic(_ ts: UInt32, _ tiles: [Int]) throws -> [DecodedFrame] {
            try tiles.map { t in defer { seq += 1 }; return try frame(tile: t, seq: seq, ts: ts) }
        }
        for f in try pic(0, [0, 1]) { store.publish(f, epoch: e) }
        for k in 1...3 {
            for f in try pic(UInt32(400 * k), [0]) { store.publish(f, epoch: e) }
        }
        let moving = try pic(UInt32(400 * 4), [0, 1])
        store.publish(moving[0], epoch: e)
        XCTAssertTrue(store.snapshot(ifNewerThan: nil)?.frames[0] === moving[0].pixelBuffer, "tile 1 was static")
        store.publish(moving[1], epoch: e)
        XCTAssertTrue(store.snapshot(ifNewerThan: nil)?.frames[1] === moving[1].pixelBuffer)
        XCTAssertEqual(store.takePresentStats().fills, 1)
    }

    /// Full-screen motion with an occasional skipped tile (~2% of pictures):
    /// that picture waits only for the next picture's first packet, and the
    /// next picture waits for its tile 3, which is on the wire by the time
    /// its tile 2 decodes (no tear in the next picture).
    func testAnOccasionalSkipDuringFullMotionWaitsForTheNextPictureOnly() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        var seq = 0
        func publish(_ ts: UInt32, _ tiles: [Int]) throws -> [DecodedFrame] {
            try tiles.map { t in
                defer { seq += 1 }
                store.noteArrival(rtpTimestamp: ts, tile: t)
                let f = try frame(tile: t, seq: seq, ts: ts)
                store.publish(f, epoch: e)
                return f
            }
        }
        _ = try publish(0, [0, 1, 2, 3])
        let skip = try publish(400, [0, 1, 2])                          // tile 3 unchanged
        XCTAssertFalse(store.snapshot(ifNewerThan: nil)?.frames[0] === skip[0].pixelBuffer, "tile 3 may still come")
        store.noteArrival(rtpTimestamp: 800, tile: 0)
        var snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertTrue(snap.frames[2] === skip[2].pixelBuffer, "400 shown when 800's first packet arrived")
        store.noteArrival(rtpTimestamp: 800, tile: 3)                   // in flight while 0–2 decode
        let next = try publish(800, [0, 1, 2])
        XCTAssertNil(store.snapshot(ifNewerThan: snap.version), "tile 3 is on its way")
        let last = try publish(800, [3])
        snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertTrue(snap.frames[0] === next[0].pixelBuffer)
        XCTAssertTrue(snap.frames[3] === last[0].pixelBuffer)
        let stats = store.takePresentStats()
        XCTAssertEqual(stats.fills, 0)
        XCTAssertEqual(stats.skips, 1)
    }

    // MARK: strip tears (live: ~1 partial picture/s with zero loss)

    // MARK: pacing

    /// Publishes picture `ts` (two strips) at `start + ms` and returns tile 0's frame.
    private func paced(_ store: VideoFrameStore, _ e: Int, ts: UInt32, seq: Int, at ms: Double,
                       from start: ContinuousClock.Instant) throws -> DecodedFrame {
        let now = start + .microseconds(Int64(ms * 1000))
        let f = try frame(tile: 0, seq: seq, ts: ts)
        store.publish(f, epoch: e, now: now)
        store.publish(try frame(tile: 1, seq: seq + 1, ts: ts), epoch: e, now: now)
        return f
    }

    private func shown(_ store: VideoFrameStore, at ms: Double, from start: ContinuousClock.Instant) -> CVPixelBuffer? {
        store.snapshot(ifNewerThan: nil, now: start + .microseconds(Int64(ms * 1000)))?.frames[0]
    }

    /// Pictures 16.7 ms apart on the RTP clock that complete with jitter
    /// (0, 25, 30, 50 ms) are presented on their own timeline: the earliest
    /// arrival relative to its timestamp (the floor) + the delay, i.e. at
    /// 10, 26.7, 40 and 56.7 ms, ~16.7 ms apart.
    func testPacingPresentsOnTheRTPTimeline() throws {
        let store = VideoFrameStore()
        store.setPacing(.init(delay: .milliseconds(10), window: .seconds(1), maxHold: .milliseconds(40)))
        let e = store.reset()
        store.configure(tileCount: 2)
        _ = store.snapshot(ifNewerThan: nil)
        _ = store.takePresentStats()
        let start = ContinuousClock.now
        var pics: [DecodedFrame] = []
        for (k, at) in [0.0, 25, 30, 50].enumerated() {
            pics.append(try paced(store, e, ts: UInt32(400 * k), seq: 10 * k, at: at, from: start))
        }
        XCTAssertNil(shown(store, at: 9, from: start))
        XCTAssertTrue(shown(store, at: 10.5, from: start) === pics[0].pixelBuffer)
        XCTAssertTrue(shown(store, at: 26, from: start) === pics[0].pixelBuffer)
        XCTAssertTrue(shown(store, at: 27, from: start) === pics[1].pixelBuffer)
        XCTAssertTrue(shown(store, at: 39.5, from: start) === pics[1].pixelBuffer)
        XCTAssertTrue(shown(store, at: 40.5, from: start) === pics[2].pixelBuffer)
        XCTAssertNotNil(store.nextDue)
        XCTAssertTrue(shown(store, at: 57, from: start) === pics[3].pixelBuffer)
        XCTAssertNil(store.nextDue)
        let stats = store.takePresentStats()
        XCTAssertEqual(stats.queued, 4)
        XCTAssertEqual(stats.paceSkips, 0)
    }

    /// A picture later than its due time is presentable at once, and when
    /// the renderer misses a due time only the newest due picture is shown.
    func testPacingNeverHoldsALatePictureAndShowsTheNewestDue() throws {
        let store = VideoFrameStore()
        store.setPacing(.init(delay: .milliseconds(10), window: .seconds(1), maxHold: .milliseconds(40)))
        let e = store.reset()
        store.configure(tileCount: 2)
        _ = store.snapshot(ifNewerThan: nil)
        _ = store.takePresentStats()
        let start = ContinuousClock.now
        _ = try paced(store, e, ts: 0, seq: 0, at: 0, from: start)
        let late = try paced(store, e, ts: 400, seq: 10, at: 60, from: start)   // due 26.7: late
        XCTAssertTrue(shown(store, at: 60, from: start) === late.pixelBuffer)
        XCTAssertEqual(store.takePresentStats().paceSkips, 1)
    }

    /// No picture is held longer than `maxHold` after it was committed.
    func testPacingHoldIsCapped() throws {
        let store = VideoFrameStore()
        store.setPacing(.init(delay: .milliseconds(100), window: .seconds(1), maxHold: .milliseconds(30)))
        let e = store.reset()
        store.configure(tileCount: 2)
        let start = ContinuousClock.now
        let p = try paced(store, e, ts: 0, seq: 0, at: 0, from: start)
        XCTAssertNil(shown(store, at: 29, from: start))
        XCTAssertTrue(shown(store, at: 30, from: start) === p.pixelBuffer)
    }


    /// second. A picture whose last strips are merely late must not be shown
    /// with the previous picture's strips (the old 50 ms timeout did).
    func testAStallShorterThanTheTimeoutDoesNotTear() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        let start = ContinuousClock.now
        for t in 0..<2 { store.publish(try frame(tile: t, seq: 50 + t, ts: 300), epoch: e, now: start) }
        store.flushStaged(now: start + .milliseconds(60))
        store.flushStaged(now: start + .milliseconds(95))
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 0, "late strips are waited for")
        for t in 2..<4 {
            store.publish(try frame(tile: t, seq: 50 + t, ts: 300), epoch: e, now: start + .milliseconds(98))
        }
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 4)
        XCTAssertEqual(store.takePartialCommits(), 0)
    }

    /// Strips decode in picture order, so a strip of the next picture means
    /// the previous one is final. Should a strip of it still come (VideoToolbox
    /// output out of order; never seen live), it fills the shown picture in.
    func testAStripAfterTheNextPictureStartedFillsTheShownPicture() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        for t in 0..<3 { store.publish(try frame(tile: t, seq: 60 + t, ts: 400), epoch: e) }
        let early = try frame(tile: 0, seq: 64, ts: 800)
        store.publish(early, epoch: e)
        var snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(snap.frames.count, 3)
        XCTAssertFalse(snap.frames[0] === early.pixelBuffer, "the next picture is still staged")
        let last = try frame(tile: 3, seq: 63, ts: 400)
        store.publish(last, epoch: e)
        snap = try XCTUnwrap(store.snapshot(ifNewerThan: snap.version))
        XCTAssertTrue(snap.frames[3] === last.pixelBuffer)
        var next = [early]
        for t in 1..<4 { next.append(try frame(tile: t, seq: 64 + t, ts: 800)); store.publish(next[t], epoch: e) }
        snap = try XCTUnwrap(store.snapshot(ifNewerThan: snap.version))
        for t in 0..<4 { XCTAssertTrue(snap.frames[t] === next[t].pixelBuffer) }
        let stats = store.takePresentStats()
        XCTAssertEqual(stats.outOfOrder, 1)
        XCTAssertEqual(stats.fills, 1)
        XCTAssertEqual(store.takePartialCommits(), 0)
    }

    /// A complete newer picture wins over an incomplete older one, whose
    /// late strips are then ignored.
    func testTheNewestCompletePictureIsShown() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        for t in 0..<2 { store.publish(try frame(tile: t, seq: 70 + t, ts: 100), epoch: e) }
        var newer: [DecodedFrame] = []
        for t in 0..<4 { newer.append(try frame(tile: t, seq: 72 + t, ts: 200)); store.publish(newer[t], epoch: e) }
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        for t in 0..<4 { XCTAssertTrue(snap.frames[t] === newer[t].pixelBuffer) }
        store.publish(try frame(tile: 2, seq: 76, ts: 100), epoch: e)   // the old picture's late strip
        XCTAssertNil(store.snapshot(ifNewerThan: snap.version))
        XCTAssertEqual(store.takePartialCommits(), 0)
    }

    /// A strip that arrives after its picture was shown incomplete (timeout)
    /// fills that picture in at once.
    func testALateStripCompletesTheShownPicture() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4)
        let start = ContinuousClock.now
        for t in 0..<3 { store.publish(try frame(tile: t, seq: 80 + t, ts: 500), epoch: e, now: start) }
        store.flushStaged(now: start + VideoFrameStore.stagingTimeout)
        let before = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(before.frames.count, 3)
        let late = try frame(tile: 3, seq: 83, ts: 500)
        store.publish(late, epoch: e)
        let after = try XCTUnwrap(store.snapshot(ifNewerThan: before.version))
        XCTAssertTrue(after.frames[3] === late.pixelBuffer)
        XCTAssertEqual(store.takePartialCommits(), 1)
    }

    /// RTP timestamps wrap: a picture just past the wrap is newer.
    func testTimestampWrapKeepsPictureOrder() throws {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 2)
        for t in 0..<2 { store.publish(try frame(tile: t, seq: 90 + t, ts: UInt32.max - 100), epoch: e) }
        var wrapped: [DecodedFrame] = []
        for t in 0..<2 { wrapped.append(try frame(tile: t, seq: 92 + t, ts: 200)); store.publish(wrapped[t], epoch: e) }
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        for t in 0..<2 { XCTAssertTrue(snap.frames[t] === wrapped[t].pixelBuffer) }
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
