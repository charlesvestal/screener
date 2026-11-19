// Finger and Pencil gestures → pointer actions (Task 22).
//
// TouchInterpreter is fed raw touches (RemoteInputView's touchesBegan/…
// for `.direct` and `.pencil` touches) and emits TouchActions; it never
// touches the wire, so every gesture's event sequence is unit-tested
// (TrackpadModeTests, HoldGestureTests). RemoteInputView performs the actions.
//
// The gestures follow Screens 5 (Edovia). In BOTH modes:
//   - tap: left click; double tap: double click
//   - two-finger tap: right click; three-finger tap: middle click
//   - two-finger drag: scroll (momentum after)
//   - touch and hold (`holdDelay`, Settings → Touch-and-Hold Drag Delay:
//     0.3 / 0.45 / 0.6 s) with one, two or three fingers until the
//     indicator appears (a progress ring, then a pulse at the cursor —
//     blue / red / green), then drag: a left / right / middle-button drag.
//     The button goes down when the fingers move past the slop after the
//     hold fired; lifting without moving does nothing more. Moving or
//     pinching before it fires cancels the hold (it is then a scroll / zoom
//     / swipe). The first finger to lift ends a multi-finger drag.
//   - three-finger swipe (moved `Tuning.swipeDistance` before the hold
//     fires): the Mac trackpad's shortcut, once per swipe — left ⌃→ (to the
//     Space on the right, as on a Magic Trackpad), right ⌃←, up ⌃↑ Mission
//     Control, down ⌃↓ App Exposé (ThreeFingerSwipe)
//   - pinch zooms around the fingers (Viewport, 1×–4×) and pans with them;
//     a two-finger double-tap resets to fit. While zoomed, a two-finger tap
//     waits `tapDelay` for a second one (reset) before right-clicking.
//   - four or more fingers are left to the system.
// Trackpad mode (the default for fingers):
//   - one-finger drag: moves the cursor relatively; finger speed sets the
//     gain (TrackpadAcceleration, 1.0 → 2.5). A hold-drag moves it the same
//     way (the fingers' centroid) with the button held.
//   - tap: left click at the cursor. The click (haptic + button) waits
//     `tapDelay` (Settings → Tap to Click: 0.15 / 0.25 / 0.35 s) for a second
//     touch, so a tap-and-drag never reaches the Mac as a click followed by a
//     press (= a double-click drag: word selection, window zoom); the click's
//     *cue* (`onCue`, for the ripple) fires immediately at the tap's touch-up,
//     not after the wait, so the feedback reads as instant even though the
//     click itself is still held back
//   - double-tap: a double click (both clicks sent at the second tap; each
//     tap's cue fires at its own touch-up, giving two rings)
//   - double-tap-and-hold (second touch within the window, then held still
//     `tapMaxDuration` or moved): left-button drag until it lifts (no hold
//     indicator: the second touch is never a hold)
//   - clicks, taps and hold indicators are at the cursor.
// Touch (direct) mode (Pencil always uses it):
//   - tap: left click at the touch; one-finger drag: an immediate left-button
//     drag from the touch point
//   - holds, two-/three-finger taps and scrolls act at the fingers'
//     centroid (the cursor jumps there when a hold fires).
//
// Feedback cues (`onCue`, TouchCue): alongside its actions the interpreter
// reports what a gesture MEANT — a click (and how many), a hold arming /
// firing / being abandoned, a drag (and its button) starting or ending, a
// trackpad finger landing — for the visual feedback (RemoteInputView →
// FeedbackSink). Cues never change the actions.
//
// Nothing stays pressed: every button-down has its button-up on lift, on a
// cancelled touch (system gesture), on too many fingers (abandon), on
// `cancel()` (mode switch, menu open, focus loss, teardown). Swipe chords are
// complete taps (modifiers down, key down/up, modifiers up).
import CoreGraphics
import Foundation

/// How finger touches drive the pointer.
enum TouchInputMode: String, CaseIterable, Sendable {
    /// Relative cursor, like a laptop trackpad (default).
    case trackpad
    /// The touch point is the cursor.
    case direct

