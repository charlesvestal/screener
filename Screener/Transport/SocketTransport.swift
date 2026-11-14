// Ported in part from iShareScreen src/isharescreen/proxy/session.py
// (_bind_udp, _resolve_host_ipv4) (AGPL-3.0)
//
// BSD-socket transports for the cases where the LOCAL address/port matters.
//
// Why not NWConnection: the HP server sends media from <its IP>:P/P+1 to
// <our TCP-peer IP>:P/P+1 (netstat during a live session, 2026-11-14), so the
// UDP flows must be bound to local ports P and P+1 exactly like the
// reference's `_bind_udp`. In the iOS simulator Network.framework silently
// ignores `NWParameters.requiredLocalEndpoint` for both UDP and TCP (probe:
// required 192.0.2.33:5913 → ready on 192.0.2.54:<ephemeral>), while a
// plain bind() is honoured. Sockets give the same, verifiable semantics on
// device and in the simulator.
import Darwin
import Foundation

enum BSDSocket {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case resolve(String)
        case syscall(String, Int32)
        var description: String {
            switch self {
            case .resolve(let h): return "cannot resolve \(h) to IPv4"
            case .syscall(let call, let e): return "\(call): \(String(cString: strerror(e))) (\(e))"
            }
        }
    }

    /// First IPv4 address for `host` (session._resolve_host_ipv4: the HP UDP
    /// transport is IPv4-only).
    static func resolveIPv4(_ host: String, port: UInt16) throws -> sockaddr_in {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { throw Failure.resolve(host) }
        defer { freeaddrinfo(res) }
        var addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        addr.sin_port = port.bigEndian
        return addr
    }

    static func any(port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = INADDR_ANY
        return a
    }

    static func address(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    static func describe(_ a: sockaddr_in) -> String { "\(address(a)):\(UInt16(bigEndian: a.sin_port))" }

    static func bind(_ fd: Int32, _ a: sockaddr_in) throws {
        var a = a
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 { throw Failure.syscall("bind \(describe(a))", errno) }
    }

    static func connect(_ fd: Int32, _ a: sockaddr_in) -> Int32 {
        var a = a
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    static func localName(_ fd: Int32) -> String {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return rc == 0 ? describe(a) : "?"
    }

    static func setInt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
        var v = value
        setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    static func local(_ host: String?, port: UInt16) throws -> sockaddr_in {
        guard let host else { return any(port: port) }
        return try resolveIPv4(host, port: port)
    }
}

// MARK: - IPv4 resolution

/// session._resolve_host_ipv4: the HP UDP transport is IPv4-only, so the
/// coordinator resolves the host ONCE to an IPv4 literal and hands that same
/// literal to the TCP control connection and to both UDP flows. Otherwise a
/// dual-stack name can put TCP on IPv6 while UDP sits on IPv4, and the server
/// (which sends media to the TCP peer address) never reaches us.
///
/// Task 18 (Bonjour): an `NWEndpoint.service` must be resolved to an IPv4
/// literal first (or take the TCP connection's resolved IPv4 remote) and go
/// through this same path; never hand the service endpoint to TCP directly.
enum IPv4Resolver {
    enum Failure: Error, Equatable, LocalizedError {
        /// The name resolves, but only to IPv6.
        case noIPv4(host: String)
        case unresolvable(host: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .noIPv4(let h):
                return "This Mac has no IPv4 address on this network (\(h) resolves only to IPv6). "
                    + "High Performance screen sharing needs IPv4."
            case .unresolvable(let h, let d):
                return "Cannot find \(h) on this network (\(d))."
            }
        }
    }

    /// getaddrinfo blocks (DNS, mDNS); it runs here, off the main actor and
    /// off Swift's cooperative pool.
    private static let queue = DispatchQueue(label: "IPv4Resolver", qos: .userInitiated, attributes: .concurrent)

    /// The first IPv4 address of `host` as a dotted-quad literal. IPv4
    /// literals pass straight through.
    static func resolve(_ host: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                cont.resume(with: Result { try resolveBlocking(host) })
            }
        }
    }

    static func resolveBlocking(_ host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        if rc == 0, let first = res {
            defer { freeaddrinfo(res) }
            let a = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            return BSDSocket.address(a)
        }
        // Distinguish "IPv6 only" from "does not resolve at all".
        hints.ai_family = AF_UNSPEC
        var any: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &any) == 0 {
            freeaddrinfo(any)
            throw Failure.noIPv4(host: host)
        }
        throw Failure.unresolvable(host: host, detail: String(cString: gai_strerror(rc)))
    }
}

// MARK: - UDP

