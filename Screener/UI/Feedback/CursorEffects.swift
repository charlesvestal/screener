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
// Locate (shake to locate / the menu's Find Cursor): the sprite grows to
// `locatePeak` (3.5×) over `locateRise` with a small overshoot (ease-out-back;
// Reduce Motion: a plain ease, no bounce), stays up while pings keep coming
// (each holds it `hold` more seconds), then eases back over `locateSettle`. A
// ping while settling rises again from the current size. Locate is
// functional, not decoration: it is kept when visual feedback is off
// (`removeDecorations`). The drawn scale is the larger of halo and locate.
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
    static let locatePeak: CGFloat = 3.5
    static let locateRise = 0.28
    static let locateSettle = 0.5
    /// A shake ping holds the cursor up this long (shake reversals come
    /// every ~0.1–0.2 s, so it stays up while the shake goes on).
    static let locateHold = 0.3
    /// The menu's Find Cursor holds it up this long.
    static let findHold = 0.9

    struct Ghost: Equatable, Sendable {
        var point: CGPoint
        var time: Double
    }

    private(set) var haloStart: Double?
    private(set) var haloReduced = false
    private(set) var ghosts: [Ghost] = []
    private var last: Ghost?
    private(set) var locateStart: Double?
    private var locateFrom: CGFloat = 0
    private var locateHoldUntil: Double = 0
    private var locateReduced = false

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

    /// Enlarges the cursor (or keeps it enlarged) for at least `hold` more seconds.
    mutating func locate(now: Double, hold: Double, reduceMotion: Bool) {
        if let s = locateStart, now >= s, now < locateHoldEnd(s) {
            locateHoldUntil = max(locateHoldUntil, now + hold)      // rising / up: just extend
            return
        }
        locateFrom = min(1, max(0, locateEnvelope(at: now)))         // idle / settling: rise from here
        locateStart = now
        locateHoldUntil = now + hold
        locateReduced = reduceMotion
    }

    private func locateHoldEnd(_ start: Double) -> Double { max(locateHoldUntil, start + Self.locateRise) }

    /// 0 at rest, 1 fully enlarged (briefly above 1 in the overshoot).
    func locateEnvelope(at now: Double) -> CGFloat {
        guard let s = locateStart, now >= s else { return 0 }
        let t = now - s
        if t < Self.locateRise {
            let p = CGFloat(t / Self.locateRise)
            let e = locateReduced ? p * p * (3 - 2 * p) : Self.easeOutBack(p)
            return locateFrom + (1 - locateFrom) * e
        }
        let end = locateHoldEnd(s)
        if now < end { return 1 }
        let p = CGFloat((now - end) / Self.locateSettle)
        guard p < 1 else { return 0 }
        return 1 - p * p * (3 - 2 * p)
    }

    /// Overshoots ~10% near the end, then lands on 1.
    static func easeOutBack(_ p: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        let q = p - 1
        return 1 + c3 * q * q * q + c1 * q * q
    }

    func locateScale(at now: Double) -> CGFloat {
        1 + (Self.locatePeak - 1) * locateEnvelope(at: now)
    }

    /// The scale the cursor sprite is drawn at (halo or locate, the larger).
    func cursorScale(at now: Double) -> CGFloat {
        max(haloScale(at: now), locateScale(at: now))
    }

    private func locateAnimating(at now: Double) -> Bool {
        guard let s = locateStart else { return false }
        return now < locateHoldEnd(s) + Self.locateSettle
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
        if locateStart != nil, !locateAnimating(at: now) { clearLocate() }
    }

    func isAnimating(at now: Double) -> Bool {
        (haloStart.map { now - $0 < Self.haloDuration } ?? false)
            || ghosts.contains { now - $0.time < Self.trailLifetime }
            || locateAnimating(at: now)
    }

    /// Halo or trail state is held (what visual feedback off clears).
    var hasDecorations: Bool { haloStart != nil || !ghosts.isEmpty || last != nil }

    /// Clears the halo and trail, keeping a locate (functional).
    mutating func removeDecorations() {
        haloStart = nil
        ghosts.removeAll()
        last = nil
    }

    mutating func removeAll() {
        removeDecorations()
        clearLocate()
    }

    private mutating func clearLocate() {
        locateStart = nil
        locateFrom = 0
        locateHoldUntil = 0
        locateReduced = false
    }
}
