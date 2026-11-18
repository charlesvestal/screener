import CoreVideo
import UIKit
import XCTest
@testable import Screener

// MARK: toasts

@MainActor
final class ToastCenterTests: XCTestCase {
    private var clock = FakeRepeatClock()
    private var announced: [String] = []

    private func make() -> ToastCenter {
        clock = FakeRepeatClock()
        announced = []
        let clock = clock
        let c = ToastCenter(schedule: { clock.schedule($0, $1) })
        c.announce = { [weak self] in self?.announced.append($0) }
        return c
    }

    func testShowsAnnouncesAndAutoDismissesAfterDisplayDuration() {
        let c = make()
        c.show("Muted", key: "audio")
        XCTAssertEqual(c.current?.text, "Muted")
        XCTAssertEqual(announced, ["Muted"])
        clock.advance(by: ToastCenter.displayDuration - 0.01)
        XCTAssertNotNil(c.current)
        clock.advance(by: 0.02)
        XCTAssertNil(c.current)
    }

    func testSameKeyOnScreenUpdatesInPlaceAndRestartsTheTimer() {
        let c = make()
        c.show("Muted", key: "audio")
        clock.advance(by: 1.0)
        c.show("Unmuted", key: "audio")
        XCTAssertEqual(c.current?.text, "Unmuted")
        XCTAssertTrue(c.queued.isEmpty)
        XCTAssertEqual(announced, ["Muted", "Unmuted"])
        clock.advance(by: 1.0)                           // 2.0 s total: the restarted timer still runs
        XCTAssertEqual(c.current?.text, "Unmuted")
        clock.advance(by: 0.7)
        XCTAssertNil(c.current)
    }

    func testDifferentKeysQueueInOrderAfterTheGap() {
        let c = make()
        c.show("Muted", key: "audio")
        c.show("Display: Sharper", key: "display")
        c.show("Touch mode", key: "touchMode")
        XCTAssertEqual(c.queued.map(\.text), ["Display: Sharper", "Touch mode"])
        clock.advance(by: ToastCenter.displayDuration + 0.01)
        XCTAssertNil(c.current)                          // the gap (exit animation)
        clock.advance(by: ToastCenter.gap)
        XCTAssertEqual(c.current?.text, "Display: Sharper")
        clock.advance(by: ToastCenter.displayDuration + ToastCenter.gap + 0.01)
        XCTAssertEqual(c.current?.text, "Touch mode")
        XCTAssertEqual(announced, ["Muted", "Display: Sharper", "Touch mode"])
    }

    func testQueuedSameKeyIsReplacedWhereItStands() {
        let c = make()
        c.show("Reconnected", key: "session")
        c.show("Display: Sharper", key: "display")
        c.show("Muted", key: "audio")
        c.show("Display: More Space", key: "display")
        XCTAssertEqual(c.queued.map(\.text), ["Display: More Space", "Muted"])
        XCTAssertEqual(announced, ["Reconnected"])       // queued toasts are announced when shown
    }

    func testQueueIsBoundedDroppingTheOldest() {
        let c = make()
        c.show("A", key: "a")
        for k in ["b", "c", "d", "e"] { c.show(k.uppercased(), key: k) }
        XCTAssertEqual(c.queued.map(\.key), ["c", "d", "e"])
        XCTAssertEqual(c.queued.count, ToastCenter.maxQueued)
    }

    func testDefaultKeyIsTheTextAndRepeatsCoalesce() {
        let c = make()
        c.show("Copied to Mac ↗")
        c.show("Copied to Mac ↗")
        XCTAssertTrue(c.queued.isEmpty)
        XCTAssertEqual(c.current?.text, "Copied to Mac ↗")
    }

    func testTapDismissesAndTheQueueContinues() {
        let c = make()
        c.show("A", key: "a")
        c.show("B", key: "b")
        c.dismissCurrent()
        XCTAssertNil(c.current)
        c.show("C", key: "c")                            // during the gap: queued, not shown
        XCTAssertNil(c.current)
        clock.advance(by: ToastCenter.gap)
        XCTAssertEqual(c.current?.text, "B")
        XCTAssertEqual(c.queued.map(\.text), ["C"])
    }

    func testClearDropsEverythingAndCancelsTimers() {
        let c = make()
        c.show("A", key: "a")
        c.show("B", key: "b")
        c.clear()
        XCTAssertNil(c.current)
        XCTAssertTrue(c.queued.isEmpty)
        XCTAssertEqual(clock.scheduledCount, 0)
        c.show("C", key: "c")
        XCTAssertEqual(c.current?.text, "C")
    }

