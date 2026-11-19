import XCTest
@testable import Screener

final class ModifierStateTests: XCTestCase {
    private let cmd: UInt32 = 0xffeb, opt: UInt32 = 0xffe7, ctrl: UInt32 = 0xffe3, shift: UInt32 = 0xffe1

    // MARK: transitions

    func testTapLatchesAndTapAgainLaterClears() {
        var s = ModifierState()
        XCTAssertEqual(s[.command], .off)
        s.tap(.command, at: 0)
        XCTAssertEqual(s[.command], .latched)
        s.tap(.command, at: 1)
        XCTAssertEqual(s[.command], .off)
    }

    func testDoubleTapWithinWindowLocks() {
        var s = ModifierState()
        s.tap(.option, at: 10)
        s.tap(.option, at: 10.25)
        XCTAssertEqual(s[.option], .locked)
        s.tap(.option, at: 10.4)                 // a tap on a locked modifier clears it
        XCTAssertEqual(s[.option], .off)
    }

    func testDoubleTapJustOutsideWindowClears() {
        var s = ModifierState()
        s.tap(.shift, at: 0)
        s.tap(.shift, at: 0.31)
        XCTAssertEqual(s[.shift], .off)
    }

    func testConsumeClearsLatchedKeepsLocked() {
        var s = ModifierState()
        s.tap(.command, at: 0)
        s.tap(.control, at: 0); s.tap(.control, at: 0.1)
        s.tap(.fn, at: 0)
        s.consumeLatched()
        XCTAssertEqual(s[.command], .off)
        XCTAssertEqual(s[.fn], .off)
        XCTAssertEqual(s[.control], .locked)
        s.consumeLatched()
        XCTAssertEqual(s[.control], .locked)
    }

    func testLockedThenRelatchAfterClear() {
        var s = ModifierState()
        s.tap(.command, at: 0); s.tap(.command, at: 0.1)   // locked
        s.tap(.command, at: 5)                             // off
        s.tap(.command, at: 5.1)                           // a fresh tap: latched, not a double-tap of the clearing tap
        XCTAssertEqual(s[.command], .latched)
    }

    func testClearAll() {
        var s = ModifierState()
        s.tap(.command, at: 0); s.tap(.command, at: 0.1)
        s.tap(.shift, at: 0)
        s.clearAll()
        XCTAssertTrue(s.isEmpty)
    }

    // MARK: keysyms

    func testLatchedCommandPlusCExactSequence() {
        var s = ModifierState()
        s.tap(.command, at: 0)
        XCTAssertEqual(s.wrap(keysym: 0x63), [.down(cmd), .down(0x63), .up(0x63), .up(cmd)])
    }

    func testPressedKeysymsOrderAndFnHasNone() {
        var s = ModifierState()
        for m in [StickyModifier.command, .shift, .option, .control, .fn] { s.tap(m, at: 0) }
        XCTAssertEqual(s.pressedKeysyms(), [ctrl, opt, shift, cmd])
        XCTAssertTrue(s.fnActive)
        XCTAssertTrue(s.commandLikeActive)
    }

    func testPhysicalModifiersAreNotPressedTwice() {
        var s = ModifierState()
        s.tap(.command, at: 0); s.tap(.shift, at: 0)
        XCTAssertEqual(s.pressedKeysyms(excluding: [cmd]), [shift])
        XCTAssertEqual(s.wrap(keysym: 0x7a, physical: [cmd]),
                       [.down(shift), .down(0x7a), .up(0x7a), .up(shift)])
    }

    func testClickWrapWithLatchedCommand() {
        var s = ModifierState()
        s.tap(.command, at: 0)
        XCTAssertEqual(s.wrap([.down(0xdead), .up(0xdead)]),
                       [.down(cmd), .down(0xdead), .up(0xdead), .up(cmd)])
    }

    func testNothingActiveWrapsNothing() {
        let s = ModifierState()
        XCTAssertEqual(s.wrap(keysym: 0x61), [.down(0x61), .up(0x61)])
        XCTAssertFalse(s.commandLikeActive)
    }

    // MARK: fn layer

