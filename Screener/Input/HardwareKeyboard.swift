// Hardware keyboard input from two sources, merged (KeyArbiter).
//
// Why: UIKit delivers hardware keys through the responder chain, and some
// chords never reach pressesBegan — iPadOS's text / focus machinery takes
// ⌥← ⌥→ ⌘← ⌘→ ⌘↑ ⌘↓ (and ⇧ variants), ⌥⌫ and ⌘⌫ as caret moves and
// deletions before any view sees them. GameController's GCKeyboard reports
// every physical key down/up (modifiers too) whatever the responder chain
// does, so while a GCKeyboard is connected it is the source of truth for
// WHICH key went down or up and WHEN. UIKit still matters for one thing GC
// cannot give: the layout's character (UIKey.characters — AZERTY, Dvorak,
// German ö…), which an unmodified printable key needs (Keysyms header).
//
// Arbitration, per key press (`KeyArbiter`):
//   - GC down of a key that needs no character (modifiers, Caps Lock,
//     specials — arrows, Delete, Return, F-keys… — or any key while ⌘/⌃
//     is held) is sent at once; its UIKit press, if one comes, is swallowed.
//   - GC down of a printable key without ⌘/⌃ (unmodified, ⇧, or ⌥ — whose
//     Option character the host must get, Keysyms) waits up to
//     `partnerWait` for its UIKit press to take the layout character from
//     it; if none comes (the text system ate it, or it arrived first and was
//     already matched) the US-table keysym is sent.
//   - A UIKit press while a GC keyboard is connected waits up to
//     `partnerWait` for its GC report (then the GC press owns the key); if
//     none comes (GC not delivering) it is sent as before — UIKit stays the
//     fallback, nothing is lost.
//   - Without a GC keyboard, UIKit presses go straight through (the old path).
//   - Events are emitted strictly in arrival order: a waiting key holds back
//     everything after it (at most `partnerWait`), so a fast "ab" or ⌥ + ←
//     never reorders.
//   - fn layer: UIKit reports the keyboard's translation (fn+← = Home,
//     fn+⌫ = forward Delete, …) where GC reports the physical key; an arrow /
//     Delete without ⌘/⌃/⌥ waits for UIKit like a printable key, and UIKit's
//     translated key is sent (`fnAliases`).
//   - Any key-up (from either source) releases the key; the other source's
//     later up is ignored. Key commands claimed from iPadOS (⌘W, ⌘Q, …,
//     `uikitTap`) are swallowed when GC reports the same key (it sends the
//     real down/up), and otherwise sent as a tap after `partnerWait`.
//   - `recentGCDown`: the on-screen keyboard proxy drops insertText /
//     deleteBackward that a GC key press produced within `dedupeWindow`.
// Repeat stays RemoteInputView's KeyRepeater (the downs go through the same
// keyDown), so a held ⌥⌫ repeats with ⌥ held. Everything held is released on
// focus loss and when the GC keyboard disconnects.
//
// Diagnostics: DEBUG builds log every hardware key event (source, HID
// usage, flags) and the keysym sent; Settings → Input → Keyboard Tester
// shows the last 10 events on screen (KeyTesterLog) in any build.
import GameController
import UIKit

/// One key event the arbiter decided to send.
struct ArbitratedKey: Equatable {
    enum Kind: Equatable { case down, up, tap }
    enum Source: String, Equatable { case gc = "GC", uikit = "UIKit" }

    var kind: Kind
    var usage: UIKeyboardHIDUsage
    var flags: UIKeyModifierFlags
    var characters: String
    var source: Source
    /// UIKit reported this press too (diagnostics: a GC-only ⌥← means UIKit ate it).
    var uikitSaw = false
}

@MainActor
final class KeyArbiter {
    /// How long one source waits for the other's report of the same press.
    static let partnerWait: TimeInterval = 0.06
    /// insertText / deleteBackward this soon after a GC key-down are its echo.
    static let dedupeWindow: TimeInterval = 0.05
    /// A late GC report this long after a UIKit-only press is still its echo.
    static let lateEcho: TimeInterval = 0.5
    /// fn-layer keys UIKit reports (the keyboard's translation) → the
    /// physical key GC reports for the same press. The UIKit key is sent.
    static let fnAliases: [UIKeyboardHIDUsage: UIKeyboardHIDUsage] = [
        .keyboardHome: .keyboardLeftArrow, .keyboardEnd: .keyboardRightArrow,
        .keyboardPageUp: .keyboardUpArrow, .keyboardPageDown: .keyboardDownArrow,
        .keyboardDeleteForward: .keyboardDeleteOrBackspace,
    ]
    private static let aliasBases = Set(fnAliases.values)

