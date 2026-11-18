// Ported from iShareScreen src/isharescreen/proxy/protocol/offers.py
// (protobuf helpers, _build_audio_f9_entry, _build_remote_endpoint_info,
// _build_mediablob, create_offers, extract_offer_ssrc, extract_canvas_dims)
// and src/isharescreen/proxy/protocol/negotiation.py (NegotiationKeys,
// random_negotiation_keys, build_0x1c, _read_video_answer) (AGPL-3.0)
//
// AVCMediaStreamNegotiator offers, the 0x1c MediaStreamOptions message that
// carries them together with the SRTP master keys, and the answer parser.
//
// Differences from the reference (wire bytes are unchanged for the default
// configuration; verified against ScreenerTests/Fixtures/media_offer.json):
//  * Env-var knobs are gone (ISS_VIDEO_CODEC, ISS_TILES_PER_FRAME, ISS_LTRP,
//    ISS_AUDIO_F4, ISS_LEGACY_CURSOR). The offer is always the reference's
//    default: LTRP on, tilesPerFrame = 4, and BOTH codec banks in Apple's
//    byte-identical order (field1=123 then field1=100). Per the reference's
//    live testing that pair is what makes the server answer with HEVC 4:4:4;
//    the AVC-only/HEVC-only bank selections are dropped.
//  * RemoteEndpointInfo strings and the field-6 client name are parameters
//    (the reference probes `sysctl hw.model`/`sw_vers` and uses
//    "iShareScreen <version>"); defaults describe this iPad and Screener.
//  * NegotiationKeys holds the reference's FOUR 46-byte blobs (audio/video ×
//    viewer→server/server→viewer); the 0x1c layout has room for exactly four.
//  * parseAnswer drops extract_canvas_dims' `msg[0] == 0x00` gate: the
//    ServerMessageParser hands over 0x3f2/0x3f3 rect payloads with the FBU
//    header already stripped (and whole top-level 0x1c records), so the
//    bplist is located by scanning instead. It throws when no usable canvas
//    is found (the reference returns zeros = "encoder not ready, retry").
import Foundation
import zlib

// MARK: - Protobuf helpers (offers._varint / _field_varint / _field_bytes / _read_varint)

enum Protobuf {
    static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    static func fieldVarint(_ field: UInt64, _ value: UInt64) -> Data {
        varint(field << 3) + varint(value)
    }

    static func fieldBytes(_ field: UInt64, _ value: Data) -> Data {
        varint(field << 3 | 2) + varint(UInt64(value.count)) + value
    }

    enum FieldValue {
        case varint(UInt64)
        case bytes(Data)
    }

    /// Walks top-level fields like the reference's inline loops: wire types
    /// 0/2 are reported, 1/5 skipped, anything else stops the walk. Lenient
    /// on truncation the way Python slicing is (a short length-delimited
    /// field yields whatever bytes remain).
    static func forEachField(_ input: Data, _ body: (_ field: UInt64, _ value: FieldValue) -> Void) {
        let b = [UInt8](input)
        var pos = 0
        func readVarint() -> UInt64 {
            var val: UInt64 = 0
            var shift: UInt64 = 0
            while pos < b.count {
                let byte = b[pos]
                pos += 1
                if shift < 64 { val |= UInt64(byte & 0x7F) << shift }
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            return val
        }
        while pos < b.count {
            let tag = readVarint()
            switch tag & 7 {
            case 0:
                body(tag >> 3, .varint(readVarint()))
            case 2:
                let len = readVarint()
                let end = len > UInt64(b.count - pos) ? b.count : pos + Int(len)
                body(tag >> 3, .bytes(Data(b[pos..<end])))
                pos = end
            case 1: pos += 8
            case 5: pos += 4
            default: return
            }
        }
    }
}

// MARK: - Offers

enum MediaOffer {
    /// The `tilesPerFrame` value advertised (VideoSettings field 6); also the
    /// number of video tiles/SSRCs to expect. HEVC default from the reference.
    static let tilesPerFrame: UInt64 = 4

    /// RemoteEndpointInfo strings (informational to AVConference).
    struct EndpointInfo: Sendable, Equatable {
        var hardwareModel: String
        var avcVersion: String
        var osBuild: String

