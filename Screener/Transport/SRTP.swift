// Ported from iShareScreen src/isharescreen/proxy/protocol/srtp.py (AGPL-3.0)
import Foundation

/// RFC 3711 AES-256-CM + HMAC-SHA1-80 SRTP/SRTCP.
///
/// Apple's AVCMediaStreamNegotiator hands us a 46-byte SRTP "key blob" per
/// direction: 32 bytes of master key followed by 14 bytes of master salt.
/// Key derivation labels (RFC 3711 §4.3):
///   0/1/2  →  RTP  cipher / auth / salt
///   3/4/5  →  RTCP cipher / auth / salt
enum SRTP {
    static let keyBlobLength = 46
    static let masterKeyLength = 32
    static let masterSaltLength = 14
    static let authTagLength = 10
    static let rtpHeaderMinLength = 12

    enum Error: Swift.Error, Equatable {
        case badBlobLength(Int)
        case packetTooShort(Int)
    }

    static func splitBlob(_ blob: Data) throws -> (key: Data, salt: Data) {
        guard blob.count == keyBlobLength else { throw Error.badBlobLength(blob.count) }
        let bytes = [UInt8](blob)
        return (Data(bytes[0..<masterKeyLength]), Data(bytes[masterKeyLength..<keyBlobLength]))
    }

    /// RFC 3711 §4.3.1 key derivation (AES-CM, label XORed into byte 7 of the 14-byte salt).
    static func kdf(masterKey: Data, masterSalt: Data, label: UInt8, length: Int) throws -> Data {
        var x = [UInt8](masterSalt)
        x[7] ^= label
        let iv = Data(x) + Data([0, 0])
        return try AES.ctr(key: masterKey, iv: iv, data: Data(count: length))
    }

    /// Per-packet IV = (salt << 16) XOR (SSRC << 64) XOR (index << 16), index = ROC << 16 | seq.
    static func packetIV(salt: Data, ssrc: UInt32, roc: UInt32, seq: UInt16) -> Data {
        var iv = [UInt8](salt) + [0, 0]                 // salt << 16 → bytes 0..13
        let s = withUnsafeBytes(of: ssrc.bigEndian, Array.init)
        for i in 0..<4 { iv[4 + i] ^= s[i] }            // SSRC << 64 → bytes 4..7
        let index = (UInt64(roc) << 16) | UInt64(seq)
        let ib = withUnsafeBytes(of: (index << 16).bigEndian, Array.init)
        for i in 0..<8 { iv[8 + i] ^= ib[i] }           // index << 16 → bytes 8..15
        return Data(iv)
    }

    /// SRTCP per-packet IV = (salt << 16) XOR (SSRC << 64) XOR (index << 16), where `index`
    /// is the 31-bit SRTCP packet index directly (RTCP has no ROC/seq split).
    static func rtcpIV(salt: Data, ssrc: UInt32, index: UInt32) -> Data {
        var iv = [UInt8](salt) + [0, 0]
        let s = withUnsafeBytes(of: ssrc.bigEndian, Array.init)
        for i in 0..<4 { iv[4 + i] ^= s[i] }
        let ib = withUnsafeBytes(of: index.bigEndian, Array.init)
        for i in 0..<4 { iv[10 + i] ^= ib[i] }
        return Data(iv)
    }
}

/// Per-SSRC rollover-counter state.
struct SSRCState: Equatable {
    var roc: UInt32
    var maxSeq: UInt16
}

/// RFC 3711 §3.3.2 replay list: a sliding window of `size` packet indices
/// below (and including) the highest authenticated index. Only packets that
/// passed authentication may `accept`; `isReplay` has no side effects.
struct ReplayWindow: Equatable {
    static let size: UInt64 = 128

    private(set) var top: UInt64
    /// Bit i set = index `top - i` was received (bit 0 = `top`).
    private var lo: UInt64 = 1
    private var hi: UInt64 = 0

