// What the user sees when a session fails, and what the app does when it
// goes to the background and comes back (both pure, so they are unit-tested).
//
// First iPad run (2026-11-14): after backgrounding, iOS aborted the sockets
// and the UI showed "POSIXErrorCode(rawValue: 53): Software caused connection
// abort". Now:
//   * background with a session (or a connect) in progress → close it
//     gracefully at once (the Mac's display privacy ends with it), keep the
//     host + credentials in memory;
//   * active again → reconnect automatically; the session view stays up with
//     "Reconnecting…" over the last picture;
//   * a connection that is aborted while connected and in the foreground is
//     reconnected too (a few times), and failures never show raw errno text.
//
// Review fixes (2026-11-14):
//   * the Local Network text is shown ONLY when iOS actually denied access
//     (EPERM / EACCES, or a TCP wait whose path reports .localNetworkDenied,
//     which TCPByteStream turns into EPERM). No route (EHOSTUNREACH,
//     EHOSTDOWN, ENETUNREACH, ENETDOWN) and TCP connect timeouts say
//     "Can't reach this Mac" instead;
//   * ECONNRESET / EPIPE on the TCP control channel is `.peerEnded`: most
//     likely the Mac's user clicked Stop (or the Mac dropped us), so it is NOT
//     auto-reconnected. NEEDS LIVE CONFIRMATION: verify on a real Mac that
//     "Stop sharing" on the host really surfaces as a reset (and not as a
//     clean FIN, which is TransportError.closed).
import Darwin
import Foundation

enum UserFacingError {
    enum Kind: Equatable, Sendable {
        /// The established connection went away (ECONNABORTED, ENOTCONN, ...):
        /// typically iOS suspended us; handled by reconnecting.
        case connectionLost
        /// Nobody is listening (ECONNREFUSED): Screen Sharing is off.
        case unreachable
        /// No route to the Mac, or the TCP connect timed out: asleep / elsewhere.
        case noRoute
        /// The Mac reset the control connection (ECONNRESET / EPIPE on TCP):
        /// probably its user stopped the session; never auto-reconnected.
        case peerEnded
        case timeout
        case authRejected
        case localNetwork
        case other
    }

    static let lostMessage = "The connection to the Mac was lost."
    static let unreachableMessage = "Screen Sharing isn't on, or this Mac isn't reachable."
    static let noRouteMessage = "Can't reach this Mac — check it's awake and on this network."
    static let peerEndedMessage = "The Mac ended the session."
    static let timeoutMessage = "The Mac didn't respond."
    static let authRejectedMessage = "Wrong username or password."
    static let genericMessage = "Couldn't connect to the Mac."

    static func kind(ofErrno e: Int32) -> Kind {
        switch e {
        case ECONNABORTED, ENOTCONN, ENETRESET: return .connectionLost
        case ECONNRESET, EPIPE: return .peerEnded
        case ECONNREFUSED, EADDRNOTAVAIL: return .unreachable
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, ETIMEDOUT: return .noRoute
        case EPERM, EACCES: return .localNetwork
        default: return .other
        }
    }

    static func kind(of error: Error) -> Kind {
        switch error {
        case let e as TransportError:
            switch e {
            case .timeout: return .noRoute   // only the TCP connect has a transport timeout
            case .posix(let errno): return kind(ofErrno: errno)
            case .closed, .failed: return .other
            }
        case let e as ControlSessionError:
            if case .timeout(let step) = e { return step == "connect" ? .noRoute : .timeout }
            return .other
        case let e as AuthError:
            if case .rejected = e { return .authRejected }
            return .other
        case let e as MediaTransportError:
            switch e {
            case .channelFailed: return .connectionLost
            // UDP sends blocked before the stream: only a privacy denial is
            // Local Network; a routing error means the Mac isn't reachable.
            case .localNetworkBlocked(let e): return e == EPERM || e == EACCES ? .localNetwork : .noRoute
            case .bindFailed: return .other
            }
        default:
            return .other
        }
    }

    /// A message for the UI: never raw errno / NWError text.
    static func message(for error: Error) -> String {
        switch kind(of: error) {
        case .connectionLost: return lostMessage
        case .unreachable: return unreachableMessage
        case .noRoute: return noRouteMessage
        case .peerEnded: return peerEndedMessage
        case .timeout: return timeoutMessage
        case .authRejected:
            // The Mac's own reason, if it sent one: sanitized and labelled (L3).
            if case AuthError.rejected(let reason) = error, let from = ServerText.labelled(reason) {
                return authRejectedMessage + " " + from
            }
            return authRejectedMessage
        case .localNetwork: return MediaTransportError.localNetworkMessage
        case .other: break
        }
        switch error {
        case let e as MediaTransportError: return e.localizedDescription
        case let e as IPv4Resolver.Failure: return e.localizedDescription
        case TransportError.closed: return "The Mac closed the connection."
        case is TransportError: return genericMessage   // .failed(NWError text), other errnos
        case is CancellationError: return ControlSessionError.closed.localizedDescription
        case is ControlSessionError, is AuthError, is RFBHandshakeError, is RecordLayerError:
            return ControlSession.describe(error)
        default:
            return genericMessage
        }
    }
}

