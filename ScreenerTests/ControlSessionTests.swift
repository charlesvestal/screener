import XCTest
@testable import Screener

/// Drives `ControlSession` against a scripted fake Screen Sharing server over
/// `MemoryPipe`. Auth is stubbed through `ControlSession.Seams.authenticate`
/// (the real SRP exchange is covered by AuthTests); everything else —
/// handshake, ServerInit, prelude, rekey, record layer, 0x1c — runs for real.
final class ControlSessionTests: XCTestCase {
    private static let wrapKey = Data(hex: "000102030405060708090a0b0c0d0e0f")

    // MARK: fake server

    /// Server end of the pipe plus a mirror `RecordLayer` built from the same
    /// rekey body (both directions start from the same key/IV, so one object
    /// can open client records and seal server records).
    final class FakeServer: @unchecked Sendable {
        let s: ByteStream
        let contentKey = SecureRandom.bytes(16)
        let iv = SecureRandom.bytes(16)
        private(set) var mirror: RecordLayer!

        init(_ s: ByteStream) { self.s = s }

        var rekeyBody: Data {
            var w = ByteWriter()
            w.u32(1)
            w.bytes(try! AES.ecbEncrypt(key: ControlSessionTests.wrapKey, block: contentKey))
            w.bytes(try! AES.ecbEncrypt(key: ControlSessionTests.wrapKey, block: iv))
            return w.data
        }

        func handshakeAndServerInit() async throws {
            try await s.write(Data("RFB 003.889\n".utf8))
            _ = try await s.read(exactly: 12)
            try await s.write(Data(hex: "041e212423"))
            let ci = try await s.read(exactly: 1)
            XCTAssertEqual(ci.hex, "c1")
            var w = ByteWriter()
            w.u16(1920); w.u16(1080); w.zeros(16)
            w.u32(3); w.bytes(Data("Mac".utf8))
            try await s.write(w.data)
        }

        /// The plaintext FBU carrying a stage-1 0x3f2 rect and the 0x44f
        /// rekey, immediately followed (same TCP write) by an encrypted 0x14
        /// heartbeat record — the ciphertext tail the prelude parser must hand
        /// to the record layer.
        func sendRekeyWithEncryptedTail() async throws {
            mirror = try RecordLayer(rekeyBody: rekeyBody, wrapKey: ControlSessionTests.wrapKey)
            var w = ByteWriter()
            w.u8(0); w.u8(0); w.u16(2)
            w.zeros(8); w.u32(0x3F2); w.u16(3); w.bytes([1, 2, 3])
            w.zeros(8); w.u32(0x44F); w.bytes(rekeyBody)
            w.bytes(try mirror.seal(Data(hex: "14000004" + "0001000c")))
            try await s.write(w.data)
        }

        func readPlainSetDisplayConfiguration() async throws -> Data {
            let head = try await s.read(exactly: 4)
            XCTAssertEqual(head[0], 0x1d)
            let size = Int(head[2]) << 8 | Int(head[3])
            return head + (try await s.read(exactly: size))
        }

        func readPlainSetEncodings() async throws -> Data {
            let head = try await s.read(exactly: 4)
            XCTAssertEqual(head[0], 0x02)
            let n = Int(head[2]) << 8 | Int(head[3])
            return head + (try await s.read(exactly: 4 * n))
        }

        /// One client record, decrypted.
        func readRecord() async throws -> Data {
            let len = try await s.read(exactly: 2)
            let ct = try await s.read(exactly: Int(len[0]) << 8 | Int(len[1]))
            return try mirror.open(ciphertext: ct)
        }

        func sendRecord(_ body: Data) async throws {
            try await s.write(try mirror.seal(body))
        }

        /// The 0x1c answer as the reference sees it in practice: an FBU whose
        /// 0x3f2 rect carries the bplist (media_offer.json `answer_msg`).
        func sendAnswer(_ bplist: Data) async throws {
            var w = ByteWriter()
            w.u8(0); w.u8(0); w.u16(1)
            w.zeros(8); w.u32(0x3F2)
            w.u16(UInt16(bplist.count)); w.bytes(bplist)
            try await sendRecord(w.data)
        }
    }

