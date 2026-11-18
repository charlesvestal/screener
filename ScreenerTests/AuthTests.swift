import XCTest
import Security
@testable import Screener

// MARK: - Test helpers

private func h(_ hex: String) -> Data { Data(hex: hex) }

private struct SRPFixture {
    let challengeWire: Data
    let N: Data, B: Data, salt: Data, A: Data, M1: Data, M2: Data, wrapKey: Data
    let g: Int, iterations: UInt64, cap: String
    let privateA: Data, password: String

    init() throws {
        let f = try Fixture.load("srp")
        let args = f["args"] as! [String: Any]
        let pc = f["parsed_challenge"] as! [String: Any]
        challengeWire = h(f["challenge_wire"] as! String)
        N = h(pc["N"] as! String)
        B = h(pc["B"] as! String)
        salt = h(pc["salt"] as! String)
        g = pc["g"] as! Int
        iterations = UInt64(pc["iterations"] as! Int)
        cap = pc["cap"] as! String
        A = h(f["A"] as! String)
        M1 = h(f["M1"] as! String)
        M2 = h(f["M2"] as! String)
        wrapKey = h(f["wrap_key"] as! String)
        privateA = h(args["a_entropy_64B"] as! String)
        password = args["password"] as! String
    }
}

/// A 2048-bit RSA keypair generated in-test, plus the public key as a DER
/// SubjectPublicKeyInfo (what screensharingd sends in the key response).
private struct TestRSAKey: @unchecked Sendable {
    let privateKey: SecKey
    let spki: Data

    init() throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pub = SecKeyCopyPublicKey(priv),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        privateKey = priv
        spki = TestRSAKey.wrapSPKI(pkcs1)
    }

    func decrypt(_ ct: Data) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let pt = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, ct as CFData, &err) else {
            throw err!.takeRetainedValue() as Error
        }
        return pt as Data
    }

    private static func derLen(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        if n < 0x100 { return Data([0x81, UInt8(n)]) }
        return Data([0x82, UInt8(n >> 8), UInt8(n & 0xff)])
    }

    private static func wrapSPKI(_ pkcs1: Data) -> Data {
        let algId = h("300d06092a864886f70d0101010500")
        let bitString = Data([0x03]) + derLen(pkcs1.count + 1) + Data([0x00]) + pkcs1
        let body = algId + bitString
        return Data([0x30]) + derLen(body.count) + body
    }
}

/// Fake-server half of the RSA1 key request: reads the 15-byte
/// `0x21 + authtype-0 RSA1` request and answers with the SPKI using
/// screensharingd's framing `u32_be(n+7) || u32_le 0x100 || u16_be n || DER || 00`.
private func serveKeyRequest(_ s: ByteStream, key: TestRSAKey) async throws -> Data {
    let req = try await s.read(exactly: 15)
    var w = ByteWriter()
    w.u32(UInt32(key.spki.count + 7))
    w.u32le(0x100)
    w.u16(UInt16(key.spki.count))
    w.bytes(key.spki)
    w.u8(0)
    try await s.write(w.data)
    return req
}

/// RFC §4.2.4.7 final proof as a live macOS server sends it (98 bytes):
/// `u32 total || u16 0 || u16 2 || u16 x || u32 payload_len ||
/// %o M2 || %o server_random || %s "" || %u 0`, x = payload_len + 4.
private func finalProofBody(m2: Data, rfcNineByteHeader: Bool = false) -> Data {
    var inner = ByteWriter()
    inner.writeO(m2)
    inner.writeO(Data(repeating: 0x5a, count: 16))
    inner.writeS("")
    inner.u32(0)
    var body = ByteWriter()
    if rfcNineByteHeader {
        body.u8(0)
        body.u32(UInt32(inner.data.count + 4))
    } else {
        body.u16(0); body.u16(2)
        body.u16(UInt16(inner.data.count + 4))
    }
    body.u32(UInt32(inner.data.count))
    body.bytes(inner.data)
    return body.data
}