    func testToastTexts() {
        XCTAssertEqual(SessionToasts.display(.sharper), "Display: Sharper")
        XCTAssertEqual(SessionToasts.touchMode(.trackpad), "Trackpad mode")
        XCTAssertEqual(SessionToasts.touchMode(.direct), "Touch mode")
        XCTAssertEqual(SessionToasts.sentToMac, "Copied to Mac ↗")
        XCTAssertEqual(SessionToasts.fromMac, "Clipboard from Mac")
    }
}

// MARK: stats

final class LiveStatsTests: XCTestCase {
    func testRingKeepsTheNewestOldestFirst() {
        var r = StatsRing<Int>(capacity: 3)
        XCTAssertTrue(r.isEmpty)
        XCTAssertNil(r.last)
        r.append(1); r.append(2)
        XCTAssertEqual(r.elements, [1, 2])
        r.append(3); r.append(4); r.append(5)
        XCTAssertEqual(r.elements, [3, 4, 5])
        XCTAssertEqual(r.last, 5)
        XCTAssertEqual(r.count, 3)
        r.append(6)
        XCTAssertEqual(r.elements, [4, 5, 6])
        r.removeAll()
        XCTAssertTrue(r.isEmpty)
        r.append(7)
        XCTAssertEqual(r.elements, [7])
    }

    func testRingOfThirtyHoldsThirtySeconds() {
        var r = StatsRing<Int>(capacity: LiveStatsModel.historySeconds)
        for i in 0..<100 { r.append(i) }
        XCTAssertEqual(r.elements, Array(70..<100))
    }

    private func reading(_ t: Double, bytes: Int, tiles: [Int: Int], nanos: Int64 = 0,
                         loss: Double? = nil, bwe: Int = 0) -> StatsSampler.Reading {
        .init(now: t, payloadBytes: bytes, tileFrames: tiles, decodeNanos: nanos, lossFraction: loss, bweKbps: bwe)
    }

    func testSamplerDeltas() throws {
        var s = StatsSampler()
        XCTAssertNil(s.sample(reading(10, bytes: 1_000_000, tiles: [0: 100, 1: 100], nanos: 0)))
        // 2 s: 14.5 MB → 58 Mbps; tile 0 decoded 120 (60 fps), tile 1 40; 160 pictures in 480 ms → 3 ms each.
        let x = try XCTUnwrap(s.sample(reading(12, bytes: 15_500_000, tiles: [0: 220, 1: 140],
                                               nanos: 480_000_000, loss: 0.012, bwe: 62_000)))
        XCTAssertEqual(x.time, 2, accuracy: 1e-9)
        XCTAssertEqual(x.fps, 60, accuracy: 1e-9)
        XCTAssertEqual(x.mbps, 58, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(x.decodeMs), 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(x.lossPercent), 1.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(x.bweMbps), 62, accuracy: 1e-9)
    }

    func testSamplerStaticScreenAndNewTiles() throws {
        var s = StatsSampler()
        _ = s.sample(reading(0, bytes: 0, tiles: [:]))
        let idle = try XCTUnwrap(s.sample(reading(1, bytes: 0, tiles: [:])))
        XCTAssertEqual(idle.fps, 0)
        XCTAssertNil(idle.decodeMs)
        XCTAssertNil(idle.lossPercent)
        XCTAssertNil(idle.bweMbps)
        let fresh = try XCTUnwrap(s.sample(reading(2, bytes: 0, tiles: [3: 30], nanos: 30_000_000)))
        XCTAssertEqual(fresh.fps, 30)                    // a tile not seen before counts from 0
        XCTAssertEqual(try XCTUnwrap(fresh.decodeMs), 1, accuracy: 1e-9)
    }

    func testSamplerRebaselinesWhenCountersGoBackwards() {
        var s = StatsSampler()
        _ = s.sample(reading(0, bytes: 5_000_000, tiles: [0: 10]))
        XCTAssertNil(s.sample(reading(1, bytes: 1_000, tiles: [0: 1])))     // a new transport
        XCTAssertNotNil(s.sample(reading(2, bytes: 126_000, tiles: [0: 61])))
        XCTAssertNil(s.sample(reading(2, bytes: 200_000, tiles: [0: 70])))  // the clock didn't move
    }

    private func sample(fps: Double, mbps: Double, loss: Double?) -> StatsSample {
        StatsSample(time: 0, fps: fps, mbps: mbps, decodeMs: nil, lossPercent: loss, bweMbps: nil)
    }

