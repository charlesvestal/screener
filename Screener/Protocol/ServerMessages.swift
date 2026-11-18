// Ported from iShareScreen src/isharescreen/proxy/session.py (_tcp_rx_loop,
// _handle_tcp_msg, _handle_fbu, _handle_cursor_rect),
// proxy/protocol/negotiation.py (_read_until_enc1103),
// proxy/protocol/rfb.py (parse_apple_display_layout) and
// proxy/protocol/clipboard.py (ClipboardReassembler) (AGPL-3.0)
//
// Server→client control-channel parsing.
//
// FRAMING (mirrors the reference, with narrow spanning per RFC §6.4.6):
// The reference treats each decrypted record body as one self-contained
// message and walks it; a message that runs past the end of its record is
// dropped, except for 0x1f ClipboardSend whose continuation records are
// concatenated. RFC §6.4.6 says large server payloads MAY span consecutive
// records, so spanning is allowed — but ONLY where the length is already
// known and bounded:
//   - the 0x1f ClipboardSend payload (after its 16-byte header),
//   - a 0x450 cursor STORE once its comp_len is buffered,
//   - a 0x06 zlib rect once its u32 length is buffered.
// Anything else left incomplete at the end of a record (e.g. an FBU that
// claims more rects than its record holds) is dropped when the next record
// arrives, and that record is parsed as a fresh message. Once a message is
// complete, anything left in that record is discarded (one record never
// carries two messages; the reference ignores such trailing bytes too).
// Corrupt cursor/zlib lengths (beyond a w*h-derived bound) are reported as
// `.unknown` and abort the record instead of waiting for megabytes.
//
// Rectangle payload lengths (FramebufferUpdate, type 0):
//   0x44f rekey ........ fixed 36 bytes            (negotiation._read_until_enc1103)
//   0x450 cursor ....... u32 cache_id, u32 comp_len, comp_len bytes (session._handle_cursor_rect)
//   0x451 layout ....... u16 prefix + payload      (session._handle_fbu 0x451 branch)
//   0x3f2/0x3f3/0x3ea/0x453/0x455/0x456
//                        u16 prefix + payload      (session._handle_fbu shared skip branch;
//                        for 0x453 this equals RFC §8.5's fixed 22 bytes)
//   0x06 zlib .......... u32 length + payload      (RFC 6143 zlib / RFC §8.9.3; the
//                        reference aborts the walk on 0x06 — see below)
//   16 ZRLE ............ u32 length + payload      (RFC 6143 §7.7.6; skipped, `.unknown`)
//   -223 DesktopSize ... no payload                (RFC 6143 §7.8.2; skipped silently)
//   anything else ...... length unknowable: emit `.unknown(type: 0, encoding:)`
//                        and discard the rest of the record, exactly like the
//                        reference's walk abort ("rects after this are dropped").
import Foundation

struct PixelPoint: Equatable, Sendable { var x: Int; var y: Int }
struct PixelSize: Equatable, Sendable { var width: Int; var height: Int }

/// One physical display's rect within the combined backing canvas, in
/// backing pixels (rfb.DisplayRect).
struct DisplayRect: Equatable, Sendable {
    var displayID: UInt32
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// AppleDisplayLayout (0x451). `scaled*` = logical, `backing*` = pixel
/// geometry the encoder renders at (RFC §8.4). An empty or short payload
/// yields `displays == []`, which consumers must treat as "no change to the
/// per-display geometry" (the reference keeps its previous layout then).
struct DisplayLayout: Equatable, Sendable {
    var scaledWidth: Int
    var scaledHeight: Int
    var backingWidth: Int
    var backingHeight: Int
    var displays: [DisplayRect]

