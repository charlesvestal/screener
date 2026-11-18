// Ported from iShareScreen src/isharescreen/proxy/protocol/clipboard.py
// (build_auto_pasteboard_msg, build_clipboard_request, build_clipboard_send,
// ClipboardReassembler, decompress_clipboard_payload, parse_clipboard_items,
// text_from_items) and the echo guard of session.py
// _spawn_outbound_clipboard_poller / _handle_clipboard_send (AGPL-3.0).
//
// Apple's rich pasteboard extension (RFC §8.2.1, §8.12):
//   0x15 AutoPasteboard  C→S  once per session, selector 1 = start monitoring
//   0x0b ClipboardFetch  C→S  sent on a 0x14 MiscStatus cmd=2 (Mac pasteboard changed)
//   0x1f ClipboardSend   both directions: 16-byte header + zlib (Z_SYNC_FLUSH)
//                        stream of an inner pasteboard archive. Inbound, the
//                        compressed payload may span several records.
// Outbound text also goes as 0x1f (cut_text), not RFB 0x06 ClientCutText: the
// daemon routes 0x06 to the legacy scrap only, so modern Mac apps can't paste it.
//
// Privacy: nothing here logs clipboard contents; callers log sizes only.
import Foundation

enum ClipboardError: Error, Equatable {
    case tooLarge(Int)
    case malformed
}

/// One pasteboard flavor of the inner archive.
struct ClipboardItem: Equatable, Sendable {
    var primaryUTI: String
    var primaryData: Data
    var aliases: [(name: String, value: Data)] = []

    static func == (a: ClipboardItem, b: ClipboardItem) -> Bool {
        a.primaryUTI == b.primaryUTI && a.primaryData == b.primaryData
            && a.aliases.map(\.name) == b.aliases.map(\.name) && a.aliases.map(\.value) == b.aliases.map(\.value)
    }
}

enum Clipboard {
    /// 0x1f HandleViewerClipboardSend (both directions).
    static let typeClipboardSend: UInt8 = 0x1f
    static let utf8UTI = "public.utf8-plain-text"

    /// Largest clipboard text synced either way (UTF-8 bytes). Larger text is
    /// skipped with a log line (size only).
    static let maxTextBytes = 1 << 20
    /// Largest inbound compressed payload accepted (bytes are still consumed
    /// off the wire, just not kept).
    static let maxCompressedBytes = 8 << 20
    /// Largest inflated inbound archive (a 1 MB text sent with all of Apple's
    /// flavors is about 3 MB: UTF-8 + UTF-16 + legacy).
    static let maxArchiveBytes = 8 << 20
    /// Largest message one record can carry: the record's u16 ciphertext
    /// length (a multiple of the 16-byte block) holds u16 len + body + pad +
    /// 20-byte MAC, so body ≤ 65520 − 22. The reference sends 0x1f as one
    /// record and never splits it; neither do we.
    static let maxOutboundMessage = 65_520 - 2 - 20

    // MARK: builders

    /// build_auto_pasteboard_msg: `15 00 u16 selector 00000000` (selector 1 = start).
    static func autoPasteboard() -> Data { ClientMessage.autoPasteboard(selector: 1) }

    /// build_clipboard_request: 8 bytes, full fetch (not promise-only).
    static func request() -> Data { ClientMessage.clipboardFetch(promiseOnly: false) }

    /// The inner archive with a single `public.utf8-plain-text` item.
    static func archive(text: String) -> Data {
        let textBytes = Data(text.utf8)
        let uti = Data(utf8UTI.utf8)
        var w = ByteWriter(capacity: 20 + uti.count + textBytes.count)
        w.u32(1)
        w.u32(UInt32(uti.count)); w.bytes(uti)
        w.u32(0)          // reserved
        w.u32(0)          // alias_count
        w.u32(UInt32(textBytes.count)); w.bytes(textBytes)
        return w.data
    }

    /// build_clipboard_send: 0x1f header + a fresh Z_SYNC_FLUSH deflate of the
    /// archive. Throws `tooLarge` past `maxTextBytes` or if the message would
    /// not fit in one record (`maxOutboundMessage`).
    static func send(text: String) throws -> Data {
        let n = text.utf8.count
        guard n <= maxTextBytes else { throw ClipboardError.tooLarge(n) }
        let inner = archive(text: text)
        let compressed = try Zlib.Deflater().compress(inner)
        var w = ByteWriter(capacity: 16 + compressed.count)
        w.u8(typeClipboardSend); w.u8(0); w.u8(0); w.u8(0)
        w.u32(0)                              // reserved
        w.u32(UInt32(inner.count))            // uncompressed_size
        w.u32(UInt32(compressed.count))       // compressed_size
        w.bytes(compressed)
        guard w.data.count <= maxOutboundMessage else { throw ClipboardError.tooLarge(w.data.count) }
        return w.data
    }

