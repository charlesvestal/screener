import XCTest
@testable import Screener

/// In-memory `DatagramChannel`: tests push inbound datagrams and inspect sends.
final class FakeDatagramChannel: DatagramChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var receive: (@Sendable (Data) -> Void)?
    private var failure: (@Sendable (String) -> Void)?
    private var _sent: [Data] = []
    private var _cancelled = false
    private var _started = false
    private var _blocked: Int32?
    /// When set, `start` throws this.
    var startError: Error?
    /// What `startupBlockedErrno` reports (EPERM etc. before the stream).
    var blocked: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return _blocked }
        set { lock.lock(); _blocked = newValue; lock.unlock() }
    }
    var startupBlockedErrno: Int32? { blocked }

    func start(onReceive: @escaping @Sendable (Data) -> Void, onEvent: @escaping @Sendable (String) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) throws {
        if let startError { throw startError }
        lock.lock(); receive = onReceive; failure = onFailure; _started = true; lock.unlock()
    }
    func deliver(_ d: Data) { lock.lock(); let r = receive; lock.unlock(); r?(d) }
    func fail(_ why: String) { lock.lock(); let f = failure; lock.unlock(); f?(why) }
    func send(_ d: Data) { lock.lock(); _sent.append(d); lock.unlock() }
    func cancel() async { markCancelled() }
    private func markCancelled() { lock.lock(); _cancelled = true; lock.unlock() }
    var sent: [Data] { lock.lock(); defer { lock.unlock() }; return _sent }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
}

final class FakeChannels: @unchecked Sendable {
    let video = FakeDatagramChannel()
    let audio = FakeDatagramChannel()
    var factory: MediaTransport.ChannelFactory {
        { [video, audio] flow, _ in flow == .video ? video : audio }
    }
}

final class MediaTransportTests: XCTestCase {
    private var blob: Data!
    private var keys: NegotiationKeys!
    private let ourVideo: UInt32 = 0x4014_2F36
    private let ourAudio: UInt32 = 0x0A69_A4FF

    override func setUpWithError() throws {
        blob = Data(hex: try Fixture.load("srtp")["blob"] as! String)
        func variant(_ b: UInt8) -> Data { var d = blob!; d[0] ^= b; return d }
        keys = NegotiationKeys(audioKeyV: variant(1), audioKeyS: variant(2), videoKeyV: variant(3), videoKeyS: variant(4))
    }

    private var fastTuning: MediaTransport.Tuning {
        var t = MediaTransport.Tuning()
        t.txInterval = .milliseconds(20)
        t.punchInterval = .milliseconds(10)
        t.burstMinPackets = 30
        t.burstDeadline = .milliseconds(300)
        t.burstSettle = .milliseconds(20)
        t.burstStarvedBelow = 20
        t.adoptStall = .milliseconds(100)
        t.keyframeMinInterval = .milliseconds(250)
        return t
    }

    private func make(_ ch: FakeChannels, tuning: MediaTransport.Tuning? = nil) -> MediaTransport {
        MediaTransport(config: .init(host: "192.0.2.1"), tuning: tuning ?? fastTuning, channelFactory: ch.factory)
    }

    private var activation: MediaTransport.Activation {
        .init(keys: keys, ourVideoSSRC: ourVideo, ourAudioSSRC: ourAudio, tilesPerGroup: 4)
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(3),
                           _ cond: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Server-side encryptors (server→viewer = S keys).
    private func videoSender(_ ssrc: UInt32) throws -> SRTPEncryptor { try SRTPEncryptor(blob: keys.videoKeyS, ssrc: ssrc, seq: 100) }

    // MARK: classification + fields

    func testVideoAndAudioPacketsDecryptWithSKeysAndCarryHeaderFields() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        try await t.activate(activation)

        // A 4-SSRC group carrying enough packets to lock the burst.
        let group: [UInt32] = [0x1000, 0x1001, 0x1002, 0x1003]
        let encs = try group.map { try videoSender($0) }
        for i in 0..<10 {
            for j in 0..<4 {
                ch.video.deliver(try encs[j].encrypt(Data("tile\(j)-\(i)".utf8), pt: 100, marker: i == 9))
            }
        }
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .started(packets: 40, group: group))
        let active = await t.activeVideoSSRCs
        XCTAssertEqual(active, group)

