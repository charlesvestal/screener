// Ported in part from iShareScreen src/isharescreen/frontend/desktop/app.py
// (on_cursor_pos, on_mouse_button, on_scroll, on_key, on_char,
// on_cursor_enter) (AGPL-3.0)
//
// Transparent view over the video that turns iPad input into host input
// (InputController) and moves the rendered host cursor (RemoteCursor).
//
// Pointer (trackpad / mouse, indirect):
//   - UIPointerInteraction hides the system pointer while a host cursor
//     shape is known (the host cursor is drawn instead); without one the
//     system pointer stays as the fallback, as the reference falls back to
//     the OS cursor on a cache miss. This only applies inside the fitted
//     video rect (regionFor/styleFor): over the letterbox the system pointer
//     always shows, and a pure hover there sends nothing (movePointer).
//   - UIHoverGestureRecognizer: movement with no button held (sends the
//     current mask, as on_cursor_pos does); leaving the view hides the
//     host cursor (on_cursor_enter).
//   - Clicks and drags arrive as `.indirectPointer` touches; the button mask
//     comes from UIEvent.buttonMask (primary → left, secondary → right,
//     button 3 → middle) and is sent on every change (on_mouse_button).
//   - Scroll: a two-finger trackpad pan (`.continuous`) maps finger travel
//     1:1 to host pixels (PixelScroll); a wheel (`.discrete`) goes through
//     the reference's wheel curve (WheelScroll). Vertical only, as the
//     reference.
// Touch (direct):
//   tap = left click at the point; two-finger tap = right click; long press
//   (0.4 s) then drag = left-button drag; two-finger pan = scroll. The host
//   cursor follows the touch.
// Keyboard:
//   - Hardware keys via pressesBegan/Ended (UIKey.keyCode + modifierFlags +
//     characters → HardwareKeyState / Keysyms: layout-aware character when
//     no Cmd/Ctrl/Opt is held, US table otherwise).
//   - Auto-repeat: iPadOS sends no repeats, so the most recently pressed
//     non-modifier key re-sends its key-down (no key-up between) after 500 ms,
//     then every ~33 ms, as the reference forwards glfw.REPEAT (KeyRepeater).
//   - On-screen keyboard: a transparent (alpha 0, not isHidden — an
//     invisible-but-unhidden view is a plain, fully supported responder)
//     UIKeyInput view becomes first responder when `softwareKeyboardVisible`;
//     typed characters go as keysym down/up (Shift added for uppercase /
//     shifted symbols), delete as BackSpace.
// Nothing sticks on the host: held keys (key-ups) and pointer buttons
// (buttons 0 at the last host position) are released when focus is lost,
// the app resigns active or the view's scene deactivates, before `input` is
// switched (on the OLD controller), and on `releaseAll()` (session teardown).
// Sticky modifiers (the floating menu's ⌘ ⌥ ⌃ ⇧, `modifiers`) are held
// around the next hardware key, soft-keyboard character, Delete, or pointer
// click/drag (latched ones then clear). Every modifier hold — hardware,
// sticky, the menu's shortcuts — is reference-counted per keysym, so the Mac
// sees one down and one up however many sources hold it (no double-downs).
// ⌘⌥M toggles the floating menu (a UIKeyCommand; the M is not forwarded).
//
// Modifier chords on every key path — the Mac sees, for e.g. ⌥⌫:
//   Alt_L↓ BackSpace↓ [BackSpace↓ … while held] BackSpace↑ Alt_L↑
//   - Hardware: the modifier keys are forwarded as their own holds. Each
//     non-modifier key-down is also checked against UIKey.modifierFlags:
//     a modifier the flags report but whose key-down never reached us (held
//     before focus arrived, eaten by iPadOS) is held around the key, and a
//     hardware modifier hold whose flag is gone (its key-up was lost) is
//     released — the Mac never keeps a stuck ⌘.
//   - Hardware chords iPadOS might take before pressesBegan (the iPadOS 26
//     menu bar's ⌘W/⌘Q/⌘M/⌘N/…, standard edit actions) are claimed as
//     UIKeyCommands with wantsPriorityOverSystemBehavior and forwarded as a
//     key tap (`forwardedChords`). System-reserved chords (⌘Tab, ⌘Space, ⌘H,
//     ⌘⇧3/4/5, Globe chords) never reach any app: the floating menu's Mac
//     Shortcuts send those.
//   - On-screen keyboard: characters and Delete get the sticky modifiers.
//     Under ⌘/⌥/⌃ a character goes as its unshifted US keysym (+ Shift if it
//     needed one), as a hardware chord does; under ⇧ alone as the shifted US
//     character. The keyboard repeats a held Delete itself: deletes that
//     follow within `softDeleteCarry` keep the modifiers the first one used,
//     so a held ⌥⌫ keeps deleting words.
//   - The keyboard accessory row (KeyboardAccessoryBar: ⌘ ⌥ ⌃ ⇧ esc ⇥ ← ↑
//     ↓ →) and the menu's special keys go through ControlMenuModel (sticky +
//     fn layer, hold-to-repeat with the modifiers held).
import UIKit

