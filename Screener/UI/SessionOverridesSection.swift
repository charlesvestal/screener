import SwiftUI

/// Edit Mac → Session: this Mac's overrides of the Settings defaults
/// (HostSessionSettings.swift). Each picker offers "Default (<current
/// default>)" or a specific value.
struct SessionOverridesSection: View {
    @Binding var overrides: SessionOverrides
    let macName: String

    @AppStorage(DisplayMode.defaultsKey) private var displayModeRaw = DisplayMode.default.rawValue
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    @AppStorage(AudioPlayer.mutedDefaultsKey) private var audioMuted = false
    @AppStorage(ClipboardSyncMode.defaultsKey) private var clipboardModeRaw = ClipboardSyncMode.default.rawValue
    @AppStorage(PacingConfig.defaultsKey) private var smoothPlayback = false

    var body: some View {
        Section {
            Picker("Display", selection: $overrides.displayMode) {
                Text(defaultLabel((DisplayMode(rawValue: displayModeRaw) ?? .default).title))
                    .tag(DisplayMode?.none)
                ForEach(DisplayMode.allCases) { Text($0.title).tag(DisplayMode?.some($0)) }
            }
            Picker("Touch Mode", selection: $overrides.touchMode) {
                Text(defaultLabel((TouchInputMode(rawValue: touchModeRaw) ?? .default).title))
                    .tag(TouchInputMode?.none)
                ForEach(TouchInputMode.allCases, id: \.self) { Text($0.title).tag(TouchInputMode?.some($0)) }
            }
            Picker("Audio", selection: $overrides.audioMuted) {
                Text(defaultLabel(Self.audioTitle(muted: audioMuted))).tag(Bool?.none)
                Text(Self.audioTitle(muted: false)).tag(Bool?.some(false))
                Text(Self.audioTitle(muted: true)).tag(Bool?.some(true))
            }
            Picker("Clipboard", selection: $overrides.clipboardMode) {
                Text(defaultLabel(Self.clipboardTitle(ClipboardSyncMode(rawValue: clipboardModeRaw) ?? .default)))
                    .tag(ClipboardSyncMode?.none)
                ForEach(ClipboardSyncMode.allCases, id: \.self) {
                    Text(Self.clipboardTitle($0)).tag(ClipboardSyncMode?.some($0))
                }
            }
            Picker("Smooth Playback", selection: $overrides.smoothPlayback) {
                Text(defaultLabel(smoothPlayback ? "On" : "Off")).tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
        } header: {
            Text("Session")
        } footer: {
            Text("Default follows Settings. Changes you make from the control menu while connected to "
                 + "\(macName) are saved here, for this Mac only.")
        }
    }

    private func defaultLabel(_ value: String) -> String { "Default (\(value))" }

    static func audioTitle(muted: Bool) -> String { muted ? "Muted" : "On" }

    static func clipboardTitle(_ mode: ClipboardSyncMode) -> String {
        switch mode {
        case .automatic: "Automatic"
        case .manual: "Manual"
        }
    }
}