    // MARK: parsing

    /// decompress_clipboard_payload, bounded: inflates in small slices and
    /// gives up once the output passes `limit` (a lying header can't make us
    /// allocate more than about limit + 1 MB).
    static func inflate(_ payload: Data, limit: Int = maxArchiveBytes) throws -> Data {
        guard !payload.isEmpty else { return Data() }
        let inflater = try Zlib.Inflater()
        var out = Data()
        var i = payload.startIndex
        while i < payload.endIndex {
            let j = payload.index(i, offsetBy: 1024, limitedBy: payload.endIndex) ?? payload.endIndex
            out.append(try inflater.inflate(payload[i..<j]))
            guard out.count <= limit else { throw ClipboardError.tooLarge(out.count) }
            i = j
        }
        return out
    }

    /// parse_clipboard_items. Fewer than 4 bytes (the empty clipboard's
    /// zero-length archive) → no items. Truncated items throw `malformed`.
    static func parseItems(_ archive: Data) throws -> [ClipboardItem] {
        guard archive.count >= 4 else { return [] }
        var r = ByteReader(archive)
        do {
            func lp() throws -> Data { try r.bytes(Int(try r.u32())) }
            let count = try r.u32()
            var items: [ClipboardItem] = []
            for _ in 0..<count {
                let uti = String(decoding: try lp(), as: UTF8.self)
                _ = try r.u32()                         // reserved
                let aliasCount = try r.u32()
                var aliases: [(name: String, value: Data)] = []
                for _ in 0..<aliasCount {
                    let name = String(decoding: try lp(), as: UTF8.self)
                    aliases.append((name, try lp()))
                }
                items.append(ClipboardItem(primaryUTI: uti, primaryData: try lp(), aliases: aliases))
            }
            return items
        } catch {
            throw ClipboardError.malformed
        }
    }

    /// text_from_items: `public.utf8-plain-text` first; then any `public.*text*`
    /// flavor (UTF-16 ones decoded big-endian, as the Mac sends them on the
    /// wire — RFC §8.2.1 — unless a BOM says otherwise); then the legacy
    /// `com.apple.traditional-mac-plain-text` (Latin-1). nil if no text flavor.
    static func text(from items: [ClipboardItem]) -> String? {
        if let it = items.first(where: { $0.primaryUTI == utf8UTI }) {
            return String(decoding: it.primaryData, as: UTF8.self)
        }
        if let it = items.first(where: { $0.primaryUTI.hasPrefix("public.") && $0.primaryUTI.contains("text") }) {
            return it.primaryUTI.contains("utf16") ? utf16(it.primaryData) : String(decoding: it.primaryData, as: UTF8.self)
        }
        if let it = items.first(where: { $0.primaryUTI == "com.apple.traditional-mac-plain-text" }) {
            return String(data: it.primaryData, encoding: .isoLatin1)
        }
        return nil
    }