    init(first index: UInt64) { top = index }

    /// True for an index already received, or too old to tell (≥ `size`
    /// behind the highest one): RFC 3711 discards both.
    func isReplay(_ index: UInt64) -> Bool {
        guard index <= top else { return false }
        let d = top - index
        guard d < Self.size else { return true }
        return d < 64 ? lo >> d & 1 == 1 : hi >> (d - 64) & 1 == 1
    }

    mutating func accept(_ index: UInt64) {
        if index > top {
            let shift = index - top
            if shift >= 128 {
                lo = 0; hi = 0
            } else if shift >= 64 {
                hi = lo << (shift - 64); lo = 0
            } else {
                hi = hi << shift | lo >> (64 - shift)
                lo <<= shift
            }
            lo |= 1
            top = index
        } else {
            let d = top - index
            guard d < Self.size else { return }
            if d < 64 { lo |= 1 << d } else { hi |= 1 << (d - 64) }
        }
    }
}

/// SRTP receiver: AES-256-CTR + HMAC-SHA1-80 with per-SSRC ROC (rollover counter) tracking.
///
/// Apple's HP stream uses several SSRCs per quality tier (one per tile) whose sequence
/// spaces are independent, so ROC must be maintained per-SSRC rather than globally.
///
/// Not thread-safe: this class has mutable per-instance state (`states`, `counts`) and is
/// meant to be owned and driven by a single task (e.g. the media receive loop). Callers
/// must not call `decrypt` concurrently from multiple tasks on the same instance.
final class SRTPDecryptor {
    private let cipherKey: Data
    private let authKey: Data
    private let salt: Data
    private var states: [UInt32: SSRCState] = [:]
    private var counts: [UInt32: Int] = [:]
    /// RFC 3711 replay protection, per SSRC, over the 48-bit index ROC‖SEQ.
    private var replay: [UInt32: ReplayWindow] = [:]
    /// Authenticated packets discarded as replays (or too old to tell).
    private(set) var replaysDropped = 0

