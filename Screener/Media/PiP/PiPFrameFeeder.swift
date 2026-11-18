// Picture in Picture: feeds the display layer from the frame store.
//
// It observes VideoFrameStore (`addObserver`, next to the renderer's
// onChange) and, on its own serial queue, composites the newest committed
// picture (PiPCompositor) into a sample buffer for `sink`, rate-limited:
//   * `.inline` — a session is up but PiP is not showing: a few pictures a
//     second, so the layer always has a recent picture for PiP to start from
//     (manually, or automatically when the app leaves the foreground);
//   * `.live` — PiP is showing: up to 30 pictures a second;
//   * `.frozen` — the user pressed pause in the PiP window: the picture holds;
//   * `.off` — no session: nothing.
// Work happens only when the store's version changes: a static Mac screen
// costs nothing. A store reset (reconnect) has no frames: nothing is sent,
// so the layer keeps showing the last picture until the new session's first.
import CoreMedia
import CoreVideo
import Foundation

final class PiPFrameFeeder: @unchecked Sendable {   // mutable state confined to `queue`
    enum Rate: Equatable, Sendable {
        case off, inline, live, frozen

        func interval(_ intervals: Intervals) -> Duration? {
            switch self {
            case .inline: intervals.inline
            case .live: intervals.live
            case .off, .frozen: nil
            }
        }
    }

    struct Intervals: Sendable {
        var inline: Duration = .milliseconds(500)
        var live: Duration = .milliseconds(33)
    }

    private let queue = DispatchQueue(label: "screener.pip.feeder", qos: .userInitiated)
    private let store: VideoFrameStore
    private let compositor: PiPCompositor
    private let intervals: Intervals
    private let sink: @Sendable (CMSampleBuffer) -> Void
    private var token: Int?
    private var rate: Rate = .off
    private var lastVersion: Int?
    private var lastEmit: ContinuousClock.Instant?
    private var timerPending = false
    private var timestamps = PiPTimestamps()
    private var emitted = 0

    init(store: VideoFrameStore, compositor: PiPCompositor = PiPCompositor(), intervals: Intervals = Intervals(),
         sink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.store = store
        self.compositor = compositor
        self.intervals = intervals
        self.sink = sink
        token = store.addObserver { [weak self] in self?.changed() }
    }

    deinit {
        if let token { store.removeObserver(token) }
    }

    /// Stops observing the store (the feeder sends nothing afterwards).
    func stop() {
        if let token { store.removeObserver(token) }
        token = nil
        queue.async { [self] in rate = .off }
    }

    /// Switches rate; entering `.inline` / `.live` sends the current picture now.
    func setRate(_ r: Rate) {
        queue.async { [self] in
            let was = rate
            rate = r
            guard r != was, r == .live || r == .inline else { return }
            emit(force: true)
        }
    }

    /// Sends the current picture now, even if unchanged (PiP is about to show).
    func refresh() {
        queue.async { [self] in
            guard rate == .live || rate == .inline else { return }
            emit(force: true)
        }
    }

    /// Waits until everything queued so far ran (tests).
    func drain() { queue.sync {} }

    /// Pictures sent so far (tests, logs).
    var emittedCount: Int { queue.sync { emitted } }

    private func changed() {
        queue.async { [self] in schedule() }
    }

    private func schedule() {
        guard let interval = rate.interval(intervals) else { return }
        let now = ContinuousClock.now
        let due = lastEmit.map { $0 + interval } ?? now
        if due <= now {
            emit(force: false)
        } else if !timerPending {
            timerPending = true
            let delay = due - now
            let nanos = delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) { [self] in
                timerPending = false
                schedule()
            }
        }
    }

    private func emit(force: Bool) {
        let snap = store.latestPicture()
        guard force || snap.version != lastVersion else { return }
        guard !snap.frames.isEmpty else { return }   // reset / reconnecting: keep the last picture
        lastVersion = snap.version
        lastEmit = .now
        guard let pb = compositor.composite(snap),
              let sample = PiPSampleBuffer.make(pb, pts: timestamps.next()) else { return }
        emitted += 1
        sink(sample)
    }
}
