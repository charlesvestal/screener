import CoreGraphics
import XCTest
@testable import Screener

// MARK: shake to locate

final class ShakeDetectorTests: XCTestCase {
    /// Back-and-forth strokes along x: `strokes` strokes of `length` points,
    /// each taking `duration` s, fed in 4 samples. Returns the time of each
    /// `true` from the detector.
    private func shake(_ d: inout ShakeDetector, strokes: Int, length: CGFloat, duration: TimeInterval,
                       start: TimeInterval = 0, axis: KeyPath<CGPoint, CGFloat> = \.x) -> [TimeInterval] {
        var pings: [TimeInterval] = []
        var t = start
        for i in 0..<strokes {
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            for _ in 0..<4 {
                t += duration / 4
                let step = sign * length / 4
                let p = axis == \CGPoint.x ? CGPoint(x: step, y: 0.3) : CGPoint(x: 0.3, y: step)
                if d.add(p, at: t) { pings.append(t) }
            }
        }
        // One more sample backwards so the last stroke's reversal registers.
        t += 0.02
        let back: CGFloat = strokes % 2 == 0 ? 20 : -20
        if d.add(axis == \CGPoint.x ? CGPoint(x: back, y: 0) : CGPoint(x: 0, y: back), at: t) { pings.append(t) }
        return pings
    }

    func testRapidBackAndForthIsAShakeOnTheThirdReversal() {
        var d = ShakeDetector()
        // 80 pt in 0.08 s = 1000 pt/s per stroke.
        let pings = shake(&d, strokes: 3, length: 80, duration: 0.08)
        XCTAssertEqual(pings.count, 1)
        // Reversals happen after strokes 1, 2 and 3: the third is the shake.
        XCTAssertGreaterThan(pings[0], 0.24)
    }

    func testTwoReversalsAreNotEnough() {
        var d = ShakeDetector()
        XCTAssertEqual(shake(&d, strokes: 2, length: 80, duration: 0.08), [])
    }

    func testAContinuingShakeKeepsPinging() {
        var d = ShakeDetector()
        let pings = shake(&d, strokes: 8, length: 80, duration: 0.08)
        XCTAssertEqual(pings.count, 6)                 // reversals 3…8
    }

    func testVerticalShakeCountsToo() {
        var d = ShakeDetector()
        XCTAssertEqual(shake(&d, strokes: 4, length: 80, duration: 0.08, axis: \.y).count, 2)
    }

    func testSlowBackAndForthIsNot() {
        var d = ShakeDetector()
        // 80 pt in 0.2 s = 400 pt/s: under minSpeed.
        XCTAssertEqual(shake(&d, strokes: 6, length: 80, duration: 0.2), [])
    }

    func testTinyFastWigglesAreNot() {
        var d = ShakeDetector()
        // 20 pt strokes: under minStroke however fast.
        XCTAssertEqual(shake(&d, strokes: 8, length: 20, duration: 0.01), [])
    }

    func testFastMotionOneWayIsNot() {
        var d = ShakeDetector()
        var t = 0.0
        for _ in 0..<40 {
            t += 0.01
            XCTAssertFalse(d.add(CGPoint(x: 30, y: 0), at: t))
        }
    }

    func testReversalsSpreadBeyondTheWindowAreNot() {
        var d = ShakeDetector()
        // Fast strokes, but a 0.2 s still pause between each (under maxPause,
        // so nothing resets): three reversals never fit in 0.6 s.
        var t = 0.0
        var pings = 0
        for i in 0..<6 {
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            for _ in 0..<4 {
                t += 0.02
                if d.add(CGPoint(x: sign * 20, y: 0), at: t) { pings += 1 }
            }
            t += 0.2
            if d.add(.zero, at: t) { pings += 1 }
        }
        XCTAssertEqual(pings, 0)
    }

