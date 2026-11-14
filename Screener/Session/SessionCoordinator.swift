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
// Concurrency: every connect runs in `connectTask` under a generation number.
// `disconnect()` and any session failure bump the generation, cancel the task
// and tear down; the connect task re-checks its generation after every await
// and never touches shared state once it is stale. Teardown awaits the media
// sockets' close, and the next connect waits for a pending teardown, so the
// UDP ports are never bound twice by this app at once.
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
        case failed(String)
    }

    struct Policy: Sendable {
        var burstRetryAttempts = 3                       // _BURST_RETRY_ATTEMPTS
        var burstRetrySleep: Duration = .milliseconds(800) // _BURST_RETRY_SLEEP_S
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
    private(set) var control: ControlSession?
    private(set) var media: MediaTransport?
    private(set) var mediaParams: ControlSession.MediaParams?
    /// The server IPv4 the current session uses.
    private(set) var serverAddress: String?
    /// Latest decoded picture per tile; the session view's renderer reads it.
    let frames = VideoFrameStore()
    /// The current session decoded its first picture.
    private(set) var hasFirstFrame = false
    /// Connected: the session view is up.
    var isSessionActive: Bool { if case .connected = state { true } else { false } }
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
    private var mediaConsumers: [MediaConsumer] = []

    /// Server IPv4s with a live session in this process: the HP ports are fixed
    /// (P/P+1 on both ends), so a second session to the same server would
    /// share the exact UDP 4-tuple.
    private static var activeServers: Set<String> = []

    init(policy: Policy = Policy(), seams: Seams = .live) {
        self.policy = policy
        self.seams = seams
        frames.onFirstFrame = { [weak self] pb in
            Log.video.info("M4 first frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) "
                           + "pixfmt=\(CVPixelBufferGetPixelFormatType(pb).fourCC)")
            Task { @MainActor in self?.hasFirstFrame = true }
        }
    }

    var isBusy: Bool { state == .connecting }

    /// Registers a consumer for every future session's MediaTransport.
    func addMediaConsumer(_ consumer: @escaping MediaConsumer) {
        mediaConsumers.append(consumer)
    }

    /// `localAddress` (DEBUG harness only) pins the TCP and UDP source address
    /// (the server sends media to the TCP peer address); nil lets the system choose.
    func connect(host: String, port: UInt16, username: String, password: String,
                 order: ControlSession.StartupOrder = .reference, localAddress: String? = nil) async {
        guard connectTask == nil, control == nil, media == nil, state != .connecting else { return }
        generation += 1
        let gen = generation
        state = .connecting
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(gen, host: host, port: port, username: username, password: password,
                            order: order, localAddress: localAddress)
        }
        connectTask = task
        await task.value
        if connectTask == task { connectTask = nil }
    }

    func disconnect() async {
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        state = .idle
        await teardown()
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func run(_ gen: Int, host: String, port: UInt16, username: String, password: String,
                     order: ControlSession.StartupOrder, localAddress: String?) async {
        // Never overlap a previous session's sockets.
        await pendingTeardown?.value
        guard isCurrent(gen) else { return }

        // 1) One IPv4 literal for TCP and UDP (session._resolve_host_ipv4).
        let ip: String
        do {
            ip = try await seams.resolveIPv4(host)
        } catch {
            guard isCurrent(gen) else { return }
            return await end(gen, .failed(Self.describe(error)))
        }
        guard isCurrent(gen) else { return }
        guard Self.activeServers.insert(ip).inserted else {
            let shown = ip == host ? host : "\(host) (\(ip))"
            return await end(gen, .failed("Already connected to \(shown). Disconnect that session first."))
        }
        serverAddress = ip
        Log.app.info("connecting to \(host) as \(ip)")

        // 2) UDP first, consumers attached before any packet can arrive.
        let media = MediaTransport(config: .init(host: ip, controlPort: port, localAddress: localAddress),
                                   tuning: seams.mediaTuning, channelFactory: seams.channelFactory)
        self.media = media
        startVideo(media, gen)
        for consume in mediaConsumers { consume(media) }
        watchFailures(media, gen)
        do {
            try await media.open()
        } catch {
            guard isCurrent(gen) else { return }
            Log.app.error("media open failed: \(error)")
            return await end(gen, .failed(Self.describe(error)))
        }
        guard isCurrent(gen) else { return }
        startStatsPolling(media)

        let (logical, backing) = Self.screenSizes()
        let config = ControlSession.Config(host: ip, port: port, username: username, password: password,
                                           logicalSize: logical, backingSize: backing, startupOrder: order)
        let attempts = max(1, policy.burstRetryAttempts)
        for attempt in 1...attempts {
            let session = ControlSession(config: config, tuning: seams.controlTuning,
                                         seams: seams.controlSeams(localAddress))
            self.control = session
            let params: ControlSession.MediaParams
            do {
                params = try await session.start()
                guard isCurrent(gen) else { return }
                try await media.activate(.init(keys: params.keys,
                                               ourVideoSSRC: MediaOffer.extractSSRC(params.videoOffer, isVideo: true),
                                               ourAudioSSRC: MediaOffer.extractSSRC(params.audioOffer, isVideo: false)))
            } catch {
                guard isCurrent(gen) else { return }
                return await end(gen, .failed(Self.describe(error)))
            }
            guard isCurrent(gen) else { return }
            mediaParams = params
            watch(session, gen)

            let outcome = await media.burstOutcome()
            guard isCurrent(gen) else { return }
            switch outcome {
            case .started:
                frames.configure(canvas: CGSize(width: params.canvas.width, height: params.canvas.height))
                state = .connected(canvasWidth: params.canvas.width, canvasHeight: params.canvas.height)
                return
            case .failed(let why):
                return await end(gen, .failed(MediaTransportError.channelFailed(why).localizedDescription))
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
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        state = final
        await teardown()
    }

    /// Detaches everything synchronously, then closes it; the returned await
    /// completes when the sockets are closed. A later connect waits for it.
    private func teardown() async {
        eventsTask?.cancel(); eventsTask = nil
        statsTask?.cancel(); statsTask = nil
        mediaFailureTask?.cancel(); mediaFailureTask = nil
        videoTask?.cancel(); videoTask = nil
        let (c, m, server) = (control, media, serverAddress)
        control = nil
        media = nil
        mediaParams = nil
        serverAddress = nil
        let previous = pendingTeardown
        let work = Task { @MainActor [weak self] in
            await previous?.value
            if let m {
                let s = await m.stats
                self?.mediaStats = s
                await m.close()
            }
            if let c { await c.close() }
            if let server { Self.activeServers.remove(server) }
        }
        pendingTeardown = work
        await work.value
        if pendingTeardown == work { pendingTeardown = nil }
    }

    /// Drains control events (nothing consumes them yet) and notices when the
    /// session ends; media goes down with it.
    private func watch(_ session: ControlSession, _ gen: Int) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await _ in session.events {}
            let failure = await session.failure
            guard let self, !Task.isCancelled, self.control === session else { return }
            await self.end(gen, failure.map { .failed(ControlSession.describe($0)) } ?? .idle)
        }
    }

    /// The single consumer of `media.video` for this session (see the header).
    private func startVideo(_ media: MediaTransport, _ gen: Int) {
        frames.reset()
        hasFirstFrame = false
        let hooks = VideoPipeline.Hooks(
            activeSSRCs: { await media.activeVideoSSRCs },
            requestKeyframe: { _ = await media.requestKeyframe(ssrc: $0) },
            notePublished: { await media.notePublished() },
            onNotHEVC: { [weak self] in await self?.videoIsNotHEVC(gen) })
        let pipeline = VideoPipeline(store: frames, hooks: hooks)
        #if DEBUG
        let makeTap = makeVideoTap
        #else
        let makeTap: (@Sendable () -> (any VideoPacketTap)?)? = nil
        #endif
        videoTask?.cancel()
        videoTask = Task.detached { await pipeline.run(media.video, tap: makeTap?()) }
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
                await self.end(gen, .failed(Self.describe(f)))
                return
            }
        }
    }

    private func startStatsPolling(_ media: MediaTransport) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                let s = await media.stats
                guard let self, self.media === media else { return }
                self.mediaStats = s
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as MediaTransportError: return e.localizedDescription
        case let e as IPv4Resolver.Failure: return e.localizedDescription
        default: return ControlSession.describe(error)
        }
    }

    /// Advertised display: the window scene's screen in points (logical) and
    /// `points × nativeScale` (backing). Using bounds × scale rather than
    /// `nativeBounds` keeps the backing size in the current orientation.
    static func screenSizes() -> (logical: CGSize, backing: CGSize) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let logical = screen?.bounds.size ?? CGSize(width: 1376, height: 1032)
        let scale = screen?.nativeScale ?? 2
        return (logical, CGSize(width: logical.width * scale, height: logical.height * scale))
    }
}
