// Ported from iShareScreen src/isharescreen/proxy/session.py (AGPL-3.0):
// _connect_internal (UDP bind), _bind_udp, _punch_firewall /
// _firewall_punch_loop, _negotiate_and_burst / _drain_socket_into and
// burst.gather_initial_burst (SSRC-group lock only), _video_process_loop,
// _ctrl_drain_loop / _ctrl_process_loop, _note_unknown_ssrc, _tx_loop,
// _send_heartbeat, _send_rr_and_maybe_sr, _send_fir_for_tile, _send_ltr_ack.
//
// The HP media plane: two UDP flows next to the control port P.
//   P+1 (5901)  video RTP (PT 100, HEVC, four tile SSRCs) + video RTCP (rtcp-mux)
//   P   (5900)  audio RTP (PT 101, AAC-ELD) + RTCP (rtcp-mux)
// Ports are symmetric: ScreensharingAgent binds <its TCP-local IP>:P / P+1 and
// connects those sockets to <our TCP-peer IP>:P / P+1 (netstat during a live
// reference session, 2026-11-14), so we bind the same local port numbers and
// connect each flow to the matching server port. The default channel is a
// BSD socket (SocketTransport.swift): NWConnection ignores the required local
// endpoint in the simulator. NWDatagramChannel is kept for comparison.
//
// Keys (negotiation.py:818): receive with the server→viewer S blobs
// (videoKeyS on P+1, audioKeyS on P); send with the viewer→server V blobs.
// What the reference sends, all to port P:
//   * every 0.5 s: PT 101 SRTP keepalive `00683400` (audioKeyV, our audio SSRC)
//   * every 0.5 s: SRTCP RR (videoKeyV) over the active video SSRCs, with an
//     empty SR prepended every 10th tick (5 s)
//   * keyframe request: RR + FIR(206, seq = tick & 0xFF) + PLI + legacy FIR(192)
//     compound, rate-limited to one per SSRC per 0.25 s
// and, on P+1, APP LTR acks (Task 13 drives those).
//
// Deviations (deliberate):
//   * The reference's ctrl process loop tests `200 <= pkt[1] & 0x7F <= 207`,
//     which can never be true, so it sends every RTCP packet to the audio SRTP
//     decryptor (where it fails auth) and never records server SRs. Here RTCP
//     is PT 200–207 after masking the marker (72...79) on BOTH ports, and is
//     unprotected with that port's S key, falling back to the other S key.
//   * Burst handling ports only the SSRC-group lock of gather_initial_burst
//     (≥100 packets or 2 s, then 0.3 s settle). The param-set check needs the
//     HEVC depacketizer (Task 13); until then a burst counts as starved when
//     fewer than 20 video packets authenticated (the reference's
//     "no-video-rtp" reason). The full-reconnect retry lives in
//     SessionCoordinator.
//   * "Recently published" (the adoption stall guard) is fed by packets on the
//     active group until a decoder calls `notePublished()` (Task 13).
//   * forget_ssrcs_except is not called: the reference defines it but never
//     uses it; the blacklist does that job.
import Foundation
import Network

/// One authenticated, decrypted RTP packet.
struct MediaPacket: Sendable, Equatable {
    let ssrc: UInt32
    let seq: UInt16
    let timestamp: UInt32
    let marker: Bool
    let payloadType: UInt8
    let payload: Data
    let arrival: ContinuousClock.Instant
}

/// Seam over one connected UDP flow, so tests can inject datagrams.
protocol DatagramChannel: AnyObject, Sendable {
    /// Begins receiving. `onReceive` is called once per datagram, in arrival
    /// order; `onEvent` carries diagnostics (state changes, errors).
    func start(onReceive: @escaping @Sendable (Data) -> Void, onEvent: @escaping @Sendable (String) -> Void)
    func send(_ datagram: Data)
    func cancel()
}

// MARK: - SSRC group tracking

/// Port of session._note_unknown_ssrc (minus the decoder restart): which
/// video SSRC group is live, and when to switch to a fresh one.
struct SSRCGroupTracker: Sendable {
    var groupSize = 4                          // tiles_per_frame() we offered
    var threshold = 5                          // _DYNAMIC_SSRC_PACKET_THRESHOLD
    var stall: Duration = .seconds(2)          // _SSRC_ADOPT_STALL_S

