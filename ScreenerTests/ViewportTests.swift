import CoreGraphics
import XCTest
@testable import Screener

final class ViewportTests: XCTestCase {
    private let view = CGSize(width: 1000, height: 800)
    /// A 16:10 picture filling the width: letterboxed top and bottom.
    private let fit = CGRect(x: 0, y: 87.5, width: 1000, height: 625)

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testIdentityMapsEveryPointToItself() {
        let v = Viewport.identity
        assertPoint(v.toScreen(CGPoint(x: 123, y: 456), viewSize: view), CGPoint(x: 123, y: 456))
        assertPoint(v.toBase(CGPoint(x: 9, y: 7), viewSize: view), CGPoint(x: 9, y: 7))
        XCTAssertFalse(v.isZoomed)
    }

    func testZoomKeepsThePointUnderThePinchCentreFixed() {
        var v = Viewport()
        let centre = CGPoint(x: 600, y: 400)
        let before = v.toBase(centre, viewSize: view)
        v.zoom(by: 2, around: centre, viewSize: view, content: fit)
        XCTAssertEqual(v.scale, 2)
        assertPoint(v.toScreen(before, viewSize: view), centre)
        assertPoint(v.toBase(centre, viewSize: view), before)
        // Again, from the zoomed state, around another point.
        let c2 = CGPoint(x: 300, y: 500)
        let b2 = v.toBase(c2, viewSize: view)
        v.zoom(by: 1.5, around: c2, viewSize: view, content: fit)
        assertPoint(v.toScreen(b2, viewSize: view), c2)
    }

    func testScaleIsClampedBetweenFitAndFourTimes() {
        var v = Viewport()
        v.zoom(by: 10, around: CGPoint(x: 500, y: 400), viewSize: view, content: fit)
        XCTAssertEqual(v.scale, Viewport.maxScale)
        v.zoom(by: 0.01, around: CGPoint(x: 500, y: 400), viewSize: view, content: fit)
        XCTAssertEqual(v.scale, Viewport.minScale)
        XCTAssertEqual(v.origin, .zero)
    }

    func testZoomNearTheEdgeIsClampedInsideThePicture() {
        var v = Viewport()
        v.zoom(by: 2, around: CGPoint(x: 0, y: 87.5), viewSize: view, content: fit)
        let visible = v.visibleUnitRect
        XCTAssertEqual(visible.minX, 0, accuracy: 1e-9)
        // The picture spans y 0.109…0.891 (unit); the visible half sits inside it.
        XCTAssertGreaterThanOrEqual(visible.minY, fit.minY / view.height - 1e-9)
        XCTAssertLessThanOrEqual(visible.maxY, fit.maxY / view.height + 1e-9)
    }

    func testANarrowPictureStaysCentredWhileItFitsTheVisibleSpan() {
        // Pillarbox: picture 0.75 wide. At 1.2× the visible span (0.833) is
        // still wider, so the picture stays centred horizontally.
        let narrow = CGRect(x: 125, y: 0, width: 750, height: 800)
        var v = Viewport()
        v.zoom(by: 1.2, around: CGPoint(x: 900, y: 400), viewSize: view, content: narrow)
        XCTAssertEqual(v.visibleUnitRect.midX, 0.5, accuracy: 1e-9)
    }

    func testPanMovesWithTheFingersAndClamps() {
        var v = Viewport()
        v.zoom(by: 2, around: CGPoint(x: 500, y: 400), viewSize: view, content: fit)
        let o = v.origin
        v.pan(by: CGPoint(x: 100, y: 0), viewSize: view, content: fit)
        XCTAssertEqual(v.origin.x, o.x - 100 / 1000 / 2, accuracy: 1e-9)  // content moved right
        v.pan(by: CGPoint(x: 10_000, y: 0), viewSize: view, content: fit)
        XCTAssertEqual(v.origin.x, 0, accuracy: 1e-9)
    }

    func testCursorFollowKeepsTheCursorInsideTenPercentMargins() {
        var v = Viewport()
        v.zoom(by: 4, around: CGPoint(x: 500, y: 400), viewSize: view, content: fit)
        // Visible: 250×200 view points centred on (500, 400): x 375…625.
        let inside = CGPoint(x: 500, y: 400)
        let before = v
        v.follow(inside, viewSize: view, content: fit)
        XCTAssertEqual(v, before, "a cursor well inside does not pan")

        let right = CGPoint(x: 640, y: 400)                       // beyond the right edge
        v.follow(right, viewSize: view, content: fit)
        let s = v.toScreen(right, viewSize: view)
        XCTAssertEqual(s.x, view.width * 0.9, accuracy: 1e-6, "pinned at the 10% margin")

        let up = CGPoint(x: 640, y: 300)
        v.follow(up, viewSize: view, content: fit)
        XCTAssertEqual(v.toScreen(up, viewSize: view).y, view.height * 0.1, accuracy: 1e-6)
    }

