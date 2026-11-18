import CoreVideo
import XCTest
@testable import Screener

/// A ByteStream over a MemoryPipe end that a test can break the way a real
/// TCP connection breaks (reads fail with an errno), and whose graceful close
/// (`closeAndWait`) takes a set time and records what had happened by then.
final class ScriptedStream: ByteStream, @unchecked Sendable {
    let inner: ByteStream
    private let lock = NSLock()
    private var injected: Error?
    private var _readStarted = false
    private var _closeConfirmed = false
    /// How long `closeAndWait` takes to "see" `.cancelled`.
    var closeDelay: Duration = .zero
    /// Runs right before `closeAndWait` confirms the close.
    var beforeCloseConfirmed: (@Sendable () -> Void)?

    init(_ inner: ByteStream) { self.inner = inner }

    var readStarted: Bool { lock.lock(); defer { lock.unlock() }; return _readStarted }
    private func markRead() { lock.lock(); _readStarted = true; lock.unlock() }
    private func markConfirmed() { lock.lock(); _closeConfirmed = true; lock.unlock() }
    var closeConfirmed: Bool { lock.lock(); defer { lock.unlock() }; return _closeConfirmed }

    /// Every pending and later read / write fails with `error`.
    func inject(_ error: Error) {
        lock.lock(); injected = error; lock.unlock()
        inner.close()
    }

    private func mapped(_ error: Error) -> Error {
        lock.lock(); defer { lock.unlock() }; return injected ?? error
    }

    func read(exactly count: Int) async throws -> Data {
        markRead()
        do { return try await inner.read(exactly: count) } catch { throw mapped(error) }
    }

    func readSome() async throws -> Data {
        markRead()
        do { return try await inner.readSome() } catch { throw mapped(error) }
    }

    func write(_ data: Data) async throws {
        do { try await inner.write(data) } catch { throw mapped(error) }
    }

    func close() { inner.close() }

    func closeAndWait(timeout: Duration) async -> Bool {
        inner.close()
        if closeDelay > .zero { try? await Task.sleep(for: min(closeDelay, timeout)) }
        beforeCloseConfirmed?()
        markConfirmed()
        return true
    }
}

/// SessionCoordinator driven all the way to `.connected`: every TCP connect
/// gets a fresh scripted fake server (ControlSessionTests.FakeServer, reference
/// order), and the test delivers an SRTP start burst on the fake video channel
/// with the keys that session negotiated. No network.
@MainActor
final class SessionCoordinatorConnectedTests: XCTestCase {
    nonisolated static let wrapKey = Data(hex: "000102030405060708090a0b0c0d0e0f")   // = ControlSessionTests.wrapKey

    final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _channels: [(MediaTransport.Flow, FakeDatagramChannel)] = []
        private var _streams: [ScriptedStream] = []
        private var _fakes: [ControlSessionTests.FakeServer] = []
        private var _auth = 0
        private var _connectionIndex = 0
        private var _framebufferOnlyFromIndex = Int.max
        private var servers: [Task<Void, Error>] = []
        let answer: Data

        init() throws {
            let fx = try Fixture.load("media_offer")
            answer = Data(hex: fx["answer_msg"] as! String).dropFirst()
        }

        var authCalls: Int { lock.lock(); defer { lock.unlock() }; return _auth }
        /// Connections at/after this 1-based index script a framebufferOnly
        /// connect (no 0x1c offer) instead of the usual HP offer/answer:
        /// fallback tests use this to script the "reconnect without a media
        /// offer" leg. Default: never (every connection is a normal HP offer).
        var framebufferOnlyFromIndex: Int {
            get { lock.lock(); defer { lock.unlock() }; return _framebufferOnlyFromIndex }
            set { lock.lock(); _framebufferOnlyFromIndex = newValue; lock.unlock() }
        }
        var streams: [ScriptedStream] { lock.lock(); defer { lock.unlock() }; return _streams }
        var lastStream: ScriptedStream? { streams.last }
        var channels: [FakeDatagramChannel] { lock.lock(); defer { lock.unlock() }; return _channels.map(\.1) }
        var lastVideo: FakeDatagramChannel? {
            lock.lock(); defer { lock.unlock() }; return _channels.last { $0.0 == .video }?.1
        }
        var lastFake: ControlSessionTests.FakeServer? { lock.lock(); defer { lock.unlock() }; return _fakes.last }

