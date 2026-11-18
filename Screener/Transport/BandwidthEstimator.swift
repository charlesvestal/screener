// Receiver-side bandwidth estimate for the RCTL feedback's BWE field (kbps),
// which the host uses as its video encoder target (live A/B 2026-11-18,
// docs/research/2026-11-18-native-feedback.md). A simple loss-based AIMD in
// the spirit of GCC's loss controller (draft-ietf-rmcat-gcc §6), plus
// app-limited detection:
//
//   * starts at `initialKbps` (50 Mbps: the native viewer gets ~50 Mbps
//     from the first seconds on the same Wi-Fi, and the first seconds are
//     what the user notices);
//   * multiplicative increase (`increasePerSecond`, 6 %/s) toward
//     `ceilingKbps` while the windowed loss is under 2 %, no recovery event
//     happened lately, and the host actually fills the estimate;
//   * loss-driven decrease (×0.9) only on SUSTAINED loss: the loss of
//     `sustainedLossWindows` (2) consecutive, non-overlapping 1 s buckets is
//     each over 10 %. Wi-Fi drops packets in bursts (power save, a neighbour,
//     a scan: 13 % in one second, then clean — iPad log 2026-11-18); a single
//     bad second never cuts. A loss-driven decrease also cuts toward
//     0.9 × the measured receive rate when that is lower (the link is
//     saturated), at most to `maxStepDown` (0.6) × the estimate — but only
//     once the episode has outlasted the burst guard;
//   * a recovery event (assembler keyframe request, decode backlog) cuts
//     ×0.9 at most every `recoveryHoldoff` (3 s);
//   * burst guard: within `burstGuard` (3 s) of the first bad sign of an
//     episode, no decrease goes under `burstGuardFraction` (0.6) × the
//     estimate the episode started at;
//   * fast recovery: an ISOLATED cut (no other cut in the previous
//     `fastRecoveryCooldown`, 20 s — longer than the
//     slow sawtooth near a fixed capacity, so that one stays plain AIMD; not a decode backlog) climbs back
//     +10 %/s to the pre-cut estimate for `fastRecoveryDuration` (3 s) once
//     the windowed loss clears — no increase hold-off, no app-limited check.
//     Repeated cuts fall back to plain AIMD;
//   * near the estimate at which the last decrease happened (within ±10 %),
//     the normal increase slows to 1 %/s, so a fixed-capacity link sees a slow
//     sawtooth rather than a cut every few seconds;
//   * 2–10 % loss: hold (the dead band that keeps it from oscillating);
//   * app-limited: when the receive rate is under `appLimitedRatio` × the
//     estimate (static screen: the encoder has nothing to send), HOLD — the
//     estimate never decays toward an idle receive rate;
//   * never below `floorKbps`, never above `ceilingKbps` (≤ 65535: BWE is a
//     u16 on the wire).
//
// Pure and deterministic: time is the `now` passed to `update` (seconds on
// any monotonic clock).
import Foundation

struct BandwidthEstimator: Sendable {
    struct Config: Sendable, Equatable {
        var initialKbps = 50_000.0
        var floorKbps = 4_000.0
        var ceilingKbps = 65_000.0
        var increasePerSecond = 0.06
        /// Increase rate within `nearCongestionBand` of the last decrease point.
        var nearCongestionIncreasePerSecond = 0.01
        var nearCongestionBand = 0.10
        var decreaseFactor = 0.9
        /// Increase only below this windowed loss fraction.
        var increaseBelowLoss = 0.02
        /// A 1 s bucket over this loss fraction is "lossy".
        var decreaseAboveLoss = 0.10
        /// Loss-driven decrease only after this many consecutive lossy buckets.
        var sustainedLossWindows = 2
        /// Loss and receive-rate window, seconds.
        var window = 1.0
        /// Fewer expected packets than this in the window: loss is unknown.
        var minPacketsForLoss = 20
        /// Minimum spacing of loss-driven decreases, seconds.
        var decreaseHoldoff = 1.0
        /// Minimum spacing of decreases caused only by recovery events (a
        /// keyframe the host is slow to send is re-requested; that must not
        /// walk the estimate down every second).
        var recoveryHoldoff = 3.0
        /// No increase for this long after a decrease or a recovery event.
        var increaseHoldoff = 2.0
        /// Receive rate below this fraction of the estimate: app-limited.
        var appLimitedRatio = 0.6
        /// Neither direction during the first seconds (session-start burst).
        var startupGrace = 1.0
        /// One decrease never cuts below this fraction of the estimate.
        var maxStepDown = 0.6
        /// Within `burstGuard` seconds of an episode's first bad sign (lossy
        /// bucket or recovery event), never below this fraction of the
        /// estimate at its start.
        var burstGuardFraction = 0.6
        var burstGuard = 3.0
        /// After an isolated cut: climb at this rate back to the pre-cut
        /// estimate, for this long after the loss clears.
        var fastRecoveryPerSecond = 0.10
        var fastRecoveryDuration = 3.0
        /// A cut is isolated when no other cut happened within this long before it.
        var fastRecoveryCooldown = 20.0
        /// An episode ends after this long without a lossy bucket or recovery event.
        var episodeClear = 3.0
        /// Nominal tick, used for the first sample's duration.
        var nominalTick = 0.05
    }

