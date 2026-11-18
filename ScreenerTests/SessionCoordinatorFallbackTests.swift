import CoreVideo
import XCTest
@testable import Screener

/// TCP-only fallback (Task 19) end to end through SessionCoordinator: a start
/// burst with no authenticated video tears the HP connection down and
/// reconnects the SAME host without a media offer (not an in-place
/// SetEncodings switch — macOS ignores that, see SessionCoordinator's
/// header), whose zlib rects become the picture.
@MainActor
final class SessionCoordinatorFallbackTests: XCTestCase {

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !cond(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
        if !cond() { throw CancellationError() }
    }

    func testStarvedBurstReconnectsWithoutAMediaOfferToTheFramebufferPath() async throws {
        let h = try SessionCoordinatorConnectedTests.Harness()
        h.framebufferOnlyFromIndex = 2   // the 2nd connection is the no-offer reconnect
        var seams = h.seams(ip: "10.9.9.1")
        seams.mediaTuning.burstDeadline = .milliseconds(150)
        var policy = SessionCoordinator.Policy()
        policy.firstFrameKeyframeAfter = .seconds(60)
        policy.firstFrameDeadline = .seconds(120)
        let c = SessionCoordinator(policy: policy, seams: seams)
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }

        // No burst is delivered on the HP connection: zero authenticated
        // video packets falls back at once.
        try await waitUntil("fallback") { c.fallbackReason != nil }
        XCTAssertEqual(c.fallbackReason, .noVideo(packets: 0))

        // The fallback tears the HP connection down and reconnects: a SECOND
        // fresh handshake, not a mid-session SetEncodings switch.
        try await waitUntil("reconnected without a media offer") { h.authCalls >= 2 }
        try await waitUntil("connected") { if case .connected = c.state { true } else { false } }
        XCTAssertEqual(h.authCalls, 2, "exactly one fresh reconnect, no loop")
        XCTAssertNotNil(c.input)
        XCTAssertFalse(c.hasFirstFrame)
        XCTAssertEqual(c.fallbackReason, .noVideo(packets: 0), "the badge survives the reconnect")

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