    /// @AppStorage key (per host in Task 23).
    static let defaultsKey = "input.touchMode"
    static let `default` = TouchInputMode.trackpad

    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .direct: "Touch"
        }
    }
}

/// Trackpad-mode pointer gain by finger speed: 1.0 when slow (precise),
/// rising smoothly to 2.5 when fast (crossing the screen in one swipe).
enum TrackpadAcceleration {
    static let minGain: CGFloat = 1.0
    static let maxGain: CGFloat = 2.5
    /// At or below this speed (view points/s) the gain is minGain.
    static let slowSpeed: CGFloat = 150
    /// At or above this speed the gain is maxGain.
    static let fastSpeed: CGFloat = 1500

    static func gain(speed: CGFloat) -> CGFloat {
        guard speed.isFinite, speed > slowSpeed else { return minGain }
        let t = min(1, (speed - slowSpeed) / (fastSpeed - slowSpeed))
        let s = t * t * (3 - 2 * t)                    // smoothstep
        return minGain + (maxGain - minGain) * s
    }

    /// `delta` (view points) moved in `dt` seconds, accelerated.
    static func apply(_ delta: CGPoint, dt: TimeInterval) -> CGPoint {
        let speed = dt > 0 ? hypot(delta.x, delta.y) / CGFloat(dt) : 0
        let g = gain(speed: speed)
        return CGPoint(x: delta.x * g, y: delta.y * g)
    }
}

enum TouchHaptic: Equatable, Sendable {
    /// A click, a swipe's shortcut.
    case light
    /// A right / middle click, a drag starting, a hold firing.
    case medium
}

/// A three-finger swipe: the Mac trackpad's equivalent shortcut. The swipe
/// direction is the fingers' (left = fingers moved left), mapped as a Magic
/// Trackpad does: swiping left reveals the Space on the right (⌃→).
enum ThreeFingerSwipe: Equatable, CaseIterable, Sendable {
    case left, right, up, down

    var chord: KeyChord {
        let ctrl = StickyModifier.control.keysym!
        switch self {
        case .left: return KeyChord([ctrl], SpecialKey.right.keysym)
        case .right: return KeyChord([ctrl], SpecialKey.left.keysym)
        case .up: return ShortcutAction.missionControl.chord        // ⌃↑
        case .down: return ShortcutAction.appExpose.chord           // ⌃↓
        }
    }

    /// The dominant direction of a travel `d` (view points, y down).
    static func direction(_ d: CGPoint) -> ThreeFingerSwipe {
        if abs(d.x) >= abs(d.y) { return d.x < 0 ? .left : .right }
        return d.y < 0 ? .up : .down
    }
}

/// What a gesture asks of the pointer.
enum TouchAction: Equatable {
    /// A new gesture began (stops scroll momentum).
    case began
    /// Trackpad: move the cursor by this many view points (accelerated).
    case moveBy(CGPoint)
    /// Direct: put the cursor under this view point.
    case moveTo(CGPoint)
    /// Press or release `button` (InputController.Button) at the cursor.
    case button(Int, down: Bool)
    /// Scroll by the fingers' travel in view points (y > 0: fingers moved down).
    case scroll(CGPoint)
    /// The fingers left a scroll moving at `velocity` (view points/s).
    case scrollEnded(velocity: CGPoint)
    /// Pinch: pan by `pan`, then zoom by `factor` around `center` (view points).
    case zoom(factor: CGFloat, center: CGPoint, pan: CGPoint)
    case resetZoom
    case haptic(TouchHaptic)
    /// Tap this key chord (a three-finger swipe's shortcut).
    case keyChord(KeyChord)
}

/// What a gesture meant, for visual feedback (never sent to the Mac).
enum TouchCue: Equatable {
    /// Trackpad mode: a finger landed (not Pencil).
    case fingerDown
    /// `count` clicks of `button` were sent (2: a double click).
    case click(button: Int, count: Int)
    /// A one-/two-/three-finger hold started arming: it fires after
    /// `duration` if the fingers stay still, for a `button` drag. `at`: the
    /// fingers' centroid (Touch mode, view points); nil in Trackpad mode (at
    /// the cursor).
    case holdArmed(at: CGPoint?, duration: TimeInterval, button: Int)
    case holdFired
    case holdCancelled
    /// A drag with `button` is armed or pressed (a fired hold, a tap-drag, a
    /// Touch-mode drag): the indicator pulse at the cursor.
    case dragBegan(button: Int)
    /// That drag is over (button released, or the hold ended unused).
    case dragEnded
}

