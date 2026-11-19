import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import Screener

// MARK: ripple state machine

final class RippleFieldTests: XCTestCase {
    private let p = CGPoint(x: 100, y: 80)

    func testClickSpawnsOneRingThatGrowsDecaysAndExpires() {
        var f = RippleField()
        f.spawn(.click, at: p, now: 10, reduceMotion: false)
        XCTAssertEqual(f.ripples.count, 1)
        let a = f.samples(at: 10.0), b = f.samples(at: 10 + RippleField.ringDuration * 0.43),
            c = f.samples(at: 10 + RippleField.ringDuration * 0.97)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].center, p)
        XCTAssertLessThan(a[0].radius, b[0].radius)
        XCTAssertLessThan(b[0].radius, c[0].radius)
        XCTAssertLessThanOrEqual(c[0].radius, RippleField.ringMaxRadius)
        XCTAssertGreaterThan(a[0].amplitude, b[0].amplitude)
        XCTAssertGreaterThan(b[0].amplitude, c[0].amplitude)
        XCTAssertGreaterThan(c[0].radius, RippleField.ringMaxRadius * 0.8)
        XCTAssertTrue(f.isAnimating(at: 10 + RippleField.ringDuration * 0.97))
        XCTAssertFalse(f.isAnimating(at: 10 + RippleField.ringDuration))
        XCTAssertEqual(f.samples(at: 10 + RippleField.ringDuration + 0.01), [])
        f.prune(at: 10 + RippleField.ringDuration + 0.01)
        XCTAssertTrue(f.isEmpty)
    }

    func testDoubleClickIsTwoRingsAProportionalGapApart() {
        var f = RippleField()
        f.spawn(.doubleClick, at: p, now: 0, reduceMotion: false)
        XCTAssertEqual(f.ripples.count, 2)
        XCTAssertEqual(f.ripples[1].start, RippleField.doubleGap, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(RippleField.doubleGap, 0.12)
        XCTAssertLessThanOrEqual(RippleField.doubleGap, 0.15)
        XCTAssertEqual(f.samples(at: RippleField.doubleGap * 0.5).count, 1)  // the second hasn't started
        XCTAssertEqual(f.samples(at: RippleField.doubleGap * 1.2).count, 2)
        // Animating until the second ring ends.
        XCTAssertTrue(f.isAnimating(at: RippleField.ringDuration + 0.05))
        XCTAssertFalse(f.isAnimating(at: RippleField.doubleGap + RippleField.ringDuration))
    }

    func testRightClickAddsADelayedTintedFainterEcho() {
        var f = RippleField()
        f.spawn(.rightClick, at: p, now: 0, reduceMotion: false)
        XCTAssertEqual(f.ripples.map(\.echo), [false, true])
        XCTAssertEqual(f.ripples[1].start, RippleField.echoDelay, accuracy: 1e-9)
        let s = f.samples(at: RippleField.echoDelay + 0.01)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].tint, RippleField.white)
        XCTAssertEqual(s[1].tint, RippleField.echoTint)
        // Both carry a tinted rim; the echo's is its own colour.
        XCTAssertEqual(s[0].rimTint, RippleField.rimTint)
        XCTAssertEqual(s[1].rimTint, RippleField.echoRimTint)
        XCTAssertNotEqual(RippleField.rimTint, RippleField.echoRimTint)
        XCTAssertGreaterThan(s[0].rim, 0)
        XCTAssertEqual(s[0].rimRadius, s[0].radius)
        let plain = RippleField.sample(Ripple(kind: .ring, center: p, start: 0), at: 0.01)!
        XCTAssertLessThan(s[1].amplitude, plain.amplitude)
    }

    func testAtMostEightRipplesNewestKept() {
        var f = RippleField()
        for i in 0..<10 { f.spawn(.click, at: CGPoint(x: i, y: 0), now: Double(i) * 0.01, reduceMotion: false) }
        XCTAssertEqual(f.ripples.count, RippleField.maxCount)
        XCTAssertEqual(f.ripples.first?.center.x, 2)
        // The drag pulse takes one slot.
        f.setPulse(at: p, now: 0.1, reduceMotion: false)
        XCTAssertEqual(f.ripples.count, RippleField.maxCount - 1)
        XCTAssertLessThanOrEqual(f.samples(at: 0.12).count, RippleField.maxCount)
    }

    func testDragPulsePersistsFollowsAndStops() {
        var f = RippleField()
        f.setPulse(at: p, now: 0, reduceMotion: false)
        XCTAssertTrue(f.isAnimating(at: 100))
        XCTAssertEqual(f.samples(at: 100).count, 1)
        f.movePulse(to: CGPoint(x: 5, y: 6))
        XCTAssertEqual(f.samples(at: 101).first?.center, CGPoint(x: 5, y: 6))
        // Radii repeat with the period.
        XCTAssertEqual(f.samples(at: 0.3)[0].radius, f.samples(at: 0.3 + RippleField.pulsePeriod)[0].radius,
                       accuracy: 1e-6)
        f.setPulse(at: nil, now: 102, reduceMotion: false)
        XCTAssertTrue(f.isEmpty)
        XCTAssertFalse(f.isAnimating(at: 102))
    }

    func testDragPulseHasAStrongerBreathingTintedRim() {
        var f = RippleField()
        f.setPulse(at: p, now: 0, reduceMotion: false)
        let rims = stride(from: 0.0, to: RippleField.pulsePeriod, by: 0.05).map { f.samples(at: $0)[0] }
        for s in rims {
            XCTAssertTrue(RippleField.pulseRimAlpha.contains(s.rim))
            XCTAssertEqual(s.rimTint, RippleField.rimTint)
            XCTAssertGreaterThan(s.rimGlow, 0)
            XCTAssertEqual(s.rimRadius, RippleField.pulseRimRadius, accuracy: RippleField.pulseRimBreath + 1e-6)
        }
        // It breathes, and is always stronger than a click's rim at birth.
        XCTAssertGreaterThan(rims.map(\.rim).max()! - rims.map(\.rim).min()!, 0.1)
        XCTAssertGreaterThan(rims.map(\.rim).min()!, RippleField.clickRimAlpha)
    }

    func testDragPulseTakesTheButtonsTintAndKeepsItWhileMoving() {
        var f = RippleField()
        f.setPulse(at: p, now: 0, reduceMotion: false, tint: DragIndicatorTint.right)
        XCTAssertEqual(f.samples(at: 0.2)[0].rimTint, DragIndicatorTint.right)
        f.movePulse(to: CGPoint(x: 9, y: 9))
        XCTAssertEqual(f.samples(at: 0.4)[0].rimTint, DragIndicatorTint.right)
        // Re-set while on: the tint follows (a new drag's button).
        f.setPulse(at: p, now: 0.5, reduceMotion: false, tint: DragIndicatorTint.middle)
        XCTAssertEqual(f.samples(at: 0.6)[0].rimTint, DragIndicatorTint.middle)
        // Reduce Motion keeps the tint too.
        var r = RippleField()
        r.setPulse(at: p, now: 0, reduceMotion: true, tint: DragIndicatorTint.middle)
        XCTAssertEqual(r.samples(at: 1)[0].rimTint, DragIndicatorTint.middle)
    }

    func testIndicatorTintsAreBlueRedGreenByButton() {
        XCTAssertEqual(DragIndicatorTint.rgb(for: InputController.Button.left), DragIndicatorTint.left)
        XCTAssertEqual(DragIndicatorTint.rgb(for: InputController.Button.right), DragIndicatorTint.right)
        XCTAssertEqual(DragIndicatorTint.rgb(for: InputController.Button.middle), DragIndicatorTint.middle)
        // Blue, red, green: the dominant channel.
        XCTAssertGreaterThan(DragIndicatorTint.left.z, max(DragIndicatorTint.left.x, DragIndicatorTint.left.y))
        XCTAssertGreaterThan(DragIndicatorTint.right.x, max(DragIndicatorTint.right.y, DragIndicatorTint.right.z))
        XCTAssertGreaterThan(DragIndicatorTint.middle.y, max(DragIndicatorTint.middle.x, DragIndicatorTint.middle.z))
    }

    func testReduceMotionGivesInPlaceFadesWithoutDistortion() {
        for v in [RippleVariant.click, .doubleClick, .rightClick] {
            var f = RippleField()
            f.spawn(v, at: p, now: 0, reduceMotion: true)
            XCTAssertEqual(f.ripples.count, 1, "\(v)")
            let a = f.samples(at: 0.01)[0], b = f.samples(at: 0.2)[0]
            XCTAssertEqual(a.amplitude, 0)
            XCTAssertEqual(a.radius, b.radius)                    // no growth
            XCTAssertGreaterThan(a.highlight, b.highlight)        // a fade
        }
        // A reduced pulse is static: drawn, but costs no frames.
        var f = RippleField()
        f.setPulse(at: p, now: 0, reduceMotion: true)
        XCTAssertFalse(f.isAnimating(at: 1))
        XCTAssertEqual(f.samples(at: 1).first?.amplitude, 0)
        XCTAssertEqual(f.samples(at: 1), f.samples(at: 2))                // static
        XCTAssertGreaterThan(f.samples(at: 1).first?.rim ?? 0, 0)         // a tinted ring
    }
}

