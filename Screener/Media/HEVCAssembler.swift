// Ported from iShareScreen (AGPL-3.0):
//   src/isharescreen/proxy/session.py — _queue_video_group_packet,
//     _sorted_group_packets, _group_complete, _ordered_group_keys,
//     _flush_ready_groups, _flush_group, _drop_incomplete_group,
//     _evict_stale_groups, _track_seq, _harvest_param_sets
//   src/isharescreen/proxy/media/hevc.py — feed_burst ordering, the
//     _decode_one IDR gate (_dpb_has_idr / _tiles_await_idr),
//     _is_decodable_nalu, _try_recovery (ISS_PERTILE_RECOVERY),
//     consume_fir_request
//   src/isharescreen/proxy/protocol/burst.py — param-set harvest, CODEC-DETECT
//   src/isharescreen/proxy/media/bitstream.py — BitReader, emulation removal
//
// Turns decrypted video RTP packets from the tile SSRCs into HEVC access
// units in decoding order for ONE shared decoder.
//
// Grouping (session.py): packets are grouped per (SSRC, RTP timestamp); a
// group is flushed as soon as its marker packet is in (the HEVC path of
// _queue_video_group_packet flushes at marker, with no NACK repair wait).
// Packets are put in sequence order with the 65535→0 wrap handled
// (_sorted_group_packets). A group is intact when its sequence numbers are
// contiguous and the marker ends it (_flush_group's "incomplete" check, plus
// _group_complete's marker-last rule). Beyond the reference, a sequence gap
// between the previous marker on that SSRC and this group's first packet
// (_group_complete's anchor test) and a broken FU are also loss. Packets for
// an already-flushed group are ignored (_recently_flushed); a pending group
// left behind by a newer flushed group on the same SSRC lost its marker and
// is dropped as loss, and so is one that got no packet for
// `pendingGroupTimeout` (_evict_stale_groups; the owner calls `tick(now:)` on
// a timer). Packets that fill a sequence gap late are not counted lost.
//
// Decoding order: every AU carries a DONL, and on Apple's stream it is ONE
// counter across all tiles: +1 per AU SENT, the tiles of one RTP timestamp
// in tile order, then the next timestamp (live captures 2026-11-14 and
// 2026-11-18: 5400 AUs, every DON step 1, never a timestamp going back).
// The encoder does NOT send every tile of every picture: a tile with nothing
// new is often skipped (with motion in one corner, 2 of 4 tiles are missing
// from ~60% of the pictures; ~2% even with full-screen motion), and the DON
// counter does not count skipped tiles. So the DON says nothing about WHICH
// tile an AU is; only that AUs come in (timestamp, tile) order, which is
// what feed_burst does so the shared DPB sees POCs in order. AUs are
// released in DON order through a reorder buffer: a DON hole holds later
// AUs for `reorderWindow` of wall time (MediaPacket.arrival), longer while
// the missing AU is visibly still arriving, and then counts as loss. The
// hole belongs to a tile whose newest AU so far is before the hole: AUs of
// one SSRC arrive in DON order, so a tile that already delivered a later
// DON (with no sequence gap) cannot own it. A hole that a reported loss
// already explains (it lies between the lossy tile's previous AU and the AU
// after its sequence gap) is not waited for — but only while that loss is
// still ahead of decoding. Cold start holds everything until an IRAP or the window,
// so an IDR that completes after its timestamp's tiles 1–3 still goes first.
// A late IRAP is never discarded. If DONs ever look per-SSRC (repeated late
// DONs), ordering falls back to marker-arrival order, which is what the
// reference feeds; the next IRAP turns DON ordering back on (a bounded
// number of times).
//
// Recovery (hevc.py _decode_one / _try_recovery): no inter picture reaches
// the decoder until an IRAP has rooted the DPB (cold start: _dpb_has_idr).
// After loss, by default only the lossy tile drops inter pictures until an
// IRAP on ANY tile at or after the loss in decoding order, which re-roots
// every tile (each gate keeps the DON of its loss, so a late IRAP does not
// lift a gate set by a later loss; reference default
// ISS_PERTILE_RECOVERY=1: Apple sends IRAPs on the base SSRC; the other
// tiles keep decoding from their intact history). A DON hole that outlives
// the wait gates the tiles that can own it (see above). The decoder
// reports a corrupt picture with `noteDecodeError(tile:don:)`, which gates
// every tile until an IRAP after it (cross-tile references can spread
// damage) and asks for a keyframe; a report for a picture before the last
// IRAP is stale and ignored. `.allTiles` keeps the session-wide gate
// (ISS_PERTILE_RECOVERY=0). Keyframe requests go to the lossy tile's SSRC
// (_send_fir_for_tile) and to the base SSRC as soon as the loss is seen,
// and are re-sent while the wait lasts (the gate's sticky
// consume_fir_request re-arm); the gate itself applies at the loss's
// decoding position, so healthy earlier AUs still in the buffer pass.
//
// Codec guard (burst.py CODEC-DETECT): if H.264 evidence (Apple's 0x92 avcC
// config packet or a first byte no HEVC payload can have) shows up before
// any HEVC parameter set, `.notHEVC` is emitted once and ingest stops.
//
// Deviations from the reference:
//   * The gate is IRAP-based: a tile that lost a picture waits for the next
//     IRAP. Design hook: once LTR acknowledgements are supported, a picture
//     whose references are all known-good (acknowledged LTR) frames must be
//     let through the gate instead (see `process`).
//   * RASL pictures (types 8/9) after a CRA that starts decoding (cold
//     start, or a tile recovering from loss), and after any BLA, reference
//     pictures the decoder never had: they are dropped until the next IRAP.
//   * Hostile input: parameter sets with ids out of range (VPS > 15, SPS >
//     15, PPS > 63) are not cached; duplicate tile SSRCs are ignored.
//
// Plain class, no concurrency: one task drives it.
import Foundation