@MainActor
final class TouchInterpreter {
    enum Tuning {
        /// Travel (points) under which a touch is still a tap / still.
        static let slop: CGFloat = 10
        /// Change in finger spread (points) that makes two fingers a pinch.
        static let pinchSlop: CGFloat = 16
        /// A tap is shorter than this.
        static let tapMaxDuration: TimeInterval = 0.3
        /// The default `tapDelay` (TapClickDelay.normal).
        static let tapDragWindow: TimeInterval = 0.25
        /// The default `holdDelay` (HoldDragDelay.normal).
        static let holdDelay: TimeInterval = 0.45
        /// Three fingers' travel (points) that makes a swipe.
        static let swipeDistance: CGFloat = 50
        /// Scroll release velocity is measured over this much recent motion.
        static let velocityWindow: TimeInterval = 0.1
    }

    private enum Phase: Equatable {
        case idle
        /// One finger down, undecided.
        case pending
        /// Trackpad: cursor moving, no button.
        case moving
        /// `dragButton` held for this gesture.
        case dragging
        /// A hold fired; the drag's button goes down when the fingers move.
        case held
        /// Two fingers, undecided.
        case twoPending
        case scrolling
        case zooming
        /// Three fingers, undecided.
        case threePending
        /// Three fingers moving before the hold fired: a swipe so far.
        case swiping
        /// Ignored until every finger lifts.
        case ignored
    }

    private struct Finger {
        var start: CGPoint
        var last: CGPoint
    }

    var mode: TouchInputMode = .default {
        didSet { if mode != oldValue { cancel() } }
    }
    /// Whether the viewport is zoomed (two-finger taps wait for a double tap).
    var isZoomed: () -> Bool = { false }
    /// Trackpad: a tap's click waits this long for a tap-drag / double tap;
    /// zoomed: a two-finger tap waits this long for a double tap
    /// (Settings → Tap to Click, TapClickDelay).
    var tapDelay: TimeInterval = Tuning.tapDragWindow
    /// How long a still hold takes to arm a drag (Settings → Touch-and-Hold
    /// Drag Delay, HoldDragDelay). Read when a hold starts arming.
    var holdDelay: TimeInterval = Tuning.holdDelay

    private let perform: (TouchAction) -> Void
    /// Feedback cues (TouchCue).
    var onCue: ((TouchCue) -> Void)?
    /// A hold is armed (its cue was sent; fired / cancelled is owed).
    private var holdArmed = false
    /// The button of the armed / fired hold.
    private var holdButton = InputController.Button.left
    private let schedule: KeyRepeater.Schedule

    private var fingers: [Int: Finger] = [:]
    private var ignoredFingers: Set<Int> = []
    private var phase = Phase.idle
    private var pencil = false
    private var gestureStart: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var startCentroid = CGPoint.zero
    private var startSpread: CGFloat = 0
    private var lastCentroid = CGPoint.zero
    private var lastSpread: CGFloat = 0
    private var scrollSamples: [(t: TimeInterval, d: CGPoint)] = []

    /// This gesture holds `dragButton`.
    private var buttonDown = false
    private var dragButton = InputController.Button.left
    /// A `dragBegan` cue was sent; `dragEnded` is owed.
    private var dragCueOpen = false
    /// Trackpad: a tap's click waiting for the tap-drag window.
    private var pendingClick: (() -> Void)?
    /// Trackpad: this gesture began inside a pending click's window.
    private var owedClick = false
    /// Zoomed: a two-finger tap's right click waiting for a double tap.
    private var pendingRightClick: (() -> Void)?
    private var pendingRightClickAt: CGPoint?
    private var timer: (() -> Void)?

    init(schedule: @escaping KeyRepeater.Schedule = KeyRepeater.runLoopTimer,
         perform: @escaping (TouchAction) -> Void) {
        self.schedule = schedule
        self.perform = perform
    }

