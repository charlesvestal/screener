// Ported from iShareScreen src/isharescreen/frontend/desktop/keymap.py
// (GLFW_KEY_TO_X11), frontend/desktop/keyboard_grab.py (_vk_to_keysym,
// _VK_KEYSYM, _KS_*) and the key paths of frontend/desktop/app.py (on_key,
// on_char) (AGPL-3.0)
//
// iPad hardware keys arrive as USB HID usages (UIKey.keyCode); the host's
// RFB key handler wants X11 keysyms (plain 0x04 KeyEvent, down/up).
//
// - Special keys use the reference's table: Return 0xff0d, BackSpace
//   0xff08, Delete (forward) 0xffff, arrows 0xff51–54, F1… 0xffbe…, etc.
// - Command → Super_L/R (0xffeb/0xffec). The reference maps GLFW's
//   KEY_LEFT_SUPER (which IS the Command key under GLFW on macOS) and the
//   Windows key to 0xffeb; the host treats Super as Command. Option → Alt_L/R
//   (0xffe9/0xffea), Control → 0xffe3/4, Shift → 0xffe1/2, CapsLock 0xffe5.
// - Printable keys send the FINAL character keysym ("Apple's RFB key handler
//   expects the final character keysym, not base-char + Shift",
//   keyboard_grab.py), with the physical Shift also sent as its own key, as
//   the reference's on_key + on_char do. The iPad has no layout-aware char
//   callback for hardware keys, so a US layout is assumed (as keyboard_grab's
//   VK table does: "the keysym we send is the US base value").
// - While Command/Control/Option is held, letters/digits go as the raw
//   unshifted keysym (app.py on_key: on_char doesn't fire under a modifier,
//   so it synthesises the lowercase ASCII keysym).
import UIKit

enum Keysyms {
    static let returnKey: UInt32 = 0xff0d
    static let tab: UInt32 = 0xff09
    static let backSpace: UInt32 = 0xff08
    static let escape: UInt32 = 0xff1b
    static let delete: UInt32 = 0xffff
    static let shiftL: UInt32 = 0xffe1
    static let superL: UInt32 = 0xffeb

    /// The keysym for a hardware key, or nil if it has none.
    static func keysym(for usage: UIKeyboardHIDUsage, shifted: Bool) -> UInt32? {
        if let special = special[usage] { return special }
        if let pair = printable[usage] {
            return (shifted ? pair.1 : pair.0).unicodeScalars.first!.value
        }
        return nil
    }

    /// One key press for typed text (the on-screen keyboard).
    struct Typed: Equatable {
        var keysym: UInt32
        /// Wrap the press in Shift_L down/up (uppercase / shifted US symbols).
        var shift: Bool
    }

    /// The key presses that type `ch`. Newline/tab become Return/Tab; other
    /// characters send their code point (Latin-1 keysyms equal their code
    /// points; beyond that the reference's on_char also sends the raw code
    /// point). Shift is added for characters that need it on a US layout.
    static func typed(_ ch: Character) -> [Typed] {
        ch.unicodeScalars.map { s in
            switch s {
            case "\n", "\r": Typed(keysym: returnKey, shift: false)
            case "\t": Typed(keysym: tab, shift: false)
            default: Typed(keysym: s.value, shift: shiftedCharacters.contains(s))
            }
        }
    }

    private static let shiftedCharacters: Set<Unicode.Scalar> = {
        var s = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
        for (_, pair) in printable where pair.0 != pair.1 { s.insert(pair.1.unicodeScalars.first!) }
        return s
    }()

    /// Letters (a–z) are the keys Caps Lock affects.
    static func isLetter(_ usage: UIKeyboardHIDUsage) -> Bool {
        (UIKeyboardHIDUsage.keyboardA.rawValue...UIKeyboardHIDUsage.keyboardZ.rawValue).contains(usage.rawValue)
    }

