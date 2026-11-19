import XCTest
@testable import Screener

/// Records what the menu sends; modifier holds/releases are recorded as
/// plain downs/ups (the real sink reference-counts them with hardware keys).
@MainActor
final class FakeKeySink: RemoteKeySink {
    private(set) var strokes: [KeyStroke] = []
    func sendKey(down: Bool, keysym: UInt32) { strokes.append(KeyStroke(down: down, keysym: keysym)) }
    func holdModifier(_ keysym: UInt32) { strokes.append(.down(keysym)) }
    func releaseModifier(_ keysym: UInt32) { strokes.append(.up(keysym)) }
    func clear() { strokes = [] }
}

final class ShortcutChordTests: XCTestCase {
    private let cmd: UInt32 = 0xffeb, opt: UInt32 = 0xffe7, ctrl: UInt32 = 0xffe3, shift: UInt32 = 0xffe1

    func testEveryChord() {
        let expected: [ShortcutAction: KeyChord] = [
            .appSwitcher: KeyChord([cmd], 0xff09),
            .spotlight: KeyChord([cmd], 0x20),
            .missionControl: KeyChord([ctrl], 0xff52),
            .appExpose: KeyChord([ctrl], 0xff54),
            .showDesktop: KeyChord([], 0xffc8),
            .lockScreen: KeyChord([ctrl, cmd], 0x71),
            .forceQuit: KeyChord([opt, cmd], 0xff1b),
            .screenshot: KeyChord([shift, cmd], 0x34),
            .screenshotToClipboard: KeyChord([ctrl, shift, cmd], 0x34),
        ]
        XCTAssertEqual(Set(expected.keys), Set(ShortcutAction.allCases))
        for action in ShortcutAction.allCases {
            XCTAssertEqual(action.chord, expected[action], "\(action)")
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.systemImage.isEmpty)
        }
    }

    func testChordStrokesNestModifiers() {
        XCTAssertEqual(ShortcutAction.lockScreen.chord.strokes,
                       [.down(ctrl), .down(cmd), .down(0x71), .up(0x71), .up(cmd), .up(ctrl)])
        XCTAssertEqual(ShortcutAction.showDesktop.chord.strokes, [.down(0xffc8), .up(0xffc8)])
    }
}

@MainActor
final class ControlMenuModelTests: XCTestCase {
    private let cmd: UInt32 = 0xffeb, shift: UInt32 = 0xffe1, ret: UInt32 = 0xff0d, tab: UInt32 = 0xff09
    private var clock = FakeRepeatClock()
    private var sink = FakeKeySink()

    private func make(password: String? = nil) -> ControlMenuModel {
        clock = FakeRepeatClock()
        sink = FakeKeySink()
        let c = clock
        let m = ControlMenuModel(modifiers: StickyModifiers(now: { c.now }), schedule: c.schedule)
        m.sink = sink
        m.password = { password }
        return m
    }

    // MARK: shortcuts

    func testEveryNonHoldingActionSendsItsChord() {
        for action in ShortcutAction.allCases where action != .appSwitcher {
            let m = make()
            m.perform(action)
            XCTAssertEqual(sink.strokes, action.chord.strokes, "\(action)")
        }
    }

    func testCommandTabHoldsCommandAcrossTapsThenReleasesWhenIdle() {
        let m = make()
        m.perform(.appSwitcher)
        clock.advance(by: 1.0)
        m.perform(.appSwitcher)
        XCTAssertTrue(m.appSwitcherActive)
        XCTAssertEqual(sink.strokes, [.down(cmd), .down(tab), .up(tab), .down(tab), .up(tab)])
        clock.advance(by: 1.4)                           // idle timer re-armed by the 2nd tap
        XCTAssertTrue(m.appSwitcherActive)
        clock.advance(by: 0.2)
        XCTAssertFalse(m.appSwitcherActive)
        XCTAssertEqual(sink.strokes.last, .up(cmd))
        XCTAssertEqual(ControlMenuModel.appSwitcherIdleRelease, 1.5)
    }

