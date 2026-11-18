// Ported from iShareScreen src/isharescreen/proxy/protocol/rtcp.py (AGPL-3.0)
//
// RTCP feedback builders and parsers. The host is an AVConference RTCP peer:
// we only build receiver-side feedback (we never encode), plus an empty SR so
// its liveness check accepts us as a sender.
//
//   PT 192  legacy Full-INTRA-frame Request (RFC 2032) — the native viewer's FIR
//   PT 200  Sender Report      PT 201  Receiver Report
//   PT 204  APP (Apple LTR-ACK, subtype 5)
//   PT 205  transport feedback (NACK = FMT 1)
//   PT 206  payload-specific feedback (PLI = FMT 1, FIR = FMT 4)
//
// Every builder returns plaintext; the caller wraps it with SRTCPEncryptor.
// Deviation: `now` is injectable (the reference reads time.time()) so the
// time-dependent fields are testable.
import Foundation

enum RTCP {
    /// Seconds between 1900-01-01 (NTP epoch) and 1970-01-01.
    static let ntpEpochDelta: UInt64 = 2_208_988_800

    /// Per-source sequence state carried in an RR report block.
    struct SourceStats: Sendable, Equatable {
        var maxSeq: UInt16
        var roc: UInt32
    }

    /// RFC 3550 §6.4.1 loss fields of one report block (A.3).
    struct LossReport: Sendable, Equatable {
        var fractionLost: UInt8
        /// Clamped to the 24-bit signed field.
        var cumulativeLost: Int32
    }

    /// Last Sender Report seen from a source: the middle 32 bits of its NTP
    /// timestamp (LSR) and when it arrived (for DLSR).
    struct SRInfo: Sendable, Equatable {
        var lsr: UInt32
        var arrival: Date
    }

    /// RFC 5761 demux: a version-2 packet whose second byte, with the marker
    /// bit cleared, is 72...79 is RTCP (PT 200–207); anything else is RTP.
    static func isRTCP(_ pkt: Data) -> Bool {
        guard pkt.count >= 2 else { return false }
        let b0 = pkt[pkt.startIndex], b1 = pkt[pkt.startIndex + 1]
        guard b0 & 0xC0 == 0x80 else { return false }
        return (72...79).contains(b1 & 0x7F)
    }

    /// build_fir: Full Intra Request (RFC 5104 §4.3.1.1).
    static func fir(senderSSRC: UInt32, targetSSRC: UInt32, seq: UInt8) -> Data {
        var w = ByteWriter()
        w.u8(0x80 | 4); w.u8(206); w.u16(4)
        w.u32(senderSSRC); w.u32(0)
        w.u32(targetSSRC)
        w.u8(seq); w.zeros(3)
        return w.data
    }

    /// build_fir_legacy: RFC 2032 §5.2.1 FIR (PT 192), what the native viewer
    /// sends; screensharingd answers it with a fresh IDR where it often
    /// ignores the AVPF FIR.
    static func firLegacy(targetSSRC: UInt32) -> Data {
        var w = ByteWriter()
        w.u8(0x80); w.u8(192); w.u16(1); w.u32(targetSSRC)
        return w.data
    }

    /// build_pli: Picture Loss Indication (RFC 4585 §6.3.1).
    static func pli(senderSSRC: UInt32, mediaSSRC: UInt32) -> Data {
        var w = ByteWriter()
        w.u8(0x80 | 1); w.u8(206); w.u16(2)
        w.u32(senderSSRC); w.u32(mediaSSRC)
        return w.data
    }