    /// Gesture semantics for this gesture: Pencil is always direct.
    private var effectiveMode: TouchInputMode { pencil ? .direct : mode }

    /// Whether this gesture holds a mouse button now.
    var isHoldingButton: Bool { buttonDown }

    // MARK: input

    func began(_ id: Int, at p: CGPoint, time t: TimeInterval, pencil isPencil: Bool = false) {
        if fingers.isEmpty, phase == .idle || phase == .ignored {
            startGesture(id, at: p, time: t, pencil: isPencil)
            return
        }
        guard !pencil, !isPencil, phase != .ignored else { ignoredFingers.insert(id); return }
        fingers[id] = Finger(start: p, last: p)
        lastTime = t
        switch (phase, fingers.count) {
        case (.pending, 2), (.moving, 2):
            cancelTimer()
            flushOwedClick()
            phase = .twoPending
            markMultiStart()
            armHold(InputController.Button.right)
        case (.twoPending, 3):
            cancelTimer()
            flushPendingRightClick()
            phase = .threePending
            markMultiStart()
            armHold(InputController.Button.middle)
        case (_, let n) where n >= 4:
            abandon()
        case (.dragging, _), (.held, _), (.scrolling, _), (.zooming, _):
            // A resting extra finger: not part of this gesture.
            fingers[id] = nil
            ignoredFingers.insert(id)
        default:
            abandon()
        }
    }

    func moved(_ id: Int, to p: CGPoint, time t: TimeInterval) {
        moved([id: p], time: t)
    }

    /// Every moved touch of one event.
    func moved(_ points: [Int: CGPoint], time t: TimeInterval) {
        var any = false
        for (id, p) in points where fingers[id] != nil {
            fingers[id]!.last = p
            any = true
        }
        guard any else { return }
        let dt = t - lastTime
        lastTime = t
        switch phase {
        case .pending:
            guard let f = fingers.values.first, distance(f.start, f.last) > Tuning.slop else { return }
            let delta = sub(f.last, f.start)
            flushPendingRightClick()
            cancelTimer()
            if effectiveMode == .trackpad {
                if owedClick {
                    owedClick = false
                    startDrag()
                } else {
                    phase = .moving
                }
                perform(.moveBy(delta))
            } else {
                perform(.moveTo(f.start))
                startDrag()
                perform(.moveTo(f.last))
            }
            lastCentroid = f.last
        case .moving, .dragging:
            let c = centroid()
            if effectiveMode == .trackpad {
                perform(.moveBy(TrackpadAcceleration.apply(sub(c, lastCentroid), dt: dt)))
            } else {
                perform(.moveTo(c))
            }
            lastCentroid = c
        case .held:
            let c = centroid()
            guard distance(c, startCentroid) > Tuning.slop else { return }
            phase = .dragging
            pressDragButton(holdButton)
            if effectiveMode == .trackpad {
                perform(.moveBy(sub(c, startCentroid)))
            } else {
                perform(.moveTo(c))
            }
            lastCentroid = c
        case .twoPending:
            guard fingers.count == 2 else { return }
            let c = centroid(), s = spread()
            if abs(s - startSpread) > Tuning.pinchSlop {
                cancelTimer()
                phase = .zooming
                lastCentroid = c
                lastSpread = s
            } else if distance(c, startCentroid) > Tuning.slop {
                cancelTimer()
                phase = .scrolling
                scrollSamples = []
                if effectiveMode == .direct { perform(.moveTo(startCentroid)) }
                emitScroll(sub(c, startCentroid), at: t)
                lastCentroid = c
            }
        case .scrolling:
            guard fingers.count == 2 else { return }
            let c = centroid()
            emitScroll(sub(c, lastCentroid), at: t)
            lastCentroid = c
        case .zooming:
            guard fingers.count == 2 else { return }
            let c = centroid(), s = spread()
            let factor = lastSpread > 0 && s > 0 ? s / lastSpread : 1
            perform(.zoom(factor: factor, center: c, pan: sub(c, lastCentroid)))
            lastCentroid = c
            lastSpread = s
        case .threePending, .swiping:
            guard fingers.count == 3 else { return }
            let d = sub(centroid(), startCentroid)
            let travel = hypot(d.x, d.y)
            if phase == .threePending {
                guard travel > Tuning.slop else { return }
                cancelTimer()
                phase = .swiping
            }
            guard travel >= Tuning.swipeDistance else { return }
            // One shortcut per swipe; the rest of the touch is ignored.
            phase = .ignored
            perform(.haptic(.light))
            perform(.keyChord(ThreeFingerSwipe.direction(d).chord))
        case .idle, .ignored:
            break
        }
    }

