// Ported from iShareScreen src/isharescreen/proxy/protocol/auth.py (AGPL-3.0)
//
// Apple's SRP-RFC5054-4096-SHA512-PBKDF2 profile: RFC 5054 4096-bit MODP
// group, SHA-512 hash, PBKDF2-SHA512 password pre-hash, empty SRP identity
// (the real username travels in the RSA-wrapped c2s1 modulus slot, not in
// `x`). See `auth._derive_x` and `auth._solve_srp` in the reference.
import Foundation
import BigInt

enum SRPError: Error {
    case invalidServerValue
}

/// RFC 5054 Appendix A 4096-bit group, as used by Apple's screensharingd.
enum SRPGroup {
    static let N = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F" +
        "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510" +
        "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7" +
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C" +
        "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7" +
        "88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6" +
        "287C59474E6BC05D99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9" +
        "93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF", radix: 16)!
    static let g = BigUInt(5)
    /// Modulus length in bytes (4096 bits), used for all PAD() operations.
    static let length = 512
}

private extension BigUInt {
    /// RFC 5054 PAD(): big-endian, zero-extended (never truncated) to `n` bytes.
    func padded(to n: Int) -> Data {
        let raw = serialize()
        return raw.count >= n ? raw : Data(count: n - raw.count) + raw
    }
}

struct SRPProof {
    let M1: Data
    let K: Data
    let expectedM2: Data
    /// `auth.do_srp_auth`'s final step: the enc1103 master key is
    /// SHA-256(K)[0:16], not K itself.
    var wrapKey: Data { Hash.sha256(K).prefix(16) }

    /// The fixture's M2 is `H(PAD(A) || M1 || K)` per the RFC doc; no
    /// function in the reference computes M2 (it treats the server's M2 as
    /// opaque and unverified), so this is the one formula not cross-checked
    /// against `auth.py` — only against the fixture.
    func verifyServerProof(_ m2: Data) -> Bool { m2 == expectedM2 }
}

struct SRPClient {
    let publicA: Data
    private let a: BigUInt
    private let x: BigUInt
    private let salt: Data

    /// - Parameters:
    ///   - iterations: PBKDF2 iteration count as received on the wire (u64).
    ///     Converted to `Int` with clamping; `PBKDF2.sha512` itself throws if
    ///     the clamped value still exceeds `UInt32.max`.
    ///   - privateA: Raw entropy for the ephemeral private exponent `a`
    ///     (reference uses `os.urandom(64)`). Reduced the same way the
    ///     reference does: `a = (entropy mod (N-1)) + 1`.
    init(password: String, salt: Data, iterations: UInt64, privateA: Data = SecureRandom.bytes(64)) throws {
        self.salt = salt
        let itersInt = iterations > UInt64(Int.max) ? Int.max : Int(iterations)
        let pPrime = try PBKDF2.sha512(password: Data(password.utf8), salt: salt,
                                        iterations: itersInt, keyLength: 128)
        // inner = SHA512("" ":" P'); x = SHA512(salt || inner). Reference's
        // empty identity ("") means the leading H(I) collapses to just ":" + P'.
        let inner = Hash.sha512(Data(":".utf8) + pPrime)
        x = BigUInt(Hash.sha512(salt + inner))

        let entropy = BigUInt(privateA)
        a = (entropy % (SRPGroup.N - 1)) + 1
        publicA = SRPGroup.g.power(a, modulus: SRPGroup.N).padded(to: SRPGroup.length)
    }

    func respond(to serverB: Data) throws -> SRPProof {
        let N = SRPGroup.N, L = SRPGroup.length
        let B = BigUInt(serverB)
        guard B % N != 0 else { throw SRPError.invalidServerValue }
        let Bb = B.padded(to: L)
        let gPadded = SRPGroup.g.padded(to: L)

        // k = H(N || PAD(g))
        let k = BigUInt(Hash.sha512(N.padded(to: L) + gPadded))
        // u = H(PAD(A) || PAD(B))
        let u = BigUInt(Hash.sha512(publicA + Bb))
        guard u != 0 else { throw SRPError.invalidServerValue }

        // S = (B - k*g^x)^(a + u*x) mod N
        let gx = SRPGroup.g.power(x, modulus: N)
        let kgx = (k * gx) % N
        let base = (B + N - kgx) % N
        let S = base.power(a + u * x, modulus: N)
        let K = Hash.sha512(S.padded(to: L))

        // M1 = H(H(N) XOR H(g) || H("") || salt || PAD(A) || PAD(B) || K)
        let hN = Hash.sha512(N.padded(to: L)), hg = Hash.sha512(gPadded)
        let hNxg = Data(zip(hN, hg).map { $0 ^ $1 })
        let hI = Hash.sha512(Data())
        let M1 = Hash.sha512(hNxg + hI + salt + publicA + Bb + K)

        // M2 (not computed by the reference; RFC-doc formula, fixture-verified).
        let M2 = Hash.sha512(publicA + M1 + K)

        return SRPProof(M1: M1, K: K, expectedM2: M2)
    }
}
