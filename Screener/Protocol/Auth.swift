// Ported from iShareScreen src/isharescreen/proxy/protocol/auth.py (AGPL-3.0)
// Fallback policy ported from src/isharescreen/proxy/protocol/negotiation.py `_phase_auth`.
//
// RFB security type 33 ("RSA1"), both of Apple's variants:
//   * SRP  — RSA1 identity envelope + SRP-RFC5054-4096-SHA512-PBKDF2
//            (`auth.do_srp_auth`; RFC doc §4.2.4).
//   * non-SRP — legacy ARD-style RSA1+AES-128-ECB credential blob
//            (`auth.do_nonsrp_auth`).
// Both return the 16-byte initial wrap key consumed by the record layer.
import Foundation
import Security

// MARK: - Public API

struct AuthResult: Sendable, Equatable {
    enum Method: Sendable, Equatable { case srp, nonSRP }
    /// 16-byte initial record-layer wrap key (RFC §6.2.2). SRP: SHA-256(K)[0:16];
    /// non-SRP: the random AES key we sent the server.
    let wrapKey: Data
    let method: Method
    /// The DER the server sent in the RSA key response (normally a
    /// SubjectPublicKeyInfo): the Mac's identity, pinned (SHA-256) on first use.
    let serverRSAPublicKeyDER: Data?

    /// SHA-256 of `serverRSAPublicKeyDER` (what `SavedHost.pinnedKeySHA256` stores).
    var serverKeySHA256: Data? { serverRSAPublicKeyDER.map(Authenticator.keyFingerprint) }
}

/// Per-host trust decisions for one connect (H1, security review).
struct AuthPolicy: Sendable, Equatable {
    /// SHA-256 of the Mac's RSA1 public key (DER) from an earlier successful
    /// sign-in (TOFU). When set, a different key fails the connect BEFORE any
    /// credential-bearing packet is sent (`AuthError.serverKeyMismatch`).
    var pinnedKeySHA256: Data?
    /// The user explicitly allowed the legacy (non-SRP) sign-in for this host
    /// (Edit Mac › "Allow legacy (less secure) sign-in"). Off by default; ad-hoc
    /// connections never allow it.
    var allowLegacy = false

    init(pinnedKeySHA256: Data? = nil, allowLegacy: Bool = false) {
        self.pinnedKeySHA256 = pinnedKeySHA256
        self.allowLegacy = allowLegacy
    }
}

enum AuthError: Error, Equatable {
    /// Non-zero SecurityResult. `reason` is an RFB-style `u32 len || utf8`
    /// string if the server sent one promptly after the result (the reference
    /// never reads one; see `readRejectionReason`).
    case rejected(reason: String?)
    /// The server's bytes did not match the expected wire layout.
    case malformed(String)
    /// The server asked for something this client cannot do (e.g. an SRP
    /// group other than RFC 5054 4096-bit/g=5, or a non-2048-bit RSA key).
    case unsupported
    /// The server answered packet-1 with a short (< 1000 byte) message instead
    /// of an SRP challenge: per `auth._read_srp_challenge` this means the
    /// server side "fell back to non-SRP" (it could not route to SRP).
    case srpUnavailable(challengeLength: Int)
    /// SRP was unusable and the only alternative is the legacy (non-SRP)
    /// sign-in, which this host doesn't allow (`AuthPolicy.allowLegacy`).
    /// Nothing was sent with the password.
    case legacyAuthRequired
    /// The Mac's RSA key isn't the pinned one. Raised right after the key
    /// response, before packet-1 (whose identity is encrypted to that key).
    case serverKeyMismatch(presentedSHA256: Data)
    /// The SRP server proof M2 was well-formed but wrong: the peer doesn't
    /// know the password verifier (not the real Mac, or a MITM).
    case serverProofMismatch
}

/// Test seam: deterministic randomness / SRP ephemeral. Production callers
/// use the default (`SecureRandom`).
struct AuthSeams: Sendable {
    /// SRP private-exponent entropy (reference: `os.urandom(64)`); nil = random.
    var privateA: Data? = nil
    /// Source for every other random value: SRP client_random (16), non-SRP
    /// AES key (16), ARD credential padding.
    var random: @Sendable (Int) -> Data = { SecureRandom.bytes($0) }
}

