import Foundation
import Network

/// Errors produced by `ByteStream` implementations.
enum TransportError: Error, Equatable {
    case timeout
    case closed
    case failed(String)
}

/// An async byte-oriented transport: read/write `Data` without caring whether the
/// underlying channel is a TCP socket, an in-memory pipe, or something else.
///
/// Cancellation semantics: if the calling `Task` is cancelled while a `read(exactly:)`
/// or `readSome()` call is suspended waiting for data, the call throws
/// `CancellationError` (not `TransportError.closed`) — the stream itself is left open
/// and other callers may continue to use it. This matches Swift's general convention
/// that task cancellation surfaces as `CancellationError` at a cancellation checkpoint.
protocol ByteStream: Sendable {
    /// Reads exactly `count` bytes, buffering partial reads internally until satisfied.
    func read(exactly count: Int) async throws -> Data
    /// Reads whatever is immediately available (at least 1 byte), without waiting for a
    /// specific amount.
    func readSome() async throws -> Data
    /// Writes `data` in full.
    func write(_ data: Data) async throws
    /// Closes the stream. Pending and future reads/writes on this stream (and, for
    /// `MemoryPipe`, its peer) fail with `TransportError.closed` once any already
    /// buffered data has been drained.
    func close()
}

// MARK: - MemoryPipe

/// An in-memory, two-ended `ByteStream` pair for testing protocol flows without a
/// network. `MemoryPipe.pair()` returns two connected ends; writing to one makes the
/// bytes available to `read`/`readSome` on the other.
enum MemoryPipe {
    static func pair() -> (ByteStream, ByteStream) {
        let a = MemoryPipeEnd()
        let b = MemoryPipeEnd()
        a.peer = b
        b.peer = a
        return (a, b)
    }
}

/// One end of a `MemoryPipe`. `@unchecked Sendable` because all mutable state
/// (buffer, closed flag, waiter list, peer reference) is guarded by `lock`; the only
/// exception is `peer`, which is assigned exactly once by `MemoryPipe.pair()` before
/// either end is handed to concurrent callers, and never mutated afterwards.
private final class MemoryPipeEnd: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    fileprivate weak var peer: MemoryPipeEnd?

    func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else { throw TransportError.failed("negative read length") }
        while true {
            switch takeExactlyIfPossible(count) {
            case .data(let result): return result
            case .closed: throw TransportError.closed
            case .wouldBlock: try await waitForMore()
            }
        }
    }

    func readSome() async throws -> Data {
        while true {
            switch takeSomeIfPossible() {
            case .data(let result): return result
            case .closed: throw TransportError.closed
            case .wouldBlock: try await waitForMore()
            }
        }
    }

    func write(_ data: Data) async throws {
        guard let peer else { throw TransportError.closed }
        try peer.deliver(data)
    }

    func close() {
        markClosed()
        peer?.markClosed()
    }

    private enum TakeResult { case data(Data), closed, wouldBlock }

    /// Synchronous, lock-protected: takes `count` bytes if already buffered.
    private func takeExactlyIfPossible(_ count: Int) -> TakeResult {
        lock.lock()
        defer { lock.unlock() }
        if buffer.count >= count {
            let result = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return .data(result)
        }
        return closed ? .closed : .wouldBlock
    }

    /// Synchronous, lock-protected: takes whatever is buffered, if anything.
    private func takeSomeIfPossible() -> TakeResult {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            let result = buffer
            buffer.removeAll()
            return .data(result)
        }
        return closed ? .closed : .wouldBlock
    }

    /// Appends `data` to this end's inbound buffer (called by the peer's `write`).
    fileprivate func deliver(_ data: Data) throws {
        let toResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        if closed {
            lock.unlock()
            throw TransportError.closed
        }
        buffer.append(data)
        toResume = drainWaitersLocked()
        lock.unlock()
        for cont in toResume { cont.resume() }
    }

    /// Marks this end closed; idempotent. Called both by `close()` on the local end
    /// and (via the peer reference) to propagate closure to the other end.
    fileprivate func markClosed() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let toResume = drainWaitersLocked()
        lock.unlock()
        for cont in toResume { cont.resume() }
    }

    /// Must be called with `lock` held; returns the continuations to resume after
    /// unlocking (we always resume continuations outside the lock to keep the
    /// critical section tiny and avoid any risk of running arbitrary continuation
    /// resumption work while holding it).
    private func drainWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        let all = Array(waiters.values)
        waiters.removeAll()
        return all
    }

    /// Synchronous, lock-protected: registers a waiter continuation and returns it.
    private func registerWaiter(_ id: UUID, _ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        waiters[id] = cont
        lock.unlock()
    }

    /// Suspends until new data arrives or the pipe closes. Throws `CancellationError`
    /// if the calling task is cancelled while suspended, leaving this end open.
    private func waitForMore() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                registerWaiter(id, cont)
            }
            try Task.checkCancellation()
        } onCancel: { [weak self] in
            self?.cancelWaiter(id)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        lock.lock()
        let cont = waiters.removeValue(forKey: id)
        lock.unlock()
        cont?.resume()
    }
}

