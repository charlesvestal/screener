import UIKit
import XCTest
@testable import Screener

/// UIKeyboardHIDUsage → X11 keysym (Keysyms.swift), checked against the
/// reference's tables (frontend/desktop/keymap.py GLFW_KEY_TO_X11 and
/// keyboard_grab.py _VK_KEYSYM / _KS_*).
final class KeysymsTests: XCTestCase {
    func testLettersDigitsAndShift() {
        XCTAssertEqual(Keysyms.keysym(for: .keyboardA, shifted: false), 0x61)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardA, shifted: true), 0x41)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardZ, shifted: false), 0x7a)
        XCTAssertEqual(Keysyms.keysym(for: .keyboard1, shifted: false), 0x31)
        XCTAssertEqual(Keysyms.keysym(for: .keyboard1, shifted: true), 0x21)       // !
        XCTAssertEqual(Keysyms.keysym(for: .keyboard0, shifted: false), 0x30)
        XCTAssertEqual(Keysyms.keysym(for: .keyboard2, shifted: true), 0x40)       // @
        XCTAssertEqual(Keysyms.keysym(for: .keyboardSpacebar, shifted: false), 0x20)
    }

    func testUSPunctuation() {
        let cases: [(UIKeyboardHIDUsage, Character, Character)] = [
            (.keyboardHyphen, "-", "_"), (.keyboardEqualSign, "=", "+"),
            (.keyboardOpenBracket, "[", "{"), (.keyboardCloseBracket, "]", "}"),
            (.keyboardBackslash, "\\", "|"), (.keyboardSemicolon, ";", ":"),
            (.keyboardQuote, "'", "\""), (.keyboardGraveAccentAndTilde, "`", "~"),
            (.keyboardComma, ",", "<"), (.keyboardPeriod, ".", ">"), (.keyboardSlash, "/", "?"),
        ]
        for (usage, base, shifted) in cases {
            XCTAssertEqual(Keysyms.keysym(for: usage, shifted: false), base.unicodeScalars.first!.value, "\(base)")
            XCTAssertEqual(Keysyms.keysym(for: usage, shifted: true), shifted.unicodeScalars.first!.value, "\(shifted)")
        }
    }

    func testSpecialKeys() {
        XCTAssertEqual(Keysyms.keysym(for: .keyboardReturnOrEnter, shifted: false), 0xff0d)
        XCTAssertEqual(Keysyms.keysym(for: .keypadEnter, shifted: false), 0xff0d)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardTab, shifted: true), 0xff09)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardEscape, shifted: false), 0xff1b)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardDeleteOrBackspace, shifted: false), 0xff08)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardDeleteForward, shifted: false), 0xffff)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardLeftArrow, shifted: false), 0xff51)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardUpArrow, shifted: false), 0xff52)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardRightArrow, shifted: false), 0xff53)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardDownArrow, shifted: false), 0xff54)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardHome, shifted: false), 0xff50)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardEnd, shifted: false), 0xff57)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardPageUp, shifted: false), 0xff55)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardPageDown, shifted: false), 0xff56)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardInsert, shifted: false), 0xff63)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardF1, shifted: false), 0xffbe)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardF12, shifted: false), 0xffc9)
        XCTAssertEqual(Keysyms.keysym(for: .keypad7, shifted: false), 0x37)
        XCTAssertEqual(Keysyms.keysym(for: .keypadAsterisk, shifted: false), 0x2a)
    }

    func testModifiers() {
        // Command → Super_L/R: the reference maps GLFW_KEY_LEFT_SUPER (the
        // Command key under GLFW on macOS) and the Windows key to 0xffeb/0xffec.
        XCTAssertEqual(Keysyms.keysym(for: .keyboardLeftGUI, shifted: false), 0xffeb)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardRightGUI, shifted: false), 0xffec)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardLeftAlt, shifted: false), 0xffe9)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardRightAlt, shifted: false), 0xffea)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardLeftShift, shifted: false), 0xffe1)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardRightShift, shifted: false), 0xffe2)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardLeftControl, shifted: false), 0xffe3)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardRightControl, shifted: false), 0xffe4)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardCapsLock, shifted: false), 0xffe5)
    }

    func testTypedCharacters() {
        XCTAssertEqual(Keysyms.typed("a"), [.init(keysym: 0x61, shift: false)])
        XCTAssertEqual(Keysyms.typed("A"), [.init(keysym: 0x41, shift: true)])
        XCTAssertEqual(Keysyms.typed("!"), [.init(keysym: 0x21, shift: true)])
        XCTAssertEqual(Keysyms.typed("1"), [.init(keysym: 0x31, shift: false)])
        XCTAssertEqual(Keysyms.typed("\n"), [.init(keysym: 0xff0d, shift: false)])
        XCTAssertEqual(Keysyms.typed("\t"), [.init(keysym: 0xff09, shift: false)])
        XCTAssertEqual(Keysyms.typed("é"), [.init(keysym: 0xe9, shift: false)])
        // Beyond Latin-1 the reference's on_char sends the raw code point.
        XCTAssertEqual(Keysyms.typed("€"), [.init(keysym: 0x20ac, shift: false)])
    }

    func testHardwareKeyStateUsesUnshiftedKeysymWhileACommandModifierIsHeld() {
        var s = HardwareKeyState()
        // app.py on_key: with Ctrl/Super/Alt held, letters go as the raw lowercase keysym
        // (US position; the layout's character is ignored, as GLFW key codes are).
        XCTAssertEqual(s.press(.keyboardC, modifiers: [.command, .shift], characters: "C"), 0x63)
        XCTAssertEqual(s.release(.keyboardC), 0x63)
        XCTAssertEqual(s.press(.keyboardQ, modifiers: [.command], characters: "a"), 0x71)   // AZERTY A-key
        XCTAssertEqual(s.press(.keyboardE, modifiers: [.alternate], characters: "\u{b4}"), 0x65)
        XCTAssertEqual(s.press(.keyboardC, modifiers: [.shift]), 0x43)                     // no characters: US table
    }

    func testHardwareKeyStateSendsTheLayoutCharacterWithoutCommandModifiers() {
        // app.py on_char: unmodified printable keys send the layout's final character.
        var s = HardwareKeyState()
        XCTAssertEqual(s.press(.keyboardQ, modifiers: [], characters: "a"), 0x61)          // AZERTY
        XCTAssertEqual(s.press(.keyboardY, modifiers: [], characters: "z"), 0x7a)          // QWERTZ
        XCTAssertEqual(s.press(.keyboard2, modifiers: [.shift], characters: "\""), 0x22)   // UK Shift-2
        XCTAssertEqual(s.press(.keyboardSemicolon, modifiers: [], characters: "\u{f6}"), 0xf6) // German ö
        // Beyond Latin-1: the raw code point, as on_char sends it.
        XCTAssertEqual(s.press(.keyboardF, modifiers: [], characters: "\u{430}"), 0x430)  // Russian а
        // Specials keep the table even though UIKit reports a character for them.
        XCTAssertEqual(s.press(.keyboardReturnOrEnter, modifiers: [], characters: "\r"), 0xff0d)
        XCTAssertEqual(s.press(.keyboardTab, modifiers: [], characters: "\t"), 0xff09)
        // Dead key / empty / control character: fall back to the US table.
        XCTAssertEqual(s.press(.keyboardEqualSign, modifiers: [], characters: ""), 0x3d)
        XCTAssertEqual(s.press(.keyboardH, modifiers: [], characters: "\u{8}"), 0x68)
    }

    func testCapsLockIsForwardedAndLettersAreNotPreCased() {
        var s = HardwareKeyState()
        XCTAssertEqual(s.press(.keyboardCapsLock, modifiers: [.alphaShift]), 0xffe5)
        // The iPad reports the cased character; it is sent as is.
        XCTAssertEqual(s.press(.keyboardA, modifiers: [.alphaShift], characters: "A"), 0x41)
        // Without a character no local caps-lock casing is applied.
        XCTAssertEqual(s.press(.keyboardB, modifiers: [.alphaShift]), 0x62)
    }

    func testISOKeyIsMapped() {
        XCTAssertEqual(Keysyms.keysym(for: .keyboardNonUSBackslash, shifted: false), 0x5c)
        XCTAssertEqual(Keysyms.keysym(for: .keyboardNonUSBackslash, shifted: true), 0x7c)
    }

    func testModifierClassification() {
        for m: UIKeyboardHIDUsage in [.keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl,
                                      .keyboardRightControl, .keyboardLeftAlt, .keyboardRightAlt,
                                      .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock] {
            XCTAssertTrue(Keysyms.isModifier(m), "\(m.rawValue)")
        }
        for k: UIKeyboardHIDUsage in [.keyboardA, .keyboardDeleteOrBackspace, .keyboardLeftArrow, .keyboardF1] {
            XCTAssertFalse(Keysyms.isModifier(k), "\(k.rawValue)")
        }
    }

    func testReleaseSendsTheKeysymThatWentDown() {
        var s = HardwareKeyState()
        XCTAssertEqual(s.press(.keyboardA, modifiers: [.shift]), 0x41)
        // Shift released before the letter: the up must still be 'A'.
        XCTAssertEqual(s.release(.keyboardA), 0x41)
        XCTAssertNil(s.release(.keyboardA))
        XCTAssertNil(s.press(.keyboardPrintScreen, modifiers: []))
    }

    func testReleaseAllReturnsEveryHeldKeysym() {
        var s = HardwareKeyState()
        _ = s.press(.keyboardLeftGUI, modifiers: [])
        _ = s.press(.keyboardV, modifiers: [.command])
        XCTAssertEqual(Set(s.releaseAll()), [0xffeb, 0x76])
        XCTAssertEqual(s.releaseAll(), [])
    }
}