    /// A GameController keyboard is connected and reporting to us.
    var gcActive = false {
        didSet { if !gcActive, oldValue { flushAll() } }
    }
    var emit: (ArbitratedKey) -> Void
    var now: () -> TimeInterval

    private let schedule: KeyRepeater.Schedule

    private struct Item {
        var kind: ArbitratedKey.Kind
        /// The press's identity: GC's key once GC reported it, else UIKit's.
        var key: UIKeyboardHIDUsage
        /// The key sent (UIKit's fn-layer translation when it reported one).
        var send: UIKeyboardHIDUsage
        /// GC reported this press.
        var gcSeen: Bool
        /// GC's modifier state when it reported the press (not when it is sent:
        /// a ⌘ pressed after a waiting "a" must not turn it into ⌘A).
        var gcFlags: UIKeyModifierFlags = []
        /// UIKit's flags / characters, if UIKit reported it.
        var uikit: (flags: UIKeyModifierFlags, characters: String)?
        var ready: Bool
        var deadline: TimeInterval
    }

    private struct Held {
        var gc: Bool
        var sent: UIKeyboardHIDUsage
    }

    private var queue: [Item] = []
    /// Keys down through the arbiter, by identity.
    private var held: [Int: Held] = [:]
    /// Modifier keys GC reports down (their flags drive GC presses).
    private var gcModifiers: Set<Int> = []
    private var timer: (() -> Void)?
    private var lastGCDown: (usage: UIKeyboardHIDUsage, at: TimeInterval)?
    /// Keys sent from UIKit alone (GC silent past `partnerWait`), and when:
    /// a GC report arriving late for one is its echo, not a new press.
    private var uikitOnlyAt: [Int: TimeInterval] = [:]
    /// GC presses recognised as late echoes: their up is dropped too.
    private var swallowedGC: Set<Int> = []
    /// UIKit fn-layer presses dropped because GC already sent the physical
    /// key: their up is dropped too.
    private var droppedUIKit: Set<Int> = []

    init(schedule: @escaping KeyRepeater.Schedule = KeyRepeater.runLoopTimer,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (ArbitratedKey) -> Void = { _ in }) {
        self.schedule = schedule
        self.now = now
        self.emit = emit
    }

    /// The modifier flags of the modifier keys GC reports down.
    var gcFlags: UIKeyModifierFlags {
        var f: UIKeyModifierFlags = []
        for raw in gcModifiers {
            if let u = UIKeyboardHIDUsage(rawValue: raw), let flag = Keysyms.modifierFlag(u) { f.insert(flag) }
        }
        return f
    }

    // MARK: input

    /// GCKeyboardInput's keyChangedHandler (HID usage = GCKeyCode.rawValue).
    func gc(_ usage: UIKeyboardHIDUsage, pressed: Bool) {
        let k = usage.rawValue
        if Keysyms.modifierFlag(usage) != nil {
            if pressed { gcModifiers.insert(k) } else { gcModifiers.remove(k) }
        }
        guard pressed else {
            if swallowedGC.remove(k) == nil { enqueueUp(usage) }
            return drain()
        }
        if held[k] == nil, pendingDown(usage) == nil, let t = uikitOnlyAt.removeValue(forKey: k),
           now() - t <= Self.lateEcho {
            swallowedGC.insert(k)                         // UIKit already sent this press
            return
        }
        lastGCDown = (usage, now())
        if let i = queue.lastIndex(where: { $0.kind != .up && !$0.gcSeen
                                            && ($0.key == usage || Self.fnAliases[$0.key] == usage) }) {
            // UIKit came first (its fn translation, too): GC owns the press now.
            queue[i].key = usage
            queue[i].gcSeen = true
            queue[i].gcFlags = gcFlags
            if queue[i].kind == .tap { queue[i].kind = .down }
            queue[i].ready = true
            return drain()
        }
        if held[k] != nil || pendingDown(usage) != nil { return }       // already down
        let flags = gcFlags
        let chord = !flags.isDisjoint(with: [.command, .control, .alternate])
        let waits = Self.needsCharacter(usage, flags: flags) || (Self.aliasBases.contains(usage) && !chord)
        queue.append(Item(kind: .down, key: usage, send: usage, gcSeen: true, gcFlags: flags, uikit: nil,
                          ready: !waits, deadline: now() + Self.partnerWait))
        drain()
    }