/// Why a datagram channel stopped for good.
enum DatagramChannelError: Error, Equatable, CustomStringConvertible {
    /// bind() failed; `errno` is the cause (EADDRINUSE: another session owns the port).
    case bind(port: UInt16, errno: Int32)
    case setup(String)

    var description: String {
        switch self {
        case .bind(let p, let e): return "bind UDP \(p): \(String(cString: strerror(e))) (\(e))"
        case .setup(let s): return s
        }
    }
}

/// What a socket error means for a media flow (pure; the channel holds one
/// under its lock).
///   * EBADF / ENOTSOCK / ENOTCONN / EADDRNOTAVAIL: the socket or its address
///     is gone; fatal at once.
///   * Before the stream is established (no datagram received yet: the
///     hole-punch / pre-burst phase), EPIPE, routing errors (EHOSTUNREACH,
///     EHOSTDOWN, ENETUNREACH, ENETDOWN) and EPERM / EACCES are never fatal.
///     On the first launch iOS fails sends with EPIPE while the Local Network
///     prompt is up, and with EPERM/EHOSTUNREACH once access is denied (first
///     iPad run, 2026-11-14). The run is remembered as `startupBlocked`
///     until a send or receive works; MediaTransport turns a block that
///     outlasts the start burst into the Local Network message.
///   * After the stream is established, the same errors are fatal only when
///     they keep coming for more than `routingGrace` with no successful send
///     or receive in between; any success restarts the clock.
///   * ECONNREFUSED (ICMP port-unreachable while the server's sockets are not
///     up yet) is never fatal and is logged on the 1st and every 50th
///     occurrence only.
///   * Everything else (ENOBUFS, ...) is transient.
/// Other transient errors are logged at most once per `logInterval` per errno.
struct SocketErrorPolicy {
    enum Verdict: Equatable { case transient(log: Bool), fatal }

    static let routingGrace: Duration = .seconds(3)
    static let logInterval: Duration = .seconds(1)
    static let refusedLogEvery = 50

    static func isFatal(_ e: Int32) -> Bool { [EBADF, ENOTSOCK, ENOTCONN, EADDRNOTAVAIL].contains(e) }
    static func isRouting(_ e: Int32) -> Bool { [EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN].contains(e) }
    /// Errors that mean "the path is blocked for now": routing trouble, a
    /// send pipe the system shut (EPIPE), or a privacy / policy denial.
    static func isBlocking(_ e: Int32) -> Bool { isRouting(e) || [EPIPE, EPERM, EACCES].contains(e) }

    /// A datagram has arrived: the server is sending.
    private(set) var established = false
    /// Start of the current unbroken run of blocking errors.
    private var blockedSince: ContinuousClock.Instant?
    private var lastBlocking: Int32?
    private var refused = 0
    private var lastLogged: [Int32: ContinuousClock.Instant] = [:]

    /// Before the stream is established: the errno of an unbroken run of
    /// blocking errors (nil once a send or receive succeeds).
    var startupBlocked: Int32? { established || blockedSince == nil ? nil : lastBlocking }

    /// A send or receive succeeded: the network works.
    mutating func noteSuccess() { blockedSince = nil; lastBlocking = nil }

    /// A datagram was received.
    mutating func noteReceive() { established = true; noteSuccess() }

    mutating func note(error e: Int32, at now: ContinuousClock.Instant) -> Verdict {
        if Self.isFatal(e) { return .fatal }
        if e == ECONNREFUSED {
            refused += 1
            return .transient(log: refused == 1 || refused % Self.refusedLogEvery == 0)
        }
        if Self.isBlocking(e) {
            let since = blockedSince ?? now
            blockedSince = since
            lastBlocking = e
            if established, now - since > Self.routingGrace { return .fatal }
        }
        if let last = lastLogged[e], now - last < Self.logInterval { return .transient(log: false) }
        lastLogged[e] = now
        return .transient(log: true)
    }
}

/// One media flow as a UDP socket bound to a fixed local port and connected
/// to the server's matching port (`_bind_udp`).
///   * SO_REUSEADDR + SO_REUSEPORT: a second viewer (another coordinator, a
///     quick reconnect) can bind the same port; because every socket is
///     connect()ed, the kernel delivers each datagram to the socket whose
///     4-tuple matches exactly, so flows to different servers never mix.
///     SessionCoordinator refuses two sessions to the same server IPv4.
///   * SO_RCVBUF: 4 MiB requested, halved on refusal down to 256 KiB; the
///     effective value is reported as an event.
///   * Connected UDP reports ICMP port-unreachable as ECONNREFUSED on the
///     next call; that is expected while punches race the server's bind and is
///     not counted until the server has sent something. Errors that mean the
///     socket is gone, or blocking errors that persist after the stream is up
///     (`SocketErrorPolicy`), stop the channel and are reported through
///     `onFailure`; before that, a block is exposed as `startupBlockedErrno`.
final class SocketDatagramChannel: DatagramChannel, @unchecked Sendable {
    static let preferredReceiveBuffer: Int32 = 4 * 1024 * 1024
    static let minimumReceiveBuffer: Int32 = 256 * 1024

