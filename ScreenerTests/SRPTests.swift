import XCTest
import BigInt
@testable import Screener

final class SRPTests: XCTestCase {
    func testMatchesReference() throws {
        let f = try Fixture.load("srp")
        let args = f["args"] as! [String: Any]
        func h(_ k: String) -> Data { Data(hex: f[k] as! String) }
        func ha(_ k: String) -> Data { Data(hex: args[k] as! String) }

        let start = Date()
        let client = try SRPClient(
            password: args["password"] as! String,
            salt: ha("salt"),
            iterations: UInt64(args["iterations"] as! Int),
            privateA: ha("a_entropy_64B")
        )
        XCTAssertEqual(client.publicA.hex, h("A").hex)
        XCTAssertEqual(Data(client.x.serialize()).hex, h("x").hex)
        let (u, S) = try client.debugIntermediates(serverB: h("B"))
        XCTAssertEqual(u.hex, h("u").hex)
        XCTAssertEqual(S.hex, h("S").hex)
        let proof = try client.respond(to: h("B"))
        XCTAssertEqual(proof.M1.hex, h("M1").hex)
        XCTAssertEqual(proof.K.hex, h("K").hex)
        XCTAssertEqual(proof.wrapKey.hex, h("wrap_key").hex)
        XCTAssertTrue(proof.verifyServerProof(h("M2")))
        var bad = h("M2"); bad[0] ^= 1
        XCTAssertFalse(proof.verifyServerProof(bad))
        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 10 { print("SRPTests.testMatchesReference took \(elapsed)s") }
    }

    func testRejectsZeroB() throws {
        let c = try SRPClient(password: "p", salt: Data(count: 32), iterations: 1,
                               privateA: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try c.respond(to: SRPGroup.N.serialize())) { error in
            XCTAssertEqual(error as? SRPError, .invalidServerValue)
        }
    }

    func testRejectsExcessiveIterations() {
        XCTAssertThrowsError(
            try SRPClient(password: "p", salt: Data(count: 32),
                           iterations: SRPClient.maxIterations + 1,
                           privateA: Data(repeating: 1, count: 32))
        ) { error in
            XCTAssertEqual(error as? SRPError, .invalidServerValue)
        }
    }

    func testDefaultEntropyProducesDifferentPublicA() throws {
        let c1 = try SRPClient(password: "p", salt: Data(count: 32), iterations: 1)
        let c2 = try SRPClient(password: "p", salt: Data(count: 32), iterations: 1)
        XCTAssertNotEqual(c1.publicA, c2.publicA)
    }
}
