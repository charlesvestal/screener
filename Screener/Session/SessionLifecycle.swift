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
import Darwin
import Foundation

enum UserFacingError {
    enum Kind: Equatable, Sendable {
        /// The established connection went away (ECONNABORTED, ENOTCONN, ...):
        /// typically iOS suspended us; handled by reconnecting.
        case connectionLost
        /// Nobody is listening / no route (ECONNREFUSED, EHOSTUNREACH, ...).
        case unreachable
        case timeout
        case authRejected
        case localNetwork
        case other
    }

    static let lostMessage = "The connection to the Mac was lost."
    static let unreachableMessage = "Screen Sharing isn't on, or this Mac isn't reachable."
    static let timeoutMessage = "The Mac didn't respond."
    static let authRejectedMessage = "Wrong username or password."
    static let genericMessage = "Couldn't connect to the Mac."

    static func kind(ofErrno e: Int32) -> Kind {
        switch e {
        case ECONNABORTED, ENOTCONN, ECONNRESET, EPIPE, ENETRESET: return .connectionLost
        case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL: return .unreachable
        case ETIMEDOUT: return .timeout
        case EPERM, EACCES: return .localNetwork
        default: return .other
        }
    }

    static func kind(of error: Error) -> Kind {
        switch error {
        case let e as TransportError:
            switch e {
            case .timeout: return .timeout
            case .posix(let errno): return kind(ofErrno: errno)
            case .closed, .failed: return .other
            }
        case let e as ControlSessionError:
            if case .timeout = e { return .timeout }
            return .other
        case let e as AuthError:
            if case .rejected = e { return .authRejected }
            return .other
        case let e as MediaTransportError:
            switch e {
            case .channelFailed: return .connectionLost
            case .localNetworkBlocked: return .localNetwork
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
        case .timeout: return timeoutMessage
        case .authRejected: return authRejectedMessage
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
}
