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
//     reference. Settings → Scroll speed (InputController.scrollSpeed)
//     scales wheel, touch (+ momentum) and pointer-lock scrolls, not the
//     hardware trackpad's continuous one. Settings → Scroll direction
//     (InputPreferences) flips every scroll path's ticks when Reversed
//     (`scrollAtPointer`, the one place all four go through).
// Touch (fingers and Pencil, Task 22): raw `.direct` / `.pencil` touches go
//   to TouchInterpreter (TouchInputMode.swift: the gestures of trackpad mode
//   — the default — and direct mode), whose TouchActions are performed here
//   (`perform`): relative cursor moves (trackpad; the host cursor position is
//   kept fractionally in `cursorHost` and the viewport follows it), absolute
//   moves (direct / Pencil), button presses with the sticky modifiers,
//   scrolls (PixelScroll, then ScrollInertia momentum on a display link —
//   stopped by any new touch), pinch zoom / pan / reset (Viewport, shared with
//   MetalRenderer through ViewportModel) and haptics (touch only; a hardware
//   pointer never triggers one). Pencil hover moves the cursor through the
//   hover recognizer; a Pencil double-tap / squeeze is a right click at the
//   cursor (UIPencilInteraction, unless the user set it to do nothing).
// Visual feedback (`feedback`, a FeedbackSink — UI/Feedback): touch clicks,
//   drags, the drag lock, trackpad finger-downs, direct-mode long presses
//   (TouchInterpreter's TouchCues), touch cursor moves, zooms and touch
//   scrolls / momentum are reported as FeedbackEvents (cursor points in
//   BASE, unzoomed view coordinates). Hardware pointer input reports none.
// Input preferences (InputPreferences: tap-to-click delay, scroll direction,
//   long-press right click): read from UserDefaults when a session's input
//   arrives and again on every UserDefaults change (live), applied to the
//   TouchInterpreter and the scroll paths.
// Locating the cursor: every relative pointer motion (trackpad-mode moves,
//   pointer-lock mouse moves, hardware pointer hover / drag deltas) feeds a
//   ShakeDetector; a shake asks the feedback sink to enlarge the drawn cursor
//   (FeedbackEvent.locateCursor, held while the shake goes on). `findCursor`
//   (the menu's Find Cursor) re-shows the cursor, centres a zoomed viewport
//   on it and enlarges it too.
// Zoom: every view point is mapped through the viewport's inverse before the
//   aspect-fit mapping (InputController.hostPoint), the system pointer is
//   hidden over the zoomed picture's on-screen rect, and a trackpad pinch
//   (UIPinchGestureRecognizer on transform events) zooms around the pointer.
// Pointer lock (PointerLock.swift): while connected, a mouse / trackpad is
//   attached and the floating menu is closed, the view asks for the pointer
//   lock (granted by iPadOS in full screen only). Locked, GCMouse supplies
//   relative motion (one count ≈ one Mac point, gently accelerated, ×
//   Settings → Pointer Speed: PointerScaling; the viewport follows),
//   buttons and scroll; UIKit's pointer touches and scroll pans are ignored
//   so nothing is sent twice.
// Keyboard:
//   - Hardware keys via pressesBegan/Ended (UIKey.keyCode + modifierFlags +
//     characters → HardwareKeyState / Keysyms: layout-aware character when
//     no Cmd/Ctrl/Opt is held, US table otherwise).
//   - While a GameController keyboard is connected (GCKeyboardSource), every
//     hardware key's down/up comes from GC as well and KeyArbiter merges the
//     two (HardwareKeyboard.swift): GC decides which key and when (so ⌥←,
//     ⌘→, ⌥⌫ that UIKit's text system swallows still reach the Mac), UIKit
//     supplies the layout character for unmodified printable keys and stays
//     the fallback. GC keys only count while this view (or the keyboard
//     proxy) is first responder, as UIKit's would.
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
import GameController
import UIKit

