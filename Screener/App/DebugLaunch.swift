#if DEBUG
import Foundation

/// DEBUG-only unattended connect for the simulator harness (Tools/sim-connect.sh).
///
/// Launch arguments (read through UserDefaults' argument domain):
///   -autoConnect <host>          connect at launch, no UI interaction
///   -autoConnectPort <port>      default 5900
///   -autoDisconnectAfter <secs>  disconnect this long after the connect starts
///   -startupOrder reference|native  ControlSession.StartupOrder (default reference)
///   -localAddress <ipv4>         pin the TCP + UDP source address. Needed to test
///                                against this same Mac: the server sends media to
///                                the TCP peer address on its own port numbers, so
///                                use a second local IP (e.g. connect to the Mac's
///                                Wi-Fi IP from its Ethernet IP); loopback cannot work.
/// Credentials come only from the SCREENER_USER / SCREENER_PASS environment
/// variables (simctl passes SIMCTL_CHILD_* through) and are never logged.
enum DebugLaunch {
    @MainActor
    static func runIfRequested(_ model: SessionCoordinator) async {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: "autoConnect"), !host.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SCREENER_USER"], !user.isEmpty, let pass = env["SCREENER_PASS"] else {
            Log.app.error("DEBUG autoConnect: SCREENER_USER / SCREENER_PASS not set; not connecting")
            return
        }
        let port = UInt16(exactly: defaults.integer(forKey: "autoConnectPort")).flatMap { $0 == 0 ? nil : $0 } ?? 5900
        let order = ControlSession.StartupOrder(rawValue: defaults.string(forKey: "startupOrder") ?? "") ?? .reference
        let after = defaults.double(forKey: "autoDisconnectAfter")
        let local = defaults.string(forKey: "localAddress").flatMap { $0.isEmpty ? nil : $0 }

        Log.app.info("DEBUG autoConnect start host=\(host) port=\(port) order=\(order.rawValue) " +
                     "localAddress=\(local ?? "-") autoDisconnectAfter=\(after)")
        // The disconnect timer runs from the start of the connect, so a stuck
        // handshake can't keep the Mac's display privacy on past the deadline.
        let timer: Task<Void, Never>? = after > 0 ? Task { @MainActor in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled else { return }
            if let s = await model.media?.stats {
                Log.app.info("DEBUG autoDisconnect: video pkts=\(s.videoPackets) audio pkts=\(s.audioPackets) " +
                             "ssrcs=\(s.activeVideoSSRCs.count)")
            } else {
                Log.app.info("DEBUG autoDisconnect")
            }
            await model.disconnect()
        } : nil
        VideoCaptureFile.attachIfRequested(to: model)
        await model.connect(host: host, port: port, username: user, password: pass, order: order, localAddress: local)
        switch model.state {
        case .connected(let w, let h): Log.app.info("DEBUG autoConnect connected canvas=\(w)x\(h)")
        case .failed(let message): Log.app.error("DEBUG autoConnect failed: \(message)")
        default: break
        }
        _ = timer
    }
}
#endif
