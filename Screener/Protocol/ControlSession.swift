// Ported from iShareScreen src/isharescreen/proxy/protocol/negotiation.py
// (connect_and_negotiate, _phase_auth, _phase_client_init, _read_ss_prompt /
// _peek_ss_prompt, _phase_handshake_plaintext, _phase_enable_enc1103,
// _read_until_enc1103, _phase_media_offer, _read_video_answer) and
// proxy/session.py (_negotiate_and_burst, _tcp_rx_loop, _handle_fbu 0x451
// re-arm, _send_cursor_rearm, _maybe_poll_cursor / _tx_loop) (AGPL-3.0)
//
// The whole TCP control-channel lifecycle for one HP session:
//   connect → RFB handshake → auth (SRP, non-SRP fallback) → ClientInit /
//   ServerInit → cleartext prelude → 0x44f rekey → record layer →
//   encrypted preface → 0x1c offer / answer → steady-state receive loop.
//
// STARTUP ORDER. The RFC (§9.1) and the reference disagree, so both are
// implemented; `.reference` is the default (task rule: follow the reference
// on a contradiction).
//   .reference (negotiation.connect_and_negotiate, curtain=True, no session-select):
//     1. ViewerInfo(0x21) + SetEncryption(1) in one write (_phase_handshake_plaintext)
//     2. settle 100 ms (_POST_VIEWERINFO_SETTLE_S)
//     3. PLAINTEXT SetDisplayConfiguration(0x1d), PLAINTEXT SetEncodings(0x02)
//     4. read until the 0x44f rekey FBU (_read_until_enc1103)
//     5. PLAINTEXT SetEncryption(2) (build_post_encryption_toggle), settle 200 ms
//     6. [enc] SetEncodings(0x02), [enc] 0x1c offer, [enc] non-incremental 0x03
//        (_phase_media_offer)
//     7. read the 0x1c answer; re-send the same 0x1c up to 16× at 200 ms on a
//        degenerate canvas
//   .native (RFC §9.1/§9.2, Screen Sharing.app capture):
//     ViewerInfo, SetEncryption(1), SetMode(1), SetEncryption(2) cleartext →
//     rekey → [enc] 0x1d, [enc] 0x02, [enc] non-incremental 0x03 → [enc] 0x1c.
// Both: NO 0x09 AutoFrameBufferUpdate (the reference never sends it: it makes
// the daemon free-run pixel rects over TCP). The RFC §8.11 "0x09 + 0x03"
// re-arm is replaced, as in the reference, by one non-incremental 0x03 on
// every 0x451 plus a periodic 1×1 incremental 0x03 poll.
//
// Other deviations from the reference (documented, deliberate):
//   * Session-select detection: the reference MSG_PEEKs 4 bytes for up to 2 s
//     after ServerInit. `ByteStream` has no peek and cancelling a TCP read
//     closes the socket, so instead the first 4 bytes the server sends after
//     the prelude are checked for the `00 4a 00 01` magic (a real FBU has pad
//     byte 0, never 0x4a). Same detection, no 2 s stall on every connect.
//   * `_drain_through_cipher` / the tail of `_read_until_enc1103` decrypt and
//     DISCARD whatever arrives right after the rekey; we dispatch it as events
//     (the reference itself later added `leftover_msgs` for the same reason).
//   * `_read_video_answer` returns "degenerate" when the first ~100 bytes it
//     reads lack the answer; we wait for an actual answer candidate instead.
//     A silent `retryAnswerWait` (5 s, its socket timeout) still counts as
//     degenerate and re-sends the same 0x1c, exactly like the reference —
//     the server does not reliably answer the first offer.
//   * `rfb.warmup_tcp` is not ported (plan: only if the live test needs it).
//     The reference runs it by default (SessionConfig.warmup_tcp=True) before
//     every session: a throwaway TCP that exchanges banners + the type list,
//     closes, then dwells 1.4 s. Its stated purpose is surviving lock →
//     login → desktop transitions, not getting connected at all (loopback
//     included). `_handshake_with_reconnect` (burst-starvation reconnect)
//     lives in SessionCoordinator, which owns the UDP side.
//   * Session-select cmd 0/2 (share console / alt session) is not implemented
//     in v1: the prompt is reported as `.sessionSelectUnsupported`.
import CoreGraphics
import Foundation