struct AccessUnit: Equatable, Sendable {
    /// VCL NAL units (types 0–31) without start codes or length prefixes.
    var nalUnits: [Data]
    /// Contains an IRAP picture (NAL types 16–21, the reference's IDR_RANGE).
    var isIDR: Bool
    /// Index into the sorted tile SSRC list (0 = base SSRC, top tile).
    var tile: Int
    var rtpTimestamp: UInt32
    var ssrc: UInt32
    /// Decoding-order number from the DONL (what an LTR ack echoes).
    var don: UInt16
}

enum AssemblerOutput: Equatable, Sendable {
    /// A new or changed VPS/SPS/PPS set; the decoder must be (re)built from
    /// it before the access units that follow.
    case parameterSets(vps: Data, sps: Data, pps: [Data])
    case accessUnit(AccessUnit)
    /// Ask the server for a fresh IRAP on this SSRC (MediaTransport.requestKeyframe).
    case needKeyframe(ssrc: UInt32)
    /// The stream is not HEVC (the server chose H.264). Emitted once.
    case notHEVC
}

final class HEVCAssembler {
    enum RecoveryScope: Sendable {
        /// Only the lossy tile waits for the next IRAP (default; reference
        /// ISS_PERTILE_RECOVERY=1). `noteDecodeError` escalates to all tiles.
        case lossyTile
        /// Loss on any tile holds every tile until the next IRAP
        /// (reference ISS_PERTILE_RECOVERY=0).
        case allTiles
    }

    struct Config: Sendable {
        var scope: RecoveryScope = .lossyTile
        /// How long a DON hole holds later AUs back (from the arrival of the
        /// oldest held AU) before the missing AU counts as lost.
        var reorderWindow: Duration = .milliseconds(60)
        /// A hole whose AU is still arriving (a pending group on its tile got
        /// a packet within `reorderWindow`) is waited for up to this long.
        var inFlightHoleLimit: Duration = .milliseconds(500)
        /// Held AUs beyond this end the wait at once (memory bound).
        var maxHeldEntries = 256
        /// While waiting for an IRAP, re-request after this many dropped AUs.
        var keyframeRetryAfterDrops = 60
        /// Cold start: dropped AUs tolerated before the first request (the
        /// burst usually starts with a few stale P pictures before its IDR).
        var coldStartGraceDrops = 8
        /// H.264 evidence packets needed for `.notHEVC`.
        var codecDetectThreshold = 3
        /// Late DONs in a row that switch off DON ordering.
        var lateDONLimit = 16
        /// Pending (unflushed) groups kept per SSRC.
        var maxPendingGroupsPerSSRC = 32
        /// A pending group that got no packet for this long lost its marker
        /// and is evicted as loss (`tick`). Separate from `reorderWindow`:
        /// a DON hole stops waiting for a stalled group long before that.
        var pendingGroupTimeout: Duration = .milliseconds(300)
        /// Times DON ordering may come back on an IRAP after a run of late
        /// DONs switched it off.
        var donOrderingRestarts = 2
    }

    struct Stats: Equatable, Sendable {
        var packets = 0
        var duplicatePackets = 0
        var latePackets = 0
        var lostPackets = 0              // sequence gaps (_track_seq) not filled by late arrivals
        var groupsFlushed = 0
        var groupsIncomplete = 0
        var groupsEvicted = 0
        var lossEvents = 0
        var donHoles = 0
        var duplicateDONs = 0
        var lateAccessUnits = 0
        var lateIRAPs = 0
        var accessUnits = 0
        var idrs = 0
        var droppedWaitingForIDR = 0
        var droppedRASL = 0
        var decodeErrors = 0
        /// Decoder errors for pictures before the last IRAP (ignored).
        var staleDecodeErrors = 0
        var keyframeRequests = 0
        var parameterSetUpdates = 0
        var rejectedParameterSets = 0
        var donOrdering = true
    }

    private(set) var stats = Stats()
    private(set) var tileSSRCs: [UInt32]
    private(set) var parameterSets: (vps: Data, sps: Data, pps: [Data])?
    private(set) var isNotHEVC = false
    /// Tiles that will not get inter pictures until an IRAP clears them.
    var tilesAwaitingIDR: Set<Int> { Set(gates.keys) }

    private let config: Config
    private var tileIndex: [UInt32: Int] = [:]
    private var ssrcState: [UInt32: SSRCState] = [:]
    /// Latest arrival seen (packets or `tick`); never moves backwards.
    private var clock: ContinuousClock.Instant?

    // Parameter-set harvest (accumulates across groups, as _harvest_param_sets).
    private var harvestVPS: Data?
    private var harvestSPS: Data?
    private var harvestPPS: [UInt32: Data] = [:]
    private var hevcConfirmed = false
    private var h264Evidence = 0

    // DON reorder buffer.
    private var held: [UInt16: Entry] = [:]
    private var expectedDON: UInt16?
    /// Before the first anchor: the first DON seen (ordering reference).
    private var coldRef: UInt16?
    private var lateDONStreak = 0
    /// Per tile: a loss already reported explains DON holes after `after`
    /// (the tile's AU before the loss; nil = none seen) up to `through` (the
    /// AU after it). Dropped once decoding passes `through`.
    private var explained: [Int: (after: UInt16?, through: UInt16)] = [:]
    /// Per tile: the newest DON received (which tiles can own a DON hole).
    private var newestDON: [Int: UInt16] = [:]
    /// (timestamp, tile) of the entry released just before `expectedDON`;
    /// nil after a hole or a reset.
    private var lastReleased: (timestamp: UInt32, tile: Int)?
    private var lastIRAPDON: UInt16?

    // Recovery.
    /// Why a tile (or the scope) waits: `don` is the decoding position of the
    /// loss or error. Only an IRAP at or after it in decoding order clears
    /// it, so a late IRAP cannot lift a gate set by a later loss. nil: no
    /// position known; any IRAP clears it.
    private struct Gate { var don: UInt16? }
    private var gates: [Int: Gate] = [:]
    private var everHadIDR = false
    /// A decode error widened the gate to every tile until an IRAP after it.
    private var escalation: Gate?
    private var donOrderingStops = 0
    /// Tiles whose RASL pictures are undecodable until the next IRAP.
    private var raslSkipTiles: Set<Int> = []
    /// SSRCs asked for a keyframe since the last IRAP.
    private var keyframeTargets: [UInt32] = []
    private var dropsSinceRequest = 0
    private var requestedSinceWait = false

