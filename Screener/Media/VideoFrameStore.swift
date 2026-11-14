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

    private let lock = NSLock()
    private var frames: [Int: (buffer: CVPixelBuffer, seq: Int)] = [:]
    private var version = 0
    private var tileCount = 4
    private var canvas: CGSize?
    private var counters = Counters()
    private var firstFrameSeen = false
    private var epoch = 0
    private var published = 0
    private var staleDropped = 0

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
                version += 1
            }
            if let canvas, canvas != self.canvas { self.canvas = canvas; version += 1 }
            return version != before ? _onChange : nil
        }
        cb?()
    }

    /// Stores `f` if it belongs to the current session (`epoch`) and is not
    /// older than the tile's stored picture.
    func publish(_ f: DecodedFrame, epoch: Int) {
        let (first, changed): ((@Sendable (CVPixelBuffer) -> Void)?, (@Sendable () -> Void)?) = lock.withLock {
            guard epoch == self.epoch else { staleDropped += 1; return (nil, nil) }   // a previous session
            if let cur = frames[f.tile], f.seq < cur.seq { return (nil, nil) }       // older than stored
            frames[f.tile] = (f.pixelBuffer, f.seq)
            version += 1
            published += 1
            counters.frames[f.tile, default: 0] += 1
            counters.decodeNanos += f.decodeTime.components.seconds * 1_000_000_000
                + f.decodeTime.components.attoseconds / 1_000_000_000
            guard !firstFrameSeen else { return (nil, _onChange) }
            firstFrameSeen = true
            return (_onFirstFrame, _onChange)
        }
        first?(f.pixelBuffer)
        changed?()
    }

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
