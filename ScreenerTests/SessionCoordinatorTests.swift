import CoreVideo
import XCTest
@testable import Screener

/// SessionCoordinator lifecycle with injected seams: no network. The control
/// handshake parks in `authenticate` until cancelled; media uses fake channels.
@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _auth = 0
        private var _channels: [FakeDatagramChannel] = []
        var failAudioBind = false

        func noteAuth() { lock.lock(); _auth += 1; lock.unlock() }
        var authCalls: Int { lock.lock(); defer { lock.unlock() }; return _auth }
        func make(_ flow: MediaTransport.Flow) -> FakeDatagramChannel {
            let c = FakeDatagramChannel()
            lock.lock()
            if flow == .audio, failAudioBind { c.startError = DatagramChannelError.bind(port: 5900, errno: EADDRINUSE) }
            _channels.append(c)
            lock.unlock()
            return c
        }
        var channels: [FakeDatagramChannel] { lock.lock(); defer { lock.unlock() }; return _channels }
    }

    private func seams(_ rec: Recorder, resolve: [String: String] = [:]) -> SessionCoordinator.Seams {
        SessionCoordinator.Seams(
            resolveIPv4: { host in
                if let ip = resolve[host] { return ip }
                return try IPv4Resolver.resolveBlocking(host)
            },
            controlSeams: { _ in
                ControlSession.Seams(
                    connect: { _, _ in throw TransportError.closed },
                    authenticate: { _, _, _, _ in
                        rec.noteAuth()
                        try await Task.sleep(for: .seconds(60))   // parked until cancelled
                        throw TransportError.closed
                    })
            },
            channelFactory: { flow, _ in rec.make(flow) })
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
        for _ in 0..<600 where !cond() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func connect(_ c: SessionCoordinator, _ host: String) -> Task<Void, Never> {
        Task { await c.connect(host: host, port: 5900, username: "u", password: "p") }
    }

    func testDisconnectDuringConnectLeavesNoSessionAndALateResultCannotOverwriteTheNextOne() async throws {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.10"]))
        let first = connect(c, "mac")
        try await waitUntil("first handshake") { rec.authCalls == 1 }
        XCTAssertEqual(c.state, .connecting)
        XCTAssertEqual(c.serverAddress, "192.0.2.10")
        XCTAssertNotNil(c.control)

        await c.disconnect()
        XCTAssertEqual(c.state, .idle)
        XCTAssertNil(c.control)
        XCTAssertNil(c.media)
        XCTAssertNil(c.serverAddress)
        XCTAssertEqual(rec.channels.count, 2)
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled), "first session's UDP must be closed")

        // A new connect; the first one's unwinding must not touch it.
        let second = connect(c, "mac")
        try await waitUntil("second handshake") { rec.authCalls == 2 }
        let secondControl = c.control
        await first.value
        XCTAssertEqual(c.state, .connecting)
        XCTAssertNotNil(secondControl)
        XCTAssertTrue(c.control === secondControl)
        XCTAssertEqual(rec.channels.count, 4)
        XCTAssertFalse(rec.channels[2].cancelled)

        await c.disconnect()
        await second.value
        XCTAssertEqual(c.state, .idle)
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled))
    }

    /// Disconnect while the host is still resolving: the late resolution
    /// must not register the server, bind media or start a handshake.
    func testDisconnectDuringResolutionDropsTheLateResult() async throws {
        let rec = Recorder()
        let gate = AsyncStream<Void>.makeStream()
        var s = seams(rec)
        s.resolveIPv4 = { _ in
            for await _ in gate.stream { break }    // ignores cancellation on purpose
            return "192.0.2.60"
        }
        let c = SessionCoordinator(seams: s)
        let t = connect(c, "slow")
        try await Task.sleep(for: .milliseconds(20))
        await c.disconnect()
        gate.continuation.yield()
        await t.value
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(c.state, .idle)
        XCTAssertNil(c.media)
        XCTAssertNil(c.serverAddress)
        XCTAssertTrue(rec.channels.isEmpty)
        XCTAssertEqual(rec.authCalls, 0)
        // 192.0.2.60 was never registered: a session to it is allowed.
        let other = SessionCoordinator(seams: seams(rec, resolve: ["x": "192.0.2.60"]))
        let t2 = connect(other, "x")
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        await other.disconnect()
        await t2.value
    }

    func testASecondSessionToTheSameServerIsRefused() async throws {
        let rec = Recorder()
        let a = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.20"]))
        let b = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.20"]))
        let ta = connect(a, "mac")
        try await waitUntil("a handshaking") { rec.authCalls == 1 }

        await b.connect(host: "192.0.2.20", port: 5900, username: "u", password: "p")
        XCTAssertEqual(b.state, .failed("Already connected to 192.0.2.20. Disconnect that session first."))
        XCTAssertNil(b.media)
        XCTAssertEqual(rec.channels.count, 2, "the refused session must not bind")

        // Once `a` is gone the server is free again.
        await a.disconnect()
        await ta.value
        let tb = connect(b, "mac")
        try await waitUntil("b handshaking") { rec.authCalls == 2 }
        await b.disconnect()
        await tb.value
    }

    func testBindFailureFailsImmediatelyWithAReadableMessage() async throws {
        let rec = Recorder()
        rec.failAudioBind = true
        let c = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.30"]))
        await c.connect(host: "mac", port: 5900, username: "u", password: "p")
        XCTAssertEqual(c.state, .failed("UDP ports 5900/5901 unavailable (another Screen Sharing session?)"))
        XCTAssertEqual(rec.authCalls, 0, "no handshake without media ports")
        XCTAssertNil(c.media)
        XCTAssertTrue(rec.channels[0].cancelled)
        // The server registration was released.
        rec.failAudioBind = false
        let t = connect(c, "mac")
        try await waitUntil("retry handshaking") { rec.authCalls == 1 }
        await c.disconnect()
        await t.value
    }

    func testMediaConsumersAreAttachedBeforeTheSocketsBind() async throws {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.40"]))
        var channelsAtAttach: Int?
        c.addMediaConsumer { _ in channelsAtAttach = rec.channels.count }
        let t = connect(c, "mac")
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        XCTAssertEqual(channelsAtAttach, 0)
        await c.disconnect()
        await t.value
    }

    func testAMediaChannelFailureFailsTheSession() async throws {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.50"]))
        let t = connect(c, "mac")
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        rec.channels[0].fail("receive: Network is down (50)")
        await t.value
        XCTAssertEqual(c.state, .failed(UserFacingError.lostMessage))
        XCTAssertNil(c.lastRequest, "credentials dropped: nothing will reconnect")
        XCTAssertNil(c.control)
        // The failure's teardown runs on the media-failure task, not `t`: wait for its close.
        try await waitUntil("sockets closed") { rec.channels.allSatisfy(\.cancelled) }
    }

    /// The handshake fails while the UDP sends are still blocked (iOS Local
    /// Network privacy): the user sees the Settings hint, not the TCP error.
    func testAHandshakeFailureWhileUDPIsBlockedShowsTheLocalNetworkHint() async {
        let rec = Recorder()
        var s = seams(rec, resolve: ["mac": "192.0.2.70"])
        s.channelFactory = { flow, _ in let c = rec.make(flow); c.blocked = EPERM; return c }
        s.controlSeams = { _ in
            ControlSession.Seams(connect: { _, _ in throw TransportError.closed },
                                 authenticate: { _, _, _, _ in throw TransportError.timeout })
        }
        let c = SessionCoordinator(seams: s)
        await c.connect(host: "mac", port: 5900, username: "u", password: "p")
        XCTAssertEqual(c.state, .failed(MediaTransportError.localNetworkMessage))
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled))
    }

    /// Backgrounding mid-connect closes everything; activation reconnects
    /// with the same request and the session view stays up ("Reconnecting…").
    func testBackgroundSuspendsAndActiveReconnects() async throws {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.80"]))
        let t = connect(c, "mac")
        try await waitUntil("handshaking") { rec.authCalls == 1 }

        await c.enterBackground()
        await t.value
        XCTAssertEqual(c.state, .suspended)
        XCTAssertTrue(c.isSessionActive, "the session view stays up")
        XCTAssertTrue(c.isReconnecting)
        XCTAssertNil(c.control)
        XCTAssertNil(c.media)
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled), "sockets closed in the background")

        let resumed = Task { await c.becomeActive() }
        try await waitUntil("reconnect handshake") { rec.authCalls == 2 }
        XCTAssertEqual(c.state, .connecting)
        XCTAssertTrue(c.isSessionActive)
        XCTAssertTrue(c.isReconnecting)
        XCTAssertEqual(c.lastRequest?.host, "mac")

        await c.disconnect()
        await resumed.value
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.isReconnecting)
        XCTAssertNil(c.lastRequest, "credentials dropped on a user disconnect")
    }

    /// UDP sends blocked by a routing error (not a privacy denial): the
    /// handshake failure says the Mac can't be reached, not "Local Network".
    func testAHandshakeFailureWhileUDPHasNoRouteSaysTheMacCantBeReached() async {
        let rec = Recorder()
        var s = seams(rec, resolve: ["mac": "192.0.2.71"])
        s.channelFactory = { flow, _ in let c = rec.make(flow); c.blocked = EHOSTUNREACH; return c }
        s.controlSeams = { _ in
            ControlSession.Seams(connect: { _, _ in throw TransportError.closed },
                                 authenticate: { _, _, _, _ in throw TransportError.timeout })
        }
        let c = SessionCoordinator(seams: s)
        await c.connect(host: "mac", port: 5900, username: "u", password: "p")
        XCTAssertEqual(c.state, .failed(UserFacingError.noRouteMessage))
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled))
    }

    /// H1: the saved host's pin and legacy permission reach the
    /// authenticator, and a key mismatch surfaces as `identityChange` (for
    /// the "This Mac's identity changed" prompt), not a generic failure.
    func testPinReachesAuthAndMismatchSetsIdentityChange() async {
        let rec = Recorder()
        var s = seams(rec, resolve: ["mac": "192.0.2.73"])
        let seen = LockedValue<AuthPolicy?>(nil)
        let presented = Data(repeating: 0xEE, count: 32)
        s.controlSeams = { _ in
            ControlSession.Seams(connect: { _, _ in throw TransportError.closed },
                                 authenticate: { _, _, policy, _ in
                                     seen.value = policy
                                     throw AuthError.serverKeyMismatch(presentedSHA256: presented)
                                 })
        }
        let c = SessionCoordinator(seams: s)
        let policy = AuthPolicy(pinnedKeySHA256: Data(repeating: 1, count: 32), allowLegacy: true)
        await c.connect(host: "mac", port: 5900, username: "u", password: "p", authPolicy: policy)
        XCTAssertEqual(seen.value, policy)
        XCTAssertEqual(c.identityChange, .init(host: "mac", presentedSHA256: presented))
        XCTAssertEqual(c.state, .failed(ControlSession.identityChangedMessage))
        c.clearIdentityChange()
        XCTAssertNil(c.identityChange)
    }

    func testLegacyRequestedIsFlaggedForTheConnectSheet() async {
        let rec = Recorder()
        var s = seams(rec, resolve: ["mac": "192.0.2.74"])
        s.controlSeams = { _ in
            ControlSession.Seams(connect: { _, _ in throw TransportError.closed },
                                 authenticate: { _, _, _, _ in throw AuthError.legacyAuthRequired })
        }
        let c = SessionCoordinator(seams: s)
        await c.connect(host: "mac", port: 5900, username: "u", password: "p")
        XCTAssertTrue(c.legacyAuthRequested)
        XCTAssertEqual(c.state, .failed(ControlSession.legacyAuthRequiredMessage))
    }

    /// The TCP connect timed out (no SYN-ACK): "Can't reach this Mac".
    func testATCPConnectTimeoutSaysTheMacCantBeReached() async {
        let rec = Recorder()
        var s = seams(rec, resolve: ["mac": "192.0.2.72"])
        s.controlSeams = { _ in
            ControlSession.Seams(connect: { _, _ in throw ControlSessionError.timeout(step: "connect") },
                                 authenticate: { _, _, _, connect in _ = try await connect(); throw TransportError.closed })
        }
        let c = SessionCoordinator(seams: s)
        await c.connect(host: "mac", port: 5900, username: "u", password: "p")
        XCTAssertEqual(c.state, .failed(UserFacingError.noRouteMessage))
        XCTAssertNil(c.lastRequest)
    }

    /// Backgrounding closes TCP first and waits for its close to go out
    /// (NWConnection `.cancelled`) before the media sockets close and
    /// `enterBackground` (which the UIApplication background task awaits) returns.
    func testBackgroundAwaitsTheTCPCloseBeforeClosingMedia() async throws {
        let rec = Recorder()
        let (client, server) = MemoryPipe.pair()   // `server` kept alive: the client end writes ClientInit
        let stream = ScriptedStream(client)
        stream.closeDelay = .milliseconds(150)
        let mediaClosedAtTCPClose = LockedValue<Bool?>(nil)
        stream.beforeCloseConfirmed = { mediaClosedAtTCPClose.value = rec.channels.contains(where: \.cancelled) }
        var s = seams(rec, resolve: ["mac": "192.0.2.81"])
        s.controlSeams = { _ in
            ControlSession.Seams(
                connect: { _, _ in throw TransportError.closed },
                authenticate: { _, _, _, _ in
                    rec.noteAuth()
                    return (stream, AuthResult(wrapKey: Data(count: 16), method: .srp, serverRSAPublicKeyDER: nil))
                })
        }
        let c = SessionCoordinator(seams: s)
        let t = connect(c, "mac")
        try await waitUntil("server init read") { stream.readStarted }   // the stream is adopted

        let started = ContinuousClock.now
        await c.enterBackground()
        let elapsed = ContinuousClock.now - started
        XCTAssertTrue(stream.closeConfirmed, "the TCP close was awaited")
        XCTAssertEqual(mediaClosedAtTCPClose.value, false, "TCP closes before media")
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled), "media closed before enterBackground returns")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(140))
        XCTAssertEqual(c.state, .suspended)
        await c.disconnect()
        await t.value
        withExtendedLifetime(server) {}
    }

    /// A first picture decoded for a session that has since been closed must
    /// not clear "Reconnecting…" (or count as the next session's picture).
    func testALateFirstFrameOfAClosedSessionIsIgnored() async throws {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.82"]))
        let t = connect(c, "mac")
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        c.frames.onFirstFrame?(try XCTUnwrap(pb))   // its main-actor hop runs after the suspend below
        await c.enterBackground()
        await t.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(c.isReconnecting)
        XCTAssertFalse(c.hasFirstFrame)
        await c.disconnect()
    }

    /// The user disconnects while the session is suspended in the
    /// background: coming back does not reconnect.
    func testNoReconnectAfterAUserDisconnect() async throws {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec, resolve: ["mac": "192.0.2.83"]))
        let t = connect(c, "mac")
        try await waitUntil("handshaking") { rec.authCalls == 1 }
        await c.enterBackground()
        await t.value
        XCTAssertEqual(c.state, .suspended)
        await c.disconnect()
        await c.becomeActive()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(rec.authCalls, 1, "no reconnect")
        XCTAssertNil(c.lastRequest)
        XCTAssertFalse(c.isSessionActive)
    }

    func testBackgroundWithoutASessionDoesNothing() async {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec))
        await c.enterBackground()
        await c.becomeActive()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(rec.authCalls, 0)
    }

    /// TCP refused: the friendly text, not "Connection failed: ...".
    func testARefusedConnectionShowsFriendlyText() async {
        let rec = Recorder()
        var s = seams(rec, resolve: ["mac": "192.0.2.90"])
        s.controlSeams = { _ in
            ControlSession.Seams(connect: { _, _ in throw TransportError.posix(ECONNREFUSED) },
                                 authenticate: { _, _, _, connect in _ = try await connect(); throw TransportError.closed })
        }
        let c = SessionCoordinator(seams: s)
        await c.connect(host: "mac", port: 5900, username: "u", password: "p")
        XCTAssertEqual(c.state, .failed(UserFacingError.unreachableMessage))
    }

    func testAHostWithoutIPv4FailsClearly() async {
        let rec = Recorder()
        let c = SessionCoordinator(seams: seams(rec))
        await c.connect(host: "::1", port: 5900, username: "u", password: "p")
        guard case .failed(let msg) = c.state else { return XCTFail("state \(c.state)") }
        XCTAssertTrue(msg.hasPrefix("This Mac has no IPv4 address on this network"), msg)
        XCTAssertTrue(rec.channels.isEmpty)
    }
}
