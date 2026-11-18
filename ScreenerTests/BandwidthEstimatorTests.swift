import XCTest
@testable import Screener

final class BandwidthEstimatorTests: XCTestCase {
    private let tick = 0.05

    /// A host that sends min(estimate, demand) kbps over a link of `capacity`
    /// kbps: what exceeds the capacity is lost. ~1200-byte packets.
    private struct Link {
        var capacityKbps: Double = .infinity
        var demandKbps: Double = .infinity
        var extraLoss = 0.0
        /// Any lost packet also makes the assembler ask for a keyframe.
        var lossTriggersRecovery = false

        func sample(estimateKbps: Double, dt: Double) -> BandwidthEstimator.Sample {
            let sent = min(estimateKbps, demandKbps)
            let delivered = min(sent, capacityKbps) * (1 - extraLoss)
            let sentPkts = Int((sent * 1000 / 8 * dt / 1200).rounded())
            let gotPkts = Int((delivered * 1000 / 8 * dt / 1200).rounded())
            return .init(rxBytes: Int(delivered * 1000 / 8 * dt), expected: sentPkts, received: gotPkts,
                         recoveryEvents: lossTriggersRecovery && gotPkts < sentPkts ? 1 : 0)
        }
    }

    /// Runs `seconds` of 50 ms ticks; returns the estimate after each tick.
    @discardableResult
    private func run(_ e: inout BandwidthEstimator, _ link: Link, from t0: Double, seconds: Double,
                     events: (Double) -> BandwidthEstimator.Sample? = { _ in nil }) -> [Double] {
        var out: [Double] = []
        let n = Int((seconds / tick).rounded())
        for i in 1...n {
            let now = t0 + Double(i) * tick
            var s = link.sample(estimateKbps: e.estimateKbps, dt: tick)
            if let extra = events(now) {
                s.recoveryEvents += extra.recoveryEvents
                s.decodeBacklog = extra.decodeBacklog
            }
            e.update(s, now: now)
            out.append(e.estimateKbps)
        }
        return out
    }

    func testStartsAtTheInitialValueAndHoldsDuringStartupGrace() {
        var e = BandwidthEstimator()
        XCTAssertEqual(e.bweKbps, 30_000)
        e.update(.init(rxBytes: 0, expected: 100, received: 10, recoveryEvents: 3), now: 0)
        e.update(.init(rxBytes: 0, expected: 100, received: 10, recoveryEvents: 3), now: 0.5)
        XCTAssertEqual(e.state, .startup)
        XCTAssertEqual(e.bweKbps, 30_000)
    }

    func testConvergesUpOnACleanBusyLinkAndStopsAtTheCeiling() {
        var e = BandwidthEstimator()
        let trace = run(&e, Link(), from: 0, seconds: 30)
        XCTAssertTrue(zip(trace, trace.dropFirst()).allSatisfy { $0 <= $1 }, "monotonic on a clean link")
        // 6 %/s from 30 Mbps after the 1 s grace: ~40 Mbps 5 s later.
        XCTAssertGreaterThan(trace[Int(6 / tick)], 38_000)
        XCTAssertLessThan(trace[Int(6 / tick)], 42_000)
        XCTAssertEqual(e.bweKbps, 65_000, "reaches the ceiling (30 → 65 Mbps takes ~14 s)")
        XCTAssertEqual(trace.max(), 65_000)
        XCTAssertEqual(e.decreases, 0)
    }

