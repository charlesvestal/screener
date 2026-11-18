// Ported in part from iShareScreen src/isharescreen/proxy/media/vtdecode.py
// (_VTSlot, _on_decoded, get_frame, good_counts) (AGPL-3.0)
//
// The hand-off between VideoToolbox's output threads and the renderer: the
// latest decoded picture per tile, plus counters for the periodic video log.
// A tile that stops getting pictures (gated after loss, waiting for an IRAP)
// keeps its last good picture, so the screen freezes there instead of going
// black. A picture submitted before the one stored is ignored (the
// reference's seq check; VideoToolbox emits in decode order, so this only
// guards rebuild races).
//
// Sessions: `reset()` starts a new epoch. Each VideoPipeline publishes with
// the epoch it was created under, so a late VideoToolbox callback from the
// previous session can never land in the next one (decoder sequence numbers
// are process-global as well). The coordinator resets on teardown too, which
// frees the pixel buffers.
//
// Coherent pictures (deviation; the reference's desktop frontend composites
// whatever each tile slot holds): a picture is the tile strips that share an
// RTP timestamp, decoded one after another, and on the paced stream the last
// strip lands up to ~20 ms after the first. Showing each strip as it decodes
// put strips of two different pictures on screen (a dragged window sheared
// at the strip seams). So a frame that carries its RTP timestamp is STAGED,
// per picture, and the presentable set (`snapshot`) changes once per picture.
//
// Apple's encoder skips tiles with nothing new (live, 2026-11-18: with
// motion in one corner, 2 of 4 tiles are missing from ~60% of the pictures;
// ~2% even with full-screen motion), so most pictures never get all strips.
// Strips decode in decoding order, which is picture order (one DON counter,
// the tiles of a timestamp in tile order: HEVCAssembler), so a picture is
// shown:
//   * at once when it has every tile that changed recently (the union of the
//     tile sets of the last `recentPictures` pictures shown; all tiles at the
//     start): a tile that has been static that long is assumed skipped. When
//     it does come after all (a region starts moving), it fills the shown
//     picture in (one short tear at the onset of motion, not a held picture);
//   * when a strip of a newer picture decodes: the older picture has every
//     strip it will ever get (a skipped tile is unchanged, a gated one keeps
//     its last good strip), so it is final — never held for strips that are
//     not coming, which used to delay motion by two pictures and then jump;
//   * when `flushStaged` (the pipeline ticker) finds that no strip came for
//     its picture for `stagingTimeout` (the last picture of a motion burst).
// A complete newer picture supersedes older staged ones. Frames without a
// timestamp (tests, single-tile streams) commit at once.
//
// Pacing (opt-in, see MetalRenderer; the reference draws on arrival): a
// picture's strips arrive with network and pacer jitter (wire captures: half the
// pictures ≥ 4–13 ms behind the earliest one relative to their RTP
// timestamps, p90 13–31 ms), so drawing each picture as it completes showed
// only 69–79% of them for their own frame time at 60 Hz (8% never visible),
// which reads as judder against the native viewer. With `setPacing`, each
// shown picture is queued with a due time on its RTP timestamp: the earliest
// recent arrival (the network floor, over `Pacing.window`) plus
// `Pacing.delay`, never before it was committed and at most `Pacing.maxHold`
// after. `snapshot(ifNewerThan:now:)` presents the newest due picture (the
// renderer asks at display vsync while `nextDue` is set). In the same
// captures a 12 ms delay gave 84–97% exact frame times; a picture later than
// its due time is drawn at once (no added latency). The RTP clock of Apple's
// video stream is 24 kHz (measured 24.03–24.05 kHz over 35–50 s); the
// rolling floor absorbs the drift.
//
// `onChange` (the renderer's redraw trigger) is called, outside the lock,
// after every change that bumps `version`.
import CoreGraphics
import CoreVideo
import Foundation

final class VideoFrameStore: @unchecked Sendable {   // all state behind `lock`
    struct Snapshot {
        var version: Int
        var frames: [Int: CVPixelBuffer]
        var tileCount: Int
        var canvas: CGSize?
        /// When the presentable set last changed (for the frame-age stats).
        var changedAt: ContinuousClock.Instant? = nil
        /// RTP timestamp of the newest picture in it (judder stats).
        var rtpTimestamp: UInt32? = nil
    }

