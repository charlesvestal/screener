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
// iPadOS system shortcuts (⌘H, ⌘Tab, …) are not captured here (Task 22).
import UIKit

@MainActor
final class RemoteInputView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
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
        keyboardProxy.onDelete = { [weak self] in self?.tapKey(Keysyms.backSpace) }
        keyboardProxy.onPresses = { [weak self] presses, down in self?.handle(presses, down: down) ?? presses }
        keyboardProxy.onResign = { [weak self] in self?.softwareKeyboardResigned() }
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
            return
        }
        guard let host = input.hostPoint(forViewPoint: point, viewSize: bounds.size) else { return }
        let moved = lastHost.map { $0 != host } ?? true
        lastHost = host
        if moved || !coalescable {
            input.pointer(buttons: buttons, x: host.x, y: host.y, coalescable: coalescable)
        }
        cursor?.move(toHostX: host.x, y: host.y, hostWidth: input.serverWidth, hostHeight: input.serverHeight)
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
            if buttons == 0 { cursor?.hide() }
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
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerTouch(touches) != nil else { return super.touchesCancelled(touches, with: event) }
        buttons = 0
        sendButtons()
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

    private func click(at point: CGPoint, button: Int) {
        guard input != nil, buttons == 0 else { return }
        movePointer(to: point, coalescable: false)
        buttons = button
        sendButtons()
        buttons = 0
        sendButtons()
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
            buttons = InputController.Button.left
            sendButtons()
        case .changed:
            movePointer(to: g.location(in: self), coalescable: true)
        case .ended, .cancelled, .failed:
            buttons = 0
            sendButtons()
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
    @discardableResult
    func keyDown(_ usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags, characters: String) -> Bool {
        guard let input, let ks = keys.press(usage, modifiers: modifiers, characters: characters) else { return false }
        input.key(down: true, keysym: ks)
        if !Keysyms.isModifier(usage) { repeater.keyDown(usage: usage.rawValue, keysym: ks) }
        return true
    }

    /// A hardware key went up; false if it never went down here.
    @discardableResult
    func keyUp(_ usage: UIKeyboardHIDUsage) -> Bool {
        repeater.keyUp(usage: usage.rawValue)
        guard let ks = keys.release(usage) else { return false }
        input?.key(down: false, keysym: ks)
        return true
    }

    private func releaseHeldKeys() {
        repeater.cancel()
        for ks in keys.releaseAll() { input?.key(down: false, keysym: ks) }
    }

    // MARK: on-screen keyboard

    private func typeText(_ text: String) {
        guard let input else { return }
        for ch in text {
            for t in Keysyms.typed(ch) {
                if t.shift { input.key(down: true, keysym: Keysyms.shiftL) }
                input.key(down: true, keysym: t.keysym)
                input.key(down: false, keysym: t.keysym)
                if t.shift { input.key(down: false, keysym: Keysyms.shiftL) }
            }
        }
    }

    private func tapKey(_ keysym: UInt32) {
        input?.key(down: true, keysym: keysym)
        input?.key(down: false, keysym: keysym)
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