    /// build_nack: generic NACK (RFC 4585 §6.2.1); consecutive losses within
    /// 16 of a PID coalesce into its BLP. Empty input → empty Data.
    static func nack(senderSSRC: UInt32, mediaSSRC: UInt32, lostSeqs: some Sequence<UInt16>) -> Data {
        let seqs = Set(lostSeqs).sorted()
        guard !seqs.isEmpty else { return Data() }
        var fcis = ByteWriter()
        var nFCI = 0
        var i = 0
        while i < seqs.count {
            let pid = seqs[i]
            var blp: UInt16 = 0
            var j = i + 1
            while j < seqs.count {
                let diff = seqs[j] &- pid
                guard (1...16).contains(diff) else { break }
                blp |= 1 << (diff - 1)
                j += 1
            }
            fcis.u16(pid); fcis.u16(blp)
            nFCI += 1
            i = j
        }
        var w = ByteWriter()
        w.u8(0x80 | 1); w.u8(205); w.u16(UInt16(2 + nFCI))
        w.u32(senderSSRC); w.u32(mediaSSRC)
        w.bytes(fcis.data)
        return w.data
    }

    /// build_rtcp_app_ltrp: Apple's LTR acknowledgment (APP, subtype 5).
    static func appLTR(senderSSRC: UInt32, ltrID: UInt32) -> Data {
        var w = ByteWriter()
        w.u8(0x80); w.u8(204); w.u16(3); w.u32(senderSSRC)
        w.u32(5)
        w.u32(ltrID)
        return w.data
    }

    /// APP name "RCTL" (0x5243544C): AVConference's receiver rate-control
    /// feedback (VCRC), what the native viewer sends every 50 ms on P+1.
    /// Layout from AVConference's -[VCVideoStreamRateAdaptationFeedbackOnly
    /// sendRateControlFeedback] → VCMediaControlInfoSerializeWithData (type 2,
    /// 20 bytes) → RTPSendRTCP's "RCTL" custom report (macOS 27 build):
    ///
    ///     [0]      0x85            0x80 | info flags 5
    ///     [1]      u8              interval-ish field (stats+0x40 × 1000 / 20); 0
    ///     [2..3]   0x0004          length of the info in words - 1
    ///     [4..5]   u16  echo       echoed media timestamp (last received RTP ts)
    ///     [6..9]   0
    ///     [10..11] u16  echoDelay  ms since that packet arrived (clamped 0xFFFF)
    ///     [12..13] u16  now        receiver clock in 1/1024 s
    ///     [14..15] u16  owrd       one-way relative delay, RTPPackDouble (0 = none)
    ///     [16..17] u16             burstyLoss << 12 | (loss field & 0xFFF)
    ///     [18..19] u16  bwe        receiver bandwidth estimate (units unverified; kbps assumed)
    static let rctlName: UInt32 = 0x5243_544C

    static func appRCTL(senderSSRC: UInt32, echo: UInt16, echoDelayMs: UInt16, now1024: UInt16,
                        owrd: UInt16 = 0, burstyLoss: UInt8 = 0, lossField: UInt16 = 0, bwe: UInt16) -> Data {
        var w = ByteWriter()
        w.u8(0x80); w.u8(204); w.u16(7); w.u32(senderSSRC)
        w.u32(rctlName)
        w.u8(0x85); w.u8(0); w.u16(4)
        w.u16(echo); w.zeros(4)
        w.u16(echoDelayMs); w.u16(now1024); w.u16(owrd)
        w.u16(UInt16(min(burstyLoss, 15)) << 12 | lossField & 0x0FFF)
        w.u16(bwe)
        return w.data
    }

    /// build_empty_sr: an empty Sender Report so AVConference sees a live sender.
    static func emptySR(senderSSRC: UInt32, now: Date = Date()) -> Data {
        let t = now.timeIntervalSince1970
        let whole = t.rounded(.towardZero)
        let ntpSec = UInt32(truncatingIfNeeded: UInt64(whole) + ntpEpochDelta)
        let ntpFrac = UInt32(truncatingIfNeeded: UInt64((t - whole) * 4_294_967_296))
        let rtpTS = UInt32(truncatingIfNeeded: UInt64(t * 90_000))
        var w = ByteWriter()
        w.u8(0x80); w.u8(200); w.u16(6)
        w.u32(senderSSRC); w.u32(ntpSec); w.u32(ntpFrac); w.u32(rtpTS); w.u32(0); w.u32(0)
        return w.data
    }