        // Burst packets of the locked group come out in arrival order.
        var it = t.video.makeAsyncIterator()
        let firstOpt = await it.next()
        let first = try XCTUnwrap(firstOpt)
        XCTAssertEqual(first.ssrc, 0x1000)
        XCTAssertEqual(first.seq, 100)
        XCTAssertEqual(first.timestamp, 0)
        XCTAssertEqual(first.payloadType, 100)
        XCTAssertFalse(first.marker)
        XCTAssertEqual(first.payload, Data("tile0-0".utf8))
        let secondOpt = await it.next()
        let second = try XCTUnwrap(secondOpt)
        XCTAssertEqual(second.ssrc, 0x1001)

        // Post-lock, a marker packet with a non-zero timestamp.
        let enc = try SRTPEncryptor(blob: keys.videoKeyS, ssrc: 0x1002, seq: 500, ts: 9000)
        ch.video.deliver(try enc.encrypt(Data([0xAB]), pt: 100, marker: true))
        var last: MediaPacket?
        while let p = await it.next() { if p.seq == 500 { last = p; break } }
        XCTAssertEqual(last?.ssrc, 0x1002)
        XCTAssertEqual(last?.timestamp, 9000)
        XCTAssertEqual(last?.marker, true)
        XCTAssertEqual(last?.payload, Data([0xAB]))

        // Audio on P with audioKeyS.
        let aenc = try SRTPEncryptor(blob: keys.audioKeyS, ssrc: 0x7777, seq: 3, ts: 480)
        ch.audio.deliver(try aenc.encrypt(Data([1, 2, 3]), pt: 101))
        var ait = t.audio.makeAsyncIterator()
        let aOpt = await ait.next()
        let a = try XCTUnwrap(aOpt)
        XCTAssertEqual(a.ssrc, 0x7777)
        XCTAssertEqual(a.seq, 3)
        XCTAssertEqual(a.timestamp, 480)
        XCTAssertEqual(a.payloadType, 101)
        XCTAssertEqual(a.payload, Data([1, 2, 3]))

