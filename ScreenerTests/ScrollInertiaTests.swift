import CoreGraphics
import XCTest
@testable import Screener

final class ScrollInertiaTests: XCTestCase {
    func testDecaysByFrictionEachFrameAndStopsBelowTheThreshold() throws {
        let v0 = 1200.0
        let run = ScrollInertia.deltas(velocity: CGPoint(x: 0, y: v0))
        // Frames until v0·0.95^n < 20: n = ceil(ln(20/1200)/ln(0.95)) = 80.
        let expected = Int((log(ScrollInertia.stopSpeed / v0) / log(ScrollInertia.friction)).rounded(.up))
        XCTAssertEqual(run.count, expected)
        XCTAssertEqual(run.count, 80)
        XCTAssertEqual(run[0].y, v0 / 60, accuracy: 1e-9)
        for (a, b) in zip(run, run.dropFirst()) {
            XCTAssertLessThan(b.y, a.y)                               // strictly decreasing
            XCTAssertEqual(b.y / a.y, ScrollInertia.friction, accuracy: 1e-9)
        }
        XCTAssertTrue(run.allSatisfy { $0.x == 0 && $0.y > 0 })
    }

    func testTotalDistanceIsTheGeometricSum() {
        let v0 = 900.0
        let run = ScrollInertia.deltas(velocity: CGPoint(x: 0, y: -v0))
        let total = run.reduce(0) { $0 + $1.y }
        let n = Double(run.count)
        let expected = -v0 / 60 * (1 - pow(0.95, n)) / (1 - 0.95)
        XCTAssertEqual(total, expected, accuracy: 1e-6)
        XCTAssertTrue(run.allSatisfy { $0.y < 0 })                    // keeps the direction
    }

    func testSlowReleaseStartsNoRun() {
        XCTAssertNil(ScrollInertia(velocity: CGPoint(x: 0, y: 30)))
        XCTAssertEqual(ScrollInertia.deltas(velocity: .zero), [])
    }

    func testWildFlickIsCapped() throws {
        let run = try XCTUnwrap(ScrollInertia(velocity: CGPoint(x: 0, y: 1e6)))
        XCTAssertEqual(run.velocity.y, ScrollInertia.maximumStartSpeed, accuracy: 1e-9)
    }

    func testFrameRateIndependent() throws {
        var a = try XCTUnwrap(ScrollInertia(velocity: CGPoint(x: 0, y: 1000)))
        var b = a
        var da: CGFloat = 0, db: CGFloat = 0
        for _ in 0..<30 { da += a.step(1.0 / 60)?.y ?? 0 }
        for _ in 0..<60 { db += b.step(1.0 / 120)?.y ?? 0 }
        XCTAssertEqual(a.velocity.y, b.velocity.y, accuracy: 1e-6)    // same decay over 0.5 s
        XCTAssertEqual(da, db, accuracy: da * 0.03)                   // ≈ same distance
    }

    func testFinishedRunReturnsNil() throws {
        var run = try XCTUnwrap(ScrollInertia(velocity: CGPoint(x: 0, y: 100)))
        while run.step() != nil {}
        XCTAssertTrue(run.isFinished)
        XCTAssertNil(run.step())
    }
}
