// Per-Mac session settings: Display mode, Touch mode, Audio, Clipboard and
// Smooth Playback can each be overridden on a saved host (Edit Mac →
// Session); nil means "Use Default" (the value in Settings).
//
//   effective setting at connect = host override ?? global default
//
// How it reaches the session: every reader (SessionCoordinator's display
// mode, SessionView's touch mode, AudioPlayer's mute, the clipboard bridge,
// MetalRenderer's pacing) and the control menu use the existing UserDefaults
// keys. While a saved Mac's session is up those keys hold that session's
// *effective* values: `HostSettingsOverlay.begin` snapshots the globals
// (persisted, so a crash mid-session can't leak one Mac's values into the
// defaults — `recoverAfterCrash` at launch puts them back), writes the
// effective values, and `end` restores the globals when the session is over.
//
// In-session changes (control menu) apply to this Mac and are remembered
// for it: `captureChanges` turns any key that no longer matches what the
// overlay wrote into an override on the host. The Settings defaults are not
// touched by the menu while a saved Mac is connected. A Mac connected
// without being saved has no overlay: its menu changes go to the defaults,
// as before.
import Foundation
import Observation
import SwiftData

/// The five per-Mac session settings, as concrete values.
struct SessionSettings: Equatable, Sendable {
    var displayMode: DisplayMode
    var touchMode: TouchInputMode
    var audioMuted: Bool
    var clipboardMode: ClipboardSyncMode
    var smoothPlayback: Bool

    enum Field: String, CaseIterable, Sendable {
        case displayMode, touchMode, audio, clipboard, smoothPlayback
    }

    /// The UserDefaults keys these live in (owned by their types).
    static let keys = [DisplayMode.defaultsKey, TouchInputMode.defaultsKey, AudioPlayer.mutedDefaultsKey,
                       ClipboardSyncMode.defaultsKey, PacingConfig.defaultsKey]

    /// The values in `defaults` (each type's default when unset).
    static func read(_ d: UserDefaults) -> SessionSettings {
        SessionSettings(
            displayMode: DisplayMode.stored(d),
            touchMode: d.string(forKey: TouchInputMode.defaultsKey).flatMap(TouchInputMode.init(rawValue:)) ?? .default,
            audioMuted: d.bool(forKey: AudioPlayer.mutedDefaultsKey),
            clipboardMode: d.string(forKey: ClipboardSyncMode.defaultsKey).flatMap(ClipboardSyncMode.init(rawValue:))
                ?? .default,
            smoothPlayback: d.bool(forKey: PacingConfig.defaultsKey))
    }

    /// Writes only the keys whose value differs (no needless change notifications).
    func write(to d: UserDefaults) {
        let current = Self.read(d)
        if current.displayMode != displayMode { d.set(displayMode.rawValue, forKey: DisplayMode.defaultsKey) }
        if current.touchMode != touchMode { d.set(touchMode.rawValue, forKey: TouchInputMode.defaultsKey) }
        if current.audioMuted != audioMuted { d.set(audioMuted, forKey: AudioPlayer.mutedDefaultsKey) }
        if current.clipboardMode != clipboardMode { d.set(clipboardMode.rawValue, forKey: ClipboardSyncMode.defaultsKey) }
        if current.smoothPlayback != smoothPlayback { d.set(smoothPlayback, forKey: PacingConfig.defaultsKey) }
    }

    /// The fields where `other` differs from this.
    func changes(to other: SessionSettings) -> [Field] {
        var f: [Field] = []
        if displayMode != other.displayMode { f.append(.displayMode) }
        if touchMode != other.touchMode { f.append(.touchMode) }
        if audioMuted != other.audioMuted { f.append(.audio) }
        if clipboardMode != other.clipboardMode { f.append(.clipboard) }
        if smoothPlayback != other.smoothPlayback { f.append(.smoothPlayback) }
        return f
    }

    // The persisted snapshot of the globals (see HostSettingsOverlay).
    var plist: [String: Any] {
        ["displayMode": displayMode.rawValue, "touchMode": touchMode.rawValue, "audioMuted": audioMuted,
         "clipboardMode": clipboardMode.rawValue, "smoothPlayback": smoothPlayback]
    }

    init(displayMode: DisplayMode = .default, touchMode: TouchInputMode = .default, audioMuted: Bool = false,
         clipboardMode: ClipboardSyncMode = .default, smoothPlayback: Bool = false) {
        self.displayMode = displayMode
        self.touchMode = touchMode
        self.audioMuted = audioMuted
        self.clipboardMode = clipboardMode
        self.smoothPlayback = smoothPlayback
    }

    init?(plist: [String: Any]) {
        guard let d = (plist["displayMode"] as? String).flatMap(DisplayMode.init(rawValue:)),
              let t = (plist["touchMode"] as? String).flatMap(TouchInputMode.init(rawValue:)),
              let a = plist["audioMuted"] as? Bool,
              let c = (plist["clipboardMode"] as? String).flatMap(ClipboardSyncMode.init(rawValue:)),
              let s = plist["smoothPlayback"] as? Bool else { return nil }
        self.init(displayMode: d, touchMode: t, audioMuted: a, clipboardMode: c, smoothPlayback: s)
    }
}