        func seams(ip: String) -> SessionCoordinator.Seams {
            var tuning = MediaTransport.Tuning()
            tuning.txInterval = .milliseconds(20)
            tuning.punchInterval = .milliseconds(10)
            tuning.burstMinPackets = 30
            tuning.burstDeadline = .seconds(2)
            tuning.burstSettle = .milliseconds(20)
            tuning.burstStarvedBelow = 20
            tuning.adoptStall = .milliseconds(100)
            tuning.keyframeMinInterval = .milliseconds(50)
            var s = SessionCoordinator.Seams(
                resolveIPv4: { _ in ip },
                controlSeams: { _ in
                    ControlSession.Seams(
                        connect: { [self] _, _ in self.newConnection() },
                        authenticate: { [self] _, _, _, connect in
                            self.noteAuth()
                            let s = try await connect()
                            return (s, AuthResult(wrapKey: SessionCoordinatorConnectedTests.wrapKey,
                                                  method: .srp, serverRSAPublicKeyDER: nil))
                        })
                },
                channelFactory: { [self] flow, _ in self.newChannel(flow) })
            s.controlTuning = .fast
            s.mediaTuning = tuning
            return s
        }

        private func noteAuth() { lock.lock(); _auth += 1; lock.unlock() }

        private func newChannel(_ flow: MediaTransport.Flow) -> FakeDatagramChannel {
            let c = FakeDatagramChannel()
            lock.lock(); _channels.append((flow, c)); lock.unlock()
            return c
        }

        private func newConnection() -> ByteStream {
            lock.lock(); _connectionIndex += 1; let idx = _connectionIndex; lock.unlock()
            let framebufferOnly = idx >= framebufferOnlyFromIndex
            let (client, server) = MemoryPipe.pair()
            let fake = ControlSessionTests.FakeServer(server)
            let answer = answer
            let task = Task {
                try await fake.handshakeAndServerInit()
                _ = try await server.read(exactly: 78)
                try await fake.sendRekeyWithEncryptedTail()
                _ = try await fake.readPlainSetDisplayConfiguration()
                _ = try await fake.readPlainSetEncodings()
                _ = try await server.read(exactly: 8)
                if framebufferOnly {
                    // No 0x1c: session.start() returns at once; the client's
                    // SetPixelFormat / framebuffer SetEncodings / first FBUR
                    // only arrive once the coordinator calls enterFramebufferMode.
                    while true { _ = try await fake.readRecord() }   // drain until closed
                } else {
                    for _ in 0..<3 { _ = try await fake.readRecord() }
                    try await fake.sendAnswer(answer)
                    while true { _ = try await fake.readRecord() }   // drain until closed
                }
            }
            let stream = ScriptedStream(client)
            lock.lock(); servers.append(task); _streams.append(stream); _fakes.append(fake); lock.unlock()
            return stream
        }

        /// Sends an AppleDisplayLayout (0x451) FBU rect with the given scaled
        /// (logical) / backing sizes (DisplayLayout.init's field layout: a
        /// leading reserved u16, then scaledWidth/Height, backingWidth/Height,
        /// then a trailing unused u16 — no displays, short payload).
        func sendDisplayLayout(scaledWidth: UInt16, scaledHeight: UInt16,
                               backingWidth: UInt16, backingHeight: UInt16) async throws {
            let fake = try XCTUnwrap(lastFake)
            var w = ByteWriter()
            w.u8(0); w.u8(0); w.u16(1)
            w.zeros(8); w.u32(0x451)
            w.u16(12)
            w.u16(0); w.u16(scaledWidth); w.u16(scaledHeight); w.u16(backingWidth); w.u16(backingHeight); w.u16(0)
            try await fake.sendRecord(w.data)
        }

