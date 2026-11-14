// Ported in part from iShareScreen src/isharescreen/proxy/session.py (the
// video RX path: group adoption → assembler → decoder, FIR on decoder error,
// _on_frame_published) and media/vtdecode.py (_on_decoded's throttled FIR)
// (AGPL-3.0).
//
// One session's video path: MediaTransport.video (its ONE consumer) →
// [DEBUG capture tap] → HEVCAssembler → VideoDecoder → VideoFrameStore.
//   * the assembler is (re)keyed to MediaTransport.activeVideoSSRCs whenever
//     a packet arrives from an SSRC outside the current group (adoption);
//   * a ~20 ms ticker calls assembler.tick even when no packet arrives (a
//     static screen sends nothing, and held AUs must still be released);
//   * .needKeyframe → MediaTransport.requestKeyframe (rate-limited there);
//   * .parameterSets → decoder (re)configure; .notHEVC → onNotHEVC;
//   * decoded pictures go straight from VideoToolbox's thread to the frame
//     store, and MediaTransport.notePublished() is called (throttled) so the
//     SSRC-adoption stall timer follows real decoded output;
//   * decode errors → assembler.noteDecodeError (throttled to one per 0.5 s,
//     as vtdecode._on_decoded), whose keyframe requests are sent at once. An
//     IRAP that fails, or an invalidated session, rebuilds the decoder (and
//     on the first IRAP, falls back to the next output mode);
//   * every 2 s: `video fps=… decode_ms=… tiles=[…]`.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