    /// Sorted (tile order).
    private(set) var active: [UInt32] = []
    private(set) var blacklist: Set<UInt32> = []
    private(set) var lastPublish: ContinuousClock.Instant?

    init(groupSize: Int = 4, threshold: Int = 5, stall: Duration = .seconds(2)) {
        self.groupSize = groupSize
        self.threshold = threshold
        self.stall = stall
    }

    /// The burst's primary group becomes the map directly, without going
    /// through adoption (gather_initial_burst._refresh_ssrc_map).
    mutating func lock(_ group: Set<UInt32>) { active = group.sorted() }

    mutating func notePublish(at now: ContinuousClock.Instant) { lastPublish = now }

    /// Returns the newly adopted group (sorted) when `ssrc`'s arrival tips a
    /// fresh consecutive group into adoption, else nil.
    mutating func noteUnknown(_ ssrc: UInt32, counts: [UInt32: Int], now: ContinuousClock.Instant) -> [UInt32]? {
        if active.contains(ssrc) { return nil }
        // Only switch when there is no working group or it has gone quiet.
        if !active.isEmpty, let last = lastPublish, now - last < stall { return nil }
        let activeSet = Set(active)
        let candidates = counts.filter { !activeSet.contains($0.key) && !blacklist.contains($0.key) && $0.value >= threshold }
            .keys.sorted()
        let want = max(1, groupSize)
        guard candidates.count >= want else { return nil }
        // Apple emits `want` CONSECUTIVE SSRCs per group; take the first
        // complete run so two concurrent groups never mix.
        var newGroup: [UInt32]?
        var run = [candidates[0]]
        if want == 1 {
            newGroup = run
        } else {
            for s in candidates.dropFirst() {
                if s &- run[run.count - 1] <= 1 && run.count < want {
                    run.append(s)
                    if run.count == want { newGroup = run; break }
                } else {
                    run = [s]
                }
            }
        }
        guard let newGroup, newGroup != active else { return nil }
        blacklist.formUnion(active)
        active = newGroup
        lastPublish = now   // grace window before another adoption
        return newGroup
    }
}

// MARK: - MediaTransport

