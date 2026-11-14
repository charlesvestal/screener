import XCTest
import BigInt
@testable import Screener

/// Times the SRP phases at the iteration count a real Mac sends (116,279).
/// Prints numbers; asserts a generous ceiling so a regression to an
/// unoptimized BigInt (7.8 s on an M1 simulator at -Onone vs ~0.35 s with the
/// vendored -O build) fails loudly.
final class SRPBenchmarkTests: XCTestCase {
    func testSRPPhaseTimings() throws {
        let clock = ContinuousClock()
        let salt = Data(repeating: 0x5a, count: 32)
        let iterations: UInt64 = 116_279

        let t0 = clock.now
        _ = try PBKDF2.sha512(password: Data("correct horse".utf8), salt: salt,
                              iterations: Int(iterations), keyLength: 128)
        let pbkdf2 = clock.now - t0

        let t1 = clock.now
        let client = try SRPClient(password: "correct horse", salt: salt, iterations: iterations,
                                   privateA: Data(repeating: 0x42, count: 64))
        let initTotal = clock.now - t1

        // A plausible B: g^b mod N for some b.
        let B = SRPGroup.g.power(BigUInt(Data(repeating: 0x37, count: 64)), modulus: SRPGroup.N).serialize()
        let t2 = clock.now
        _ = try client.respond(to: B)
        let respond = clock.now - t2

        let msg = "SRP timings: PBKDF2(\(iterations))=\(pbkdf2.ms) ms, init(PBKDF2+g^a)=\(initTotal.ms) ms, "
            + "respond(g^x, S)=\(respond.ms) ms, total=\((initTotal + respond).ms) ms"
        print(msg)
        XCTContext.runActivity(named: msg) { _ in }
        XCTAssertLessThan(initTotal + respond, .seconds(3), msg)
    }
}
