// Ported from iShareScreen src/isharescreen/proxy/protocol/rfb.py,
// proxy/protocol/negotiation.py, proxy/protocol/apple.py,
// proxy/protocol/clipboard.py and proxy/input.py (AGPL-3.0)
//
// Client→server control-channel messages. Every builder returns the plaintext
// message body; after the rekey the caller seals it with `RecordLayer`.
// Byte layouts match the reference byte-for-byte (ScreenerTests/Fixtures).
import Foundation

/// RFC §5.6 SetEncryptionMessage command values.
enum SetEncryptionCommand: UInt16, Sendable {
    /// `command = 1`: full form carrying the method list (AES-128). Same bytes
    /// as the reference's `APPLE_0X12_FOLLOWUP`.
    case start = 1
    /// `command = 2`: short form. Same bytes as `build_post_encryption_toggle`.
    case stop = 2
}

enum ClientMessage {
    // Message types (rfb.py CLI_*, plus the Apple-private ones from RFC §8.2).
    static let typeSetEncodings: UInt8 = 0x02
    static let typeFramebufferUpdateRequest: UInt8 = 0x03
    static let typeKeyEvent: UInt8 = 0x04
    static let typePointerEvent: UInt8 = 0x05
    static let typeClientCutText: UInt8 = 0x06
    static let typeScaleFactor: UInt8 = 0x08
    static let typeAutoFramebufferUpdate: UInt8 = 0x09
    static let typeSetMode: UInt8 = 0x0a
    static let typeClipboardRequest: UInt8 = 0x0b
    static let typeSetDisplay: UInt8 = 0x0d
    static let typeEncryptedEvent: UInt8 = 0x10
    static let typeSetEncryption: UInt8 = 0x12
    static let typeAutoPasteboard: UInt8 = 0x15
    static let typeSetDisplayConfiguration: UInt8 = 0x1d
    static let typeViewerInfo: UInt8 = 0x21

    /// rfb.HP_ENCODINGS_FULL. -239 (RichCursor) is intentionally absent; the
    /// cached-cursor pseudo-encoding 1104 (0x450) is used instead.
    static let hpEncodingsFull: [Int32] = [
        1010, 1011, 1002, 6, 16, 1104, 1100,
        -223, 1101, 1105, 1107, 1109, 1110,
    ]

    /// TCP-only fallback (Task 19, RFC §11 Profile A / §12): zlib (6) and
    /// raw (0) — the only pixel encodings ZlibRectDecoder decodes — then the
    /// pseudo-encodings the session needs: 0x450 cursor, 0x451 layout, 0x453
    /// vendor keysyms, 0x455 keyboard source, 0x456 device info, 0x44f
    /// rekey. NO 0x3f2 (media init), 0x3f3 / 0x3ea (Apple codecs we can't
    /// decode) or ZRLE (16): R-A18 / R-B4.
    static let framebufferEncodings: [Int32] = [6, 0, 0x450, 0x451, 0x453, 0x455, 0x456, 0x44F]

    /// Apple's non-standard pointer button mask (bits 1/2 swapped vs RFC 6143).
    enum Button {
        static let left: UInt8 = 1 << 0
        static let right: UInt8 = 1 << 1
        static let middle: UInt8 = 1 << 2
        static let scrollUp: UInt8 = 1 << 3
        static let scrollDown: UInt8 = 1 << 4
    }

    /// apple._build_apple_viewer_command_mask: the 32-byte ViewerInfo feature
    /// bitmap Screen Sharing.app sends.
    static let appleViewerCommandMask: Data = {
        var m = [UInt8](repeating: 0, count: 32)
        m[0] = 0xb0; m[2] = 0x0c; m[3] = 0x03; m[4] = 0x90; m[10] = 0x40
        return Data(m)
    }()

    /// apple.APPLE_VIEWER_OS_VER
    static let appleViewerOSVersion: (UInt32, UInt32, UInt32) = (15, 3, 0)

    // MARK: standard RFB

