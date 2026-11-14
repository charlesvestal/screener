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

enum RecordLayerError: Error {
    case badRekey
    case integrity
    case badFrame
}

/// Bidirectional enc1103 cipher state, built from the 36-byte 1103 blob.
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
    /// were sealed (wire order == counter order).
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
        let plaintext = try dec.update(Data(ciphertext))
        let ctrStart = recvSeq
        recvSeq &+= 1

        // Reference: a block no longer than the mac has no room for a mac at
        // all, so it's returned verbatim (unreachable in practice, since the
        // sender's padding scheme never emits a frame this short).
        guard ciphertext.count > Self.macLen else { return plaintext }

        let body = plaintext.prefix(plaintext.count - Self.macLen)
        let mac = plaintext.suffix(Self.macLen)
        let lo = ctrStart == 0 ? 0 : ctrStart - 1
        for c in lo..<(ctrStart + Self.decryptWindow) {
            var s = ByteWriter()
            s.u32(c)
            if Hash.sha1(s.data + body) == mac {
                recvSeq = c &+ 1
                var r = ByteReader(body)
                let len = Int(try r.u16())
                return try r.bytes(len)
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
        while buffer.count >= 2 {
            let len = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
            guard len > 0, len % 16 == 0 else { throw RecordLayerError.badFrame }
            guard buffer.count >= 2 + len else { break }
            out.append(buffer.subdata(in: buffer.startIndex + 2 ..< buffer.startIndex + 2 + len))
            buffer.removeFirst(2 + len)
        }
        return out
    }
}
