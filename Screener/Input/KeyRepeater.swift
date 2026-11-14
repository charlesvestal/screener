// Ported in part from iShareScreen src/isharescreen/frontend/desktop/app.py
// (on_key: `glfw.REPEAT` is forwarded as another key-down) (AGPL-3.0)
//
// Hardware key auto-repeat. iPadOS reports one pressesBegan per physical
// press (no repeats), so a held Backspace/arrow would act once. The
// reference forwards every GLFW REPEAT as `key_event(True, keysym)` — a
// key-down with no key-up in between (X11 autorepeat as seen by the host) —
// so here the most recently pressed non-modifier key re-sends its stored
// key-down after `initialDelay`, then every `interval`, until its key-up or
// a cancel (focus loss, deactivation, controller switch).
//
// The timer is injected (`Schedule`) so tests drive it with a manual clock.
import Foundation

@MainActor
final class KeyRepeater {
    /// Schedules `fire` after `delay` seconds; returns a cancel function.
    typealias Schedule = @MainActor (_ delay: TimeInterval,
                                     _ fire: @escaping @MainActor @Sendable () -> Void) -> () -> Void

    static var initialDelay: TimeInterval { RemoteInputView.Tuning.keyRepeatDelay }
    static var interval: TimeInterval { RemoteInputView.Tuning.keyRepeatInterval }

    /// Called with the stored keysym on every repeat.
    var onRepeat: ((UInt32) -> Void)?
    /// The key (HID usage) currently repeating.
    private(set) var usage: Int?

    private let schedule: Schedule
    private var keysym: UInt32 = 0
    private var cancelTimer: (() -> Void)?
    private var generation = 0

    init(schedule: @escaping Schedule = KeyRepeater.runLoopTimer) {
        self.schedule = schedule
    }

    /// A non-modifier key went down: it becomes the repeating key.
    func keyDown(usage: Int, keysym: UInt32) {
        cancel()
        self.usage = usage
        self.keysym = keysym
        arm(Self.initialDelay)
    }

    /// A key went up: stops the repeat if it was the repeating key.
    func keyUp(usage: Int) {
        if usage == self.usage { cancel() }
    }

    func cancel() {
        generation += 1
        cancelTimer?()
        cancelTimer = nil
        usage = nil
    }

    private func arm(_ delay: TimeInterval) {
        let gen = generation
        cancelTimer = schedule(delay) { [weak self] in
            guard let self, self.generation == gen, self.usage != nil else { return }
            self.cancelTimer = nil
            self.onRepeat?(self.keysym)
            if self.generation == gen, self.usage != nil { self.arm(Self.interval) }
        }
    }

    /// One-shot main-run-loop timer in `.common` modes (keeps firing while a
    /// scroll or gesture is tracking).
    static func runLoopTimer(_ delay: TimeInterval,
                             _ fire: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let t = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(t, forMode: .common)
        return { t.invalidate() }
    }
}