    func testAPauseStartsOver() {
        var d = ShakeDetector()
        var pings = shake(&d, strokes: 2, length: 80, duration: 0.08)
        // A pause longer than maxPause, then two more strokes: still only two reversals each side.
        pings += shake(&d, strokes: 2, length: 80, duration: 0.08, start: 2)
        XCTAssertEqual(pings, [])
    }

    func testJitterAtATurnDoesNotBreakTheChain() {
        var d = ShakeDetector()
        var t = 0.0
        var pings = 0
        for i in 0..<5 {
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            for step: CGFloat in [25, 25, 25, -3, 8] {     // a 3-pt wobble before the end of each stroke
                t += 0.02
                if d.add(CGPoint(x: sign * step, y: 0), at: t) { pings += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(pings, 1)
    }
}

// MARK: locate animation

final class CursorLocateTests: XCTestCase {
    func testFindCursorRisesWithAnOvershootHoldsAndSettles() {
        var c = CursorEffects()
        c.locate(now: 10, hold: CursorEffects.findHold, reduceMotion: false)
        XCTAssertEqual(c.locateScale(at: 10), 1, accuracy: 1e-6)
        // Overshoot somewhere in the rise.
        let peak = stride(from: 10.0, through: 10 + CursorEffects.locateRise, by: 0.005)
            .map { c.locateScale(at: $0) }.max()!
        XCTAssertGreaterThan(peak, CursorEffects.locatePeak)
        XCTAssertLessThan(peak, 4.2)
        XCTAssertEqual(c.locateScale(at: 10.5), CursorEffects.locatePeak, accuracy: 1e-6)
        let holdEnd = 10 + CursorEffects.findHold
        XCTAssertEqual(c.locateScale(at: holdEnd - 0.01), CursorEffects.locatePeak, accuracy: 1e-6)
        let mid = c.locateScale(at: holdEnd + CursorEffects.locateSettle / 2)
        XCTAssertGreaterThan(mid, 1)
        XCTAssertLessThan(mid, CursorEffects.locatePeak)
        XCTAssertTrue(c.isAnimating(at: holdEnd + CursorEffects.locateSettle - 0.01))
        XCTAssertEqual(c.locateScale(at: holdEnd + CursorEffects.locateSettle), 1)
        XCTAssertFalse(c.isAnimating(at: holdEnd + CursorEffects.locateSettle))
        c.prune(at: holdEnd + CursorEffects.locateSettle)
        XCTAssertNil(c.locateStart)
    }

    func testReduceMotionEnlargesWithoutBounce() {
        var c = CursorEffects()
        c.locate(now: 0, hold: CursorEffects.findHold, reduceMotion: true)
        let samples = stride(from: 0.0, through: CursorEffects.locateRise, by: 0.005).map { c.locateScale(at: $0) }
        XCTAssertLessThanOrEqual(samples.max()!, CursorEffects.locatePeak + 1e-6)
        XCTAssertEqual(zip(samples, samples.dropFirst()).filter { $1 < $0 - 1e-9 }.count, 0)   // monotonic
        XCTAssertEqual(c.locateScale(at: 0.5), CursorEffects.locatePeak, accuracy: 1e-6)
    }

    func testShakePingsKeepItUpAndItSettlesAfterTheyStop() {
        var c = CursorEffects()
        var t = 0.0
        for _ in 0..<10 {                       // a ping every 0.15 s for 1.5 s
            c.locate(now: t, hold: CursorEffects.locateHold, reduceMotion: false)
            t += 0.15
            XCTAssertEqual(c.locateScale(at: t - 0.001), CursorEffects.locatePeak, accuracy: 0.6)
        }
        let last = t - 0.15
        XCTAssertEqual(c.locateScale(at: last + CursorEffects.locateHold - 0.01), CursorEffects.locatePeak,
                       accuracy: 1e-6)
        // Back to normal about half a second after the hold.
        XCTAssertEqual(c.locateScale(at: last + CursorEffects.locateHold + CursorEffects.locateSettle), 1)
    }

    func testAPingWhileSettlingRisesFromTheCurrentSize() {
        var c = CursorEffects()
        c.locate(now: 0, hold: 0.3, reduceMotion: false)
        let t = 0.3 + CursorEffects.locateSettle / 2
        let before = c.locateScale(at: t)
        c.locate(now: t, hold: 0.3, reduceMotion: false)
        XCTAssertEqual(c.locateScale(at: t), before, accuracy: 1e-6)          // no jump
        XCTAssertEqual(c.locateScale(at: t + CursorEffects.locateRise + 0.01), CursorEffects.locatePeak,
                       accuracy: 1e-6)
    }

    func testCursorScaleIsTheLargerOfHaloAndLocate() {
        var c = CursorEffects()
        c.halo(now: 0, reduceMotion: false)
        XCTAssertEqual(c.cursorScale(at: CursorEffects.haloRise), CursorEffects.haloPeak, accuracy: 1e-6)
        c.locate(now: 0, hold: 1, reduceMotion: false)
        XCTAssertEqual(c.cursorScale(at: 0.5), CursorEffects.locatePeak, accuracy: 1e-6)
    }

    func testRemoveDecorationsKeepsALocate() {
        var c = CursorEffects()
        c.halo(now: 0, reduceMotion: false)
        c.locate(now: 0, hold: 1, reduceMotion: false)
        XCTAssertTrue(c.hasDecorations)
        c.removeDecorations()
        XCTAssertFalse(c.hasDecorations)
        XCTAssertEqual(c.cursorScale(at: 0.5), CursorEffects.locatePeak, accuracy: 1e-6)
        c.removeAll()
        XCTAssertEqual(c.cursorScale(at: 0.5), 1)
    }
}

@MainActor
final class LocateFeedbackCenterTests: XCTestCase {
    private var clock = FakeRepeatClock()

    private func make(visual: Bool) -> FeedbackCenter {
        clock = FakeRepeatClock()
        let c = FeedbackCenter(schedule: clock.schedule)
        c.now = { [unowned self] in self.clock.now }
        c.visualEnabled = { visual }
        c.reduceMotion = { false }
        return c
    }

    func testLocateWorksWithVisualFeedbackOff() {
        let c = make(visual: false)
        var redraws = 0
        c.onChange = { redraws += 1 }
        c.feedback(.locateCursor(hold: CursorEffects.findHold))
        XCTAssertEqual(redraws, 1)
        XCTAssertTrue(c.needsFrames(at: 0.5))
        XCTAssertEqual(c.gpuState(at: 0.5).haloScale, CursorEffects.locatePeak, accuracy: 1e-6)
        // Later (decorative) events don't clear it.
        c.feedback(.fingerDown)
        c.feedback(.click(at: .zero))
        XCTAssertEqual(c.gpuState(at: 0.5).haloScale, CursorEffects.locatePeak, accuracy: 1e-6)
        XCTAssertEqual(c.gpuState(at: 0.5).haloGlow, 0)
        XCTAssertTrue(c.gpuState(at: CursorEffects.findHold + CursorEffects.locateSettle + 0.01).isEmpty)
    }
}

// MARK: shake / Find Cursor in the view

@MainActor
final class FindCursorTests: XCTestCase {
    final class Recorder: FeedbackSink {
        var events: [FeedbackEvent] = []
        func feedback(_ event: FeedbackEvent) { events.append(event) }
        var locates: [TimeInterval] {
            events.compactMap { if case .locateCursor(let h) = $0 { h } else { nil } }
        }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        func append(_ d: Data) { lock.withLock { _sent.append(d) } }
        var sent: [Data] { lock.withLock { _sent } }
    }

    private var t: TimeInterval = 0

    /// A 1600×1000 view over a 1600×1000 host (1 point = 1 host pixel).
    private func make() -> (RemoteInputView, InputController, Sink, Recorder) {
        let sink = Sink()
        let input = InputController(contentKey: nil, serverWidth: 1600, serverHeight: 1000,
                                    send: { sink.append($0) })
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                   repeatSchedule: FakeRepeatClock().schedule)
        view.now = { [unowned self] in self.t }
        view.cursor = RemoteCursor()
        view.input = input
        let r = Recorder()
        view.feedback = r
        return (view, input, sink, r)
    }

    func testFindCursorCentresTheZoomedViewportOnTheCursor() throws {
        let (view, _, _, r) = make()
        view.perform(.moveBy(.zero))                                    // (800, 500)
        view.zoom(by: 4, around: CGPoint(x: 800, y: 500), pan: .zero)
        // Pan the picture away so the cursor is off screen.
        view.zoom(by: 1, around: .zero, pan: CGPoint(x: 1000, y: 600))
        let before = try XCTUnwrap(view.cursorViewPoint)
        XCTAssertFalse(view.bounds.contains(before))
        view.findCursor()
        let drawn = try XCTUnwrap(view.cursorViewPoint)
        XCTAssertEqual(drawn.x, 800, accuracy: 4.01)
        XCTAssertEqual(drawn.y, 500, accuracy: 4.01)
        XCTAssertEqual(view.viewport.value.scale, 4, accuracy: 1e-6)         // zoom kept
        XCTAssertEqual(r.locates, [CursorEffects.findHold])
    }

    func testFindCursorNearAnEdgeCentresAsFarAsTheClampAllows() throws {
        let (view, _, _, _) = make()
        view.perform(.moveBy(CGPoint(x: 790, y: 490)))                  // (1590, 990)
        view.zoom(by: 2, around: CGPoint(x: 0, y: 0), pan: .zero)
        view.findCursor()
        let vp = view.viewport.value
        XCTAssertEqual(vp.visibleUnitRect.maxX, 1, accuracy: 1e-6)
        XCTAssertEqual(vp.visibleUnitRect.maxY, 1, accuracy: 1e-6)
        XCTAssertTrue(view.bounds.contains(try XCTUnwrap(view.cursorViewPoint)))
    }

    func testFindCursorUnzoomedKeepsTheViewportAndStillEnlarges() {
        let (view, _, _, r) = make()
        view.perform(.moveBy(CGPoint(x: 100, y: 0)))
        view.findCursor()
        XCTAssertEqual(view.viewport.value, .identity)
        XCTAssertEqual(r.locates, [CursorEffects.findHold])
    }

    func testFindCursorWithNoPositionPutsItMidScreen() async {
        let (view, input, sink, r) = make()
        view.findCursor()
        await input.flush()
        let last = sink.sent.last.map { [UInt8]($0) }
        XCTAssertEqual(last?[0], 5)
        XCTAssertEqual(last.map { Int($0[2]) << 8 | Int($0[3]) }, 800)
        XCTAssertEqual(r.locates.count, 1)
    }

    func testFindCursorReshowsAHiddenCursor() {
        let (view, _, _, _) = make()
        let cursor = view.cursor!
        view.perform(.moveBy(CGPoint(x: 10, y: 10)))
        cursor.hide()
        XCTAssertNil(cursor.position)
        view.findCursor()
        XCTAssertEqual(cursor.position, CGPoint(x: 810, y: 510))
    }

    func testTheMenuTileReachesTheView() {
        let (view, _, _, r) = make()
        let menu = ControlMenuModel()
        view.controlMenu = menu
        menu.findCursor()
        XCTAssertEqual(r.locates.count, 1)
    }

    func testShakingTheTrackpadCursorEnlargesIt() {
        let (view, _, _, r) = make()
        for i in 0..<5 {
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            for _ in 0..<4 {
                t += 0.02
                view.perform(.moveBy(CGPoint(x: sign * 25, y: 0)))
            }
        }
        t += 0.02
        view.perform(.moveBy(CGPoint(x: 25, y: 0)))
        XCTAssertGreaterThanOrEqual(r.locates.count, 2)
        XCTAssertTrue(r.locates.allSatisfy { $0 == CursorEffects.locateHold })
    }

    func testShakingThePointerLockMouseEnlargesIt() {
        let (view, _, _, r) = make()
        // Pointer-lock moves go through moveCursor too (lockedMouseMoved is gated
        // on a real lock; its moveCursor call is what feeds the detector).
        for i in 0..<5 {
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            for _ in 0..<4 {
                t += 0.02
                view.moveCursor(by: CGPoint(x: sign * 25, y: 0))
            }
        }
        t += 0.02
        view.moveCursor(by: CGPoint(x: 25, y: 0))
        XCTAssertGreaterThanOrEqual(r.locates.count, 2)
    }

    func testShakingTheHardwarePointerEnlargesIt() {
        let (view, _, _, r) = make()
        var x: CGFloat = 800
        for i in 0..<5 {
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            for _ in 0..<4 {
                t += 0.02
                x += sign * 25
                view.noteHardwarePointer(at: CGPoint(x: x, y: 500))
            }
        }
        t += 0.02
        view.noteHardwarePointer(at: CGPoint(x: x + 25, y: 500))
        XCTAssertGreaterThanOrEqual(r.locates.count, 2)
    }

    func testOrdinaryMovesDoNotEnlargeIt() {
        let (view, _, _, r) = make()
        for _ in 0..<50 {
            t += 0.016
            view.perform(.moveBy(CGPoint(x: 6, y: 2)))
        }
        XCTAssertEqual(r.locates, [])
    }
}

// MARK: preferences

final class InputPreferencesTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "InputPreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTapDelayPresets() {
        XCTAssertEqual(TapClickDelay.fast.seconds, 0.15)
        XCTAssertEqual(TapClickDelay.normal.seconds, 0.25)
        XCTAssertEqual(TapClickDelay.relaxed.seconds, 0.35)
        XCTAssertEqual(TapClickDelay.default, .normal)
        XCTAssertEqual(TapClickDelay.default.seconds, TouchInterpreter.Tuning.tapDragWindow)
        XCTAssertEqual(TapClickDelay.allCases.map(\.title), ["Fast", "Normal", "Relaxed"])
        XCTAssertEqual(TapClickDelay.defaultsKey, "input.tapDelay")
    }