    func testBacksOffOnALossBurstAndHoldsOffBeforeTheNextDecrease() {
        var e = BandwidthEstimator(config: .init(initialKbps: 50_000))
        run(&e, Link(demandKbps: 50_000), from: 0, seconds: 3)
        let before = e.estimateKbps
        // 30 % loss for 0.5 s.
        var lossy = Link(demandKbps: 50_000); lossy.extraLoss = 0.3
        let during = run(&e, lossy, from: 3, seconds: 0.5)
        XCTAssertEqual(e.decreases, 1, "one decrease, then the hold-off")
        XCTAssertLessThanOrEqual(during.last!, before * 0.85 + 1)
        // The burst clears: the window still holds it for ≤ 1 s, then the dead band, then the increase hold-off.
        let after = run(&e, Link(demandKbps: 50_000), from: 3.5, seconds: 1.5)
        XCTAssertLessThanOrEqual(e.decreases, 2)
        XCTAssertTrue(after.allSatisfy { $0 <= during.last! })
        run(&e, Link(demandKbps: 50_000), from: 5, seconds: 5)
        XCTAssertEqual(e.state, .increase, "recovers once the link is clean again")
    }

    func testHeavyLossCutsTowardTheReceiveRate() {
        var e = BandwidthEstimator(config: .init(initialKbps: 60_000))
        // A 20 Mbps link: the host overshoots by 3×.
        run(&e, Link(capacityKbps: 20_000), from: 0, seconds: 1.0)
        run(&e, Link(capacityKbps: 20_000), from: 1.0, seconds: 0.05)
        XCTAssertEqual(e.decreases, 1)
        XCTAssertEqual(e.estimateKbps, 30_000, accuracy: 1, "capped at halving per step")
        run(&e, Link(capacityKbps: 20_000), from: 1.05, seconds: 1.0)
        XCTAssertEqual(e.estimateKbps, 17_000, accuracy: 300, "0.85 × the 20 Mbps receive rate")
    }

    func testHoldsWhenAppLimited() {
        var e = BandwidthEstimator(config: .init(initialKbps: 50_000))
        // Static screen: 3 Mbps of a 50 Mbps estimate, no loss.
        let trace = run(&e, Link(demandKbps: 3_000), from: 0, seconds: 30)
        XCTAssertEqual(e.state, .appLimited)
        XCTAssertTrue(trace.allSatisfy { $0 == 50_000 }, "never decays toward the idle receive rate")
        // Nothing at all arriving: also a hold.
        e.update(.init(), now: 40)
        for i in 1...40 { e.update(.init(), now: 40 + Double(i) * tick) }
        XCTAssertEqual(e.state, .noData)
        XCTAssertEqual(e.bweKbps, 50_000)
        // Motion resumes on a clean link: increases again.
        run(&e, Link(), from: 50, seconds: 3)
        XCTAssertEqual(e.state, .increase)
        XCTAssertGreaterThan(e.estimateKbps, 50_000)
    }

    func testRespectsTheFloorAndTheCeiling() {
        var e = BandwidthEstimator(config: .init(initialKbps: 10_000, floorKbps: 4_000, ceilingKbps: 12_000))
        var dead = Link(); dead.extraLoss = 0.5
        let down = run(&e, dead, from: 0, seconds: 60)
        XCTAssertEqual(e.bweKbps, 4_000)
        XCTAssertTrue(down.allSatisfy { $0 >= 4_000 })
        let up = run(&e, Link(), from: 60, seconds: 60)
        XCTAssertEqual(e.bweKbps, 12_000)
        XCTAssertTrue(up.allSatisfy { $0 <= 12_000 })
        // The wire field is a u16: a ceiling above it clamps.
        let big = BandwidthEstimator(config: .init(initialKbps: 90_000, ceilingKbps: 100_000))
        XCTAssertEqual(big.bweKbps, 65_535)
    }

    func testLossInTheDeadBandHolds() {
        var e = BandwidthEstimator(config: .init(initialKbps: 40_000))
        var link = Link(demandKbps: 40_000); link.extraLoss = 0.05
        let trace = run(&e, link, from: 0, seconds: 20)
        XCTAssertEqual(e.state, .hold)
        XCTAssertTrue(trace.allSatisfy { $0 == 40_000 }, "2–10 % loss neither raises nor lowers")
        XCTAssertEqual(e.decreases, 0)
    }