    func ended(_ id: Int, at p: CGPoint, time t: TimeInterval) {
        if ignoredFingers.remove(id) != nil {
            if fingers.isEmpty, ignoredFingers.isEmpty, phase == .ignored { phase = .idle }
            return
        }
        guard let f = fingers.removeValue(forKey: id) else { return }
        let duration = t - gestureStart
        switch phase {
        case .scrolling:
            // The first finger up ends the scroll; the other is ignored.
            perform(.scrollEnded(velocity: scrollVelocity(at: t)))
            phase = .ignored
        case .zooming, .swiping:
            phase = .ignored
        case .dragging, .held:
            // The first finger up ends a multi-finger drag.
            if !fingers.isEmpty {
                releaseGestureButton()
                phase = .ignored
            }
        case .twoPending, .threePending:
            // A finger lifted: no hold (a tap is still possible).
            if !fingers.isEmpty { cancelTimer() }
        default:
            break
        }
        guard fingers.isEmpty else { return }
        let ended = phase
        phase = .idle
        cancelTimer()
        switch ended {
        case .pending:
            if effectiveMode == .trackpad {
                trackpadTap(quick: duration <= Tuning.tapMaxDuration)
            } else {
                perform(.moveTo(f.start))
                click(InputController.Button.left, haptic: .light)
            }
        case .dragging, .held:
            releaseGestureButton()                   // a still hold: nothing more
        case .twoPending:
            if duration <= Tuning.tapMaxDuration * 1.5 { twoFingerTap() }
        case .threePending:
            if duration <= Tuning.tapMaxDuration * 1.5 { threeFingerTap() }
        case .moving, .scrolling, .zooming, .swiping, .ignored, .idle:
            break
        }
        ignoredFingers.removeAll()
        owedClick = false
    }

    /// A touch was cancelled (a system gesture took it): the whole gesture
    /// ends, releasing anything it pressed.
    func cancelled(_ id: Int) {
        if ignoredFingers.remove(id) != nil { return }
        guard fingers.removeValue(forKey: id) != nil else { return }
        if phase == .scrolling { perform(.scrollEnded(velocity: .zero)) }
        cancelTimer()
        releaseGestureButton()
        owedClick = false
        phase = fingers.isEmpty ? .idle : .ignored
        if fingers.isEmpty { ignoredFingers.removeAll() } else {
            ignoredFingers.formUnion(fingers.keys)
            fingers.removeAll()
        }
    }

    /// Ends everything: pending clicks are dropped, held buttons released.
    /// Mode switch, menu open, focus loss, teardown.
    func cancel() {
        cancelTimer()
        pendingClick?()
        pendingClick = nil
        pendingRightClick?()
        pendingRightClick = nil
        owedClick = false
        if phase == .scrolling { perform(.scrollEnded(velocity: .zero)) }
        releaseGestureButton()
        // Fingers still down stay out of the next gesture.
        ignoredFingers.formUnion(fingers.keys)
        fingers.removeAll()
        phase = .idle
    }

    // MARK: gestures

    private func startGesture(_ id: Int, at p: CGPoint, time t: TimeInterval, pencil isPencil: Bool) {
        perform(.began)
        fingers = [id: Finger(start: p, last: p)]
        ignoredFingers.removeAll()
        pencil = isPencil
        gestureStart = t
        lastTime = t
        lastCentroid = p
        startCentroid = p
        phase = .pending
        if effectiveMode == .trackpad {
            onCue?(.fingerDown)
            if let cancelClick = pendingClick {
                // A second touch inside the tap's window: a double tap or a tap-drag.
                cancelClick()
                pendingClick = nil
                owedClick = true
                timer = schedule(Tuning.tapMaxDuration) { [weak self] in self?.holdBecameDrag() }
                return
            }
        } else {
            flushPendingClicks()
        }
        armHold(InputController.Button.left)
    }

