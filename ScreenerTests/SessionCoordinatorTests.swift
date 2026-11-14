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
                    authenticate: { _, _, _ in
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
        XCTAssertEqual(c.state, .failed("Media connection lost (receive: Network is down (50))"))
        XCTAssertNil(c.control)
        XCTAssertTrue(rec.channels.allSatisfy(\.cancelled))
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