actor MediaTransport {
    enum Flow: String, Sendable { case video, audio }

    struct Config: Sendable {
        var host: String
        /// The control port P. Video is P+1, audio is P.
        var controlPort: UInt16 = 5900
        /// Local IPv4 address to bind (nil = any). Must be the address the
        /// control TCP originates from: the server sends media to that.
        var localAddress: String?
        /// Bind the same local port numbers as the server's (reference _bind_udp).
        var symmetricLocalPorts = true

        var videoPort: UInt16 { controlPort &+ 1 }
        var audioPort: UInt16 { controlPort }
        func remotePort(_ flow: Flow) -> UInt16 { flow == .video ? videoPort : audioPort }
    }

    struct Activation: Sendable {
        var keys: NegotiationKeys
        /// Our SSRCs from the offers (extract_offer_ssrc).
        var ourVideoSSRC: UInt32?
        var ourAudioSSRC: UInt32?
        var tilesPerGroup = Int(MediaOffer.tilesPerFrame)
    }

    struct Tuning: Sendable {
        var txInterval: Duration = .milliseconds(500)       // _TX_INTERVAL_S
        var srEveryNTicks = 10                              // _RTCP_SR_EVERY_N_TICKS
        var statsEveryNTicks = 4                            // _TX_PROFILE_EVERY_N_TICKS (2 s)
        var punchInterval: Duration = .milliseconds(100)    // _firewall_punch_loop
        var burstMinPackets = 100                           // gather_initial_burst min_packets (HEVC)
        var burstDeadline: Duration = .seconds(2)           // _drain_socket_into max_seconds (HEVC)
        var burstSettle: Duration = .milliseconds(300)      // settle_seconds
        var burstStarvedBelow = 20                          // "no-video-rtp" if fewer packets
        var adoptThreshold = 5                              // _DYNAMIC_SSRC_PACKET_THRESHOLD
        var adoptStall: Duration = .seconds(2)              // _SSRC_ADOPT_STALL_S
        var keyframeMinInterval: Duration = .milliseconds(250) // _FIR_MIN_INTERVAL_S
        var rawBufferLimit = 16_384                         // _UDP_DRAIN_QUEUE_MAX
    }

    struct Stats: Sendable, Equatable {
        var videoDatagrams = 0, audioDatagrams = 0
        var videoBytes = 0, audioBytes = 0
        var videoPackets = 0, audioPackets = 0, rtcpPackets = 0
        var authFailures = 0, rtcpAuthFailures = 0
        var droppedDatagrams = 0
        var punchesSent = 0, keepalivesSent = 0, reportsSent = 0, keyframeRequestsSent = 0, ltrAcksSent = 0
        var serverSRs = 0
        var activeVideoSSRCs: [UInt32] = []
        var ssrcCounts: [UInt32: Int] = [:]
    }

    enum BurstOutcome: Sendable, Equatable {
        case started(packets: Int, group: [UInt32])
        case starved(packets: Int)
    }

    typealias ChannelFactory = @Sendable (_ flow: Flow, _ config: Config) -> DatagramChannel

    nonisolated let video: AsyncStream<MediaPacket>
    nonisolated let audio: AsyncStream<MediaPacket>
    private let videoOut: AsyncStream<MediaPacket>.Continuation
    private let audioOut: AsyncStream<MediaPacket>.Continuation

    private let config: Config
    private let tuning: Tuning
    private let makeChannel: ChannelFactory
    private let clock = ContinuousClock()

    private var channels: [Flow: DatagramChannel] = [:]
    private var pumps: [Task<Void, Never>] = []
    private var punchTask: Task<Void, Never>?
    private var txTask: Task<Void, Never>?
    private var burstTimer: Task<Void, Never>?
    private var isOpen = false
    private var isClosed = false

    // Before activation: raw datagrams wait here (reference: burst drained into a list).
    private var pending: [(Flow, Data, ContinuousClock.Instant)] = []

    // After activation.
    private var activation: Activation?
    private var videoDecryptor: SRTPDecryptor?
    private var audioDecryptor: SRTPDecryptor?
    private var rtcpDecryptors: [Flow: [SRTCPDecryptor]] = [:]
    private var rtcpKeyLogged: Set<Flow> = []
    private var keepaliveEncryptor: SRTPEncryptor?
    private var rtcpEncryptor: SRTCPEncryptor?
    private var serverSR: [UInt32: RTCP.SRInfo] = [:]
    private var tick = 0
    private var lastKeyframeRequest: [UInt32: ContinuousClock.Instant] = [:]
    private var lastLTRAcked: UInt32?
    private var decoderDrivesPublish = false

    // Burst / SSRC group.
    private var tracker: SSRCGroupTracker
    private var groupLocked = false
    private var burstVideo: [MediaPacket] = []
    private var burstResult: BurstOutcome?
    private var burstWaiters: [CheckedContinuation<BurstOutcome, Never>] = []

    private var counters = Stats()
    private let drops = DropCounter()

    init(config: Config, tuning: Tuning = Tuning(), channelFactory: ChannelFactory? = nil) {
        self.config = config
        self.tuning = tuning
        self.makeChannel = channelFactory ?? { flow, cfg in SocketDatagramChannel.make(flow: flow, config: cfg) }
        self.tracker = SSRCGroupTracker(threshold: tuning.adoptThreshold, stall: tuning.adoptStall)
        (video, videoOut) = AsyncStream.makeStream(of: MediaPacket.self, bufferingPolicy: .bufferingNewest(4096))
        (audio, audioOut) = AsyncStream.makeStream(of: MediaPacket.self, bufferingPolicy: .bufferingNewest(1024))
    }

    // MARK: lifecycle

    /// Binds both flows and starts receiving + hole-punching. Call before the
    /// control handshake so the session-start burst (which lands within
    /// ~100 ms of the 0x1c answer) is never dropped.
    func open() {
        guard !isOpen, !isClosed else { return }
        isOpen = true
        let localDesc = config.localAddress ?? "*"
        Log.media.info("UDP bind local=\(localDesc):\(config.audioPort)/\(config.videoPort) " +
                       "-> \(config.host):\(config.audioPort)/\(config.videoPort)")
        for flow in [Flow.video, .audio] {
            let channel = makeChannel(flow, config)
            channels[flow] = channel
            let (stream, cont) = AsyncStream.makeStream(of: (Data, ContinuousClock.Instant).self,
                                                        bufferingPolicy: .bufferingNewest(tuning.rawBufferLimit))
            let drops = drops
            let clock = clock
            channel.start(onReceive: { data in
                if case .dropped = cont.yield((data, clock.now)) { drops.increment() }
            }, onEvent: { msg in
                Log.media.info("udp \(flow.rawValue): \(msg)")
            })
            pumps.append(Task { [weak self] in
                for await (data, at) in stream {
                    guard let self else { return }
                    await self.ingest(flow, data, at)
                }
            })
            finishers.append { cont.finish() }
        }
        let punchEvery = tuning.punchInterval
        punchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.punch()
                try? await Task.sleep(for: punchEvery)
            }
        }
    }

    private var finishers: [@Sendable () -> Void] = []

    /// Installs the negotiated keys, processes everything buffered so far and
    /// starts the keepalive / RTCP loop and the burst SSRC-group lock.
    func activate(_ a: Activation) throws {
        guard !isClosed, activation == nil else { return }
        if !isOpen { open() }
        let k = a.keys
        videoDecryptor = try SRTPDecryptor(blob: k.videoKeyS)
        audioDecryptor = try SRTPDecryptor(blob: k.audioKeyS)
        let videoRTCP = try SRTCPDecryptor(blob: k.videoKeyS)
        let audioRTCP = try SRTCPDecryptor(blob: k.audioKeyS)
        rtcpDecryptors = [.video: [videoRTCP, audioRTCP], .audio: [audioRTCP, videoRTCP]]
        rtcpEncryptor = try SRTCPEncryptor(blob: k.videoKeyV)
        if let s = a.ourAudioSSRC { keepaliveEncryptor = try SRTPEncryptor(blob: k.audioKeyV, ssrc: s) }
        tracker = SSRCGroupTracker(groupSize: a.tilesPerGroup, threshold: tuning.adoptThreshold, stall: tuning.adoptStall)
        activation = a
        Log.media.info("media keys installed; ourSSRC video=\(hex(a.ourVideoSSRC)) audio=\(hex(a.ourAudioSSRC)); " +
                       "buffered=\(pending.count)")

        let buffered = pending
        pending = []
        for (flow, data, at) in buffered { process(flow, data, at) }

        let deadline = tuning.burstDeadline
        burstTimer = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            await self?.burstDeadlineReached()
        }
        let interval = tuning.txInterval
        txTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.txTick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Resolves once the session-start burst has been judged (SSRC group
    /// locked, or starved).
    func burstOutcome() async -> BurstOutcome {
        if let burstResult { return burstResult }
        return await withCheckedContinuation { burstWaiters.append($0) }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        punchTask?.cancel(); txTask?.cancel(); burstTimer?.cancel()
        for c in channels.values { c.cancel() }
        channels = [:]
        for f in finishers { f() }
        finishers = []
        for p in pumps { p.cancel() }
        pumps = []
        videoOut.finish(); audioOut.finish()
        resolveBurst(.starved(packets: counters.videoPackets), ifUnresolvedOnly: true)
        Log.media.info("media transport closed: \(statsLine())")
    }

    // MARK: public API

    var activeVideoSSRCs: [UInt32] { tracker.active }

    var stats: Stats {
        var s = counters
        s.droppedDatagrams = drops.value
        s.activeVideoSSRCs = tracker.active
        s.ssrcCounts = videoDecryptor?.ssrcCounts ?? [:]
        return s
    }

    /// The decoder takes over the adoption stall signal (session._on_frame_published).
    func notePublished() {
        decoderDrivesPublish = true
        tracker.notePublish(at: clock.now)
    }

    /// Keyframe request for one tile SSRC, the reference's default variant:
    /// compound RR + AVPF FIR (PT 206) + PLI + legacy FIR (PT 192), sent to P.
    @discardableResult
    func requestKeyframe(ssrc: UInt32) -> Bool {
        guard let a = activation, let sender = a.ourVideoSSRC, let enc = rtcpEncryptor,
              let channel = channels[.audio] else { return false }
        let now = clock.now
        if let last = lastKeyframeRequest[ssrc], now - last < tuning.keyframeMinInterval { return false }
        lastKeyframeRequest[ssrc] = now
        let seq = UInt8(truncatingIfNeeded: tick)
        let compound = RTCP.compoundWithRR(senderSSRC: sender,
                                           payload: RTCP.fir(senderSSRC: sender, targetSSRC: ssrc, seq: seq)
                                               + RTCP.pli(senderSSRC: sender, mediaSSRC: ssrc)
                                               + RTCP.firLegacy(targetSSRC: ssrc))
        guard let wire = try? enc.protect(compound) else { return false }
        channel.send(wire)
        counters.keyframeRequestsSent += 1
        return true
    }

    /// session._send_ltr_ack: APP LTR ack carrying the DONL, on the video port.
    func sendLTRAck(donl: UInt32) {
        guard donl != lastLTRAcked, let sender = activation?.ourVideoSSRC, let enc = rtcpEncryptor,
              let channel = channels[.video],
              let wire = try? enc.protect(RTCP.appLTR(senderSSRC: sender, ltrID: donl)) else { return }
        lastLTRAcked = donl
        channel.send(wire)
        counters.ltrAcksSent += 1
    }

    // MARK: receive path

    private func ingest(_ flow: Flow, _ data: Data, _ at: ContinuousClock.Instant) {
        guard !isClosed else { return }
        switch flow {
        case .video: counters.videoDatagrams += 1; counters.videoBytes += data.count
        case .audio: counters.audioDatagrams += 1; counters.audioBytes += data.count
        }
        guard activation != nil else {
            if pending.count < tuning.rawBufferLimit { pending.append((flow, data, at)) } else { drops.increment() }
            return
        }
        process(flow, data, at)
    }

    private func process(_ flow: Flow, _ data: Data, _ at: ContinuousClock.Instant) {
        if RTCP.isRTCP(data) {
            handleRTCP(flow, data)
            return
        }
        let decryptor = flow == .video ? videoDecryptor : audioDecryptor
        guard let decryptor, let out = decryptor.decrypt(data) else {
            counters.authFailures += 1
            return
        }
        let h = [UInt8](out.header)
        let pkt = MediaPacket(ssrc: out.ssrc, seq: out.seq,
                              timestamp: UInt32(h[4]) << 24 | UInt32(h[5]) << 16 | UInt32(h[6]) << 8 | UInt32(h[7]),
                              marker: h[1] & 0x80 != 0, payloadType: h[1] & 0x7F, payload: out.payload, arrival: at)
        switch flow {
        case .audio:
            counters.audioPackets += 1
            audioOut.yield(pkt)
        case .video:
            counters.videoPackets += 1
            handleVideo(pkt)
        }
    }

    private func handleVideo(_ pkt: MediaPacket) {
        guard groupLocked else {
            if burstVideo.count < tuning.rawBufferLimit { burstVideo.append(pkt) }
            if counters.videoPackets >= tuning.burstMinPackets { scheduleBurstLock() }
            return
        }
        if tracker.active.contains(pkt.ssrc) {
            if !decoderDrivesPublish { tracker.notePublish(at: pkt.arrival) }
            videoOut.yield(pkt)
            return
        }
        let counts = videoDecryptor?.ssrcCounts ?? [:]
        if let adopted = tracker.noteUnknown(pkt.ssrc, counts: counts, now: clock.now) {
            Log.media.info("adopting fresh SSRC group: \(adopted.map(hex))")
            for s in adopted { requestKeyframe(ssrc: s) }
            videoOut.yield(pkt)
        }
    }

    private var burstLockScheduled = false

    private func scheduleBurstLock() {
        guard !burstLockScheduled else { return }
        burstLockScheduled = true
        burstTimer?.cancel()
        let settle = tuning.burstSettle
        burstTimer = Task { [weak self] in
            try? await Task.sleep(for: settle)
            await self?.lockBurstGroup()
        }
    }

    private func burstDeadlineReached() { scheduleBurstLock() }

    /// gather_initial_burst: the primary (most-packets) consecutive group
    /// becomes the tile map; buffered packets of that group are released in
    /// arrival order, everything else from the burst is dropped.
    private func lockBurstGroup() {
        guard !groupLocked, !isClosed else { return }
        groupLocked = true
        punchTask?.cancel()   // the reference punches until the burst is in
        punchTask = nil
        let total = counters.videoPackets
        let primary = videoDecryptor?.getPrimarySSRCGroup(tier: 0, groupSize: tracker.groupSize) ?? []
        Log.media.info("initial-burst packets: \(total)")
        if total < tuning.burstStarvedBelow || primary.isEmpty {
            Log.media.error("burst starved (no-video-rtp, \(total) pkts)")
            burstVideo = []
            resolveBurst(.starved(packets: total))
            return
        }
        tracker.lock(primary)
        tracker.notePublish(at: clock.now)
        let group = tracker.active
        Log.media.info("SSRC group (tier 0): \(group.map(hex))")
        if let declared = activation?.tilesPerGroup, declared != group.count {
            Log.media.info("tile count: burst observed \(group.count), offered \(declared)")
        }
        for p in burstVideo where primary.contains(p.ssrc) { videoOut.yield(p) }
        burstVideo = []
        resolveBurst(.started(packets: total, group: group))
    }

    private func resolveBurst(_ outcome: BurstOutcome, ifUnresolvedOnly: Bool = false) {
        if ifUnresolvedOnly, burstResult != nil { return }
        burstResult = outcome
        let waiters = burstWaiters
        burstWaiters = []
        for w in waiters { w.resume(returning: outcome) }
    }

    private func handleRTCP(_ flow: Flow, _ data: Data) {
        for (i, dec) in (rtcpDecryptors[flow] ?? []).enumerated() {
            guard let plain = dec.unprotect(data) else { continue }
            counters.rtcpPackets += 1
            if rtcpKeyLogged.insert(flow).inserted {
                let key = (flow == .video) == (i == 0) ? "videoKeyS" : "audioKeyS"
                Log.media.info("SRTCP on \(flow.rawValue) port authenticates with \(key)")
            }
            for sr in RTCP.parseSRArrivals(plain) {
                serverSR[sr.ssrc] = RTCP.SRInfo(lsr: sr.ntpMid32, arrival: sr.arrival)
                counters.serverSRs += 1
            }
            return
        }
        counters.rtcpAuthFailures += 1
    }

    // MARK: send path

    /// _punch_firewall: one 1-byte datagram out of each flow to the server's
    /// matching port (too short to be RTP, so the host drops it).
    private func punch() {
        for flow in [Flow.audio, .video] {
            guard let c = channels[flow] else { continue }
            c.send(Data([0x00]))
            counters.punchesSent += 1
        }
    }

    /// One _tx_loop tick: heartbeat, RR (+SR every 10th), stats every 4th.
    private func txTick() {
        guard !isClosed else { return }
        tick += 1
        sendHeartbeat()
        sendReport()
        if tick % tuning.statsEveryNTicks == 0 { Log.media.info(statsLine()) }
    }

    private func sendHeartbeat() {
        guard let enc = keepaliveEncryptor, let channel = channels[.audio],
              let wire = try? enc.encrypt(Data([0x00, 0x68, 0x34, 0x00]), pt: 101) else { return }
        channel.send(wire)
        counters.keepalivesSent += 1
    }

    private func sendReport() {
        guard let sender = activation?.ourVideoSSRC, let enc = rtcpEncryptor, let channel = channels[.audio] else { return }
        let sources = tracker.active
        let states = videoDecryptor?.stateSnapshot() ?? [:]
        var stats: [UInt32: RTCP.SourceStats] = [:]
        for s in sources {
            let st = states[s]
            stats[s] = RTCP.SourceStats(maxSeq: st?.maxSeq ?? 0, roc: st?.roc ?? 0)
        }
        var rr = RTCP.receiverReport(senderSSRC: sender, sources: sources, stats: stats, srData: serverSR)
        if tick % tuning.srEveryNTicks == 0 { rr = RTCP.emptySR(senderSSRC: sender) + rr }
        guard let wire = try? enc.protect(rr) else { return }
        channel.send(wire)
        counters.reportsSent += 1
    }

    private func statsLine() -> String {
        let s = stats
        return "M3 udp video pkts=\(s.videoPackets) audio pkts=\(s.audioPackets) ssrcs=[\(s.activeVideoSSRCs.map(hex).joined(separator: ","))]"
            + " rtcp=\(s.rtcpPackets) raw=\(s.videoDatagrams)/\(s.audioDatagrams) authfail=\(s.authFailures)"
            + " rtcpfail=\(s.rtcpAuthFailures) drop=\(s.droppedDatagrams) sr=\(s.serverSRs)"
            + " tx ka=\(s.keepalivesSent) rr=\(s.reportsSent) fir=\(s.keyframeRequestsSent) punch=\(s.punchesSent)"
    }
}

