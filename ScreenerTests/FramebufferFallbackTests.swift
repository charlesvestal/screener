import XCTest
@testable import Screener

/// TCP-only fallback (Task 19): the fallback policy, the fallback
/// SetEncodings, the parser's framebuffer mode and ControlSession's
/// framebuffer path against the scripted fake server.
final class FramebufferFallbackTests: XCTestCase {

    // MARK: MediaFallbackPolicy

    func testNoAuthenticatedVideoFallsBackAtOnce() {
        var p = MediaFallbackPolicy()
        XCTAssertEqual(p.burstStarved(packets: 0, attempt: 1, attempts: 3), .fallBack(.noVideo(packets: 0)))
        XCTAssertTrue(p.isFallenBack)
        // Once fallen back, nothing else triggers.
        XCTAssertEqual(p.negotiationFailed(), .stay)
        XCTAssertEqual(p.decoderFailed(at: .now), .stay)
    }

    func testPartialBurstRetriesThenFallsBackOnTheLastAttempt() {
        var p = MediaFallbackPolicy()
        XCTAssertEqual(p.burstStarved(packets: 5, attempt: 1, attempts: 3), .retryHandshake)
        XCTAssertEqual(p.burstStarved(packets: 7, attempt: 2, attempts: 3), .retryHandshake)
        XCTAssertFalse(p.isFallenBack)
        XCTAssertEqual(p.burstStarved(packets: 9, attempt: 3, attempts: 3), .fallBack(.noVideo(packets: 9)))
    }

    func testNegotiationFailureFallsBack() {
        var p = MediaFallbackPolicy()
        XCTAssertEqual(p.negotiationFailed(), .fallBack(.negotiationFailed))
    }

    func testThreeDecoderFailuresWithinTenSecondsFallBack() {
        var p = MediaFallbackPolicy()
        let t0 = ContinuousClock.now
        XCTAssertEqual(p.decoderFailed(at: t0), .stay)
        XCTAssertEqual(p.decoderFailed(at: t0 + .seconds(4)), .stay)
        XCTAssertEqual(p.decoderFailed(at: t0 + .seconds(9)), .fallBack(.decoderFailures(3)))
    }

    func testDecoderFailuresOutsideTheWindowDoNot() {
        var p = MediaFallbackPolicy()
        let t0 = ContinuousClock.now
        XCTAssertEqual(p.decoderFailed(at: t0), .stay)
        XCTAssertEqual(p.decoderFailed(at: t0 + .seconds(6)), .stay)
        XCTAssertEqual(p.decoderFailed(at: t0 + .seconds(12)), .stay)   // the first one expired
        XCTAssertEqual(p.decoderFailed(at: t0 + .seconds(13)), .fallBack(.decoderFailures(3)))
        p.reset()
        XCTAssertFalse(p.isFallenBack)
        XCTAssertEqual(p.decoderFailed(at: t0 + .seconds(14)), .stay)
    }

    // MARK: SetEncodings / SetPixelFormat

    /// R-A18: only what we decode (zlib, raw) plus the needed pseudo-encodings.
    func testFallbackEncodingsAdvertiseOnlyDecodableEncodings() {
        let e = ClientMessage.framebufferEncodings
        XCTAssertEqual(e, [6, 0, 0x450, 0x451, 0x453, 0x455, 0x456, 0x44F])
        for undecodable: Int32 in [0x3F2, 0x3F3, 0x3EA, 0x3E8, 0x3E9, 16] { XCTAssertFalse(e.contains(undecodable)) }
        XCTAssertEqual(ClientMessage.setEncodings(e).hex,
                       "02000008" + "00000006" + "00000000" + "00000450" + "00000451"
                       + "00000453" + "00000455" + "00000456" + "0000044f")
    }

    func testSetPixelFormatBytes() {
        XCTAssertEqual(ClientMessage.setPixelFormat(.bgra32).hex, "00000000" + "2018000100ff00ff00ff100800000000")
    }

    func testIncrementalRequestCoversTheBacking() {
        XCTAssertEqual(ControlSession.framebufferRequest(backing: (2752, 2064)),
                       ClientMessage.framebufferUpdateRequest(incremental: true, w: 2752, h: 2064))
        XCTAssertEqual(ControlSession.framebufferRequest(backing: nil),
                       ClientMessage.framebufferUpdateRequest(incremental: true))
    }

    // MARK: parser framebuffer mode

    private func fbu(_ rects: [Data]) -> Data {
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(UInt16(rects.count))
        for r in rects { w.bytes(r) }
        return w.data
    }

    private func rect(_ enc: Int32, x: UInt16 = 0, y: UInt16 = 0, w: UInt16, h: UInt16, _ payload: Data) -> Data {
        var b = ByteWriter()
        b.u16(x); b.u16(y); b.u16(w); b.u16(h); b.u32(UInt32(bitPattern: enc))
        b.bytes(payload)
        return b.data
    }

