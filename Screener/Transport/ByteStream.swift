import Foundation
import Network

/// Errors produced by `ByteStream` implementations.
enum TransportError: Error, Equatable {
    case timeout
    case closed
    case failed(String)
    /// A socket-level failure with its errno (ECONNREFUSED, ECONNABORTED, ...),
    /// so the UI can say something useful instead of the raw code.
    case posix(Int32)

    /// NWError → `.posix` when it carries an errno, else `.failed`.
    static func from(_ error: NWError) -> TransportError {
        if case .posix(let code) = error { return .posix(code.rawValue) }
        return .failed("\(error)")
    }
}

/// An async byte-oriented transport: read/write `Data` without caring whether the
/// underlying channel is a TCP socket, an in-memory pipe, or something else.
///
/// Cancellation semantics: if the calling `Task` is cancelled while a `read(exactly:)`
/// or `readSome()` call is suspended waiting for data, the call throws
/// `CancellationError` (not `TransportError.closed`). What happens to the stream
/// itself differs by implementation: cancelling a pending read on `TCPByteStream`
/// closes the stream (a cancelled `NWConnection.receive` may still complete and its
/// bytes would otherwise be silently discarded, desyncing the RFB stream — closing is
/// the only safe outcome); on `MemoryPipe` it leaves the stream usable, since no bytes
/// can be lost that way in-process.
///
/// Concurrency: a `ByteStream` instance supports exactly one concurrent reader (i.e.
/// at most one of `read(exactly:)`/`readSome()` in flight at a time) but any number of
/// concurrent writers. This matches its intended use by `ControlSession`, which has a
/// single reader task and multiple concurrent writers.
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
    /// Closes the stream like `close()` and waits, at most `timeout`, until the
    /// close has actually gone out (for TCP: NWConnection reached `.cancelled`,
    /// i.e. the FIN was handed to the network). Returns false on timeout.
    /// Used when the app is backgrounded: iOS may suspend us right after, and
    /// the Mac only ends sharing (and display privacy) when it sees the close.
    func closeAndWait(timeout: Duration) async -> Bool
}

extension ByteStream {
    /// In-process streams close synchronously.
    func closeAndWait(timeout: Duration) async -> Bool {
        close()
        return true
    }
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
final class MemoryPipeEnd: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    fileprivate weak var peer: MemoryPipeEnd?

