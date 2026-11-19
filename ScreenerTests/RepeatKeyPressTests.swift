import XCTest
@testable import Screener

/// The menu's special keys are plain Buttons (so a drag that starts on one
/// scrolls the menu); RepeatKeyPress turns their press state into key events.
final class RepeatKeyPressTests: XCTestCase {
    func testHoldGoesDownOnPressAndUpOnRelease() {
        var p = RepeatKeyPress()
        XCTAssertEqual(p.pressedChanged(true), [.down])
        XCTAssertEqual(p.pressedChanged(true), [])          // no double down
        XCTAssertEqual(p.pressedChanged(false), [.up])
        XCTAssertEqual(p.tapped(), [])                      // the release's action: already sent
        p.pressFinished()
        XCTAssertEqual(p.pressedChanged(true), [.down])     // the next press works
    }

    func testActionBeforeTheReleaseSendsNothingExtra() {
        var p = RepeatKeyPress()
        _ = p.pressedChanged(true)
        XCTAssertEqual(p.tapped(), [])
        XCTAssertEqual(p.pressedChanged(false), [.up])
    }

    func testATapTooQuickToShowPressedStillSendsOneKey() {
        var p = RepeatKeyPress()
        XCTAssertEqual(p.tapped(), [.down, .up])
        XCTAssertFalse(p.isDown)
    }

    func testAScrollCancelsThePressWithoutAnAction() {
        var p = RepeatKeyPress()
        XCTAssertEqual(p.pressedChanged(true), [.down])
        XCTAssertEqual(p.pressedChanged(false), [.up])      // the scroll took the touch: no action
        p.pressFinished()
        XCTAssertEqual(p.tapped(), [.down, .up])            // a later quick tap still types
    }
}
