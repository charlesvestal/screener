// Bonjour discovery of Macs with Screen Sharing on (_rfb._tcp), and the
// resolution of a discovered service to the IPv4 literal the session uses.
//
// IPv4 consistency (IPv4Resolver, SocketTransport.swift): the HP media plane
// is IPv4-only and the Mac sends UDP to the TCP peer address, so TCP and UDP
// must use the SAME IPv4. A service endpoint is therefore never handed to the
// control connection: `BonjourResolver` resolves it to an IPv4 literal first
// (a short IPv4-only NWConnection to the service, reading the path's remote
// endpoint, then cancelled), and that literal goes through
// SessionCoordinator.connect like a typed address.
import Foundation
import Network
import Observation

struct DiscoveredHost: Identifiable, Hashable, Sendable {
    /// The Bonjour service name (the Mac's Sharing name, e.g. "Studio").
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

@MainActor @Observable
final class BonjourBrowser {
    static let serviceType = "_rfb._tcp"

    private(set) var hosts: [DiscoveredHost] = []
    private(set) var isBrowsing = false
    private var browser: NWBrowser?

    #if DEBUG
    /// DemoHosts (screenshots): fixed fake services, no browsing.
    private var demo = false
    func showDemo(_ names: [String]) {
        stop()
        demo = true
        hosts = names.map { DiscoveredHost(name: $0, endpoint: .service(name: $0, type: Self.serviceType,
                                                                         domain: "local.", interface: nil)) }
        isBrowsing = true
    }
    #endif

    /// Starts browsing (the first start triggers the Local Network prompt).
    func start() {
        #if DEBUG
        if demo { return }
        #endif
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.hosts(from: results)
            Task { @MainActor in self?.update(found) }
        }
        b.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): Log.hosts.error("bonjour browse failed: \(error)")
            case .waiting(let error): Log.hosts.info("bonjour browse waiting: \(error)")
            default: break
            }
        }
        b.start(queue: .main)
        browser = b
        isBrowsing = true
        Log.hosts.info("bonjour browse started")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    /// Pull to refresh: a fresh browse (stale services drop out; the ones
    /// still advertised come back with the new browser's first results).
    func restart() {
        #if DEBUG
        if demo { return }
        #endif
        stop()
        hosts = []
        start()
    }

    func host(named name: String) -> DiscoveredHost? {
        hosts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func update(_ found: [DiscoveredHost]) {
        guard browser != nil, found != hosts else { return }
        hosts = found
        Log.hosts.info("bonjour: \(found.count) Mac(s) on the network")
    }

    /// One entry per service name (a Mac seen on two interfaces appears
    /// twice in the results), sorted by name.
    nonisolated static func hosts(from results: Set<NWBrowser.Result>) -> [DiscoveredHost] {
        var byName: [String: DiscoveredHost] = [:]
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            if byName[name] == nil { byName[name] = DiscoveredHost(name: name, endpoint: r.endpoint) }
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Resolution

enum BonjourResolver {
    enum Failure: Error, Equatable, LocalizedError {
        case unreachable(name: String)
        case noIPv4(name: String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let n): return "Couldn't reach \(n) on this network."
            case .noIPv4(let n):
                return "\(n) has no IPv4 address on this network. High Performance screen sharing needs IPv4."
            }
        }
    }

    static let timeout: Duration = .seconds(5)

    /// The IPv4 literal and port of a discovered service: an IPv4-only TCP
    /// connection to the service endpoint, cancelled as soon as it's ready.
    static func resolve(_ host: DiscoveredHost, timeout: Duration = timeout) async throws -> (address: String, port: UInt16) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: host.endpoint, using: params)
        let queue = DispatchQueue(label: "BonjourResolver", qos: .userInitiated)
        let once = OnceFlag()
        let name = host.name
        let result: (String, UInt16) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, UInt16), Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let remote = connection.currentPath?.remoteEndpoint
                        guard once.claim() else { return }
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        if let remote, let r = ipv4HostPort(remote) {
                            cont.resume(returning: r)
                        } else {
                            cont.resume(throwing: Failure.noIPv4(name: name))
                        }
                    case .failed, .cancelled:
                        guard once.claim() else { return }
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        cont.resume(throwing: Failure.unreachable(name: name))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                let nanos = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                    guard once.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    cont.resume(throwing: Failure.unreachable(name: name))
                }
            }
        } onCancel: {
            connection.cancel()
        }
        Log.hosts.info("bonjour resolved \(name) → \(result.0):\(result.1)")
        return (result.0, result.1)
    }

    /// `.hostPort(.ipv4, port)` → ("a.b.c.d", port), without any "%scope" suffix.
    static func ipv4HostPort(_ endpoint: NWEndpoint) -> (String, UInt16)? {
        guard case let .hostPort(host, port) = endpoint, case let .ipv4(addr) = host else { return nil }
        let b = [UInt8](addr.rawValue)
        guard b.count == 4 else { return nil }
        return ("\(b[0]).\(b[1]).\(b[2]).\(b[3])", port.rawValue)
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - Matching discovered ↔ saved

enum HostMatcher {
    /// Letters and digits only, lowercased, without a trailing ".local":
    /// "Alex’s MacBook Pro" and "Alexs-MacBook-Pro.local" both become
    /// "alexsmacbookpro" (the Mac derives its .local name from its
    /// Sharing name that way).
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        while t.hasSuffix(".") { t.removeLast() }
        if t.hasSuffix(".local") { t.removeLast(".local".count) }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func isIPv4Literal(_ s: String) -> Bool { IPv4Address(s) != nil && s.split(separator: ".").count == 4 }

    /// Whether `saved` is the Mac behind the discovered service `name`.
    /// `resolvedIPv4` is the service's IPv4, if it has been resolved.
    static func matches(_ saved: SavedHost, discoveredName name: String, resolvedIPv4: String? = nil) -> Bool {
        if let b = saved.bonjourName, b.caseInsensitiveCompare(name) == .orderedSame { return true }
        let host = saved.host.trimmingCharacters(in: .whitespaces)
        if let ip = resolvedIPv4, host == ip { return true }
        if host.isEmpty || isIPv4Literal(host) { return false }
        let n = normalize(name)
        return !n.isEmpty && normalize(host) == n
    }

    /// The discovered hosts that match no saved host (shown under "On This Network").
    static func unmatched(_ discovered: [DiscoveredHost], saved: [SavedHost],
                          resolved: [String: String] = [:]) -> [DiscoveredHost] {
        discovered.filter { d in
            !saved.contains { matches($0, discoveredName: d.name, resolvedIPv4: resolved[d.name]) }
        }
    }

    /// The saved host that a discovered service belongs to, if any.
    static func savedHost(for d: DiscoveredHost, in saved: [SavedHost], resolved: [String: String] = [:]) -> SavedHost? {
        saved.first { matches($0, discoveredName: d.name, resolvedIPv4: resolved[d.name]) }
    }

    /// The discovered service for a saved host, if it's on the network now.
    static func discovered(for saved: SavedHost, in discovered: [DiscoveredHost],
                           resolved: [String: String] = [:]) -> DiscoveredHost? {
        discovered.first { matches(saved, discoveredName: $0.name, resolvedIPv4: resolved[$0.name]) }
    }
}