    /// Starts the hold timer for a `button` drag (the fingers are still).
    private func armHold(_ button: Int) {
        holdButton = button
        let delay = holdDelay
        timer = schedule(delay) { [weak self] in self?.holdFired() }
        holdArmed = true
        onCue?(.holdArmed(at: effectiveMode == .direct ? startCentroid : nil, duration: delay, button: button))
    }

    /// The fingers stayed still for `holdDelay`: the drag is armed (the
    /// indicator shows); its button goes down when they move.
    private func holdFired() {
        timer = nil
        let needed: Int
        let expected: Phase
        switch holdButton {
        case InputController.Button.right: (needed, expected) = (2, .twoPending)
        case InputController.Button.middle: (needed, expected) = (3, .threePending)
        default: (needed, expected) = (1, .pending)
        }
        let valid = phase == expected && fingers.count == needed && !owedClick
        if holdArmed {
            holdArmed = false
            if !valid { onCue?(.holdCancelled) }
        }
        guard valid else { return }
        flushPendingRightClick()
        phase = .held
        if effectiveMode == .direct { perform(.moveTo(startCentroid)) }
        perform(.haptic(.medium))
        onCue?(.holdFired)
        dragButton = holdButton
        dragCueOpen = true
        onCue?(.dragBegan(button: holdButton))
    }

    private func trackpadTap(quick: Bool) {
        guard quick else { return }
        if owedClick {
            // The first tap's ring already fired at its own touch-up; this is
            // the second tap's ring (together: the double-click look).
            owedClick = false
            perform(.haptic(.light))
            perform(.button(InputController.Button.left, down: true))
            perform(.button(InputController.Button.left, down: false))
            perform(.button(InputController.Button.left, down: true))
            perform(.button(InputController.Button.left, down: false))
            onCue?(.click(button: InputController.Button.left, count: 1))
            return
        }
        // The ripple fires now, at recognition; the click itself (haptic +
        // button) waits `tapDelay` for a possible tap-drag / double tap.
        onCue?(.click(button: InputController.Button.left, count: 1))
        pendingClick = schedule(tapDelay) { [weak self] in
            guard let self else { return }
            self.pendingClick = nil
            self.sendClick(InputController.Button.left, haptic: .light)
        }
    }

    private func twoFingerTap() {
        let at = startCentroid
        if let cancelRight = pendingRightClick {
            cancelRight()
            pendingRightClick = nil
            pendingRightClickAt = nil
            perform(.resetZoom)
            return
        }
        if isZoomed() {
            pendingRightClickAt = at
            // Ripple now, at recognition; the click waits for a possible
            // second two-finger tap (zoom reset).
            onCue?(.click(button: InputController.Button.right, count: 1))
            pendingRightClick = schedule(tapDelay) { [weak self] in
                guard let self else { return }
                self.pendingRightClick = nil
                self.sendRightClick(at: self.pendingRightClickAt ?? at)
                self.pendingRightClickAt = nil
            }
        } else {
            rightClick(at: at)
        }
    }

    /// Middle click at the cursor (Touch: at the fingers).
    private func threeFingerTap() {
        if effectiveMode == .direct { perform(.moveTo(startCentroid)) }
        click(InputController.Button.middle, haptic: .medium)
    }

    private func rightClick(at p: CGPoint) {
        if effectiveMode == .direct { perform(.moveTo(p)) }
        click(InputController.Button.right, haptic: .medium)
    }

    /// `rightClick(at:)` without the cue: for a delayed send whose ripple
    /// already fired at recognition.
    private func sendRightClick(at p: CGPoint) {
        if effectiveMode == .direct { perform(.moveTo(p)) }
        sendClick(InputController.Button.right, haptic: .medium)
    }

    /// Trackpad: double-tap-and-hold without moving.
    private func holdBecameDrag() {
        timer = nil
        guard phase == .pending, owedClick else { return }
        owedClick = false
        flushPendingRightClick()
        startDrag()
    }

