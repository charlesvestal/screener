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
// whatever each tile slot holds): a picture is four tile strips that share an
// RTP timestamp and are decoded one after another, and on the paced stream
// the last strip lands up to ~20 ms after the first. Showing each strip as it
// decodes put strips of two different pictures on screen (a dragged window
// sheared at the strip seams). So a frame that carries its RTP timestamp is
// STAGED, per picture (up to `picturesInFlight` pictures at once), and the
// presentable set (`snapshot`) changes once per picture: when a picture has
// all `tileCount` strips (it and any older staged picture leave the stage),
// when more than `picturesInFlight` pictures are staged (the oldest lost a
// strip for good: its tile is gated), or when `flushStaged` finds the oldest
// staged picture older than `stagingTimeout` (the pipeline ticker calls it,
// so the last picture before the screen goes static is never held back). A
// strip arriving after its picture was shown incomplete fills it in.
// Frames without a timestamp (tests, single-tile streams) commit at once.
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
    }

    struct Counters: Equatable, Sendable {
        var frames: [Int: Int] = [:]
        var errors = 0
        var decodeNanos: Int64 = 0
    }

    /// How long a partly-decoded picture may stay staged (see the header).
    /// Only a strip that is really gone (its tile gated, and no newer picture
    /// coming) should hit it: the paced stream stalls ALL tiles for up to
    /// ~100 ms about once a second, and a 50 ms timeout tore every one of them.
    static let stagingTimeout: Duration = .milliseconds(250)

    /// Staged pictures beyond this many commit their oldest as incomplete.
    static let picturesInFlight = 2

    private let lock = NSLock()
    private var frames: [Int: (buffer: CVPixelBuffer, seq: Int)] = [:]
    private struct StagedPicture {
        var ts: UInt32
        var strips: [Int: (buffer: CVPixelBuffer, seq: Int)]
        var since: ContinuousClock.Instant
    }
    /// Pictures being assembled, oldest RTP timestamp first.
    private var pending: [StagedPicture] = []
    /// The picture on screen and the tiles it was shown without.
    private var shownTimestamp: UInt32?
    private var shownMissing: Set<Int> = []
    private var partialCommits = 0
    private var version = 0
    private var tileCount = 4
    private var canvas: CGSize?
    private var counters = Counters()
    private var firstFrameSeen = false
    private var epoch = 0
    private var published = 0
    private var staleDropped = 0
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
            pending = []; shownTimestamp = nil; shownMissing = []
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
                pending = []; shownTimestamp = nil; shownMissing = []
                version += 1
            }
            if let canvas, canvas != self.canvas { self.canvas = canvas; version += 1 }
            return version != before ? _onChange : nil
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
        if let shown = shownTimestamp, !Self.isAfter(ts, shown) {
            // A strip of the picture on screen (shown incomplete after a
            // timeout) completes it in place; anything older is superseded.
            guard ts == shown, shownMissing.contains(f.tile) else { return false }
            frames[f.tile] = entry
            shownMissing.remove(f.tile)
            version += 1
            return true
        }
        if let i = pending.firstIndex(where: { $0.ts == ts }) {
            pending[i].strips[f.tile] = entry
        } else {
            let at = pending.firstIndex { Self.isAfter($0.ts, ts) } ?? pending.endIndex
            pending.insert(StagedPicture(ts: ts, strips: [f.tile: entry], since: now), at: at)
        }
        // The newest complete picture wins; older staged ones are never shown.
        if let done = pending.lastIndex(where: { $0.strips.count >= tileCount }) {
            commitLocked(through: done, now: now, reason: "complete")
            return true
        }
        // More pictures in flight than a decode/arrival hiccup explains: the
        // oldest lost a strip for good (its tile is gated), show it as it is.
        var changed = false
        while pending.count > Self.picturesInFlight {
            commitLocked(through: 0, now: now, reason: "superseded")
            changed = true
        }
        return changed
    }

    /// Commits a staged picture older than `timeout` (the pipeline ticker).
    func flushStaged(now: ContinuousClock.Instant = .now, timeout: Duration = VideoFrameStore.stagingTimeout) {
        let cb: (@Sendable () -> Void)? = lock.withLock {
            var changed = false
            while let oldest = pending.first, now - oldest.since >= timeout {
                commitLocked(through: 0, now: now, reason: "timeout")
                changed = true
            }
            return changed ? _onChange : nil
        }
        cb?()
    }

    /// Pictures shown with fewer than `tileCount` new strips (since the last call).
    func takePartialCommits() -> Int { lock.withLock { defer { partialCommits = 0 }; return partialCommits } }

    /// Shows staged picture `index`: its strips go over the older stored ones
    /// (merged with the strips of the older staged pictures it supersedes, so
    /// a tile missing from it keeps its newest strip), and it and every older
    /// staged picture leave the stage.
    private func commitLocked(through index: Int, now: ContinuousClock.Instant, reason: String) {
        let picture = pending[index]
        let partial = picture.strips.count < tileCount
        #if DEBUG
        if partial {
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
        pending.removeFirst(index + 1)
        if partial { partialCommits += 1 }
        version += 1
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

    /// nil when nothing changed since `version`.
    func snapshot(ifNewerThan seen: Int?) -> Snapshot? {
        lock.withLock {
            if let seen, seen == version { return nil }
            return Snapshot(version: version, frames: frames.mapValues(\.buffer), tileCount: tileCount, canvas: canvas)
        }
    }
}
