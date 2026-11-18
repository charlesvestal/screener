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
//   the reference's on_key + on_char do. With no Command/Control/Option held
//   the keysym comes from UIKey.characters — the layout-aware final character
//   (AZERTY, Dvorak, UK Shift-2 = ", German ö, …), the counterpart of GLFW's
//   on_char. Specials (Return, Tab, arrows, …) always use the table, and an
//   empty/control `characters` (dead key) falls back to the US table.
// - Code points: Latin-1 keysyms equal their code points. Beyond Latin-1 the
//   reference's on_char sends the RAW code point (`key_event(True,
//   codepoint)`), not X11's 0x01000000|cp Unicode keysym; we match it
//   (`Keysyms.character(_:)` is the single place to change that if the host
//   turns out to want the 0x01000000 form — untested on screensharingd).
// - While Command/Control/Option is held, letters/digits go as the raw
//   unshifted keysym from the US table (app.py on_key: on_char doesn't fire
//   under a modifier, so it synthesises the lowercase ASCII keysym from the
//   GLFW key code, which is a US-position code).
// - Caps Lock is forwarded to the Mac as its own key (0xffe5) and letters are
//   NOT pre-cased locally from the caps state: the character the iPad reports
//   is sent as is. macOS's Caps Lock doesn't invert Shift, so a Mac that also
//   has Caps Lock on still types the reported case (no double application).
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

    /// The keysym for a typed code point: the raw code point (Latin-1 keysyms
    /// equal their code points; beyond that the reference's on_char also sends
    /// the raw code point rather than 0x01000000 | cp).
    static func character(_ s: Unicode.Scalar) -> UInt32 { s.value }

    /// The layout-aware keysym for UIKey.characters, or nil when it isn't a
    /// single printable character (empty for a dead key, control characters).
    static func character(in characters: String) -> UInt32? {
        let scalars = characters.unicodeScalars
        guard scalars.count == 1, let s = scalars.first else { return nil }
        guard s.value >= 0x20, s.value != 0x7f, !(0xf700...0xf8ff).contains(s.value) else { return nil }
        return character(s)
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
            default: Typed(keysym: character(s), shift: shiftedCharacters.contains(s))
            }
        }
    }

    /// The US-layout unshifted keysym of a shifted printable keysym ("A" → "a",
    /// "?" → "/", "!" → "1"), nil if `keysym` isn't one. A soft-keyboard
    /// character under a sticky ⌘/⌥/⌃ goes as this plus Shift, as a hardware
    /// chord does (⌘⇧/ sends Super + Shift + '/').
    static func usUnshifted(_ keysym: UInt32) -> UInt32? { unshiftOf[keysym] }

    /// The US-layout shifted keysym of an unshifted printable keysym ("a" →
    /// "A", "1" → "!"), nil if it has none. A soft-keyboard character under a
    /// sticky ⇧ alone goes as the final (shifted) character, as hardware does.
    static func usShifted(_ keysym: UInt32) -> UInt32? { shiftOf[keysym] }

    private static let unshiftOf: [UInt32: UInt32] = {
        var m: [UInt32: UInt32] = [:]
        for (_, pair) in printable where pair.0 != pair.1 {
            m[pair.1.unicodeScalars.first!.value] = pair.0.unicodeScalars.first!.value
        }
        return m
    }()

    private static let shiftOf: [UInt32: UInt32] = {
        var m: [UInt32: UInt32] = [:]
        for (_, pair) in printable where pair.0 != pair.1 {
            m[pair.0.unicodeScalars.first!.value] = pair.1.unicodeScalars.first!.value
        }
        return m
    }()

    /// The modifier flag a modifier key sets (nil for Caps Lock and non-modifiers):
    /// used to drop a hardware modifier hold whose key-up never arrived.
    static func modifierFlag(_ usage: UIKeyboardHIDUsage) -> UIKeyModifierFlags? {
        switch usage {
        case .keyboardLeftControl, .keyboardRightControl: .control
        case .keyboardLeftShift, .keyboardRightShift: .shift
        case .keyboardLeftAlt, .keyboardRightAlt: .alternate
        case .keyboardLeftGUI, .keyboardRightGUI: .command
        default: nil
        }
    }

    /// Each chord modifier flag with its left keysym and both sides' keysyms,
    /// in press order (⌃ ⌥ ⇧ ⌘, as StickyModifier).
    static let flagKeysyms: [(flag: UIKeyModifierFlags, left: UInt32, sides: Set<UInt32>)] = [
        (.control, 0xffe3, [0xffe3, 0xffe4]),
        (.alternate, 0xffe9, [0xffe9, 0xffea]),
        (.shift, shiftL, [shiftL, 0xffe2]),
        (.command, superL, [superL, 0xffec]),
    ]

    /// The canonical press order of the left modifier keysyms.
    static let modifierPressOrder: [UInt32] = flagKeysyms.map(\.left)

    private static let shiftedCharacters: Set<Unicode.Scalar> = {
        var s = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
        for (_, pair) in printable where pair.0 != pair.1 { s.insert(pair.1.unicodeScalars.first!) }
        return s
    }()

    /// Shift/Control/Option/Command (left and right) and Caps Lock: never
    /// auto-repeated.
    static func isModifier(_ usage: UIKeyboardHIDUsage) -> Bool {
        usage == .keyboardCapsLock
            || (UIKeyboardHIDUsage.keyboardLeftControl.rawValue...UIKeyboardHIDUsage.keyboardRightGUI.rawValue)
                .contains(usage.rawValue)
    }

    /// Keys with a fixed (non-character) keysym: Return, arrows, F-keys,
    /// modifiers, … Every other key may produce a layout character
    /// (including keys outside the US table, e.g. JIS ろ / ¥).
    static func isSpecial(_ usage: UIKeyboardHIDUsage) -> Bool { special[usage] != nil }

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
            // ISO key next to left Shift (HID 0x64): US-layout value \ | (the
            // layout's real character comes from UIKey.characters when unmodified).
            (.keyboardNonUSBackslash, "\\", "|"),
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
/// first) and held keys can be released when focus is lost. Auto-repeat is
/// driven by RemoteInputView (KeyRepeater): iPadOS delivers one press per
/// physical press.
struct HardwareKeyState {
    private var held: [Int: UInt32] = [:]

