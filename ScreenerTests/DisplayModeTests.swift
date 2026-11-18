import CoreVideo
import XCTest
@testable import Screener

/// Task 21: display modes, the debounced resize state machine, and the
/// receive side of an in-band resize (expected SSRC group adoption with
/// replay, the frame store holding the last picture until the new stream's).
final class DisplayModeTests: XCTestCase {
    // iPad Pro 13" (M4): 1376×1032 pt landscape, 2× (2752×2064 px).
    private let landscape = CGSize(width: 1376, height: 1032)
    private let portrait = CGSize(width: 1032, height: 1376)
    /// A half-width Stage Manager window on the 13" in landscape.
    private let halfWidth = CGSize(width: 688, height: 1032)

    private func g(_ w: Int, _ h: Int) -> DisplayGeometry { DisplayGeometry(logicalWidth: w, logicalHeight: h, hidpiScale: 2) }

    // MARK: geometry

    func testFitRetinaIsTheViewInPointsAt2x() {
        let l = DisplayMode.fitRetina.geometry(viewPoints: landscape, scale: 2)
        XCTAssertEqual(l, g(1376, 1032))
        XCTAssertEqual(l?.backingSize, CGSize(width: 2752, height: 2064))
        XCTAssertEqual(DisplayMode.fitRetina.geometry(viewPoints: portrait, scale: 2), g(1032, 1376))
        XCTAssertEqual(DisplayMode.fitRetina.geometry(viewPoints: halfWidth, scale: 2)?.backingSize,
                       CGSize(width: 1376, height: 2064))
        // Fractional Stage Manager sizes round to whole points.
        XCTAssertEqual(DisplayMode.fitRetina.geometry(viewPoints: CGSize(width: 683.5, height: 1012), scale: 2),
                       g(684, 1012))
    }

    func testMoreSpaceIs125PercentRoundedEven() {
        XCTAssertEqual(DisplayMode.moreSpace.geometry(viewPoints: landscape, scale: 2), g(1720, 1290))
        XCTAssertEqual(DisplayMode.moreSpace.geometry(viewPoints: landscape, scale: 2)?.backingSize,
                       CGSize(width: 3440, height: 2580))
        XCTAssertEqual(DisplayMode.moreSpace.geometry(viewPoints: portrait, scale: 2), g(1290, 1720))
        XCTAssertEqual(DisplayMode.moreSpace.geometry(viewPoints: halfWidth, scale: 2), g(860, 1290))
        let odd = DisplayMode.moreSpace.geometry(viewPoints: CGSize(width: 683, height: 1011), scale: 2)!
        XCTAssertEqual([odd.logicalWidth % 2, odd.logicalHeight % 2], [0, 0])
        XCTAssertEqual(odd, g(854, 1264))   // 853.75 → 854, 1263.75 → 1264
    }

    func testSharperIs80PercentRoundedEven() {
        XCTAssertEqual(DisplayMode.sharper.geometry(viewPoints: landscape, scale: 2), g(1100, 826))
        XCTAssertEqual(DisplayMode.sharper.geometry(viewPoints: landscape, scale: 2)?.backingSize,
                       CGSize(width: 2200, height: 1652))
        XCTAssertEqual(DisplayMode.sharper.geometry(viewPoints: portrait, scale: 2), g(826, 1100))
        XCTAssertEqual(DisplayMode.sharper.geometry(viewPoints: halfWidth, scale: 2), g(550, 826))
    }

    func testMatchMacSendsNoDynamicGeometryAndUsesTheMacsSize() {
        XCTAssertNil(DisplayMode.matchMac.geometry(viewPoints: landscape, scale: 2))
        XCTAssertFalse(DisplayMode.matchMac.isDynamic)
        XCTAssertTrue(DisplayMode.allCases.filter { $0 != .matchMac }.allSatisfy(\.isDynamic))
        XCTAssertEqual(DisplayGeometry.matching(serverWidth: 1920, serverHeight: 1080), g(1920, 1080))
        // A 5K framebuffer reported in pixels is kept inside the cap.
        let big = DisplayGeometry.matching(serverWidth: 5120, serverHeight: 2880)!
        XCTAssertLessThanOrEqual(max(big.backingWidth, big.backingHeight), 3840)
    }

