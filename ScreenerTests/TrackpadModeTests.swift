import CoreGraphics
import XCTest
@testable import Screener

final class TrackpadAccelerationTests: XCTestCase {
    func testGainRisesFromOneToTwoAndAHalfWithSpeed() {
        XCTAssertEqual(TrackpadAcceleration.gain(speed: 0), 1)
        XCTAssertEqual(TrackpadAcceleration.gain(speed: TrackpadAcceleration.slowSpeed), 1)
        XCTAssertEqual(TrackpadAcceleration.gain(speed: TrackpadAcceleration.fastSpeed), 2.5, accuracy: 1e-9)
        XCTAssertEqual(TrackpadAcceleration.gain(speed: 1e6), 2.5)
        let mid = (TrackpadAcceleration.slowSpeed + TrackpadAcceleration.fastSpeed) / 2
        XCTAssertEqual(TrackpadAcceleration.gain(speed: mid), 1.75, accuracy: 1e-9)  // smoothstep midpoint
        var last: CGFloat = 0
        for speed in stride(from: 0.0, through: 3000, by: 25) {
            let g = TrackpadAcceleration.gain(speed: CGFloat(speed))
            XCTAssertGreaterThanOrEqual(g, last)
            last = g
        }
        XCTAssertEqual(TrackpadAcceleration.gain(speed: .nan), 1)
    }

    func testApplyScalesTheDeltaBySpeed() {
        // 2 pt in 1/60 s = 120 pt/s: slow, unchanged.
        XCTAssertEqual(TrackpadAcceleration.apply(CGPoint(x: 2, y: 0), dt: 1.0 / 60), CGPoint(x: 2, y: 0))
        // 40 pt in 1/60 s = 2400 pt/s: fast, ×2.5.
        let fast = TrackpadAcceleration.apply(CGPoint(x: 30, y: 40), dt: 1.0 / 60)
        XCTAssertEqual(fast.x, 75, accuracy: 1e-9)
        XCTAssertEqual(fast.y, 100, accuracy: 1e-9)
        XCTAssertEqual(TrackpadAcceleration.apply(CGPoint(x: 5, y: 5), dt: 0), CGPoint(x: 5, y: 5))
    }
}

/// TouchInterpreter: each gesture's action sequence (a recording fake sink,
/// a manual clock for its timers).
@MainActor
final class TrackpadModeTests: XCTestCase {
    private var clock = FakeRepeatClock()
    private var actions: [TouchAction] = []
    private var zoomed = false
    private let L = InputController.Button.left
    private let R = InputController.Button.right

    private func make(_ mode: TouchInputMode = .trackpad) -> TouchInterpreter {
        clock = FakeRepeatClock()
        actions = []
        let t = TouchInterpreter(schedule: clock.schedule) { [weak self] in self?.actions.append($0) }
        t.mode = mode
        t.isZoomed = { [weak self] in self?.zoomed ?? false }
        return t
    }

    /// Advances the clock, then returns the time.
    private func at(_ dt: TimeInterval) -> TimeInterval {
        clock.advance(by: dt)
        return clock.now
    }

    /// The actions, without the momentum/began bookkeeping and with moves merged.
    private var buttonsAndHaptics: [TouchAction] {
        actions.filter {
            switch $0 {
            case .button, .haptic, .resetZoom: true
            default: false
            }
        }
    }

    private func click(_ b: Int) -> [TouchAction] { [.button(b, down: true), .button(b, down: false)] }

    private func tap(_ t: TouchInterpreter, id: Int = 1, at p: CGPoint = CGPoint(x: 100, y: 100)) {
        t.began(id, at: p, time: clock.now)
        t.ended(id, at: p, time: at(0.08))
    }

    // MARK: trackpad

    func testDefaultModeIsTrackpad() {
        XCTAssertEqual(TouchInputMode.default, .trackpad)
        XCTAssertEqual(TouchInputMode.defaultsKey, "input.touchMode")
        XCTAssertEqual(TouchInterpreter(perform: { _ in }).mode, .trackpad)
    }

    func testOneFingerDragMovesTheCursorRelativelyWithoutButtons() {
        let t = make()
        t.began(1, at: CGPoint(x: 500, y: 500), time: clock.now)
        t.moved(1, to: CGPoint(x: 515, y: 500), time: at(0.05))      // past the slop: the full 15 pt
        t.moved(1, to: CGPoint(x: 517, y: 501), time: at(1.0 / 60))  // slow: gain 1
        t.ended(1, at: CGPoint(x: 517, y: 501), time: at(0.01))
        clock.advance(by: 1)
        XCTAssertEqual(actions, [.began, .moveBy(CGPoint(x: 15, y: 0)), .moveBy(CGPoint(x: 2, y: 1))])
    }

    func testFastFingerIsAccelerated() {
        let t = make()
        t.began(1, at: .zero, time: clock.now)
        t.moved(1, to: CGPoint(x: 20, y: 0), time: at(0.02))
        t.moved(1, to: CGPoint(x: 60, y: 0), time: at(1.0 / 60))     // 2400 pt/s
        XCTAssertEqual(actions.last, .moveBy(CGPoint(x: 100, y: 0)))
    }