enum ControlSessionError: Error, Equatable, LocalizedError {
    /// A handshake step did not complete within its time limit.
    case timeout(step: String)
    /// The server sent the session-select prompt (another user is logged in).
    case sessionSelectUnsupported(consoleUser: String)
    /// The server never sent the 0x44f rekey (negotiation._read_until_enc1103).
    case noRekey
    /// No usable canvas in the 0x1c answer after all re-queries.
    case mediaNegotiationFailed
    case closed
    case alreadyStarted

    var errorDescription: String? {
        switch self {
        case .timeout(let step):
            return "The Mac stopped responding during \(step)."
        case .sessionSelectUnsupported(let user):
            let who = user.isEmpty ? "Another user" : "Another user (\(user))"
            return "\(who) is logged in on this Mac. Screener can't share another user's session yet — " +
                "log that user out, or connect with their account."
        case .noRekey:
            return "The Mac didn't enable encryption. This is most often rate limiting — wait 10–15 seconds and retry."
        case .mediaNegotiationFailed:
            return "The Mac didn't start a High Performance stream."
        case .closed:
            return "The connection was closed."
        case .alreadyStarted:
            return "This session was already started."
        }
    }
}

/// Races `op` against `limit`; on expiry the operation is cancelled (which
/// closes a TCP stream it was reading) and `.timeout(step:)` is thrown.
func withStepTimeout<T: Sendable>(_ step: String, _ limit: Duration,
                                  _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await op() }
        group.addTask { try await Task.sleep(for: limit); return nil }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else {
            throw ControlSessionError.timeout(step: step)
        }
        return value
    }
}

