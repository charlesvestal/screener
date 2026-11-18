import XCTest
@testable import Screener

final class UserFacingErrorTests: XCTestCase {
    func testCommonErrorsMapToFriendlyText() {
        let cases: [(Error, String)] = [
            (TransportError.posix(ECONNREFUSED), "Screen Sharing isn't on, or this Mac isn't reachable."),
            (TransportError.timeout, UserFacingError.noRouteMessage),
            (ControlSessionError.timeout(step: "connect"), UserFacingError.noRouteMessage),
            (ControlSessionError.timeout(step: "auth"), "The Mac didn't respond."),
            (TransportError.posix(ETIMEDOUT), UserFacingError.noRouteMessage),
            (AuthError.rejected(reason: nil), "Wrong username or password."),
            (AuthError.rejected(reason: nil), "Wrong username or password."),
            (AuthError.rejected(reason: "bad"), "Wrong username or password. Message from the Mac: “bad”"),
            (TransportError.posix(ECONNABORTED), "The connection to the Mac was lost."),
            (TransportError.posix(ECONNRESET), "The Mac ended the session."),
            (TransportError.posix(EPIPE), "The Mac ended the session."),
            (TransportError.posix(ENOTCONN), "The connection to the Mac was lost."),
            (MediaTransportError.channelFailed("receive: Network is down (50)"), "The connection to the Mac was lost."),
            (MediaTransportError.localNetworkBlocked(errno: EPERM),
             "Screener needs Local Network access — check Settings › Privacy & Security › Local Network."),
            (TransportError.posix(EPERM),
             "Screener needs Local Network access — check Settings › Privacy & Security › Local Network."),
            (TransportError.posix(EACCES), MediaTransportError.localNetworkMessage),
            (MediaTransportError.localNetworkBlocked(errno: EACCES), MediaTransportError.localNetworkMessage),
            (IPv4Resolver.Failure.timedOut(host: "mac.local"), "Couldn't look up mac.local."),
            (TransportError.failed("POSIXErrorCode(rawValue: 53): Software caused connection abort"),
             "Couldn't connect to the Mac."),
            (TransportError.posix(EIO), "Couldn't connect to the Mac."),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(UserFacingError.message(for: error), expected, "\(error)")
        }
    }

    /// The bug from the first iPad run: no message may carry errno / NWError text.
    func testNoMessageShowsRawPOSIXText() {
        let errors: [Error] = [TransportError.posix(53), TransportError.posix(61), TransportError.posix(EIO),
                               TransportError.failed("POSIXErrorCode(rawValue: 53): Software caused connection abort"),
                               MediaTransportError.channelFailed("udp audio: send: Broken pipe (32)"),
                               CancellationError(), TransportError.closed]
        for e in errors {
            let m = UserFacingError.message(for: e)
            XCTAssertFalse(m.contains("POSIX") || m.contains("rawValue") || m.contains("(32)") || m.contains("(53)"), m)
        }
    }

    /// Only a real privacy denial is "Local Network"; no route / no answer
    /// is "Can't reach this Mac" (TCP and UDP alike).
    func testRoutingErrorsAndTCPTimeoutSayTheMacCantBeReached() {
        let reach = "Can't reach this Mac — check it's awake and on this network."
        XCTAssertEqual(UserFacingError.noRouteMessage, reach)
        for e in [EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN] {
            XCTAssertEqual(UserFacingError.message(for: TransportError.posix(e)), reach, "tcp errno \(e)")
            XCTAssertEqual(UserFacingError.message(for: MediaTransportError.localNetworkBlocked(errno: e)), reach,
                           "udp errno \(e)")
            XCTAssertNotEqual(UserFacingError.kind(of: TransportError.posix(e)), .localNetwork)
        }
        XCTAssertEqual(UserFacingError.message(for: TransportError.timeout), reach)
        XCTAssertEqual(UserFacingError.message(for: ControlSessionError.timeout(step: "connect")), reach)
        XCTAssertEqual(UserFacingError.message(for: MediaTransportError.localNetworkBlocked(errno: EPERM)),
                       "Screener needs Local Network access — check Settings › Privacy & Security › Local Network.")
        XCTAssertEqual(UserFacingError.message(for: TransportError.posix(EPERM)), MediaTransportError.localNetworkMessage)
    }