    init(blob: Data) throws {
        let (key, masterSalt) = try SRTP.splitBlob(blob)
        cipherKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 0, length: 32)
        authKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 1, length: 20)
        salt = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 2, length: 14)
    }

    /// Exposed for tests: the raw derived cipher/auth/salt (RFC 3711 §4.3 labels 0/1/2).
    var derivedKeys: (cipherKey: Data, authKey: Data, salt: Data) { (cipherKey, authKey, salt) }

    var ssrcCounts: [UInt32: Int] { counts }

    /// Drop count + cipher state for every SSRC not in `keep`.
    ///
    /// Used after adopting a fresh SSRC group: any losing group still on the wire would
    /// otherwise keep accumulating counts and trigger another adoption the moment the
    /// cool-down expires. Resetting forces a clean restart for any later-arriving stream.
    func forgetSSRCs(except keep: Set<UInt32>) {
        // The replay window goes with the ROC state: a forgotten SSRC starts
        // over at ROC 0 like a brand-new one (the reference behaviour).
        for ssrc in Set(counts.keys).union(states.keys) where !keep.contains(ssrc) {
            counts.removeValue(forKey: ssrc)
            states.removeValue(forKey: ssrc)
            replay.removeValue(forKey: ssrc)
        }
    }

    /// Returns one of the consecutive-SSRC groups Apple emits per tier (one SSRC per tile;
    /// `groupSize` = the tilesPerFrame we offered, default 4). Tier 0 = the highest-quality
    /// (most-packets) group.
    func getPrimarySSRCGroup(tier: Int = 0, groupSize: Int = 4) -> Set<UInt32> {
        guard !counts.isEmpty else { return [] }
        let grp = max(1, groupSize)
        let sorted = counts.keys.sorted()
        var groups: [[UInt32]] = [[sorted[0]]]
        for s in sorted.dropFirst() {
            if s - groups[groups.count - 1].last! <= 1 && groups[groups.count - 1].count < grp {
                groups[groups.count - 1].append(s)
            } else {
                groups.append([s])
            }
        }
        // Python's `sort(key=-sum)` is stable over groups built in ascending-SSRC order, so
        // equal sums keep ascending first-SSRC order. Swift's sort is not guaranteed stable:
        // make the tie-break explicit.
        groups.sort { lhs, rhs in
            let lsum = lhs.reduce(0) { $0 + (counts[$1] ?? 0) }
            let rsum = rhs.reduce(0) { $0 + (counts[$1] ?? 0) }
            if lsum != rsum { return lsum > rsum }
            return lhs[0] < rhs[0]
        }
        let idx = min(tier, groups.count - 1)
        return Set(groups[idx])
    }

    /// Per-SSRC stats for receiver reports.
    func stateSnapshot() -> [UInt32: SSRCState] { states }

    /// Decrypts one SRTP packet. Returns `(header, payload, ssrc, seq)`, or `nil` if the
    /// auth tag fails for every ROC candidate, or if the authenticated index was already
    /// received / is more than 128 behind the newest (RFC 3711 §3.3.2 replay window).
    /// On failure, ROC/count/replay state is unchanged.
    func decrypt(_ pkt: Data) -> (header: Data, payload: Data, ssrc: UInt32, seq: UInt16)? {
        guard pkt.count >= SRTP.rtpHeaderMinLength + SRTP.authTagLength else { return nil }
        let bytes = [UInt8](pkt)
        let bodyLen = bytes.count - SRTP.authTagLength
        let seq = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let ssrc = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])

        let state = states[ssrc]
        let rocGuess: UInt32
        if let state {
            let diff = Int(seq) - Int(state.maxSeq)
            if diff > 0x7FFF {
                rocGuess = state.roc > 0 ? state.roc - 1 : 0
            } else if diff < -0x7FFF {
                rocGuess = state.roc &+ 1
            } else {
                rocGuess = state.roc
            }
        } else {
            rocGuess = 0
        }

        // Try guess, current, guess+1, guess-1. Dedupe while preserving order.
        var candidates: [UInt32] = []
        var seen: Set<UInt32> = []
        let fallback = state?.roc ?? 0
        for r in [rocGuess, fallback, rocGuess &+ 1, rocGuess > 0 ? rocGuess - 1 : 0] {
            if seen.insert(r).inserted { candidates.append(r) }
        }

        for roc in candidates {
            if let result = tryDecrypt(bytes: bytes, bodyLen: bodyLen, seq: seq, ssrc: ssrc, roc: roc) {
                // The tag covers ROC‖SEQ, so the index is authenticated: a
                // replayed packet only verifies under its original ROC.
                let index = UInt64(roc) << 16 | UInt64(seq)
                if let w = replay[ssrc], w.isReplay(index) {
                    replaysDropped += 1
                    return nil
                }
                if replay[ssrc] == nil { replay[ssrc] = ReplayWindow(first: index) } else { replay[ssrc]!.accept(index) }
                updateState(ssrc: ssrc, roc: roc, seq: seq)
                counts[ssrc, default: 0] += 1
                return (result.header, result.payload, ssrc, seq)
            }
        }
        return nil
    }

    private func tryDecrypt(
        bytes: [UInt8], bodyLen: Int, seq: UInt16, ssrc: UInt32, roc: UInt32
    ) -> (header: Data, payload: Data)? {
        let rocBE = withUnsafeBytes(of: roc.bigEndian, Array.init)
        let body = Data(bytes[0..<bodyLen])
        let mac = HMAC1.sha1(key: authKey, data: body + Data(rocBE))
        let tag = Data(bytes[bodyLen..<(bodyLen + SRTP.authTagLength)])
        guard ConstantTime.equal(mac.prefix(SRTP.authTagLength), tag) else { return nil }

        let firstByte = bytes[0]
        let cc = Int(firstByte & 0x0F)
        var hdrLen = SRTP.rtpHeaderMinLength + cc * 4
        if (firstByte >> 4) & 1 == 1 {
            guard hdrLen + 4 <= bodyLen else { return nil }
            let extLen = Int(bytes[hdrLen + 2]) << 8 | Int(bytes[hdrLen + 3])
            hdrLen += 4 + extLen * 4
        }
        guard hdrLen <= bodyLen else { return nil }

        let header = Data(bytes[0..<hdrLen])
        if hdrLen == bodyLen { return (header, Data()) }

        let iv = SRTP.packetIV(salt: salt, ssrc: ssrc, roc: roc, seq: seq)
        let ciphertext = Data(bytes[hdrLen..<bodyLen])
        guard let plaintext = try? AES.ctr(key: cipherKey, iv: iv, data: ciphertext) else { return nil }
        return (header, plaintext)
    }

    private func updateState(ssrc: UInt32, roc: UInt32, seq: UInt16) {
        guard let cur = states[ssrc] else {
            states[ssrc] = SSRCState(roc: roc, maxSeq: seq)
            return
        }
        let newFull = (UInt64(roc) << 16) | UInt64(seq)
        let curFull = (UInt64(cur.roc) << 16) | UInt64(cur.maxSeq)
        if newFull > curFull {
            states[ssrc] = SSRCState(roc: roc, maxSeq: seq)
        }
    }
}