actor VideoPipeline {
    struct Hooks: Sendable {
        var activeSSRCs: @Sendable () async -> [UInt32]
        var requestKeyframe: @Sendable (UInt32) async -> Void
        var notePublished: @Sendable () async -> Void
        var onNotHEVC: @Sendable () async -> Void
    }

    nonisolated let store: VideoFrameStore
    private let hooks: Hooks
    private var assembler: HEVCAssembler?
    private var decoder: VideoDecoder!
    private var stopped = false
    private var lastErrorReport: ContinuousClock.Instant?
    private var lastRebuild: ContinuousClock.Instant?
    private var lastStatsLog = ContinuousClock.now
    private var fed = 0
    private var dropped = 0
    private let publishThrottle = PublishThrottle()

    init(store: VideoFrameStore, hooks: Hooks) {
        self.store = store
        self.hooks = hooks
        let throttle = publishThrottle
        let weakSelf = WeakBox<VideoPipeline>()
        self.decoder = VideoDecoder { event in
            switch event {
            case .frame(let f):
                store.publish(f)
                if throttle.shouldNotify() { Task { await hooks.notePublished() } }
            case .error(let tile, let don, let status, let irap):
                store.noteError()
                Task { await weakSelf.value?.decodeFailed(tile: tile, don: don, status: status, isIRAP: irap) }
            }
        }
        weakSelf.value = self
    }

    // MARK: - driving

    /// Consumes `media.video` until it ends or the task is cancelled; runs the
    /// assembler ticker alongside. `tap` (DEBUG capture) sees every packet first.
    nonisolated func run(_ video: AsyncStream<MediaPacket>, tap: (any VideoPacketTap)?) async {
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                await self.tick()
            }
        }
        for await p in video {
            if Task.isCancelled { break }
            tap?.write(p)
            await ingest(p)
        }
        ticker.cancel()
        tap?.close()
        await stop()
    }

    func ingest(_ p: MediaPacket) async {
        guard !stopped else { return }
        if assembler == nil || !assembler!.tileSSRCs.contains(p.ssrc) {
            let group = await hooks.activeSSRCs()
            guard !stopped, group.contains(p.ssrc) else { return }   // not (yet) an adopted tile
            if let a = assembler {
                if group != a.tileSSRCs {
                    Log.video.info("video: SSRC group changed → \(group.map { String(format: "%08x", $0) })")
                    a.resetForNewGroup(tileSSRCs: group)
                }
            } else {
                assembler = HEVCAssembler(tileSSRCs: group)
            }
            store.configure(tileCount: group.count)
        }
        await handle(assembler!.ingest(p))
    }

    func tick(now: ContinuousClock.Instant = .now) async {
        guard !stopped else { return }
        if let a = assembler { await handle(a.tick(now: now)) }
        if now - lastStatsLog >= .seconds(2) { logStats(now) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        decoder.invalidate()
        if let a = assembler { Log.video.info("video: stopped; assembler \(a.stats)") }
    }

    // MARK: - outputs

    private func handle(_ outputs: [AssemblerOutput]) async {
        for o in outputs {
            switch o {
            case .parameterSets(let vps, let sps, let pps):
                let info = HEVCSPSInfo(sps: sps)
                Log.video.info("video: parameter sets VPS \(vps.count)B SPS \(sps.count)B PPS x\(pps.count) "
                    + (info.map { "profile=\($0.profileIdc) chroma=\($0.chromaFormatIdc) "
                                  + "\($0.width)x\($0.height) \($0.bitDepthLuma)-bit" } ?? ""))
                do {
                    try decoder.configure(vps: vps, sps: sps, pps: pps)
                } catch {
                    Log.video.error("video: decoder configure failed: \(error)")
                }
            case .accessUnit(let au):
                guard decoder.isReady else { dropped += 1; continue }
                fed += 1
                let status = decoder.decode(au)
                if status != noErr {
                    store.noteError()
                    await decodeFailed(tile: au.tile, don: au.don, status: status, isIRAP: au.isIDR)
                }
            case .needKeyframe(let ssrc):
                await hooks.requestKeyframe(ssrc)
            case .notHEVC:
                Log.video.error("video: the server chose H.264 (no HEVC parameter sets); Screener decodes HEVC only")
                await hooks.onNotHEVC()
            }
        }
    }

    /// A frame failed (from the output handler, or a synchronous submit error).
    func decodeFailed(tile: Int, don: UInt16, status: OSStatus, isIRAP: Bool) async {
        guard !stopped, let a = assembler else { return }
        let now = ContinuousClock.now
        if status == kVTInvalidSessionErr || isIRAP {
            // Frames already queued on the old session fail too: one rebuild.
            if let last = lastRebuild, now - last < .milliseconds(500) { return }
            lastRebuild = now
            Log.video.error("video: decode failed status=\(status) tile=\(tile) don=\(don) irap=\(isIRAP); rebuilding")
            do {
                // The first IRAP failing on a fresh session = this output mode
                // cannot decode the stream (e.g. no 4:4:4 support): fall back.
                if isIRAP && !store.hasDecoded, try decoder.fallBack() {
                } else {
                    try decoder.rebuild()
                }
            } catch {
                Log.video.error("video: decoder rebuild failed: \(error)")
            }
            lastErrorReport = now
            await handle(a.noteDecodeError(tile: tile))
            return
        }
        // Concealment-class error: gate + keyframe, throttled (vtdecode: 0.5 s).
        if let last = lastErrorReport, now - last < .milliseconds(500) { return }
        lastErrorReport = now
        Log.video.error("video: decode error status=\(status) tile=\(tile) don=\(don); requesting keyframe")
        await handle(a.noteDecodeError(tile: tile))
    }

    private func logStats(_ now: ContinuousClock.Instant) {
        let span = now - lastStatsLog
        lastStatsLog = now
        let c = store.takeCounters()
        let total = c.frames.values.reduce(0, +)
        guard total > 0 || fed > 0 || c.errors > 0 else { return }
        let secs = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        let tiles = max(1, assembler?.tileSSRCs.count ?? 1)
        let perTile = (0..<tiles).map { String(format: "%.0f", Double(c.frames[$0] ?? 0) / secs) }
        let fps = Double(c.frames.values.max() ?? 0) / secs
        let ms = total > 0 ? Double(c.decodeNanos) / Double(total) / 1e6 : 0
        Log.video.info(String(format: "video fps=%.1f decode_ms=%.2f tiles=[%@] fed=%d errors=%d dropped=%d mode=%@",
                              fps, ms, perTile.joined(separator: ","), fed, c.errors, dropped,
                              decoder.mode.map { "\($0)" } ?? "-"))
        fed = 0
        dropped = 0
    }
}

/// The DEBUG capture tap (VideoCaptureWriter); owned by the video loop.
protocol VideoPacketTap: AnyObject {
    func write(_ p: MediaPacket)
    func close()
}

/// notePublished at most every 250 ms (the adoption stall is 2 s).
private final class PublishThrottle: @unchecked Sendable {   // state behind `lock`
    private let lock = NSLock()
    private var last: ContinuousClock.Instant?
    func shouldNotify() -> Bool {
        let now = ContinuousClock.now
        return lock.withLock {
            if let last, now - last < .milliseconds(250) { return false }
            last = now
            return true
        }
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {   // set once, before use
    weak var value: T?
}