    func testTapClicksAtTheCursorAfterTheTapDragWindow() {
        let t = make()
        tap(t, at: CGPoint(x: 900, y: 50))
        XCTAssertEqual(buttonsAndHaptics, [], "the click waits for a possible tap-drag")
        clock.advance(by: TouchInterpreter.Tuning.tapDragWindow + 0.01)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.light)] + click(L))
        XCTAssertFalse(actions.contains { if case .moveTo = $0 { true } else { false } }, "no absolute move")
    }

    func testLongStillTouchArmsADragButLiftingSendsNoClick() {
        let t = make()
        t.began(1, at: .zero, time: clock.now)
        t.ended(1, at: .zero, time: at(0.8))
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)], "the hold's haptic only: no button, no click")
    }

    func testTouchLiftedBeforeTheLongPressIsNotAClick() {
        let t = make()
        t.began(1, at: .zero, time: clock.now)
        t.ended(1, at: .zero, time: at(TouchInterpreter.Tuning.holdDelay - 0.1))
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [])
    }

    func testDoubleTapIsADoubleClick() {
        let t = make()
        tap(t)
        clock.advance(by: 0.1)
        tap(t, id: 2)
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.light)] + click(L) + click(L))
    }

    func testDoubleTapAndDragIsADragWithNoClickFirst() {
        let t = make()
        tap(t)
        clock.advance(by: 0.1)
        t.began(2, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.moved(2, to: CGPoint(x: 130, y: 100), time: at(0.05))
        t.moved(2, to: CGPoint(x: 131, y: 100), time: at(1.0 / 60))
        t.ended(2, at: CGPoint(x: 131, y: 100), time: at(0.01))
        clock.advance(by: 1)
        XCTAssertEqual(actions, [
            .began, .began, .haptic(.medium), .button(L, down: true),
            .moveBy(CGPoint(x: 30, y: 0)), .moveBy(CGPoint(x: 1, y: 0)), .button(L, down: false),
        ])
    }

    func testDoubleTapAndHoldStillStartsTheDrag() {
        let t = make()
        tap(t)
        clock.advance(by: 0.1)
        t.began(2, at: CGPoint(x: 100, y: 100), time: clock.now)
        clock.advance(by: TouchInterpreter.Tuning.tapMaxDuration + 0.01)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium), .button(L, down: true)])
        t.moved(2, to: CGPoint(x: 140, y: 100), time: at(0.05))
        t.ended(2, at: CGPoint(x: 140, y: 100), time: at(0.01))
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium), .button(L, down: true), .button(L, down: false)])
    }

    func testSecondTouchAfterTheWindowIsAPlainMove() {
        let t = make()
        tap(t)
        clock.advance(by: TouchInterpreter.Tuning.tapDragWindow + 0.05)  // click sent
        t.began(2, at: .zero, time: clock.now)
        t.moved(2, to: CGPoint(x: 40, y: 0), time: at(0.05))
        t.ended(2, at: CGPoint(x: 40, y: 0), time: at(0.01))
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.light)] + click(L))
    }

    func testTwoFingerTapIsARightClick() {
        let t = make()
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 160, y: 100), time: at(0.01))
        t.ended(1, at: CGPoint(x: 100, y: 100), time: at(0.07))
        t.ended(2, at: CGPoint(x: 160, y: 100), time: at(0.02))
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))
        XCTAssertFalse(actions.contains { if case .moveTo = $0 { true } else { false } },
                       "trackpad: at the cursor, not the fingers")
    }

    func testTwoFingerDragScrollsAndEndsWithVelocity() throws {
        let t = make()
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 200, y: 100), time: clock.now)
        var y: CGFloat = 100
        for _ in 0..<10 {
            y += 12
            t.moved([1: CGPoint(x: 100, y: y), 2: CGPoint(x: 200, y: y)], time: at(1.0 / 60))
        }
        t.ended(1, at: CGPoint(x: 100, y: y), time: clock.now)
        t.ended(2, at: CGPoint(x: 200, y: y), time: at(0.01))
        let scrolled = actions.reduce(CGFloat(0)) { if case .scroll(let d) = $1 { $0 + d.y } else { $0 } }
        XCTAssertEqual(scrolled, 120, accuracy: 1e-9)                  // every point of travel
        guard case .scrollEnded(let v)? = actions.last else { return XCTFail("\(actions)") }
        XCTAssertEqual(v.y, 720, accuracy: 1)                           // 12 pt per 1/60 s
        XCTAssertEqual(buttonsAndHaptics, [], "a scroll is not a click")
    }

    func testScrollThatStoppedBeforeLiftingHasNoMomentum() {
        let t = make()
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 200, y: 100), time: clock.now)
        t.moved([1: CGPoint(x: 100, y: 150), 2: CGPoint(x: 200, y: 150)], time: at(0.1))
        t.ended(1, at: CGPoint(x: 100, y: 150), time: at(0.5))
        XCTAssertEqual(actions.last, .scrollEnded(velocity: .zero))
    }

    func testFourFingersAreLeftToTheSystem() {
        let t = make()
        for id in 1...4 { t.began(id, at: CGPoint(x: id * 50, y: 0), time: clock.now) }
        t.moved([1: CGPoint(x: 50, y: 100), 2: CGPoint(x: 100, y: 100)], time: at(0.1))
        for id in 1...4 { t.ended(id, at: .zero, time: at(0.01)) }
        clock.advance(by: 1)
        XCTAssertEqual(actions, [.began])
    }

    // MARK: zoom (both modes)

    func testPinchZoomsAroundTheFingers() throws {
        for mode in TouchInputMode.allCases {
            let t = make(mode)
            t.began(1, at: CGPoint(x: 400, y: 300), time: clock.now)
            t.began(2, at: CGPoint(x: 500, y: 300), time: clock.now)
            t.moved([1: CGPoint(x: 380, y: 300), 2: CGPoint(x: 520, y: 300)], time: at(0.03))  // spread 140: pinch
            t.moved([1: CGPoint(x: 350, y: 300), 2: CGPoint(x: 560, y: 300)], time: at(0.03))  // 210
            let zooms = actions.compactMap { a -> (CGFloat, CGPoint, CGPoint)? in
                if case .zoom(let f, let c, let p) = a { (f, c, p) } else { nil }
            }
            XCTAssertEqual(zooms.count, 1, "\(mode)")
            XCTAssertEqual(zooms[0].0, 1.5, accuracy: 1e-9)
            XCTAssertEqual(zooms[0].1, CGPoint(x: 455, y: 300))
            XCTAssertEqual(zooms[0].2, CGPoint(x: 5, y: 0))
            for id in 1...2 { t.ended(id, at: .zero, time: at(0.01)) }
            XCTAssertEqual(buttonsAndHaptics, [], "\(mode): a pinch is not a click")
        }
    }

    func testTwoFingerDoubleTapResetsZoomWhenZoomed() {
        let t = make()
        zoomed = true
        for k in 0..<2 {
            t.began(1, at: CGPoint(x: 100, y: 100), time: at(k == 0 ? 0 : 0.1))
            t.began(2, at: CGPoint(x: 160, y: 100), time: clock.now)
            t.ended(1, at: .zero, time: at(0.06))
            t.ended(2, at: .zero, time: clock.now)
        }
        clock.advance(by: 1)
        XCTAssertEqual(buttonsAndHaptics, [.resetZoom], "no right click")
    }

    func testZoomedTwoFingerTapStillRightClicksAfterTheWindow() {
        let t = make()
        zoomed = true
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 160, y: 100), time: clock.now)
        t.ended(1, at: .zero, time: at(0.06))
        t.ended(2, at: .zero, time: clock.now)
        XCTAssertEqual(buttonsAndHaptics, [])
        clock.advance(by: TouchInterpreter.Tuning.tapDragWindow + 0.01)
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R))
    }

    func testZoomedRightClickIsSentBeforeAFollowingMove() {
        let t = make()
        zoomed = true
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 160, y: 100), time: clock.now)
        t.ended(1, at: .zero, time: at(0.06))
        t.ended(2, at: .zero, time: clock.now)
        t.began(3, at: .zero, time: at(0.05))
        t.moved(3, to: CGPoint(x: 30, y: 0), time: at(0.05))
        clock.advance(by: 1)
        XCTAssertEqual(Array(actions.suffix(4)), [.haptic(.medium)] + click(R) + [.moveBy(CGPoint(x: 30, y: 0))])
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium)] + click(R), "exactly one right click")
    }

    // MARK: direct

    func testDirectTapClicksAtTheTouch() {
        let t = make(.direct)
        tap(t, at: CGPoint(x: 321, y: 123))
        XCTAssertEqual(actions, [.began, .moveTo(CGPoint(x: 321, y: 123)), .haptic(.light)] + click(L))
    }

    func testDirectDragIsALeftDragFromTheTouchPoint() {
        let t = make(.direct)
        t.began(1, at: CGPoint(x: 10, y: 10), time: clock.now)
        t.moved(1, to: CGPoint(x: 40, y: 10), time: at(0.05))
        t.moved(1, to: CGPoint(x: 60, y: 20), time: at(0.02))
        t.ended(1, at: CGPoint(x: 60, y: 20), time: at(0.01))
        clock.advance(by: 1)
        XCTAssertEqual(actions, [
            .began, .moveTo(CGPoint(x: 10, y: 10)), .haptic(.medium), .button(L, down: true),
            .moveTo(CGPoint(x: 40, y: 10)), .moveTo(CGPoint(x: 60, y: 20)), .button(L, down: false),
        ])
    }

    func testDirectStillHoldReleasedDoesNothingMore() {
        let t = make(.direct)
        t.began(1, at: CGPoint(x: 70, y: 80), time: clock.now)
        clock.advance(by: TouchInterpreter.Tuning.holdDelay + 0.01)
        XCTAssertEqual(actions, [.began, .moveTo(CGPoint(x: 70, y: 80)), .haptic(.medium)])
        t.ended(1, at: CGPoint(x: 70, y: 80), time: clock.now)
        clock.advance(by: 1)
        XCTAssertEqual(actions.count, 3, "no right click (Screens: a hold arms a drag): \(actions)")
    }

    func testDirectLongPressThenMoveIsALeftDrag() {
        let t = make(.direct)
        t.began(1, at: CGPoint(x: 70, y: 80), time: clock.now)
        clock.advance(by: 0.6)
        t.moved(1, to: CGPoint(x: 120, y: 80), time: clock.now)
        t.ended(1, at: CGPoint(x: 120, y: 80), time: at(0.01))
        XCTAssertEqual(buttonsAndHaptics, [.haptic(.medium), .button(L, down: true), .button(L, down: false)])
    }

    func testDirectTwoFingerScrollStartsAtTheFingers() {
        let t = make(.direct)
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 200, y: 100), time: clock.now)
        t.moved([1: CGPoint(x: 100, y: 130), 2: CGPoint(x: 200, y: 130)], time: at(0.05))
        XCTAssertEqual(Array(actions.prefix(3)), [.began, .moveTo(CGPoint(x: 150, y: 100)),
                                                  .scroll(CGPoint(x: 0, y: 30))])
    }

    func testDirectTwoFingerTapRightClicksAtTheFingers() {
        let t = make(.direct)
        t.began(1, at: CGPoint(x: 100, y: 100), time: clock.now)
        t.began(2, at: CGPoint(x: 200, y: 100), time: clock.now)
        t.ended(1, at: .zero, time: at(0.05))
        t.ended(2, at: .zero, time: clock.now)
        XCTAssertEqual(actions, [.began, .moveTo(CGPoint(x: 150, y: 100)), .haptic(.medium)] + click(R))
    }

    func testPencilUsesDirectSemanticsInTrackpadMode() {
        let t = make(.trackpad)
        t.began(1, at: CGPoint(x: 5, y: 6), time: clock.now, pencil: true)
        t.ended(1, at: CGPoint(x: 5, y: 6), time: at(0.05))
        XCTAssertEqual(actions, [.began, .moveTo(CGPoint(x: 5, y: 6)), .haptic(.light)] + click(L))
    }

    // MARK: never left down

    func testModeSwitchReleasesAHoldDragAndDropsAPendingClick() {
        let t = make()
        tap(t)                                                    // click pending
        clock.advance(by: 0.1)
        // A two-finger hold-drag (right button).
        t.began(11, at: CGPoint(x: 40, y: 0), time: clock.now)
        t.began(12, at: CGPoint(x: 80, y: 0), time: clock.now)
        clock.advance(by: TouchInterpreter.Tuning.holdDelay + 0.01)
        t.moved([11: CGPoint(x: 40, y: 30), 12: CGPoint(x: 80, y: 30)], time: at(0.05))
        XCTAssertTrue(t.isHoldingButton)
        t.mode = .direct
        XCTAssertFalse(t.isHoldingButton)
        clock.advance(by: 1)
        for b in [L, R] {
            let downs = actions.filter { $0 == .button(b, down: true) }.count
            let ups = actions.filter { $0 == .button(b, down: false) }.count
            XCTAssertEqual(downs, ups, "\(b): \(actions)")
        }
        XCTAssertEqual(actions.filter { $0 == .button(R, down: false) }.count, 1)
        // The fingers still down when the mode switched are ignored.
        let n = actions.count
        t.moved([11: CGPoint(x: 40, y: 90), 12: CGPoint(x: 80, y: 90)], time: at(0.05))
        t.ended(11, at: .zero, time: clock.now)
        t.ended(12, at: .zero, time: clock.now)
        XCTAssertEqual(actions.count, n)
    }

    func testCancelledTouchReleasesTheDrag() {
        let t = make(.direct)
        t.began(1, at: .zero, time: clock.now)
        t.moved(1, to: CGPoint(x: 50, y: 0), time: at(0.05))
        t.cancelled(1)
        XCTAssertEqual(actions.last, .button(L, down: false))
        t.ended(1, at: .zero, time: at(0.01))                     // late end: nothing more
        XCTAssertEqual(actions.last, .button(L, down: false))
    }

    func testCancelReleasesADirectDrag() {
        let t = make(.direct)
        t.began(1, at: .zero, time: clock.now)
        t.moved(1, to: CGPoint(x: 50, y: 0), time: at(0.05))
        t.cancel()
        XCTAssertEqual(actions.last, .button(L, down: false))
    }
}