    /// Presentation stats for the periodic video log (since the last take).
    struct PresentStats: Equatable, Sendable {
        /// Pictures that became the presentable set.
        var shown = 0
        /// Staged pictures superseded by a newer one before being shown.
        var merged = 0
        /// Shown pictures without every tile (skipped by the encoder, or gated).
        var skips = 0
        /// Strips that completed a picture already shown without them (a
        /// brief tear: a static region started moving, or a strip stalled).
        var fills = 0
        /// Wait between a shown picture's last strip and its commit (ms).
        var waitTotalMs = 0.0
        var waitMaxMs = 0.0
        /// Strips that decoded after a strip of a newer picture.
        var outOfOrder = 0
        /// Queued pictures never presented: a newer one was due by the same vsync.
        var paceSkips = 0
        /// Pacing: due time − commit time of queued pictures (ms).
        var holdTotalMs = 0.0
        var holdMaxMs = 0.0
        var queued = 0
        /// Redraws of a new presentable set, and commit → draw age (ms).
        var drawn = 0
        var ageTotalMs = 0.0
        var ageMaxMs = 0.0
        /// Consecutive draws of pictures ≤ 100 ms apart on the RTP clock:
        /// |draw interval − RTP interval| (ms), the judder a viewer sees.
        var judderCount = 0
        var judderTotalMs = 0.0
        var judderOver8 = 0

        /// `shown=… merged=… skips=… fills=… wait_ms=avg/max ooo=… hold_ms=avg/max
        /// pace_skips=… drawn=… age_ms=avg/max judder_ms=avg judder8=…`.
        var summary: String {
            String(format: "shown=%d merged=%d skips=%d fills=%d wait_ms=%.1f/%.0f ooo=%d hold_ms=%.1f/%.0f "
                   + "pace_skips=%d drawn=%d age_ms=%.1f/%.0f judder_ms=%.1f judder8=%d",
                   shown, merged, skips, fills, shown > 0 ? waitTotalMs / Double(shown) : 0, waitMaxMs, outOfOrder,
                   queued > 0 ? holdTotalMs / Double(queued) : 0, holdMaxMs, paceSkips,
                   drawn, drawn > 0 ? ageTotalMs / Double(drawn) : 0, ageMaxMs,
                   judderCount > 0 ? judderTotalMs / Double(judderCount) : 0, judderOver8)
        }
    }

    /// Presentation pacing (see the header).
    struct Pacing: Equatable, Sendable {
        /// Due time after the network floor.
        var delay: Duration = .milliseconds(12)
        /// How far back the floor (earliest arrival vs RTP time) looks.
        var window: Duration = .seconds(1)
        /// Never hold a picture longer than this after it was committed.
        var maxHold: Duration = .milliseconds(40)
        /// Video RTP clock (ticks per second).
        static let clockRate: Int64 = 24_000
    }

    struct Counters: Equatable, Sendable {
        var frames: [Int: Int] = [:]
        var errors = 0
        var decodeNanos: Int64 = 0
    }

    /// How long a staged picture waits after its newest strip when nothing
    /// newer decodes (see the header). On live captures consecutive strips of
    /// one picture arrive ≤ 13 ms apart (p99.9; one in ~19000 gaps above
    /// 50 ms), but the paced stream has been seen to stall every tile for up
    /// to ~100 ms; with newer strips resolving every mid-stream picture, the
    /// timeout only ends a motion burst whose last picture skipped a tile.
    static let stagingTimeout: Duration = .milliseconds(100)

    /// Pictures whose tile sets make up the expected set (see the header):
    /// ~0.5 s at 60 fps, so a tile skipped now and then during motion is
    /// still waited for. On a live capture with motion in one corner, 4 / 8 /
    /// 16 / 30 / 60 pictures traded fills (onset tears) of 91 / 63 / 33 / 21
    /// / 4 for an average wait after the last strip of 2.8 / 4.5 / 6.9 / 9.3
    /// / 11.2 ms (the previous store: 23 ms, and 53 pictures never shown).
    static let recentPictures = 30