    func testScrollDirection() {
        XCTAssertEqual(ScrollDirection.default, .natural)
        XCTAssertEqual(ScrollDirection.natural.sign, 1)
        XCTAssertEqual(ScrollDirection.reversed.sign, -1)
        XCTAssertEqual(ScrollDirection.defaultsKey, "input.scrollDirection")
    }

    func testLoadDefaultsAndStoredValues() {
        let d = suite()
        XCTAssertEqual(InputPreferences.load(d), InputPreferences())
        XCTAssertFalse(InputPreferences().longPressRightClick, "off by default: two-finger tap is the right click")
        d.set("relaxed", forKey: TapClickDelay.defaultsKey)
        d.set("reversed", forKey: ScrollDirection.defaultsKey)
        d.set(true, forKey: InputPreferences.longPressRightClickKey)
        XCTAssertEqual(InputPreferences.load(d),
                       InputPreferences(tapDelay: .relaxed, scrollDirection: .reversed, longPressRightClick: true))
        d.set("bogus", forKey: TapClickDelay.defaultsKey)
        d.set("sideways", forKey: ScrollDirection.defaultsKey)
        XCTAssertEqual(InputPreferences.load(d).tapDelay, .normal)
        XCTAssertEqual(InputPreferences.load(d).scrollDirection, .natural)
    }