    func testCommandTabReleasesWhenTheMenuCollapses() {
        let m = make()
        m.perform(.appSwitcher)
        m.menuDidCollapse()
        XCTAssertEqual(sink.strokes, [.down(cmd), .down(tab), .up(tab), .up(cmd)])
        clock.advance(by: 5)
        XCTAssertEqual(sink.strokes.count, 4)            // no second release
    }

    func testAnotherActionEndsTheAppSwitcherFirst() {
        let m = make()
        m.perform(.appSwitcher)
        m.perform(.spotlight)
        XCTAssertEqual(sink.strokes, [.down(cmd), .down(tab), .up(tab), .up(cmd)] + ShortcutAction.spotlight.chord.strokes)
    }

    // MARK: modifiers + special keys

    func testLatchedCommandThenSpecialKeyWrapsAndClears() {
        let m = make()
        m.tapModifier(.command)
        m.specialKeyDown(.left)
        m.specialKeyUp()
        XCTAssertEqual(sink.strokes, [.down(cmd), .down(0xff51), .up(0xff51), .up(cmd)])
        XCTAssertEqual(m.modifiers.state[.command], .off)
        sink.clear()
        m.specialKeyDown(.left); m.specialKeyUp()
        XCTAssertEqual(sink.strokes, [.down(0xff51), .up(0xff51)])
    }

    func testFnLayerRemapsArrowsAndBackspace() {
        let m = make()
        m.tapModifier(.fn)
        m.specialKeyDown(.left); m.specialKeyUp()          // fn latched → Home, then clears
        m.specialKeyDown(.left); m.specialKeyUp()
        m.tapModifier(.fn); clock.advance(by: 0.1); m.tapModifier(.fn)   // lock fn
        m.specialKeyDown(.backspace); m.specialKeyUp()
        m.specialKeyDown(.down); m.specialKeyUp()
        XCTAssertEqual(sink.strokes, [
            .down(0xff50), .up(0xff50), .down(0xff51), .up(0xff51),
            .down(0xffff), .up(0xffff), .down(0xff56), .up(0xff56),
        ])
        XCTAssertEqual(m.modifiers.state[.fn], .locked)
    }

    func testHeldSpecialKeyRepeats() {
        let m = make()
        m.specialKeyDown(.down)
        clock.advance(by: 0.5 + KeyRepeater.interval * 2 + 0.001)
        m.specialKeyUp()
        clock.advance(by: 1)
        XCTAssertEqual(sink.strokes, [.down(0xff54), .down(0xff54), .down(0xff54), .down(0xff54), .up(0xff54)])
    }

    func testDoubleTapLocksViaTheInjectedClock() {
        let m = make()
        m.tapModifier(.shift)
        clock.advance(by: 0.2)
        m.tapModifier(.shift)
        XCTAssertEqual(m.modifiers.state[.shift], .locked)
    }

    // MARK: Type Password

    func testTypePasswordTypesThenReturn() {
        let m = make(password: "aB1!")
        XCTAssertTrue(m.canTypePassword)
        m.tapModifier(.command)                            // a latched modifier is not applied to the password
        XCTAssertTrue(m.typePassword())
        XCTAssertEqual(sink.strokes, [
            .down(0x61), .up(0x61),
            .down(shift), .down(0x42), .up(0x42), .up(shift),
            .down(0x31), .up(0x31),
            .down(shift), .down(0x21), .up(0x21), .up(shift),
            .down(ret), .up(ret),
        ])
        XCTAssertEqual(sink.strokes.suffix(2), [.down(ret), .up(ret)])
    }

    func testTypePasswordDisabledWithoutPassword() {
        let m = make(password: nil)
        XCTAssertFalse(m.canTypePassword)
        XCTAssertFalse(m.typePassword())
        XCTAssertEqual(sink.strokes, [])
        let e = make(password: "")
        XCTAssertFalse(e.canTypePassword)
        XCTAssertFalse(e.typePassword())
    }

    func testInputReleasedResetsHeldState() {
        let m = make()
        m.perform(.appSwitcher)
        m.inputWasReleased()
        XCTAssertFalse(m.appSwitcherActive)
        clock.advance(by: 5)
        XCTAssertEqual(sink.strokes, [.down(cmd), .down(tab), .up(tab)])   // the view already released ⌘
    }
}