    /// rfb.parse_apple_display_layout, plus the scaled size session.py reads
    /// from the same header. `payload` excludes the u16 length prefix. Never
    /// fails: the reference re-arms on every 0x451 even when it can't parse
    /// it, so a short payload yields zeros / no displays.
    init(payload p: Data) {
        let b = [UInt8](p)
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        func u32(_ o: Int) -> UInt32 { o + 4 <= b.count ? UInt32(u16(o)) << 16 | UInt32(u16(o + 2)) : 0 }
        scaledWidth = u16(2); scaledHeight = u16(4)
        backingWidth = u16(6); backingHeight = u16(8)
        var rects: [DisplayRect] = []
        if b.count >= 20 {
            let count = u16(18)
            var off = 20
            for _ in 0..<count {
                guard off + 56 <= b.count else { break }
                let id = u32(off + 16)
                let py0 = u16(off + 28), px0 = u16(off + 30), py1 = u16(off + 32), px1 = u16(off + 34)
                if px1 > px0 && py1 > py0 {
                    rects.append(DisplayRect(displayID: id, x: px0, y: py0, width: px1 - px0, height: py1 - py0))
                }
                off += 56
            }
        }
        displays = rects
    }
}

/// 16-byte 0x1f ClipboardSend header (clipboard.parse_clipboard_send_header).
struct ClipboardSendHeader: Equatable, Sendable {
    var promise: UInt8
    var reserved: UInt32
    var uncompressedSize: UInt32
    var compressedSize: UInt32
}

enum ServerEvent: Equatable, Sendable {
    /// 0x44f: 36-byte rekey body for `RecordLayer(rekeyBody:wrapKey:)`.
    case rekey(Data)
    /// 0x451. Receiver must re-arm (0x09 + non-incremental 0x03) on every one.
    case displayLayout(DisplayLayout)
    /// 0x450 STORE: the inflated `w*h*4` BGRA pixmap + `w*h` alpha plane,
    /// already converted to premultiplied RGBA (`CursorImage.premultipliedRGBA`)
    /// here, off the main actor. `w, h ≤ CursorImage.maxDimension`.
    case cursorStore(id: UInt32, hotspot: PixelPoint, size: PixelSize, rgba: Data)
    /// 0x450 SELECT: re-apply a previously stored cursor.
    case cursorSelect(id: UInt32)
    /// 0x455.
    case keyboardSource(String, secureInput: Bool)
    /// 0x456 (device identifier = sysctl hw.model).
    case deviceInfo(model: String)
    /// 0x453.
    case vendorKeysyms([UInt32])
    /// The 0x1c answer candidate. Either a top-level 0x1c record (whole body,
    /// emitted unconditionally) or — as the reference observes in practice —
    /// FBU bytes containing an embedded "bplist00": the payload of a
    /// 0x3f2/0x3f3/0x3ea rect, or the rest of the record after an unknown
    /// encoding aborts the walk (the reference searches the whole FBU for a
    /// bplist regardless of encoding). FBU rects WITHOUT "bplist00" (e.g. the
    /// stage-1 0x3f2 in the prelude) are not reported. This is only a
    /// candidate: consumers (`MediaStreamOptions.parseAnswer`) still locate
    /// and validate the plist and ignore it if it doesn't carry a canvas.
    case mediaStreamAnswer(Data)
    /// 0x14 MiscStatus: 12 heartbeat, 2 remote clipboard changed, 11 user session changed.
    case miscStatus(cmd: UInt16)
    /// 0x1f: emitted once per record as the compressed payload arrives; the
    /// chunks concatenate to exactly `header.compressedSize` bytes.
    case clipboard(header: ClipboardSendHeader, payloadChunk: Data)
    case bell
    /// 0x06 zlib rect, raw compressed payload (decoded on a persistent stream later).
    case zlibRect(x: Int, y: Int, w: Int, h: Int, payload: Data)
    /// Unknown message type, or (type 0) an unknown rect encoding.
    case unknown(type: UInt8, encoding: Int32? = nil)
}

enum ServerMessageError: Error, Equatable {
    /// A single message grew beyond `ServerMessageParser.maxPendingBytes`
    /// without completing — the stream is desynchronised.
    case oversizedMessage(Int)
}

struct ServerMessageParser {
    enum Framing: Sendable {
        /// Decrypted record bodies (steady state). Bytes left in a record
        /// after a message completes are discarded.
        case records
        /// The raw plaintext prelude stream (negotiation._read_until_enc1103):
        /// messages are back-to-back; parsing halts after the FBU carrying the
        /// rekey, and the bytes after it (ciphertext) are left for
        /// `takeRemainder()`.
        case stream
    }

