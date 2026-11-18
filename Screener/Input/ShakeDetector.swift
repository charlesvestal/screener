// Shake to locate the cursor (pure; RemoteInputView feeds it, CursorEffects
// draws the result), like macOS's "shake mouse pointer to locate".
//
// Fed every relative pointer motion in view points (trackpad-mode finger
// moves, pointer-lock mouse moves, hardware pointer hover/drag deltas) with
// its time. Each axis is tracked on its own: its position integrates the
// deltas, and a direction reversal is registered once the motion has come
// back `hysteresis` points from the stroke's extreme (so jitter at a turn is
// not a reversal). A finished stroke counts if it was at least `minStroke`
// long and faster than `minSpeed` (length / duration); a stroke that does
// not count breaks the chain. `reversalsNeeded` counting reversals within
// `window` seconds on one axis is a shake: `add` returns true on that
// reversal and on every further counting one while the shake goes on (each
// is a "ping" that keeps the enlarged cursor up). A pause longer than
// `maxPause` between samples starts over.
import CoreGraphics
import Foundation

struct ShakeDetector: Equatable, Sendable {
    static let window: TimeInterval = 0.6
    static let reversalsNeeded = 3
    /// Points/s a stroke must average.
    static let minSpeed: CGFloat = 700
    /// Points a stroke must cover.
    static let minStroke: CGFloat = 30
    /// Points of counter-motion that make a reversal.
    static let hysteresis: CGFloat = 6
    static let maxPause: TimeInterval = 0.25

    struct Axis: Equatable, Sendable {
        var pos: CGFloat = 0
        /// +1 / −1, 0 before the first stroke has a direction.
        var dir: CGFloat = 0
        var extreme: CGFloat = 0
        var extremeTime: TimeInterval = 0
        var strokeStart: CGFloat = 0
        var strokeStartTime: TimeInterval = 0
        /// Times of the counting reversals still inside the window.
        var reversals: [TimeInterval] = []

        /// Adds `d`; true if this completed a counting stroke (a reversal).
        mutating func add(_ d: CGFloat, at t: TimeInterval) -> Bool {
            pos += d
            if dir == 0 {
                guard abs(pos - strokeStart) > ShakeDetector.hysteresis else { return false }
                dir = pos > strokeStart ? 1 : -1
                extreme = pos
                extremeTime = t
                return false
            }
            if (pos - extreme) * dir >= 0 {
                extreme = pos
                extremeTime = t
                return false
            }
            guard abs(pos - extreme) > ShakeDetector.hysteresis else { return false }
            let length = abs(extreme - strokeStart)
            let duration = max(extremeTime - strokeStartTime, 1.0 / 240)
            let counts = length >= ShakeDetector.minStroke && length / CGFloat(duration) >= ShakeDetector.minSpeed
            if counts { reversals.append(extremeTime) } else { reversals.removeAll() }
            strokeStart = extreme
            strokeStartTime = extremeTime
            dir = -dir
            extreme = pos
            extremeTime = t
            return counts
        }

        mutating func prune(at t: TimeInterval) {
            reversals.removeAll { t - $0 > ShakeDetector.window }
        }

        mutating func reset(at t: TimeInterval) {
            self = Axis(strokeStartTime: t)
        }
    }

    private(set) var x = Axis()
    private(set) var y = Axis()
    private var lastTime: TimeInterval?

    /// Adds a motion of `d` view points at `t`; true while a shake goes on
    /// (on each reversal that counts once there are enough of them).
    mutating func add(_ d: CGPoint, at t: TimeInterval) -> Bool {
        if lastTime.map({ t - $0 > Self.maxPause || t < $0 }) ?? true {
            x.reset(at: t)
            y.reset(at: t)
        }
        lastTime = t
        let rx = x.add(d.x, at: t), ry = y.add(d.y, at: t)
        x.prune(at: t)
        y.prune(at: t)
        return (rx && x.reversals.count >= Self.reversalsNeeded)
            || (ry && y.reversals.count >= Self.reversalsNeeded)
    }

    mutating func reset() {
        self = ShakeDetector()
    }
}