    /// rfb.build_set_encodings
    static func setEncodings(_ encodings: [Int32] = hpEncodingsFull) -> Data {
        var w = ByteWriter(capacity: 4 + 4 * encodings.count)
        w.u8(typeSetEncodings); w.u8(0); w.u16(UInt16(encodings.count))
        for e in encodings { w.u32(UInt32(bitPattern: e)) }
        return w.data
    }

    /// RFC 6143 §7.5.1 SetPixelFormat: `00 pad×3 PIXEL_FORMAT(16)`.
    static func setPixelFormat(_ format: RFBPixelFormat) -> Data {
        var w = ByteWriter(capacity: 20)
        w.u8(0); w.zeros(3); w.bytes(format.data)
        return w.data
    }

    /// negotiation.build_fbu_request
    static func framebufferUpdateRequest(incremental: Bool, x: UInt16 = 0, y: UInt16 = 0,
                                         w: UInt16 = 0xFFFF, h: UInt16 = 0xFFFF) -> Data {
        var b = ByteWriter(capacity: 10)
        b.u8(typeFramebufferUpdateRequest); b.u8(incremental ? 1 : 0)
        b.u16(x); b.u16(y); b.u16(w); b.u16(h)
        return b.data
    }

    /// rfb.build_key_event (X11 keysym)
    static func keyEvent(down: Bool, keysym: UInt32) -> Data {
        var w = ByteWriter(capacity: 8)
        w.u8(typeKeyEvent); w.u8(down ? 1 : 0); w.zeros(2); w.u32(keysym)
        return w.data
    }

    /// rfb.build_pointer_event. Buttons are masked to 8 bits, coordinates
    /// clamped to u16.
    static func pointerEvent(buttons: Int, x: Int, y: Int) -> Data {
        var w = ByteWriter(capacity: 6)
        w.u8(typePointerEvent); w.u8(UInt8(buttons & 0xFF)); w.u16(clampU16(x)); w.u16(clampU16(y))
        return w.data
    }

    /// RFC 6143 §7.5.6 ClientCutText: Latin-1 text; characters outside
    /// Latin-1 become "?". (The reference sends clipboard text via 0x1f
    /// instead — see Task 17 — because the daemon routes 0x06 to the legacy
    /// scrap only.)
    static func clientCutText(_ text: String) -> Data {
        let latin1 = text.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") }
        var w = ByteWriter(capacity: 8 + latin1.count)
        w.u8(typeClientCutText); w.zeros(3); w.u32(UInt32(latin1.count)); w.bytes(latin1)
        return w.data
    }

    // MARK: Apple private

    /// RFC §8.10 ScaleFactor: `08 00 || f64_be scale`.
    static func scaleFactor(_ scale: Double) -> Data {
        var w = ByteWriter(capacity: 10)
        w.u8(typeScaleFactor); w.u8(0); w.f64(scale)
        return w.data
    }

    /// negotiation.build_auto_framebuffer_update (16 bytes). Region is the
    /// backing (pixel) size.
    static func autoFramebufferUpdate(w width: UInt16, h height: UInt16) -> Data {
        var w = ByteWriter(capacity: 16)
        w.u8(typeAutoFramebufferUpdate); w.zeros(2); w.u8(1)
        w.u32(0xFFFF_FFFF); w.u32(0)
        w.u16(width); w.u16(height)
        return w.data
    }

    /// RFC §5.7 SetMode: `0a 00 u16 mode` (0 = observe, 1 = control).
    static func setMode(_ mode: UInt16) -> Data {
        var w = ByteWriter(capacity: 4)
        w.u8(typeSetMode); w.u8(0); w.u16(mode)
        return w.data
    }

    /// clipboard.build_clipboard_request (8 bytes; 9 would desync the daemon).
    static func clipboardFetch(promiseOnly: Bool = false) -> Data {
        var w = ByteWriter(capacity: 8)
        w.u8(typeClipboardRequest); w.u8(promiseOnly ? 1 : 0); w.zeros(6)
        return w.data
    }