    func testCursorFollowClampsAtThePictureEdge() {
        var v = Viewport()
        v.zoom(by: 2, around: CGPoint(x: 500, y: 400), viewSize: view, content: fit)
        let corner = CGPoint(x: 999, y: fit.maxY - 1)
        v.follow(corner, viewSize: view, content: fit)
        XCTAssertEqual(v.visibleUnitRect.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(v.visibleUnitRect.maxY, fit.maxY / view.height, accuracy: 1e-9)
        // The cursor reaches the very edge, past the margin: still visible.
        let s = v.toScreen(corner, viewSize: view)
        XCTAssertLessThanOrEqual(s.x, view.width)
        XCTAssertLessThanOrEqual(s.y, view.height)
    }

    func testFollowDoesNothingAtFit() {
        var v = Viewport()
        v.follow(CGPoint(x: 1, y: 1), viewSize: view, content: fit)
        XCTAssertEqual(v, .identity)
    }

    func testResetReturnsToFit() {
        var v = Viewport()
        v.zoom(by: 3, around: CGPoint(x: 100, y: 100), viewSize: view, content: fit)
        v.reset()
        XCTAssertEqual(v, .identity)
    }

    func testRendererRectAndInputInverseAgreeInPixels() {
        // The renderer maps drawable-pixel rects; input maps view points.
        // Unit coordinates make both the same transform.
        var v = Viewport()
        v.zoom(by: 2.5, around: CGPoint(x: 700, y: 300), viewSize: view, content: fit)
        let pixels = CGSize(width: 2000, height: 1600)
        let basePt = CGPoint(x: 640, y: 333)
        let screenPt = v.toScreen(basePt, viewSize: view)
        let screenPx = v.toScreen(CGPoint(x: basePt.x * 2, y: basePt.y * 2), viewSize: pixels)
        assertPoint(screenPx, CGPoint(x: screenPt.x * 2, y: screenPt.y * 2))
        let r = v.toScreen(CGRect(x: 10, y: 20, width: 30, height: 40), viewSize: view)
        XCTAssertEqual(r.width, 75, accuracy: 1e-9)
        assertPoint(v.toBase(r.origin, viewSize: view), CGPoint(x: 10, y: 20))
    }

    @MainActor
    func testModelBumpsRevisionOnlyOnChange() {
        let m = ViewportModel()
        var calls = 0
        m.onChange = { calls += 1 }
        m.update { $0.reset() }
        XCTAssertEqual(m.revision, 0)
        m.update { $0.zoom(by: 2, around: .zero, viewSize: CGSize(width: 10, height: 10),
                           content: CGRect(x: 0, y: 0, width: 10, height: 10)) }
        XCTAssertEqual(m.revision, 1)
        XCTAssertEqual(calls, 1)
    }
}

/// InputController's mapping through the viewport's inverse.
@MainActor
final class ViewportInputMappingTests: XCTestCase {
    private func controller() -> InputController {
        InputController(contentKey: nil, serverWidth: 1600, serverHeight: 1000, send: { _ in })
    }

    func testZoomedTapMapsToTheHostPixelDrawnUnderIt() throws {
        let c = controller()
        let view = CGSize(width: 1600, height: 1000)                // fit = whole view, 1 pt = 1 px
        var v = Viewport()
        v.zoom(by: 2, around: CGPoint(x: 800, y: 500), viewSize: view, content: c.fittedRect(in: view))
        // At 2× around the centre, the view's top-left shows host (400, 250).
        let tl = try XCTUnwrap(c.hostPoint(forViewPoint: .zero, viewSize: view, viewport: v))
        XCTAssertEqual(tl.x, 400)
        XCTAssertEqual(tl.y, 250)
        let centre = try XCTUnwrap(c.hostPoint(forViewPoint: CGPoint(x: 800, y: 500), viewSize: view, viewport: v))
        XCTAssertEqual(centre.x, 800)
        XCTAssertEqual(centre.y, 500)
    }

    func testHostToViewRoundTripsThroughTheViewport() throws {
        let c = controller()
        let view = CGSize(width: 1194, height: 834)                 // letterboxed
        var v = Viewport()
        v.zoom(by: 3, around: CGPoint(x: 300, y: 600), viewSize: view, content: c.fittedRect(in: view))
        for (x, y) in [(0, 0), (517, 333), (1599, 999), (900, 640)] {
            let base = try XCTUnwrap(c.baseViewPoint(forHostX: CGFloat(x), y: CGFloat(y), viewSize: view))
            let screen = v.toScreen(base, viewSize: view)
            let back = try XCTUnwrap(c.hostPoint(forViewPoint: screen, viewSize: view, viewport: v))
            XCTAssertEqual(back.x, x)
            XCTAssertEqual(back.y, y)
        }
    }

    func testFingerTravelShrinksWithZoom() {
        let c = controller()
        let view = CGSize(width: 800, height: 500)                  // 2 host px per point
        XCTAssertEqual(c.hostPixelsPerPoint(viewSize: view), 2, accuracy: 1e-9)
        XCTAssertEqual(c.hostPixelsPerPoint(viewSize: view, zoom: 4), 0.5, accuracy: 1e-9)
        c.pointScale = 2
        XCTAssertEqual(c.scrollTicksPerPoint(viewSize: view, zoom: 2),
                       c.scrollTicksPerPoint(viewSize: view) / 2, accuracy: 1e-9)
    }
}
