// Ported from iShareScreen src/isharescreen/proxy/protocol/enc1103.py (AGPL-3.0)
//
// Apple's bespoke RFB control-channel stream cipher. After auth, the server
// sends a `1103` encoding entry containing a 36-byte blob, ECB-wrapped under
// the auth-derived key, that unwraps to a 16-byte AES key + 16-byte CBC IV.
// From then on every control message in either direction is AES-128-CBC
// framed with a counter-keyed plain-SHA-1 tag (NOT HMAC):
// `SHA1(u32_be(counter) || plaintext-before-tag)`.
//
// Wire format on the encrypted channel:
//   u16 BE  ciphertext_length
//   bytes   ciphertext      (multiple of 16)
//
// Plaintext payload inside the cipher block:
//   u16 BE  msg_length
//   bytes   msg
//   bytes   pad             (zero pad to 16-byte alignment after the mac)
//   bytes   mac             (20-byte plain SHA-1 tag)
import Foundation

enum RecordLayerError: Error, Equatable {
    case badRekey
    case integrity
    case badFrame
}

/// Bidirectional enc1103 cipher state, built from the 36-byte 1103 blob.
///
/// Threading contract: `seal` and the corresponding socket write MUST happen
/// as a single serialized step (one actor/writer owning both), because wire
/// order must equal counter order — the reference holds its send lock across
/// the socket write in `encrypt_and_send`. If two callers race to `seal`
/// concurrently and then write independently, the wire order can diverge
/// from the sequence order the receiver expects, breaking the MAC window.
final class RecordLayer: @unchecked Sendable {
    /// The unwrapped CBC key, public because the alt-session path's input
    /// wrapper needs to AES-128-ECB-encrypt blocks under this same key.
    let contentKey: Data
    private let enc: AESCBCStream
    private let dec: AESCBCStream
    private var sendSeq: UInt32 = 0
    private var recvSeq: UInt32 = 0
    private let lock = NSLock()

    private static let macLen = 20
    private static let block = 16
    /// Matches the reference's `_DECRYPT_COUNTER_WINDOW`: forgive up to a
    /// 6-message gap/reordering from the server before failing integrity.
    private static let decryptWindow: UInt32 = 6

    init(rekeyBody: Data, wrapKey: Data) throws {
        guard rekeyBody.count == 36, wrapKey.count == 16 else { throw RecordLayerError.badRekey }
        let b = Data(rekeyBody)
        contentKey = try AES.ecbDecrypt(key: wrapKey, block: b.subdata(in: 4..<20))
        let iv = try AES.ecbDecrypt(key: wrapKey, block: b.subdata(in: 20..<36))
        enc = try AESCBCStream(key: contentKey, iv: iv, operation: .encrypt)
        dec = try AESCBCStream(key: contentKey, iv: iv, operation: .decrypt)
    }

    /// Encrypts one control-channel message. Returns the full wire form
    /// `u16 len || ciphertext`. Callers MUST write records in the order they
    /// were sealed (wire order == counter order) — see the class doc comment:
    /// `seal` and the socket write must be one serialized step.
    func seal(_ body: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var w = ByteWriter(capacity: body.count + 40)
        w.u16(UInt16(body.count))
        w.bytes(body)
        let pad = (Self.block - (2 + body.count + Self.macLen) % Self.block) % Self.block
        w.zeros(pad)
        var seqW = ByteWriter()
        seqW.u32(sendSeq)
        let mac = Hash.sha1(seqW.data + w.data)
        let ciphertext = try enc.update(w.data + mac)
        sendSeq &+= 1
        var out = ByteWriter(capacity: ciphertext.count + 2)
        out.u16(UInt16(ciphertext.count))
        out.bytes(ciphertext)
        return out.data
    }

    /// Decrypts one record's ciphertext (without the leading u16 length
    /// prefix) and returns its inner body. The AES-CBC decrypt always runs
    /// (and the receive counter always advances) regardless of MAC outcome,
    /// since CBC chaining state must stay in sync with the sender.
    func open(ciphertext: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }

        // AES-CBC only accepts whole blocks; a ciphertext that isn't a non-zero
        // multiple of the 16-byte block size can't be decrypted at all, and
        // `FrameSplitter` (the only normal producer of ciphertext fed here) never
        // emits one. Reject it before touching `dec`, so a malformed/adversarial
        // frame can't desync the CBC chaining state that legitimate records depend
        // on for every subsequent `open` call.
        guard ciphertext.count > 0, ciphertext.count % 16 == 0 else {
            throw RecordLayerError.badFrame
        }

        let plaintext = try dec.update(Data(ciphertext))
        let ctrStart = recvSeq
        recvSeq &+= 1

        // Minimum legit record: 2-byte length + 0-byte body + 20-byte mac,
        // padded up to a 32-byte multiple of the 16-byte block size. Anything
        // shorter cannot possibly contain a real mac, so treating it as
        // "trusted plaintext, no mac to check" (as the reference does for
        // unreachable short blocks) would be a integrity bypass; reject it.
        guard ciphertext.count >= 32 else { throw RecordLayerError.badFrame }

        let body = plaintext.prefix(plaintext.count - Self.macLen)
        let mac = plaintext.suffix(Self.macLen)
        // Iterate in Int space to avoid overflow when ctrStart is near
        // UInt32.max, then convert back with truncation (matching the
        // reference's modular u32 counter semantics).
        let loInt = ctrStart == 0 ? 0 : Int(ctrStart) - 1
        let hiInt = Int(ctrStart) + Int(Self.decryptWindow)
        for cInt in loInt..<hiInt {
            let c = UInt32(truncatingIfNeeded: cInt)
            var s = ByteWriter()
            s.u32(c)
            if ConstantTime.equal(Hash.sha1(s.data + body), mac) {
                recvSeq = c &+ 1
                do {
                    var r = ByteReader(body)
                    let len = Int(try r.u16())
                    return try r.bytes(len)
                } catch {
                    throw RecordLayerError.badFrame
                }
            }
        }
        throw RecordLayerError.integrity
    }
}

/// Splits a TCP byte stream into complete `u16 len || ciphertext` record
/// frames, buffering incomplete tails across calls.
struct FrameSplitter {
    private var buffer = Data()

    mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        // Track a read position within this push and remove the whole
        // consumed prefix once at the end, rather than repeatedly calling
        // removeFirst() (which would re-copy/re-release the backing storage
        // on every frame). Behavior is identical to the previous
        // per-frame-removal version.
        var pos = buffer.startIndex
        defer {
            if pos > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<pos)
            }
        }
        while buffer.count - (pos - buffer.startIndex) >= 2 {
            let len = Int(buffer[pos]) << 8 | Int(buffer[pos + 1])
            guard len > 0, len % 16 == 0 else { throw RecordLayerError.badFrame }
            guard buffer.distance(from: pos, to: buffer.endIndex) >= 2 + len else { break }
            out.append(buffer.subdata(in: pos + 2 ..< pos + 2 + len))
            pos += 2 + len
        }
        return out
    }
}