    /// One tick's inputs.
    struct Sample: Sendable, Equatable {
        /// Video bytes received this tick.
        var rxBytes = 0
        /// Packets expected / received this tick over the active video
        /// sources (RTPReceptionStats.takeCounts; late packets arrive as
        /// received > expected in a later tick).
        var expected = 0
        var received = 0
        /// Assembler keyframe requests (loss events, decode errors) this tick.
        var recoveryEvents = 0
        /// The decode path is falling behind (packets dropped for a lagging consumer).
        var decodeBacklog = false
    }

    enum State: String, Sendable {
        case startup, increase, decrease
        /// Fast climb back to the pre-cut estimate after an isolated cut.
        case recover
        /// Loss between the thresholds.
        case hold
        /// Receive rate far below the estimate (idle screen): hold.
        case appLimited = "hold-app"
        /// Increase blocked by a recent decrease / recovery event.
        case holdoff = "hold-off"
        /// Too few packets to judge loss (and so app-limited too).
        case noData = "hold-idle"
    }

    let config: Config
    private(set) var estimateKbps: Double
    private(set) var state: State = .startup
    private(set) var decreases = 0
    private var start: Double?
    private var lastNow: Double?
    private var lastDecrease: Double?
    private var lastRecovery: Double?
    /// The estimate just before the last decrease (where congestion showed).
    private(set) var congestionKbps: Double?
    /// Float slack for the time comparisons.
    private let eps = 1e-6
    private var window: [(t: Double, dt: Double, bytes: Int, expected: Int, received: Int)] = []
    /// The current non-overlapping loss bucket (start, expected, received).
    private var bucket: (start: Double, expected: Int, received: Int)?
    /// Consecutive closed buckets over `decreaseAboveLoss`.
    private(set) var lossyBuckets = 0
    /// The current congestion episode: when it started / last showed, and the estimate before it.
    private var episode: (start: Double, last: Double, anchorKbps: Double)?
    /// Fast recovery armed by the last cut: the loss-clear time once seen.
    private var fastRecovery: (armed: Bool, clearedAt: Double?) = (false, nil)

    init(config: Config = Config()) {
        self.config = config
        estimateKbps = min(max(config.initialKbps, config.floorKbps), config.ceilingKbps)
    }

    /// The estimate as it goes on the wire.
    var bweKbps: UInt16 { UInt16(clamping: Int(estimateKbps.rounded())) }

    /// Windowed loss fraction (0…1), nil when too few packets were expected.
    var lossFraction: Double? {
        let exp = window.reduce(0) { $0 + $1.expected }
        let rec = window.reduce(0) { $0 + $1.received }
        guard exp >= config.minPacketsForLoss else { return nil }
        return max(0, Double(exp - rec) / Double(exp))
    }

    /// Windowed receive rate, kbps; nil until half a window was observed.
    var receiveKbps: Double? {
        let span = window.reduce(0) { $0 + $1.dt }
        guard span >= config.window / 2 else { return nil }
        return Double(window.reduce(0) { $0 + $1.bytes }) * 8 / 1000 / span
    }

