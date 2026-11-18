// Receiver-side bandwidth estimate for the RCTL feedback's BWE field (kbps),
// which the host uses as its video encoder target (live A/B 2026-11-18,
// docs/research/2026-11-18-native-feedback.md). A simple loss-based AIMD in
// the spirit of GCC's loss controller (draft-ietf-rmcat-gcc §6), plus
// app-limited detection:
//
//   * starts at `initialKbps` (30 Mbps; the native captures do not show the
//     native viewer's start value — its RCTL body is encrypted and the
//     captured sessions were mostly static);
//   * multiplicative increase (`increasePerSecond`, 6 %/s) toward
//     `ceilingKbps` while the windowed loss is under 2 %, no recovery event
//     happened lately, and the host actually fills the estimate;
//   * multiplicative decrease (×0.85) when the windowed loss is over 10 %, or
//     on a recovery event (assembler keyframe request, decode backlog), with
//     a hold-off between decreases. A loss-driven decrease also cuts to
//     0.85 × the measured receive rate when that is lower (the link is
//     saturated, so the receive rate is the capacity), at most halving;
//   * near the estimate at which the last decrease happened (within ±10 %),
//     the increase slows to 1 %/s, so a fixed-capacity link sees a slow
//     sawtooth rather than a 15 % cut every few seconds;
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
        var initialKbps = 30_000.0
        var floorKbps = 4_000.0
        var ceilingKbps = 65_000.0
        var increasePerSecond = 0.06
        /// Increase rate within `nearCongestionBand` of the last decrease point.
        var nearCongestionIncreasePerSecond = 0.01
        var nearCongestionBand = 0.10
        var decreaseFactor = 0.85
        /// Increase only below this windowed loss fraction.
        var increaseBelowLoss = 0.02
        /// Decrease above this windowed loss fraction.
        var decreaseAboveLoss = 0.10
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
        var maxStepDown = 0.5
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

        let recovery = s.recoveryEvents > 0 || s.decodeBacklog
        guard now - start! >= config.startupGrace - eps else {
            state = .startup
            return bweKbps
        }
        let loss = lossFraction
        let rx = receiveKbps
        let lossCongested = (loss ?? 0) > config.decreaseAboveLoss

        if lossCongested || recovery {
            let holdoff = lossCongested ? config.decreaseHoldoff : config.recoveryHoldoff
            if let last = lastDecrease, now - last < holdoff - eps {
                state = .holdoff
            } else {
                var target = estimateKbps * config.decreaseFactor
                if lossCongested, let rx, rx < estimateKbps {
                    target = min(target, max(rx * config.decreaseFactor, estimateKbps * config.maxStepDown))
                }
                congestionKbps = estimateKbps
                estimateKbps = max(config.floorKbps, target)
                lastDecrease = now
                decreases += 1
                state = .decrease
            }
            if recovery { lastRecovery = now }
            return bweKbps
        }

        guard let loss else { state = .noData; return bweKbps }
        if loss >= config.increaseBelowLoss { state = .hold; return bweKbps }
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
}
