import XCTest
@testable import Screener

final class UserFacingErrorTests: XCTestCase {
    func testCommonErrorsMapToFriendlyText() {
        let cases: [(Error, String)] = [
            (TransportError.posix(ECONNREFUSED), "Screen Sharing isn't on, or this Mac isn't reachable."),
            (TransportError.posix(EHOSTUNREACH), "Screen Sharing isn't on, or this Mac isn't reachable."),
            (TransportError.timeout, "The Mac didn't respond."),
            (ControlSessionError.timeout(step: "auth"), "The Mac didn't respond."),
            (TransportError.posix(ETIMEDOUT), "The Mac didn't respond."),
            (AuthError.rejected(reason: nil), "Wrong username or password."),
            (AuthError.rejected(reason: "bad"), "Wrong username or password."),
            (TransportError.posix(ECONNABORTED), "The connection to the Mac was lost."),
            (TransportError.posix(ENOTCONN), "The connection to the Mac was lost."),
            (MediaTransportError.channelFailed("receive: Network is down (50)"), "The connection to the Mac was lost."),
            (MediaTransportError.localNetworkBlocked(errno: EPERM),
             "Screener needs Local Network access — check Settings › Privacy & Security › Local Network."),
            (TransportError.posix(EPERM),
             "Screener needs Local Network access — check Settings › Privacy & Security › Local Network."),
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

    func testKinds() {
        XCTAssertEqual(UserFacingError.kind(of: TransportError.posix(ECONNABORTED)), .connectionLost)
        XCTAssertEqual(UserFacingError.kind(of: TransportError.posix(ECONNREFUSED)), .unreachable)
        XCTAssertEqual(UserFacingError.kind(of: AuthError.rejected(reason: nil)), .authRejected)
        XCTAssertEqual(UserFacingError.kind(of: ControlSessionError.noRekey), .other)
        XCTAssertEqual(UserFacingError.message(for: ControlSessionError.noRekey),
                       ControlSessionError.noRekey.localizedDescription)
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

    func testOtherForegroundFailuresAreShown() {
        var p = LifecyclePolicy()
        XCTAssertEqual(p.sessionFailed(kind: .authRejected, wasConnected: false, canReconnect: true), .none)
        XCTAssertEqual(p.sessionFailed(kind: .unreachable, wasConnected: true, canReconnect: true), .none)
        XCTAssertEqual(p.sessionFailed(kind: .connectionLost, wasConnected: false, canReconnect: true), .none,
                       "a connect that never got up is not auto-retried")
    }
}
