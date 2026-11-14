import XCTest
import Network
@testable import Screener

final class ByteStreamTests: XCTestCase {
    func testPipeExactReadAcrossWrites() async throws {
        let (a, b) = MemoryPipe.pair()
        Task { try? await a.write(Data([1, 2])); try? await a.write(Data([3, 4, 5])) }
        let got = try await b.read(exactly: 4)
        XCTAssertEqual(got, Data([1, 2, 3, 4]))
        let rest = try await b.read(exactly: 1)
        XCTAssertEqual(rest, Data([5]))
    }

    func testPipeCloseFailsReads() async throws {
        let (a, b) = MemoryPipe.pair()
        Task { try? await Task.sleep(for: .milliseconds(20)); a.close() }
        do { _ = try await b.read(exactly: 1); XCTFail("expected closed") }
        catch TransportError.closed {}
    }

    func testPipeCloseFailsBothEndsAfterDrain() async throws {
        let (a, b) = MemoryPipe.pair()
        try await a.write(Data([9, 9]))
        a.close()
        // Buffered data on b must drain before b observes closed.
        let drained = try await b.read(exactly: 2)
        XCTAssertEqual(drained, Data([9, 9]))
        do { _ = try await b.read(exactly: 1); XCTFail("expected closed on b after drain") }
        catch TransportError.closed {}
        do { _ = try await a.read(exactly: 1); XCTFail("expected closed on a (closer side)") }
        catch TransportError.closed {}
        do { try await a.write(Data([1])); XCTFail("expected closed on write after close") }
        catch TransportError.closed {}
    }

    func testPipeReadSomeReturnsWhateverIsBuffered() async throws {
        let (a, b) = MemoryPipe.pair()
        try await a.write(Data([1, 2, 3]))
        let got = try await b.readSome()
        XCTAssertEqual(got, Data([1, 2, 3]))
    }

    func testPipeReadCancellation() async throws {
        let (_, b) = MemoryPipe.pair()
        let task = Task {
            try await b.read(exactly: 1)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation or closed error")
        } catch is CancellationError {
            // documented: a cancelled pending read throws CancellationError
        } catch TransportError.closed {
            // acceptable alternative per spec; not expected with current implementation
        }
    }

    func testTCPTimeout() async {
        do {
            _ = try await TCPByteStream.connect(host: "10.255.255.1", port: 5900, timeout: .milliseconds(300))
            XCTFail("expected timeout or failure")
        } catch TransportError.timeout {
            // expected on most networks
        } catch TransportError.failed {
            // some simulator network configurations fail fast with a different
            // NWError (e.g. "no route to host") before our timer fires; accept it.
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTCPLoopbackRoundTripThenClose() async throws {
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "listener ready")
        let accepted = AcceptedConnectionBox()

        listener.newConnectionHandler = { conn in
            Task { await accepted.set(conn) }
            conn.start(queue: .main)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)

        guard let port = listener.port else { XCTFail("no port"); return }

        let client = try await TCPByteStream.connect(host: "127.0.0.1", port: port.rawValue, timeout: .seconds(5))

        try await client.write(Data([0xAA, 0xBB, 0xCC]))

        // Wait for the server side to accept the connection.
        guard let serverConn = await accepted.waitForConnection(timeout: 5) else {
            XCTFail("no server connection"); return
        }

        let received = try await receiveExactly(3, from: serverConn)
        XCTAssertEqual(received, Data([0xAA, 0xBB, 0xCC]))

        client.close()
        listener.cancel()

        do {
            _ = try await client.read(exactly: 1)
            XCTFail("expected closed after close()")
        } catch TransportError.closed {
        } catch TransportError.failed {
            // Also acceptable: NWConnection can surface closure as a POSIX error
            // on some simulator network stacks.
        }
    }

    private func receiveExactly(_ n: Int, from conn: NWConnection) async throws -> Data {
        let accumulator = ReceiveAccumulator()
        return try await withCheckedThrowingContinuation { cont in
            accumulator.pump(connection: conn, target: n, continuation: cont)
        }
    }
}

/// Accumulates bytes across repeated `NWConnection.receive` calls until `target`
/// bytes are collected. A plain `@unchecked Sendable` class: every mutation and the
/// recursive `receive` call happen on the connection's own callback queue, so there
/// is never concurrent access, but the compiler can't see that across the escaping
/// closure boundary.
private final class ReceiveAccumulator: @unchecked Sendable {
    private var buffer = Data()

    func pump(connection: NWConnection, target: Int, continuation: CheckedContinuation<Data, Error>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: target - buffer.count) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                continuation.resume(throwing: error)
                return
            }
            if let data { self.buffer.append(data) }
            if self.buffer.count >= target {
                continuation.resume(returning: self.buffer)
            } else {
                self.pump(connection: connection, target: target, continuation: continuation)
            }
        }
    }
}

/// Hands an accepted `NWConnection` from the listener's callback to the awaiting test.
private actor AcceptedConnectionBox {
    private var connection: NWConnection?

    func set(_ connection: NWConnection) {
        self.connection = connection
    }

    func waitForConnection(timeout: TimeInterval) async -> NWConnection? {
        let deadline = Date().addingTimeInterval(timeout)
        while connection == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return connection
    }
}