        /// A 4-tile start burst (40 packets) under the session's server video key.
        func deliverBurst(_ keys: NegotiationKeys) throws {
            let video = try XCTUnwrap(lastVideo)
            let encs = try (0..<4).map { try SRTPEncryptor(blob: keys.videoKeyS, ssrc: 0x1000 + UInt32($0), seq: 100) }
            for i in 0..<10 {
                for j in 0..<4 {
                    // HEVC TRAIL_R slices (no parameter sets: nothing decodes).
                    video.deliver(try encs[j].encrypt(Data([0x02, 0x01, UInt8(i), UInt8(j)]), pt: 100, marker: i == 9))
                }
            }
        }
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !cond(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
        if !cond() { throw CancellationError() }
    }

    private func isConnected(_ c: SessionCoordinator) -> Bool {
        if case .connected = c.state { return true }
        return false
    }

    /// Waits for a new session's handshake (after `previous`), then starts its stream.
    private func bringUp(_ c: SessionCoordinator, _ h: Harness, after previous: ControlSession?) async throws {
        try await waitUntil("handshake") { c.mediaParams != nil && c.control != nil && c.control !== previous }
        try h.deliverBurst(try XCTUnwrap(c.mediaParams?.keys))
        try await waitUntil("connected") { isConnected(c) }
    }

    private func policy(firstFrameAfter: Duration = .seconds(60), deadline: Duration = .seconds(120)) -> SessionCoordinator.Policy {
        var p = SessionCoordinator.Policy()
        p.firstFrameKeyframeAfter = firstFrameAfter
        p.firstFrameDeadline = deadline
        return p
    }