/// SRTP sender. Used only for the PT=101 keepalive Apple expects from us.
///
/// Not thread-safe: `seq`/`roc`/`ts` are mutated by every `encrypt` call. Meant to be owned
/// and driven by a single task.
final class SRTPEncryptor {
    private let cipherKey: Data
    private let authKey: Data
    private let salt: Data
    let ssrc: UInt32
    private var seq: UInt16
    private var roc: UInt32
    private var ts: UInt32

    /// `seq`/`roc`/`ts` default to 0 but can be primed for tests or for resuming a session.
    init(blob: Data, ssrc: UInt32, seq: UInt16 = 0, roc: UInt32 = 0, ts: UInt32 = 0) throws {
        let (key, masterSalt) = try SRTP.splitBlob(blob)
        cipherKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 0, length: 32)
        authKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 1, length: 20)
        salt = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 2, length: 14)
        self.ssrc = ssrc
        self.seq = seq
        self.roc = roc
        self.ts = ts
    }

    func encrypt(_ payload: Data, pt: UInt8 = 101, marker: Bool = false) throws -> Data {
        let curSeq = seq
        let curRoc = roc
        let curTs = ts
        if curSeq == 0xFFFF {
            seq = 0
            roc &+= 1
        } else {
            seq = curSeq + 1
        }
        ts &+= 480

        var header = Data()
        header.append(0x80)
        header.append((pt & 0x7F) | (marker ? 0x80 : 0))
        header.append(UInt8(curSeq >> 8))
        header.append(UInt8(curSeq & 0xFF))
        header.append(contentsOf: withUnsafeBytes(of: curTs.bigEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))

        let iv = SRTP.packetIV(salt: salt, ssrc: ssrc, roc: curRoc, seq: curSeq)
        let ciphertext = try AES.ctr(key: cipherKey, iv: iv, data: payload)
        let body = header + ciphertext
        let rocBE = withUnsafeBytes(of: curRoc.bigEndian, Array.init)
        let mac = HMAC1.sha1(key: authKey, data: body + Data(rocBE))
        return body + mac.prefix(SRTP.authTagLength)
    }
}

/// SRTCP receiver. RTCP shares the same master key/salt as RTP but uses derivation labels 3/4/5.
///
/// Replay protection (RFC 3711 §3.3.2) per sender SSRC over the 31-bit SRTCP index:
/// an authenticated packet whose index was already seen, or is ≥ 128 behind the
/// newest, is discarded without changing any state. Not thread-safe (one owner task).
final class SRTCPDecryptor {
    private let cipherKey: Data
    private let authKey: Data
    private let salt: Data
    private var replay: [UInt32: ReplayWindow] = [:]
    private(set) var replaysDropped = 0

