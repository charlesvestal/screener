import XCTest
@testable import Screener

private func h(_ hex: String) -> Data { Data(hex: hex) }

final class SRTPTests: XCTestCase {
    // MARK: - Fixture

    private struct SRTPFixture {
        let blob: Data
        let cipherKey: Data
        let authKey: Data
        let salt: Data
        let ssrc: UInt32
        let pt: UInt8
        let packets: [(seq: UInt16, wire: Data, plaintext: Data)]
        let rtcpPktForSample: Data
        let srtcpWire: Data

        init() throws {
            let f = try Fixture.load("srtp")
            blob = h(f["blob"] as! String)
            cipherKey = h(f["cipher_key"] as! String)
            authKey = h(f["auth_key"] as! String)
            salt = h(f["salt"] as! String)
            let args = f["args"] as! [String: Any]
            ssrc = UInt32(args["ssrc"] as! Int)
            pt = UInt8(args["pt"] as! Int)
            let pkts = f["packets"] as! [[String: Any]]
            packets = pkts.map { p in
                (seq: UInt16(p["seq"] as! Int), wire: h(p["wire"] as! String), plaintext: h(p["plaintext"] as! String))
            }
            rtcpPktForSample = h(args["rtcp_pkt_for_srtcp_sample"] as! String)
            let sample = f["srtcp_sample"] as! [String: Any]
            srtcpWire = h(sample["wire"] as! String)
        }
    }

    // MARK: - KDF