    /// AIMD against a fixed-capacity link (any loss → a keyframe request)
    /// settles into a slow sawtooth around the capacity, not tick-to-tick
    /// flapping.
    func testHysteresisPreventsOscillation() {
        var e = BandwidthEstimator(config: .init(initialKbps: 20_000))
        var times: [Double] = []
        var states: [BandwidthEstimator.State] = []
        var link = Link(capacityKbps: 25_000)
        link.lossTriggersRecovery = true
        for i in 1...Int(120 / tick) {
            let now = Double(i) * tick
            let before = e.decreases
            e.update(link.sample(estimateKbps: e.estimateKbps, dt: tick), now: now)
            if e.decreases > before { times.append(now) }
            states.append(e.state)
            if now > 30 {
                XCTAssertGreaterThan(e.estimateKbps, 25_000 * 0.8)
                XCTAssertLessThan(e.estimateKbps, 25_000 * 1.15)
            }
        }
        XCTAssertGreaterThan(times.count, 0, "it does probe past the capacity")
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 1.0 }, "decreases respect the hold-off")
        XCTAssertLessThanOrEqual(times.count, 15, "≥ ~8 s between decreases on average (slow increase near the cut point)")
        let flips = zip(states, states.dropFirst()).filter { $0 == .increase && $1 == .decrease }.count
        XCTAssertLessThanOrEqual(flips, times.count)
    }

    func testRecoveryEventsDecreaseWithTheirOwnHoldoffAndBlockIncreases() {
        var e = BandwidthEstimator(config: .init(initialKbps: 40_000))
        run(&e, Link(), from: 0, seconds: 3)
        let top = e.estimateKbps
        e.update(.init(rxBytes: 250_000, expected: 100, received: 100, recoveryEvents: 2), now: 3.05)
        XCTAssertEqual(e.state, .decrease)
        XCTAssertEqual(e.estimateKbps, top * 0.85, accuracy: 0.5)
        // A re-request 1 s later (keyframe still pending): no second cut yet.
        run(&e, Link(), from: 3.05, seconds: 1.0)
        e.update(.init(rxBytes: 250_000, expected: 100, received: 100, recoveryEvents: 1), now: 4.1)
        XCTAssertEqual(e.state, .holdoff)
        XCTAssertEqual(e.decreases, 1)
        XCTAssertEqual(e.estimateKbps, top * 0.85, accuracy: 0.5, "no increase right after recovery")
        // After the recovery hold-off: a backlog signal cuts again.
        run(&e, Link(), from: 4.1, seconds: 2.0)
        e.update(.init(rxBytes: 250_000, expected: 100, received: 100, decodeBacklog: true), now: 6.2)
        XCTAssertEqual(e.decreases, 2)
    }

    /// Late (reordered) packets fill a gap in the next tick: the windowed
    /// loss cancels them, so no decrease.
    func testLatePacketsAreNotLoss() {
        var e = BandwidthEstimator(config: .init(initialKbps: 20_000))
        run(&e, Link(demandKbps: 20_000), from: 0, seconds: 2)
        e.update(.init(rxBytes: 125_000, expected: 100, received: 80), now: 2.05)
        XCTAssertGreaterThan(e.lossFraction ?? 0, 0)
        e.update(.init(rxBytes: 125_000, expected: 100, received: 120), now: 2.10)
        XCTAssertEqual(e.decreases, 0)
        XCTAssertEqual(e.lossFraction ?? -1, 0, accuracy: 0.001)
    }
}

final class RTPReceptionStatsTests: XCTestCase {
    func testInOrderHasNoLoss() {
        var s = RTPReceptionStats(firstSeq: 100)
        for q in UInt16(101)...199 { s.update(q) }
        XCTAssertEqual(s.expected, 100)
        XCTAssertEqual(s.received, 100)
        XCTAssertEqual(s.makeReport(), .init(fractionLost: 0, cumulativeLost: 0))
    }

