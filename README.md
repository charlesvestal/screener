# Screener

Screener is an open-source iPadOS app that connects to a Mac's built-in Screen Sharing in Apple's "High Performance" mode, letting you use your Mac remotely from an iPad. Protocol logic is ported from [iShareScreen](https://github.com/renegadelink/iShareScreen) (AGPL-3.0). Screener is licensed AGPL-3.0.

## Requirements

- An Apple-silicon Mac with Screen Sharing enabled and High Performance mode allowed.
- An M-series iPad.

## Building

```bash
brew install xcodegen
git submodule update --init
xcodegen generate
open Screener.xcodeproj
```

## Notes

High Performance mode forces display privacy on the host Mac: the host's screen goes dark while a session is active.
