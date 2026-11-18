import CoreGraphics
import XCTest
@testable import Screener

final class PointerScalingTests: XCTestCase {
    func testHardwareGainIsGentle() {
        XCTAssertEqual(PointerScaling.hardwareGain(speed: 0), 1)
        XCTAssertEqual(PointerScaling.hardwareGain(speed: PointerScaling.slowSpeed), 1)
        XCTAssertEqual(PointerScaling.hardwareGain(speed: PointerScaling.fastSpeed), PointerScaling.maxGain)
        XCTAssertEqual(PointerScaling.hardwareGain(speed: 50_000), PointerScaling.maxGain)
        XCTAssertEqual(PointerScaling.hardwareGain(speed: .infinity), 1)
        var last: CGFloat = 1
        for v in stride(from: CGFloat(0), through: 4000, by: 100) {
            let g = PointerScaling.hardwareGain(speed: v)
            XCTAssertGreaterThanOrEqual(g, last)
            last = g
        }
        // Gentler than the touch curve that used to drive the hardware pointer.
        XCTAssertLessThan(PointerScaling.hardwareGain(speed: 1500), TrackpadAcceleration.gain(speed: 1500))
        XCTAssertLessThan(PointerScaling.maxGain, TrackpadAcceleration.maxGain)
    }

    func testOneCountIsOneMacPointAtDefaultSpeed() {
        // Slow motion (no acceleration), Retina host: 10 counts = 10 Mac points = 20 backing px.
        let px = PointerScaling.hardwareHostPixels(CGPoint(x: 10, y: -4), dt: 1, speed: 1, hostPointScale: 2)
        XCTAssertEqual(px.x, 20, accuracy: 1e-9)
        XCTAssertEqual(px.y, -8, accuracy: 1e-9)
        // Non-Retina host: 10 counts = 10 px.
        XCTAssertEqual(PointerScaling.hardwareHostPixels(CGPoint(x: 10, y: 0), dt: 1, speed: 1,
                                                         hostPointScale: 1).x, 10, accuracy: 1e-9)
    }

    func testSpeedSettingScalesAndIsClamped() {
        func px(_ speed: Double) -> CGFloat {
            PointerScaling.hardwareHostPixels(CGPoint(x: 10, y: 0), dt: 1, speed: speed, hostPointScale: 2).x
        }
        XCTAssertEqual(px(0.5), 10, accuracy: 1e-9)
        XCTAssertEqual(px(2), 40, accuracy: 1e-9)
        XCTAssertEqual(px(10), px(3), accuracy: 1e-9)
        XCTAssertEqual(px(0), px(0.25), accuracy: 1e-9)
        XCTAssertEqual(px(.nan), px(1), accuracy: 1e-9)
        XCTAssertEqual(PointerScaling.touchDelta(CGPoint(x: 10, y: -6), speed: 0.5), CGPoint(x: 5, y: -3))
        XCTAssertEqual(PointerScaling.touchDelta(CGPoint(x: 10, y: 0), speed: 9), CGPoint(x: 30, y: 0))
    }

    func testFastMotionIsAcceleratedByAtMostMaxGain() {
        // 100 counts in 10 ms = 10 000 counts/s.
        let px = PointerScaling.hardwareHostPixels(CGPoint(x: 100, y: 0), dt: 0.01, speed: 1, hostPointScale: 2)
        XCTAssertEqual(px.x, 200 * PointerScaling.maxGain, accuracy: 1e-6)
    }

    func testViewDeltaMatchesTheIPadsOwnPointerPace() {
        // A 1440×900-pt Mac (2880 backing) on a 1366-pt-wide iPad view.
        let k1: CGFloat = 2880 / 1366
        let d = PointerScaling.viewDelta(counts: CGPoint(x: 10, y: 0), dt: 1, speed: 1, hostPointScale: 2,
                                         hostPixelsPerViewPoint: k1)
        XCTAssertEqual(d.x, 20 / k1, accuracy: 1e-9)          // ≈ 9.5 iPad points for 10 counts
        XCTAssertEqual(d.x, 9.49, accuracy: 0.01)
    }