// MARK: cursor halo / trail

final class CursorEffectsTests: XCTestCase {
    func testHaloScalesUpThenSettles() {
        var c = CursorEffects()
        c.halo(now: 0, reduceMotion: false)
        XCTAssertTrue(c.isAnimating(at: 0))
        XCTAssertEqual(c.haloScale(at: CursorEffects.haloRise), CursorEffects.haloPeak, accuracy: 1e-6)
        XCTAssertGreaterThan(c.haloScale(at: 0.15), 1)
        XCTAssertLessThan(c.haloScale(at: 0.15), CursorEffects.haloPeak)
        XCTAssertEqual(c.haloScale(at: CursorEffects.haloDuration), 1)
        XCTAssertFalse(c.isAnimating(at: CursorEffects.haloDuration))
    }

    func testReduceMotionHaloGlowsWithoutScaling() {
        var c = CursorEffects()
        c.halo(now: 0, reduceMotion: true)
        XCTAssertEqual(c.haloScale(at: CursorEffects.haloRise), 1)
        XCTAssertGreaterThan(c.haloEnvelope(at: CursorEffects.haloRise), 0.9)
    }

    func testTrailOnlyOnFastMovesAndFades() {
        var c = CursorEffects()
        // Slow: 2 pt per 1/60 s = 120 pt/s.
        for i in 0..<10 { c.moved(to: CGPoint(x: Double(i) * 2, y: 0), now: Double(i) / 60, reduceMotion: false) }
        XCTAssertTrue(c.ghosts.isEmpty)
        // Fast: 30 pt per 1/60 s = 1800 pt/s.
        let t0 = 1.0
        for i in 0..<10 { c.moved(to: CGPoint(x: Double(i) * 30, y: 0), now: t0 + Double(i) / 60, reduceMotion: false) }
        XCTAssertEqual(c.ghosts.count, CursorEffects.maxGhosts)
        let now = t0 + 9.0 / 60
        let g = c.visibleGhosts(at: now)
        XCTAssertFalse(g.isEmpty)
        XCTAssertTrue(g.allSatisfy { $0.alpha > 0 && $0.alpha <= CursorEffects.ghostAlpha })
        XCTAssertTrue(c.isAnimating(at: now))
        XCTAssertTrue(c.visibleGhosts(at: now + CursorEffects.trailLifetime).isEmpty)
        XCTAssertFalse(c.isAnimating(at: now + CursorEffects.trailLifetime))
        // Reduce Motion: no trail.
        var r = CursorEffects()
        for i in 0..<10 { r.moved(to: CGPoint(x: Double(i) * 30, y: 0), now: Double(i) / 60, reduceMotion: true) }
        XCTAssertTrue(r.ghosts.isEmpty)
    }
}

// MARK: feedback center

@MainActor
final class FeedbackCenterTests: XCTestCase {
    private var clock = FakeRepeatClock()

    private func make(visual: Bool = true, reduce: Bool = false) -> FeedbackCenter {
        clock = FakeRepeatClock()
        let c = FeedbackCenter(schedule: clock.schedule)
        c.now = { [unowned self] in self.clock.now }
        c.visualEnabled = { visual }
        c.reduceMotion = { reduce }
        return c
    }

