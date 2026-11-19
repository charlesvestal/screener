// Sticky modifiers for touch-only use (the floating control menu).
//
// Each of ⌘ ⌥ ⌃ ⇧ fn is off, latched or locked:
// - a tap toggles off ↔ latched; a second tap on a latched modifier within
//   300 ms locks it; any tap on a locked one turns it off;
// - a latched modifier applies to the next non-modifier key OR pointer click
//   (so ⌘-click and ⌥-drag work from touch) and then clears; a locked one
//   stays until tapped.
// The active ⌃ ⌥ ⇧ ⌘ are pressed (Mac order) around the key or click and
// released in reverse. Modifiers the hardware keyboard already holds are not
// pressed again (union, no double-downs).
//
// fn has no keysym the host understands. As on a Mac keyboard it is a local
// layer: with fn active the special-keys panel sends Home/End/PgUp/PgDn for
// the arrows and forward Delete for Delete (SpecialKey.withFn).
import Foundation
import Observation

enum StickyModifier: Int, CaseIterable, Sendable, Hashable {
    // Declaration order = press order (⌃ ⌥ ⇧ ⌘, as macOS lists them).
    case control, option, shift, command, fn

    /// The left-hand keysym (Keysyms), nil for fn (a local layer).
    var keysym: UInt32? {
        switch self {
        case .control: 0xffe3
        case .option: Keysyms.optionL       // Meta_L: the host's Option (Alt_L is Command)
        case .shift: Keysyms.shiftL
        case .command: Keysyms.superL
        case .fn: nil
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .fn: "fn"
        }
    }

    var name: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        case .fn: "Function"
        }
    }

    /// Order shown in the menu (as on a Mac keyboard's bottom row, reversed).
    static let displayOrder: [StickyModifier] = [.command, .option, .control, .shift, .fn]
}

enum StickyLevel: Sendable, Equatable {
    case off, latched, locked
}

/// One key event on the wire.
struct KeyStroke: Equatable, Sendable, CustomStringConvertible {
    var down: Bool
    var keysym: UInt32

    static func down(_ k: UInt32) -> KeyStroke { KeyStroke(down: true, keysym: k) }
    static func up(_ k: UInt32) -> KeyStroke { KeyStroke(down: false, keysym: k) }

    var description: String { String(format: "%x%@", keysym, down ? "↓" : "↑") }
}

struct ModifierState: Equatable, Sendable {
    static let doubleTapWindow: TimeInterval = 0.3

    private var levels: [StickyModifier: StickyLevel] = [:]
    /// When each modifier was last latched by a tap (double-tap detection).
    private var latchedAt: [StickyModifier: TimeInterval] = [:]

    subscript(_ m: StickyModifier) -> StickyLevel { levels[m] ?? .off }

    mutating func tap(_ m: StickyModifier, at now: TimeInterval) {
        switch self[m] {
        case .off:
            levels[m] = .latched
            latchedAt[m] = now
        case .latched:
            if let t = latchedAt[m], now - t < Self.doubleTapWindow {
                levels[m] = .locked
            } else {
                levels[m] = .off
            }
            latchedAt[m] = nil
        case .locked:
            levels[m] = .off
        }
    }

    /// After a non-modifier key or a click: latched modifiers clear.
    mutating func consumeLatched() {
        for (m, l) in levels where l == .latched { levels[m] = .off }
        latchedAt.removeAll()
    }

    mutating func clearAll() {
        levels.removeAll()
        latchedAt.removeAll()
    }

    var isEmpty: Bool { active.isEmpty }
    var active: [StickyModifier] { StickyModifier.allCases.filter { self[$0] != .off } }
    var fnActive: Bool { self[.fn] != .off }
    /// ⌘, ⌥ or ⌃ is active: letters go as their unshifted US keysym, as with
    /// a hardware chord.
    var commandLikeActive: Bool { [.command, .option, .control].contains { self[$0] != .off } }

    /// The modifier keysyms to press around the next key or click (⌃ ⌥ ⇧ ⌘
    /// order), minus those already held by the hardware keyboard.
    func pressedKeysyms(excluding physical: Set<UInt32> = []) -> [UInt32] {
        StickyModifier.allCases.compactMap { m in
            guard self[m] != .off, let k = m.keysym, !physical.contains(k) else { return nil }
            return k
        }
    }

    /// `inner` (a key press, a click, …) wrapped in the sticky modifiers'
    /// downs and, reversed, their ups.
    func wrap(_ inner: [KeyStroke], physical: Set<UInt32> = []) -> [KeyStroke] {
        let mods = pressedKeysyms(excluding: physical)
        return mods.map(KeyStroke.down) + inner + mods.reversed().map(KeyStroke.up)
    }

    /// One key press (down, up) wrapped in the sticky modifiers.
    func wrap(keysym: UInt32, physical: Set<UInt32> = []) -> [KeyStroke] {
        wrap([.down(keysym), .up(keysym)], physical: physical)
    }
}

/// The session's shared sticky-modifier state: the floating menu taps it,
/// RemoteInputView applies (and consumes) it on keys, typed text and clicks.
@MainActor
@Observable
final class StickyModifiers {
    var state = ModifierState()
    @ObservationIgnored private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func tap(_ m: StickyModifier) { state.tap(m, at: now()) }

    /// Clears latched modifiers (no-op write when none is latched, so
    /// observers don't churn on every key).
    func consumeLatched() {
        guard state.active.contains(where: { state[$0] == .latched }) else { return }
        state.consumeLatched()
    }

    func clearAll() {
        guard !state.isEmpty else { return }
        state.clearAll()
    }
}

/// A key in the special-keys panel.
enum SpecialKey: Hashable, Sendable {
    case escape, tab, backspace, forwardDelete
    case left, up, right, down
    case home, end, pageUp, pageDown
    case function(Int)          // F1…F12

    static let functionRow: [SpecialKey] = (1...12).map { .function($0) }

    var keysym: UInt32 {
        switch self {
        case .escape: Keysyms.escape
        case .tab: Keysyms.tab
        case .backspace: Keysyms.backSpace
        case .forwardDelete: Keysyms.delete
        case .left: 0xff51
        case .up: 0xff52
        case .right: 0xff53
        case .down: 0xff54
        case .home: 0xff50
        case .end: 0xff57
        case .pageUp: 0xff55
        case .pageDown: 0xff56
        case .function(let n): 0xffbe + UInt32(max(1, min(12, n)) - 1)
        }
    }

    /// The fn layer, as on a Mac keyboard: fn+←/→ = Home/End, fn+↑/↓ =
    /// Page Up/Down, fn+Delete = forward Delete. Other keys are unchanged.
    var withFn: SpecialKey {
        switch self {
        case .left: .home
        case .right: .end
        case .up: .pageUp
        case .down: .pageDown
        case .backspace: .forwardDelete
        default: self
        }
    }

    var label: String {
        switch self {
        case .escape: "esc"
        case .tab: "⇥"
        case .backspace: "⌫"
        case .forwardDelete: "⌦"
        case .left: "←"
        case .up: "↑"
        case .right: "→"
        case .down: "↓"
        case .home: "home"
        case .end: "end"
        case .pageUp: "pg up"
        case .pageDown: "pg dn"
        case .function(let n): "F\(n)"
        }
    }

    var accessibilityName: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .backspace: "Delete"
        case .forwardDelete: "Forward Delete"
        case .left: "Left Arrow"
        case .up: "Up Arrow"
        case .right: "Right Arrow"
        case .down: "Down Arrow"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .function(let n): "F\(n)"
        }
    }
}
