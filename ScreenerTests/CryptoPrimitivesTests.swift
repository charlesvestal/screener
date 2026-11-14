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
}
