// Ported from iShareScreen src/isharescreen/proxy/media/nalu.py (AGPL-3.0):
// reassemble_group, first_donl, NAL type constants.
//
// Apple's HEVC RTP payload format (RFC 7798 variant, apple_vnc_rfc.md §10.6):
//   * Single NAL unit: [NAL hdr 2][DONL 2][NAL payload]. The DONL is stripped
//     before the NAL goes to a decoder.
//   * Aggregation Packet (type 48): [AP hdr 2][DONL 2] then repeated
//     [u16 size][NAL]. ONE DONL for the whole packet and NO DOND between the
//     aggregated units, so every unit carries the same DON.
//   * Fragmentation Unit (type 49): [FU NAL hdr 2][FU hdr 1][DONL 2][fragment].
//     The DONL rides in EVERY fragment, not just the start one. On the start
//     fragment the original NAL header is rebuilt from the FU NAL header (F
//     bit and layer-id MSB) with the FU header's type, plus the FU NAL
//     header's second byte (layer-id LSBs + TID).
//
// Malformed units are dropped the way the reference drops them: an AP stops
// at the first zero-size or overrunning entry and keeps what came before it.
import Foundation

/// HEVC NAL unit type helpers (ITU-T H.265 Table 7-1, RFC 7798 §4.4).
enum HEVCNAL {
    static let vps: UInt8 = 32
    static let sps: UInt8 = 33
    static let pps: UInt8 = 34
    static let aggregation: UInt8 = 48
    static let fragmentation: UInt8 = 49
    /// IRAP pictures, BLA_W_LP (16) through CRA_NUT (21): nalu.IDR_RANGE.
    static let irap: ClosedRange<UInt8> = 16...21

    /// nal_unit_type from the first header byte.
    @inline(__always) static func type(_ firstByte: UInt8) -> UInt8 { (firstByte >> 1) & 0x3F }
    static func type(of nal: Data) -> UInt8? { nal.first.map(type) }
}

enum HEVCDepacketizer {
    enum Error: Swift.Error, Equatable {
        /// Too short for its packet type (reference: silently skipped).
        case truncated
        /// A single FU fragment that is not both start and end: it needs
        /// `FUReassembler` (or `reassembleGroup`) to become a NAL unit.
        case fragmentNeedsReassembly
    }

    /// One fragment of a type-49 Fragmentation Unit.
    struct Fragment: Equatable {
        var isStart: Bool
        var isEnd: Bool
        /// The original NAL unit type carried in the FU header.
        var nalType: UInt8
        /// The rebuilt 2-byte header of the original NAL unit.
        var nalHeader: (UInt8, UInt8)
        var don: UInt16
        /// Fragment bytes after the DONL.
        var body: Data

        static func == (a: Fragment, b: Fragment) -> Bool {
            a.isStart == b.isStart && a.isEnd == b.isEnd && a.nalType == b.nalType
                && a.nalHeader == b.nalHeader && a.don == b.don && a.body == b.body
        }
    }

    /// One RTP payload, classified.
    enum Unit: Equatable {
        /// Single NAL or Aggregation Packet: complete NAL units, all with `don`.
        case nals([Data], don: UInt16)
        case fragment(Fragment)
    }

    /// Classifies and unpacks one decrypted RTP payload.
    static func parse(_ payload: Data) throws -> Unit {
        let p = payload.startIndex
        guard payload.count >= 2 else { throw Error.truncated }
        let type = HEVCNAL.type(payload[p])
        switch type {
        case HEVCNAL.aggregation:
            // header(2) + DONL(2) + [size(2) + data]...
            guard payload.count >= 4 else { throw Error.truncated }
            let don = u16(payload, p + 2)
            var out: [Data] = []
            var pos = p + 4
            let end = payload.endIndex
            while pos + 2 <= end {
                let size = Int(u16(payload, pos))
                pos += 2
                if size == 0 || pos + size > end { break }
                out.append(Data(payload[pos..<(pos + size)]))
                pos += size
            }
            return .nals(out, don: don)

        case HEVCNAL.fragmentation:
            // header(2) + FU header(1) + DONL(2) + fragment
            guard payload.count >= 6 else { throw Error.truncated }
            let fu = payload[p + 2]
            let inner = fu & 0x3F
            return .fragment(Fragment(isStart: fu & 0x80 != 0, isEnd: fu & 0x40 != 0, nalType: inner,
                                      nalHeader: ((payload[p] & 0x81) | (inner << 1), payload[p + 1]),
                                      don: u16(payload, p + 3), body: Data(payload[(p + 5)...])))

        default:
            // Single NAL with a 2-byte DONL after the NAL header.
            guard payload.count >= 4 else { throw Error.truncated }
            var nal = Data(capacity: payload.count - 2)
            nal.append(payload[p]); nal.append(payload[p + 1])
            nal.append(payload[(p + 4)...])
            return .nals([nal], don: u16(payload, p + 2))
        }
    }