@MainActor
final class RemoteInputView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate,
                             UIPencilInteractionDelegate, RemoteKeySink {
    /// Device-tunable input constants, in one place.
    enum Tuning {
        /// Points of wheel translation per wheel notch (GLFW reports 1.0 per
        /// notch; UIKit reports discrete scrolls as a translation). Tune on device.
        static let pointsPerWheelNotch: CGFloat = 10
        /// Hardware key auto-repeat: delay before the first repeat, then the
        /// interval between repeats (≈ macOS defaults).
        static let keyRepeatDelay: TimeInterval = 0.5
        static let keyRepeatInterval: TimeInterval = 0.033
        /// Pointer lock: GCMouse scroll units → view points of "finger"
        /// travel (sign: + = content follows a downward swipe). Tune on device.
        static let lockedScrollPoints: CGFloat = 1
    }

    /// How finger touches drive the pointer (the floating menu's Input Mode).
    var touchMode: TouchInputMode = .default {
        didSet { touchInterpreter.mode = touchMode }
    }
    /// The session's zoom/pan, shared with the renderer.
    var viewport = ViewportModel() {
        didSet { if viewport !== oldValue { viewport.update { $0.reset() } } }
    }
    /// The floating menu is open: the pointer lock is released and touch
    /// gestures (a drag lock too) are cancelled.
    var menuOpen = false {
        didSet {
            guard menuOpen != oldValue else { return }
            if menuOpen { touchInterpreter.cancel() }
            updatePointerLock()
        }
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
            cursorHost = nil
            lastPointerLocation = nil
            shake.reset()
            stopInertia()
            if input != nil { reloadPreferences() }     // session start
            updatePointerLock()
            updateGCKeyboard()
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
        didSet {
            keyboardAccessory.menu = controlMenu
            controlMenu?.onFindCursor = { [weak self] in self?.findCursor() }
        }
    }
    /// Everything held was released on the wire (focus loss, teardown, a
    /// controller switch): holders such as the menu forget their holds.
    var onInputReleased: (() -> Void)?
    /// The pointer moved to a point in window coordinates (nil: it left /
    /// the host cursor was hidden). Used to keep the menu pill out of its way.
    var onPointerMoved: ((CGPoint?) -> Void)?
    /// Visual touch feedback (ripples, halo, HUDs).
    weak var feedback: FeedbackSink?
    /// Settings → Input (tap delay, scroll direction, long-press right click).
    var preferences = InputPreferences() {
        didSet {
            touchInterpreter.tapDelay = preferences.tapDelay.seconds
            touchInterpreter.longPressRightClick = preferences.longPressRightClick
            if preferences.keyboardTester != oldValue.keyboardTester { updateKeyTester() }
        }
    }
    /// Where `preferences` are read from (injected by tests).
    var defaults: UserDefaults = .standard

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
    /// The cursor in host pixels, fractional (relative moves accumulate).
    private var cursorHost: CGPoint?
    private let schedule: KeyRepeater.Schedule
    private(set) lazy var touchInterpreter: TouchInterpreter = {
        let t = TouchInterpreter(schedule: schedule) { [weak self] in self?.perform($0) }
        t.mode = touchMode
        t.tapDelay = preferences.tapDelay.seconds
        t.longPressRightClick = preferences.longPressRightClick
        t.isZoomed = { [weak self] in self?.viewport.value.isZoomed ?? false }
        t.onCue = { [weak self] in self?.handleCue($0) }
        return t
    }()
    private var inertia: ScrollInertia?
    private var inertiaLink: CADisplayLink?
    private var lastLayoutSize = CGSize.zero
    private var shake = ShakeDetector()
    private let gcKeyboard = GCKeyboardSource()
    /// Merges GameController and UIKit hardware key reports (HardwareKeyboard.swift).
    private(set) lazy var keyArbiter: KeyArbiter = KeyArbiter(
        schedule: schedule, now: { [weak self] in self?.now() ?? 0 },
        emit: { [weak self] in self?.applyArbitrated($0) })
    /// Settings → Input → Keyboard Tester: the last hardware key events.
    let keyTesterLog = KeyTesterLog()
    private let keyTesterLabel = UILabel()
    /// The last hardware pointer location (view points) for hover deltas.
    private var lastPointerLocation: CGPoint?
    private var trackpadPinchScale: CGFloat = 1
    private var pointerLocked = false
    private var lastLockedMove: TimeInterval?
    private var lockedScroll = PixelScroll()
    private lazy var lightImpact = UIImpactFeedbackGenerator(style: .light, view: self)
    private lazy var mediumImpact = UIImpactFeedbackGenerator(style: .medium, view: self)
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
        schedule = repeatSchedule
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
        nc.addObserver(self, selector: #selector(miceChanged(_:)), name: .GCMouseDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(miceChanged(_:)), name: .GCMouseDidDisconnect, object: nil)
        nc.addObserver(self, selector: #selector(pointerLockChanged(_:)),
                       name: UIPointerLockState.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(defaultsChanged(_:)),
                       name: UserDefaults.didChangeNotification, object: nil)
        preferences = InputPreferences.load(defaults)
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

        // A trackpad pinch (transform events, never finger touches: those
        // go raw to the TouchInterpreter, which does its own pinch).
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(trackpadPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        scrollRecognizers = [ObjectIdentifier(trackpad), ObjectIdentifier(wheelPan), ObjectIdentifier(pinch)]

        addInteraction(UIPencilInteraction(delegate: self))

        // alpha 0 rather than isHidden: the proxy must stay an ordinary,
        // focusable responder; it is 1×1 and invisible either way.
        keyboardProxy.alpha = 0
        keyboardProxy.onText = { [weak self] in self?.typeText($0) }
        keyboardProxy.onDelete = { [weak self] in self?.softDelete() }
        keyboardProxy.onPresses = { [weak self] presses, down in self?.handle(presses, down: down) ?? presses }
        keyboardProxy.onResign = { [weak self] in self?.softwareKeyboardResigned() }
        keyboardProxy.accessory = keyboardAccessory
        addSubview(keyboardProxy)

        gcKeyboard.onKey = { [weak self] usage, pressed in self?.gcKey(usage, pressed: pressed) }
        gcKeyboard.onAvailability = { [weak self] on in self?.gcKeyboardAvailability(on) }

        keyTesterLabel.numberOfLines = 0
        keyTesterLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keyTesterLabel.textColor = .white
        keyTesterLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        keyTesterLabel.isUserInteractionEnabled = false
        keyTesterLabel.isHidden = true
        keyTesterLabel.accessibilityLabel = "Keyboard Tester"
        addSubview(keyTesterLabel)
    }

    private var scrollRecognizers: Set<ObjectIdentifier> = []

    // MARK: first responder (hardware keyboard)

    override var canBecomeFirstResponder: Bool { true }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopInertia()
            PointerLock.withdraw(self, from: window)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !softwareKeyboardVisible { becomeFirstResponder() }
        updatePointerLock()
        updateGCKeyboard()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Rotation / resize: the zoomed region no longer means the same thing.
        if !keyTesterLabel.isHidden { layoutKeyTester() }
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            viewport.update { $0.reset() }
            pointerInteraction?.invalidate()
        }
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
        stopInertia()
        touchInterpreter.cancel()
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
        // Claim chords from iPadOS only while there is a Mac to send them to.
        return input == nil ? [toggle] : [toggle] + Self.forwardedKeyCommands
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
        if keyArbiter.gcActive {
            // GC delivers the real key down/up; this only claims the chord from iPadOS.
            keyArbiter.uikitTap(chord.usage, flags: chord.flags)
        } else {
            forward(chord)
        }
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

    /// Any UserDefaults change (posted on the writer's thread): re-read the
    /// input preferences on the main actor.
    @objc nonisolated private func defaultsChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.reloadPreferences() }
    }

    /// Re-reads Settings → Input (cheap: three keys); applied only on a change.
    func reloadPreferences() {
        let p = InputPreferences.load(defaults)
        if p != preferences { preferences = p }
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
    /// `point` is where it is drawn (zoomed); `clampToPicture`: a touch in
    /// the letterbox goes to the nearest edge instead of hiding the cursor.
    func movePointer(to point: CGPoint, coalescable: Bool, clampToPicture: Bool = false) {
        guard let input else { return }
        let size = bounds.size, zoom = viewport.value
        if buttons == 0, !clampToPicture,
           !input.fittedRect(in: size).contains(zoom.toBase(point, viewSize: size)) {
            cursor?.hide()
            onPointerMoved?(nil)
            return
        }
        guard let host = input.hostPoint(forViewPoint: point, viewSize: size, viewport: zoom) else { return }
        cursorHost = CGPoint(x: host.x, y: host.y)
        sendCursor(host, coalescable: coalescable)
        onPointerMoved?(convert(point, to: nil))
    }

    /// Sends the pointer at `host` with the current buttons (a coalescable
    /// pure move only when it changed) and moves the drawn cursor there.
    private func sendCursor(_ host: (x: Int, y: Int), coalescable: Bool) {
        guard let input else { return }
        let moved = lastHost.map { $0 != host } ?? true
        lastHost = host
        if moved || !coalescable {
            input.pointer(buttons: buttons, x: host.x, y: host.y, coalescable: coalescable)
        }
        cursor?.move(toHostX: host.x, y: host.y, hostWidth: input.serverWidth, hostHeight: input.serverHeight)
    }

    /// Relative move by `delta` view points of finger travel (trackpad mode,
    /// pointer lock): the cursor moves that far on screen at any zoom, and
    /// a zoomed viewport pans to keep it inside its 10% margins.
    func moveCursor(by delta: CGPoint) {
        guard let input else { return }
        if delta != .zero { noteCursorMotion(delta) }
        let size = bounds.size
        let k = input.hostPixelsPerPoint(viewSize: size, zoom: viewport.value.scale)
        let w = CGFloat(input.serverWidth), h = CGFloat(input.serverHeight)
        var c = cursorHost ?? lastHost.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: w / 2, y: h / 2)
        c.x = min(w - 1, max(0, c.x + delta.x * k))
        c.y = min(h - 1, max(0, c.y + delta.y * k))
        cursorHost = c
        sendCursor((Int(c.x), Int(c.y)), coalescable: delta != .zero)
        guard let base = input.baseViewPoint(forHostX: CGFloat(Int(c.x)), y: CGFloat(Int(c.y)), viewSize: size)
        else { return }
        let fit = input.fittedRect(in: size)
        viewport.update { $0.follow(base, viewSize: size, content: fit) }
        onPointerMoved?(convert(viewport.value.toScreen(base, viewSize: size), to: nil))
    }

    // MARK: locating the cursor

    /// A relative pointer motion of `d` view points: a shake enlarges the cursor.
    func noteCursorMotion(_ d: CGPoint) {
        guard shake.add(d, at: now()) else { return }
        feedback?.feedback(.locateCursor(hold: CursorEffects.locateHold))
    }

    /// A hardware pointer at `p` (hover / drag): its delta feeds the shake detector.
    func noteHardwarePointer(at p: CGPoint) {
        if let last = lastPointerLocation { noteCursorMotion(CGPoint(x: p.x - last.x, y: p.y - last.y)) }
        lastPointerLocation = p
    }

    /// Find Cursor (the floating menu): shows the cursor where it is (placing
    /// it mid-screen if it never had a position), centres a zoomed viewport
    /// on it and enlarges it. Works with visual feedback off.
    func findCursor() {
        guard let input else { return }
        if let host = lastHost {
            cursor?.move(toHostX: host.x, y: host.y, hostWidth: input.serverWidth, hostHeight: input.serverHeight)
        } else {
            moveCursor(by: .zero)
        }
        guard let base = cursorBasePoint else { return }
        let size = bounds.size, fit = input.fittedRect(in: size)
        if viewport.value.isZoomed {
            viewport.update { $0.center(on: base, viewSize: size, content: fit) }
            pointerInteraction?.invalidate()
        }
        onPointerMoved?(convert(viewport.value.toScreen(base, viewSize: size), to: nil))
        feedback?.feedback(.locateCursor(hold: CursorEffects.findHold))
    }

    /// The cursor's unzoomed (BASE) view point, if it has a position.
    var cursorBasePoint: CGPoint? {
        guard let input, let host = lastHost else { return nil }
        return input.baseViewPoint(forHostX: CGFloat(host.x), y: CGFloat(host.y), viewSize: bounds.size)
    }

    /// Where the cursor is drawn (view points), if it has a position.
    var cursorViewPoint: CGPoint? {
        guard let input, let host = lastHost,
              let base = input.baseViewPoint(forHostX: CGFloat(host.x), y: CGFloat(host.y), viewSize: bounds.size)
        else { return nil }
        return viewport.value.toScreen(base, viewSize: bounds.size)
    }

    /// Sends the current buttons at the last pointer position.
    private func sendButtons() {
        guard let input, let host = lastHost else { return }
        input.pointer(buttons: buttons, x: host.x, y: host.y)
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        guard !pointerLocked else { return }
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            if g.state == .began { lastPointerLocation = nil }
            noteHardwarePointer(at: p)
            movePointer(to: p, coalescable: true)
        case .ended, .cancelled, .failed:
            lastPointerLocation = nil
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

    /// Finger and Pencil touches (TouchInterpreter's input).
    private func gestureTouches(_ touches: Set<UITouch>) -> [UITouch] {
        touches.filter { $0.type == .direct || $0.type == .pencil }
    }

    private static func touchID(_ t: UITouch) -> Int { ObjectIdentifier(t).hashValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in gestureTouches(touches) {
            touchInterpreter.began(Self.touchID(t), at: t.location(in: self), time: t.timestamp,
                                   pencil: t.type == .pencil)
        }
        guard let t = pointerTouch(touches) else {
            let rest = touches.filter { $0.type != .direct && $0.type != .pencil }
            if !rest.isEmpty { super.touchesBegan(rest, with: event) }
            return
        }
        stopInertia()
        guard !pointerLocked else { return }          // GCMouse has the buttons
        if touchInterpreter.dragLocked { touchInterpreter.cancel() }   // a real click ends a touch drag lock
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
        let fingers = gestureTouches(touches)
        if !fingers.isEmpty {
            var points: [Int: CGPoint] = [:]
            for t in fingers { points[Self.touchID(t)] = t.location(in: self) }
            touchInterpreter.moved(points, time: event?.timestamp ?? fingers[0].timestamp)
        }
        guard let t = pointerTouch(touches) else {
            let rest = touches.filter { $0.type != .direct && $0.type != .pencil }
            if !rest.isEmpty { super.touchesMoved(rest, with: event) }
            return
        }
        guard !pointerLocked else { return }
        let m = Self.mask(event?.buttonMask ?? [])
        let changed = m != 0 && m != buttons
        if changed { buttons = m }
        noteHardwarePointer(at: t.location(in: self))
        movePointer(to: t.location(in: self), coalescable: !changed)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in gestureTouches(touches) {
            touchInterpreter.ended(Self.touchID(t), at: t.location(in: self), time: t.timestamp)
        }
        guard let t = pointerTouch(touches) else {
            let rest = touches.filter { $0.type != .direct && $0.type != .pencil }
            if !rest.isEmpty { super.touchesEnded(rest, with: event) }
            return
        }
        guard !pointerLocked else { return }
        lastHost = input?.hostPoint(forViewPoint: t.location(in: self), viewSize: bounds.size,
                                    viewport: viewport.value) ?? lastHost
        buttons = 0
        sendButtons()
        releaseStickyForPointer()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in gestureTouches(touches) { touchInterpreter.cancelled(Self.touchID(t)) }
        guard pointerTouch(touches) != nil else {
            let rest = touches.filter { $0.type != .direct && $0.type != .pencil }
            if !rest.isEmpty { super.touchesCancelled(rest, with: event) }
            return
        }
        guard !pointerLocked else { return }
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

    /// Every scroll path ends here: `dy` host ticks (< 0 = up) at the
    /// pointer, flipped when Settings → Scroll direction is Reversed.
    private func scrollAtPointer(_ dy: Int, fallback: CGPoint) {
        guard dy != 0, let input else { return }
        if lastHost == nil { movePointer(to: fallback, coalescable: false) }
        guard let host = lastHost else { return }
        input.scroll(x: host.x, y: host.y, dy: dy * preferences.scrollDirection.sign)
    }

    @objc private func trackpadScroll(_ g: UIPanGestureRecognizer) {
        guard input != nil else { return }
        if g.state == .began { stopInertia() }
        let d = delta(g)
        guard !pointerLocked else { return }          // GCMouse has the scroll
        continuousScroll(d, at: g.location(in: self))
    }

    /// A hardware trackpad's continuous scroll of `d` view points (1:1).
    func continuousScroll(_ d: CGPoint, at point: CGPoint) {
        guard let input else { return }
        let ticks = trackpadScroll.ticks(points: d.y, ticksPerPoint: input.scrollTicksPerPoint(
            viewSize: bounds.size, zoom: viewport.value.scale))
        scrollAtPointer(ticks, fallback: point)
    }

    @objc private func wheelScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began { stopInertia() }
        let d = delta(g)
        guard !pointerLocked else { return }
        wheelScrolled(d, at: g.location(in: self))
    }

    /// A mouse wheel's discrete scroll of `d` view points (the wheel curve).
    func wheelScrolled(_ d: CGPoint, at point: CGPoint) {
        guard d.y != 0 else { return }
        let speed = input?.scrollSpeed ?? 1
        let ticks = wheel.ticks(wheelDelta: d.y / Tuning.pointsPerWheelNotch * speed,
                                atMilliseconds: now() * 1000)
        scrollAtPointer(ticks, fallback: point)
    }

    /// A finger scroll (or a momentum step) of `d` view points.
    func scrollTouch(_ d: CGPoint) {
        guard let input else { return }
        if d.y != 0 { feedback?.feedback(.scrolled(dy: d.y)) }
        let ticks = touchScroll.ticks(points: d.y, ticksPerPoint: input.scrollSpeed * input.scrollTicksPerPoint(
            viewSize: bounds.size, zoom: viewport.value.scale))
        scrollAtPointer(ticks, fallback: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: scroll momentum

    /// Starts momentum after a finger scroll left at `velocity` (vertical
    /// only, as the wire's scroll).
    func startInertia(_ velocity: CGPoint) {
        stopInertia()
        guard input != nil, let run = ScrollInertia(velocity: CGPoint(x: 0, y: velocity.y)) else {
            feedback?.feedback(.scrollEnded)
            return
        }
        inertia = run
        let link = CADisplayLink(target: self, selector: #selector(inertiaTick(_:)))
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    func stopInertia() {
        let wasCoasting = inertia != nil
        inertiaLink?.invalidate()
        inertiaLink = nil
        inertia = nil
        if wasCoasting { feedback?.feedback(.scrollEnded) }
    }

    var isCoasting: Bool { inertia != nil }

    @objc private func inertiaTick(_ link: CADisplayLink) {
        let dt = min(1.0 / 30, max(1.0 / 240, link.targetTimestamp - link.timestamp))
        guard var run = inertia, let d = run.step(dt) else { return stopInertia() }
        inertia = run
        scrollTouch(d)
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

    // MARK: touch gestures (TouchInterpreter's actions)

    /// Performs one gesture action (TouchInputMode.swift).
    func perform(_ action: TouchAction) {
        switch action {
        case .began:
            stopInertia()
        case .moveBy(let d):
            moveCursor(by: PointerScaling.touchDelta(d, speed: preferences.touchPointerSpeed))
            if let p = cursorBasePoint { feedback?.feedback(.cursorMoved(to: p)) }
        case .moveTo(let p):
            movePointer(to: p, coalescable: true, clampToPicture: true)
        case .button(let b, let down):
            pressButton(b, down: down)
        case .scroll(let d):
            scrollTouch(d)
        case .scrollEnded(let v):
            startInertia(v)
        case .zoom(let factor, let center, let pan):
            zoom(by: factor, around: center, pan: pan)
        case .resetZoom:
            viewport.update { $0.reset() }
            pointerInteraction?.invalidate()
            feedback?.feedback(.zoomChanged(scale: viewport.value.scale))
        case .haptic(let h):
            let g = h == .light ? lightImpact : mediumImpact
            g.impactOccurred()
        }
    }

    /// Presses / releases `button` at the cursor (placed mid-screen if it
    /// has no position yet); the sticky modifiers are held from the first
    /// press until the last release.
    func pressButton(_ button: Int, down: Bool) {
        guard input != nil else { return }
        if lastHost == nil { moveCursor(by: .zero) }
        if down {
            guard buttons & button == 0 else { return }
            if buttons == 0 { pressStickyForPointer() }
            buttons |= button
            sendButtons()
        } else {
            guard buttons & button != 0 else { return }
            buttons &= ~button
            sendButtons()
            if buttons == 0 { releaseStickyForPointer() }
        }
    }

    /// Pans by `pan`, then zooms by `factor` around `center` (view points).
    func zoom(by factor: CGFloat, around center: CGPoint, pan: CGPoint) {
        guard let input else { return }
        let size = bounds.size, fit = input.fittedRect(in: size)
        viewport.update {
            $0.pan(by: pan, viewSize: size, content: fit)
            $0.zoom(by: factor, around: center, viewSize: size, content: fit)
        }
        pointerInteraction?.invalidate()
        feedback?.feedback(.zoomChanged(scale: viewport.value.scale))
    }

    /// Centres the zoomed viewport on `u` (unit coordinates of the fitted
    /// picture: the minimap).
    func jumpViewport(toContentUnit u: CGPoint) {
        guard let input, viewport.value.isZoomed else { return }
        let size = bounds.size, fit = input.fittedRect(in: size)
        let base = CGPoint(x: fit.minX + u.x * fit.width, y: fit.minY + u.y * fit.height)
        viewport.update { $0.center(on: base, viewSize: size, content: fit) }
        pointerInteraction?.invalidate()
    }

    /// A gesture's meaning (TouchInterpreter) → a FeedbackEvent at the cursor.
    func handleCue(_ cue: TouchCue) {
        guard let feedback else { return }
        switch cue {
        case .fingerDown:
            feedback.feedback(.fingerDown)
        case .click(let button, let count):
            guard let p = cursorBasePoint else { return }
            if button == InputController.Button.right {
                feedback.feedback(.rightClick(at: p))
            } else {
                feedback.feedback(count >= 2 ? .doubleClick(at: p) : .click(at: p))
            }
        case .dragBegan:
            guard let p = cursorBasePoint else { return }
            feedback.feedback(.dragBegan(at: p))
        case .dragEnded:
            feedback.feedback(.dragEnded)
        case .dragLock(let on):
            feedback.feedback(.dragLock(active: on, at: cursorBasePoint))
        case .longPressArmed(let p, let duration):
            feedback.feedback(.longPressBegan(at: p, duration: duration))
        case .longPressFired:
            feedback.feedback(.longPressEnded(fired: true))
        case .longPressCancelled:
            feedback.feedback(.longPressEnded(fired: false))
        }
    }

    @objc private func trackpadPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            stopInertia()
            trackpadPinchScale = 1
        case .changed:
            let factor = trackpadPinchScale > 0 ? g.scale / trackpadPinchScale : 1
            trackpadPinchScale = g.scale
            zoom(by: factor, around: g.location(in: self), pan: .zero)
        default:
            break
        }
    }

    // MARK: Apple Pencil

    /// Pencil double-tap (unless set to do nothing in Settings): right click
    /// at the cursor.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        rightClickAtCursor()
    }

    /// Pencil Pro squeeze (unless set to do nothing): right click at the cursor.
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        rightClickAtCursor()
    }

    private func rightClickAtCursor() {
        guard input != nil, buttons == 0 else { return }
        pressButton(InputController.Button.right, down: true)
        pressButton(InputController.Button.right, down: false)
    }

    // MARK: pointer lock (hardware mouse / trackpad)

    /// Asks for (or gives up) the pointer lock: wanted while connected, in
    /// a window, a mouse/trackpad attached and the menu closed.
    func updatePointerLock() {
        let want = window != nil && input != nil && !menuOpen && PointerLock.mouseConnected
        PointerLock.setWanted(want, by: self)
        if !want { setPointerLocked(false) }
    }

    @objc private func miceChanged(_ note: Notification) {
        updatePointerLock()
        if pointerLocked { attachMice() }
    }

    @objc private func pointerLockChanged(_ note: Notification) {
        guard let scene = window?.windowScene else { return }
        if let changed = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene, changed !== scene { return }
        setPointerLocked(scene.pointerLockState?.isLocked ?? false)
    }

    private func setPointerLocked(_ locked: Bool) {
        guard locked != pointerLocked else { return }
        // Buttons pressed under one regime are released before the other takes over.
        releaseButtons()
        pointerLocked = locked
        lastLockedMove = nil
        Log.input.info("pointer lock \(locked ? "on" : "off")")
        if locked { attachMice() } else { detachMice() }
    }

    private func attachMice() {
        for mouse in GCMouse.mice() {
            guard let m = mouse.mouseInput else { continue }
            m.mouseMovedHandler = { [weak self] _, dx, dy in
                MainActor.assumeIsolated { self?.lockedMouseMoved(dx: CGFloat(dx), dy: CGFloat(dy)) }
            }
            let pairs: [(GCControllerButtonInput?, Int)] = [
                (m.leftButton, InputController.Button.left), (m.rightButton, InputController.Button.right),
                (m.middleButton, InputController.Button.middle),
            ]
            for (control, button) in pairs {
                control?.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated { self?.lockedButton(button, pressed: pressed) }
                }
            }
            m.scroll.valueChangedHandler = { [weak self] _, _, y in
                MainActor.assumeIsolated { self?.lockedScrolled(dy: CGFloat(y)) }
            }
        }
    }

    private func detachMice() {
        for mouse in GCMouse.mice() {
            guard let m = mouse.mouseInput else { continue }
            m.mouseMovedHandler = nil
            m.leftButton.pressedChangedHandler = nil
            m.rightButton?.pressedChangedHandler = nil
            m.middleButton?.pressedChangedHandler = nil
            m.scroll.valueChangedHandler = nil
        }
    }

    /// GCMouse motion (y up) → a relative move (y down), scaled like macOS
    /// at its default tracking speed (PointerScaling) × Settings → Pointer Speed.
    func lockedMouseMoved(dx: CGFloat, dy: CGFloat) {
        guard pointerLocked else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastLockedMove.map { now - $0 } ?? 1.0 / 120
        lastLockedMove = now
        hardwareMouseMoved(dx: dx, dy: dy, dt: dt)
    }

    /// A GCMouse delta of (dx, dy) counts (y up) over `dt` seconds.
    func hardwareMouseMoved(dx: CGFloat, dy: CGFloat, dt: TimeInterval) {
        guard let input else { return }
        moveCursor(by: PointerScaling.viewDelta(
            counts: CGPoint(x: dx, y: -dy), dt: dt, speed: preferences.pointerSpeed,
            hostPointScale: input.pointScale,
            hostPixelsPerViewPoint: input.hostPixelsPerPoint(viewSize: bounds.size, zoom: 1)))
    }

    private func lockedButton(_ button: Int, pressed: Bool) {
        guard pointerLocked else { return }
        stopInertia()
        if pressed, touchInterpreter.dragLocked { touchInterpreter.cancel() }
        pressButton(button, down: pressed)
    }

    private func lockedScrolled(dy: CGFloat) {
        guard pointerLocked else { return }
        stopInertia()
        lockedScroll(dy: dy)
    }

    /// A pointer-lock (GCMouse) scroll of `dy` units.
    func lockedScroll(dy: CGFloat) {
        guard let input, dy != 0 else { return }
        let ticks = lockedScroll.ticks(points: dy * Tuning.lockedScrollPoints * input.scrollSpeed,
                                       ticksPerPoint: input.scrollTicksPerPoint(
            viewSize: bounds.size, zoom: viewport.value.scale))
        scrollAtPointer(ticks, fallback: CGPoint(x: bounds.midX, y: bounds.midY))
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
        let size = bounds.size
        let fit = viewport.value.toScreen(input.fittedRect(in: size), viewSize: size).intersection(bounds)
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
            if uikitKey(key.keyCode, down: down, modifiers: key.modifierFlags, characters: key.characters) == false {
                rest.insert(press)
            }
        }
        return rest
    }

    /// One UIKit hardware key event. With a GC keyboard it goes to the
    /// arbiter (which decides whether it is sent); without, straight to
    /// keyDown/keyUp. False: not a key we map (passed on).
    @discardableResult
    func uikitKey(_ usage: UIKeyboardHIDUsage, down: Bool, modifiers flags: UIKeyModifierFlags,
                  characters: String) -> Bool {
        #if DEBUG
        Log.input.debug("key UIKit \(down ? "down" : "up") usage 0x\(String(usage.rawValue, radix: 16)) "
                        + "flags 0x\(String(flags.rawValue, radix: 16)) gc \(keyArbiter.gcActive)")
        #endif
        guard keyArbiter.gcActive else {
            if !down { noteKeyTester(source: "UIKit", down: false, usage: usage, flags: flags, keysym: keys.keysym(of: usage)) }
            let handled = down ? keyDown(usage, modifiers: flags, characters: characters) : keyUp(usage)
            if down, handled { noteKeyTester(source: "UIKit", down: true, usage: usage, flags: flags, keysym: keys.keysym(of: usage)) }
            return handled
        }
        guard Self.isMappable(usage, characters: characters), !Self.isMenuShortcut(usage, modifiers: flags)
        else { return false }
        keyArbiter.uikit(usage, down: down, flags: flags, characters: characters)
        return true
    }

    /// Keys the hardware path can send: modifiers, table keys, or a key
    /// whose layout character is printable.
    static func isMappable(_ usage: UIKeyboardHIDUsage, characters: String) -> Bool {
        Keysyms.isModifier(usage) || Keysyms.keysym(for: usage, shifted: false) != nil
            || Keysyms.character(in: characters) != nil
    }

    // MARK: GameController keyboard

    /// GC reports keys only while there is a session in a window.
    private func updateGCKeyboard() {
        gcKeyboard.enabled = window != nil && input != nil
    }

    func gcKeyboardAvailability(_ on: Bool) {
        Log.input.info("hardware keyboard via GameController \(on ? "on" : "off")")
        keyArbiter.gcActive = on
        if !on { releaseHeldKeys() }             // nothing GC held may stick
    }

    /// GC keys count only where UIKit's would: this view or the keyboard
    /// proxy has focus in the key window (a text field elsewhere keeps its
    /// keys). Key-ups always pass, so nothing sticks.
    private var acceptsHardwareKeys: Bool {
        guard let window, window.isKeyWindow else { return false }
        return isFirstResponder || keyboardProxy.isFirstResponder
    }

    /// A GCKeyboard key changed (the seam tests drive).
    func gcKey(_ usage: UIKeyboardHIDUsage, pressed: Bool, force: Bool = false) {
        #if DEBUG
        Log.input.debug("key GC \(pressed ? "down" : "up") usage 0x\(String(usage.rawValue, radix: 16))")
        #endif
        guard input != nil, keyArbiter.gcActive, !pressed || force || acceptsHardwareKeys else { return }
        keyArbiter.gc(usage, pressed: pressed)
    }

    /// Sends what the arbiter decided.
    private func applyArbitrated(_ k: ArbitratedKey) {
        let source = k.source == .gc ? (k.uikitSaw ? "GC+UIKit" : "GC") : "UIKit"
        switch k.kind {
        case .down:
            keyDown(k.usage, modifiers: k.flags, characters: k.characters)
            noteKeyTester(source: source, down: true, usage: k.usage, flags: k.flags, keysym: keys.keysym(of: k.usage))
        case .up:
            noteKeyTester(source: source, down: false, usage: k.usage, flags: k.flags, keysym: keys.keysym(of: k.usage))
            keyUp(k.usage)
        case .tap:
            guard keyDown(k.usage, modifiers: k.flags, characters: k.characters) else { return }
            noteKeyTester(source: source, down: true, usage: k.usage, flags: k.flags, keysym: keys.keysym(of: k.usage))
            keyUp(k.usage)
        }
    }

    // MARK: keyboard tester

    private func noteKeyTester(source: String, down: Bool, usage: UIKeyboardHIDUsage, flags: UIKeyModifierFlags,
                               keysym: UInt32?) {
        let ks = keysym.map { "0x" + String($0, radix: 16) } ?? "–"
        #if DEBUG
        Log.input.debug("key sent \(source) \(down ? "down" : "up") usage 0x\(String(usage.rawValue, radix: 16)) "
                        + "flags 0x\(String(flags.rawValue, radix: 16)) keysym \(ks)")
        #endif
        guard preferences.keyboardTester else { return }
        let line = "\(source.padding(toLength: 8, withPad: " ", startingAt: 0)) \(down ? "↓" : "↑") "
            + "0x\(String(format: "%02x", usage.rawValue)) \(KeyTesterLog.symbols(flags).padding(toLength: 4, withPad: " ", startingAt: 0)) → \(ks)"
        keyTesterLog.append(line)
        keyTesterLabel.text = keyTesterLog.lines.joined(separator: "\n")
        layoutKeyTester()
    }

    private func updateKeyTester() {
        keyTesterLabel.isHidden = !preferences.keyboardTester
        if !preferences.keyboardTester { keyTesterLog.clear(); keyTesterLabel.text = nil }
        else {
            keyTesterLabel.text = "Keyboard Tester — press keys"
            layoutKeyTester()
        }
    }

    private func layoutKeyTester() {
        let maxW = min(360, bounds.width - 32)
        let size = keyTesterLabel.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        keyTesterLabel.frame = CGRect(x: 16, y: safeAreaInsets.top + 16, width: min(maxW, size.width + 8),
                                      height: size.height + 8)
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
        keyArbiter.reset()
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
        // A hardware key the GC path already sent, echoed by the text system.
        if keyArbiter.recentGCDown({ !Keysyms.isModifier($0) && $0 != .keyboardDeleteOrBackspace }) { return }
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
        if keyArbiter.recentGCDown({ $0 == .keyboardDeleteOrBackspace }) { return }    // the GC path sent it
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
