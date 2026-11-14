import XCTest
@testable import Screener

final class RFBHandshakeTests: XCTestCase {
    private static let banner = Data("RFB 003.889\n".utf8)

    /// RFC §4.1.2/§4.1.3: both banners `RFB 003.889\n`, then the server's
    /// security-type list `04 1e 21 24 23`. Nothing else may be written (the
    /// 0x21 selector belongs to `Authenticator`).
    func testHappyPathOffersType33() async throws {
        let (client, server) = MemoryPipe.pair()
        let serverTask = Task { () -> Data in
            try await server.write(Self.banner)
            let clientBanner = try await server.read(exactly: 12)
            try await server.write(Data(hex: "041e212423"))
            return clientBanner
        }
        let offered = try await RFBHandshake.negotiate(client)
        let clientBanner = try await serverTask.value

        XCTAssertEqual(clientBanner.hex, "524642203030332e3838390a")
        XCTAssertEqual(offered, [30, 33, 36, 35])
        // No selector byte was sent: the server end has nothing more to read.
        client.close()
        do { _ = try await server.read(exactly: 1); XCTFail("unexpected extra byte from client") } catch {}
    }

    /// RFC §4.1.3: count 0 is an RFB failure list; RFB 3.8 follows it with
    /// `u32 len || reason`.
    func testCountZeroFailureListWithReason() async throws {
        let (client, server) = MemoryPipe.pair()
        let reason = "Too many authentication failures"
        _ = Task {
            try await server.write(Self.banner)
            _ = try await server.read(exactly: 12)
            var w = ByteWriter()
            w.u8(0); w.u32(UInt32(reason.utf8.count)); w.bytes(Data(reason.utf8))
            try await server.write(w.data)
        }
        do {
            _ = try await RFBHandshake.negotiate(client)
            XCTFail("expected failure")
        } catch let e as RFBHandshakeError {
            XCTAssertEqual(e, .serverRefused(reason: reason))
        }
    }

    /// Count 0 with the server closing before a reason: still a refusal.
    func testCountZeroFailureListWithoutReason() async throws {
        let (client, server) = MemoryPipe.pair()
        _ = Task {
            try await server.write(Self.banner)
            _ = try await server.read(exactly: 12)
            try await server.write(Data([0]))
            server.close()
        }
        do {
            _ = try await RFBHandshake.negotiate(client)
            XCTFail("expected failure")
        } catch let e as RFBHandshakeError {
            XCTAssertEqual(e, .serverRefused(reason: nil))
        }
    }

    func testType33AbsentIsUnsupported() async throws {
        let (client, server) = MemoryPipe.pair()
        _ = Task {
            try await server.write(Self.banner)
            _ = try await server.read(exactly: 12)
            try await server.write(Data(hex: "031e2423"))
        }
        do {
            _ = try await RFBHandshake.negotiate(client)
            XCTFail("expected failure")
        } catch let e as RFBHandshakeError {
            XCTAssertEqual(e, .unsupported(offered: [30, 36, 35]))
        }
    }

    func testWrongServerVersionIsRejected() async throws {
        let (client, server) = MemoryPipe.pair()
        Task { try await server.write(Data("RFB 003.008\n".utf8)) }
        do {
            _ = try await RFBHandshake.negotiate(client)
            XCTFail("expected failure")
        } catch let e as RFBHandshakeError {
            XCTAssertEqual(e, .unsupportedVersion("RFB 003.008"))
        }
    }

    /// RFC §5.2/§5.3: ClientInit is the single byte 0xC1; ServerInit is
    /// `u16 w, u16 h, 16-byte pixel format, u32 name_len, name`.
    func testClientInitAndServerInit() async throws {
        let (client, server) = MemoryPipe.pair()
        let pf = Data(hex: "2018000100ff00ff00ff100800000000")
        let serverTask = Task { () -> Data in
            let ci = try await server.read(exactly: 1)
            var w = ByteWriter()
            w.u16(3024); w.u16(1964); w.bytes(pf)
            let name = Data("Alex’s MacBook Pro".utf8)
            w.u32(UInt32(name.count)); w.bytes(name)
            try await server.write(w.data)
            return ci
        }
        let si = try await RFBHandshake.clientInit(client)
        let ci = try await serverTask.value
        XCTAssertEqual(ci.hex, "c1")
        XCTAssertEqual(si.width, 3024)
        XCTAssertEqual(si.height, 1964)
        XCTAssertEqual(si.pixelFormat, pf)
        XCTAssertEqual(si.name, "Alex’s MacBook Pro")
    }

    func testServerInitEmptyName() async throws {
        let (client, server) = MemoryPipe.pair()
        _ = Task {
            _ = try await server.read(exactly: 1)
            var w = ByteWriter()
            w.u16(1920); w.u16(1080); w.zeros(16); w.u32(0)
            try await server.write(w.data)
        }
        let si = try await RFBHandshake.clientInit(client)
        XCTAssertEqual([si.width, si.height], [1920, 1080])
        XCTAssertEqual(si.name, "")
    }

    func testServerInitAbsurdNameLengthIsMalformed() async throws {
        let (client, server) = MemoryPipe.pair()
        _ = Task {
            _ = try await server.read(exactly: 1)
            var w = ByteWriter()
            w.u16(1920); w.u16(1080); w.zeros(16); w.u32(0x7fff_ffff)
            try await server.write(w.data)
        }
        do {
            _ = try await RFBHandshake.clientInit(client)
            XCTFail("expected failure")
        } catch let e as RFBHandshakeError {
            XCTAssertEqual(e, .malformedServerInit)
        }
    }
}
