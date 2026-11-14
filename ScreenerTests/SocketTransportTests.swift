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
        a.start(onReceive: ia.add, onEvent: ia.event)
        b.start(onReceive: ib.add, onEvent: ib.event)
        XCTAssertEqual(ia.eventSnapshot.first, "bound local=127.0.0.1:47901 remote=127.0.0.1:47902")
        a.send(Data([1, 2, 3]))
        b.send(Data([9]))
        try await waitFor { ib.snapshot.count == 1 && ia.snapshot.count == 1 }
        XCTAssertEqual(ib.snapshot, [Data([1, 2, 3])])
        XCTAssertEqual(ia.snapshot, [Data([9])])
        a.cancel(); b.cancel()
        a.send(Data([7]))   // after cancel: a no-op, not a crash
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