    func testKDFMatchesFixture() throws {
        let fx = try SRTPFixture()
        let (key, masterSalt) = try SRTP.splitBlob(fx.blob)
        let cipherKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 0, length: 32)
        let authKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 1, length: 20)
        let salt = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 2, length: 14)
        XCTAssertEqual(cipherKey, fx.cipherKey)
        XCTAssertEqual(authKey, fx.authKey)
        XCTAssertEqual(salt, fx.salt)
    }

    func testDecryptorDerivedKeysMatchFixture() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)
        let keys = dec.derivedKeys
        XCTAssertEqual(keys.cipherKey, fx.cipherKey)
        XCTAssertEqual(keys.authKey, fx.authKey)
        XCTAssertEqual(keys.salt, fx.salt)
    }

    // MARK: - Decrypt (seq rollover 65534 -> 65535 -> 0, ROC 0 -> 1)

    func testDecryptThreeFixturePacketsWithROCRollover() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)

        for (i, pkt) in fx.packets.enumerated() {
            guard let result = dec.decrypt(pkt.wire) else {
                return XCTFail("packet \(i) (seq \(pkt.seq)) failed to decrypt")
            }
            XCTAssertEqual(result.ssrc, fx.ssrc, "packet \(i)")
            XCTAssertEqual(result.seq, pkt.seq, "packet \(i)")
            XCTAssertEqual(result.payload, pkt.plaintext, "packet \(i) plaintext")
        }

        // After seq 65534, 65535, 0 the ROC must have rolled from 0 to 1.
        let snapshot = dec.stateSnapshot()
        let state = try XCTUnwrap(snapshot[fx.ssrc])
        XCTAssertEqual(state.roc, 1)
        XCTAssertEqual(state.maxSeq, 0)
        XCTAssertEqual(dec.ssrcCounts[fx.ssrc], 3)
    }

    func testTamperedTagReturnsNilAndDoesNotChangeState() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)

        // Decrypt the first packet successfully to establish state.
        XCTAssertNotNil(dec.decrypt(fx.packets[0].wire))
        let countBefore = dec.ssrcCounts[fx.ssrc]
        let stateBefore = dec.stateSnapshot()[fx.ssrc]

        // Tamper the auth tag of the second packet.
        var tampered = [UInt8](fx.packets[1].wire)
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertNil(dec.decrypt(Data(tampered)))

        XCTAssertEqual(dec.ssrcCounts[fx.ssrc], countBefore)
        XCTAssertEqual(dec.stateSnapshot()[fx.ssrc], stateBefore)
    }

    func testTamperedPayloadReturnsNilAndDoesNotChangeState() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)

        XCTAssertNotNil(dec.decrypt(fx.packets[0].wire))
        let countBefore = dec.ssrcCounts[fx.ssrc]
        let stateBefore = dec.stateSnapshot()[fx.ssrc]

        var tampered = [UInt8](fx.packets[1].wire)
        tampered[20] ^= 0x01 // flip a byte inside the ciphertext, before the tag
        XCTAssertNil(dec.decrypt(Data(tampered)))

        XCTAssertEqual(dec.ssrcCounts[fx.ssrc], countBefore)
        XCTAssertEqual(dec.stateSnapshot()[fx.ssrc], stateBefore)
    }

    // MARK: - Encryptor

    func testEncryptorOutputMatchesFixture() throws {
        let fx = try SRTPFixture()
        // Prime seq to 65534 so the natural wraparound produces seqs 65534, 65535, 0,
        // exactly as the fixture-generation script did.
        let enc = try SRTPEncryptor(blob: fx.blob, ssrc: fx.ssrc, seq: 65534)

        for (i, pkt) in fx.packets.enumerated() {
            let wire = try enc.encrypt(pkt.plaintext, pt: fx.pt, marker: false)
            XCTAssertEqual(wire, pkt.wire, "packet \(i) (seq \(pkt.seq))")
        }
    }

    // MARK: - SRTCP

    func testSRTCPEncryptorMatchesFixture() throws {
        let fx = try SRTPFixture()
        let enc = try SRTCPEncryptor(blob: fx.blob)
        let wire = try enc.protect(fx.rtcpPktForSample)
        XCTAssertEqual(wire, fx.srtcpWire)
    }

    func testSRTCPDecryptorRoundTrips() throws {
        let fx = try SRTPFixture()
        let dec = try SRTCPDecryptor(blob: fx.blob)
        let plaintext = try XCTUnwrap(dec.unprotect(fx.srtcpWire))
        XCTAssertEqual(plaintext, fx.rtcpPktForSample)
    }

    func testSRTCPDecryptorRejectsTamperedTag() throws {
        let fx = try SRTPFixture()
        let dec = try SRTCPDecryptor(blob: fx.blob)
        var tampered = [UInt8](fx.srtcpWire)
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertNil(dec.unprotect(Data(tampered)))
    }

    // MARK: - get_primary_ssrc_group

    func testGetPrimarySSRCGroupPicksConsecutiveGroupWithMostPackets() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)

        // Group A: 4 consecutive SSRCs (10,11,12,13), 5 packets each = 20 total.
        // Group B: 3 consecutive SSRCs (20,21,22), 3 packets each = 9 total.
        // Isolated SSRC 50 with 1 packet.
        var groupACounts: [UInt32: Int] = [10: 5, 11: 5, 12: 5, 13: 5]
        var groupBCounts: [UInt32: Int] = [20: 3, 21: 3, 22: 3]
        let isolated: [UInt32: Int] = [50: 1]

        func feed(_ counts: [UInt32: Int]) throws {
            for (ssrc, n) in counts {
                let enc = try SRTPEncryptor(blob: fx.blob, ssrc: ssrc)
                for i in 0..<n {
                    let wire = try enc.encrypt(Data("payload-\(i)".utf8))
                    XCTAssertNotNil(dec.decrypt(wire))
                }
            }
        }
        try feed(groupACounts)
        try feed(groupBCounts)
        try feed(isolated)

        let primary = dec.getPrimarySSRCGroup(tier: 0, groupSize: 4)
        XCTAssertEqual(primary, Set(groupACounts.keys))

        let secondary = dec.getPrimarySSRCGroup(tier: 1, groupSize: 4)
        XCTAssertEqual(secondary, Set(groupBCounts.keys))

        _ = groupACounts.removeValue(forKey: 10)
        _ = groupBCounts.removeValue(forKey: 20)
    }

    // MARK: - Perf (informational only; no bound asserted)

    func testDecryptPerformance() throws {
        let fx = try SRTPFixture()
        let encSSRC: UInt32 = 0xAABBCCDD
        let enc = try SRTPEncryptor(blob: fx.blob, ssrc: encSSRC)
        let dec = try SRTPDecryptor(blob: fx.blob)
        let payload = Data(repeating: 0x42, count: 1200 - 12 - 10)

        let packetCount = 5000
        var wires: [Data] = []
        wires.reserveCapacity(packetCount)
        for _ in 0..<packetCount {
            wires.append(try enc.encrypt(payload))
        }

        let start = Date()
        for wire in wires {
            XCTAssertNotNil(dec.decrypt(wire))
        }
        let elapsed = Date().timeIntervalSince(start)
        let rate = Double(packetCount) / elapsed
        print("SRTPTests: decrypted \(packetCount) x ~1200-byte packets in \(elapsed)s (\(rate) pkt/s)")
    }
}