    /// RFC §7.4 SetDisplayMessage: `0d || u8 combine_all || u16 0 || u32 display_id`.
    static func setDisplay(combineAll: Bool, displayID: UInt32 = 0) -> Data {
        var w = ByteWriter(capacity: 8)
        w.u8(typeSetDisplay); w.u8(combineAll ? 1 : 0); w.u16(0); w.u32(displayID)
        return w.data
    }

    /// input._build_msg10_pointer: msg 0x10 EncryptedEventMessage wrapping a
    /// pointer event, AES-128-ECB under the record layer's content key
    /// (`RecordLayer.contentKey`). Plaintext: 10 zero bytes, 0xff sentinel,
    /// buttons, u16 x, u16 y. The reference has no encrypted *key* event
    /// builder (keys go as plain 0x04 KeyEvent), so none is ported.
    static func encryptedPointerEvent(key: Data, buttons: Int, x: Int, y: Int) throws -> Data {
        var p = ByteWriter(capacity: 16)
        p.zeros(10); p.u8(0xff); p.u8(UInt8(buttons & 0xff))
        p.u16(UInt16(truncatingIfNeeded: x)); p.u16(UInt16(truncatingIfNeeded: y))
        let ct = try AES.ecbEncrypt(key: key.prefix(16), block: p.data)
        var w = ByteWriter(capacity: 18)
        w.u8(typeEncryptedEvent); w.u8(0); w.bytes(ct)
        return w.data
    }

    /// RFC §5.6 SetEncryptionMessage.
    static func setEncryption(command: SetEncryptionCommand) -> Data {
        var w = ByteWriter(capacity: 12)
        w.u8(typeSetEncryption); w.u8(0); w.u16(command.rawValue)
        switch command {
        case .start: w.u16(1); w.u16(1); w.u32(1)    // method_count=1, method=1 (AES-128), trailer=1
        case .stop: w.u16(1); w.u16(0)
        }
        return w.data
    }

    /// clipboard.build_auto_pasteboard_msg: `15 00 u16 selector 00000000`
    /// (RFC §8.12: 1 = start monitoring, 2 = stop).
    static func autoPasteboard(selector: UInt16 = 1) -> Data {
        var w = ByteWriter(capacity: 8)
        w.u8(typeAutoPasteboard); w.u8(0); w.u16(selector); w.zeros(4)
        return w.data
    }