    /// NAL units (DONL stripped) and their DON from one payload. A complete
    /// single-packet FU (start and end set) yields its NAL; any other FU
    /// fragment throws `.fragmentNeedsReassembly`.
    static func nalUnits(from payload: Data) throws -> [(nal: Data, don: UInt16)] {
        switch try parse(payload) {
        case .nals(let nals, let don):
            return nals.map { ($0, don) }
        case .fragment(let f):
            guard f.isStart, f.isEnd else { throw Error.fragmentNeedsReassembly }
            return [(f.rebuiltStart(), f.don)]
        }
    }

    /// nalu.reassemble_group: the NAL units of one RTP timestamp group whose
    /// payloads are already in sequence order. Like the reference it drops
    /// malformed entries and FU continuations with no start; it cannot see
    /// sequence gaps, so callers check contiguity first (see HEVCAssembler).
    static func reassembleGroup<S: Sequence>(_ payloads: S) -> [Data] where S.Element == Data {
        var out: [Data] = []
        var fu: Data?
        for payload in payloads {
            switch try? parse(payload) {
            case .nals(let nals, _)?:
                out += nals
            case .fragment(let f)?:
                if f.isStart {
                    fu = f.rebuiltStart()
                    // The reference only closes a buffer on a non-start end
                    // fragment, so a start+end fragment stays open too.
                } else if fu != nil {
                    fu!.append(f.body)
                    if f.isEnd { out.append(fu!); fu = nil }
                }
            case nil:
                continue
            }
        }
        return out
    }

    /// nalu.first_donl: the DONL of the first payload that carries one
    /// (offset 2 for single/AP, offset 3 for FU).
    static func firstDONL<S: Sequence>(_ payloads: S) -> UInt16? where S.Element == Data {
        for payload in payloads where payload.count >= 2 {
            let p = payload.startIndex
            if HEVCNAL.type(payload[p]) == HEVCNAL.fragmentation {
                if payload.count >= 5 { return u16(payload, p + 3) }
            } else if payload.count >= 4 {
                return u16(payload, p + 2)
            }
        }
        return nil
    }

    @inline(__always) static func u16(_ d: Data, _ i: Data.Index) -> UInt16 {
        UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }
}

extension HEVCDepacketizer.Fragment {
    /// Rebuilt NAL header followed by this fragment's body.
    func rebuiltStart() -> Data {
        var nal = Data(capacity: body.count + 2)
        nal.append(nalHeader.0); nal.append(nalHeader.1)
        nal.append(body)
        return nal
    }
}

/// Stateful FU reassembly for one SSRC, driven packet by packet with RTP
/// sequence numbers so a missing fragment is detected (the reference relies
/// on its group-level gap check instead; HEVCAssembler does both).
struct FUReassembler {
    enum Output: Equatable {
        /// Fragment consumed, NAL not finished yet.
        case pending
        case nal(Data, don: UInt16)
        /// A fragment went missing: the partial NAL (if any) was dropped.
        case lost(don: UInt16)
    }

    private var buffer: Data?
    private var don: UInt16 = 0
    private var lastSeq: UInt16 = 0

    var isActive: Bool { buffer != nil }

    mutating func reset() { buffer = nil }

    mutating func push(_ f: HEVCDepacketizer.Fragment, seq: UInt16) -> Output {
        if f.isStart {
            let abandoned = buffer != nil
            buffer = f.rebuiltStart()
            don = f.don
            lastSeq = seq
            if f.isEnd { return finish() }
            // A new start while one was open: the old NAL lost its end.
            return abandoned ? .lost(don: f.don) : .pending
        }
        guard buffer != nil else { return .lost(don: f.don) }      // start missing
        guard seq == lastSeq &+ 1 else {                             // middle missing
            buffer = nil
            return .lost(don: f.don)
        }
        buffer!.append(f.body)
        lastSeq = seq
        return f.isEnd ? finish() : .pending
    }

    private mutating func finish() -> Output {
        let nal = buffer!
        buffer = nil
        return .nal(nal, don: don)
    }
}