private func finalProofFrame(m2: Data) -> Data {
    let body = finalProofBody(m2: m2)
    var w = ByteWriter()
    w.u32(UInt32(body.count))
    w.bytes(body)
    return w.data
}

private struct SRPServerCapture: Sendable {
    let keyRequest: Data
    let packet1: Data       // full frame incl. u32 length
    let identityPlaintext: Data
    let packet2: Data       // full frame incl. u32 length
}

/// Scripted SRP server: key request → packet-1 → challenge → packet-2 →
/// final proof (`m2`) → SecurityResult (`result`, then optional reason).
private func runFakeSRPServer(_ s: ByteStream, key: TestRSAKey, fx: SRPFixture,
                              m2: Data, result: UInt32 = 0, reason: String? = nil) async throws -> SRPServerCapture {
    do {
        return try await fakeSRPServerBody(s, key: key, fx: fx, m2: m2, result: result, reason: reason)
    } catch {
        s.close()   // unblock the client so the failure surfaces instead of hanging
        throw error
    }
}

private func fakeSRPServerBody(_ s: ByteStream, key: TestRSAKey, fx: SRPFixture,
                               m2: Data, result: UInt32, reason: String?) async throws -> SRPServerCapture {
    let keyReq = try await serveKeyRequest(s, key: key)
    let p1len = try await s.read(exactly: 4)
    let p1 = try await s.read(exactly: Int(try { var r = ByteReader(p1len); return try r.u32() }()))
    // packet-1: 0100 RSA1 0002 0100 <256 ct> <384 zeros>
    let ct = p1.subdata(in: 10..<266)
    let ident = try key.decrypt(ct)

    var cw = ByteWriter()
    cw.u32(UInt32(fx.challengeWire.count))
    cw.bytes(fx.challengeWire)
    try await s.write(cw.data)

    let p2len = try await s.read(exactly: 4)
    let p2 = try await s.read(exactly: Int(try { var r = ByteReader(p2len); return try r.u32() }()))

    var out = ByteWriter()
    out.bytes(finalProofFrame(m2: m2))
    out.u32(result)
    if let reason {
        out.u32(UInt32(reason.utf8.count))
        out.bytes(Data(reason.utf8))
    }
    try await s.write(out.data)
    return SRPServerCapture(keyRequest: keyReq, packet1: p1len + p1, identityPlaintext: ident, packet2: p2len + p2)
}

// MARK: - Tests

final class AuthTests: XCTestCase {

