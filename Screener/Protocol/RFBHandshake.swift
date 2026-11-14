// Ported from iShareScreen src/isharescreen/proxy/protocol/rfb.py
// (do_protocol_handshake) and proxy/protocol/negotiation.py
// (_open_socket_and_handshake, _phase_client_init) (AGPL-3.0)
//
// The cleartext RFB steps either side of authentication:
//   * `negotiate`: RFC §4.1.2/§4.1.3 — server banner, client banner, the
//     security-type list. Stops BEFORE the selector byte, which `Authenticator`
//     sends coalesced with the RSA1 key request (see the byte-boundary
//     contract on `Authenticator`).
//   * `clientInit`: RFC §5.2/§5.3 — after SecurityResult 0, send ClientInit
//     `0xC1` and read ServerInit.
//
// Deviations from the reference, which reads and ignores both banners and
// the type list and lets auth fail later: we close early (RFC §3.2 S1/S2/S3)
// on a non-`003.889` banner, a count-0 failure list (reading the RFB 3.8
// reason string if one follows), or a list without type 33.
import Foundation

enum RFBHandshakeError: Error, Equatable {
    /// The server's banner was not `RFB 003.889` (RFC §4.1.2).
    case unsupportedVersion(String)
    /// Count-0 security-type list (RFC §4.1.3), with the server's reason if sent.
    case serverRefused(reason: String?)
    /// Type 33 (RSA1/SRP) was not offered.
    case unsupported(offered: [UInt8])
    case malformedServerInit
}

/// RFC §5.3 ServerInit.
struct ServerInit: Sendable, Equatable {
    var width: Int
    var height: Int
    /// The raw 16-byte RFB PIXEL_FORMAT (unused in HP mode, kept for logs).
    var pixelFormat: Data
    var name: String
}

enum RFBHandshake {
    /// RFC §4.1.2: both directions send exactly these 12 bytes (rfb.PROTOCOL_VERSION).
    static let protocolVersion = Data("RFB 003.889\n".utf8)
    /// RSA1 / SRP (RFC §4.2.4).
    static let securityTypeRSA1: UInt8 = 33
    /// RFC §5.2: shared-flag byte `0x80 | 0x40 | 0x01`.
    static let clientInitFlag: UInt8 = 0xC1

    private static let maxReasonLength = 4096
    private static let maxNameLength = 64 * 1024

    /// rfb.do_protocol_handshake. Returns the advertised security types
    /// (wire order) after verifying 33 is among them. The stream is left
    /// positioned for `Authenticator` to send the `0x21` selector.
    static func negotiate(_ s: ByteStream) async throws -> [UInt8] {
        let banner = try await s.read(exactly: 12)
        guard banner == protocolVersion else {
            let text = String(decoding: banner.prefix { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self)
            throw RFBHandshakeError.unsupportedVersion(text)
        }
        try await s.write(protocolVersion)

        let count = Int(try await s.read(exactly: 1)[0])
        guard count > 0 else {
            throw RFBHandshakeError.serverRefused(reason: await readFailureReason(s))
        }
        let types = [UInt8](try await s.read(exactly: count))
        Log.control.info("security types offered: \(types.map(String.init).joined(separator: ","))")
        guard types.contains(securityTypeRSA1) else { throw RFBHandshakeError.unsupported(offered: types) }
        return types
    }

    /// negotiation._phase_client_init: send ClientInit, read ServerInit
    /// (`u16 w, u16 h, byte[16] pixel_format, u32 name_len, name`).
    static func clientInit(_ s: ByteStream) async throws -> ServerInit {
        try await s.write(Data([clientInitFlag]))
        var r = ByteReader(try await s.read(exactly: 24))
        let w = Int(try r.u16()), h = Int(try r.u16())
        let pf = try r.bytes(16)
        let nameLen = Int(try r.u32())
        guard nameLen <= maxNameLength else { throw RFBHandshakeError.malformedServerInit }
        let name = nameLen > 0 ? String(decoding: try await s.read(exactly: nameLen), as: UTF8.self) : ""
        Log.control.info("ServerInit: \(w)x\(h)")
        return ServerInit(width: w, height: h, pixelFormat: pf, name: name)
    }

    /// RFB 3.8 failure list: `u32 len || reason`. Best effort — a server that
    /// closes instead yields nil.
    private static func readFailureReason(_ s: ByteStream) async -> String? {
        guard let lenBytes = try? await s.read(exactly: 4) else { return nil }
        var r = ByteReader(lenBytes)
        guard let len = try? r.u32(), len > 0, len <= maxReasonLength,
              let text = try? await s.read(exactly: Int(len)) else { return nil }
        return String(decoding: text, as: UTF8.self)
    }
}