/// Runs RFB security type 33 over an already-handshaken `ByteStream`.
///
/// ## Byte-boundary contract with RFBHandshake (Task 10)
/// Mirrors the reference's split between `rfb.do_protocol_handshake` and
/// `auth._rsa1_init`:
/// * **Handshake (caller) owns**: reading the server's 12-byte `RFB 003.889\n`
///   banner, sending ours, and reading the security-type list
///   (`u8 count || u8[count] types`). It must verify `33` is offered.
///   It does NOT send a selector byte.
/// * **Authenticator owns**: everything from the `0x21` selector byte (sent
///   coalesced with the 14-byte authtype-0 RSA1 key request, exactly as
///   `_rsa1_init` does) through the `u32` SecurityResult inclusive. On
///   success the stream is positioned immediately before ClientInit, which
///   the caller sends.
/// * On any thrown error the stream is in an undefined state (possibly
///   mid-message, or closed if a read was cancelled); the caller must close it.
///
/// ## Fallback policy (`negotiation._phase_auth`)
/// The reference tries SRP first; on *any* `AuthError` it closes the socket,
/// opens a **brand-new TCP connection** (re-running the version/security-type
/// handshake), and runs non-SRP on that. Errors from the fallback attempt
/// propagate. Socket/transport errors are not `AuthError` and do not trigger
/// fallback. Because fallback needs a new connection, `run` performs a single
/// attempt on the stream it is given; `runWithFallback` implements the full
/// policy given a `connect` closure that opens + handshakes a fresh stream.
///
/// ### Deviation (Task 22, security): no fallback after a genuine SRP rejection
/// Unlike the reference, we do **not** fall back to non-SRP when the
/// *primary* attempt is SRP and it fails with `.rejected` — i.e. the full
/// challenge/response exchange completed and the server's SecurityResult
/// says the password was wrong. In that case we close the stream and
/// rethrow `.rejected` directly. Retrying a wrong password via non-SRP
/// would (a) double the number of failed attempts the server sees,
/// tripping lockout/backoff sooner, and (b) resend that same password
/// over the weaker RSA-wrapped-AES-ECB channel instead of SRP — an active
/// MITM that cannot break SRP could deliberately force this downgrade by
/// answering with a bogus `SecurityResult=1` and harvest the password from
/// the non-SRP attempt. Fallback is still used for `.srpUnavailable`
/// (server routed to non-SRP itself) and for `.unsupported`/`.malformed`
/// raised before or while parsing the challenge (SRP itself unusable, not a
/// wrong password) — and, for those two cases, in a few more situations
/// than the reference: bad/truncated DER in the RSA key response, a
/// truncated challenge parse, a too-long username, or a non-RFC5054 SRP
/// group.
///
/// ### Deviation (security review H1): legacy sign-in is opt-in per host
/// A LAN MITM can answer packet-1 with a short message (`.srpUnavailable`)
/// or garbage to force the non-SRP fallback, whose credential blob it can
/// decrypt with its own RSA key — i.e. harvest the Mac password. So the
/// fallback to non-SRP happens only when `policy.allowLegacy` is set (the
/// host's "Allow legacy sign-in" toggle) AND the fallback connection's RSA
/// key matches `policy.pinnedKeySHA256` — or, for a host with no pin yet,
/// the key the SRP attempt saw. Otherwise `.srpUnavailable` becomes
/// `.legacyAuthRequired` and `.unsupported`/`.malformed` propagate, with no
/// second connection. `.serverKeyMismatch` and `.serverProofMismatch` never
/// fall back. Known limitation: `password` is a `String` and cannot be
/// zeroized, so it is retained in memory across the fallback attempt.
enum Authenticator {
    static func run(stream: ByteStream, username: String, password: String,
                    method: AuthResult.Method = .srp, pin: Data? = nil) async throws -> AuthResult {
        try await run(stream: stream, username: username, password: password, method: method, pin: pin,
                      seams: AuthSeams())
    }

    /// SHA-256 of a server key's DER (the pin).
    static func keyFingerprint(_ der: Data) -> Data { Hash.sha256(der) }