        /// This device: `hw.machine` (e.g. "iPad16,5"; the iOS analogue of
        /// the Mac `hw.model` the reference sends) and `kern.osversion`
        /// (the build, as `sw_vers -buildVersion` gives on macOS).
        /// SCREENER_ENDPOINT_MODEL overrides the model (A/B test: does the
        /// server treat an iPad model differently from the Mac model the
        /// reference and the native viewer send?).
        static var current: EndpointInfo {
            var model = sysctlString("hw.machine") ?? "Generic"
            let env = ProcessInfo.processInfo.environment
            if let sim = env["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { model = sim }
            if let forced = env["SCREENER_ENDPOINT_MODEL"], !forced.isEmpty { model = forced }
            return EndpointInfo(hardwareModel: model.isEmpty ? "Generic" : model,
                                avcVersion: "1.0.0",
                                osBuild: sysctlString("kern.osversion") ?? "0")
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return s.isEmpty ? nil : s
        }

        /// offers._build_remote_endpoint_info: f1=0, f2=1, then three
        /// one-byte-length strings truncated to 127 UTF-8 bytes.
        var encoded: Data {
            func str(_ tag: UInt8, _ s: String) -> Data {
                let b = Data(s.utf8.prefix(127))
                return Data([tag, UInt8(b.count)]) + b
            }
            return Data([0x08, 0x00, 0x10, 0x01]) + str(0x1A, hardwareModel) + str(0x22, avcVersion) + str(0x2A, osBuild)
        }
    }

    static var defaultClientName: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Screener \(v)"
    }

    enum Mode: Int64 { case video = 7, audio = 8 }

    // Apple's canonical f9 audio-config tier list (f1 kind, f2, optional f3).
    private static let audioF9Tiers: [(UInt64, UInt64, UInt64?)] = [
        (0, 40_000_000, 12288),
        (0, 6_000_000, 131072),
        (4074, 0, 16384),          // header marker
        (16, 4100, nil),           // CELT-NB 4100
        (0, 75_000_000, 524288),   // 75M CELT-FB (HP tier)
        (0, 20_000_000, 98304),
        (4, 6500, nil),            // SILK 6500
        (0, 60_000_000, 262144),
        (1, 299, nil),
        (0, 100_000_000, 1048576), // 100M CELT-FB (HP tier)
    ]

    /// offers._build_audio_f9_entry.
    static func audioF9Entry(_ f1: UInt64, _ f2: UInt64, _ f3: UInt64?) -> Data {
        var body = Data([0x08]) + Protobuf.varint(f1) + Data([0x10]) + Protobuf.varint(f2)
        if let f3 { body += Data([0x18]) + Protobuf.varint(f3) }
        return Data([0x4A]) + Protobuf.varint(UInt64(body.count)) + body
    }

    private static let appleAudioF9: Data = audioF9Tiers.reduce(into: Data()) { $0 += audioF9Entry($1.0, $1.1, $1.2) }

    // LTR is always advertised (HEVC path; reference default ISS_LTRP=1).
    private static let hevcParamsLTR = Data("FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;".utf8)
    private static let avcParams = Data("FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:16/9,5/8;XR:16/9,5/8;".utf8)

    /// Audio-description field 4 (preferredMediaBitRate): 24191 selects the
    /// system-audio tier; a sub-floor value gates the server's audio off.
    private static let audioF4On: UInt64 = 24191
    private static let audioF4Off: UInt64 = 1000