    /// A UIKit press (pressesBegan / Ended / Cancelled). Only call while
    /// `gcActive`; otherwise UIKit keys take the direct path.
    func uikit(_ usage: UIKeyboardHIDUsage, down: Bool, flags: UIKeyModifierFlags, characters: String) {
        let k = usage.rawValue
        guard down else {
            if droppedUIKit.remove(k) != nil { return }
            if let id = identity(sending: usage) { enqueueUp(id) }
            return drain()
        }
        if let i = queue.lastIndex(where: { $0.kind != .up && $0.uikit == nil
                                            && ($0.key == usage || ($0.gcSeen && Self.fnAliases[usage] == $0.key)) }) {
            queue[i].uikit = (flags, characters)
            queue[i].send = usage                         // the fn translation, if any
            if queue[i].gcSeen { queue[i].ready = true }
            return drain()
        }
        if held[k] != nil || identity(sending: usage) != nil { return }   // GC already sent it: its echo
        if let base = Self.fnAliases[usage], held[base.rawValue]?.gc == true {
            droppedUIKit.insert(k)                        // GC sent the physical key already (fn + chord)
            return
        }
        queue.append(Item(kind: .down, key: usage, send: usage, gcSeen: false, uikit: (flags, characters),
                          ready: false, deadline: now() + Self.partnerWait))
        drain()
    }

    /// A key command claimed from iPadOS (no key-up follows). Swallowed if
    /// GC reports (or reported) the key; else a tap after `partnerWait`.
    func uikitTap(_ usage: UIKeyboardHIDUsage, flags: UIKeyModifierFlags) {
        if let i = pendingDown(usage) {
            if queue[i].uikit == nil { queue[i].uikit = (flags, "") }
            if queue[i].gcSeen { queue[i].ready = true }
            return drain()
        }
        if held[usage.rawValue] != nil { return }
        queue.append(Item(kind: .tap, key: usage, send: usage, gcSeen: false, uikit: (flags, ""), ready: false,
                          deadline: now() + Self.partnerWait))
        drain()
    }

    /// True if GC reported a key-down matching `matches` within `dedupeWindow`
    /// (the on-screen keyboard's echo of a hardware key).
    func recentGCDown(_ matches: (UIKeyboardHIDUsage) -> Bool) -> Bool {
        guard gcActive, let last = lastGCDown else { return false }
        return now() - last.at <= Self.dedupeWindow && matches(last.usage)
    }

    /// Forgets everything (focus loss: RemoteInputView releases the keys).
    func reset() {
        timer?()
        timer = nil
        queue.removeAll()
        held.removeAll()
        uikitOnlyAt.removeAll()
        swallowedGC.removeAll()
        droppedUIKit.removeAll()
    }

    /// The keys currently down through the arbiter (as sent).
    var heldUsages: [UIKeyboardHIDUsage] { held.values.map(\.sent) }

    // MARK: arbitration

    /// A printable key without ⌘/⌃: its keysym comes from the layout
    /// character (under Option, the Option character: Keysyms.optionCharacter).
    static func needsCharacter(_ usage: UIKeyboardHIDUsage, flags: UIKeyModifierFlags) -> Bool {
        !Keysyms.isModifier(usage) && !Keysyms.isSpecial(usage)
            && flags.isDisjoint(with: [.command, .control])
    }

    private func pendingDown(_ key: UIKeyboardHIDUsage) -> Int? {
        queue.lastIndex { $0.key == key && $0.kind != .up }
    }

    /// The identity of the press that sends (or will send) `usage`.
    private func identity(sending usage: UIKeyboardHIDUsage) -> UIKeyboardHIDUsage? {
        if let i = queue.lastIndex(where: { $0.kind != .up && $0.send == usage }) { return queue[i].key }
        if let (k, _) = held.first(where: { $0.value.sent == usage }) { return UIKeyboardHIDUsage(rawValue: k) }
        return nil
    }