    func testFnRemapsSpecialKeys() {
        XCTAssertEqual(SpecialKey.left.withFn, .home)
        XCTAssertEqual(SpecialKey.right.withFn, .end)
        XCTAssertEqual(SpecialKey.up.withFn, .pageUp)
        XCTAssertEqual(SpecialKey.down.withFn, .pageDown)
        XCTAssertEqual(SpecialKey.backspace.withFn, .forwardDelete)
        XCTAssertEqual(SpecialKey.escape.withFn, .escape)
        XCTAssertEqual(SpecialKey.function(5).withFn, .function(5))
    }

    func testSpecialKeysyms() {
        XCTAssertEqual(SpecialKey.escape.keysym, 0xff1b)
        XCTAssertEqual(SpecialKey.tab.keysym, 0xff09)
        XCTAssertEqual(SpecialKey.backspace.keysym, 0xff08)
        XCTAssertEqual(SpecialKey.forwardDelete.keysym, 0xffff)
        XCTAssertEqual(SpecialKey.left.keysym, 0xff51)
        XCTAssertEqual(SpecialKey.up.keysym, 0xff52)
        XCTAssertEqual(SpecialKey.right.keysym, 0xff53)
        XCTAssertEqual(SpecialKey.down.keysym, 0xff54)
        XCTAssertEqual(SpecialKey.home.keysym, 0xff50)
        XCTAssertEqual(SpecialKey.end.keysym, 0xff57)
        XCTAssertEqual(SpecialKey.pageUp.keysym, 0xff55)
        XCTAssertEqual(SpecialKey.pageDown.keysym, 0xff56)
        XCTAssertEqual(SpecialKey.function(1).keysym, 0xffbe)
        XCTAssertEqual(SpecialKey.function(12).keysym, 0xffc9)
        XCTAssertEqual(SpecialKey.functionRow.count, 12)
    }
}

final class PillPlacementTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 800)
    private let pill = CGSize(width: 60, height: 44)

    func testSnapsToTheNearestEdgeKeepingThePositionAlongIt() {
        XCTAssertEqual(PillPlacement.snapped(center: CGPoint(x: 30, y: 400), in: screen),
                       PillPlacement(edge: .leading, fraction: 0.5))
        XCTAssertEqual(PillPlacement.snapped(center: CGPoint(x: 950, y: 200), in: screen),
                       PillPlacement(edge: .trailing, fraction: 0.25))
        XCTAssertEqual(PillPlacement.snapped(center: CGPoint(x: 500, y: 20), in: screen),
                       PillPlacement(edge: .top, fraction: 0.5))
        XCTAssertEqual(PillPlacement.snapped(center: CGPoint(x: 250, y: 790), in: screen),
                       PillPlacement(edge: .bottom, fraction: 0.25))
    }

    func testCenterStaysOnScreen() {
        let c = PillPlacement(edge: .trailing, fraction: 0).center(pill: pill, in: screen)
        XCTAssertEqual(c, CGPoint(x: 1000 - 12 - 30, y: 12 + 22))
        let b = PillPlacement(edge: .bottom, fraction: 1).center(pill: pill, in: screen)
        XCTAssertEqual(b, CGPoint(x: 1000 - 12 - 30, y: 800 - 12 - 22))
    }

    func testRawValueRoundTripAndAsideTowardTheMiddle() {
        let p = PillPlacement(edge: .leading, fraction: 0.8)
        XCTAssertEqual(PillPlacement(rawValue: p.rawValue), p)
        XCTAssertNil(PillPlacement(rawValue: "nowhere:1"))
        XCTAssertLessThan(p.asideOffset(pill: pill, in: screen).height, 0)
        XCTAssertGreaterThan(PillPlacement(edge: .top, fraction: 0.1).asideOffset(pill: pill, in: screen).width, 0)
    }
}

@MainActor
final class PointerAvoidanceTests: XCTestCase {
    func testOnlyFlipsWhenThePointerEntersOrLeavesThePill() {
        let m = ControlMenuModel()
        m.pillRestingFrame = CGRect(x: 100, y: 100, width: 60, height: 44)
        m.pointerMoved(to: CGPoint(x: 10, y: 10))
        XCTAssertFalse(m.pointerOverPill)
        m.pointerMoved(to: CGPoint(x: 120, y: 120))
        XCTAssertTrue(m.pointerOverPill)
        m.pointerMoved(to: nil)
        XCTAssertFalse(m.pointerOverPill)
    }
}
