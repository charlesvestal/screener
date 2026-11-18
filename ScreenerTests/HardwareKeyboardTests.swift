import GameController
import UIKit
import XCTest
@testable import Screener

/// GameController key codes are HID usages: the existing Keysyms table maps them.
final class GCKeyCodeTableTests: XCTestCase {
    private func ks(_ code: GCKeyCode, shifted: Bool = false) -> UInt32? {
        UIKeyboardHIDUsage(rawValue: code.rawValue).flatMap { Keysyms.keysym(for: $0, shifted: shifted) }
    }

    func testGCKeyCodesAreHIDUsages() {
        XCTAssertEqual(GCKeyCode.keyA.rawValue, UIKeyboardHIDUsage.keyboardA.rawValue)
        XCTAssertEqual(GCKeyCode.leftArrow.rawValue, UIKeyboardHIDUsage.keyboardLeftArrow.rawValue)
        XCTAssertEqual(GCKeyCode.leftGUI.rawValue, UIKeyboardHIDUsage.keyboardLeftGUI.rawValue)
        XCTAssertEqual(GCKeyCode.nonUSBackslash.rawValue, UIKeyboardHIDUsage.keyboardNonUSBackslash.rawValue)
    }

    func testLettersDigitsAndPunctuation() {
        XCTAssertEqual(ks(.keyA), 0x61)
        XCTAssertEqual(ks(.keyA, shifted: true), 0x41)
        XCTAssertEqual(ks(.keyZ), 0x7a)
        XCTAssertEqual(ks(.one), 0x31)
        XCTAssertEqual(ks(.one, shifted: true), 0x21)
        XCTAssertEqual(ks(.zero), 0x30)
        XCTAssertEqual(ks(.hyphen), 0x2d)
        XCTAssertEqual(ks(.equalSign), 0x3d)
        XCTAssertEqual(ks(.openBracket), 0x5b)
        XCTAssertEqual(ks(.semicolon), 0x3b)
        XCTAssertEqual(ks(.quote), 0x27)
        XCTAssertEqual(ks(.comma), 0x2c)
        XCTAssertEqual(ks(.period), 0x2e)
        XCTAssertEqual(ks(.slash), 0x2f)
        XCTAssertEqual(ks(.slash, shifted: true), 0x3f)
        XCTAssertEqual(ks(.graveAccentAndTilde), 0x60)
        XCTAssertEqual(ks(.spacebar), 0x20)
        XCTAssertEqual(ks(.nonUSBackslash), 0x5c)               // ISO key (US value; layout char from UIKit)
    }

    func testSpecialKeys() {
        XCTAssertEqual(ks(.leftArrow), 0xff51)
        XCTAssertEqual(ks(.upArrow), 0xff52)
        XCTAssertEqual(ks(.rightArrow), 0xff53)
        XCTAssertEqual(ks(.downArrow), 0xff54)
        XCTAssertEqual(ks(.deleteOrBackspace), 0xff08)
        XCTAssertEqual(ks(.deleteForward), 0xffff)
        XCTAssertEqual(ks(.returnOrEnter), 0xff0d)
        XCTAssertEqual(ks(.escape), 0xff1b)
        XCTAssertEqual(ks(.tab), 0xff09)
        XCTAssertEqual(ks(.home), 0xff50)
        XCTAssertEqual(ks(.end), 0xff57)
        XCTAssertEqual(ks(.pageUp), 0xff55)
        XCTAssertEqual(ks(.pageDown), 0xff56)
        XCTAssertEqual(ks(.F1), 0xffbe)
        XCTAssertEqual(ks(.F12), 0xffc9)
    }

