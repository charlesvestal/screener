// Per-source RTP reception statistics, RFC 3550 Appendix A.1 (sequence
// number validity / extended highest sequence) and A.3 (expected, lost,
// fraction lost). Feeds the RR report blocks and the RCTL bandwidth estimate.
//
// Deviations from A.1 (deliberate):
//   * No probation (MIN_SEQUENTIAL = 0): every packet reaching this has
//     already authenticated with the session's SRTP key, so a new SSRC is
//     valid from its first packet.
//   * `maxGap` records the largest in-order sequence jump (a burst of
//     consecutive missing packets) for the RCTL burstyLoss nibble. A gap that
//     reordering later fills still counts there (an upper bound); the
//     expected/received counts, which drive the loss rate, are exact.
import Foundation

struct RTPReceptionStats: Sendable, Equatable {
    static let maxDropout: UInt16 = 3000
    static let maxMisorder: UInt16 = 100
    private static let seqMod: UInt32 = 1 << 16

    private(set) var baseSeq: UInt32 = 0
    private(set) var maxSeq: UInt16 = 0
    /// Shifted count of sequence number cycles (multiples of 65536).
    private(set) var cycles: UInt32 = 0
    private var badSeq: UInt32 = seqMod + 1
    /// Packets received (duplicates included, as in A.1).
    private(set) var received: UInt32 = 0
    private var expectedPrior: Int64 = 0
    private var receivedPrior: Int64 = 0
    /// Separate interval baseline for the bandwidth estimator.
    private var estExpectedPrior: Int64 = 0
    private var estReceivedPrior: Int64 = 0
    /// Largest in-order gap (missing packets) since the last `takeMaxGap()`.
    private var maxGap = 0

    init(firstSeq: UInt16) {
        initSeq(firstSeq)
        received = 1
    }

    private mutating func initSeq(_ seq: UInt16) {
        baseSeq = UInt32(seq)
        maxSeq = seq
        badSeq = Self.seqMod + 1
        cycles = 0
        received = 0
        expectedPrior = 0; receivedPrior = 0
        estExpectedPrior = 0; estReceivedPrior = 0
    }

    /// A.1 update_seq. Returns false for a packet that is not counted (a
    /// very large jump not yet confirmed by its successor).
    @discardableResult
    mutating func update(_ seq: UInt16) -> Bool {
        let udelta = seq &- maxSeq
        if udelta < Self.maxDropout {
            // In order, with a permissible gap.
            if seq < maxSeq { cycles &+= Self.seqMod }
            if udelta > 1 { maxGap = max(maxGap, Int(udelta) - 1) }
            maxSeq = seq
        } else if udelta <= UInt16(Self.seqMod - UInt32(Self.maxMisorder)) {
            // A very large jump: the sender restarted, unless it is a stray.
            if UInt32(seq) == badSeq {
                initSeq(seq)
            } else {
                badSeq = (UInt32(seq) + 1) & (Self.seqMod - 1)
                return false
            }
        } else {
            // Duplicate or reordered (late) packet: counted, max unchanged.
        }
        received &+= 1
        return true
    }

    var extendedMax: UInt32 { cycles &+ UInt32(maxSeq) }
    var expected: Int64 { Int64(extendedMax) - Int64(baseSeq) + 1 }
    /// Cumulative lost (A.3); negative when duplicates outnumber losses.
    var cumulativeLost: Int64 { expected - Int64(received) }

    /// A.3 for one report block: fraction lost since the previous report
    /// (8-bit fixed point, 0 when nothing was lost or late packets made up
    /// for it) and the cumulative count clamped to the 24-bit signed field.
    mutating func makeReport() -> RTCP.LossReport {
        let exp = expected, rec = Int64(received)
        let expectedInterval = exp - expectedPrior
        let receivedInterval = rec - receivedPrior
        expectedPrior = exp
        receivedPrior = rec
        let lostInterval = expectedInterval - receivedInterval
        let fraction: UInt8 = expectedInterval <= 0 || lostInterval <= 0
            ? 0 : UInt8(min(255, (lostInterval << 8) / expectedInterval))
        let cum = Int32(max(-0x80_0000, min(0x7F_FFFF, cumulativeLost)))
        return RTCP.LossReport(fractionLost: fraction, cumulativeLost: cum)
    }

    /// Expected / received packets since the previous call (estimator ticks).
    /// `received` can exceed `expected` in one interval when late packets
    /// fill an earlier gap; sum over a window to cancel that out.
    mutating func takeCounts() -> (expected: Int, received: Int) {
        let exp = expected, rec = Int64(received)
        defer { estExpectedPrior = exp; estReceivedPrior = rec }
        return (Int(exp - estExpectedPrior), Int(rec - estReceivedPrior))
    }

    mutating func takeMaxGap() -> Int {
        defer { maxGap = 0 }
        return maxGap
    }
}