/// One-, two- and three-finger touch-and-hold drags (left / right / middle,
/// as Screens), three-finger taps and swipes, in both modes.
@MainActor
final class HoldGestureTests: XCTestCase {
    private var clock = FakeRepeatClock()
    private var actions: [TouchAction] = []
    private var cues: [TouchCue] = []
    private var zoomed = false
    private let L = InputController.Button.left
    private let R = InputController.Button.right
    private let M = InputController.Button.middle
    private let hold = TouchInterpreter.Tuning.holdDelay

    private func make(_ mode: TouchInputMode = .trackpad, holdDelay: TimeInterval? = nil) -> TouchInterpreter {
        clock = FakeRepeatClock()
        actions = []
        cues = []
        zoomed = false
        let t = TouchInterpreter(schedule: clock.schedule) { [weak self] in self?.actions.append($0) }
        t.mode = mode
        t.isZoomed = { [weak self] in self?.zoomed ?? false }
        t.onCue = { [weak self] in self?.cues.append($0) }
        if let holdDelay { t.holdDelay = holdDelay }
        return t
    }

    private func at(_ dt: TimeInterval) -> TimeInterval {
        clock.advance(by: dt)
        return clock.now
    }

    private var buttons: [TouchAction] {
        actions.filter { if case .button = $0 { true } else { false } }
    }

