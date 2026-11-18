// Ported in part from iShareScreen src/isharescreen/proxy/session.py
// (_connect_internal, _resolve_host_ipv4, _handshake_with_reconnect) (AGPL-3.0)
//
// Owns one HP session: the TCP ControlSession and the UDP MediaTransport.
//   connect → resolve the host ONCE to an IPv4 literal (used by TCP and UDP)
//   → refuse a second session to the same server → create the media
//   transport, attach the video/audio consumers → bind UDP + punch (before the
//   handshake, so the start burst is never dropped) → control handshake →
//   0x1c answer → install media keys → wait for the start burst.
// A starved burst (the host accepted the canvas but never streamed) is
// retried with a full fresh handshake, as _handshake_with_reconnect does: up
// to 3 attempts, 0.8 s apart, on the SAME UDP sockets (the reference keeps
// them; only the TCP is torn down). Later tasks extend this (decoder, input,
// reconnect policy).
//
// Video (Task 14): the coordinator owns the ONE consumer of
// MediaTransport.video: a VideoPipeline task (packets → DEBUG capture tap →
// HEVCAssembler → VideoDecoder → `frames`), started right after the
// transport is created, before open(). Keyframe requests, notePublished and
// the assembler's 20 ms tick are wired inside it. A stream that turns out to
// be H.264 fails the session ("server chose H.264").
//
// Audio (Task 16): one AudioPlayer per session consumes MediaTransport.audio
// on a detached task (decode off the main thread), subscribed before open().
// Teardown cancels the consumer and stops the player (engine + audio session)
// before the sockets close.
//
// Input (Task 15): once the stream has started, an InputController sends
// pointer / key input on the control channel (0x10 pointer events under the
// record layer's content key). Control events feed it and the host cursor:
// each 0x451 updates the pointer's canvas (backing) size and the cursor's
// backing/scaled factor; 0x450 STORE / SELECT update RemoteCursor. Both are
// dropped at teardown (cursor cache ids are per connection).
//
// Clipboard (Task 17): `clipboard` (ClipboardBridge) is attached once the
// stream starts (0x15 enable + prime), gets the 0x14 / 0x1f control events,
// re-checks the iPad pasteboard when the scene becomes active, and is
// detached at teardown. Its sync bookkeeping outlives sessions.
//
// Display (Task 21): the connect-time 0x1d is sized by DisplayMode from the
// session view's size (the window scene's before it exists); afterwards
// `display` (DisplayResizer) follows view / mode changes with debounced
// dynamic 0x1d requests. A 0x451 that changes the backing size (ControlSession
// re-offers 0x1c on it) makes the media transport expect the new SSRC group
// and the frame store hold the last picture until the new stream's first;
// input and the cursor follow the 0x451 at once (the server's geometry is
// authoritative).
//
// Concurrency: every connect runs in `connectTask` under a generation number.
// `disconnect()` and any session failure bump the generation, cancel the task
// and tear down; the connect task re-checks its generation after every await
// and never touches shared state once it is stale. Teardown awaits the media
// sockets' close, and the next connect waits for a pending teardown, so the
// UDP ports are never bound twice by this app at once.
//
// Background / foreground (LifecyclePolicy, SessionLifecycle.swift): going to
// the background closes the session at once (`.suspended`, request kept in
// memory); becoming active reconnects with `isReconnecting` set, so the
// session view stays up with "Reconnecting…" over the last picture until the
// resumed session decodes. Errors reach the UI only through
// UserFacingError.message (never raw errno text).
//
// Closing (teardown): the TCP control connection is closed FIRST and its
// close awaited (FIN out, NWConnection `.cancelled`, capped at
// `Policy.controlCloseTimeout`), then the media sockets. On backgrounding
// this is what the UIApplication background task waits for: the Mac must see
// the close before iOS suspends us, or it keeps sharing (display privacy on).
//
// TCP-only fallback (Task 19; MediaFallbackPolicy.swift): no authenticated
// video at the start burst, or 3 hard decoder failures within 10 s, tear this
// connection down and reconnect the SAME host without a media offer
// (`reconnectWithoutMediaOffer` → `ConnectRequest.framebufferOnly`, kept for
// this session's later reconnects too). A failed 0x1c negotiation
// (ControlSession's `fallbackOnMediaFailure`) never activated media either,
// so it goes straight to the framebuffer path on the SAME connection
// (`enterFallback`). Either way a FramebufferPipeline decodes ControlSession's
// zlib / raw rects into a BGRA picture and `fallbackReason` drives the
// "Reduced performance" badge + toast. We never switch HP → framebuffer
// in place on a connection that already activated media: a live capture
// (2026-11-18) showed macOS answers the SetEncodings that mid-session switch
// sends with exactly one framebuffer update and then nothing, while it keeps
// streaming the old HP UDP video — so a fresh connection without the offer is
// the only path that reliably recovers. If the framebuffer path still shows
// no picture within `Policy.firstFrameDeadline`, the session reconnects
// without a media offer once more, then gives up.
//
// First picture: once `.connected`, a picture must decode within
// `Policy.firstFrameDeadline` (a keyframe is requested at
// `firstFrameKeyframeAfter`), else the session fails with
// `noPictureMessage`; "Connecting…" / "Reconnecting…" never stays up forever.
import CoreGraphics
import CoreVideo
import Observation
import UIKit