    private let label: String
    private let remoteHost: String
    private let remotePort: UInt16
    private let localHost: String?
    private let localPort: UInt16
    private let queue: DispatchQueue
    // `lock` guards fd / source / closed / failed / handlers / counters /
    // errorPolicy / closeWaiters.
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var closed = false
    private var failed = false
    private var fdClosed = true
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var onReceive: (@Sendable (Data) -> Void)?
    private var onEvent: (@Sendable (String) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var sendErrors = 0, receiveErrors = 0
    private var errorPolicy = SocketErrorPolicy()

    init(label: String, remoteHost: String, remotePort: UInt16, localHost: String?, localPort: UInt16?) {
        self.label = label
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.localHost = localHost
        self.localPort = localPort ?? 0
        queue = DispatchQueue(label: "MediaTransport.udp.\(label)", qos: .userInteractive)
    }

    static func make(flow: MediaTransport.Flow, config: MediaTransport.Config) -> SocketDatagramChannel {
        let port = config.remotePort(flow)
        return SocketDatagramChannel(label: flow.rawValue, remoteHost: config.host, remotePort: port,
                                     localHost: config.localAddress, localPort: config.symmetricLocalPorts ? port : nil)
    }

    /// Binds synchronously so the port is ours before the handshake starts;
    /// throws if the port cannot be bound.
    func start(onReceive: @escaping @Sendable (Data) -> Void, onEvent: @escaping @Sendable (String) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) throws {
        lock.lock()
        self.onReceive = onReceive
        self.onEvent = onEvent
        self.onFailure = onFailure
        lock.unlock()
        try open()
    }

    private func open() throws {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw DatagramChannelError.setup("socket: \(String(cString: strerror(errno)))") }
        BSDSocket.setInt(s, SOL_SOCKET, SO_REUSEADDR, 1)
        BSDSocket.setInt(s, SOL_SOCKET, SO_REUSEPORT, 1)
        BSDSocket.setInt(s, SOL_SOCKET, SO_NOSIGPIPE, 1)
        let rcvbuf = Self.setReceiveBuffer(s)
        do {
            do {
                try BSDSocket.bind(s, BSDSocket.local(localHost, port: localPort))
            } catch BSDSocket.Failure.syscall(_, let e) {
                throw DatagramChannelError.bind(port: localPort, errno: e)
            }
            let remote = try BSDSocket.resolveIPv4(remoteHost, port: remotePort)
            if BSDSocket.connect(s, remote) != 0 { throw BSDSocket.Failure.syscall("connect", errno) }
            _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
            emit("bound local=\(BSDSocket.localName(s)) remote=\(BSDSocket.describe(remote))")
            emit("rcvbuf requested=\(Self.preferredReceiveBuffer) accepted=\(rcvbuf.accepted) effective=\(rcvbuf.effective)")
        } catch let e as DatagramChannelError {
            Darwin.close(s)
            throw e
        } catch {
            Darwin.close(s)
            throw DatagramChannelError.setup("\(error)")
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.drain(s) }
        // The fd is closed only here, after the source has stopped using it;
        // `cancel()` waits for this.
        src.setCancelHandler { [weak self] in
            Darwin.close(s)
            self?.didCloseFD()
        }
        lock.lock()
        fdClosed = false
        if closed {
            lock.unlock()
            src.setEventHandler {}
            src.resume()
            src.cancel()
            return
        }
        fd = s
        source = src
        lock.unlock()
        src.resume()
    }

