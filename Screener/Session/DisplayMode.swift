// Ported in part from iShareScreen src/isharescreen/proxy/session.py
// (send_dynamic_resolution) and frontend/desktop/app.py (the resize tracker:
// re-advertise the virtual display when the viewer window changes size)
// (AGPL-3.0).
//
// How the Mac's virtual display is sized, and the in-band resize that follows
// rotation and Stage Manager window changes without reconnecting (RFC §7.3,
// §10.9):
//   view size change → debounce 400 ms → dynamic 0x1d (ControlSession.
//   requestDisplay) → the server's 0x451 → 0x1c re-offer (ControlSession) →
//   a new four-SSRC group with new VPS/SPS/PPS and an IDR (MediaTransport.
//   expectNewGroup, HEVCAssembler.resetForNewGroup, VideoDecoder.configure)
//   while VideoFrameStore holds the last picture until the new one is in.
// The server's geometry (0x451) is authoritative: it may answer a smaller
// size than asked (backing cap), and the canvas, input mapping and cursor
// follow what it says, never the request.
import CoreGraphics
import Foundation

/// What the Mac's virtual display is sized to.
enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// The view's size in points, at 2× (Retina): what the iPad shows 1:1
    /// (on a 3× iPhone: its pixels at 2×, i.e. points × 1.5).
    case fitRetina
    /// 1.25× the view's points at 2×: more room, smaller text.
    case moreSpace
    /// 0.8× the view's points at 2×: fewer pixels, so more bits per pixel
    /// from the same encoder bitrate (sharper under motion), larger text.
    case sharper
    /// No dynamic descriptor: a bare one at the Mac's own (ServerInit) size,
    /// fixed for the session (the window letterboxes on rotation).
    case matchMac

    static let defaultsKey = "display.mode"
    static let `default` = DisplayMode.fitRetina

    var id: String { rawValue }

    /// The stored choice (UserDefaults `display.mode`).
    static func stored(_ defaults: UserDefaults = .standard) -> DisplayMode {
        defaults.string(forKey: defaultsKey).flatMap(DisplayMode.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .fitRetina: "Fit (Retina)"
        case .moreSpace: "More Space"
        case .sharper: "Sharper"
        case .matchMac: "Match Mac"
        }
    }

    var detail: String {
        switch self {
        case .fitRetina: "The Mac's desktop matches this window, pixel for pixel."
        case .moreSpace: "25% more desktop; text is smaller."
        case .sharper: "Larger text and fewer pixels: crisper while things move."
        case .matchMac: "The Mac's own resolution; doesn't follow rotation or window size."
        }
    }

    /// Point-size multiplier of the dynamic modes.
    var pointFactor: Double? {
        switch self {
        case .fitRetina: 1
        case .moreSpace: 1.25
        case .sharper: 0.8
        case .matchMac: nil
        }
    }

    /// Whether the session is created with a dynamic descriptor and follows
    /// the view (`.matchMac`: bare descriptor, fixed at the Mac's size).
    var isDynamic: Bool { pointFactor != nil }

    /// The Mac's HiDPI scale is at most 2× (macOS has no 3× displays).
    static let maxHiDPIScale = 2.0

    /// The virtual display to ask for in a view of `viewPoints` on a screen of
    /// `scale` (backing pixels per point: 2 on every iPad, 3 on most
    /// iPhones, 1 or 2 for the iPad app on a Mac), or nil for `.matchMac`.
    /// The Mac's display is HiDPI at `min(scale, 2)`, sized so its backing
    /// matches the view's pixels: on a 3× iPhone its logical size is the
    /// view's points × 1.5 (× the mode's factor) — pixel for pixel, and a Mac
    /// desktop large enough to work in (AdaptiveLayout). Logical sizes of
    /// the scaled modes are rounded to even numbers; every mode keeps the
    /// backing inside `maxBacking` (either orientation) by shrinking uniformly.
    func geometry(viewPoints: CGSize, scale: CGFloat,
                  maxBacking: DisplayGeometry.Cap = .serverDefault) -> DisplayGeometry? {
        guard let factor = pointFactor else { return nil }
        let screen = max(1, Double(scale))
        let hidpi = min(screen, Self.maxHiDPIScale)
        let pixelMatch = screen / hidpi
        var w = Double(viewPoints.width) * factor * pixelMatch, h = Double(viewPoints.height) * factor * pixelMatch
        guard w > 0, h > 0 else { return nil }
        // Fit the backing inside the cap (orientation-agnostic: long × short).
        let long = max(w, h) * hidpi, short = min(w, h) * hidpi
        let shrink = min(1, Double(maxBacking.long) / long, Double(maxBacking.short) / short)
        w *= shrink; h *= shrink
        // Even sizes for the scaled modes (nearest; down when shrunk, so the
        // backing never exceeds the cap).
        let even = factor != 1 || shrink < 1
        func round(_ v: Double) -> Int {
            guard even else { return Int(v.rounded()) }
            return 2 * Int((v / 2).rounded(shrink < 1 ? .down : .toNearestOrAwayFromZero))
        }
        let lw = max(DisplayGeometry.minLogical, round(w)), lh = max(DisplayGeometry.minLogical, round(h))
        return DisplayGeometry(logicalWidth: lw, logicalHeight: lh, hidpiScale: hidpi)
    }
}

