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
        guard let bEnd = b as? MemoryPipeEnd else {
            XCTFail("expected MemoryPipeEnd")
            return
        }
        let readTask = Task { try await b.read(exactly: 1) }

        // Poll (bounded by a timeout) until the reader is actually registered as
        // waiting, instead of guessing with a fixed sleep, so this test covers
        // close-while-a-read-is-genuinely-suspended deterministically.
        let deadline = Date().addingTimeInterval(2)
        while !bEnd.hasWaiterForTesting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(bEnd.hasWaiterForTesting, "reader never registered as waiting")

        a.close()

        do { _ = try await readTask.value; XCTFail("expected closed") }
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

    /// Stress test for the lost-wakeup race in `MemoryPipeEnd.waitForMore`: before
    /// the fix, a reader could observe an empty buffer, unlock, and then register as
    /// a waiter *after* the writer had already delivered and drained waiters in that
    /// gap, hanging forever. Each iteration uses a fresh pipe and a tight per-read
    /// timeout so a regression fails the test instead of hanging the whole suite.
    func testPipeReadWriteStressDoesNotHang() async throws {
        for i in 0..<2000 {
            let (a, b) = MemoryPipe.pair()
            let writer = Task { try await a.write(Data([UInt8(truncatingIfNeeded: i)])) }
            let got = try await withTimeout(seconds: 2) { try await b.read(exactly: 1) }
            XCTAssertEqual(got, Data([UInt8(truncatingIfNeeded: i)]), "iteration \(i)")
            _ = try await writer.value
        }
    }

    /// Stress test for cancellation racing the same lost-wakeup window: cancelling a
    /// task right as it starts a blocking read must always resolve (either throwing
    /// `CancellationError` or `TransportError.closed`), never hang.
    func testPipeReadCancelRaceStressDoesNotHang() async throws {
        for i in 0..<2000 {
            let (_, b) = MemoryPipe.pair()
            let task = Task { try await b.read(exactly: 1) }
            task.cancel()
            try await withTimeout(seconds: 2) {
                do {
                    _ = try await task.value
                    XCTFail("iteration \(i): expected an error")
                } catch is CancellationError {
                } catch TransportError.closed {
                } catch {
                    XCTFail("iteration \(i): unexpected error \(error)")
                }
            }
        }
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
        } catch TransportError.failed, TransportError.posix {
            // some simulator network configurations fail fast with a different
            // NWError (e.g. "no route to host") before our timer fires; accept it.
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTCPLoopbackRoundTripThenClose() async throws {
        let listener = try NWListener(using: .tcp)
        defer { listener.cancel() }
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
        } catch TransportError.failed, TransportError.posix {
            // Also acceptable: NWConnection can surface closure as a POSIX error
            // on some simulator network stacks.
        }
    }

    func testTCPReadCancellationClosesStream() async throws {
        let listener = try NWListener(using: .tcp)
        defer { listener.cancel() }
        let ready = expectation(description: "listener ready")
        listener.newConnectionHandler = { conn in conn.start(queue: .main) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)

        guard let port = listener.port else { XCTFail("no port"); return }
        let client = try await TCPByteStream.connect(host: "127.0.0.1", port: port.rawValue, timeout: .seconds(5))

        // Nothing is ever written, so this read would otherwise block forever
        // waiting for data.
        let readTask = Task { try await client.read(exactly: 1) }
        readTask.cancel()

        do {
            _ = try await readTask.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected: cancelling a pending TCP read surfaces CancellationError.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // Per the documented ByteStream cancellation semantics, cancelling a pending
        // read on TCPByteStream closes the stream: a subsequent read must observe it
        // as closed (not silently hang, and not succeed).
        do {
            _ = try await client.read(exactly: 1)
            XCTFail("expected closed after cancellation")
        } catch TransportError.closed {
        } catch TransportError.failed, TransportError.posix {
            // Also acceptable: NWConnection can surface a cancelled connection as a
            // POSIX error on some simulator network stacks.
        }
    }

    func testTCPWriteAfterCloseMapsToClosed() async throws {
        let listener = try NWListener(using: .tcp)
        defer { listener.cancel() }
        let ready = expectation(description: "listener ready")
        listener.newConnectionHandler = { conn in conn.start(queue: .main) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)

        guard let port = listener.port else { XCTFail("no port"); return }
        let client = try await TCPByteStream.connect(host: "127.0.0.1", port: port.rawValue, timeout: .seconds(5))

        client.close()

        do {
            try await client.write(Data([0x01]))
            XCTFail("expected write after close to throw")
        } catch TransportError.closed {
        } catch TransportError.failed, TransportError.posix {
            // Also acceptable: some simulator network stacks surface a cancelled
            // connection's send failure as a different NWError.
        }
    }

    func testTCPConcurrentReadsThrowFailed() async throws {
        let listener = try NWListener(using: .tcp)
        defer { listener.cancel() }
        let ready = expectation(description: "listener ready")
        listener.newConnectionHandler = { conn in conn.start(queue: .main) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)

        guard let port = listener.port else { XCTFail("no port"); return }
        let client = try await TCPByteStream.connect(host: "127.0.0.1", port: port.rawValue, timeout: .seconds(5))

        // Read A: nothing is ever written, so it blocks until cancelled below.
        let readA = Task { try await client.read(exactly: 1) }

        // Poll (bounded by a timeout) until read A has actually registered itself as
        // the active reader, instead of guessing with a fixed sleep.
        let deadline = Date().addingTimeInterval(2)
        while !client.isReadActiveForTesting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(client.isReadActiveForTesting, "read A never became active")

        do {
            _ = try await client.read(exactly: 1)
            XCTFail("expected a second concurrent read to fail")
        } catch TransportError.failed(let message) {
            XCTAssertEqual(message, "concurrent read")
        }

        readA.cancel()
        _ = try? await readA.value
    }

    private func receiveExactly(_ n: Int, from conn: NWConnection) async throws -> Data {
        let accumulator = ReceiveAccumulator()
        return try await withCheckedThrowingContinuation { cont in
            accumulator.pump(connection: conn, target: n, continuation: cont)
        }
    }
}

/// Runs `operation`, failing the test (rather than hanging) if it doesn't complete
/// within `seconds`. Used by the stress tests so a lost-wakeup regression surfaces as
/// a fast, deterministic failure instead of a suite-wide hang/timeout.
private func withTimeout<T: Sendable>(seconds: TimeInterval, _ operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}

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