    /// `negotiation._phase_auth`: primary method on a fresh connection; on
    /// `AuthError`, close it, reconnect, and run the other method.
    /// - Parameter connect: opens a new TCP connection and runs the RFB
    ///   version + security-type handshake, leaving the stream positioned for
    ///   the `0x21` selector (see the contract above).
    static func runWithFallback(username: String, password: String,
                                policy: AuthPolicy = AuthPolicy(),
                                primary: AuthResult.Method = .srp,
                                seams: AuthSeams = AuthSeams(),
                                connect: @Sendable () async throws -> ByteStream) async throws
        -> (stream: ByteStream, result: AuthResult) {
        let fallback: AuthResult.Method = primary == .srp ? .nonSRP : .srp
        let seenKey = KeySeen()
        let first = try await connect()
        do {
            return (first, try await run(stream: first, username: username, password: password, method: primary,
                                         pin: policy.pinnedKeySHA256, seams: seams, onKey: { seenKey.value = $0 }))
        } catch let error as AuthError {
            first.close()
            switch error {
            case .rejected:
                Log.auth.error("\(primary) auth rejected by server; NOT falling back to \(fallback) " +
                               "(see runWithFallback doc comment: avoids retrying a wrong password over the weaker channel)")
                throw error
            case .serverKeyMismatch, .serverProofMismatch, .legacyAuthRequired:
                Log.auth.error("\(primary) auth failed (\(error)); not falling back")
                throw error
            case .srpUnavailable, .unsupported, .malformed:
                if fallback == .nonSRP, !policy.allowLegacy {
                    Log.auth.error("\(primary) auth failed (\(error)); legacy sign-in not allowed for this host, " +
                                   "NOT falling back to \(fallback)")
                    if case .srpUnavailable = error { throw AuthError.legacyAuthRequired }
                    throw error
                }
                Log.auth.error("\(primary) auth failed (\(error)); falling back to \(fallback) on a new connection")
            }
        } catch {
            first.close()
            throw error
        }
        // The fallback must talk to the same Mac: the pinned key, else the
        // key the first attempt saw (if it got that far).
        let pin = policy.pinnedKeySHA256 ?? seenKey.value
        let second = try await connect()
        do {
            return (second, try await run(stream: second, username: username, password: password, method: fallback,
                                          pin: pin, seams: seams))
        } catch {
            second.close()
            throw error
        }
    }

    /// One attempt. `pin`: the expected key fingerprint (checked before
    /// anything key-encrypted is sent); `onKey`: the presented fingerprint.
    static func run(stream: ByteStream, username: String, password: String,
                    method: AuthResult.Method = .srp, pin: Data? = nil, seams: AuthSeams,
                    onKey: (Data) -> Void = { _ in }) async throws -> AuthResult {
        switch method {
        case .srp:
            return try await doSRPAuth(stream, username: username, password: password, pin: pin, seams: seams,
                                       onKey: onKey)
        case .nonSRP:
            return try await doNonSRPAuth(stream, username: username, password: password, pin: pin, seams: seams,
                                          onKey: onKey)
        }
    }

    /// Throws `.serverKeyMismatch` unless `der` hashes to `pin` (nil: TOFU).
    static func verifyPin(_ der: Data, pin: Data?, onKey: (Data) -> Void) throws {
        let presented = keyFingerprint(der)
        onKey(presented)
        guard let pin else { return }
        guard presented == pin else {
            Log.auth.error("server RSA key does not match the pinned key for this host; refusing before packet-1")
            throw AuthError.serverKeyMismatch(presentedSHA256: presented)
        }
        Log.auth.info("server RSA key matches the pinned key")
    }
}

/// The first attempt's key fingerprint, read by the fallback (same task).
private final class KeySeen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var value: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Constants (auth.py)

private enum K {
    static let srpHashLen = 64                 // SHA-512
    static let srpModulusLen = 512             // 4096 bits
    static let nonSRPAESKeyLen = 16
    static let rsaModulusPayloadLen = 256      // RSA-2048 ciphertext
    static let nonSRPCredFieldLen = 64         // ARD-style slot
    static let packet1TotalLen: UInt32 = 650
    static let packet2TotalLen = 1076
    static let srpMaxIterations: UInt64 = 1_000_000
    static let srpMinChallengeLen = 1000
    /// Sanity bound on server-declared frame lengths (not in the reference,
    /// which would happily allocate whatever the u32 says).
    static let maxFrameLen = 64 * 1024
    static let maxReasonLen = 4096
    /// Cap on server-provided strings (rejection reason, SRP options) echoed
    /// into our logs, after `sanitizeForLog` escapes control characters.
    static let maxLoggedStringLen = 200
    /// How long to wait for an optional reason string after a non-zero result.
    static let reasonGrace: Duration = .milliseconds(500)
}

// MARK: - Shared phase: RSA1 init

struct ServerRSAKey: @unchecked Sendable {   // SecKey is an immutable CF type
    let key: SecKey
    let der: Data
}