    private var chords: [KeyChord] {
        actions.compactMap { if case .keyChord(let c) = $0 { c } else { nil } }
    }

    private var moves: [TouchAction] {
        actions.filter {
            switch $0 {
            case .moveBy, .moveTo: true
            default: false
            }
        }
    }

    private func click(_ b: Int) -> [TouchAction] { [.button(b, down: true), .button(b, down: false)] }

    /// Every press has its release, per button.
    private func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
        for b in [L, R, M] {
            var down = false
            for a in actions {
                if a == .button(b, down: true) {
                    XCTAssertFalse(down, "\(b) pressed twice: \(actions)", file: file, line: line)
                    down = true
                } else if a == .button(b, down: false) {
                    down = false
                }
            }
            XCTAssertFalse(down, "\(b) left down: \(actions)", file: file, line: line)
        }
    }

    /// `n` fingers down at x = 100, 150, 200… (y 100), ids 1…n.
    private func down(_ t: TouchInterpreter, _ n: Int) {
        for i in 0..<n { t.began(i + 1, at: CGPoint(x: 100 + 50 * CGFloat(i), y: 100), time: clock.now) }
    }

    /// Moves all `n` fingers by `d` from their start.
    private func move(_ t: TouchInterpreter, _ n: Int, by d: CGPoint, dt: TimeInterval = 0.05) {
        var pts: [Int: CGPoint] = [:]
        for i in 0..<n { pts[i + 1] = CGPoint(x: 100 + 50 * CGFloat(i) + d.x, y: 100 + d.y) }
        t.moved(pts, time: at(dt))
    }

    private func up(_ t: TouchInterpreter, _ n: Int) {
        for i in 0..<n { t.ended(i + 1, at: .zero, time: at(0.01)) }
    }

    // MARK: settings

    func testHoldDelayPresets() {
        XCTAssertEqual(HoldDragDelay.short.seconds, 0.3)
        XCTAssertEqual(HoldDragDelay.normal.seconds, 0.45)
        XCTAssertEqual(HoldDragDelay.long.seconds, 0.6)
        XCTAssertEqual(HoldDragDelay.default, .normal)
        XCTAssertEqual(HoldDragDelay.default.seconds, TouchInterpreter.Tuning.holdDelay)
        XCTAssertEqual(HoldDragDelay.allCases.map(\.title), ["Short", "Normal", "Long"])
        XCTAssertEqual(HoldDragDelay.defaultsKey, "input.holdDelay")
        XCTAssertEqual(TouchInterpreter(perform: { _ in }).holdDelay, 0.45)
    }

    func testTheHoldFiresAtTheConfiguredDelay() {
        for preset in HoldDragDelay.allCases {
            for fingers in 1...3 {
                let t = make(holdDelay: preset.seconds)
                down(t, fingers)
                clock.advance(by: preset.seconds - 0.02)
                XCTAssertFalse(actions.contains(.haptic(.medium)), "\(preset) \(fingers): not yet")
                clock.advance(by: 0.03)
                XCTAssertEqual(actions.filter { $0 == .haptic(.medium) }.count, 1, "\(preset) \(fingers): fired")
                XCTAssertEqual(buttons, [], "\(preset) \(fingers): no button until a move")
                t.cancel()
            }
        }
    }

    // MARK: one finger (left)

    func testTrackpadOneFingerHoldThenMoveIsALeftDrag() {
        let t = make()
        down(t, 1)
        clock.advance(by: hold + 0.01)
        XCTAssertEqual(actions, [.began, .haptic(.medium)])
        move(t, 1, by: CGPoint(x: 5, y: 0))                          // under the slop: still nothing
        XCTAssertEqual(buttons, [])
        move(t, 1, by: CGPoint(x: 30, y: 0))
        XCTAssertEqual(Array(actions.suffix(2)), [.button(L, down: true), .moveBy(CGPoint(x: 30, y: 0))])
        move(t, 1, by: CGPoint(x: 32, y: 1), dt: 1.0 / 60)
        XCTAssertEqual(actions.last, .moveBy(CGPoint(x: 2, y: 1)))
        up(t, 1)
        XCTAssertEqual(buttons, click(L))
        assertBalanced()
    }

    func testTrackpadHoldIsNotArmedForTheSecondTouchOfADoubleTap() {
        let t = make()
        t.began(1, at: .zero, time: clock.now)
        t.ended(1, at: .zero, time: at(0.08))
        cues = []
        t.began(2, at: .zero, time: at(0.1))
        XCTAssertFalse(cues.contains { if case .holdArmed = $0 { true } else { false } })
        clock.advance(by: 1)
        XCTAssertEqual(buttons, [.button(L, down: true)], "double-tap-and-hold: pressed at once")
        t.ended(2, at: .zero, time: at(0.01))
        assertBalanced()
    }

    func testMovingBeforeTheHoldFiresIsAPlainMove() {
        let t = make()
        down(t, 1)
        move(t, 1, by: CGPoint(x: 40, y: 0), dt: 0.1)
        clock.advance(by: 1)
        up(t, 1)
        XCTAssertEqual(buttons, [])
        XCTAssertFalse(actions.contains(.haptic(.medium)))
    }

    func testDirectHoldThenMoveIsALeftDragAtTheFinger() {
        let t = make(.direct)
        down(t, 1)
        clock.advance(by: hold + 0.01)
        XCTAssertEqual(actions, [.began, .moveTo(CGPoint(x: 100, y: 100)), .haptic(.medium)])
        move(t, 1, by: CGPoint(x: 0, y: 40))
        XCTAssertEqual(Array(actions.suffix(2)), [.button(L, down: true), .moveTo(CGPoint(x: 100, y: 140))])
        up(t, 1)
        XCTAssertEqual(buttons, click(L))
    }

    func testDirectOneFingerDragIsStillImmediate() {
        let t = make(.direct)
        down(t, 1)
        move(t, 1, by: CGPoint(x: 30, y: 0))
        XCTAssertEqual(buttons, [.button(L, down: true)], "no hold needed in Touch mode")
        up(t, 1)
        assertBalanced()
    }

    // MARK: two fingers (right)

    func testTrackpadTwoFingerHoldThenMoveIsARightDrag() {
        let t = make()
        down(t, 2)
        clock.advance(by: hold + 0.01)
        XCTAssertEqual(actions.filter { $0 == .haptic(.medium) }.count, 1)
        XCTAssertEqual(buttons, [])
        move(t, 2, by: CGPoint(x: 0, y: 30))
        XCTAssertEqual(Array(actions.suffix(2)), [.button(R, down: true), .moveBy(CGPoint(x: 0, y: 30))])
        move(t, 2, by: CGPoint(x: 0, y: 32), dt: 1.0 / 60)                // slow: gain 1
        XCTAssertEqual(actions.last, .moveBy(CGPoint(x: 0, y: 2)))
        XCTAssertFalse(actions.contains { if case .scroll = $0 { true } else { false } }, "a drag, not a scroll")
        // The first finger up ends it; the other lifting does nothing more.
        t.ended(1, at: .zero, time: at(0.01))
        XCTAssertEqual(buttons, click(R))
        move(t, 2, by: CGPoint(x: 0, y: 80))
        t.ended(2, at: .zero, time: at(0.01))
        XCTAssertEqual(buttons, click(R))
        assertBalanced()
    }

    func testDirectTwoFingerHoldIsARightDragAtTheFingers() {
        let t = make(.direct)
        down(t, 2)                                                   // centroid (125, 100)
        clock.advance(by: hold + 0.01)
        XCTAssertEqual(Array(actions.suffix(2)), [.moveTo(CGPoint(x: 125, y: 100)), .haptic(.medium)])
        move(t, 2, by: CGPoint(x: 20, y: 20))
        XCTAssertEqual(Array(actions.suffix(2)), [.button(R, down: true), .moveTo(CGPoint(x: 145, y: 120))])
        up(t, 2)
        XCTAssertEqual(buttons, click(R))
    }

    func testTwoFingerStillHoldReleasedSendsNothing() {
        for mode in TouchInputMode.allCases {
            let t = make(mode)
            down(t, 2)
            clock.advance(by: 1)
            up(t, 2)
            clock.advance(by: 1)
            XCTAssertEqual(buttons, [], "\(mode): not a right click either (held too long for a tap)")
        }
    }

    func testTwoFingerScrollBeforeTheHoldCancelsIt() {
        let t = make()
        down(t, 2)
        move(t, 2, by: CGPoint(x: 0, y: 30), dt: 0.1)
        clock.advance(by: 1)
        move(t, 2, by: CGPoint(x: 0, y: 60))
        up(t, 2)
        XCTAssertEqual(buttons, [])
        XCTAssertFalse(actions.contains(.haptic(.medium)))
        XCTAssertTrue(actions.contains(.scroll(CGPoint(x: 0, y: 30))))
    }

    func testPinchBeforeTheHoldCancelsItAndStillZooms() {
        for mode in TouchInputMode.allCases {
            let t = make(mode)
            t.began(1, at: CGPoint(x: 400, y: 300), time: clock.now)
            t.began(2, at: CGPoint(x: 500, y: 300), time: clock.now)
            t.moved([1: CGPoint(x: 380, y: 300), 2: CGPoint(x: 520, y: 300)], time: at(0.1))
            clock.advance(by: 1)
            t.moved([1: CGPoint(x: 350, y: 300), 2: CGPoint(x: 560, y: 300)], time: at(0.03))
            XCTAssertTrue(actions.contains { if case .zoom = $0 { true } else { false } }, "\(mode)")
            XCTAssertFalse(actions.contains(.haptic(.medium)), "\(mode): no hold")
            up(t, 2)
            XCTAssertEqual(buttons, [], "\(mode)")
        }
    }

    func testJitterUnderTheSlopStillFires() {
        let t = make()
        down(t, 2)
        move(t, 2, by: CGPoint(x: 4, y: 3), dt: 0.2)
        clock.advance(by: hold)
        XCTAssertTrue(actions.contains(.haptic(.medium)))
    }

    func testLiftingOneOfTwoFingersBeforeTheHoldCancelsIt() {
        let t = make()
        down(t, 2)
        t.ended(2, at: .zero, time: at(0.1))
        clock.advance(by: 1)
        t.moved(1, to: CGPoint(x: 100, y: 200), time: at(0.05))
        t.ended(1, at: .zero, time: at(0.01))
        XCTAssertFalse(actions.contains(.haptic(.medium)))
        XCTAssertEqual(buttons, [])
    }

    func testTwoFingerTapIsStillARightClickAndZoomedDoubleTapStillResets() {
        let t = make()
        down(t, 2)
        up(t, 2)
        XCTAssertEqual(buttons, click(R))
        let z = make()
        zoomed = true
        for _ in 0..<2 {
            down(z, 2)
            up(z, 2)
            clock.advance(by: 0.08)
        }
        clock.advance(by: 1)
        XCTAssertTrue(actions.contains(.resetZoom))
        XCTAssertEqual(buttons, [])
    }

    func testZoomedTwoFingerTapThenAHoldSendsTheRightClickFirst() {
        let t = make()
        zoomed = true
        down(t, 2)
        up(t, 2)                                                    // waiting for a double tap
        clock.advance(by: 0.05)
        down(t, 1)
        clock.advance(by: hold + 0.01)
        XCTAssertEqual(buttons, click(R), "the waiting right click went before the hold")
    }

    // MARK: three fingers (middle)

    func testTrackpadThreeFingerHoldThenMoveIsAMiddleDrag() {
        let t = make()
        down(t, 3)
        clock.advance(by: hold + 0.01)
        XCTAssertEqual(buttons, [])
        move(t, 3, by: CGPoint(x: -20, y: 0))
        XCTAssertEqual(Array(actions.suffix(2)), [.button(M, down: true), .moveBy(CGPoint(x: -20, y: 0))])
        XCTAssertEqual(chords, [], "a hold-drag is not a swipe")
        move(t, 3, by: CGPoint(x: -200, y: 0))
        XCTAssertEqual(chords, [], "not even a long one")
        up(t, 3)
        XCTAssertEqual(buttons, click(M))
        assertBalanced()
    }

    func testDirectThreeFingerHoldIsAMiddleDragAtTheFingers() {
        let t = make(.direct)
        down(t, 3)                                                   // centroid (150, 100)
        clock.advance(by: hold + 0.01)
        XCTAssertEqual(moves.last, .moveTo(CGPoint(x: 150, y: 100)))
        move(t, 3, by: CGPoint(x: 0, y: -25))
        XCTAssertEqual(Array(actions.suffix(2)), [.button(M, down: true), .moveTo(CGPoint(x: 150, y: 75))])
        t.ended(3, at: .zero, time: at(0.01))
        XCTAssertEqual(buttons, click(M))
        up(t, 2)
        assertBalanced()
    }

    func testThreeFingerTapIsAMiddleClick() {
        let t = make()
        down(t, 3)
        up(t, 3)
        XCTAssertEqual(buttons, click(M))
        XCTAssertTrue(actions.contains(.haptic(.medium)))
        XCTAssertEqual(moves, [], "trackpad: at the cursor")
        let d = make(.direct)
        down(d, 3)
        up(d, 3)
        XCTAssertEqual(actions.suffix(4), [.moveTo(CGPoint(x: 150, y: 100)), .haptic(.medium)] + click(M))
    }

    func testSlowThreeFingerTapIsNothing() {
        let t = make()
        down(t, 3)
        clock.advance(by: TouchInterpreter.Tuning.tapMaxDuration * 1.5 + 0.05)   // before the hold (0.45)…
        up(t, 3)
        XCTAssertEqual(buttons, [], "…but too slow for a tap")
    }

    // MARK: three-finger swipes

    func testThreeFingerSwipesSendTheMacTrackpadShortcuts() {
        let ctrl = StickyModifier.control.keysym!
        let cases: [(CGPoint, KeyChord)] = [
            (CGPoint(x: -80, y: 0), KeyChord([ctrl], SpecialKey.right.keysym)),   // left: the Space on the right
            (CGPoint(x: 80, y: 5), KeyChord([ctrl], SpecialKey.left.keysym)),
            (CGPoint(x: 5, y: -80), KeyChord([ctrl], SpecialKey.up.keysym)),      // Mission Control
            (CGPoint(x: -5, y: 80), KeyChord([ctrl], SpecialKey.down.keysym)),    // App Exposé
        ]
        for mode in TouchInputMode.allCases {
            for (d, chord) in cases {
                let t = make(mode)
                down(t, 3)
                move(t, 3, by: CGPoint(x: d.x / 4, y: d.y / 4))
                XCTAssertEqual(chords, [], "\(mode) \(d): not yet")
                move(t, 3, by: d)
                move(t, 3, by: CGPoint(x: d.x * 3, y: d.y * 3))
                up(t, 3)
                clock.advance(by: 1)
                XCTAssertEqual(chords, [chord], "\(mode) \(d): exactly once")
                XCTAssertEqual(buttons, [], "\(mode) \(d)")
                XCTAssertFalse(actions.contains(.haptic(.medium)), "\(mode) \(d): the hold never fired")
                XCTAssertEqual(moves, [], "\(mode) \(d): the cursor stays")
            }
        }
    }

    func testSwipeChordsMatchTheMenuShortcuts() {
        XCTAssertEqual(ThreeFingerSwipe.up.chord, ShortcutAction.missionControl.chord)
        XCTAssertEqual(ThreeFingerSwipe.down.chord, ShortcutAction.appExpose.chord)
        XCTAssertEqual(ThreeFingerSwipe.direction(CGPoint(x: -10, y: 3)), .left)
        XCTAssertEqual(ThreeFingerSwipe.direction(CGPoint(x: 10, y: -3)), .right)
        XCTAssertEqual(ThreeFingerSwipe.direction(CGPoint(x: 3, y: -10)), .up)
        XCTAssertEqual(ThreeFingerSwipe.direction(CGPoint(x: -3, y: 10)), .down)
        for s in ThreeFingerSwipe.allCases {
            XCTAssertEqual(s.chord.strokes.first, .down(StickyModifier.control.keysym!), "\(s): ⌃ first")
            XCTAssertEqual(s.chord.strokes.last, .up(StickyModifier.control.keysym!), "\(s): ⌃ released last")
        }
    }

    func testShortThreeFingerTravelIsNeitherASwipeNorATap() {
        let t = make()
        down(t, 3)
        move(t, 3, by: CGPoint(x: 30, y: 0))
        up(t, 3)
        clock.advance(by: 1)
        XCTAssertEqual(chords, [])
        XCTAssertEqual(buttons, [])
    }

    func testAFingerLiftingEndsASwipeInProgress() {
        let t = make()
        down(t, 3)
        move(t, 3, by: CGPoint(x: 30, y: 0))
        t.ended(1, at: .zero, time: at(0.01))
        t.moved([2: CGPoint(x: 400, y: 100), 3: CGPoint(x: 450, y: 100)], time: at(0.05))
        up(t, 3)
        XCTAssertEqual(chords, [])
    }

    // MARK: nothing stays pressed

    func testCancelReleasesEveryHoldDrag() {
        for (fingers, b) in [(1, L), (2, R), (3, M)] {
            for mode in TouchInputMode.allCases {
                let t = make(mode)
                down(t, fingers)
                clock.advance(by: hold + 0.01)
                move(t, fingers, by: CGPoint(x: 40, y: 0))
                XCTAssertEqual(buttons, [.button(b, down: true)], "\(mode) \(fingers)")
                t.cancel()
                XCTAssertEqual(buttons, click(b), "\(mode) \(fingers)")
                XCTAssertEqual(cues.last, .dragEnded)
                up(t, fingers)                                       // late lifts: nothing more
                XCTAssertEqual(buttons, click(b))
            }
        }
    }

    func testACancelledTouchReleasesTheDrag() {
        for (fingers, b) in [(1, L), (2, R), (3, M)] {
            let t = make()
            down(t, fingers)
            clock.advance(by: hold + 0.01)
            move(t, fingers, by: CGPoint(x: 0, y: 40))
            t.cancelled(1)
            XCTAssertEqual(buttons, click(b), "\(fingers)")
            move(t, fingers, by: CGPoint(x: 0, y: 90))
            up(t, fingers)
            XCTAssertEqual(buttons, click(b), "\(fingers): the rest is ignored")
        }
    }

    func testAFourthFingerAbandonsAMiddleDrag() {
        let t = make()
        down(t, 3)
        clock.advance(by: hold + 0.01)
        move(t, 3, by: CGPoint(x: 40, y: 0))
        t.began(4, at: CGPoint(x: 400, y: 100), time: clock.now)
        XCTAssertEqual(buttons, click(M))
        up(t, 3)
        t.ended(4, at: .zero, time: at(0.01))
        assertBalanced()
    }

    func testARestingExtraFingerDuringAOneFingerHoldDragIsIgnored() {
        let t = make()
        down(t, 1)
        clock.advance(by: hold + 0.01)
        t.began(9, at: CGPoint(x: 600, y: 600), time: clock.now)
        move(t, 1, by: CGPoint(x: 40, y: 0))
        XCTAssertEqual(buttons, [.button(L, down: true)])
        t.ended(9, at: .zero, time: at(0.01))
        XCTAssertEqual(buttons, [.button(L, down: true)], "the resting finger lifting ends nothing")
        up(t, 1)
        XCTAssertEqual(buttons, click(L))
    }

    func testAHoldFiringAfterAModeSwitchDoesNothing() {
        let t = make()
        down(t, 2)
        t.mode = .direct
        clock.advance(by: 1)
        XCTAssertFalse(actions.contains(.haptic(.medium)))
        XCTAssertEqual(cues.filter { $0 == .holdFired }, [])
    }

    func testEveryGestureMixLeavesNothingPressed() {
        for mode in TouchInputMode.allCases {
            let t = make(mode)
            for fingers in 1...3 {
                // tap, hold-drag, still hold, swipe-ish moves, in sequence.
                down(t, fingers); up(t, fingers); clock.advance(by: 0.5)
                down(t, fingers); clock.advance(by: hold + 0.01)
                move(t, fingers, by: CGPoint(x: 60, y: 0)); up(t, fingers); clock.advance(by: 0.5)
                down(t, fingers); clock.advance(by: hold + 0.01); up(t, fingers); clock.advance(by: 0.5)
                down(t, fingers); move(t, fingers, by: CGPoint(x: 0, y: 90)); up(t, fingers); clock.advance(by: 0.5)
            }
            assertBalanced()
        }
    }
}

