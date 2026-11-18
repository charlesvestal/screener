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

    // MARK: - Replay protection (RFC 3711 §3.3.2, security review L1)

    func testReplayWindowBitmapAcrossBothWords() {
        var w = ReplayWindow(first: 1000)
        XCTAssertTrue(w.isReplay(1000))
        XCTAssertFalse(w.isReplay(1001))
        XCTAssertFalse(w.isReplay(999), "never seen, inside the window")
        w.accept(1070)                                  // shift 70: 1000 moves into the high word
        XCTAssertTrue(w.isReplay(1000))
        XCTAssertTrue(w.isReplay(1070))
        XCTAssertFalse(w.isReplay(1069))
        w.accept(1069); w.accept(943)                   // 943 = 1070 - 127, the oldest slot
        XCTAssertTrue(w.isReplay(1069))
        XCTAssertTrue(w.isReplay(943))
        XCTAssertTrue(w.isReplay(942), "128 behind: too old to tell, discarded")
        w.accept(1070 + 200)                            // jump past the whole window
        XCTAssertFalse(w.isReplay(1269))
        XCTAssertTrue(w.isReplay(1270))
        XCTAssertTrue(w.isReplay(1070))
    }

    func testReplayedSRTPPacketIsDroppedWithoutStateChange() throws {
        let fx = try SRTPFixture()
        let enc = try SRTPEncryptor(blob: fx.blob, ssrc: 0x1234)
        let dec = try SRTPDecryptor(blob: fx.blob)
        let wires = try (0..<10).map { try enc.encrypt(Data([UInt8($0)])) }
        for w in wires { XCTAssertNotNil(dec.decrypt(w)) }
        let count = dec.ssrcCounts[0x1234], state = dec.stateSnapshot()[0x1234]
        XCTAssertNil(dec.decrypt(wires[5]), "exact replay")
        XCTAssertNil(dec.decrypt(wires[9]), "replay of the newest")
        XCTAssertEqual(dec.replaysDropped, 2)
        XCTAssertEqual(dec.ssrcCounts[0x1234], count)
        XCTAssertEqual(dec.stateSnapshot()[0x1234], state)
    }

    func testReorderedSRTPPacketInsideTheWindowIsAcceptedOnce() throws {
        let fx = try SRTPFixture()
        let enc = try SRTPEncryptor(blob: fx.blob, ssrc: 0x1234)
        let dec = try SRTPDecryptor(blob: fx.blob)
        let wires = try (0..<300).map { try enc.encrypt(Data([UInt8($0 & 0xff)])) }
        for (i, w) in wires.enumerated() where i != 150 && i != 50 && i < 200 { XCTAssertNotNil(dec.decrypt(w)) }
        XCTAssertEqual(dec.decrypt(wires[150])?.seq, 150, "late but inside the 128 window")
        XCTAssertNil(dec.decrypt(wires[150]))
        XCTAssertNil(dec.decrypt(wires[50]), "149 behind the newest: outside the window")
        XCTAssertNotNil(dec.decrypt(wires[299]))
    }

    func testReplayAcrossROCRolloverUsesTheFullIndex() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)
        for pkt in fx.packets { XCTAssertNotNil(dec.decrypt(pkt.wire)) }   // 65534, 65535, 0 (ROC 1)
        for pkt in fx.packets { XCTAssertNil(dec.decrypt(pkt.wire), "seq \(pkt.seq) replayed") }
        XCTAssertEqual(dec.stateSnapshot()[fx.ssrc]?.roc, 1)
    }

    func testReplayedSRTCPPacketIsDropped() throws {
        let fx = try SRTPFixture()
        let enc = try SRTCPEncryptor(blob: fx.blob)
        let dec = try SRTCPDecryptor(blob: fx.blob)
        let wires = try (0..<200).map { _ in try enc.protect(fx.rtcpPktForSample) }
        XCTAssertNotNil(dec.unprotect(wires[0]))
        XCTAssertNil(dec.unprotect(wires[0]), "same index again")
        XCTAssertNotNil(dec.unprotect(wires[2]))
        XCTAssertNotNil(dec.unprotect(wires[1]), "reordered, inside the window")
        XCTAssertNotNil(dec.unprotect(wires[199]))
        XCTAssertNil(dec.unprotect(wires[3]), "index must not fall ≥ 128 behind")
        XCTAssertEqual(dec.replaysDropped, 2)
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

    // MARK: - Ties / forget

    func testGetPrimarySSRCGroupBreaksTiesByAscendingFirstSSRC() throws {
        let fx = try SRTPFixture()
        for _ in 0..<5 {   // repeat: an unstable sort would flip some of the time
            let dec = try SRTPDecryptor(blob: fx.blob)
            for ssrc: UInt32 in [40, 41, 42, 43, 10, 11, 12, 13] {
                let enc = try SRTPEncryptor(blob: fx.blob, ssrc: ssrc)
                for i in 0..<3 { XCTAssertNotNil(dec.decrypt(try enc.encrypt(Data([UInt8(i)])))) }
            }
            XCTAssertEqual(dec.getPrimarySSRCGroup(tier: 0), [10, 11, 12, 13])
            XCTAssertEqual(dec.getPrimarySSRCGroup(tier: 1), [40, 41, 42, 43])
        }
    }

    func testForgetSSRCsExceptDropsCountsAndState() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)
        for ssrc: UInt32 in [1, 2, 3] {
            let enc = try SRTPEncryptor(blob: fx.blob, ssrc: ssrc)
            XCTAssertNotNil(dec.decrypt(try enc.encrypt(Data([1, 2, 3]))))
        }
        dec.forgetSSRCs(except: [2])
        XCTAssertEqual(dec.ssrcCounts, [2: 1])
        XCTAssertEqual(Set(dec.stateSnapshot().keys), [2])
    }

    // MARK: - Hostile input

    /// A wire packet whose auth tag is valid (ROC 0), so the parser past the
    /// tag check is what's exercised.
    private func signed(_ body: [UInt8], fx: SRTPFixture, dec: SRTPDecryptor) -> Data {
        let mac = HMAC1.sha1(key: dec.derivedKeys.authKey, data: Data(body) + Data([0, 0, 0, 0]))
        return Data(body) + mac.prefix(SRTP.authTagLength)
    }

    func testPacketShorterThan22BytesIsRejected() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)
        for n in 0..<22 { XCTAssertNil(dec.decrypt(Data(repeating: 0x80, count: n)), "len \(n)") }
    }

    func testCSRCCountBeyondBodyIsRejected() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)
        let body: [UInt8] = [0x8F, 100, 0, 1, 0, 0, 0, 0, 0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB]   // cc=15
        XCTAssertNil(dec.decrypt(signed(body, fx: fx, dec: dec)))
        XCTAssertTrue(dec.ssrcCounts.isEmpty)
    }

    func testOversizedExtensionLengthIsRejected() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)
        // X bit set, extension header claims 0xFFFF words.
        let body: [UInt8] = [0x90, 100, 0, 1, 0, 0, 0, 0, 0x11, 0x22, 0x33, 0x44, 0xBE, 0xDE, 0xFF, 0xFF, 1, 2]
        XCTAssertNil(dec.decrypt(signed(body, fx: fx, dec: dec)))
        // X bit set but not even room for the 4-byte extension header.
        let short: [UInt8] = [0x90, 100, 0, 2, 0, 0, 0, 0, 0x11, 0x22, 0x33, 0x44, 0xBE]
        XCTAssertNil(dec.decrypt(signed(short, fx: fx, dec: dec)))
    }

    func testHeaderOnlyPacketYieldsEmptyPayload() throws {
        let fx = try SRTPFixture()
        let dec = try SRTPDecryptor(blob: fx.blob)
        let body: [UInt8] = [0x80, 0xE4, 0, 7, 0, 0, 0, 9, 0x11, 0x22, 0x33, 0x44]
        let out = try XCTUnwrap(dec.decrypt(signed(body, fx: fx, dec: dec)))
        XCTAssertEqual(out.header, Data(body))
        XCTAssertEqual(out.payload, Data())
        XCTAssertEqual(out.ssrc, 0x1122_3344)
        XCTAssertEqual(out.seq, 7)
    }

    func testSRTCPUnencryptedPacketPassesThroughWhenAuthentic() throws {
        let fx = try SRTPFixture()
        let (key, salt) = try SRTP.splitBlob(fx.blob)
        let rtcpAuth = try SRTP.kdf(masterKey: key, masterSalt: salt, label: 4, length: 20)
        let plain = fx.rtcpPktForSample
        let body = plain + Data([0x00, 0x00, 0x00, 0x05])   // E=0, index 5
        let wire = body + HMAC1.sha1(key: rtcpAuth, data: body).prefix(SRTP.authTagLength)
        let dec = try SRTCPDecryptor(blob: fx.blob)
        XCTAssertEqual(dec.unprotect(wire), plain)
    }

    func testSRTCPEncryptorRejectsShortPacketWithoutTrapping() throws {
        let fx = try SRTPFixture()
        let enc = try SRTCPEncryptor(blob: fx.blob)
        XCTAssertThrowsError(try enc.protect(Data([0x80, 0xC9, 0, 1]))) { err in
            XCTAssertEqual(err as? SRTP.Error, .packetTooShort(4))
        }
        XCTAssertNil(try SRTCPDecryptor(blob: fx.blob).unprotect(Data(repeating: 0, count: 21)))
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
