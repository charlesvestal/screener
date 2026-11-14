import XCTest
@testable import Screener

final class MediaOfferTests: XCTestCase {
    private var fx: [String: Any] = [:]
    private var args: [String: Any] { fx["args"] as! [String: Any] }

    /// The RemoteEndpointInfo strings the fixture-generating host reported
    /// (`sysctl -n hw.model`, `sw_vers -buildVersion` on a Mac mini), plus
    /// the reference's client-name string (`f"iShareScreen {__version__}"`).
    private let fixtureEndpoint = MediaOffer.EndpointInfo(hardwareModel: "Macmini9,1", avcVersion: "1.0.0", osBuild: "26A428")
    private let fixtureClientName = "iShareScreen 0.1.0"

    override func setUpWithError() throws {
        fx = try Fixture.load("media_offer")
    }

    private func hexArg(_ key: String) -> Data { Data(hex: fx[key] as! String) }

    private func fixtureOffers() throws -> (audio: Data, video: Data) {
        let callID = try XCTUnwrap(UUID(uuidString: args["fixed_call_id_uuid"] as! String))
        return try MediaOffer.create(
            sessionID: UInt32((args["fixed_session_id"] as! NSNumber).uint32Value),
            timestamp: (args["fixed_timestamp_ns"] as! NSNumber).uint64Value,
            callID: callID,
            audioEnabled: args["audio_enabled"] as! Bool,
            endpoint: fixtureEndpoint,
            clientName: fixtureClientName)
    }

    private func fixtureKeys() -> NegotiationKeys {
        let k = args["keys"] as! [String: String]
        return NegotiationKeys(audioKeyV: Data(hex: k["audio_key_v"]!), audioKeyS: Data(hex: k["audio_key_s"]!),
                               videoKeyV: Data(hex: k["video_key_v"]!), videoKeyS: Data(hex: k["video_key_s"]!))
    }

    func testOffersMatchFixture() throws {
        let offers = try fixtureOffers()
        XCTAssertEqual(offers.video.hex, hexArg("video_offer").hex)
        XCTAssertEqual(offers.audio.hex, hexArg("audio_offer").hex)
    }

    func testExtractOfferSSRC() throws {
        let sid = UInt32((args["fixed_session_id"] as! NSNumber).uint32Value)
        XCTAssertEqual(MediaOffer.extractSSRC(hexArg("video_offer"), isVideo: true), sid)
        XCTAssertEqual(MediaOffer.extractSSRC(hexArg("audio_offer"), isVideo: false), sid)
        XCTAssertNil(MediaOffer.extractSSRC(Data("junk".utf8), isVideo: true))
    }

    func testMsg1cMatchesFixture() throws {
        let callID = try XCTUnwrap(UUID(uuidString: args["fixed_call_id_uuid"] as! String))
        let msg = MediaStreamOptions.build(keys: fixtureKeys(),
                                           audioOffer: hexArg("audio_offer"), videoOffer: hexArg("video_offer"),
                                           uuid: callID, flags: MediaStreamOptions.configFlags(altSession: false))
        XCTAssertEqual(msg.hex, hexArg("msg_1c").hex)
        // Flags word at +0x06 is big-endian 00 00 00 07 (reference, not RFC §10.3).
        XCTAssertEqual(Array(msg[6..<10]), [0, 0, 0, 7])
        XCTAssertEqual(MediaStreamOptions.configFlags(altSession: true), 5)
    }

    func testParseAnswerFixture() throws {
        let r = fx["extract_canvas_dims_result"] as! [String: Int]
        let answer = try MediaStreamOptions.parseAnswer(hexArg("answer_msg"))
        XCTAssertEqual(answer.canvasWidth, r["cw"])
        XCTAssertEqual(answer.canvasHeight, r["ch"])
        XCTAssertEqual(answer.tiles, r["ct"])
    }