/// A saved host's overrides (nil: use the default).
struct SessionOverrides: Equatable, Sendable {
    var displayMode: DisplayMode?
    var touchMode: TouchInputMode?
    var audioMuted: Bool?
    var clipboardMode: ClipboardSyncMode?
    var smoothPlayback: Bool?

    static let none = SessionOverrides()

    var isEmpty: Bool { self == .none }

    /// host override ?? global default, per setting.
    func resolved(over global: SessionSettings) -> SessionSettings {
        SessionSettings(displayMode: displayMode ?? global.displayMode,
                        touchMode: touchMode ?? global.touchMode,
                        audioMuted: audioMuted ?? global.audioMuted,
                        clipboardMode: clipboardMode ?? global.clipboardMode,
                        smoothPlayback: smoothPlayback ?? global.smoothPlayback)
    }

    /// Sets `fields` to their values in `live`.
    mutating func adopt(_ fields: [SessionSettings.Field], from live: SessionSettings) {
        for f in fields {
            switch f {
            case .displayMode: displayMode = live.displayMode
            case .touchMode: touchMode = live.touchMode
            case .audio: audioMuted = live.audioMuted
            case .clipboard: clipboardMode = live.clipboardMode
            case .smoothPlayback: smoothPlayback = live.smoothPlayback
            }
        }
    }
}

extension SavedHost {
    /// The host's session overrides (unknown stored raw values read as "Use Default").
    var sessionOverrides: SessionOverrides {
        get {
            SessionOverrides(displayMode: displayMode.flatMap(DisplayMode.init(rawValue:)),
                             touchMode: inputMode.flatMap(TouchInputMode.init(rawValue:)),
                             audioMuted: audioEnabled.map { !$0 },
                             clipboardMode: clipboardEnabled.map { $0 ? .automatic : .manual },
                             smoothPlayback: smoothPlayback)
        }
        set {
            displayMode = newValue.displayMode?.rawValue
            inputMode = newValue.touchMode?.rawValue
            audioEnabled = newValue.audioMuted.map { !$0 }
            clipboardEnabled = newValue.clipboardMode.map { $0 == .automatic }
            smoothPlayback = newValue.smoothPlayback
        }
    }
}

/// Puts a saved Mac's effective session settings into the live UserDefaults
/// keys for the length of its session (see the header).
@MainActor
final class HostSettingsOverlay {
    /// The globals while an overlay is applied (crash recovery).
    nonisolated static let savedGlobalsKey = "hostOverlay.savedGlobals"

    let defaults: UserDefaults
    /// The saved host whose values are in the live keys (nil: the globals are).
    private(set) var hostID: UUID?
    private(set) var hostName: String?
    /// What the live keys held when last written / captured by the overlay.
    private var applied: SessionSettings?
    private var globals: SessionSettings?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isActive: Bool { hostID != nil }

    /// Applies `host`'s overrides over the current globals. Already applied
    /// for this host: nothing. Applied for another: that one ends first.
    func begin(_ host: SavedHost) {
        if hostID == host.id { return }
        end()
        let global = SessionSettings.read(defaults)
        globals = global
        defaults.set(global.plist, forKey: Self.savedGlobalsKey)
        let effective = host.sessionOverrides.resolved(over: global)
        effective.write(to: defaults)
        applied = effective
        hostID = host.id
        hostName = host.name
    }

    /// Restores the globals. Idempotent.
    func end() {
        guard hostID != nil || globals != nil else { return }
        hostID = nil
        hostName = nil
        applied = nil
        if let globals { globals.write(to: defaults) }
        globals = nil
        defaults.removeObject(forKey: Self.savedGlobalsKey)
    }

    /// The live keys changed (control menu): remembers every setting that no
    /// longer matches what the overlay wrote as an override on `host` (the
    /// active one). Returns the fields saved (empty: nothing was the user's).
    @discardableResult
    func captureChanges(into host: SavedHost) -> [SessionSettings.Field] {
        guard hostID == host.id, let applied else { return [] }
        let live = SessionSettings.read(defaults)
        let fields = applied.changes(to: live)
        guard !fields.isEmpty else { return [] }
        var o = host.sessionOverrides
        o.adopt(fields, from: live)
        host.sessionOverrides = o
        self.applied = live
        return fields
    }

    /// At launch: a session that never ended (crash, kill while suspended)
    /// left a Mac's values in the live keys; put the globals back.
    nonisolated static func recoverAfterCrash(_ defaults: UserDefaults = .standard) {
        guard let plist = defaults.dictionary(forKey: savedGlobalsKey) else { return }
        if let globals = SessionSettings(plist: plist) {
            globals.write(to: defaults)
            Log.hosts.info("restored the session defaults left by an unfinished session")
        }
        defaults.removeObject(forKey: savedGlobalsKey)
    }
}