    func testModifiersBothSides() {
        XCTAssertEqual(ks(.leftShift), 0xffe1)
        XCTAssertEqual(ks(.rightShift), 0xffe2)
        XCTAssertEqual(ks(.leftControl), 0xffe3)
        XCTAssertEqual(ks(.rightControl), 0xffe4)
        XCTAssertEqual(ks(.leftAlt), 0xffe9)
        XCTAssertEqual(ks(.rightAlt), 0xffea)
        XCTAssertEqual(ks(.leftGUI), 0xffeb)
        XCTAssertEqual(ks(.rightGUI), 0xffec)
        XCTAssertEqual(ks(.capsLock), 0xffe5)
    }
}

/// The GameController hardware-key path through RemoteInputView, checked as
/// the exact key events on the wire (GC events injected through `gcKey`).
@MainActor
final class GCKeyPathTests: XCTestCase {
    private let cmd: UInt32 = 0xffeb, opt: UInt32 = 0xffe9, ctrl: UInt32 = 0xffe3, shift: UInt32 = 0xffe1
    private let bs: UInt32 = 0xff08, left: UInt32 = 0xff51, right: UInt32 = 0xff53, home: UInt32 = 0xff50
    private let fdel: UInt32 = 0xffff

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        func append(_ d: Data) { lock.withLock { _sent.append(d) } }
        var sent: [Data] { lock.withLock { _sent } }
    }

    private var clock = FakeRepeatClock()
    private var view: RemoteInputView!
    private var input: InputController!
    private var sink: Sink!

    /// A view over a 100×100 host with a GCKeyboard connected, on a manual clock.
    private func make() {
        clock = FakeRepeatClock()
        let s = Sink()
        sink = s
        input = InputController(contentKey: nil, serverWidth: 100, serverHeight: 100, send: { s.append($0) })
        view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repeatSchedule: clock.schedule)
        view.input = input
        let c = clock
        view.now = { c.now }
        view.keyArbiter.gcActive = true
    }

    private func gc(_ u: UIKeyboardHIDUsage, _ down: Bool) { view.gcKey(u, pressed: down, force: true) }

    private func uk(_ u: UIKeyboardHIDUsage, _ down: Bool, _ flags: UIKeyModifierFlags = [], _ chars: String = "") {
        XCTAssertTrue(view.uikitKey(u, down: down, modifiers: flags, characters: chars))
    }

    /// GC reports a chord (modifiers down in order, the key tapped, modifiers up in reverse).
    private func gcChord(_ mods: [UIKeyboardHIDUsage], _ key: UIKeyboardHIDUsage) {
        for m in mods { gc(m, true) }
        gc(key, true)
        gc(key, false)
        for m in mods.reversed() { gc(m, false) }
    }

    private func strokes() async -> [KeyStroke] {
        await input.flush()
        return sink.sent.compactMap { d -> KeyStroke? in
            let b = [UInt8](d)
            guard b.first == 4 else { return nil }
            let ks = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
            return KeyStroke(down: b[1] == 1, keysym: ks)
        }
    }

    private func wrapped(_ mods: [UInt32], _ key: UInt32) -> [KeyStroke] {
        mods.map(KeyStroke.down) + [.down(key), .up(key)] + mods.reversed().map(KeyStroke.up)
    }

    // MARK: chords UIKit never delivers (GC only)

    func testOptionArrowsViaGC() async {
        make()
        gcChord([.keyboardLeftAlt], .keyboardLeftArrow)
        gcChord([.keyboardLeftAlt], .keyboardRightArrow)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([opt], left) + wrapped([opt], right))
    }

    func testCommandArrowsViaGC() async {
        make()
        gcChord([.keyboardLeftGUI], .keyboardRightArrow)
        gcChord([.keyboardRightGUI], .keyboardLeftArrow)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([cmd], right) + wrapped([0xffec], left))
    }

    func testShiftOptionRightViaGC() async {
        make()
        gcChord([.keyboardLeftShift, .keyboardLeftAlt], .keyboardRightArrow)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([shift, opt], right))
    }

    func testOptionDeleteAndCommandDeleteViaGC() async {
        make()
        gcChord([.keyboardLeftAlt], .keyboardDeleteOrBackspace)
        gcChord([.keyboardLeftGUI], .keyboardDeleteOrBackspace)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([opt], bs) + wrapped([cmd], bs))
    }

    func testChordsAreNotDelayed() async {
        make()
        gc(.keyboardLeftAlt, true)
        gc(.keyboardLeftArrow, true)
        let got = await strokes()                      // no clock advance
        XCTAssertEqual(got, [.down(opt), .down(left)])
    }

    // MARK: both sources report (no duplicates)

    func testBothSourcesSendEachKeyOnce() async {
        make()
        // ⌥ via GC then UIKit, ← via UIKit then GC, ups in mixed order.
        gc(.keyboardLeftAlt, true)
        uk(.keyboardLeftAlt, true, .alternate)
        uk(.keyboardLeftArrow, true, .alternate)
        gc(.keyboardLeftArrow, true)
        gc(.keyboardLeftArrow, false)
        uk(.keyboardLeftArrow, false, .alternate)
        uk(.keyboardLeftAlt, false)
        gc(.keyboardLeftAlt, false)
        clock.advance(by: 1)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([opt], left))
    }

    func testPlainArrowResolvesAsSoonAsUIKitConfirms() async {
        make()
        gc(.keyboardLeftArrow, true)
        var got = await strokes()
        XCTAssertEqual(got, [])                         // waiting: could be fn + ← = Home
        uk(.keyboardLeftArrow, true)
        got = await strokes()
        XCTAssertEqual(got, [.down(left)])
    }

    func testPlainArrowGCOnlyIsSentAfterThePartnerWait() async {
        make()
        gc(.keyboardLeftArrow, true)
        clock.advance(by: KeyArbiter.partnerWait + 0.001)
        gc(.keyboardLeftArrow, false)
        let got = await strokes()
        XCTAssertEqual(got, [.down(left), .up(left)])
    }

    // MARK: fn layer

    func testFnLeftIsHome() async {
        make()
        gc(.keyboardLeftArrow, true)
        uk(.keyboardHome, true)
        gc(.keyboardLeftArrow, false)
        uk(.keyboardHome, false)
        // UIKit first, too.
        uk(.keyboardDeleteForward, true)
        gc(.keyboardDeleteOrBackspace, true)
        uk(.keyboardDeleteForward, false)
        gc(.keyboardDeleteOrBackspace, false)
        clock.advance(by: 1)
        let got = await strokes()
        XCTAssertEqual(got, [.down(home), .up(home), .down(fdel), .up(fdel)])
    }

    func testFnWithACommandChordDoesNotDoubleSend() async {
        make()
        gc(.keyboardLeftGUI, true)
        gc(.keyboardLeftArrow, true)                    // chord: sent at once as ←
        uk(.keyboardHome, true, .command)               // UIKit's translation: dropped
        uk(.keyboardHome, false, .command)
        gc(.keyboardLeftArrow, false)
        gc(.keyboardLeftGUI, false)
        clock.advance(by: 1)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([cmd], left))
    }

    // MARK: printable keys take the layout character from UIKit

    func testLayoutCharacterComesFromUIKit() async {
        make()
        // AZERTY: the key at the US "A" position types "q".
        gc(.keyboardA, true)
        uk(.keyboardA, true, [], "q")
        gc(.keyboardA, false)
        uk(.keyboardA, false)
        // UIKit first.
        uk(.keyboardQ, true, [], "a")
        gc(.keyboardQ, true)
        gc(.keyboardQ, false)
        clock.advance(by: 1)
        let got = await strokes()
        XCTAssertEqual(got, [.down(0x71), .up(0x71), .down(0x61), .up(0x61)])
    }

    func testPrintableGCOnlyFallsBackToTheUSTable() async {
        make()
        gc(.keyboardA, true)
        clock.advance(by: KeyArbiter.partnerWait + 0.001)
        gc(.keyboardA, false)
        let got = await strokes()
        XCTAssertEqual(got, [.down(0x61), .up(0x61)])
    }

    func testAWaitingKeyHoldsBackLaterKeysAndKeepsItsOwnModifiers() async {
        make()
        // "a" waits for its character; ⌘ goes down before UIKit reports the "a".
        gc(.keyboardA, true)
        gc(.keyboardLeftGUI, true)
        var got = await strokes()
        XCTAssertEqual(got, [])
        uk(.keyboardA, true, [], "a")
        got = await strokes()
        XCTAssertEqual(got, [.down(0x61), .down(cmd)])  // in order, and not ⌘A
    }

    func testFastTypingKeepsOrder() async {
        make()
        gc(.keyboardA, true)
        gc(.keyboardB, true)
        uk(.keyboardA, true, [], "a")
        uk(.keyboardB, true, [], "b")
        gc(.keyboardA, false)
        gc(.keyboardB, false)
        let got = await strokes()
        XCTAssertEqual(got, [.down(0x61), .down(0x62), .up(0x61), .up(0x62)])
    }

    // MARK: UIKit fallback

    func testUIKitAloneStillWorksWhenGCIsSilent() async {
        make()
        uk(.keyboardLeftControl, true, .control)
        uk(.keyboardA, true, .control, "\u{1}")
        clock.advance(by: KeyArbiter.partnerWait + 0.001)
        uk(.keyboardA, false, .control)
        uk(.keyboardLeftControl, false)
        // A late GC report of the same press is an echo, not a second press.
        gc(.keyboardA, true)
        gc(.keyboardA, false)
        clock.advance(by: 1)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([ctrl], 0x61))
    }

    func testWithoutGCUIKitGoesStraightThrough() async {
        make()
        view.keyArbiter.gcActive = false
        uk(.keyboardLeftAlt, true, .alternate)
        uk(.keyboardLeftArrow, true, .alternate)
        let got = await strokes()                       // no wait
        XCTAssertEqual(got, [.down(opt), .down(left)])
    }

    // MARK: key commands

    private func keyCommand(_ input: String, _ flags: UIKeyModifierFlags) -> UIKeyCommand {
        UIKeyCommand(input: input, modifierFlags: flags, action: #selector(RemoteInputView.forwardKeyCommand(_:)))
    }

    func testClaimedKeyCommandIsSwallowedWhenGCSendsTheKey() async {
        make()
        gc(.keyboardLeftGUI, true)
        gc(.keyboardW, true)
        view.forwardKeyCommand(keyCommand("w", .command))
        gc(.keyboardW, false)
        gc(.keyboardLeftGUI, false)
        // Key command before GC's report.
        gc(.keyboardLeftGUI, true)
        view.forwardKeyCommand(keyCommand("q", .command))
        gc(.keyboardQ, true)
        gc(.keyboardQ, false)
        gc(.keyboardLeftGUI, false)
        clock.advance(by: 1)
        let got = await strokes()
        XCTAssertEqual(got, wrapped([cmd], 0x77) + wrapped([cmd], 0x71))
    }

    func testClaimedKeyCommandWithSilentGCIsATap() async {
        make()
        view.forwardKeyCommand(keyCommand("z", [.command, .shift]))
        var got = await strokes()
        XCTAssertEqual(got, [])
        clock.advance(by: KeyArbiter.partnerWait + 0.001)
        got = await strokes()
        XCTAssertEqual(got, wrapped([shift, cmd], 0x7a))
    }

    // MARK: on-screen keyboard dedupe

    func testSoftKeyboardEchoOfAGCKeyIsDropped() async {
        make()
        gc(.keyboardLeftAlt, true)
        gc(.keyboardDeleteOrBackspace, true)
        view.softDelete()                               // the text system's echo of ⌥⌫
        gc(.keyboardDeleteOrBackspace, false)
        gc(.keyboardLeftAlt, false)
        clock.advance(by: 0.2)
        view.softDelete()                               // a real on-screen Delete later
        let got = await strokes()
        XCTAssertEqual(got, wrapped([opt], bs) + [.down(bs), .up(bs)])
    }

    func testSoftKeyboardTextEchoIsDropped() async {
        make()
        gc(.keyboardA, true)
        view.typeText("a")
        uk(.keyboardA, true, [], "a")
        gc(.keyboardA, false)
        clock.advance(by: 0.2)
        view.typeText("b")
        let got = await strokes()
        XCTAssertEqual(got, [.down(0x61), .up(0x61), .down(0x62), .up(0x62)])
    }

    // MARK: repeat, release

    func testHeldGCKeyRepeatsWithTheModifierHeld() async {
        make()
        gc(.keyboardLeftAlt, true)
        gc(.keyboardDeleteOrBackspace, true)
        clock.advance(by: 0.5 + KeyRepeater.interval + 0.001)
        gc(.keyboardDeleteOrBackspace, false)
        gc(.keyboardLeftAlt, false)
        let got = await strokes()
        XCTAssertEqual(got, [.down(opt), .down(bs), .down(bs), .down(bs), .up(bs), .up(opt)])
    }

    func testKeyboardDisconnectReleasesWhatGCHeld() async {
        make()
        gc(.keyboardLeftGUI, true)
        gc(.keyboardRightArrow, true)
        view.gcKeyboardAvailability(false)
        XCTAssertFalse(view.keyArbiter.gcActive)
        gc(.keyboardRightArrow, false)                  // late ups change nothing
        gc(.keyboardLeftGUI, false)
        clock.advance(by: 2)                            // no repeat left behind
        let got = await strokes()
        XCTAssertEqual(Set(got.filter { !$0.down }.map(\.keysym)), [cmd, right])
        XCTAssertEqual(got.filter(\.down), [.down(cmd), .down(right)])
        XCTAssertEqual(got.count, 4)
    }

    func testFocusLossForgetsGCHeldKeys() async {
        make()
        gc(.keyboardLeftAlt, true)
        view.releaseAll()
        gc(.keyboardLeftAlt, false)
        gc(.keyboardLeftAlt, true)                      // a new press after focus came back
        let got = await strokes()
        XCTAssertEqual(got, [.down(opt), .up(opt), .down(opt)])
    }

    func testGCKeyDownsAreIgnoredWithoutFocusButUpsPass() async {
        make()
        gc(.keyboardLeftAlt, true)
        view.gcKey(.keyboardLeftArrow, pressed: true)   // not in a window: no focus
        view.gcKey(.keyboardLeftAlt, pressed: false)
        let got = await strokes()
        XCTAssertEqual(got, [.down(opt), .up(opt)])
    }

    func testTheMenuShortcutIsNeverForwarded() async {
        make()
        gc(.keyboardLeftGUI, true)
        gc(.keyboardLeftAlt, true)
        gc(.keyboardM, true)
        gc(.keyboardM, false)
        XCTAssertFalse(view.uikitKey(.keyboardM, down: true, modifiers: [.command, .alternate], characters: "µ"))
        gc(.keyboardLeftAlt, false)
        gc(.keyboardLeftGUI, false)
        let got = await strokes()
        XCTAssertEqual(got, [.down(cmd), .down(opt), .up(opt), .up(cmd)])
    }

    func testKeyboardTesterRecordsTheLastTenEvents() {
        make()
        view.preferences.keyboardTester = true
        for _ in 0..<8 { gcChord([.keyboardLeftAlt], .keyboardLeftArrow) }
        XCTAssertEqual(view.keyTesterLog.lines.count, KeyTesterLog.capacity)
        XCTAssertTrue(view.keyTesterLog.lines.last!.hasPrefix("GC"))
        XCTAssertTrue(view.keyTesterLog.lines.contains { $0.contains("⌥") && $0.contains("0xff51") })
        view.preferences.keyboardTester = false
        XCTAssertEqual(view.keyTesterLog.lines, [])
    }
}