    @MainActor
    func testTheViewAppliesThemAtSessionStartAndLive() {
        let d = suite()
        d.set("fast", forKey: TapClickDelay.defaultsKey)
        d.set(false, forKey: InputPreferences.longPressRightClickKey)
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   repeatSchedule: FakeRepeatClock().schedule)
        view.defaults = d
        view.input = InputController(contentKey: nil, serverWidth: 100, serverHeight: 100, send: { _ in })
        XCTAssertEqual(view.touchInterpreter.tapDelay, 0.15)
        XCTAssertFalse(view.touchInterpreter.longPressRightClick)
        d.set("relaxed", forKey: TapClickDelay.defaultsKey)
        d.set(true, forKey: InputPreferences.longPressRightClickKey)
        view.reloadPreferences()                    // what a UserDefaults change notification does
        XCTAssertEqual(view.touchInterpreter.tapDelay, 0.35)
        XCTAssertTrue(view.touchInterpreter.longPressRightClick)
    }
}

// MARK: tap delay and long-press right click (TouchInterpreter)

@MainActor
final class TapDelayAndLongPressTests: XCTestCase {
    private var clock = FakeRepeatClock()
    private var actions: [TouchAction] = []
    private let L = InputController.Button.left
    private let R = InputController.Button.right
    private let p = CGPoint(x: 100, y: 100)