    func testRawRectsAndUpdateEndOnlyInFramebufferMode() throws {
        let px = Data((0..<16).map { UInt8($0) })
        let msg = fbu([rect(0, x: 1, y: 2, w: 2, h: 2, px)])
        var hp = ServerMessageParser()
        XCTAssertEqual(try hp.feed(msg), [.unknown(type: 0, encoding: 0)])   // as before

        var fb = ServerMessageParser()
        fb.framebufferMode = true
        XCTAssertEqual(try fb.feed(msg), [.rawRect(x: 1, y: 2, w: 2, h: 2, pixels: px), .framebufferUpdateEnd])
        // An FBU with only pseudo-encodings still ends.
        var sel = ByteWriter(); sel.u32(1000); sel.u32(0)
        XCTAssertEqual(try fb.feed(fbu([rect(0x450, w: 0, h: 0, sel.data)])), [.cursorSelect(id: 1000), .framebufferUpdateEnd])
        // So does one aborted on an unknown encoding.
        XCTAssertEqual(try fb.feed(fbu([rect(0x7777, w: 1, h: 1, Data([9, 9]))])),
                       [.unknown(type: 0, encoding: 0x7777), .framebufferUpdateEnd])
    }

    func testRawRectSpansRecords() throws {
        let px = Data((0..<400).map { UInt8($0 & 0xff) })
        let msg = fbu([rect(0, w: 10, h: 10, px)])
        var p = ServerMessageParser()
        p.framebufferMode = true
        XCTAssertEqual(try p.feed(msg.prefix(100)), [])
        XCTAssertEqual(try p.feed(msg.dropFirst(100)), [.rawRect(x: 0, y: 0, w: 10, h: 10, pixels: px), .framebufferUpdateEnd])
    }

    func testHostileRawRectAbortsTheRecord() throws {
        var p = ServerMessageParser()
        p.framebufferMode = true
        XCTAssertEqual(try p.feed(fbu([rect(0, w: 65535, h: 65535, Data(count: 8))])),
                       [.unknown(type: 0, encoding: 0), .framebufferUpdateEnd])
        XCTAssertEqual(try p.feed(Data([0x02])), [.bell])
    }

    // MARK: ControlSession framebuffer path (fake server)

    private static let wrapKey = Data(hex: "000102030405060708090a0b0c0d0e0f")

    private func makeSession(_ client: ByteStream, configure: (inout ControlSession.Config) -> Void,
                             tuning: ControlSession.Tuning = .fast) -> ControlSession {
        var config = ControlSession.Config(host: "fake", port: 5900, username: "u", password: "p",
                                           logicalSize: CGSize(width: 1376, height: 1032),
                                           backingSize: CGSize(width: 2752, height: 2064), startupOrder: .reference)
        configure(&config)
        var seams = ControlSession.Seams.live
        seams.connect = { _, _ in client }
        seams.authenticate = { _, _, _, connect in
            let s = try await connect()
            return (s, AuthResult(wrapKey: Self.wrapKey, method: .srp, serverRSAPublicKeyDER: nil))
        }
        return ControlSession(config: config, tuning: tuning, seams: seams)
    }

