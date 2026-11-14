import XCTest
@testable import Screener

final class ServerMessagesTests: XCTestCase {

    // MARK: helpers

    /// FramebufferUpdate: `00 00 u16 n_rects` + rects.
    private func fbu(_ rects: [Data]) -> Data {
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(UInt16(rects.count))
        for r in rects { w.bytes(r) }
        return w.data
    }

    /// One rect: x,y,w,h u16 + i32 encoding + payload.
    private func rect(_ enc: Int32, x: UInt16 = 0, y: UInt16 = 0, w: UInt16 = 0, h: UInt16 = 0, _ payload: Data) -> Data {
        var b = ByteWriter()
        b.u16(x); b.u16(y); b.u16(w); b.u16(h); b.u32(UInt32(bitPattern: enc))
        b.bytes(payload)
        return b.data
    }

    /// u16 length prefix + payload.
    private func prefixed(_ payload: Data) -> Data {
        var b = ByteWriter(); b.u16(UInt16(payload.count)); b.bytes(payload); return b.data
    }

    /// A valid Z_SYNC_FLUSH-framed zlib stream using one stored block
    /// (`78 01`, BFINAL=0 stored block, then the empty sync-flush block).
    private func zlibStored(_ raw: Data) -> Data {
        var b = ByteWriter()
        b.bytes([0x78, 0x01, 0x00])
        let n = UInt16(raw.count)
        b.u8(UInt8(n & 0xff)); b.u8(UInt8(n >> 8)); b.u8(UInt8(~n & 0xff)); b.u8(UInt8(~n >> 8))
        b.bytes(raw)
        b.bytes([0x00, 0x00, 0x00, 0xff, 0xff])
        return b.data
    }

    private static let keyboardPayload =
        Data(hex: "001f000100000000" + "0017") + Data("com.apple.keylayout.ABC".utf8)   // RFC §8.6

    private static let vendorPayload =
        Data(hex: "001400010004" + "1008fd00" + "1008fd01" + "1008fd02" + "1008fd03")   // RFC §8.5 / C.5

    // MARK: 0x451 fixture

    func testDisplayLayoutFixture() throws {
        let f = try Fixture.load("messages")
        let entry = f["parse_apple_display_layout"] as! [String: Any]
        let payload = Data(hex: (entry["args"] as! [String: Any])["payload"] as! String)
        let expected = entry["result"] as! [String: Any]
        let disp = (expected["displays"] as! [[String: Int]])[0]

        var p = ServerMessageParser()
        let events = try p.feed(fbu([rect(0x451, prefixed(payload))]))
        XCTAssertEqual(events.count, 1)
        guard case .displayLayout(let layout)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(layout.scaledWidth, 1920)
        XCTAssertEqual(layout.scaledHeight, 1080)
        XCTAssertEqual(layout.backingWidth, expected["backing_w"] as! Int)
        XCTAssertEqual(layout.backingHeight, expected["backing_h"] as! Int)
        XCTAssertEqual(layout.displays, [DisplayRect(displayID: UInt32(disp["display_id"]!), x: disp["x"]!, y: disp["y"]!,
                                                     width: disp["w"]!, height: disp["h"]!)])
    }

    func testDisplayLayoutTwoDisplays() throws {
        var w = ByteWriter()
        w.u16(1); w.u16(3840); w.u16(1080); w.u16(7680); w.u16(2160)
        w.bytes(Data(count: 8)); w.u16(2)
        func disp(_ id: UInt32, _ x0: UInt16, _ y0: UInt16, _ x1: UInt16, _ y1: UInt16) {
            w.bytes(Data(count: 16)); w.u32(id); w.bytes(Data(count: 8))
            w.u16(y0); w.u16(x0); w.u16(y1); w.u16(x1)
            w.bytes(Data(count: 20))
        }
        disp(1, 0, 0, 3840, 2160)
        disp(2, 3840, 0, 7680, 2160)
        XCTAssertEqual(w.data.count, 20 + 2 * 56)
        var p = ServerMessageParser()
        guard case .displayLayout(let l)? = try p.feed(fbu([rect(0x451, prefixed(w.data))])).first else { return XCTFail() }
        XCTAssertEqual(l.scaledWidth, 3840)
        XCTAssertEqual(l.backingWidth, 7680)
        XCTAssertEqual(l.displays, [DisplayRect(displayID: 1, x: 0, y: 0, width: 3840, height: 2160),
                                    DisplayRect(displayID: 2, x: 3840, y: 0, width: 3840, height: 2160)])
    }