    /// build_rr: Receiver Report with up to 31 report blocks. No sources → the
    /// 1-word empty RR. Loss comes from `loss` (RTPReceptionStats.makeReport;
    /// a source without an entry reports zero, as the reference always does).
    /// Jitter is always zero.
    static func receiverReport(senderSSRC: UInt32, sources: [UInt32] = [],
                               stats: [UInt32: SourceStats] = [:],
                               srData: [UInt32: SRInfo] = [:], loss: [UInt32: LossReport] = [:],
                               now: Date = Date()) -> Data {
        var w = ByteWriter()
        guard !sources.isEmpty else {
            w.u8(0x80); w.u8(201); w.u16(1); w.u32(senderSSRC)
            return w.data
        }
        let rc = min(sources.count, 31)
        w.u8(0x80 | UInt8(rc)); w.u8(201); w.u16(UInt16(1 + rc * 6)); w.u32(senderSSRC)
        for ssrc in sources.prefix(rc) {
            let s = stats[ssrc] ?? SourceStats(maxSeq: 0, roc: 0)
            let extSeq = (s.roc & 0xFFFF) << 16 | UInt32(s.maxSeq)
            var lsr: UInt32 = 0, dlsr: UInt32 = 0
            if let sr = srData[ssrc] {
                lsr = sr.lsr
                // int() truncates toward zero, then & 0xFFFFFFFF.
                dlsr = UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince(sr.arrival) * 65536))
            }
            let l = loss[ssrc] ?? LossReport(fractionLost: 0, cumulativeLost: 0)
            let lostWord = UInt32(l.fractionLost) << 24 | UInt32(bitPattern: l.cumulativeLost) & 0x00FF_FFFF
            w.u32(ssrc); w.u32(lostWord); w.u32(extSeq); w.u32(0); w.u32(lsr); w.u32(dlsr)
        }
        return w.data
    }

    /// parse_sr_arrivals: walk a compound RTCP buffer and return every SR as
    /// (ssrc, middle 32 bits of its NTP timestamp, arrival).
    static func parseSRArrivals(_ data: Data, now: Date = Date())
        -> [(ssrc: UInt32, ntpMid32: UInt32, arrival: Date)] {
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        var out: [(ssrc: UInt32, ntpMid32: UInt32, arrival: Date)] = []
        var pos = 0
        while pos + 4 <= b.count {
            let pt = b[pos + 1]
            let pktLen = ((Int(b[pos + 2]) << 8 | Int(b[pos + 3])) + 1) * 4
            guard pos + pktLen <= b.count else { break }
            if pt == 200 && pktLen >= 28 {
                let ssrc = u32(pos + 4), ntpSec = u32(pos + 8), ntpFrac = u32(pos + 12)
                out.append((ssrc, (ntpSec & 0xFFFF) << 16 | (ntpFrac >> 16) & 0xFFFF, now))
            }
            pos += pktLen
        }
        return out
    }

    /// Packet types of every packet in a compound RTCP buffer (diagnostics:
    /// which feedback the server sends). Stops at a truncated packet.
    static func packetTypes(_ data: Data) -> [UInt8] {
        let b = [UInt8](data)
        var out: [UInt8] = []
        var pos = 0
        while pos + 4 <= b.count {
            let pktLen = ((Int(b[pos + 2]) << 8 | Int(b[pos + 3])) + 1) * 4
            guard pos + pktLen <= b.count else { break }
            out.append(b[pos + 1])
            pos += pktLen
        }
        return out
    }

    /// compound_with_rr: prefix feedback with an empty RR (some peers reject
    /// feedback that isn't a compound packet starting with SR/RR).
    static func compoundWithRR(senderSSRC: UInt32, payload: Data) -> Data {
        receiverReport(senderSSRC: senderSSRC) + payload
    }
}