    /// rfb.build_virtual_display — 0x1d SetDisplayConfiguration.
    ///
    /// `logicalWidth/Height` are the point size; the mode table advertises
    /// `point × hidpiScale` backing pixels. `dynamic: true` (the reference's
    /// only form, and native Screen Sharing.app's) sets display_flags=1,
    /// display_type=4 and reserved/rotations=7 — required for an in-band
    /// resize (RFC §7.3). `dynamic: false` emits the bare descriptor RFC §7.3
    /// describes for fixed-resolution sessions (those three fields zero).
    /// The fixture uses the reference's default display name; ours differs.
    /// `maxWidth`/`maxHeight`: the descriptor's backing bound (the reference
    /// and native send 3840×2160; a portrait request swaps them, see
    /// DisplayGeometry.maxBacking).
    static func setDisplayConfiguration(logicalWidth: Int, logicalHeight: Int, hidpiScale: Double = 2.0,
                                        refreshHz: Double = 60.0, hdr: Bool = false, dynamic: Bool = true,
                                        displayName: String = "Screener Virtual Display",
                                        modeCount: Int = 5, maxWidth: Int = 3840, maxHeight: Int = 2160) -> Data {
        let diSize = 0x9C + 28 * modeCount
        var di = [UInt8](repeating: 0, count: diSize)
        func put16(_ off: Int, _ v: UInt16) { di[off] = UInt8(v >> 8); di[off + 1] = UInt8(v & 0xff) }
        func put32(_ off: Int, _ v: UInt32) { for i in 0..<4 { di[off + i] = UInt8((v >> (24 - 8 * i)) & 0xff) } }
        func put64(_ off: Int, _ v: UInt64) { put32(off, UInt32(v >> 32)); put32(off + 4, UInt32(v & 0xffff_ffff)) }

        put16(0x00, UInt16(diSize))
        // Name region D+0x02..+0x79; capped at 119 bytes so a NUL fits at +0x79.
        let name = Array(displayName.utf8.prefix(119))
        di.replaceSubrange(0x02..<0x02 + name.count, with: name)
        put32(0x7A, dynamic ? 1 : 0)            // display_flags: DYNAMIC_RESOLUTION
        put32(0x7E, dynamic ? 4 : 0)            // display_type: 4 = virtual display
        put32(0x82, Float(369.4545593261719).bitPattern)   // physical mm (native capture)
        put32(0x86, Float(207.81817626953125).bitPattern)
        put32(0x8A, UInt32(maxWidth)); put32(0x8E, UInt32(maxHeight))   // max backing size (server cap)
        put16(0x92, 0); put16(0x94, 0)          // current / preferred mode index
        put32(0x96, dynamic ? 7 : 0)            // reserved/rotations — native sends 7
        put16(0x9A, UInt16(modeCount))

        // Native kModes template (backing w,h, point w,h), scaled to the target.
        let nativeModes: [(Int, Int, Int, Int)] = [
            (3840, 2160, 1920, 1080), (2880, 1800, 1440, 900), (3840, 2160, 1920, 1080),
            (2880, 1620, 1440, 810), (2624, 1696, 1312, 848),
        ]
        let sx = logicalWidth != 0 ? Double(logicalWidth) / 1920.0 : 1.0
        let sy = logicalHeight != 0 ? Double(logicalHeight) / 1080.0 : 1.0
        for i in 0..<modeCount {
            let base = nativeModes[i % nativeModes.count]
            let msw = Int(Double(base.2) * sx + 0.5), msh = Int(Double(base.3) * sy + 0.5)
            let mw = Int(Double(msw) * hidpiScale + 0.5), mh = Int(Double(msh) * hidpiScale + 0.5)
            let m = 0x9C + 28 * i
            put32(m + 0x00, UInt32(mw)); put32(m + 0x04, UInt32(mh))
            put32(m + 0x08, UInt32(msw)); put32(m + 0x0C, UInt32(msh))
            put64(m + 0x10, refreshHz.bitPattern)
            put32(m + 0x18, hdr ? 1 : 0)
        }

        var w = ByteWriter(capacity: 12 + diSize)
        w.u8(typeSetDisplayConfiguration); w.u8(0)
        w.u16(UInt16(8 + diSize))   // message_size: bytes after this field
        w.u16(1)                    // version
        w.u16(1)                    // display_count
        w.u32(0)                    // flags
        w.bytes(di)
        return w.data
    }

    /// rfb.build_viewer_info — 0x21 ViewerInfo.
    static func viewerInfo(appID: UInt32 = 2, appVersion: (UInt32, UInt32, UInt32) = (6, 1, 0),
                           osVersion: (UInt32, UInt32, UInt32) = appleViewerOSVersion,
                           commandMask: Data = appleViewerCommandMask, extra: Data = Data()) -> Data {
        precondition(commandMask.count == 32, "command_mask must be exactly 32 bytes")
        var w = ByteWriter(capacity: 66 + extra.count)
        w.u8(typeViewerInfo); w.u8(0)
        w.u16(UInt16(0x3E + extra.count))   // msgSize: bytes after this field
        w.u16(1)                            // msgVersion
        w.u32(appID)
        w.u32(appVersion.0); w.u32(appVersion.1); w.u32(appVersion.2)
        w.u32(osVersion.0); w.u32(osVersion.1); w.u32(osVersion.2)
        w.bytes(commandMask); w.bytes(extra)
        return w.data
    }

    private static func clampU16(_ v: Int) -> UInt16 { UInt16(max(0, min(0xFFFF, v))) }
}
