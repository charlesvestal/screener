# Screener (iPad HP Screen Sharing client) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an iPadOS app that connects to a Mac's built-in Screen Sharing service in Apple's High Performance mode (HEVC 4:4:4 + AAC-ELD over SRTP/UDP) with mouse/keyboard/touch control, audio, clipboard and Bonjour host discovery.

**Architecture:** A single iPadOS app target. Code is organised in folders by protocol layer (`Protocol/`, `Transport/`, `Media/`, `Input/`, `Hosts/`, `UI/`). The protocol logic is ported from the AGPL Python reference iShareScreen, which is vendored as a git submodule at `Reference/iShareScreen`. Its spec is `Reference/iShareScreen/docs/apple_vnc_rfc.md` (cited below as **RFC §x**). Deterministic components are unit-tested in the iPad simulator against known-answer fixtures generated from the reference Python code. Live behaviour is verified on the user's iPad Pro against the host Mac.

**Tech Stack:** Swift 6, SwiftUI + UIKit, Network.framework, CommonCrypto, Security.framework, VideoToolbox, Metal/MetalKit, AudioToolbox/AVFAudio, SwiftData, XcodeGen, [attaswift/BigInt](https://github.com/attaswift/BigInt) (MIT), XCTest. Fixture generation uses `uv` + Python 3.12.

**User decisions (already made):**
- "apple's built-in": connect to macOS's native High Performance mode. No helper app on the Mac.
- "Open source on GitHub": AGPL-3.0, porting iShareScreen code with credit.
- v1 scope: "Video + mouse/keyboard, Audio, Clipboard sync, Saved hosts + Bonjour".
- Test setup: "M-series iPad, this Mac as host" (iPad Pro 13" M5 UDID `00000000-0000000000000000`; host = this M1 Mac).
- Approach: "Approach B": one iPad app, ported directly, tested on device. No separate package and no Mac probe CLI.
- Niceties: "think through all the niceties like automatic reconnection, modifier keys in a floating menu, etc" → Tasks 19–24.

**Porting convention (applies to every task that ports reference code):** the reference is pinned at commit `9ab40d3a3151524f954cff9d6239d891197c1705`. When a step says "port `X` from `file.py`", read that function in full and reproduce its wire behaviour exactly: byte layouts, constants, ordering and edge cases. Write it as idiomatic Swift; do not transliterate Python idioms. Drop the reference's Linux/Windows backends, browser frontend, AVC/H.264 path, libav logging and env-var knobs. Add a header comment `// Ported from iShareScreen <path> (AGPL-3.0)` to each ported file.

**Common commands** (used in Verify lines):
- `$SIM` = `-destination 'platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000'` (iPad Pro 13-inch (M5) simulator)
- `$DEV` = `-destination 'id=00000000-0000000000000000'`
- Unit tests: `xcodebuild test -project Screener.xcodeproj -scheme Screener $SIM -only-testing:ScreenerTests/<Class> 2>&1 | tail -5` → expect `** TEST SUCCEEDED **`
- Device build+install+launch: `Tools/run-on-ipad.sh` (created in Task 0)
- Device log fetch: `Tools/fetch-ipad-log.sh` (created in Task 0) → prints `screener.log` from the app's Documents container

**Live-test caveat:** HP mode forces display privacy on the host, so this Mac's screen goes dark while the iPad is connected. Live-session steps must be kept short. Start them from the terminal and ask the user to watch the iPad. The user disconnects from the iPad toolbar (or by force-quitting the app) to get the Mac's screen back.

---

## File Structure

```
screener/
├── project.yml                      XcodeGen spec (app + unit-test targets, BigInt package)
├── LICENSE                          AGPL-3.0 text
├── README.md                        what it is, credits iShareScreen, build steps
├── .gitignore / .gitmodules
├── Reference/iShareScreen/          git submodule, pinned
├── Tools/
│   ├── run-on-ipad.sh               build → install → launch on the iPad
│   ├── fetch-ipad-log.sh            pull Documents/screener.log from the iPad
│   └── fixtures/make_fixtures.py    generates ScreenerTests/Fixtures/*.json from the reference
├── Screener/
│   ├── App/ScreenerApp.swift        @main, SwiftData container
│   ├── App/Log.swift                os_log + file mirror (Documents/screener.log)
│   ├── Support/ByteIO.swift         ByteWriter / ByteReader (big-endian)
│   ├── Support/CryptoPrimitives.swift  AES-ECB, streaming AES-CBC, AES-CTR, SHA1/256/512, HMAC-SHA1, PBKDF2-SHA512, random
│   ├── Protocol/SRP.swift           SRP-6a client (Apple profile)
│   ├── Protocol/RecordLayer.swift   enc1103 AES-128-CBC + SHA-1 record layer
│   ├── Protocol/Auth.swift          RSA1 envelope, SRP auth (type 33), non-SRP fallback
│   ├── Protocol/RFBHandshake.swift  version, security types, ClientInit/ServerInit, session-select detection
│   ├── Protocol/Messages.swift      client→server message builders
│   ├── Protocol/ServerMessages.swift server→client parsers (FBU rects, 0x451/0x450/0x455/0x456/0x14/0x1f)
│   ├── Protocol/MediaOffer.swift    AVCMediaStreamNegotiator offer blobs + 0x1c build/answer parse
│   ├── Protocol/Clipboard.swift     pasteboard archive build/parse + zlib
│   ├── Protocol/ControlSession.swift actor: full TCP session lifecycle + event stream
│   ├── Transport/ByteStream.swift   protocol + NWConnection TCP impl + in-memory test pipe
│   ├── Transport/SRTP.swift         SRTP/SRTCP decrypt + encrypt (keepalive/RTCP)
│   ├── Transport/RTCP.swift         RR, FIR (legacy + AVPF), PLI, NACK builders
│   ├── Transport/MediaTransport.swift UDP 5900/5901 NWConnections, keepalive, feedback
│   ├── Media/HEVCDepacketizer.swift Apple RFC 7798 variant (DONL) → NAL units
│   ├── Media/HEVCAssembler.swift    per-SSRC ordering, access-unit assembly, param-set cache, loss → FIR
│   ├── Media/VideoDecoder.swift     VTDecompressionSession (HEVC RExt 4:4:4)
│   ├── Media/MetalRenderer.swift    MTKView delegate: 4:4:4 bi-planar → RGB, aspect-fit, cursor overlay
│   ├── Media/AudioPlayer.swift      AAC-ELD AudioConverter → AVAudioEngine
│   ├── Media/ZlibRectDecoder.swift  TCP-fallback: encoding 0x06 zlib rects → BGRA framebuffer
│   ├── Input/Keysyms.swift          UIKeyboardHIDUsage → X11 keysym table
│   ├── Input/InputController.swift  pointer/scroll/key → control messages, coordinate mapping
│   ├── Input/RemoteInputView.swift  UIView capturing pointer, touch gestures, hardware keys, soft keyboard
│   ├── Hosts/SavedHost.swift        SwiftData model
│   ├── Hosts/Keychain.swift         password storage
│   ├── Hosts/BonjourBrowser.swift   NWBrowser for _rfb._tcp
│   ├── Session/SessionCoordinator.swift @MainActor: ControlSession + MediaTransport + decoders + reconnect/fallback
│   └── UI/
│       ├── HostListView.swift       saved + discovered hosts
│       ├── ConnectSheet.swift       host/user/password form
│       ├── SessionView.swift        full-screen remote display + toolbar + overlays
│       └── StatsOverlay.swift       fps / bitrate / loss
└── ScreenerTests/
    ├── Fixtures/*.json              generated by Tools/fixtures/make_fixtures.py
    ├── FixtureLoader.swift
    └── <Component>Tests.swift
```

---

### Task 0: Project scaffold

**Goal:** A buildable, launchable iPadOS app skeleton with unit-test target, BigInt dependency, logging, AGPL licensing, the reference submodule, and device helper scripts.

**Files:**
- Create: `project.yml`, `LICENSE`, `README.md`, `.gitignore`, `.gitmodules` (via `git submodule add`)
- Create: `Screener/App/ScreenerApp.swift`, `Screener/App/Log.swift`, `Screener/UI/HostListView.swift` (placeholder text only)
- Create: `ScreenerTests/FixtureLoader.swift`, `ScreenerTests/SmokeTests.swift`
- Create: `Tools/run-on-ipad.sh`, `Tools/fetch-ipad-log.sh`

**Acceptance Criteria:**
- [ ] `xcodegen generate` produces `Screener.xcodeproj` without errors
- [ ] `SmokeTests` passes in the iPad simulator
- [ ] `Tools/run-on-ipad.sh` installs and launches the app on the iPad (exit 0)
- [ ] `Tools/fetch-ipad-log.sh` prints a line containing `Screener launched`
- [ ] `Reference/iShareScreen` is a submodule at commit `9ab40d3a`

**Verify:** `xcodegen generate && xcodebuild test -project Screener.xcodeproj -scheme Screener $SIM -only-testing:ScreenerTests/SmokeTests 2>&1 | tail -3` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1: Add the reference submodule and license**

```bash
cd /path/to/github/screener
git submodule add https://github.com/renegadelink/iShareScreen Reference/iShareScreen
git -C Reference/iShareScreen checkout 9ab40d3a3151524f954cff9d6239d891197c1705
cp Reference/iShareScreen/LICENSE LICENSE   # AGPL-3.0 full text
```

`.gitignore`:
```
*.xcodeproj/
DerivedData/
build/
.DS_Store
xcuserdata/
Tools/fixtures/.venv/
```

(The `.xcodeproj` is generated; `project.yml` is the source of truth.)

- [ ] **Step 2: Write `project.yml`**

```yaml
name: Screener
options:
  bundleIdPrefix: com.charlesvestal
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    DEVELOPMENT_TEAM: YOURTEAMID
    CODE_SIGN_STYLE: Automatic
    TARGETED_DEVICE_FAMILY: "2"
packages:
  BigInt:
    url: https://github.com/attaswift/BigInt
    from: "5.4.0"
targets:
  Screener:
    type: application
    platform: iOS
    sources: [Screener]
    dependencies:
      - package: BigInt
    info:
      path: Screener/Info.plist
      properties:
        CFBundleDisplayName: Screener
        UILaunchScreen: {}
        UIRequiresFullScreen: false
        UISupportedInterfaceOrientations~ipad:
          [UIInterfaceOrientationPortrait, UIInterfaceOrientationPortraitUpsideDown,
           UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight]
        NSLocalNetworkUsageDescription: Screener connects to Macs on your local network for screen sharing.
        NSBonjourServices: [_rfb._tcp]
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UIApplicationSupportsIndirectInputEvents: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.charlesvestal.screener
  ScreenerTests:
    type: bundle.unit-test
    platform: iOS
    sources: [ScreenerTests]
    resources: [ScreenerTests/Fixtures]
    dependencies:
      - target: Screener
schemes:
  Screener:
    build:
      targets: {Screener: all, ScreenerTests: [test]}
    test:
      targets: [ScreenerTests]
```

Create `ScreenerTests/Fixtures/.gitkeep` so the resource folder exists.

- [ ] **Step 3: Write `Log.swift`**

```swift
import Foundation
import os

/// Per-layer loggers. Every message is also appended to Documents/screener.log
/// so Tools/fetch-ipad-log.sh can read it from the device.
enum Log {
    static let app = Channel("app")
    static let auth = Channel("auth")
    static let record = Channel("record")
    static let control = Channel("control")
    static let media = Channel("media")
    static let video = Channel("video")
    static let audio = Channel("audio")
    static let input = Channel("input")
    static let hosts = Channel("hosts")

    struct Channel: Sendable {
        let logger: Logger
        let name: String
        init(_ name: String) {
            self.name = name
            self.logger = Logger(subsystem: "com.screener", category: name)
        }
        func info(_ msg: String) { logger.info("\(msg, privacy: .public)"); FileMirror.shared.write("[\(name)] \(msg)") }
        func error(_ msg: String) { logger.error("\(msg, privacy: .public)"); FileMirror.shared.write("[\(name)] ERROR \(msg)") }
        func debug(_ msg: String) { logger.debug("\(msg, privacy: .public)") }
    }
}

final class FileMirror: @unchecked Sendable {
    static let shared = FileMirror()
    private let queue = DispatchQueue(label: "screener.filelog")
    private var handle: FileHandle?
    private let formatter = ISO8601DateFormatter()

    private init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("screener.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)   // truncate per launch
        handle = try? FileHandle(forWritingTo: url)
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
    }

    func write(_ line: String) {
        let stamp = formatter.string(from: Date())
        queue.async { [handle] in
            handle?.write(Data("\(stamp) \(line)\n".utf8))
        }
    }
}
```

- [ ] **Step 4: App entry and placeholder UI**

`ScreenerApp.swift`:
```swift
import SwiftUI

@main
struct ScreenerApp: App {
    init() { Log.app.info("Screener launched") }
    var body: some Scene {
        WindowGroup { HostListView() }
    }
}
```

`HostListView.swift` (placeholder until Task 18):
```swift
import SwiftUI

struct HostListView: View {
    var body: some View {
        NavigationStack { Text("Screener").navigationTitle("Hosts") }
    }
}
```

- [ ] **Step 5: Test support**

`FixtureLoader.swift`:
```swift
import Foundation
import XCTest

enum Fixture {
    /// Loads ScreenerTests/Fixtures/<name>.json as a dictionary.
    static func load(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: BundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private final class BundleToken {}

extension Data {
    init(hex: String) {
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
```

`SmokeTests.swift`:
```swift
import XCTest
@testable import Screener

final class SmokeTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(Data(hex: "00ff10").hex, "00ff10")
    }
}
```

- [ ] **Step 6: Device scripts**

`Tools/run-on-ipad.sh`:
```bash
#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=00000000-0000000000000000
xcodegen generate >/dev/null
xcodebuild -project Screener.xcodeproj -scheme Screener -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates build | tail -3
APP=build/Build/Products/Debug-iphoneos/Screener.app
xcrun devicectl device install app --device $DEVICE "$APP"
xcrun devicectl device process launch --terminate-existing --device $DEVICE com.charlesvestal.screener "$@"
```

`Tools/fetch-ipad-log.sh`:
```bash
#!/bin/zsh
set -euo pipefail
DEVICE=00000000-0000000000000000
OUT=$(mktemp -d)
xcrun devicectl device copy from --device $DEVICE --domain-type appDataContainer \
  --domain-identifier com.charlesvestal.screener --source Documents/screener.log --destination "$OUT/screener.log" >/dev/null
cat "$OUT/screener.log"
```

`chmod +x Tools/*.sh`

- [ ] **Step 7: README**

Include: a one-paragraph description; "Protocol logic ported from [iShareScreen](https://github.com/renegadelink/iShareScreen) (AGPL-3.0). Screener is licensed AGPL-3.0."; requirements (Mac with Apple silicon, Screen Sharing enabled, High Performance allowed; iPad with M-series chip); build steps (`brew install xcodegen`, `git submodule update --init`, `xcodegen generate`, open the project); and the display-privacy caveat.

- [ ] **Step 8: Generate, test, run on device, commit**

```bash
xcodegen generate
xcodebuild test -project Screener.xcodeproj -scheme Screener $SIM -only-testing:ScreenerTests/SmokeTests 2>&1 | tail -3
Tools/run-on-ipad.sh && sleep 3 && Tools/fetch-ipad-log.sh   # expect "Screener launched"
git add -A && git commit -m "chore: scaffold Screener iPad app"
```

If the device build fails for signing, have the user unlock the iPad and trust the developer certificate (Settings → General → VPN & Device Management), then re-run.

---

### Task 1: Reference fixture generator

**Goal:** A script that drives the reference Python modules with fixed inputs and writes known-answer JSON fixtures that later Swift tests compare against.

**Files:**
- Create: `Tools/fixtures/make_fixtures.py`, `Tools/fixtures/README.md`
- Create (generated): `ScreenerTests/Fixtures/record_layer.json`, `srp.json`, `srtp.json`, `messages.json`, `media_offer.json`, `clipboard.json`, `rtcp.json`, `hevc_rtp.json`

**Acceptance Criteria:**
- [ ] `uv run ... make_fixtures.py` exits 0 and writes all 8 JSON files
- [ ] Every byte value in the fixtures is produced by calling **reference** functions or classes (not re-implemented in the script), except where noted in Step 2
- [ ] Re-running produces byte-identical files (all randomness seeded or fixed)

**Verify:** `cd Tools/fixtures && uv run --python 3.12 --with cryptography --with pycryptodome --with numpy python make_fixtures.py && ls ../../ScreenerTests/Fixtures/*.json | wc -l` → `8`

**Steps:**

- [ ] **Step 1: Import strategy.** Put `Reference/iShareScreen/src` on `sys.path`. Import only `isharescreen.proxy.protocol.*` submodules and `isharescreen.proxy.media.hevc_rps`/NAL helpers as needed. If a module's import chain drags in `av`, `glfw` or `wgpu`, load that single file with `importlib.util.spec_from_file_location` and stub the missing package in `sys.modules` before loading. Write hex strings for bytes and ints for numbers.

- [ ] **Step 2: Produce these fixtures** (field names are the contract with the Swift tests):

| File | Contents | Reference source |
|---|---|---|
| `record_layer.json` | `ecb_key`, `key_blob_36`, `cbc_key` (unwrapped), plus `client_records`: list of `{plaintext, wire}` for 3 consecutive `encrypt_message` calls (bodies `1d00…`, `0200…`, `0300…`) on one `StreamCipher`. The reference pads with zeros, so the output is deterministic. | `enc1103.StreamCipher` |
| `srp.json` | Fixed `salt`, `iterations` (=1000), `password` (`"test-password"`), `a` (fixed 32-byte secret), `b` (server secret). Use the RFC 5054 4096 `N` and `g=5`. Expected: `x`, `A`, `B` (computed server-side with `v=g^x`, `k`, `b`), `u`, `S`, `K`, `M1`, `M2`, `wrap_key` (= SHA-256(K)[0:16]). Use `auth._derive_x` and the math inside `auth._solve_srp`. If `_solve_srp` draws `a` from `secrets`, monkeypatch that source to return the fixed `a`. The server-side `B` is computed in the script because the reference has no server; that is the one allowed re-implementation. | `auth._derive_x`, `auth._solve_srp`, `auth._parse_apple_srp_challenge` |
| `srp.json` (cont.) | `challenge_wire`: a challenge frame built per RFC §4.2.4.4 from the same values, and the parsed fields `_parse_apple_srp_challenge` returns | as above |
| `srtp.json` | `blob` (46 B fixed), the derived `cipher_key`, `auth_key` and `salt` (via `_srtp_kdf` labels 0/1/2); 3 packets from `SRTPEncryptor.encrypt` (ssrc 0x11223344, PT 100, seqs 65534, 65535, 0) with their `plaintext`; and one `SRTCPEncryptor.protect` sample | `srtp.py` |
| `messages.json` | Output of each reference builder with fixed args: `build_set_encodings()`, `build_post_encryption_toggle()`, `build_key_event(down=True, keysym=0x61)`, `build_pointer_event(buttons=1,x=100,y=200)`, `build_viewer_info(...)` (defaults), `build_virtual_display(...)` for 2752×2064 logical / 1376×1032 scaled (static form), `build_fbu_request(...)` non-incremental, `build_auto_framebuffer_update(2752,2064)`, `_build_msg10_pointer(...)` (from `input.py`, with a fixed ECB key), `_build_apple_viewer_command_mask()`. Plus parser vectors: a synthesized `0x451` body (from the RFC §8.4 layout, 1 display, 1920×1080 scaled / 3840×2160 backing) with the dict `rfb.parse_apple_display_layout` returns. | `rfb.py`, `negotiation.py`, `input.py`, `apple.py` |
| `media_offer.json` | `create_offers(audio_enabled=True)` with `secrets`, `uuid` and `time` monkeypatched to fixed values → `audio_offer`, `video_offer`; `build_0x1c(...)` with fixed `NegotiationKeys` → `msg_1c`; and a synthesized answer with the result of `extract_canvas_dims(answer)` | `offers.py`, `negotiation.py` |
| `clipboard.json` | `build_clipboard_send("héllo 👋")`, `build_auto_pasteboard_msg()`, `build_clipboard_request()`, and a round-trip: decompress+parse of a payload built from the same text | `clipboard.py` |
| `rtcp.json` | `build_fir_legacy(0x11223344)`, `build_fir(1, 0x11223344, 7)`, `build_pli(1, 0x11223344)`, `build_nack(1, 0x11223344, [10,11,13])`, `build_rr(...)` with fixed args, `build_rtcp_app_ltrp(1, 5)` | `rtcp.py` |
| `hevc_rtp.json` | Hand-built RTP payloads per RFC §10.6: a single NAL (type 1) with DONL, an AP (type 48) carrying VPS/SPS/PPS, and FU (type 49) start/middle/end fragments of one IDR slice. Each comes with the expected de-DONL'd NAL units. These are synthesized in the script from the RFC layout. The reference parser for this lives inside `session.py`/`hevc.py` and is not callable in isolation, so cross-check the layout against those functions by reading them. | RFC §10.6, `hevc.py` |

- [ ] **Step 3: Run and commit**

```bash
cd Tools/fixtures && uv run --python 3.12 --with cryptography --with pycryptodome --with numpy python make_fixtures.py
cd ../.. && git add Tools/fixtures ScreenerTests/Fixtures && git commit -m "test: generate known-answer fixtures from iShareScreen reference"
```

---

### Task 2: ByteIO helpers

**Goal:** Big-endian `ByteWriter`/`ByteReader` used by every protocol message.

**Files:**
- Create: `Screener/Support/ByteIO.swift`
- Test: `ScreenerTests/ByteIOTests.swift`

**Acceptance Criteria:**
- [ ] Writer emits BE u8/u16/u32/u64/f32/f64, raw bytes, zero padding, and little-endian u32
- [ ] Reader throws `ByteReader.Error.underflow` on short reads and never traps

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/ByteIOTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import Screener

final class ByteIOTests: XCTestCase {
    func testWriterBigEndian() {
        var w = ByteWriter()
        w.u8(0x1d); w.u8(0); w.u16(304); w.u32(0x01020304); w.f64(60.0); w.u32le(7); w.zeros(2)
        XCTAssertEqual(w.data.hex, "1d00013001020304404e000000000000070000000000")
    }
    func testReaderRoundTripAndUnderflow() throws {
        var r = ByteReader(Data(hex: "0001000000020304"))
        XCTAssertEqual(try r.u16(), 1)
        XCTAssertEqual(try r.u32(), 2)
        XCTAssertEqual(try r.bytes(2).hex, "0304")
        XCTAssertThrowsError(try r.u8())
    }
}
```

- [ ] **Step 2:** Run it and expect a compile failure (`ByteWriter` undefined).

- [ ] **Step 3: Implement**

```swift
import Foundation

struct ByteWriter {
    private(set) var data = Data()
    init(capacity: Int = 64) { data.reserveCapacity(capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
}

struct ByteReader {
    enum Error: Swift.Error { case underflow(needed: Int, remaining: Int) }
    private let data: Data
    private(set) var offset: Int = 0
    init(_ data: Data) { self.data = Data(data) }   // rebase indices to 0
    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, n <= remaining else { throw Error.underflow(needed: n, remaining: remaining) }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }
    mutating func skip(_ n: Int) throws { _ = try bytes(n) }
    mutating func rest() -> Data { let d = data.subdata(in: offset..<data.count); offset = data.count; return d }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 { try fixed() }
    mutating func u32() throws -> UInt32 { try fixed() }
    mutating func u64() throws -> UInt64 { try fixed() }
    mutating func u32le() throws -> UInt32 { UInt32(littleEndian: try fixed(bigEndian: false)) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    private mutating func fixed<T: FixedWidthInteger>(bigEndian: Bool = true) throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        let v = raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        return bigEndian ? T(bigEndian: v) : v
    }
}
```

- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add big-endian ByteWriter/ByteReader"`

---

### Task 3: Crypto primitives

**Goal:** Thin, tested wrappers over CommonCrypto/CryptoKit for every primitive the protocol needs.

**Files:**
- Create: `Screener/Support/CryptoPrimitives.swift`
- Test: `ScreenerTests/CryptoPrimitivesTests.swift`

**Acceptance Criteria:**
- [ ] `AES.ecbEncrypt/ecbDecrypt(key:block:)` for 16-byte blocks, with AES-128 and AES-256 keys
- [ ] `AESCBCStream` keeps CBC chaining state across `update` calls (one CCCryptor, `kCCOptionECBMode` off, no padding)
- [ ] `AES.ctr(key:iv:data:)` handles AES-256 keys and any data length
- [ ] `Hash.sha1/sha256/sha512`, `HMAC.sha1(key:data:)`, `PBKDF2.sha512(password:salt:iterations:keyLength:)`, `SecureRandom.bytes(_:)`
- [ ] CBC streaming test: encrypting 48 bytes in one call equals encrypting 3×16 in three calls
- [ ] PBKDF2 matches the RFC 6070-style known vector `PBKDF2-HMAC-SHA512("password","salt",1,64)` = `867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce`

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/CryptoPrimitivesTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import Screener

final class CryptoPrimitivesTests: XCTestCase {
    let key = Data(hex: "000102030405060708090a0b0c0d0e0f")
    let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")

    func testCBCStreamChainsAcrossCalls() throws {
        let pt = Data((0..<48).map { UInt8($0) })
        let one = try AESCBCStream(key: key, iv: iv, operation: .encrypt)
        let whole = try one.update(pt)
        let three = try AESCBCStream(key: key, iv: iv, operation: .encrypt)
        let parts = try three.update(pt[0..<16]) + three.update(pt[16..<32]) + three.update(pt[32..<48])
        XCTAssertEqual(whole, parts)
        let dec = try AESCBCStream(key: key, iv: iv, operation: .decrypt)
        XCTAssertEqual(try dec.update(whole), pt)
    }
    func testECBRoundTrip() throws {
        let block = Data(repeating: 0xab, count: 16)
        XCTAssertEqual(try AES.ecbDecrypt(key: key, block: AES.ecbEncrypt(key: key, block: block)), block)
    }
    func testFIPS197AES128Vector() throws {
        XCTAssertEqual(try AES.ecbEncrypt(key: key, block: Data(hex: "00112233445566778899aabbccddeeff")).hex,
                       "69c4e0d86a7b0430d8cdb78070b4c55a")
    }
    func testPBKDF2SHA512() throws {
        let dk = try PBKDF2.sha512(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 1, keyLength: 64)
        XCTAssertEqual(dk.hex, "867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce")
    }
    func testCTRIsInvolution() throws {
        let k = Data(repeating: 7, count: 32)
        let d = Data((0..<37).map { UInt8($0) })
        XCTAssertEqual(try AES.ctr(key: k, iv: iv, data: AES.ctr(key: k, iv: iv, data: d)), d)
    }
}
```

- [ ] **Step 2:** Run it and expect a compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation
import CommonCrypto
import CryptoKit
import Security

enum CryptoError: Error { case status(Int32), badLength }

enum AES {
    static func ecbEncrypt(key: Data, block: Data) throws -> Data { try ecb(kCCEncrypt, key, block) }
    static func ecbDecrypt(key: Data, block: Data) throws -> Data { try ecb(kCCDecrypt, key, block) }

    private static func ecb(_ op: Int, _ key: Data, _ input: Data) throws -> Data {
        guard input.count % 16 == 0 else { throw CryptoError.badLength }
        var out = Data(count: input.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, i.baseAddress, input.count,
                            o.baseAddress, input.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }

    /// AES-CTR with a full 16-byte big-endian counter block (RFC 3711 style).
    static func ctr(key: Data, iv: Data, data: Data) throws -> Data {
        var ref: CCCryptorRef?
        var status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count,
                                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
        } }
        guard status == kCCSuccess, let ref else { throw CryptoError.status(status) }
        defer { CCCryptorRelease(ref) }
        var out = Data(count: data.count)
        var moved = 0
        status = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { i in
            CCCryptorUpdate(ref, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
        } }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }
}

/// One persistent AES-128-CBC context: chaining state carries across update() calls.
final class AESCBCStream: @unchecked Sendable {
    enum Operation { case encrypt, decrypt }
    private let ref: CCCryptorRef

    init(key: Data, iv: Data, operation: Operation) throws {
        var r: CCCryptorRef?
        let op = operation == .encrypt ? kCCEncrypt : kCCDecrypt
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreate(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), 0 /* CBC, no padding */,
                            k.baseAddress, key.count, v.baseAddress, &r)
        } }
        guard status == kCCSuccess, let r else { throw CryptoError.status(status) }
        ref = r
    }
    deinit { CCCryptorRelease(ref) }

    func update(_ input: Data) throws -> Data {
        guard input.count % 16 == 0 else { throw CryptoError.badLength }
        var out = Data(count: input.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in input.withUnsafeBytes { i in
            CCCryptorUpdate(ref, i.baseAddress, input.count, o.baseAddress, input.count, &moved)
        } }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }
}

enum Hash {
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    static func sha512(_ d: Data) -> Data { Data(SHA512.hash(data: d)) }
}

enum HMAC1 {
    static func sha1(key: Data, data: Data) -> Data {
        Data(CryptoKit.HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

enum PBKDF2 {
    static func sha512(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        var out = Data(count: keyLength)
        let status = out.withUnsafeMutableBytes { o in salt.withUnsafeBytes { s in password.withUnsafeBytes { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                 s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations),
                                 o.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
        } } }
        guard status == kCCSuccess else { throw CryptoError.status(status) }
        return out
    }
}

enum SecureRandom {
    static func bytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }
}
```

(`HMAC1` avoids clashing with CryptoKit's `HMAC`.) If `iterations` from the server exceeds `UInt32.max`, `PBKDF2.sha512` must throw rather than truncate. Add that guard.

- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add CommonCrypto/CryptoKit primitives"`

---

### Task 4: SRP-6a client (Apple profile)

**Goal:** Compute `A`, `M1`, `K`, the expected `M2` and the initial wrap key for Apple's SRP (RFC 5054 4096-bit group, g=5, SHA-512, PBKDF2-SHA512 password pre-hash, empty identity), matching the reference.

**Files:**
- Create: `Screener/Protocol/SRP.swift`
- Test: `ScreenerTests/SRPTests.swift`

**Acceptance Criteria:**
- [ ] With fixture `a`, `salt`, `iterations`, `password` and `B`, the client produces fixture `x`, `A`, `u`, `S`, `K`, `M1`, `M2`, `wrap_key` byte-for-byte
- [ ] `verifyServerProof` returns false for a corrupted `M2`
- [ ] Throws `SRPError.invalidServerValue` when `B mod N == 0`

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/SRPTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1: Failing test**

```swift
import XCTest
import BigInt
@testable import Screener

final class SRPTests: XCTestCase {
    func testMatchesReference() throws {
        let f = try Fixture.load("srp")
        func h(_ k: String) -> Data { Data(hex: f[k] as! String) }
        let client = try SRPClient(password: f["password"] as! String, salt: h("salt"),
                                   iterations: UInt64(f["iterations"] as! Int), privateA: h("a"))
        XCTAssertEqual(client.publicA.hex, h("A").hex)
        let proof = try client.respond(to: h("B"))
        XCTAssertEqual(proof.M1.hex, h("M1").hex)
        XCTAssertEqual(proof.K.hex, h("K").hex)
        XCTAssertEqual(proof.wrapKey.hex, h("wrap_key").hex)
        XCTAssertTrue(proof.verifyServerProof(h("M2")))
        var bad = h("M2"); bad[0] ^= 1
        XCTAssertFalse(proof.verifyServerProof(bad))
    }
    func testRejectsZeroB() throws {
        let c = try SRPClient(password: "p", salt: Data(count: 32), iterations: 1, privateA: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try c.respond(to: SRPGroup.N.serialize()))
    }
}
```

- [ ] **Step 2:** Run it and expect a compile failure.

- [ ] **Step 3: Implement.** Use the RFC §4.2.4.6 formulas. Pad to 512 bytes (`PAD`). `H` = SHA-512. Cross-check each formula against `auth._derive_x` / `auth._solve_srp` (in particular, check whether the reference pads `A`/`B` inside `M1`; the fixture is authoritative).

```swift
import Foundation
import BigInt

enum SRPError: Error { case invalidServerValue }

enum SRPGroup {
    /// RFC 5054 Appendix A, 4096-bit group.
    static let N = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F" +
        "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510" +
        "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7" +
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C" +
        "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7" +
        "88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6" +
        "287C59474E6BC05D99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9" +
        "93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF", radix: 16)!
    static let g = BigUInt(5)
    static let length = 512
}

extension BigUInt {
    func padded(to n: Int) -> Data {
        let raw = serialize()
        return raw.count >= n ? raw : Data(count: n - raw.count) + raw
    }
}

struct SRPProof {
    let M1: Data
    let K: Data
    let expectedM2: Data
    /// RFC §4.2.4.8: initial record-layer wrap key = SHA-256(K)[0:16].
    var wrapKey: Data { Hash.sha256(K).prefix(16) }
    func verifyServerProof(_ m2: Data) -> Bool { m2 == expectedM2 }
}

struct SRPClient {
    let publicA: Data
    private let a: BigUInt
    private let x: BigUInt
    private let salt: Data

    init(password: String, salt: Data, iterations: UInt64, privateA: Data = SecureRandom.bytes(32)) throws {
        self.salt = salt
        let pPrime = try PBKDF2.sha512(password: Data(password.utf8), salt: salt,
                                       iterations: Int(iterations), keyLength: 128)
        let inner = Hash.sha512(Data(":".utf8) + pPrime)           // H(I ":" P') with I = ""
        x = BigUInt(Hash.sha512(salt + inner))
        a = BigUInt(privateA)
        publicA = SRPGroup.g.power(a, modulus: SRPGroup.N).padded(to: SRPGroup.length)
    }

    func respond(to serverB: Data) throws -> SRPProof {
        let N = SRPGroup.N, L = SRPGroup.length
        let B = BigUInt(serverB)
        guard B % N != 0 else { throw SRPError.invalidServerValue }
        let k = BigUInt(Hash.sha512(N.padded(to: L) + SRPGroup.g.padded(to: L)))
        let u = BigUInt(Hash.sha512(publicA + B.padded(to: L)))
        guard u != 0 else { throw SRPError.invalidServerValue }
        let gx = SRPGroup.g.power(x, modulus: N)
        let kgx = (k * gx) % N
        let base = (B + N - kgx) % N
        let S = base.power(a + u * x, modulus: N)
        let K = Hash.sha512(S.padded(to: L))
        let hN = Hash.sha512(N.serialize()), hg = Hash.sha512(SRPGroup.g.serialize())
        let hNxg = Data(zip(hN, hg).map { $0 ^ $1 })
        let hI = Hash.sha512(Data())
        let M1 = Hash.sha512(hNxg + hI + salt + publicA + B.padded(to: L) + K)
        let M2 = Hash.sha512(publicA + M1 + K)
        return SRPProof(M1: M1, K: K, expectedM2: M2)
    }
}
```

If the fixture disagrees on any intermediate value, the reference is right. Adjust padding or hash inputs to match `_solve_srp` exactly and note the deviation from RFC §4.2.4.6 in a code comment.

- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add Apple-profile SRP-6a client"`

---

### Task 5: Record layer (enc1103)

**Goal:** The AES-128-CBC + SHA-1 control-channel record layer, including rekey unwrap, the persistent per-direction CBC state, sequence counters, the reference's decrypt counter-tolerance window, and multi-record reassembly helpers.

**Files:**
- Create: `Screener/Protocol/RecordLayer.swift`
- Test: `ScreenerTests/RecordLayerTests.swift`

**Acceptance Criteria:**
- [ ] `RecordLayer(rekeyBody:wrapKey:)` unwraps fixture `key_blob_36` to fixture `cbc_key`
- [ ] `seal` reproduces fixture `client_records[i].wire` for i = 0, 1, 2 in order (zero filler, matching the reference)
- [ ] A second `RecordLayer` with the same inputs `open`s those wire records back to the bodies
- [ ] A flipped ciphertext byte makes `open` throw `RecordLayerError.integrity`, and that record's CBC state is still consumed
- [ ] `FrameSplitter` returns complete `u16 len || ciphertext` frames from arbitrary chunking and throws on `len == 0` or `len % 16 != 0`

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/RecordLayerTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import Screener

final class RecordLayerTests: XCTestCase {
    func testMatchesReference() throws {
        let f = try Fixture.load("record_layer")
        let blob = Data(hex: f["key_blob_36"] as! String), wrap = Data(hex: f["ecb_key"] as! String)
        let records = f["client_records"] as! [[String: String]]
        let tx = try RecordLayer(rekeyBody: blob, wrapKey: wrap)
        XCTAssertEqual(tx.contentKey.hex, f["cbc_key"] as! String)
        let rx = try RecordLayer(rekeyBody: blob, wrapKey: wrap)
        for r in records {
            let wire = try tx.seal(Data(hex: r["plaintext"]!))
            XCTAssertEqual(wire.hex, r["wire"]!)
            XCTAssertEqual(try rx.open(ciphertext: wire.dropFirst(2)).hex, r["plaintext"]!, "sender CBC == receiver CBC")
        }
    }
    func testIntegrityFailure() throws {
        let tx = try RecordLayer(rekeyBody: Data(count: 36), wrapKey: Data(count: 16))
        let rx = try RecordLayer(rekeyBody: Data(count: 36), wrapKey: Data(count: 16))
        var wire = try tx.seal(Data([0x03, 0x00]))
        wire[5] ^= 0xff
        XCTAssertThrowsError(try rx.open(ciphertext: wire.dropFirst(2)))
    }
    func testFrameSplitter() throws {
        var s = FrameSplitter()
        let frame = Data([0x00, 0x20]) + Data(count: 32)
        XCTAssertEqual(try s.push(frame.prefix(10)).count, 0)
        XCTAssertEqual(try s.push(frame.dropFirst(10) + frame).count, 2)
        XCTAssertThrowsError(try s.push(Data([0x00, 0x11])))
    }
}
```

- [ ] **Step 2:** Run it and expect a compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum RecordLayerError: Error { case badRekey, integrity, badFrame }

/// RFC §6: AES-128-CBC records with plain SHA-1(u32_be(seq) || plaintext) trailer.
/// Ported from iShareScreen proxy/protocol/enc1103.py (AGPL-3.0)
final class RecordLayer: @unchecked Sendable {
    let contentKey: Data
    private let enc: AESCBCStream
    private let dec: AESCBCStream
    private var sendSeq: UInt32 = 0
    private var recvSeq: UInt32 = 0
    private let lock = NSLock()
    private static let macLen = 20
    private static let decryptWindow: UInt32 = 6   // matches reference _DECRYPT_COUNTER_WINDOW

    init(rekeyBody: Data, wrapKey: Data) throws {
        guard rekeyBody.count == 36, wrapKey.count == 16 else { throw RecordLayerError.badRekey }
        let b = Data(rekeyBody)
        contentKey = try AES.ecbDecrypt(key: wrapKey, block: b.subdata(in: 4..<20))
        let iv = try AES.ecbDecrypt(key: wrapKey, block: b.subdata(in: 20..<36))
        enc = try AESCBCStream(key: contentKey, iv: iv, operation: .encrypt)
        dec = try AESCBCStream(key: contentKey, iv: iv, operation: .decrypt)
    }

    /// Returns the full wire form `u16 len || ciphertext`. Callers must write the
    /// returned bytes before sealing the next record (wire order == seq order).
    func seal(_ body: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var w = ByteWriter(capacity: body.count + 40)
        w.u16(UInt16(body.count)); w.bytes(body)
        let pad = (16 - (2 + body.count + Self.macLen) % 16) % 16
        w.zeros(pad)
        var seqW = ByteWriter(); seqW.u32(sendSeq)
        let mac = Hash.sha1(seqW.data + w.data)
        let ct = try enc.update(w.data + mac)
        sendSeq &+= 1
        var out = ByteWriter(capacity: ct.count + 2); out.u16(UInt16(ct.count)); out.bytes(ct)
        return out.data
    }

    /// Decrypts one record's ciphertext (without the u16 length prefix); returns its body.
    func open(ciphertext: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let pt = try dec.update(Data(ciphertext))       // always advance CBC state
        let start = recvSeq
        recvSeq &+= 1
        guard pt.count > Self.macLen + 2 else { throw RecordLayerError.badFrame }
        let head = pt.prefix(pt.count - Self.macLen), mac = pt.suffix(Self.macLen)
        let lo = start == 0 ? 0 : start - 1
        for c in lo..<(start + Self.decryptWindow) {
            var s = ByteWriter(); s.u32(c)
            if Hash.sha1(s.data + head) == mac {
                recvSeq = c &+ 1
                var r = ByteReader(head)
                let len = Int(try r.u16())
                return try r.bytes(len)
            }
        }
        throw RecordLayerError.integrity
    }
}

/// Splits a TCP byte stream into record ciphertexts.
struct FrameSplitter {
    private var buffer = Data()
    mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        while buffer.count >= 2 {
            let len = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
            guard len > 0, len % 16 == 0 else { throw RecordLayerError.badFrame }
            guard buffer.count >= 2 + len else { break }
            out.append(buffer.subdata(in: buffer.startIndex + 2 ..< buffer.startIndex + 2 + len))
            buffer.removeFirst(2 + len)
        }
        return out
    }
}
```

Note: the reference returns `None` on a MAC miss without closing. RFC §12 says MUST close. Follow the RFC: `ControlSession` (Task 10) closes on `.integrity`. The counter window only exists to resync legitimate gaps.

- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add enc1103 record layer"`

---

### Task 6: ByteStream transport

**Goal:** An async byte-stream abstraction with an `NWConnection` TCP implementation and an in-memory pipe for testing protocol flows without a network.

**Files:**
- Create: `Screener/Transport/ByteStream.swift`
- Test: `ScreenerTests/ByteStreamTests.swift`

**Acceptance Criteria:**
- [ ] `protocol ByteStream: Sendable { func read(exactly: Int) async throws -> Data; func readSome() async throws -> Data; func write(_: Data) async throws; func close() }`
- [ ] `TCPByteStream.connect(host:port:timeout:)` uses `NWConnection` (`.tcp`, `noDelay = true`) and throws `TransportError.timeout` after the timeout
- [ ] `MemoryPipe.pair()` returns two connected ends; `read(exactly:)` assembles across partial writes; `close()` makes pending reads throw `TransportError.closed`

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/ByteStreamTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import Screener

final class ByteStreamTests: XCTestCase {
    func testPipeExactReadAcrossWrites() async throws {
        let (a, b) = MemoryPipe.pair()
        Task { try await a.write(Data([1, 2])); try await a.write(Data([3, 4, 5])) }
        let got = try await b.read(exactly: 4)
        XCTAssertEqual(got, Data([1, 2, 3, 4]))
        XCTAssertEqual(try await b.read(exactly: 1), Data([5]))
    }
    func testPipeCloseFailsReads() async throws {
        let (a, b) = MemoryPipe.pair()
        Task { try await Task.sleep(for: .milliseconds(20)); a.close() }
        do { _ = try await b.read(exactly: 1); XCTFail("expected closed") }
        catch TransportError.closed {}
    }
    func testTCPTimeout() async {
        do { _ = try await TCPByteStream.connect(host: "10.255.255.1", port: 5900, timeout: .milliseconds(300)); XCTFail() }
        catch TransportError.timeout {} catch { XCTFail("\(error)") }
    }
}
```

- [ ] **Step 2:** Run it and expect a compile failure.

- [ ] **Step 3: Implement.** `MemoryPipe`: each end is an actor holding an inbound `Data` buffer plus a list of waiting continuations; `write` appends to the peer's buffer and resumes waiters. `TCPByteStream`: a `final class` wrapping `NWConnection` on a private serial queue. `connect` awaits `.ready` via `stateUpdateHandler` using a `CheckedContinuation` guarded so it resumes once, and races it against `Task.sleep(timeout)`. `read(exactly:)` loops `connection.receive(minimumIncompleteLength: 1, maximumLength: n - have)` until it has `n` bytes. A receive with `isComplete && data == nil` throws `.closed`. Errors are `enum TransportError: Error { case timeout, closed, failed(String) }`.

- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add ByteStream with TCP and in-memory implementations"`

---

### Task 7: Authentication (RSA1 + SRP, non-SRP fallback)

**Goal:** Run security type 33 end-to-end over a `ByteStream` and return the 16-byte wrap key, with non-SRP fallback, porting `auth.py`.

**Files:**
- Create: `Screener/Protocol/Auth.swift`
- Test: `ScreenerTests/AuthTests.swift`

**Acceptance Criteria:**
- [ ] `Authenticator.run(stream:username:password:) async throws -> AuthResult` where `AuthResult { wrapKey: Data; method: .srp | .nonSRP }`
- [ ] Ports `_rsa1_init`, `_send_srp_modulus`, `_read_srp_challenge`, `_parse_apple_srp_challenge`, `_solve_srp` (via Task 4's `SRPClient`), `_send_srp_proof`, `_read_srp_result`, `do_nonsrp_auth`, `_pack_ard_credential`
- [ ] RSA encryption uses `SecKeyCreateEncryptedData(.rsaEncryptionPKCS1)` on a key from `SecKeyCreateWithData` (DER SubjectPublicKeyInfo → strip the SPKI header to PKCS#1 if `SecKeyCreateWithData` rejects SPKI)
- [ ] Parsing fixture `challenge_wire` yields fixture N/g/salt/B/iterations/options
- [ ] Packet-2 header bytes follow RFC §4.2.4.5 (`total_len`, `0100`, `RSA1`, `0002`, `inner_len+4`, `0000`, `inner_len`)
- [ ] A scripted fake server on `MemoryPipe` gets SRP through to `SecurityResult = 0` and returns the fixture `wrap_key`. The fake server replays fixture values and does not check the RSA ciphertext.
- [ ] A non-zero SecurityResult throws `AuthError.rejected(reason:)`, carrying the server's reason string if one follows
- [ ] SRP failure falls back to non-SRP exactly when the reference does (read `do_srp_auth`'s callers in `negotiation._phase_auth`)

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/AuthTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1:** Write `AuthTests` with three tests: `testParseChallenge` (fixture `challenge_wire` → fields), `testPacket2Header` (build packet-2 from fixture A/M1/options and a fixed client_random, then assert the first 18 bytes per the RFC layout), and `testSRPHappyPathAgainstFakeServer`. The fake server is a `Task` on the far end of `MemoryPipe`. It reads the auth-type-0 key request and replies with a DER public key from a 2048-bit RSA key generated in the test via `SecKeyCreateRandomKey`. Then it reads packet-1, sends `challenge_wire`, reads packet-2, sends a final proof containing fixture `M2`, and sends `00000000`.
- [ ] **Step 2:** Run them and expect a compile failure.
- [ ] **Step 3:** Implement `Auth.swift` by porting the listed functions (Porting convention). Use the RFC §2.5 grammar atoms as `ByteReader` extensions: `readM()` (u16-length bytes), `readO()` (u8-length bytes), `readS()` (u16-length UTF-8), `readQ()` (u64). Matching `ByteWriter` extensions go in the same file. Log each phase with `Log.auth.info` (never log the password or keys).
- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add RSA1/SRP and non-SRP authentication"`

---

### Task 8: Control-channel messages

**Goal:** Builders for all client→server messages and parsers for all server→client messages and framebuffer-update rectangles used in v1, matching reference bytes.

**Files:**
- Create: `Screener/Protocol/Messages.swift`, `Screener/Protocol/ServerMessages.swift`
- Test: `ScreenerTests/MessagesTests.swift`, `ScreenerTests/ServerMessagesTests.swift`

**Acceptance Criteria:**
- [ ] Builders (`enum ClientMessage` static funcs returning `Data`) match fixture `messages.json` byte-for-byte: `setEncodings`, `setEncryption(command:)`, `keyEvent`, `pointerEvent`, `viewerInfo`, `setDisplayConfiguration(logical:backing:refreshHz:)` (static form as in `rfb.build_virtual_display`), `framebufferUpdateRequest(incremental:x:y:w:h:)`, `autoFramebufferUpdate(w:h:)`, `encryptedPointerEvent` (port `input._build_msg10_pointer`, needs the ECB key), `scaleFactor(_:)`, `setDisplay(combineAll:)`, `clientCutText`, `clipboardFetch`, `autoPasteboard(selector:)`
- [ ] `SetEncodings` HP list = reference `HP_ENCODINGS_FULL` (read from `rfb.py`)
- [ ] `ServerMessageParser` takes decrypted record bodies (concatenated across records per RFC §6.4.6) and emits `enum ServerEvent`: `.rekey(Data)`, `.displayLayout(DisplayLayout)`, `.cursorStore(id:hotspot:size:bgra:alpha:)`, `.cursorSelect(id:)`, `.keyboardSource(String, secureInput: Bool)`, `.deviceInfo(model: String)`, `.vendorKeysyms`, `.mediaStreamAnswer(Data)`, `.miscStatus(cmd: UInt16)`, `.clipboard(header:payloadChunk:)`, `.bell`, `.zlibRect(x:y:w:h:payload:)`, `.unknown(type:)`
- [ ] Parser handles a framebuffer-update rectangle whose payload is split across two `feed` calls (stateful, buffer-driven)
- [ ] `0x451` fixture parses to scaled 1920×1080 and backing 3840×2160 (matching `rfb.parse_apple_display_layout`)
- [ ] An unknown message or encoding produces `.unknown` and does not throw (RFC §12)

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/MessagesTests -only-testing:ScreenerTests/ServerMessagesTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1:** Write `MessagesTests` with one assertion per fixture key in `messages.json` (`XCTAssertEqual(ClientMessage.x(...).hex, f["x"])`, using the same args the fixture script used). Write `ServerMessagesTests` covering: the 0x451 fixture; a synthetic `0x455` (`001f 0001 00000000 0017` + `"com.apple.keylayout.ABC"`, from RFC §8.6); a `0x453` 22-byte vector (RFC §8.5); a `0x14` cmd=2; a split rectangle; and an unknown encoding `0x7777` followed by a valid `0x455`. That last case means an unknown encoding without a length prefix can't be skipped. Document how the reference handles it in `session.py`'s TCP rx loop and mirror that behaviour, e.g. by treating it as `.unknown` and discarding the rest of that record body.
- [ ] **Step 2:** Run them and expect a compile failure.
- [ ] **Step 3:** Implement by porting `rfb.py` builders, `negotiation.build_fbu_request` / `build_auto_framebuffer_update`, `apple._build_apple_viewer_command_mask`, `input._build_msg10_pointer`, and the server-message dispatch in `session.py`/`burst.py`. For framing details use RFC §8. Cursor STORE payloads are zlib: decompress with `Compression`'s `COMPRESSION_ZLIB` after stripping the 2-byte zlib header, or use `NSData.decompressed(using: .zlib)` on raw deflate. Write a `Zlib.inflate(_:)` helper in `ServerMessages.swift` that handles the `Z_SYNC_FLUSH` framing, and test it with a reference-compressed blob from `clipboard.json`.
- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add control-channel message builders and parsers"`

---

### Task 9: Media offer + MediaStreamOptions (0x1c)

**Goal:** Build the AVCMediaStreamNegotiator audio/video offer blobs and the `0x1c` offer message, and parse the server's `0x1c` answer (canvas size, SSRCs), byte-identical to the reference.

**Files:**
- Create: `Screener/Protocol/MediaOffer.swift`
- Test: `ScreenerTests/MediaOfferTests.swift`

**Acceptance Criteria:**
- [ ] `MediaOffer.create(sessionID:timestamp:callID:audioEnabled:)` → `(audio: Data, video: Data)` equals fixture `audio_offer`/`video_offer` given the fixture's fixed dynamic values (port `create_offers`, `_build_mediablob`, `_build_remote_endpoint_info`, `_build_audio_f9_entry`, protobuf helpers, plist + zlib framing). HEVC only, with `tilesPerFrame = 4`.
- [ ] `MediaStreamOptions.build(keys:offers:uuid:flags:)` equals fixture `msg_1c` (port `negotiation.build_0x1c`; flags are little-endian at +0x06 per RFC §10.3)
- [ ] `MediaStreamOptions.parseAnswer(_:)` → `(canvasWidth, canvasHeight, tiles)` matches `extract_canvas_dims` on the fixture answer
- [ ] `NegotiationKeys.random()` produces 6 × 46-byte blobs from `SecureRandom`

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/MediaOfferTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1:** Write tests comparing against `media_offer.json`.
- [ ] **Step 2:** Run them and expect a compile failure.
- [ ] **Step 3:** Port the listed functions. Use `PropertyListSerialization` with binary format for plists. The reference uses `plistlib` and the fixture is authoritative; if Foundation's binary plist ordering differs, emit the plist with a small hand-written binary-plist writer that matches the reference byte order. Use `ByteWriter` for the protobuf varints.
- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add media offer and 0x1c MediaStreamOptions"`

---

### Task 10: ControlSession + debug connect (Milestones 1–2)

**Goal:** An actor that runs the whole TCP lifecycle (handshake → auth → init → prelude → rekey → encrypted preface → media offer/answer → steady-state receive loop) and exposes an `AsyncStream<ServerEvent>`. A temporary debug connect form proves milestones 1 and 2 on the iPad against this Mac.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Protocol/RFBHandshake.swift`, `Screener/Protocol/ControlSession.swift`
- Create: `Screener/UI/ConnectSheet.swift` (minimal: host, port, username, password, Connect; reused by Task 18)
- Modify: `Screener/UI/HostListView.swift` (toolbar "+" button presents `ConnectSheet`)
- Test: `ScreenerTests/RFBHandshakeTests.swift`

**Acceptance Criteria:**
- [ ] `RFBHandshake` handles: version `RFB 003.889` both ways; the security-type list (prefer 33, throw `.unsupported` if absent, throw on count 0); ClientInit `0xC1`; and ServerInit parse (width, height, name). Unit-tested over `MemoryPipe` with the RFC §4.1.3 bytes `04 1e 21 24 23`.
- [ ] Session-select prompt detection (port `_peek_ss_prompt`/`_read_ss_prompt`): if the server sends a session-select prompt, throw `ControlSessionError.sessionSelectUnsupported` with a user-readable message ("Another user is logged in on this Mac…"). v1 does not implement cmd 0/2.
- [ ] Prelude order per RFC §9.1 (ViewerInfo → SetEncryption(1) → SetMode(1) → SetEncryption(2)), handling a rekey that arrives before SetEncryption(2) (RFC §3.3)
- [ ] After the rekey, all traffic goes through `RecordLayer`. The encrypted preface is `0x1d` then `0x02`, then `0x03` non-incremental + `0x09`. Then the `0x1c` offer, built from Task 9 with `iPad nativeBounds` as the backing size and `bounds` as logical.
- [ ] `ControlSession.send(_ body: Data) async throws` serialises seal+write (an actor guarantees wire order)
- [ ] Re-arms `0x09` + non-incremental `0x03` on every `.displayLayout` (RFC §8.11)
- [ ] Each handshake step times out after 10 s with `ControlSessionError.timeout(step:)`
- [ ] Logs `M1 auth ok` after SecurityResult 0, `M2 record layer active` after the first successful `open`, and `M2 media answer canvas=WxH` on the `0x1c` answer
- [ ] **On device:** connecting from the iPad to this Mac's LAN IP logs all three lines. Evidence: `Tools/fetch-ipad-log.sh | grep -E "M1|M2"` output captured in the task close.

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/RFBHandshakeTests` → `** TEST SUCCEEDED **`; then `Tools/run-on-ipad.sh`, the user enters credentials and taps Connect, then `Tools/fetch-ipad-log.sh | grep -E "M1 auth ok|M2 record layer active|M2 media answer"` prints 3 lines

**Steps:**

- [ ] **Step 1:** Write `RFBHandshakeTests` (happy path, count-0 failure list, type-33-absent).
- [ ] **Step 2:** Run them and expect a compile failure.
- [ ] **Step 3:** Implement `RFBHandshake.swift` and `ControlSession.swift` by porting `negotiation.connect_and_negotiate` and its `_phase_*` helpers, `_read_until_enc1103`, `_read_video_answer`, and the TCP receive dispatch from `session.py` (`_negotiate_and_burst` and the rx loop). Drop the reference's reconnect/warm-up hacks (`warmup_tcp`, `_handshake_with_reconnect`) unless the live test in Step 5 shows they're needed. If it does, port `warmup_tcp` and record why in a comment.

```swift
actor ControlSession {
    struct Config: Sendable { var host: String; var port: UInt16 = 5900; var username: String; var password: String
                              var logicalSize: CGSize; var backingSize: CGSize }
    struct MediaParams: Sendable { let keys: NegotiationKeys; let canvas: (width: Int, height: Int); let tiles: Int }
    nonisolated let events: AsyncStream<ServerEvent>
    func start() async throws -> MediaParams   // runs through the 0x1c answer, then spawns the rx loop
    func send(_ body: Data) async throws
    func close()
}
```

- [ ] **Step 4:** Run the unit tests and expect them to pass.
- [ ] **Step 5: Live check.** Get this Mac's LAN IP (`ipconfig getifaddr en0`). Make sure Screen Sharing is enabled (System Settings → General → Sharing) and High Performance is allowed. Run `Tools/run-on-ipad.sh`. Ask the user to tap "+", enter the IP and their macOS username/password, and tap Connect. Then run `Tools/fetch-ipad-log.sh`. If it fails, compare against the reference: `cd Reference/iShareScreen && uv run --python 3.12 iss --help` and run it against `127.0.0.1` with `--log-level debug`, then diff the phase-by-phase logs.
- [ ] **Step 6:** `git commit -m "feat: add ControlSession through media negotiation (M1-M2)"`

---

### Task 11: SRTP / SRTCP

**Goal:** RFC 3711 AES-256-CM + HMAC-SHA1-80 decrypt with per-SSRC ROC tracking, plus encryptors for keepalive and RTCP, matching `srtp.py`.

**Files:**
- Create: `Screener/Transport/SRTP.swift`
- Test: `ScreenerTests/SRTPTests.swift`

**Acceptance Criteria:**
- [ ] KDF output equals fixture `cipher_key`, `auth_key` and `salt`
- [ ] `SRTPDecryptor(blob:).decrypt(packet)` returns `(header, payload)` equal to the fixture plaintext for all 3 fixture packets, including the seq 65535 → 0 rollover (ROC 0 → 1)
- [ ] A tampered tag returns `nil` and does not change ROC state
- [ ] `SRTPEncryptor` and `SRTCPEncryptor` outputs equal the fixture bytes
- [ ] `SRTCPDecryptor.unprotect` round-trips the fixture SRTCP packet

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/SRTPTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1:** Write tests against `srtp.json`.
- [ ] **Step 2:** Run them and expect a compile failure.
- [ ] **Step 3:** Port `srtp.py`. The KDF and IV construction:

```swift
/// RFC 3711 §4.3.1 key derivation (AES-CM, label XORed into byte 7 of the 14-byte salt).
static func kdf(masterKey: Data, masterSalt: Data, label: UInt8, length: Int) throws -> Data {
    var x = [UInt8](masterSalt)
    x[7] ^= label
    let iv = Data(x) + Data([0, 0])
    return try AES.ctr(key: masterKey, iv: iv, data: Data(count: length))
}

/// Per-packet IV = (salt << 16) XOR (SSRC << 64) XOR (index << 16), index = ROC << 16 | seq.
static func packetIV(salt: Data, ssrc: UInt32, roc: UInt32, seq: UInt16) -> Data {
    var iv = [UInt8](salt) + [0, 0]                 // salt << 16 → bytes 0..13
    let s = withUnsafeBytes(of: ssrc.bigEndian, Array.init)
    for i in 0..<4 { iv[4 + i] ^= s[i] }            // SSRC << 64 → bytes 4..7
    let index = (UInt64(roc) << 16) | UInt64(seq)
    let ib = withUnsafeBytes(of: (index << 16).bigEndian, Array.init)
    for i in 0..<8 { iv[8 + i] ^= ib[i] }           // index << 16 → bytes 8..15
    return Data(iv)
}
```

Port the ROC guessing (`decrypt`'s candidate list), `_update_state`, the RTP header length calculation (CSRC count + extension), `SRTPEncryptor.encrypt`, and `SRTCPDecryptor`/`SRTCPEncryptor`. Use `HMAC1.sha1` truncated to 10 bytes, and compare tags in constant time.

- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add SRTP/SRTCP"`

---

### Task 12: UDP media transport + RTCP (Milestone 3)

**Goal:** Open the UDP flows (video at P+1, audio at P), decrypt SRTP, emit RTCP feedback and keepalives, and deliver `(ssrc, rtpHeader, payload)` packets to consumers. Verified live by packet counts.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Transport/RTCP.swift`, `Screener/Transport/MediaTransport.swift`
- Create: `Screener/Session/SessionCoordinator.swift` (owns ControlSession + MediaTransport; later tasks extend it)
- Modify: `Screener/UI/ConnectSheet.swift` (Connect now drives `SessionCoordinator`)
- Test: `ScreenerTests/RTCPTests.swift`

**Acceptance Criteria:**
- [ ] RTCP builders match `rtcp.json` (`firLegacy`, `fir`, `pli`, `nack`, `receiverReport`, `appLTR`)
- [ ] `MediaTransport` opens `NWConnection(host, port: P+1, using: .udp)` for video and `P` for audio. It uses the `key2` blobs for receive decryption and `key1` for send (RFC §10.3). It distinguishes RTCP (PT 200–207 in the 2nd byte & 0x7f range 72–79) from RTP and routes RTCP to `SRTCPDecryptor`.
- [ ] It sends the keepalive the reference sends (port the keepalive logic from `session.py`: search for `SRTPEncryptor` usage) and periodic RRs, using the reference cadence
- [ ] `requestKeyframe(ssrc:)` sends the same FIR variant the reference uses by default
- [ ] SSRC-group adoption: track the 4-consecutive-SSRC video group with the most packets (port `get_primary_ssrc_group` / `forget_ssrcs_except` logic) and expose `activeVideoSSRCs: [UInt32]` sorted (tile order)
- [ ] Logs `M3 udp video pkts=N audio pkts=M ssrcs=[…]` every 2 s
- [ ] **On device:** after Connect, the log shows `M3` lines with video pkts > 100 and 4 SSRCs within 5 s. Evidence: `fetch-ipad-log.sh | grep M3 | tail -3`.

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/RTCPTests` → `** TEST SUCCEEDED **`; then live: `Tools/run-on-ipad.sh` → the user connects → `Tools/fetch-ipad-log.sh | grep "M3 udp" | tail -3` shows `pkts` > 100 and 4 SSRCs

**Steps:**

- [ ] **Step 1:** Write `RTCPTests` from `rtcp.json`. **Step 2:** Run them and expect a failure.
- [ ] **Step 3:** Port `rtcp.py`. Implement `MediaTransport` as an actor with `AsyncStream<MediaPacket>` outputs `video` and `audio`, where `struct MediaPacket: Sendable { ssrc: UInt32; seq: UInt16; timestamp: UInt32; marker: Bool; payloadType: UInt8; payload: Data; arrival: ContinuousClock.Instant }`. Receive with `connection.receiveMessage` in a loop. Port the UDP "hole-punch"/first-send behaviour the reference performs before the server starts sending (look for the initial sends to 5900/5901 in `session.py`'s `_connect_internal`).
- [ ] **Step 4:** Run the unit tests and expect them to pass. **Step 5:** Run the live check (keep it short: the user disconnects right after the 5 s window). **Step 6:** `git commit -m "feat: add UDP media transport with SRTP and RTCP (M3)"`

---

### Task 13: HEVC depacketizer + assembler

**Goal:** Turn decrypted video RTP packets into decodable HEVC access units in decoding order across the 4 tile SSRCs, with parameter-set caching and loss detection that triggers keyframe requests.

**Files:**
- Create: `Screener/Media/HEVCDepacketizer.swift`, `Screener/Media/HEVCAssembler.swift`
- Test: `ScreenerTests/HEVCDepacketizerTests.swift`, `ScreenerTests/HEVCAssemblerTests.swift`

**Acceptance Criteria:**
- [ ] `HEVCDepacketizer.nalUnits(from payload: Data) -> [(nal: Data, don: UInt16)]` handles single (DONL stripped), AP type 48 (one DONL, then `[u16 size][NAL]`, no DOND), and FU type 49 (DONL in every fragment, original header rebuilt on start). All `hevc_rtp.json` vectors pass.
- [ ] FU reassembly across packets; a missing middle fragment (seq gap) drops the NAL and reports loss
- [ ] `HEVCAssembler` keeps per-SSRC sequence tracking. It caches VPS/SPS/PPS (types 32/33/34). It emits `AccessUnit { nalUnits: [Data]; isIDR: Bool; tile: Int; rtpTimestamp: UInt32 }` in DON order across SSRCs, mirroring how the reference orders by DONL before feeding its single decoder (port the ordering/grouping from `session._queue_video_group_packet`, `_group_complete`, `_flush_group`, `_ordered_group_keys`). It emits `.needKeyframe(ssrc:)` on unrecoverable loss.
- [ ] After loss, inter frames are dropped until the next IDR (no garbage to the decoder)
- [ ] When the SSRC group changes (resize/restart), state resets and parameter sets are re-harvested

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/HEVCDepacketizerTests -only-testing:ScreenerTests/HEVCAssemblerTests` → `** TEST SUCCEEDED **`

**Steps:**

- [ ] **Step 1:** Write the depacketizer tests from `hevc_rtp.json`. Write assembler tests with synthetic packets: (a) in-order IDR (VPS/SPS/PPS + IDR FU) on SSRC base → one AU with `isIDR` and params cached; (b) 4 SSRCs interleaved with DONs 10–13 → AUs emitted in DON order; (c) a seq gap on a P-frame → `.needKeyframe` and no AU until the next IDR.
- [ ] **Step 2:** Run them and expect a failure.
- [ ] **Step 3:** Implement by porting from `session.py` (the group/flush functions above) and `media/hevc.py` (`feed_burst`, `feed_nalu`, `_is_decodable_nalu`), plus `hevc_rps.py` only if needed for recovery decisions. Keep these as plain structs with no concurrency; the coordinator drives them from one task.
- [ ] **Step 4:** Run the tests and expect them to pass. **Step 5:** `git commit -m "feat: add HEVC RTP depacketizer and assembler"`

---

### Task 14: Video decode + Metal rendering + SessionView (Milestone 4)

**Goal:** Decode the HEVC 4:4:4 stream with VideoToolbox, render it full-screen with Metal (tiles composited vertically, aspect-fit), and show it in a `SessionView` with a minimal toolbar.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Media/VideoDecoder.swift`, `Screener/Media/MetalRenderer.swift`, `Screener/Media/Shaders.metal`
- Create: `Screener/UI/SessionView.swift`
- Modify: `Screener/Session/SessionCoordinator.swift` (wire assembler → decoder → renderer; FIR on decoder error)
- Modify: `Screener/UI/ConnectSheet.swift` (on success, present `SessionView` full-screen)

**Acceptance Criteria:**
- [ ] `VideoDecoder` builds a `CMVideoFormatDescription` from VPS/SPS/PPS (`CMVideoFormatDescriptionCreateFromHEVCParameterSets`). It creates a `VTDecompressionSession` requesting `kCVPixelFormatType_444YpCbCr8BiPlanarFullRange` and IOSurface/Metal-compatible buffers. It decodes AVCC-framed (4-byte length) samples, and rebuilds the session and asks for a keyframe on `kVTVideoDecoderBadDataErr` or when the format changes.
- [ ] The decoder is fed every tile's AUs. Decoded output is stored per tile, and the renderer composites the 4 strips vertically in SSRC order (RFC §10.7). If VideoToolbox outputs the full picture rather than strips, render it directly; log which case occurs.
- [ ] `MetalRenderer` converts bi-planar 4:4:4 full-range YCbCr to RGB in a fragment shader (BT.709 matrix, unless the stream's color metadata says otherwise; log the metadata), via `CVMetalTextureCache`. It aspect-fits into the view and is driven by `MTKView` at the display's max refresh rate.
- [ ] `SessionView`: full-screen, hidden status bar, a toolbar with Disconnect, and a "Connecting…" overlay until the first frame
- [ ] Logs `M4 first frame WxH pixfmt=…` and per-2s `video fps=… decode_ms=…`
- [ ] **On device:** the user confirms the Mac desktop is visible and live (moving a window on the host via Screens or another device isn't possible while privacy is on, so confirm a clock/animation updates). Evidence: the user's confirmation plus a `grep M4` log line.

**Verify:** `xcodebuild build -project Screener.xcodeproj -scheme Screener $DEV -allowProvisioningUpdates | tail -1` → `** BUILD SUCCEEDED **`; live: `Tools/run-on-ipad.sh` → connect → `Tools/fetch-ipad-log.sh | grep -E "M4|video fps" | tail -3`, and the user confirms the image on the iPad

**Steps:**

- [ ] **Step 1:** Implement `VideoDecoder` by porting the VideoToolbox approach from `media/vtdecode.py` (the reference's macOS path calls VT via ctypes: copy its session attributes and format-description construction).
- [ ] **Step 2:** Implement `Shaders.metal` (fullscreen-triangle vertex shader; fragment samples the Y `r8Unorm` and CbCr `rg8Unorm` planes and applies the YCbCr→RGB matrix) and `MetalRenderer`.
- [ ] **Step 3:** Wire the coordinator: `for await pkt in transport.video` → assembler → decoder → renderer, and `.needKeyframe` → `transport.requestKeyframe`.
- [ ] **Step 4:** Build for the device, run the live check, and ask the user to confirm the image. If decode fails, check whether the reference requests `tilesPerFrame=1` for its decode path. The offer must stay at 4 (HEVC default), but compare the VT session attributes.
- [ ] **Step 5:** `git commit -m "feat: decode and render HEVC 4:4:4 stream (M4)"`

---

### Task 15: Input: pointer, touch, keyboard, cursor (Milestone 5)

**Goal:** Full remote control from trackpad/mouse, touch and hardware keyboard, with the server cursor rendered at the local pointer position.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Input/Keysyms.swift`, `Screener/Input/InputController.swift`, `Screener/Input/RemoteInputView.swift`
- Modify: `Screener/Media/MetalRenderer.swift` (cursor overlay quad from the `0x450` cache)
- Modify: `Screener/UI/SessionView.swift` (host `RemoteInputView` over the Metal view; keyboard toolbar button)
- Test: `ScreenerTests/KeysymsTests.swift`, `ScreenerTests/InputControllerTests.swift`

**Acceptance Criteria:**
- [ ] `InputController` maps view points → host coordinates using the latest `DisplayLayout`. Pointer events go in the coordinate space the reference uses: read `InputController.set_server_dims` / `pointer_event` in `input.py`, which decides between scaled and backing geometry. It sends whichever message type the reference sends (standard `0x05` pointer vs `0x10` encrypted), port `input.py` exactly. Scroll uses the reference's `scroll_event` (button 4/5/6/7 press-release pairs with its step scaling).
- [ ] `RemoteInputView` (UIKit): `UIPointerInteraction` hides the local pointer; `UIHoverGestureRecognizer` handles movement; it also handles `pressesBegan/Ended` with `UIKey.keyCode` and modifiers, and trackpad two-finger scroll via `UIPanGestureRecognizer(allowedScrollTypesMask: .continuous)`. Touch mode: tap = left click; two-finger tap = right click; long-press + drag = drag; two-finger pan = scroll. A hidden `UITextField` becomes first responder for the on-screen keyboard (text insertion → keysym down/up per character).
- [ ] `Keysyms.keysym(for: UIKeyboardHIDUsage, shifted: Bool) -> UInt32?` covers letters, digits, punctuation, F1–F12, arrows, Home/End/PgUp/PgDn, Return, Tab, Escape, Backspace, Delete, and Shift/Control/Option/Command (Command → `0xffe7` Meta_L, or whatever the reference's keyboard path maps Command to: check `frontend/desktop/keyboard_grab.py`)
- [ ] The cursor STORE/SELECT cache renders the BGRA+alpha-plane pixmap (RFC §8.3) as a texture at the local pointer position minus the hotspot
- [ ] Tests: keysym table spot checks (a → 0x61, Shift+a → 0x41, Return → 0xff0d, Left → 0xff51); InputController coordinate mapping for a 1376×1032 view onto 1920×1080 scaled with aspect-fit letterboxing (centre point → (960,540); a point in the letterbox clamps to the edge)
- [ ] **On device:** the user confirms they can move the pointer, click, right-click, scroll, drag a window, and type into TextEdit on the Mac from the iPad's Magic Keyboard/trackpad and from touch

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/KeysymsTests -only-testing:ScreenerTests/InputControllerTests` → `** TEST SUCCEEDED **`; then a live check with the user's confirmation for each listed action

**Steps:**

- [ ] **Step 1:** Write the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement (port `input.py`; for the key mapping consult `keyboard_grab.py`). **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add pointer, touch, keyboard input and cursor rendering (M5)"`

---

### Task 16: Audio (Milestone 6)

**Goal:** Play the Mac's audio on the iPad by decoding AAC-ELD-SBR with AudioToolbox.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Media/AudioPlayer.swift`
- Modify: `Screener/Session/SessionCoordinator.swift` (audio packets → player); `Screener/UI/SessionView.swift` (mute toggle)
- Test: `ScreenerTests/AudioPlayerTests.swift`

**Acceptance Criteria:**
- [ ] `AudioPlayer` creates an `AudioConverter` from AAC-ELD (`kAudioFormatMPEG4AAC_ELD_SBR`, the reference's sample rate, channels and frames-per-packet) to Float32 PCM. It sets the magic cookie the reference sets (port `_AudioToolboxBackend._make_converter` and `_set_magic_cookie` exactly, including the cookie bytes) and decodes one RTP payload per call (port `_fill_callback`'s packet-description handling).
- [ ] PCM is scheduled on an `AVAudioPlayerNode` with a jitter buffer of about 60 ms; underruns insert silence and do not stall
- [ ] `AVAudioSession` category `.playback` with `.mixWithOthers`
- [ ] A unit test: constructing the converter with the reference's cookie succeeds (`noErr`), and decoding an empty or garbage payload returns `nil` without crashing
- [ ] Logs `M6 audio first pcm frames=N`
- [ ] **On device:** the user plays a sound on the Mac (e.g. `afplay /System/Library/Sounds/Glass.aiff`, run by the agent over the terminal) and confirms they hear it on the iPad

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/AudioPlayerTests` → `** TEST SUCCEEDED **`; live: connect, then the agent runs `afplay /System/Library/Sounds/Glass.aiff` on the Mac, the user confirms it plays on the iPad, and `fetch-ipad-log.sh | grep M6` shows a line

**Steps:**

- [ ] **Step 1:** Write the test. **Step 2:** Run it and expect a failure. **Step 3:** Port `aac_eld.py`'s AudioToolbox backend only. **Step 4:** Run the test and expect it to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add AAC-ELD audio playback (M6)"`

---

### Task 17: Clipboard sync (Milestone 7)

**Goal:** Two-way text clipboard between iPad and Mac.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Protocol/Clipboard.swift`
- Modify: `Screener/Session/SessionCoordinator.swift`
- Test: `ScreenerTests/ClipboardTests.swift`

**Acceptance Criteria:**
- [ ] Ports `clipboard.py`: `buildAutoPasteboard`, `buildClipboardRequest`, `buildClipboardSend(text)`, `ClipboardReassembler` (multi-record `0x1f`), `parseItems`, `textFromItems` (prefers `public.utf8-plain-text`, falls back to UTF-16-BE). Empty clipboard (`uncompressed_size = 0`) → no items (RFC §8.2.1).
- [ ] Tests: fixture `clipboard.json` round trip; builder bytes equal fixture
- [ ] Mac→iPad: on `0x14 cmd=2`, send `0x0b` fetch; on a complete `0x1f`, set `UIPasteboard.general.string`
- [ ] iPad→Mac: on `UIPasteboard.changedNotification` while connected and on returning to foreground (check `changeCount`), send the text via the same mechanism the reference uses for outbound clipboard (`_spawn_outbound_clipboard_poller` → `cut_text` or `build_clipboard_send`; use whichever the reference uses)
- [ ] Enable auto-pasteboard at session start, as the reference does
- [ ] **On device:** text copied on the iPad pastes on the Mac (the agent verifies with `pbpaste` in the terminal), and text the agent sets with `echo hello-from-mac | pbcopy` appears in the iPad's pasteboard (the user pastes it into Notes and confirms)

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/ClipboardTests` → `** TEST SUCCEEDED **`; live: `pbpaste` output equals the text the user copied on the iPad, and the user confirms `hello-from-mac` pasted on the iPad

**Steps:**

- [ ] **Step 1:** Write the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement. **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add two-way clipboard sync (M7)"`

---

### Task 18: Hosts: Bonjour, saved hosts, Keychain, host list UI (Milestone 8)

**Goal:** A Screens-like host list: Macs discovered on the LAN, saved hosts with credentials in the Keychain, and one-tap connect.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Hosts/SavedHost.swift`, `Screener/Hosts/Keychain.swift`, `Screener/Hosts/BonjourBrowser.swift`
- Modify: `Screener/UI/HostListView.swift` (real implementation), `Screener/UI/ConnectSheet.swift` (save toggle, prefill), `Screener/App/ScreenerApp.swift` (`.modelContainer(for: SavedHost.self)`)
- Test: `ScreenerTests/KeychainTests.swift`

**Acceptance Criteria:**
- [ ] `@Model final class SavedHost { id: UUID; name: String; host: String; port: Int; username: String; lastConnected: Date? }`. Passwords are stored only in the Keychain (`kSecClassGenericPassword`, service `com.charlesvestal.screener`, account = `SavedHost.id.uuidString`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- [ ] `Keychain.set/get/delete` with a round-trip unit test in the simulator
- [ ] `BonjourBrowser` uses `NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: nil))` and publishes `[DiscoveredHost(name, endpoint)]`. Resolving to a host and port happens at connect time via `NWConnection` to the service endpoint (`TCPByteStream` gains an `init(endpoint:)`).
- [ ] `HostListView`: sections "Saved" and "On This Network" in a grid of cards (name, address, last connected); tap → connect (prompting for a password if none is stored); context menu Edit/Delete; "+" → `ConnectSheet`. A discovered host that matches a saved one shows only under Saved.
- [ ] A first-launch local-network permission prompt appears (Info.plist keys from Task 0)
- [ ] **On device:** this Mac appears under "On This Network" within 5 s; saving it, force-quitting and relaunching keeps it; tapping it connects without re-entering the password

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/KeychainTests` → `** TEST SUCCEEDED **`; then a live check with the user's confirmation of the three behaviours

**Steps:**

- [ ] **Step 1:** Write `KeychainTests`. **Step 2:** Run them and expect a failure. **Step 3:** Implement the models, Keychain, browser and UI. **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add Bonjour discovery, saved hosts and Keychain (M8)"`

---

### Task 19: Resilience: automatic reconnect, TCP-only fallback, stats

**Goal:** Implement the spec's error handling: reconnect overlay with backoff, fallback to TCP framebuffer rendering when UDP media never arrives, decoder rebuild, and a stats overlay.

**Files:**
- Create: `Screener/Media/ZlibRectDecoder.swift`, `Screener/UI/StatsOverlay.swift`
- Modify: `Screener/Session/SessionCoordinator.swift`, `Screener/UI/SessionView.swift`, `Screener/Media/MetalRenderer.swift` (BGRA framebuffer texture path)
- Test: `ScreenerTests/ZlibRectDecoderTests.swift`, `ScreenerTests/SessionCoordinatorPolicyTests.swift`

**Acceptance Criteria:**
- [ ] `ConnectionPolicy` (a pure struct, unit-tested) decides: on TCP drop or record-layer error → reconnect with backoff 1 s, 2 s, 4 s, then give up (3 attempts); on no video packets within 3 s of the `0x1c` answer → `.fallbackToTCP`; on 3 decoder failures within 10 s → `.fallbackToTCP`
- [ ] Automatic reconnect triggers (these don't count against the 3-attempt budget): an `NWPathMonitor` path change (Wi-Fi switch, network back); a scene entering background → graceful close (so the Mac's display privacy ends), then scene active again → reconnect if the session was open; a host wake (TCP connect refused/timeout → keep retrying every 3 s for up to 60 s while the overlay says "Waiting for <host>…"). A reconnect reuses stored credentials, display mode and viewport/zoom, and keeps the last frame visible underneath a small non-modal "Reconnecting…" pill (not a blocking alert).
- [ ] TCP fallback: send `SetEncodings` with only zlib (6) and raw (0) plus the pseudo-encodings (`0x450`, `0x451`, `0x453`, `0x455`, `0x456`, `0x44f`), and no `0x3f2`/`0x3f3`/`0x3ea`, per R-A18. Then `0x09` + `0x03`. `ZlibRectDecoder` keeps one persistent zlib stream (standard RFB zlib) and blits 32-bit pixels into a BGRA framebuffer of the `0x451` backing size. The renderer shows that texture. A "Reduced performance" badge is visible.
- [ ] The reconnect overlay "Reconnecting… (n/3)" appears over the last frame; on final failure the app returns to the host list with an alert showing the error
- [ ] The auth error shows the server reason in `ConnectSheet` (wrong password → "Authentication failed")
- [ ] `StatsOverlay` (toggle in the toolbar): fps, decode ms, video kbps, packet loss %, mode (HP/TCP)
- [ ] Tests: policy transitions; `ZlibRectDecoder` decodes a 4×2 rect compressed with zlib in the test (`Compression` framework deflate + zlib header) into the expected BGRA bytes at the right offset
- [ ] Policy tests cover: path change → immediate reconnect without backoff; background → close; foreground → reconnect; 3 consecutive failures → `.giveUp`
- [ ] Live: (a) toggling the iPad's Wi-Fi off and back on mid-session shows the pill and recovers on its own; (b) backgrounding the app for 10 s and returning resumes the session without user action (the user confirms both)

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/ZlibRectDecoderTests -only-testing:ScreenerTests/SessionCoordinatorPolicyTests` → `** TEST SUCCEEDED **`; then the live Wi-Fi toggle check with the user's confirmation

**Steps:**

- [ ] **Step 1:** Write the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement. **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add reconnect, TCP fallback, and stats overlay"`

---

### Task 20: Floating control menu + modifier/special keys

**Goal:** A Screens-style draggable floating menu that holds sticky modifiers, special keys, Mac shortcut actions and session controls, replacing the plain toolbar from Task 14.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/UI/FloatingMenu/FloatingMenuView.swift` (collapsed pill + expanded panel), `Screener/UI/FloatingMenu/ModifierBar.swift`, `Screener/UI/FloatingMenu/SpecialKeysPanel.swift`, `Screener/UI/FloatingMenu/ShortcutActions.swift`
- Create: `Screener/Input/ModifierState.swift`
- Modify: `Screener/Input/InputController.swift` (merge sticky modifiers into every key/pointer event), `Screener/UI/SessionView.swift` (replace toolbar)
- Test: `ScreenerTests/ModifierStateTests.swift`, `ScreenerTests/ShortcutActionsTests.swift`

**Acceptance Criteria:**
- [ ] `ModifierState` (pure struct) for ⌘ ⌥ ⌃ ⇧ fn, each `.off | .latched | .locked`. Tap toggles off ↔ latched; double-tap (< 300 ms) → locked; a latched modifier clears after the next non-modifier key **or click** (⌘-click and ⌥-drag work from touch); a locked one stays until tapped. `pressedKeysyms(for:)` returns the down events to wrap around a key or click. Physical hardware-keyboard modifiers combine with sticky ones (union), with no double-down events.
- [ ] Unit tests cover the latch/lock/clear transitions and the exact down/up keysym sequence for latched ⌘ + "c" (`ffe7↓ 63↓ 63↑ ffe7↑`, or the Command keysym chosen in Task 15)
- [ ] `ShortcutActions`: ⌘Tab (holds ⌘ while repeated taps send Tab, releasing on menu dismiss, so the app switcher is usable), ⌘Space, Mission Control (⌃↑), App Exposé (⌃↓), Show Desktop (F11), Lock Screen (⌃⌘Q), Force Quit (⌘⌥Esc), Screenshot (⌘⇧4), Screenshot to clipboard (⌃⌘⇧4). Each is a declarative key-chord list, and the tests check every list.
- [ ] Special-keys panel: Esc, Tab, ←↑→↓, F1–F12 (via a fn-row toggle), forward delete, Home, End, PgUp, PgDn, plus key-repeat when held (500 ms delay, 30 Hz)
- [ ] Session controls in the expanded panel: show/hide keyboard, Type Password (types the stored host password followed by Return, after a confirm tap; disabled when no password is stored), fetch/send clipboard now, mute, display mode menu (Task 21), input mode toggle (Task 22), stats, disconnect
- [ ] Pill behaviour: draggable, snaps to the nearest screen edge with a spring, remembers its position per orientation (`@AppStorage`), fades to 30% after 3 s idle, never covers the remote cursor (moves aside when the cursor is under it), shows latched/locked modifier badges while collapsed. VoiceOver labels on every button.
- [ ] Hardware-keyboard shortcut ⌘⌥M toggles the menu (iPad-side `UIKeyCommand`, not forwarded)
- [ ] **On device:** the user confirms: latched ⌘ then tapping "Q" in the special keys quits the frontmost Mac app; ⌘Tab cycles apps; Lock Screen locks the Mac; Type Password unlocks it; the pill drags/snaps and remembers its position after rotation

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/ModifierStateTests -only-testing:ScreenerTests/ShortcutActionsTests` → `** TEST SUCCEEDED **`; then a live check with the user's confirmation of each item

**Steps:**

- [ ] **Step 1:** Write the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement `ModifierState` and `ShortcutActions`, then the SwiftUI menu (`.glassEffect()` material on iPadOS 26; `DragGesture` + edge snapping). **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add floating control menu with sticky modifiers and shortcuts"`

---

### Task 21: Display modes + dynamic resolution

**Goal:** Let the user choose how the Mac's virtual display is sized, and follow rotation and Stage Manager window resizes in-band without reconnecting.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Session/DisplayMode.swift`
- Modify: `Screener/Protocol/Messages.swift` (dynamic `0x1d` descriptor), `Screener/Protocol/ControlSession.swift` (resize + `0x1c` re-offer), `Screener/Media/HEVCAssembler.swift` / `VideoDecoder.swift` (new SSRC group + parameter sets), `Screener/UI/SessionView.swift`
- Test: `ScreenerTests/DisplayModeTests.swift`, additions to `ScreenerTests/MessagesTests.swift`

**Acceptance Criteria:**
- [ ] `enum DisplayMode { case fitRetina, fitMoreSpace, matchMac }`. `geometry(viewPoints:scale:)` → (logical, backing): fitRetina = view size in points @2x; fitMoreSpace = view points × 1.25 @2x, rounded to even numbers; matchMac = don't send a dynamic descriptor and use whatever the server reports. Tests cover iPad Pro 13" landscape/portrait and a 1/2-width Stage Manager window.
- [ ] Dynamic `0x1d` descriptor per RFC §7.3/§10.9 (`display_flags` bit 0, `display_type = 4`, reserved/rotations = 7, valid mode indices, max size, populated mode table), checked against the reference's dynamic `build_virtual_display` output (add a `messages.json` key to the fixture script for the dynamic form)
- [ ] Resize flow: view size change → debounce 400 ms → send `0x1d` → on `.displayLayout`, send the `0x1c` re-offer (reusing keys, per RFC §10.9 step 3) → adopt the new SSRC group, re-harvest VPS/SPS/PPS and rebuild the decoder. The server's geometry is authoritative (backing cap). The last frame is held, scaled, until the new IDR arrives (no black flash).
- [ ] The display mode is chosen from the floating menu and stored per host (Task 23)
- [ ] **On device:** rotating the iPad re-flows the Mac desktop to the new orientation within about 2 s with no reconnect (the log shows no new `M1 auth ok`); switching modes changes the Mac's apparent resolution; resizing in Stage Manager does the same (the user confirms)

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/DisplayModeTests -only-testing:ScreenerTests/MessagesTests` → `** TEST SUCCEEDED **`; live: rotate → `fetch-ipad-log.sh | grep -c "M1 auth ok"` stays 1, and the user confirms the re-flow

**Steps:**

- [ ] **Step 1:** Extend the fixture script and the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement by porting `session.send_dynamic_resolution` and the resize-recovery handling it triggers. **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add display modes and in-band dynamic resolution"`

---

### Task 22: Touch input modes, zoom, and input polish

**Goal:** A Screens-quality touch experience: trackpad mode and direct-touch mode, pinch-zoom with a cursor-following viewport, inertial scrolling, haptics, Pencil hover, pointer lock, and better system-shortcut capture.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Input/TouchInputMode.swift`, `Screener/Input/Viewport.swift`, `Screener/Input/ScrollInertia.swift`
- Modify: `Screener/Input/RemoteInputView.swift`, `Screener/Input/InputController.swift`, `Screener/Media/MetalRenderer.swift` (viewport transform), `Screener/UI/SessionView.swift`
- Test: `ScreenerTests/ViewportTests.swift`, `ScreenerTests/ScrollInertiaTests.swift`, `ScreenerTests/TrackpadModeTests.swift`

**Acceptance Criteria:**
- [ ] **Trackpad mode** (default for touch): one-finger drag moves the remote cursor relatively, with acceleration (gain curve 1.0 → 2.5 by finger speed). Tap = click at the cursor; two-finger tap = right-click; double-tap-and-hold then drag = drag; two-finger drag = scroll; three-finger drag = drag lock.
- [ ] **Direct-touch mode:** the touch point = the cursor position; tap = click there; long-press (0.5 s, with haptic) = right-click; one-finger drag = left-drag; two-finger drag = scroll
- [ ] **Zoom:** pinch zooms 1×–4× around the pinch centre in both modes. `Viewport` (pure struct) keeps the cursor visible by panning when the cursor nears within 10% of an edge. Double-tap with two fingers resets to fit. The renderer applies the viewport as a transform, and `InputController` mapping uses the inverse.
- [ ] `ScrollInertia` (pure): converts the gesture's end velocity into decaying scroll events (friction 0.95 per 1/60 s, stops below a threshold). The trackpad `.continuous` scroll type gets no added inertia because the system provides it.
- [ ] Haptics: `UIImpactFeedbackGenerator(.light)` on click and `.medium` on right-click/drag-start in touch modes. Off when a hardware pointer is used.
- [ ] Apple Pencil: hover (`UIHoverGestureRecognizer` with a Pencil) moves the cursor; Pencil tap = click; squeeze/double-tap = right-click
- [ ] Pointer lock: `prefersPointerLocked = true` while full screen with a hardware trackpad/mouse connected (`GCMouse` relative deltas move the cursor), so the iPad pointer never escapes to the Dock. Releases when the floating menu opens.
- [ ] System shortcuts: override `keyCommands` with `wantsPriorityOverSystemBehavior = true` for ⌘H, ⌘W, ⌘Q, ⌘M, ⌘N, ⌘T, ⌘F, ⌘P, ⌘S, ⌘Z/⇧⌘Z, ⌘C/⌘V/⌘X/⌘A, ⌘←/→, ⌘Tab where iPadOS allows it, and forward them to the Mac. Caps Lock state is synced at connect and on change (`UIKey.modifierFlags.alphaShift`).
- [ ] The input mode is toggled from the floating menu and stored per host (Task 23)
- [ ] Unit tests: viewport zoom-around-point and cursor-follow clamping; inertia decay sequence length and monotonic decrease; trackpad acceleration mapping
- [ ] **On device:** the user confirms each gesture in both modes, pinch-zoom with cursor follow, Pencil hover, ⌘W closing a Mac window rather than iPad UI, and pointer lock with the Magic Keyboard trackpad

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/ViewportTests -only-testing:ScreenerTests/ScrollInertiaTests -only-testing:ScreenerTests/TrackpadModeTests` → `** TEST SUCCEEDED **`; then a live check with the user's confirmation

**Steps:**

- [ ] **Step 1:** Write the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement the pure structs, then gesture wiring. **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add trackpad/direct touch modes, zoom, inertia, Pencil and pointer lock"`

---

### Task 23: Host niceties: thumbnails, per-host settings, Wake-on-LAN, key pinning

**Goal:** Make the host list feel finished and safe: live-looking cards, per-host preferences, waking a sleeping Mac, and trust-on-first-use pinning of the Mac's RSA key.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/Hosts/HostSettings.swift`, `Screener/Hosts/WakeOnLAN.swift`, `Screener/Hosts/Reachability.swift`, `Screener/Hosts/ThumbnailStore.swift`, `Screener/UI/HostSettingsView.swift`
- Modify: `Screener/Hosts/SavedHost.swift` (settings, MAC address, pinned key fingerprint), `Screener/Protocol/Auth.swift` (expose the server key DER), `Screener/UI/HostListView.swift`, `Screener/Session/SessionCoordinator.swift`
- Test: `ScreenerTests/WakeOnLANTests.swift`, `ScreenerTests/KeyPinningTests.swift`

**Acceptance Criteria:**
- [ ] `SavedHost` gains `displayMode`, `inputMode`, `audioEnabled`, `clipboardEnabled`, `macAddress: String?`, `pinnedKeySHA256: Data?`. SwiftData lightweight migration from Task 18's schema works (`VersionedSchema` + `SchemaMigrationPlan`).
- [ ] `HostSettingsView` (from the card's context menu → Edit) edits all of these, plus name/address/username/password
- [ ] Thumbnails: on disconnect, save the last rendered frame (downscaled to 640 px wide, HEIC) to Application Support keyed by host id. Cards show it, with a placeholder Mac glyph when there is none.
- [ ] Reachability: every 15 s while the list is visible, a TCP connect probe to port 5900 (1 s timeout, closed immediately) → green "Available" or grey "Offline" badge. Bonjour presence also counts as available.
- [ ] Wake-on-LAN: `WakeOnLAN.packet(mac:)` = 6×0xFF + 16× MAC (unit-tested for `aa:bb:cc:dd:ee:ff` and `AA-BB-…` parsing). Sent as UDP broadcast to 255.255.255.255:9 and the subnet broadcast. Requires the `com.apple.developer.networking.multicast` entitlement; if the entitlement isn't granted for this team, fall back to unicast to the host's last-known IP and note it in the README. "Wake" is in the card menu when a MAC is set, and connecting to an offline host with a MAC sends a wake first, then retries for up to 60 s.
- [ ] Key pinning (RFC §13.2): the first successful auth stores SHA-256 of the server's RSA DER. If a later connect sees a different key, stop **before** sending credentials and show "This Mac's identity changed" with Cancel or Trust New Key. Unit-tested by injecting two different DER keys into the pinning check.
- [ ] Recents ordering (lastConnected desc) and a `.searchable` filter
- [ ] **On device:** the user confirms thumbnails appear after a session, the offline badge shows when Screen Sharing is turned off, and per-host display/input settings are applied on connect. If the entitlement is available, Wake-on-LAN wakes the Mac from sleep.

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/WakeOnLANTests -only-testing:ScreenerTests/KeyPinningTests` → `** TEST SUCCEEDED **`; then a live check with the user's confirmation

**Steps:**

- [ ] **Step 1:** Write the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement. **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add host thumbnails, per-host settings, Wake-on-LAN and key pinning"`

---

### Task 24: System integration: multi-window, URL scheme, Shortcuts, idle timer

**Goal:** Make sessions first-class iPadOS citizens: each session in its own Stage Manager window, launchable from a URL, Shortcuts and Spotlight, with the screen kept awake.

> **USER-ORDERED GATE: NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `Screener/App/ConnectIntent.swift` (App Intents), `Screener/App/DeepLink.swift`
- Modify: `Screener/App/ScreenerApp.swift` (`WindowGroup(for: SavedHost.ID.self)` session scenes + `openWindow`), `Screener/UI/HostListView.swift` ("Open in New Window" context menu), `Screener/UI/SessionView.swift`, `project.yml` (`CFBundleURLTypes` scheme `screener`, `UIApplicationSupportsMultipleScenes: true`)
- Test: `ScreenerTests/DeepLinkTests.swift`

**Acceptance Criteria:**
- [ ] Each session runs in its own scene. The host list stays in the main window; "Open in New Window" and dragging a card out both create a session window. Two Macs can be connected at once (each `SessionCoordinator` is independent, and audio comes only from the focused session).
- [ ] `DeepLink.parse("screener://connect?host=<saved name or address>")` → a saved host or an ad-hoc host+user (it never accepts a password in the URL); unit-tested, including bad input
- [ ] `ConnectIntent: AppIntent` with an `AppEntity` for saved hosts ("Connect to <host>"), shown as an App Shortcut so it appears in Spotlight and the Shortcuts app
- [ ] `UIApplication.shared.isIdleTimerDisabled = true` while any session is connected and in the foreground; restored afterwards
- [ ] Disconnect on background is per scene (Task 19 behaviour applies per window)
- [ ] **On device:** the user confirms two session windows side by side in Stage Manager (both to this Mac is fine if the server allows it; otherwise one session plus the host list); `screener://connect?host=<name>` typed into Safari opens the session; the Shortcuts action connects; and the screen doesn't dim during a 2+ minute idle session

**Verify:** `xcodebuild test ... -only-testing:ScreenerTests/DeepLinkTests` → `** TEST SUCCEEDED **`; then a live check with the user's confirmation

**Steps:**

- [ ] **Step 1:** Write the tests. **Step 2:** Run them and expect a failure. **Step 3:** Implement. **Step 4:** Run the tests and expect them to pass. **Step 5:** Run the live check. **Step 6:** `git commit -m "feat: add multi-window sessions, URL scheme, Shortcuts and idle-timer handling"`

---

## Spec coverage check

| Spec item | Task |
|---|---|
| HP connect over LAN, HEVC display | 10, 11, 12, 13, 14 |
| Mouse / trackpad / keyboard / touch | 15 |
| Audio | 16 |
| Clipboard | 17 |
| Bonjour, saved hosts, Keychain | 18 |
| Auth failure messages, 10 s timeouts | 10, 19 |
| Reconnect overlay + backoff | 19 |
| Packet loss → FIR, freeze not garbage | 12, 13 |
| UDP blocked → TCP fallback + badge | 19 |
| Decoder error → rebuild + keyframe | 14, 19 |
| os_log subsystem `com.screener` per layer | 0 |
| XCTest units with reference vectors | 1–9, 11, 13, 15–19 |
| On-device milestones 1–8 | 10 (M1–2), 12 (M3), 14 (M4), 15 (M5), 16 (M6), 17 (M7), 18 (M8) |
| AGPL + credit | 0 |
| Automatic reconnection (network change, foreground, host wake) | 19 |
| Floating menu, sticky modifiers, special keys, shortcuts, Type Password | 20 |
| Display modes + rotation/Stage Manager resize | 21 |
| Trackpad/direct touch, zoom, inertia, haptics, Pencil, pointer lock, system-shortcut capture | 22 |
| Thumbnails, reachability, per-host settings, Wake-on-LAN, key pinning, search/recents | 23 |
| Multi-window, URL scheme, App Intents, idle timer | 24 |
