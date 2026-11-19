import XCTest

/// The control menu scrolls when a drag starts on one of its keys (the
/// special keys used to claim every touch with a zero-distance drag gesture).
/// Uses the DEBUG menu preview (`-previewControlMenu`): no Mac involved.
final class ControlMenuScrollUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testADragStartingOnAKeyScrollsTheMenu() throws {
        // iPhone: the menu is a bottom sheet whose content scrolls at the medium detent.
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the iPad panel fits without scrolling")
        let app = XCUIApplication()
        app.launchArguments += ["-previewControlMenu", "YES", "-previewMenuExpanded", "YES"]
        app.launch()

        let escape = app.buttons["Escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 10))
        sleep(1)                                            // the sheet settles
        let before = escape.frame
        let start = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)),
                    withVelocity: .default, thenHoldForDuration: 0.3)
        let after = escape.frame
        XCTAssertLessThan(after.minY, before.minY - 60, "the menu scrolled (was \(before), now \(after))")
    }

    /// Keys still type: a tap is one Escape down + up; a hold repeats, then
    /// goes up on release. (PreviewKeyLog: "↓ff1b ↑ff1b".)
    @MainActor
    func testKeysStillTypeOnTapAndRepeatWhileHeld() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-previewControlMenu", "YES", "-previewMenuExpanded", "YES"]
        app.launch()
        let escape = app.buttons["Escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 10))
        sleep(1)
        let log = app.staticTexts["previewKeyLog"]

        escape.tap()
        XCTAssertTrue(waitFor(log, toContain: "↓ff1b ↑ff1b"), log.label)

        escape.press(forDuration: 1.5)
        let downs = log.label.components(separatedBy: "↓ff1b").count - 1
        XCTAssertGreaterThanOrEqual(downs, 3, "held key repeats: \(log.label)")
        // Released at the end (the preview's sticky ⇧ is released after it).
        let escapes = log.label.split(separator: " ").filter { $0.hasSuffix("ff1b") }
        XCTAssertEqual(escapes.last, "↑ff1b", log.label)
    }

    private func waitFor(_ e: XCUIElement, toContain s: String) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", s)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: 3) == .completed
    }
}
