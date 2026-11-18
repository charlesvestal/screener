// The session view's small extras, hosted by one modifier so SessionView
// stays as it is (`.sessionPolish(model)`):
//   - toasts (ToastCenter) for clipboard transfers, Mute, Display mode,
//     Touch mode, and a resumed session ("Reconnected");
//   - the stats overlay (the menu's Stats tile) and LiveStatsModel in the
//     environment for the menu's quality badge;
//   - Keep Screen Awake: the idle timer is off while a session is up
//     (IdleTimerPolicy), and back on when the session view goes away.
import SwiftUI
import UIKit

extension View {
    func sessionPolish(_ model: SessionCoordinator) -> some View {
        modifier(SessionPolish(model: model))
    }
}

private struct SessionPolish: ViewModifier {
    let model: SessionCoordinator
    @State private var toasts = ToastCenter()
    @AppStorage(AudioPlayer.mutedDefaultsKey) private var audioMuted = false
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    @AppStorage(DisplayMode.defaultsKey) private var displayModeRaw = DisplayMode.default.rawValue
    @AppStorage(ScreenerSettings.statsOverlayKey) private var showStats = ScreenerSettings.statsOverlayDefault
    @AppStorage(ScreenerSettings.keepAwakeKey) private var keepAwake = ScreenerSettings.keepAwakeDefault
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var keepsAwake: Bool {
        IdleTimerPolicy.disablesIdleTimer(keepAwake: keepAwake, sessionActive: model.isSessionActive)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if showStats {
                    StatsOverlay(stats: model.liveStats)
                        .padding(.leading, 16).padding(.top, 16)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                }
            }
            .overlay(alignment: .top) { ToastOverlay(center: toasts) }
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: showStats)
            .environment(model.liveStats)
            .onAppear {
                let toasts = toasts
                model.clipboard.onActivity = { activity in
                    switch activity {
                    case .sentToMac: toasts.show(SessionToasts.sentToMac, systemImage: "doc.on.clipboard",
                                                 key: "clipboard.out")
                    case .receivedFromMac: toasts.show(SessionToasts.fromMac, systemImage: "clipboard",
                                                       key: "clipboard.in")
                    }
                }
            }
            .onDisappear {
                model.clipboard.onActivity = nil
                toasts.clear()
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: audioMuted) { _, muted in
                toasts.show(muted ? "Muted" : "Unmuted",
                            systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", key: "audio")
            }
            .onChange(of: touchModeRaw) { _, raw in
                let mode = TouchInputMode(rawValue: raw) ?? .default
                toasts.show(SessionToasts.touchMode(mode),
                            systemImage: mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left",
                            key: "touchMode")
            }
            .onChange(of: displayModeRaw) { _, raw in
                toasts.show(SessionToasts.display(DisplayMode(rawValue: raw) ?? .default), systemImage: "display",
                            key: "display")
            }
            .onChange(of: model.isReconnecting) { was, now in
                guard was, !now, model.hasFirstFrame, case .connected = model.state else { return }
                toasts.show(SessionToasts.reconnected, systemImage: "checkmark.circle.fill", key: "session")
            }
            .onChange(of: keepsAwake, initial: true) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
    }
}

/// Toast texts.
enum SessionToasts {
    static let sentToMac = "Copied to Mac ↗"
    static let fromMac = "Clipboard from Mac"
    static let reconnected = "Reconnected"
    static func display(_ mode: DisplayMode) -> String { "Display: \(mode.title)" }
    static func touchMode(_ mode: TouchInputMode) -> String {
        switch mode {
        case .trackpad: "Trackpad mode"
        case .direct: "Touch mode"
        }
    }
}