    static let maxPendingBytes = 16 << 20

    private enum State {
        case idle
        case fbu(rectsLeft: Int, sawRekey: Bool)
        case clipboard(ClipboardSendHeader, remaining: Int)
        case halted
    }

    let framing: Framing
    private var buf: [UInt8] = []
    private var pos = 0
    private var state: State = .idle
    /// True only while the pending message may legitimately continue in the
    /// next record (see FRAMING). Cleared whenever a message/rect completes.
    private var spanOK = false

    init(framing: Framing = .records) { self.framing = framing }

    /// True once a `.stream` parser has seen the rekey FBU.
    var isHalted: Bool { if case .halted = state { return true } else { return false } }

    /// Returns (and clears) the unparsed bytes; used after a `.stream` parser
    /// halts to hand the ciphertext tail to the record layer.
    mutating func takeRemainder() -> Data {
        let d = Data(buf[pos...])
        buf.removeAll(keepingCapacity: false); pos = 0
        return d
    }

    mutating func feed(_ body: Data) throws -> [ServerEvent] {
        if case .halted = state { buf.append(contentsOf: body); return [] }
        if framing == .records && hasPending && !spanOK {
            // Each record is self-contained (reference behaviour): the
            // incomplete message from the previous record is dropped.
            Log.control.debug("dropping incomplete server message (\(buf.count - pos) byte(s)) at record boundary")
            buf.removeAll(keepingCapacity: true); pos = 0
            state = .idle
        }
        buf.append(contentsOf: body)
        var events: [ServerEvent] = []
        loop: while true {
            switch state {
            case .halted:
                break loop
            case .idle:
                guard pos < buf.count else { break loop }
                guard try startMessage(&events) else { break loop }
            case .fbu(let left, let sawRekey):
                if left == 0 { finishMessage(halt: sawRekey); continue }
                switch parseRect(&events, afterRekey: sawRekey) {
                case .needMore: break loop
                case .done(let isRekey):
                    spanOK = false
                    state = .fbu(rectsLeft: left - 1, sawRekey: sawRekey || isRekey)
                case .abort: finishMessage(halt: sawRekey)
                }
            case .clipboard(let header, let remaining):
                let n = min(remaining, buf.count - pos)
                if n > 0 {
                    events.append(.clipboard(header: header, payloadChunk: slice(pos, n)))
                    pos += n
                }
                if remaining - n == 0 { finishMessage() } else {
                    state = .clipboard(header, remaining: remaining - n)
                    spanOK = true
                }
                if remaining - n > 0 { break loop }
            }
        }
        compact()
        if buf.count - pos > Self.maxPendingBytes {
            let n = buf.count - pos
            buf.removeAll(); pos = 0; state = .idle; spanOK = false
            throw ServerMessageError.oversizedMessage(n)
        }
        return events
    }

    /// A message has started but not completed (or a header is partial).
    private var hasPending: Bool {
        if case .idle = state { return pos < buf.count }
        return true
    }

    // MARK: messages