    func testPreferencesLoadAndClamp() {
        let name = "PointerScalingTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(InputPreferences.load(d).pointerSpeed, 1)
        XCTAssertEqual(InputPreferences.load(d).touchPointerSpeed, 1)
        d.set(0.5, forKey: PointerScaling.pointerSpeedKey)
        d.set(7.0, forKey: PointerScaling.touchPointerSpeedKey)
        XCTAssertEqual(InputPreferences.load(d).pointerSpeed, 0.5)
        XCTAssertEqual(InputPreferences.load(d).touchPointerSpeed, 3)
        XCTAssertEqual(PointerScaling.pointerSpeedKey, "input.pointerSpeed")
        XCTAssertEqual(PointerScaling.touchPointerSpeedKey, "input.touchPointerSpeed")
    }
}

/// The scaling on the wire: host pixels the cursor moves.
@MainActor
final class PointerScalingWireTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        func append(_ d: Data) { lock.withLock { _sent.append(d) } }
        var sent: [Data] { lock.withLock { _sent } }
    }

    /// A 1600×1000 view over a 3200×2000 Retina host (2 backing px per view point).
    private func make() -> (RemoteInputView, InputController, Sink) {
        let sink = Sink()
        let input = InputController(contentKey: nil, serverWidth: 3200, serverHeight: 2000,
                                    send: { sink.append($0) })
        input.pointScale = 2
        let view = RemoteInputView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                   repeatSchedule: FakeRepeatClock().schedule)
        view.input = input
        view.preferences = InputPreferences()
        return (view, input, sink)
    }

    private func lastPointer(_ input: InputController, _ sink: Sink) async -> (x: Int, y: Int)? {
        await input.flush()
        guard let b = sink.sent.last.map({ [UInt8]($0) }), b.first == 5 else { return nil }
        return (Int(b[2]) << 8 | Int(b[3]), Int(b[4]) << 8 | Int(b[5]))
    }

    func testHardwareCountsAreMacPoints() async {
        let (view, input, sink) = make()
        view.perform(.moveBy(.zero))                          // (1600, 1000)
        view.hardwareMouseMoved(dx: 10, dy: 5, dt: 1)         // slow: 10 / 5 Mac points, y up
        let p = await lastPointer(input, sink)
        XCTAssertEqual(p?.x, 1620)
        XCTAssertEqual(p?.y, 990)
    }

    func testHardwareSpeedSetting() async {
        let (view, input, sink) = make()
        view.preferences.pointerSpeed = 0.5
        view.perform(.moveBy(.zero))
        view.hardwareMouseMoved(dx: 10, dy: 0, dt: 1)
        let p = await lastPointer(input, sink)
        XCTAssertEqual(p?.x, 1610)
    }

    func testZoomedHardwareKeepsItsOnScreenPace() async {
        let (view, input, sink) = make()
        view.perform(.moveBy(.zero))
        view.zoom(by: 2, around: CGPoint(x: 800, y: 500), pan: .zero)
        view.hardwareMouseMoved(dx: 10, dy: 0, dt: 1)
        let p = await lastPointer(input, sink)
        XCTAssertEqual(p?.x, 1610)                            // half the host pixels at 2×
    }

    func testTouchPointerSpeed() async {
        let (view, input, sink) = make()
        view.perform(.moveBy(.zero))
        view.preferences.touchPointerSpeed = 0.5
        view.perform(.moveBy(CGPoint(x: 10, y: 0)))           // 5 view points = 10 host px
        var p = await lastPointer(input, sink)
        XCTAssertEqual(p?.x, 1610)
        view.preferences.touchPointerSpeed = 2
        view.perform(.moveBy(CGPoint(x: 10, y: 0)))           // 20 view points = 40 host px
        p = await lastPointer(input, sink)
        XCTAssertEqual(p?.x, 1650)
    }
}
