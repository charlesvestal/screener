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
//   * a new SSRC group or new parameter sets mid-session (a dynamic resize,
//     RFC §10.9) → VideoFrameStore.beginGroup: the last picture stays up
//     until the new stream's first one is complete;
//   * decoded pictures go straight from VideoToolbox's thread to the frame
//     store, and MediaTransport.notePublished() is called (throttled) so the
//     SSRC-adoption stall timer follows real decoded output;
//   * decode errors → DecoderRecoveryPolicy: assembler.noteDecodeError
//     (gate + keyframe, throttled to one per 0.5 s as vtdecode._on_decoded),
//     a rebuild for a failed IRAP or a session-level error, and a fallback to
//     the next output mode only for format-unsupported errors or after 3 IRAP
//     failures in a row in the same mode;
//   * frames are published with the store epoch this pipeline was created
//     under (late callbacks after a reset are dropped);
//   * the ticker also commits a picture whose strips stopped coming
//     (VideoFrameStore.flushStaged; strips are presented per picture);
//   * LTR acks (session._on_frame_published → _send_ltr_ack): APP name 5
//     carrying the RTP TIMESTAMP of a decoded picture (AVConference logs
//     "Received APP_LTRP_ACK timestamp=%u" and matches it against the frames
//     it sent; the reference sent the DON, which matches nothing). OFF by
//     default: SCREENER_LTR_ACK=1 acks the newest tile-0 picture,
//     SCREENER_FB_ACKALL=1 every tile's picture as the native viewer does
//     (one APP per marker). On 2026-11-18 (simulator, induced loss) the host
//     answered every FIR/PLI with an IDR with or without them — no LTR-based
//     repair was seen — and the bitrate was the same;
//   * loss recovery: HEVCAssembler's reference recovery (HEVCReferenceTracker)
//     releases every picture whose references were decoded and asks for a
//     keyframe only for a broken picture or a tile left without a decodable
//     one; SCREENER_REF_RECOVERY=0 goes back to IRAP-only gating;
//   * every 2 s: `video fps=… decode_ms=… tiles=[…] kbps=… au_avg=[…]
//     au_max=[…] idr=… partial=… shown=… merged=… skips=… fills=… wait_ms=…
//     ooo=… hold_ms=… pace_skips=… drawn=… age_ms=… rx_gap_max_ms=…
//     rx_gaps50=…` (AU payload bytes of what was fed; `partial` = pictures
//     shown after their strips stopped coming; then VideoFrameStore.
//     PresentStats; then the largest gap between video packet arrival stamps
//     and the gaps over 50 ms: in the simulator the receive path stalls
//     ~100 ms 2–3 times a second while the wire shows none, 2026-11-18).
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
        /// LTR acks: (RTP timestamp of a decoded picture, ack every picture).
        var ackLTR: (@Sendable (UInt32, Bool) async -> Void)? = nil
        /// A hard decoder failure (a rebuild or an output-mode fallback, not a
        /// concealment error): SessionCoordinator's TCP-fallback trigger
        /// (MediaFallbackPolicy: 3 within 10 s).
        var onHardFailure: (@Sendable () async -> Void)? = nil
    }

    /// Which decoded pictures are acknowledged (APP name 5 + DON on P+1).
    enum LTRAckMode: Sendable, Equatable {
        case off
        /// Reference: the newest tile-0 DON (SCREENER_LTR_ACK=1).
        case tile0
        /// Native viewer: one ack per decoded picture of every tile, right
        /// after it decodes (≈1–3 ms after the tile's marker packet; one 30-byte
        /// SRTCP APP per marker in the native capture). SCREENER_FB_ACKALL=1.
        case allTiles

        static func fromEnvironment(_ env: [String: String] = ExperimentEnv.current) -> LTRAckMode {
            if env["SCREENER_FB_ACKALL"] == "1" { return .allTiles }
            if env["SCREENER_LTR_ACK"] == "1" { return .tile0 }
            return .off
        }
    }

    static let ltrAckMode = LTRAckMode.fromEnvironment()

    /// SCREENER_REF_RECOVERY=0: IRAP-only loss recovery (the reference's),
    /// for A/B; SCREENER_LOSS_WAIT_MS: HEVCAssembler.Config.lossRecoveryWait.
    static let assemblerConfig: HEVCAssembler.Config = {
        let env = ExperimentEnv.current
        var c = HEVCAssembler.Config()
        if env["SCREENER_REF_RECOVERY"] == "0" { c.referenceRecovery = false }
        if let ms = env["SCREENER_LOSS_WAIT_MS"].flatMap(Int.init), ms > 0 { c.lossRecoveryWait = .milliseconds(ms) }
        Log.video.info("video: loss recovery \(c.referenceRecovery ? "by references (keyframe after \(c.lossRecoveryWait) without a decodable picture)" : "IRAP-only")")
        return c
    }()

    nonisolated let store: VideoFrameStore
    private let hooks: Hooks
    private var assembler: HEVCAssembler?
    private var decoder: VideoDecoder!
    private var stopped = false
    private var recovery = DecoderRecoveryPolicy()
    private var publishedAtLastFailure = 0
    private var lastStatsLog = ContinuousClock.now
    private var fed = 0
    private var dropped = 0
    private var interval = IntervalStats()
    private var lastArrival: ContinuousClock.Instant?
    private var rxGapMax: Duration = .zero
    private var rxGaps50 = 0
    private let publishThrottle = PublishThrottle()

    init(store: VideoFrameStore, hooks: Hooks, ltrAcks: LTRAckMode = VideoPipeline.ltrAckMode) {
        self.store = store
        self.hooks = hooks
        let throttle = publishThrottle
        let weakSelf = WeakBox<VideoPipeline>()
        let epoch = store.currentEpoch
        let ackLTR = ltrAcks != .off ? hooks.ackLTR : nil
        let ackAll = ltrAcks == .allTiles
        let lastTS = LatestTimestamp()
        if ackLTR != nil { Log.video.info("video: LTR acks ON (RTP timestamp of \(ackAll ? "every tile" : "each tile-0") picture decoded)") }
        self.decoder = VideoDecoder { event in
            switch event {
            case .frame(let f):
                store.publish(f, epoch: epoch)
                if throttle.shouldNotify() { Task { await hooks.notePublished() } }
                // Tasks may run out of order: each sends the newest timestamp at that moment.
                if let ts = f.rtpTimestamp, let ackLTR {
                    if ackAll {
                        Task { await ackLTR(ts, true) }
                    } else if f.tile == 0 {
                        lastTS.set(ts)
                        Task { if let ts = lastTS.get() { await ackLTR(ts, false) } }
                    }
                }
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
        if let last = lastArrival, p.arrival > last {
            let gap = p.arrival - last
            rxGapMax = max(rxGapMax, gap)
            if gap > .milliseconds(50) { rxGaps50 += 1 }
        }
        lastArrival = max(lastArrival ?? p.arrival, p.arrival)
        if assembler == nil || !assembler!.tileSSRCs.contains(p.ssrc) {
            let group = await hooks.activeSSRCs()
            guard !stopped, group.contains(p.ssrc) else { return }   // not (yet) an adopted tile
            if let a = assembler {
                if group != a.tileSSRCs {
                    // A resize (RFC §10.9) or a server restart: re-harvest the
                    // parameter sets, re-root on the new IDR, and keep the
                    // last picture up until the new stream's first one.
                    Log.video.info("video: SSRC group changed → \(group.map { String(format: "%08x", $0) })")
                    a.resetForNewGroup(tileSSRCs: group)
                    store.beginGroup(tileCount: group.count, afterSeq: VideoDecoder.lastSequence)
                }
            } else {
                assembler = HEVCAssembler(tileSSRCs: group, config: Self.assemblerConfig)
                store.configure(tileCount: group.count)
            }
        }
        await handle(assembler!.ingest(p))
    }

    func tick(now: ContinuousClock.Instant = .now) async {
        guard !stopped else { return }
        if let a = assembler { await handle(a.tick(now: now)) }
        store.flushStaged(now: now)
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
                    let wasConfigured = decoder.formatDescription != nil
                    if try decoder.configure(vps: vps, sps: sps, pps: pps) {
                        recovery.noteModeChanged()
                        // New parameter sets mid-session (a resize keeps or
                        // changes the group): pictures from here on are the
                        // new stream's.
                        if wasConfigured { store.beginGroup(tileCount: nil, afterSeq: VideoDecoder.lastSequence) }
                    }
                } catch {
                    Log.video.error("video: decoder configure failed: \(error)")
                }
            case .accessUnit(let au):
                guard decoder.isReady else { dropped += 1; continue }
                fed += 1
                interval.note(au)
                let status = decoder.decode(au)
                if status != noErr {
                    store.noteError()
                    await decodeFailed(tile: au.tile, don: au.don, status: status, isIRAP: au.isIDR)
                }
            case .needKeyframe(let ssrc):
                #if DEBUG
                if let ms = Int(ExperimentEnv.current["SCREENER_FIR_DELAY_MS"] ?? ""), ms > 0 {
                    // Experiment: give the host `ms` to recover on its own (LTR) first.
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(ms))
                        guard let self, await self.stillWaiting() else { return }
                        Log.video.info("video: FIR after \(ms) ms delay (ssrc \(String(format: "%08x", ssrc)))")
                        await self.hooks.requestKeyframe(ssrc)
                    }
                    continue
                }
                #endif
                await hooks.requestKeyframe(ssrc)
            case .notHEVC:
                Log.video.error("video: the server chose H.264 (no HEVC parameter sets); Screener decodes HEVC only")
                await hooks.onNotHEVC()
            }
        }
    }

    private func stillWaiting() -> Bool { !(assembler?.tilesAwaitingIDR.isEmpty ?? true) }

    /// A frame failed (from the output handler, or a synchronous submit error).
    func decodeFailed(tile: Int, don: UInt16, status: OSStatus, isIRAP: Bool) async {
        guard !stopped, let a = assembler else { return }
        let published = store.totalPublished
        let decodedSince = published > publishedAtLastFailure
        publishedAtLastFailure = published
        let action = recovery.decide(status: status, isIRAP: isIRAP, decodedSinceLastFailure: decodedSince,
                                     now: .now)
        switch action {
        case .ignore:
            return
        case .requestKeyframe:
            Log.video.error("video: decode error status=\(status) tile=\(tile) don=\(don); requesting keyframe")
        case .rebuild:
            Log.video.error("video: decode failed status=\(status) tile=\(tile) don=\(don) irap=\(isIRAP); "
                            + "rebuilding (mode \(decoder.mode.map { "\($0)" } ?? "-"), "
                            + "IRAP failures in a row: \(recovery.consecutiveIRAPFailures))")
            do { try decoder.rebuild() } catch { Log.video.error("video: decoder rebuild failed: \(error)") }
            await hooks.onHardFailure?()
        case .fallBack:
            let from = decoder.mode.map { "\($0)" } ?? "-"
            Log.video.error("video: !!! OUTPUT MODE FALLBACK from \(from): status=\(status) tile=\(tile) "
                            + "irap=\(isIRAP) (format unsupported, or \(DecoderRecoveryPolicy.fallbackAfterIRAPFailures) "
                            + "IRAP failures in a row with nothing decoded) !!!")
            do {
                if try !decoder.fallBack() {
                    Log.video.error("video: no output mode left to fall back to; rebuilding \(from)")
                    try decoder.rebuild()
                }
            } catch {
                Log.video.error("video: decoder fallback failed: \(error)")
            }
            recovery.noteModeChanged()
            await hooks.onHardFailure?()
        }
        await handle(a.noteDecodeError(tile: tile, don: don))
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
        Log.video.info(String(format: "video fps=%.1f decode_ms=%.2f tiles=[%@] fed=%d errors=%d dropped=%d mode=%@ %@ partial=%d %@ rx_gap_max_ms=%d rx_gaps50=%d",
                              fps, ms, perTile.joined(separator: ","), fed, c.errors, dropped,
                              decoder.mode.map { "\($0)" } ?? "-", interval.summary(seconds: secs, tiles: tiles),
                              store.takePartialCommits(), store.takePresentStats().summary, rxGapMax.ms, rxGaps50))
        rxGapMax = .zero
        rxGaps50 = 0
        fed = 0
        dropped = 0
        interval = IntervalStats()
    }
}