    /// UTF-16 text, big-endian unless it starts with a little-endian BOM.
    static func utf16(_ d: Data) -> String {
        var bytes = [UInt8](d)
        var littleEndian = false
        if bytes.count >= 2 {
            if bytes[0] == 0xFF && bytes[1] == 0xFE { littleEndian = true; bytes.removeFirst(2) }
            else if bytes[0] == 0xFE && bytes[1] == 0xFF { bytes.removeFirst(2) }
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(littleEndian ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                                      : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A complete inbound 0x1f → its text (nil: no text flavor). Throws on a
    /// bad stream / archive or past the size caps. Pure; call off the main actor.
    static func decodeText(header: ClipboardSendHeader, payload: Data) throws -> String? {
        let archive = try inflate(payload)
        if archive.count != Int(header.uncompressedSize) {
            Log.control.debug("clipboard inner size mismatch (got \(archive.count), expected \(header.uncompressedSize))")
        }
        let items = try parseItems(archive)
        guard let text = text(from: items) else {
            Log.control.info("clipboard recv: \(items.count) item(s), no text flavor")
            return nil
        }
        let n = text.utf8.count
        guard n <= maxTextBytes else { throw ClipboardError.tooLarge(n) }
        return text
    }

    /// The echo-guard comparison form (the poller's `_norm`): CRLF → LF,
    /// trailing whitespace dropped.
    static func normalized(_ s: String?) -> String {
        var t = (s ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        while let last = t.last, last.isWhitespace { t.removeLast() }
        return t
    }
}

/// ClipboardReassembler over the parser's `.clipboard` events: the header
/// plus payload chunks (one per record) that concatenate to `compressedSize`.
/// Returns the complete compressed payload once all of it arrived. Payloads
/// over `limit` are counted through (so the next message starts clean) but
/// not kept, and reported as `.oversized`.
struct ClipboardReassembler {
    enum Output: Equatable {
        case complete(ClipboardSendHeader, Data)
        case oversized(Int)
    }

    let limit: Int
    private var header: ClipboardSendHeader?
    private var buffer = Data()
    private var received = 0

    init(limit: Int = Clipboard.maxCompressedBytes) { self.limit = limit }

    var inProgress: Bool { header != nil }

    mutating func reset() { header = nil; buffer = Data(); received = 0 }

    mutating func feed(header h: ClipboardSendHeader, chunk: Data) -> Output? {
        if let current = header, current != h {
            // A new message while one was in flight (the parser emits chunks
            // in order, so this means the old one was cut short): start over.
            reset()
        }
        if header == nil {
            header = h
            buffer = Data()
            received = 0
            if Int(h.compressedSize) <= limit { buffer.reserveCapacity(Int(h.compressedSize)) }
        }
        let total = Int(h.compressedSize)
        received += chunk.count
        if total <= limit { buffer.append(chunk) }
        guard received >= total else { return nil }
        let out: Output = total <= limit ? .complete(h, Data(buffer.prefix(total))) : .oversized(total)
        reset()
        return out
    }
}

/// Echo-loop prevention and "what changed" bookkeeping for two-way sync,
/// without touching UIPasteboard (the coordinator does the I/O). Reading the
/// iPad pasteboard's text can show iOS's "Allow Paste" banner, so a read
/// happens only when its `changeCount` moved since we last accounted for it.
struct ClipboardSyncState: Equatable {
    /// What a session should do first.
    enum Start: Equatable {
        /// The Mac is the source of truth: prime the iPad with a fetch.
        case fetchMac
        /// The iPad pasteboard changed since the last sync (e.g. copied in
        /// another app while we were in the background): read it and send it.
        case pushLocal
    }

    /// The iPad pasteboard `changeCount` we've accounted for, and its text
    /// when known (nil: not read, no text, or the user refused the paste).
    private(set) var localChangeCount: Int?
    private(set) var localText: String?
    /// The text known to be on the Mac's pasteboard this session.
    private(set) var macText: String?

    mutating func sessionStarted(changeCount: Int) -> Start {
        macText = nil
        guard let known = localChangeCount else {
            // First session: whatever is on the iPad now predates us.
            localChangeCount = changeCount
            localText = nil
            return .fetchMac
        }
        return known == changeCount ? .fetchMac : .pushLocal
    }

    /// True if the iPad pasteboard changed since we last accounted for it.
    func localChanged(changeCount: Int) -> Bool { localChangeCount != changeCount }

    /// The Mac's pasteboard text arrived. True if it should be written to the
    /// iPad (false when the iPad already holds exactly that, unchanged).
    mutating func remoteText(_ text: String, changeCount: Int) -> Bool {
        macText = text
        if localChangeCount == changeCount, localText != nil,
           Clipboard.normalized(localText) == Clipboard.normalized(text) {
            return false
        }
        return true
    }

    /// We wrote `text` to the iPad pasteboard; it now has `changeCount`.
    mutating func didWriteLocal(_ text: String, changeCount: Int) {
        localChangeCount = changeCount
        localText = text
    }

    /// We accounted for the iPad pasteboard at `changeCount` without reading
    /// it (no strings on it): nothing to send until it changes again.
    mutating func noteLocal(changeCount: Int) {
        localChangeCount = changeCount
        localText = nil
    }

    /// We read the iPad pasteboard (`text` nil: no text or paste refused).
    /// Returns the text to send to the Mac, or nil. `force` (an explicit
    /// "Send") sends even if the Mac should already have it.
    mutating func localRead(_ text: String?, changeCount: Int, force: Bool = false) -> String? {
        localChangeCount = changeCount
        localText = text
        guard let text, !text.isEmpty else { return nil }
        if !force, macText != nil, Clipboard.normalized(macText) == Clipboard.normalized(text) { return nil }
        macText = text
        return text
    }
}

/// How the iPad→Mac direction is driven (Mac→iPad is always automatic in
/// `.automatic`; in `.manual` both directions wait for the menu buttons).
enum ClipboardSyncMode: String, CaseIterable, Sendable {
    case automatic, manual
    static let defaultsKey = "clipboard.syncMode"
    static let `default` = ClipboardSyncMode.automatic

    static var current: ClipboardSyncMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ClipboardSyncMode.init(rawValue:)) ?? .default
    }
}