        // Wrong-key and garbage datagrams are counted, not delivered.
        let wrong = try SRTPEncryptor(blob: keys.videoKeyV, ssrc: 0x1000)
        ch.video.deliver(try wrong.encrypt(Data([9]), pt: 100))
        ch.video.deliver(Data([0x00]))
        try await waitUntil("auth failures") { await t.stats.authFailures == 2 }
        let s = await t.stats
        XCTAssertEqual(s.videoPackets, 41)
        XCTAssertEqual(s.audioPackets, 1)
        await t.close()
    }

    func testDatagramsBeforeActivationAreBufferedThenDecrypted() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        let enc = try videoSender(0x2000)
        for _ in 0..<3 { ch.video.deliver(try enc.encrypt(Data([1]), pt: 100)) }
        try await waitUntil("raw buffered") { await t.stats.videoDatagrams == 3 }
        let before = await t.stats.videoPackets
        XCTAssertEqual(before, 0)
        try await t.activate(activation)
        let after = await t.stats.videoPackets
        XCTAssertEqual(after, 3)
        await t.close()
    }

    // MARK: RTCP routing

    func testServerRTCPIsRoutedToSRTCPAndFeedsTheReceiverReport() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        try await t.activate(activation)

        // A server SR on the video port, SRTCP-protected with videoKeyS.
        let sr = Data(hex: "80c80006" + "00001000" + "0001aaaa" + "bbbb0000" + "00000000" + "00000000" + "00000000")
        ch.video.deliver(try SRTCPEncryptor(blob: keys.videoKeyS).protect(sr))
        // And one on the audio port protected with the video key (what the reference assumed).
        ch.audio.deliver(try SRTCPEncryptor(blob: keys.videoKeyS).protect(sr))
        // An RTCP-looking packet nobody can authenticate.
        ch.audio.deliver(Data([0x80, 201, 0, 1, 0, 0, 0, 1]) + Data(repeating: 0, count: 14))
        try await waitUntil("rtcp") { await t.stats.rtcpPackets == 2 }
        let s = await t.stats
        XCTAssertEqual(s.serverSRs, 2)
        XCTAssertEqual(s.rtcpAuthFailures, 1)
        XCTAssertEqual(s.videoPackets + s.audioPackets, 0, "RTCP must not reach the RTP decryptors")
        XCTAssertEqual(s.authFailures, 0)
        await t.close()
    }

    // MARK: send path

    func testKeepaliveAndReceiverReportsGoToTheAudioPortWithVKeys() async throws {
        let ch = FakeChannels()
        var tuning = fastTuning
        tuning.srEveryNTicks = 2
        let t = make(ch, tuning: tuning)
        try await t.open()
        try await t.activate(activation)
        try await waitUntil("reports") { await t.stats.reportsSent >= 2 }
        await t.close()

        let audioDec = try SRTPDecryptor(blob: keys.audioKeyV)
        let rtcpDec = try SRTCPDecryptor(blob: keys.videoKeyV)
        var keepalives = 0, rrs = 0, srs = 0, punches = 0
        for d in ch.audio.sent {
            if d == Data([0x00]) { punches += 1; continue }
            if RTCP.isRTCP(d) {
                let p = try XCTUnwrap(rtcpDec.unprotect(d), "RTCP must be protected with videoKeyV")
                if p[1] == 200 { srs += 1; XCTAssertEqual(p[p.startIndex + 29], 201) } else { XCTAssertEqual(p[1], 201) }
                XCTAssertEqual(p.subdata(in: 4..<8), Data([0x40, 0x14, 0x2F, 0x36]))
                rrs += 1
            } else {
                let out = try XCTUnwrap(audioDec.decrypt(d), "keepalive must be protected with audioKeyV")
                XCTAssertEqual(out.ssrc, ourAudio)
                XCTAssertEqual(out.header[1] & 0x7F, 101)
                XCTAssertEqual(out.payload, Data([0x00, 0x68, 0x34, 0x00]))
                keepalives += 1
            }
        }
        XCTAssertGreaterThanOrEqual(keepalives, 2)
        XCTAssertGreaterThanOrEqual(rrs, 2)
        XCTAssertGreaterThanOrEqual(srs, 1)
        XCTAssertGreaterThan(punches, 0)
        // Only punches go out on the video port.
        XCTAssertTrue(ch.video.sent.allSatisfy { $0 == Data([0x00]) })
    }

    func testRequestKeyframeSendsCompoundFIRAndIsRateLimited() async throws {
        let ch = FakeChannels()
        var tuning = fastTuning
        tuning.txInterval = .seconds(60)   // keep RR/keepalive out of the way
        let t = make(ch, tuning: tuning)
        try await t.open()
        try await t.activate(activation)
        try await waitUntil("first tick") { await t.stats.reportsSent == 1 }
        let target: UInt32 = 0x1122_3344
        let sentFirst = await t.requestKeyframe(ssrc: target)
        let sentAgain = await t.requestKeyframe(ssrc: target)
        XCTAssertTrue(sentFirst)
        XCTAssertFalse(sentAgain, "second request inside 250 ms is coalesced")
        await t.close()

        let rtcpDec = try SRTCPDecryptor(blob: keys.videoKeyV)
        let firs = ch.audio.sent.filter { RTCP.isRTCP($0) }.compactMap { rtcpDec.unprotect($0) }
            .filter { $0.count > 8 + 8 + 4 }   // the first tick's RR is 8 bytes (no group yet)
        XCTAssertEqual(firs.count, 1)
        let expected = RTCP.compoundWithRR(senderSSRC: ourVideo,
                                           payload: RTCP.fir(senderSSRC: ourVideo, targetSSRC: target, seq: 1)
                                               + RTCP.pli(senderSSRC: ourVideo, mediaSSRC: target)
                                               + RTCP.firLegacy(targetSSRC: target))
        XCTAssertEqual(firs.first?.hex, expected.hex)
    }

    // MARK: burst starvation + adoption

    func testBurstWithTooFewPacketsIsStarved() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        try await t.activate(activation)
        let enc = try videoSender(0x1000)
        for _ in 0..<5 { ch.video.deliver(try enc.encrypt(Data([1]), pt: 100)) }
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .starved(packets: 5))
        await t.close()
    }

    func testBurstLocksTheConsecutiveGroupWithMostPacketsAndLaterAdoptsAFreshGroup() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        try await t.activate(activation)
        // Low-tier group 0x50..0x53 (2 pkts each) + primary 0x10..0x13 (8 each).
        for s: UInt32 in 0x50...0x53 { let e = try videoSender(s); for _ in 0..<2 { ch.video.deliver(try e.encrypt(Data([1]), pt: 100)) } }
        for s: UInt32 in 0x10...0x13 { let e = try videoSender(s); for _ in 0..<8 { ch.video.deliver(try e.encrypt(Data([1]), pt: 100)) } }
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .started(packets: 40, group: [0x10, 0x11, 0x12, 0x13]))

        // The old group goes silent; a fresh group appears. After the stall,
        // 4 consecutive SSRCs with ≥5 packets each are adopted (+ FIRs).
        try await Task.sleep(for: .milliseconds(150))
        for s: UInt32 in 0x90...0x93 { let e = try videoSender(s); for _ in 0..<6 { ch.video.deliver(try e.encrypt(Data([1]), pt: 100)) } }
        try await waitUntil("adoption") { await t.activeVideoSSRCs == [0x90, 0x91, 0x92, 0x93] }
        try await waitUntil("FIRs") { await t.stats.keyframeRequestsSent == 4 }
        await t.close()
    }

    func testRTCPOnTheAudioPortAuthenticatesWithAudioKeyS() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        try await t.activate(activation)
        let sr = Data(hex: "80c80006" + "00007777" + "0001aaaa" + "bbbb0000" + "00000000" + "00000000" + "00000000")
        ch.audio.deliver(try SRTCPEncryptor(blob: keys.audioKeyS).protect(sr))
        try await waitUntil("rtcp") { await t.stats.rtcpPackets == 1 }
        let s = await t.stats
        XCTAssertEqual(s.serverSRs, 1)
        XCTAssertEqual(s.rtcpAuthFailures, 0)
        XCTAssertEqual(s.authFailures, 0)
        await t.close()
    }

    // MARK: lifecycle failures

    func testOpenThrowsWhenAPortCannotBeBoundAndReleasesTheOtherChannel() async throws {
        let ch = FakeChannels()
        ch.audio.startError = DatagramChannelError.bind(port: 5900, errno: EADDRINUSE)
        let t = make(ch)
        do {
            try await t.open()
            XCTFail("expected open to throw")
        } catch let e as MediaTransportError {
            guard case .bindFailed(5900, 5901, _) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(e.localizedDescription, "UDP ports 5900/5901 unavailable (another Screen Sharing session?)")
        }
        XCTAssertTrue(ch.video.cancelled, "the already-bound video channel must be closed")
    }

    func testChannelFailureIsPublishedAndEndsTheBurstWait() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        try await t.activate(activation)
        ch.video.fail("receive: Socket is not connected (57)")
        var it = t.failures.makeAsyncIterator()
        let f = await it.next()
        XCTAssertEqual(f, .channelFailed("receive: Socket is not connected (57)"))
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .failed(.channelFailed("receive: Socket is not connected (57)")))
        await t.close()
    }

    /// Sends still failing with a privacy-class error when the burst window
    /// closes: the session fails with the Local Network message, not "starved".
    func testABurstThatTimesOutWhileSendsAreBlockedFailsWithTheLocalNetworkMessage() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        ch.audio.blocked = EPERM
        let blockedNow = await t.localNetworkBlocked
        XCTAssertTrue(blockedNow)
        try await t.activate(activation)
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .failed(.localNetworkBlocked(errno: EPERM)))
        XCTAssertEqual(MediaTransportError.localNetworkBlocked(errno: EPERM).localizedDescription,
                       "Screener needs Local Network access — check Settings › Privacy & Security › Local Network.")
        var it = t.failures.makeAsyncIterator()
        let f = await it.next()
        XCTAssertEqual(f, .localNetworkBlocked(errno: EPERM))
        await t.close()
    }

    func testResetForRetryKeepsTheChannelsAndAcceptsAFreshBurst() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        try await t.activate(activation)
        let starved = await t.burstOutcome()
        XCTAssertEqual(starved, .starved(packets: 0))
        await t.resetForRetry()
        XCTAssertFalse(ch.video.cancelled)

        // New handshake, new keys.
        func variant(_ b: UInt8) -> Data { var d = blob!; d[1] ^= b; return d }
        let keys2 = NegotiationKeys(audioKeyV: variant(5), audioKeyS: variant(6), videoKeyV: variant(7), videoKeyS: variant(8))
        try await t.activate(.init(keys: keys2, ourVideoSSRC: ourVideo, ourAudioSSRC: ourAudio, tilesPerGroup: 4))
        for s: UInt32 in 0x10...0x13 {
            let e = try SRTPEncryptor(blob: keys2.videoKeyS, ssrc: s, seq: 1)
            for _ in 0..<8 { ch.video.deliver(try e.encrypt(Data([1]), pt: 100)) }
        }
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .started(packets: 32, group: [0x10, 0x11, 0x12, 0x13]))
        await t.close()
    }

    func testALaggingVideoConsumerLosesOldestPacketsAndTheyAreCounted() async throws {
        let ch = FakeChannels()
        var tuning = fastTuning
        tuning.videoBufferLimit = 8
        let t = make(ch, tuning: tuning)
        try await t.open()
        try await t.activate(activation)
        for s: UInt32 in 0x10...0x13 {
            let e = try videoSender(s)
            for _ in 0..<8 { ch.video.deliver(try e.encrypt(Data([1]), pt: 100)) }
        }
        _ = await t.burstOutcome()
        let s = await t.stats
        XCTAssertEqual(s.videoStreamDrops, 32 - 8)
        await t.close()
    }

    func testCloseCancelsChannelsAndFinishesStreams() async throws {
        let ch = FakeChannels()
        let t = make(ch)
        try await t.open()
        await t.close()
        XCTAssertTrue(ch.video.cancelled)
        XCTAssertTrue(ch.audio.cancelled)
        var it = t.video.makeAsyncIterator()
        let none = await it.next()
        XCTAssertNil(none)
        let outcome = await t.burstOutcome()
        XCTAssertEqual(outcome, .starved(packets: 0))
    }
}

