import XCTest
@testable import Screener

final class CryptoPrimitivesTests: XCTestCase {
    let key = Data(hex: "000102030405060708090a0b0c0d0e0f")
    let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")

    func testCBCStreamChainsAcrossCalls() throws {
        let pt = Data((0..<48).map { UInt8($0) })
        let one = try AESCBCStream(key: key, iv: iv, operation: .encrypt)
        let whole = try one.update(pt)
        let three = try AESCBCStream(key: key, iv: iv, operation: .encrypt)
        let parts = try three.update(pt[0..<16]) + three.update(pt[16..<32]) + three.update(pt[32..<48])
        XCTAssertEqual(whole, parts)
        let dec = try AESCBCStream(key: key, iv: iv, operation: .decrypt)
        XCTAssertEqual(try dec.update(whole), pt)
    }
    func testECBRoundTrip() throws {
        let block = Data(repeating: 0xab, count: 16)
        XCTAssertEqual(try AES.ecbDecrypt(key: key, block: AES.ecbEncrypt(key: key, block: block)), block)
    }
    func testFIPS197AES128Vector() throws {
        XCTAssertEqual(try AES.ecbEncrypt(key: key, block: Data(hex: "00112233445566778899aabbccddeeff")).hex,
                       "69c4e0d86a7b0430d8cdb78070b4c55a")
    }
    func testPBKDF2SHA512() throws {
        let dk = try PBKDF2.sha512(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 1, keyLength: 64)
        XCTAssertEqual(dk.hex, "867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce")
    }
    func testCTRIsInvolution() throws {
        let k = Data(repeating: 7, count: 32)
        let d = Data((0..<37).map { UInt8($0) })
        XCTAssertEqual(try AES.ctr(key: k, iv: iv, data: AES.ctr(key: k, iv: iv, data: d)), d)
    }
    func testPBKDF2ThrowsOnIterationsOverflow() {
        let tooMany = Int(UInt32.max) + 1
        XCTAssertThrowsError(
            try PBKDF2.sha512(password: Data("password".utf8), salt: Data("salt".utf8), iterations: tooMany, keyLength: 64)
        )
    }

    /// NIST SP 800-38A F.5.5 (CTR-AES256.Encrypt). Expected ciphertext independently
    /// verified via `cryptography.hazmat.primitives.ciphers` (AES-256-CTR, no padding).
    func testAESCTR256KnownAnswerVector() throws {
        let k = Data(hex: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let initialCounter = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plaintext = Data(hex:
            "6bc1bee22e409f96e93d7e117393172a" +
            "ae2d8a571e03ac9c9eb76fac45af8e51" +
            "30c81c46a35ce411e5fbc1191a0a52ef" +
            "f69f2445df4f9b17ad2b417be66c3710")
        let expected =
            "601ec313775789a5b7a7f504bbf3d228" +
            "f443e3ca4d62b59aca84e990cacaf5c5" +
            "2b0930daa23de94ce87017ba2d84988d" +
            "dfc9c58db67aada613c2dd08457941a6"
        XCTAssertEqual(try AES.ctr(key: k, iv: initialCounter, data: plaintext).hex, expected)
    }

    /// FIPS-197 C.3 AES-256 known-answer vector. Expected ciphertext independently
    /// verified via `openssl enc -aes-256-ecb -K ... -nopad`.
    func testECBRoundTripAndKnownAnswerAES256() throws {
        let key256 = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let block = Data(hex: "00112233445566778899aabbccddeeff")
        let ct = try AES.ecbEncrypt(key: key256, block: block)
        XCTAssertEqual(ct.hex, "8ea2b7ca516745bfeafc49904b496089")
        XCTAssertEqual(try AES.ecbDecrypt(key: key256, block: ct), block)
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(ConstantTime.equal(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(ConstantTime.equal(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(ConstantTime.equal(Data([1, 2]), Data([1, 2, 3])))
        XCTAssertTrue(ConstantTime.equal(Data(), Data()))
    }
}
