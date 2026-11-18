// Settings (the gear in the host list toolbar): the session defaults the
// control menu also changes during a session, plus a few app-wide ones.
// Everything is @AppStorage (keys: ScreenerSettings and the owning types).
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ScreenerSettings.visualFeedbackKey) private var visualFeedback = ScreenerSettings.visualFeedbackDefault
    @AppStorage(PacingConfig.defaultsKey) private var smoothPlayback = false
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    @AppStorage(DisplayMode.defaultsKey) private var displayModeRaw = DisplayMode.default.rawValue
    @AppStorage(ClipboardSyncMode.defaultsKey) private var clipboardModeRaw = ClipboardSyncMode.default.rawValue
    @AppStorage(AudioPlayer.mutedDefaultsKey) private var audioMuted = false
    @AppStorage(ScreenerSettings.scrollSpeedKey) private var scrollSpeed = ScreenerSettings.scrollSpeedDefault
    @AppStorage(ScreenerSettings.keepAwakeKey) private var keepAwake = ScreenerSettings.keepAwakeDefault
    @State private var showAcknowledgements = false

    private var displayMode: DisplayMode { DisplayMode(rawValue: displayModeRaw) ?? .default }

    private var autoClipboard: Binding<Bool> {
        Binding {
            (ClipboardSyncMode(rawValue: clipboardModeRaw) ?? .default) == .automatic
        } set: { on in
            clipboardModeRaw = (on ? ClipboardSyncMode.automatic : .manual).rawValue
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Touch Mode", selection: $touchModeRaw) {
                        ForEach(TouchInputMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Scroll Speed") {
                            Text(String(format: "%.1f×", scrollSpeed)).monospacedDigit()
                        }
                        Slider(value: $scrollSpeed, in: ScreenerSettings.scrollSpeedRange) {
                            Text("Scroll Speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").accessibilityLabel("Slower")
                        } maximumValueLabel: {
                            Image(systemName: "hare").accessibilityLabel("Faster")
                        }
                        .accessibilityValue(String(format: "%.1f times", scrollSpeed))
                    }
                    Toggle("Visual Feedback", isOn: $visualFeedback)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Trackpad: drag to move the pointer, tap to click. Touch: the pointer goes where you touch. "
                         + "Visual Feedback shows where touches and clicks land.")
                }

                Section {
                    Picker("Display", selection: $displayModeRaw) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    Toggle("Smooth Playback", isOn: $smoothPlayback)
                } header: {
                    Text("Display")
                } footer: {
                    Text(displayMode.detail + " Smooth Playback presents frames on the Mac's timeline: smoother "
                         + "motion, a little more delay (from the next connection).")
                }

                Section {
                    Toggle("Auto Clipboard", isOn: autoClipboard)
                    Toggle("Mute Audio", isOn: $audioMuted)
                    Toggle("Keep Screen Awake", isOn: $keepAwake)
                } header: {
                    Text("Session")
                } footer: {
                    Text("Auto Clipboard copies text between the iPad and the Mac as you copy it; iPadOS may ask "
                         + "to allow pasting. Keep Screen Awake stops the iPad from locking while connected.")
                }

                Section {
                    Button("Acknowledgements") { showAcknowledgements = true }
                    ShareLogButton()
                } footer: {
                    Text("These defaults can also be changed from the control menu during a session.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showAcknowledgements) { AcknowledgementsView() }
        }
    }
}
