import XCTest
@testable import Screener

/// Synthetic RTP sender for the four tile SSRCs, building payloads in Apple's
/// format (DONL on single NALs, APs and every FU fragment).
private final class Sender {
    let ssrcs: [UInt32]
    var seq: [UInt32: UInt16] = [:]
    /// Arrival time stamped on the packets built next.
    var now = ContinuousClock.now

    static let vps = Data([0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF])
    static let sps = makeSPS(id: 0)
    static let pps = Data([0x44, 0x01, 0xC1, 0x73])       // pps_id ue '1' = 0

    /// A well-formed Main-profile SPS header (64x64 4:2:0) with `id`.
    static func makeSPS(id: UInt64) -> Data {
        var w = BitWriter()
        w.put(0, 4); w.put(0, 3); w.put(1, 1)              // vps id, max_sub_layers_minus1, nesting
        w.put(0, 2); w.put(0, 1); w.put(1, 5)              // profile space, tier, profile_idc
        w.put(0x6000_0000, 32); w.put(0, 48); w.put(93, 8)
        w.ue(id); w.ue(1); w.ue(64); w.ue(64); w.put(0, 1)
        w.ue(0); w.ue(0)
        var nal = Data([0x42, 0x01]); nal.append(w.bytesWithEmulationPrevention())
        return nal
    }

    /// A PPS whose pps_pic_parameter_set_id is `id` (sps id 0).
    static func makePPS(id: UInt64) -> Data {
        var w = BitWriter()
        w.ue(id); w.ue(0); w.put(0, 7)
        var nal = Data([0x44, 0x01]); nal.append(w.bytesWithEmulationPrevention())
        return nal
    }

    func advance(ms: Int) { now = now.advanced(by: .milliseconds(ms)) }

    init(_ ssrcs: [UInt32], startSeq: UInt16 = 100) {
        self.ssrcs = ssrcs
        for s in ssrcs { seq[s] = startSeq }
    }

    /// The slice NAL a picture carries (first_slice_segment_in_pic_flag set).
    static func slice(type: UInt8, don: UInt16, size: Int = 12) -> Data {
        var d = Data([type << 1, 0x01, 0x80 | UInt8(don & 0x3F)])
        d.append(contentsOf: (0..<max(0, size - 3)).map { UInt8(truncatingIfNeeded: Int(don) &+ $0) })
        return d
    }

    private func next(_ ssrc: UInt32) -> UInt16 {
        let s = seq[ssrc]!
        seq[ssrc] = s &+ 1
        return s
    }

    /// Simulates `n` packets on `tile` that never arrive.
    func lose(tile: Int, packets n: Int = 1) {
        let s = ssrcs[tile]
        seq[s] = seq[s]! &+ UInt16(n)
    }

    func packet(tile: Int, ts: UInt32, marker: Bool, _ payload: Data) -> MediaPacket {
        let ssrc = ssrcs[tile]
        return MediaPacket(ssrc: ssrc, seq: next(ssrc), timestamp: ts, marker: marker, payloadType: 100,
                           payload: payload, arrival: now)
    }

    static func apPayload(don: UInt16, _ nals: [Data]) -> Data {
        var d = Data([HEVCNAL.aggregation << 1, 0x01, UInt8(don >> 8), UInt8(don & 0xFF)])
        for n in nals { d.append(contentsOf: [UInt8(n.count >> 8), UInt8(n.count & 0xFF)]); d.append(n) }
        return d
    }

    static func singlePayload(_ nal: Data, don: UInt16) -> Data {
        var d = Data(nal.prefix(2)); d.append(contentsOf: [UInt8(don >> 8), UInt8(don & 0xFF)]); d.append(nal.dropFirst(2))
        return d
    }

    static func fuPayloads(_ nal: Data, don: UInt16, parts: Int) -> [Data] {
        let type = HEVCNAL.type(nal[0])
        let body = [UInt8](nal.dropFirst(2))
        let chunk = (body.count + parts - 1) / parts
        return (0..<parts).map { i in
            var fuHeader = type
            if i == 0 { fuHeader |= 0x80 }
            if i == parts - 1 { fuHeader |= 0x40 }
            var d = Data([(nal[0] & 0x81) | (HEVCNAL.fragmentation << 1), nal[1], fuHeader,
                          UInt8(don >> 8), UInt8(don & 0xFF)])
            d.append(contentsOf: body[min(i * chunk, body.count)..<min((i + 1) * chunk, body.count)])
            return d
        }
    }

    /// One access unit as RTP packets: optional VPS/SPS/PPS AP, then the
    /// slice as a single NAL or an FU, marker on the last packet.
    func picture(tile: Int, ts: UInt32, don: UInt16, type: UInt8 = 1, fragments: Int = 1,
                 params: Bool = false) -> [MediaPacket] {
        var payloads: [Data] = []
        if params { payloads.append(Self.apPayload(don: don, [Self.vps, Self.sps, Self.pps])) }
        let nal = Self.slice(type: type, don: don, size: fragments > 1 ? 40 : 12)
        payloads += fragments > 1 ? Self.fuPayloads(nal, don: don, parts: fragments) : [Self.singlePayload(nal, don: don)]
        return payloads.enumerated().map { i, p in
            packet(tile: tile, ts: ts, marker: i == payloads.count - 1, p)
        }
    }
}

private extension AssemblerOutput {
    var au: AccessUnit? { if case .accessUnit(let a) = self { a } else { nil } }
    var keyframeSSRC: UInt32? { if case .needKeyframe(let s) = self { s } else { nil } }
    var isParameterSets: Bool { if case .parameterSets = self { true } else { false } }
}

final class HEVCAssemblerTests: XCTestCase {
    private let ssrcs: [UInt32] = [0x4623_D60D, 0x4623_D60E, 0x4623_D60F, 0x4623_D610]

    private func feed(_ a: HEVCAssembler, _ pkts: [MediaPacket]) -> [AssemblerOutput] {
        pkts.flatMap { a.ingest($0) }
    }

    /// Assembler that has already taken its first IDR (DON 0, tile 0).
    private func warm(_ config: HEVCAssembler.Config = .init()) -> (HEVCAssembler, Sender) {
        let a = HEVCAssembler(tileSSRCs: ssrcs, config: config)
        let s = Sender(ssrcs)
        let out = feed(a, s.picture(tile: 0, ts: 1000, don: 0, type: 19, fragments: 3, params: true))
        XCTAssertEqual(out.compactMap(\.au).map(\.isIDR), [true])
        return (a, s)
    }