    /// The keysym to send as key-down, or nil if the key has none.
    /// `characters`: UIKey.characters (layout-aware), used for printable keys
    /// when no Command/Control/Option is held (on_char vs on_key).
    mutating func press(_ usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags,
                        characters: String = "") -> UInt32? {
        let commandHeld = !modifiers.isDisjoint(with: [.command, .control, .alternate])
        let ks: UInt32?
        if commandHeld {
            ks = Keysyms.keysym(for: usage, shifted: false)
        } else if !Keysyms.isSpecial(usage), let ch = Keysyms.character(in: characters) {
            ks = ch
        } else {
            ks = Keysyms.keysym(for: usage, shifted: modifiers.contains(.shift))
        }
        guard let ks else { return nil }
        held[usage.rawValue] = ks
        return ks
    }

    /// The key is down (its key-up hasn't been seen).
    func isHeld(_ usage: UIKeyboardHIDUsage) -> Bool { held[usage.rawValue] != nil }

    /// The keysym the key went down as (nil if it isn't down).
    func keysym(of usage: UIKeyboardHIDUsage) -> UInt32? { held[usage.rawValue] }

    /// The modifier keys (Shift/Control/Option/Command, either side; not Caps
    /// Lock) currently down.
    var heldModifierUsages: [UIKeyboardHIDUsage] {
        held.keys.compactMap { UIKeyboardHIDUsage(rawValue: $0) }
            .filter { Keysyms.modifierFlag($0) != nil }
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