    private func make(delay: TimeInterval = 0.25, longPress: Bool = true) -> TouchInterpreter {
        clock = FakeRepeatClock()
        actions = []
        let t = TouchInterpreter(schedule: clock.schedule) { [weak self] in self?.actions.append($0) }
        t.tapDelay = delay
        t.longPressRightClick = longPress
        return t
    }

    private func at(_ dt: TimeInterval) -> TimeInterval {
        clock.advance(by: dt)
        return clock.now
    }

    private var buttonsAndHaptics: [TouchAction] {
        actions.filter {
            switch $0 {
            case .button, .haptic: true
            default: false
            }
        }
    }

    private func click(_ b: Int) -> [TouchAction] { [.button(b, down: true), .button(b, down: false)] }

    private func tap(_ t: TouchInterpreter, id: Int = 1) {
        t.began(id, at: p, time: clock.now)
        t.ended(id, at: p, time: at(0.08))
    }

    // Tap delay

    func testFastDelayClicksSooner() {
        let t = make(delay: TapClickDelay.fast.seconds)
        tap(t)
        clock.advance(by: 0.14)
        XCTAssertEqual(buttonsAndHaptics, [])
        clock.advance(by: 0.02)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.light)] + click(L))
    }

    func testFastDelayMakesALateSecondTapTwoClicks() {
        let t = make(delay: TapClickDelay.fast.seconds)
        tap(t)
        clock.advance(by: 0.2)                    // past 0.15: the first click went
        tap(t, id: 2)
        clock.advance(by: 0.2)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.light)] + click(L) + [.haptic(.light)] + click(L))
    }

    func testRelaxedDelayStillCatchesALateSecondTapAsADoubleClick() {
        let t = make(delay: TapClickDelay.relaxed.seconds)
        tap(t)
        clock.advance(by: 0.3)                    // inside 0.35
        XCTAssertEqual(buttonsAndHaptics, [])
        tap(t, id: 2)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.light)] + click(L) + click(L))
    }

    func testZoomedTwoFingerTapWaitsTheTapDelay() {
        let t = make(delay: TapClickDelay.relaxed.seconds)
        t.isZoomed = { true }
        t.began(1, at: p, time: clock.now)
        t.began(2, at: CGPoint(x: 140, y: 100), time: clock.now)
        t.ended(1, at: p, time: at(0.05))
        t.ended(2, at: CGPoint(x: 140, y: 100), time: at(0.01))
        clock.advance(by: 0.3)
        XCTAssertEqual(buttonsAndHaptics, [])
        clock.advance(by: 0.06)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))
    }

    // Long-press right click

    func testStillLongPressRightClicksWhenItFires() {
        let t = make()
        t.began(1, at: p, time: clock.now)
        clock.advance(by: TouchInterpreter.Tuning.longPress - 0.01)
        XCTAssertEqual(buttonsAndHaptics, [])
        clock.advance(by: 0.02)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))
        t.ended(1, at: p, time: at(0.3))
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))         // no left click on lift
    }

    func testAfterTheRightClickTheFingerMovesTheCursor() {
        let t = make()
        t.began(1, at: p, time: clock.now)
        clock.advance(by: 0.6)
        t.moved(1, to: CGPoint(x: 160, y: 100), time: at(0.05))
        t.ended(1, at: CGPoint(x: 160, y: 100), time: at(0.05))
        XCTAssertTrue(actions.contains { if case .moveBy = $0 { true } else { false } })
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))
    }

    func testSmallJitterUnderTheSlopStillCounts() {
        let t = make()
        t.began(1, at: p, time: clock.now)
        t.moved(1, to: CGPoint(x: 104, y: 103), time: at(0.2))
        clock.advance(by: 0.35)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))
    }

    func testMovingBeforeItFiresIsAMoveNotARightClick() {
        let t = make()
        t.began(1, at: p, time: clock.now)
        t.moved(1, to: CGPoint(x: 140, y: 100), time: at(0.2))
        clock.advance(by: 0.5)
        t.ended(1, at: CGPoint(x: 140, y: 100), time: at(0.05))
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [])
    }

    func testOffALongStillTouchStartsADragUntilItLifts() {
        let t = make(longPress: false)
        t.began(1, at: p, time: clock.now)
        clock.advance(by: TouchInterpreter.Tuning.longPress - 0.05)
        XCTAssertEqual(buttonsAndHaptics, [], "nothing before the threshold")
        clock.advance(by: 0.06)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium), .button(L, down: true)])
        t.moved(1, to: CGPoint(x: 160, y: 100), time: at(0.05))
        XCTAssertTrue(actions.contains { if case .moveBy = $0 { true } else { false } }, "the drag moves the cursor")
        t.ended(1, at: CGPoint(x: 160, y: 100), time: at(0.01))
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium), .button(L, down: true), .button(L, down: false)])
    }

    func testOffMovingBeforeTheThresholdIsJustAMove() {
        let t = make(longPress: false)
        t.began(1, at: p, time: clock.now)
        t.moved(1, to: CGPoint(x: 160, y: 100), time: at(0.1))
        clock.advance(by: 1)
        t.ended(1, at: CGPoint(x: 160, y: 100), time: at(0.01))
        XCTAssertEqual(buttonsAndHaptics, [])
    }

    func testOffLongPressUnderTheDragLockDoesNotPressAgain() {
        let t = make(longPress: false)
        // Three-finger drag engages the lock.
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 150, y: 100), time: at(0.01))
        t.began(3, at: CGPoint(x: 200, y: 100), time: at(0.01))
        for (i, x) in [100.0, 150, 200].enumerated() { t.moved(i + 1, to: CGPoint(x: x, y: 140), time: at(0.01)) }
        for i in 1...3 { t.ended(i, at: CGPoint(x: 0, y: 140), time: at(0.01)) }
        XCTAssertTrue(t.dragLocked)
        actions = []
        t.began(4, at: p, time: clock.now)
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [], "the lock already holds the button")
    }

    func testAQuickTapIsStillALeftClick() {
        let t = make()
        tap(t)
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.light)] + click(L))
    }

    func testDoubleTapAndHoldIsStillADragNotARightClick() {
        let t = make()
        tap(t)
        clock.advance(by: 0.1)
        t.began(2, at: p, time: clock.now)
        clock.advance(by: 0.8)                    // held well past the long press
        t.ended(2, at: p, time: at(0.01))
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium), .button(L, down: true), .button(L, down: false)])
    }

    func testSecondFingerBeforeItFiresCancelsIt() {
        let t = make()
        t.began(1, at: p, time: clock.now)
        t.began(2, at: CGPoint(x: 160, y: 100), time: at(0.2))
        t.moved([1: CGPoint(x: 100, y: 140), 2: CGPoint(x: 160, y: 140)], time: at(0.1))   // a scroll
        clock.advance(by: 0.5)
        t.ended(1, at: CGPoint(x: 100, y: 140), time: at(0.01))
        t.ended(2, at: CGPoint(x: 160, y: 140), time: at(0.01))
        XCTAssertEqual(buttonsAndHaptics.filter { $0 == .button(R, down: true) }, [])
    }

    func testNoRightClickUnderTheDragLock() {
        let t = make()
        // Three-finger drag engages the lock.
        t.began(1, at: p, time: clock.now)
        t.began(2, at: CGPoint(x: 140, y: 100), time: clock.now)
        t.began(3, at: CGPoint(x: 180, y: 100), time: clock.now)
        t.moved([1: CGPoint(x: 100, y: 140), 2: CGPoint(x: 140, y: 140), 3: CGPoint(x: 180, y: 140)],
                time: at(0.05))
        for id in 1...3 { t.ended(id, at: .zero, time: at(0.01)) }
        XCTAssertTrue(t.dragLocked)
        actions = []
        t.began(4, at: p, time: clock.now)
        clock.advance(by: 0.8)
        XCTAssertEqual(buttonsAndHaptics, [])
        XCTAssertTrue(t.dragLocked)
    }

    func testCancelBeforeItFiresDropsIt() {
        let t = make()
        t.began(1, at: p, time: clock.now)
        t.cancel()
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [])
    }

    func testDirectModeLongPressIsUnchanged() {
        let t = make()
        t.mode = .direct
        t.began(1, at: p, time: clock.now)
        clock.advance(by: 0.6)
        t.ended(1, at: p, time: at(0.01))
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))
    }
}