    private static let special: [UIKeyboardHIDUsage: UInt32] = {
        var m: [UIKeyboardHIDUsage: UInt32] = [
            .keyboardEscape: escape, .keyboardTab: tab, .keyboardDeleteOrBackspace: backSpace,
            .keyboardReturnOrEnter: returnKey, .keypadEnter: returnKey, .keyboardReturn: returnKey,
            .keyboardDeleteForward: delete, .keyboardInsert: 0xff63,
            .keyboardHome: 0xff50, .keyboardEnd: 0xff57, .keyboardPageUp: 0xff55, .keyboardPageDown: 0xff56,
            .keyboardLeftArrow: 0xff51, .keyboardUpArrow: 0xff52, .keyboardRightArrow: 0xff53,
            .keyboardDownArrow: 0xff54,
            .keyboardLeftShift: shiftL, .keyboardRightShift: 0xffe2,
            .keyboardLeftControl: 0xffe3, .keyboardRightControl: 0xffe4,
            .keyboardLeftAlt: 0xffe9, .keyboardRightAlt: 0xffea,
            .keyboardLeftGUI: superL, .keyboardRightGUI: 0xffec,
            .keyboardCapsLock: 0xffe5,
        ]
        let fkeys: [UIKeyboardHIDUsage] = [.keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5,
                                           .keyboardF6, .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10,
                                           .keyboardF11, .keyboardF12, .keyboardF13, .keyboardF14, .keyboardF15,
                                           .keyboardF16, .keyboardF17, .keyboardF18, .keyboardF19, .keyboardF20]
        for (i, k) in fkeys.enumerated() { m[k] = 0xffbe + UInt32(i) }   // F1..F24 → 0xffbe…
        return m
    }()

    /// (unshifted, shifted) for printable keys, US layout.
    private static let printable: [UIKeyboardHIDUsage: (Character, Character)] = {
        var m: [UIKeyboardHIDUsage: (Character, Character)] = [:]
        for i in 0..<26 {
            let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboardA.rawValue + i)!
            let lower = Character(Unicode.Scalar(UInt8(0x61 + i)))
            m[usage] = (lower, Character(lower.uppercased()))
        }
        let digits: [(UIKeyboardHIDUsage, Character, Character)] = [
            (.keyboard1, "1", "!"), (.keyboard2, "2", "@"), (.keyboard3, "3", "#"), (.keyboard4, "4", "$"),
            (.keyboard5, "5", "%"), (.keyboard6, "6", "^"), (.keyboard7, "7", "&"), (.keyboard8, "8", "*"),
            (.keyboard9, "9", "("), (.keyboard0, "0", ")"),
            (.keyboardSpacebar, " ", " "),
            (.keyboardHyphen, "-", "_"), (.keyboardEqualSign, "=", "+"),
            (.keyboardOpenBracket, "[", "{"), (.keyboardCloseBracket, "]", "}"),
            (.keyboardBackslash, "\\", "|"), (.keyboardNonUSPound, "\\", "|"),
            (.keyboardSemicolon, ";", ":"), (.keyboardQuote, "'", "\""),
            (.keyboardGraveAccentAndTilde, "`", "~"),
            (.keyboardComma, ",", "<"), (.keyboardPeriod, ".", ">"), (.keyboardSlash, "/", "?"),
            // Keypad: share the digit / operator keysyms (keyboard_grab.py _VK_KEYSYM).
            (.keypad0, "0", "0"), (.keypad1, "1", "1"), (.keypad2, "2", "2"), (.keypad3, "3", "3"),
            (.keypad4, "4", "4"), (.keypad5, "5", "5"), (.keypad6, "6", "6"), (.keypad7, "7", "7"),
            (.keypad8, "8", "8"), (.keypad9, "9", "9"),
            (.keypadAsterisk, "*", "*"), (.keypadPlus, "+", "+"), (.keypadHyphen, "-", "-"),
            (.keypadPeriod, ".", "."), (.keypadSlash, "/", "/"), (.keypadEqualSign, "=", "="),
        ]
        for (u, a, b) in digits { m[u] = (a, b) }
        return m
    }()
}

/// Turns hardware key presses into keysyms and remembers what went down, so
/// every key-up carries the keysym of its key-down (Shift may be released
/// first) and held keys can be released when focus is lost. Key repeat is
/// the Mac's job: only down/up are sent.
struct HardwareKeyState {
    private var held: [Int: UInt32] = [:]

    /// The keysym to send as key-down, or nil if the key has none.
    mutating func press(_ usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> UInt32? {
        let commandHeld = !modifiers.isDisjoint(with: [.command, .control, .alternate])
        var shifted = modifiers.contains(.shift)
        if Keysyms.isLetter(usage), modifiers.contains(.alphaShift) { shifted.toggle() }
        if commandHeld { shifted = false }
        guard let ks = Keysyms.keysym(for: usage, shifted: shifted) else { return nil }
        held[usage.rawValue] = ks
        return ks
    }

    /// The keysym to send as key-up (nil if the key never went down).
    mutating func release(_ usage: UIKeyboardHIDUsage) -> UInt32? {
        held.removeValue(forKey: usage.rawValue)
    }

    /// Every held keysym (for key-ups when focus is lost); clears the state.
    mutating func releaseAll() -> [UInt32] {
        defer { held.removeAll() }
        return Array(held.values)
    }
}