private func hex(_ v: UInt32) -> String { String(format: "0x%08x", v) }
private func hex(_ v: UInt32?) -> String { v.map(hex) ?? "nil" }

/// Datagrams dropped because a flow's receive buffer was full.
private final class DropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// MARK: - Network.framework channel

/// A UDP flow as a connected `NWConnection` (IPv4, like the reference's
/// AF_INET sockets) bound to a fixed local port. The server sends from the
/// same port we send to, so a connected flow sees all of its traffic.
final class NWDatagramChannel: DatagramChannel, @unchecked Sendable {
    // `lock` guards connection / closed / handlers / restarts.
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let label: String
    private let remote: NWEndpoint
    private let local: NWEndpoint?
    private var connection: NWConnection?
    private var closed = false
    private var onReceive: (@Sendable (Data) -> Void)?
    private var onEvent: (@Sendable (String) -> Void)?
    private var restarts = 0
    private var sendErrors = 0
    private var receiveErrors = 0

    init(label: String, remoteHost: String, remotePort: UInt16, localHost: String?, localPort: UInt16?) {
        self.label = label
        queue = DispatchQueue(label: "MediaTransport.\(label)", qos: .userInteractive)
        remote = .hostPort(host: NWEndpoint.Host(remoteHost), port: NWEndpoint.Port(rawValue: remotePort) ?? .any)
        if localHost != nil || localPort != nil {
            local = .hostPort(host: NWEndpoint.Host(localHost ?? "0.0.0.0"),
                              port: localPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        } else {
            local = nil
        }
    }

    static func make(flow: MediaTransport.Flow, config: MediaTransport.Config) -> NWDatagramChannel {
        let port = config.remotePort(flow)
        return NWDatagramChannel(label: flow.rawValue, remoteHost: config.host, remotePort: port,
                                 localHost: config.localAddress,
                                 localPort: config.symmetricLocalPorts ? port : nil)
    }

    func start(onReceive: @escaping @Sendable (Data) -> Void, onEvent: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.onReceive = onReceive
        self.onEvent = onEvent
        lock.unlock()
        openConnection()
    }

    private func makeParameters() -> NWParameters {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        if let local { params.requiredLocalEndpoint = local }
        return params
    }

    private func openConnection() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let conn = NWConnection(to: remote, using: makeParameters())
        connection = conn
        lock.unlock()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                let path = conn.currentPath
                self.emit("ready local=\(path?.localEndpoint.map { "\($0)" } ?? "?") remote=\(path?.remoteEndpoint.map { "\($0)" } ?? "\(self.remote)")")
                self.receiveLoop(conn)
            case .waiting(let error):
                self.emit("waiting: \(error)")
            case .failed(let error):
                self.emit("failed: \(error); reopening")
                conn.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reopen(after: conn) }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func reopen(after old: NWConnection) {
        lock.lock()
        let stale = connection !== old || closed
        if !stale { restarts += 1 }
        lock.unlock()
        if !stale { openConnection() }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn else { return }
            if let data, !data.isEmpty { self.deliver(data) }
            if let error {
                let n = self.bumpReceiveErrors()
                if n <= 5 || n % 100 == 0 { self.emit("receive error #\(n): \(error)") }
                if case .cancelled = conn.state { return }
                // Connected UDP surfaces ICMP port-unreachable (e.g. a punch that
                // beat the server's bind) as ECONNREFUSED; keep listening.
                self.queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.rearm(conn) }
                return
            }
            self.rearm(conn)
        }
    }

    private func rearm(_ conn: NWConnection) {
        lock.lock()
        let live = connection === conn && !closed
        lock.unlock()
        if live, case .ready = conn.state { receiveLoop(conn) }
    }

    private func deliver(_ data: Data) {
        lock.lock(); let cb = onReceive; lock.unlock()
        cb?(data)
    }

    private func emit(_ msg: String) {
        lock.lock(); let cb = onEvent; lock.unlock()
        cb?(msg)
    }

    private func bumpReceiveErrors() -> Int { lock.lock(); defer { lock.unlock() }; receiveErrors += 1; return receiveErrors }
    private func bumpSendErrors() -> Int { lock.lock(); defer { lock.unlock() }; sendErrors += 1; return sendErrors }

    func send(_ datagram: Data) {
        lock.lock(); let conn = closed ? nil : connection; lock.unlock()
        conn?.send(content: datagram, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            let n = self.bumpSendErrors()
            if n <= 5 || n % 100 == 0 { self.emit("send error #\(n): \(error)") }
        })
    }

    func cancel() {
        lock.lock()
        closed = true
        let conn = connection
        connection = nil
        onReceive = nil
        lock.unlock()
        conn?.cancel()
    }
}