extension Authenticator {
    /// `_rsa1_init`: send `0x21` selector + empty authtype-0 RSA1 envelope
    /// (`u32 10 || 0100 || "RSA1" || 0000 || 0000`), read the key response
    /// `u32 len || 2-byte prefix || u32_be key_len || DER[key_len] || …`.
    /// (RFC §4.2.4.1 describes the same bytes as `u32_le 0x100 || u16_be n`;
    /// the reference's u32_be at offset 2 reads the identical value.)
    static func rsa1Init(_ s: ByteStream) async throws -> ServerRSAKey {
        var w = ByteWriter(capacity: 15)
        w.u8(0x21)
        w.u32(10)
        w.u16(0x0100)
        w.bytes(Data("RSA1".utf8))
        w.u16(0)
        w.u16(0)
        try await s.write(w.data)

        let pkt = try await readFrame(s, what: "RSA key response")
        let der: Data
        do {
            var r = ByteReader(pkt)
            try r.skip(2)
            der = try r.bytes(Int(try r.u32()))
        } catch is ByteReader.Error {
            throw AuthError.malformed("RSA key response truncated")
        }
        let key = try loadRSAPublicKey(der)
        Log.auth.info("RSA1 init: server pubkey \(SecKeyGetBlockSize(key) * 8) bits")
        return ServerRSAKey(key: key, der: der)
    }

    /// `load_der_public_key`. `SecKeyCreateWithData` wants PKCS#1
    /// RSAPublicKey; if it rejects the DER as-is (SPKI), strip the SPKI wrapper.
    static func loadRSAPublicKey(_ der: Data) throws -> SecKey {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                      kSecAttrKeyClass: kSecAttrKeyClassPublic]
        if let k = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) { return k }
        if let pkcs1 = DER.pkcs1FromSPKI(der),
           let k = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, nil) { return k }
        throw AuthError.malformed("server RSA public key is not a usable DER RSA key")
    }

    static func rsaEncrypt(_ key: SecKey, _ plaintext: Data) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let ct = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plaintext as CFData, &err) else {
            _ = err?.takeRetainedValue()
            throw AuthError.unsupported
        }
        return ct as Data
    }
}

// MARK: - Non-SRP path

extension Authenticator {
    /// `do_nonsrp_auth`.
    static func doNonSRPAuth(_ s: ByteStream, username: String, password: String, pin: Data? = nil,
                             seams: AuthSeams, onKey: (Data) -> Void = { _ in }) async throws -> AuthResult {
        var lap = Lap()
        let server = try await rsa1Init(s)
        lap.log("RSA1 init")
        try verifyPin(server.der, pin: pin, onKey: onKey)
        let aesKey = seams.random(K.nonSRPAESKeyLen)
        try await sendNonSRPCredentials(s, server: server.key, aesKey: aesKey,
                                        username: username, password: password, random: seams.random)
        lap.log("non-SRP credentials send")
        try await readNonSRPResult(s)
        lap.log("non-SRP result read")
        Log.auth.info("AUTH OK (non-SRP) in \(lap.total.ms) ms")
        return AuthResult(wrapKey: aesKey, method: .nonSRP, serverRSAPublicKeyDER: server.der)
    }

    /// `_pack_ard_credential`: UTF-8 + NUL, random-padded to 64, truncated to 64
    /// (so a ≥64-byte credential loses its terminator — as in the reference).
    static func packARDCredential(_ value: String, random: (Int) -> Data) -> Data {
        var d = Data(value.utf8)
        d.append(0)
        if d.count < K.nonSRPCredFieldLen { d.append(random(K.nonSRPCredFieldLen - d.count)) }
        return d.prefix(K.nonSRPCredFieldLen)
    }

    /// `_send_nonsrp_credentials`: `u32 len || 0100 "RSA1" || 0001 ||
    /// AES-ECB(creds)[128] || 0001 || RSA-PKCS1(aes_key)[256]`.
    static func sendNonSRPCredentials(_ s: ByteStream, server: SecKey, aesKey: Data,
                                      username: String, password: String,
                                      random: (Int) -> Data) async throws {
        let creds = packARDCredential(username, random: random) + packARDCredential(password, random: random)
        let encCreds = try AES.ecbEncrypt(key: aesKey, block: creds)
        let encKey = try rsaEncrypt(server, aesKey)
        var blob = ByteWriter(capacity: 400)
        blob.u16(0x0100)
        blob.bytes(Data("RSA1".utf8))
        blob.u16(1)
        blob.bytes(encCreds)
        blob.u16(1)
        blob.bytes(encKey)
        var w = ByteWriter(capacity: blob.data.count + 4)
        w.u32(UInt32(blob.data.count))
        w.bytes(blob.data)
        try await s.write(w.data)
    }