    init(tileSSRCs: [UInt32], config: Config = Config()) {
        self.config = config
        self.tileSSRCs = []
        resetForNewGroup(tileSSRCs: tileSSRCs)
    }

    /// The SSRC group changed (resize, restart, adoption): forget everything,
    /// including parameter sets, which are re-harvested and re-emitted.
    /// Repeated SSRCs are ignored after their first position.
    func resetForNewGroup(tileSSRCs: [UInt32]) {
        var seen = Set<UInt32>()
        let unique = tileSSRCs.filter { seen.insert($0).inserted }
        self.tileSSRCs = unique
        tileIndex = Dictionary(unique.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        ssrcState = [:]
        parameterSets = nil
        harvestVPS = nil; harvestSPS = nil; harvestPPS = [:]
        hevcConfirmed = false; h264Evidence = 0; isNotHEVC = false
        held = [:]; expectedDON = nil; coldRef = nil; lateDONStreak = 0
        explained = [:]; newestDON = [:]; lastReleased = nil; lastIRAPDON = nil
        everHadIDR = false
        escalation = nil
        donOrderingStops = 0
        raslSkipTiles = []
        gates = Dictionary(uniqueKeysWithValues: unique.indices.map { ($0, Gate(don: nil)) })
        keyframeTargets = []
        dropsSinceRequest = 0
        requestedSinceWait = false
        stats.donOrdering = true                 // stats are otherwise cumulative
    }

    // MARK: - ingest

    func ingest(_ pkt: MediaPacket) -> [AssemblerOutput] {
        guard !isNotHEVC, let tile = tileIndex[pkt.ssrc] else { return [] }
        stats.packets += 1
        advanceClock(pkt.arrival)
        var state = ssrcState[pkt.ssrc] ?? SSRCState()
        state.track(pkt.seq, stats: &stats)

        if !hevcConfirmed, noteCodecEvidence(pkt.payload) {
            ssrcState[pkt.ssrc] = state
            isNotHEVC = true
            return [.notHEVC]
        }
        if state.recentlyFlushed.contains(pkt.timestamp) {
            ssrcState[pkt.ssrc] = state
            stats.latePackets += 1           // _recently_flushed: group already gone
            return []
        }
        var group = state.pending[pkt.timestamp] ?? Group(firstSeq: pkt.seq, lastArrival: pkt.arrival)
        guard group.seqs.insert(pkt.seq).inserted else {
            ssrcState[pkt.ssrc] = state
            stats.duplicatePackets += 1
            return []
        }
        group.packets.append(.init(seq: pkt.seq, marker: pkt.marker, payload: pkt.payload))
        if Self.precedes(pkt.seq, group.firstSeq) { group.firstSeq = pkt.seq }
        group.hasMarker = group.hasMarker || pkt.marker
        group.lastArrival = max(group.lastArrival, pkt.arrival)

        var entries: [Entry] = []
        if group.hasMarker {
            state.pending[pkt.timestamp] = nil
            entries = flush(group, timestamp: pkt.timestamp, ssrc: pkt.ssrc, tile: tile, state: &state)
        } else {
            state.pending[pkt.timestamp] = group
            if state.pending.count > config.maxPendingGroupsPerSSRC,
               let e = evictOldest(&state, tile: tile, ssrc: pkt.ssrc) {
                entries = [e]
            }
        }
        // Stored before ordering so the in-flight check sees this SSRC's state.
        ssrcState[pkt.ssrc] = state
        var out: [AssemblerOutput] = []
        for e in entries { enqueue(e, out: &out) }
        drain(out: &out)
        return out
    }

    /// Timer hook: evicts pending groups that got no packet for
    /// `pendingGroupTimeout` (their marker is lost) and releases AUs held behind a
    /// DON hole that has outlived the window. Call every ~20 ms while video
    /// flows; without it, stale state only moves on the next packet.
    func tick(now: ContinuousClock.Instant) -> [AssemblerOutput] {
        guard !isNotHEVC else { return [] }
        advanceClock(now)
        let now = clock ?? now
        var entries: [Entry] = []
        for ssrc in tileSSRCs {
            guard var state = ssrcState[ssrc], let tile = tileIndex[ssrc] else { continue }
            let stale = state.pending.filter { now - $0.value.lastArrival >= config.pendingGroupTimeout }
            guard !stale.isEmpty else { continue }
            let ref = state.maxSeq ?? 0
            for (ts, g) in stale.sorted(by: { (ref &- $0.value.firstSeq) > (ref &- $1.value.firstSeq) }) {
                state.pending[ts] = nil
                state.markFlushed(ts)
                entries.append(evicted(g, timestamp: ts, tile: tile, ssrc: ssrc))
            }
            ssrcState[ssrc] = state
        }
        var out: [AssemblerOutput] = []
        for e in entries { enqueue(e, out: &out) }
        drain(out: &out)
        return out
    }

    /// The decoder hit a corrupt or undecodable picture (on `tile`, and at
    /// decoding position `don`, if known). Damage can spread through
    /// cross-tile references, so every tile waits for an IRAP after it, and
    /// a keyframe is requested. Decoding is asynchronous: a report for a
    /// picture before the last IRAP is stale (that IRAP re-rooted the DPB)
    /// and is ignored. Without `don`, the error is placed at the current
    /// decoding position.
    func noteDecodeError(tile: Int?, don: UInt16? = nil) -> [AssemblerOutput] {
        if let don, let i = lastIRAPDON, Self.precedes(don, i) {
            stats.staleDecodeErrors += 1
            return []
        }
        stats.decodeErrors += 1
        let at = don ?? expectedDON
        escalation = Gate(don: escalation == nil ? at : Self.later(escalation?.don, at))
        setGate(Set(tileSSRCs.indices), don: at)
        var out: [AssemblerOutput] = []
        requestKeyframes(for: tile.flatMap { tileSSRCs.indices.contains($0) ? [$0] : nil }, out: &out)
        return out
    }

    private func advanceClock(_ t: ContinuousClock.Instant) {
        if let c = clock, c >= t { return }
        clock = t
    }

    // MARK: - grouping (session.py)

    private struct Packet { var seq: UInt16; var marker: Bool; var payload: Data }
    private struct Group {
        var packets: [Packet] = []
        var seqs: Set<UInt16> = []
        var hasMarker = false
        /// Lowest sequence number so far (wrap-aware), kept as packets arrive.
        var firstSeq: UInt16
        var lastArrival: ContinuousClock.Instant
        init(firstSeq: UInt16, lastArrival: ContinuousClock.Instant) {
            self.firstSeq = firstSeq
            self.lastArrival = lastArrival
        }
    }

    private struct SSRCState {
        var pending: [UInt32: Group] = [:]
        var lastMarkerSeq: UInt16?
        var maxSeq: UInt16?
        var recentlyFlushed: [UInt32] = []
        /// Sequence numbers counted lost that may still arrive late.
        var missing: Set<UInt16> = []

        /// Gaps wider than this are counted lost without per-packet tracking.
        static let trackedGap: UInt16 = 256
        static let maxMissing = 512
        /// A missing packet this far behind the newest is lost for good.
        static let missingHorizon: UInt16 = 1024

        mutating func track(_ seq: UInt16, stats: inout Stats) {
            guard let prev = maxSeq else { maxSeq = seq; return }
            let diff = seq &- prev
            if diff == 0 { return }                      // duplicate
            if diff > 0x8000 {
                // Late: if it fills a counted gap, it was reordered, not lost.
                if missing.remove(seq) != nil { stats.lostPackets -= 1 }
                return
            }
            stats.lostPackets += Int(diff) - 1
            if diff > 1, diff <= Self.trackedGap {
                for k in 1..<diff { missing.insert(prev &+ k) }
            }
            maxSeq = seq
            if missing.count > Self.maxMissing {
                missing = missing.filter { seq &- $0 < Self.missingHorizon }
                if missing.count > Self.maxMissing { missing = [] }
            }
        }

        mutating func markFlushed(_ ts: UInt32) {
            recentlyFlushed.append(ts)
            if recentlyFlushed.count > 64 { recentlyFlushed.removeFirst(recentlyFlushed.count - 64) }
        }
    }

    /// _sorted_group_packets: sequence order, starting right after the
    /// largest circular gap so runs across 65535→0 stay in order.
    private static func sorted(_ packets: [Packet]) -> [Packet] {
        let s = packets.sorted { $0.seq < $1.seq }
        guard s.count >= 2, s[s.count - 1].seq - s[0].seq > 0x8000 else { return s }
        var gapIndex = 0, gap: UInt16 = 0
        for i in s.indices {
            let g = s[(i + 1) % s.count].seq &- s[i].seq
            if g >= gap { gap = g; gapIndex = i }
        }
        let start = (gapIndex + 1) % s.count
        return Array(s[start...] + s[..<start])
    }

    /// The groups left behind (evicted as loss), then this group's entry.
    private func flush(_ group: Group, timestamp: UInt32, ssrc: UInt32, tile: Int,
                       state: inout SSRCState) -> [Entry] {
        stats.groupsFlushed += 1
        let packets = Self.sorted(group.packets)
        let first = packets[0].seq
        let contiguous = zip(packets, packets.dropFirst()).allSatisfy { $1.seq &- $0.seq == 1 }
        let markerLast = packets[packets.count - 1].marker
        // _group_complete's anchor: loss right before this AU's first packet.
        let gapBefore = state.lastMarkerSeq.map { first != $0 &+ 1 } ?? false
        if let m = packets.last(where: \.marker) { state.lastMarkerSeq = m.seq }
        state.markFlushed(timestamp)

        // Groups still pending from before this one lost their marker.
        var entries: [Entry] = []
        let behindGroups = state.pending.compactMap { ts, g -> (UInt32, Group, UInt16)? in
            let behind = first &- g.firstSeq
            return behind != 0 && behind < 0x8000 ? (ts, g, behind) : nil
        }
        for (ts, g, _) in behindGroups.sorted(by: { $0.2 > $1.2 }) {
            state.pending[ts] = nil
            state.markFlushed(ts)
            entries.append(evicted(g, timestamp: ts, tile: tile, ssrc: ssrc))
        }

        // Reassemble with sequence-aware FU tracking.
        var nals: [Data] = []
        var fu = FUReassembler()
        var fuBroken = false
        var donFirst: UInt16?, donLast: UInt16?
        for p in packets {
            guard let unit = try? HEVCDepacketizer.parse(p.payload) else { continue }
            switch unit {
            case .nals(let n, let don):
                nals += n
                donFirst = donFirst ?? don; donLast = don
            case .fragment(let f):
                donFirst = donFirst ?? f.don; donLast = f.don
                switch fu.push(f, seq: p.seq) {
                case .pending: break
                case .nal(let nal, _): nals.append(nal)
                case .lost: fuBroken = true
                }
            }
        }
        if fu.isActive { fuBroken = true }

        // Harvest first: parameter sets may be intact in a damaged group.
        let newParams = harvest(nals)
        let intact = contiguous && markerLast && !fuBroken
        if !intact { stats.groupsIncomplete += 1 }

        // _is_decodable_nalu minus the first_slice_segment_in_pic_flag test:
        // the whole AU goes to one sample (Apple sends one slice per AU).
        let vcl = nals.filter { $0.count >= 3 && HEVCNAL.type($0[$0.startIndex]) < 32 }
        let kind: Entry.Kind
        if !intact {
            kind = .lost
        } else if vcl.isEmpty {
            kind = .noPicture
        } else {
            let idr = vcl.contains { HEVCNAL.irap.contains(HEVCNAL.type($0[$0.startIndex])) }
            kind = .picture(AccessUnit(nalUnits: vcl, isIDR: idr, tile: tile, rtpTimestamp: timestamp,
                                       ssrc: ssrc, don: donFirst ?? 0))
        }
        entries.append(Entry(donFirst: donFirst, donLast: donLast ?? donFirst, tile: tile, timestamp: timestamp, kind: kind,
                             gapBefore: gapBefore, parameterSets: newParams, arrival: clock ?? .now))
        return entries
    }

    /// _drop_incomplete_group for a group whose marker never came.
    private func evicted(_ g: Group, timestamp: UInt32, tile: Int, ssrc: UInt32) -> Entry {
        stats.groupsEvicted += 1
        let payloads = Self.sorted(g.packets).map(\.payload)
        let don = HEVCDepacketizer.firstDONL(payloads)
        // Parameter sets in a complete AP survive the loss of the picture.
        var params: AssemblerOutput?
        for p in payloads {
            if case .nals(let n, _)? = try? HEVCDepacketizer.parse(p), let ps = harvest(n) { params = ps }
        }
        return Entry(donFirst: don, donLast: don, tile: tile, timestamp: timestamp, kind: .lost, gapBefore: false,
                     parameterSets: params, arrival: clock ?? .now)
    }

    private func evictOldest(_ state: inout SSRCState, tile: Int, ssrc: UInt32) -> Entry? {
        guard let max = state.maxSeq,
              let (ts, g) = state.pending.max(by: { a, b in
                  // oldest = largest distance behind the newest sequence number
                  (max &- a.value.firstSeq) < (max &- b.value.firstSeq)
              }) else { return nil }
        state.pending[ts] = nil
        state.markFlushed(ts)
        return evicted(g, timestamp: ts, tile: tile, ssrc: ssrc)
    }

    // MARK: - parameter sets (session._harvest_param_sets / burst.py)

    /// Accumulates VPS/SPS/PPS; returns `.parameterSets` when the complete set
    /// is new or changed. Ids out of range are hostile or corrupt and are not
    /// cached: vps_video_parameter_set_id is u(4), so never above 15;
    /// sps_seq_parameter_set_id must be ≤ 15 and pps_pic_parameter_set_id ≤ 63
    /// (H.265 7.4.3.2.1 / 7.4.3.3.1). That also bounds `harvestPPS`.
    private func harvest(_ nals: [Data]) -> AssemblerOutput? {
        var touched = false
        for nal in nals where nal.count >= 2 {
            switch HEVCNAL.type(nal[nal.startIndex]) {
            case HEVCNAL.vps:
                harvestVPS = nal; touched = true
            case HEVCNAL.sps:
                guard let info = HEVCSPSInfo(sps: nal), info.spsID <= 15 else {
                    stats.rejectedParameterSets += 1
                    continue
                }
                harvestSPS = nal; touched = true
            case HEVCNAL.pps where nal.count > 2:
                var r = HEVCBitReader(rbsp: nal.dropFirst(2))
                let id = r.ue()
                guard id <= 63 else {
                    stats.rejectedParameterSets += 1
                    continue
                }
                harvestPPS[id] = nal; touched = true
            default: continue
            }
        }
        guard touched, let vps = harvestVPS, let sps = harvestSPS, !harvestPPS.isEmpty else { return nil }
        hevcConfirmed = true
        let pps = harvestPPS.keys.sorted().map { harvestPPS[$0]! }
        if let cur = parameterSets, cur.vps == vps, cur.sps == sps, cur.pps == pps { return nil }
        parameterSets = (vps, sps, pps)
        return .parameterSets(vps: vps, sps: sps, pps: pps)
    }

    /// burst.py CODEC-DETECT, reduced to unambiguous H.264 evidence: Apple's
    /// avcC config packet (0x92) or a first byte with the forbidden bit set
    /// or an HEVC type no Apple HEVC payload uses (50–63; H.264 IDR 0x65,
    /// STAP-A 0x78, FU-A 0x7C all land there).
    private func noteCodecEvidence(_ payload: Data) -> Bool {
        guard let b = payload.first else { return false }
        if b & 0x80 != 0 || HEVCNAL.type(b) >= 50 { h264Evidence += 1 }
        return h264Evidence >= config.codecDetectThreshold
    }

    // MARK: - decoding order (DON reorder buffer)

    private struct Entry {
        enum Kind { case picture(AccessUnit), noPicture, lost }
        var donFirst: UInt16?
        var donLast: UInt16?
        var tile: Int
        var timestamp: UInt32
        var kind: Kind
        var gapBefore: Bool
        var parameterSets: AssemblerOutput?
        var arrival: ContinuousClock.Instant
        /// Entries without a DON that arrived while this one was the newest
        /// held entry: processed right after it.
        var followers: [Entry] = []

        var isLost: Bool { if case .lost = kind { true } else { false } }
        var isIRAP: Bool { if case .picture(let au) = kind { au.isIDR } else { false } }
        /// The DON of the slice (the group's last DON).
        var pictureDON: UInt16? { donLast ?? donFirst }
    }

    /// A DON jump this far back on an IRAP is a renumbered stream, not a
    /// late picture.
    private static let discontinuity: UInt16 = 0x400

    private func enqueue(_ e: Entry, out: inout [AssemblerOutput]) {
        // Ask for the keyframe now so the request is not delayed behind the
        // reorder buffer; the gate applies when `process` reaches the entry.
        if e.gapBefore || e.isLost { reportLoss(tiles: [e.tile], out: &out) }
        let previous = newestDON[e.tile]
        if let d = e.pictureDON { newestDON[e.tile] = Self.later(previous, d) }
        guard stats.donOrdering, let don = e.donFirst else {
            // No DON: ordered by arrival, after everything already held.
            if let k = newestHeldKey() { held[k]!.followers.append(e) } else { process(e, out: &out) }
            return
        }
        if let exp = expectedDON {
            let behind = exp &- don
            if behind != 0, behind < 0x8000 {
                late(e, don: don, behind: behind, out: &out)
                return
            }
        } else if coldRef == nil {
            coldRef = don
        }
        lateDONStreak = 0
        if e.gapBefore || e.isLost { explain(tile: e.tile, after: previous, through: e.pictureDON ?? don) }
        guard var first = held[don] else {
            held[don] = e
            return
        }
        // Same DON twice: keep the first, but not at the cost of the
        // second's parameter sets (harvest only reports a set once) or its
        // loss. A discarded picture is a lost picture for its tile.
        stats.duplicateDONs += 1
        if let ps = e.parameterSets { first.parameterSets = ps }
        var rest = e
        rest.parameterSets = nil
        if case .picture = rest.kind {
            rest.kind = .lost
            reportLoss(tiles: [rest.tile], out: &out)
        }
        if rest.isLost || rest.gapBefore { first.followers.append(rest) }
        held[don] = first
    }

    /// An entry whose decode slot has passed.
    private func late(_ e: Entry, don: UInt16, behind: UInt16, out: inout [AssemblerOutput]) {
        if e.isIRAP {
            // Never discard an IRAP: it is what every waiting tile needs.
            stats.lateIRAPs += 1
            if behind >= Self.discontinuity {
                // Renumbered stream: release what is held, then re-anchor.
                drainAll(out: &out)
                expectedDON = nil
                explained = [:]
                newestDON = [:]
            }
            process(e, out: &out)
            return
        }
        stats.lateAccessUnits += 1
        // Only late pictures say something about DON numbering; an evicted
        // group is late by nature (its hole was given up first).
        if case .picture = e.kind { lateDONStreak += 1 }
        if lateDONStreak >= config.lateDONLimit {
            stats.donOrdering = false        // DONs are not one global counter
            donOrderingStops += 1
            lateDONStreak = 0
            Log.video.error("HEVC: DONs are not in decoding order across tiles; using arrival order")
        }
        var l = e
        if let i = lastIRAPDON, (i &- don) != 0, (i &- don) < 0x8000 {
            // Before the last IRAP in decoding order: superseded, not lost.
            l.kind = .noPicture
            l.gapBefore = false
        } else if case .picture = e.kind {
            l.kind = .lost
            reportLoss(tiles: [e.tile], out: &out)
        }
        process(l, out: &out)
        if !stats.donOrdering { drainAll(out: &out) }
    }

    private func drain(out: inout [AssemblerOutput]) {
        guard stats.donOrdering else { return }
        if expectedDON == nil, !anchorColdStart(out: &out) { return }
        while let exp = expectedDON {
            // A loss that decoding has passed explains nothing any more.
            explained = explained.filter { ($0.value.through &- exp) < 0x8000 }
            if let e = held.removeValue(forKey: exp) {
                process(e, out: &out)
                advance(past: e.donLast ?? exp)
                lastReleased = (e.timestamp, e.tile)
                continue
            }
            guard let next = held.keys.min(by: { ($0 &- exp) < ($1 &- exp) }) else { return }
            let owners = holeOwners(from: exp, before: held[next]!)
            if let lossy = explainedHole(from: exp), owners.isSubset(of: lossy) {
                gate(tiles: owners, don: next &- 1, out: &out)           // reported already; gate it here
            } else {
                guard holeExpired(tiles: owners) else { return }
                // A DON hole that outlived the window: those AUs are gone.
                stats.donHoles += 1
                reportLoss(tiles: owners, out: &out)
                gate(tiles: owners, don: next &- 1, out: &out)
            }
            lastReleased = nil
            expectedDON = next
        }
    }

    /// Cold start: hold everything until an IRAP is in (the IDR often
    /// completes after the same timestamp's other tiles) or the window ends.
    /// AUs before the IRAP cannot be decoded but may carry parameter sets.
    private func anchorColdStart(out: inout [AssemblerOutput]) -> Bool {
        guard !held.isEmpty else { return false }
        let ref = (coldRef ?? 0) &- 0x4000
        let keys = held.keys.sorted { ($0 &- ref) < ($1 &- ref) }
        if let irap = keys.first(where: { held[$0]!.isIRAP }) {
            for k in keys where (k &- ref) < (irap &- ref) { process(held.removeValue(forKey: k)!, out: &out) }
            expectedDON = irap
        } else if holeExpired(tiles: [0]) {               // IRAPs come on the base SSRC
            expectedDON = keys[0]
        } else {
            return false
        }
        coldRef = nil
        return true
    }

    private func drainAll(out: inout [AssemblerOutput]) {
        let ref = expectedDON ?? ((coldRef ?? 0) &- 0x4000)
        let rest = held.values.sorted { ($0.donFirst ?? 0) &- ref < ($1.donFirst ?? 0) &- ref }
        held = [:]
        for e in rest { process(e, out: &out) }
    }

    /// Moves expectedDON forward to just after `don`, never backwards.
    private func advance(past don: UInt16) {
        let next = don &+ 1
        guard let exp = expectedDON else { expectedDON = next; return }
        if (next &- exp) < 0x8000 { expectedDON = next }
    }

    private func newestHeldKey() -> UInt16? {
        let ref = expectedDON ?? ((coldRef ?? 0) &- 0x4000)
        return held.keys.max { ($0 &- ref) < ($1 &- ref) }
    }

    /// Whether the wait for the hole ahead of the held AUs is over.
    private func holeExpired(tiles: Set<Int>?) -> Bool {
        if held.count > config.maxHeldEntries { return true }
        guard let now = clock, let oldest = held.values.map(\.arrival).min() else { return false }
        let age = now - oldest
        if age < config.reorderWindow { return false }
        if age < config.inFlightHoleLimit, holeInFlight(tiles: tiles, now: now) { return false }
        return true
    }

    /// A pending group on one of the hole's possible tiles is still
    /// receiving packets.
    private func holeInFlight(tiles: Set<Int>?, now: ContinuousClock.Instant) -> Bool {
        guard let tiles else { return false }
        return tiles.contains { t in
            guard tileSSRCs.indices.contains(t) else { return false }
            let pending = ssrcState[tileSSRCs[t]]?.pending.values
            return pending?.contains { now - $0.lastArrival < config.reorderWindow } ?? false
        }
    }

    // MARK: - DON hole attribution

    /// The tiles that can own the DON hole starting at `from`, ahead of the
    /// held entry `next`: those whose newest AU so far is before the hole,
    /// plus those whose reported loss covers it (a tile that delivered a
    /// later DON with no sequence gap cannot); failing that, the tiles that
    /// have sent nothing yet. When the AUs on both sides of the hole share a
    /// timestamp, only the tiles between them fit (DONs follow tile order
    /// within a picture). Never empty: with no candidate (a renumbered
    /// stream) every tile.
    private func holeOwners(from: UInt16, before next: Entry) -> Set<Int> {
        let all = Set(tileSSRCs.indices)
        var owners = all.filter { t in newestDON[t].map { Self.precedes($0, from) } ?? false }
        owners.formUnion(explainedHole(from: from) ?? [])
        if owners.isEmpty { owners = all.filter { newestDON[$0] == nil } }
        if let prev = lastReleased, prev.timestamp == next.timestamp {
            owners = owners.filter { $0 > prev.tile && $0 < next.tile }
        }
        return owners.isEmpty ? all : owners
    }

    /// The tiles whose reported loss covers DON `from`; nil when none does.
    private func explainedHole(from: UInt16) -> Set<Int>? {
        let tiles = explained.filter { _, r in
            (r.after.map { Self.precedes($0, from) } ?? true) && Self.precedes(from, r.through)
        }.keys
        return tiles.isEmpty ? nil : Set(tiles)
    }

    private func explain(tile: Int, after: UInt16?, through don: UInt16) {
        if let cur = explained[tile], Self.precedes(don, cur.through) { return }   // already further
        // A second loss before decoding reached the first keeps the earlier start.
        let start = explained[tile].map { $0.after } ?? after
        explained[tile] = (start, don)
    }

    // MARK: - decode gate + recovery (hevc.py _decode_one / _try_recovery)

    private func process(_ e: Entry, out: inout [AssemblerOutput]) {
        if let ps = e.parameterSets {
            stats.parameterSetUpdates += 1
            out.append(ps)
            // A changed set means a rebuilt decoder with an empty DPB. Its IRAP
            // normally follows at once, so wait like a cold start (grace before
            // the first request) instead of asking for another one now.
            if everHadIDR {
                setGate(Set(tileSSRCs.indices), don: e.donFirst ?? expectedDON)
                keyframeTargets = []
                requestedSinceWait = false
                dropsSinceRequest = 0
            }
        }
        // The loss takes effect here, at its decoding position.
        if e.gapBefore || e.isLost { gate(tiles: [e.tile], don: e.pictureDON ?? expectedDON, out: &out) }
        switch e.kind {
        case .noPicture, .lost:
            break
        case .picture(let au):
            if au.isIDR, parameterSets != nil {
                irap(au, pictureDON: e.pictureDON ?? au.don, out: &out)
            } else if gates[au.tile] != nil || parameterSets == nil {
                // LTR hook: with LTR acknowledgements, a picture referencing
                // only acknowledged (known-good) frames may pass here.
                stats.droppedWaitingForIDR += 1
                dropsSinceRequest += 1
                if keyframeTargets.isEmpty, let base = tileSSRCs.first { keyframeTargets = [base] }
                let due = requestedSinceWait
                    ? dropsSinceRequest >= config.keyframeRetryAfterDrops
                    : dropsSinceRequest >= config.coldStartGraceDrops
                if due { rerequestKeyframes(out: &out) }
            } else if raslSkipTiles.contains(au.tile), au.isRASL {
                stats.droppedRASL += 1
            } else {
                stats.accessUnits += 1
                out.append(.accessUnit(au))
            }
        }
        for f in e.followers { process(f, out: &out) }
    }

    /// An IRAP on any tile re-roots the shared DPB for every tile — but it
    /// lifts only gates set at or before it in decoding order: a late IRAP
    /// does not clear a tile that lost a picture after it.
    private func irap(_ au: AccessUnit, pictureDON: UInt16, out: inout [AssemblerOutput]) {
        let clears = { (g: Gate) in g.don.map { !Self.precedes(pictureDON, $0) } ?? true }
        let cleared = Set(gates.filter { clears($0.value) }.keys)
        let recovering = everHadIDR ? cleared : Set(tileSSRCs.indices)
        // RASL pictures of a CRA that starts decoding (and of any BLA)
        // reference pictures this decoder never had (H.265 8.1.3).
        let types = au.nalUnits.map { HEVCNAL.type($0[$0.startIndex]) }
        if types.contains(where: { (16...18).contains($0) }) {
            raslSkipTiles = Set(tileSSRCs.indices)
        } else if types.contains(21) {
            raslSkipTiles = recovering
        } else {
            raslSkipTiles = []
        }
        everHadIDR = true
        for t in cleared { gates[t] = nil }
        if let g = escalation, clears(g) { escalation = nil }
        if gates.isEmpty {
            keyframeTargets = []
            requestedSinceWait = false
            dropsSinceRequest = 0
        }
        if lastIRAPDON.map({ !Self.precedes(pictureDON, $0) }) ?? true { lastIRAPDON = pictureDON }
        lateDONStreak = 0
        if !stats.donOrdering, donOrderingStops <= config.donOrderingRestarts {
            // Arrival order was a fallback; try DON order again from here.
            // Nothing is held while ordering is off.
            stats.donOrdering = true
            expectedDON = pictureDON
            explained = [:]
            Log.video.info("HEVC: DON ordering re-enabled at IRAP DON \(pictureDON)")
        }
        advance(past: pictureDON)
        coldRef = nil
        stats.idrs += 1
        stats.accessUnits += 1
        out.append(.accessUnit(au))
    }

    /// Loss seen on `tiles` (nil = unknown tile, e.g. a DON hole): ask for a
    /// keyframe now. The gate follows at the decoding position.
    private func reportLoss(tiles: Set<Int>?, out: inout [AssemblerOutput]) {
        stats.lossEvents += 1
        // Before the first IRAP every tile already waits, and the cold-start
        // grace paces requests: a burst that begins mid-AU is not news.
        guard everHadIDR else { return }
        requestKeyframes(for: tiles, out: &out)
    }

    /// Holds `tiles` (widened by the scope) until an IRAP at or after `don`.
    private func gate(tiles: Set<Int>?, don: UInt16?, out: inout [AssemblerOutput]) {
        guard everHadIDR else { return }
        setGate(scopeTiles(tiles), don: don)
        requestKeyframes(for: tiles, out: &out)      // no-op if already asked this wait
    }

    /// Adds gates; a tile already gated keeps the later of the two DONs.
    private func setGate(_ tiles: Set<Int>, don: UInt16?) {
        for t in tiles { gates[t] = Gate(don: gates[t] == nil ? don : Self.later(gates[t]?.don, don)) }
    }

    private func scopeTiles(_ tiles: Set<Int>?) -> Set<Int> {
        if escalation != nil || config.scope == .allTiles { return Set(tileSSRCs.indices) }
        return tiles ?? Set(tileSSRCs.indices)
    }

    /// `a` comes strictly before `b` (16-bit serial-number order).
    private static func precedes(_ a: UInt16, _ b: UInt16) -> Bool {
        let d = b &- a
        return d != 0 && d < 0x8000
    }

    /// The later of two positions; a known one wins over nil.
    private static func later(_ a: UInt16?, _ b: UInt16?) -> UInt16? {
        guard let a else { return b }
        guard let b else { return a }
        return precedes(a, b) ? b : a
    }

    /// Requests a keyframe on the tiles' SSRCs and the base SSRC, each once
    /// per wait; the drop counter paces re-requests.
    private func requestKeyframes(for tiles: Set<Int>?, out: inout [AssemblerOutput]) {
        var targets = (tiles ?? []).sorted().filter { tileSSRCs.indices.contains($0) }.map { tileSSRCs[$0] }
        if let base = tileSSRCs.first, !targets.contains(base) { targets.append(base) }
        let new = targets.filter { !keyframeTargets.contains($0) }
        guard !new.isEmpty else { return }
        keyframeTargets += new
        for ssrc in new {
            stats.keyframeRequests += 1
            out.append(.needKeyframe(ssrc: ssrc))
        }
        requestedSinceWait = true
        dropsSinceRequest = 0
    }

    private func rerequestKeyframes(out: inout [AssemblerOutput]) {
        for ssrc in keyframeTargets {
            stats.keyframeRequests += 1
            out.append(.needKeyframe(ssrc: ssrc))
        }
        requestedSinceWait = true
        dropsSinceRequest = 0
    }
}

private extension AccessUnit {
    /// Every slice is RASL_N / RASL_R (types 8, 9).
    var isRASL: Bool {
        !nalUnits.isEmpty && nalUnits.allSatisfy { (8...9).contains(HEVCNAL.type($0[$0.startIndex])) }
    }
}


// MARK: - bitstream helpers (bitstream.py)

/// MSB-first reader over an RBSP (emulation-prevention bytes removed on init).
/// Reads past the end yield zero bits, like the reference.
struct HEVCBitReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    /// `rbsp` is NAL payload after the 2-byte header, still with 00 00 03.
    init<D: Collection>(rbsp: D) where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(rbsp.count)
        var zeros = 0
        for b in rbsp {
            if zeros >= 2, b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        bytes = out
    }

