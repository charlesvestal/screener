// The session view's small extras, hosted by one modifier so SessionView
// stays as it is (`.sessionPolish(model)`):
//   - toasts (ToastCenter) for clipboard transfers, Mute, Display mode,
//     Touch mode, Auto Clipboard, Smooth Playback, and a resumed session
//     ("Reconnected"). On a saved Mac the setting toasts say "Saved for
//     <name>": menu changes are remembered for that Mac (HostSessionSettings);
//   - the stats overlay (the menu's Stats tile) and LiveStatsModel in the
//     environment for the menu's quality badge;
//   - Keep Screen Awake: the idle timer is off while a session is up
//     (IdleTimerPolicy), and back on when the session view goes away.
import SwiftUI
import UIKit

extension View {
    /// `savedFor`: the saved Mac menu changes are remembered for (nil: none).
    func sessionPolish(_ model: SessionCoordinator, savedFor: String? = nil) -> some View {
        modifier(SessionPolish(model: model, savedFor: savedFor))
    }
}

private struct SessionPolish: ViewModifier {
    let model: SessionCoordinator
    let savedFor: String?
    @State private var toasts = ToastCenter()
    @AppStorage(ClipboardSyncMode.defaultsKey) private var clipboardModeRaw = ClipboardSyncMode.default.rawValue
    @AppStorage(PacingConfig.defaultsKey) private var smoothPlayback = false
    @AppStorage(AudioPlayer.mutedDefaultsKey) private var audioMuted = false
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    @AppStorage(DisplayMode.defaultsKey) private var displayModeRaw = DisplayMode.default.rawValue
    @AppStorage(ScreenerSettings.statsOverlayKey) private var showStats = ScreenerSettings.statsOverlayDefault
    @AppStorage(ScreenerSettings.keepAwakeKey) private var keepAwake = ScreenerSettings.keepAwakeDefault
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var keepsAwake: Bool {
        IdleTimerPolicy.disablesIdleTimer(keepAwake: keepAwake, sessionActive: model.isSessionActive)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if showStats {
                    StatsOverlay(stats: model.liveStats)
                        .padding(.leading, 16)
                        .padding(.top, AdaptiveLayout.statsTopInset(horizontal: horizontalSizeClass))
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
            // Only while the session is up: the defaults are put back as it
            // ends (HostSettingsOverlay), which is not the user's change.
            .onChange(of: audioMuted) { _, muted in
                guard model.isSessionActive else { return }
                toasts.show(muted ? "Muted" : "Unmuted",
                            systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", key: "audio",
                            detail: savedDetail)
            }
            .onChange(of: touchModeRaw) { _, raw in
                guard model.isSessionActive else { return }
                let mode = TouchInputMode(rawValue: raw) ?? .default
                toasts.show(SessionToasts.touchMode(mode),
                            systemImage: mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left",
                            key: "touchMode", detail: savedDetail)
            }
            .onChange(of: displayModeRaw) { _, raw in
                guard model.isSessionActive else { return }
                toasts.show(SessionToasts.display(DisplayMode(rawValue: raw) ?? .default), systemImage: "display",
                            key: "display", detail: savedDetail)
            }
            .onChange(of: clipboardModeRaw) { _, raw in
                guard model.isSessionActive else { return }
                let auto = (ClipboardSyncMode(rawValue: raw) ?? .default) == .automatic
                toasts.show(SessionToasts.autoClipboard(auto), systemImage: "arrow.left.arrow.right.circle",
                            key: "clipboardMode", detail: savedDetail)
            }
            .onChange(of: smoothPlayback) { _, on in
                guard model.isSessionActive else { return }
                toasts.show(SessionToasts.smoothPlayback(on), systemImage: "waveform.path",
                            key: "smoothPlayback", detail: savedDetail)
            }
            .onChange(of: model.fallbackReason != nil) { _, fellBack in
                guard fellBack else { return }
                toasts.show(FallbackText.toast, systemImage: "tortoise.fill", key: "session")
            }
            .onChange(of: model.isReconnecting) { was, now in
                guard was, !now, model.hasFirstFrame, case .connected = model.state else { return }
                toasts.show(SessionToasts.reconnected, systemImage: "checkmark.circle.fill", key: "session")
            }
            // One toast per resize burst: `isResizing` only flips false→true
            // at the start of a burst (SessionCoordinator/ResizeFeedback
            // coalesce the rest), so this onChange fires once per burst.
            // Informational — shown regardless of `feedback.visual` (the
            // held-frame blur, UI/SessionOverlays.swift, is the part that
            // setting gates).
            .onChange(of: model.isResizing) { was, now in
                guard !was, now else { return }
                toasts.show(SessionToasts.resizing, systemImage: "arrow.up.left.and.arrow.down.right",
                            key: "resize")
            }
            .onChange(of: keepsAwake, initial: true) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
    }
}

private extension SessionPolish {
    var savedDetail: String? { savedFor.map(SessionToasts.savedFor) }
}

/// Toast texts.
enum SessionToasts {
    static func savedFor(_ name: String) -> String { "Saved for \(name)" }
    static func autoClipboard(_ on: Bool) -> String { on ? "Auto Clipboard on" : "Auto Clipboard off" }
    static func smoothPlayback(_ on: Bool) -> String {
        on ? "Smooth Playback on (next connection)" : "Smooth Playback off (next connection)"
    }
    static let sentToMac = "Copied to Mac ↗"
    static let fromMac = "Clipboard from Mac"
    static let reconnected = "Reconnected"
    static let resizing = "Resizing…"
    static func display(_ mode: DisplayMode) -> String { "Display: \(mode.title)" }
    static func touchMode(_ mode: TouchInputMode) -> String {
        switch mode {
        case .trackpad: "Trackpad mode"
        case .direct: "Touch mode"
        }
    }
}