    func testQualityThresholds() {
        XCTAssertEqual(StreamQuality.classify(sample(fps: 60, mbps: 58, loss: 0)), .good)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 60, mbps: 58, loss: nil)), .good)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 60, mbps: 58, loss: 0.99)), .good)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 60, mbps: 58, loss: 1)), .fair)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 60, mbps: 58, loss: 4.9)), .fair)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 60, mbps: 58, loss: 5)), .poor)
        // A static screen sends few pictures: low fps alone is fine.
        XCTAssertEqual(StreamQuality.classify(sample(fps: 0, mbps: 0.1, loss: 0)), .good)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 3, mbps: 4.9, loss: 0)), .good)
        // A busy stream at a low frame rate is struggling; a 24 fps movie is not.
        XCTAssertEqual(StreamQuality.classify(sample(fps: 24, mbps: 30, loss: 0)), .good)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 19, mbps: 30, loss: 0)), .fair)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 9, mbps: 30, loss: 0)), .poor)
        XCTAssertEqual(StreamQuality.classify(sample(fps: 9, mbps: 30, loss: 2)), .poor)
    }

    func testBadgeText() {
        let s = sample(fps: 59.6, mbps: 57.8, loss: 0)
        XCTAssertEqual(QualityBadgeText.text(s, chroma: .yuv444), "HP · 4:4:4 · 60 fps · 58 Mbps")
        XCTAssertEqual(QualityBadgeText.text(sample(fps: 30, mbps: 4.24, loss: 0), chroma: .yuv420),
                       "HP · 4:2:0 · 30 fps · 4.2 Mbps")
        XCTAssertEqual(QualityBadgeText.text(nil, chroma: .yuv444), "HP · 4:4:4")
        XCTAssertEqual(QualityBadgeText.text(nil, chroma: nil), "HP")
        XCTAssertEqual(QualityBadgeText.mbps(9.96), "10 Mbps")
        XCTAssertEqual(QualityBadgeText.mbps(0), "0.0 Mbps")
        let a11y = QualityBadgeText.accessibilityText(s, chroma: .yuv444)
        XCTAssertTrue(a11y.hasPrefix("Stream quality good"), a11y)
        XCTAssertTrue(a11y.contains("60 frames per second"), a11y)
        XCTAssertTrue(a11y.contains("58 megabits per second"), a11y)
    }

    func testChromaFromPixelFormat() {
        XCTAssertEqual(ChromaFormat(pixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange), .yuv444)
        XCTAssertEqual(ChromaFormat(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), .yuv420)
        XCTAssertEqual(ChromaFormat(pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange), .yuv422)
        XCTAssertEqual(ChromaFormat(pixelFormat: kCVPixelFormatType_32BGRA), .rgb)
        XCTAssertNil(ChromaFormat(pixelFormat: 0))
    }

    @MainActor
    func testModelIngestsResetsAndThrottlesToItsPolls() throws {
        let m = LiveStatsModel()
        var media = MediaTransport.Stats()
        var video = VideoFrameStore.LiveTotals()
        video.pixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        m.ingest(media: media, video: video, now: 0)
        XCTAssertNil(m.latest)                           // one reading is not a rate yet
        XCTAssertEqual(m.chroma, .yuv444)
        XCTAssertEqual(m.badgeText, "HP · 4:4:4")
        for i in 1...40 {
            media.videoPayloadBytes += 7_250_000         // 58 Mbps
            media.bweKbps = 62_000
            video.frames[0, default: 0] += 60
            m.ingest(media: media, video: video, now: Double(i))
        }
        XCTAssertEqual(m.history.count, LiveStatsModel.historySeconds)
        XCTAssertEqual(m.badgeText, "HP · 4:4:4 · 60 fps · 58 Mbps")
        XCTAssertEqual(m.quality, .good)
        m.reset()
        XCTAssertNil(m.latest)
        XCTAssertNil(m.quality)
        XCTAssertTrue(m.history.isEmpty)
        XCTAssertNil(m.chroma)
    }

    func testFrameStoreLiveTotalsAreCumulative() {
        let store = VideoFrameStore()
        XCTAssertEqual(store.liveTotals, VideoFrameStore.LiveTotals())
    }
}

// MARK: settings

