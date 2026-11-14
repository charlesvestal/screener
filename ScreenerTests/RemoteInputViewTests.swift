import UIKit
import XCTest
@testable import Screener

/// Manual clock for KeyRepeater: timers fire only when the test advances time.
@MainActor
final class FakeRepeatClock {
    private struct Pending { var id: Int; var deadline: TimeInterval; var fire: @MainActor @Sendable () -> Void }
    private(set) var now: TimeInterval = 0
    private var pending: [Pending] = []
    private var nextID = 0

    var scheduledCount: Int { pending.count }

    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        pending.append(Pending(id: id, deadline: now + delay, fire: fire))
        return { [weak self] in self?.pending.removeAll { $0.id == id } }
    }

    func advance(by dt: TimeInterval) {
        let end = now + dt
        while let next = pending.filter({ $0.deadline <= end + 1e-9 }).min(by: { $0.deadline < $1.deadline }) {
            pending.removeAll { $0.id == next.id }
            now = next.deadline
            next.fire()
        }
        now = end
    }
}

@MainActor
final class KeyRepeaterTests: XCTestCase {
    private var clock = FakeRepeatClock()
    private var repeats: [UInt32] = []

    private func make() -> KeyRepeater {
        clock = FakeRepeatClock()
        repeats = []
        let r = KeyRepeater(schedule: clock.schedule)
        r.onRepeat = { [weak self] in self?.repeats.append($0) }
        return r
    }

    func testRepeatsAfterInitialDelayThenAtTheInterval() {
        let r = make()
        r.keyDown(usage: 1, keysym: 0xff08)
        clock.advance(by: 0.49)
        XCTAssertEqual(repeats, [])
        clock.advance(by: 0.02)                       // 0.51
        XCTAssertEqual(repeats, [0xff08])
        clock.advance(by: KeyRepeater.interval * 3)
        XCTAssertEqual(repeats.count, 4)
        XCTAssertEqual(KeyRepeater.initialDelay, 0.5)
        XCTAssertEqual(KeyRepeater.interval, 0.033, accuracy: 0.002)
    }

    func testKeyUpOfTheRepeatingKeyStops() {
        let r = make()
        r.keyDown(usage: 1, keysym: 0xff51)
        clock.advance(by: 0.6)
        let n = repeats.count
        r.keyUp(usage: 1)
        clock.advance(by: 1)
        XCTAssertEqual(repeats.count, n)
        XCTAssertEqual(clock.scheduledCount, 0)
    }

    func testOnlyTheMostRecentKeyRepeats() {
        let r = make()
        r.keyDown(usage: 1, keysym: 0x61)
        clock.advance(by: 0.3)
        r.keyDown(usage: 2, keysym: 0x62)
        clock.advance(by: 0.3)                        // 'a' would have fired at 0.5
        XCTAssertEqual(repeats, [])
        r.keyUp(usage: 1)                             // releasing the older key: 'b' keeps going
        clock.advance(by: 0.25)                       // 0.85 > 0.3 + 0.5
        XCTAssertEqual(repeats.first, 0x62)
        XCTAssertFalse(repeats.contains(0x61))
    }

    func testCancelStops() {
        let r = make()
        r.keyDown(usage: 1, keysym: 0x61)
        r.cancel()
        clock.advance(by: 2)
        XCTAssertEqual(repeats, [])
        XCTAssertEqual(clock.scheduledCount, 0)
    }
}

