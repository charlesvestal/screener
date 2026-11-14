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

    /// Called once per session, from a VideoToolbox thread, with the first picture.
    var onFirstFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get { lock.withLock { _onFirstFrame } }
        set { lock.withLock { _onFirstFrame = newValue } }
    }
    private var _onFirstFrame: (@Sendable (CVPixelBuffer) -> Void)?

    /// Forget everything (new session).
    func reset() {
        lock.withLock {
            frames = [:]; version += 1; canvas = nil; tileCount = 4
            counters = Counters(); firstFrameSeen = false
        }
    }

    func configure(tileCount: Int? = nil, canvas: CGSize? = nil) {
        lock.withLock {
            if let tileCount, tileCount > 0, tileCount != self.tileCount {
                self.tileCount = tileCount
                frames = frames.filter { $0.key < tileCount }
                version += 1
            }
            if let canvas, canvas != self.canvas { self.canvas = canvas; version += 1 }
        }
    }

    func publish(_ f: DecodedFrame) {
        let first: (@Sendable (CVPixelBuffer) -> Void)? = lock.withLock {
            if let cur = frames[f.tile], f.seq < cur.seq { return nil }   // older than stored
            frames[f.tile] = (f.pixelBuffer, f.seq)
            version += 1
            counters.frames[f.tile, default: 0] += 1
            counters.decodeNanos += f.decodeTime.components.seconds * 1_000_000_000
                + f.decodeTime.components.attoseconds / 1_000_000_000
            guard !firstFrameSeen else { return nil }
            firstFrameSeen = true
            return _onFirstFrame
        }
        first?(f.pixelBuffer)
    }

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
