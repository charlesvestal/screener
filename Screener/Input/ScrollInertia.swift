// Momentum after a two-finger touch scroll (Task 22).
//
// A finger scroll ends with the fingers' velocity (view points per second).
// ScrollInertia turns it into a decaying run of scroll deltas: every 1/60 s
// the velocity is multiplied by `friction` (0.95) and the distance covered in
// that time is emitted, until the speed falls below `stopSpeed`. Time steps of
// any length (a 120 Hz display link) decay by friction^(dt·60), so the run
// covers the same distance at any frame rate.
//
// Only touch scrolls get this: a Magic Keyboard / trackpad `.continuous`
// scroll already carries the system's own momentum events, and a wheel has
// none. Any new touch stops it (RemoteInputView).
import CoreGraphics

struct ScrollInertia: Equatable, Sendable {
    /// Velocity kept per 1/60 s.
    static let friction: Double = 0.95
    /// Below this speed (points/s) the run stops.
    static let stopSpeed: Double = 20
    /// Release speeds below this start no run at all (a deliberate stop).
    static let minimumStartSpeed: Double = 60
    /// Release speeds are capped here (one wild flick doesn't scroll forever).
    static let maximumStartSpeed: Double = 6000
    static let frame: Double = 1.0 / 60

    private(set) var velocity: CGPoint

    /// nil when `velocity` is too slow to start a run.
    init?(velocity v: CGPoint) {
        let speed = hypot(v.x, v.y)
        guard speed.isFinite, speed >= Self.minimumStartSpeed else { return nil }
        let k = min(1, Self.maximumStartSpeed / speed)
        velocity = CGPoint(x: v.x * k, y: v.y * k)
    }

    var isFinished: Bool { hypot(velocity.x, velocity.y) < Self.stopSpeed }

    /// Advances by `dt` seconds: the distance to scroll now, or nil once the
    /// run is over.
    mutating func step(_ dt: Double = ScrollInertia.frame) -> CGPoint? {
        guard !isFinished, dt > 0 else { return nil }
        let d = CGPoint(x: velocity.x * dt, y: velocity.y * dt)
        let decay = pow(Self.friction, dt / Self.frame)
        velocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        return d
    }

    /// The whole run at 60 Hz (tests, tuning).
    static func deltas(velocity: CGPoint) -> [CGPoint] {
        guard var run = ScrollInertia(velocity: velocity) else { return [] }
        var out: [CGPoint] = []
        while let d = run.step() { out.append(d) }
        return out
    }
}