final class ScreenerSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ScreenerSettingsTests"

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsWhenUnset() {
        XCTAssertTrue(ScreenerSettings.visualFeedback(defaults))
        XCTAssertTrue(ScreenerSettings.keepAwake(defaults))
        XCTAssertEqual(ScreenerSettings.scrollSpeed(defaults), 1.0)
        XCTAssertFalse(ScreenerSettings.statsOverlayDefault)
        XCTAssertEqual(ScreenerSettings.visualFeedbackKey, "feedback.visual")
        XCTAssertEqual(ScreenerSettings.scrollSpeedKey, "input.scrollSpeed")
        XCTAssertEqual(ScreenerSettings.keepAwakeKey, "session.keepAwake")
        // The keys Settings shares with the menu and the session.
        XCTAssertEqual(PacingConfig.defaultsKey, "video.smoothPlayback")
        XCTAssertEqual(TouchInputMode.defaultsKey, "input.touchMode")
        XCTAssertEqual(DisplayMode.defaultsKey, "display.mode")
        XCTAssertEqual(ClipboardSyncMode.defaultsKey, "clipboard.syncMode")
        XCTAssertEqual(AudioPlayer.mutedDefaultsKey, "audio.muted")
    }

    func testStoredValuesWin() {
        defaults.set(false, forKey: ScreenerSettings.visualFeedbackKey)
        defaults.set(false, forKey: ScreenerSettings.keepAwakeKey)
        defaults.set(1.5, forKey: ScreenerSettings.scrollSpeedKey)
        XCTAssertFalse(ScreenerSettings.visualFeedback(defaults))
        XCTAssertFalse(ScreenerSettings.keepAwake(defaults))
        XCTAssertEqual(ScreenerSettings.scrollSpeed(defaults), 1.5)
    }

    func testScrollSpeedIsClamped() {
        defaults.set(9.0, forKey: ScreenerSettings.scrollSpeedKey)
        XCTAssertEqual(ScreenerSettings.scrollSpeed(defaults), 2.0)
        defaults.set(0.1, forKey: ScreenerSettings.scrollSpeedKey)
        XCTAssertEqual(ScreenerSettings.scrollSpeed(defaults), 0.5)
        defaults.set(Double.nan, forKey: ScreenerSettings.scrollSpeedKey)
        XCTAssertEqual(ScreenerSettings.scrollSpeed(defaults), 1.0)
    }

    func testIdleTimerPolicy() {
        XCTAssertTrue(IdleTimerPolicy.disablesIdleTimer(keepAwake: true, sessionActive: true))
        XCTAssertFalse(IdleTimerPolicy.disablesIdleTimer(keepAwake: true, sessionActive: false))
        XCTAssertFalse(IdleTimerPolicy.disablesIdleTimer(keepAwake: false, sessionActive: true))
        XCTAssertFalse(IdleTimerPolicy.disablesIdleTimer(keepAwake: false, sessionActive: false))
    }

    @MainActor
    func testIdleSessionIsNotActive() {
        XCTAssertFalse(SessionCoordinator().isSessionActive)
    }
}

// MARK: modifier glow

@MainActor
final class ModifierGlowTests: XCTestCase {
    func testGlowLevels() {
        XCTAssertEqual(ModifierGlow.opacity(.off), 0)
        XCTAssertEqual(ModifierGlow.radius(.off), 0)
        XCTAssertGreaterThan(ModifierGlow.radius(.latched), ModifierGlow.radius(.locked))   // soft vs tight
        XCTAssertGreaterThan(ModifierGlow.opacity(.latched), 0)
        XCTAssertGreaterThan(ModifierGlow.opacity(.locked), 0)
        XCTAssertEqual(ModifierGlow.accessibilityValue(.locked), "Locked")
    }

    private func underline(_ b: UIButton) -> NSUnderlineStyle? {
        b.configuration?.attributedTitle?.runs.first?[AttributeScopes.UIKitAttributes.UnderlineStyleAttribute.self]
    }

    func testAccessoryBarGlowsAndUnderlinesLocked() throws {
        let menu = ControlMenuModel()
        let bar = KeyboardAccessoryBar()
        bar.menu = menu
        let cmd = try XCTUnwrap(bar.button(for: .modifier(.command)))
        XCTAssertEqual(cmd.layer.shadowOpacity, 0)
        menu.tapModifier(.command)
        bar.menu = nil; bar.menu = menu                  // re-render synchronously
        XCTAssertEqual(cmd.layer.shadowOpacity, Float(ModifierGlow.opacity(.latched)))
        XCTAssertEqual(cmd.layer.shadowRadius, ModifierGlow.radius(.latched))
        XCTAssertNil(underline(cmd))
        menu.tapModifier(.command)                       // a quick second tap locks
        bar.menu = nil; bar.menu = menu
        XCTAssertEqual(menu.modifiers.state[.command], .locked)
        XCTAssertEqual(cmd.layer.shadowRadius, ModifierGlow.radius(.locked))
        XCTAssertEqual(underline(cmd), .single)
        XCTAssertEqual(cmd.accessibilityValue, "Locked")
    }
}