@MainActor
final class RemoteInputView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate, RemoteKeySink {
    /// Device-tunable input constants, in one place.
    enum Tuning {
        /// Points of wheel translation per wheel notch (GLFW reports 1.0 per
        /// notch; UIKit reports discrete scrolls as a translation). Tune on device.
        static let pointsPerWheelNotch: CGFloat = 10
        /// Hardware key auto-repeat: delay before the first repeat, then the
        /// interval between repeats (≈ macOS defaults).
        static let keyRepeatDelay: TimeInterval = 0.5
        static let keyRepeatInterval: TimeInterval = 0.033
    }

    var input: InputController? {
        willSet {
            guard newValue !== input else { return }
            // Release on the controller that saw the downs, before switching.
            releaseAll()
        }
        didSet {
            guard input !== oldValue else { return }
            buttons = 0
            lastHost = nil
        }
    }

    var cursor: RemoteCursor? {
        didSet {
            oldValue?.onAvailabilityChange = nil
            cursor?.onAvailabilityChange = { [weak self] _ in self?.pointerInteraction?.invalidate() }
            pointerInteraction?.invalidate()
        }
    }

    /// The on-screen keyboard is up (bound to the session toolbar button).
    var softwareKeyboardVisible = false {
        didSet {
            guard softwareKeyboardVisible != oldValue else { return }
            if softwareKeyboardVisible {
                keyboardProxy.becomeFirstResponder()
            } else if keyboardProxy.isFirstResponder {
                becomeFirstResponder()
            }
        }
    }
    /// The user dismissed the on-screen keyboard from the keyboard itself.
    var onSoftwareKeyboardDismissed: (() -> Void)?
    /// The floating menu's sticky modifiers (shared with ControlMenuModel).
    var modifiers: StickyModifiers?
    /// ⌘⌥M on a hardware keyboard.
    var onToggleMenu: (() -> Void)?
    /// The floating menu's model: the keyboard accessory row's keys go
    /// through it (shared sticky modifiers, fn layer, repeat).
    weak var controlMenu: ControlMenuModel? {
        didSet { keyboardAccessory.menu = controlMenu }
    }
    /// Everything held was released on the wire (focus loss, teardown, a
    /// controller switch): holders such as the menu forget their holds.
    var onInputReleased: (() -> Void)?
    /// The pointer moved to a point in window coordinates (nil: it left /
    /// the host cursor was hidden). Used to keep the menu pill out of its way.
    var onPointerMoved: ((CGPoint?) -> Void)?

