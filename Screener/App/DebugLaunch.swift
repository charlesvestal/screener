#if DEBUG
import CoreGraphics
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
///   -displayMode <mode>          DisplayMode raw value for this launch (stored)
///   -testResize "<s>:<W>x<H>[@<scale>],…"  after connecting, at <s> seconds from
///                                the connect start, request that raw geometry
///                                (ControlSession.requestDisplay; no clamping)
///   -testView "<s>:<W>x<H>,…"    report a view size change at <s> seconds
///                                (the DisplayResizer path: mode + debounce)
///   -testMode "<s>:<mode>,…"     switch the display mode at <s> seconds
///   -displayMax <W>x<H>          the 0x1d max_width/max_height (experiments)
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

        if let raw = defaults.string(forKey: "displayMode"), DisplayMode(rawValue: raw) != nil {
            defaults.set(raw, forKey: DisplayMode.defaultsKey)
        }
        scheduleResizeTests(model, defaults)
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

    /// "<s>:<W>x<H>[@<scale>]" entries of a comma-separated list.
    static func parseSteps(_ raw: String?) -> [(at: Double, w: Int, h: Int, scale: Double)] {
        (raw ?? "").split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":")
            guard parts.count == 2, let at = Double(parts[0]) else { return nil }
            let sizeScale = parts[1].split(separator: "@")
            let wh = sizeScale[0].split(separator: "x")
            guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { return nil }
            let scale = sizeScale.count > 1 ? Double(sizeScale[1]) ?? 2 : 2
            return (at, w, h, scale)
        }
    }

    @MainActor
    private static func scheduleResizeTests(_ model: SessionCoordinator, _ defaults: UserDefaults) {
        for step in parseSteps(defaults.string(forKey: "testResize")) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(step.at))
                guard let control = model.control, case .connected = model.state else { return }
                let g = DisplayGeometry(logicalWidth: step.w, logicalHeight: step.h, hidpiScale: step.scale)
                Log.app.info("DEBUG testResize t=\(step.at)s → \(g)")
                try? await control.requestDisplay(g)
            }
        }
        for item in (defaults.string(forKey: "testMode") ?? "").split(separator: ",") {
            let parts = item.split(separator: ":")
            guard parts.count == 2, let at = Double(parts[0]), let mode = DisplayMode(rawValue: String(parts[1])) else { continue }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(at))
                Log.app.info("DEBUG testMode t=\(at)s → \(mode.rawValue)")
                model.setDisplayMode(mode)
            }
        }
        for step in parseSteps(defaults.string(forKey: "testView")) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(step.at))
                Log.app.info("DEBUG testView t=\(step.at)s → \(step.w)x\(step.h)pt")
                model.viewSizeChanged(points: CGSize(width: step.w, height: step.h), scale: step.scale)
            }
        }
    }
}
#endif