    private func connected(_ ip: String, policy: SessionCoordinator.Policy? = nil) async throws
        -> (SessionCoordinator, Harness, Task<Void, Never>) {
        let h = try Harness()
        let c = SessionCoordinator(policy: policy ?? self.policy(), seams: h.seams(ip: ip))
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }
        try await bringUp(c, h, after: nil)
        return (c, h, t)
    }

    // MARK: auto-reconnect

    /// A lost connection (ECONNABORTED) while connected in the foreground is
    /// reconnected; the 4th loss in a row shows the error instead.
    func testForegroundLossReconnectsThreeTimesThenShowsTheError() async throws {
        let (c, h, t) = try await connected("192.0.2.110")
        await t.value
        for attempt in 1...LifecyclePolicy.maxAutoReconnects {
            let previous = c.control
            h.lastStream?.inject(TransportError.posix(ECONNABORTED))
            try await bringUp(c, h, after: previous)
            XCTAssertEqual(h.authCalls, attempt + 1)
            XCTAssertTrue(c.isSessionActive)
        }
        h.lastStream?.inject(TransportError.posix(ECONNABORTED))
        try await waitUntil("failed") { c.state == .failed(UserFacingError.lostMessage) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.authCalls, LifecyclePolicy.maxAutoReconnects + 1, "no 4th reconnect")
        XCTAssertFalse(c.isReconnecting)
        XCTAssertNil(c.lastRequest, "credentials dropped once nothing will reconnect")
        XCTAssertTrue(h.channels.allSatisfy(\.cancelled))
    }

    /// ECONNRESET on the control channel while connected: probably the Mac's
    /// user clicked Stop. Not reconnected; "The Mac ended the session."
    func testAResetControlChannelIsNotReconnected() async throws {
        let (c, h, t) = try await connected("192.0.2.111")
        await t.value
        h.lastStream?.inject(TransportError.posix(ECONNRESET))
        try await waitUntil("failed") { c.state == .failed(UserFacingError.peerEndedMessage) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(h.authCalls, 1)
        XCTAssertNil(c.lastRequest)
        XCTAssertNil(c.control)
    }

    // MARK: first-frame deadline

    /// Connected but nothing decodes: a keyframe is requested at the first
    /// mark, the session fails at the deadline (never "Connecting…" forever).
    func testNoPictureAfterConnectingRequestsAKeyframeThenFails() async throws {
        let (c, _, t) = try await connected("192.0.2.112",
                                            policy: policy(firstFrameAfter: .milliseconds(150), deadline: .milliseconds(500)))
        await t.value
        XCTAssertTrue(c.isSessionActive)
        try await waitUntil("failed") { c.state == .failed(SessionCoordinator.noPictureMessage) }
        XCTAssertFalse(c.isSessionActive)
        XCTAssertNil(c.media)
        // The final stats are read during the (async) teardown.
        try await waitUntil("keyframe request in the final stats") { (c.mediaStats?.keyframeRequestsSent ?? 0) >= 1 }
    }

    func testAFirstPictureCancelsTheDeadline() async throws {
        let (c, _, t) = try await connected("192.0.2.113",
                                            policy: policy(firstFrameAfter: .milliseconds(100), deadline: .milliseconds(250)))
        await t.value
        c.frames.onFirstFrame?(try makePixelBuffer())
        try await waitUntil("first frame") { c.hasFirstFrame }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(isConnected(c), "\(c.state)")
        await c.disconnect()
    }

    /// The deadline restarts for a reconnected session.
    func testTheDeadlineAppliesAfterAReconnectToo() async throws {
        let (c, h, t) = try await connected("192.0.2.114",
                                            policy: policy(firstFrameAfter: .milliseconds(100), deadline: .milliseconds(400)))
        await t.value
        c.frames.onFirstFrame?(try makePixelBuffer())
        try await waitUntil("first frame") { c.hasFirstFrame }
        let previous = c.control
        h.lastStream?.inject(TransportError.posix(ECONNABORTED))
        try await bringUp(c, h, after: previous)
        XCTAssertFalse(c.hasFirstFrame)
        XCTAssertTrue(c.isReconnecting)
        try await waitUntil("failed") { c.state == .failed(SessionCoordinator.noPictureMessage) }
        XCTAssertFalse(c.isReconnecting)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return try XCTUnwrap(pb)
    }

    // MARK: teardown releases input first

    /// A disconnect calls `releaseInput` (the session view's
    /// RemoteInputView.releaseAll(), here a fake) before `input` is torn
    /// down, and gives whatever was already queued (the releases it just
    /// sent) a bounded chance to actually reach the control channel: a
    /// message enqueued right before `disconnect()` must still be sent, not
    /// silently dropped by `input.close()`.
    func testDisconnectReleasesInputBeforeClosingTheControlChannel() async throws {
        let (c, h, t) = try await connected("192.0.2.210")
        await t.value
        let input = try XCTUnwrap(c.input)
        var released = false
        c.releaseInput = { released = true }
        input.key(down: false, keysym: 0xffe1)   // queued as if releaseAll() had just run
        let before = input.sentCount
        await c.disconnect()
        XCTAssertTrue(released, "releaseInput was not called before teardown")
        XCTAssertEqual(input.sentCount, before + 1,
                       "the queued release must reach the control channel before input is closed")
        XCTAssertNil(c.input)
        _ = h
    }

    // MARK: single canvas source of truth

    /// A 0x451 with a different backing size updates both the frame store's
    /// canvas (video layout / drawCursor's CompositeLayout) and the input
    /// controller's mapping, so they never disagree about the canvas.
    func testDisplayLayoutUpdatesTheFrameStoreCanvasAndInputMappingTogether() async throws {
        let (c, h, t) = try await connected("192.0.2.211")
        await t.value
        let canvasBefore = c.frames.snapshot(ifNewerThan: nil)?.canvas
        XCTAssertEqual(canvasBefore, CGSize(width: 3840, height: 2160))   // the 0x1c answer's canvas
        let input = try XCTUnwrap(c.input)
        XCTAssertEqual(input.serverWidth, 3840)
        XCTAssertEqual(input.serverHeight, 2160)

        try await h.sendDisplayLayout(scaledWidth: 960, scaledHeight: 600, backingWidth: 1920, backingHeight: 1200)
        try await waitUntil("input dims updated") { input.serverWidth == 1920 && input.serverHeight == 1200 }
        try await waitUntil("frame store canvas updated") {
            c.frames.snapshot(ifNewerThan: nil)?.canvas == CGSize(width: 1920, height: 1200)
        }
        XCTAssertEqual(c.frames.snapshot(ifNewerThan: nil)?.canvas, CGSize(width: input.serverWidth, height: input.serverHeight))
        await c.disconnect()
    }
}