    func testShortDisplayLayoutHasNoDisplays() throws {
        var p = ServerMessageParser()
        guard case .displayLayout(let l)? = try p.feed(fbu([rect(0x451, prefixed(Data([0, 1])))])).first else { return XCTFail() }
        XCTAssertEqual(l.displays, [], "empty displays = no change for consumers")
    }

    // MARK: metadata rects

    func testKeyboardInputSource() throws {
        var p = ServerMessageParser()
        XCTAssertEqual(Self.keyboardPayload.count, 23 + 10, "RFC §8.6: total = S + 10")
        let events = try p.feed(fbu([rect(0x455, Self.keyboardPayload)]))
        XCTAssertEqual(events, [.keyboardSource("com.apple.keylayout.ABC", secureInput: false)])
    }

    func testKeyboardInputSourceSecureFlag() throws {
        var p = ServerMessageParser()
        let payload = Data(hex: "001f000100000001" + "0017") + Data("com.apple.keylayout.ABC".utf8)
        XCTAssertEqual(try p.feed(fbu([rect(0x455, payload)])), [.keyboardSource("com.apple.keylayout.ABC", secureInput: true)])
    }

    func testVendorKeysyms() throws {
        var p = ServerMessageParser()
        XCTAssertEqual(Self.vendorPayload.count, 22)
        let events = try p.feed(fbu([rect(0x453, Self.vendorPayload)]))
        XCTAssertEqual(events, [.vendorKeysyms([0x1008FD00, 0x1008FD01, 0x1008FD02, 0x1008FD03])])
    }