    private let lock = NSLock()
    private var frames: [Int: (buffer: CVPixelBuffer, seq: Int)] = [:]
    private struct StagedPicture {
        var ts: UInt32
        var strips: [Int: (buffer: CVPixelBuffer, seq: Int)]
        var since: ContinuousClock.Instant
        /// When its newest strip was staged.
        var lastStrip: ContinuousClock.Instant
    }
    /// Pictures being assembled, oldest RTP timestamp first.
    private var pending: [StagedPicture] = []
    /// The picture on screen and the tiles it was shown without.
    private var shownTimestamp: UInt32?
    private var shownMissing: Set<Int> = []
    /// Tile sets of the last `recentPictures` pictures shown, oldest first.
    private var recentSets: [Set<Int>] = []
    private var partialCommits = 0
    private var present = PresentStats()
    private var changedAt: ContinuousClock.Instant?
    /// Newest RTP timestamp staged this session (out-of-order detection).
    private var newestStaged: UInt32?
    private var version = 0
    private var tileCount = 4
    private var canvas: CGSize?
    private var counters = Counters()
    private var firstFrameSeen = false
    private var epoch = 0
    private var published = 0
    private var staleDropped = 0
    private var lastDraw: (ts: UInt32, at: ContinuousClock.Instant)?
    private var pacing: Pacing?
    /// Shown pictures waiting for their due time, oldest first (pacing).
    private var queue: [(snapshot: Snapshot, due: ContinuousClock.Instant)] = []
    /// The presented set (pacing); without pacing the committed set is.
    private var presented: Snapshot?
    private var mediaAnchor: (ts: UInt32, at: ContinuousClock.Instant)?
    private var lateness: [(at: ContinuousClock.Instant, late: Duration)] = []
    #if DEBUG
    // Tear diagnostics: recent publishes and partial commits awaiting their missing strips.
    private var trace: [(tile: Int, ts: UInt32?, seq: Int, at: ContinuousClock.Instant)] = []
    private var pendingMissing: [(ts: UInt32, tiles: Set<Int>, at: ContinuousClock.Instant)] = []
    #endif