    func testClickRipplesAndAsksForFramesUntilDone() {
        let c = make()
        var redraws = 0
        c.onChange = { redraws += 1 }
        c.feedback(.click(at: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(redraws, 1)
        XCTAssertTrue(c.needsFrames(at: clock.now))
        XCTAssertEqual(c.gpuState(at: clock.now + 0.1).ripples.count, 1)
        XCTAssertGreaterThan(c.gpuState(at: clock.now + 0.1).ripples[0].amplitude, 0)
        XCTAssertFalse(c.needsFrames(at: clock.now + RippleField.ringDuration + 0.05))
        XCTAssertTrue(c.gpuState(at: clock.now + RippleField.ringDuration + 0.05).isEmpty)
    }

    func testDragBeganStartsThePulseAndDragEndedStopsIt() {
        let c = make()
        var redraws = 0
        c.onChange = { redraws += 1 }
        c.feedback(.dragBegan(at: CGPoint(x: 1, y: 1), button: InputController.Button.left))
        XCTAssertEqual(redraws, 1)
        XCTAssertTrue(c.needsFrames(at: clock.now + 5))
        c.feedback(.cursorMoved(to: CGPoint(x: 20, y: 30)))
        XCTAssertEqual(c.gpuState(at: clock.now + 0.2).ripples.last?.center, CGPoint(x: 20, y: 30))
        c.feedback(.dragEnded)
        XCTAssertFalse(c.needsFrames(at: clock.now + 5))
        XCTAssertTrue(c.gpuState(at: clock.now + 5).isEmpty)
    }

    func testVisualOffDisablesRipplesHaloTrailAndScrollPill() {
        let c = make(visual: false)
        var redraws = 0
        c.onChange = { redraws += 1 }
        c.feedback(.click(at: .zero))
        c.feedback(.rightClick(at: .zero))
        c.feedback(.dragBegan(at: .zero, button: InputController.Button.right))
        c.feedback(.fingerDown)
        c.feedback(.scrolled(dy: 10))
        XCTAssertEqual(redraws, 0)
        XCTAssertTrue(c.gpuState(at: clock.now).isEmpty)
        XCTAssertFalse(c.needsFrames(at: clock.now))
        XCTAssertNil(c.scrollPill)
        // Informational HUDs stay.
        c.feedback(.zoomChanged(scale: 2))
        XCTAssertEqual(c.zoomPill, 2)
        c.feedback(.holdBegan(at: .zero, duration: 0.5, button: InputController.Button.middle))
        XCTAssertNotNil(c.hold, "the hold ring is informational: shown with visual feedback off")
    }

    func testReduceMotionHasNoDistortionOrHaloScale() {
        let c = make(reduce: true)
        c.feedback(.click(at: CGPoint(x: 5, y: 5)))
        c.feedback(.fingerDown)
        let s = c.gpuState(at: clock.now + CursorEffects.haloRise)
        XCTAssertEqual(s.ripples.count, 1)
        XCTAssertEqual(s.ripples[0].amplitude, 0)
        XCTAssertGreaterThan(s.ripples[0].highlight, 0)
        XCTAssertEqual(s.haloScale, 1)
        XCTAssertGreaterThan(s.haloGlow, 0)
    }

    func testZoomPillFadesOneSecondAfterTheLastChange() {
        let c = make()
        c.feedback(.zoomChanged(scale: 1.5))
        clock.advance(by: 0.6)
        c.feedback(.zoomChanged(scale: 2.4))
        XCTAssertEqual(c.zoomPill, 2.4)
        clock.advance(by: 0.5)                      // 1.1 s after the first
        XCTAssertEqual(c.zoomPill, 2.4)
        clock.advance(by: 0.55)                     // 1.05 s after the last
        XCTAssertNil(c.zoomPill)
    }

    func testMinimapFadesAfterIdleEvenWhileStillZoomed() {
        let c = make()
        let map = FeedbackCenter.Minimap(aspect: 1.6, viewport: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        c.setMinimap(map)                           // zoomed in
        XCTAssertTrue(c.minimapShown)
        clock.advance(by: FeedbackCenter.minimapLinger - 0.5)
        c.setMinimap(map)                           // same view, every frame: not activity
        XCTAssertTrue(c.minimapShown)
        clock.advance(by: 0.51)
        XCTAssertFalse(c.minimapShown)              // faded...
        XCTAssertNotNil(c.minimap)                  // ...though still zoomed
    }

    func testPanOrZoomBringsTheMinimapBackThenItFadesAgain() {
        let c = make()
        var map = FeedbackCenter.Minimap(aspect: 1.6, viewport: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        c.setMinimap(map)
        clock.advance(by: FeedbackCenter.minimapLinger + 0.01)
        XCTAssertFalse(c.minimapShown)
        map.viewport.origin.x = 0.3                 // a pan
        c.setMinimap(map)
        XCTAssertTrue(c.minimapShown)
        clock.advance(by: 2)
        c.feedback(.zoomChanged(scale: 2.5))        // a pinch restarts the fade
        clock.advance(by: 2)
        XCTAssertTrue(c.minimapShown)
        clock.advance(by: FeedbackCenter.minimapLinger - 2 + 0.01)
        XCTAssertFalse(c.minimapShown)
        c.wakeMinimap()                             // a touch on it
        XCTAssertTrue(c.minimapShown)
    }

    func testUnzoomingHidesTheMinimapAndZoomAloneDoesNotShowIt() {
        let c = make()
        c.feedback(.zoomChanged(scale: 1.2))        // before the renderer reports the zoom
        XCTAssertFalse(c.minimapShown)
        c.setMinimap(.init(aspect: 1.6, viewport: CGRect(x: 0, y: 0, width: 0.8, height: 0.8)))
        XCTAssertTrue(c.minimapShown)
        c.setMinimap(nil)
        XCTAssertFalse(c.minimapShown)
        XCTAssertNil(c.minimap)
        clock.advance(by: FeedbackCenter.minimapLinger + 1)
        XCTAssertFalse(c.minimapShown)
    }

    func testScrollPillMovesWithTravelAndFades() {
        let c = make()
        c.feedback(.scrolled(dy: -100))             // fingers up: content scrolls down
        let a = try! XCTUnwrap(c.scrollPill)
        XCTAssertGreaterThan(a, 0.5)
        c.feedback(.scrolled(dy: 300))
        XCTAssertLessThan(c.scrollPill!, 0.5)
        c.feedback(.scrollEnded)
        clock.advance(by: FeedbackCenter.scrollPillLinger + 0.01)
        XCTAssertNil(c.scrollPill)
    }

    func testHoldRingCancelsAtOnceAndFlashesWhenFired() {
        let c = make()
        c.feedback(.holdBegan(at: CGPoint(x: 3, y: 4), duration: 0.45, button: InputController.Button.right))
        XCTAssertEqual(c.hold?.point, CGPoint(x: 3, y: 4))
        XCTAssertEqual(c.hold?.button, InputController.Button.right)
        XCTAssertEqual(c.hold?.duration, 0.45)
        c.feedback(.holdEnded(fired: false))
        XCTAssertNil(c.hold)
        c.feedback(.holdBegan(at: .zero, duration: 0.45, button: InputController.Button.left))
        c.feedback(.holdEnded(fired: true))
        XCTAssertEqual(c.hold?.fired, true)
        clock.advance(by: FeedbackCenter.holdFlash + 0.01)
        XCTAssertNil(c.hold)
    }

    func testANewHoldDuringTheFlashReplacesIt() {
        let c = make()
        c.feedback(.holdBegan(at: .zero, duration: 0.45, button: InputController.Button.left))
        c.feedback(.holdEnded(fired: true))
        c.feedback(.holdBegan(at: CGPoint(x: 8, y: 8), duration: 0.45, button: InputController.Button.middle))
        clock.advance(by: FeedbackCenter.holdFlash + 0.01)
        XCTAssertEqual(c.hold?.button, InputController.Button.middle, "the old flash's timer doesn't clear it")
        XCTAssertEqual(c.hold?.fired, false)
    }

    func testDragPulseIsTintedByButtonAndFollowsTheCursorUntilEnded() {
        let c = make()
        c.feedback(.dragBegan(at: CGPoint(x: 1, y: 1), button: InputController.Button.middle))
        c.feedback(.cursorMoved(to: CGPoint(x: 50, y: 60)))
        let s = c.gpuState(at: clock.now + 0.2).ripples.last
        XCTAssertEqual(s?.center, CGPoint(x: 50, y: 60))
        XCTAssertEqual(s?.rimTint, DragIndicatorTint.middle)
        XCTAssertTrue(c.needsFrames(at: clock.now + 5))
        c.feedback(.dragEnded)
        XCTAssertFalse(c.needsFrames(at: clock.now + 5))
    }
}

// MARK: gesture → cue / event emission

@MainActor
final class FeedbackCueTests: XCTestCase {
    private var clock = FakeRepeatClock()
    private var cues: [TouchCue] = []
    private var zoomed = false
    private let L = InputController.Button.left
    private let R = InputController.Button.right
    private let M = InputController.Button.middle

    private func make(_ mode: TouchInputMode = .trackpad) -> TouchInterpreter {
        clock = FakeRepeatClock()
        cues = []
        zoomed = false
        let t = TouchInterpreter(schedule: clock.schedule) { _ in }
        t.mode = mode
        t.isZoomed = { [weak self] in self?.zoomed ?? false }
        t.onCue = { [weak self] in self?.cues.append($0) }
        return t
    }

    private func at(_ dt: TimeInterval) -> TimeInterval {
        clock.advance(by: dt)
        return clock.now
    }

    private static func isHold(_ c: TouchCue) -> Bool {
        switch c {
        case .holdArmed, .holdFired, .holdCancelled: true
        default: false
        }
    }

    /// The cues without the hold ring's (armed / fired / cancelled).
    private var plain: [TouchCue] { cues.filter { !Self.isHold($0) } }

    /// The ripple cue fires the moment the tap is recognised (touch-up); the
    /// actual click (haptic + button, TouchAction, tested in
    /// TrackpadModeTests) still waits for the tap-drag window.
    func testTrackpadTapRippleFiresAtTouchUpBeforeTheClickIsSent() {
        let t = make()
        t.began(1, at: CGPoint(x: 10, y: 10), time: at(0))
        t.ended(1, at: CGPoint(x: 10, y: 10), time: at(0.1))
        XCTAssertEqual(plain, [.fingerDown, .click(button: L, count: 1)], "the ripple cue, right away")
        _ = at(TouchInterpreter.Tuning.tapDragWindow + 0.01)
        XCTAssertEqual(plain, [.fingerDown, .click(button: L, count: 1)], "no second cue once the click is sent")
        XCTAssertEqual(cues.filter(Self.isHold), [
            .holdArmed(at: nil, duration: TouchInterpreter.Tuning.holdDelay, button: L), .holdCancelled,
        ], "the hold armed at the touch and was dropped by the tap")
    }

    /// Each tap of a double tap rings on its own touch-up: the first tap's
    /// ring, then the second's — together, the double-click look.
    func testTrackpadDoubleTapRipplesOnceAtEachTap() {
        let t = make()
        t.began(1, at: .zero, time: at(0))
        t.ended(1, at: .zero, time: at(0.08))
        XCTAssertEqual(plain, [.fingerDown, .click(button: L, count: 1)], "the first tap's ring, immediately")
        t.began(2, at: .zero, time: at(0.1))
        t.ended(2, at: .zero, time: at(0.08))
        XCTAssertEqual(plain, [.fingerDown, .click(button: L, count: 1), .fingerDown, .click(button: L, count: 1)])
        _ = at(1)
        XCTAssertEqual(plain.count, 4, "no further cue once both clicks are actually sent")
    }

    /// The first tap's ring already fired at its touch-up (its click was
    /// never sent); the drag just adds its own pulse on top.
    func testTrackpadTapDragIsADragStart() {
        let t = make()
        t.began(1, at: .zero, time: at(0))
        t.ended(1, at: .zero, time: at(0.08))
        t.began(2, at: .zero, time: at(0.1))
        t.moved(2, to: CGPoint(x: 40, y: 0), time: at(0.05))
        XCTAssertEqual(plain, [.fingerDown, .click(button: L, count: 1), .fingerDown, .dragBegan(button: L)])
    }

    func testTrackpadTapDragEndsWithDragEndedOnLift() {
        let t = make()
        t.began(1, at: .zero, time: at(0))
        t.ended(1, at: .zero, time: at(0.08))
        t.began(2, at: .zero, time: at(0.1))
        t.moved(2, to: CGPoint(x: 40, y: 0), time: at(0.05))
        t.ended(2, at: CGPoint(x: 40, y: 0), time: at(0.1))
        XCTAssertEqual(cues.last, .dragEnded)
    }

    func testTwoFingerTapIsARightClick() {
        let t = make()
        t.began(1, at: CGPoint(x: 10, y: 10), time: at(0))
        t.began(2, at: CGPoint(x: 60, y: 10), time: at(0.01))
        t.ended(1, at: CGPoint(x: 10, y: 10), time: at(0.1))
        t.ended(2, at: CGPoint(x: 60, y: 10), time: at(0.01))
        XCTAssertEqual(cues.last, .click(button: R, count: 1))
    }

    /// Zoomed, a two-finger tap's right-click ripple also fires at
    /// recognition, even though the click itself waits for a possible
    /// second two-finger tap (zoom reset).
    func testZoomedTwoFingerTapRippleFiresAtRecognition() {
        let t = make()
        zoomed = true
        t.began(1, at: CGPoint(x: 10, y: 10), time: at(0))
        t.began(2, at: CGPoint(x: 60, y: 10), time: at(0.01))
        t.ended(1, at: CGPoint(x: 10, y: 10), time: at(0.1))
        t.ended(2, at: CGPoint(x: 60, y: 10), time: at(0.01))
        XCTAssertEqual(cues.last, .click(button: R, count: 1), "the ripple, right away")
        _ = at(TouchInterpreter.Tuning.tapDragWindow + 0.01)
        XCTAssertEqual(cues.filter { $0 == .click(button: R, count: 1) }.count, 1, "no second cue when it's sent")
    }

    func testTrackpadHoldArmsAtTheCursorFiresAndShowsTheDragIndicator() {
        let t = make()
        t.began(1, at: CGPoint(x: 30, y: 40), time: at(0))
        XCTAssertEqual(cues, [.fingerDown, .holdArmed(at: nil, duration: TouchInterpreter.Tuning.holdDelay, button: L)])
        _ = at(TouchInterpreter.Tuning.holdDelay + 0.01)
        XCTAssertEqual(Array(cues.suffix(2)), [.holdFired, .dragBegan(button: L)])
        t.moved(1, to: CGPoint(x: 80, y: 40), time: at(0.05))
        XCTAssertEqual(cues.count, 4, "pressing the button on the move adds no cue")
        t.ended(1, at: CGPoint(x: 80, y: 40), time: at(0.05))
        XCTAssertEqual(cues.last, .dragEnded)
    }

    func testAStillHoldReleasedEndsTheIndicator() {
        let t = make()
        t.began(1, at: .zero, time: at(0))
        _ = at(1)
        t.ended(1, at: .zero, time: at(0.05))
        XCTAssertEqual(Array(cues.suffix(3)), [.holdFired, .dragBegan(button: L), .dragEnded])
    }

    func testTwoFingerHoldIsARedRightDragIndicator() {
        let t = make()
        t.began(1, at: CGPoint(x: 10, y: 10), time: at(0))
        t.began(2, at: CGPoint(x: 60, y: 10), time: at(0.02))
        XCTAssertEqual(Array(cues.suffix(2)), [
            .holdCancelled, .holdArmed(at: nil, duration: TouchInterpreter.Tuning.holdDelay, button: R),
        ], "the one-finger hold gives way to the two-finger one")
        _ = at(TouchInterpreter.Tuning.holdDelay + 0.01)
        XCTAssertEqual(Array(cues.suffix(2)), [.holdFired, .dragBegan(button: R)])
    }

    func testThreeFingerHoldIsAGreenMiddleDragIndicator() {
        let t = make()
        for (i, x) in [10.0, 40, 70].enumerated() { t.began(i, at: CGPoint(x: x, y: 10), time: at(0.01)) }
        XCTAssertEqual(cues.last, .holdArmed(at: nil, duration: TouchInterpreter.Tuning.holdDelay, button: M))
        _ = at(TouchInterpreter.Tuning.holdDelay + 0.01)
        XCTAssertEqual(Array(cues.suffix(2)), [.holdFired, .dragBegan(button: M)])
        t.cancel()
        XCTAssertEqual(cues.last, .dragEnded)
    }

    func testDirectHoldArmsAtTheFingersCentroid() {
        let t = make(.direct)
        t.began(1, at: CGPoint(x: 100, y: 100), time: at(0))
        XCTAssertEqual(cues, [.holdArmed(at: CGPoint(x: 100, y: 100), duration: TouchInterpreter.Tuning.holdDelay,
                                         button: L)])
        t.began(2, at: CGPoint(x: 200, y: 100), time: at(0.02))
        XCTAssertEqual(cues.last, .holdArmed(at: CGPoint(x: 150, y: 100), duration: TouchInterpreter.Tuning.holdDelay,
                                             button: R))
    }

    func testHoldCueUsesTheConfiguredDelay() {
        let t = make()
        t.holdDelay = HoldDragDelay.long.seconds
        t.began(1, at: .zero, time: at(0))
        XCTAssertEqual(cues.last, .holdArmed(at: nil, duration: 0.6, button: L))
    }

    func testScrollCancelsTheTwoFingerHold() {
        let t = make()
        t.began(1, at: CGPoint(x: 10, y: 10), time: at(0))
        t.began(2, at: CGPoint(x: 60, y: 10), time: at(0.01))
        t.moved([1: CGPoint(x: 10, y: 50), 2: CGPoint(x: 60, y: 50)], time: at(0.05))
        XCTAssertEqual(cues.last, .holdCancelled)
        _ = at(1)
        XCTAssertFalse(cues.contains(.holdFired))
    }

    func testThreeFingerTapIsAMiddleClick() {
        let t = make()
        for (i, x) in [10.0, 40, 70].enumerated() { t.began(i, at: CGPoint(x: x, y: 10), time: at(0.01)) }
        for i in 0..<3 { t.ended(i, at: .zero, time: at(0.02)) }
        XCTAssertEqual(cues.last, .click(button: M, count: 1))
    }

    func testDirectTouchDragIsALeftDragIndicator() {
        let t = make(.direct)
        t.began(1, at: .zero, time: at(0))
        t.moved(1, to: CGPoint(x: 30, y: 0), time: at(0.1))
        XCTAssertEqual(Array(cues.dropFirst()), [.holdCancelled, .dragBegan(button: L)])
        _ = at(1)                                        // the timer never fires
        XCTAssertEqual(cues.count, 3)
    }

    func testDirectTapCancelsTheHoldAndClicks() {
        let t = make(.direct)
        t.began(1, at: .zero, time: at(0))
        t.ended(1, at: .zero, time: at(0.1))
        XCTAssertEqual(Array(cues.dropFirst()), [.holdCancelled, .click(button: L, count: 1)])
    }

    func testDirectHoldThenMoveKeepsOneIndicator() {
        let t = make(.direct)
        t.began(1, at: .zero, time: at(0))
        _ = at(0.6)
        t.moved(1, to: CGPoint(x: 30, y: 0), time: at(0.05))
        t.ended(1, at: CGPoint(x: 30, y: 0), time: at(0.1))
        XCTAssertEqual(Array(cues.dropFirst()), [.holdFired, .dragBegan(button: L), .dragEnded])
    }
}

/// RemoteInputView: cues and its own work → FeedbackEvents at the cursor.
@MainActor
final class FeedbackEmissionTests: XCTestCase {
    final class Recorder: FeedbackSink {
        var events: [FeedbackEvent] = []
        func feedback(_ event: FeedbackEvent) { events.append(event) }
    }

    private var clock = FakeRepeatClock()

    /// A 200×100 view over a 200×100 host.
    private func make() -> (RemoteInputView, Recorder) {
        clock = FakeRepeatClock()
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), repeatSchedule: clock.schedule)
        view.input = InputController(contentKey: nil, serverWidth: 200, serverHeight: 100, send: { _ in })
        let r = Recorder()
        view.feedback = r
        return (view, r)
    }

    func testClicksAreReportedAtTheCursorInBasePoints() throws {
        let (view, r) = make()
        view.perform(.moveTo(CGPoint(x: 50, y: 40)))
        let p = try XCTUnwrap(view.cursorBasePoint)
        XCTAssertEqual(p.x, 50.5, accuracy: 0.01)
        view.handleCue(.click(button: InputController.Button.left, count: 1))
        view.handleCue(.click(button: InputController.Button.left, count: 2))
        view.handleCue(.click(button: InputController.Button.right, count: 1))
        view.handleCue(.click(button: InputController.Button.middle, count: 1))
        view.handleCue(.dragBegan(button: InputController.Button.right))
        view.handleCue(.dragEnded)
        view.handleCue(.fingerDown)
        XCTAssertEqual(r.events, [.click(at: p), .doubleClick(at: p), .rightClick(at: p), .click(at: p),
                                  .dragBegan(at: p, button: InputController.Button.right), .dragEnded, .fingerDown])
    }

    func testZoomedClicksStillReportTheUnzoomedPoint() throws {
        let (view, r) = make()
        view.perform(.zoom(factor: 2, center: CGPoint(x: 100, y: 50), pan: .zero))
        XCTAssertEqual(r.events, [.zoomChanged(scale: 2)])
        view.perform(.moveTo(CGPoint(x: 100, y: 50)))     // screen centre = base centre at 2× about it
        view.handleCue(.click(button: InputController.Button.left, count: 1))
        guard case .click(let p) = r.events.last else { return XCTFail("\(r.events)") }
        XCTAssertEqual(p.x, 100, accuracy: 1)
        XCTAssertEqual(p.y, 50, accuracy: 1)
        view.perform(.resetZoom)
        XCTAssertEqual(r.events.last, .zoomChanged(scale: 1))
    }

    func testTrackpadMovesReportTheCursorAndScrollsReportSteps() {
        let (view, r) = make()
        view.perform(.moveBy(CGPoint(x: 10, y: 0)))
        guard case .cursorMoved = r.events.last else { return XCTFail("\(r.events)") }
        view.perform(.scroll(CGPoint(x: 0, y: 12)))
        XCTAssertEqual(r.events.last, .scrolled(dy: 12))
        view.perform(.scrollEnded(velocity: .zero))          // too slow for momentum
        XCTAssertEqual(r.events.last, .scrollEnded)
        view.perform(.scrollEnded(velocity: CGPoint(x: 0, y: 900)))
        XCTAssertTrue(view.isCoasting)
        r.events = []
        view.stopInertia()
        XCTAssertEqual(r.events, [.scrollEnded])
    }

    func testHoldCuesPassThroughAtTheFingersOrTheCursor() throws {
        let (view, r) = make()
        // Touch mode: at the fingers.
        view.handleCue(.holdArmed(at: CGPoint(x: 5, y: 6), duration: 0.45, button: InputController.Button.right))
        view.handleCue(.holdFired)
        view.handleCue(.holdCancelled)
        XCTAssertEqual(r.events, [.holdBegan(at: CGPoint(x: 5, y: 6), duration: 0.45, button: InputController.Button.right),
                                  .holdEnded(fired: true), .holdEnded(fired: false)])
        // Trackpad mode: at the cursor (SCREEN).
        r.events = []
        view.perform(.moveTo(CGPoint(x: 50, y: 40)))
        let cursor = try XCTUnwrap(view.cursorViewPoint)
        view.handleCue(.holdArmed(at: nil, duration: 0.3, button: InputController.Button.middle))
        XCTAssertEqual(r.events, [.holdBegan(at: cursor, duration: 0.3, button: InputController.Button.middle)])
    }

    func testMinimapJumpCentresTheViewport() {
        let (view, _) = make()
        view.perform(.zoom(factor: 2, center: CGPoint(x: 100, y: 50), pan: .zero))
        view.jumpViewport(toContentUnit: CGPoint(x: 0, y: 0))
        XCTAssertEqual(view.viewport.value.origin, .zero)            // clamped at the corner
        view.jumpViewport(toContentUnit: CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(view.viewport.value.origin.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(view.viewport.value.origin.y, 0.25, accuracy: 1e-6)
    }
}

// MARK: minimap geometry

final class MinimapGeometryTests: XCTestCase {
    func testThumbnailSizeIsClampedWhateverTheLayoutAspect() {
        // Security review L7: the aspect comes from the server's 0x451.
        XCTAssertEqual(MetalRenderer.thumbnailSize(canvas: CGSize(width: 2560, height: 1600)).height, 160)
        XCTAssertEqual(MetalRenderer.thumbnailSize(canvas: CGSize(width: 1, height: 65535)).height,
                       MetalRenderer.thumbnailMaxHeight)
        XCTAssertEqual(MetalRenderer.thumbnailSize(canvas: CGSize(width: 65535, height: 1)).height, 1)
        XCTAssertEqual(MetalRenderer.thumbnailSize(canvas: CGSize(width: 0, height: 100)).height, 1)
        XCTAssertEqual(MetalRenderer.thumbnailSize(canvas: CGSize(width: 1, height: 65535)).width,
                       MetalRenderer.thumbnailWidth)
    }

    func testViewportRectInContentUnits() {
        // 16:10 picture letterboxed in a 4:3 view: content spans y 0.0625…0.9375.
        let content = MinimapGeometry.unitContent(CGRect(x: 0, y: 48, width: 1024, height: 640),
                                                  viewSize: CGSize(width: 1024, height: 768))
        XCTAssertEqual(content.minY, 0.0625, accuracy: 1e-9)
        var v = Viewport()
        v.zoom(by: 2, around: CGPoint(x: 1024, y: 768), viewSize: CGSize(width: 1024, height: 768),
               content: CGRect(x: 0, y: 48, width: 1024, height: 640))
        let r = MinimapGeometry.viewportRect(visible: v.visibleUnitRect, content: content)
        XCTAssertEqual(r.maxX, 1, accuracy: 1e-9)                 // bottom-right corner
        XCTAssertEqual(r.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(r.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.height, 0.5 / (640.0 / 768), accuracy: 1e-9)
    }

    func testViewportRectClipsToThePicture() {
        let r = MinimapGeometry.viewportRect(visible: CGRect(x: -0.2, y: 0, width: 0.5, height: 0.5),
                                             content: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 0.3, height: 0.5))
        XCTAssertEqual(MinimapGeometry.viewportRect(visible: .zero, content: .zero), .zero)
    }

    func testContentPointClamps() {
        let s = CGSize(width: 200, height: 100)
        XCTAssertEqual(MinimapGeometry.contentPoint(CGPoint(x: 50, y: 25), minimapSize: s), CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(MinimapGeometry.contentPoint(CGPoint(x: -5, y: 500), minimapSize: s), CGPoint(x: 0, y: 1))
    }

    func testSizeKeepsTheAspectWithinTheBox() {
        XCTAssertEqual(MinimapGeometry.size(aspect: 16.0 / 10), CGSize(width: 200, height: 125))
        XCTAssertEqual(MinimapGeometry.size(aspect: 2), CGSize(width: 200, height: 100))
        XCTAssertEqual(MinimapGeometry.size(aspect: 1), CGSize(width: 130, height: 130))
    }

    func testViewportCenterClamps() {
        let size = CGSize(width: 100, height: 100), content = CGRect(x: 0, y: 0, width: 100, height: 100)
        var v = Viewport()
        v.center(on: CGPoint(x: 50, y: 50), viewSize: size, content: content)
        XCTAssertEqual(v, Viewport())                       // not zoomed: no-op
        v.zoom(by: 4, around: .zero, viewSize: size, content: content)
        v.center(on: CGPoint(x: 50, y: 50), viewSize: size, content: content)
        XCTAssertEqual(v.origin.x, 0.375, accuracy: 1e-9)
        v.center(on: CGPoint(x: 100, y: 100), viewSize: size, content: content)
        XCTAssertEqual(v.origin.x, 0.75, accuracy: 1e-9)
    }
}

// MARK: renderer

@MainActor
final class RippleRenderTests: XCTestCase {
    /// Where the rippled frame is written for eyeballing (best effort).
    static let pngPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("screener-ripple.png")

    func testRippleUniformsMapThroughZoomAndPixels() {
        let s = RippleSample(center: CGPoint(x: 50, y: 25), radius: 10, amplitude: 4, width: 6, highlight: 0.3,
                             tint: RippleField.echoTint, rim: 0.25, rimRadius: 11, rimWidth: 1.5, rimGlow: 0.125,
                             rimTint: RippleField.echoRimTint)
        var zoom = Viewport()
        zoom.zoom(by: 2, around: .zero, viewSize: CGSize(width: 200, height: 100),
                  content: CGRect(x: 0, y: 0, width: 200, height: 100))
        let u = MetalRenderer.rippleUniforms([s], size: CGSize(width: 400, height: 200), pixelsPerPoint: 2, zoom: zoom)
        XCTAssertEqual(MetalRenderer.rippleStride, 4)
        XCTAssertEqual(u.count, 1 + MetalRenderer.rippleStride * RippleField.maxCount)
        XCTAssertEqual(u[0], SIMD4(400, 200, 1, 0))
        // (50, 25) pt → (100, 50) px → ×2 about the origin → (200, 100).
        XCTAssertEqual(u[1], SIMD4(200, 100, 20, 8))
        XCTAssertEqual(u[2], SIMD4(12, 0.3, 0.25, 3))                      // rim width in pixels
        XCTAssertEqual(u[3], SIMD4(RippleField.echoTint, 0.125))
        XCTAssertEqual(u[4], SIMD4(RippleField.echoRimTint, 22))            // rim radius in pixels
        // At most maxCount ripples reach the shader.
        let many = MetalRenderer.rippleUniforms(Array(repeating: s, count: 12), size: CGSize(width: 1, height: 1),
                                                pixelsPerPoint: 1, zoom: .identity)
        XCTAssertEqual(many[0].z, Float(RippleField.maxCount))
    }

    /// A synthetic '444f' test pattern: a grid over colour bands.
    private func pattern(width w: Int, height h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                           attrs as CFDictionary, &pb), kCVReturnSuccess)
        let b = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(b, [])
        let bands: [(UInt8, UInt8)] = [(90, 200), (200, 90), (60, 110), (160, 160), (128, 128)]
        for row in 0..<h {
            let yp = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(b, 0))
                .assumingMemoryBound(to: UInt8.self)
            let cp = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(b, 1))
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let grid = x % 32 == 0 || row % 32 == 0 || x % 32 == 1 || row % 32 == 1
                let band = bands[x * bands.count / w]
                yp[x] = grid ? 235 : UInt8(70 + (row * 100 / h))
                cp[2 * x] = grid ? 128 : band.0
                cp[2 * x + 1] = grid ? 128 : band.1
            }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    private func render(_ renderer: MetalRenderer, frame: CVPixelBuffer, size: (Int, Int)) throws -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalRenderer.colorPixelFormat,
                                                            width: size.0, height: size.1, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: desc))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let cmd = try XCTUnwrap(queue.makeCommandBuffer())
        let snap = VideoFrameStore.Snapshot(version: 1, frames: [0: frame], tileCount: 1, canvas: nil)
        XCTAssertTrue(renderer.encode(snap, into: pass, size: CGSize(width: size.0, height: size.1), commandBuffer: cmd))
        let out = try XCTUnwrap(renderer.device.makeBuffer(length: size.0 * size.1 * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(cmd.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.0, height: size.1, depth: 1), to: out, destinationOffset: 0,
                  destinationBytesPerRow: size.0 * 4, destinationBytesPerImage: size.0 * size.1 * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: UInt8.self),
                                         count: size.0 * size.1 * 4))
    }

    func testRippleRefractsAroundTheRingOnlyAndLeavesTheRestUntouched() throws {
        let (w, h) = (640, 400)
        let frame = try pattern(width: w, height: h)
        let renderer = try XCTUnwrap(MetalRenderer(store: VideoFrameStore()))
        renderer.pixelsPerPoint = 1
        let plain = try render(renderer, frame: frame, size: (w, h))

        var t = 100.0
        let center = FeedbackCenter()
        center.now = { t }
        center.visualEnabled = { true }
        center.reduceMotion = { false }
        renderer.feedback = center
        center.feedback(.click(at: CGPoint(x: 160, y: 200)))
        center.feedback(.doubleClick(at: CGPoint(x: 330, y: 140)))
        center.feedback(.rightClick(at: CGPoint(x: 500, y: 270)))
        t += 0.17
        let rippled = try render(renderer, frame: frame, size: (w, h))
        try? Self.writePNG(rippled, width: w, height: h, to: Self.pngPath)

        func px(_ b: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { Array(b[(y * w + x) * 4 ..< (y * w + x) * 4 + 3]) }
        let r = RippleField.sample(Ripple(kind: .ring, center: .zero, start: 0), at: 0.17)!.radius
        var changed = 0
        for a in stride(from: 0.0, to: 2 * Double.pi, by: 0.2) {
            let x = Int(160 + cos(a) * Double(r)), y = Int(200 + sin(a) * Double(r))
            if px(plain, x, y) != px(rippled, x, y) { changed += 1 }
        }
        XCTAssertGreaterThan(changed, 20, "the ring crest is highlighted / displaced")
        // Far from every ripple: identical.
        XCTAssertEqual(px(plain, 20, 20), px(rippled, 20, 20))
        XCTAssertEqual(px(plain, 620, 20), px(rippled, 620, 20))

        // Reduce Motion: highlight only — nothing outside the crest moves.
        t += 1
        center.reduceMotion = { true }
        center.feedback(.click(at: CGPoint(x: 160, y: 200)))
        t += 0.05
        let faded = try render(renderer, frame: frame, size: (w, h))
        XCTAssertEqual(px(plain, 160, 200), px(faded, 160, 200))    // centre: no refraction
        XCTAssertNotEqual(px(plain, 184, 200), px(faded, 184, 200))  // on the ring: brighter

        // Once over, the frame is exactly the plain one.
        t += 1
        XCTAssertEqual(try render(renderer, frame: frame, size: (w, h)), plain)
    }

    static func writePNG(_ bgra: [UInt8], width: Int, height: Int, to path: String) throws {
        let data = Data(bgra) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: scroll speed (Settings)

@MainActor
final class ScrollSpeedTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        var n = 0
    }

    /// Messages sent for one 20-point touch scroll at `speed` (under the 50-tick cap).
    private func scrollMessages(speed: CGFloat) async -> Int {
        let counter = Counter()
        let input = InputController(contentKey: nil, serverWidth: 200, serverHeight: 100,
                                    send: { _ in counter.n += 1 })
        input.pointScale = 1
        input.scrollSpeed = speed
        let clock = FakeRepeatClock()
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), repeatSchedule: clock.schedule)
        view.input = input
        view.perform(.moveTo(CGPoint(x: 100, y: 50)))
        await input.flush()
        let before = counter.n
        view.perform(.scroll(CGPoint(x: 0, y: 20)))
        await input.flush()
        return counter.n - before
    }

    func testScrollSpeedScalesTouchScrolls() async {
        let base = await scrollMessages(speed: 1)
        XCTAssertEqual(base, 2 * 20)                      // 1 host px per point, press + release
        let fast = await scrollMessages(speed: 2)
        XCTAssertEqual(fast, 2 * base)
        let slow = await scrollMessages(speed: 0.5)
        XCTAssertEqual(slow, base / 2)
    }

    func testSessionReadsTheClampedSetting() {
        let d = UserDefaults(suiteName: "ScrollSpeedTests")!
        d.removePersistentDomain(forName: "ScrollSpeedTests")
        XCTAssertEqual(ScreenerSettings.scrollSpeed(d), 1)
        d.set(5.0, forKey: ScreenerSettings.scrollSpeedKey)
        XCTAssertEqual(ScreenerSettings.scrollSpeed(d), 2)
        XCTAssertEqual(InputController(contentKey: nil, serverWidth: 1, serverHeight: 1, send: { _ in }).scrollSpeed, 1)
    }
}