/// Per-interval AU sizes for the stats line (fed AUs only).
struct IntervalStats: Equatable {
    var bytes = 0
    var idrs = 0
    var count: [Int: Int] = [:]
    var total: [Int: Int] = [:]
    var largest: [Int: Int] = [:]

    mutating func note(_ au: AccessUnit) {
        let n = au.nalUnits.reduce(0) { $0 + $1.count }
        bytes += n
        if au.isIDR { idrs += 1 }
        count[au.tile, default: 0] += 1
        total[au.tile, default: 0] += n
        largest[au.tile] = max(largest[au.tile] ?? 0, n)
    }

    /// `kbps=… au_avg=[…] au_max=[…] idr=…` (sizes in bytes, per tile).
    func summary(seconds: Double, tiles: Int) -> String {
        let kbps = seconds > 0 ? Double(bytes) * 8 / seconds / 1000 : 0
        let avg = (0..<tiles).map { t in String((total[t] ?? 0) / max(1, count[t] ?? 0)) }
        let mx = (0..<tiles).map { String(largest[$0] ?? 0) }
        return String(format: "kbps=%.0f au_avg=[%@] au_max=[%@] idr=%d", kbps,
                      avg.joined(separator: ","), mx.joined(separator: ","), idrs)
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

/// The newest decoded tile-0 RTP timestamp (VideoToolbox thread → ack tasks).
private final class LatestTimestamp: @unchecked Sendable {   // `value` behind `lock`
    private let lock = NSLock()
    private var value: UInt32?
    func set(_ v: UInt32) { lock.withLock { value = v } }
    func get() -> UInt32? { lock.withLock { value } }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {   // set once, before use
    weak var value: T?
}
