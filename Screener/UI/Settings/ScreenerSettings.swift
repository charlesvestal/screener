// The app's settings keys and defaults (UserDefaults / @AppStorage), shared
// by SettingsView, the control menu and the session.
//
// Keys owned elsewhere are referenced, not redefined: smooth playback
// (PacingConfig), touch mode (TouchInputMode), display mode (DisplayMode),
// Auto Clipboard (ClipboardSyncMode "clipboard.syncMode"), mute
// (AudioPlayer "audio.muted").
import Foundation

enum ScreenerSettings {
    /// Touch ripples and other on-screen input feedback.
    static let visualFeedbackKey = "feedback.visual"
    static let visualFeedbackDefault = true

    /// Scroll speed multiplier (applied at session start).
    static let scrollSpeedKey = "input.scrollSpeed"
    static let scrollSpeedDefault = 1.0
    static let scrollSpeedRange: ClosedRange<Double> = 0.5...2.0

    /// Keep the iPad from auto-locking while a session is up.
    static let keepAwakeKey = "session.keepAwake"
    static let keepAwakeDefault = true

    /// The session's stats overlay (the menu's Stats tile).
    static let statsOverlayKey = "session.statsOverlay"
    static let statsOverlayDefault = false

    static func visualFeedback(_ d: UserDefaults = .standard) -> Bool {
        bool(visualFeedbackKey, default: visualFeedbackDefault, d)
    }

    static func keepAwake(_ d: UserDefaults = .standard) -> Bool {
        bool(keepAwakeKey, default: keepAwakeDefault, d)
    }

    /// The stored scroll speed, clamped to `scrollSpeedRange`.
    static func scrollSpeed(_ d: UserDefaults = .standard) -> Double {
        guard d.object(forKey: scrollSpeedKey) != nil else { return scrollSpeedDefault }
        let v = d.double(forKey: scrollSpeedKey)
        guard v.isFinite else { return scrollSpeedDefault }
        return min(scrollSpeedRange.upperBound, max(scrollSpeedRange.lowerBound, v))
    }

    private static func bool(_ key: String, default value: Bool, _ d: UserDefaults) -> Bool {
        d.object(forKey: key) == nil ? value : d.bool(forKey: key)
    }
}

/// When the iPad's idle timer (auto-lock) is off.
enum IdleTimerPolicy {
    /// Only while a session is up and the user wants the screen kept awake.
    static func disablesIdleTimer(keepAwake: Bool, sessionActive: Bool) -> Bool {
        keepAwake && sessionActive
    }
}
