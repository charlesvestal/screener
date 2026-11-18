# Screener

Screener is an open-source iPadOS and iOS app that connects to a Mac's built-in Screen Sharing in Apple's "High Performance" mode, letting you use your Mac remotely from an iPad or iPhone. The iPad app also runs on Apple-silicon Macs ("Designed for iPad"). Protocol logic is ported from [iShareScreen](https://github.com/renegadelink/iShareScreen) (AGPL-3.0). Screener is licensed AGPL-3.0.

## Requirements

- An Apple-silicon Mac with Screen Sharing enabled and High Performance mode allowed.
- An M-series iPad, or an iPhone on iOS 26, or an Apple-silicon Mac (as an iPad app).

## Building

```bash
brew install xcodegen
git submodule update --init
xcodegen generate
open Screener.xcodeproj
```

## iPhone

The same app, with layouts for compact size classes (`Screener/UI/AdaptiveLayout.swift`):

- **Host list**: one column of rows, each with a small thumbnail beside the Mac's name.
- **Session**: full screen, edge to edge. Portrait shows a "turn sideways" hint once per session, since a Mac desktop is wide.
- **Display size**: Fit (Retina) is the default on every device, and its geometry depends on the screen scale. The Mac's virtual display is always 2× HiDPI, sized pixel for pixel to the view. On a 3× iPhone, that makes the Mac desktop 1.5× the phone's points: an iPhone 17 Pro in landscape gets a 1311×603 pt desktop, drawn 1:1 into its 2622×1206 px screen. Mac text appears at about ⅔ of its size on the Mac. Pinch to zoom in, and use trackpad mode (the default) to point precisely. Sharper and More Space scale from there.
- **Control menu**: the same draggable pill. Tapping it opens a bottom sheet (medium and large detents) with the same sections, including the modifier glow and the quality badge. Keyboard closes the sheet first.
- **Keyboard row**: the keys stay at least 44 pt wide, and the row scrolls sideways when the screen is too narrow (portrait).
- **Toasts, stats, gesture coach**: toasts wrap on narrow screens, the stats panel sits below the toast row, and the coach uses shorter cards in landscape.
- **Picture in Picture**: the same code as on iPad.

## Mac ("Designed for iPad")

`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` is on, so the iPad app is offered on Apple-silicon Macs. Build it with `xcodebuild -scheme Screener -destination 'platform=macOS,arch=arm64,id=<your Mac's id>'` (`-showdestinations` lists the id). Known limitations:

- **Pointer lock is off** (`ProcessInfo.isiOSAppOnMac`). macOS doesn't lock its pointer to an iOS app's window, and GCMouse deltas aren't the primary pointer there. The Mac's own pointer drives the session through hover and clicks (absolute positioning).
- **Picture in Picture is hidden**. Keep the window small instead.
- **Keyboard**: GCKeyboard reports keys while the window is key. System-reserved shortcuts (⌘Tab, ⌘Space, ⌘Q, ⌘H, Mission Control keys) go to the local Mac, not the remote one. Use the menu's Mac Shortcuts for those.
- **Display scale**: the window's screen scale is 2 on Retina displays and 1 on non-Retina displays, and the Mac's virtual display follows it (1× HiDPI on a non-Retina display). Resizing the window resizes the remote display, like Stage Manager on iPad.
- **Local network**: macOS asks for Local Network permission the first time, just as iOS does. Bonjour discovery needs it.
- **Keychain**: passwords go in the data-protection Keychain under the app's identifier, so they are separate from the iPad's copies.
- **Background**: hiding or minimizing the window may not background the scene. The session stays open until you disconnect or quit.

## Third-party code

- [iShareScreen](https://github.com/renegadelink/iShareScreen) (AGPL-3.0): the High Performance protocol logic is ported in part from it.
- [BigInt](https://github.com/attaswift/BigInt) by Károly Lőrentey (MIT): vendored in `Vendor/BigInt` for the SRP arithmetic.

The full notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) and in the app (Hosts › About › Acknowledgements).

## Notes

High Performance mode forces display privacy on the host Mac: the host's screen goes dark while a session is active.