    /// Dispatches on the type byte (session._handle_tcp_msg). Returns false
    /// if more bytes are needed.
    private mutating func startMessage(_ events: inout [ServerEvent]) throws -> Bool {
        let avail = buf.count - pos
        let type = buf[pos]
        switch type {
        case 0x00:   // FramebufferUpdate: 00 pad u16 n_rects
            guard avail >= 4 else { return false }
            let n = Int(u16(pos + 2))
            pos += 4
            state = .fbu(rectsLeft: n, sawRekey: false)
        case 0x14:   // MiscStatus: 14 00 u16 len, then len bytes (u16 flags, u16 cmd, ...)
            if framing == .records && avail < 8 {
                // Short record: the reference reads cmd only if present and
                // never waits for more.
                Log.control.debug("short 0x14 MiscStatus record (\(avail) byte(s))")
                events.append(.unknown(type: type))
                pos = buf.count
                finishMessage()
                return true
            }
            guard avail >= 4 else { return false }
            let total = max(8, 4 + Int(u16(pos + 2)))
            guard avail >= total || framing == .records else { return false }
            events.append(.miscStatus(cmd: u16(pos + 6)))
            pos += min(total, avail)
            finishMessage()
        case 0x1f:   // ClipboardSend: 16-byte header, then compressed payload (may span records)
            guard avail >= 16 else { return false }
            let header = ClipboardSendHeader(promise: buf[pos + 2], reserved: u32(pos + 4),
                                             uncompressedSize: u32(pos + 8), compressedSize: u32(pos + 12))
            pos += 16
            if header.compressedSize == 0 {
                events.append(.clipboard(header: header, payloadChunk: Data()))
                finishMessage()
            } else {
                state = .clipboard(header, remaining: Int(header.compressedSize))
                spanOK = true   // the payload may span records
            }
        case 0x02:   // Bell
            events.append(.bell)
            pos += 1
            finishMessage()
        case 0x03:   // ServerCutText (RFC 6143): 03 pad×3 u32 len text — unused by the
                     // reference (Apple uses 0x1f); consumed by length, reported as unknown.
            guard avail >= 8 else { return false }
            let n = Int(u32(pos + 4))
            guard avail >= 8 + n else { return false }
            events.append(.unknown(type: type))
            pos += 8 + n
            finishMessage()
        case 0x1c:   // MediaStreamOptions answer: the whole record (negotiation._read_video_answer)
            events.append(.mediaStreamAnswer(slice(pos, avail)))
            pos = buf.count
            finishMessage()
        default:     // Unknown: no length rule — ignore the record (RFC §12).
            Log.control.debug("unknown server message type 0x\(String(type, radix: 16)); discarding record")
            events.append(.unknown(type: type))
            pos = buf.count
            finishMessage()
        }
        return true
    }

    private mutating func finishMessage(halt: Bool = false) {
        spanOK = false
        switch framing {
        case .records:
            if pos < buf.count {
                Log.control.debug("discarding \(buf.count - pos) trailing byte(s) after server message")
            }
            buf.removeAll(keepingCapacity: true); pos = 0
            state = .idle
        case .stream:
            state = halt ? .halted : .idle
        }
    }

    // MARK: rects

    private enum RectResult { case needMore, done(isRekey: Bool), abort }