final class SSRCGroupTrackerTests: XCTestCase {
    private let t0 = ContinuousClock.now

    func testNoAdoptionWhileActiveGroupIsPublishing() {
        var tr = SSRCGroupTracker(stall: .seconds(2))
        tr.lock([1, 2, 3, 4])
        tr.notePublish(at: t0)
        let counts: [UInt32: Int] = [1: 50, 2: 50, 3: 50, 4: 50, 10: 9, 11: 9, 12: 9, 13: 9]
        XCTAssertNil(tr.noteUnknown(10, counts: counts, now: t0 + .seconds(1)))
        XCTAssertEqual(tr.noteUnknown(10, counts: counts, now: t0 + .seconds(3)), [10, 11, 12, 13])
        XCTAssertEqual(tr.active, [10, 11, 12, 13])
        XCTAssertEqual(tr.blacklist, [1, 2, 3, 4])
    }

    func testNeedsThresholdAndAConsecutiveRunAndSkipsBlacklisted() {
        var tr = SSRCGroupTracker(threshold: 5)
        // No active group: adoption allowed immediately.
        XCTAssertNil(tr.noteUnknown(10, counts: [10: 5, 11: 5, 12: 5, 13: 4], now: t0), "below threshold")
        XCTAssertNil(tr.noteUnknown(10, counts: [10: 5, 11: 5, 13: 5, 14: 5], now: t0), "not consecutive")
        // Two interleaved groups: the first complete run wins, never a mix.
        XCTAssertEqual(tr.noteUnknown(20, counts: [20: 9, 21: 9, 22: 9, 23: 9, 24: 9, 40: 9], now: t0), [20, 21, 22, 23])
        // The abandoned group is never re-adopted.
        let back = tr.noteUnknown(30, counts: [30: 9, 31: 9, 32: 9, 33: 9, 20: 99, 21: 99, 22: 99, 23: 99],
                                  now: t0 + .seconds(10))
        XCTAssertEqual(back, [30, 31, 32, 33])
        XCTAssertNil(tr.noteUnknown(20, counts: [20: 99, 21: 99, 22: 99, 23: 99], now: t0 + .seconds(20)))
    }

    func testAdoptionStartsAGraceWindow() {
        var tr = SSRCGroupTracker(stall: .seconds(2))
        XCTAssertNotNil(tr.noteUnknown(1, counts: [1: 5, 2: 5, 3: 5, 4: 5], now: t0))
        XCTAssertNil(tr.noteUnknown(9, counts: [9: 5, 10: 5, 11: 5, 12: 5], now: t0 + .seconds(1)))
    }
}
