import XCTest
@testable import Screener

/// Depacketizer against ScreenerTests/Fixtures/hevc_rtp.json, whose expected
/// NAL units are the output of the reference's media/nalu.reassemble_group.
final class HEVCDepacketizerTests: XCTestCase {
    private var f: [String: Any] = [:]

    override func setUpWithError() throws { f = try Fixture.load("hevc_rtp") }

    private func vector(_ key: String) -> [String: Any] { f[key] as! [String: Any] }
    private func expected(_ v: [String: Any]) -> [String] { v["expected_nalus"] as! [String] }

    func testSingleNAL() throws {
        let v = vector("single_nal")
        let payload = Data(hex: v["rtp_payload"] as! String)
        let units = try HEVCDepacketizer.nalUnits(from: payload)
        XCTAssertEqual(units.map(\.nal.hex), expected(v))
        XCTAssertEqual(units.map(\.don), [UInt16(v["first_donl"] as! Int)])
        XCTAssertEqual(HEVCDepacketizer.reassembleGroup([payload]).map(\.hex), expected(v))
        XCTAssertEqual(HEVCDepacketizer.firstDONL([payload]), UInt16(v["first_donl"] as! Int))
    }

    func testAggregationPacketSharesOneDONL() throws {
        let v = vector("aggregation_packet")
        let payload = Data(hex: v["rtp_payload"] as! String)
        let units = try HEVCDepacketizer.nalUnits(from: payload)
        XCTAssertEqual(units.map(\.nal.hex), expected(v))
        XCTAssertEqual(Set(units.map(\.don)), [42])
        XCTAssertEqual(units.map { HEVCNAL.type(of: $0.nal) }, [32, 33, 34])
        XCTAssertEqual(HEVCDepacketizer.firstDONL([payload]), 42)
    }

    func testFragmentationUnitAcrossPackets() throws {
        let v = vector("fragmentation_unit")
        let p = v["rtp_payloads"] as! [String: String]
        let packets = ["start", "middle", "end"].map { Data(hex: p[$0]!) }
        XCTAssertEqual(HEVCDepacketizer.reassembleGroup(packets).map(\.hex), expected(v))
        XCTAssertEqual(HEVCDepacketizer.firstDONL(packets), 49)

        // Every fragment carries the DONL; the start rebuilds the header.
        guard case .fragment(let start) = try HEVCDepacketizer.parse(packets[0]) else { return XCTFail() }
        XCTAssertTrue(start.isStart); XCTAssertFalse(start.isEnd)
        XCTAssertEqual(start.nalType, 19)
        XCTAssertEqual(start.don, 49)
        guard case .fragment(let end) = try HEVCDepacketizer.parse(packets[2]) else { return XCTFail() }
        XCTAssertTrue(end.isEnd); XCTAssertEqual(end.don, 49)

        XCTAssertThrowsError(try HEVCDepacketizer.nalUnits(from: packets[0])) {
            XCTAssertEqual($0 as? HEVCDepacketizer.Error, .fragmentNeedsReassembly)
        }

        var fu = FUReassembler()
        let frags = try packets.map { p -> HEVCDepacketizer.Fragment in
            guard case .fragment(let f) = try HEVCDepacketizer.parse(p) else { throw HEVCDepacketizer.Error.truncated }
            return f
        }
        XCTAssertEqual(fu.push(frags[0], seq: 65535), .pending)
        XCTAssertEqual(fu.push(frags[1], seq: 0), .pending)        // wraps
        XCTAssertEqual(fu.push(frags[2], seq: 1), .nal(Data(hex: expected(v)[0]), don: 49))
        XCTAssertFalse(fu.isActive)
    }

    func testMissingMiddleFragmentDropsNALAndReportsLoss() throws {
        let p = vector("fragmentation_unit")["rtp_payloads"] as! [String: String]
        guard case .fragment(let start) = try HEVCDepacketizer.parse(Data(hex: p["start"]!)),
              case .fragment(let end) = try HEVCDepacketizer.parse(Data(hex: p["end"]!)) else { return XCTFail() }
        var fu = FUReassembler()
        XCTAssertEqual(fu.push(start, seq: 10), .pending)
        XCTAssertEqual(fu.push(end, seq: 12), .lost(don: 49))       // seq 11 never came
        XCTAssertFalse(fu.isActive)
        // A continuation without a start is loss too.
        XCTAssertEqual(fu.push(end, seq: 13), .lost(don: 49))
        // A new start while one is open: the open NAL lost its end.
        XCTAssertEqual(fu.push(start, seq: 20), .pending)
        XCTAssertEqual(fu.push(start, seq: 21), .lost(don: 49))
    }

    func testMalformedPayloads() throws {
        XCTAssertThrowsError(try HEVCDepacketizer.parse(Data([0x02])))
        XCTAssertThrowsError(try HEVCDepacketizer.parse(Data([0x02, 0x01, 0x00])))          // single < 4
        XCTAssertThrowsError(try HEVCDepacketizer.parse(Data([0x62, 0x01, 0x93, 0x00, 0x01]))) // FU < 6
        // AP: a truncated entry stops parsing but keeps the earlier units.
        let ap = Data([0x60, 0x01, 0x00, 0x05, 0x00, 0x02, 0x40, 0x01, 0x00, 0x09, 0x42])
        XCTAssertEqual(try HEVCDepacketizer.nalUnits(from: ap).map(\.nal), [Data([0x40, 0x01])])
        // Zero-size entry ends it too.
        let ap0 = Data([0x60, 0x01, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0x40, 0x01])
        XCTAssertEqual(try HEVCDepacketizer.nalUnits(from: ap0).count, 0)
        // reassembleGroup skips what it cannot parse.
        XCTAssertEqual(HEVCDepacketizer.reassembleGroup([Data([0x02]), Data(hex: "02010007aabbccdd")]).map(\.hex),
                       ["0201aabbccdd"])
    }

    func testSlicedDataWithNonZeroStartIndex() throws {
        let backing = Data(hex: "ffffff02010007aabbccdd")
        let slice = backing[3...]
        XCTAssertEqual(try HEVCDepacketizer.nalUnits(from: slice).map(\.nal.hex), ["0201aabbccdd"])
        XCTAssertEqual(HEVCDepacketizer.firstDONL([slice]), 7)
    }
}
