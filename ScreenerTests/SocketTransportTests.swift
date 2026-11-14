import Network
import XCTest
@testable import Screener

final class SocketTransportTests: XCTestCase {
    private final class Inbox: @unchecked Sendable {
        let lock = NSLock()
        var items: [Data] = []
        var events: [String] = []
        func add(_ d: Data) { lock.lock(); items.append(d); lock.unlock() }
        func event(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return items }
        var eventSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func waitFor(_ cond: () -> Bool) async throws {
        for _ in 0..<300 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Two channels bound to fixed loopback ports and connected to each other:
    /// the local port is the one we asked for, and datagrams flow both ways.
    func testUDPChannelBindsTheRequestedPortAndExchangesDatagrams() async throws {
        let pa: UInt16 = 47_901, pb: UInt16 = 47_902
        let a = SocketDatagramChannel(label: "a", remoteHost: "127.0.0.1", remotePort: pb, localHost: "127.0.0.1", localPort: pa)
        let b = SocketDatagramChannel(label: "b", remoteHost: "127.0.0.1", remotePort: pa, localHost: "127.0.0.1", localPort: pb)
        let ia = Inbox(), ib = Inbox()
        try a.start(onReceive: ia.add, onEvent: ia.event, onFailure: ia.event)
        try b.start(onReceive: ib.add, onEvent: ib.event, onFailure: ib.event)
        XCTAssertEqual(ia.eventSnapshot.first, "bound local=127.0.0.1:47901 remote=127.0.0.1:47902")
        let rcv = try XCTUnwrap(ia.eventSnapshot.first { $0.hasPrefix("rcvbuf ") })
        XCTAssertTrue(rcv.hasPrefix("rcvbuf requested=4194304 accepted="), rcv)
        XCTAssertFalse(rcv.hasSuffix("effective=0"), rcv)
        a.send(Data([1, 2, 3]))
        b.send(Data([9]))
        try await waitFor { ib.snapshot.count == 1 && ia.snapshot.count == 1 }
        XCTAssertEqual(ib.snapshot, [Data([1, 2, 3])])
        XCTAssertEqual(ia.snapshot, [Data([9])])
        await a.cancel(); await b.cancel()
        a.send(Data([7]))   // after cancel: a no-op, not a crash
    }

    /// A plain socket bound to `port` without SO_REUSEPORT (or -1 + errno).
    private func exclusiveBind(_ port: UInt16, reusePort: Bool = false) -> Int32 {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if reusePort { var one: Int32 = 1; setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, 4) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 { Darwin.close(s); return -1 }
        return s
    }

    func testBindFailureThrows() throws {
        let port: UInt16 = 47_921
        let blocker = exclusiveBind(port)
        XCTAssertGreaterThanOrEqual(blocker, 0)
        defer { Darwin.close(blocker) }
        let c = SocketDatagramChannel(label: "x", remoteHost: "127.0.0.1", remotePort: 47_922, localHost: "127.0.0.1", localPort: port)
        let inbox = Inbox()
        XCTAssertThrowsError(try c.start(onReceive: inbox.add, onEvent: inbox.event, onFailure: inbox.event)) { e in
            XCTAssertEqual(e as? DatagramChannelError, .bind(port: port, errno: EADDRINUSE))
        }
    }

    func testMediaTransportOpenThrowsWhenTheAudioPortIsTaken() async throws {
        let port: UInt16 = 47_930     // audio = P, video = P+1
        let blocker = exclusiveBind(port)
        XCTAssertGreaterThanOrEqual(blocker, 0)
        defer { Darwin.close(blocker) }
        let t = MediaTransport(config: .init(host: "127.0.0.1", controlPort: port, localAddress: "127.0.0.1"))
        do {
            try await t.open()
            XCTFail("expected open to throw")
        } catch let e as MediaTransportError {
            guard case .bindFailed(port, port + 1, _) = e else { return XCTFail("got \(e)") }
        }
        // The video socket bound first and must be closed again: an exclusive
        // bind of P+1 now succeeds.
        let again = exclusiveBind(port + 1)
        XCTAssertGreaterThanOrEqual(again, 0, "video port still held after a failed open")
        if again >= 0 { Darwin.close(again) }
    }

    /// SO_REUSEPORT: a second channel binds the same local port; because both
    /// are connected, each receives only its own peer's datagrams.
    func testReusePortAllowsASecondBindAndConnectedSocketsStayIsolated() async throws {
        let shared: UInt16 = 47_940, r1: UInt16 = 47_941, r2: UInt16 = 47_942
        let a = SocketDatagramChannel(label: "a", remoteHost: "127.0.0.1", remotePort: r1, localHost: "127.0.0.1", localPort: shared)
        let b = SocketDatagramChannel(label: "b", remoteHost: "127.0.0.1", remotePort: r2, localHost: "127.0.0.1", localPort: shared)
        let p1 = SocketDatagramChannel(label: "p1", remoteHost: "127.0.0.1", remotePort: shared, localHost: "127.0.0.1", localPort: r1)
        let p2 = SocketDatagramChannel(label: "p2", remoteHost: "127.0.0.1", remotePort: shared, localHost: "127.0.0.1", localPort: r2)
        // An unconnected SO_REUSEPORT socket on the port: what another
        // session looks like between its bind() and connect(). Darwin lets
        // connected sockets share a port anyway; this one needs SO_REUSEPORT.
        let holder = exclusiveBind(shared, reusePort: true)
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { Darwin.close(holder) }
        let ia = Inbox(), ib = Inbox(), sink = Inbox()
        try a.start(onReceive: ia.add, onEvent: ia.event, onFailure: ia.event)
        try b.start(onReceive: ib.add, onEvent: ib.event, onFailure: ib.event)
        try p1.start(onReceive: sink.add, onEvent: sink.event, onFailure: sink.event)
        try p2.start(onReceive: sink.add, onEvent: sink.event, onFailure: sink.event)
        for _ in 0..<5 { p1.send(Data([1])); p2.send(Data([2])) }
        try await waitFor { ia.snapshot.count == 5 && ib.snapshot.count == 5 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ia.snapshot, Array(repeating: Data([1]), count: 5))
        XCTAssertEqual(ib.snapshot, Array(repeating: Data([2]), count: 5))
        for c in [a, b, p1, p2] { await c.cancel() }
    }

    /// cancel() returns only once the fd is closed: an exclusive bind of the
    /// same port succeeds immediately afterwards.
    func testCancelReturnsAfterTheSocketIsClosed() async throws {
        let port: UInt16 = 47_950
        for _ in 0..<20 {
            let c = SocketDatagramChannel(label: "c", remoteHost: "127.0.0.1", remotePort: 47_951, localHost: "127.0.0.1", localPort: port)
            let inbox = Inbox()
            try c.start(onReceive: inbox.add, onEvent: inbox.event, onFailure: inbox.event)
            await c.cancel()
            let s = exclusiveBind(port)
            XCTAssertGreaterThanOrEqual(s, 0, "port still bound after cancel()")
            if s >= 0 { Darwin.close(s) } else { return }
        }
    }

    func testFatalErrnoClassification() {
        for e in [ENOTCONN, EBADF, ENETDOWN, EHOSTUNREACH, ENETUNREACH] {
            XCTAssertTrue(SocketDatagramChannel.isFatal(e), "\(e)")
        }
        for e in [EAGAIN, EINTR, ECONNREFUSED, ENOBUFS] {
            XCTAssertFalse(SocketDatagramChannel.isFatal(e), "\(e)")
        }
    }

    /// Cancelling a pinned TCP connect aborts it promptly (no 10 s poll).
    func testPinnedTCPConnectHonoursCancellation() async throws {
        let start = ContinuousClock.now
        let t = Task {
            // TEST-NET-1: SYNs go unanswered (or fail fast without a route).
            try await SocketTCPByteStream.connect(host: "192.0.2.1", port: 5900, localAddress: "0.0.0.0", timeout: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(150))
        t.cancel()
        do {
            _ = try await t.value
            XCTFail("expected the connect to fail")
        } catch {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    // MARK: IPv4 resolution

    func testIPv4ResolverPassesLiteralsThroughAndResolvesLocalhost() async throws {
        let lit = try await IPv4Resolver.resolve("192.0.2.7")
        XCTAssertEqual(lit, "192.0.2.7")
        let local = try await IPv4Resolver.resolve("localhost")
        XCTAssertEqual(local, "127.0.0.1")
    }

    func testIPv4ResolverRejectsIPv6OnlyHosts() async {
        do {
            _ = try await IPv4Resolver.resolve("::1")
            XCTFail("expected noIPv4")
        } catch {
            XCTAssertEqual(error as? IPv4Resolver.Failure, .noIPv4(host: "::1"))
            XCTAssertTrue(error.localizedDescription.hasPrefix("This Mac has no IPv4 address on this network"))
        }
    }

    func testTCPStreamPinsTheSourceAddressAndRoundTrips() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listening")
        let accepted = Inbox()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            if case .hostPort(let h, _) = conn.endpoint { accepted.event("\(h)") }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 100) { data, _, _, _ in
                conn.send(content: (data ?? Data()) + Data([0xFF]), completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port).rawValue

        let s = try await SocketTCPByteStream.connect(host: "127.0.0.1", port: port, localAddress: "127.0.0.1",
                                                      timeout: .seconds(3))
        try await s.write(Data([1, 2]))
        let echoed = try await s.read(exactly: 3)
        XCTAssertEqual(echoed, Data([1, 2, 0xFF]))
        XCTAssertEqual(accepted.eventSnapshot.first, "127.0.0.1")

        // Cancelling a pending read throws and closes the stream.
        let reader = Task { try await s.readSome() }
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        do {
            _ = try await reader.value
            XCTFail("expected the cancelled read to throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        do {
            try await s.write(Data([1]))
            XCTFail("expected a write after close to fail")
        } catch let e as TransportError {
            XCTAssertEqual(e, .closed)
        }
        listener.cancel()
    }
}