@MainActor @Observable
final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case connecting
        case connected(canvasWidth: Int, canvasHeight: Int)
        /// Closed because the app went to the background; reconnects when active.
        case suspended
        case failed(String)
    }

    /// What `connect` was asked for; kept (in memory only) to reconnect.
    struct ConnectRequest: Equatable, Sendable {
        var host: String
        var port: UInt16
        var username: String
        var password: String
        var order: ControlSession.StartupOrder = .reference
        var localAddress: String?
        /// Pinned Mac key / legacy sign-in permission (H1). A first sign-in
        /// pins the key here too, so this session's reconnects are pinned.
        var authPolicy = AuthPolicy()
        /// TCP fallback: connect without a media offer (framebuffer path),
        /// and why. Set by the coordinator only.
        var framebufferOnly: MediaFallbackPolicy.Reason?
    }

    /// A connect refused because the Mac's key isn't the pinned one (H1):
    /// the UI asks "This Mac's identity changed" → Cancel / Trust New Key.
    struct IdentityChange: Equatable, Sendable {
        let host: String
        let presentedSHA256: Data
    }

    struct Policy: Sendable {
        var burstRetryAttempts = 3                       // _BURST_RETRY_ATTEMPTS
        var burstRetrySleep: Duration = .milliseconds(800) // _BURST_RETRY_SLEEP_S
        /// After `.connected`: request a keyframe if no picture yet...
        var firstFrameKeyframeAfter: Duration = .seconds(5)
        /// ...and fail the session if there is still none.
        var firstFrameDeadline: Duration = .seconds(10)
        /// Longest wait for the TCP close to go out before closing media anyway.
        var controlCloseTimeout: Duration = .seconds(1)
        /// Longest wait, at teardown, for queued input (the releases sent by
        /// `releaseInput`) to reach the control channel before it's closed.
        var inputFlushTimeout: Duration = .milliseconds(150)
    }

    /// Injection points for tests.
    struct Seams: Sendable {
        /// Host name or literal → IPv4 literal (blocking work must stay off the
        /// main actor and the cooperative pool).
        var resolveIPv4: @Sendable (String) async throws -> String
        var controlSeams: @Sendable (_ localAddress: String?) -> ControlSession.Seams
        var controlTuning = ControlSession.Tuning()
        /// nil = BSD sockets.
        var channelFactory: MediaTransport.ChannelFactory?
        var mediaTuning = MediaTransport.Tuning()

        static let live = Seams(resolveIPv4: { try await IPv4Resolver.resolve($0) },
                                controlSeams: { ControlSession.Seams.live(localAddress: $0) })
    }

    /// Receives each new MediaTransport before it binds, so it can subscribe to
    /// `video` / `audio` ahead of the start burst (MediaTransport's contract).
    typealias MediaConsumer = @MainActor (MediaTransport) -> Void

    private(set) var state: State = .idle
    /// Refreshed once a second while media flows.
    private(set) var mediaStats: MediaTransport.Stats?
    /// fps / Mbps / decode / loss / BWE for the menu's quality badge and the
    /// stats overlay (LiveStats.swift), sampled by the same 1 Hz poll.
    let liveStats = LiveStatsModel()
    private(set) var control: ControlSession?
    private(set) var media: MediaTransport?
    private(set) var mediaParams: ControlSession.MediaParams?
    /// The server IPv4 the current session uses.
    private(set) var serverAddress: String?
    /// Latest decoded picture per tile; the session view's renderer reads it.
    let frames = VideoFrameStore()
    /// The host's cursor shape and the local pointer position (rendered over the video).
    let cursor = RemoteCursor()
    /// Two-way text clipboard (attached while a session's stream runs).
    let clipboard = ClipboardBridge()
    /// Sends pointer / keyboard input; nil until the stream has started.
    private(set) var input: InputController?
    /// Releases every held key and pointer button on the UI layer (weakly
    /// capturing the session view's `RemoteInputView`; a no-op once that view
    /// is gone). Called synchronously before any teardown, so the Mac never
    /// keeps input held after a disconnect, background, or failure.
    var releaseInput: (() -> Void)?
    /// Latest 0x451 backing size (pointer clamp) and backing/scaled factor.
    private var hostBacking: (width: Int, height: Int)?
    private var hostPointScale: CGFloat = 2
    /// Display sizing and in-band resizes (DisplayMode.swift).
    @ObservationIgnored private(set) var display: DisplayResizer!
    /// The session view's size in points and its screen scale (last reported).
    private var viewGeometry: (points: CGSize, scale: CGFloat)?
    /// The current session decoded its first picture.
    private(set) var hasFirstFrame = false
    /// A suspended session is being resumed: from the background close until
    /// the resumed session's first picture (or its failure).
    private(set) var isReconnecting = false
    /// TCP-only fallback (Task 19): why this session shows the framebuffer
    /// path instead of HP video (nil = HP). Drives the "Reduced performance" badge.
    private(set) var fallbackReason: MediaFallbackPolicy.Reason?
    @ObservationIgnored private var fallbackPolicy = MediaFallbackPolicy()
    @ObservationIgnored private var framebuffer: FramebufferPipeline?
    /// "Signing in…" → "Securing…" → "Starting video…" (ConnectionStage.swift).
    private(set) var stage: ConnectionStage = .idle
    /// The Mac's model identifier (DeviceInfo 0x456), once this session sent it.
    private(set) var deviceModel: String?
    /// The Mac's key fingerprint and sign-in method of the current (or last
    /// successful) session; HostConnector pins / checks it on the saved host.
    private(set) var serverKeySHA256: Data?
    private(set) var authMethod: AuthResult.Method?
    /// Set when a connect failed with `AuthError.serverKeyMismatch`;
    /// cleared by the next connect (or `clearIdentityChange`).
    private(set) var identityChange: IdentityChange?
    /// The last connect failed because the Mac asked for the legacy (non-SRP)
    /// sign-in and the host doesn't allow it (`AuthError.legacyAuthRequired`).
    private(set) var legacyAuthRequested = false
    /// The last picture of the session torn down most recently (downscaled,
    /// rendered off the main thread by FrameSnapshot): the "Reconnecting…"
    /// backdrop and the host card thumbnail. `serial` grows per capture.
    private(set) var lastPicture: (image: UIImage, serial: Int)?
    @ObservationIgnored private var pictureSerial = 0
    /// The last connect request (cleared by a user disconnect).
    private(set) var lastRequest: ConnectRequest?
    private(set) var lifecycle = LifecyclePolicy()
    /// The session view is up: connected, suspended, or reconnecting.
    var isSessionActive: Bool {
        switch state {
        case .connected, .suspended: true
        case .connecting: isReconnecting
        case .idle, .failed: false
        }
    }
    #if DEBUG
    /// Per-session DEBUG packet tap (video capture), created on the video task.
    var makeVideoTap: (@Sendable () -> (any VideoPacketTap)?)?
    #endif

    private let policy: Policy
    private let seams: Seams
    private var generation = 0
    private var connectTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var mediaFailureTask: Task<Void, Never>?
    private var pendingTeardown: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var audioPlayer: AudioPlayer?
    private var firstFrameTask: Task<Void, Never>?
    private var mediaConsumers: [MediaConsumer] = []
    /// `generation` as of the last `startVideo`, readable from the frame
    /// store's callback thread: a first frame is credited only to the session
    /// that was current when it was decoded.
    private let videoGeneration = LockedValue(0)

    /// Server IPv4s with a live session in this process: the HP ports are fixed
    /// (P/P+1 on both ends), so a second session to the same server would
    /// share the exact UDP 4-tuple.
    private static var activeServers: Set<String> = []

    init(policy: Policy = Policy(), seams: Seams = .live) {
        self.policy = policy
        self.seams = seams
        display = DisplayResizer(hooks: .init(send: { [weak self] g in await self?.requestDisplay(g) }))
        let videoGeneration = videoGeneration
        frames.onFirstFrame = { [weak self] pb in
            let gen = videoGeneration.value
            Log.video.info("M4 first frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) "
                           + "pixfmt=\(CVPixelBufferGetPixelFormatType(pb).fourCC)")
            Task { @MainActor in self?.firstFrameArrived(gen) }
        }
    }

    var isBusy: Bool { state == .connecting }

    /// A picture decoded for session `gen`; ignored if that session is gone
    /// (a late hop must not clear "Reconnecting…" for the next one).
    private func firstFrameArrived(_ gen: Int) {
        guard gen == generation else { return }
        hasFirstFrame = true
        isReconnecting = false
        stage = stage.advanced(by: .firstFrame)
        firstFrameTask?.cancel(); firstFrameTask = nil
    }

    static let noPictureMessage = "Connected, but no picture arrived from the Mac."

    /// Session `gen` is connected: a picture must follow (see the header).
    private func startFirstFrameDeadline(_ gen: Int, _ media: MediaTransport) {
        firstFrameTask?.cancel()
        guard !hasFirstFrame else { return }
        let nudge = policy.firstFrameKeyframeAfter, deadline = policy.firstFrameDeadline
        firstFrameTask = Task { [weak self] in
            if nudge < deadline {
                try? await Task.sleep(for: nudge)
                guard let self, !Task.isCancelled, self.isCurrent(gen), !self.hasFirstFrame else { return }
                let ssrcs = await media.activeVideoSSRCs
                var sent = 0
                for ssrc in ssrcs {
                    if await media.requestKeyframe(ssrc: ssrc) { sent += 1 }
                }
                Log.app.error("no picture \(nudge.ms) ms after connecting; requested a keyframe (\(sent)/\(ssrcs.count) tiles)")
            }
            try? await Task.sleep(for: deadline - min(nudge, deadline))
            guard let self, !Task.isCancelled, self.isCurrent(gen), !self.hasFirstFrame else { return }
            Log.app.error("no picture \(deadline.ms) ms after connecting; giving up")
            await self.end(gen, .failed(Self.noPictureMessage))
        }
    }

    /// Registers a consumer for every future session's MediaTransport.
    func addMediaConsumer(_ consumer: @escaping MediaConsumer) {
        mediaConsumers.append(consumer)
    }

    /// `localAddress` (DEBUG harness only) pins the TCP and UDP source address
    /// (the server sends media to the TCP peer address); nil lets the system choose.
    func connect(host: String, port: UInt16, username: String, password: String,
                 authPolicy: AuthPolicy = AuthPolicy(),
                 order: ControlSession.StartupOrder = .reference, localAddress: String? = nil) async {
        guard connectTask == nil, control == nil, media == nil, state != .connecting else { return }
        let request = ConnectRequest(host: host, port: port, username: username, password: password,
                                     order: order, localAddress: localAddress, authPolicy: authPolicy)
        identityChange = nil
        legacyAuthRequested = false
        serverKeySHA256 = nil
        authMethod = nil
        lifecycle.userConnected()
        isReconnecting = false
        lastRequest = request
        await begin(request)
    }

    private func begin(_ r: ConnectRequest) async {
        guard connectTask == nil, control == nil, media == nil, state != .connecting else { return }
        generation += 1
        let gen = generation
        state = .connecting
        stage = stage.advanced(by: .started)
        deviceModel = nil
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(gen, host: r.host, port: r.port, username: r.username, password: r.password,
                           order: r.order, localAddress: r.localAddress, authPolicy: r.authPolicy)
        }
        connectTask = task
        await task.value
        if connectTask == task { connectTask = nil }
    }

    func clearIdentityChange() { identityChange = nil }

    func disconnect() async {
        lifecycle.userDisconnected()
        lastRequest = nil
        isReconnecting = false
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        state = .idle
        await teardown()
    }

    // MARK: background / foreground

    /// The scene went to the background: close a session (or a connect in
    /// progress) now, so the Mac ends sharing; reconnect on `becomeActive`.
    func enterBackground() async {
        let status: LifecyclePolicy.SessionStatus = switch state {
        case .connected: .connected
        case .connecting: .connecting
        default: .none
        }
        guard lifecycle.didEnterBackground(session: status) == .suspend else { return }
        Log.app.info("app backgrounded: closing the session (will reconnect when active)")
        await suspend(background: true)
    }

    /// The scene is active again: resume a suspended session.
    func becomeActive() async {
        switch lifecycle.didBecomeActive(canReconnect: lastRequest != nil) {
        case .reconnect:
            await reconnect()
        case .none, .suspend:
            if state == .suspended { state = .idle; isReconnecting = false }
            clipboard.appBecameActive()
        }
    }

    private func suspend(background: Bool = false) async {
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        state = .suspended
        isReconnecting = true
        await teardown(background: background)
    }

    private func reconnect() async {
        guard let r = lastRequest else { return }
        // A reconnect scheduled by a failure may run after the app left the
        // foreground: never connect from the background; resume on activation.
        guard lifecycle.isForeground else {
            Log.app.info("reconnect deferred: app not in the foreground")
            lifecycle.deferReconnect()
            return
        }
        Log.app.info("reconnecting to \(private: r.host)")
        isReconnecting = true
        await begin(r)
    }

    /// Every error that ends session `gen` comes here: the lifecycle policy
    /// may turn it into a quiet suspend or a reconnect; otherwise the user
    /// sees UserFacingError's message.
    private func fail(_ gen: Int, _ error: Error) async {
        guard gen == generation else { return }
        let kind = UserFacingError.kind(of: error)
        let wasConnected = if case .connected = state { true } else { false }
        if case AuthError.serverKeyMismatch(let presented) = error {
            identityChange = IdentityChange(host: lastRequest?.host ?? "", presentedSHA256: presented)
            return await end(gen, .failed(ControlSession.identityChangedMessage))
        }
        if case AuthError.legacyAuthRequired = error { legacyAuthRequested = true }
        Log.app.error("session failed (\(kind), connected=\(wasConnected)): \(ControlSession.describe(error))")
        switch lifecycle.sessionFailed(kind: kind, wasConnected: wasConnected, canReconnect: lastRequest != nil) {
        case .suspend:
            await suspend()
        case .reconnect:
            await suspend()
            Task { [weak self] in await self?.reconnect() }
        case .none:
            // A reset before the session was up is not "the Mac ended the session".
            let message = kind == .peerEnded && !wasConnected
                ? UserFacingError.lostMessage : UserFacingError.message(for: error)
            await end(gen, .failed(message))
        }
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func run(_ gen: Int, host: String, port: UInt16, username: String, password: String,
                     order: ControlSession.StartupOrder, localAddress: String?, authPolicy: AuthPolicy) async {
        // Never overlap a previous session's sockets.
        await pendingTeardown?.value
        guard isCurrent(gen) else { return }

        // 1) One IPv4 literal for TCP and UDP (session._resolve_host_ipv4).
        let ip: String
        do {
            ip = try await seams.resolveIPv4(host)
        } catch {
            guard isCurrent(gen) else { return }
            return await fail(gen, error)
        }
        guard isCurrent(gen) else { return }
        guard Self.activeServers.insert(ip).inserted else {
            let shown = ip == host ? host : "\(host) (\(ip))"
            return await end(gen, .failed("Already connected to \(shown). Disconnect that session first."))
        }
        serverAddress = ip
        Log.app.info("connecting to \(private: host) as \(private: ip)")
        fallbackPolicy.reset()
        let framebufferOnly = lastRequest?.framebufferOnly ?? (Self.forceTCP == "connect" ? .forced : nil)

        // 2) UDP first, consumers attached before any packet can arrive.
        let media = MediaTransport(config: .init(host: ip, controlPort: port, localAddress: localAddress),
                                   tuning: seams.mediaTuning, channelFactory: seams.channelFactory)
        self.media = media
        startVideo(media, gen)
        startAudio(media)
        for consume in mediaConsumers { consume(media) }
        watchFailures(media, gen)
        do {
            try await media.open()
        } catch {
            guard isCurrent(gen) else { return }
            Log.app.error("media open failed: \(error)")
            return await fail(gen, error)
        }
        guard isCurrent(gen) else { return }
        startStatsPolling(media)

        let view = viewGeometry ?? Self.sceneGeometry()
        display.setMode(.stored())
        let mode = display.mode
        // matchMac: ControlSession sends a bare descriptor at the Mac's ServerInit size instead.
        let geometry = mode.geometry(viewPoints: view.points, scale: view.scale)
            ?? DisplayMode.fitRetina.geometry(viewPoints: view.points, scale: view.scale)
            ?? DisplayGeometry(logicalWidth: 1376, logicalHeight: 1032, hidpiScale: 2)
        let (logical, backing) = (geometry.logicalSize, geometry.backingSize)
        hostBacking = nil
        hostPointScale = logical.width > 0 ? backing.width / logical.width : 2
        cursor.setPointScale(hostPointScale)
        Log.app.info("display: mode \(mode.rawValue), view \(Int(view.points.width))x\(Int(view.points.height))pt "
                     + "@\(view.scale)x → \(geometry)")
        var config = ControlSession.Config(host: ip, port: port, username: username, password: password,
                                           logicalSize: logical, backingSize: backing, startupOrder: order)
        config.dynamicDisplay = mode.isDynamic
        config.authPolicy = authPolicy
        config.framebufferOnly = framebufferOnly != nil
        config.fallbackOnMediaFailure = true
        config.onMilestone = { [weak self] m in Task { @MainActor in self?.milestone(m, gen) } }
        let attempts = max(1, policy.burstRetryAttempts)
        for attempt in 1...attempts {
            let session = ControlSession(config: config, tuning: seams.controlTuning,
                                         seams: seams.controlSeams(localAddress))
            self.control = session
            cursor.reset()
            let params: ControlSession.MediaParams
            activation: do {
                params = try await session.start()
                guard isCurrent(gen) else { return }
                if params.framebufferOnly { break activation }
                try await media.activate(.init(keys: params.keys,
                                               ourVideoSSRC: MediaOffer.extractSSRC(params.videoOffer, isVideo: true),
                                               ourAudioSSRC: MediaOffer.extractSSRC(params.audioOffer, isVideo: false)))
            } catch {
                guard isCurrent(gen) else { return }
                // A handshake that died while our UDP sends were blocked:
                // the UDP errno says more than TCP's (EPERM / EACCES: Local
                // Network denied; routing errors: the Mac isn't reachable).
                if let blocked = await media.startupBlockedErrno {
                    guard isCurrent(gen) else { return }
                    Log.app.error("control start failed (\(error)) while UDP sends are blocked (errno \(blocked))")
                    return await fail(gen, MediaTransportError.localNetworkBlocked(errno: blocked))
                }
                guard isCurrent(gen) else { return }
                return await fail(gen, error)
            }
            guard isCurrent(gen) else { return }
            mediaParams = params
            serverKeySHA256 = params.serverKeySHA256
            authMethod = params.authMethod
            // Pin for this session's reconnects (TOFU; a mismatch already failed).
            if lastRequest?.authPolicy.pinnedKeySHA256 == nil, let key = params.serverKeySHA256 {
                lastRequest?.authPolicy.pinnedKeySHA256 = key
            }
            watch(session, gen)

            // Mode of `display.start` once the picture flows (HP or fallback).
            let mac = DisplayGeometry.matching(serverWidth: params.serverInit.width,
                                               serverHeight: params.serverInit.height)
            if params.framebufferOnly {
                // No media keys: framebuffer path at once (negotiation failed,
                // or a framebuffer-only reconnect).
                let reason = framebufferOnly ?? .negotiationFailed
                if reason == .negotiationFailed { _ = fallbackPolicy.negotiationFailed() }
                guard await enterFallback(gen, session, params, reason: reason, closeMedia: true) else { return }
                startFallbackStream(session, params, initial: mode.isDynamic ? geometry : mac, mac: mac)
                return
            }

            let outcome = await media.burstOutcome()
            guard isCurrent(gen) else { return }
            if case .starved(let packets) = outcome,
               case .fallBack(let reason) = fallbackPolicy.burstStarved(packets: packets, attempt: attempt,
                                                                       attempts: attempts) {
                await reconnectWithoutMediaOffer(gen, reason: reason)
                return
            }
            switch outcome {
            case .started:
                frames.configure(canvas: CGSize(width: params.canvas.width, height: params.canvas.height))
                startInput(session, params)
                display.start(initial: mode.isDynamic ? geometry : mac, mac: mac)
                clipboard.start(send: { try await session.send($0) })
                state = .connected(canvasWidth: params.canvas.width, canvasHeight: params.canvas.height)
                stage = stage.advanced(by: .streamStarted)
                startFirstFrameDeadline(gen, media)
                if Self.forceTCP == "inplace" {
                    _ = await enterFallback(gen, session, params, reason: .forced, closeMedia: false)
                }
                return
            case .failed(let error):
                return await fail(gen, error)
            case .starved(let packets):
                // Drop only the TCP side; the UDP sockets stay bound.
                eventsTask?.cancel(); eventsTask = nil
                control = nil
                mediaParams = nil
                await session.close()
                guard isCurrent(gen) else { return }
                await media.resetForRetry()
                guard isCurrent(gen) else { return }
                if attempt < attempts {
                    Log.app.error("burst starved (no-video-rtp, \(packets) pkts); full reconnect \(attempt)/\(attempts)")
                    try? await Task.sleep(for: policy.burstRetrySleep)
                    guard isCurrent(gen) else { return }
                } else {
                    let msg = "HP stream never started: \(packets) video packets arrived across \(attempts) fresh "
                        + "handshakes. On the Mac, toggle Screen Sharing off and on, then reconnect."
                    Log.app.error(msg)
                    return await end(gen, .failed(msg))
                }
            }
        }
    }

    /// Ends the session of generation `gen` (if still current) in `final`.
    private func end(_ gen: Int, _ final: State) async {
        guard gen == generation else { return }
        isReconnecting = false
        // Nothing will reconnect with them: drop the credentials.
        if !lifecycle.pendingReconnect { lastRequest = nil }
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        state = final
        await teardown()
    }

    /// Detaches everything synchronously, then closes it: the TCP control
    /// connection first (its close awaited, capped at
    /// `policy.controlCloseTimeout`), then the media sockets. The returned
    /// await completes when all of it is closed. A later connect waits for it.
    private func teardown(background: Bool = false) async {
        eventsTask?.cancel(); eventsTask = nil
        firstFrameTask?.cancel(); firstFrameTask = nil
        framebuffer?.stop(); framebuffer = nil
        fallbackReason = nil
        statsTask?.cancel(); statsTask = nil
        mediaFailureTask?.cancel(); mediaFailureTask = nil
        videoTask?.cancel(); videoTask = nil
        audioTask?.cancel(); audioTask = nil
        audioPlayer?.stop(); audioPlayer = nil
        // Never leave a key or pointer button held on the Mac: release
        // everything on the UI layer at once, synchronously (before `input`
        // itself is cleared below), so the Mac sees the releases as soon as
        // possible. The flush that gets them onto the wire needs an await
        // (below, inside `work`): it must not land between clearing `state`
        // and clearing `input`/`media`, which callers (and tests) read as
        // one atomic transition.
        releaseInput?()
        clipboard.stop()
        display.stop()
        let input = input
        self.input = nil
        cursor.reset()
        let (c, m, server) = (control, media, serverAddress)
        control = nil
        media = nil
        mediaParams = nil
        serverAddress = nil
        // The last picture, for the reconnect backdrop and the card
        // thumbnail: taken before the reset drops the buffers, rendered off
        // the main thread.
        stage = stage.advanced(by: .ended)
        capturePicture()
        // New epoch: late VideoToolbox callbacks are dropped and the pixel
        // buffers are freed (the layer keeps showing the last picture).
        frames.reset()
        let previous = pendingTeardown
        let closeTimeout = policy.controlCloseTimeout
        let inputFlushTimeout = policy.inputFlushTimeout
        let work = Task { @MainActor [weak self] in
            await previous?.value
            // Give whatever `releaseInput` just queued a bounded chance to
            // actually reach the control channel before `input` (and then
            // the control channel itself) is closed.
            if let input {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await input.flush() }
                    group.addTask { try? await Task.sleep(for: inputFlushTimeout) }
                    await group.next()
                    group.cancelAll()
                }
                input.close()
            }
            // TCP first: the Mac ends the session (and display privacy) when
            // it sees this close, so it must go out before anything else.
            if let c {
                let started = ContinuousClock.now
                let confirmed = await c.closeAndWait(timeout: closeTimeout)
                let what = background ? "background close" : "control close"
                if confirmed {
                    Log.app.info("\(what) confirmed (\((ContinuousClock.now - started).ms)ms)")
                } else {
                    Log.app.error("\(what) timed out")
                }
            }
            if let m {
                let s = await m.stats
                self?.mediaStats = s
                await m.close()
            }
            if let server { Self.activeServers.remove(server) }
        }
        pendingTeardown = work
        await work.value
        if pendingTeardown == work { pendingTeardown = nil }
    }

    /// A connect milestone from session `gen` (ControlSession's arrive on
    /// their own hop; the stage never steps back, so order doesn't matter).
    private func milestone(_ m: ConnectionMilestone, _ gen: Int) {
        guard gen == generation else { return }
        stage = stage.advanced(by: m)
    }

    private func capturePicture() {
        guard let snap = FrameSnapshot.capture(frames) else { return }
        pictureSerial += 1
        let serial = pictureSerial
        Task { [weak self] in
            guard let image = await snap.image() else { return }
            guard let self, serial > (self.lastPicture?.serial ?? 0) else { return }
            self.lastPicture = (image, serial)
        }
    }

    /// Feeds control events to input and the cursor, and notices when the
    /// session ends; media goes down with it.
    private func watch(_ session: ControlSession, _ gen: Int) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in session.events {
                guard let self, self.control === session else { continue }
                self.apply(event)
            }
            let failure = await session.failure
            guard let self, !Task.isCancelled, self.control === session else { return }
            if let failure {
                await self.fail(gen, failure)
            } else {
                await self.end(gen, .idle)
            }
        }
    }

    /// input.py set_server_dims (from the 0x451 handler) and the cursor cache.
    private func apply(_ event: ServerEvent) {
        switch event {
        case .displayLayout(let l):
            if l.backingWidth > 0, l.backingHeight > 0 {
                let previous = hostBacking
                hostBacking = (l.backingWidth, l.backingHeight)
                input?.setServerDims(width: l.backingWidth, height: l.backingHeight)
                // One canvas source of truth: the frame store (video layout
                // and drawCursor's CompositeLayout) and the input mapping
                // must agree on the same backing size. On a resize (RFC
                // §10.9) the store switches to it with the new stream's first
                // picture, holding the last one until then.
                let canvas = CGSize(width: l.backingWidth, height: l.backingHeight)
                if fallbackReason != nil {
                    // The framebuffer path sizes the store itself (FramebufferPipeline).
                } else if let previous, previous != (l.backingWidth, l.backingHeight) {
                    Log.app.info("display: Mac resized to \(l.scaledWidth)x\(l.scaledHeight)pt "
                                 + "(\(l.backingWidth)x\(l.backingHeight)px), was \(previous.width)x\(previous.height)px")
                    frames.holdForResize(canvas: canvas)
                    if let media { Task { await media.expectNewGroup() } }
                } else {
                    frames.configure(canvas: canvas)
                }
                if l.scaledWidth > 0 {
                    hostPointScale = CGFloat(l.backingWidth) / CGFloat(l.scaledWidth)
                    input?.pointScale = hostPointScale
                    cursor.setPointScale(hostPointScale)
                }
            }
        case .cursorStore(let id, let hotspot, let size, let rgba):
            cursor.store(id: id, hotspot: hotspot, size: size, rgba: rgba)
        case .cursorSelect(let id):
            cursor.select(id: id)
        case .miscStatus, .clipboard:
            clipboard.handle(event)
        case .deviceInfo(let model):
            // Server text (L3): sanitized and capped before the UI / SwiftData.
            let clean = ServerText.sanitize(model, maxLength: 64)
            deviceModel = clean.isEmpty ? nil : clean
        default:
            break
        }
    }

    /// session.py step 9: the InputController over the control channel,
    /// clamped to the canvas (then to each 0x451's backing size).
    private func startInput(_ session: ControlSession, _ params: ControlSession.MediaParams) {
        let input = InputController(contentKey: params.contentKey, serverWidth: params.canvas.width,
                                    serverHeight: params.canvas.height,
                                    send: { try await session.send($0) })
        if let b = hostBacking { input.setServerDims(width: b.width, height: b.height) }
        input.pointScale = hostPointScale
        // Settings → Scroll speed, read once per session (InputController.scrollSpeed).
        input.scrollSpeed = CGFloat(ScreenerSettings.scrollSpeed())
        self.input?.close()
        self.input = input
        Log.input.info("M5 input ready: canvas \(input.serverWidth)x\(input.serverHeight), pointer via 0x10")
    }

    /// The single consumer of `media.video` for this session (see the header).
    private func startVideo(_ media: MediaTransport, _ gen: Int) {
        frames.reset()
        videoGeneration.value = gen
        hasFirstFrame = false
        let hooks = VideoPipeline.Hooks(
            activeSSRCs: { await media.activeVideoSSRCs },
            requestKeyframe: { _ = await media.requestKeyframe(ssrc: $0) },
            notePublished: { await media.notePublished() },
            onNotHEVC: { [weak self] in await self?.videoIsNotHEVC(gen) },
            ackLTR: { await media.sendLTRAck(timestamp: $0, everyPicture: $1) },
            onHardFailure: { [weak self] in await self?.decoderHardFailure(gen) })
        let pipeline = VideoPipeline(store: frames, hooks: hooks)
        #if DEBUG
        let makeTap = makeVideoTap
        #else
        let makeTap: (@Sendable () -> (any VideoPacketTap)?)? = nil
        #endif
        videoTask?.cancel()
        videoTask = Task.detached { await pipeline.run(media.video, tap: makeTap?()) }
    }

    /// The single consumer of `media.audio` for this session (see the header).
    private func startAudio(_ media: MediaTransport) {
        audioTask?.cancel()
        audioPlayer?.stop()
        let player = AudioPlayer()
        audioPlayer = player
        audioTask = Task.detached {
            for await packet in media.audio { player.handle(packet) }
        }
    }

    static let notHEVCMessage = "The Mac sent H.264 video (server chose H.264); Screener needs HEVC. "
        + "Make sure High Performance mode is available on the Mac (Apple silicon, macOS 14 or later)."

    private func videoIsNotHEVC(_ gen: Int) async {
        guard gen == generation else { return }
        Log.app.error(Self.notHEVCMessage)
        await end(gen, .failed(Self.notHEVCMessage))
    }

    /// A media socket died: the whole session fails.
    private func watchFailures(_ media: MediaTransport, _ gen: Int) {
        mediaFailureTask?.cancel()
        mediaFailureTask = Task { [weak self] in
            for await f in media.failures {
                guard let self, !Task.isCancelled, self.media === media else { return }
                guard self.fallbackReason == nil else {
                    // The picture comes over TCP now; audio may be lost.
                    Log.app.error("media channel failed during the TCP fallback (ignored): \(f)")
                    return
                }
                await self.fail(gen, f)
                return
            }
        }
    }

    private func startStatsPolling(_ media: MediaTransport) {
        statsTask?.cancel()
        liveStats.reset()
        let epoch = ContinuousClock.now
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                let s = await media.stats
                guard let self, self.media === media else { return }
                self.mediaStats = s
                let t = ContinuousClock.now - epoch
                self.liveStats.ingest(media: s, video: self.frames.liveTotals,
                                      now: Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: TCP-only fallback (Task 19)

    static let framebufferBrokenMessage = "The picture stream from the Mac broke. Reconnect to continue."

    /// DEBUG live testing (ExperimentEnv; Release ignores it):
    /// SCREENER_FORCE_TCP=connect connects without a media offer (the good
    /// path). =inplace deliberately exercises the broken mid-session switch
    /// (SetEncodings after HP media started) so it can be compared against
    /// `reconnectWithoutMediaOffer`; do not use it as a real fallback path.
    static let forceTCP: String? = {
        let v = ExperimentEnv.current["SCREENER_FORCE_TCP"]
        if let v { Log.app.info("TCP fallback forced: SCREENER_FORCE_TCP=\(v)") }
        return v
    }()

    /// Switches session `gen` (control `session`) to the framebuffer path:
    /// stops HP video, resets the frame store, starts a FramebufferPipeline
    /// and ControlSession's framebuffer mode. `closeMedia`: no media keys
    /// were installed, so the UDP transport is useless. False if the session
    /// went away or failed meanwhile.
    private func enterFallback(_ gen: Int, _ session: ControlSession, _ params: ControlSession.MediaParams,
                               reason: MediaFallbackPolicy.Reason, closeMedia: Bool) async -> Bool {
        guard isCurrent(gen), control === session, framebuffer == nil else { return false }
        Log.app.error("TCP fallback: \(reason); switching to the framebuffer path (reduced performance)")
        fallbackReason = reason
        if reason == .negotiationFailed, lastRequest?.framebufferOnly == nil {
            // Negotiation takes ~80 s to fail: this session's reconnects skip it.
            lastRequest?.framebufferOnly = reason
        }
        videoTask?.cancel(); videoTask = nil
        firstFrameTask?.cancel(); firstFrameTask = nil
        frames.reset()
        videoGeneration.value = gen
        if closeMedia, let m = media {
            Task { await m.close() }
            Log.app.info("TCP fallback: media transport closed (no media keys)")
        }
        let size = hostBacking ?? (params.canvas.width, params.canvas.height)
        let (format, _) = ControlSession.framebufferPixelFormat(serverInit: params.serverInit.pixelFormat)
        let pipeline = FramebufferPipeline(
            store: frames, format: format, size: size,
            hooks: .init(updateConsumed: { Task { await session.framebufferUpdateConsumed() } },
                         failed: { [weak self] error in
                             Task { @MainActor in await self?.framebufferFailed(gen, error) }
                         }))
        framebuffer = pipeline
        do {
            try await session.enterFramebufferMode(serverInit: params.serverInit, sink: { pipeline.submit($0) })
        } catch {
            guard isCurrent(gen) else { return false }
            await fail(gen, error)
            return false
        }
        guard isCurrent(gen) else { return false }
        startFallbackFirstFrameDeadline(gen)
        return true
    }

    /// Media already activated on this connection (burst starved, or hard
    /// decoder failures): tears the session down cleanly and reconnects the
    /// same host without a media offer, instead of switching this connection
    /// to the framebuffer path in place (macOS ignores that mid-session
    /// SetEncodings; see the header). `fallbackReason` is set first so the
    /// "Reduced performance" badge/toast is already up while the teardown
    /// and reconnect run. `lastRequest.framebufferOnly` sticks for the rest
    /// of this session (its later reconnects skip HP too); a fresh
    /// `connect()` or the next session starts clean and retries HP.
    private func reconnectWithoutMediaOffer(_ gen: Int, reason: MediaFallbackPolicy.Reason) async {
        guard isCurrent(gen), lastRequest != nil else { return }
        Log.app.error("TCP fallback: \(reason); reconnecting \(private: lastRequest?.host ?? "?") without a media offer (reduced performance)")
        fallbackReason = reason
        lastRequest?.framebufferOnly = reason
        await suspend()
        Task { [weak self] in await self?.reconnect() }
    }

    /// The `.started` set-up for a session that went straight to the framebuffer path.
    private func startFallbackStream(_ session: ControlSession, _ params: ControlSession.MediaParams,
                                     initial: DisplayGeometry?, mac: DisplayGeometry?) {
        let size = hostBacking ?? (params.canvas.width, params.canvas.height)
        startInput(session, params)
        display.start(initial: initial, mac: mac)
        clipboard.start(send: { try await session.send($0) })
        state = .connected(canvasWidth: size.width, canvasHeight: size.height)
        stage = stage.advanced(by: .streamStarted)
    }

    /// A hard decoder failure in session `gen` (VideoPipeline hook).
    private func decoderHardFailure(_ gen: Int) async {
        guard gen == generation, control != nil, mediaParams != nil, case .connected = state else { return }
        guard case .fallBack(let reason) = fallbackPolicy.decoderFailed(at: .now) else { return }
        await reconnectWithoutMediaOffer(gen, reason: reason)
    }

    /// The framebuffer path must show a picture within `firstFrameDeadline`
    /// (`firstFrameArrived` cancels this): else re-establish the session
    /// without a media offer, once; then give up.
    private func startFallbackFirstFrameDeadline(_ gen: Int) {
        firstFrameTask?.cancel()
        let deadline = policy.firstFrameDeadline
        firstFrameTask = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self, !Task.isCancelled, self.isCurrent(gen) else { return }
            if self.lastRequest != nil, self.lastRequest?.framebufferOnly == nil {
                Log.app.error("TCP fallback: no picture \(deadline.ms) ms after switching")
                await self.reconnectWithoutMediaOffer(gen, reason: self.fallbackReason ?? .noVideo(packets: 0))
            } else {
                Log.app.error("TCP fallback: no picture \(deadline.ms) ms after switching; giving up")
                await self.end(gen, .failed(Self.noPictureMessage))
            }
        }
    }

    private func framebufferFailed(_ gen: Int, _ error: Error) async {
        guard gen == generation else { return }
        Log.app.error("TCP fallback: framebuffer stream failed: \(error)")
        await end(gen, .failed(Self.framebufferBrokenMessage))
    }

    // MARK: display (Task 21)

    /// The session view's size changed (rotation, Stage Manager): the resizer
    /// debounces it into a dynamic 0x1d when the session is up.
    func viewSizeChanged(points: CGSize, scale: CGFloat) {
        guard points.width > 0, points.height > 0 else { return }
        Log.app.info("display: view \(Int(points.width))x\(Int(points.height))pt @\(scale)x")
        viewGeometry = (points, scale)
        display.viewChanged(points: points, scale: scale)
    }

    /// The user picked a display mode (stored by the menu; applies now when dynamic).
    func setDisplayMode(_ mode: DisplayMode) {
        display.setMode(mode)
    }

    private func requestDisplay(_ g: DisplayGeometry) async {
        guard let control, case .connected = state else { return }
        do {
            try await control.requestDisplay(g)
        } catch {
            Log.app.error("display: resize request failed: \(ControlSession.describe(error))")
        }
    }

    /// The UI text for `error` (UserFacingError: no raw errno text).
    static func describe(_ error: Error) -> String { UserFacingError.message(for: error) }

    /// Before the session view reports its size: the window scene's size in
    /// points (the window in Stage Manager, the screen in full screen, in the
    /// current orientation) and its screen's native scale.
    static func sceneGeometry() -> (points: CGSize, scale: CGFloat) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let points = scene?.coordinateSpace.bounds.size ?? CGSize(width: 1376, height: 1032)
        return (points, scene?.screen.nativeScale ?? 2)
    }
}

/// A lock-protected value shared with non-isolated callbacks.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