    /// A TCP connect stuck in `.waiting`: Local Network denied fails at once
    /// (as EPERM → the Settings hint); routing waits keep waiting.
    func testTCPWaitingVerdict() {
        XCTAssertEqual(TCPByteStream.waitingVerdict(.posix(.ENETDOWN), unsatisfiedReason: .localNetworkDenied),
                       .posix(EPERM))
        XCTAssertEqual(TCPByteStream.waitingVerdict(.posix(.ECONNREFUSED), unsatisfiedReason: nil), .posix(ECONNREFUSED))
        XCTAssertNil(TCPByteStream.waitingVerdict(.posix(.EHOSTUNREACH), unsatisfiedReason: nil))
        XCTAssertNil(TCPByteStream.waitingVerdict(.posix(.ENETUNREACH), unsatisfiedReason: .notAvailable))
        XCTAssertEqual(UserFacingError.message(for: TCPByteStream.waitingVerdict(.posix(.ENETDOWN),
                                                                               unsatisfiedReason: .localNetworkDenied)!),
                       MediaTransportError.localNetworkMessage)
    }

    func testKinds() {
        XCTAssertEqual(UserFacingError.kind(of: TransportError.posix(ECONNABORTED)), .connectionLost)
        XCTAssertEqual(UserFacingError.kind(of: TransportError.posix(ECONNREFUSED)), .unreachable)
        XCTAssertEqual(UserFacingError.kind(of: TransportError.posix(EHOSTUNREACH)), .noRoute)
        XCTAssertEqual(UserFacingError.kind(of: TransportError.posix(ECONNRESET)), .peerEnded)
        XCTAssertEqual(UserFacingError.kind(of: AuthError.rejected(reason: nil)), .authRejected)
        XCTAssertEqual(UserFacingError.kind(of: ControlSessionError.noRekey), .other)
        XCTAssertEqual(UserFacingError.message(for: ControlSessionError.noRekey),
                       ControlSessionError.noRekey.localizedDescription)
    }
}

final class PrivacyCoverPolicyTests: XCTestCase {
    func testBackgroundShowsTheCover() {
        var p = PrivacyCoverPolicy()
        XCTAssertFalse(p.showCover)
        XCTAssertTrue(p.phaseChanged(to: .background))
        XCTAssertTrue(p.showCover)
    }

    /// The e0785df bug: every non-`.active` phase (including `.inactive`)
    /// blanked the screen, hiding the session during Split View focus
    /// changes and system banners. Only `.background` may cover now.
    func testInactiveNeverShowsTheCover() {
        var p = PrivacyCoverPolicy()
        XCTAssertFalse(p.phaseChanged(to: .inactive))
        XCTAssertFalse(p.showCover)

        _ = p.phaseChanged(to: .background)
        // Returning via .inactive (the normal foreground path) still hides it.
        XCTAssertFalse(p.phaseChanged(to: .inactive))
        XCTAssertFalse(p.showCover)
    }

    func testActiveAlwaysHidesTheCover() {
        var p = PrivacyCoverPolicy()
        _ = p.phaseChanged(to: .background)
        XCTAssertFalse(p.phaseChanged(to: .active))
        XCTAssertFalse(p.showCover)
    }

    /// background → inactive → active (the normal return-to-foreground
    /// sequence): covered only for the middle (background) phase.
    func testFullBackgroundAndForegroundCycle() {
        var p = PrivacyCoverPolicy()
        XCTAssertTrue(p.phaseChanged(to: .background))
        XCTAssertFalse(p.phaseChanged(to: .inactive))
        XCTAssertFalse(p.phaseChanged(to: .active))
    }