    /// Test-only hook: true once at least one reader is registered as waiting for
    /// more data (i.e. a `read`/`readSome` call has found nothing buffered and is
    /// suspended). Lets tests deterministically detect "a reader is blocked" instead
    /// of guessing with a fixed sleep.
    var hasWaiterForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !waiters.isEmpty
    }

    func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else { throw TransportError.failed("negative read length") }
        while true {
            switch takeExactlyIfPossible(count) {
            case .data(let result): return result
            case .closed: throw TransportError.closed
            case .wouldBlock: try await waitForMore(isReady: { self.buffer.count >= count })
            }
        }
    }

    func readSome() async throws -> Data {
        while true {
            switch takeSomeIfPossible() {
            case .data(let result): return result
            case .closed: throw TransportError.closed
            case .wouldBlock: try await waitForMore(isReady: { !self.buffer.isEmpty })
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

    /// Suspends until new data arrives, the pipe closes, or the calling task is
    /// cancelled. `isReady` is evaluated *under `lock`*, in the very same critical
    /// section that registers the waiter continuation, so there is no gap between
    /// "nothing to read yet" and "now registered to be woken up": any `deliver`/
    /// `markClosed` that lands before this check sees it (because `isReady`/`closed`
    /// now holds), and any that lands after sees the registered waiter (because
    /// `drainWaitersLocked` runs under the same lock). Without this, a reader could
    /// observe an empty buffer, then have data (or close, or cancellation) delivered
    /// in the gap before it registers — a lost wakeup that hangs forever.
    ///
    /// Throws `CancellationError` if the calling task is cancelled while suspended
    /// (or was already cancelled when this was called), leaving this end open.
    /// `isReady` must only read state guarded by `lock` (e.g. `buffer`), never
    /// re-enter any of this type's locking methods.
    private func waitForMore(isReady: @escaping () -> Bool) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isReady() || closed || Task.isCancelled {
                    lock.unlock()
                    cont.resume()
                } else {
                    waiters[id] = cont
                    lock.unlock()
                }
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
    /// Guards `readerActive`, the only mutable state on this instance: `connection`
    /// and `queue` are immutable, and NWConnection's own callbacks are independently
    /// thread-safe. `@unchecked Sendable` is justified by this lock.
    private let stateLock = NSLock()
    /// Whether a `read(exactly:)`/`readSome()` call is currently in flight. Enforces
    /// the single-reader contract documented on `ByteStream`.
    private var readerActive = false

    /// Test-only hook mirroring `readerActive`, so tests can deterministically wait
    /// for a read to become active instead of guessing with a fixed sleep.
    var isReadActiveForTesting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return readerActive
    }

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
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        // The HP media plane is IPv4-only and the server sends UDP to the TCP
        // peer address, so the control connection must be IPv4 as well
        // (session._resolve_host_ipv4). SessionCoordinator passes an IPv4
        // literal; this also keeps a Bonjour endpoint (Task 18) off IPv6.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
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
                // Cleared on every resume path below (ready/failed/cancelled/timeout):
                // once connect has resumed (one way or another), there's no
                // reader-facing need for further state updates, and clearing it
                // breaks the connection↔handler reference cycle this closure forms.
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumeState.markResumed() {
                            connection.stateUpdateHandler = nil
                            cont.resume(returning: TCPByteStream(connection: connection, queue: queue))
                        }
                    case .failed(let error):
                        if resumeState.markResumed() {
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            cont.resume(throwing: TransportError.from(error))
                        }
                    case .waiting(let error):
                        let reason = connection.currentPath?.unsatisfiedReason
                        if let verdict = waitingVerdict(error, unsatisfiedReason: reason),
                           resumeState.markResumed() {
                            Log.control.error("tcp connect waiting (\(error); path \(String(describing: reason))): giving up")
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            cont.resume(throwing: verdict)
                        }
                    case .cancelled:
                        if resumeState.markResumed() {
                            connection.stateUpdateHandler = nil
                            cont.resume(throwing: TransportError.closed)
                        }
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.asDispatchTimeInterval) {
                    if resumeState.markResumed() {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        cont.resume(throwing: TransportError.timeout)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// What a `.waiting` NWConnection means for a connect in progress: an
    /// error to fail with now, or nil to keep waiting (until the timeout).
    ///   * ECONNREFUSED: nobody is listening (Screen Sharing off); NWConnection
    ///     would retry until the timeout, so say so now.
    ///   * The path is unsatisfied because the user denied Local Network
    ///     access: no amount of waiting helps; fail with EPERM, the errno
    ///     UserFacingError maps to the Local Network message.
    ///   * Anything else (no route yet, the Local Network prompt still up)
    ///     waits; a timeout reads as "Can't reach this Mac".
    static func waitingVerdict(_ error: NWError, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> TransportError? {
        if unsatisfiedReason == .localNetworkDenied { return .posix(EPERM) }
        if case .posix(.ECONNREFUSED) = error { return .posix(ECONNREFUSED) }
        return nil
    }

    func closeAndWait(timeout: Duration) async -> Bool {
        let once = ResumeOnce()
        let connection = connection, queue = queue
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // On the connection's queue, so the state check and the handler
            // install cannot miss a `.cancelled` delivered in between.
            queue.async {
                switch connection.state {
                case .cancelled:
                    if once.markResumed() { cont.resume(returning: true) }
                    return
                default:
                    break
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .cancelled, .failed:
                        if once.markResumed() {
                            connection.stateUpdateHandler = nil
                            cont.resume(returning: true)
                        }
                    default:
                        break
                    }
                }
                connection.cancel()   // graceful: FIN, not RST (that is forceCancel)
                queue.asyncAfter(deadline: .now() + timeout.asDispatchTimeInterval) {
                    if once.markResumed() {
                        connection.stateUpdateHandler = nil
                        cont.resume(returning: false)
                    }
                }
            }
        }
    }

    func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else { throw TransportError.failed("negative read length") }
        try beginRead()
        defer { endRead() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            // If this throws (closed/failed/cancelled), the bytes already
            // accumulated in `result` are discarded along with it: the stream is
            // dead at that point, so there's no way for a caller to resume a
            // partial read, and returning a short `Data` would silently desync the
            // RFB framing above us.
            let chunk = try await receiveChunk(maximumLength: count - result.count)
            result.append(chunk)
        }
        return result
    }

    func readSome() async throws -> Data {
        try beginRead()
        defer { endRead() }
        return try await receiveChunk(maximumLength: 64 * 1024)
    }

    /// Marks a read as in-flight, enforcing the single-reader contract documented on
    /// `ByteStream`. Throws `TransportError.failed` if another read is already active.
    private func beginRead() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if readerActive {
            throw TransportError.failed("concurrent read")
        }
        readerActive = true
    }

    private func endRead() {
        stateLock.lock()
        readerActive = false
        stateLock.unlock()
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    // Matches `receiveChunk`: a connection cancelled via `close()` or a
                    // different in-flight read's cancellation surfaces a pending send's
                    // failure as POSIX ECANCELED. Report that as `.closed` rather than
                    // `.failed`, since "the stream is closed" is the accurate, documented
                    // outcome callers should be matching on.
                    if case .posix(.ECANCELED) = error {
                        cont.resume(throwing: TransportError.closed)
                    } else {
                        cont.resume(throwing: TransportError.from(error))
                    }
                } else {
                    cont.resume(returning: ())
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }

    /// Receives at least 1 and at most `maximumLength` bytes. Throws
    /// `TransportError.closed` on a clean remote close, `TransportError.failed` on a
    /// network error, and `CancellationError` if the calling task is cancelled while
    /// waiting (per the documented `ByteStream` cancellation semantics).
    private func receiveChunk(maximumLength: Int) async throws -> Data {
        // Set by `onCancel` below, and consulted by the `receive` completion so it
        // can report `CancellationError` instead of whatever NWError the now-cancelled
        // connection happens to surface for this in-flight call.
        let cancelFlag = CancelFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(maximumLength, 1)) { data, _, isComplete, error in
                    if cancelFlag.isSet {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    if let error {
                        // A receive on a connection that was cancelled out from under
                        // it (by a *different* call's cancellation, via `onCancel`
                        // below) surfaces as a POSIX ECANCELED NWError. Report that as
                        // `.closed`, matching the documented outcome that cancelling a
                        // pending read closes the stream for everyone.
                        if case .posix(.ECANCELED) = error {
                            cont.resume(throwing: TransportError.closed)
                        } else {
                            cont.resume(throwing: TransportError.from(error))
                        }
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
            // NWConnection has no per-call cancel: a cancelled read's in-flight
            // `receive` would otherwise complete and silently drop its bytes,
            // desyncing the RFB stream for whoever reads next. So cancellation
            // closes the whole connection instead, making the suspended read throw
            // CancellationError and any subsequent read throw TransportError.closed
            // — the only safe outcome, per the documented ByteStream cancellation
            // semantics.
            cancelFlag.set()
            connection.cancel()
        }
    }
}

/// A lock-protected one-shot flag, set by a `withTaskCancellationHandler`'s
/// `onCancel` closure and read from the concurrently-running `receive` completion
/// handler it races with.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
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