    func testDeviceInfo() throws {
        // RFC §8.7 layout; per the reference the leading u16 is a length
        // prefix for the bytes that follow it.
        var body = ByteWriter()
        let model = Data("Mac16,10\0".utf8), color = Data("1\0".utf8), encl = Data("2\0".utf8)
        body.u16(2); body.u32(1); body.u32(0)
        body.u16(UInt16(model.count)); body.u16(UInt16(color.count)); body.u16(UInt16(encl.count))
        body.bytes(model); body.bytes(color); body.bytes(encl); body.u32(7)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x456, prefixed(body.data))])), [.deviceInfo(model: "Mac16,10")])
    }

    func testMetadataBurstInOneFBU() throws {
        // RFC §9.1 step 17 order: 0x451, 0x453, 0x455, 0x456, 0x450 in one FBU;
        // the cursor SELECT after the metadata rects must not be lost.
        let layout = Data(hex: "0001078004380f000870ffffffff000000000000")
        var dev = ByteWriter(); dev.u16(2); dev.u32(1); dev.u32(0); dev.u16(1); dev.u16(1); dev.u16(1)
        dev.bytes([0, 0, 0]); dev.u32(0)
        var sel = ByteWriter(); sel.u32(1000); sel.u32(0)
        var p = ServerMessageParser()
        let events = try p.feed(fbu([rect(0x451, prefixed(layout)), rect(0x453, Self.vendorPayload),
                                     rect(0x455, Self.keyboardPayload), rect(0x456, prefixed(dev.data)),
                                     rect(0x450, sel.data)]))
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.last, .cursorSelect(id: 1000))
    }

    // MARK: cursor

    func testCursorStoreSplitAcrossTwoFeeds() throws {
        // 2×2 cursor: 16 B BGRA + 4 B alpha plane (RFC §8.3)
        let bgra = Data((0..<16).map { UInt8($0) }), alpha = Data([0xff, 0x80, 0x40, 0x00])
        let z = zlibStored(bgra + alpha)
        var body = ByteWriter(); body.u32(1001); body.u32(UInt32(z.count)); body.bytes(z)
        let msg = fbu([rect(0x450, x: 3, y: 4, w: 2, h: 2, body.data)])

        var p = ServerMessageParser()
        let cut = 4 + 12 + 8 + 5   // mid-way through the zlib payload
        XCTAssertEqual(try p.feed(msg.prefix(cut)), [], "incomplete rect must wait for the next record")
        let events = try p.feed(msg.dropFirst(cut))
        XCTAssertEqual(events, [.cursorStore(id: 1001, hotspot: PixelPoint(x: 3, y: 4), size: PixelSize(width: 2, height: 2),
                                             bgra: bgra, alpha: alpha)])
        // The parser is idle again: a fresh record parses normally.
        XCTAssertEqual(try p.feed(Data(hex: "1400000400010002")), [.miscStatus(cmd: 2)])
    }

    func testRectHeaderSplitAcrossRecordsIsDropped() throws {
        // Only cursor/zlib payloads (length known) and clipboard payloads may
        // span records; a rect cut inside its 12-byte header is dropped and
        // the next record is parsed as a fresh message.
        let msg = fbu([rect(0x455, Self.keyboardPayload)])
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(msg.prefix(9)), [])
        XCTAssertEqual(try p.feed(Data(hex: "1400000400010002")), [.miscStatus(cmd: 2)])
    }

    func testCursorStoreSpanningThreeRecords() throws {
        let bgra = Data((0..<16).map { UInt8($0) }), alpha = Data([0xff, 0x80, 0x40, 0x00])
        let z = zlibStored(bgra + alpha)
        var body = ByteWriter(); body.u32(1001); body.u32(UInt32(z.count)); body.bytes(z)
        let msg = fbu([rect(0x450, x: 3, y: 4, w: 2, h: 2, body.data)])
        var p = ServerMessageParser()
        let c1 = 4 + 12 + 8 + 3, c2 = c1 + 10
        XCTAssertEqual(try p.feed(msg.prefix(c1)), [])
        XCTAssertEqual(try p.feed(msg[c1..<c2]), [])
        XCTAssertEqual(try p.feed(msg.dropFirst(c2)),
                       [.cursorStore(id: 1001, hotspot: PixelPoint(x: 3, y: 4), size: PixelSize(width: 2, height: 2),
                                     bgra: bgra, alpha: alpha)])
    }

    func testCursorCutBeforeLengthIsDropped() throws {
        // compLen not yet known (have < 8): not spannable.
        var body = ByteWriter(); body.u32(1001); body.u32(20); body.bytes(Data(count: 20))
        let msg = fbu([rect(0x450, w: 2, h: 2, body.data)])
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(msg.prefix(4 + 12 + 6)), [])
        XCTAssertEqual(try p.feed(Data([0x02])), [.bell])
    }

    func testOversizedCursorLengthIsUnknownAndAbortsRecord() throws {
        // 2x2 cursor can't need ~1 MB of compressed data: treat as corrupt.
        var body = ByteWriter(); body.u32(1001); body.u32(1_000_000); body.bytes(Data(count: 16))
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x450, w: 2, h: 2, body.data)])), [.unknown(type: 0x00, encoding: 0x450)])
        XCTAssertEqual(try p.feed(Data(hex: "1400000400010002")), [.miscStatus(cmd: 2)])
    }

    func testCursorSelect() throws {
        var body = ByteWriter(); body.u32(1000); body.u32(0)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x450, body.data)])), [.cursorSelect(id: 1000)])
    }

    func testCursorStoreSizeMismatchIsDropped() throws {
        // Reference logs + skips (no notify) when the inflated size != w*h*5;
        // the walk continues with the next rect.
        let z = zlibStored(Data(count: 7))
        var body = ByteWriter(); body.u32(1002); body.u32(UInt32(z.count)); body.bytes(z)
        var sel = ByteWriter(); sel.u32(1000); sel.u32(0)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x450, w: 2, h: 2, body.data), rect(0x450, sel.data)])),
                       [.cursorSelect(id: 1000)])
    }

    // MARK: zlib rect (0x06)

    func testZlibRectSplitAcrossThreeFeeds() throws {
        let payload = Data((0..<300).map { UInt8($0 & 0xff) })
        var body = ByteWriter(); body.u32(UInt32(payload.count)); body.bytes(payload)
        let msg = fbu([rect(6, x: 10, y: 20, w: 30, h: 40, body.data)])
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(msg.prefix(100)), [])
        XCTAssertEqual(try p.feed(msg.dropFirst(100).prefix(100)), [])
        XCTAssertEqual(try p.feed(msg.dropFirst(200)), [.zlibRect(x: 10, y: 20, w: 30, h: 40, payload: payload)])
    }

    func testZlibRectSpanningTwoRecords() throws {
        let payload = Data((0..<300).map { UInt8($0 & 0xff) })
        var body = ByteWriter(); body.u32(UInt32(payload.count)); body.bytes(payload)
        let msg = fbu([rect(6, x: 1, y: 2, w: 30, h: 40, body.data)])
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(msg.prefix(4 + 12 + 4 + 50)), [])
        XCTAssertEqual(try p.feed(msg.dropFirst(4 + 12 + 4 + 50)), [.zlibRect(x: 1, y: 2, w: 30, h: 40, payload: payload)])
    }

    func testOversizedZlibLengthIsUnknownAndAbortsRecord() throws {
        var body = ByteWriter(); body.u32(50_000_000); body.bytes(Data(count: 8))
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(6, w: 2, h: 2, body.data)])), [.unknown(type: 0x00, encoding: 6)])
        XCTAssertEqual(try p.feed(Data([0x02])), [.bell])
    }

    func testZRLESkippedByLength() throws {
        var z = ByteWriter(); z.u32(5); z.bytes([1, 2, 3, 4, 5])
        var sel = ByteWriter(); sel.u32(1000); sel.u32(0)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(16, z.data), rect(0x450, sel.data)])),
                       [.unknown(type: 0x00, encoding: 16), .cursorSelect(id: 1000)])
    }

    func testDesktopSizeHasNoPayload() throws {
        var sel = ByteWriter(); sel.u32(1000); sel.u32(0)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(-223, w: 800, h: 600, Data()), rect(0x450, sel.data)])),
                       [.cursorSelect(id: 1000)])
    }

    // MARK: record boundaries

    func testShortFBUThenSeparateMiscStatusRecord() throws {
        // FBU claims 2 rects but its record holds 1: the reference drops the
        // missing rect; the next record must parse as a fresh 0x14.
        var data = fbu([rect(0x455, Self.keyboardPayload)])
        data[3] = 2
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(data), [.keyboardSource("com.apple.keylayout.ABC", secureInput: false)])
        XCTAssertEqual(try p.feed(Data(hex: "1400000400010002")), [.miscStatus(cmd: 2)])
    }

    func testKeyboardSourceCutMidPayloadThenFreshRecord() throws {
        let msg = fbu([rect(0x455, Self.keyboardPayload)])
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(msg.prefix(4 + 12 + 10)), [])
        XCTAssertEqual(try p.feed(fbu([rect(0x455, Self.keyboardPayload)])),
                       [.keyboardSource("com.apple.keylayout.ABC", secureInput: false)])
    }

    // MARK: rekey

    func testRekeyRect() throws {
        let blob = Data((0..<36).map { UInt8($0) })
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x44f, blob)])), [.rekey(blob)])
    }

    func testStreamModeHaltsAfterRekeyAndKeepsRemainder() throws {
        // Plaintext prelude (negotiation._read_until_enc1103): 0x14 then an FBU
        // with 1103 + 1010; everything after that FBU is ciphertext.
        let blob = Data(repeating: 0xab, count: 36)
        let tail = Data(repeating: 0xcd, count: 50)
        let wire = Data(hex: "1400000400010004") + fbu([rect(0x44f, blob), rect(0x3f2, prefixed(Data([1, 2])))]) + tail
        var p = ServerMessageParser(framing: .stream)
        let events = try p.feed(wire)
        XCTAssertEqual(events, [.miscStatus(cmd: 4), .rekey(blob)], "stage-1 0x3f2 without a bplist is not an answer")
        XCTAssertEqual(p.takeRemainder(), tail)
    }

    func testStreamModeUnknownRectAfterRekeyKeepsCiphertext() throws {
        // FBU claims 2 rects but only the rekey is plaintext; the "second
        // rect" is ciphertext and must stay in the remainder untouched.
        let blob = Data(repeating: 0xab, count: 36)
        let tail = Data(repeating: 0xcd, count: 50)
        var head = fbu([rect(0x44f, blob)])
        head[3] = 2
        var p = ServerMessageParser(framing: .stream)
        XCTAssertEqual(try p.feed(head + tail), [.rekey(blob)])
        XCTAssertTrue(p.isHalted)
        XCTAssertEqual(p.takeRemainder(), tail)
    }

    // MARK: control messages

    func testMiscStatus() throws {
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(Data(hex: "1400000400010002")), [.miscStatus(cmd: 2)])
    }

    func testMiscStatusConsumesDeclaredLength() throws {
        // 14 00 u16 len, then len bytes (flags, cmd, extra) — stream framing
        // continues right after it.
        var p = ServerMessageParser(framing: .stream)
        XCTAssertEqual(try p.feed(Data(hex: "140000060001000caabb") + Data([0x02])), [.miscStatus(cmd: 12), .bell])
    }

    func testShortMiscStatusRecordDoesNotWait() throws {
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(Data(hex: "14000004")), [.unknown(type: 0x14)])
        XCTAssertEqual(try p.feed(Data([0x02])), [.bell])
    }

    func testBell() throws {
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(Data([0x02])), [.bell])
    }

    func testTopLevelMediaStreamAnswer() throws {
        let body = Data(hex: "1c000010000300000007")
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(body), [.mediaStreamAnswer(body)])
    }

    func testMediaAnswerInFBURect() throws {
        // session.py: the 0x1c answer arrives as a 0x00 FBU (embedded bplist),
        // in the 1010 (0x3f2) u16-prefixed rect.
        let blob = Data("bplist00xyz".utf8)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x3f2, prefixed(blob))])), [.mediaStreamAnswer(blob)])
    }

    func testMediaAnswerIn0x3eaRectWithBplist() throws {
        let blob = Data("..bplist00xyz".utf8)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x3ea, prefixed(blob))])), [.mediaStreamAnswer(blob)])
    }

    func testFBURectWithoutBplistIsNotAnswer() throws {
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x3f2, prefixed(Data([1, 2, 3])))])), [])
        XCTAssertEqual(try p.feed(fbu([rect(0x3f3, prefixed(Data([1, 2, 3])))])), [])
    }

    func testUnknownEncodingAbortStillFindsBplist() throws {
        // The reference searches the whole FBU for a bplist regardless of
        // encoding; the abort path reports the rest of the record if it has one.
        let r = rect(0x7777, Data("zzbplist00abc".utf8))
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([r])), [.unknown(type: 0x00, encoding: 0x7777), .mediaStreamAnswer(r)])
    }

    func testClipboardSendSpanningRecords() throws {
        let c = try Fixture.load("clipboard")
        let full = Data(hex: c["build_clipboard_send"] as! String)
        let rt = c["roundtrip"] as! [String: Any]
        let compressed = full.dropFirst(16)
        var p = ServerMessageParser()
        let e1 = try p.feed(full.prefix(30))
        let e2 = try p.feed(full.dropFirst(30))
        let header = ClipboardSendHeader(promise: 0, reserved: 0, uncompressedSize: 53, compressedSize: 53)
        XCTAssertEqual(e1, [.clipboard(header: header, payloadChunk: Data(full[16..<30]))])
        XCTAssertEqual(e2, [.clipboard(header: header, payloadChunk: Data(full.dropFirst(30)))])
        XCTAssertEqual(try Zlib.inflate(Data(compressed)).hex, rt["decompressed"] as! String)
        XCTAssertEqual(try p.feed(Data(hex: "1400000400010002")), [.miscStatus(cmd: 2)], "reassembly finished")
    }

    // MARK: unknowns (RFC §12)

    func testUnknownEncodingDiscardsRestOfRecord() throws {
        // session._handle_fbu: an unknown encoding has no length, so the walk
        // aborts and the rest of that record (including the following valid
        // 0x455) is dropped. The next record parses normally.
        var p = ServerMessageParser()
        let events = try p.feed(fbu([rect(0x7777, Data([1, 2, 3, 4])), rect(0x455, Self.keyboardPayload)]))
        XCTAssertEqual(events, [.unknown(type: 0x00, encoding: 0x7777)])
        XCTAssertEqual(try p.feed(fbu([rect(0x455, Self.keyboardPayload)])),
                       [.keyboardSource("com.apple.keylayout.ABC", secureInput: false)])
    }

    func testUnknownMessageType() throws {
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(Data([0x99, 1, 2, 3])), [.unknown(type: 0x99)])
        XCTAssertEqual(try p.feed(Data([0x02])), [.bell])
    }

    func testIgnoredKnownEncodingsAreSkipped() throws {
        // 0x3ea is skipped via its u16 prefix (session._handle_fbu) with no event.
        var sel = ByteWriter(); sel.u32(1000); sel.u32(0)
        var p = ServerMessageParser()
        XCTAssertEqual(try p.feed(fbu([rect(0x3ea, prefixed(Data([9, 9, 9]))), rect(0x450, sel.data)])),
                       [.cursorSelect(id: 1000)])
    }
}