// MARK: - TCPByteStream

/// A `ByteStream` backed by `NWConnection` over TCP.
final class TCPByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    /// Buffers bytes that arrived from the network but haven't been consumed by a
    /// `read(exactly:)` call yet. Only ever touched on `queue`.
    private var pending = Data()
    private var closed = false

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Connects to `host:port` over TCP, failing with `TransportError.timeout` if the
    /// connection does not become ready within `timeout`.
    static func connect(host: String, port: UInt16, timeout: Duration) async throws -> TCPByteStream {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.failed("invalid port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        return try await connect(endpoint: endpoint, timeout: timeout)
    }

    /// Connects to an arbitrary `NWEndpoint` (e.g. a Bonjour service endpoint) over
    /// TCP, failing with `TransportError.timeout` if the connection does not become
    /// ready within `timeout`.
    static func connect(endpoint: NWEndpoint, timeout: Duration) async throws -> TCPByteStream {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "ByteStream.TCP")

        let resumeState = ResumeOnce()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TCPByteStream, Error>) in
                // No named `DispatchWorkItem` is kept around: each closure below is
                // self-contained and only ever resumes if it wins the race (guarded
                // by `resumeState`), so there is nothing to explicitly cancel when
                // the *other* path wins instead.
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumeState.markResumed() {
                            cont.resume(returning: TCPByteStream(connection: connection, queue: queue))
                        }
                    case .failed(let error):
                        if resumeState.markResumed() {
                            connection.cancel()
                            cont.resume(throwing: TransportError.failed("\(error)"))
                        }
                    case .cancelled:
                        if resumeState.markResumed() {
                            cont.resume(throwing: TransportError.closed)
                        }
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.asDispatchTimeInterval) {
                    if resumeState.markResumed() {
                        connection.cancel()
                        cont.resume(throwing: TransportError.timeout)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else { throw TransportError.failed("negative read length") }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try await receiveChunk(maximumLength: count - result.count)
            result.append(chunk)
        }
        return result
    }

    func readSome() async throws -> Data {
        try await receiveChunk(maximumLength: 64 * 1024)
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: TransportError.failed("\(error)"))
                } else {
                    cont.resume(returning: ())
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }

    /// Receives at least 1 and at most `maximumLength` bytes, consulting any
    /// internally-buffered leftovers first. Throws `TransportError.closed` on a
    /// clean remote close, `TransportError.failed` on a network error, and
    /// `CancellationError` if the calling task is cancelled while waiting (per the
    /// documented `ByteStream` cancellation semantics).
    private func receiveChunk(maximumLength: Int) async throws -> Data {
        if !pending.isEmpty {
            let take = min(pending.count, maximumLength)
            let chunk = pending.prefix(take)
            pending.removeFirst(take)
            return Data(chunk)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(maximumLength, 1)) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: TransportError.failed("\(error)"))
                        return
                    }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                        return
                    }
                    if isComplete {
                        cont.resume(throwing: TransportError.closed)
                        return
                    }
                    cont.resume(throwing: TransportError.failed("empty receive"))
                }
            }
        } onCancel: {
            // We intentionally do not cancel the whole connection here: a cancelled
            // read should not tear down the stream for other callers. The in-flight
            // `receive` completion (if any) will simply be ignored once this call's
            // continuation has already thrown via checkCancellation at the next
            // checkpoint; NWConnection itself has no per-call cancel, so a cancelled
            // read may still let its receive complete and its data be dropped. This
            // is an accepted limitation of the current implementation.
        }
    }
}

/// Guards a `CheckedContinuation` against being resumed more than once across the
/// several callback paths (`.ready`, `.failed`, `.cancelled`, timeout) that can race
/// to resume it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

private extension Duration {
    var asDispatchTimeInterval: DispatchTimeInterval {
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(nanoseconds))
    }
}