    /// Reference counts of held modifier keysyms, and their press order.
    private var modifierHolds: [UInt32: Int] = [:]
    private var modifierOrder: [UInt32] = []
    /// Sticky modifiers held for a hardware key (by HID usage) until its key-up.
    private var stickyForKey: [Int: [UInt32]] = [:]
    /// Sticky modifiers held for the current pointer press until buttons 0.
    private var stickyForPointer: [UInt32] = []
    /// Non-modifier keys down via the sink (the menu's special keys, the
    /// accessory row): released with everything else on focus loss.
    private var sinkHeld: Set<UInt32> = []
    /// The modifiers (and fn) the last on-screen-keyboard Delete used, and when.
    private var lastSoftDelete: (mods: [UInt32], fn: Bool, at: TimeInterval)?
    /// The on-screen keyboard repeats a held Delete as more deleteBackward
    /// calls (first after ≈0.5 s, then faster): one within this of the
    /// previous keeps its modifiers.
    static let softDeleteCarry: TimeInterval = 0.6
    /// Clock for `softDeleteCarry` (injected by tests).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var buttons = 0
    private var lastHost: (x: Int, y: Int)?
    private var keys = HardwareKeyState()
    private let repeater: KeyRepeater
    private var wheel = WheelScroll()
    private var trackpadScroll = PixelScroll()
    private var touchScroll = PixelScroll()
    private var lastTranslation: [ObjectIdentifier: CGPoint] = [:]
    private var pointerInteraction: UIPointerInteraction?
    private let keyboardProxy = SoftKeyboardProxy(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    let keyboardAccessory = KeyboardAccessoryBar()

    override convenience init(frame: CGRect) {
        self.init(frame: frame, repeatSchedule: KeyRepeater.runLoopTimer)
    }

    /// `repeatSchedule`: the key-repeat timer (injected by tests).
    init(frame: CGRect, repeatSchedule: @escaping KeyRepeater.Schedule) {
        repeater = KeyRepeater(schedule: repeatSchedule)
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        setUp()
        repeater.onRepeat = { [weak self] ks in self?.input?.key(down: true, keysym: ks) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appWillResignActive(_:)),
                       name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                       name: UIScene.willDeactivateNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp() {
        let pointer = UIPointerInteraction(delegate: self)
        addInteraction(pointer)
        pointerInteraction = pointer

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        let trackpad = UIPanGestureRecognizer(target: self, action: #selector(trackpadScroll(_:)))
        trackpad.allowedScrollTypesMask = .continuous
        trackpad.delegate = self
        addGestureRecognizer(trackpad)

        let wheelPan = UIPanGestureRecognizer(target: self, action: #selector(wheelScroll(_:)))
        wheelPan.allowedScrollTypesMask = .discrete
        wheelPan.delegate = self
        addGestureRecognizer(wheelPan)
        scrollRecognizers = [ObjectIdentifier(trackpad), ObjectIdentifier(wheelPan)]

        let direct = [UITouch.TouchType.direct.rawValue as NSNumber]
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        tap.allowedTouchTypes = direct
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = direct
        addGestureRecognizer(twoFingerTap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        press.minimumPressDuration = 0.4
        press.allowedTouchTypes = direct
        addGestureRecognizer(press)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(touchScroll(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.allowedTouchTypes = direct
        twoFingerPan.allowedScrollTypesMask = []
        addGestureRecognizer(twoFingerPan)

        // alpha 0 rather than isHidden: the proxy must stay an ordinary,
        // focusable responder; it is 1×1 and invisible either way.
        keyboardProxy.alpha = 0
        keyboardProxy.onText = { [weak self] in self?.typeText($0) }
        keyboardProxy.onDelete = { [weak self] in self?.softDelete() }
        keyboardProxy.onPresses = { [weak self] presses, down in self?.handle(presses, down: down) ?? presses }
        keyboardProxy.onResign = { [weak self] in self?.softwareKeyboardResigned() }
        keyboardProxy.accessory = keyboardAccessory
        addSubview(keyboardProxy)
    }

    private var scrollRecognizers: Set<ObjectIdentifier> = []

    // MARK: first responder (hardware keyboard)

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !softwareKeyboardVisible { becomeFirstResponder() }
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldKeys()
        return super.resignFirstResponder()
    }

    // MARK: releasing held input

    /// Sends key-ups for every held key and, if pointer buttons are down,
    /// buttons 0 at the last host position; stops key repeat. Safe to call
    /// repeatedly. The session calls this before tearing the controller down.
    func releaseAll() {
        releaseHeldKeys()
        releaseButtons()
    }

    private func releaseButtons() {
        guard buttons != 0 else { return }
        buttons = 0
        sendButtons()
        releaseStickyForPointer()
    }

    // MARK: modifier holds (RemoteKeySink)

    func sendKey(down: Bool, keysym: UInt32) {
        if down { sinkHeld.insert(keysym) } else { sinkHeld.remove(keysym) }
        input?.key(down: down, keysym: keysym)
    }

    func holdModifier(_ keysym: UInt32) {
        let n = modifierHolds[keysym, default: 0]
        modifierHolds[keysym] = n + 1
        guard n == 0 else { return }
        modifierOrder.append(keysym)
        input?.key(down: true, keysym: keysym)
    }

    func releaseModifier(_ keysym: UInt32) {
        guard let n = modifierHolds[keysym] else { return }
        if n > 1 {
            modifierHolds[keysym] = n - 1
            return
        }
        modifierHolds[keysym] = nil
        modifierOrder.removeAll { $0 == keysym }
        input?.key(down: false, keysym: keysym)
    }

    /// The sticky modifiers to apply now (none if no menu is attached).
    private var sticky: ModifierState { modifiers?.state ?? ModifierState() }

    /// Holds the active sticky modifiers; latched ones clear. Returns what
    /// was held, to release later.
    private func holdSticky() -> [UInt32] {
        hold(sticky.pressedKeysyms())
    }

    /// Holds `extra` plus the active sticky modifiers (each once, ⌃ ⌥ ⇧ ⌘
    /// order); latched ones clear. Returns what was held, to release later.
    private func hold(_ extra: [UInt32]) -> [UInt32] {
        let want = Set(extra).union(sticky.pressedKeysyms())
        let mods = Keysyms.modifierPressOrder.filter(want.contains)
        for m in mods { holdModifier(m) }
        modifiers?.consumeLatched()
        return mods
    }

    /// The modifiers `flags` reports that nothing holds on the wire (their
    /// key-down never reached this view), as left keysyms.
    private func impliedModifiers(_ flags: UIKeyModifierFlags) -> [UInt32] {
        Keysyms.flagKeysyms.compactMap { f in
            guard flags.contains(f.flag), f.sides.allSatisfy({ modifierHolds[$0] == nil }) else { return nil }
            return f.left
        }
    }

    /// Releases hardware modifier holds whose flag `flags` no longer reports
    /// (their key-up was lost), so nothing sticks on the Mac.
    private func releaseStaleModifiers(_ flags: UIKeyModifierFlags) {
        for usage in keys.heldModifierUsages {
            guard let f = Keysyms.modifierFlag(usage), !flags.contains(f),
                  let ks = keys.release(usage) else { continue }
            releaseModifier(ks)
        }
    }

    private func pressStickyForPointer() {
        guard stickyForPointer.isEmpty else { return }
        stickyForPointer = holdSticky()
    }

    private func releaseStickyForPointer() {
        let mods = stickyForPointer
        stickyForPointer = []
        for m in mods.reversed() { releaseModifier(m) }
    }

    // MARK: menu shortcut

    override var keyCommands: [UIKeyCommand]? {
        let toggle = UIKeyCommand(title: "Show/Hide Control Menu", action: #selector(toggleControlMenu(_:)),
                                  input: "m", modifierFlags: [.command, .alternate])
        toggle.wantsPriorityOverSystemBehavior = true
        return [toggle] + Self.forwardedKeyCommands
    }

    /// A hardware chord claimed from iPadOS and forwarded to the Mac.
    struct ForwardedChord: Sendable {
        var input: String
        var flags: UIKeyModifierFlags
        var usage: UIKeyboardHIDUsage
    }

    /// Chords the app's own (iPadOS 26 menu bar) key commands could take
    /// before pressesBegan: window commands (Close ⌘W, Quit ⌘Q, Minimize ⌘M,
    /// New Window ⌘N/⇧⌘N, Settings ⌘,, cycle windows ⌘`, Full Screen ⌃⌘F) and
    /// the standard edit actions (⌘C/X/V/A/Z, ⇧⌘Z, ⌘F). Each is a tap (no
    /// key-up timing or repeat matters for these). Arrows, Tab, Delete,
    /// Escape and plain letters stay on pressesBegan so they keep their real
    /// key-up and auto-repeat. System-reserved chords (⌘Tab, ⌘Space, ⌘H,
    /// ⇧⌘3/4/5, ⌥⌘D, Globe chords) can't be claimed by any app.
    static let forwardedChords: [ForwardedChord] = [
        ForwardedChord(input: "w", flags: .command, usage: .keyboardW),
        ForwardedChord(input: "q", flags: .command, usage: .keyboardQ),
        ForwardedChord(input: "m", flags: .command, usage: .keyboardM),
        ForwardedChord(input: "n", flags: .command, usage: .keyboardN),
        ForwardedChord(input: "n", flags: [.command, .shift], usage: .keyboardN),
        ForwardedChord(input: ",", flags: .command, usage: .keyboardComma),
        ForwardedChord(input: "`", flags: .command, usage: .keyboardGraveAccentAndTilde),
        ForwardedChord(input: "f", flags: [.command, .control], usage: .keyboardF),
        ForwardedChord(input: "f", flags: .command, usage: .keyboardF),
        ForwardedChord(input: "c", flags: .command, usage: .keyboardC),
        ForwardedChord(input: "x", flags: .command, usage: .keyboardX),
        ForwardedChord(input: "v", flags: .command, usage: .keyboardV),
        ForwardedChord(input: "a", flags: .command, usage: .keyboardA),
        ForwardedChord(input: "z", flags: .command, usage: .keyboardZ),
        ForwardedChord(input: "z", flags: [.command, .shift], usage: .keyboardZ),
    ]

    private static var forwardedKeyCommands: [UIKeyCommand] {
        forwardedChords.map { c in
            let k = UIKeyCommand(input: c.input, modifierFlags: c.flags, action: #selector(forwardKeyCommand(_:)))
            k.wantsPriorityOverSystemBehavior = true
            return k
        }
    }

    @objc func forwardKeyCommand(_ sender: UIKeyCommand) {
        guard let chord = Self.forwardedChords.first(where: {
            $0.input == sender.input && $0.flags == sender.modifierFlags
        }) else { return }
        Log.input.debug("forwarded key command \(chord.input) flags \(chord.flags.rawValue)")
        forward(chord)
    }

    /// Sends a claimed chord as one tap of its key. The modifiers its flags
    /// report are already held by their own key-downs; any that are not are
    /// held around the tap (impliedModifiers).
    func forward(_ chord: ForwardedChord) {
        guard keyDown(chord.usage, modifiers: chord.flags, characters: "") else { return }
        keyUp(chord.usage)
    }

    @objc func toggleControlMenu(_ sender: Any?) {
        onToggleMenu?()
    }

    /// ⌘⌥M is the iPad-side menu shortcut: never forwarded.
    static func isMenuShortcut(_ usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
        usage == .keyboardM && modifiers.contains(.command) && modifiers.contains(.alternate)
    }

    @objc private func appWillResignActive(_ note: Notification) {
        releaseAll()
    }

    @objc private func sceneWillDeactivate(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
        releaseAll()
    }

    // MARK: pointer movement

    /// Maps `point` to the host, sends the pointer with the current buttons
    /// and moves the drawn cursor there. A pure hover (no button held)
    /// outside the fitted video rect (the letterbox) sends nothing and hides
    /// our cursor — the system pointer shows there instead, via
    /// `pointerInteraction(_:regionFor:defaultRegion:)` / `styleFor`.
    func movePointer(to point: CGPoint, coalescable: Bool) {
        guard let input else { return }
        if buttons == 0, !input.fittedRect(in: bounds.size).contains(point) {
            cursor?.hide()
            onPointerMoved?(nil)
            return
        }
        guard let host = input.hostPoint(forViewPoint: point, viewSize: bounds.size) else { return }
        let moved = lastHost.map { $0 != host } ?? true
        lastHost = host
        if moved || !coalescable {
            input.pointer(buttons: buttons, x: host.x, y: host.y, coalescable: coalescable)
        }
        cursor?.move(toHostX: host.x, y: host.y, hostWidth: input.serverWidth, hostHeight: input.serverHeight)
        onPointerMoved?(convert(point, to: nil))
    }

    /// Sends the current buttons at the last pointer position.
    private func sendButtons() {
        guard let input, let host = lastHost else { return }
        input.pointer(buttons: buttons, x: host.x, y: host.y)
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            movePointer(to: g.location(in: self), coalescable: true)
        case .ended, .cancelled, .failed:
            if buttons == 0 {
                cursor?.hide()
                onPointerMoved?(nil)
            }
        default:
            break
        }
    }

    // MARK: pointer buttons (indirect touches)

    static func mask(_ m: UIEvent.ButtonMask) -> Int {
        var b = 0
        if m.contains(.primary) { b |= InputController.Button.left }
        if m.contains(.secondary) { b |= InputController.Button.right }
        if m.contains(.button(3)) { b |= InputController.Button.middle }
        return b
    }

    private func pointerTouch(_ touches: Set<UITouch>) -> UITouch? {
        touches.first { $0.type == .indirectPointer }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = pointerTouch(touches) else { return super.touchesBegan(touches, with: event) }
        let m = Self.mask(event?.buttonMask ?? .primary)
        pointerDown(buttons: m == 0 ? InputController.Button.left : m, at: t.location(in: self))
    }

    /// A pointer button press at `point` (view coordinates).
    func pointerDown(buttons mask: Int, at point: CGPoint) {
        if buttons == 0 { pressStickyForPointer() }
        buttons = mask
        movePointer(to: point, coalescable: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = pointerTouch(touches) else { return super.touchesMoved(touches, with: event) }
        let m = Self.mask(event?.buttonMask ?? [])
        let changed = m != 0 && m != buttons
        if changed { buttons = m }
        movePointer(to: t.location(in: self), coalescable: !changed)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = pointerTouch(touches) else { return super.touchesEnded(touches, with: event) }
        lastHost = input?.hostPoint(forViewPoint: t.location(in: self), viewSize: bounds.size) ?? lastHost
        buttons = 0
        sendButtons()
        releaseStickyForPointer()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerTouch(touches) != nil else { return super.touchesCancelled(touches, with: event) }
        buttons = 0
        sendButtons()
        releaseStickyForPointer()
    }

    // MARK: scrolling

    /// The translation since the recognizer's previous callback.
    private func delta(_ g: UIPanGestureRecognizer) -> CGPoint {
        let id = ObjectIdentifier(g)
        let t = g.translation(in: self)
        if g.state == .began { lastTranslation[id] = .zero }
        let prev = lastTranslation[id] ?? .zero
        lastTranslation[id] = g.state == .ended || g.state == .cancelled ? nil : t
        return CGPoint(x: t.x - prev.x, y: t.y - prev.y)
    }

    private func scrollAtPointer(_ dy: Int, fallback: CGPoint) {
        guard dy != 0, let input else { return }
        if lastHost == nil { movePointer(to: fallback, coalescable: false) }
        guard let host = lastHost else { return }
        input.scroll(x: host.x, y: host.y, dy: dy)
    }

    @objc private func trackpadScroll(_ g: UIPanGestureRecognizer) {
        guard let input else { return }
        let d = delta(g)
        let ticks = trackpadScroll.ticks(points: d.y, ticksPerPoint: input.scrollTicksPerPoint(viewSize: bounds.size))
        scrollAtPointer(ticks, fallback: g.location(in: self))
    }

    @objc private func wheelScroll(_ g: UIPanGestureRecognizer) {
        let d = delta(g)
        guard d.y != 0 else { return }
        let ticks = wheel.ticks(wheelDelta: d.y / Tuning.pointsPerWheelNotch,
                                atMilliseconds: ProcessInfo.processInfo.systemUptime * 1000)
        scrollAtPointer(ticks, fallback: g.location(in: self))
    }

    @objc private func touchScroll(_ g: UIPanGestureRecognizer) {
        guard let input else { return }
        if g.state == .began { movePointer(to: g.location(in: self), coalescable: false) }
        let d = delta(g)
        let ticks = touchScroll.ticks(points: d.y, ticksPerPoint: input.scrollTicksPerPoint(viewSize: bounds.size))
        scrollAtPointer(ticks, fallback: g.location(in: self))
    }

    // MARK: touch clicks

    /// A touch click at `point` (sticky modifiers held around it).
    func click(at point: CGPoint, button: Int) {
        guard input != nil, buttons == 0 else { return }
        movePointer(to: point, coalescable: false)
        pressStickyForPointer()
        buttons = button
        sendButtons()
        buttons = 0
        sendButtons()
        releaseStickyForPointer()
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        click(at: g.location(in: self), button: InputController.Button.left)
    }

    @objc private func twoFingerTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        click(at: g.location(in: self), button: InputController.Button.right)
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            movePointer(to: g.location(in: self), coalescable: false)
            pressStickyForPointer()
            buttons = InputController.Button.left
            sendButtons()
        case .changed:
            movePointer(to: g.location(in: self), coalescable: true)
        case .ended, .cancelled, .failed:
            buttons = 0
            sendButtons()
            releaseStickyForPointer()
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The scroll pans take scroll events only, never touches (so a
        // click-drag on the trackpad is a drag, not a scroll).
        !scrollRecognizers.contains(ObjectIdentifier(g))
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer
    }

    // MARK: UIPointerInteractionDelegate

    /// Identifies the region returned for a point inside the fitted video
    /// rect, so `styleFor` only hides the system pointer there.
    private static let videoRegionID = "video" as NSString

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let input else { return defaultRegion }
        let fit = input.fittedRect(in: bounds.size)
        guard fit.contains(request.location) else { return defaultRegion }
        return UIPointerRegion(rect: fit, identifier: Self.videoRegionID)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard (region.identifier as? NSString) == Self.videoRegionID else { return nil }
        return cursor?.image != nil ? .hidden() : nil
    }

    // MARK: hardware keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handle(presses, down: true)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handle(presses, down: false)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handle(presses, down: false)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Sends the keys among `presses`; returns the presses that are not
    /// keyboard keys we map.
    private func handle(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        guard input != nil else { return presses }
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { rest.insert(press); continue }
            let handled = down
                ? keyDown(key.keyCode, modifiers: key.modifierFlags, characters: key.characters)
                : keyUp(key.keyCode)
            if !handled { rest.insert(press) }
        }
        return rest
    }

    /// A hardware key went down; false if it has no keysym (passed on).
    /// Modifier keys are reference-counted holds; any other key gets the
    /// sticky modifiers held around it until its key-up.
    @discardableResult
    func keyDown(_ usage: UIKeyboardHIDUsage, modifiers flags: UIKeyModifierFlags, characters: String) -> Bool {
        guard let input, !Self.isMenuShortcut(usage, modifiers: flags) else { return false }
        if Keysyms.isModifier(usage) {
            // A second down without an up (a lost key-up) must not add a
            // second hold, or one key-up would leave it stuck on the Mac.
            if keys.isHeld(usage) { return true }
            guard let ks = keys.press(usage, modifiers: flags, characters: characters) else { return false }
            holdModifier(ks)
            return true
        }
        releaseStaleModifiers(flags)
        let state = sticky
        var keyFlags = flags
        var chars = characters
        if state.commandLikeActive {
            // A sticky ⌘/⌥/⌃ chord sends the unshifted US keysym, as a hardware chord does.
            keyFlags.insert(.command)
        } else if state[.shift] != .off, !Keysyms.isSpecial(usage) {
            // A sticky ⇧ alone: the final (shifted) character, as with a held Shift.
            keyFlags.insert(.shift)
            chars = Self.shiftedLayoutCharacter(characters)
        }
        guard let ks = keys.press(usage, modifiers: keyFlags, characters: chars) else { return false }
        if let old = stickyForKey.removeValue(forKey: usage.rawValue) {   // a repeated down without an up
            for m in old.reversed() { releaseModifier(m) }
        }
        let mods = hold(impliedModifiers(flags))
        if !mods.isEmpty { stickyForKey[usage.rawValue] = mods }
        input.key(down: true, keysym: ks)
        repeater.keyDown(usage: usage.rawValue, keysym: ks)
        return true
    }

    /// A hardware key went up; false if it never went down here.
    @discardableResult
    func keyUp(_ usage: UIKeyboardHIDUsage) -> Bool {
        repeater.keyUp(usage: usage.rawValue)
        guard let ks = keys.release(usage) else { return false }
        if Keysyms.isModifier(usage) {
            releaseModifier(ks)
        } else {
            input?.key(down: false, keysym: ks)
            for m in (stickyForKey.removeValue(forKey: usage.rawValue) ?? []).reversed() { releaseModifier(m) }
        }
        return true
    }

    /// A layout character as typed with Shift: an uppercased letter, or ""
    /// (the US table's shifted keysym) for anything else.
    static func shiftedLayoutCharacter(_ characters: String) -> String {
        let upper = characters.uppercased()
        return upper != characters && upper.unicodeScalars.count == 1 ? upper : ""
    }

    private func releaseHeldKeys() {
        repeater.cancel()
        lastSoftDelete = nil
        for ks in keys.releaseAll() where modifierHolds[ks] == nil { input?.key(down: false, keysym: ks) }
        for ks in sinkHeld.sorted() where modifierHolds[ks] == nil { input?.key(down: false, keysym: ks) }
        sinkHeld.removeAll()
        for ks in modifierOrder.reversed() { input?.key(down: false, keysym: ks) }
        modifierHolds.removeAll()
        modifierOrder.removeAll()
        stickyForKey.removeAll()
        stickyForPointer.removeAll()
        onInputReleased?()
    }

    // MARK: on-screen keyboard

    /// Soft-keyboard text. Each character gets the sticky modifiers (a
    /// latched one applies to the first character only). Under a sticky
    /// ⌘/⌥/⌃ a character goes as its unshifted US keysym, Shift as a separate
    /// key when it needed one, as a hardware chord does: latched ⌘ + "c" = ⌘C,
    /// ⌘ + "?" = ⌘⇧/. Under a sticky ⇧ alone it goes as the shifted US
    /// character ("a" → "A"). Newline/tab are Return/Tab (with the modifiers).
    func typeText(_ text: String) {
        guard let input else { return }
        for ch in text {
            let state = sticky
            let commandLike = state.commandLikeActive
            let shiftSticky = state[.shift] != .off
            let mods = holdSticky()
            for t in Keysyms.typed(ch) {
                var ks = t.keysym
                var shift = t.shift
                if commandLike, let u = Keysyms.usUnshifted(ks) {
                    ks = u
                } else if !commandLike, shiftSticky, let s = Keysyms.usShifted(ks) {
                    ks = s
                    shift = true
                }
                if shift { holdModifier(Keysyms.shiftL) }
                input.key(down: true, keysym: ks)
                input.key(down: false, keysym: ks)
                if shift { releaseModifier(Keysyms.shiftL) }
            }
            for m in mods.reversed() { releaseModifier(m) }
        }
    }

    /// Soft-keyboard Delete: with the sticky modifiers; fn makes it forward
    /// Delete. A Delete within `softDeleteCarry` of the previous one (the
    /// keyboard's own repeat of a held Delete) keeps that one's modifiers,
    /// so latched ⌥ + held Delete deletes word after word.
    func softDelete() {
        guard input != nil else { return }
        let t = now()
        var carried: [UInt32] = []
        var fn = sticky.fnActive
        if let last = lastSoftDelete, t - last.at <= Self.softDeleteCarry {
            carried = last.mods
            fn = fn || last.fn
        }
        let key: SpecialKey = fn ? SpecialKey.backspace.withFn : .backspace
        let mods = hold(carried)
        input?.key(down: true, keysym: key.keysym)
        input?.key(down: false, keysym: key.keysym)
        for m in mods.reversed() { releaseModifier(m) }
        lastSoftDelete = mods.isEmpty && !fn ? nil : (mods, fn, t)
    }

    private func softwareKeyboardResigned() {
        releaseHeldKeys()
        guard softwareKeyboardVisible else { return }
        // Dismissed from the keyboard itself: hand focus back for hardware keys.
        softwareKeyboardVisible = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.softwareKeyboardVisible else { return }
            self.becomeFirstResponder()
        }
        onSoftwareKeyboardDismissed?()
    }
}

/// Hidden first responder that brings up the on-screen keyboard and reports
/// what is typed. Hardware key presses that reach it while it has focus are
/// forwarded to the same key path as RemoteInputView's (and not passed on,
/// so they are not also inserted as text).
@MainActor
final class SoftKeyboardProxy: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?
    /// (presses, down) → the presses not handled.
    var onPresses: ((Set<UIPress>, Bool) -> Set<UIPress>)?
    var onResign: (() -> Void)?
    /// Shown above the on-screen keyboard (the modifier/arrow row).
    var accessory: UIView?

    override var inputAccessoryView: UIView? { accessory }

    // UITextInputTraits: a raw key stream, no text services.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var inlinePredictionType: UITextInlinePredictionType = .no

    override init(frame: CGRect) {
        super.init(frame: frame)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let did = super.resignFirstResponder()
        if did { onResign?() }
        return did
    }

    var hasText: Bool { true }      // so delete is always reported
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onDelete?() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = onPresses?(presses, true) ?? presses
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = onPresses?(presses, false) ?? presses
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = onPresses?(presses, false) ?? presses
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}