/// A requested virtual display: logical (point) size and the backing:point ratio.
struct DisplayGeometry: Equatable, Sendable, CustomStringConvertible {
    var logicalWidth: Int
    var logicalHeight: Int
    var hidpiScale: Double

    /// Longest and shortest backing side the request may have.
    struct Cap: Equatable, Sendable {
        var long: Int
        var short: Int
        /// The descriptor's bound (`descriptorMax`; RFC §10.9 backing cap).
        /// Verified live (2026-11-18) up to 3440×2580 and 2580×3440.
        static let serverDefault = Cap(long: 3840, short: 3840)
    }

    static let minLogical = 320

    /// The descriptor's max_width/max_height. The server applies the bound
    /// of the connect-time descriptor per axis for the whole session (live,
    /// 2026-11-18: created with 3840×2160, a 2064×2752 portrait request got a
    /// 1280×1708 fallback; created with 2160×3840, a 2752×2064 landscape one
    /// got 1600×1200), so it must bound both orientations.
    var maxBacking: (width: Int, height: Int) { Self.descriptorMax }

    static let descriptorMax: (width: Int, height: Int) = {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "displayMax") {
            let p = raw.split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { return (p[0], p[1]) }
        }
        #endif
        return (Cap.serverDefault.long, Cap.serverDefault.short)
    }()

    /// `.matchMac`: a bare descriptor at the Mac's own framebuffer size from
    /// ServerInit, taken as points at 2× (kept inside the cap).
    static func matching(serverWidth w: Int, serverHeight h: Int) -> DisplayGeometry? {
        guard w > 0, h > 0 else { return nil }
        return DisplayMode.fitRetina.geometry(viewPoints: CGSize(width: w, height: h), scale: 2)
    }

    var backingWidth: Int { Int((Double(logicalWidth) * hidpiScale).rounded()) }
    var backingHeight: Int { Int((Double(logicalHeight) * hidpiScale).rounded()) }
    var logicalSize: CGSize { CGSize(width: logicalWidth, height: logicalHeight) }
    var backingSize: CGSize { CGSize(width: backingWidth, height: backingHeight) }

    var description: String {
        "\(logicalWidth)x\(logicalHeight)pt @\(hidpiScale)x (\(backingWidth)x\(backingHeight)px)"
    }
}

/// The resize state machine: view size / mode changes are debounced and turned
/// into at most one dynamic 0x1d per quiet period, only when the geometry
/// differs from the one in effect. The server's answer (0x451 → re-offer →
/// new SSRC group) is handled by ControlSession, MediaTransport and the video
/// pipeline; this only decides what to ask for and when.
@MainActor
final class DisplayResizer {
    struct Hooks {
        /// Sends the dynamic 0x1d for `geometry` (ControlSession.requestDisplay).
        var send: @MainActor (DisplayGeometry) async -> Void
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    static let defaultDebounce: Duration = .milliseconds(400)

    let debounce: Duration
    private let hooks: Hooks
    private(set) var mode: DisplayMode
    /// The geometry the Mac was last asked for (the connect-time one first).
    private(set) var current: DisplayGeometry?
    /// A session that accepts resizes is up.
    private(set) var isActive = false
    private(set) var requestsSent = 0
    private var viewPoints: CGSize?
    private var scale: CGFloat = 2
    private var pending: Task<Void, Never>?

    init(mode: DisplayMode = .stored(), debounce: Duration = DisplayResizer.defaultDebounce, hooks: Hooks) {
        self.mode = mode
        self.debounce = debounce
        self.hooks = hooks
    }

    /// `.matchMac`'s fixed geometry for this session (the Mac's ServerInit size).
    private(set) var macGeometry: DisplayGeometry?

    /// The geometry `mode` wants: for the view as last reported, or the
    /// Mac's own size for `.matchMac` (nil: not known yet).
    var wanted: DisplayGeometry? {
        if mode == .matchMac { return macGeometry }
        return viewPoints.flatMap { mode.geometry(viewPoints: $0, scale: scale) }
    }

    /// A session is up; `initial` is what its connect-time 0x1d asked for,
    /// `mac` the `.matchMac` geometry. A change that came in while connecting
    /// is applied now. (A display created by a bare descriptor still takes
    /// dynamic requests: live, 2026-11-18.)
    func start(initial: DisplayGeometry?, mac: DisplayGeometry? = nil) {
        isActive = true
        current = initial
        macGeometry = mac
        schedule()
    }

    func stop() {
        isActive = false
        pending?.cancel(); pending = nil
    }

    func viewChanged(points: CGSize, scale: CGFloat) {
        guard points.width > 0, points.height > 0 else { return }
        guard points != viewPoints || scale != self.scale else { return }
        viewPoints = points
        self.scale = scale
        schedule()
    }

    func setMode(_ m: DisplayMode) {
        guard m != mode else { return }
        mode = m
        schedule()
    }

    private func schedule() {
        pending?.cancel(); pending = nil
        guard isActive, wanted != nil else { return }
        let sleep = hooks.sleep, delay = debounce
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    private func fire() async {
        pending = nil
        guard isActive, let g = wanted, g != current else { return }
        Log.app.info("display: \(mode.rawValue) → requesting \(g) (was \(current.map { "\($0)" } ?? "-"))")
        current = g
        requestsSent += 1
        await hooks.send(g)
    }
}