    /// offers._build_mediablob (codec "both", LTRP on).
    static func mediaBlob(mode: Mode, sessionID: UInt32, timestamp: UInt64, audioEnabled: Bool, clientName: String) -> Data {
        typealias P = Protobuf
        let descField: Data
        switch mode {
        case .video:
            let res = P.fieldVarint(1, 1) + P.fieldVarint(2, 1) + P.fieldVarint(3, 50115) + P.fieldVarint(4, 0)
            let resAlt = P.fieldVarint(1, 1) + P.fieldVarint(2, 2) + P.fieldVarint(3, 50115) + P.fieldVarint(4, 0)
            // Bank names follow the PARAMS they carry; the server's response is
            // inverted (field1=123 → H.264, field1=100 → HEVC 4:4:4). Sending
            // both in this order is Apple's offer; the server picks HEVC.
            let bank123 = P.fieldVarint(1, 123)
                + P.fieldBytes(2, res) + P.fieldBytes(2, resAlt) + P.fieldBytes(2, res) + P.fieldBytes(2, resAlt)
                + P.fieldBytes(3, hevcParamsLTR) + P.fieldVarint(4, 1)
            let bank100 = P.fieldVarint(1, 100)
                + P.fieldBytes(2, res) + P.fieldBytes(2, resAlt)
                + P.fieldBytes(3, avcParams) + P.fieldVarint(4, 14)
            // VideoSettings: 2 = allowRTCPFB/LTRP, 6 = tilesPerFrame, 7 = ltrpEnabled.
            let desc = P.fieldVarint(1, UInt64(sessionID)) + P.fieldVarint(2, 1)
                + P.fieldBytes(3, bank123) + P.fieldBytes(3, bank100)
                + P.fieldVarint(6, tilesPerFrame) + P.fieldVarint(7, 1)
                + P.fieldVarint(8, 63)
                + P.fieldVarint(9, 1) + P.fieldVarint(12, 1)
            descField = P.fieldBytes(5, desc)
        case .audio:
            let desc = P.fieldVarint(1, UInt64(sessionID)) + P.fieldVarint(2, 0)
                + P.fieldVarint(3, 0) + P.fieldVarint(4, audioEnabled ? audioF4On : audioF4Off)
                + P.fieldVarint(5, 0) + P.fieldVarint(6, 0)
            descField = P.fieldBytes(3, desc)
        }
        return P.fieldVarint(1, 1) + P.fieldVarint(2, 1)
            + descField
            + P.fieldBytes(6, Data(clientName.utf8))
            + P.fieldVarint(8, 0)
            + appleAudioF9
            + P.fieldVarint(13, timestamp)
            + P.fieldVarint(14, 2) + P.fieldVarint(16, 0) + P.fieldVarint(18, 1)
    }

    /// One offer plist (the inner `_plist(mode)` of offers.create_offers).
    static func offer(mode: Mode, sessionID: UInt32, timestamp: UInt64, callID: UUID, audioEnabled: Bool,
                      endpoint: EndpointInfo, clientName: String) throws -> Data {
        let blob = mediaBlob(mode: mode, sessionID: sessionID, timestamp: timestamp,
                             audioEnabled: audioEnabled, clientName: clientName)
        return BinaryPlist.encode(.dict([
            "avcMediaStreamOptionRemoteEndpointInfo": .data(endpoint.encoded),
            "avcMediaStreamNegotiatorMode": .int(mode.rawValue),
            "avcMediaStreamNegotiatorMediaBlob": .data(try zlibCompress(blob)),
            "avcMediaStreamOptionCallID": .string(callID.uuidString),   // uppercase, as str(uuid).upper()
        ]))
    }

    /// Deterministic offers: the same session ID / timestamp / CallID for both
    /// (how the fixture was generated). Production code uses `create(audioEnabled:)`.
    static func create(sessionID: UInt32, timestamp: UInt64, callID: UUID, audioEnabled: Bool,
                       endpoint: EndpointInfo = .current, clientName: String = defaultClientName) throws -> (audio: Data, video: Data) {
        let video = try offer(mode: .video, sessionID: sessionID, timestamp: timestamp, callID: callID,
                              audioEnabled: audioEnabled, endpoint: endpoint, clientName: clientName)
        let audio = try offer(mode: .audio, sessionID: sessionID, timestamp: timestamp, callID: callID,
                              audioEnabled: audioEnabled, endpoint: endpoint, clientName: clientName)
        return (audio, video)
    }

    /// offers.create_offers: fresh random session ID (= our SSRC), wall-clock
    /// nanosecond timestamp and CallID per offer, video built first.
    static func create(audioEnabled: Bool, endpoint: EndpointInfo = .current,
                       clientName: String = defaultClientName) throws -> (audio: Data, video: Data) {
        func fresh(_ mode: Mode) throws -> Data {
            let sid = SecureRandom.bytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            return try offer(mode: mode, sessionID: sid, timestamp: ts, callID: UUID(),
                             audioEnabled: audioEnabled, endpoint: endpoint, clientName: clientName)
        }
        let video = try fresh(.video)
        let audio = try fresh(.audio)
        return (audio, video)
    }

