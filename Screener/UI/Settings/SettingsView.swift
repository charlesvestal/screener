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
    @AppStorage(TapClickDelay.defaultsKey) private var tapDelayRaw = TapClickDelay.default.rawValue
    @AppStorage(ScrollDirection.defaultsKey) private var scrollDirectionRaw = ScrollDirection.default.rawValue
    @AppStorage(InputPreferences.longPressRightClickKey) private var longPressRightClick =
        InputPreferences.longPressRightClickDefault
    @AppStorage(ResumeOnLaunch.enabledKey) private var reconnectOnLaunch = ResumeOnLaunch.enabledDefault
    @State private var showAcknowledgements = false
    @State private var showHelp = false

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
                    Picker("Scroll Direction", selection: $scrollDirectionRaw) {
                        ForEach(ScrollDirection.allCases, id: \.self) { d in
                            Text(d.title).tag(d.rawValue)
                        }
                    }
                    Picker("Tap to Click Delay", selection: $tapDelayRaw) {
                        ForEach(TapClickDelay.allCases, id: \.self) { d in
                            Text(d.title).tag(d.rawValue)
                        }
                    }
                    Toggle("Long-Press to Right-Click", isOn: $longPressRightClick)
                    Toggle("Visual Feedback", isOn: $visualFeedback)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Trackpad: drag to move the pointer, tap to click. Touch: the pointer goes where you touch. "
                         + "Scroll Direction: Natural follows the iPad; Reversed flips every scroll. "
                         + "Tap to Click Delay is how long a tap waits for a double tap or tap-and-drag: Fast "
                         + "clicks sooner, Relaxed gives more time. Long-Press to Right-Click: in Trackpad mode, "
                         + "hold one finger still to right-click. Shake the pointer to find it. "
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
                    Toggle("Reconnect to Last Mac on Launch", isOn: $reconnectOnLaunch)
                } header: {
                    Text("Session")
                } footer: {
                    Text("Auto Clipboard copies text between the iPad and the Mac as you copy it; iPadOS may ask "
                         + "to allow pasting. Items a password manager marks as concealed or transient are never "
                         + "sent automatically, and text from the Mac stays on this iPad (not shared with your other "
                         + "devices via Universal Clipboard). Keep Screen Awake stops the iPad from locking while "
                         + "connected. Reconnect to Last Mac on Launch connects to the Mac you used last when "
                         + "Screener opens, if its password is saved (you can cancel it).")
                }

                Section {
                    Button("Help") { showHelp = true }
                    Button("Acknowledgements") { showAcknowledgements = true }
                    ShareLogButton()
                } footer: {
                    Text("These are the defaults. Each saved Mac can override them (Edit Mac → Session), and "
                         + "changes made from the control menu during a session are remembered for that Mac.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showAcknowledgements) { AcknowledgementsView() }
            .sheet(isPresented: $showHelp) { HelpView() }
        }
    }
}
