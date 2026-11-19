# Screener

Screener is a fast iPad and iPhone client for macOS Screen Sharing's **High Performance** mode. It connects straight to the Screen Sharing service built into every Mac. There's nothing to install on the Mac, and no server sits in between.

High Performance mode is the protocol Apple's own Screen Sharing app uses between Apple-silicon Macs: HEVC 4:4:4 video at up to ~60 fps, stereo audio and a shared clipboard. Screener implements that protocol natively in Swift for iPadOS and iOS. On a good Wi-Fi network it holds ~60 fps at up to ~60 Mbps, so text stays sharp and windows move smoothly.

> Screener is an independent project. It is not affiliated with, endorsed by, or sponsored by Apple.

## Features

**Picture and sound**
- HEVC Range Extensions 4:4:4 video (full chroma, so small text stays crisp), decoded in hardware with VideoToolbox and drawn with Metal.
- Adaptive bitrate up to ~60 Mbps (see [How it works](#how-it-works)), with loss recovery that keeps decoding whenever the lost pictures weren't needed.
- The Mac's audio (AAC-ELD, 48 kHz stereo) through a jitter buffer, with mute.
- Picture in Picture: keep an eye on the Mac while you use another app.

**Touch and pointer**
- Two touch modes: **Trackpad**, where your finger moves a relative cursor with speed-dependent acceleration (the default), and **Touch**, where the cursor goes wherever you tap.
- Tap to click, two-finger tap (or press and hold in Touch mode) to right-click, drag, two-finger scrolling with momentum, and pinch to zoom.
- Visual feedback: ripples where clicks land, a halo and trail on the cursor, and shake to locate the pointer. Reduce Motion is respected.
- A gesture coach the first time you connect, and help any time after.
- Hardware mouse and trackpad support, with pointer lock on iPad.

**Keyboard**
- Hardware keyboard passthrough, including the chords iPadOS normally keeps for caret movement (⌥←, ⌘→, ⌘⌫, …) and key repeat.
- A software keyboard with an accessory row (Esc, Tab, arrows, function keys, …).

**Control menu**
- A floating, draggable menu (⌘⌥M on a hardware keyboard) with sticky modifiers (tap ⌘ ⌥ ⌃ ⇧ to latch, tap twice to lock), Mac shortcuts that iPadOS would otherwise intercept (App Switcher, Spotlight, Mission Control, App Exposé, Show Desktop, Lock Screen, Force Quit, screenshots), clipboard actions, display and input settings, live stats, and a Mac switcher.

**Display**
- Display modes: **Fit (Retina)** gives a pixel-for-pixel desktop, **More Space** gives 25% more desktop, **Sharper** uses fewer pixels for crisper motion, and **Match Mac** keeps the Mac's own resolution.
- The Mac's virtual display follows rotation, Split View, Stage Manager and window resizing live.

**Macs**
- Bonjour discovery of Macs on your network, plus Macs saved by address (VPNs such as Tailscale work too).
- Passwords are kept in the Keychain. Each saved Mac shows a thumbnail of its last session, its model icon and whether it's online.
- Per-Mac settings that override the global defaults: display mode, touch mode, audio, clipboard and smooth playback.
- Optionally reconnects to the last Mac at launch, and reconnects automatically after the app returns from the background.
- Clipboard sync for text, automatic or on demand.

**Robustness and platforms**
- If the UDP media stream is blocked or fails, the session falls back to the classic TCP framebuffer and shows a "Reduced performance" badge.
- iPhone layouts for compact screens. The iPad app also runs on Apple-silicon Macs ("Designed for iPad"), with the limitations listed below.

## Requirements

- **Host:** an Apple-silicon Mac with **Screen Sharing** turned on (System Settings › General › Sharing). Screener asks for High Performance mode automatically. High Performance screen sharing needs an Apple-silicon Mac on macOS Sonoma or later.
- **Client:** iPadOS 26 or iOS 26. An M-series iPad gives the best results. Apple-silicon Macs can run the iPad app.
- A fast local network. High Performance mode is designed for low-latency links, and it works over a VPN with a softer picture.

Note that High Performance mode always turns on display privacy on the host: the Mac's own screen goes dark while a session is active.

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone --recurse-submodules https://github.com/charlesvestal/screener.git
cd screener                         # (or: git submodule update --init)
cp Local.xcconfig.example Local.xcconfig   # then set your team id and bundle id
xcodegen generate
open Screener.xcodeproj
```

- `Local.xcconfig` is git-ignored. It sets `DEVELOPMENT_TEAM` and `SCREENER_BUNDLE_ID`. Simulator builds and tests work without it, but device builds need your team and a bundle id registered to it.
- `Reference/iShareScreen` is a git submodule containing the Python reference implementation. The app doesn't need it to build, but the fixture generator (`Tools/fixtures`) and `Tools/ref-connect.sh` use it.
- Run the tests on an iPad simulator:

  ```bash
  xcodebuild -project Screener.xcodeproj -scheme Screener \
    -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test
  ```

- The helper scripts in `Tools/` read device and simulator ids from the environment or from a git-ignored `Tools/local.env` (see `Tools/local.env.example`). Live-test credentials live in `~/.screener-test.env` (created by `Tools/make-test-env.sh`, mode 600). The scripts never put them in argv.

### Mac ("Designed for iPad")

`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` is on, so the iPad app also runs on Apple-silicon Macs. Build it with `-destination 'platform=macOS,arch=arm64,id=<your Mac's id>'` (`-showdestinations` lists the id). Known limitations:

- There's no pointer lock. The Mac's own pointer drives the session with absolute positioning.
- Picture in Picture is hidden.
- System-reserved shortcuts (⌘Tab, ⌘Space, ⌘Q, ⌘H, Mission Control keys) go to the local Mac. Use the control menu's Mac shortcuts to send them to the remote one.
- Resizing the window resizes the remote display.

## How it works

A High Performance session runs over two channels:

1. **Control channel (TCP 5900).** It starts as RFB (VNC). Authentication uses Apple's RSA1 security type, SRP-4096 (SHA-512, PBKDF2) wrapped in an RSA identity envelope, with the legacy RSA/AES variant only if you allow it for that Mac. After authentication, Apple's own record layer takes over: AES-128-CBC framing with a counter-keyed SHA-1 tag. Over that channel the client describes the virtual display it wants and exchanges a media offer and answer that carries the SRTP keys.
2. **Media (UDP).** Video arrives on port 5901 as SRTP (AES-256-CM, HMAC-SHA1-80). Each frame is four HEVC tiles, one SSRC each, all from a single HEVC sequence that shares one decoder. Audio arrives on 5900 as AAC-ELD. The client sends RTCP back on the same ports.

**Bitrate discovery: RCTL.** With the reference implementation's feedback, the Mac's encoder sat flat at ~17–20 Mbps no matter how much the screen moved. Packet captures of Apple's own client showed one extra RTCP packet every 50 ms: an APP packet named `RCTL` that carries a 20-byte rate-control block. Its last field is the receiver's bandwidth estimate in kbps, and the Mac uses it as its encoder target. Screener sends `RCTL` at 20 Hz with an adaptive estimate (4–65 Mbps, driven by measured loss and receive rate). With it, the host's video rate goes from ~20 Mbps to ~60 Mbps while you drag a window, at ~60 fps.

**Loss recovery.** Screener tracks which earlier pictures each picture uses as references, across tiles. A lost packet only drops the pictures that depend on it, and Screener asks for a keyframe only when nothing decodable is left.

More detail:
- [docs/research/2026-11-18-native-feedback.md](docs/research/2026-11-18-native-feedback.md): native client captures, the RCTL layout, A/B measurements, adaptive bandwidth estimation and loss recovery.
- [docs/superpowers/specs/2026-11-13-screener-ipad-hp-client-design.md](docs/superpowers/specs/2026-11-13-screener-ipad-hp-client-design.md): architecture and protocol design.
- [docs/superpowers/plans/](docs/superpowers/plans/): the implementation plan and its task log.
- Files ported from iShareScreen name the original Python functions in their headers.

## Status and limitations

Screener works day to day against Apple-silicon Macs. Things to know:

- The protocol is undocumented and was reverse-engineered, so a macOS update could change it.
- Only Apple-silicon hosts with High Performance mode are supported. Intel Macs are not a target.
- Discovery is Bonjour only. To reach a Mac away from home, add it by address over a VPN.
- The clipboard syncs plain text only.
- The Mac's screen is always curtained (dark) during a session. That's how High Performance mode works.
- Screener isn't distributed through the App Store or TestFlight. Build it yourself as described above.

## Privacy and security

- **No servers, no analytics.** Screener talks only to your Mac, directly, over your network or your VPN.
- **Passwords** are stored in the Keychain (`WhenUnlockedThisDeviceOnly`), never in app storage. They never appear in logs.
- **Mac identity pinning.** The first successful sign-in pins the SHA-256 of the Mac's RSA key. If the key ever changes, Screener stops before sending your password and asks you to confirm. A saved Mac's address only follows Bonjour when the pinned key matches.
- **Legacy sign-in** (the weaker non-SRP variant) is off unless you enable it for that Mac.
- **Clipboard.** Items that password managers mark as concealed or transient are never sent automatically. Manual mode only applies the Mac's clipboard when you ask for it.
- **Thumbnails** of your Mac's screen stay on the device. They're excluded from backups and file-protected, and you can clear them.
- **Logs** keep host names, addresses and user names private. "Share Log" exports a redacted copy.

## Credits

- **[iShareScreen](https://github.com/renegadelink/iShareScreen)** (AGPL-3.0). Screener's High Performance protocol logic (handshake, authentication, record layer, media negotiation, SRTP/RTCP transport, video assembly and input) is ported in part from this Python implementation. It's included as a submodule under `Reference/`. Thank you to its authors for the original reverse-engineering work.
- **[BigInt](https://github.com/attaswift/BigInt)** by Károly Lőrentey (MIT). Vendored in `Vendor/BigInt` for the SRP arithmetic.

Full notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) and in the app under Hosts › About › Acknowledgements.

## License

Screener is free software under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0), the same license as iShareScreen, from which it is partly derived.

Not affiliated with Apple. macOS, iPadOS, iOS, Mac, iPad, iPhone and Bonjour are trademarks of Apple Inc.
