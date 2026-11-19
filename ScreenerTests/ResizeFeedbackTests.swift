import XCTest
@testable import Screener

/// `ResizeFeedback`: the pure part of the "Resizing…" toast + held-frame
/// blur (SessionCoordinator.isResizing). SessionCoordinator drives it with
/// `begin()` on every 0x1d actually sent (DisplayResizer.fire → requestDisplay)
/// and `end()` on the new picture showing or the timeout — this file covers
/// the transitions and the coalescing, without any session/UI involved.
final class ResizeFeedbackTests: XCTestCase {
    func testStartsInactive() {
        XCTAssertFalse(ResizeFeedback().isActive)
    }

    func testBeginActivatesAndReportsStartOfBurst() {
        var feedback = ResizeFeedback()
        XCTAssertTrue(feedback.begin(), "the first begin() in a burst starts it")
        XCTAssertTrue(feedback.isActive)
    }

    func testEndDeactivates() {
        var feedback = ResizeFeedback()
        feedback.begin()
        feedback.end()
        XCTAssertFalse(feedback.isActive)
    }

    /// No flicker on rapid successive resizes: once active, further begin()
    /// calls (a Stage Manager drag firing several debounced 0x1ds) coalesce
    /// — they stay active and report "not a new burst", so the caller knows
    /// not to re-show the toast or restart the blur's fade-in.
    func testRapidSuccessiveResizesCoalesceIntoOneBurst() {
        var feedback = ResizeFeedback()
        XCTAssertTrue(feedback.begin())
        XCTAssertFalse(feedback.begin(), "already active: not a new burst")
        XCTAssertFalse(feedback.begin())
        XCTAssertTrue(feedback.isActive)
    }

    /// Ending, then a fresh resize later, starts a new burst (fires again).
    func testEndThenBeginAgainStartsANewBurst() {
        var feedback = ResizeFeedback()
        feedback.begin()
        feedback.end()
        XCTAssertTrue(feedback.begin(), "a new burst after the previous one ended")
    }

    /// A caller mirroring SessionView's `.onChange(of: model.isResizing)`
    /// toast trigger (fire only on a false→true transition) over a realistic
    /// event stream — several coalesced resizes, then one more burst later —
    /// shows the toast exactly twice, not once per 0x1d.
    func testToastFiresOncePerBurstOverAnEventStream() {
        var feedback = ResizeFeedback()
        var previousActive = false
        var toastCount = 0
        func step(_ event: Bool) {
            if event { feedback.begin() } else { feedback.end() }
            if feedback.isActive, !previousActive { toastCount += 1 }
            previousActive = feedback.isActive
        }
        // Burst 1: three debounced resizes while dragging, then it settles.
        step(true); step(true); step(true); step(false)
        // Burst 2: a single later resize (e.g. a rotation).
        step(true); step(false)
        XCTAssertEqual(toastCount, 2)
    }

    func testRedundantEndIsANoOp() {
        var feedback = ResizeFeedback()
        feedback.end()
        XCTAssertFalse(feedback.isActive)
        feedback.begin()
        feedback.end()
        feedback.end()
        XCTAssertFalse(feedback.isActive)
    }
}
