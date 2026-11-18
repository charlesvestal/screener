// What the floating control menu does, separate from how it looks, so every
// action is unit-tested against a fake sink (ShortcutActionsTests).
//
// - Sticky modifiers: shared with RemoteInputView (StickyModifiers), which
//   applies them to hardware keys, soft-keyboard text and clicks.
// - Special keys: the fn layer remaps the key (SpecialKey.withFn), the sticky
//   modifiers are held around it, and a held key repeats like a hardware key
//   (KeyRepeater: 500 ms, then ~30 Hz).
// - Shortcut actions: declarative chords (ShortcutActions). ⌘Tab keeps ⌘
//   held across taps so the Mac's app switcher stays up.
// - Type Password: types the session's in-memory password, then Return. The
//   password is read on demand from the coordinator and never stored here or
//   logged.
import CoreGraphics
import Foundation
import Observation

/// Where the menu's keys go. RemoteInputView implements it; modifier holds
/// are reference-counted there with the hardware keyboard's own modifiers,
/// so the Mac never sees a modifier pressed twice.
@MainActor
protocol RemoteKeySink: AnyObject {
    /// A non-modifier key event, sent as is.
    func sendKey(down: Bool, keysym: UInt32)
    /// Holds a modifier down.
    func holdModifier(_ keysym: UInt32)
    /// Releases one hold of a modifier.
    func releaseModifier(_ keysym: UInt32)
}

@MainActor
@Observable
final class ControlMenuModel {
    static let appSwitcherIdleRelease: TimeInterval = 1.5

    let modifiers: StickyModifiers
    @ObservationIgnored weak var sink: (any RemoteKeySink)?
    /// The session's password (in memory only); nil/empty disables Type Password.
    @ObservationIgnored var password: () -> String? = { nil }
    /// Find Cursor: shows, centres and enlarges the remote cursor (RemoteInputView).
    @ObservationIgnored var onFindCursor: (() -> Void)?

    /// ⌘ is being held for the app switcher.
    private(set) var appSwitcherActive = false
    /// The remote pointer is over the pill's resting frame: the pill steps aside.
    private(set) var pointerOverPill = false
    /// The collapsed pill's resting frame (window coordinates, not moved aside).
    @ObservationIgnored var pillRestingFrame: CGRect = .null

    @ObservationIgnored private let schedule: KeyRepeater.Schedule
    @ObservationIgnored private let repeater: KeyRepeater
    @ObservationIgnored private var cancelAppSwitcherTimer: (() -> Void)?
    /// The special key being held and the modifiers held with it.
    @ObservationIgnored private var heldSpecial: (keysym: UInt32, modifiers: [UInt32])?

    init(modifiers: StickyModifiers = StickyModifiers(), schedule: @escaping KeyRepeater.Schedule = KeyRepeater.runLoopTimer) {
        self.modifiers = modifiers
        self.schedule = schedule
        repeater = KeyRepeater(schedule: schedule)
        repeater.onRepeat = { [weak self] ks in self?.sink?.sendKey(down: true, keysym: ks) }
    }

    // MARK: modifiers

    func tapModifier(_ m: StickyModifier) { modifiers.tap(m) }

    // MARK: special keys

    /// A special key went down (finger down on its button).
    func specialKeyDown(_ key: SpecialKey) {
        specialKeyUp()
        endAppSwitcher()
        let state = modifiers.state
        let resolved = state.fnActive ? key.withFn : key
        let mods = state.pressedKeysyms()
        for m in mods { sink?.holdModifier(m) }
        sink?.sendKey(down: true, keysym: resolved.keysym)
        heldSpecial = (resolved.keysym, mods)
        repeater.keyDown(usage: Int(resolved.keysym), keysym: resolved.keysym)
        modifiers.consumeLatched()
    }

    /// The held special key went up (finger lifted or the touch cancelled).
    func specialKeyUp() {
        repeater.cancel()
        guard let held = heldSpecial else { return }
        heldSpecial = nil
        sink?.sendKey(down: false, keysym: held.keysym)
        for m in held.modifiers.reversed() { sink?.releaseModifier(m) }
    }

    // MARK: shortcuts

    func perform(_ action: ShortcutAction) {
        specialKeyUp()
        if action == .appSwitcher {
            appSwitcherTap()
            return
        }
        endAppSwitcher()
        let chord = action.chord
        for m in chord.modifiers { sink?.holdModifier(m) }
        sink?.sendKey(down: true, keysym: chord.key)
        sink?.sendKey(down: false, keysym: chord.key)
        for m in chord.modifiers.reversed() { sink?.releaseModifier(m) }
    }

    private func appSwitcherTap() {
        let chord = ShortcutAction.appSwitcher.chord
        if !appSwitcherActive {
            for m in chord.modifiers { sink?.holdModifier(m) }
            appSwitcherActive = true
        }
        sink?.sendKey(down: true, keysym: chord.key)
        sink?.sendKey(down: false, keysym: chord.key)
        cancelAppSwitcherTimer?()
        cancelAppSwitcherTimer = schedule(Self.appSwitcherIdleRelease) { [weak self] in
            self?.cancelAppSwitcherTimer = nil
            self?.endAppSwitcher()
        }
    }

    /// Releases ⌘ if the app switcher holds it.
    func endAppSwitcher() {
        cancelAppSwitcherTimer?()
        cancelAppSwitcherTimer = nil
        guard appSwitcherActive else { return }
        appSwitcherActive = false
        for m in ShortcutAction.appSwitcher.chord.modifiers.reversed() { sink?.releaseModifier(m) }
    }

    /// The expanded panel closed: nothing the menu holds stays down.
    func menuDidCollapse() {
        specialKeyUp()
        endAppSwitcher()
    }

    /// RemoteInputView released everything on the wire (focus loss,
    /// teardown): forget what the menu held without sending it again.
    func inputWasReleased() {
        repeater.cancel()
        heldSpecial = nil
        cancelAppSwitcherTimer?()
        cancelAppSwitcherTimer = nil
        appSwitcherActive = false
    }

    // MARK: pointer avoidance

    /// RemoteInputView moved the pointer (window coordinates; nil = hidden).
    /// Only a change of "over the pill" is published, not every move.
    func pointerMoved(to point: CGPoint?) {
        let over = point.map { pillRestingFrame.insetBy(dx: -16, dy: -16).contains($0) } ?? false
        if over != pointerOverPill { pointerOverPill = over }
    }

    // MARK: Find Cursor

    func findCursor() { onFindCursor?() }

    // MARK: Type Password

    var canTypePassword: Bool { !(password() ?? "").isEmpty }

    /// Types the session password and Return (sticky modifiers are neither
    /// applied nor consumed). False, sending nothing, without a password.
    @discardableResult
    func typePassword() -> Bool {
        guard let pw = password(), !pw.isEmpty, let sink else { return false }
        specialKeyUp()
        endAppSwitcher()
        for ch in pw {
            for t in Keysyms.typed(ch) {
                if t.shift { sink.holdModifier(Keysyms.shiftL) }
                sink.sendKey(down: true, keysym: t.keysym)
                sink.sendKey(down: false, keysym: t.keysym)
                if t.shift { sink.releaseModifier(Keysyms.shiftL) }
            }
        }
        sink.sendKey(down: true, keysym: Keysyms.returnKey)
        sink.sendKey(down: false, keysym: Keysyms.returnKey)
        return true
    }
}