    private static func answerBplist() throws -> Data {
        let fx = try Fixture.load("media_offer")
        return Data(hex: fx["answer_msg"] as! String).dropFirst()   // strip the FBU type byte
    }

    private func makeSession(_ client: ByteStream, order: ControlSession.StartupOrder,
                             tuning: ControlSession.Tuning = .fast) -> ControlSession {
        let config = ControlSession.Config(host: "fake", port: 5900, username: "u", password: "p",
                                           logicalSize: CGSize(width: 1376, height: 1032),
                                           backingSize: CGSize(width: 2752, height: 2064),
                                           startupOrder: order)
        var seams = ControlSession.Seams.live
        seams.connect = { _, _ in client }
        seams.authenticate = { _, _, connect in
            let s = try await connect()
            return (s, AuthResult(wrapKey: ControlSessionTests.wrapKey, method: .srp, serverRSAPublicKeyDER: nil))
        }
        return ControlSession(config: config, tuning: tuning, seams: seams)
    }

    // MARK: startup ordering

    /// Reference order (negotiation.connect_and_negotiate): ViewerInfo +
    /// SetEncryption(1) → [rekey arrives here, RFC §3.3] → plaintext 0x1d,
    /// 0x02 → plaintext SetEncryption(2) → encrypted 0x02, 0x1c, one
    /// non-incremental 0x03. No 0x09 anywhere.
    func testReferenceOrderStartup() async throws {
        let (client, server) = MemoryPipe.pair()
        let fake = FakeServer(server)
        let bplist = try Self.answerBplist()
        let session = makeSession(client, order: .reference)

        let serverTask = Task { () -> [Data] in
            try await fake.handshakeAndServerInit()
            let prelude = try await server.read(exactly: 66 + 12)
            XCTAssertEqual(prelude, ClientMessage.viewerInfo() + ClientMessage.setEncryption(command: .start))
            try await fake.sendRekeyWithEncryptedTail()   // right after SetEncryption(1)
            let sdc = try await fake.readPlainSetDisplayConfiguration()
            XCTAssertEqual(sdc, ClientMessage.setDisplayConfiguration(logicalWidth: 1376, logicalHeight: 1032, hidpiScale: 2))
            let enc = try await fake.readPlainSetEncodings()
            XCTAssertEqual(enc, ClientMessage.setEncodings())
            let stop = try await server.read(exactly: 8)
            XCTAssertEqual(stop, ClientMessage.setEncryption(command: .stop))
            var records: [Data] = []
            for _ in 0..<3 { records.append(try await fake.readRecord()) }
            try await fake.sendAnswer(bplist)
            return records
        }

        let params = try await session.start()
        let records = try await serverTask.value

        XCTAssertEqual(records[0], ClientMessage.setEncodings())
        XCTAssertEqual(records[1].first, 0x1c)
        XCTAssertTrue(records[1].range(of: params.keys.videoKeyS) != nil, "0x1c must carry the returned keys")
        XCTAssertEqual(records[2], ClientMessage.framebufferUpdateRequest(incremental: false))
        XCTAssertFalse(records.contains { $0.first == 0x09 })

        XCTAssertEqual(params.canvas.width, 3840)
        XCTAssertEqual(params.canvas.height, 2160)
        XCTAssertEqual(params.tiles, 4)
        XCTAssertEqual(params.contentKey, fake.contentKey)
        XCTAssertEqual(params.serverInit.name, "Mac")

        // The encrypted 0x14 that followed the rekey in the same write reached the event stream.
        var it = session.events.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first, .miscStatus(cmd: 12))
        await session.close()
    }

    /// RFC §9.1 native order: ViewerInfo, SetEncryption(1), SetMode(1),
    /// SetEncryption(2) cleartext (the rekey arriving right after
    /// SetEncryption(1)), then the encrypted preface 0x1d, 0x02, one
    /// non-incremental 0x03 (no 0x09), then the 0x1c offer.
    func testNativeOrderStartup() async throws {
        let (client, server) = MemoryPipe.pair()
        let fake = FakeServer(server)
        let bplist = try Self.answerBplist()
        let session = makeSession(client, order: .native)

        let serverTask = Task { () -> [Data] in
            try await fake.handshakeAndServerInit()
            let prelude = try await server.read(exactly: 66 + 12)
            XCTAssertEqual(prelude, ClientMessage.viewerInfo() + ClientMessage.setEncryption(command: .start))
            try await fake.sendRekeyWithEncryptedTail()   // before SetMode / SetEncryption(2), RFC §3.3
            let rest = try await server.read(exactly: 4 + 8)
            XCTAssertEqual(rest, ClientMessage.setMode(1) + ClientMessage.setEncryption(command: .stop))
            var records: [Data] = []
            for _ in 0..<4 { records.append(try await fake.readRecord()) }
            try await fake.sendAnswer(bplist)
            return records
        }

        let params = try await session.start()
        let records = try await serverTask.value

        XCTAssertEqual(records[0], ClientMessage.setDisplayConfiguration(logicalWidth: 1376, logicalHeight: 1032, hidpiScale: 2))
        XCTAssertEqual(records[1], ClientMessage.setEncodings())
        XCTAssertEqual(records[2], ClientMessage.framebufferUpdateRequest(incremental: false))
        XCTAssertEqual(records[3].first, 0x1c)
        XCTAssertFalse(records.contains { $0.first == 0x09 })
        XCTAssertEqual([params.canvas.width, params.canvas.height, params.tiles], [3840, 2160, 4])
        await session.close()
    }

    // MARK: steady state

    /// Brings a session up (reference order) and returns it with the fake
    /// server positioned right after the answer.
    private func startedSession(tuning: ControlSession.Tuning = .fast)
        async throws -> (ControlSession, FakeServer) {
        let (client, server) = MemoryPipe.pair()
        let fake = FakeServer(server)
        let bplist = try Self.answerBplist()
        let session = makeSession(client, order: .reference, tuning: tuning)
        let serverTask = Task {
            try await fake.handshakeAndServerInit()
            _ = try await server.read(exactly: 78)
            try await fake.sendRekeyWithEncryptedTail()
            _ = try await fake.readPlainSetDisplayConfiguration()
            _ = try await fake.readPlainSetEncodings()
            _ = try await server.read(exactly: 8)
            for _ in 0..<3 { _ = try await fake.readRecord() }
            try await fake.sendAnswer(bplist)
        }
        _ = try await session.start()
        try await serverTask.value
        return (session, fake)
    }

    func testDisplayLayoutTriggersNonIncrementalFBUR() async throws {
        let (session, fake) = try await startedSession()
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(1)
        w.zeros(8); w.u32(0x451)
        w.u16(12); w.u16(0); w.u16(0); w.u16(1920); w.u16(1080); w.u16(3840); w.u16(2160)
        try await fake.sendRecord(w.data)
        let next = try await fake.readRecord()
        XCTAssertEqual(next, ClientMessage.framebufferUpdateRequest(incremental: false))
        await session.close()
    }

    /// session._maybe_poll_cursor: a 1×1 incremental 0x03 every tx tick.
    func testPeriodicCursorPoll() async throws {
        var tuning = ControlSession.Tuning.fast
        tuning.cursorPollInterval = .milliseconds(50)
        let (session, fake) = try await startedSession(tuning: tuning)
        let a = try await fake.readRecord()
        let b = try await fake.readRecord()
        let poll = ClientMessage.framebufferUpdateRequest(incremental: true, x: 0, y: 0, w: 1, h: 1)
        XCTAssertEqual(a, poll)
        XCTAssertEqual(b, poll)
        await session.close()
    }

    func testSendSealsInOrder() async throws {
        let (session, fake) = try await startedSession()
        let bodies = (0..<20).map { ClientMessage.keyEvent(down: true, keysym: UInt32($0)) }
        try await withThrowingTaskGroup(of: Void.self) { g in
            for b in bodies { g.addTask { try await session.send(b) } }
            try await g.waitForAll()
        }
        var got: [Data] = []
        for _ in 0..<20 { got.append(try await fake.readRecord()) }   // open() would throw on counter skew
        XCTAssertEqual(Set(got), Set(bodies))
        await session.close()
    }

    /// RFC §12: a record-layer integrity failure closes the session and
    /// finishes the event stream; the cause is kept in `failure`.
    func testIntegrityFailureClosesSession() async throws {
        let (session, fake) = try await startedSession()
        var garbage = ByteWriter(); garbage.u16(32); garbage.bytes(SecureRandom.bytes(32))
        try await fake.s.write(garbage.data)
        for await _ in session.events {}   // returns once the stream finishes
        let failure = await session.failure
        XCTAssertEqual(failure as? RecordLayerError, .integrity)
        do { try await session.send(ClientMessage.setMode(1)); XCTFail("send after close") } catch {}
    }

    // MARK: errors

    func testSessionSelectPromptIsUnsupported() async throws {
        let (client, server) = MemoryPipe.pair()
        let fake = FakeServer(server)
        let session = makeSession(client, order: .reference)
        Task {
            try await fake.handshakeAndServerInit()
            var ssi = ByteWriter()
            ssi.bytes([0x00, 0x4a, 0x00, 0x01]); ssi.u32(0x5); ssi.zeros(4)
            ssi.bytes(Data("alice".utf8)); ssi.u8(0)
            ssi.zeros(76 - ssi.data.count)
            try await server.write(ssi.data)
        }
        do {
            _ = try await session.start()
            XCTFail("expected sessionSelectUnsupported")
        } catch let e as ControlSessionError {
            XCTAssertEqual(e, .sessionSelectUnsupported(consoleUser: "alice"))
            XCTAssertTrue(e.localizedDescription.contains("Another user"), e.localizedDescription)
        }
    }

    func testStepTimeout() async throws {
        let (client, server) = MemoryPipe.pair()
        var tuning = ControlSession.Tuning.fast
        tuning.stepTimeout = .milliseconds(200)
        let session = makeSession(client, order: .reference, tuning: tuning)
        Task {
            try await server.write(Data("RFB 003.889\n".utf8))
            _ = try await server.read(exactly: 12)
            try await server.write(Data(hex: "041e212423"))
            _ = try await server.read(exactly: 1)   // ClientInit, then never answer
        }
        do {
            _ = try await session.start()
            XCTFail("expected timeout")
        } catch let e as ControlSessionError {
            XCTAssertEqual(e, .timeout(step: "server init"))
        }
        withExtendedLifetime(server) {}
    }

    /// negotiation._phase_media_offer: a degenerate (no-canvas) answer
    /// triggers a 0x1c re-query on the same connection.
    func testDegenerateAnswerRequeries() async throws {
        let (client, server) = MemoryPipe.pair()
        let fake = FakeServer(server)
        let bplist = try Self.answerBplist()
        let session = makeSession(client, order: .reference)
        let serverTask = Task { () -> Data in
            try await fake.handshakeAndServerInit()
            _ = try await server.read(exactly: 78)
            try await fake.sendRekeyWithEncryptedTail()
            _ = try await fake.readPlainSetDisplayConfiguration()
            _ = try await fake.readPlainSetEncodings()
            _ = try await server.read(exactly: 8)
            var offer = Data()
            for i in 0..<3 { let r = try await fake.readRecord(); if i == 1 { offer = r } }
            try await fake.sendRecord(Data([0x1c, 0, 0, 0]))   // degenerate: no bplist
            let again = try await fake.readRecord()
            XCTAssertEqual(again, offer)
            try await fake.sendAnswer(bplist)
            return again
        }
        let params = try await session.start()
        _ = try await serverTask.value
        XCTAssertEqual(params.canvas.width, 3840)
        await session.close()
    }
}

extension ControlSession.Tuning {
    /// No settle delays and no background poll, so record order is deterministic.
    static var fast: Self {
        var t = Self()
        t.postViewerInfoSettle = .zero
        t.postToggleSettle = .zero
        t.degenerateRetryInterval = .milliseconds(10)
        t.cursorPollInterval = .seconds(3600)
        return t
    }
}