actor ControlSession {
    enum StartupOrder: String, Sendable { case reference, native }

    struct Config: Sendable {
        var host: String
        var port: UInt16 = 5900
        var username: String
        var password: String
        /// Advertised in 0x1d: logical (point) size and backing (pixel) size.
        var logicalSize: CGSize
        var backingSize: CGSize
        var audioEnabled: Bool = true
        var startupOrder: StartupOrder = .reference
    }

    /// Timing knobs; defaults are the reference's values.
    struct Tuning: Sendable {
        /// Per handshake step (connect, handshake, server init, rekey). The media
        /// answer instead waits `retryAnswerWait` per offer, up to
        /// `degenerateRetryLimit` re-sends.
        /// Auth gets twice this (primary + fallback attempt).
        var stepTimeout: Duration = .seconds(10)
        var postViewerInfoSettle: Duration = .milliseconds(100)   // _POST_VIEWERINFO_SETTLE_S
        var postToggleSettle: Duration = .milliseconds(200)       // _POST_TOGGLE_SETTLE_S
        var cursorPollInterval: Duration = .milliseconds(500)     // session._TX_INTERVAL_S
        var degenerateRetryInterval: Duration = .milliseconds(200) // _DEGENERATE_RETRY_INTERVAL_S
        var degenerateRetryLimit = 16                              // _DEGENERATE_RETRY_LIMIT
        var retryAnswerWait: Duration = .seconds(5)                // _read_video_answer settimeout(5.0)
        /// How often start() logs "still waiting for <step>" (diagnostics).
        var progressLogInterval: Duration = .seconds(5)
    }

    /// Injection points for tests.
    struct Seams: Sendable {
        var connect: @Sendable (_ host: String, _ port: UInt16) async throws -> ByteStream
        var authenticate: @Sendable (_ username: String, _ password: String,
                                     _ connect: @escaping @Sendable () async throws -> ByteStream)
            async throws -> (stream: ByteStream, result: AuthResult)

        static let live = live(localAddress: nil)

        /// `localAddress` pins the TCP source address (DEBUG builds only). The HP server sends its
        /// UDP media to the control connection's peer address, so MediaTransport
        /// must bind the same address (matters when the Mac has several, or
        /// for same-host testing where loopback cannot work).
        static func live(localAddress: String?) -> Seams {
            Seams(
                connect: { host, port in
                    do {
                        // Network.framework ignores a required local endpoint in the
                        // simulator, so a pinned source address uses a BSD socket.
                        // DEBUG-only path (launch harness); release ignores it.
                        #if DEBUG
                        if let localAddress {
                            return try await SocketTCPByteStream.connect(host: host, port: port, localAddress: localAddress,
                                                                         timeout: .seconds(10))
                        }
                        #endif
                        return try await TCPByteStream.connect(host: host, port: port, timeout: .seconds(10))
                    } catch TransportError.timeout {
                        throw ControlSessionError.timeout(step: "connect")
                    }
                },
                authenticate: { user, pass, connect in
                    try await Authenticator.runWithFallback(username: user, password: pass, connect: connect)
                })
        }
    }

    struct MediaParams: Sendable {
        let keys: NegotiationKeys
        let canvas: (width: Int, height: Int)
        let tiles: Int
        /// Record-layer content key, for 0x10 encrypted input (`ClientMessage.encryptedPointerEvent`).
        let contentKey: Data
        let audioOffer: Data
        let videoOffer: Data
        let ltrpEnabled: Bool?
        let serverInit: ServerInit
    }

    /// Every server message after the rekey (and any plaintext ones before
    /// it). Finishes when the session closes; read `failure` for the cause.
    nonisolated let events: AsyncStream<ServerEvent>
    private let continuation: AsyncStream<ServerEvent>.Continuation

    /// Why the session ended (nil after a clean `close()`).
    private(set) var failure: Error?

    private let config: Config
    private let tuning: Tuning
    private let seams: Seams

    private var stream: ByteStream?
    private var record: RecordLayer?
    private var started = false
    private var isClosed = false
    private var rxTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var loggedRecordActive = false
    // start() progress (diagnostics): the step in flight and when it began.
    private(set) var currentStep = "connect"
    private var stepStarted = ContinuousClock.now
    private var startBegan = ContinuousClock.now
    #if DEBUG
    private var rxRecordCount = 0
    #endif

    // Serialises every wire write (seal + write is one step; RecordLayer contract).
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    // 0x1c answer hand-off from the rx loop to start().
    private enum AnswerOutcome: Sendable { case answer(MediaAnswer), degenerate, timedOut }
    private var collectingAnswers = false
    private var queuedAnswer: AnswerOutcome?
    private var answerWaiter: CheckedContinuation<AnswerOutcome, Error>?
    private var answerTimer: Task<Void, Never>?
    private var answerGeneration = 0

    init(config: Config, tuning: Tuning = Tuning(), seams: Seams = .live) {
        self.config = config
        self.tuning = tuning
        self.seams = seams
        (events, continuation) = AsyncStream.makeStream(of: ServerEvent.self, bufferingPolicy: .bufferingNewest(1024))
    }

    // MARK: start

    /// Runs the handshake through the 0x1c answer, then leaves the receive
    /// loop and the cursor poll running. Throws (and closes) on any failure.
    func start() async throws -> MediaParams {
        guard !started else { throw ControlSessionError.alreadyStarted }
        started = true
        startBegan = .now
        stepStarted = .now
        let interval = tuning.progressLogInterval
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.logStillWaiting()
            }
        }
        defer { watchdog.cancel() }
        do {
            let params = try await run()
            Log.control.info("start completed in \((ContinuousClock.now - startBegan).ms) ms")
            return params
        } catch {
            // Prefer the receive loop's recorded cause (e.g. an integrity failure)
            // over the secondary `.closed` a pending send then saw.
            let mapped = failure ?? Self.mapStartError(error)
            Log.control.error("start failed: \(Self.describe(mapped))")
            teardown(error: mapped)
            throw mapped
        }
    }

    /// Logs how long the previous step took and starts timing `step`.
    private func beginStep(_ step: String) {
        let now = ContinuousClock.now
        Log.control.info("step \(currentStep) done in \((now - stepStarted).ms) ms; now \(step)")
        currentStep = step
        stepStarted = now
    }

    private func logStillWaiting() {
        guard !isClosed, started else { return }
        let now = ContinuousClock.now
        Log.control.info("still waiting for \(currentStep) (\((now - stepStarted).ms) ms in step, "
                         + "\((now - startBegan).ms) ms since start)")
    }

    private func run() async throws -> MediaParams {
        let cfg = config, seams = seams, limit = tuning.stepTimeout
        Log.control.info("connecting to \(cfg.host):\(cfg.port) order=\(cfg.startupOrder.rawValue)")

        // 1) TCP + handshake + auth (negotiation._phase_auth / _open_socket_and_handshake).
        let connect: @Sendable () async throws -> ByteStream = { [weak self] in
            let s = try await seams.connect(cfg.host, cfg.port)
            do {
                _ = try await withStepTimeout("handshake", limit) { try await RFBHandshake.negotiate(s) }
            } catch {
                s.close()
                throw error
            }
            guard let self, await self.adopt(s) else { s.close(); throw ControlSessionError.closed }
            return s
        }
        currentStep = "connect+handshake+auth"
        let (stream, auth) = try await withStepTimeout("auth", limit * 2) {
            try await seams.authenticate(cfg.username, cfg.password, connect)
        }
        guard adopt(stream) else { throw ControlSessionError.closed }
        Log.control.info("M1 auth ok")
        beginStep("server init")

        // 2) ClientInit / ServerInit (_phase_client_init).
        let serverInit = try await withStepTimeout("server init", limit) { try await RFBHandshake.clientInit(stream) }

        // 3) Cleartext prelude.
        beginStep("cleartext prelude")
        let scale = cfg.logicalSize.width > 0 ? Double(cfg.backingSize.width / cfg.logicalSize.width) : 2.0
        let sdc = ClientMessage.setDisplayConfiguration(logicalWidth: Int(cfg.logicalSize.width.rounded()),
                                                        logicalHeight: Int(cfg.logicalSize.height.rounded()),
                                                        hidpiScale: scale)
        try await writePlain(ClientMessage.viewerInfo() + ClientMessage.setEncryption(command: .start))
        try await Task.sleep(for: tuning.postViewerInfoSettle)
        switch cfg.startupOrder {
        case .reference:
            try await writePlain(sdc)
            try await writePlain(ClientMessage.setEncodings())
        case .native:
            try await writePlain(ClientMessage.setMode(1) + ClientMessage.setEncryption(command: .stop))
        }

        // 4) Rekey (_read_until_enc1103), with session-select detection.
        let wrapKey = auth.wrapKey
        beginStep("rekey")
        let rekey = try await withStepTimeout("rekey", limit) {
            try await Self.readUntilRekey(stream, wrapKey: wrapKey)
        }
        record = rekey.record
        for e in rekey.events { continuation.yield(e) }
        Log.control.info("rekey received; record layer installed")
        let initial = rekey.tail
        rxTask = Task { [weak self] in await self?.rxLoop(initial: initial) }

        // 5) Encrypted preface + 0x1c offer (_phase_enable_enc1103 / _phase_media_offer).
        beginStep("media offer")
        let offers = try MediaOffer.create(audioEnabled: cfg.audioEnabled)
        let keys = NegotiationKeys.random()
        let msg1c = MediaStreamOptions.build(keys: keys, audioOffer: offers.audio, videoOffer: offers.video)
        let fullFBUR = ClientMessage.framebufferUpdateRequest(incremental: false)
        collectingAnswers = true
        switch cfg.startupOrder {
        case .reference:
            try await writePlain(ClientMessage.setEncryption(command: .stop))
            try await Task.sleep(for: tuning.postToggleSettle)
            try await send(ClientMessage.setEncodings())
            try await send(msg1c)
            Log.control.info("0x1c sent (encrypted)")
            try await send(fullFBUR)
        case .native:
            try await Task.sleep(for: tuning.postToggleSettle)
            try await send(sdc)
            try await send(ClientMessage.setEncodings())
            try await send(fullFBUR)
            try await send(msg1c)
            Log.control.info("0x1c sent (encrypted)")
        }

        // 6) Answer, re-querying on a degenerate canvas OR on silence.
        // negotiation._read_video_answer returns (0,0,0) both for a
        // canvas-less answer and for a 5 s read timeout, and _phase_media_offer
        // re-sends the same 0x1c in both cases. The server does not reliably
        // answer the first offer: a reference capture (conn 2) shows the first
        // 0x1c unanswered for 3 s and the re-sent one answered in 67 ms.
        beginStep("media answer")
        var outcome = try await awaitAnswer(timeout: tuning.retryAnswerWait)
        var attempt = 0
        var lastTimedOut = false
        while true {
            if case .answer = outcome { break }
            if case .timedOut = outcome { lastTimedOut = true } else { lastTimedOut = false }
            guard attempt < tuning.degenerateRetryLimit else {
                if lastTimedOut { throw ControlSessionError.timeout(step: "media answer") }
                throw ControlSessionError.mediaNegotiationFailed
            }
            attempt += 1
            try await Task.sleep(for: tuning.degenerateRetryInterval)
            try await send(msg1c)
            let why = lastTimedOut ? "no answer" : "degenerate canvas"
            Log.control.info("0x1c re-query \(attempt)/\(tuning.degenerateRetryLimit) (\(why))")
            outcome = try await awaitAnswer(timeout: tuning.retryAnswerWait)
        }
        collectingAnswers = false
        beginStep("done")
        guard case .answer(let answer) = outcome, let record else { throw ControlSessionError.closed }
        Log.control.info("M2 media answer canvas=\(answer.canvasWidth)x\(answer.canvasHeight) tiles=\(answer.tiles)")

        startCursorPoll()
        return MediaParams(keys: keys, canvas: (answer.canvasWidth, answer.canvasHeight), tiles: answer.tiles,
                           contentKey: record.contentKey, audioOffer: offers.audio, videoOffer: offers.video,
                           ltrpEnabled: answer.ltrpEnabled, serverInit: serverInit)
    }

    /// Records the newest stream so `close()` can abort it. False if already closed.
    private func adopt(_ s: ByteStream) -> Bool {
        if isClosed { return false }
        stream = s
        return true
    }

    // MARK: prelude read

    private struct RekeyResult: Sendable {
        let record: RecordLayer
        let tail: Data
        let events: [ServerEvent]
    }

    /// Magic at the start of the 76-byte SessionSelect prompt (negotiation._SS_MAGIC).
    static let sessionSelectMagic = Data([0x00, 0x4a, 0x00, 0x01])

    /// negotiation._read_until_enc1103 + _read_ss_prompt: parse the plaintext
    /// stream until the FBU carrying the 0x44f rekey; return the record
    /// layer, the ciphertext that followed, and any other messages seen.
    private static func readUntilRekey(_ s: ByteStream, wrapKey: Data) async throws -> RekeyResult {
        let first: Data
        do {
            first = try await s.read(exactly: 4)
        } catch TransportError.closed {
            throw ControlSessionError.noRekey
        }
        if first == sessionSelectMagic {
            let rest = (try? await s.read(exactly: 72)) ?? Data()
            let ssi = first + rest
            let user = ssi.count > 0xC
                ? String(decoding: ssi.dropFirst(0xC).prefix { $0 != 0 }, as: UTF8.self) : ""
            Log.control.error("session-select prompt (console user \(user.isEmpty ? "?" : user)); unsupported in v1")
            throw ControlSessionError.sessionSelectUnsupported(consoleUser: user)
        }
        var parser = ServerMessageParser(framing: .stream)
        var rekeyBody: Data?
        var others: [ServerEvent] = []
        var chunk = first
        while true {
            #if DEBUG
            wireLog("rx plain chunk", chunk, prefix: 48)
            #endif
            for e in try parser.feed(chunk) {
                #if DEBUG
                Log.control.info("wire rx plain event \(Self.eventSummary(e))")
                #endif
                if case .rekey(let body) = e { rekeyBody = body } else { others.append(e) }
            }
            if parser.isHalted { break }
            do {
                chunk = try await s.readSome()
            } catch TransportError.closed {
                throw ControlSessionError.noRekey
            }
        }
        guard let rekeyBody else { throw ControlSessionError.noRekey }
        let record = try RecordLayer(rekeyBody: rekeyBody, wrapKey: wrapKey)
        let tail = parser.takeRemainder()
        #if DEBUG
        Log.control.info("wire rekey parsed; ciphertext tail \(tail.count)B")
        #endif
        return RekeyResult(record: record, tail: tail, events: others)
    }

    // MARK: answer hand-off

    private func awaitAnswer(timeout: Duration) async throws -> AnswerOutcome {
        if let q = queuedAnswer { queuedAnswer = nil; return q }
        if isClosed { throw failure ?? ControlSessionError.closed }
        answerGeneration += 1
        let generation = answerGeneration
        return try await withCheckedThrowingContinuation { c in
            answerWaiter = c
            answerTimer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.answerTimedOut(generation: generation)
            }
        }
    }

    private func answerTimedOut(generation: Int) {
        guard generation == answerGeneration, answerWaiter != nil else { return }
        resolveAnswer(.success(.timedOut))
    }

    private func resolveAnswer(_ result: Result<AnswerOutcome, Error>) {
        answerTimer?.cancel(); answerTimer = nil
        if let c = answerWaiter {
            answerWaiter = nil
            c.resume(with: result)
        } else if case .success(let o) = result, collectingAnswers {
            queuedAnswer = o
        }
    }

    // MARK: sending

    /// Seals `body` with the record layer and writes it; seal + write is one
    /// serialised step so wire order equals the record counter order.
    func send(_ body: Data) async throws {
        await acquireWrite()
        defer { releaseWrite() }
        guard !isClosed, let stream, let record else { throw ControlSessionError.closed }
        #if DEBUG
        Self.wireLog("tx enc", body, prefix: 32)
        #endif
        try await stream.write(try record.seal(body))
    }

    private func writePlain(_ data: Data) async throws {
        await acquireWrite()
        defer { releaseWrite() }
        guard !isClosed, let stream else { throw ControlSessionError.closed }
        #if DEBUG
        Self.wireLog("tx plain", data, prefix: 32)
        #endif
        try await stream.write(data)
    }

    private func acquireWrite() async {
        if !writing { writing = true; return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func releaseWrite() {
        if writeWaiters.isEmpty { writing = false } else { writeWaiters.removeFirst().resume() }
    }

    // MARK: receive loop (session._tcp_rx_loop / _handle_tcp_msg)

    private func rxLoop(initial: Data) async {
        guard let stream, let record else { return }
        var splitter = FrameSplitter()
        var parser = ServerMessageParser(framing: .records)
        var chunk = initial
        do {
            while !Task.isCancelled {
                if !chunk.isEmpty {
                    #if DEBUG
                    Log.control.info("wire rx chunk \(chunk.count)B")
                    #endif
                    for frame in try splitter.push(chunk) {
                        let body = try record.open(ciphertext: frame)
                        if !loggedRecordActive {
                            loggedRecordActive = true
                            Log.control.info("M2 record layer active")
                        }
                        let events = try parser.feed(body)
                        #if DEBUG
                        rxRecordCount += 1
                        Self.wireLog("rx rec#\(rxRecordCount) ct=\(frame.count)B", body, prefix: 48)
                        Log.control.info("wire   events: [\(events.map(Self.eventSummary).joined(separator: ", "))]")
                        #endif
                        try await handle(events)
                    }
                }
                chunk = try await stream.readSome()
            }
        } catch {
            if !isClosed {
                Log.control.error("control channel ended: \(Self.describe(error))")
                teardown(error: error)
            }
        }
    }

    private func handle(_ events: [ServerEvent]) async throws {
        var sawCursor = false
        for event in events {
            switch event {
            case .displayLayout:
                // session._handle_fbu 0x451 → _send_cursor_rearm: one
                // non-incremental 0x03 on EVERY layout, never 0x09.
                // TODO(Task 21): on a geometry change also re-offer 0x1c
                // (session._schedule_post_layout_arm).
                try await send(ClientMessage.framebufferUpdateRequest(incremental: false))
            case .cursorStore, .cursorSelect:
                sawCursor = true
            case .mediaStreamAnswer(let data):
                if collectingAnswers {
                    if let a = try? MediaStreamOptions.parseAnswer(data) {
                        resolveAnswer(.success(.answer(a)))
                    } else {
                        resolveAnswer(.success(.degenerate))
                    }
                }
            case .rekey:
                // TODO: wrap-key rotation (RFC §6.2.1) is unobserved in captures and unported.
                Log.control.error("mid-session rekey received; not supported, ignoring")
            default:
                break
            }
            continuation.yield(event)
        }
        // session._handle_fbu tail: after an FBU with a cursor rect, re-request a
        // 1×1 incremental update so shape changes keep flowing.
        if sawCursor { try await send(Self.cursorPoll) }
    }

    // MARK: cursor poll (session._maybe_poll_cursor, every _TX_INTERVAL_S)

    /// input.request_framebuffer_update: incremental 1×1 at (0,0).
    static let cursorPoll = ClientMessage.framebufferUpdateRequest(incremental: true, x: 0, y: 0, w: 1, h: 1)

    private func startCursorPoll() {
        let interval = tuning.cursorPollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                do { try await self.send(Self.cursorPoll) } catch { return }
            }
        }
    }

    #if DEBUG
    // MARK: wire instrumentation (DEBUG only; never called with auth material)

    static func wireLog(_ what: String, _ d: Data, prefix: Int) {
        let hex = d.prefix(prefix).map { String(format: "%02x", $0) }.joined()
        Log.control.info("wire \(what) len=\(d.count) type=0x\(String(format: "%02x", d.first ?? 0)) \(hex)")
    }

    static func eventSummary(_ e: ServerEvent) -> String {
        switch e {
        case .rekey: return "rekey"
        case .displayLayout(let l): return "layout(\(l.backingWidth)x\(l.backingHeight),\(l.displays.count)d)"
        case .cursorStore(let id, _, let s, _, _): return "cursorStore(\(id),\(s.width)x\(s.height))"
        case .cursorSelect(let id): return "cursorSelect(\(id))"
        case .keyboardSource(let s, let sec): return "kbdSource(\(s),\(sec))"
        case .deviceInfo(let m): return "deviceInfo(\(m))"
        case .vendorKeysyms(let k): return "keysyms(\(k.count))"
        case .mediaStreamAnswer(let d): return "answerCandidate(\(d.count)B)"
        case .miscStatus(let c): return "misc(\(c))"
        case .clipboard(let h, let c): return "clipboard(\(h.compressedSize),chunk \(c.count))"
        case .bell: return "bell"
        case .zlibRect(_, _, let w, let h, let p): return "zlib(\(w)x\(h),\(p.count)B)"
        case .unknown(let t, let enc): return "unknown(0x\(String(t, radix: 16))\(enc.map { ",enc=\($0)" } ?? ""))"
        }
    }
    #endif

    // MARK: teardown

    /// Closes the TCP connection and finishes `events`. Idempotent.
    func close() {
        if !isClosed { Log.control.info("closing control session") }
        teardown(error: nil)
    }

    /// `close()`, then waits (at most `timeout`) until the TCP close has
    /// actually gone out (ByteStream.closeAndWait). Returns false on timeout.
    func closeAndWait(timeout: Duration) async -> Bool {
        let s = stream
        close()
        guard let s else { return true }
        return await s.closeAndWait(timeout: timeout)
    }

    private func teardown(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        if let error { failure = error }
        rxTask?.cancel()
        pollTask?.cancel()
        stream?.close()
        resolveAnswer(.failure(error ?? ControlSessionError.closed))
        continuation.finish()
    }

    // MARK: errors

    private static func mapStartError(_ error: Error) -> Error {
        switch error {
        case TransportError.timeout: return ControlSessionError.timeout(step: "connect")
        case is CancellationError: return ControlSessionError.closed
        default: return error
        }
    }

    /// A user-readable message for any error `start()` or `failure` can carry.
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as ControlSessionError:
            return e.errorDescription ?? "\(e)"
        case let e as AuthError:
            switch e {
            case .rejected: return "The Mac rejected the username or password."
            case .unsupported, .srpUnavailable: return "The Mac asked for an authentication method Screener doesn't support."
            case .malformed: return "Authentication failed (unexpected reply from the Mac)."
            }
        case let e as RFBHandshakeError:
            switch e {
            case .unsupportedVersion(let v): return "This isn't a macOS Screen Sharing server (\(v))."
            case .serverRefused(let reason): return "The Mac refused the connection" + (reason.map { ": \($0)" } ?? ".")
            case .unsupported: return "The Mac doesn't offer the sign-in method Screener needs. Is High Performance screen sharing enabled?"
            case .malformedServerInit: return "Unexpected reply from the Mac."
            }
        case let e as TransportError:
            switch e {
            case .timeout: return "The Mac didn't respond."
            case .closed: return "The Mac closed the connection."
            case .failed(let why): return "Connection failed: \(why)"
            case .posix(let e): return "Connection failed: \(String(cString: strerror(e))) (\(e))"
            }
        case let e as RecordLayerError:
            return "The encrypted connection failed (\(e)); disconnected."
        default:
            return error.localizedDescription
        }
    }
}
