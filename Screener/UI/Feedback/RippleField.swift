// The GPU ripples' state machine (pure; MetalRenderer draws its samples
// through Shaders.metal `rippleFragment`).
//
// A ripple is a ring refracting the picture outward from a point: radius,
// displacement amplitude, ring width and crest highlight are functions of the
// ripple's age. Variants:
//   click        one ring — shown only when a touch/Pencil tap is actually
//                registered as a click (never for ordinary pointing/hover,
//                and never for hardware mouse/trackpad clicks)
//   doubleClick  two rings, the second `doubleGap` later
//   rightClick   a ring plus a fainter, tinted echo `echoDelay` later
//   pulse        a slow repeating ring following the cursor while a
//                tap-drag, a long-press drag, or the three-finger drag lock
//                is held (FeedbackCenter drives this directly, not through
//                `spawn` — see `setPulse`) — released the moment it lets go
// Plain pointing, hovering and an ordinary one-finger drag's cursor motion
// get nothing: see FeedbackEvent.swift for which gestures reach this at all.
// Ring timings and sizes are tuned slow and subtle on purpose (see the
// constants below): a quick, snappy ripple reads as a glitch, not a touch.
// Reduce Motion: every transient variant is one in-place highlight fade (no
// refraction, no growth); the pulse is a static faint ring (not animated, so
// it costs no frames).
//
// Visibility on any background: refraction and a white crest vanish over
// white windows, so every ring also carries a thin tinted rim (`rimTint`,
// the app's indigo→teal accent; the right click's echo keeps its own
// `echoRimTint`). The shader makes the rim luminance-adaptive: over light
// pixels it darkens toward a deeper tint (multiply-like), over dark ones it
// glows lighter (screen-like) — see Shaders.metal `rippleFragment`. Clicks get
// a faint rim; the drag pulse, a state indicator, a solid-ish breathing ring
// with a soft outer glow. All the rim strengths are the constants below.
//
// At most `maxCount` ripples exist (the shader's uniform array): a new one
// beyond that replaces the oldest transient one. Times are seconds on one
// monotonic clock (FeedbackCenter.now); points are BASE view points.
import CoreGraphics
import simd

enum RippleVariant: Equatable, Sendable {
    case click, doubleClick, rightClick
}

struct Ripple: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ring, fade, pulse
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
    /// Tinted rim: peak opacity (0 = none), drawn at `rimRadius`.
    var rim: CGFloat = 0
    /// Tinted rim radius (points); usually `radius`.
    var rimRadius: CGFloat = 0
    /// Tinted rim half-width (points) of its solid core (edges are soft).
    var rimWidth: CGFloat = 1
    /// Soft outer glow around the rim: opacity (0 = none); spreads 5 × `rimWidth`.
    var rimGlow: CGFloat = 0
    /// Rim colour.
    var rimTint = RippleField.rimTint
}

struct RippleField: Equatable, Sendable {
    static let maxCount = 8

    // MARK: tuning (seconds / points — tweak freely)

    /// A ring's full life, start to finish.
    static let ringDuration = 0.65
    /// A ring's radius at the end of its life.
    static let ringMaxRadius: CGFloat = 150
    /// A ring's peak displacement (points) at birth.
    static let ringAmplitude: CGFloat = 9
    /// Double-click: delay before the second ring starts.
    static let doubleGap = 0.13
    /// Right-click: delay before the fainter, tinted echo ring starts.
    static let echoDelay = 0.24
    /// Right-click echo: fraction of a plain ring's amplitude/highlight.
    static let echoStrength: CGFloat = 0.6
    /// Reduce Motion: the in-place highlight fade's life.
    static let fadeDuration = 0.3
    /// Drag pulse (tap-drag / long-press-drag / three-finger lock): repeat period.
    static let pulsePeriod = 1.5

    static let white = SIMD3<Float>(1, 1, 1)
    static let echoTint = SIMD3<Float>(0.55, 0.78, 1)

    // MARK: tinted rim (visible on white as well as dark — see the header)

