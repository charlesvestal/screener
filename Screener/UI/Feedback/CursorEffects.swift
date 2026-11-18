// Trackpad-mode cursor halo and motion trail (pure; MetalRenderer draws them
// with the host cursor sprite).
//
// Halo: when a finger lands in trackpad mode the drawn cursor scales up to
// `haloPeak` (1.6×) over `haloRise` with a soft glow under it, then settles
// back by `haloDuration` (250 ms). Reduce Motion: no scale, the glow only.
// Trail: while a touch moves the cursor faster than `trailMinSpeed`, its
// previous positions are kept for `trailLifetime` as fading ghost sprites
// (at most `maxGhosts`, at least `ghostSpacing` apart). Off under Reduce
// Motion. A hardware pointer never reports here (no halo, no trail).
// Times are seconds (FeedbackCenter.now); points are BASE view points.
import CoreGraphics

struct CursorEffects: Equatable, Sendable {
    static let haloDuration = 0.25
    static let haloRise = 0.06
    static let haloPeak: CGFloat = 1.6
    static let trailLifetime = 0.14
    static let trailMinSpeed: CGFloat = 900       // points/s
    static let maxGhosts = 4
    static let ghostSpacing: CGFloat = 10
    static let ghostAlpha: Float = 0.3

    struct Ghost: Equatable, Sendable {
        var point: CGPoint
        var time: Double
    }

    private(set) var haloStart: Double?
    private(set) var haloReduced = false
    private(set) var ghosts: [Ghost] = []
    private var last: Ghost?

    mutating func halo(now: Double, reduceMotion: Bool) {
        haloStart = now
        haloReduced = reduceMotion
    }

    /// 0…1: rises over haloRise, settles (ease-out) by haloDuration.
    func haloEnvelope(at now: Double) -> CGFloat {
        guard let s = haloStart else { return 0 }
        let t = now - s
        guard t >= 0, t < Self.haloDuration else { return 0 }
        if t < Self.haloRise {
            let p = CGFloat(t / Self.haloRise)
            return 1 - (1 - p) * (1 - p)
        }
        let p = CGFloat((t - Self.haloRise) / (Self.haloDuration - Self.haloRise))
        return 1 - p * p * (3 - 2 * p)
    }

    /// The cursor sprite's scale at `now` (1 at rest).
    func haloScale(at now: Double) -> CGFloat {
        haloReduced ? 1 : 1 + (Self.haloPeak - 1) * haloEnvelope(at: now)
    }

    /// A touch moved the cursor to `p`.
    mutating func moved(to p: CGPoint, now: Double, reduceMotion: Bool) {
        defer { last = Ghost(point: p, time: now) }
        guard !reduceMotion, let prev = last else { return }
        let dt = now - prev.time
        let d = hypot(p.x - prev.point.x, p.y - prev.point.y)
        guard dt > 0, dt < 0.1, d / CGFloat(dt) >= Self.trailMinSpeed else { return }
        if let g = ghosts.last, hypot(g.point.x - prev.point.x, g.point.y - prev.point.y) < Self.ghostSpacing {
            return
        }
        ghosts.append(prev)
        if ghosts.count > Self.maxGhosts { ghosts.removeFirst(ghosts.count - Self.maxGhosts) }
    }

    /// The ghosts still visible at `now`, with their alpha (oldest first).
    func visibleGhosts(at now: Double) -> [(point: CGPoint, alpha: Float)] {
        ghosts.compactMap { g in
            let age = now - g.time
            guard age >= 0, age < Self.trailLifetime else { return nil }
            return (g.point, Self.ghostAlpha * Float(1 - age / Self.trailLifetime))
        }
    }

    mutating func prune(at now: Double) {
        ghosts.removeAll { now - $0.time >= Self.trailLifetime }
        if let s = haloStart, now - s >= Self.haloDuration { haloStart = nil }
    }

    func isAnimating(at now: Double) -> Bool {
        (haloStart.map { now - $0 < Self.haloDuration } ?? false)
            || ghosts.contains { now - $0.time < Self.trailLifetime }
    }

    mutating func removeAll() {
        haloStart = nil
        ghosts.removeAll()
        last = nil
    }
}
