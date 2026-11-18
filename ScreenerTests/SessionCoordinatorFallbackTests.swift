import CoreVideo
import XCTest
@testable import Screener

/// TCP-only fallback (Task 19) end to end through SessionCoordinator: a start
/// burst with no authenticated video switches the same control connection to
/// the framebuffer path, whose zlib rects become the picture.
@MainActor
final class SessionCoordinatorFallbackTests: XCTestCase {

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !cond(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
        if !cond() { throw CancellationError() }
    }

    func testStarvedBurstFallsBackToTheFramebufferPathOnTheSameConnection() async throws {
        let h = try SessionCoordinatorConnectedTests.Harness()
        var seams = h.seams(ip: "10.9.9.1")
        seams.mediaTuning.burstDeadline = .milliseconds(150)
        var policy = SessionCoordinator.Policy()
        policy.firstFrameKeyframeAfter = .seconds(60)
        policy.firstFrameDeadline = .seconds(120)
        let c = SessionCoordinator(policy: policy, seams: seams)
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }

        // No burst is delivered: zero authenticated video packets.
        try await waitUntil("fallback") { c.fallbackReason != nil }
        XCTAssertEqual(c.fallbackReason, .noVideo(packets: 0))
        try await waitUntil("connected") { if case .connected = c.state { true } else { false } }
        XCTAssertEqual(h.authCalls, 1, "same connection: no fresh handshake")
        XCTAssertNotNil(c.input)
        XCTAssertFalse(c.hasFirstFrame)

        // The Mac sends a zlib rect + the update end: it becomes the picture.
        let fake = try XCTUnwrap(h.lastFake)
        let raw = Data((0..<16).flatMap { [UInt8($0), 0x20, 0x30, 0] })
        let z = try Zlib.Deflater().compress(raw)
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(1)
        w.u16(0); w.u16(0); w.u16(4); w.u16(4); w.u32(6); w.u32(UInt32(z.count)); w.bytes(z)
        try await fake.sendRecord(w.data)
        try await waitUntil("framebuffer picture") { c.hasFirstFrame }
        let snap = try XCTUnwrap(c.frames.snapshot(ifNewerThan: nil))
        XCTAssertEqual(snap.tileCount, 1)
        let pb = try XCTUnwrap(snap.frames[0])
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_32BGRA)

        await c.disconnect()
        XCTAssertNil(c.fallbackReason)
        await t.value
    }
}