    init(blob: Data) throws {
        let (key, masterSalt) = try SRTP.splitBlob(blob)
        cipherKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 3, length: 32)
        authKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 4, length: 20)
        salt = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 5, length: 14)
    }

    func unprotect(_ pkt: Data) -> Data? {
        guard pkt.count >= 8 + 4 + SRTP.authTagLength else { return nil }
        let bytes = [UInt8](pkt)
        let bodyLen = bytes.count - SRTP.authTagLength
        let body = Data(bytes[0..<bodyLen])
        let tag = Data(bytes[bodyLen..<bytes.count])
        let expected = HMAC1.sha1(key: authKey, data: body)
        guard ConstantTime.equal(expected.prefix(SRTP.authTagLength), tag) else { return nil }

        let eIndexOffset = bodyLen - 4
        let eIndex = UInt32(bytes[eIndexOffset]) << 24 | UInt32(bytes[eIndexOffset + 1]) << 16
            | UInt32(bytes[eIndexOffset + 2]) << 8 | UInt32(bytes[eIndexOffset + 3])
        let encrypted = (eIndex & 0x8000_0000) != 0
        let index = eIndex & 0x7FFF_FFFF
        let ssrc = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        if let w = replay[ssrc], w.isReplay(UInt64(index)) {
            replaysDropped += 1
            return nil
        }
        let header = Data(bytes[0..<8])
        let payload = Data(bytes[8..<eIndexOffset])
        guard encrypted else {
            accept(ssrc: ssrc, index: index)
            return header + payload
        }

        let iv = SRTP.rtcpIV(salt: salt, ssrc: ssrc, index: index)
        guard let plaintext = try? AES.ctr(key: cipherKey, iv: iv, data: payload) else { return nil }
        accept(ssrc: ssrc, index: index)
        return header + plaintext
    }

    private func accept(ssrc: UInt32, index: UInt32) {
        if replay[ssrc] == nil { replay[ssrc] = ReplayWindow(first: UInt64(index)) } else { replay[ssrc]!.accept(UInt64(index)) }
    }
}

/// SRTCP sender. Wraps RR / FIR / PLI / NACK packets.
///
/// Not thread-safe: `index` is mutated by every `protect` call. Meant to be owned and
/// driven by a single task.
final class SRTCPEncryptor {
    private let cipherKey: Data
    private let authKey: Data
    private let salt: Data
    private var index: UInt32 = 0

    init(blob: Data) throws {
        let (key, masterSalt) = try SRTP.splitBlob(blob)
        cipherKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 3, length: 32)
        authKey = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 4, length: 20)
        salt = try SRTP.kdf(masterKey: key, masterSalt: masterSalt, label: 5, length: 14)
    }

    /// Throws `SRTP.Error.packetTooShort` for anything shorter than the 8-byte
    /// RTCP header + sender SSRC (the reference would raise on the slice too).
    func protect(_ pkt: Data) throws -> Data {
        guard pkt.count >= 8 else { throw SRTP.Error.packetTooShort(pkt.count) }
        let bytes = [UInt8](pkt)
        let curIndex = index
        index &+= 1

        let header = Data(bytes[0..<8])
        let plaintext = Data(bytes[8...])
        let ssrc = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])

        let iv = SRTP.rtcpIV(salt: salt, ssrc: ssrc, index: curIndex)
        let ciphertext = try AES.ctr(key: cipherKey, iv: iv, data: plaintext)
        let eIndex = 0x8000_0000 | curIndex
        var body = header + ciphertext
        body.append(contentsOf: withUnsafeBytes(of: eIndex.bigEndian, Array.init))
        let mac = HMAC1.sha1(key: authKey, data: body)
        return body + mac.prefix(SRTP.authTagLength)
    }
}