    @discardableResult
    mutating func update(_ s: Sample, now: Double) -> UInt16 {
        let dt = lastNow.map { max(0, now - $0) } ?? config.nominalTick
        lastNow = now
        if start == nil { start = now }
        window.append((now, dt, s.rxBytes, s.expected, s.received))
        window.removeAll { $0.t <= now - config.window }
        let bucketClosed = advanceBucket(s, now: now, dt: dt)

        let recovery = s.recoveryEvents > 0 || s.decodeBacklog
        if let e = episode, now - e.last > config.episodeClear + eps, lossyBuckets == 0 { episode = nil }
        if recovery || (bucketClosed && lossyBuckets > 0) {
            if episode == nil { episode = (now, now, estimateKbps) } else { episode!.last = now }
        }
        guard now - start! >= config.startupGrace - eps else {
            state = .startup
            return bweKbps
        }
        let loss = lossFraction
        let rx = receiveKbps
        let lossCongested = lossyBuckets >= config.sustainedLossWindows

        if (lossCongested && bucketClosed) || recovery {
            let holdoff = lossCongested && bucketClosed ? config.decreaseHoldoff : config.recoveryHoldoff
            if let last = lastDecrease, now - last < holdoff - eps {
                state = .holdoff
            } else {
                decrease(lossDriven: lossCongested && bucketClosed, rx: rx, backlog: s.decodeBacklog, now: now)
            }
            if recovery { lastRecovery = now }
            return bweKbps
        }
        if lossCongested { state = .holdoff; return bweKbps }

        guard let loss else { state = .noData; return bweKbps }
        if loss >= config.increaseBelowLoss { state = .hold; return bweKbps }

        if fastRecovery.armed, let target = congestionKbps, estimateKbps < target {
            let cleared = fastRecovery.clearedAt ?? now
            fastRecovery.clearedAt = cleared
            if now - cleared <= config.fastRecoveryDuration + eps {
                estimateKbps = min(target, config.ceilingKbps,
                                   estimateKbps * pow(1 + config.fastRecoveryPerSecond, dt))
                state = .recover
                return bweKbps
            }
        }
        fastRecovery.armed = false

        let recent = [lastDecrease, lastRecovery].compactMap { $0 }.max()
        if let recent, now - recent < config.increaseHoldoff - eps { state = .holdoff; return bweKbps }
        guard let rx, rx >= config.appLimitedRatio * estimateKbps else { state = .appLimited; return bweKbps }
        var rate = config.increasePerSecond
        if let c = congestionKbps, abs(estimateKbps - c) <= c * config.nearCongestionBand {
            rate = config.nearCongestionIncreasePerSecond
        }
        estimateKbps = min(config.ceilingKbps, estimateKbps * pow(1 + rate, dt))
        state = .increase
        return bweKbps
    }

    /// Adds the tick to the current 1 s loss bucket; on closing it, updates
    /// `lossyBuckets`. Returns whether a bucket closed.
    private mutating func advanceBucket(_ s: Sample, now: Double, dt: Double) -> Bool {
        var b = bucket ?? (now - dt, 0, 0)
        b.expected += s.expected
        b.received += s.received
        guard now - b.start >= config.window - eps else { bucket = b; return false }
        bucket = (now, 0, 0)
        if b.expected >= config.minPacketsForLoss {
            let loss = max(0, Double(b.expected - b.received) / Double(b.expected))
            lossyBuckets = loss > config.decreaseAboveLoss ? lossyBuckets + 1 : 0
        } else {
            lossyBuckets = 0
        }
        return true
    }

    private mutating func decrease(lossDriven: Bool, rx: Double?, backlog: Bool, now: Double) {
        var target = estimateKbps * config.decreaseFactor
        if let e = episode, now - e.start < config.burstGuard - eps {
            // Early in an episode (a burst, as far as we know): only the plain
            // ×0.9 step, and never under 0.6× the pre-episode estimate.
            target = max(target, min(estimateKbps, e.anchorKbps * config.burstGuardFraction))
        } else if lossDriven, let rx, rx < estimateKbps {
            target = min(target, max(rx * config.decreaseFactor, estimateKbps * config.maxStepDown))
        }
        let isolated = lastDecrease.map { now - $0 >= config.fastRecoveryCooldown - eps } ?? true
        fastRecovery = (isolated && !backlog, nil)
        congestionKbps = estimateKbps
        estimateKbps = max(config.floorKbps, target)
        lastDecrease = now
        decreases += 1
        state = .decrease
    }
}