    // (a) in-order IDR with VPS/SPS/PPS on the base SSRC
    func testIDRWithParameterSetsOnBaseSSRC() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        let pkts = s.picture(tile: 0, ts: 9000, don: 100, type: 19, fragments: 3, params: true)
        XCTAssertEqual(pkts.count, 4)
        XCTAssertEqual(a.ingest(pkts[0]), [])
        XCTAssertEqual(a.ingest(pkts[1]), [])
        XCTAssertEqual(a.ingest(pkts[2]), [])
        let out = a.ingest(pkts[3])
        XCTAssertEqual(out, [
            .parameterSets(vps: Sender.vps, sps: Sender.sps, pps: [Sender.pps]),
            .accessUnit(AccessUnit(nalUnits: [Sender.slice(type: 19, don: 100, size: 40)], isIDR: true, tile: 0,
                                   rtpTimestamp: 9000, ssrc: ssrcs[0], don: 100)),
        ])
        XCTAssertEqual(a.parameterSets?.sps, Sender.sps)
        XCTAssertEqual(a.tilesAwaitingIDR, [])
        XCTAssertEqual(a.stats.idrs, 1)

        // Identical parameter sets with the next IDR are not re-emitted.
        let again = feed(a, s.picture(tile: 0, ts: 9400, don: 101, type: 19, fragments: 2, params: true))
        XCTAssertEqual(again.filter(\.isParameterSets).count, 0)
        XCTAssertEqual(again.compactMap(\.au).map(\.don), [101])
    }

    // (b) four SSRCs interleaved, released in DON order
    func testFourTilesReleasedInDONOrder() {
        let (a, s) = warm()
        let t2 = s.picture(tile: 2, ts: 2000, don: 3)
        let t1 = s.picture(tile: 1, ts: 2000, don: 2)
        let t0 = s.picture(tile: 0, ts: 2000, don: 1)
        let t3 = s.picture(tile: 3, ts: 2000, don: 4)
        XCTAssertEqual(feed(a, t2), [])
        XCTAssertEqual(feed(a, t1), [])
        XCTAssertEqual(feed(a, t3), [])
        let out = feed(a, t0)
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [1, 2, 3, 4])
        XCTAssertEqual(out.compactMap(\.au).map(\.tile), [0, 1, 2, 3])
        XCTAssertEqual(out.compactMap(\.au).map(\.ssrc), ssrcs)
        XCTAssertEqual(out.count, 4)
        // DONs 10–13 in the same shape, already in order: released at once.
        let next = [0, 1, 2, 3].map { feed(a, s.picture(tile: $0, ts: 2400, don: UInt16(5 + $0))) }
        XCTAssertEqual(next.map { $0.compactMap(\.au).map(\.don) }, [[5], [6], [7], [8]])
    }

    // (c) a sequence gap on a P picture: keyframe request, nothing until the next IDR
    func testSeqGapOnPFrameRequestsKeyframeAndHoldsUntilIDR() {
        var c = HEVCAssembler.Config(); c.scope = .allTiles
        let (a, s) = warm(c)
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 1)).compactMap(\.au).map(\.don), [1])
        s.lose(tile: 0)                                                  // DON 2 never arrives
        let out = feed(a, s.picture(tile: 0, ts: 3000, don: 3))
        XCTAssertEqual(out, [.needKeyframe(ssrc: ssrcs[0])])
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
        // Every tile now drops inter pictures (shared DPB, cross-tile refs).
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 3000, don: 4)), [])
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 4000, don: 5)), [])
        // The next IRAP (base SSRC) re-roots every tile.
        let idr = feed(a, s.picture(tile: 0, ts: 5000, don: 6, type: 19, fragments: 2))
        XCTAssertEqual(idr.compactMap(\.au).map { [Int($0.don), $0.isIDR ? 1 : 0] }, [[6, 1]])
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 5000, don: 7)).compactMap(\.au).map(\.don), [7])
        XCTAssertEqual(a.stats.lossEvents, 1)
        XCTAssertEqual(a.stats.droppedWaitingForIDR, 3)
    }

    func testLossOnOtherTileRequestsThatTileAndBase() {
        let (a, s) = warm()
        _ = feed(a, s.picture(tile: 2, ts: 1000, don: 2))
        s.lose(tile: 2, packets: 3)
        let out = feed(a, s.picture(tile: 2, ts: 2000, don: 6))
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[2], ssrcs[0]])
        XCTAssertTrue(out.compactMap(\.au).isEmpty)
    }

    // Default scope (reference ISS_PERTILE_RECOVERY): only the lossy tile waits.
    func testLossyTileScopeKeepsHealthyTilesFlowing() {
        let (a, s) = warm()
        XCTAssertEqual(feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)]).compactMap(\.au).map(\.don), [1, 2, 3])
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(0, 4), (1, 5)]).compactMap(\.au).map(\.don), [4, 5])
        s.lose(tile: 2)                                                 // DON 6 lost
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(3, 7)]), [])
        XCTAssertEqual(feedTiles(a, s, ts: 3000, [(0, 8), (1, 9)]), [])
        // Tile 2's next AU explains the hole at DON 6 (the interleave puts it
        // on tile 2): the held AUs go at once and only tile 2 waits.
        let out = feedTiles(a, s, ts: 3000, [(2, 10)])
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[2], ssrcs[0]])
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [7, 8, 9])
        XCTAssertEqual(a.tilesAwaitingIDR, [2])
        XCTAssertEqual(feedTiles(a, s, ts: 3000, [(3, 11)]).compactMap(\.au).map(\.don), [11])
        XCTAssertEqual(feedTiles(a, s, ts: 4000, [(0, 12), (1, 13), (2, 14)]).compactMap(\.au).map(\.don), [12, 13])
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 5000, don: 16, type: 19)), [])   // behind DON 15
        XCTAssertEqual(feedTiles(a, s, ts: 4000, [(3, 15)]).compactMap(\.au).map(\.don), [15, 16])
        XCTAssertEqual(feedTiles(a, s, ts: 5000, [(2, 18), (1, 17)]).compactMap(\.au).map(\.don), [17, 18])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
        XCTAssertEqual(a.stats.donHoles, 0)
    }

    func testKeyframeReRequestedWhileStillWaiting() {
        var c = HEVCAssembler.Config(); c.keyframeRetryAfterDrops = 3; c.scope = .allTiles
        let (a, s) = warm(c)
        s.lose(tile: 0)
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 2)), [.needKeyframe(ssrc: ssrcs[0])])
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 2000, don: 3)), [])
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 2000, don: 4)), [.needKeyframe(ssrc: ssrcs[0])])
        XCTAssertEqual(feed(a, s.picture(tile: 3, ts: 2000, don: 5)), [])
    }

    func testMissingMiddleFragmentDropsPictureAndReportsLoss() {
        let (a, s) = warm()
        var pkts = s.picture(tile: 1, ts: 2000, don: 1, fragments: 3)
        pkts.remove(at: 1)
        let out = feed(a, pkts)
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[1], ssrcs[0]])
        XCTAssertTrue(out.compactMap(\.au).isEmpty)
        XCTAssertEqual(a.stats.groupsIncomplete, 1)
    }

    func testIncompleteIDRIsNotEmitted() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        var pkts = s.picture(tile: 0, ts: 1000, don: 0, type: 19, fragments: 4, params: true)
        pkts.remove(at: 2)
        var out = feed(a, pkts)
        s.advance(ms: 70)
        out += a.tick(now: s.now)
        // Parameter sets in the intact AP still count; the picture does not.
        XCTAssertEqual(out.filter(\.isParameterSets).count, 1)
        XCTAssertTrue(out.compactMap(\.au).isEmpty)
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
    }

    func testColdStartDropsInterPicturesAndRequestsAfterGrace() {
        var c = HEVCAssembler.Config(); c.coldStartGraceDrops = 2
        let a = HEVCAssembler(tileSSRCs: ssrcs, config: c)
        let s = Sender(ssrcs)
        // Held while an IRAP may still complete; then released (and dropped).
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 1000, don: 5, params: true)), [])
        s.advance(ms: 70)
        let next = feed(a, s.picture(tile: 2, ts: 1000, don: 6))
        XCTAssertEqual(next.filter(\.isParameterSets).count, 1)
        XCTAssertTrue(next.compactMap(\.au).isEmpty)
        XCTAssertEqual(next.compactMap(\.keyframeSSRC), [ssrcs[0]])
        let idr = feed(a, s.picture(tile: 0, ts: 2000, don: 7, type: 19))
        XCTAssertEqual(idr.compactMap(\.au).map(\.isIDR), [true])
    }

    func testIDRWithoutParameterSetsIsHeld() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        XCTAssertTrue(feed(a, s.picture(tile: 0, ts: 1000, don: 0, type: 19)).compactMap(\.au).isEmpty)
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 1, type: 19, params: true)).compactMap(\.au).count, 1)
    }

    func testParameterSetsHarvestedAcrossGroups() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        let vpsOnly = s.packet(tile: 0, ts: 500, marker: true, Sender.apPayload(don: 0, [Sender.vps]))
        XCTAssertEqual(a.ingest(vpsOnly), [])
        let rest = s.packet(tile: 0, ts: 600, marker: true, Sender.apPayload(don: 1, [Sender.sps, Sender.pps]))
        XCTAssertEqual(a.ingest(rest), [])                      // cold start: held until the IRAP
        let out = feed(a, s.picture(tile: 0, ts: 1000, don: 2, type: 19))
        XCTAssertEqual(out.first, .parameterSets(vps: Sender.vps, sps: Sender.sps, pps: [Sender.pps]))
        XCTAssertEqual(out.compactMap(\.au).map(\.isIDR), [true])
    }

    func testGroupChangeResetsAndReharvests() {
        let (a, s) = warm()
        let newGroup: [UInt32] = [0x5000_0001, 0x5000_0002, 0x5000_0003, 0x5000_0004]
        a.resetForNewGroup(tileSSRCs: newGroup)
        XCTAssertNil(a.parameterSets)
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
        // The old group's packets are ignored.
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 1)), [])
        let n = Sender(newGroup)
        XCTAssertTrue(feed(a, n.picture(tile: 1, ts: 100, don: 50)).compactMap(\.au).isEmpty)
        // Same parameter sets as before, but a new group re-emits them.
        let out = feed(a, n.picture(tile: 0, ts: 500, don: 51, type: 19, params: true))
        XCTAssertEqual(out.filter(\.isParameterSets).count, 1)
        XCTAssertEqual(out.compactMap(\.au).map(\.ssrc), [newGroup[0]])
    }

    func testNotHEVCDetected() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        // Apple's avcC config packet, an H.264 FU-A and an IDR slice.
        XCTAssertEqual(a.ingest(s.packet(tile: 0, ts: 1, marker: true, Data([0x92, 0x00, 0x01, 0x42]))), [])
        XCTAssertEqual(a.ingest(s.packet(tile: 0, ts: 2, marker: false, Data([0x7C, 0x85, 0x88, 0x84]))), [])
        XCTAssertEqual(a.ingest(s.packet(tile: 0, ts: 2, marker: true, Data([0x65, 0x88, 0x84, 0x00]))), [.notHEVC])
        XCTAssertTrue(a.isNotHEVC)
        XCTAssertEqual(a.ingest(s.packet(tile: 0, ts: 3, marker: true, Data([0x65, 0x88, 0x84, 0x00]))), [])
    }

    func testHEVCStreamIsNotFlaggedOnceParameterSetsArrive() {
        let (a, s) = warm()
        for b: UInt8 in [0x92, 0x7C, 0x65, 0x78] {
            _ = a.ingest(s.packet(tile: 3, ts: 7, marker: false, Data([b, 0x01, 0x00, 0x00])))
        }
        XCTAssertFalse(a.isNotHEVC)
    }

    func testLateAndDuplicatePacketsIgnored() {
        let (a, s) = warm()
        let p = s.picture(tile: 1, ts: 2000, don: 1, fragments: 2)
        XCTAssertEqual(a.ingest(p[0]), [])
        XCTAssertEqual(a.ingest(p[0]), [])                     // duplicate
        XCTAssertEqual(a.ingest(p[1]).compactMap(\.au).map(\.don), [1])
        XCTAssertEqual(a.ingest(p[1]), [])                     // group already flushed
        XCTAssertEqual(a.stats.duplicatePackets, 1)
        XCTAssertEqual(a.stats.latePackets, 1)
    }

    func testSequenceWrapInsideOneGroup() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs, startSeq: 65534)
        var pkts = s.picture(tile: 0, ts: 1000, don: 0, type: 19, fragments: 3, params: true)
        XCTAssertEqual(pkts.map(\.seq), [65534, 65535, 0, 1])
        pkts.swapAt(1, 2)                                      // reordered inside the group
        XCTAssertEqual(feed(a, pkts).compactMap(\.au).map(\.isIDR), [true])
        XCTAssertEqual(a.stats.groupsIncomplete, 0)
    }

    func testGroupWhoseMarkerIsLostCountsAsLoss() {
        let (a, s) = warm()
        var lostTail = s.picture(tile: 0, ts: 2000, don: 1, fragments: 3)
        lostTail.removeLast()                                  // marker packet lost
        XCTAssertEqual(feed(a, lostTail), [])
        let out = feed(a, s.picture(tile: 0, ts: 3000, don: 2))
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[0]])
        XCTAssertTrue(out.compactMap(\.au).isEmpty)
        XCTAssertEqual(a.stats.groupsEvicted, 1)
    }

    func testWholeAccessUnitLostOnAnotherTileIsADONHole() {
        let (a, s) = warm()
        // DON 1 (tile 1) vanishes completely; tile 1 sends nothing else yet.
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1000, don: 2)), [])
        XCTAssertEqual(feed(a, s.picture(tile: 3, ts: 1000, don: 3)), [])
        s.advance(ms: 30)
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 4)), [])   // inside the window
        s.advance(ms: 40)
        let out = a.tick(now: s.now)
        // Tiles 0, 2 and 3 already sent later DONs: only tile 1 can own DON 1.
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[1], ssrcs[0]])
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [2, 3, 4])
        XCTAssertEqual(a.tilesAwaitingIDR, [1])
        XCTAssertEqual(a.stats.donHoles, 1)
    }

    // DON 1 cannot be tile 0's (its AUs 0 and 2 came with no sequence gap):
    // the tiles that sent nothing after it wait, tile 0 keeps going.
    func testDONHoleGatesOnlyTheTilesThatCanOwnIt() {
        let (a, s) = warm()
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 2)), [])
        s.advance(ms: 70)
        let out = a.tick(now: s.now)
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[1], ssrcs[2], ssrcs[3], ssrcs[0]])
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [2])
        XCTAssertEqual(a.tilesAwaitingIDR, [1, 2, 3])
        XCTAssertEqual(a.stats.donHoles, 1)
    }

    // Apple's encoder skips tiles with nothing new, and the DON counter does
    // not count them (live, 2026-11-18: motion in the top-left corner sent
    // tiles {0,1} in ~60% of the pictures, all four in ~35%, {0,1,3} in the
    // rest; DONs stayed contiguous). A skipped tile is not a loss.
    func testSkippedTilesAreNotLoss() {
        let (a, s) = warm()
        var don: UInt16 = 1
        var emitted: [UInt16] = []
        for (i, tiles) in [[1, 2, 3], [0, 1], [0, 1], [0, 1, 2, 3], [0, 1, 3], [3], [0, 2, 3], [0, 1]].enumerated() {
            let tileDONs = tiles.map { t -> (Int, UInt16) in defer { don += 1 }; return (t, don) }
            emitted += feedTiles(a, s, ts: UInt32(1000 + 400 * i), tileDONs).compactMap(\.au).map(\.don)
            s.advance(ms: 17)
            emitted += a.tick(now: s.now).compactMap(\.au).map(\.don)
        }
        XCTAssertEqual(emitted, Array(1..<don))
        XCTAssertEqual(a.stats.keyframeRequests, 0)
        XCTAssertEqual(a.stats.droppedWaitingForIDR, 0)
        XCTAssertEqual(a.stats.donHoles, 0)
        XCTAssertEqual(a.tilesAwaitingIDR, [])
    }

    // After skipped tiles, a whole lost AU is put on the tile that can own
    // it, not on the one a fixed tile interleave would name: DON 7 here was
    // tile 3's, where (DON − IDR DON) mod 4 says tile 2.
    func testHoleAfterSkippedTilesGatesTheTileThatCanOwnIt() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        _ = feedTiles(a, s, ts: 1400, [(0, 4), (1, 5)])                 // tiles 2, 3 skipped
        XCTAssertEqual(feedTiles(a, s, ts: 1800, [(0, 6)]).compactMap(\.au).map(\.don), [6])
        s.lose(tile: 3)                                                 // DON 7 (tile 3) vanishes
        XCTAssertEqual(feedTiles(a, s, ts: 2200, [(0, 8), (1, 9), (2, 10)]), [])
        s.advance(ms: 70)
        let out = a.tick(now: s.now)
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[3], ssrcs[0]])
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [8, 9, 10])
        XCTAssertEqual(a.tilesAwaitingIDR, [3])
        // Tile 3's next AU shows the sequence gap; it waits for an IRAP.
        XCTAssertEqual(feedTiles(a, s, ts: 2600, [(0, 11), (3, 12)]).compactMap(\.au).map(\.don), [11])
    }

    func testGroupSpanningTwoDONsAdvancesExpectedDON() {
        let (a, s) = warm()
        // A param-set AP with its own DON in front of the picture's DON.
        let ap = s.packet(tile: 0, ts: 2000, marker: false, Sender.apPayload(don: 1, [Sender.vps, Sender.sps, Sender.pps]))
        let nal = Sender.slice(type: 1, don: 2)
        let pic = s.packet(tile: 0, ts: 2000, marker: true, Sender.singlePayload(nal, don: 2))
        XCTAssertEqual(feed(a, [ap, pic]).compactMap(\.au).map(\.don), [1])   // AU tagged with its first DON
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 2000, don: 3)).compactMap(\.au).map(\.don), [3])
    }

    func testSPSInfo() throws {
        // profile 4 (RExt), 4:4:4, 1280x1708, 8-bit: an Apple-shaped SPS.
        var w = BitWriter()
        w.put(0, 4); w.put(0, 3); w.put(1, 1)              // vps id, max_sub_layers_minus1, nesting
        w.put(0, 2); w.put(0, 1); w.put(4, 5)              // profile space, tier, profile_idc
        w.put(0x0800_0000, 32); w.put(0, 48); w.put(123, 8)
        w.ue(0); w.ue(3); w.put(0, 1)                      // sps id, chroma 4:4:4, separate planes
        w.ue(1280); w.ue(1708); w.put(0, 1)
        w.ue(0); w.ue(0)
        var nal = Data([0x42, 0x01]); nal.append(w.bytesWithEmulationPrevention())
        let info = try XCTUnwrap(HEVCSPSInfo(sps: nal))
        XCTAssertEqual([info.profileIdc, info.chromaFormatIdc, info.width, info.height, info.bitDepthLuma,
                        info.bitDepthChroma], [4, 3, 1280, 1708, 8, 8])
        XCTAssertNil(HEVCSPSInfo(sps: Sender.pps))
    }

    func testBitReaderRemovesEmulationPrevention() {
        var r = HEVCBitReader(rbsp: [0x00, 0x00, 0x03, 0x01, 0x80])
        XCTAssertEqual(r.bits(24), 0x000001)
        XCTAssertEqual(r.ue(), 0)
    }

    // MARK: - review fixes

    /// Feeds one picture per (tile, DON) at `ts`, in the order given.
    private func feedTiles(_ a: HEVCAssembler, _ s: Sender, ts: UInt32, _ tileDONs: [(Int, UInt16)],
                           type: UInt8 = 1) -> [AssemblerOutput] {
        tileDONs.flatMap { feed(a, s.picture(tile: $0.0, ts: ts, don: $0.1, type: type)) }
    }

    // A hole explained by an old loss must not let a later out-of-order
    // tile jump ahead once an IRAP has moved decoding past it.
    func testStaleExplainedHoleDoesNotSkipAfterIDR() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        _ = feedTiles(a, s, ts: 2000, [(0, 4)])
        s.lose(tile: 1)                                                 // DON 5 lost
        _ = feedTiles(a, s, ts: 2000, [(2, 6), (3, 7)])
        _ = feedTiles(a, s, ts: 3000, [(0, 8), (1, 9), (2, 10), (3, 11)])  // 9: gap before
        let idr = feed(a, s.picture(tile: 0, ts: 4000, don: 12, type: 19, fragments: 2))
        XCTAssertEqual(idr.compactMap(\.au).map(\.isIDR), [true])
        XCTAssertEqual(feedTiles(a, s, ts: 4000, [(1, 13), (2, 14), (3, 15)]).compactMap(\.au).map(\.don), [13, 14, 15])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
        // Tile 2 completes before tiles 0 and 1.
        let after = feedTiles(a, s, ts: 5000, [(2, 18), (0, 16), (1, 17), (3, 19)])
        XCTAssertEqual(after.compactMap(\.keyframeSSRC), [])
        XCTAssertEqual(after.compactMap(\.au).map(\.don), [16, 17, 18, 19])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
    }

    // Cold start: tile 0's IDR completes after tiles 1–3 of the same timestamp.
    func testColdStartIRAPCompletingLastIsEmittedFirst() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        var out = feedTiles(a, s, ts: 1000, [(1, 101), (2, 102), (3, 103)])
        out += feed(a, s.picture(tile: 0, ts: 1000, don: 100, type: 19, fragments: 3, params: true))
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [100, 101, 102, 103])
        XCTAssertEqual(out.compactMap(\.au).first?.isIDR, true)
        XCTAssertEqual(out.filter(\.isParameterSets).count, 1)
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [])
    }

    // After loss with every tile waiting, the IRAP must still be processed
    // before tiles 1–3 of its timestamp (they are not skipped past it).
    func testIRAPAfterLossCompletingLastIsEmittedFirst() {
        var c = HEVCAssembler.Config(); c.scope = .allTiles
        let (a, s) = warm(c)
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        s.lose(tile: 0)                                                 // DON 4 lost
        _ = feedTiles(a, s, ts: 2000, [(1, 5), (2, 6), (3, 7)])
        let loss = feedTiles(a, s, ts: 3000, [(0, 8), (1, 9), (2, 10), (3, 11)])
        XCTAssertEqual(loss.compactMap(\.keyframeSSRC), [ssrcs[0]])
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
        var out = feedTiles(a, s, ts: 4000, [(1, 13), (2, 14), (3, 15)])
        out += feed(a, s.picture(tile: 0, ts: 4000, don: 12, type: 19, fragments: 3))
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [12, 13, 14, 15])
        XCTAssertEqual(out.compactMap(\.au).first?.isIDR, true)
    }

    // Loss gating applies at the loss's decode position: an earlier-DON
    // healthy AU still in the reorder buffer is not dropped.
    func testLossGatesAtDecodePositionNotArrival() {
        var c = HEVCAssembler.Config(); c.scope = .allTiles
        let (a, s) = warm(c)
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        _ = feedTiles(a, s, ts: 2000, [(0, 4)])
        s.lose(tile: 2)
        let early = feed(a, s.picture(tile: 2, ts: 2000, don: 6))       // gap before; DON 5 not in yet
        XCTAssertEqual(early.compactMap(\.keyframeSSRC), [ssrcs[2], ssrcs[0]])   // FIR at once
        XCTAssertEqual(early.compactMap(\.au), [])
        let out = feed(a, s.picture(tile: 1, ts: 2000, don: 5))
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [5])
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
    }

    // Two entries with one DON: the first is kept, the second's parameter
    // sets are not lost.
    func testDuplicateDONKeepsFirstAndMergesParameterSets() {
        let (a, s) = warm()
        let pps1 = Sender.makePPS(id: 1)
        let ap = s.packet(tile: 2, ts: 1000, marker: true, Sender.apPayload(don: 2, [Sender.vps, Sender.sps, pps1]))
        XCTAssertEqual(a.ingest(ap), [])                                // held behind DON 1
        // The second (a picture) is discarded, so tile 2 lost a picture.
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1100, don: 2)).compactMap(\.keyframeSSRC), [ssrcs[2], ssrcs[0]])
        let out = feed(a, s.picture(tile: 1, ts: 1000, don: 1))
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [1])
        XCTAssertEqual(out.filter(\.isParameterSets), [.parameterSets(vps: Sender.vps, sps: Sender.sps,
                                                                        pps: [Sender.pps, pps1])])
    }

    // An entry without a DON does not jump ahead of held entries.
    func testEntryWithoutDONWaitsBehindHeldEntries() {
        var c = HEVCAssembler.Config(); c.scope = .allTiles
        let (a, s) = warm(c)
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1000, don: 2)), [])
        s.lose(tile: 0)
        let junk = a.ingest(s.packet(tile: 0, ts: 1100, marker: true, Data([0x02, 0x01, 0x00])))  // no DONL
        XCTAssertEqual(junk.compactMap(\.keyframeSSRC), [ssrcs[0]])
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 1000, don: 1)).compactMap(\.au).map(\.don), [1, 2])
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
    }

    // An IRAP completing after the reorder window is still emitted.
    func testIRAPLaterThanWindowIsStillEmitted() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        let idr = s.picture(tile: 0, ts: 2000, don: 4, type: 19, fragments: 2)   // delayed in the network
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(1, 5), (2, 6), (3, 7)]), [])
        s.advance(ms: 100)
        let ticked = a.tick(now: s.now)
        XCTAssertEqual(ticked.compactMap(\.keyframeSSRC), [ssrcs[0]])
        XCTAssertEqual(ticked.compactMap(\.au).map(\.don), [5, 6, 7])   // healthy tiles flow
        XCTAssertEqual(a.tilesAwaitingIDR, [0])
        let late = feed(a, idr)
        XCTAssertEqual(late.compactMap(\.au).map(\.isIDR), [true])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
        XCTAssertEqual(a.stats.lateIRAPs, 1)
        XCTAssertEqual(feedTiles(a, s, ts: 3000, [(0, 8), (1, 9)]).compactMap(\.au).map(\.don), [8, 9])
    }

    // A hole whose AU is visibly still arriving is waited for past the window.
    func testInFlightIRAPIsWaitedForPastWindow() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        let idr = s.picture(tile: 0, ts: 2000, don: 4, type: 19, fragments: 3)
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(1, 5), (2, 6), (3, 7)]), [])
        s.advance(ms: 50)
        XCTAssertEqual(a.ingest(MediaPacket(ssrc: idr[0].ssrc, seq: idr[0].seq, timestamp: 2000, marker: false,
                                            payloadType: 100, payload: idr[0].payload, arrival: s.now)), [])
        s.advance(ms: 20)
        XCTAssertEqual(a.tick(now: s.now), [])                          // 70 ms, but the IDR is arriving
        let out = feed(a, Array(idr.dropFirst()))
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [4, 5, 6, 7])
        XCTAssertEqual(out.compactMap(\.au).first?.isIDR, true)
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [])
    }

    func testTickEvictsGroupWhoseMarkerNeverCame() {
        let (a, s) = warm()
        let pkts = s.picture(tile: 1, ts: 1000, don: 1, fragments: 3)
        XCTAssertEqual(feed(a, Array(pkts.prefix(2))), [])
        s.advance(ms: 30)
        XCTAssertEqual(a.tick(now: s.now), [])
        s.advance(ms: 280)                                              // pendingGroupTimeout (300 ms)
        XCTAssertEqual(a.tick(now: s.now).compactMap(\.keyframeSSRC), [ssrcs[1], ssrcs[0]])
        XCTAssertEqual(a.stats.groupsEvicted, 1)
        XCTAssertEqual(a.tilesAwaitingIDR, [1])
        XCTAssertEqual(a.ingest(pkts[2]), [])                           // its marker, too late
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1000, don: 2)).compactMap(\.au).map(\.don), [2])
    }

    func testDecodeErrorEscalatesToAllTilesUntilIRAP() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        XCTAssertEqual(a.noteDecodeError(tile: 2), [.needKeyframe(ssrc: ssrcs[2]), .needKeyframe(ssrc: ssrcs[0])])
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(0, 4), (1, 5), (2, 6), (3, 7)]).compactMap(\.au), [])
        XCTAssertEqual(a.noteDecodeError(tile: 2), [])                  // already asked this wait
        let idr = feed(a, s.picture(tile: 0, ts: 3000, don: 8, type: 19))
        XCTAssertEqual(idr.compactMap(\.au).map(\.isIDR), [true])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
        // Back to per-tile scope after the IRAP.
        _ = feedTiles(a, s, ts: 3000, [(1, 9), (2, 10), (3, 11)])
        s.lose(tile: 3)
        _ = feedTiles(a, s, ts: 4000, [(0, 12), (1, 13), (2, 14), (3, 15)])
        XCTAssertEqual(a.tilesAwaitingIDR, [3])
        XCTAssertEqual(a.stats.decodeErrors, 2)
    }

    func testDuplicateTileSSRCsDoNotTrap() {
        let a = HEVCAssembler(tileSSRCs: [ssrcs[0], ssrcs[1], ssrcs[0], ssrcs[1]])
        XCTAssertEqual(a.tileSSRCs, [ssrcs[0], ssrcs[1]])
        XCTAssertEqual(a.tilesAwaitingIDR, [0, 1])
        let s = Sender(ssrcs)
        let out = feed(a, s.picture(tile: 0, ts: 1000, don: 0, type: 19, params: true))
        XCTAssertEqual(out.compactMap(\.au).map(\.tile), [0])
        a.resetForNewGroup(tileSSRCs: [ssrcs[3], ssrcs[3]])
        XCTAssertEqual(a.tileSSRCs, [ssrcs[3]])
    }

    // RASL after a CRA that starts decoding cannot be decoded; after a CRA
    // in a healthy stream it can.
    func testRASLDroppedAfterRecoveryCRAOnly() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 1000, don: 0, type: 21, params: true)).compactMap(\.au).map(\.isIDR), [true])
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 1000, don: 1, type: 8)).compactMap(\.au), [])
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1000, don: 2, type: 1)).compactMap(\.au).map(\.don), [2])
        XCTAssertEqual(a.stats.droppedRASL, 1)
        _ = feedTiles(a, s, ts: 1000, [(3, 3)])
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 4, type: 21)).compactMap(\.au).map(\.don), [4])
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 2000, don: 5, type: 9)).compactMap(\.au).map(\.don), [5])
    }

    func testHostileParameterSetIDsAreRejected() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        // PPS id 64 and an all-zero (huge ue) PPS are dropped; id 63 is kept.
        let pps63 = Sender.makePPS(id: 63)
        let ap = Sender.apPayload(don: 0, [Sender.vps, Sender.sps, Sender.makePPS(id: 64), Data([0x44, 0x01, 0, 0, 0, 0, 0]), pps63])
        XCTAssertEqual(a.ingest(s.packet(tile: 0, ts: 1, marker: true, ap)), [])   // held until an IRAP
        XCTAssertEqual(a.parameterSets?.pps, [pps63])
        XCTAssertEqual(a.stats.rejectedParameterSets, 2)
        // SPS id 16 is not cached.
        let b = HEVCAssembler(tileSSRCs: ssrcs)
        let bad = Sender.apPayload(don: 0, [Sender.vps, Sender.makeSPS(id: 16), Sender.pps])
        XCTAssertEqual(b.ingest(s.packet(tile: 1, ts: 1, marker: true, bad)), [])
        XCTAssertNil(b.parameterSets)
        XCTAssertEqual(HEVCSPSInfo(sps: Sender.makeSPS(id: 15))?.spsID, 15)
    }

    // MARK: - re-review fixes

    // An IRAP processed late clears only gates from losses before it in
    // decoding order: tile 2's loss at DON 106 survives the IRAP at DON 100.
    func testLateIRAPDoesNotClearLaterGate() {
        let a = HEVCAssembler(tileSSRCs: ssrcs)
        let s = Sender(ssrcs)
        let first = feed(a, s.picture(tile: 0, ts: 1000, don: 96, type: 19, params: true))
        XCTAssertEqual(first.compactMap(\.au).map(\.isIDR), [true])
        _ = feedTiles(a, s, ts: 1000, [(1, 97), (2, 98), (3, 99)])
        // Tile 0's IRAP (DON 100) is delayed past the window; it is built
        // below, after tile 0's next AU, so tile 0 shows no sequence gap.
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(1, 101), (2, 102), (3, 103)]), [])
        s.advance(ms: 100)
        XCTAssertEqual(a.tick(now: s.now).compactMap(\.au).map(\.don), [101, 102, 103])
        XCTAssertEqual(a.tilesAwaitingIDR, [0])
        s.lose(tile: 2)                                                 // gap before DON 106
        let loss = feedTiles(a, s, ts: 3000, [(0, 104), (1, 105), (2, 106), (3, 107)])
        XCTAssertEqual(loss.compactMap(\.au).map(\.don), [105, 107])
        XCTAssertEqual(a.tilesAwaitingIDR, [0, 2])
        let idr = s.picture(tile: 0, ts: 2000, don: 100, type: 19, fragments: 2)
        XCTAssertEqual(feed(a, idr).compactMap(\.au).map(\.don), [100])   // late IRAP still emitted
        XCTAssertEqual(a.tilesAwaitingIDR, [2])
        let next = feedTiles(a, s, ts: 4000, [(0, 108), (1, 109), (2, 110), (3, 111)])
        XCTAssertEqual(next.compactMap(\.au).map(\.don), [108, 109, 111])
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 5000, don: 112, type: 19)).compactMap(\.au).map(\.don), [112])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
        XCTAssertEqual(feedTiles(a, s, ts: 5000, [(1, 113), (2, 114)]).compactMap(\.au).map(\.don), [113, 114])
    }

    // A decode-error escalation is gated at the reported DON: an IRAP that
    // precedes it in decoding order does not lift it.
    func testLateIRAPDoesNotClearLaterDecodeErrorEscalation() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        let idr = s.picture(tile: 0, ts: 2000, don: 4, type: 19, fragments: 2)   // delayed
        _ = feedTiles(a, s, ts: 2000, [(1, 5), (2, 6), (3, 7)])
        s.advance(ms: 100)
        XCTAssertEqual(a.tick(now: s.now).compactMap(\.au).map(\.don), [5, 6, 7])
        _ = a.noteDecodeError(tile: 2, don: 6)
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
        XCTAssertEqual(feed(a, idr).compactMap(\.au).map(\.don), [4])
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
        XCTAssertEqual(feedTiles(a, s, ts: 3000, [(0, 8), (1, 9), (2, 10), (3, 11)]).compactMap(\.au), [])
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 4000, don: 12, type: 19)).compactMap(\.au).map(\.don), [12])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
    }

    // A decoder error reported (asynchronously) for a picture before the
    // last IRAP is stale: the IRAP already re-rooted everything.
    func testStaleDecodeErrorBeforeLastIRAPIsIgnored() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 2000, don: 4, type: 19)).compactMap(\.au).map(\.don), [4])
        XCTAssertEqual(a.noteDecodeError(tile: 2, don: 2), [])
        XCTAssertEqual(a.tilesAwaitingIDR, [])
        XCTAssertEqual(a.stats.decodeErrors, 0)
        XCTAssertEqual(a.stats.staleDecodeErrors, 1)
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(1, 5)]).compactMap(\.au).map(\.don), [5])
        // At or after the IRAP: a real error.
        XCTAssertEqual(a.noteDecodeError(tile: 1, don: 5), [.needKeyframe(ssrc: ssrcs[1]), .needKeyframe(ssrc: ssrcs[0])])
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
        XCTAssertEqual(a.stats.decodeErrors, 1)
    }

    // A hole that a sequence gap explains, and that only the lossy tile can
    // own (between tiles 0 and 2 of one picture), is not waited for and
    // gates only that tile, with a tile skipped before it (tile 2 sent
    // nothing at ts 1000).
    func testExplainedHoleAfterSkippedTileGatesOnlyTheLossyTile() {
        let (a, s) = warm()
        XCTAssertEqual(feedTiles(a, s, ts: 1000, [(1, 1), (3, 2)]).compactMap(\.au).map(\.don), [1, 2])
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(0, 3)]).compactMap(\.au).map(\.don), [3])
        s.lose(tile: 1)                                                 // DON 4 (tile 1) lost
        XCTAssertEqual(feedTiles(a, s, ts: 2000, [(2, 5), (3, 6)]), [])
        let out = feed(a, s.picture(tile: 1, ts: 2400, don: 7))         // gap before
        XCTAssertEqual(out.compactMap(\.keyframeSSRC), [ssrcs[1], ssrcs[0]])
        XCTAssertEqual(out.compactMap(\.au).map(\.don), [5, 6])
        XCTAssertEqual(a.tilesAwaitingIDR, [1])
        XCTAssertEqual(a.stats.donHoles, 0)
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 2400, don: 8)).compactMap(\.au).map(\.don), [8])
    }

    // A sequence gap on one tile does not explain a hole another tile may
    // still fill: DON 5 sits between tiles 0 and 2 of one picture, so it is
    // tile 1's, whatever tile 2 lost.
    func testExplainedLossOnOneTileStillWaitsForAnotherTilesAU() {
        let (a, s) = warm()
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        _ = feedTiles(a, s, ts: 2000, [(0, 4)])
        s.lose(tile: 2)
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 2000, don: 6)).compactMap(\.au), [])
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 2000, don: 5)).compactMap(\.au).map(\.don), [5])
        XCTAssertEqual(a.tilesAwaitingIDR, [2])
    }

    // Pending groups are evicted after their own timeout, not the 60 ms
    // reorder window.
    func testPendingGroupEvictionUsesItsOwnTimeout() {
        var c = HEVCAssembler.Config(); c.pendingGroupTimeout = .milliseconds(300)
        let (a, s) = warm(c)
        let pkts = s.picture(tile: 1, ts: 1000, don: 1, fragments: 3)
        XCTAssertEqual(feed(a, Array(pkts.prefix(2))), [])
        s.advance(ms: 100)
        XCTAssertEqual(a.tick(now: s.now), [])
        XCTAssertEqual(a.stats.groupsEvicted, 0)
        s.advance(ms: 210)
        XCTAssertEqual(a.tick(now: s.now).compactMap(\.keyframeSSRC), [ssrcs[1], ssrcs[0]])
        XCTAssertEqual(a.stats.groupsEvicted, 1)
    }

    // Packets that arrive out of order are not lost.
    func testReorderedPacketsAreNotCountedAsLost() {
        let (a, s) = warm()
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 1000, don: 1)).compactMap(\.au).map(\.don), [1])
        let p = s.picture(tile: 1, ts: 2000, don: 5, fragments: 3)
        _ = feedTiles(a, s, ts: 1500, [(2, 2), (3, 3), (0, 4)])
        XCTAssertEqual(feed(a, [p[1], p[0], p[2]]).compactMap(\.au).map(\.don), [5])
        XCTAssertEqual(a.stats.lostPackets, 0)
        s.lose(tile: 1)
        _ = feed(a, s.picture(tile: 1, ts: 3000, don: 9))
        XCTAssertEqual(a.stats.lostPackets, 1)
    }

    // DON ordering switched off by a run of late DONs comes back on an IRAP.
    func testDONOrderingIsReenabledByIRAP() {
        var c = HEVCAssembler.Config(); c.lateDONLimit = 2
        let (a, s) = warm(c)
        _ = feedTiles(a, s, ts: 1000, [(1, 1), (2, 2), (3, 3)])
        _ = feedTiles(a, s, ts: 2000, [(1, 1), (2, 2)])                 // late DONs
        XCTAssertFalse(a.stats.donOrdering)
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 3000, don: 4, type: 19)).compactMap(\.au).map(\.don), [4])
        XCTAssertTrue(a.stats.donOrdering)
        XCTAssertEqual(feedTiles(a, s, ts: 3000, [(2, 6), (1, 5)]).compactMap(\.au).map(\.don), [5, 6])
    }

    // MARK: - replay of a real capture (local only)

    /// Replays a DEBUG capture (VideoCaptureFile) through the assembler and
    /// checks its invariants. Skipped unless SCREENER_HEVC_CAPTURE points at
    /// a capture (xcodebuild: TEST_RUNNER_SCREENER_HEVC_CAPTURE=<path>).
    /// Captures hold screen images: keep them out of the repository.
    func testReplayCapture() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENER_HEVC_CAPTURE"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no capture (set TEST_RUNNER_SCREENER_HEVC_CAPTURE)")
        }
        let records = try VideoCaptureFile.read(URL(fileURLWithPath: path))
        let base = ContinuousClock.now
        let group = Array(Set(records.map(\.ssrc))).sorted()
        let a = HEVCAssembler(tileSSRCs: group)
        var aus: [AccessUnit] = [], keyframes = 0, params: [Data] = [], notHEVC = false
        for r in records {
            for o in a.ingest(r.packet(base: base)) {
                switch o {
                case .accessUnit(let au): aus.append(au)
                case .needKeyframe: keyframes += 1
                case .parameterSets(_, let sps, _): params.append(sps)
                case .notHEVC: notHEVC = true
                }
            }
        }
        XCTAssertFalse(notHEVC)
        // DON order, and nothing before an IRAP.
        for (x, y) in zip(aus, aus.dropFirst()) { XCTAssertLessThan(y.don &- x.don, 0x8000) }
        if let first = aus.first { XCTAssertTrue(first.isIDR) }
        let span = Double((records.last?.arrivalNanos ?? 0) - (records.first?.arrivalNanos ?? 0)) / 1e9
        let spsInfo = params.last.flatMap { HEVCSPSInfo(sps: $0) }
        let msg = "replay: \(records.count) pkts over \(String(format: "%.2f", span)) s, ssrcs=\(group.count), "
            + "AUs=\(aus.count) (\(String(format: "%.1f", Double(aus.count) / max(span, 0.001)))/s) "
            + "IDRs=\(aus.filter(\.isIDR).count) keyframeReqs=\(keyframes) paramSets=\(params.count) "
            + "sps=\(spsInfo.map { "profile=\($0.profileIdc) chroma=\($0.chromaFormatIdc) \($0.width)x\($0.height)" } ?? "-") "
            + "stats=\(a.stats)"
        print(msg)
        add(XCTAttachment(string: msg))
    }
}

/// MSB-first bit writer for building test SPS NALs.
private struct BitWriter {
    var bytes: [UInt8] = []
    var bitCount = 0

    mutating func put(_ value: UInt64, _ n: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if (value >> UInt64(i)) & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount % 8) }
            bitCount += 1
        }
    }

    mutating func ue(_ v: UInt64) {
        let x = v + 1
        let len = 64 - x.leadingZeroBitCount
        put(0, len - 1)
        put(x, len)
    }

    func bytesWithEmulationPrevention() -> Data {
        var out = Data(), zeros = 0
        for b in bytes + [0x80] {                          // + rbsp trailing bits
            if zeros >= 2, b <= 3 { out.append(3); zeros = 0 }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }
}