    /// session._handle_fbu, one rect. Consumes nothing unless the whole rect
    /// is buffered; an incomplete rect is retried on the next record only if
    /// it is spannable (`spanOK`, see FRAMING), otherwise it is dropped.
    private mutating func parseRect(_ events: inout [ServerEvent], afterRekey: Bool) -> RectResult {
        let avail = buf.count - pos
        guard avail >= 12 else { return .needMore }
        let rx = Int(u16(pos)), ry = Int(u16(pos + 2)), rw = Int(u16(pos + 4)), rh = Int(u16(pos + 6))
        let enc = Int32(bitPattern: u32(pos + 8))
        let p = pos + 12
        let have = avail - 12

        func prefixed16() -> Int? {   // total payload length incl. the u16, nil if not buffered
            guard have >= 2 else { return nil }
            let total = 2 + Int(u16(p))
            return have >= total ? total : nil
        }

        switch enc {
        case 0x44F:   // EncodeEncryptionInfo (rekey): fixed 36 bytes
            guard have >= 36 else { return .needMore }
            events.append(.rekey(slice(p, 36)))
            pos = p + 36
            return .done(isRekey: true)

        case 0x450:   // CursorImage
            guard have >= 8 else { return .needMore }
            let cacheID = u32(p), compLen = Int(u32(p + 4))
            // A cursor is at most maxDimension² (real ones are ≤ 256²): larger
            // claimed sizes are skipped, and the comp_len bound uses the
            // capped size so a 65535×65535 header can't justify megabytes.
            let maxSide = CursorImage.maxDimension
            let oversized = rw > maxSide || rh > maxSide
            let px = min(rw, maxSide) * min(rh, maxSide) * 5
            guard compLen <= max(4096, px + px / 100 + 64) else {
                Log.control.error("cursor comp_len \(compLen) implausible for \(rw)x\(rh); aborting record")
                return abortRect(&events, enc: enc, afterRekey: afterRekey, scanForAnswer: false)
            }
            guard have >= 8 + compLen else { spanOK = true; return .needMore }
            if compLen == 0 {
                events.append(.cursorSelect(id: cacheID))
            } else if oversized {
                Log.control.error("cursor \(rw)x\(rh) exceeds \(maxSide)x\(maxSide); skipped")
                events.append(.unknown(type: 0x00, encoding: enc))
            } else if let e = cursorStore(id: cacheID, x: rx, y: ry, w: rw, h: rh, compressed: slice(p + 8, compLen)) {
                events.append(e)
            }
            pos = p + 8 + compLen
            return .done(isRekey: false)

        case 0x451:   // AppleDisplayLayout
            guard let total = prefixed16() else { return .needMore }
            events.append(.displayLayout(DisplayLayout(payload: slice(p + 2, total - 2))))
            pos = p + total
            return .done(isRekey: false)

        case 0x3F2, 0x3F3, 0x3EA, 0x453, 0x455, 0x456:   // u16 prefix + payload
            guard let total = prefixed16() else { return .needMore }
            let payload = slice(p + 2, total - 2)
            switch enc {
            case 0x3F2, 0x3F3, 0x3EA:
                // Only a payload carrying a bplist is an answer candidate.
                if Self.containsBplist(buf[(p + 2)..<(p + total)]) { events.append(.mediaStreamAnswer(payload)) }
            case 0x453: events.append(.vendorKeysyms(Self.parseVendorKeysyms(payload)))
            case 0x455: if let e = Self.parseKeyboardSource(payload) { events.append(e) }
            case 0x456: if let e = Self.parseDeviceInfo(payload) { events.append(e) }
            default: break
            }
            pos = p + total
            return .done(isRekey: false)

        case 0x06, 16:    // zlib / ZRLE: u32 length + payload
            guard have >= 4 else { return .needMore }
            let n = Int(u32(p))
            let raw = rw * rh * 4
            guard n <= max(4096, raw + raw / 100 + 64) else {
                Log.control.error("enc \(enc) length \(n) implausible for \(rw)x\(rh); aborting record")
                return abortRect(&events, enc: enc, afterRekey: afterRekey, scanForAnswer: false)
            }
            guard have >= 4 + n else {
                if enc == 0x06 { spanOK = true }
                return .needMore
            }
            if enc == 0x06 {
                events.append(.zlibRect(x: rx, y: ry, w: rw, h: rh, payload: slice(p + 4, n)))
            } else {
                Log.control.debug("skipping ZRLE rect (\(n) byte(s))")
                events.append(.unknown(type: 0x00, encoding: enc))
            }
            pos = p + 4 + n
            return .done(isRekey: false)

        case -223:    // DesktopSize pseudo-encoding: no payload
            pos = p
            return .done(isRekey: false)

        default:
            // Unknown/video encoding: payload size unknowable, so (like the
            // reference) abort the walk and drop the rest of this record.
            Log.control.debug("FBU rect with unknown encoding 0x\(String(UInt32(bitPattern: enc), radix: 16)); aborting walk")
            return abortRect(&events, enc: enc, afterRekey: afterRekey, scanForAnswer: true)
        }
    }

    /// Aborts the FBU walk at the rect starting at `pos`.
    /// - `.stream` after the rekey: the "rect" is really ciphertext, so
    ///   nothing is consumed or reported and `takeRemainder()` keeps it.
    /// - otherwise: reports `.unknown`, plus `.mediaStreamAnswer(rest)` if the
    ///   rest of the record contains a bplist, and discards the rest.
    private mutating func abortRect(_ events: inout [ServerEvent], enc: Int32, afterRekey: Bool,
                                    scanForAnswer: Bool) -> RectResult {
        if framing == .stream && afterRekey { return .abort }
        events.append(.unknown(type: 0x00, encoding: enc))
        if scanForAnswer && Self.containsBplist(buf[pos...]) {
            events.append(.mediaStreamAnswer(slice(pos, buf.count - pos)))
        }
        pos = buf.count
        return .abort
    }

