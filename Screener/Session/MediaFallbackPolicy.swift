// When an HP session gives up on the UDP media stream and falls back to the
// TCP framebuffer path (Task 19; RFC §11 R-C10, §12). Pure, so it is
// unit-tested; SessionCoordinator acts on its decisions.
//
// Triggers:
//   * no authenticated video: the start burst (MediaTransport.burstOutcome,
//     judged ~2.3 s after the keys from the 0x1c answer are installed, so
//     within 3 s of the answer) is starved. With NO authenticated video
//     packet at all, UDP is most likely blocked (firewall, VPN, Local
//     Network) and a fresh handshake can't help: fall back at once. With a
//     few packets (the stream started and stalled) the reference's
//     fresh-handshake retry (_handshake_with_reconnect) is kept, and the
//     last attempt falls back instead of failing the session;
//   * media negotiation failure (the 0x1c answer never carried a canvas);
//   * `decoderFailureLimit` hard decoder failures (rebuilds / output-mode
//     fallbacks, not concealment errors) within `decoderFailureWindow`.
// Once fallen back nothing else triggers (for the rest of the connection).
import Foundation

struct MediaFallbackPolicy: Sendable, Equatable {
    enum Reason: Equatable, Sendable, CustomStringConvertible {
        case noVideo(packets: Int)
        case negotiationFailed
        case decoderFailures(Int)

        var description: String {
            switch self {
            case .noVideo(let n): "no authenticated video (\(n) packet(s)) after the media answer"
            case .negotiationFailed: "media negotiation failed"
            case .decoderFailures(let n): "\(n) decoder failures in a row"
            }
        }
    }

    enum Decision: Equatable, Sendable {
        /// Nothing to do (media is fine, or already fallen back).
        case stay
        /// A fresh HP handshake on the same UDP sockets.
        case retryHandshake
        /// Switch this connection to the TCP framebuffer path.
        case fallBack(Reason)
    }

    var decoderFailureLimit = 3
    var decoderFailureWindow: Duration = .seconds(10)
    private(set) var isFallenBack = false
    private var failures: [ContinuousClock.Instant] = []

    /// The start burst of HP handshake `attempt` (1-based) of `attempts` was
    /// starved with `packets` authenticated video packets.
    mutating func burstStarved(packets: Int, attempt: Int, attempts: Int) -> Decision {
        guard !isFallenBack else { return .stay }
        if packets == 0 || attempt >= attempts { return fall(.noVideo(packets: packets)) }
        return .retryHandshake
    }

    mutating func negotiationFailed() -> Decision {
        guard !isFallenBack else { return .stay }
        return fall(.negotiationFailed)
    }

    /// A hard decoder failure at `now`.
    mutating func decoderFailed(at now: ContinuousClock.Instant) -> Decision {
        guard !isFallenBack else { return .stay }
        failures.append(now)
        failures.removeAll { now - $0 > decoderFailureWindow }
        guard failures.count >= decoderFailureLimit else { return .stay }
        return fall(.decoderFailures(failures.count))
    }

    /// A new connection: HP again.
    mutating func reset() {
        isFallenBack = false
        failures = []
    }

    private mutating func fall(_ r: Reason) -> Decision {
        isFallenBack = true
        failures = []
        return .fallBack(r)
    }
}

/// The fallback's UI texts.
enum FallbackText {
    static let badge = "Reduced performance"
    static let toast = "Reduced performance: High Performance video isn't available"
}