/// RemoteInputView's key, repeat and release paths, driven through the same
/// internal entry points pressesBegan/Ended use (UIPress can't be built in a test).
@MainActor
final class RemoteInputViewTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        func append(_ d: Data) { lock.withLock { _sent.append(d) } }
        var sent: [Data] { lock.withLock { _sent } }
    }

    enum Event: Equatable {
        case key(down: Bool, keysym: UInt32)
        case pointer(buttons: Int, x: Int, y: Int)
    }

    private static func decode(_ d: Data) -> Event? {
        let b = [UInt8](d)
        switch b.first {
        case 4?:
            let ks = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
            return .key(down: b[1] == 1, keysym: ks)
        case 5?:
            return .pointer(buttons: Int(b[1]), x: Int(b[2]) << 8 | Int(b[3]), y: Int(b[4]) << 8 | Int(b[5]))
        default:
            return nil
        }
    }

    private var clock = FakeRepeatClock()

    /// A 100×100 view over a 100×100 host (no content key: plain 0x04/0x05 messages).
    private func make() -> (RemoteInputView, InputController, Sink) {
        clock = FakeRepeatClock()
        let sink = Sink()
        let input = InputController(contentKey: nil, serverWidth: 100, serverHeight: 100,
                                    send: { sink.append($0) })
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   repeatSchedule: clock.schedule)
        view.input = input
        return (view, input, sink)
    }

    private func events(_ input: InputController, _ sink: Sink) async -> [Event] {
        await input.flush()
        return sink.sent.compactMap(Self.decode)
    }

    func testHeldKeyRepeatsAsKeyDownsWithoutUps() async {
        let (view, input, sink) = make()
        XCTAssertTrue(view.keyDown(.keyboardDeleteOrBackspace, modifiers: [], characters: "\u{8}"))
        clock.advance(by: 0.5 + KeyRepeater.interval * 2 + 0.001)
        XCTAssertTrue(view.keyUp(.keyboardDeleteOrBackspace))
        clock.advance(by: 1)
        let bs: UInt32 = 0xff08
        let got_input = await events(input, sink)
        XCTAssertEqual(got_input, [
            .key(down: true, keysym: bs), .key(down: true, keysym: bs),
            .key(down: true, keysym: bs), .key(down: true, keysym: bs),
            .key(down: false, keysym: bs),
        ])
    }

    func testModifiersDoNotRepeat() async {
        let (view, input, sink) = make()
        view.keyDown(.keyboardLeftShift, modifiers: [.shift], characters: "")
        clock.advance(by: 2)
        view.keyUp(.keyboardLeftShift)
        let got_input = await events(input, sink)
        XCTAssertEqual(got_input, [.key(down: true, keysym: 0xffe1), .key(down: false, keysym: 0xffe1)])
    }

    func testRepeatResendsTheStoredKeysymAfterShiftIsReleased() async {
        let (view, input, sink) = make()
        view.keyDown(.keyboardLeftShift, modifiers: [.shift], characters: "")
        view.keyDown(.keyboardA, modifiers: [.shift], characters: "A")
        view.keyUp(.keyboardLeftShift)
        clock.advance(by: 0.51)
        view.keyUp(.keyboardA)
        let got_input = await events(input, sink)
        XCTAssertEqual(got_input, [
            .key(down: true, keysym: 0xffe1), .key(down: true, keysym: 0x41),
            .key(down: false, keysym: 0xffe1), .key(down: true, keysym: 0x41),
            .key(down: false, keysym: 0x41),
        ])
    }

    func testReleaseAllSendsKeyUpsAndButtonUpAndStopsRepeat() async {
        let (view, input, sink) = make()
        view.pointerDown(buttons: InputController.Button.left, at: CGPoint(x: 10, y: 20))
        view.keyDown(.keyboardLeftArrow, modifiers: [], characters: "")
        view.releaseAll()
        clock.advance(by: 2)
        view.releaseAll()                              // nothing left: no duplicates
        let got_input = await events(input, sink)
        XCTAssertEqual(got_input, [
            .pointer(buttons: 1, x: 10, y: 20), .key(down: true, keysym: 0xff51),
            .key(down: false, keysym: 0xff51), .pointer(buttons: 0, x: 10, y: 20),
        ])
    }

    func testWillResignActiveReleasesHeldInput() async {
        let (view, input, sink) = make()
        view.pointerDown(buttons: InputController.Button.right, at: CGPoint(x: 50, y: 50))
        view.keyDown(.keyboardLeftGUI, modifiers: [.command], characters: "")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let got_input = await events(input, sink)
        XCTAssertEqual(got_input, [
            .pointer(buttons: 2, x: 50, y: 50), .key(down: true, keysym: 0xffeb),
            .key(down: false, keysym: 0xffeb), .pointer(buttons: 0, x: 50, y: 50),
        ])
    }

    func testSceneDeactivationOfAnotherSceneIsIgnored() async {
        let (view, input, sink) = make()
        view.keyDown(.keyboardLeftGUI, modifiers: [.command], characters: "")
        // The view has no window, so a deactivation with no scene object is not ours.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: nil)
        let got_input = await events(input, sink)
        XCTAssertEqual(got_input, [.key(down: true, keysym: 0xffeb)])
    }

    func testSwitchingControllersReleasesOnTheOldOne() async {
        let (view, old, oldSink) = make()
        view.pointerDown(buttons: InputController.Button.left, at: CGPoint(x: 1, y: 2))
        view.keyDown(.keyboardX, modifiers: [], characters: "x")
        let newSink = Sink()
        let new = InputController(contentKey: nil, serverWidth: 100, serverHeight: 100, send: { newSink.append($0) })
        view.input = new
        clock.advance(by: 2)                           // repeat stopped with the switch
        let got_old = await events(old, oldSink)
        XCTAssertEqual(got_old, [
            .pointer(buttons: 1, x: 1, y: 2), .key(down: true, keysym: 0x78),
            .key(down: false, keysym: 0x78), .pointer(buttons: 0, x: 1, y: 2),
        ])
        view.keyUp(.keyboardX)                         // already released: nothing on the new one
        let got_new = await events(new, newSink)
        XCTAssertEqual(got_new, [])
    }

    // MARK: sticky modifiers (floating menu)

    private func makeSticky() -> (RemoteInputView, InputController, Sink, StickyModifiers) {
        let (view, input, sink) = make()
        let sticky = StickyModifiers(now: { 0 })
        view.modifiers = sticky
        return (view, input, sink, sticky)
    }

    func testSoftKeyboardCharacterWithLatchedCommand() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.command)
        view.typeText("cc")
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .key(down: true, keysym: 0xffeb), .key(down: true, keysym: 0x63),
            .key(down: false, keysym: 0x63), .key(down: false, keysym: 0xffeb),
            .key(down: true, keysym: 0x63), .key(down: false, keysym: 0x63),    // latched: first character only
        ])
        XCTAssertEqual(sticky.state[.command], .off)
    }

    func testSoftKeyboardUppercaseWithStickyCommandSendsShiftPlusLowercase() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.command)
        view.typeText("Z")
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .key(down: true, keysym: 0xffeb), .key(down: true, keysym: 0xffe1),
            .key(down: true, keysym: 0x7a), .key(down: false, keysym: 0x7a),
            .key(down: false, keysym: 0xffe1), .key(down: false, keysym: 0xffeb),
        ])
    }

    func testStickyShiftAndTypedShiftDoNotDoubleDown() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.shift)
        view.typeText("A")
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .key(down: true, keysym: 0xffe1), .key(down: true, keysym: 0x41),
            .key(down: false, keysym: 0x41), .key(down: false, keysym: 0xffe1),
        ])
    }

    func testSoftDeleteWithFnIsForwardDelete() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.fn)
        view.softDelete()
        view.softDelete()
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .key(down: true, keysym: 0xffff), .key(down: false, keysym: 0xffff),
            .key(down: true, keysym: 0xff08), .key(down: false, keysym: 0xff08),
        ])
    }

    func testClickWithLatchedCommand() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.command)
        view.click(at: CGPoint(x: 10, y: 10), button: InputController.Button.left)
        view.click(at: CGPoint(x: 10, y: 10), button: InputController.Button.left)
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .pointer(buttons: 0, x: 10, y: 10),
            .key(down: true, keysym: 0xffeb), .pointer(buttons: 1, x: 10, y: 10),
            .pointer(buttons: 0, x: 10, y: 10), .key(down: false, keysym: 0xffeb),
            .pointer(buttons: 0, x: 10, y: 10),                         // latched ⌘ consumed by the first click
            .pointer(buttons: 1, x: 10, y: 10), .pointer(buttons: 0, x: 10, y: 10),
        ])
    }

    func testLockedOptionHeldAcrossADrag() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.option); sticky.tap(.option)                 // same instant: locked
        view.pointerDown(buttons: InputController.Button.left, at: CGPoint(x: 5, y: 5))
        view.movePointer(to: CGPoint(x: 20, y: 20), coalescable: false)
        view.releaseAll()
        let got = await events(input, sink)
        XCTAssertEqual(got.first, .key(down: true, keysym: 0xffe9))
        XCTAssertEqual(got[1], .pointer(buttons: 1, x: 5, y: 5))
        XCTAssertTrue(got.contains(.key(down: false, keysym: 0xffe9)))
        XCTAssertEqual(sticky.state[.option], .locked)
    }

    func testHardwareKeyWithLatchedCommandUsesUSKeysymAndHoldsUntilKeyUp() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.command)
        view.keyDown(.keyboardC, modifiers: [], characters: "c")
        view.keyUp(.keyboardC)
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .key(down: true, keysym: 0xffeb), .key(down: true, keysym: 0x63),
            .key(down: false, keysym: 0x63), .key(down: false, keysym: 0xffeb),
        ])
    }

    func testPhysicalCommandUnionWithStickyCommandNoDoubleDown() async {
        let (view, input, sink, sticky) = makeSticky()
        sticky.tap(.command)
        view.keyDown(.keyboardLeftGUI, modifiers: [.command], characters: "")
        view.keyDown(.keyboardC, modifiers: [.command], characters: "c")
        view.keyUp(.keyboardC)
        view.keyUp(.keyboardLeftGUI)
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .key(down: true, keysym: 0xffeb), .key(down: true, keysym: 0x63),
            .key(down: false, keysym: 0x63), .key(down: false, keysym: 0xffeb),
        ])
    }

    func testMenuShortcutIsNotForwarded() async {
        let (view, input, sink, _) = makeSticky()
        XCTAssertFalse(view.keyDown(.keyboardM, modifiers: [.command, .alternate], characters: "m"))
        XCTAssertFalse(view.keyUp(.keyboardM))
        var toggled = 0
        view.onToggleMenu = { toggled += 1 }
        view.toggleControlMenu(nil)
        XCTAssertEqual(toggled, 1)
        let cmd = view.keyCommands?.first
        XCTAssertEqual(cmd?.input, "m")
        XCTAssertEqual(cmd?.modifierFlags, [.command, .alternate])
        let got = await events(input, sink)
        XCTAssertEqual(got, [])
    }

    func testMenuHoldsAreReferenceCountedWithHardware() async {
        let (view, input, sink, _) = makeSticky()
        view.holdModifier(0xffeb)
        view.keyDown(.keyboardLeftGUI, modifiers: [.command], characters: "")
        view.releaseModifier(0xffeb)
        view.keyUp(.keyboardLeftGUI)
        view.releaseModifier(0xffeb)                            // extra release: ignored
        let got = await events(input, sink)
        XCTAssertEqual(got, [.key(down: true, keysym: 0xffeb), .key(down: false, keysym: 0xffeb)])
    }

    func testReleaseAllReleasesMenuHoldsAndNotifies() async {
        let (view, input, sink, _) = makeSticky()
        var released = 0
        view.onInputReleased = { released += 1 }
        view.holdModifier(0xffe3)
        view.holdModifier(0xffeb)
        view.releaseAll()
        view.releaseModifier(0xffeb)                            // after the flush: nothing
        let got = await events(input, sink)
        XCTAssertEqual(got, [
            .key(down: true, keysym: 0xffe3), .key(down: true, keysym: 0xffeb),
            .key(down: false, keysym: 0xffeb), .key(down: false, keysym: 0xffe3),
        ])
        XCTAssertEqual(released, 1)
    }

    func testKeyboardProxyIsTransparentNotHidden() {
        let (view, _, _) = make()
        let proxy = view.subviews.first { $0 is SoftKeyboardProxy }
        XCTAssertNotNil(proxy)
        XCTAssertEqual(proxy?.isHidden, false)
        XCTAssertEqual(proxy?.alpha, 0)
    }

    func testWheelNotchTunable() {
        XCTAssertEqual(RemoteInputView.Tuning.pointsPerWheelNotch, 10)
    }

    // MARK: pointer hiding is scoped to the fitted video rect

    /// A pure hover outside the fitted video rect (the letterbox, here the
    /// 25pt pillarbox either side of a 50×100 canvas in a 100×100 view)
    /// sends nothing — the system pointer shows there instead.
    func testHoverOutsideTheFittedRectSendsNothing() async {
        let (view, input, sink) = make()
        input.setServerDims(width: 50, height: 100)
        view.movePointer(to: CGPoint(x: 10, y: 10), coalescable: true)
        let got = await events(input, sink)
        XCTAssertEqual(got, [])
    }

    /// The same hover inside the fitted rect sends a move as usual.
    func testHoverInsideTheFittedRectSendsAMove() async {
        let (view, input, sink) = make()
        input.setServerDims(width: 50, height: 100)
        view.movePointer(to: CGPoint(x: 50, y: 10), coalescable: true)
        let got = await events(input, sink)
        XCTAssertFalse(got.isEmpty, "a hover inside the video rect must still move the pointer")
    }

    /// `styleFor` hides the system pointer only for the region `regionFor`
    /// tags as the video (identifier "video"); any other region (the
    /// letterbox's default region) always shows the normal pointer, even
    /// with a host cursor image known.
    func testStyleHidesTheSystemPointerOnlyForTheVideoRegion() {
        let (view, _, _) = make()
        let cursor = RemoteCursor()
        cursor.store(id: 1, hotspot: PixelPoint(x: 0, y: 0), size: PixelSize(width: 1, height: 1),
                    bgra: Data([0, 0, 0, 0]), alpha: Data([255]))
        view.cursor = cursor
        let interaction = UIPointerInteraction(delegate: view)
        let letterbox = UIPointerRegion(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(view.pointerInteraction(interaction, styleFor: letterbox))
        let video = UIPointerRegion(rect: CGRect(x: 0, y: 0, width: 10, height: 10), identifier: "video" as NSString)
        XCTAssertNotNil(view.pointerInteraction(interaction, styleFor: video))
    }
}