    /// active → inactive → active (Split View / system banner, no actual
    /// backgrounding): never covered.
    func testInactiveWithoutBackgroundingIsNeverCovered() {
        var p = PrivacyCoverPolicy()
        XCTAssertFalse(p.phaseChanged(to: .active))
        XCTAssertFalse(p.phaseChanged(to: .inactive))
        XCTAssertFalse(p.phaseChanged(to: .active))
    }
}

final class LifecyclePolicyTests: XCTestCase {
    func testBackgroundWithASessionSuspendsAndActiveReconnects() {
        var p = LifecyclePolicy()
        XCTAssertEqual(p.didEnterBackground(session: .connected), .suspend)
        XCTAssertFalse(p.isForeground)
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .reconnect)
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .none, "only once")
    }

    func testAConnectInProgressIsSuspendedToo() {
        var p = LifecyclePolicy()
        XCTAssertEqual(p.didEnterBackground(session: .connecting), .suspend)
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .reconnect)
    }

    func testNoSessionNothingToDo() {
        var p = LifecyclePolicy()
        XCTAssertEqual(p.didEnterBackground(session: .none), .none)
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .none)
    }

    func testUserDisconnectWhileBackgroundedCancelsTheReconnect() {
        var p = LifecyclePolicy()
        _ = p.didEnterBackground(session: .connected)
        p.userDisconnected()
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .none)
    }

    func testWithoutCredentialsThereIsNoReconnect() {
        var p = LifecyclePolicy()
        _ = p.didEnterBackground(session: .connected)
        XCTAssertEqual(p.didBecomeActive(canReconnect: false), .none)
    }

    /// iOS aborted the sockets (ECONNABORTED) while we were away: suspend
    /// quietly, reconnect on activation; never an error.
    func testAFailureWhileBackgroundedSuspends() {
        var p = LifecyclePolicy()
        _ = p.didEnterBackground(session: .none)
        XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: true, canReconnect: true), .suspend)
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .reconnect)
    }

    func testALostConnectionInTheForegroundReconnectsAFewTimes() {
        var p = LifecyclePolicy()
        for _ in 0..<LifecyclePolicy.maxAutoReconnects {
            XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: true, canReconnect: true), .reconnect)
        }
        XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: true, canReconnect: true), .none)
        p.userConnected()
        XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: true, canReconnect: true), .reconnect)
    }

    /// ECONNRESET / EPIPE on TCP while connected: the Mac's user may have
    /// clicked Stop; never auto-reconnected in the foreground.
    func testAPeerResetIsNotReconnected() {
        var p = LifecyclePolicy()
        XCTAssertEqual(p.sessionFailed(kind: .peerEnded, wasConnected: true, canReconnect: true), .none)
    }

    /// A reconnect that came due after the app left the foreground waits for activation.
    func testADeferredReconnectRunsOnActivation() {
        var p = LifecyclePolicy()
        _ = p.didEnterBackground(session: .none)
        p.deferReconnect()
        XCTAssertEqual(p.didBecomeActive(canReconnect: true), .reconnect)
    }

    func testOtherForegroundFailuresAreShown() {
        var p = LifecyclePolicy()
        XCTAssertEqual(p.sessionFailed(kind: .authRejected, wasConnected: false, canReconnect: true), .none)
        XCTAssertEqual(p.sessionFailed(kind: .unreachable, wasConnected: true, canReconnect: true), .none)
        XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: false, canReconnect: true), .none,
                       "a connect that never got up is not auto-retried")
    }
}

final class IPv4ResolverTimeoutTests: XCTestCase {
    func testASlowLookupTimesOut() async {
        do {
            _ = try await IPv4Resolver.resolve("mac.local", timeout: .milliseconds(50)) { _ in
                Thread.sleep(forTimeInterval: 0.5)
                return "192.0.2.1"
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? IPv4Resolver.Failure, .timedOut(host: "mac.local"))
            XCTAssertEqual(UserFacingError.message(for: error), "Couldn't look up mac.local.")
        }
    }

    func testAFastLookupWins() async throws {
        let ip = try await IPv4Resolver.resolve("192.0.2.7", timeout: .seconds(5))
        XCTAssertEqual(ip, "192.0.2.7")
    }
}