    private static let bplistMagic = Array("bplist00".utf8)

    private static func containsBplist(_ bytes: ArraySlice<UInt8>) -> Bool {
        let m = bplistMagic
        guard bytes.count >= m.count else { return false }
        var i = bytes.startIndex
        let last = bytes.endIndex - m.count
        while i <= last {
            if bytes[i] == m[0] && bytes[i..<(i + m.count)].elementsEqual(m) { return true }
            i += 1
        }
        return false
    }

    /// session._handle_cursor_rect STORE path: a fresh zlib stream per cursor
    /// (the reference uses a new `decompressobj()` each time); inflated bytes
    /// must be exactly w*h*4 BGRA + w*h alpha, else the rect is dropped.
    /// Inflation is capped at w*h*5 bytes (w, h ≤ maxDimension), so a zlib
    /// bomb — even one injected into the unauthenticated plaintext prelude —
    /// stops at ≤ 1.25 MB. The premultiply runs here, off the main actor.
    private func cursorStore(id: UInt32, x: Int, y: Int, w: Int, h: Int, compressed: Data) -> ServerEvent? {
        let px = w * h
        let raw: Data
        do { raw = try Zlib.inflate(compressed, maxOutput: px * 5) } catch {
            Log.control.error("cursor zlib inflate failed (\(w)x\(h)): \(error)")
            return nil
        }
        guard raw.count == px * 5 else {
            Log.control.debug("cursor size mismatch (got \(raw.count), expected \(px * 5) = \(w)x\(h)*5)")
            return nil
        }
        guard let rgba = CursorImage.premultipliedRGBA(bgra: raw.prefix(px * 4), alpha: raw.suffix(px), pixels: px)
        else { return nil }
        return .cursorStore(id: id, hotspot: PixelPoint(x: x, y: y), size: PixelSize(width: w, height: h), rgba: rgba)
    }

    /// RFC §8.5: u16 header_count, u16 version, u16 value_count, u32 × value_count.
    private static func parseVendorKeysyms(_ payload: Data) -> [UInt32] {
        var r = ByteReader(payload)
        guard (try? r.skip(2)) != nil, let count = try? r.u16() else { return [] }
        var out: [UInt32] = []
        for _ in 0..<count { guard let v = try? r.u32() else { break }; out.append(v) }
        return out
    }

    /// RFC §8.6: u16 version, u32 flags (bit = secure event input), u16 id_len, id.
    private static func parseKeyboardSource(_ payload: Data) -> ServerEvent? {
        var r = ByteReader(payload)
        guard (try? r.skip(2)) != nil, let flags = try? r.u32(), let n = try? r.u16(),
              let id = try? r.bytes(Int(n)) else { return nil }
        return .keyboardSource(String(decoding: id, as: UTF8.self), secureInput: flags != 0)
    }

    /// RFC §8.7: u16 pair_count, u32 version, u32 rgb, u16 id_len, u16, u16,
    /// then the NUL-terminated device identifier first.
    private static func parseDeviceInfo(_ payload: Data) -> ServerEvent? {
        var r = ByteReader(payload)
        guard (try? r.skip(10)) != nil, let n = try? r.u16(), (try? r.skip(4)) != nil,
              let id = try? r.bytes(Int(n)) else { return nil }
        let trimmed = id.prefix { $0 != 0 }
        return .deviceInfo(model: String(decoding: trimmed, as: UTF8.self))
    }

    // MARK: buffer helpers

    private func u16(_ i: Int) -> UInt16 { UInt16(buf[i]) << 8 | UInt16(buf[i + 1]) }
    private func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) << 16 | UInt32(u16(i + 2)) }
    private func slice(_ i: Int, _ n: Int) -> Data { Data(buf[i..<i + n]) }

    private mutating func compact() {
        if pos == buf.count { buf.removeAll(keepingCapacity: true); pos = 0 }
        else if pos > 1 << 20 { buf.removeFirst(pos); pos = 0 }
    }
}