    func testGrammarAtomsRoundTrip() throws {
        var w = ByteWriter()
        w.writeM(Data([1, 2, 3]))
        w.writeO(Data([4]))
        w.writeS("hé")
        w.writeQ(0x0102_0304_0506_0708)
        XCTAssertEqual(w.data.hex, "0003010203" + "0104" + "000368c3a9" + "0102030405060708")
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.readM(), Data([1, 2, 3]))
        XCTAssertEqual(try r.readO(), Data([4]))
        XCTAssertEqual(try r.readS(), "hé")
        XCTAssertEqual(try r.readQ(), 0x0102_0304_0506_0708)
        XCTAssertTrue(r.isAtEnd)
    }

    func testParseChallenge() throws {
        let fx = try SRPFixture()
        let ch = try Authenticator.parseSRPChallenge(fx.challengeWire)
        XCTAssertEqual(ch.N.hex, fx.N.hex)
        XCTAssertEqual(ch.g, Data([UInt8(fx.g)]))
        XCTAssertEqual(ch.salt.hex, fx.salt.hex)
        XCTAssertEqual(ch.B.hex, fx.B.hex)
        XCTAssertEqual(ch.iterations, fx.iterations)
        XCTAssertEqual(String(decoding: ch.options, as: UTF8.self), fx.cap)
    }

    func testParseChallengeRejectsMissingZeroMarker() throws {
        let fx = try SRPFixture()
        var bad = fx.challengeWire
        bad[12] = 1
        XCTAssertThrowsError(try Authenticator.parseSRPChallenge(bad)) { e in
            guard case .malformed = e as? AuthError else { return XCTFail("\(e)") }
        }
    }

    func testParseChallengeRejectsExcessiveIterations() throws {
        let fx = try SRPFixture()
        // iterations u64 sits after: 12 hdr + 1 zero + 512 N + 2+1 g + 1+32 salt + 2+512 B
        var bad = fx.challengeWire
        let off = 12 + 1 + 512 + 3 + 33 + 514
        var w = ByteWriter(); w.u64(1_000_001)
        bad.replaceSubrange(off..<off + 8, with: w.data)
        XCTAssertThrowsError(try Authenticator.parseSRPChallenge(bad)) { e in
            guard case .malformed = e as? AuthError else { return XCTFail("\(e)") }
        }
    }

    func testPacket2Header() throws {
        let fx = try SRPFixture()
        let civ = Data(repeating: 0xc1, count: 16)
        let frame = try Authenticator.buildSRPPacket2(publicA: fx.A, M1: fx.M1,
                                                     options: Data(fx.cap.utf8), clientRandom: civ)
        let innerLen = 2 + 512 + 1 + 64 + 2 + fx.cap.utf8.count + 1 + 16
        var w = ByteWriter()
        w.u32(1076)
        w.u16(0x0100)
        w.bytes(Data("RSA1".utf8))
        w.u16(2)
        w.u16(UInt16(innerLen + 4))
        w.u16(0)
        w.u16(UInt16(innerLen))
        XCTAssertEqual(frame.prefix(18).hex, w.data.hex)
        XCTAssertEqual(frame.count, 4 + 1076)
        // inner: %m A || %o M1 || %s options || %o client_random, then zero tail
        var r = ByteReader(frame.subdata(in: 18..<frame.count))
        XCTAssertEqual(try r.readM(), fx.A)
        XCTAssertEqual(try r.readO(), fx.M1)
        XCTAssertEqual(try r.readS(), fx.cap)
        XCTAssertEqual(try r.readO(), civ)
        XCTAssertEqual(r.rest(), Data(count: 1076 - 14 - innerLen))
    }

    func testSRPHappyPathAgainstFakeServer() async throws {
        let fx = try SRPFixture()
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task { try await runFakeSRPServer(server, key: key, fx: fx, m2: fx.M2) }

        let result = try await Authenticator.run(stream: client, username: "alice", password: fx.password,
                                                 seams: .init(privateA: fx.privateA))
        let cap = try await serverTask.value

        XCTAssertEqual(result.wrapKey.hex, fx.wrapKey.hex)
        XCTAssertEqual(result.method, .srp)
        XCTAssertEqual(result.serverRSAPublicKeyDER, key.spki)

        // 0x21 selector + authtype-0 RSA1 key request (auth.py _rsa1_init).
        XCTAssertEqual(cap.keyRequest.hex, "21" + "0000000a" + "0100" + "52534131" + "0000" + "0000")
        // packet-1 envelope (RFC §4.2.4.2): total 650, 0100 RSA1 0002 0100, 256 ct, 384 zero.
        XCTAssertEqual(cap.packet1.count, 654)
        XCTAssertEqual(cap.packet1.prefix(14).hex, "0000028a" + "0100" + "52534131" + "0002" + "0100")
        XCTAssertEqual(cap.packet1.suffix(384), Data(count: 384))
        // identity plaintext (RFC §4.2.4.3): u32 payload_len || u32 ulen || user || u16 0 || u8 0
        XCTAssertEqual(cap.identityPlaintext.hex,
                       "0000000c" + "00000005" + Data("alice".utf8).hex + "0000" + "00")
        // packet-2 carries the fixture A and M1.
        var r = ByteReader(cap.packet2.subdata(in: 18..<cap.packet2.count))
        XCTAssertEqual(try r.readM(), fx.A)
        XCTAssertEqual(try r.readO(), fx.M1)
        XCTAssertEqual(try r.readS(), fx.cap)
    }

    /// Live macOS server, 98-byte final proof with the 10-byte header
    /// `00000002 005c 00000058` (observed 2026-11-14): M2 must be found.
    /// Before the fix the 9-byte RFC header was assumed, so the u8 read at
    /// offset 9 (0x58 = 88) was taken as the M2 length and M2 was never checked.
    func testExtractM2FromLiveShapedFinalProof() {
        let m2 = Data((0..<64).map { UInt8($0) })
        let body = finalProofBody(m2: m2)
        XCTAssertEqual(body.count, 98)
        XCTAssertEqual(body.prefix(11).hex, "00000002005c0000005840")
        XCTAssertEqual(Authenticator.extractM2(body), m2)
    }

    func testExtractM2FromRFCShapedFinalProof() {
        let m2 = Data(repeating: 0xab, count: 64)
        XCTAssertEqual(Authenticator.extractM2(finalProofBody(m2: m2, rfcNineByteHeader: true)), m2)
    }

    func testExtractM2RejectsInconsistentHeader() {
        var body = finalProofBody(m2: Data(repeating: 1, count: 64))
        body[5] ^= 0x01   // x no longer equals payload_len + 4
        XCTAssertNil(Authenticator.extractM2(body))
        XCTAssertNil(Authenticator.extractM2(Data()))
        XCTAssertNil(Authenticator.extractM2(finalProofBody(m2: Data(repeating: 1, count: 63))))
    }

    /// L4: a well-formed but wrong server proof is a hard failure, even
    /// though the SecurityResult that follows says success.
    func testM2MismatchFails() async throws {
        let fx = try SRPFixture()
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        var badM2 = fx.M2; badM2[0] ^= 0xff
        let serverTask = Task { try await runFakeSRPServer(server, key: key, fx: fx, m2: badM2) }
        do {
            _ = try await Authenticator.run(stream: client, username: "alice", password: fx.password,
                                            seams: .init(privateA: fx.privateA))
            XCTFail("expected a server-proof failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .serverProofMismatch)
        }
        _ = try await serverTask.value
        XCTAssertEqual(ControlSession.describe(AuthError.serverProofMismatch).contains("identity could not be verified"),
                       true)
    }

    // MARK: H1 — key pinning and the legacy-sign-in gate

    /// A pinned key that matches: SRP proceeds as usual.
    func testPinnedKeyMatchSucceeds() async throws {
        let fx = try SRPFixture()
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task { try await runFakeSRPServer(server, key: key, fx: fx, m2: fx.M2) }
        let result = try await Authenticator.run(stream: client, username: "alice", password: fx.password,
                                                 pin: Authenticator.keyFingerprint(key.spki),
                                                 seams: .init(privateA: fx.privateA))
        _ = try await serverTask.value
        XCTAssertEqual(result.serverKeySHA256, Authenticator.keyFingerprint(key.spki))
        XCTAssertEqual(result.serverKeySHA256?.count, 32)
    }

    /// A different key than the pinned one fails right after the key
    /// response: packet-1 (identity encrypted to the attacker's key) is never sent.
    func testPinnedKeyMismatchRefusesBeforePacket1() async throws {
        let pinned = try TestRSAKey()
        let attacker = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task { () -> Bool in
            _ = try await serveKeyRequest(server, key: attacker)
            do { _ = try await server.read(exactly: 1); return true } catch { return false }
        }
        do {
            _ = try await Authenticator.run(stream: client, username: "alice", password: "pw",
                                            pin: Authenticator.keyFingerprint(pinned.spki), seams: AuthSeams())
            XCTFail("expected a key mismatch")
        } catch {
            XCTAssertEqual(error as? AuthError,
                           .serverKeyMismatch(presentedSHA256: Authenticator.keyFingerprint(attacker.spki)))
        }
        client.close()
        let receivedPacket1 = try await serverTask.value
        XCTAssertFalse(receivedPacket1, "nothing may be sent after a key mismatch")
    }

    /// Same for the non-SRP path: no credential blob to a mismatched key.
    func testPinnedKeyMismatchRefusesNonSRPCredentials() async throws {
        let pinned = try TestRSAKey()
        let attacker = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task { () -> Bool in
            _ = try await serveKeyRequest(server, key: attacker)
            do { _ = try await server.read(exactly: 1); return true } catch { return false }
        }
        do {
            _ = try await Authenticator.run(stream: client, username: "alice", password: "pw", method: .nonSRP,
                                            pin: Authenticator.keyFingerprint(pinned.spki), seams: AuthSeams())
            XCTFail("expected a key mismatch")
        } catch {
            XCTAssertEqual(error as? AuthError,
                           .serverKeyMismatch(presentedSHA256: Authenticator.keyFingerprint(attacker.spki)))
        }
        client.close()
        let receivedCreds = try await serverTask.value
        XCTAssertFalse(receivedCreds)
    }

    /// A short challenge (the MITM downgrade lever) on a host without
    /// "Allow legacy sign-in": no second connection, `.legacyAuthRequired`.
    func testShortChallengeDoesNotFallBackWithoutLegacyPermission() async throws {
        let key = try TestRSAKey()
        let (c1, s1) = MemoryPipe.pair()
        let (c2, _) = MemoryPipe.pair()
        let srpServer = Task {
            _ = try await serveKeyRequest(s1, key: key)
            _ = try await s1.read(exactly: 654)
            var w = ByteWriter(); w.u32(8); w.zeros(8)
            try await s1.write(w.data)
        }
        let conns = ConnQueue([c1, c2])
        do {
            _ = try await Authenticator.runWithFallback(username: "a", password: "b") { try await conns.next() }
            XCTFail("expected legacyAuthRequired")
        } catch {
            XCTAssertEqual(error as? AuthError, .legacyAuthRequired)
        }
        try await srpServer.value
        let opened = await conns.opened
        XCTAssertEqual(opened, 1, "no legacy fallback connection without the per-host permission")
        XCTAssertTrue(ControlSession.describe(AuthError.legacyAuthRequired).contains("legacy"))
    }

    /// `.malformed` / `.unsupported` without permission: propagate, no fallback.
    func testMalformedDoesNotFallBackWithoutLegacyPermission() async throws {
        let (c1, s1) = MemoryPipe.pair()
        let (c2, _) = MemoryPipe.pair()
        let server = Task {
            _ = try await s1.read(exactly: 15)
            var w = ByteWriter(); w.u32(4); w.u16(0); w.u16(0)   // truncated key response
            try await s1.write(w.data)
        }
        let conns = ConnQueue([c1, c2])
        do {
            _ = try await Authenticator.runWithFallback(username: "a", password: "b") { try await conns.next() }
            XCTFail("expected malformed")
        } catch {
            guard case .malformed = error as? AuthError else { return XCTFail("\(error)") }
        }
        try await server.value
        let opened = await conns.opened
        XCTAssertEqual(opened, 1)
    }

    /// Permission given but the fallback connection presents a different key
    /// than the SRP attempt saw (no stored pin): refused before credentials.
    func testLegacyFallbackRefusesADifferentKey() async throws {
        let key = try TestRSAKey()
        let other = try TestRSAKey()
        let (c1, s1) = MemoryPipe.pair()
        let (c2, s2) = MemoryPipe.pair()
        let srpServer = Task {
            _ = try await serveKeyRequest(s1, key: key)
            _ = try await s1.read(exactly: 654)
            var w = ByteWriter(); w.u32(8); w.zeros(8)
            try await s1.write(w.data)
        }
        let nonSRPServer = Task { () -> Bool in
            _ = try await serveKeyRequest(s2, key: other)
            do { _ = try await s2.read(exactly: 1); return true } catch { return false }
        }
        let conns = ConnQueue([c1, c2])
        do {
            _ = try await Authenticator.runWithFallback(username: "a", password: "b",
                                                        policy: AuthPolicy(allowLegacy: true)) {
                try await conns.next()
            }
            XCTFail("expected a key mismatch")
        } catch {
            XCTAssertEqual(error as? AuthError,
                           .serverKeyMismatch(presentedSHA256: Authenticator.keyFingerprint(other.spki)))
        }
        try await srpServer.value
        let gotCredentials = try await nonSRPServer.value
        XCTAssertFalse(gotCredentials)
    }

    /// A pinned host whose (MITM) key differs: refused on the SRP attempt,
    /// before packet-1, even with legacy allowed — no second connection.
    func testPinMismatchNeverFallsBack() async throws {
        let pinned = try TestRSAKey()
        let attacker = try TestRSAKey()
        let (c1, s1) = MemoryPipe.pair()
        let (c2, _) = MemoryPipe.pair()
        let server = Task { _ = try await serveKeyRequest(s1, key: attacker) }
        let conns = ConnQueue([c1, c2])
        do {
            _ = try await Authenticator.runWithFallback(
                username: "a", password: "b",
                policy: AuthPolicy(pinnedKeySHA256: Authenticator.keyFingerprint(pinned.spki), allowLegacy: true)
            ) { try await conns.next() }
            XCTFail("expected a key mismatch")
        } catch {
            guard case .serverKeyMismatch = error as? AuthError else { return XCTFail("\(error)") }
        }
        try await server.value
        let opened = await conns.opened
        XCTAssertEqual(opened, 1)
    }

    func testRejectedSecurityResultWithReason() async throws {
        let fx = try SRPFixture()
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task {
            try await runFakeSRPServer(server, key: key, fx: fx, m2: fx.M2, result: 1, reason: "Authentication failed")
        }
        do {
            _ = try await Authenticator.run(stream: client, username: "alice", password: fx.password,
                                            seams: .init(privateA: fx.privateA))
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AuthError, .rejected(reason: "Authentication failed"))
        }
        _ = try await serverTask.value
    }

    func testRejectedSecurityResultWithoutReason() async throws {
        let fx = try SRPFixture()
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task {
            let c = try await runFakeSRPServer(server, key: key, fx: fx, m2: fx.M2, result: 1)
            server.close()      // reference server just drops the connection
            return c
        }
        do {
            _ = try await Authenticator.run(stream: client, username: "alice", password: fx.password,
                                            seams: .init(privateA: fx.privateA))
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AuthError, .rejected(reason: nil))
        }
        _ = try await serverTask.value
    }

    func testShortChallengeMeansSRPUnavailable() async throws {
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task {
            _ = try await serveKeyRequest(server, key: key)
            _ = try await server.read(exactly: 654)
            var w = ByteWriter(); w.u32(8); w.zeros(8)
            try await server.write(w.data)
        }
        do {
            _ = try await Authenticator.run(stream: client, username: "alice", password: "pw")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .srpUnavailable(challengeLength: 8))
        }
        try await serverTask.value
    }

    /// Non-SRP (auth.py do_nonsrp_auth): checks the exact c2s1 layout the
    /// client sends and that the returned key is the RSA-wrapped AES key.
    func testNonSRPAgainstFakeServer() async throws {
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task { () -> (Data, Data, Data) in
            let keyReq = try await serveKeyRequest(server, key: key)
            let lenBytes = try await server.read(exactly: 4)
            var lr = ByteReader(lenBytes)
            let blob = try await server.read(exactly: Int(try lr.u32()))
            var out = ByteWriter(); out.u32(0); out.u32(0)
            try await server.write(out.data)
            return (keyReq, lenBytes, blob)
        }
        // Deterministic "random": AES key = 0x11 * 16, padding = 0xEE...
        let seams = AuthSeams(random: { n in Data(repeating: n == 16 ? 0x11 : 0xee, count: n) })
        let result = try await Authenticator.run(stream: client, username: "alice", password: "s3cret",
                                                 method: .nonSRP, seams: seams)
        let (keyReq, lenBytes, blob) = try await serverTask.value

        let aesKey = Data(repeating: 0x11, count: 16)
        XCTAssertEqual(result.method, .nonSRP)
        XCTAssertEqual(result.wrapKey, aesKey)
        XCTAssertEqual(result.serverRSAPublicKeyDER, key.spki)
        XCTAssertEqual(keyReq.hex, "21" + "0000000a" + "0100" + "52534131" + "0000" + "0000")

        // u32 len || 0100 RSA1 || 0001 enc_creds[128] || 0001 enc_aes_key[256]
        XCTAssertEqual(lenBytes.hex, "0000018a")       // 394
        XCTAssertEqual(blob.count, 394)
        XCTAssertEqual(blob.prefix(8).hex, "0100" + "52534131" + "0001")
        XCTAssertEqual(blob.subdata(in: 136..<138).hex, "0001")
        XCTAssertEqual(try key.decrypt(blob.subdata(in: 138..<394)), aesKey)

        let creds = try AES.ecbDecrypt(key: aesKey, block: blob.subdata(in: 8..<136))
        let userSlot = Data("alice".utf8) + Data([0]) + Data(repeating: 0xee, count: 64 - 6)
        let passSlot = Data("s3cret".utf8) + Data([0]) + Data(repeating: 0xee, count: 64 - 7)
        XCTAssertEqual(creds.hex, (userSlot + passSlot).hex)
    }

    func testPackARDCredentialTruncatesLongValues() {
        let long = String(repeating: "x", count: 80)
        let slot = Authenticator.packARDCredential(long, random: { Data(count: $0) })
        XCTAssertEqual(slot, Data(repeating: UInt8(ascii: "x"), count: 64))
        let short = Authenticator.packARDCredential("ab", random: { Data(repeating: 7, count: $0) })
        XCTAssertEqual(short, Data([0x61, 0x62, 0]) + Data(repeating: 7, count: 61))
    }

    func testNonSRPRejected() async throws {
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task {
            _ = try await serveKeyRequest(server, key: key)
            _ = try await server.read(exactly: 4 + 394)
            var out = ByteWriter(); out.u32(0); out.u32(2)
            try await server.write(out.data)
            server.close()
        }
        do {
            _ = try await Authenticator.run(stream: client, username: "a", password: "b", method: .nonSRP)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AuthError, .rejected(reason: nil))
        }
        try await serverTask.value
    }

    /// negotiation._phase_auth: SRP fails with AuthError → close, open a
    /// NEW connection, run non-SRP on it.
    func testFallbackReconnectsAndRunsNonSRP() async throws {
        let key = try TestRSAKey()
        let (c1, s1) = MemoryPipe.pair()
        let (c2, s2) = MemoryPipe.pair()
        let srpServer = Task {
            _ = try await serveKeyRequest(s1, key: key)
            _ = try await s1.read(exactly: 654)
            var w = ByteWriter(); w.u32(8); w.zeros(8)
            try await s1.write(w.data)
        }
        let nonSRPServer = Task {
            _ = try await serveKeyRequest(s2, key: key)
            _ = try await s2.read(exactly: 4 + 394)
            var out = ByteWriter(); out.u32(0); out.u32(0)
            try await s2.write(out.data)
        }
        let conns = ConnQueue([c1, c2])
        // H1: only with the host's legacy permission, and the same (pinned) key.
        let (stream, result) = try await Authenticator.runWithFallback(
            username: "a", password: "b",
            policy: AuthPolicy(pinnedKeySHA256: Authenticator.keyFingerprint(key.spki), allowLegacy: true)
        ) {
            try await conns.next()
        }
        try await srpServer.value
        try await nonSRPServer.value
        XCTAssertEqual(result.method, .nonSRP)
        XCTAssertTrue(stream as AnyObject === c2 as AnyObject)
        let opened = await conns.opened
        XCTAssertEqual(opened, 2)
        // The failed SRP connection was closed.
        do { _ = try await s1.readSome(); XCTFail("s1 should be closed") } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    /// Task 22 fix (Important/security): a rejection after a *full* SRP
    /// exchange means the password was wrong, not that SRP is unusable — the
    /// reference's "retry everything on any AuthError" policy would resend
    /// the same wrong password over the weaker RSA-wrapped-AES channel. We
    /// must close the stream and rethrow `.rejected` without opening a
    /// second connection.
    func testRejectedSRPDoesNotFallBack() async throws {
        let fx = try SRPFixture()
        let key = try TestRSAKey()
        let (c1, s1) = MemoryPipe.pair()
        let srpServer = Task {
            try await runFakeSRPServer(s1, key: key, fx: fx, m2: fx.M2, result: 1, reason: "Authentication failed")
        }
        let conns = ConnQueue([c1])
        do {
            _ = try await Authenticator.runWithFallback(username: "alice", password: fx.password) {
                try await conns.next()
            }
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AuthError, .rejected(reason: "Authentication failed"))
        }
        _ = try await srpServer.value
        let opened = await conns.opened
        XCTAssertEqual(opened, 1, "fallback must not open a second connection after a genuine SRP rejection")
    }

    /// (2a) On success, the client must not consume any bytes past the
    /// SecurityResult u32 — proves there is no speculative reason-read on
    /// the success path.
    func testSuccessDoesNotReadPastSecurityResult() async throws {
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task {
            _ = try await serveKeyRequest(server, key: key)
            _ = try await server.read(exactly: 4 + 394)
            var out = ByteWriter()
            out.u32(0)   // non-SRP 4-byte padding
            out.u32(0)   // SecurityResult success
            out.bytes(Data(hex: "DEADBEEF"))   // sentinel the client must not touch
            try await server.write(out.data)
        }
        let seams = AuthSeams(random: { n in Data(repeating: n == 16 ? 0x11 : 0xee, count: n) })
        _ = try await Authenticator.run(stream: client, username: "alice", password: "s3cret",
                                        method: .nonSRP, seams: seams)
        _ = try await serverTask.value
        let sentinel = try await client.read(exactly: 4)
        XCTAssertEqual(sentinel.hex, "deadbeef")
    }

    /// (2b) A non-zero result with nothing following it, on a connection the
    /// server keeps open, must still resolve to `.rejected(reason: nil)`
    /// within the reason-read grace period (~500ms), not hang indefinitely.
    func testRejectedWithoutReasonOnOpenConnection() async throws {
        let key = try TestRSAKey()
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task {
            _ = try await serveKeyRequest(server, key: key)
            _ = try await server.read(exactly: 4 + 394)
            var out = ByteWriter(); out.u32(0); out.u32(1)
            try await server.write(out.data)
            // Deliberately do NOT close `server` or send anything else.
        }
        let start = Date()
        do {
            _ = try await Authenticator.run(stream: client, username: "a", password: "b", method: .nonSRP)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AuthError, .rejected(reason: nil))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        _ = try await serverTask.value
        server.close()
    }

    func testTransportErrorDoesNotFallBack() async throws {
        let (c1, s1) = MemoryPipe.pair()
        s1.close()
        let conns = ConnQueue([c1])
        do {
            _ = try await Authenticator.runWithFallback(username: "a", password: "b") { try await conns.next() }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
        let opened = await conns.opened
        XCTAssertEqual(opened, 1)
    }

    func testReadsAreCancellable() async throws {
        let (client, server) = MemoryPipe.pair()
        let task = Task { try await Authenticator.run(stream: client, username: "a", password: "b") }
        // Wait until the client is blocked reading the key response.
        _ = try await server.read(exactly: 15)
        let end = client as! MemoryPipeEnd
        while !end.hasWaiterForTesting { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}

private actor ConnQueue {
    private var streams: [ByteStream]
    private(set) var opened = 0
    init(_ s: [ByteStream]) { streams = s }
    func next() throws -> ByteStream {
        guard !streams.isEmpty else { throw TransportError.failed("no more connections") }
        opened += 1
        return streams.removeFirst()
    }
}
