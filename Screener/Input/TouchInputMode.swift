// Finger and Pencil gestures → pointer actions (Task 22).
//
// TouchInterpreter is fed raw touches (RemoteInputView's touchesBegan/…
// for `.direct` and `.pencil` touches) and emits TouchActions; it never
// touches the wire, so every gesture's event sequence is unit-tested
// (TrackpadModeTests). RemoteInputView performs the actions.
//
// Trackpad mode (the default for fingers; like Screens):
//   - one-finger drag: moves the cursor relatively; finger speed sets the
//     gain (TrackpadAcceleration, 1.0 → 2.5)
//   - tap: left click at the cursor. The click waits `tapDragWindow` for a
//     second touch, so a tap-and-drag never reaches the Mac as a click
//     followed by a press (= a double-click drag: word selection, window zoom)
//   - double-tap: a double click (both clicks sent at the second tap)
//   - double-tap-and-hold (second touch within the window, then held still
//     `tapMaxDuration` or moved): left-button drag until it lifts
//   - two-finger tap: right click; two-finger drag: scroll (momentum after)
//   - three-finger drag: drag lock — the button goes down and stays down
//     after the fingers lift; one-finger drags keep dragging; a tap releases
// Direct mode (the original touch behaviour; Pencil always uses it):
//   - tap: left click at the touch; one-finger drag: left-button drag from
//     the touch point
//   - long press (0.5 s, haptic): released in place = right click there;
//     moved after = left-button drag (the original long-press drag)
//   - two-finger tap: right click at the fingers; two-finger drag: scroll at
//     the fingers
// Both modes: pinch zooms around the fingers (Viewport, 1×–4×) and pans with
// them; a two-finger double-tap resets to fit. While zoomed, a two-finger tap
// waits `tapDragWindow` for a second one (reset) before right-clicking.
// Four or more fingers are left to the system.
//
// Nothing stays pressed: every button-down has its button-up on lift, on a
// cancelled touch (system gesture), on `cancel()` (mode switch, menu open,
// focus loss, teardown). The drag lock is the one deliberate hold; it too
// is released by `cancel()`.
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
    /// A click.
    case light
    /// A right click, a drag starting, a long press.
    case medium
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
        /// Trackpad: a tap's click waits this long for a tap-drag / double tap;
        /// zoomed: a two-finger tap waits this long for a double tap.
        static let tapDragWindow: TimeInterval = 0.25
        /// Direct: long press.
        static let longPress: TimeInterval = 0.5
        /// Scroll release velocity is measured over this much recent motion.
        static let velocityWindow: TimeInterval = 0.1
    }

    private enum Phase: Equatable {
        case idle
        /// Down, undecided.
        case pending
        /// Trackpad: cursor moving (button held only under a drag lock).
        case moving
        /// Left button held for this gesture.
        case dragging
        /// Direct: long press recognised, finger still down.
        case longPressed
        /// Two fingers, undecided.
        case twoPending
        case scrolling
        case zooming
        /// Trackpad: three fingers, undecided.
        case threePending
        /// Trackpad: three-finger drag (lock).
        case threeDrag
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

    private let perform: (TouchAction) -> Void
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

    /// This gesture holds the left button.
    private var buttonDown = false
    /// Trackpad drag lock: the button stays down between gestures.
    private(set) var dragLocked = false
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
        case (.twoPending, 3) where effectiveMode == .trackpad:
            phase = .threePending
            markMultiStart()
        case (_, let n) where n >= 4:
            abandon()
        case (.dragging, _), (.longPressed, _), (.scrolling, _), (.zooming, _), (.threeDrag, _):
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
            if effectiveMode == .trackpad {
                cancelTimer()
                if owedClick {
                    owedClick = false
                    startDrag()
                } else {
                    phase = .moving
                }
                perform(.moveBy(delta))
            } else {
                cancelTimer()
                perform(.moveTo(f.start))
                startDrag()
                perform(.moveTo(f.last))
            }
            lastCentroid = f.last
        case .moving, .dragging:
            guard let f = fingers.values.first else { return }
            if effectiveMode == .trackpad {
                perform(.moveBy(TrackpadAcceleration.apply(sub(f.last, lastCentroid), dt: dt)))
            } else {
                perform(.moveTo(f.last))
            }
            lastCentroid = f.last
        case .longPressed:
            guard let f = fingers.values.first, distance(f.start, f.last) > Tuning.slop else { return }
            phase = .dragging
            buttonDown = true
            perform(.button(InputController.Button.left, down: true))
            perform(.moveTo(f.last))
            lastCentroid = f.last
        case .twoPending:
            guard fingers.count == 2 else { return }
            let c = centroid(), s = spread()
            if abs(s - startSpread) > Tuning.pinchSlop {
                phase = .zooming
                lastCentroid = c
                lastSpread = s
            } else if distance(c, startCentroid) > Tuning.slop {
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
        case .threePending:
            guard fingers.count == 3 else { return }
            let c = centroid()
            guard distance(c, startCentroid) > Tuning.slop else { return }
            phase = .threeDrag
            perform(.haptic(.medium))
            if !dragLocked { perform(.button(InputController.Button.left, down: true)) }
            dragLocked = true
            perform(.moveBy(sub(c, startCentroid)))
            lastCentroid = c
        case .threeDrag:
            guard fingers.count == 3 else { return }
            let c = centroid()
            perform(.moveBy(TrackpadAcceleration.apply(sub(c, lastCentroid), dt: dt)))
            lastCentroid = c
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
        case .zooming:
            phase = .ignored
        case .threeDrag:
            phase = .ignored                       // the lock holds the button
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
        case .longPressed:
            click(InputController.Button.right, haptic: nil)          // haptic given at the press
        case .dragging:
            releaseGestureButton()
        case .twoPending:
            if duration <= Tuning.tapMaxDuration * 1.5 { twoFingerTap() }
        case .moving, .scrolling, .zooming, .threePending, .threeDrag, .ignored, .idle:
            break
        }
        ignoredFingers.removeAll()
        owedClick = false
    }

    /// A touch was cancelled (a system gesture took it): the whole gesture
    /// ends, releasing anything it pressed (the drag lock stays).
    func cancelled(_ id: Int) {
        if ignoredFingers.remove(id) != nil { return }
        guard fingers.removeValue(forKey: id) != nil else { return }
        if phase == .scrolling { perform(.scrollEnded(velocity: .zero)) }
        cancelTimer()
        releaseGestureButton()
        owedClick = false
        phase = fingers.isEmpty ? .idle : .ignored
        if fingers.isEmpty { ignoredFingers.removeAll() }
    }

    /// Ends everything: pending clicks are dropped, held buttons (the drag
    /// lock too) released. Mode switch, menu open, focus loss, teardown.
    func cancel() {
        cancelTimer()
        pendingClick?()
        pendingClick = nil
        pendingRightClick?()
        pendingRightClick = nil
        owedClick = false
        if phase == .scrolling { perform(.scrollEnded(velocity: .zero)) }
        releaseGestureButton()
        if dragLocked {
            dragLocked = false
            perform(.button(InputController.Button.left, down: false))
        }
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
        phase = .pending
        if effectiveMode == .trackpad {
            if let cancelClick = pendingClick {
                // A second touch inside the tap's window: a double tap or a tap-drag.
                cancelClick()
                pendingClick = nil
                owedClick = true
                timer = schedule(Tuning.tapMaxDuration) { [weak self] in self?.holdBecameDrag() }
            }
        } else {
            flushPendingClicks()
            timer = schedule(Tuning.longPress) { [weak self] in self?.longPressFired() }
        }
    }

    private func trackpadTap(quick: Bool) {
        if dragLocked {
            dragLocked = false
            perform(.button(InputController.Button.left, down: false))
            perform(.haptic(.light))
            return
        }
        guard quick else { return }
        if owedClick {
            owedClick = false
            perform(.haptic(.light))
            perform(.button(InputController.Button.left, down: true))
            perform(.button(InputController.Button.left, down: false))
            perform(.button(InputController.Button.left, down: true))
            perform(.button(InputController.Button.left, down: false))
            return
        }
        pendingClick = schedule(Tuning.tapDragWindow) { [weak self] in
            guard let self else { return }
            self.pendingClick = nil
            self.click(InputController.Button.left, haptic: .light)
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
            pendingRightClick = schedule(Tuning.tapDragWindow) { [weak self] in
                guard let self else { return }
                self.pendingRightClick = nil
                self.rightClick(at: self.pendingRightClickAt ?? at)
                self.pendingRightClickAt = nil
            }
        } else {
            rightClick(at: at)
        }
    }

    private func rightClick(at p: CGPoint) {
        if effectiveMode == .direct { perform(.moveTo(p)) }
        click(InputController.Button.right, haptic: .medium)
    }

    /// Trackpad: double-tap-and-hold without moving.
    private func holdBecameDrag() {
        timer = nil
        guard phase == .pending, owedClick else { return }
        owedClick = false
        flushPendingRightClick()
        startDrag()
    }

    private func longPressFired() {
        timer = nil
        guard phase == .pending, let f = fingers.values.first else { return }
        flushPendingRightClick()
        phase = .longPressed
        perform(.moveTo(f.start))
        perform(.haptic(.medium))
    }

    private func startDrag() {
        phase = .dragging
        perform(.haptic(.medium))
        if dragLocked { return }                     // already held by the lock
        buttonDown = true
        perform(.button(InputController.Button.left, down: true))
    }

    private func releaseGestureButton() {
        guard buttonDown else { return }
        buttonDown = false
        perform(.button(InputController.Button.left, down: false))
    }

    private func click(_ button: Int, haptic: TouchHaptic?) {
        if let haptic { perform(.haptic(haptic)) }
        perform(.button(button, down: true))
        perform(.button(button, down: false))
    }

    /// A gesture that is not a click came in while one was waiting: send it now.
    private func flushOwedClick() {
        guard owedClick else { return }
        owedClick = false
        click(InputController.Button.left, haptic: .light)
    }

    /// A one-finger gesture committed while a zoomed two-finger tap waited
    /// for its double tap: right click now, before the cursor moves.
    private func flushPendingRightClick() {
        guard let cancelRight = pendingRightClick else { return }
        cancelRight()
        pendingRightClick = nil
        rightClick(at: pendingRightClickAt ?? startCentroid)
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