    /// `_read_nonsrp_result`: 4 padding bytes, then u32 result.
    static func readNonSRPResult(_ s: ByteStream) async throws {
        _ = try await s.read(exactly: 4)
        try await readSecurityResult(s, label: "non-SRP")
    }
}

// MARK: - SRP path

struct SRPChallenge: Sendable, Equatable {
    let N: Data          // 512 bytes
    let g: Data
    let salt: Data
    let B: Data
    let iterations: UInt64
    /// `%s options` kept as raw bytes so packet-2 echoes it byte-for-byte.
    let options: Data
}

extension Authenticator {
    /// `do_srp_auth`.
    static func doSRPAuth(_ s: ByteStream, username: String, password: String, pin: Data? = nil,
                          seams: AuthSeams, onKey: (Data) -> Void = { _ in }) async throws -> AuthResult {
        var lap = Lap()
        let server = try await rsa1Init(s)
        lap.log("RSA1 init")
        // Before packet-1: its identity is encrypted to this key.
        try verifyPin(server.der, pin: pin, onKey: onKey)
        try await sendSRPModulus(s, server: server.key, username: username)
        let challenge = try await readSRPChallenge(s)
        lap.log("SRP modulus sent + challenge read")
        Log.auth.info("SRP: computing proof (PBKDF2 \(challenge.iterations) iters + 4096-bit modexps)…")
        let (publicA, proof) = try await solveSRP(challenge, password: password, privateA: seams.privateA)
        lap.log("SRP solve total")
        try await s.write(try buildSRPPacket2(publicA: publicA, M1: proof.M1,
                                              options: challenge.options, clientRandom: seams.random(16)))
        lap.log("SRP proof send")
        try await readSRPResult(s, proof: proof)
        lap.log("SRP result read")
        Log.auth.info("AUTH OK (SRP) in \(lap.total.ms) ms")
        return AuthResult(wrapKey: proof.wrapKey, method: .srp, serverRSAPublicKeyDER: server.der)
    }

    /// `_send_srp_modulus` (packet-1, RFC §4.2.4.2/§4.2.4.3).
    static func sendSRPModulus(_ s: ByteStream, server: SecKey, username: String) async throws {
        let user = Data(username.utf8)
        var inner = ByteWriter()
        inner.u32(UInt32(user.count))
        inner.bytes(user)
        inner.zeros(3)                       // u16 empty string len, u8 empty opaque len
        var payload = ByteWriter()
        payload.u32(UInt32(inner.data.count))
        payload.bytes(inner.data)
        let encrypted = try rsaEncrypt(server, payload.data)
        guard encrypted.count == K.rsaModulusPayloadLen else {
            Log.auth.error("expected \(K.rsaModulusPayloadLen)B RSA block, got \(encrypted.count)")
            throw AuthError.unsupported
        }
        var w = ByteWriter(capacity: 654)
        w.u32(K.packet1TotalLen)
        w.u16(0x0100)
        w.bytes(Data("RSA1".utf8))
        w.u16(2)
        w.u16(UInt16(K.rsaModulusPayloadLen))
        w.bytes(encrypted)
        w.zeros(384)
        try await s.write(w.data)
    }

    /// `_read_srp_challenge`.
    static func readSRPChallenge(_ s: ByteStream) async throws -> SRPChallenge {
        let body = try await readFrame(s, what: "SRP challenge")
        guard body.count >= K.srpMinChallengeLen else {
            Log.auth.error("SRP challenge too short (\(body.count)B); server fell back to non-SRP path")
            throw AuthError.srpUnavailable(challengeLength: body.count)
        }
        return try parseSRPChallenge(body)
    }

