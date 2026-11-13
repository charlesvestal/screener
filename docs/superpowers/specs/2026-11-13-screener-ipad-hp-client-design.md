# Screener — iPad client for macOS Screen Sharing "High Performance" mode

Date: 2026-11-13
Status: Approved design, pending implementation plan

## Goal

An open-source (AGPL-3.0) iPadOS app that connects to a Mac's built-in Screen Sharing
service using Apple's **High Performance** mode: HEVC RExt 4:4:4 video and AAC-ELD audio
over UDP/SRTP, with control on TCP 5900. No software is installed on the Mac.

## Background

- Apple does not document the High Performance protocol.
- Screens 5.10.3 (Edovia) implements it natively. Its `VNCKit.framework` has
  `VncAppleHighPerformanceSession`, `VncAppleHEVCDecoder`, RTP/HEVC assembly and a
  TCP-only fallback, and its UI strings say display privacy is forced on in HP mode.
- [iShareScreen](https://github.com/renegadelink/iShareScreen) (AGPL-3.0, Python) is a
  working reverse-engineered client. Its `docs/apple_vnc_rfc.md` documents the protocol.
  Screener ports its protocol logic to Swift and credits it. Screener is AGPL-3.0 as well.

## Scope (v1)

1. Connect over the LAN in HP mode; display the HEVC stream; control with mouse,
   trackpad, keyboard and touch.
2. Remote audio playback.
3. Two-way clipboard sync.
4. Bonjour discovery of `_rfb._tcp`, saved hosts, credentials in Keychain.

5. Quality-of-life features (added 2026-11-13 at the user's request: "think through all the
   niceties like automatic reconnection, modifier keys in a floating menu, etc"):
   - **Automatic reconnection:** reconnect silently on network change (`NWPathMonitor`), when
     the app returns from the background, and when the host wakes. Keep the last frame on
     screen with a small "Reconnecting…" pill. Give up only after 3 failed attempts.
   - **Floating control menu:** a draggable pill that snaps to screen edges and auto-hides.
     - Sticky modifiers ⌘ ⌥ ⌃ ⇧ fn: tap to latch for one keystroke, double-tap to lock.
     - Special-keys row: Esc, Tab, arrows, F1–F12, forward delete, Home/End, PgUp/PgDn.
     - Shortcut actions: ⌘Tab, ⌘Space, Mission Control, Lock Screen ⌃⌘Q, Force Quit ⌘⌥Esc,
       Screenshot ⌘⇧4.
     - Keyboard toggle, "Type Password" (types the saved password into the Mac's lock
       screen), send/fetch clipboard, mute, stats, display mode, disconnect.
   - **Touch input modes:** trackpad mode (relative cursor; the default, like Screens) and
     direct-touch mode, with pinch-zoom and a viewport that follows the cursor. Also scroll
     inertia, haptic click feedback, Apple Pencil hover moves the pointer, and pointer lock
     when full screen with a trackpad.
   - **Keyboard:** iPadOS system shortcuts such as ⌘H, ⌘W and ⌘Q go to the Mac where iPadOS
     allows it, and Caps Lock state stays in sync. Shortcuts iPadOS always keeps for itself
     (⌘Tab, ⌘Space, Globe) are reachable from the floating menu instead.
   - **Display modes:** Fit iPad (Retina), Fit iPad (more space), Match Mac. The remote
     resolution follows rotation and Stage Manager window resizes in-band (RFC §10.9).
   - **Hosts:**
     - Last-frame thumbnails, reachability badges, search, recents.
     - Per-host settings: display mode, input mode, audio, clipboard.
     - Wake-on-LAN, using a MAC address the user enters.
     - Server RSA key pinning on first use, with a warning if the key changes (RFC §13.2).
   - **System integration:**
     - `screener://connect?host=` URL scheme and an App Intent so Shortcuts and Spotlight
       can connect to a saved host.
     - The idle timer stays off while connected.
     - Several sessions at once, each in its own Stage Manager window (one scene per session).

Out of scope for v1: standard VNC (non-HP) sessions, connections over the internet or
through a relay, multi-display selection UI beyond the default display, file transfer,
iPhone layout, mirroring to an external display, and image/file clipboard (text only).

## Test environment

- Host: this M1 Mac, with Screen Sharing enabled and listening on TCP 5900.
- Client: iPad Pro 13" (M5), paired with this Mac.
- HP mode forces display privacy, so the host screen goes dark during a session. Live
  tests are short runs started from this Mac and watched on the iPad.

## Architecture

There is one Xcode project, `Screener.xcodeproj`, with a single iPadOS 26 app target
(Swift 6, SwiftUI, Metal). The only third-party dependency is a BigInt Swift package,
used for SRP. Code is organised by layer:

| Folder | Responsibility | Reference source |
|---|---|---|
| `Protocol/` | RFB version and security negotiation; RSA1+SRP and non-SRP auth; enc1103 record layer and `0x44f` rekey; Apple prelude (ViewerInfo, SetEncryption, SetMode); SetDisplayConfiguration; Apple messages (cursor `0x450`, layout `0x451`, keysyms `0x453`, input source `0x455`, device info `0x456`, media offers, clipboard) | `rfb.py`, `auth.py`, `negotiation.py`, `offers.py`, `clipboard.py`, `session.py`, `apple_vnc_rfc.md` |
| `Transport/` | TCP control socket and UDP 5900 (audio + RTCP) / 5901 (video) on Network.framework; SRTP decryption; keepalives; RTCP keyframe requests | `srtp.py`, `burst.py`, `session.py` |
| `Media/` | `HEVCAssembler` (RTP → NAL units, DON reordering, FU reassembly, loss handling); `VideoDecoder` (VTDecompressionSession, 4:4:4); `MetalRenderer`; `AudioPlayer` (AudioToolbox AAC-ELD → AVAudioEngine) | `hevc.py`, `hevc_rps.py`, `vtdecode.py`, `aac_eld.py` |
| `Input/` | Pointer events (trackpad, mouse, Pencil), hardware keyboard → Apple keysym messages, touch gestures (tap = click, two-finger scroll, drag), clipboard sync | `input.py`, `keyboard_grab.py`, `clipboard.py` |
| `Hosts/` | `NWBrowser` Bonjour discovery, SwiftData `SavedHost`, Keychain credentials | — |
| `UI/` | Host list, connect sheet, full-screen session view with toolbar (keyboard, disconnect, stats) | — |

### Session flow

1. TCP connect, then RFB version and security-type negotiation, then authentication
   (SRP preferred, non-SRP fallback). Authentication yields the session key.
2. Turn on the encrypted record layer. Send ViewerInfo, SetEncryption, SetMode, and
   SetDisplayConfiguration sized to the iPad's native resolution.
3. Accept the media offers. Open the UDP flows with SRTP.
4. Video: UDP 5901 → SRTP → `HEVCAssembler` → `VideoDecoder` → `MetalRenderer`.
   Audio: UDP 5900 → SRTP → AAC-ELD → AVAudioEngine.
   Input and clipboard go back over the encrypted TCP channel.

A single `Session` actor owns all of these, and the session view owns the `Session`.

## Error handling

- **Auth failures** (bad credentials, Screen Sharing disabled, user not permitted) are
  shown in the connect sheet with the server's reason. Each handshake step times out
  after 10 s.
- **Network loss or host sleep** shows a "Reconnecting…" overlay, retries 3 times with
  backoff, then returns to the host list.
- **Video packet loss** drops broken access units and sends an RTCP keyframe request.
  The picture freezes briefly instead of showing artefacts.
- **UDP blocked** (no video for 3 s): switch to the TCP-only fallback and show a
  "Reduced performance" badge.
- **Decoder error** rebuilds the VideoToolbox session and requests a keyframe.
- **Logging** uses `os_log`, subsystem `com.screener`, with one category per layer.

## Testing and verification

- XCTest unit tests run in the iPad simulator. They cover SRP math, the record layer
  (CBC state, sequence numbers, integrity trailer), SRTP decryption, HEVC RTP
  assembly, and message encode/decode. They use iShareScreen's tests and fixtures
  as known-answer vectors where available.
- On-device milestones, run on the iPad Pro against this Mac, each gated in order:
  1. Authentication succeeds.
  2. The encrypted channel is up and messages round-trip.
  3. HP is negotiated and the first UDP packets arrive.
  4. The first decoded frame is visible.
  5. Mouse and keyboard control work.
  6. Audio plays.
  7. Clipboard syncs both ways.
  8. Bonjour discovery and saved hosts work.

  Builds are installed with `xcodebuild` and `devicectl`, and logs are read from the
  device. Visual and audio milestones are confirmed by the user.
- When debugging, run iShareScreen against the same Mac and compare its logs and bytes
  with Screener's.
