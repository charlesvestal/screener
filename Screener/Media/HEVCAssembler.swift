// Ported from iShareScreen (AGPL-3.0):
//   src/isharescreen/proxy/session.py — _queue_video_group_packet,
//     _sorted_group_packets, _group_complete, _ordered_group_keys,
//     _flush_ready_groups, _flush_group, _drop_incomplete_group,
//     _evict_stale_groups, _track_seq, _harvest_param_sets
//   src/isharescreen/proxy/media/hevc.py — feed_burst ordering, the
//     _decode_one IDR gate (_dpb_has_idr / _tiles_await_idr),
//     _is_decodable_nalu, _try_recovery, consume_fir_request
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
// is dropped as loss (_evict_stale_groups, without timers).
//
// Decoding order: every AU carries a DONL, and on Apple's stream it is ONE
// counter across all tiles (+1 per AU, tile 0..3 per RTP timestamp; seen on
// a live capture, 2026-11-14). That is exactly the (timestamp, tile)
// interleave feed_burst uses so the shared DPB sees POCs in order. AUs are
// released in DON order through a small reorder buffer; a DON hole that
// outlives `reorderWindow` later entries counts as loss. If DONs ever look
// per-SSRC (repeated late DONs), ordering falls back to marker-arrival order,
// which is what the reference feeds.
//
// Recovery (hevc.py _decode_one): no inter picture reaches the decoder until
// an IRAP has re-rooted the DPB (cold start: _dpb_has_idr). After loss, the
// affected tiles drop inter pictures until the next IRAP on ANY tile, which
// re-roots every tile (Apple sends IRAPs on the base SSRC; tiles share one
// DPB and POC sequence). The default scope is all tiles because the
// reference documents cross-tile references (a lost picture on tile N can
// be referenced by tile M); `.lossyTile` is the reference's
// ISS_PERTILE_RECOVERY behaviour. Keyframe requests go to the lossy tile's
// SSRC (_send_fir_for_tile) and to the base SSRC, and are re-sent while the
// wait lasts (the gate's sticky consume_fir_request re-arm).
//
// Codec guard (burst.py CODEC-DETECT): if H.264 evidence (Apple's 0x92 avcC
// config packet or a first byte no HEVC payload can have) shows up before
// any HEVC parameter set, `.notHEVC` is emitted once and ingest stops.
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
        /// Loss on any tile holds every tile until the next IRAP (default).
        case allTiles
        /// Only the lossy tile waits (reference ISS_PERTILE_RECOVERY).
        case lossyTile
    }

    struct Config: Sendable {
        var scope: RecoveryScope = .allTiles
        /// Entries held behind a DON hole before it is declared lost.
        /// nil = 2 × tile count.
        var reorderWindow: Int?
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
    }

    struct Stats: Equatable, Sendable {
        var packets = 0
        var duplicatePackets = 0
        var latePackets = 0
        var lostPackets = 0              // forward sequence gaps (_track_seq)
        var groupsFlushed = 0
        var groupsIncomplete = 0
        var groupsEvicted = 0
        var lossEvents = 0
        var donHoles = 0
        var lateAccessUnits = 0
        var accessUnits = 0
        var idrs = 0
        var droppedWaitingForIDR = 0
        var keyframeRequests = 0
        var parameterSetUpdates = 0
        var donOrdering = true
    }

    private(set) var stats = Stats()
    private(set) var tileSSRCs: [UInt32]
    private(set) var parameterSets: (vps: Data, sps: Data, pps: [Data])?
    private(set) var isNotHEVC = false
    /// Tiles that will not get inter pictures until the next IRAP.
    private(set) var tilesAwaitingIDR: Set<Int>

    private let config: Config
    private var tileIndex: [UInt32: Int] = [:]
    private var ssrcState: [UInt32: SSRCState] = [:]

    // Parameter-set harvest (accumulates across groups, as _harvest_param_sets).
    private var harvestVPS: Data?
    private var harvestSPS: Data?
    private var harvestPPS: [UInt32: Data] = [:]
    private var hevcConfirmed = false
    private var h264Evidence = 0

    // DON reorder buffer.
    private var held: [UInt16: Entry] = [:]
    private var expectedDON: UInt16?
    private var lateDONStreak = 0
    /// DON holes up to here are explained by a loss already reported (the
    /// entry after a sequence gap): skip them instead of waiting.
    private var explainedHolesThrough: UInt16?

    // Recovery.
    private var everHadIDR = false
    private var keyframeTargets: [UInt32] = []
    private var dropsSinceRequest = 0
    private var requestedSinceWait = false

    init(tileSSRCs: [UInt32], config: Config = Config()) {
        self.config = config
        self.tileSSRCs = []
        self.tilesAwaitingIDR = []
        resetForNewGroup(tileSSRCs: tileSSRCs)
    }

    /// The SSRC group changed (resize, restart, adoption): forget everything,
    /// including parameter sets, which are re-harvested and re-emitted.
    func resetForNewGroup(tileSSRCs: [UInt32]) {
        self.tileSSRCs = tileSSRCs
        tileIndex = Dictionary(uniqueKeysWithValues: tileSSRCs.enumerated().map { ($1, $0) })
        ssrcState = [:]
        parameterSets = nil
        harvestVPS = nil; harvestSPS = nil; harvestPPS = [:]
        hevcConfirmed = false; h264Evidence = 0; isNotHEVC = false
        held = [:]; expectedDON = nil; lateDONStreak = 0; explainedHolesThrough = nil
        everHadIDR = false
        tilesAwaitingIDR = Set(tileSSRCs.indices)
        keyframeTargets = []
        dropsSinceRequest = 0
        requestedSinceWait = false
        stats.donOrdering = true                 // stats are otherwise cumulative
    }

    // MARK: - ingest

    func ingest(_ pkt: MediaPacket) -> [AssemblerOutput] {
        guard !isNotHEVC, let tile = tileIndex[pkt.ssrc] else { return [] }
        stats.packets += 1
        var state = ssrcState[pkt.ssrc] ?? SSRCState()
        defer { ssrcState[pkt.ssrc] = state }
        state.track(pkt.seq, stats: &stats)

        if !hevcConfirmed, noteCodecEvidence(pkt.payload) {
            isNotHEVC = true
            return [.notHEVC]
        }
        if state.recentlyFlushed.contains(pkt.timestamp) {
            stats.latePackets += 1           // _recently_flushed: group already gone
            return []
        }
        var group = state.pending[pkt.timestamp] ?? Group()
        guard !group.packets.contains(where: { $0.seq == pkt.seq }) else {
            stats.duplicatePackets += 1
            return []
        }
        group.packets.append(.init(seq: pkt.seq, marker: pkt.marker, payload: pkt.payload))
        var out: [AssemblerOutput] = []
        guard group.packets.contains(where: \.marker) else {
            state.pending[pkt.timestamp] = group
            if state.pending.count > config.maxPendingGroupsPerSSRC {
                evictOldest(&state, tile: tile, ssrc: pkt.ssrc, out: &out)
            }
            return out
        }
        state.pending[pkt.timestamp] = nil
        flush(group, timestamp: pkt.timestamp, ssrc: pkt.ssrc, tile: tile, state: &state, out: &out)
        return out
    }

    // MARK: - grouping (session.py)

    private struct Packet { var seq: UInt16; var marker: Bool; var payload: Data }
    private struct Group { var packets: [Packet] = [] }

    private struct SSRCState {
        var pending: [UInt32: Group] = [:]
        var lastMarkerSeq: UInt16?
        var maxSeq: UInt16?
        var recentlyFlushed: [UInt32] = []

        mutating func track(_ seq: UInt16, stats: inout Stats) {
            guard let prev = maxSeq else { maxSeq = seq; return }
            let diff = seq &- prev
            if diff == 0 || diff > 0x8000 { return }     // duplicate / late
            stats.lostPackets += Int(diff) - 1
            maxSeq = seq
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

    private func flush(_ group: Group, timestamp: UInt32, ssrc: UInt32, tile: Int,
                       state: inout SSRCState, out: inout [AssemblerOutput]) {
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
        for (ts, g) in state.pending {
            let gFirst = Self.sorted(g.packets)[0].seq
            let behind = first &- gFirst
            guard behind != 0, behind < 0x8000 else { continue }
            state.pending[ts] = nil
            state.markFlushed(ts)
            evicted(g, tile: tile, ssrc: ssrc, timestamp: ts, out: &out)
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
        let entry = Entry(donFirst: donFirst, donLast: donLast ?? donFirst, tile: tile, kind: kind,
                          gapBefore: gapBefore, parameterSets: newParams)
        enqueue(entry, out: &out)
    }

    /// _drop_incomplete_group for a group whose marker never came.
    private func evicted(_ g: Group, tile: Int, ssrc: UInt32, timestamp: UInt32, out: inout [AssemblerOutput]) {
        stats.groupsEvicted += 1
        let payloads = Self.sorted(g.packets).map(\.payload)
        let don = HEVCDepacketizer.firstDONL(payloads)
        // Parameter sets in a complete AP survive the loss of the picture.
        var params: AssemblerOutput?
        for p in payloads {
            if case .nals(let n, _)? = try? HEVCDepacketizer.parse(p), let ps = harvest(n) { params = ps }
        }
        enqueue(Entry(donFirst: don, donLast: don, tile: tile, kind: .lost, gapBefore: false, parameterSets: params),
                out: &out)
    }

    private func evictOldest(_ state: inout SSRCState, tile: Int, ssrc: UInt32, out: inout [AssemblerOutput]) {
        guard let max = state.maxSeq,
              let (ts, g) = state.pending.max(by: { a, b in
                  // oldest = largest distance behind the newest sequence number
                  (max &- Self.sorted(a.value.packets)[0].seq) < (max &- Self.sorted(b.value.packets)[0].seq)
              }) else { return }
        state.pending[ts] = nil
        state.markFlushed(ts)
        evicted(g, tile: tile, ssrc: ssrc, timestamp: ts, out: &out)
    }

    // MARK: - parameter sets (session._harvest_param_sets / burst.py)

    /// Accumulates VPS/SPS/PPS; returns `.parameterSets` when the complete set
    /// is new or changed.
    private func harvest(_ nals: [Data]) -> AssemblerOutput? {
        var touched = false
        for nal in nals where nal.count >= 2 {
            switch HEVCNAL.type(nal[nal.startIndex]) {
            case HEVCNAL.vps: harvestVPS = nal; touched = true
            case HEVCNAL.sps: harvestSPS = nal; touched = true
            case HEVCNAL.pps where nal.count > 2:
                var r = HEVCBitReader(rbsp: nal.dropFirst(2))
                harvestPPS[r.ue()] = nal; touched = true
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
        var kind: Kind
        var gapBefore: Bool
        var parameterSets: AssemblerOutput?
        var isLost: Bool { if case .lost = kind { true } else { false } }
    }

    private var window: Int { config.reorderWindow ?? max(2, 2 * tileSSRCs.count) }

    private func enqueue(_ e: Entry, out: inout [AssemblerOutput]) {
        // Report loss now so the keyframe request is not delayed behind the
        // reorder buffer; `process` re-applies it at its decode position.
        if e.gapBefore || e.isLost { noteLoss(tile: e.tile, out: &out) }
        guard stats.donOrdering, let don = e.donFirst else {
            process(e, out: &out)
            return
        }
        if let exp = expectedDON {
            let behind = exp &- don
            if behind != 0, behind < 0x8000 {
                // Late: its decode slot has passed, so the picture is lost.
                stats.lateAccessUnits += 1
                lateDONStreak += 1
                if lateDONStreak >= config.lateDONLimit {
                    stats.donOrdering = false        // DONs are not one global counter
                    Log.video.error("HEVC: DONs are not in decoding order across tiles; using arrival order")
                }
                var late = e
                if case .picture = e.kind {
                    late.kind = .lost
                    noteLoss(tile: e.tile, out: &out)
                }
                process(late, out: &out)
                if !stats.donOrdering { drainAll(out: &out) }
                return
            }
        } else {
            expectedDON = don
        }
        lateDONStreak = 0
        if e.gapBefore || e.isLost { explainedHolesThrough = don }
        held[don] = e
        drain(out: &out)
    }

    private func drain(out: inout [AssemblerOutput]) {
        while var exp = expectedDON {
            if let e = held.removeValue(forKey: exp) {
                process(e, out: &out)
                exp = (e.donLast ?? exp) &+ 1
                expectedDON = exp
                continue
            }
            guard !held.isEmpty else { return }
            let next = held.keys.min { ($0 &- exp) < ($1 &- exp) }!
            let explained = explainedHolesThrough.map { next &- exp <= $0 &- exp } ?? false
            if !explained, tilesAwaitingIDR.count < tileSSRCs.count {
                guard held.count > window else { return }
                // A DON hole that outlived the window: those AUs are gone.
                stats.donHoles += 1
                noteLoss(tile: nil, out: &out)
            }
            // (An explained hole is already reported; while every tile waits
            // for an IRAP nothing but an IRAP passes. Neither is waited for.)
            expectedDON = next
        }
    }

    private func drainAll(out: inout [AssemblerOutput]) {
        let rest = held.values.sorted { ($0.donFirst ?? 0) &- (expectedDON ?? 0) < ($1.donFirst ?? 0) &- (expectedDON ?? 0) }
        held = [:]
        for e in rest { process(e, out: &out) }
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
                tilesAwaitingIDR = Set(tileSSRCs.indices)
                keyframeTargets = []
                requestedSinceWait = false
                dropsSinceRequest = 0
            }
        }
        // Already reported in enqueue; this only re-arms the wait if an IRAP
        // earlier in decoding order cleared it in the meantime.
        if everHadIDR, e.gapBefore || e.isLost {
            enterWait(tiles: scopeTiles(e.tile), lossyTile: e.tile, out: &out)
        }
        switch e.kind {
        case .noPicture, .lost:
            break
        case .picture(let au):
            if au.isIDR, parameterSets != nil {
                // An IRAP on any tile re-roots the shared DPB for every tile.
                everHadIDR = true
                tilesAwaitingIDR = []
                keyframeTargets = []
                requestedSinceWait = false
                dropsSinceRequest = 0
                stats.idrs += 1
                stats.accessUnits += 1
                out.append(.accessUnit(au))
            } else if tilesAwaitingIDR.contains(au.tile) || parameterSets == nil {
                stats.droppedWaitingForIDR += 1
                dropsSinceRequest += 1
                if keyframeTargets.isEmpty, let base = tileSSRCs.first { keyframeTargets = [base] }
                let due = requestedSinceWait
                    ? dropsSinceRequest >= config.keyframeRetryAfterDrops
                    : dropsSinceRequest >= config.coldStartGraceDrops
                if due { requestKeyframes(out: &out) }
            } else {
                stats.accessUnits += 1
                out.append(.accessUnit(au))
            }
        }
    }

    /// Loss on `tile` (nil = unknown tile, e.g. a DON hole).
    private func noteLoss(tile: Int?, out: inout [AssemblerOutput]) {
        stats.lossEvents += 1
        // Before the first IRAP every tile already waits, and the cold-start
        // grace paces requests: a burst that begins mid-AU is not news.
        guard everHadIDR else { return }
        enterWait(tiles: scopeTiles(tile), lossyTile: tile, out: &out)
    }

    private func scopeTiles(_ tile: Int?) -> Set<Int> {
        switch (config.scope, tile) {
        case (.lossyTile, let t?): [t]
        default: Set(tileSSRCs.indices)
        }
    }

    private func enterWait(tiles: Set<Int>, lossyTile: Int?, out: inout [AssemblerOutput]) {
        var targets: [UInt32] = []
        if let t = lossyTile, tileSSRCs.indices.contains(t) { targets.append(tileSSRCs[t]) }
        if let base = tileSSRCs.first, !targets.contains(base) { targets.append(base) }
        let newTiles = !tiles.isSubset(of: tilesAwaitingIDR)
        let newTargets = targets.filter { !keyframeTargets.contains($0) }
        tilesAwaitingIDR.formUnion(tiles)
        keyframeTargets += newTargets
        // Request on the transition into waiting (or for a newly lossy tile);
        // while already waiting, the drop counter paces re-requests.
        if newTiles || !newTargets.isEmpty { requestKeyframes(out: &out, only: requestedSinceWait ? newTargets : nil) }
    }

    private func requestKeyframes(out: inout [AssemblerOutput], only: [UInt32]? = nil) {
        for ssrc in only ?? keyframeTargets {
            stats.keyframeRequests += 1
            out.append(.needKeyframe(ssrc: ssrc))
        }
        requestedSinceWait = true
        dropsSinceRequest = 0
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
        _ = r.ue()                                  // sps_seq_parameter_set_id
        chromaFormatIdc = Int(r.ue())
        if chromaFormatIdc == 3 { r.skip(1) }       // separate_colour_plane_flag
        width = Int(r.ue())
        height = Int(r.ue())
        if r.bit() == 1 { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }   // conformance window
        bitDepthLuma = Int(r.ue()) + 8
        bitDepthChroma = Int(r.ue()) + 8
    }
}