    /// `_parse_apple_srp_challenge`. Like the reference, uses fixed offsets
    /// for the head: 12 header bytes (RFC: `u8 step || u32 x || u32 len ||
    /// %c control || u16 N_len(=513)`), a 0x00 marker (the leading byte of
    /// the 513-byte `%m N`), 512 bytes of N; then `%m g || %o salt || %m B
    /// || %q iterations || %s options`.
    static func parseSRPChallenge(_ body: Data) throws -> SRPChallenge {
        do {
            var r = ByteReader(body)
            try r.skip(12)
            let marker = try r.u8()
            guard marker == 0 else {
                throw AuthError.malformed(String(format: "SRP parse: missing DER zero marker at offset 12, got 0x%02x", marker))
            }
            let N = try r.bytes(K.srpModulusLen)
            let g = try r.readM()
            let salt = try r.readO()
            let B = try r.readM()
            let iterations = try r.readQ()
            let options = try r.readM()     // `%s`, kept as raw bytes for the echo
            guard iterations <= K.srpMaxIterations else {
                throw AuthError.malformed("SRP iteration count \(iterations) exceeds 1M cap")
            }
            Log.auth.info("SRP challenge: N=\(N.count * 8)b g=\(g.map(String.init).joined()) salt=\(salt.count)B iters=\(iterations) cap=\(sanitizeForLog(String(decoding: options, as: UTF8.self)))")
            return SRPChallenge(N: N, g: g, salt: salt, B: B, iterations: iterations, options: options)
        } catch is ByteReader.Error {
            throw AuthError.malformed("SRP challenge truncated")
        }
    }