    /// offers.extract_offer_ssrc: our advertised SSRC (= session ID). Video
    /// lives in blob field 5 → 1, audio in field 3 → 1. Nil if absent.
    static func extractSSRC(_ offerPlist: Data, isVideo: Bool) -> UInt32? {
        guard let plist = try? PropertyListSerialization.propertyList(from: offerPlist, format: nil) as? [String: Any],
              let compressed = plist["avcMediaStreamNegotiatorMediaBlob"] as? Data,
              let blob = try? Zlib.inflate(compressed) else { return nil }
        let target: UInt64 = isVideo ? 5 : 3
        var ssrc: UInt32?
        Protobuf.forEachField(blob) { field, value in
            guard ssrc == nil, field == target, case .bytes(let inner) = value else { return }
            // Only the first inner field is consulted, and only if it is f1 varint.
            var first: (UInt64, Protobuf.FieldValue)?
            Protobuf.forEachField(inner) { f, v in if first == nil { first = (f, v) } }
            if let (f, v) = first, f == 1, case .varint(let n) = v { ssrc = UInt32(truncatingIfNeeded: n) }
        }
        return ssrc
    }

    /// One-shot zlib (Python `zlib.compress(blob)`: default level, Z_FINISH).
    static func zlibCompress(_ input: Data) throws -> Data {
        var destLen = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(destLen))
        let rc = input.withUnsafeBytes { src in
            compress2(&out, &destLen, src.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
        }
        guard rc == Z_OK else { throw ZlibError.stream(rc) }
        return Data(out.prefix(Int(destLen)))
    }
}

// MARK: - 0x1c MediaStreamOptions

/// SRTP master keys exchanged in 0x1c: each blob is 32 B key + 14 B salt.
/// `V` = viewer→server, `S` = server→viewer (reference akv/aks/vkv/vks).
struct NegotiationKeys: Sendable, Equatable {
    static let blobLength = 46
    var audioKeyV: Data
    var audioKeyS: Data
    var videoKeyV: Data
    var videoKeyS: Data

    /// negotiation.random_negotiation_keys.
    static func random() -> NegotiationKeys {
        NegotiationKeys(audioKeyV: SecureRandom.bytes(blobLength), audioKeyS: SecureRandom.bytes(blobLength),
                        videoKeyV: SecureRandom.bytes(blobLength), videoKeyS: SecureRandom.bytes(blobLength))
    }
}

/// Canvas the server's encoder will produce (extract_canvas_dims).
struct MediaAnswer: Sendable, Equatable {
    var canvasWidth: Int
    var canvasHeight: Int
    var tiles: Int
    /// Answer F5.f7: whether the server accepted LTRP (nil if absent).
    var ltrpEnabled: Bool?
}

enum MediaAnswerError: Error, Equatable {
    /// No bplist with a non-degenerate canvas: treat as "encoder not ready, retry".
    case noCanvas
}

enum MediaStreamOptions {
    /// Config bitmask at body+0x06: bit0 60 fps stream 1, bit1 60 fps stream 2,
    /// bit2 do-not-send-cursor (cursor drawn locally from enc 1104).
    /// Normal: 3 | 4 = 7. Alt-session (cmd=2 path): drop bit1, set bit2 = 5.
    static func configFlags(altSession: Bool) -> UInt32 {
        altSession ? (3 & ~2) | 4 : 3 | 4
    }

    /// negotiation.build_0x1c. Layout:
    ///   +0x00 u8 0x1c, +0x02 u16 BE MS = AS+VS+0xd8, +0x04 u16 BE 3,
    ///   +0x06 u32 BE flags, +0x0a u16 BE AS, +0x0c u16 BE VS,
    ///   +0x14 16 B CallID UUID, +0x24 akv, +0x52 aks, +0x80 audio offer,
    ///   then vkv, vks, video offer.
    /// The flags word is BIG-endian (`00 00 00 07`) as the reference writes it
    /// deliberately: the host forwards it un-swapped across an IPC/NDR boundary
    /// that byte-swaps it, and only big-endian makes the agent honor
    /// do_not_send_cursor. RFC §10.3 says little-endian; the reference wins.
    static func build(keys: NegotiationKeys, audioOffer: Data, videoOffer: Data,
                      uuid: UUID = UUID(), flags: UInt32 = configFlags(altSession: false)) -> Data {
        precondition([keys.audioKeyV, keys.audioKeyS, keys.videoKeyV, keys.videoKeyS].allSatisfy { $0.count == NegotiationKeys.blobLength })
        let ms = audioOffer.count + videoOffer.count + 0xD8
        var w = ByteWriter()
        w.u8(0x1C); w.u8(0)
        w.u16(UInt16(truncatingIfNeeded: ms))
        w.u16(3)
        w.u32(flags)
        w.u16(UInt16(truncatingIfNeeded: audioOffer.count))
        w.u16(UInt16(truncatingIfNeeded: videoOffer.count))
        w.zeros(0x14 - 0x0E)
        w.bytes(withUnsafeBytes(of: uuid.uuid) { Data($0) })
        w.bytes(keys.audioKeyV); w.bytes(keys.audioKeyS)
        w.bytes(audioOffer)
        w.bytes(keys.videoKeyV); w.bytes(keys.videoKeyS)
        w.bytes(videoOffer)
        return w.data
    }