    func testBackingIsShrunkUniformlyIntoTheCap() {
        let big = DisplayMode.moreSpace.geometry(viewPoints: CGSize(width: 2000, height: 1500), scale: 2)!
        XCTAssertEqual(big, g(1920, 1440))
        XCTAssertEqual(big.backingSize, CGSize(width: 3840, height: 2880))
        let tall = DisplayMode.moreSpace.geometry(viewPoints: CGSize(width: 1500, height: 2000), scale: 2)!
        XCTAssertEqual(tall, g(1440, 1920))
        let tiny = DisplayMode.fitRetina.geometry(viewPoints: CGSize(width: 200, height: 100), scale: 2)!
        XCTAssertEqual([tiny.logicalWidth, tiny.logicalHeight], [DisplayGeometry.minLogical, DisplayGeometry.minLogical])
        XCTAssertNil(DisplayMode.fitRetina.geometry(viewPoints: .zero, scale: 2))
    }

    /// The descriptor's max size bounds both orientations (the server keeps
    /// the connect-time bound per axis for the session; live 2026-11-18).
    func testDescriptorMaxBoundsBothOrientations() {
        XCTAssertEqual(g(1376, 1032).maxBacking.width, 3840)
        XCTAssertEqual(g(1376, 1032).maxBacking.height, 3840)
        XCTAssertEqual(g(1032, 1376).maxBacking.height, 3840)
    }