    /// RFC 3550 A.3: fraction = (lost_interval << 8) / expected_interval.
    func testGapsAreLostAndFractionIsPerInterval() {
        var s = RTPReceptionStats(firstSeq: 0)
        for q in UInt16(1)...99 where !(40..<50).contains(q) { s.update(q) }
        XCTAssertEqual(s.makeReport(), .init(fractionLost: 25, cumulativeLost: 10))  // 10 × 256 / 100
        XCTAssertEqual(s.takeMaxGap(), 10)
        XCTAssertEqual(s.takeMaxGap(), 0)
        for q in UInt16(100)...199 { s.update(q) }
        XCTAssertEqual(s.makeReport(), .init(fractionLost: 0, cumulativeLost: 10), "clean interval, cumulative kept")
    }

    func testLatePacketsFillTheGap() {
        var s = RTPReceptionStats(firstSeq: 10)
        s.update(11); s.update(14); s.update(15)
        XCTAssertEqual(s.cumulativeLost, 2)
        s.update(12); s.update(13)                 // reordered, arrive late
        XCTAssertEqual(s.cumulativeLost, 0)
        XCTAssertEqual(s.extendedMax, 15)
        let c = s.takeCounts()
        XCTAssertEqual(c.expected, 6)
        XCTAssertEqual(c.received, 6)
    }

    func testLateArrivalsAfterAReportGiveAZeroFractionNotNegative() {
        var s = RTPReceptionStats(firstSeq: 0)
        s.update(1); s.update(4)
        XCTAssertEqual(s.makeReport(), .init(fractionLost: 102, cumulativeLost: 2))  // 2 × 256 / 5
        s.update(2); s.update(3)
        XCTAssertEqual(s.makeReport(), .init(fractionLost: 0, cumulativeLost: 0))
    }

    func testDuplicatesMakeCumulativeNegative() {
        var s = RTPReceptionStats(firstSeq: 5)
        s.update(6); s.update(6); s.update(6)
        XCTAssertEqual(s.makeReport(), .init(fractionLost: 0, cumulativeLost: -2))
    }

    func testSequenceWrapCountsCycles() {
        var s = RTPReceptionStats(firstSeq: 65_530)
        for q in UInt16(65_531)...65_535 { s.update(q) }
        for q in UInt16(0)...9 { s.update(q) }
        XCTAssertEqual(s.cycles, 65_536)
        XCTAssertEqual(s.extendedMax, 65_536 + 9)
        XCTAssertEqual(s.expected, 16)
        XCTAssertEqual(s.cumulativeLost, 0)
    }

    func testLargeJumpResyncsOnlyAfterTwoSequentialPackets() {
        var s = RTPReceptionStats(firstSeq: 100)
        s.update(101)
        XCTAssertFalse(s.update(30_000), "a stray far jump is not counted")
        XCTAssertEqual(s.received, 2)
        s.update(102)
        XCTAssertFalse(s.update(40_000))
        XCTAssertTrue(s.update(40_001), "its successor confirms a sender restart")
        XCTAssertEqual(s.baseSeq, 40_001)
        XCTAssertEqual(s.received, 1)
        XCTAssertEqual(s.cumulativeLost, 0)
    }

    func testCumulativeLostClampsTo24BitsAndTheWireCarriesIt() {
        var s = RTPReceptionStats(firstSeq: 0)
        // 4000 in-order jumps of 2999: ~12 M lost, over the 24-bit field.
        var q: UInt16 = 0
        for _ in 0..<4000 { q = q &+ 2999; s.update(q) }
        XCTAssertEqual(s.cumulativeLost, Int64(4000 * 2998))
        XCTAssertEqual(s.makeReport().cumulativeLost, 0x7F_FFFF, "clamped")
        let rr = RTCP.receiverReport(senderSSRC: 1, sources: [7], loss: [7: .init(fractionLost: 0x40, cumulativeLost: -2)],
                                     now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rr.subdata(in: 12..<16).hex, "40fffffe", "fraction | 24-bit two's-complement cumulative")
    }
}
