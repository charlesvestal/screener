// Whether a saved Mac is on the network right now, for the host card's dot.
// The only signal is Bonjour (_rfb._tcp): a host is online while its service
// is being advertised. Saved hosts are never probed with a TCP connect —
// every connect to port 5900 is a Screen Sharing session attempt to the Mac,
// which logs it and rate-limits repeated attempts.
import Foundation

enum HostReachability: Equatable, Sendable {
    /// Advertised on Bonjour now (green, pulsing).
    case online
    /// Browsing, and not advertised (grey).
    case offline
    /// Not browsing (e.g. a session is up): nothing is known (grey).
    case unknown

    var isOnline: Bool { self == .online }

    var accessibilityLabel: String {
        switch self {
        case .online: "On this network"
        case .offline: "Not found on this network"
        case .unknown: "Network status unknown"
        }
    }

    static func of(_ saved: SavedHost, discovered: [DiscoveredHost], resolved: [String: String],
                   isBrowsing: Bool) -> HostReachability {
        if HostMatcher.discovered(for: saved, in: discovered, resolved: resolved) != nil { return .online }
        return isBrowsing ? .offline : .unknown
    }
}