    mutating func bit() -> UInt32 {
        let i = position >> 3
        guard i < bytes.count else { position += 1; return 0 }
        let v = UInt32(bytes[i] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return v
    }

    mutating func bits(_ n: Int) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<n { v = v << 1 | bit() }
        return v
    }

    mutating func skip(_ n: Int) { position += n }

    /// ue(v), bounded at 31 leading zeros.
    mutating func ue() -> UInt32 {
        var zeros = 0
        while bit() == 0, zeros < 31 { zeros += 1 }
        return (UInt32(1) << zeros) - 1 + bits(zeros)
    }
}

/// The leading SPS fields (H.265 7.3.2.2), for logging and sizing.
struct HEVCSPSInfo: Equatable, Sendable {
    /// sps_seq_parameter_set_id (valid range 0–15).
    var spsID: Int
    var profileIdc: Int
    var chromaFormatIdc: Int
    var width: Int
    var height: Int
    var bitDepthLuma: Int
    var bitDepthChroma: Int

    /// `nal` is the full SPS NAL unit (2-byte header included).
    init?(sps nal: Data) {
        guard nal.count > 4, HEVCNAL.type(nal[nal.startIndex]) == HEVCNAL.sps else { return nil }
        var r = HEVCBitReader(rbsp: nal.dropFirst(2))
        r.skip(4)                                   // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(r.bits(3))
        r.skip(1)                                   // temporal_id_nesting
        // profile_tier_level(1, maxSubLayersMinus1)
        r.skip(3)                                   // profile_space, tier
        profileIdc = Int(r.bits(5))
        r.skip(32 + 48 + 8)                         // compat flags, constraints, level
        var subProfile: [Bool] = [], subLevel: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 { subProfile.append(r.bit() == 1); subLevel.append(r.bit() == 1) }
        if maxSubLayersMinus1 > 0 { r.skip(2 * (8 - maxSubLayersMinus1)) }
        for i in 0..<maxSubLayersMinus1 {
            if subProfile[i] { r.skip(88) }
            if subLevel[i] { r.skip(8) }
        }
        spsID = Int(r.ue())                         // sps_seq_parameter_set_id
        chromaFormatIdc = Int(r.ue())
        if chromaFormatIdc == 3 { r.skip(1) }       // separate_colour_plane_flag
        width = Int(r.ue())
        height = Int(r.ue())
        if r.bit() == 1 { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }   // conformance window
        bitDepthLuma = Int(r.ue()) + 8
        bitDepthChroma = Int(r.ue()) + 8
    }
}