    /// The same answer as ServerMessages delivers it from a 0x3f2 FBU rect:
    /// the u16-prefixed rect payload with FBU/rect headers stripped, so the
    /// bplist has no leading 0x00 (unlike the reference's whole-FBU input).
    func testParseAnswerFromFBURectPayload() throws {
        let bplist = Data(hexArg("answer_msg").dropFirst())
        var inner = Data([0x01, 0x02, 0x03]); inner.append(bplist); inner.append(contentsOf: [0xAA, 0xBB])
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(1)                                   // FBU, 1 rect
        w.u16(0); w.u16(0); w.u16(0); w.u16(0); w.u32(0x3F2)         // rect header, enc 1010
        w.u16(UInt16(inner.count)); w.bytes(inner)                   // u16-prefixed payload
        var parser = ServerMessageParser()
        let events = try parser.feed(w.data)
        guard case .mediaStreamAnswer(let payload)? = events.first else { return XCTFail("\(events)") }
        let a = try MediaStreamOptions.parseAnswer(payload)
        XCTAssertEqual([a.canvasWidth, a.canvasHeight, a.tiles], [3840, 2160, 4])

        // Top-level 0x1c record shape: a 0x1c header then the bplist.
        var top = Data([0x1c, 0x00, 0x01, 0x00]); top.append(bplist)
        let b = try MediaStreamOptions.parseAnswer(top)
        XCTAssertEqual([b.canvasWidth, b.canvasHeight, b.tiles], [3840, 2160, 4])
    }

    func testParseAnswerWithoutCanvasThrows() {
        XCTAssertThrowsError(try MediaStreamOptions.parseAnswer(Data([0x00, 0x01, 0x02])))
        XCTAssertThrowsError(try MediaStreamOptions.parseAnswer(Data()))
    }

    func testEndpointModelOverride() {
        setenv("SCREENER_ENDPOINT_MODEL", "Mac16,10", 1)
        defer { unsetenv("SCREENER_ENDPOINT_MODEL") }
        XCTAssertEqual(MediaOffer.EndpointInfo.current.hardwareModel, "Mac16,10")
    }

    func testRandomKeys() {
        let k = NegotiationKeys.random()
        let all = [k.audioKeyV, k.audioKeyS, k.videoKeyV, k.videoKeyS]
        XCTAssertTrue(all.allSatisfy { $0.count == 46 })
        XCTAssertEqual(Set(all).count, 4)
        XCTAssertNotEqual(NegotiationKeys.random().audioKeyV, k.audioKeyV)
    }

    func testRandomOffersDecodeAndDiffer() throws {
        let a = try MediaOffer.create(audioEnabled: true)
        let b = try MediaOffer.create(audioEnabled: true)
        XCTAssertNotEqual(a.video, b.video)
        XCTAssertNotNil(MediaOffer.extractSSRC(a.video, isVideo: true))
        XCTAssertNotNil(MediaOffer.extractSSRC(a.audio, isVideo: false))
    }
}

final class BinaryPlistTests: XCTestCase {
    // Expected bytes produced by CPython 3 `plistlib.dumps(v, fmt=FMT_BINARY)`.
    func testMatchesPlistlibMixed() {
        let v: BinaryPlist.Value = .dict([
            "b": .bool(true), "a": .bool(false), "z": .array([.int(1), .int(2), .int(1)]),
            "u": .string("héllo"), "d": .data(Data(repeating: 0x78, count: 20)),
            "n": .int(300), "m": .int(70000), "big": .int(1 << 40), "neg": .int(-5),
        ])
        XCTAssertEqual(BinaryPlist.encode(v).hex, "62706c6973743030d90102030405060708090a0b0c0d0e0f10111251615162536269675164516d516e536e65675175517a08091300000100000000004f10147878787878787878787878787878787878787878120001117011012c13fffffffffffffffb65006800e9006c006c006fa313141310011002081b1d1f232527292d2f3132333c53585b646f73750000000000000101000000000000001500000000000000000000000000000077")
    }

    func testMatchesPlistlibNested() {
        let v: BinaryPlist.Value = .dict(["k": .dict(["inner": .string("v")]), "list": .array([.string("v"), .string("v")])])
        XCTAssertEqual(BinaryPlist.encode(v).hex, "62706c6973743030d201020306516b546c697374d1040555696e6e65725176a20505080d0f14171d1f0000000000000101000000000000000700000000000000000000000000000022")
    }
}
