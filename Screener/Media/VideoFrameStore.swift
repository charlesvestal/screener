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
// Apple's encoder skips tiles with nothing new — with LTR acks almost
// entirely (live, 2026-11-19: a window moving inside strips 1–2 of 4 sends
// {1,2} in ~70% of the pictures, a third tile now and then, the fourth
// almost never), so most pictures never get all strips. Nothing in the
// stream says which tiles a picture will have (live captures, 2026-11-19):
// the RTP header extension (profile 0x9311 or 0x9301, one word) is u16
// packets in this tile picture + u16 frame counter, and that counter is
// global (shared by the tiles of a timestamp, +1 per picture sent); DON and
// POC are one counter each, +1 per tile picture SENT (a skipped tile
// consumes neither); the marker ends each tile picture. What IS known:
// tile pictures are sent, and decode, in (timestamp, tile) order, all of a
// timestamp's strips back to back (≤ 5 ms apart on the sender's wire) before
// the next timestamp. So a picture is shown:
//   * at once when it has the last tile (nothing can follow it);
//   * at once when no strip of it is still on its way (`noteArrival`: the
//     pipeline reports each tile picture's first packet) and either a packet
//     of a newer picture has arrived (it is final), or the previous picture
//     shown had no tile after its last strip (predicted complete; if one does
//     come after all — a region starts moving — it fills the shown picture
//     in: one short tear at the onset of motion, usually absorbed by the
//     pacing delay). Otherwise it waits for that evidence: about one frame
//     while the stream is live (the next picture's first packet), longer only
//     when the stream goes silent (a Wi-Fi stall holds the old picture
//     rather than tearing for its length);
//   * when a strip of a newer picture decodes (it is final: a skipped tile is
//     unchanged, a gated one keeps its last good strip);
//   * when `flushStaged` (the pipeline ticker) finds that no strip came for
//     its picture for `stagingTimeout` (a stall, or the end of a burst whose
//     last picture dropped a tile the previous one had).
// The previous store expected every tile seen in the last 30 pictures, so a
// tile that changed once (a cursor, a clock) made the next ~0.5 s of
// pictures wait for the next picture's strip (up to `stagingTimeout`): with
// motion in two strips, wait_ms 6–8 avg / ~100 max and paced judder.
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
// Resize hold (Task 21, RFC §10.9): a dynamic resize restarts the encoder on
// a new SSRC group with new parameter sets, a new canvas and maybe a new tile
// count. `holdForResize(canvas:)` (the 0x451) and `beginGroup` (the pipeline:
// new group / new parameter sets) keep the last picture, its canvas and tile
// count on screen — the renderer keeps scaling it into the view — until the
// new stream's first picture has every tile (or `incomingTimeout` after its
// first strip); then frames, canvas and tile count switch together, so there
// is no black flash and old strips are never laid out on the new canvas.
// Pictures are told apart by their decoder sequence number (submitted after
// `beginGroup` = new stream). A held canvas with no new stream after
// `resizeHoldLimit` is applied anyway.
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
        /// Shown pictures that waited until a newer strip decoded or the
        /// staging timeout (nothing told the store earlier that they were done).
        var held = 0

        /// `shown=… merged=… skips=… fills=… wait_ms=avg/max ooo=… hold_ms=avg/max
        /// pace_skips=… drawn=… age_ms=avg/max judder_ms=avg judder8=… held=…`.
        var summary: String {
            String(format: "shown=%d merged=%d skips=%d fills=%d wait_ms=%.1f/%.0f ooo=%d hold_ms=%.1f/%.0f "
                   + "pace_skips=%d drawn=%d age_ms=%.1f/%.0f judder_ms=%.1f judder8=%d held=%d",
                   shown, merged, skips, fills, shown > 0 ? waitTotalMs / Double(shown) : 0, waitMaxMs, outOfOrder,
                   queued > 0 ? holdTotalMs / Double(queued) : 0, holdMaxMs, paceSkips,
                   drawn, drawn > 0 ? ageTotalMs / Double(drawn) : 0, ageMaxMs,
                   judderCount > 0 ? judderTotalMs / Double(judderCount) : 0, judderOver8, held)
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

    /// Cumulative (never reset) decode totals for the live stats overlay
    /// (LiveStatsModel samples deltas); `takeCounters` stays the log's.
    struct LiveTotals: Equatable, Sendable {
        var frames: [Int: Int] = [:]
        var decodeNanos: Int64 = 0
        var pixelFormat: OSType?
    }

    /// How long a staged picture waits after its newest strip when nothing
    /// resolves it (see the header). Consecutive strips of one picture leave
    /// the host ≤ 5 ms apart, but Wi-Fi stalls the stream for 80–150 ms a few
    /// times a second on some networks (2026-11-19: the host's wired send
    /// side shows no gap), mid-picture too; holding the old picture through
    /// one is better than tearing for its length. Mid-stream pictures are
    /// resolved by the next picture's first packet long before this.
    static let stagingTimeout: Duration = .milliseconds(100)

    /// Timestamps whose wire tiles are remembered (`noteArrival`): ~2 s at
    /// 60 fps, well beyond the decode backlog after a stall.
    static let wireMemory = 128

    /// Resize hold: a partial first picture of the new stream is shown this
    /// long after its first strip; a held canvas without a new stream is
    /// applied after `resizeHoldLimit`.
    static let incomingTimeout: Duration = .milliseconds(500)
    static let resizeHoldLimit: Duration = .seconds(3)

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
    /// Tile set of the last picture shown (the completeness prediction).
    private var previousTiles: Set<Int>?
    /// Tiles with a packet on the wire per RTP timestamp (`noteArrival`; the
    /// timestamps in arrival order for pruning), and the newest one seen.
    private var wire: [UInt32: Set<Int>] = [:]
    private var wireOrder: [UInt32] = []
    private var newestWire: UInt32?
    private var partialCommits = 0
    /// Resize hold (see the header).
    private struct NextGroup {
        var afterSeq: Int
        var tileCount: Int?
        var incoming: [Int: (buffer: CVPixelBuffer, seq: Int)] = [:]
        var firstAt: ContinuousClock.Instant?
        var since: ContinuousClock.Instant
    }
    private var nextGroup: NextGroup?
    private var heldCanvas: (size: CGSize, since: ContinuousClock.Instant)?
    private var present = PresentStats()
    private var changedAt: ContinuousClock.Instant?
    /// Newest RTP timestamp staged this session (out-of-order detection).
    private var newestStaged: UInt32?
    private var version = 0
    private var tileCount = 4
    private var canvas: CGSize?
    private var counters = Counters()
    private var live = LiveTotals()
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
        get { lock.withLock { rendererOnChange } }
        set { lock.withLock { rendererOnChange = newValue } }
    }
    private var rendererOnChange: (@Sendable () -> Void)?
    private var onChangeOwner: ObjectIdentifier?
    /// Extra change observers (Picture in Picture's compositor), called after
    /// `onChange`; keyed by `addObserver`'s token.
    private var observers: [Int: @Sendable () -> Void] = [:]
    private var nextObserver = 0
    /// What every change notifies (read under `lock`).
    private var _onChange: (@Sendable () -> Void)? {
        guard !observers.isEmpty else { return rendererOnChange }
        let renderer = rendererOnChange, extra = Array(observers.values)
        return { renderer?(); for cb in extra { cb() } }
    }

    /// Installs `onChange` on behalf of `owner` (a renderer).
    func setOnChange(owner: AnyObject, _ cb: @escaping @Sendable () -> Void) {
        lock.withLock { rendererOnChange = cb; onChangeOwner = ObjectIdentifier(owner) }
    }

    /// Removes `onChange` only if `owner` installed it (a dismantled view must
    /// not unhook its successor).
    func clearOnChange(owner: AnyObject) {
        lock.withLock {
            guard onChangeOwner == ObjectIdentifier(owner) else { return }
            rendererOnChange = nil; onChangeOwner = nil
        }
    }

    /// Adds a change observer next to the renderer's `onChange` (same
    /// threads and timing). Returns the token for `removeObserver`.
    func addObserver(_ cb: @escaping @Sendable () -> Void) -> Int {
        lock.withLock { nextObserver += 1; observers[nextObserver] = cb; return nextObserver }
    }

    func removeObserver(_ token: Int) { lock.withLock { _ = observers.removeValue(forKey: token) } }

    /// The committed presentable set, without touching the pacing queue the
    /// renderer presents from (Picture in Picture reads this).
    func latestPicture() -> Snapshot { lock.withLock { committedSnapshotLocked() } }

    /// Forget everything and start a new session epoch (frees the pixel
    /// buffers). Returns the new epoch.
    @discardableResult
    func reset() -> Int {
        let (e, cb) = lock.withLock {
            frames = [:]; version += 1; canvas = nil; tileCount = 4
            nextGroup = nil; heldCanvas = nil
            pending = []; shownTimestamp = nil; shownMissing = []; newestStaged = nil; previousTiles = nil; wire = [:]; wireOrder = []; newestWire = nil
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
                pending = []; shownTimestamp = nil; shownMissing = []; previousTiles = nil; wire = [:]; wireOrder = []; newestWire = nil
                version += 1
            }
            if let canvas {
                heldCanvas = nil
                if canvas != self.canvas { self.canvas = canvas; version += 1 }
            }
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
            live.frames[f.tile, default: 0] += 1
            live.decodeNanos += f.decodeTime.components.seconds * 1_000_000_000
                + f.decodeTime.components.attoseconds / 1_000_000_000
            live.pixelFormat = CVPixelBufferGetPixelFormatType(f.pixelBuffer)
            let committed: Bool
            if var next = nextGroup, f.seq > next.afterSeq {
                // The new stream (resize hold): collect its first picture.
                next.incoming[f.tile] = (f.pixelBuffer, f.seq)
                next.firstAt = next.firstAt ?? now
                nextGroup = next
                committed = next.incoming.count >= (next.tileCount ?? tileCount)
                if committed { switchToNextGroupLocked(now: now, reason: "complete") }
            } else if let ts = f.rtpTimestamp, tileCount > 1 {
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
            previousTiles?.insert(f.tile)
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
        if commitCompleteLocked(now: now, reason: "complete") { return true }
        // A strip of a newer picture decoded: every older one is final.
        guard pending.count > 1 else { return false }
        commitLocked(through: pending.count - 2, now: now, reason: "final")
        present.held += 1
        _ = commitCompleteLocked(now: now, reason: "complete")   // the newer one, predicted from it
        return true
    }

    /// Shows the newest complete staged picture (older staged ones are never
    /// shown), repeatedly: the picture shown is the next one's prediction.
    private func commitCompleteLocked(now: ContinuousClock.Instant, reason: String) -> Bool {
        var changed = false
        while let done = pending.lastIndex(where: isCompleteLocked) {
            commitLocked(through: done, now: now, reason: reason)
            changed = true
        }
        return changed
    }

    /// Whether staged picture `p` has every strip it will get (see the header).
    private func isCompleteLocked(_ p: StagedPicture) -> Bool {
        guard let top = p.strips.keys.max() else { return false }
        if top >= tileCount - 1 { return true }                          // nothing can follow the last tile
        let have = Set(p.strips.keys)
        if let w = wire[p.ts], !w.isSubset(of: have) { return false }      // on its way
        if let n = newestWire, Self.isAfter(n, p.ts) { return true }      // the next picture has begun
        let previous = previousTiles ?? Set(0..<tileCount)
        return !previous.contains { $0 > top }
    }

    /// The pipeline saw the first packet of tile picture (`ts`, `tile`) — before
    /// it is assembled and decoded. A packet of a newer picture finalizes the
    /// staged ones whose strips are all in (see the header).
    func noteArrival(rtpTimestamp ts: UInt32, tile: Int, now: ContinuousClock.Instant = .now) {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            if wire[ts, default: []].insert(tile).inserted, wire[ts]!.count == 1 {
                wireOrder.append(ts)
                if wireOrder.count > Self.wireMemory { wire[wireOrder.removeFirst()] = nil }
            }
            let newer = newestWire.map { Self.isAfter(ts, $0) } ?? true
            if newer { newestWire = ts }
            guard newer, nextGroup == nil, commitCompleteLocked(now: now, reason: "next on wire") else { return nil }
            return _onChange
        }
        cb?()
    }

    // MARK: resize hold

    /// The server confirmed a new display geometry (0x451, RFC §7.5): with a
    /// picture on screen, `canvas` applies together with the new stream's
    /// first picture (see the header); with none, at once.
    func holdForResize(canvas size: CGSize, now: ContinuousClock.Instant = .now) {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            guard size != canvas || nextGroup != nil else { heldCanvas = nil; return nil }
            if frames.isEmpty, pending.isEmpty, nextGroup == nil {
                heldCanvas = nil
                canvas = size; version += 1
                scheduleLocked(ts: nil, now: now)
                return _onChange
            }
            heldCanvas = (size, now)
            return nil
        }
        cb?()
    }

    /// The video pipeline switched to a new stream (SSRC group or parameter
    /// sets) of `tileCount` tiles (nil: unchanged): pictures submitted after
    /// decoder sequence `afterSeq` belong to it. Until its first picture is
    /// in, the current one stays up. With nothing on screen it applies at once.
    func beginGroup(tileCount: Int?, afterSeq: Int, now: ContinuousClock.Instant = .now) {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            if frames.isEmpty, pending.isEmpty, nextGroup == nil {
                var changed = false
                if let t = tileCount, t > 0, t != self.tileCount { self.tileCount = t; changed = true }
                if let held = heldCanvas { heldCanvas = nil; if held.size != canvas { canvas = held.size; changed = true } }
                guard changed else { return nil }
                version += 1
                scheduleLocked(ts: nil, now: now)
                return _onChange
            }
            var next = nextGroup ?? NextGroup(afterSeq: afterSeq, since: now)
            next.afterSeq = max(next.afterSeq, afterSeq)
            if let t = tileCount, t > 0 { next.tileCount = t }
            // Strips of the new stream decoded before this call stay in.
            next.incoming = next.incoming.filter { $0.value.seq > next.afterSeq }
            if next.incoming.isEmpty { next.firstAt = nil }
            nextGroup = next
            return nil
        }
        cb?()
    }

    /// Holding the last picture for a resize / stream switch.
    var isHoldingForNewStream: Bool { lock.withLock { nextGroup != nil || heldCanvas != nil } }

    /// Frames, tile count and canvas switch to the new stream together.
    private func switchToNextGroupLocked(now: ContinuousClock.Instant, reason: String) {
        guard let next = nextGroup else { return }
        nextGroup = nil
        let newTiles = next.tileCount.flatMap { $0 > 0 ? $0 : nil } ?? tileCount
        let geometryChanged = heldCanvas != nil || newTiles != tileCount
        // Same geometry (a plain stream restart): a tile the new picture
        // lacks keeps its last strip; otherwise old strips cannot be mixed in.
        frames = geometryChanged ? next.incoming : frames.merging(next.incoming) { _, new in new }
        tileCount = newTiles
        if let held = heldCanvas { canvas = held.size }
        heldCanvas = nil
        pending = []; shownTimestamp = nil; shownMissing = []; previousTiles = nil; wire = [:]; wireOrder = []; newestWire = nil; newestStaged = nil
        version += 1
        changedAt = now
        scheduleLocked(ts: nil, now: now)
        Log.video.info("video: new stream shown (\(reason): \(next.incoming.count)/\(newTiles) tiles, canvas "
                       + "\(canvas.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"), held \((now - next.since).ms) ms)")
    }

    /// Commits a staged picture older than `timeout` (the pipeline ticker).
    func flushStaged(now: ContinuousClock.Instant = .now, timeout: Duration = VideoFrameStore.stagingTimeout) {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            var changed = false
            while let oldest = pending.first, now - oldest.lastStrip >= timeout {
                commitLocked(through: 0, now: now, reason: "timeout")
                present.held += 1
                changed = true
            }
            if changed { _ = commitCompleteLocked(now: now, reason: "complete") }
            if let first = nextGroup?.firstAt, now - first >= Self.incomingTimeout {
                switchToNextGroupLocked(now: now, reason: "timeout")
                changed = true
            } else if nextGroup == nil, let held = heldCanvas, now - held.since >= Self.resizeHoldLimit {
                Log.video.error("video: resize hold: no new stream \(Self.resizeHoldLimit.ms) ms after the layout; "
                                + "applying canvas \(Int(held.size.width))x\(Int(held.size.height))")
                heldCanvas = nil
                if held.size != canvas { canvas = held.size; version += 1; changed = true }
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
        previousTiles = Set(picture.strips.keys)
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

    /// Cumulative decode totals (all sessions; see LiveTotals).
    var liveTotals: LiveTotals { lock.withLock { live } }

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
