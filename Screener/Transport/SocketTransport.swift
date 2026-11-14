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

    static func describe(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        return "\(String(cString: buf)):\(UInt16(bigEndian: a.sin_port))"
    }

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

// MARK: - UDP

/// One media flow as a UDP socket bound to a fixed local port (SO_REUSEADDR,
/// 4 MiB SO_RCVBUF like `_bind_udp`) and connected to the server's matching
/// port. Connected UDP reports ICMP port-unreachable as ECONNREFUSED on the
/// next call; that is expected while punches race the server's bind and is
/// only counted.
final class SocketDatagramChannel: DatagramChannel, @unchecked Sendable {
    private let label: String
    private let remoteHost: String
    private let remotePort: UInt16
    private let localHost: String?
    private let localPort: UInt16
    private let queue: DispatchQueue
    // `lock` guards fd / source / closed / handlers / error counters.
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var closed = false
    private var onReceive: (@Sendable (Data) -> Void)?
    private var onEvent: (@Sendable (String) -> Void)?
    private var sendErrors = 0, receiveErrors = 0

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

    func start(onReceive: @escaping @Sendable (Data) -> Void, onEvent: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.onReceive = onReceive
        self.onEvent = onEvent
        lock.unlock()
        // Bind synchronously so the port is ours before the handshake starts.
        do {
            try open()
        } catch {
            onEvent("open failed: \(error)")
        }
    }

    private func open() throws {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw BSDSocket.Failure.syscall("socket", errno) }
        BSDSocket.setInt(s, SOL_SOCKET, SO_REUSEADDR, 1)
        BSDSocket.setInt(s, SOL_SOCKET, SO_RCVBUF, 4 * 1024 * 1024)
        BSDSocket.setInt(s, SOL_SOCKET, SO_NOSIGPIPE, 1)
        do {
            try BSDSocket.bind(s, BSDSocket.local(localHost, port: localPort))
            let remote = try BSDSocket.resolveIPv4(remoteHost, port: remotePort)
            if BSDSocket.connect(s, remote) != 0 { throw BSDSocket.Failure.syscall("connect", errno) }
            _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
            emit("bound local=\(BSDSocket.localName(s)) remote=\(BSDSocket.describe(remote))")
        } catch {
            Darwin.close(s)
            throw error
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.drain(s) }
        src.setCancelHandler { Darwin.close(s) }
        lock.lock()
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

    /// session._video_drain_loop: empty the kernel buffer as fast as possible.
    private func drain(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                lock.lock(); let cb = onReceive; lock.unlock()
                cb?(Data(buf[0..<n]))
                continue
            }
            if n < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return }
                lock.lock(); receiveErrors += 1; let k = receiveErrors; lock.unlock()
                if k <= 5 || k % 100 == 0 { emit("receive error #\(k): \(String(cString: strerror(e)))") }
                if e == ECONNREFUSED { continue }   // ICMP from an early punch; keep draining
                return
            }
            return
        }
    }

    func send(_ datagram: Data) {
        lock.lock()
        let s = closed ? -1 : fd
        lock.unlock()
        guard s >= 0 else { return }
        let n = datagram.withUnsafeBytes { Darwin.send(s, $0.baseAddress, $0.count, 0) }
        if n < 0 {
            let e = errno
            lock.lock(); sendErrors += 1; let k = sendErrors; lock.unlock()
            if k <= 5 || k % 100 == 0 { emit("send error #\(k): \(String(cString: strerror(e)))") }
        }
    }

    func cancel() {
        lock.lock()
        closed = true
        let src = source
        source = nil
        fd = -1
        onReceive = nil
        lock.unlock()
        src?.cancel()   // the cancel handler closes the fd
    }

    private func emit(_ msg: String) {
        lock.lock(); let cb = onEvent; lock.unlock()
        cb?(msg)
    }
}

// MARK: - TCP

/// A `ByteStream` over a BSD TCP socket, used when the control connection's
/// source address must be pinned (`ControlSession.Seams.live(localAddress:)`).
/// Same contract as `TCPByteStream`: one reader, many writers; cancelling a
/// pending read closes the stream.
final class SocketTCPByteStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "SocketTCPByteStream.read")
    private let writeQueue = DispatchQueue(label: "SocketTCPByteStream.write")
    private let lock = NSLock()
    private var closed = false

    private init(fd: Int32) { self.fd = fd }

    deinit { Darwin.close(fd) }

    static func connect(host: String, port: UInt16, localAddress: String, timeout: Duration) async throws -> SocketTCPByteStream {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try connectBlocking(host: host, port: port, localAddress: localAddress, timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func connectBlocking(host: String, port: UInt16, localAddress: String,
                                        timeout: Duration) throws -> SocketTCPByteStream {
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
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let ms = Int32(min(Double(Int32.max), (Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18) * 1000))
            let rc = poll(&pfd, 1, ms)
            if rc == 0 { Darwin.close(s); throw TransportError.timeout }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if rc < 0 || err != 0 {
                Darwin.close(s)
                throw TransportError.failed("connect: \(String(cString: strerror(err != 0 ? err : errno)))")
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
