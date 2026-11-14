// Ported in part from iShareScreen src/isharescreen/proxy/session.py
// (_connect_internal, _handshake_with_reconnect) (AGPL-3.0)
//
// Owns one HP session: the TCP ControlSession and the UDP MediaTransport.
//   connect → bind UDP + punch (before the handshake, so the start burst is
//   never dropped) → control handshake → 0x1c answer → install media keys →
//   wait for the start burst.
// A starved burst (the host accepted the canvas but never streamed) is
// retried with a full fresh handshake, as _handshake_with_reconnect does:
// up to 3 attempts, 0.8 s apart. Later tasks extend this (decoder, input,
// reconnect policy).
import CoreGraphics
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

    private(set) var state: State = .idle
    /// Refreshed once a second while media flows.
    private(set) var mediaStats: MediaTransport.Stats?
    private(set) var control: ControlSession?
    private(set) var media: MediaTransport?
    private(set) var mediaParams: ControlSession.MediaParams?

    private let policy: Policy
    private var eventsTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var userClosed = false

    init(policy: Policy = Policy()) { self.policy = policy }

    var isBusy: Bool { state == .connecting }

    /// `localAddress` pins the TCP and UDP source address (the server sends
    /// media to the TCP peer address); nil lets the system choose.
    func connect(host: String, port: UInt16, username: String, password: String,
                 order: ControlSession.StartupOrder = .reference, localAddress: String? = nil) async {
        guard control == nil, state != .connecting else { return }
        userClosed = false
        state = .connecting
        let (logical, backing) = Self.screenSizes()
        let config = ControlSession.Config(host: host, port: port, username: username, password: password,
                                           logicalSize: logical, backingSize: backing, startupOrder: order)
        let attempts = max(1, policy.burstRetryAttempts)
        for attempt in 1...attempts {
            let media = MediaTransport(config: .init(host: host, controlPort: port, localAddress: localAddress))
            let session = ControlSession(config: config, seams: .live(localAddress: localAddress))
            self.media = media
            self.control = session
            await media.open()
            let params: ControlSession.MediaParams
            do {
                params = try await session.start()
                try await media.activate(.init(keys: params.keys,
                                               ourVideoSSRC: MediaOffer.extractSSRC(params.videoOffer, isVideo: true),
                                               ourAudioSSRC: MediaOffer.extractSSRC(params.audioOffer, isVideo: false)))
            } catch {
                await teardown()
                state = userClosed ? .idle : .failed(ControlSession.describe(error))
                return
            }
            guard !userClosed, self.control === session else { return }
            mediaParams = params
            watch(session)
            startStatsPolling(media)

            let outcome = await media.burstOutcome()
            guard !userClosed, self.control === session else { return }
            switch outcome {
            case .started:
                state = .connected(canvasWidth: params.canvas.width, canvasHeight: params.canvas.height)
                return
            case .starved(let packets):
                await teardown()
                if attempt < attempts {
                    Log.app.error("burst starved (no-video-rtp, \(packets) pkts); full reconnect \(attempt)/\(attempts)")
                    try? await Task.sleep(for: policy.burstRetrySleep)
                    guard !userClosed else { state = .idle; return }
                } else {
                    let msg = "HP stream never started: \(packets) video packets arrived across \(attempts) fresh "
                        + "handshakes. On the Mac, toggle Screen Sharing off and on, then reconnect."
                    Log.app.error(msg)
                    state = .failed(msg)
                    return
                }
            }
        }
    }

    func disconnect() async {
        userClosed = true
        await teardown()
        state = .idle
    }

    private func teardown() async {
        eventsTask?.cancel(); eventsTask = nil
        statsTask?.cancel(); statsTask = nil
        let (c, m) = (control, media)
        control = nil
        media = nil
        mediaParams = nil
        if let m {
            mediaStats = await m.stats
            await m.close()
        }
        if let c { await c.close() }
    }

    /// Drains control events (nothing consumes them yet) and notices when the
    /// session ends; media goes down with it.
    private func watch(_ session: ControlSession) {
        eventsTask = Task { [weak self] in
            for await _ in session.events {}
            let failure = await session.failure
            guard let self, !Task.isCancelled, self.control === session else { return }
            await self.teardown()
            self.state = failure.map { .failed(ControlSession.describe($0)) } ?? .idle
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