    func testStoredModeDefaultsToFitRetina() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "DisplayModeTests"))
        d.removePersistentDomain(forName: "DisplayModeTests")
        XCTAssertEqual(DisplayMode.stored(d), .fitRetina)
        d.set("sharper", forKey: DisplayMode.defaultsKey)
        XCTAssertEqual(DisplayMode.stored(d), .sharper)
        d.set("bogus", forKey: DisplayMode.defaultsKey)
        XCTAssertEqual(DisplayMode.stored(d), .fitRetina)
        d.removePersistentDomain(forName: "DisplayModeTests")
    }

    // MARK: resize state machine

    @MainActor
    private final class Sent {
        var geometries: [DisplayGeometry] = []
    }

    @MainActor
    private func resizer(_ mode: DisplayMode = .fitRetina, _ sent: Sent) -> DisplayResizer {
        DisplayResizer(mode: mode, debounce: .milliseconds(40),
                       hooks: .init(send: { sent.geometries.append($0) }))
    }

    @MainActor
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    /// A rotation reports several sizes in a row: one 0x1d for the last one,
    /// after the quiet period.
    @MainActor
    func testRapidViewChangesSendOneRequestAfterTheDebounce() async throws {
        let sent = Sent()
        let r = resizer(.fitRetina, sent)
        r.viewChanged(points: landscape, scale: 2)
        r.start(initial: g(1376, 1032))
        try await settle()
        XCTAssertEqual(sent.geometries, [], "the connect-time geometry is already in effect")

        r.viewChanged(points: CGSize(width: 1200, height: 1100), scale: 2)
        r.viewChanged(points: CGSize(width: 1100, height: 1200), scale: 2)
        r.viewChanged(points: portrait, scale: 2)
        XCTAssertEqual(sent.geometries, [], "nothing before the debounce")
        try await settle()
        XCTAssertEqual(sent.geometries, [g(1032, 1376)])
        XCTAssertEqual(r.current, g(1032, 1376))

        // Same size again (e.g. a layout pass): no new request.
        r.viewChanged(points: portrait, scale: 2)
        r.viewChanged(points: CGSize(width: 1032.2, height: 1375.9), scale: 2)
        try await settle()
        XCTAssertEqual(sent.geometries.count, 1)
        XCTAssertEqual(r.requestsSent, 1)
    }

    @MainActor
    func testModeChangesRequestTheirGeometry() async throws {
        let sent = Sent()
        let r = resizer(.fitRetina, sent)
        r.viewChanged(points: landscape, scale: 2)
        r.start(initial: g(1376, 1032), mac: g(1920, 1080))
        r.setMode(.sharper)
        try await settle()
        r.setMode(.moreSpace)
        try await settle()
        r.setMode(.matchMac)
        try await settle()
        XCTAssertEqual(sent.geometries, [g(1100, 826), g(1720, 1290), g(1920, 1080)])
        // matchMac does not follow the view.
        r.viewChanged(points: portrait, scale: 2)
        try await settle()
        XCTAssertEqual(sent.geometries.count, 3)
        // Back to a dynamic mode: follows the (new) view at once.
        r.setMode(.fitRetina)
        try await settle()
        XCTAssertEqual(sent.geometries.last, g(1032, 1376))
    }

    @MainActor
    func testNoRequestsWithoutASessionAndPendingOnesAreCancelledByStop() async throws {
        let sent = Sent()
        let r = resizer(.fitRetina, sent)
        r.viewChanged(points: portrait, scale: 2)
        try await settle()
        XCTAssertEqual(sent.geometries, [], "not connected")
        r.start(initial: g(1376, 1032))
        r.stop()
        try await settle()
        XCTAssertEqual(sent.geometries, [], "stopped before the debounce ran out")
        // A view change during connect is applied when the session starts.
        r.viewChanged(points: halfWidth, scale: 2)
        r.start(initial: g(1032, 1376))
        try await settle()
        XCTAssertEqual(sent.geometries, [g(688, 1032)])
    }

    @MainActor
    func testAMatchMacSessionSendsNothingUntilTheModeChanges() async throws {
        let sent = Sent()
        let r = resizer(.matchMac, sent)
        r.viewChanged(points: landscape, scale: 2)
        r.start(initial: g(1920, 1080), mac: g(1920, 1080))
        r.viewChanged(points: portrait, scale: 2)
        try await settle()
        XCTAssertEqual(sent.geometries, [])
        r.setMode(.fitRetina)
        try await settle()
        XCTAssertEqual(sent.geometries, [g(1032, 1376)])
    }

    // MARK: SSRC group: expected adoption

    func testAnExpectedGroupIsAdoptedWithoutTheStall() {
        let t0 = ContinuousClock.now
        var tr = SSRCGroupTracker(stall: .seconds(2))
        tr.lock([1, 2, 3, 4])
        tr.notePublish(at: t0)
        let counts: [UInt32: Int] = [1: 50, 2: 50, 3: 50, 4: 50, 10: 5, 11: 5, 12: 5, 13: 5]
        XCTAssertNil(tr.noteUnknown(10, counts: counts, now: t0 + .milliseconds(100)), "old group still publishing")
        tr.expectNewGroup(until: t0 + .seconds(5))
        XCTAssertTrue(tr.isExpecting(at: t0 + .milliseconds(100)))
        XCTAssertEqual(tr.noteUnknown(10, counts: counts, now: t0 + .milliseconds(200)), [10, 11, 12, 13])
        XCTAssertFalse(tr.isExpecting(at: t0 + .milliseconds(300)), "one adoption per expectation")
        // The expectation expires.
        tr.notePublish(at: t0 + .seconds(6))
        tr.expectNewGroup(until: t0 + .seconds(7))
        XCTAssertNil(tr.noteUnknown(20, counts: [20: 9, 21: 9, 22: 9, 23: 9], now: t0 + .seconds(7.5)))
    }

    // MARK: MediaTransport: the new group's first packets are replayed

    func testExpectedGroupIsAdoptedAtOnceAndItsFirstPacketsAreReplayed() async throws {
        let blob = Data(hex: try Fixture.load("srtp")["blob"] as! String)
        func variant(_ b: UInt8) -> Data { var d = blob; d[0] ^= b; return d }
        let keys = NegotiationKeys(audioKeyV: variant(1), audioKeyS: variant(2), videoKeyV: variant(3), videoKeyS: variant(4))
        var tuning = MediaTransport.Tuning()
        tuning.burstMinPackets = 30
        tuning.burstDeadline = .milliseconds(300)
        tuning.burstSettle = .milliseconds(20)
        tuning.adoptStall = .seconds(30)   // never by stall in this test
        let ch = FakeChannels()
        let t = MediaTransport(config: .init(host: "192.0.2.1"), tuning: tuning, channelFactory: ch.factory)
        let received = PacketLog()
        let consumer = Task { for await p in t.video { received.add(p) } }
        try await t.open()
        try await t.activate(.init(keys: keys, ourVideoSSRC: 0x4014_2F36, ourAudioSSRC: 0x0A69_A4FF, tilesPerGroup: 4))
        for s: UInt32 in 0x10...0x13 {
            let e = try SRTPEncryptor(blob: keys.videoKeyS, ssrc: s, seq: 100)
            for _ in 0..<8 { ch.video.deliver(try e.encrypt(Data([1]), pt: 100)) }
        }
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .started(packets: 32, group: [0x10, 0x11, 0x12, 0x13]))

        await t.expectNewGroup()
        // The new group's burst: the first packet of each SSRC carries its
        // parameter sets (payload 0xAA); adoption needs 5 per SSRC.
        for s: UInt32 in 0x90...0x93 {
            let e = try SRTPEncryptor(blob: keys.videoKeyS, ssrc: s, seq: 1)
            ch.video.deliver(try e.encrypt(Data([0xAA]), pt: 100))
            for _ in 0..<5 { ch.video.deliver(try e.encrypt(Data([1]), pt: 100)) }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while await t.activeVideoSSRCs != [0x90, 0x91, 0x92, 0x93], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let active = await t.activeVideoSSRCs
        XCTAssertEqual(active, [0x90, 0x91, 0x92, 0x93], "adopted without waiting for the stall")
        while received.count(where: { $0.ssrc >= 0x90 }) < 24, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let fresh = received.all.filter { $0.ssrc >= 0x90 }
        XCTAssertEqual(fresh.count, 24, "every packet of the new group, including those before adoption")
        for s: UInt32 in 0x90...0x93 {
            XCTAssertEqual(fresh.first { $0.ssrc == s }?.payload, Data([0xAA]), "first packet of \(s) replayed first")
        }
        let adoptions = await t.stats.groupAdoptions
        XCTAssertEqual(adoptions, 1)
        consumer.cancel()
        await t.close()
    }

    // MARK: VideoFrameStore: the last picture is held through a resize

    private func pixelBuffer() throws -> CVPixelBuffer {
        var b: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                           nil, &b), kCVReturnSuccess)
        return try XCTUnwrap(b)
    }

    private func frame(tile: Int, seq: Int, ts: UInt32? = nil) throws -> DecodedFrame {
        DecodedFrame(tile: tile, pixelBuffer: try pixelBuffer(), decodeTime: .milliseconds(1), don: 0, seq: seq,
                     rtpTimestamp: ts)
    }

    /// A store showing a 4-tile 2752×2064 picture (decoder seqs 1–4).
    private func showingLandscape() throws -> (VideoFrameStore, Int) {
        let store = VideoFrameStore()
        let e = store.reset()
        store.configure(tileCount: 4, canvas: CGSize(width: 2752, height: 2064))
        for t in 0..<4 { store.publish(try frame(tile: t, seq: t + 1), epoch: e) }
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.frames.count, 4)
        return (store, e)
    }

    func testTheLastPictureIsHeldUntilTheNewStreamsFirstIsComplete() throws {
        let (store, e) = try showingLandscape()
        let before = try XCTUnwrap(store.snapshot(ifNewerThan: nil))

        // 0x451 → 2064×2752; then the pipeline switches groups (3 tiles, say).
        store.holdForResize(canvas: CGSize(width: 2064, height: 2752))
        store.beginGroup(tileCount: 3, afterSeq: 10)
        XCTAssertTrue(store.isHoldingForNewStream)
        XCTAssertNil(store.snapshot(ifNewerThan: before.version), "nothing changes yet: the old picture stays up")

        // A late picture of the OLD stream (submitted before the switch) still lands on the old canvas.
        store.publish(try frame(tile: 0, seq: 9), epoch: e)
        let late = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(late.canvas, CGSize(width: 2752, height: 2064))
        XCTAssertEqual(late.tileCount, 4)

        // New stream strips: held until all 3 are in, then everything switches together.
        store.publish(try frame(tile: 0, seq: 11, ts: 500), epoch: e)
        store.publish(try frame(tile: 1, seq: 12, ts: 500), epoch: e)
        XCTAssertNil(store.snapshot(ifNewerThan: late.version), "partial new picture not shown")
        store.publish(try frame(tile: 2, seq: 13, ts: 500), epoch: e)
        let after = try XCTUnwrap(store.snapshot(ifNewerThan: late.version))
        XCTAssertEqual(after.canvas, CGSize(width: 2064, height: 2752))
        XCTAssertEqual(after.tileCount, 3)
        XCTAssertEqual(Set(after.frames.keys), [0, 1, 2], "no old strip mixed into the new canvas")
        XCTAssertFalse(store.isHoldingForNewStream)

        // Then the new stream flows normally.
        for t in 0..<3 { store.publish(try frame(tile: t, seq: 20 + t, ts: 900), epoch: e) }
        XCTAssertNotNil(store.snapshot(ifNewerThan: after.version))
    }

    func testAPartialFirstPictureIsShownAfterTheTimeout() throws {
        let (store, e) = try showingLandscape()
        store.holdForResize(canvas: CGSize(width: 2064, height: 2752))
        store.beginGroup(tileCount: 4, afterSeq: 10)
        let t0 = ContinuousClock.now
        store.publish(try frame(tile: 0, seq: 11), epoch: e, now: t0)
        let v = store.currentVersion
        store.flushStaged(now: t0 + .milliseconds(100))
        XCTAssertEqual(store.currentVersion, v)
        store.flushStaged(now: t0 + VideoFrameStore.incomingTimeout)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: v))
        XCTAssertEqual(snap.canvas, CGSize(width: 2064, height: 2752))
        XCTAssertEqual(Array(snap.frames.keys), [0])
    }

    func testWithNothingOnScreenTheNewGeometryAppliesAtOnce() throws {
        let store = VideoFrameStore()
        store.reset()
        store.configure(tileCount: 4, canvas: CGSize(width: 2752, height: 2064))
        store.holdForResize(canvas: CGSize(width: 2064, height: 2752))
        store.beginGroup(tileCount: 2, afterSeq: 5)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(snap.canvas, CGSize(width: 2064, height: 2752))
        XCTAssertEqual(snap.tileCount, 2)
        XCTAssertFalse(store.isHoldingForNewStream)
    }

    func testAHeldCanvasWithoutANewStreamIsAppliedAfterTheLimit() throws {
        let (store, _) = try showingLandscape()
        let t0 = ContinuousClock.now
        store.holdForResize(canvas: CGSize(width: 2064, height: 2752), now: t0)
        store.flushStaged(now: t0 + .seconds(1))
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.canvas, CGSize(width: 2752, height: 2064))
        store.flushStaged(now: t0 + VideoFrameStore.resizeHoldLimit)
        XCTAssertEqual(store.snapshot(ifNewerThan: nil)?.canvas, CGSize(width: 2064, height: 2752))
        XCTAssertFalse(store.isHoldingForNewStream)
    }

    /// A stream restart with the same geometry: a tile the first new picture
    /// lacks keeps its last strip (no black band).
    func testASameGeometryRestartKeepsStripsTheNewPictureLacks() throws {
        let (store, e) = try showingLandscape()
        store.beginGroup(tileCount: 4, afterSeq: 10)
        let t0 = ContinuousClock.now
        store.publish(try frame(tile: 1, seq: 11), epoch: e, now: t0)
        store.flushStaged(now: t0 + VideoFrameStore.incomingTimeout)
        let snap = try XCTUnwrap(store.snapshot(ifNewerThan: nil))
        XCTAssertEqual(Set(snap.frames.keys), [0, 1, 2, 3])
        XCTAssertEqual(snap.canvas, CGSize(width: 2752, height: 2064))
    }

    func testResetDropsAHold() throws {
        let (store, _) = try showingLandscape()
        store.holdForResize(canvas: CGSize(width: 2064, height: 2752))
        store.beginGroup(tileCount: 4, afterSeq: 10)
        store.reset()
        XCTAssertFalse(store.isHoldingForNewStream)
    }
}

/// Packets seen by a test consumer (any thread).
private final class PacketLog: @unchecked Sendable {   // `items` behind `lock`
    private let lock = NSLock()
    private var items: [MediaPacket] = []
    func add(_ p: MediaPacket) { lock.withLock { items.append(p) } }
    var all: [MediaPacket] { lock.withLock { items } }
    func count(where f: (MediaPacket) -> Bool) -> Int { lock.withLock { items.filter(f).count } }
}