    /// Called once per session, from a VideoToolbox thread, with the first picture.
    var onFirstFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get { lock.withLock { _onFirstFrame } }
        set { lock.withLock { _onFirstFrame = newValue } }
    }
    private var _onFirstFrame: (@Sendable (CVPixelBuffer) -> Void)?

    /// Called after every change (VideoToolbox threads, the main actor, ...).
    var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    private var _onChange: (@Sendable () -> Void)?
    private var onChangeOwner: ObjectIdentifier?

    /// Installs `onChange` on behalf of `owner` (a renderer).
    func setOnChange(owner: AnyObject, _ cb: @escaping @Sendable () -> Void) {
        lock.withLock { _onChange = cb; onChangeOwner = ObjectIdentifier(owner) }
    }

    /// Removes `onChange` only if `owner` installed it (a dismantled view must
    /// not unhook its successor).
    func clearOnChange(owner: AnyObject) {
        lock.withLock {
            guard onChangeOwner == ObjectIdentifier(owner) else { return }
            _onChange = nil; onChangeOwner = nil
        }
    }

    /// Forget everything and start a new session epoch (frees the pixel
    /// buffers). Returns the new epoch.
    @discardableResult
    func reset() -> Int {
        let (e, cb) = lock.withLock {
            frames = [:]; version += 1; canvas = nil; tileCount = 4
            pending = []; shownTimestamp = nil; shownMissing = []; newestStaged = nil; recentSets = []
            resetPacingLocked()
            counters = Counters(); firstFrameSeen = false
            epoch += 1
            return (epoch, _onChange)
        }
        cb?()
        return e
    }

    /// The epoch frames must carry to be accepted (see `reset`).
    var currentEpoch: Int { lock.withLock { epoch } }

    func configure(tileCount: Int? = nil, canvas: CGSize? = nil) {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            let before = version
            if let tileCount, tileCount > 0, tileCount != self.tileCount {
                self.tileCount = tileCount
                frames = frames.filter { $0.key < tileCount }
                pending = []; shownTimestamp = nil; shownMissing = []; recentSets = []
                version += 1
            }
            if let canvas, canvas != self.canvas { self.canvas = canvas; version += 1 }
            guard version != before else { return nil }
            scheduleLocked(ts: nil, now: .now)
            return _onChange
        }
        cb?()
    }

    /// Stores `f` if it belongs to the current session (`epoch`) and is not
    /// older than the tile's stored or staged picture. With an RTP timestamp
    /// the frame is staged until its picture is complete (see the header).
    func publish(_ f: DecodedFrame, epoch: Int, now: ContinuousClock.Instant = .now) {
        let (first, changed): ((@Sendable (CVPixelBuffer) -> Void)?, (@Sendable () -> Void)?) = lock.withLock {
            guard epoch == self.epoch else { staleDropped += 1; return (nil, nil) }   // a previous session
            #if DEBUG
            traceLocked(f, now: now)
            #endif
            let stagedSeq = pending.compactMap { $0.strips[f.tile]?.seq }.max() ?? Int.min
            let newest = max(frames[f.tile]?.seq ?? Int.min, stagedSeq)
            if f.seq < newest { return (nil, nil) }                                   // older than stored
            published += 1
            counters.frames[f.tile, default: 0] += 1
            counters.decodeNanos += f.decodeTime.components.seconds * 1_000_000_000
                + f.decodeTime.components.attoseconds / 1_000_000_000
            let committed: Bool
            if let ts = f.rtpTimestamp, tileCount > 1 {
                committed = stageLocked(f, ts: ts, now: now)
            } else {
                frames[f.tile] = (f.pixelBuffer, f.seq)
                shownTimestamp = nil; shownMissing = []
                version += 1
                changedAt = now
                scheduleLocked(ts: nil, now: now)
                committed = true
            }
            let cb = committed ? _onChange : nil
            guard !firstFrameSeen else { return (nil, cb) }
            firstFrameSeen = true
            return (_onFirstFrame, cb)
        }
        first?(f.pixelBuffer)
        changed?()
    }

    /// `a` is after `b` in RTP timestamp order (wrap-safe).
    private static func isAfter(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }

    /// Returns whether the presentable set changed.
    private func stageLocked(_ f: DecodedFrame, ts: UInt32, now: ContinuousClock.Instant) -> Bool {
        let entry = (buffer: f.pixelBuffer, seq: f.seq)
        if let n = newestStaged, Self.isAfter(n, ts) { present.outOfOrder += 1 }
        if newestStaged.map({ Self.isAfter(ts, $0) }) ?? true { newestStaged = ts }
        if let shown = shownTimestamp, !Self.isAfter(ts, shown) {
            // A strip of the picture on screen (shown without it: the tile
            // was static, or its strip stalled) completes it in place;
            // anything older is superseded.
            guard ts == shown, shownMissing.contains(f.tile) else { return false }
            frames[f.tile] = entry
            shownMissing.remove(f.tile)
            if !recentSets.isEmpty { recentSets[recentSets.count - 1].insert(f.tile) }
            present.fills += 1
            version += 1
            changedAt = now
            scheduleLocked(ts: nil, now: now, replacingTail: true)
            return true
        }
        if let i = pending.firstIndex(where: { $0.ts == ts }) {
            pending[i].strips[f.tile] = entry
            pending[i].lastStrip = now
        } else {
            let at = pending.firstIndex { Self.isAfter($0.ts, ts) } ?? pending.endIndex
            pending.insert(StagedPicture(ts: ts, strips: [f.tile: entry], since: now, lastStrip: now), at: at)
        }
        // The newest picture with every recently changed tile wins; older
        // staged ones are never shown.
        let expected = recentSets.isEmpty ? Set(0..<tileCount) : recentSets.reduce(into: Set<Int>()) { $0.formUnion($1) }
        if let done = pending.lastIndex(where: { expected.isSubset(of: $0.strips.keys) }) {
            commitLocked(through: done, now: now, reason: "complete")
            return true
        }
        // A strip of a newer picture decoded: every older one is final.
        guard pending.count > 1 else { return false }
        commitLocked(through: pending.count - 2, now: now, reason: "final")
        return true
    }

    /// Commits a staged picture older than `timeout` (the pipeline ticker).
    func flushStaged(now: ContinuousClock.Instant = .now, timeout: Duration = VideoFrameStore.stagingTimeout) {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            var changed = false
            while let oldest = pending.first, now - oldest.lastStrip >= timeout {
                commitLocked(through: 0, now: now, reason: "timeout")
                changed = true
            }
            return changed ? _onChange : nil
        }
        cb?()
    }

    /// The renderer drew a new presentable set that changed at `changedAt`
    /// (with picture `rtpTimestamp`).
    func noteDrawn(changedAt: ContinuousClock.Instant?, rtpTimestamp: UInt32? = nil,
                   now: ContinuousClock.Instant = .now) {
        lock.withLock {
            present.drawn += 1
            if let ts = rtpTimestamp, let last = lastDraw, ts != last.ts {
                let media = Double(Int32(bitPattern: ts &- last.ts)) * 1000 / Double(Pacing.clockRate)
                if media > 0, media <= 100 {
                    let j = abs(Double((now - last.at) / .microseconds(1)) / 1000 - media)
                    present.judderCount += 1
                    present.judderTotalMs += j
                    if j > 8 { present.judderOver8 += 1 }
                }
            }
            if let ts = rtpTimestamp { lastDraw = (ts, now) }
            guard let changedAt else { return }
            let age = Double((now - changedAt) / .microseconds(1)) / 1000
            present.ageTotalMs += age
            present.ageMaxMs = max(present.ageMaxMs, age)
        }
    }

    /// Presentation stats since the last call (then zeroed).
    func takePresentStats() -> PresentStats {
        lock.withLock { defer { present = PresentStats() }; return present }
    }

    /// Pictures shown incomplete because their strips stopped coming for
    /// `stagingTimeout` (since the last call). Tiles the encoder skipped do
    /// not count (PresentStats.skips).
    func takePartialCommits() -> Int { lock.withLock { defer { partialCommits = 0 }; return partialCommits } }

    /// Shows staged picture `index`: its strips go over the older stored ones
    /// (merged with the strips of the older staged pictures it supersedes, so
    /// a tile missing from it keeps its newest strip), and it and every older
    /// staged picture leave the stage.
    private func commitLocked(through index: Int, now: ContinuousClock.Instant, reason: String) {
        let picture = pending[index]
        let partial = picture.strips.count < tileCount
        #if DEBUG
        if partial, reason == "timeout" {
            let missing = Set(0..<tileCount).subtracting(picture.strips.keys)
            let recent = trace.suffix(12).map { e in
                "t\(e.tile):\(e.ts.map(String.init) ?? "-")/\(e.seq)@\((now - e.at).ms)"
            }.joined(separator: " ")
            Log.video.info("tear: partial ts=\(picture.ts) reason=\(reason) missing=\(missing.sorted()) "
                           + "staged_age_ms=\((now - picture.since).ms) recent(tile:ts/seq@ms_ago)=[\(recent)]")
            pendingMissing.append((picture.ts, missing, now))
            if pendingMissing.count > 16 { pendingMissing.removeFirst() }
        }
        #endif
        for p in pending[...index] { for (tile, entry) in p.strips { frames[tile] = entry } }
        shownTimestamp = picture.ts
        shownMissing = Set(0..<tileCount).subtracting(picture.strips.keys)
        recentSets.append(Set(picture.strips.keys))
        if recentSets.count > Self.recentPictures { recentSets.removeFirst(recentSets.count - Self.recentPictures) }
        pending.removeFirst(index + 1)
        if partial { present.skips += 1 }
        if partial, reason == "timeout" { partialCommits += 1 }
        let wait = Double((now - picture.lastStrip) / .microseconds(1)) / 1000
        present.shown += 1
        present.merged += index
        present.waitTotalMs += wait
        present.waitMaxMs = max(present.waitMaxMs, wait)
        version += 1
        changedAt = now
        scheduleLocked(ts: picture.ts, now: now)
    }

    // MARK: pacing

    /// Turns pacing on (or off with nil) for the renderer that presents.
    func setPacing(_ p: Pacing?) { lock.withLock { pacing = p; resetPacingLocked() } }

    /// When the oldest queued picture is due (nil: nothing queued).
    var nextDue: ContinuousClock.Instant? { lock.withLock { queue.first?.due } }

    private func resetPacingLocked() {
        queue = []; mediaAnchor = nil; lateness = []
        presented = pacing == nil ? nil : committedSnapshotLocked()
    }

    private func committedSnapshotLocked() -> Snapshot {
        Snapshot(version: version, frames: frames.mapValues(\.buffer), tileCount: tileCount, canvas: canvas,
                 changedAt: changedAt, rtpTimestamp: shownTimestamp)
    }

    /// Queues the committed set for presentation (pacing only): due on the
    /// picture's RTP timestamp `ts`, or at once without one. A fill-in
    /// replaces the queued picture it completes.
    private func scheduleLocked(ts: UInt32?, now: ContinuousClock.Instant, replacingTail: Bool = false) {
        guard let pacing else { return }
        let snap = committedSnapshotLocked()
        if replacingTail, !queue.isEmpty {
            queue[queue.count - 1].snapshot = snap
            return
        }
        var due = now
        if let ts { due = dueLocked(ts, now: now, pacing) }
        if let last = queue.last?.due, due < last { due = last }
        queue.append((snap, due))
        let hold = Double((due - now) / .microseconds(1)) / 1000
        present.queued += 1
        present.holdTotalMs += hold
        present.holdMaxMs = max(present.holdMaxMs, hold)
    }

    /// Network floor + delay on the RTP timeline, clamped to [now, now + maxHold].
    private func dueLocked(_ ts: UInt32, now: ContinuousClock.Instant, _ p: Pacing) -> ContinuousClock.Instant {
        let anchor = mediaAnchor ?? (ts, now)
        mediaAnchor = anchor
        let ticks = Int64(Int32(bitPattern: ts &- anchor.ts))
        let media = anchor.at + .microseconds(ticks * 1_000_000 / Pacing.clockRate)
        let late = now - media
        lateness.removeAll { now - $0.at > p.window }
        lateness.append((now, late))
        let floor = lateness.map(\.late).min() ?? late
        return min(max(media + floor + p.delay, now), now + p.maxHold)
    }

    #if DEBUG
    private func traceLocked(_ f: DecodedFrame, now: ContinuousClock.Instant) {
        if let prev = trace.last, f.seq < prev.seq {
            Log.video.info("tear: out-of-order output seq=\(f.seq) tile=\(f.tile) after seq=\(prev.seq) tile=\(prev.tile)")
        }
        trace.append((f.tile, f.rtpTimestamp, f.seq, now))
        if trace.count > 32 { trace.removeFirst(trace.count - 32) }
        guard let ts = f.rtpTimestamp,
              let i = pendingMissing.firstIndex(where: { $0.ts == ts && $0.tiles.contains(f.tile) }) else { return }
        Log.video.info("tear: missing strip ts=\(ts) tile=\(f.tile) arrived \((now - pendingMissing[i].at).ms) ms after its partial commit")
        pendingMissing[i].tiles.remove(f.tile)
        if pendingMissing[i].tiles.isEmpty { pendingMissing.remove(at: i) }
    }
    #endif

    /// Pictures stored since the store was created (all sessions).
    var totalPublished: Int { lock.withLock { published } }

    /// Frames dropped because they came from an earlier epoch.
    var staleFramesDropped: Int { lock.withLock { staleDropped } }

    func noteError() { lock.withLock { counters.errors += 1 } }

    /// Counters since the last call (then zeroed).
    func takeCounters() -> Counters {
        lock.withLock { defer { counters = Counters() }; return counters }
    }

    var currentVersion: Int { lock.withLock { version } }

    /// A picture has been decoded this session.
    var hasDecoded: Bool { lock.withLock { firstFrameSeen } }

    /// nil when nothing changed since `version`. With pacing, the newest
    /// queued picture due by `now` becomes the presented set first.
    func snapshot(ifNewerThan seen: Int?, now: ContinuousClock.Instant = .now) -> Snapshot? {
        lock.withLock {
            guard pacing != nil else {
                if let seen, seen == version { return nil }
                return committedSnapshotLocked()
            }
            if let i = queue.lastIndex(where: { $0.due <= now }) {
                present.paceSkips += i
                presented = queue[i].snapshot
                queue.removeFirst(i + 1)
            }
            guard let p = presented, p.version != seen else { return nil }
            return p
        }
    }
}