    /// `_solve_srp` via `SRPClient`. CPU-heavy (PBKDF2 + 4096-bit modexps):
    /// runs on a detached task so it never blocks the caller's executor.
    ///
    /// Cancellation: the detached task is wrapped in
    /// `withTaskCancellationHandler` so cancelling the calling task (e.g. the
    /// user backgrounds/cancels the connect attempt) promptly cancels the
    /// compute too; we also check `Task.isCancelled` between PBKDF2 and
    /// `SRPClient.init`, and again before `respond(to:)`. Note PBKDF2-SHA512
    /// itself (inside `SRPClient.init`) cannot be interrupted mid-computation
    /// — CryptoKit/CommonCrypto's PBKDF2 runs to completion once started, so
    /// cancellation there only takes effect at the next checkpoint, not
    /// instantly.
    static func solveSRP(_ ch: SRPChallenge, password: String,
                         privateA: Data?) async throws -> (publicA: Data, proof: SRPProof) {
        // SRPClient hard-codes the RFC 5054 4096-bit group with g = 5; the
        // reference instead uses whatever N/g the server sent. Apple always
        // sends this group, so refuse anything else rather than mis-compute.
        // Check the byte count before reducing into an Int so a maliciously
        // long `g` can't be shifted into overflow first.
        guard ch.g.count <= 8 else {
            Log.auth.error("SRP challenge uses an unsupported group")
            throw AuthError.unsupported
        }
        let gValue = ch.g.reduce(0) { ($0 << 8) | Int($1) }
        guard ch.N == Data(SRPGroup.N.serialize()), gValue == 5 else {
            Log.auth.error("SRP challenge uses an unsupported group")
            throw AuthError.unsupported
        }
        let task = Task.detached(priority: .userInitiated) { () -> Result<(Data, SRPProof), Error> in
            Result {
                try Task.checkCancellation()
                let started = ContinuousClock.now
                let client = if let privateA {
                    try SRPClient(password: password, salt: ch.salt, iterations: ch.iterations, privateA: privateA)
                } else {
                    try SRPClient(password: password, salt: ch.salt, iterations: ch.iterations)
                }
                let initDone = ContinuousClock.now
                try Task.checkCancellation()
                let proof = try client.respond(to: ch.B)
                let pbkdf2 = client.pbkdf2Duration
                Log.auth.info("SRP timing: PBKDF2=\(pbkdf2.ms) ms, g^a=\((initDone - started - pbkdf2).ms) ms, "
                              + "respond(g^x, S)=\((ContinuousClock.now - initDone).ms) ms")
                return (client.publicA, proof)
            }
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        do {
            let (a, proof) = try result.get()
            return (a, proof)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.auth.error("SRP computation rejected server values: \(error)")
            throw AuthError.malformed("invalid SRP server values")
        }
    }

    /// `_send_srp_proof` (packet-2, RFC §4.2.4.5):
    /// `u32 1076 || 0100 "RSA1" 0002 || u16(inner+4) || u32(inner) || inner || zero pad to 1076`,
    /// inner = `%m A || %o M1 || %s options || %o client_random`.
    /// The reference pads with zeros (the native client's tail is non-zero;
    /// RFC says receivers must not depend on it).
    static func buildSRPPacket2(publicA: Data, M1: Data, options: Data, clientRandom: Data) throws -> Data {
        var sd = ByteWriter(capacity: 700)
        sd.writeM(publicA)
        sd.writeO(M1)
        sd.writeM(options)
        sd.writeO(clientRandom)
        var pay = ByteWriter(capacity: K.packet2TotalLen)
        pay.u16(0x0100)
        pay.bytes(Data("RSA1".utf8))
        pay.u16(2)
        pay.u16(UInt16(truncatingIfNeeded: sd.data.count + 4))
        pay.u32(UInt32(sd.data.count))
        pay.bytes(sd.data)
        // Reference would emit a mislabelled frame here; refuse instead.
        guard pay.data.count <= K.packet2TotalLen else {
            throw AuthError.malformed("SRP options string too long for packet-2 (\(options.count)B)")
        }
        pay.zeros(K.packet2TotalLen - pay.data.count)
        var w = ByteWriter(capacity: K.packet2TotalLen + 4)
        w.u32(UInt32(K.packet2TotalLen))
        w.bytes(pay.data)
        return w.data
    }

    /// `_read_srp_result`: `u32 len || final proof[len] || u32 SecurityResult`.
    /// The reference treats the proof as opaque. We extract M2 (RFC §4.2.4.7)
    /// and verify it; the formula has been verified against a live macOS
    /// server, so a well-formed but WRONG M2 is a hard failure
    /// (`.serverProofMismatch`: the peer doesn't hold the password verifier).
    /// A proof that doesn't parse in either known header shape is only
    /// logged: it carries no M2 to judge, and the record layer (keyed from
    /// K, which only the real verifier holder can derive) still fails closed
    /// at the rekey if the peer is not the Mac.
    static func readSRPResult(_ s: ByteStream, proof: SRPProof) async throws {
        let finalProof = try await readFrame(s, what: "SRP final proof")
        // SecurityResult first: a wrong password is `.rejected` (whatever
        // proof a rejecting server sends); nothing is sent between the two.
        try await readSecurityResult(s, label: "SRP")
        if let m2 = extractM2(finalProof) {
            if proof.verifyServerProof(m2) {
                Log.auth.info("SRP server proof M2 verified")
            } else {
                Log.auth.error("SRP server proof M2 MISMATCH — the Mac's identity could not be verified; failing")
                throw AuthError.serverProofMismatch
            }
        } else {
            // Lengths only: the proof is public, but keep the log terse.
            let head = finalProof.prefix(10).map { String(format: "%02x", $0) }.joined()
            Log.auth.error("SRP final proof (\(finalProof.count)B, header \(head)) did not parse per RFC §4.2.4.7; M2 not checked")
        }
    }

    /// RFC §4.2.4.7 final proof → M2. The inner payload is
    /// `%o M2 || %o server_random || %s "" || %u 0`, behind a header whose
    /// `x` field always equals `payload_len + 4`. Two header shapes:
    ///   * observed live (macOS screensharingd, 98-byte proof):
    ///     `u16 0 || u16 2 || u16 x || u32 payload_len` (10 bytes) — the same
    ///     shape as the challenge (`00000002 0487 00000483 …`), whose fixed
    ///     12-byte skip in `parseSRPChallenge` already assumes it;
    ///   * as written in the RFC text: `u8 step || u32 x || u32 payload_len`
    ///     (9 bytes).
    /// A header is accepted only if `x == payload_len + 4` and the payload
    /// fills the rest of the frame exactly, so the two cannot be confused.
    static func extractM2(_ body: Data) -> Data? {
        func m2(afterHeader n: Int, x: Int, payloadLen: Int) -> Data? {
            guard x == payloadLen + 4, body.count == n + payloadLen else { return nil }
            var r = ByteReader(body.dropFirst(n))
            guard let m2 = try? r.readO(), m2.count == K.srpHashLen else { return nil }
            return m2
        }
        var r10 = ByteReader(body)
        if (try? r10.skip(4)) != nil, let x = try? r10.u16(), let len = try? r10.u32(),
           let v = m2(afterHeader: 10, x: Int(x), payloadLen: Int(len)) {
            return v
        }
        var r9 = ByteReader(body)
        if (try? r9.skip(1)) != nil, let x = try? r9.u32(), let len = try? r9.u32(),
           let v = m2(afterHeader: 9, x: Int(x), payloadLen: Int(len)) {
            return v
        }
        return nil
    }
}

// MARK: - Timing

/// Phase timer for the auth log: `log` prints the time since the previous lap.
struct Lap {
    private let start = ContinuousClock.now
    private var last = ContinuousClock.now
    var total: Duration { ContinuousClock.now - start }
    mutating func log(_ phase: String) {
        let now = ContinuousClock.now
        Log.auth.info("auth timing: \(phase) \((now - last).ms) ms")
        last = now
    }
}

// MARK: - Shared reads

extension Authenticator {
    /// Server-provided strings (rejection `reason`, SRP `options`) are
    /// attacker-controlled bytes echoed straight off the wire. Before they
    /// reach `Log`/the on-device log file, replace control characters
    /// (including newlines, which could otherwise forge extra log lines)
    /// with spaces and cap the length, so a malicious/buggy server can't
    /// pollute or blow up the log.
    static func sanitizeForLog(_ s: String) -> String { ServerText.sanitize(s, maxLength: K.maxLoggedStringLen) }

