// The GPU ripples' state machine (pure; MetalRenderer draws its samples
// through Shaders.metal `rippleFragment`).
//
// A ripple is a ring refracting the picture outward from a point: radius,
// displacement amplitude, ring width and crest highlight are functions of the
// ripple's age. Variants:
//   click        one ring, 0 → 120 pt over 350 ms, amplitude decaying
//   doubleClick  two rings, the second `doubleGap` later
//   rightClick   a ring plus a fainter, tinted echo `echoDelay` later
//   grab         (drag start) a ring contracting 72 → 8 pt over 300 ms
//   pulse        (drag lock) a slow repeating ring following the cursor
//                until released — the only persistent one
// Reduce Motion: every transient variant is one in-place highlight fade (no
// refraction, no growth); the pulse is a static faint ring (not animated, so
// it costs no frames).
//
// At most `maxCount` ripples exist (the shader's uniform array): a new one
// beyond that replaces the oldest transient one. Times are seconds on one
// monotonic clock (FeedbackCenter.now); points are BASE view points.
import CoreGraphics
import simd

enum RippleVariant: Equatable, Sendable {
    case click, doubleClick, rightClick, grab
}

struct Ripple: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ring, grab, fade, pulse
    }
    var kind: Kind
    var center: CGPoint
    /// When it starts (may be in the future: a delayed ring).
    var start: Double
    /// The right click's echo: tinted, fainter.
    var echo = false
    /// Reduce Motion pulse: drawn static.
    var reduced = false
}

/// One ripple's shape at an instant (BASE point, sizes in view points).
struct RippleSample: Equatable, Sendable {
    var center: CGPoint
    var radius: CGFloat
    /// Peak displacement (points) of the picture at the ring.
    var amplitude: CGFloat
    /// Ring half-width (points).
    var width: CGFloat
    /// Crest highlight strength (0…1).
    var highlight: CGFloat
    /// Highlight colour (linear-ish RGB).
    var tint: SIMD3<Float>
}

struct RippleField: Equatable, Sendable {
    static let maxCount = 8

    static let ringDuration = 0.35
    static let ringMaxRadius: CGFloat = 120
    static let ringAmplitude: CGFloat = 9
    static let doubleGap = 0.09
    static let echoDelay = 0.15
    static let echoStrength: CGFloat = 0.6
    static let grabDuration = 0.3
    static let grabStartRadius: CGFloat = 72
    static let fadeDuration = 0.3
    static let pulsePeriod = 1.2

    static let white = SIMD3<Float>(1, 1, 1)
    static let echoTint = SIMD3<Float>(0.55, 0.78, 1)

    /// Transient ripples, oldest first.
    private(set) var ripples: [Ripple] = []
    /// The drag-lock pulse.
    private(set) var pulse: Ripple?

    var isEmpty: Bool { ripples.isEmpty && pulse == nil }

    static func duration(_ r: Ripple) -> Double {
        switch r.kind {
        case .ring: ringDuration
        case .grab: grabDuration
        case .fade: fadeDuration
        case .pulse: .infinity
        }
    }

    // MARK: changes

    mutating func spawn(_ variant: RippleVariant, at p: CGPoint, now: Double, reduceMotion: Bool) {
        if reduceMotion {
            add(Ripple(kind: .fade, center: p, start: now, echo: variant == .rightClick))
            return
        }
        switch variant {
        case .click:
            add(Ripple(kind: .ring, center: p, start: now))
        case .doubleClick:
            add(Ripple(kind: .ring, center: p, start: now))
            add(Ripple(kind: .ring, center: p, start: now + Self.doubleGap))
        case .rightClick:
            add(Ripple(kind: .ring, center: p, start: now))
            add(Ripple(kind: .ring, center: p, start: now + Self.echoDelay, echo: true))
        case .grab:
            add(Ripple(kind: .grab, center: p, start: now))
        }
    }

    /// Starts (a point) or stops (nil) the drag-lock pulse.
    mutating func setPulse(at p: CGPoint?, now: Double, reduceMotion: Bool) {
        guard let p else { pulse = nil; return }
        if pulse != nil { pulse?.center = p; return }
        pulse = Ripple(kind: .pulse, center: p, start: now, reduced: reduceMotion)
        trim()
    }

    /// The pulse follows the cursor.
    mutating func movePulse(to p: CGPoint) {
        pulse?.center = p
    }

    /// Drops finished ripples.
    mutating func prune(at now: Double) {
        ripples.removeAll { now >= $0.start + Self.duration($0) }
    }

    mutating func removeAll() {
        ripples.removeAll()
        pulse = nil
    }

    private mutating func add(_ r: Ripple) {
        ripples.append(r)
        trim()
    }

    private mutating func trim() {
        let room = Self.maxCount - (pulse == nil ? 0 : 1)
        if ripples.count > room { ripples.removeFirst(ripples.count - room) }
    }

    // MARK: reading

    /// Whether anything still moves at `now` (frames must keep coming).
    /// A ring that has not started yet counts.
    func isAnimating(at now: Double) -> Bool {
        if let pulse, !pulse.reduced { return true }
        return ripples.contains { now < $0.start + Self.duration($0) }
    }

    /// The visible ripples at `now` (pulse last), at most maxCount.
    func samples(at now: Double) -> [RippleSample] {
        var out = ripples.compactMap { Self.sample($0, at: now) }
        if let pulse, let s = Self.sample(pulse, at: now) { out.append(s) }
        return Array(out.suffix(Self.maxCount))
    }

    static func sample(_ r: Ripple, at now: Double) -> RippleSample? {
        let age = now - r.start
        guard age >= 0, age < duration(r) else { return nil }
        let tint = r.echo ? echoTint : white
        switch r.kind {
        case .ring:
            let p = CGFloat(age / ringDuration)
            let e = 1 - pow(1 - p, 3)                               // ease-out
            let k = r.echo ? echoStrength : 1
            return RippleSample(center: r.center, radius: 4 + (ringMaxRadius - 4) * e,
                                amplitude: ringAmplitude * (1 - p) * (1 - p) * k,
                                width: 14 + 10 * p, highlight: 0.32 * pow(1 - p, 1.5) * k, tint: tint)
        case .grab:
            let p = CGFloat(age / grabDuration)
            let e = 1 - pow(1 - p, 3)
            let s = sin(.pi * p)
            return RippleSample(center: r.center, radius: 8 + (grabStartRadius - 8) * (1 - e),
                                amplitude: 7 * s, width: 12, highlight: 0.3 * s, tint: tint)
        case .fade:
            let p = CGFloat(age / fadeDuration)
            return RippleSample(center: r.center, radius: 24, amplitude: 0, width: 6,
                                highlight: 0.45 * (1 - p), tint: tint)
        case .pulse:
            if r.reduced {
                return RippleSample(center: r.center, radius: 26, amplitude: 0, width: 5, highlight: 0.2, tint: tint)
            }
            let phase = CGFloat((age / pulsePeriod).truncatingRemainder(dividingBy: 1))
            return RippleSample(center: r.center, radius: 18 + 30 * phase,
                                amplitude: 3.5 * 4 * phase * (1 - phase), width: 10,
                                highlight: 0.22 * (1 - phase), tint: tint)
        }
    }
}
