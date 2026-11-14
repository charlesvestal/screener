import Foundation
import CommonCrypto
import CryptoKit
import Security

enum CryptoError: Error {
    case status(Int32)
    case badLength
    case iterationsOverflow
}

enum AES {
    static func ecbEncrypt(key: Data, block: Data) throws -> Data { try ecb(CCOperation(kCCEncrypt), key, block) }
    static func ecbDecrypt(key: Data, block: Data) throws -> Data { try ecb(CCOperation(kCCDecrypt), key, block) }

    private static func ecb(_ op: CCOperation, _ key: Data, _ input: Data) throws -> Data {
        guard input.count % 16 == 0 else { throw CryptoError.badLength }
        var out = Data(count: input.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, i.baseAddress, input.count,
                            o.baseAddress, input.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }

    /// AES-CTR with a full 16-byte big-endian counter block.
    static func ctr(key: Data, iv: Data, data: Data) throws -> Data {
        var ref: CCCryptorRef?
        var status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
            }
        }
        guard status == kCCSuccess, let ref else { throw CryptoError.status(status) }
        defer { CCCryptorRelease(ref) }
        var out = Data(count: data.count)
        var moved = 0
        status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                CCCryptorUpdate(ref, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }
}

/// One persistent AES-128/256-CBC context: chaining state carries across update() calls.
///
/// `@unchecked Sendable` because `CCCryptorRef` is not itself `Sendable`-checked, and the
/// chaining state inside it is mutated by every `update(_:)` call. Callers must serialize
/// access to a given instance — `update()` is **not** safe to call concurrently from multiple
/// tasks on the same `AESCBCStream`.
final class AESCBCStream: @unchecked Sendable {
    enum Operation { case encrypt, decrypt }
    private let ref: CCCryptorRef

    init(key: Data, iv: Data, operation: Operation) throws {
        var r: CCCryptorRef?
        let op: CCOperation = operation == .encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreate(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(0) /* CBC, no padding */,
                                 k.baseAddress, key.count, v.baseAddress, &r)
            }
        }
        guard status == kCCSuccess, let r else { throw CryptoError.status(status) }
        ref = r
    }
    deinit { CCCryptorRelease(ref) }

    func update(_ input: Data) throws -> Data {
        guard input.count % 16 == 0 else { throw CryptoError.badLength }
        var out = Data(count: input.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                CCCryptorUpdate(ref, i.baseAddress, input.count, o.baseAddress, input.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }
}

enum Hash {
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    static func sha512(_ d: Data) -> Data { Data(SHA512.hash(data: d)) }
}

enum HMAC1 {
    static func sha1(key: Data, data: Data) -> Data {
        Data(CryptoKit.HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

enum PBKDF2 {
    static func sha512(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        guard iterations > 0, iterations <= Int(UInt32.max) else { throw CryptoError.iterationsOverflow }
        var out = Data(count: keyLength)
        let status = out.withUnsafeMutableBytes { o -> Int32 in
            salt.withUnsafeBytes { s -> Int32 in
                password.withUnsafeBytes { p -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        p.bindMemory(to: UInt8.self).baseAddress, password.count,
                        s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations),
                        o.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }
}

enum SecureRandom {
    static func bytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }
}
