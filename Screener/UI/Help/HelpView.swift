// Help: how to set up the Mac, use the gestures and keyboard, reach it away
// from home, what Screener does for privacy, and the usual things to check
// when a connection won't come up. Opened from Settings and from the empty
// host list (HostsEmptyState).
import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showCoach = false

    var body: some View {
        NavigationStack {
            Form {
                setupSection
                gesturesSection
                keyboardSection
                awaySection
                privacySection
                troubleshootingSection
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .fullScreenCover(isPresented: $showCoach) {
            GestureCoachOverlay { showCoach = false }
                .background(Color.black.opacity(0.001))
        }
    }

    private var setupSection: some View {
        Section("Set up your Mac") {
            helpRow("1. Turn on Screen Sharing",
                    "On the Mac, open **System Settings › General › Sharing** and turn on **Screen Sharing**.")
            helpRow("2. High Performance",
                    "On an Apple-silicon Mac, Screener automatically uses Apple's High Performance mode for the "
                    + "best picture and the lowest delay — there's nothing to turn on.")
            helpRow("3. Same Wi-Fi",
                    "Keep the iPad on the same Wi-Fi network as the Mac so it shows up on its own.")
        }
    }

    private var gesturesSection: some View {
        Section("Gestures") {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey("Screener turns finger touches into clicks, drags, scrolling and zoom — "
                     + "in either **Trackpad** or **Touch** mode (Settings › Input). Tap to click; tap with two "
                     + "fingers to right-click, three to middle-click. Touch and hold with one, two or three "
                     + "fingers until the **blue**, **red** or **green** ring appears, then drag for a left, "
                     + "right or middle drag. Swipe three fingers left or right to switch Spaces, up for "
                     + "Mission Control, down for App Exposé."))
                    .font(.subheadline)
                Button("Show the Gesture Coach") { showCoach = true }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .padding(.vertical, 2)
        }
    }

    private var keyboardSection: some View {
        Section("Keyboard") {
            helpRow("Accessory row", "A row of special keys (Esc, Tab, arrows, function keys, …) sits above the "
                    + "software keyboard whenever it's on screen.")
            helpRow("Sticky modifiers", "⌘, ⌥, ⌃ and ⇧ in the control menu latch so you can tap them, then a key, "
                    + "instead of holding two fingers down. Tap twice to lock a modifier until you tap it again.")
            helpRow("Open the control menu", "Press **⌘⌥M** on a hardware keyboard, or tap the floating button.")
            helpRow("Shortcuts iPadOS keeps", "A few combinations (like ⌘Space or ⌘Tab) stay with iPadOS and never "
                    + "reach the Mac; use the control menu's Mac Shortcuts tiles to send them instead.")
        }
    }

    private var awaySection: some View {
        Section("Away from home") {
            helpRow("Use a VPN", "Screener only finds Macs with Bonjour, which doesn't reach outside your home "
                    + "network. To connect from elsewhere, install **Tailscale** (or another VPN) on both the Mac "
                    + "and the iPad, then add the Mac in Screener by its Tailscale IP address or name — Bonjour "
                    + "discovery won't see it, so add it by hand.")
            helpRow("Bandwidth", "High Performance mode looks best on a fast, low-latency connection; over a VPN "
                    + "on cellular or a slow network, expect a softer picture and more delay.")
        }
    }

    private var privacySection: some View {
        Section("Privacy & security") {
            helpRow("Passwords", "Saved passwords live in the iPad's Keychain, never in Screener's own storage.")
            helpRow("Mac identity", "The first successful sign-in to a Mac pins its identity; if it ever presents "
                    + "a different one, Screener stops before sending your password and asks you to confirm it's "
                    + "really your Mac.")
            helpRow("Legacy sign-in", "Older Macs that don't support Screener's normal sign-in need a per-Mac "
                    + "\"Allow legacy sign-in\" toggle (Edit Mac) before Screener will fall back to it.")
            helpRow("Clipboard", "Auto Clipboard copies text you copy on either side to the other; items a "
                    + "password manager marks concealed or transient are never sent automatically, and text from "
                    + "the Mac stays on this iPad.")
            helpRow("Nothing leaves your network", "Screener talks directly to your Mac over your own network (or "
                    + "your own VPN) — there's no server in between.")
        }
    }

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            helpRow("No Macs appear", "Make sure iPadOS has granted Screener **Local Network** access "
                    + "(Settings app › Screener) and that Screen Sharing is turned on on the Mac.")
            helpRow("Connection refused", "Screen Sharing may be off, or the Mac user name or password is wrong — "
                    + "Screener will ask again if the password doesn't match.")
            helpRow("Stuck connecting", "A firewall blocking the Mac's screen-sharing port, or blocking the UDP "
                    + "traffic the video stream uses, will stop a connection from finishing; check your router or "
                    + "firewall settings if this Mac has worked before.")
        }
    }

    private func helpRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(LocalizedStringKey(body)).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview {
    HelpView()
}
#endif
