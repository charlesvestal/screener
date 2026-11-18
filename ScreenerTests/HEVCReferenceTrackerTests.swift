import XCTest
@testable import Screener

/// Apple's HP stream: SPS / PPS and first-slice headers from a live capture
/// (192.0.2.54, 2026-11-18; 2752x2064 as four 1280x432 tiles — the slices'
/// first bytes only, no picture data worth the name). Expected values from
/// the reference's hevc_rps.py on the same bytes.
final class HEVCReferenceTrackerTests: XCTestCase {
    private static func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { i -> UInt8 in
            let a = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)!
        })
    }

    static let sps = hex("420101040800000300be08000003000096900050100d8b10087722904573f89f85fd0beb1bd70feba08f5d"
                         + "413abab0ad5d5c17ababa0cd5d5d41bababaa0ed5d5d541fababaaa043575755529b8606808040")
    static let pps = hex("4401c072f05b24")

    func testAppleSPSShortTermSets() throws {
        let p = try XCTUnwrap(HEVCRPSParameters(sps: Self.sps, pps: Self.pps))
        XCTAssertEqual(p.log2MaxPOCLsb, 11)
        XCTAssertFalse(p.longTermRefsPresent)
        XCTAssertEqual(p.widthLuma, 1280)
        XCTAssertEqual(p.shortTermSets.count, 16)
        // hevc_rps.py: sets keep -1…-n for n = 1, 2, 3, 4, 4, 5, …, 15; used:
        // {-1} {-1,-2} … then {-1,-4}, then {-4,-8}.
        func used(_ i: Int) -> [Int] { p.shortTermSets[i].negative.filter(\.used).map(\.delta) }
        let sizes = [1, 2, 3, 4] + Array(4...15)
        XCTAssertEqual(p.shortTermSets.map { $0.negative.map(\.delta) }, sizes.map { n in (1...n).map { -$0 } })
        XCTAssertTrue(p.shortTermSets.allSatisfy { $0.positive.isEmpty })
        XCTAssertEqual(used(0), [-1])
        XCTAssertEqual(used(1), [-1, -2])
        XCTAssertEqual(used(3), [-1, -2])
        XCTAssertEqual(used(4), [-1, -4])
        XCTAssertEqual(used(7), [-1, -4])
        XCTAssertEqual(used(8), [-4, -8])
        XCTAssertEqual(used(15), [-4, -8])
    }

    func testAppleSliceHeaders() throws {
        let p = try XCTUnwrap(HEVCRPSParameters(sps: Self.sps, pps: Self.pps))
        let cases: [(String, Int, Int, [Int])] = [
            ("2801af3d8e1d132b1483b995429c6a80", 20, 0, []),
            ("0201d80116622c70e2d4097d11613000", 1, 1, []),
            ("0201d0040baf7440a58e10140c26427c", 1, 4, [-3, -4]),
            ("0201d005aba206ac73d248db4925fd5d", 1, 5, [-1, -4]),
            ("0201d008c3a2072c73b2c91a4925fc18", 1, 8, [-4, -8]),
            ("0201d010021ababaa4a74419638427842734f13c", 1, 16, [-4, -8]),
            ("0201d018021aba926a48d7442d8e14fcaa296c69f8284cc0", 1, 24, [-4, -24]),   // explicit RPS
        ]
        for (h, type, poc, used) in cases {
            let r = try XCTUnwrap(HEVCPictureRefs(slice: Self.hex(h), params: p), h)
            XCTAssertEqual(r.nalType, type, h)
            XCTAssertEqual(r.pocLsb, poc, h)
            XCTAssertEqual(r.usedDeltas, used, h)
        }
    }

    func testTrackerPOCWrapAndVerdicts() throws {
        var t = HEVCReferenceTracker()
        t.setParameters(sps: Self.sps, pps: Self.pps)
        let idr = Self.hex("2801af3d8e1d132b1483b995429c6a80")
        guard case .decodable(0)? = t.classify(idr)?.verdict else { return XCTFail("IDR") }
        t.commit(poc: 0, irap: true)
        // POC 4 needs 1 and 0; only 0 was decoded.
        let p4 = Self.hex("0201d0040baf7440a58e10140c26427c")
        XCTAssertEqual(t.classify(p4)?.verdict, .broken(poc: 4, missing: [1]))
        t.commit(poc: 1, irap: false)
        XCTAssertEqual(t.classify(p4)?.verdict, .decodable(poc: 4))
    }
}