    /// The rim's accent: a soft blue-teal between the icon's indigo and teal.
    static let rimTint = SIMD3<Float>(0.16, 0.60, 0.92)
    /// The right click's echo rim: indigo, distinct from the plain rim.
    static let echoRimTint = SIMD3<Float>(0.45, 0.38, 1.0)
    /// Click rings: rim peak opacity at birth (fades linearly over the ring's life,
    /// a little slower than the crest, so it still reads on white mid-ring).
    static let clickRimAlpha: CGFloat = 0.34
    /// Click rings: rim half-width (points).
    static let clickRimWidth: CGFloat = 0.9
    /// Drag pulse: the breathing rim's opacity range (min…max).
    static let pulseRimAlpha: ClosedRange<CGFloat> = 0.5...0.68
    /// Drag pulse: the rim's radius (points), ± `pulseRimBreath` with the breath.
    static let pulseRimRadius: CGFloat = 22
    static let pulseRimBreath: CGFloat = 1.5
    /// Drag pulse: rim half-width (points): a ~2.5 pt ring.
    static let pulseRimWidth: CGFloat = 1.25
    /// Drag pulse: soft outer glow opacity.
    static let pulseGlowAlpha: CGFloat = 0.22
    /// Reduce Motion: the static/fading rim's opacity.
    static let reducedRimAlpha: CGFloat = 0.45

    /// Transient ripples, oldest first.
    private(set) var ripples: [Ripple] = []
    /// The drag pulse (tap-drag / long-press-drag / three-finger lock).
    private(set) var pulse: Ripple?

    var isEmpty: Bool { ripples.isEmpty && pulse == nil }

    static func duration(_ r: Ripple) -> Double {
        switch r.kind {
        case .ring: ringDuration
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
        }
    }

    /// Starts (a point) or stops (nil) the drag pulse.
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
        let rimTint = r.echo ? echoRimTint : rimTint
        switch r.kind {
        case .ring:
            let p = CGFloat(age / ringDuration)
            let e = 1 - pow(1 - p, 3)                               // easeOutCubic
            let k = r.echo ? echoStrength : 1
            let radius = 4 + (ringMaxRadius - 4) * e
            // Gentler decay than the radius ease: stays visible longer.
            let decay = pow(1 - p, 1.5)
            return RippleSample(center: r.center, radius: radius, amplitude: ringAmplitude * decay * k,
                                width: 14 + 10 * p, highlight: 0.32 * decay * k, tint: tint,
                                rim: clickRimAlpha * (1 - p) * k, rimRadius: radius, rimWidth: clickRimWidth,
                                rimTint: rimTint)
        case .fade:
            let p = CGFloat(age / fadeDuration)
            return RippleSample(center: r.center, radius: 24, amplitude: 0, width: 6,
                                highlight: 0.45 * (1 - p), tint: tint,
                                rim: reducedRimAlpha * (1 - p), rimRadius: 24, rimWidth: clickRimWidth,
                                rimTint: rimTint)
        case .pulse:
            if r.reduced {
                return RippleSample(center: r.center, radius: 26, amplitude: 0, width: 5, highlight: 0.2, tint: tint,
                                    rim: reducedRimAlpha, rimRadius: pulseRimRadius, rimWidth: pulseRimWidth,
                                    rimGlow: pulseGlowAlpha * 0.7, rimTint: rimTint)
            }
            let phase = CGFloat((age / pulsePeriod).truncatingRemainder(dividingBy: 1))
            // The breath: 0 → 1 → 0 over a period, smooth at the wrap.
            let breath = 0.5 - 0.5 * cos(2 * .pi * phase)
            return RippleSample(center: r.center, radius: 18 + 30 * phase,
                                amplitude: 3.5 * 4 * phase * (1 - phase), width: 10,
                                highlight: 0.22 * (1 - phase), tint: tint,
                                rim: pulseRimAlpha.lowerBound
                                    + (pulseRimAlpha.upperBound - pulseRimAlpha.lowerBound) * breath,
                                rimRadius: pulseRimRadius + pulseRimBreath * (2 * breath - 1),
                                rimWidth: pulseRimWidth, rimGlow: pulseGlowAlpha * (0.7 + 0.3 * breath),
                                rimTint: rimTint)
        }
    }
}