// MARK: scroll direction on every path

@MainActor
final class ScrollDirectionWireTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        func append(_ d: Data) { lock.withLock { _sent.append(d) } }
        var sent: [Data] { lock.withLock { _sent } }
    }

    private func make(_ dir: ScrollDirection) -> (RemoteInputView, InputController, Sink) {
        let sink = Sink()
        let input = InputController(contentKey: nil, serverWidth: 1600, serverHeight: 1000,
                                    send: { sink.append($0) })
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                   repeatSchedule: FakeRepeatClock().schedule)
        view.input = input
        view.preferences.scrollDirection = dir
        view.perform(.moveBy(.zero))
        return (view, input, sink)
    }

    /// The scroll buttons (up / down bits) of every scroll press sent.
    private func scrollBits(_ input: InputController, _ sink: Sink) async -> Set<Int> {
        await input.flush()
        let up = InputController.Button.scrollUp, down = InputController.Button.scrollDown
        return Set(sink.sent.compactMap { d -> Int? in
            let b = [UInt8](d)
            guard b.first == 5 else { return nil }
            let bits = Int(b[1]) & (up | down)
            return bits == 0 ? nil : bits
        })
    }

    private func check(_ path: (RemoteInputView) -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        let (n, ni, ns) = make(.natural)
        path(n)
        let natural = await scrollBits(ni, ns)
        let (r, ri, rs) = make(.reversed)
        path(r)
        let reversed = await scrollBits(ri, rs)
        XCTAssertEqual(natural, [InputController.Button.scrollUp], file: file, line: line)
        XCTAssertEqual(reversed, [InputController.Button.scrollDown], file: file, line: line)
    }

    // Each: a "fingers / content moving down" motion = scroll up when natural.

    func testTouchScroll() async {
        await check { $0.perform(.scroll(CGPoint(x: 0, y: 60))) }
    }

    func testTouchMomentum() async {
        await check { $0.scrollTouch(CGPoint(x: 0, y: 60)) }          // what each momentum tick does
    }

    func testHardwareContinuousScroll() async {
        await check { $0.continuousScroll(CGPoint(x: 0, y: 60), at: CGPoint(x: 800, y: 500)) }
    }

    func testWheelScroll() async {
        await check { $0.wheelScrolled(CGPoint(x: 0, y: 20), at: CGPoint(x: 800, y: 500)) }
    }

    func testPointerLockScroll() async {
        await check { $0.lockedScroll(dy: 60) }
    }
}