    /// SO_RCVBUF: ask for 4 MiB, halve on refusal down to 256 KiB, and read
    /// back what the kernel granted (_check_rmem_cap's concern, every platform).
    private static func setReceiveBuffer(_ s: Int32) -> (accepted: Int32, effective: Int32) {
        var want = preferredReceiveBuffer
        var accepted: Int32 = 0
        while want >= minimumReceiveBuffer {
            var v = want
            if setsockopt(s, SOL_SOCKET, SO_RCVBUF, &v, socklen_t(MemoryLayout<Int32>.size)) == 0 { accepted = want; break }
            want /= 2
        }
        var eff: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_RCVBUF, &eff, &len)
        return (accepted, eff)
    }

    /// session._video_drain_loop: empty the kernel buffer as fast as possible.
    private func drain(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                lock.lock(); errorPolicy.noteReceive(); let cb = onReceive; lock.unlock()
                cb?(Data(buf[0..<n]))
                continue
            }
            if n < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return }
                if !noteSocketError(e, op: "receive") { return }
                if e == ECONNREFUSED { continue }   // ICMP from an early punch; keep draining
                return
            }
            return
        }
    }

    func send(_ datagram: Data) {
        lock.lock()
        let s = closed || failed ? -1 : fd
        lock.unlock()
        guard s >= 0 else { return }
        let n = datagram.withUnsafeBytes { Darwin.send(s, $0.baseAddress, $0.count, 0) }
        if n < 0 {
            noteSocketError(errno, op: "send")   // EAGAIN/ENOBUFS: datagram dropped (transient)
        } else {
            noteSocketSuccess()
        }
    }

    /// A send or receive succeeded (resets the routing-error clock).
    func noteSocketSuccess() {
        lock.lock(); errorPolicy.noteSuccess(); lock.unlock()
    }

    /// A datagram arrived (internal for tests; `drain` does this).
    func noteSocketReceive() {
        lock.lock(); errorPolicy.noteReceive(); lock.unlock()
    }

    var startupBlockedErrno: Int32? {
        lock.lock(); defer { lock.unlock() }; return errorPolicy.startupBlocked
    }

    /// (send, receive) errors counted so far (tests, diagnostics).
    var errorCounts: (send: Int, receive: Int) {
        lock.lock(); defer { lock.unlock() }; return (sendErrors, receiveErrors)
    }

    /// The error path of `send` / `drain` (internal for tests): counts and
    /// rate-limits the log, and stops the flow when the policy says fatal.
    /// Returns false once the channel has failed.
    @discardableResult
    func noteSocketError(_ e: Int32, op: String, at now: ContinuousClock.Instant = .now) -> Bool {
        lock.lock()
        // Refusals before the server sends are expected (its sockets are not up).
        let counts = !(e == ECONNREFUSED && !errorPolicy.established)
        if counts { if op == "send" { sendErrors += 1 } else { receiveErrors += 1 } }
        let k = op == "send" ? sendErrors : receiveErrors
        let verdict = errorPolicy.note(error: e, at: now)
        let established = errorPolicy.established
        lock.unlock()
        switch verdict {
        case .fatal:
            fail("\(op): \(String(cString: strerror(e))) (\(e))")
            return false
        case .transient(let log):
            if log {
                let what = counts ? "error #\(k)" : "error (server not sending yet)"
                let phase = established ? "" : " [startup, transient]"
                emit("\(op) \(what): \(String(cString: strerror(e))) (\(e))\(phase)")
            }
            return true
        }
    }

    /// A persistent socket error: stop receiving (the source's cancel handler
    /// closes the fd) and report once.
    private func fail(_ reason: String) {
        lock.lock()
        guard !closed, !failed else { lock.unlock(); return }
        failed = true
        let src = source
        source = nil
        fd = -1
        let cb = onFailure
        lock.unlock()
        src?.cancel()
        cb?("udp \(label): \(reason)")
    }

    /// Stops the flow and returns once the socket is actually closed, so a
    /// following bind of the same port never overlaps this one.
    func cancel() async {
        detach()?.cancel()   // the cancel handler closes the fd
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fdClosed { lock.unlock(); cont.resume(); return }
            closeWaiters.append(cont)
            lock.unlock()
        }
    }

    private func detach() -> DispatchSourceRead? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        let src = source
        source = nil
        fd = -1
        onReceive = nil
        onFailure = nil
        return src
    }

    private func didCloseFD() {
        lock.lock()
        fdClosed = true
        let waiters = closeWaiters
        closeWaiters = []
        lock.unlock()
        for w in waiters { w.resume() }
    }

    private func emit(_ msg: String) {
        lock.lock(); let cb = onEvent; lock.unlock()
        cb?(msg)
    }
}

// MARK: - TCP (DEBUG only)