/// RemoteInputView performing touch actions: wire events, zoom alignment.
@MainActor
final class TouchActionWireTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        func append(_ d: Data) { lock.withLock { _sent.append(d) } }
        var sent: [Data] { lock.withLock { _sent } }
    }

    private struct Pointer: Equatable { var buttons: Int, x: Int, y: Int }

    /// A 1600×1000 view over a 1600×1000 host (1 point = 1 host pixel).
    private func make() -> (RemoteInputView, InputController, Sink, RemoteCursor) {
        let sink = Sink()
        let input = InputController(contentKey: nil, serverWidth: 1600, serverHeight: 1000,
                                    send: { sink.append($0) })
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                   repeatSchedule: FakeRepeatClock().schedule)
        let cursor = RemoteCursor()
        view.cursor = cursor
        view.input = input
        return (view, input, sink, cursor)
    }

    private func pointers(_ input: InputController, _ sink: Sink) async -> [Pointer] {
        await input.flush()
        return sink.sent.compactMap { d in
            let b = [UInt8](d)
            guard b.first == 5 else { return nil }
            return Pointer(buttons: Int(b[1]), x: Int(b[2]) << 8 | Int(b[3]), y: Int(b[4]) << 8 | Int(b[5]))
        }
    }

    func testRelativeMovesStartMidScreenAndClickAtTheCursor() async {
        let (view, input, sink, _) = make()
        view.perform(.moveBy(CGPoint(x: 10, y: -20)))
        view.perform(.button(InputController.Button.left, down: true))
        view.perform(.button(InputController.Button.left, down: false))
        let got = await pointers(input, sink)
        XCTAssertEqual(got, [Pointer(buttons: 0, x: 810, y: 480), Pointer(buttons: 1, x: 810, y: 480),
                             Pointer(buttons: 0, x: 810, y: 480)])
    }

    func testRelativeMoveClampsToTheCanvas() async {
        let (view, input, sink, _) = make()
        view.perform(.moveBy(CGPoint(x: -5000, y: 5000)))
        let got = await pointers(input, sink)
        XCTAssertEqual(got.last, Pointer(buttons: 0, x: 0, y: 999))
    }

    func testZoomedRelativeMoveIsSlowerOnTheHostAndTheViewportFollows() async throws {
        let (view, input, sink, cursor) = make()
        view.perform(.moveBy(.zero))                                     // cursor at (800, 500)
        view.zoom(by: 4, around: CGPoint(x: 800, y: 500), pan: .zero)
        view.perform(.moveBy(CGPoint(x: 100, y: 0)))                      // 100 pt on screen = 25 host px
        var got = await pointers(input, sink)
        XCTAssertEqual(got.last, Pointer(buttons: 0, x: 825, y: 500))
        // Push past the right margin: the viewport pans to keep it 10% inside.
        for _ in 0..<10 { view.perform(.moveBy(CGPoint(x: 100, y: 0))) }
        got = await pointers(input, sink)
        XCTAssertEqual(got.last, Pointer(buttons: 0, x: 1075, y: 500))
        let drawn = try XCTUnwrap(view.cursorViewPoint)
        XCTAssertLessThanOrEqual(drawn.x, 1600 * 0.9 + 4.01)          // within the margin (± a host px)
        XCTAssertGreaterThan(drawn.x, 1600 * 0.85)
        // The drawn cursor and the host pixel agree: mapping the drawn point back gives the cursor's pixel.
        let back = try XCTUnwrap(input.hostPoint(forViewPoint: drawn, viewSize: view.bounds.size,
                                                 viewport: view.viewport.value))
        XCTAssertEqual(back.x, 1075)
        XCTAssertEqual(back.y, 500)
        XCTAssertEqual(cursor.position, CGPoint(x: 1075, y: 500))
    }

    func testZoomedDirectTouchMapsThroughTheInverse() async {
        let (view, input, sink, _) = make()
        view.zoom(by: 2, around: CGPoint(x: 800, y: 500), pan: .zero)
        view.perform(.moveTo(CGPoint(x: 0, y: 0)))
        view.perform(.button(InputController.Button.left, down: true))
        view.perform(.button(InputController.Button.left, down: false))
        let got = await pointers(input, sink)
        XCTAssertEqual(got.first, Pointer(buttons: 0, x: 400, y: 250))
        XCTAssertEqual(got.last, Pointer(buttons: 0, x: 400, y: 250))
    }

    func testResetZoomReturnsToFit() {
        let (view, _, _, _) = make()
        view.zoom(by: 3, around: CGPoint(x: 100, y: 100), pan: .zero)
        XCTAssertTrue(view.viewport.value.isZoomed)
        view.perform(.resetZoom)
        XCTAssertEqual(view.viewport.value, .identity)
    }

    func testReleaseAllReleasesATouchDragAndStopsMomentum() async {
        let (view, input, sink, _) = make()
        view.perform(.moveBy(.zero))
        view.perform(.button(InputController.Button.left, down: true))
        view.perform(.scrollEnded(velocity: CGPoint(x: 0, y: 2000)))
        XCTAssertTrue(view.isCoasting)
        view.releaseAll()
        XCTAssertFalse(view.isCoasting)
        let got = await pointers(input, sink)
        XCTAssertEqual(got.last, Pointer(buttons: 0, x: 800, y: 500))
    }

    func testTouchBeganStopsMomentum() {
        let (view, _, _, _) = make()
        view.perform(.scrollEnded(velocity: CGPoint(x: 0, y: 2000)))
        XCTAssertTrue(view.isCoasting)
        view.perform(.began)
        XCTAssertFalse(view.isCoasting)
    }

    func testASwipeChordGoesOutAsAKeyTap() async {
        let (view, input, sink, _) = make()
        view.perform(.keyChord(ThreeFingerSwipe.left.chord))
        await input.flush()
        let keys = sink.sent.compactMap { d -> KeyStroke? in
            let b = [UInt8](d)
            guard b.first == 4, b.count >= 8 else { return nil }
            let ks = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
            return KeyStroke(down: b[1] != 0, keysym: ks)
        }
        XCTAssertEqual(keys, ThreeFingerSwipe.left.chord.strokes)
    }

    func testModeSwitchOnTheViewReleasesTheButton() async {
        let (view, input, sink, _) = make()
        view.perform(.moveBy(.zero))
        view.pressButton(InputController.Button.left, down: true)
        view.touchMode = .direct          // interpreter idle: nothing it holds; the view's press stays
        view.releaseAll()
        let got = await pointers(input, sink)
        XCTAssertEqual(got.last?.buttons, 0)
    }
}
