import UIKit
import XCTest
@testable import Screener

/// Every key path with modifiers, checked as the exact key events on the
/// wire: hardware chords (pressesBegan path and claimed key commands), the
/// on-screen keyboard with sticky modifiers, the menu's special keys and the
/// keyboard accessory row.
@MainActor
final class ModifierKeyPathsTests: XCTestCase {
    private let cmd: UInt32 = 0xffeb, opt: UInt32 = 0xffe9, ctrl: UInt32 = 0xffe3, shift: UInt32 = 0xffe1
    private let bs: UInt32 = 0xff08, left: UInt32 = 0xff51, up: UInt32 = 0xff52, right: UInt32 = 0xff53
    private let down: UInt32 = 0xff54

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        func append(_ d: Data) { lock.withLock { _sent.append(d) } }
        var sent: [Data] { lock.withLock { _sent } }
    }

    private var clock = FakeRepeatClock()
    private var t: TimeInterval = 0

    private struct Rig {
        let view: RemoteInputView
        let input: InputController
        fileprivate let sink: Sink
        let sticky: StickyModifiers
        let menu: ControlMenuModel
    }

    private func make() -> Rig {
        clock = FakeRepeatClock()
        t = 0
        let sink = Sink()
        let input = InputController(contentKey: nil, serverWidth: 100, serverHeight: 100,
                                    send: { sink.append($0) })
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   repeatSchedule: clock.schedule)
        view.input = input
        let c = clock
        let sticky = StickyModifiers(now: { c.now })
        let menu = ControlMenuModel(modifiers: sticky, schedule: c.schedule)
        view.modifiers = sticky
        menu.sink = view
        view.controlMenu = menu
        view.onInputReleased = { [weak menu] in menu?.inputWasReleased() }   // as SessionView wires it
        view.now = { [unowned self] in self.t }
        return Rig(view: view, input: input, sink: sink, sticky: sticky, menu: menu)
    }

    private func strokes(_ r: Rig) async -> [KeyStroke] {
        await r.input.flush()
        return r.sink.sent.compactMap { d -> KeyStroke? in
            let b = [UInt8](d)
            guard b.first == 4 else { return nil }
            let ks = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
            return KeyStroke(down: b[1] == 1, keysym: ks)
        }
    }

    /// A physical chord: modifier keys down (in order), the key tapped, the
    /// modifier keys released in reverse.
    private func chord(_ r: Rig, _ mods: [(UIKeyboardHIDUsage, UIKeyModifierFlags)],
                       _ key: UIKeyboardHIDUsage, characters: String = "") {
        var flags: UIKeyModifierFlags = []
        for (u, f) in mods {
            flags.insert(f)
            r.view.keyDown(u, modifiers: flags, characters: "")
        }
        XCTAssertTrue(r.view.keyDown(key, modifiers: flags, characters: characters))
        XCTAssertTrue(r.view.keyUp(key))
        for (u, _) in mods.reversed() { r.view.keyUp(u) }
    }

    private let lOpt = (UIKeyboardHIDUsage.keyboardLeftAlt, UIKeyModifierFlags.alternate)
    private let lCmd = (UIKeyboardHIDUsage.keyboardLeftGUI, UIKeyModifierFlags.command)
    private let lCtrl = (UIKeyboardHIDUsage.keyboardLeftControl, UIKeyModifierFlags.control)
    private let lShift = (UIKeyboardHIDUsage.keyboardLeftShift, UIKeyModifierFlags.shift)

    private func wrapped(_ mods: [UInt32], _ key: UInt32) -> [KeyStroke] {
        mods.map(KeyStroke.down) + [.down(key), .up(key)] + mods.reversed().map(KeyStroke.up)
    }

    // MARK: hardware keyboard

    func testHardwareOptionDeleteAndCommandDelete() async {
        let r = make()
        chord(r, [lOpt], .keyboardDeleteOrBackspace, characters: "\u{8}")
        chord(r, [lCmd], .keyboardDeleteOrBackspace, characters: "\u{8}")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([opt], bs) + wrapped([cmd], bs))
    }

    func testHardwareOptionAndCommandArrows() async {
        let r = make()
        chord(r, [lOpt], .keyboardLeftArrow)
        chord(r, [lOpt], .keyboardRightArrow)
        chord(r, [lCmd], .keyboardLeftArrow)
        chord(r, [lCmd], .keyboardRightArrow)
        chord(r, [lCmd], .keyboardUpArrow)
        chord(r, [lCmd], .keyboardDownArrow)
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([opt], left) + wrapped([opt], right) + wrapped([cmd], left)
                       + wrapped([cmd], right) + wrapped([cmd], up) + wrapped([cmd], down))
    }

    func testHardwareShiftOptionRightSelectsAWord() async {
        let r = make()
        chord(r, [lShift, lOpt], .keyboardRightArrow)
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([shift, opt], right))
    }

    func testHardwareControlAAndE() async {
        let r = make()
        chord(r, [lCtrl], .keyboardA, characters: "\u{1}")
        chord(r, [lCtrl], .keyboardE, characters: "\u{5}")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([ctrl], 0x61) + wrapped([ctrl], 0x65))
    }

    func testHardwareOptionLetterDeadKeySendsTheUSLetterWithAlt() async {
        let r = make()
        chord(r, [lOpt], .keyboardE, characters: "")          // dead key: no character
        chord(r, [lOpt], .keyboardU, characters: "¨")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([opt], 0x65) + wrapped([opt], 0x75))
    }

    func testHardwareCommandLettersAndCommandShiftLetter() async {
        let r = make()
        chord(r, [lCmd], .keyboardS, characters: "s")
        chord(r, [lShift, lCmd], .keyboardZ, characters: "Z")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([cmd], 0x73) + wrapped([shift, cmd], 0x7a))
    }

    func testHardwareFnLayerKeysAsReportedByTheKeyboard() async {
        // fn+arrows arrive as Home/End/PgUp/PgDn usages (fn itself has no usage).
        let r = make()
        for u: UIKeyboardHIDUsage in [.keyboardHome, .keyboardEnd, .keyboardPageUp, .keyboardPageDown,
                                      .keyboardDeleteForward] {
            chord(r, [lShift], u)
        }
        let got = await strokes(r)
        XCTAssertEqual(got, [0xff50, 0xff57, 0xff55, 0xff56, 0xffff].flatMap { wrapped([shift], $0) })
    }

    func testHeldHardwareKeyRepeatsWithTheModifierHeld() async {
        let r = make()
        r.view.keyDown(.keyboardLeftAlt, modifiers: .alternate, characters: "")
        r.view.keyDown(.keyboardDeleteOrBackspace, modifiers: .alternate, characters: "\u{8}")
        clock.advance(by: 0.5 + KeyRepeater.interval + 0.001)
        r.view.keyUp(.keyboardDeleteOrBackspace)
        r.view.keyUp(.keyboardLeftAlt)
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(opt), .down(bs), .down(bs), .down(bs), .up(bs), .up(opt)])
    }

    func testModifierReportedByFlagsButNeverPressedIsHeldAroundTheKey() async {
        // ⌘ went down before this view had focus: only the flags know.
        let r = make()
        r.view.keyDown(.keyboardLeftArrow, modifiers: .command, characters: "")
        clock.advance(by: 0.5 + 0.001)
        r.view.keyUp(.keyboardLeftArrow)
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(cmd), .down(left), .down(left), .up(left), .up(cmd)])
    }

    func testStaleHardwareModifierIsReleasedWhenTheFlagsDropIt() async {
        let r = make()
        r.view.keyDown(.keyboardLeftGUI, modifiers: .command, characters: "")
        // ⌘'s key-up was lost; the next key reports no ⌘.
        r.view.keyDown(.keyboardA, modifiers: [], characters: "a")
        r.view.keyUp(.keyboardA)
        r.view.keyUp(.keyboardLeftGUI)                     // late: already released, nothing sent
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(cmd), .up(cmd), .down(0x61), .up(0x61)])
    }

    func testRepeatedModifierDownWithoutUpHoldsOnce() async {
        let r = make()
        r.view.keyDown(.keyboardLeftGUI, modifiers: .command, characters: "")
        r.view.keyDown(.keyboardLeftGUI, modifiers: .command, characters: "")
        r.view.keyUp(.keyboardLeftGUI)
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(cmd), .up(cmd)])
    }

    func testRightHandModifiersAreNotDuplicatedByTheFlags() async {
        let r = make()
        chord(r, [(.keyboardRightAlt, .alternate)], .keyboardDeleteOrBackspace)
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([0xffea], bs))
    }

    func testClaimedKeyCommandsHavePriorityAndForwardTheChord() async {
        let r = make()
        let commands = r.view.keyCommands ?? []
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
        let w = commands.first { $0.input == "w" && $0.modifierFlags == .command }
        XCTAssertNotNil(w)
        // ⌘ went down through pressesBegan; the W is delivered as the key command.
        r.view.keyDown(.keyboardLeftGUI, modifiers: .command, characters: "")
        r.view.forward(RemoteInputView.forwardedChords.first { $0.input == "w" }!)
        XCTAssertFalse(r.view.keyUp(.keyboardW))         // its pressesEnded: already up, passed on
        r.view.keyUp(.keyboardLeftGUI)
        // ⇧⌘Z with neither modifier seen: both held around the tap.
        r.view.forward(RemoteInputView.forwardedChords.first { $0.input == "z" && $0.flags.contains(.shift) }!)
        clock.advance(by: 2)                             // no repeat left behind
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([cmd], 0x77) + wrapped([shift, cmd], 0x7a))
    }

    func testForwardedChordsDoNotShadowTheMenuShortcutOrPlainKeys() {
        for c in RemoteInputView.forwardedChords {
            XCTAssertFalse(c.flags.isEmpty, c.input)
            XCTAssertFalse(RemoteInputView.isMenuShortcut(c.usage, modifiers: c.flags), c.input)
            XCTAssertEqual(Keysyms.keysym(for: c.usage, shifted: false),
                           c.input.unicodeScalars.first!.value, c.input)
        }
    }

    // MARK: on-screen keyboard + sticky modifiers

    func testLatchedOptionPlusSoftDeleteIsOptionDelete() async {
        let r = make()
        r.menu.tapModifier(.option)
        r.view.softDelete()
        t = 5
        r.view.softDelete()                              // latched: consumed by the first
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([opt], bs) + [.down(bs), .up(bs)])
        XCTAssertEqual(r.sticky.state[.option], .off)
    }

    func testLatchedCommandPlusSoftDeleteIsCommandDelete() async {
        let r = make()
        r.menu.tapModifier(.command)
        r.view.softDelete()
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([cmd], bs))
    }

    func testHeldSoftDeleteKeepsTheLatchedModifierWhileTheKeyboardRepeats() async {
        let r = make()
        r.menu.tapModifier(.option)
        r.view.softDelete()                              // t 0
        t = 0.5; r.view.softDelete()                     // keyboard repeat
        t = 0.6; r.view.softDelete()
        t = 2.0; r.view.softDelete()                     // a new press: plain
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([opt], bs) + wrapped([opt], bs) + wrapped([opt], bs) + [.down(bs), .up(bs)])
    }

    func testLockedModifierPersistsAcrossSoftKeys() async {
        let r = make()
        r.menu.tapModifier(.command); r.menu.tapModifier(.command)    // same instant: locked
        r.view.typeText("ab")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([cmd], 0x61) + wrapped([cmd], 0x62))
        XCTAssertEqual(r.sticky.state[.command], .locked)
    }

    func testSoftLettersWithLatchedControlAndOption() async {
        let r = make()
        r.menu.tapModifier(.control)
        r.view.typeText("A")                             // ⌃⇧A: unshifted + Shift
        r.menu.tapModifier(.option)
        r.view.typeText("e")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([ctrl, shift], 0x61) + wrapped([opt], 0x65))
    }

    func testSoftShiftedSymbolWithCommandSendsTheUnshiftedUSKey() async {
        let r = make()
        r.menu.tapModifier(.command)
        r.view.typeText("?")
        r.menu.tapModifier(.command)
        r.view.typeText("!")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([cmd, shift], 0x2f) + wrapped([cmd, shift], 0x31))
    }

    func testSoftLetterWithLatchedShiftIsTheShiftedCharacter() async {
        let r = make()
        r.menu.tapModifier(.shift)
        r.view.typeText("a1")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([shift], 0x41) + [.down(0x31), .up(0x31)])
    }

    func testSoftReturnAndTabWithModifiers() async {
        let r = make()
        r.menu.tapModifier(.command)
        r.view.typeText("\n")
        r.menu.tapModifier(.shift)
        r.view.typeText("\t")
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([cmd], 0xff0d) + wrapped([shift], 0xff09))
    }

    // MARK: special keys (menu panel)

    func testPanelArrowsWithLatchedAndLockedModifiers() async {
        let r = make()
        r.menu.tapModifier(.shift)
        r.menu.specialKeyDown(.left); r.menu.specialKeyUp()
        r.menu.specialKeyDown(.left); r.menu.specialKeyUp()       // latched ⇧ consumed
        r.menu.tapModifier(.option); r.menu.tapModifier(.option)  // locked
        r.menu.specialKeyDown(.right); r.menu.specialKeyUp()
        r.menu.specialKeyDown(.backspace); r.menu.specialKeyUp()
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([shift], left) + [.down(left), .up(left)]
                       + wrapped([opt], right) + wrapped([opt], bs))
        XCTAssertEqual(r.sticky.state[.option], .locked)
    }

    func testPanelKeyWithHardwareCommandHeldAndStickyCommandNoDoubleDown() async {
        let r = make()
        r.view.keyDown(.keyboardLeftGUI, modifiers: .command, characters: "")
        r.menu.tapModifier(.command)
        r.menu.specialKeyDown(.up); r.menu.specialKeyUp()
        r.view.keyUp(.keyboardLeftGUI)
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([cmd], up))
    }

    func testPanelEveryKeyWithCommandAndFnLayer() async {
        let r = make()
        let keys: [SpecialKey] = [.escape, .tab, .backspace, .forwardDelete, .home, .end, .pageUp, .pageDown,
                                  .function(1), .function(12)]
        for k in keys {
            r.menu.tapModifier(.command)
            r.menu.specialKeyDown(k); r.menu.specialKeyUp()
        }
        r.menu.tapModifier(.fn); r.menu.tapModifier(.option)
        r.menu.specialKeyDown(.left); r.menu.specialKeyUp()        // fn ← = Home, with ⌥
        let got = await strokes(r)
        XCTAssertEqual(got, keys.flatMap { wrapped([cmd], $0.keysym) } + wrapped([opt], 0xff50))
    }

    func testHeldPanelKeyRepeatsWithModifiersHeld() async {
        let r = make()
        r.menu.tapModifier(.option)
        r.menu.specialKeyDown(.left)
        clock.advance(by: 0.5 + KeyRepeater.interval + 0.001)
        r.menu.specialKeyUp()
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(opt), .down(left), .down(left), .down(left), .up(left), .up(opt)])
    }

    func testFocusLossWhileAPanelKeyIsHeldReleasesKeyAndModifiers() async {
        let r = make()
        r.menu.tapModifier(.shift)
        r.menu.specialKeyDown(.down)
        r.view.releaseAll()
        clock.advance(by: 2)                             // repeat stopped
        r.menu.specialKeyUp()                            // forgotten: nothing more
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(shift), .down(down), .up(down), .up(shift)])
    }

    // MARK: keyboard accessory row

    func testAccessoryRowItemsAndWiring() {
        let r = make()
        XCTAssertEqual(KeyboardAccessoryBar.items, [
            .modifier(.command), .modifier(.option), .modifier(.control), .modifier(.shift),
            .key(.escape), .key(.tab), .key(.left), .key(.up), .key(.down), .key(.right),
        ])
        XCTAssertTrue(r.view.keyboardAccessory.menu === r.menu)
        let proxy = r.view.subviews.first { $0 is SoftKeyboardProxy }
        XCTAssertTrue(proxy?.inputAccessoryView === r.view.keyboardAccessory)
        for item in KeyboardAccessoryBar.items {
            XCTAssertNotNil(r.view.keyboardAccessory.button(for: item))
        }
    }

    func testAccessoryModifierThenArrowSendsTheChordAndSharesState() async {
        let r = make()
        let bar = r.view.keyboardAccessory
        bar.button(for: .modifier(.shift))?.sendActions(for: .touchUpInside)
        XCTAssertEqual(r.sticky.state[.shift], .latched)               // the menu sees it too
        bar.button(for: .key(.right))?.sendActions(for: .touchDown)
        bar.button(for: .key(.right))?.sendActions(for: .touchUpInside)
        bar.button(for: .key(.escape))?.sendActions(for: .touchDown)
        bar.button(for: .key(.escape))?.sendActions(for: .touchCancel)
        let got = await strokes(r)
        XCTAssertEqual(got, wrapped([shift], right) + [.down(0xff1b), .up(0xff1b)])
        XCTAssertEqual(r.sticky.state[.shift], .off)
    }

    func testAccessoryDoubleTapLocksAndHoldRepeats() async {
        let r = make()
        let bar = r.view.keyboardAccessory
        bar.button(for: .modifier(.command))?.sendActions(for: .touchUpInside)
        clock.advance(by: 0.1)
        bar.button(for: .modifier(.command))?.sendActions(for: .touchUpInside)
        XCTAssertEqual(r.sticky.state[.command], .locked)
        bar.button(for: .key(.up))?.sendActions(for: .touchDown)
        clock.advance(by: 0.5 + 0.001)
        bar.button(for: .key(.up))?.sendActions(for: .touchUpOutside)
        bar.button(for: .key(.tab))?.sendActions(for: .touchDown)
        bar.button(for: .key(.tab))?.sendActions(for: .touchUpInside)
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(cmd), .down(up), .down(up), .up(up), .up(cmd)] + wrapped([cmd], 0xff09))
        XCTAssertEqual(r.sticky.state[.command], .locked)
    }

    func testAccessoryReflectsTheSharedState() async {
        let r = make()
        let bar = r.view.keyboardAccessory
        let cmdButton = bar.button(for: .modifier(.command))
        XCTAssertEqual(cmdButton?.accessibilityValue, "Off")
        r.menu.tapModifier(.command)                                   // from the floating menu
        r.menu.tapModifier(.fn)
        for _ in 0..<20 where cmdButton?.accessibilityValue == "Off" { await Task.yield() }
        XCTAssertEqual(cmdButton?.accessibilityValue, "Latched for the next key")
        XCTAssertEqual(bar.title(for: .key(.left)), "home")
        XCTAssertEqual(bar.title(for: .modifier(.command)), "⌘")
    }

    func testAccessoryReleasesAHeldKeyWhenRemovedFromTheWindow() async {
        let r = make()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        let bar = r.view.keyboardAccessory
        window.addSubview(bar)
        bar.button(for: .key(.left))?.sendActions(for: .touchDown)
        bar.removeFromSuperview()
        let got = await strokes(r)
        XCTAssertEqual(got, [.down(left), .up(left)])
    }
}