#if DEBUG
/// A `ByteStream` over a BSD TCP socket, used only when the control
/// connection's source address must be pinned (`ControlSession.Seams
/// .live(localAddress:)`, reachable from the DEBUG launch harness: testing
/// against the same Mac needs a second local IP). Release builds always use
/// `TCPByteStream`. Same contract as `TCPByteStream`: one reader, many
/// writers; cancelling a pending read closes the stream.
final class SocketTCPByteStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "SocketTCPByteStream.read")
    private let writeQueue = DispatchQueue(label: "SocketTCPByteStream.write")
    private let lock = NSLock()
    private var closed = false

    private init(fd: Int32) { self.fd = fd }

    deinit { Darwin.close(fd) }

    /// `host` should be an IPv4 literal (SessionCoordinator resolves once).
    /// Cancelling the calling task aborts the connect with CancellationError.
    static func connect(host: String, port: UInt16, localAddress: String, timeout: Duration) async throws -> SocketTCPByteStream {
        let cancelled = CancelBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: Result {
                        try connectBlocking(host: host, port: port, localAddress: localAddress, timeout: timeout,
                                            isCancelled: { cancelled.isSet })
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private static func connectBlocking(host: String, port: UInt16, localAddress: String, timeout: Duration,
                                        isCancelled: () -> Bool) throws -> SocketTCPByteStream {
        let remote: sockaddr_in
        do { remote = try BSDSocket.resolveIPv4(host, port: port) } catch { throw TransportError.failed("\(error)") }
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { throw TransportError.failed("socket: \(errno)") }
        BSDSocket.setInt(s, SOL_SOCKET, SO_NOSIGPIPE, 1)
        BSDSocket.setInt(s, IPPROTO_TCP, TCP_NODELAY, 1)
        do {
            try BSDSocket.bind(s, BSDSocket.local(localAddress, port: 0))
        } catch {
            Darwin.close(s)
            throw TransportError.failed("\(error)")
        }
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        if BSDSocket.connect(s, remote) != 0 {
            guard errno == EINPROGRESS else {
                let e = errno; Darwin.close(s)
                throw TransportError.failed("connect: \(String(cString: strerror(e)))")
            }
            // Poll in short slices so cancellation is noticed; EINTR retries.
            let deadline = ContinuousClock.now + timeout
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            while true {
                if isCancelled() { Darwin.close(s); throw CancellationError() }
                let left = deadline - ContinuousClock.now
                if left <= .zero { Darwin.close(s); throw TransportError.timeout }
                let ms = Int32(min(100, max(1, Double(left.components.seconds) * 1000
                                                + Double(left.components.attoseconds) / 1e15)))
                pfd.revents = 0
                let rc = poll(&pfd, 1, ms)
                if rc == 0 { continue }
                if rc < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    Darwin.close(s)
                    throw TransportError.failed("poll: \(String(cString: strerror(e)))")
                }
                break
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 {
                Darwin.close(s)
                throw TransportError.failed("connect: \(String(cString: strerror(err)))")
            }
        }
        _ = fcntl(s, F_SETFL, flags)   // back to blocking for the read/write queues
        Log.control.info("tcp pinned local=\(BSDSocket.localName(s)) remote=\(BSDSocket.describe(remote))")
        return SocketTCPByteStream(fd: s)
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else { throw TransportError.failed("negative read length") }
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count { out.append(try await receive(max: count - out.count)) }
        return out
    }

    func readSome() async throws -> Data { try await receive(max: 64 * 1024) }

    /// A read cancelled by its task throws CancellationError (ByteStream contract).
    private func receive(max: Int) async throws -> Data {
        do {
            return try await receiveRaw(max: max)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func receiveRaw(max: Int) async throws -> Data {
        try Task.checkCancellation()
        let fd = fd
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                readQueue.async { [self] in
                    if isClosed { cont.resume(throwing: TransportError.closed); return }
                    var buf = [UInt8](repeating: 0, count: Swift.max(max, 1))
                    let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                    if n > 0 { cont.resume(returning: Data(buf[0..<n])); return }
                    if n == 0 || isClosed { cont.resume(throwing: TransportError.closed); return }
                    cont.resume(throwing: TransportError.failed("recv: \(String(cString: strerror(errno)))"))
                }
            }
        } onCancel: {
            close()
        }
    }

    func write(_ data: Data) async throws {
        let fd = fd
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                var off = 0
                while off < data.count {
                    if isClosed { cont.resume(throwing: TransportError.closed); return }
                    let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + off, data.count - off, 0) }
                    if n < 0 {
                        if errno == EINTR { continue }
                        let e = errno
                        cont.resume(throwing: isClosed ? TransportError.closed
                                                       : TransportError.failed("send: \(String(cString: strerror(e)))"))
                        return
                    }
                    off += n
                }
                cont.resume(returning: ())
            }
        }
    }

    func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        if first { shutdown(fd, SHUT_RDWR) }   // unblocks a pending recv; the fd closes in deinit
    }
}

private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
#endif