    /// Collects sink events.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ServerEvent] = []
        func add(_ e: ServerEvent) { lock.withLock { events.append(e) } }
        var all: [ServerEvent] { lock.withLock { events } }
    }

    private func waitFor(_ cond: @escaping () -> Bool, timeout: Duration = .seconds(2)) async {
        let end = ContinuousClock.now + timeout
        while !cond(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Reads the three records enterFramebufferMode sends (ServerInit's
    /// all-zero pixel format is not decodable, so SetPixelFormat comes first).
    private func expectFramebufferPreface(_ fake: ControlSessionTests.FakeServer) async throws {
        do { let r = try await fake.readRecord(); XCTAssertEqual(r, ClientMessage.setPixelFormat(.bgra32)) }
        do { let r = try await fake.readRecord(); XCTAssertEqual(r, ClientMessage.setEncodings(ClientMessage.framebufferEncodings)) }
        do { let r = try await fake.readRecord(); XCTAssertEqual(r, ClientMessage.framebufferUpdateRequest(incremental: false)) }
    }

    /// Framebuffer-only connect: no 0x1c at all, the fallback encodings in
    /// the prelude; then zlib rects reach the sink (not `events`) and each
    /// consumed update gets one incremental full-screen 0x03 (no 0x09).
    func testFramebufferOnlyConnectAndUpdateLoop() async throws {
        let (client, server) = MemoryPipe.pair()
        let fake = ControlSessionTests.FakeServer(server)
        let session = makeSession(client, configure: { $0.framebufferOnly = true })
        let serverTask = Task {
            try await fake.handshakeAndServerInit()
            _ = try await server.read(exactly: 78)
            try await fake.sendRekeyWithEncryptedTail()
            _ = try await fake.readPlainSetDisplayConfiguration()
            let enc = try await fake.readPlainSetEncodings()
            XCTAssertEqual(enc, ClientMessage.setEncodings(ClientMessage.framebufferEncodings))
            let stop = try await server.read(exactly: 8)
            XCTAssertEqual(stop, ClientMessage.setEncryption(command: .stop))
        }
        let params = try await session.start()
        try await serverTask.value
        XCTAssertTrue(params.framebufferOnly)
        XCTAssertEqual(params.canvas.width, 1920)
        XCTAssertEqual(params.canvas.height, 1080)

        let sink = Sink()
        try await session.enterFramebufferMode(serverInit: params.serverInit, sink: { sink.add($0) })
        try await expectFramebufferPreface(fake)

        let z = try Zlib.Deflater().compress(Data(count: 16))
        var body = ByteWriter(); body.u32(UInt32(z.count)); body.bytes(z)
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(1)
        w.u16(0); w.u16(0); w.u16(2); w.u16(2); w.u32(6); w.bytes(body.data)
        try await fake.sendRecord(w.data)
        await waitFor { sink.all.count >= 2 }
        XCTAssertEqual(sink.all, [.zlibRect(x: 0, y: 0, w: 2, h: 2, payload: z), .framebufferUpdateEnd])

        await session.framebufferUpdateConsumed()
        let next = try await fake.readRecord()
        XCTAssertEqual(next, ClientMessage.framebufferUpdateRequest(incremental: true))
        XCTAssertNotEqual(next.first, 0x09)
        await session.close()
    }

    /// RFC §12: a failed 0x1c negotiation keeps the connection and switches
    /// it to the framebuffer path instead of failing the session.
    func testNegotiationFailureFallsBackOnTheSameConnection() async throws {
        let (client, server) = MemoryPipe.pair()
        let fake = ControlSessionTests.FakeServer(server)
        var tuning = ControlSession.Tuning.fast
        tuning.retryAnswerWait = .milliseconds(20)
        tuning.degenerateRetryLimit = 1
        let session = makeSession(client, configure: { $0.fallbackOnMediaFailure = true }, tuning: tuning)
        let serverTask = Task {
            try await fake.handshakeAndServerInit()
            _ = try await server.read(exactly: 78)
            try await fake.sendRekeyWithEncryptedTail()
            _ = try await fake.readPlainSetDisplayConfiguration()
            _ = try await fake.readPlainSetEncodings()
            _ = try await server.read(exactly: 8)
            var offers = 0
            while offers < 2 { if try await fake.readRecord().first == 0x1c { offers += 1 } }
        }
        let params = try await session.start()
        try await serverTask.value
        XCTAssertTrue(params.framebufferOnly)

        try await session.enterFramebufferMode(serverInit: params.serverInit, sink: { _ in })
        // (The original non-incremental 0x03 of the offer sequence came first.)
        try await expectFramebufferPreface(fake)
        await session.close()
    }

    /// In place on a running HP session: the fallback preface, then a 0x451
    /// with a new geometry gets its non-incremental 0x03 but no 0x1c re-offer.
    func testInPlaceFallbackStopsMediaReoffers() async throws {
        let (client, server) = MemoryPipe.pair()
        let fake = ControlSessionTests.FakeServer(server)
        let session = makeSession(client, configure: { _ in })
        let fx = try Fixture.load("media_offer")
        let bplist = Data(hex: fx["answer_msg"] as! String).dropFirst()
        let serverTask = Task {
            try await fake.handshakeAndServerInit()
            _ = try await server.read(exactly: 78)
            try await fake.sendRekeyWithEncryptedTail()
            _ = try await fake.readPlainSetDisplayConfiguration()
            _ = try await fake.readPlainSetEncodings()
            _ = try await server.read(exactly: 8)
            for _ in 0..<3 { _ = try await fake.readRecord() }
            try await fake.sendAnswer(Data(bplist))
        }
        let params = try await session.start()
        try await serverTask.value
        XCTAssertFalse(params.framebufferOnly)

        let sink = Sink()
        try await session.enterFramebufferMode(serverInit: params.serverInit, sink: { sink.add($0) })
        try await expectFramebufferPreface(fake)

        func layout(_ bw: Int, _ bh: Int) -> Data {
            var w = ByteWriter()
            w.u8(0); w.u8(0); w.u16(1)
            w.zeros(8); w.u32(0x451)
            w.u16(12); w.u16(0); w.u16(1376); w.u16(1032); w.u16(UInt16(bw)); w.u16(UInt16(bh)); w.u16(0)
            return w.data
        }
        try await fake.sendRecord(layout(2752, 2064))
        do { let r = try await fake.readRecord(); XCTAssertEqual(r, ClientMessage.framebufferUpdateRequest(incremental: false)) }
        try await fake.sendRecord(layout(2000, 1500))
        do { let r = try await fake.readRecord(); XCTAssertEqual(r, ClientMessage.framebufferUpdateRequest(incremental: false)) }
        await waitFor { sink.all.filter { if case .displayLayout = $0 { true } else { false } }.count >= 2 }
        // Next client record is the incremental request, not a 0x1c.
        await session.framebufferUpdateConsumed()
        do { let r = try await fake.readRecord(); XCTAssertEqual(r, ClientMessage.framebufferUpdateRequest(incremental: true, w: 2000, h: 1500)) }
        let reoffers = await session.reoffersSent
        XCTAssertEqual(reoffers, 0)
        await session.close()
    }
}