    /// An immediate left drag (tap-drag, Touch-mode drag): pressed now.
    private func startDrag() {
        phase = .dragging
        perform(.haptic(.medium))
        pressDragButton(InputController.Button.left)
        dragCueOpen = true
        onCue?(.dragBegan(button: InputController.Button.left))
    }

    private func pressDragButton(_ button: Int) {
        guard !buttonDown else { return }
        buttonDown = true
        dragButton = button
        perform(.button(button, down: true))
    }

    /// Releases this gesture's button (if pressed) and ends its indicator.
    private func releaseGestureButton() {
        if buttonDown {
            buttonDown = false
            perform(.button(dragButton, down: false))
        }
        if dragCueOpen {
            dragCueOpen = false
            onCue?(.dragEnded)
        }
    }

    private func click(_ button: Int, haptic: TouchHaptic?) {
        sendClick(button, haptic: haptic)
        onCue?(.click(button: button, count: 1))
    }

    /// `click`'s haptic + button press, with no cue: for a delayed send
    /// whose ripple already fired at recognition (touch-up).
    private func sendClick(_ button: Int, haptic: TouchHaptic?) {
        if let haptic { perform(.haptic(haptic)) }
        perform(.button(button, down: true))
        perform(.button(button, down: false))
    }

    /// A gesture that is not a click came in while one was waiting: send it
    /// now. Its ripple already fired at the tap's own touch-up.
    private func flushOwedClick() {
        guard owedClick else { return }
        owedClick = false
        sendClick(InputController.Button.left, haptic: .light)
    }

    /// A gesture committed while a zoomed two-finger tap waited for its
    /// double tap: right click now, before the cursor moves. Its ripple
    /// already fired when the two-finger tap was recognised.
    private func flushPendingRightClick() {
        guard let cancelRight = pendingRightClick else { return }
        cancelRight()
        pendingRightClick = nil
        sendRightClick(at: pendingRightClickAt ?? startCentroid)
        pendingRightClickAt = nil
    }

    private func flushPendingClicks() {
        if let c = pendingClick {
            c()
            pendingClick = nil
            click(InputController.Button.left, haptic: .light)
        }
    }

    /// Too many fingers, or an unexpected combination: release and ignore
    /// until everything lifts.
    private func abandon() {
        cancelTimer()
        flushOwedClick()
        if phase == .scrolling { perform(.scrollEnded(velocity: .zero)) }
        releaseGestureButton()
        phase = .ignored
        ignoredFingers.formUnion(fingers.keys)
        fingers.removeAll()
    }

    private func cancelTimer() {
        timer?()
        timer = nil
        if holdArmed {
            holdArmed = false
            onCue?(.holdCancelled)
        }
    }

    // MARK: geometry

    private func markMultiStart() {
        startCentroid = centroid()
        lastCentroid = startCentroid
        startSpread = spread()
        lastSpread = startSpread
    }

    private func emitScroll(_ d: CGPoint, at t: TimeInterval) {
        guard d != .zero else { return }
        scrollSamples.append((t, d))
        scrollSamples.removeAll { t - $0.t > Tuning.velocityWindow }
        perform(.scroll(d))
    }

    /// The fingers' velocity over the last `velocityWindow` (zero if they
    /// had stopped).
    private func scrollVelocity(at t: TimeInterval) -> CGPoint {
        let recent = scrollSamples.filter { t - $0.t <= Tuning.velocityWindow }
        guard let first = recent.first, recent.count >= 2 else { return .zero }
        // Distance after the first sample, over the time since it.
        let span = t - first.t
        guard span > 0.005 else { return .zero }
        let sum = recent.dropFirst().reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.d.x, y: $0.y + $1.d.y) }
        return CGPoint(x: sum.x / span, y: sum.y / span)
    }

    private func centroid() -> CGPoint {
        guard !fingers.isEmpty else { return lastCentroid }
        let n = CGFloat(fingers.count)
        let s = fingers.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.last.x, y: $0.y + $1.last.y) }
        return CGPoint(x: s.x / n, y: s.y / n)
    }

    private func spread() -> CGFloat {
        let ps = Array(fingers.values)
        guard ps.count >= 2 else { return 0 }
        return distance(ps[0].last, ps[1].last)
    }
}

private func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }