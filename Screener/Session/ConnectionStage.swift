// What the user sees while a session comes up: "Signing in…" →
// "Securing…" → "Starting video…" (a 3-step indicator), derived from the
// connect milestones the coordinator and ControlSession already pass:
//   started            connect / reconnect began (TCP + RFB + SRP auth next)
//   authenticated      ControlSession "M1 auth ok"
//   recordLayerActive  ControlSession: 0x44f rekey, record layer installed
//   mediaAnswered      ControlSession "M2 media answer"
//   streamStarted      SessionCoordinator: start burst arrived (`.connected`)
//   firstFrame         SessionCoordinator: first picture decoded
//   ended              teardown (disconnect, background, failure)
//
// The stage only moves forward within one attempt: milestones hop to the
// main actor on separate tasks, and a starved-burst retry repeats the
// ControlSession ones, so a late or repeated milestone never steps back.
// Only `started` and `ended` reset it; milestones arriving while idle are
// stale (a torn-down session's) and ignored.
import Foundation

enum ConnectionMilestone: Sendable, Equatable {
    case started, authenticated, recordLayerActive, mediaAnswered, streamStarted, firstFrame, ended
}

enum ConnectionStage: Int, Sendable, Comparable, CaseIterable {
    case idle, signingIn, securing, startingVideo, live

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    func advanced(by m: ConnectionMilestone) -> ConnectionStage {
        switch m {
        case .started: return .signingIn
        case .ended: return .idle
        default: break
        }
        guard self != .idle else { return .idle }
        let target: ConnectionStage = switch m {
        case .authenticated: .securing
        case .recordLayerActive, .mediaAnswered, .streamStarted: .startingVideo
        case .firstFrame: .live
        case .started, .ended: self
        }
        return max(self, target)
    }

    static func derive(_ milestones: [ConnectionMilestone], from start: ConnectionStage = .idle) -> ConnectionStage {
        milestones.reduce(start) { $0.advanced(by: $1) }
    }

    /// The three visible steps.
    static let steps: [ConnectionStage] = [.signingIn, .securing, .startingVideo]

    /// 0-based index among `steps` (nil when idle / live).
    var stepIndex: Int? { Self.steps.firstIndex(of: self) }

    var title: String {
        switch self {
        case .idle: "Connecting…"
        case .signingIn: "Signing in…"
        case .securing: "Securing…"
        case .startingVideo: "Starting video…"
        case .live: "Connected"
        }
    }
}