    /// offers.extract_canvas_dims over any answer shape: a whole FBU message,
    /// a 0x3f2/0x3f3 rect payload, or a top-level 0x1c record. Every embedded
    /// `bplist` is tried in order; the first whose media blob's field 5 has a
    /// non-zero width and height wins.
    ///
    /// Bounded against a hostile answer (security review M1): at most
    /// `maxAnswerCandidates` "bplist" markers are tried, each with at most
    /// `maxPlistParsesPerCandidate` full plist parses (so many markers or many
    /// self-consistent fake trailers cost O(candidates × n), not O(n²)), and
    /// the media blob inflates to at most `maxMediaBlobBytes`.
    static func parseAnswer(_ data: Data) throws -> MediaAnswer {
        let b = [UInt8](data)
        let magic = Array("bplist".utf8)
        var idx = 0, candidates = 0
        while candidates < maxAnswerCandidates, let start = find(magic, in: b, from: idx) {
            idx = start + magic.count
            candidates += 1
            guard let plist = embeddedPlist(b, at: start),
                  let compressed = plist["avcMediaStreamNegotiatorMediaBlob"] as? Data, !compressed.isEmpty,
                  let blob = try? Zlib.inflate(compressed, maxOutput: maxMediaBlobBytes) else { continue }
            var answer = MediaAnswer(canvasWidth: 0, canvasHeight: 0, tiles: 0)
            Protobuf.forEachField(blob) { field, value in
                guard field == 5, case .bytes(let sub) = value else { return }
                Protobuf.forEachField(sub) { f, v in
                    guard case .varint(let n) = v else { return }
                    switch f {
                    case 4: answer.canvasWidth = Int(truncatingIfNeeded: n)
                    case 5: answer.canvasHeight = Int(truncatingIfNeeded: n)
                    case 6: answer.tiles = Int(truncatingIfNeeded: n)
                    case 7: answer.ltrpEnabled = n != 0
                    default: break
                    }
                }
            }
            if answer.canvasWidth != 0 && answer.canvasHeight != 0 { return answer }
        }
        throw MediaAnswerError.noCanvas
    }

    /// "bplist" markers tried per answer (a real answer carries one).
    static let maxAnswerCandidates = 8
    /// Full plist parses per marker (prefixes with a self-consistent trailer).
    static let maxPlistParsesPerCandidate = 4
    /// The inflated AVC media blob (a real one is a few hundred bytes).
    static let maxMediaBlobBytes = 1 << 20

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        for i in from...(hay.count - needle.count)
        where hay[i] == needle[0] && hay[i..<i + needle.count].elementsEqual(needle) {
            return i
        }
        return nil
    }

    /// The shortest prefix starting at `start` that parses as a dictionary
    /// plist (the reference tries growing prefixes with plistlib). A prefix is
    /// only handed to PropertyListSerialization when its last 32 bytes form a
    /// self-consistent bplist trailer (an O(1) check per end offset), and at
    /// most `maxPlistParsesPerCandidate` times per marker.
    private static func embeddedPlist(_ b: [UInt8], at start: Int) -> [String: Any]? {
        let minLen = 8 + 1 + 32
        guard b.count - start >= minLen else { return nil }
        var parses = 0
        for end in (start + minLen)...b.count {
            let t = end - 32
            let offsetSize = Int(b[t + 6]), refSize = Int(b[t + 7])
            guard [1, 2, 4, 8].contains(offsetSize), [1, 2, 4, 8].contains(refSize) else { continue }
            let count = be64(b, t + 8), tableOffset = be64(b, t + 24)
            guard count > 0, count < 1 << 20, tableOffset < UInt64(end - start),
                  tableOffset + count * UInt64(offsetSize) + 32 == UInt64(end - start) else { continue }
            guard parses < maxPlistParsesPerCandidate else { return nil }
            parses += 1
            let slice = Data(b[start..<end])
            if let d = try? PropertyListSerialization.propertyList(from: slice, format: nil) as? [String: Any] {
                return d
            }
        }
        return nil
    }

    private static func be64(_ b: [UInt8], _ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[at + $1]) }
    }
}