    /// `u32 len || body[len]`.
    static func readFrame(_ s: ByteStream, what: String) async throws -> Data {
        var r = ByteReader(try await s.read(exactly: 4))
        let len = Int(try r.u32())
        guard len <= K.maxFrameLen else { throw AuthError.malformed("\(what) length \(len) exceeds sanity bound") }
        return try await s.read(exactly: len)
    }

    static func readSecurityResult(_ s: ByteStream, label: String) async throws {
        var r = ByteReader(try await s.read(exactly: 4))
        let result = try r.u32()
        guard result == 0 else {
            // Attacker-controllable text: sanitized + capped before it reaches the log or the UI.
            let reason = await readRejectionReason(s).map(ServerText.sanitize)
            Log.auth.error("\(label) auth rejected: result=\(result) reason=\(reason ?? "<none>")")
            throw AuthError.rejected(reason: reason)
        }
    }

    /// Best-effort read of an RFB 3.8-style failure reason (`u32 len || utf8`).
    /// The reference does not read one and just closes. We wait briefly; if
    /// nothing arrives (or the peer closes) the reason is nil. The read is
    /// cancelled on timeout, which closes a TCP stream — harmless, as the
    /// connection is dead after a rejection anyway.
    static func readRejectionReason(_ s: ByteStream) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let lenData = try? await s.read(exactly: 4) else { return nil }
                var r = ByteReader(lenData)
                guard let len = try? r.u32(), len > 0, len <= K.maxReasonLen,
                      let text = try? await s.read(exactly: Int(len)) else { return nil }
                return String(decoding: text, as: UTF8.self)
            }
            group.addTask {
                try? await Task.sleep(for: K.reasonGrace)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Minimal DER (SPKI → PKCS#1)

enum DER {
    /// SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier SEQUENCE, BIT STRING (0x00 || RSAPublicKey) }
    static func pkcs1FromSPKI(_ der: Data) -> Data? {
        var outer = ByteReader(der)
        guard let (t0, spki) = element(&outer), t0 == 0x30 else { return nil }
        var r = ByteReader(spki)
        guard let (t1, _) = element(&r), t1 == 0x30,
              let (t2, bits) = element(&r), t2 == 0x03, bits.first == 0 else { return nil }
        return Data(bits.dropFirst())
    }

    private static func element(_ r: inout ByteReader) -> (UInt8, Data)? {
        guard let tag = try? r.u8(), let first = try? r.u8() else { return nil }
        var len = Int(first)
        if first & 0x80 != 0 {
            let n = Int(first & 0x7f)
            guard n >= 1, n <= 3 else { return nil }
            len = 0
            for _ in 0..<n {
                guard let b = try? r.u8() else { return nil }
                len = (len << 8) | Int(b)
            }
        }
        guard let body = try? r.bytes(len) else { return nil }
        return (tag, body)
    }
}

// MARK: - RFC §2.5 grammar atoms

extension ByteReader {
    /// `%m`: u16 length || bytes
    mutating func readM() throws -> Data { try bytes(Int(try u16())) }
    /// `%o`: u8 length || bytes
    mutating func readO() throws -> Data { try bytes(Int(try u8())) }
    /// `%s`: u16 length || UTF-8
    mutating func readS() throws -> String { String(decoding: try readM(), as: UTF8.self) }
    /// `%q`: u64
    mutating func readQ() throws -> UInt64 { try u64() }
}

extension ByteWriter {
    /// `%m`: u16 length || bytes (precondition: ≤ 65535 bytes)
    mutating func writeM(_ d: Data) { precondition(d.count <= 0xffff); u16(UInt16(d.count)); bytes(d) }
    /// `%o`: u8 length || bytes (precondition: ≤ 255 bytes)
    mutating func writeO(_ d: Data) { precondition(d.count <= 0xff); u8(UInt8(d.count)); bytes(d) }
    /// `%s`: u16 length || UTF-8
    mutating func writeS(_ s: String) { writeM(Data(s.utf8)) }
    /// `%q`: u64
    mutating func writeQ(_ v: UInt64) { u64(v) }
}
