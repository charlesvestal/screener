import AVFoundation
import XCTest
@testable import Screener

final class AudioPlayerTests: XCTestCase {

    // MARK: decoder

    func testConverterCreatesWithReferenceCookie() throws {
        XCTAssertEqual(AACELDDecoder.magicCookie.count, 43)
        XCTAssertEqual(Array(AACELDDecoder.magicCookie[31...36]), [0xF8, 0xE6, 0x51, 0x32, 0xE0, 0x00],
                       "the cookie wraps the AudioSpecificConfig")
        do {
            _ = try AACELDDecoder()
        } catch {
            XCTFail("AudioConverter setup failed at \(error.stage): \(error.status)")
        }
    }

    func testEmptyAndGarbagePayloadsReturnNil() throws {
        let d = try AACELDDecoder()
        XCTAssertNil(d.decode(Data()))
        XCTAssertNil(d.decode(Data(repeating: 0xAB, count: AACELDDecoder.maxPayload + 1)), "oversized")
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let n = Int.random(in: 1...64, using: &rng)
            let garbage = Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
            _ = d.decode(garbage)   // must not crash; output (if any) is bounded
        }
        XCTAssertNil(d.decode(Data(repeating: 0xFF, count: 32)))
        XCTAssertNil(d.decode(Data()))
    }

    func testSilenceAUsDecodeToSilentFrames() throws {
        let d = try AACELDDecoder()
        var frames: [Int] = []
        for _ in 0..<10 { if let n = d.decode(Data(count: 4)) { frames.append(n) } }
        XCTAssertFalse(frames.isEmpty, "4-byte all-zero AUs (the Mac's silence) decode")
        XCTAssertTrue(frames.allSatisfy { $0 > 0 && $0 <= Int(AACELDDecoder.framesPerPacket) }, "\(frames)")
        XCTAssertEqual(frames.last, Int(AACELDDecoder.framesPerPacket), "480 frames (10 ms) per packet")
        let n = frames.last ?? 0
        XCTAssertTrue((0..<(n * 2)).allSatisfy { abs(d.output[$0]) < 1e-3 })
    }

    // MARK: jitter buffer

    private let cfg = AudioJitterBuffer.Config()   // 60 ms target, 200 ms max, 48 kHz

    func testPrefillHoldsUntilTargetThenReleases() {
        var j = AudioJitterBuffer(config: cfg)
        for _ in 0..<5 { XCTAssertEqual(j.enqueue(480), .hold) }
        XCTAssertEqual(j.heldFrames, 2_400)
        XCTAssertEqual(j.enqueue(480), .release, "6 × 10 ms = 60 ms")
        XCTAssertEqual(j.state, .playing)
        XCTAssertEqual(j.queuedFrames, 2_880)
        XCTAssertEqual(j.heldFrames, 0)
        XCTAssertEqual(j.enqueue(480), .play)
        XCTAssertEqual(j.queuedFrames, 3_360)
    }

    func testSteadyStateHasNoUnderrunsOrDrops() {
        var j = AudioJitterBuffer(config: cfg)
        for _ in 0..<6 { _ = j.enqueue(480) }
        for _ in 0..<1_000 {
            XCTAssertEqual(j.enqueue(480), .play)
            XCTAssertFalse(j.consumed(480))
        }
        XCTAssertEqual(j.underruns, 0)
        XCTAssertEqual(j.drops, 0)
        XCTAssertEqual(j.queuedFrames, 2_880)
    }

    func testUnderrunRebuffersWithLongerTarget() {
        var j = AudioJitterBuffer(config: cfg)
        for _ in 0..<6 { _ = j.enqueue(480) }
        for _ in 0..<5 { XCTAssertFalse(j.consumed(480)) }
        XCTAssertTrue(j.consumed(480), "queue ran dry")
        XCTAssertEqual(j.underruns, 1)
        XCTAssertEqual(j.state, .buffering)
        XCTAssertEqual(j.targetFrames, 3_840, "target grows 20 ms")
        for _ in 0..<7 { XCTAssertEqual(j.enqueue(480), .hold) }
        XCTAssertEqual(j.enqueue(480), .release, "80 ms now")
        // Bounded growth.
        for _ in 0..<10 {
            while j.queuedFrames > 0 { j.consumed(480) }
            while j.enqueue(480) != .release {}
        }
        XCTAssertEqual(j.targetFrames, cfg.maxTargetFrames)
    }

    func testTargetRelaxesAfterQuietPeriod() {
        var j = AudioJitterBuffer(config: cfg)
        for _ in 0..<6 { _ = j.enqueue(480) }
        while j.queuedFrames > 0 { j.consumed(480) }           // underrun → 80 ms
        while j.enqueue(480) != .release {}
        XCTAssertEqual(j.targetFrames, 3_840)
        for _ in 0..<(cfg.relaxAfterFrames / 480) {
            _ = j.enqueue(480)
            j.consumed(480)
        }
        XCTAssertEqual(j.targetFrames, 2_880, "10 s without an underrun steps back toward 60 ms")
        XCTAssertEqual(j.underruns, 1)
    }

    func testOverflowDropsAndDrainsBackToTarget() {
        var j = AudioJitterBuffer(config: cfg)
        for _ in 0..<6 { _ = j.enqueue(480) }
        // A burst: nothing consumed.
        var plays = 0
        while j.enqueue(480) == .play { plays += 1 }
        XCTAssertEqual(j.queuedFrames, 9_600, "never more than 200 ms queued")
        XCTAssertEqual(plays, 14)
        XCTAssertEqual(j.state, .draining)
        XCTAssertEqual(j.drops, 1)
        // Still above the target: keep dropping even though there is room.
        j.consumed(480)
        XCTAssertEqual(j.enqueue(480), .drop)
        while j.queuedFrames > 2_880 { j.consumed(480) }
        XCTAssertEqual(j.enqueue(480), .play, "back at the target: playing again")
        XCTAssertEqual(j.state, .playing)
        XCTAssertEqual(j.drops, 2)
        XCTAssertEqual(j.underruns, 0)
    }

    func testResetFlushes() {
        var j = AudioJitterBuffer(config: cfg)
        for _ in 0..<6 { _ = j.enqueue(480) }
        j.consumed(2_880)
        XCTAssertEqual(j.targetFrames, 3_840)
        j.reset()
        XCTAssertEqual(j.state, .buffering)
        XCTAssertEqual(j.queuedFrames, 0)
        XCTAssertEqual(j.heldFrames, 0)
        XCTAssertEqual(j.targetFrames, 2_880)
        XCTAssertFalse(j.consumed(480), "a late completion after a flush is not an underrun")
    }

    // MARK: player

    private func defaults(muted: Bool) -> UserDefaults {
        let name = "AudioPlayerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.set(muted, forKey: AudioPlayer.mutedDefaultsKey)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return d
    }

    private func packet(_ payload: Data, age: Duration = .zero, now: ContinuousClock.Instant) -> MediaPacket {
        MediaPacket(ssrc: 1, seq: 0, timestamp: 0, marker: false, payloadType: 101, payload: payload,
                    arrival: now - age)
    }

    func testMutedDropsWithoutDecoding() {
        let d = defaults(muted: true)
        let player = AudioPlayer(defaults: d)
        defer { player.stop() }
        XCTAssertTrue(player.isMuted)
        let now = ContinuousClock.now
        for _ in 0..<20 { XCTAssertEqual(player.handle(packet(Data(count: 4), now: now), now: now), .muted) }
        let c = player.counterSnapshot
        XCTAssertEqual(c.mutedDrops, 20)
        XCTAssertEqual(c.decoded, 0)
        XCTAssertEqual(c.undecodable, 0)
    }

    func testMuteFollowsDefaults() {
        let d = defaults(muted: false)
        let player = AudioPlayer(defaults: d)
        defer { player.stop() }
        XCTAssertFalse(player.isMuted)
        d.set(true, forKey: AudioPlayer.mutedDefaultsKey)
        XCTAssertTrue(player.isMuted, "the menu's @AppStorage toggle reaches the player")
        let now = ContinuousClock.now
        XCTAssertEqual(player.handle(packet(Data(count: 4), now: now), now: now), .muted)
        d.set(false, forKey: AudioPlayer.mutedDefaultsKey)
        XCTAssertFalse(player.isMuted)
    }

    func testStaleAndUndecodablePacketsAreDropped() {
        let player = AudioPlayer(defaults: defaults(muted: false))
        defer { player.stop() }
        let now = ContinuousClock.now
        XCTAssertEqual(player.handle(packet(Data(count: 4), age: .milliseconds(250), now: now), now: now), .stale)
        XCTAssertEqual(player.handle(packet(Data(), now: now), now: now), .undecodable)
        XCTAssertEqual(player.counterSnapshot.staleDrops, 1)
        XCTAssertEqual(player.counterSnapshot.decoded, 0)
    }

    func testPrefillHoldsDecodedPCM() {
        let player = AudioPlayer(defaults: defaults(muted: false))
        defer { player.stop() }
        let now = ContinuousClock.now
        var outcomes: [AudioPlayer.Outcome] = []
        for _ in 0..<3 { outcomes.append(player.handle(packet(Data(count: 4), now: now), now: now)) }
        XCTAssertTrue(outcomes.allSatisfy { $0 == .held || $0 == .undecodable }, "\(outcomes)")
        XCTAssertLessThan(player.jitterSnapshot.heldFrames, player.jitterSnapshot.targetFrames)
    }

    func testStoppedPlayerIgnoresPackets() {
        let player = AudioPlayer(defaults: defaults(muted: false))
        player.stop()
        player.stop()
        let now = ContinuousClock.now
        XCTAssertEqual(player.handle(packet(Data(count: 4), now: now), now: now), .stopped)
    }
}