/// The privacy cover shown over the remote screen so iOS's own snapshot
/// machinery never persists a picture of the Mac's screen (the app switcher
/// thumbnail, the Home Screen icon preview). A pure function of scene-phase
/// transitions, so the policy is unit-tested without a live scene.
///
/// `.background` is the only phase in which UIKit captures and keeps a
/// snapshot of the scene — so it's the only phase that needs covering.
///
/// `.inactive` deliberately does NOT cover: that was the bug in e0785df.
/// The scene turns `.inactive` for a Split View sibling becoming key, a
/// system banner ("Allow Paste"), Control Center, and other moments the
/// user is still sitting right next to the Mac and working beside the
/// session — covering there blanked the screen while they were using it.
///
/// Trade-off (documented, not verified live — no device runs for this fix):
/// on iPadOS, a quick swipe-up *peek* at the app switcher, without actually
/// switching away, can snapshot the scene while it is merely `.inactive` —
/// the scene never reaches `.background` if the user lets go and returns to
/// Screener. From scene-phase alone (and from
/// `UIApplication.shared.applicationState`, which mirrors the same
/// single-scene phase here, since Screener has one scene) that `.inactive`
/// is indistinguishable from an ordinary Split View focus change, which must
/// stay uncovered. We accept the small risk of one live frame in that one
/// gesture rather than reintroduce blanking on every ordinary `.inactive`.
struct PrivacyCoverPolicy: Equatable, Sendable {
    /// Mirrors SwiftUI.ScenePhase's cases without requiring SwiftUI, so the
    /// policy — and its tests — don't need to import SwiftUI or touch a
    /// live scene.
    enum Phase: Equatable, Sendable { case active, inactive, background }

    private(set) var showCover = false

    /// Call on every scene-phase change; returns the (also stored) new
    /// `showCover` value.
    @discardableResult
    mutating func phaseChanged(to phase: Phase) -> Bool {
        showCover = (phase == .background)
        return showCover
    }
}

/// Background / foreground and auto-reconnect decisions.
struct LifecyclePolicy: Equatable, Sendable {
    enum SessionStatus: Equatable, Sendable { case none, connecting, connected }
    enum Action: Equatable, Sendable {
        case none
        /// Close the session now; reconnect when the app is active again.
        case suspend
        /// Reconnect now with the stored request.
        case reconnect
    }

    /// Reconnects after a lost connection (foreground) before giving up and
    /// showing the error; reset by a user connect or a return to the foreground.
    static let maxAutoReconnects = 3

    private(set) var isForeground = true
    private(set) var pendingReconnect = false
    private(set) var autoReconnects = 0

    mutating func didEnterBackground(session: SessionStatus) -> Action {
        isForeground = false
        guard session != .none else { return .none }
        pendingReconnect = true
        return .suspend
    }

    mutating func didBecomeActive(canReconnect: Bool) -> Action {
        isForeground = true
        autoReconnects = 0
        guard pendingReconnect else { return .none }
        pendingReconnect = false
        return canReconnect ? .reconnect : .none
    }

    /// A session ended with an error of `kind`.
    mutating func sessionFailed(kind: UserFacingError.Kind, wasConnected: Bool, canReconnect: Bool) -> Action {
        guard canReconnect else { return .none }
        if !isForeground {
            // Whatever iOS did to the sockets while we were away: come back quietly.
            pendingReconnect = true
            return .suspend
        }
        // .peerEnded is deliberately not here: the Mac's user may have
        // clicked Stop, and reconnecting would restart the session against
        // their will.
        if kind == .connectionLost, wasConnected, autoReconnects < Self.maxAutoReconnects {
            autoReconnects += 1
            return .reconnect
        }
        return .none
    }

    mutating func userConnected() {
        autoReconnects = 0
        pendingReconnect = false
    }

    mutating func userDisconnected() { pendingReconnect = false }

    /// A reconnect was due but the app is no longer in the foreground:
    /// do it on the next `didBecomeActive` instead.
    mutating func deferReconnect() { pendingReconnect = true }
}