    private func enqueueUp(_ key: UIKeyboardHIDUsage) {
        if let i = pendingDown(key) {
            queue[i].ready = true                        // decide it now: its up is here
            if queue[i].kind == .tap { return }          // a tap carries its own up
        } else if held[key.rawValue] == nil {
            return                                       // never went down here (or already up)
        }
        queue.append(Item(kind: .up, key: key, send: key, gcSeen: false, uikit: nil, ready: true, deadline: 0))
    }

    private func drain() {
        while let head = queue.first, head.ready || now() >= head.deadline {
            queue.removeFirst()
            send(head)
        }
        timer?()
        timer = nil
        if let head = queue.first {
            timer = schedule(max(0, head.deadline - now())) { [weak self] in
                guard let self else { return }
                self.timer = nil
                // The head's partner never came: decide it as it stands.
                if !self.queue.isEmpty { self.queue[0].ready = true }
                self.drain()
            }
        }
    }

    private func flushAll() {
        for i in queue.indices { queue[i].ready = true }
        drain()
    }

    private func send(_ item: Item) {
        let k = item.key.rawValue
        switch item.kind {
        case .up:
            guard let h = held.removeValue(forKey: k) else { return }
            emit(ArbitratedKey(kind: .up, usage: h.sent, flags: [], characters: "", source: h.gc ? .gc : .uikit))
        case .down, .tap:
            // A GC press uses GC's modifier state (it saw every modifier key);
            // UIKit's characters when it reported the press.
            let flags = item.gcSeen ? item.gcFlags : (item.uikit?.flags ?? [])
            let chars = item.uikit?.characters ?? ""
            let source: ArbitratedKey.Source = item.gcSeen ? .gc : .uikit
            if !item.gcSeen, gcActive { uikitOnlyAt[k] = now() }
            if item.kind == .tap, !item.gcSeen {
                emit(ArbitratedKey(kind: .tap, usage: item.send, flags: flags, characters: chars, source: source,
                                   uikitSaw: true))
                return
            }
            held[k] = Held(gc: item.gcSeen, sent: item.send)
            emit(ArbitratedKey(kind: .down, usage: item.send, flags: flags, characters: chars, source: source,
                               uikitSaw: item.uikit != nil))
        }
    }
}

/// The connected GameController keyboard, feeding a KeyArbiter while
/// `enabled` (RemoteInputView: in a window with a session).
@MainActor
final class GCKeyboardSource {
    var enabled = false {
        didSet { if enabled != oldValue { update() } }
    }
    /// A key changed (HID usage, pressed).
    var onKey: ((UIKeyboardHIDUsage, Bool) -> Void)?
    /// The keyboard connected (true) / disconnected (false) while enabled.
    var onAvailability: ((Bool) -> Void)?

    private var attached: GCKeyboard?
    /// The source whose handler is installed (the one keyboard has one
    /// handler: a session view being torn down must not clear its successor's).
    private static weak var installed: GCKeyboardSource?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed(_:)), name: .GCKeyboardDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(changed(_:)), name: .GCKeyboardDidDisconnect, object: nil)
    }

    var isAttached: Bool { attached != nil }

    @objc nonisolated private func changed(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    private func update() {
        let want = enabled ? GCKeyboard.coalesced : nil
        guard want !== attached else { return }
        if let old = attached, Self.installed === self { old.keyboardInput?.keyChangedHandler = nil }
        attached = want
        if let kb = want {
            Self.installed = self
            kb.handlerQueue = .main
            kb.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
                MainActor.assumeIsolated {
                    guard let self, let usage = UIKeyboardHIDUsage(rawValue: code.rawValue) else { return }
                    self.onKey?(usage, pressed)
                }
            }
        }
        onAvailability?(want != nil)
    }
}

/// The on-screen Keyboard Tester's last events (Settings → Input).
@MainActor
final class KeyTesterLog {
    static let capacity = 10
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    func clear() { lines.removeAll() }

    /// "⌃⌥⇧⌘" for the chord flags in `flags`.
    static func symbols(_ flags: UIKeyModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.alternate) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}
