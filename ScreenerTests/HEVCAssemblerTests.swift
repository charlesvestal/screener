import XCTest
@testable import Screener

/// Synthetic RTP sender for the four tile SSRCs, building payloads in Apple's
/// format (DONL on single NALs, APs and every FU fragment).
private final class Sender {
    let ssrcs: [UInt32]
    var seq: [UInt32: UInt16] = [:]
    let clock = ContinuousClock.now

    static let vps = Data([0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF])
    static let sps = Data([0x42, 0x01, 0x01, 0x04, 0x08, 0x00])
    static let pps = Data([0x44, 0x01, 0xC1, 0x73])       // pps_id ue '1' = 0

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
                           payload: payload, arrival: clock)
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
        let (a, s) = warm()
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

    func testLossyTileScopeKeepsHealthyTilesFlowing() {
        var c = HEVCAssembler.Config(); c.scope = .lossyTile
        let (a, s) = warm(c)
        XCTAssertEqual(feed(a, s.picture(tile: 1, ts: 1000, don: 1)).compactMap(\.au).map(\.don), [1])
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1000, don: 2)).compactMap(\.au).map(\.don), [2])
        s.lose(tile: 2)
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 2000, don: 6)).compactMap(\.keyframeSSRC), [ssrcs[2], ssrcs[0]])
        XCTAssertEqual(a.tilesAwaitingIDR, [2])
        XCTAssertEqual(feed(a, s.picture(tile: 3, ts: 2000, don: 7)).compactMap(\.au).map(\.don), [7])
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 3000, don: 10)), [])
    }

    func testKeyframeReRequestedWhileStillWaiting() {
        var c = HEVCAssembler.Config(); c.keyframeRetryAfterDrops = 3
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
        let out = feed(a, pkts)
        // Parameter sets in the intact AP still count; the picture does not.
        XCTAssertEqual(out.filter(\.isParameterSets).count, 1)
        XCTAssertTrue(out.compactMap(\.au).isEmpty)
        XCTAssertEqual(a.tilesAwaitingIDR, Set(0..<4))
    }

    func testColdStartDropsInterPicturesAndRequestsAfterGrace() {
        var c = HEVCAssembler.Config(); c.coldStartGraceDrops = 2
        let a = HEVCAssembler(tileSSRCs: ssrcs, config: c)
        let s = Sender(ssrcs)
        let first = feed(a, s.picture(tile: 1, ts: 1000, don: 5, params: true))
        XCTAssertEqual(first.filter(\.isParameterSets).count, 1)
        XCTAssertTrue(first.compactMap(\.au).isEmpty)
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1000, don: 6)), [.needKeyframe(ssrc: ssrcs[0])])
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
        XCTAssertEqual(a.ingest(rest), [.parameterSets(vps: Sender.vps, sps: Sender.sps, pps: [Sender.pps])])
        XCTAssertEqual(feed(a, s.picture(tile: 0, ts: 1000, don: 2, type: 19)).compactMap(\.au).map(\.isIDR), [true])
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
        var c = HEVCAssembler.Config(); c.reorderWindow = 2
        let (a, s) = warm(c)
        // DON 1 (tile 1) vanishes completely; tile 1 sends nothing else yet.
        XCTAssertEqual(feed(a, s.picture(tile: 2, ts: 1000, don: 2)), [])
        XCTAssertEqual(feed(a, s.picture(tile: 3, ts: 1000, don: 3)), [])
        let out = feed(a, s.picture(tile: 0, ts: 2000, don: 4))
        XCTAssertEqual(out, [.needKeyframe(ssrc: ssrcs[0])])
        XCTAssertEqual(a.stats.donHoles, 1)
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
