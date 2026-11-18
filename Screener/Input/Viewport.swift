// Zoom and pan over the remote screen (Task 22).
//
// The video is drawn aspect-fitted in the view (CompositeLayout.aspectFit);
// the viewport magnifies that picture by `scale` (1× = fit … 4×) and shows
// the region whose top-left corner is `origin`. Everything is in UNIT view
// coordinates (0…1 across the view), so the same viewport maps view points
// (input) and drawable pixels (MetalRenderer) without knowing either size:
//
//   screen = (base − origin·size) · scale          (toScreen)
//   base   = screen / scale + origin·size          (toBase, the inverse)
//
// where "base" is the unzoomed view point and `size` the view's (points or
// pixels — both sides use the same unit).
//
// Clamping: along each axis, if the visible span (1/scale) is narrower than
// the fitted picture the visible region stays inside the picture; otherwise
// it is centred on the picture (no panning into the letterbox). At 1× the
// origin is therefore always (0, 0).
//
// Cursor follow (`follow`): after a relative cursor move, the viewport pans
// so the cursor stays at least `followMargin` (10%) of the visible span from
// each edge — clamped at the picture's edges, where the cursor may reach the
// border.
import CoreGraphics

struct Viewport: Equatable, Sendable {
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 4
    /// The cursor is kept this fraction of the visible span from each edge.
    static let followMargin: CGFloat = 0.10

    /// Zoom (1 = the fitted picture fills its usual rect).
    private(set) var scale: CGFloat = 1
    /// Top-left of the visible region, in unit view coordinates.
    private(set) var origin: CGPoint = .zero

    static let identity = Viewport()

    var isZoomed: Bool { scale > Self.minScale + 0.001 }

    /// The visible region in unit view coordinates.
    var visibleUnitRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: 1 / scale, height: 1 / scale)
    }

    // MARK: mapping

    /// Unzoomed view point → where it is drawn.
    func toScreen(_ p: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: (p.x - origin.x * viewSize.width) * scale, y: (p.y - origin.y * viewSize.height) * scale)
    }

    /// Drawn point → the unzoomed view point under it (toScreen's inverse).
    func toBase(_ s: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: s.x / scale + origin.x * viewSize.width, y: s.y / scale + origin.y * viewSize.height)
    }

    func toScreen(_ r: CGRect, viewSize: CGSize) -> CGRect {
        let o = toScreen(r.origin, viewSize: viewSize)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    // MARK: changes

    /// Zooms by `factor` keeping the picture under `center` (view points) fixed.
    mutating func zoom(by factor: CGFloat, around center: CGPoint, viewSize: CGSize, content: CGRect) {
        guard factor.isFinite, factor > 0, viewSize.width > 0, viewSize.height > 0 else { return }
        let u = CGPoint(x: center.x / viewSize.width, y: center.y / viewSize.height)
        let anchor = CGPoint(x: u.x / scale + origin.x, y: u.y / scale + origin.y)
        let newScale = min(Self.maxScale, max(Self.minScale, scale * factor))
        scale = newScale
        origin = CGPoint(x: anchor.x - u.x / newScale, y: anchor.y - u.y / newScale)
        clamp(viewSize: viewSize, content: content)
    }

    /// Moves the picture with the fingers by `delta` view points.
    mutating func pan(by delta: CGPoint, viewSize: CGSize, content: CGRect) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        origin.x -= delta.x / viewSize.width / scale
        origin.y -= delta.y / viewSize.height / scale
        clamp(viewSize: viewSize, content: content)
    }

    /// Pans so `base` (an unzoomed view point, e.g. the cursor) is at least
    /// `followMargin` of the visible span inside each edge.
    mutating func follow(_ base: CGPoint, viewSize: CGSize, content: CGRect) {
        guard isZoomed, viewSize.width > 0, viewSize.height > 0 else { return }
        let span = 1 / scale, m = span * Self.followMargin
        let p = CGPoint(x: base.x / viewSize.width, y: base.y / viewSize.height)
        if p.x < origin.x + m { origin.x = p.x - m } else if p.x > origin.x + span - m { origin.x = p.x - span + m }
        if p.y < origin.y + m { origin.y = p.y - m } else if p.y > origin.y + span - m { origin.y = p.y - span + m }
        clamp(viewSize: viewSize, content: content)
    }

    /// Pans so `base` (an unzoomed view point) is centred, within the clamp.
    mutating func center(on base: CGPoint, viewSize: CGSize, content: CGRect) {
        guard isZoomed, viewSize.width > 0, viewSize.height > 0 else { return }
        let span = 1 / scale
        origin = CGPoint(x: base.x / viewSize.width - span / 2, y: base.y / viewSize.height - span / 2)
        clamp(viewSize: viewSize, content: content)
    }

    mutating func reset() {
        scale = Self.minScale
        origin = .zero
    }

    private mutating func clamp(viewSize: CGSize, content: CGRect) {
        let span = 1 / scale
        let c = content.width > 0 && content.height > 0
            ? CGRect(x: content.minX / viewSize.width, y: content.minY / viewSize.height,
                     width: content.width / viewSize.width, height: content.height / viewSize.height)
            : CGRect(x: 0, y: 0, width: 1, height: 1)
        func axis(_ o: CGFloat, _ lo: CGFloat, _ len: CGFloat) -> CGFloat {
            len >= span ? min(lo + len - span, max(lo, o)) : lo + len / 2 - span / 2
        }
        origin = CGPoint(x: axis(origin.x, c.minX, c.width), y: axis(origin.y, c.minY, c.height))
        if !isZoomed { origin = .zero; scale = Self.minScale }
    }
}

/// The session's viewport, shared by the input view (which changes it) and
/// the renderer (which draws through it).
@MainActor
final class ViewportModel {
    private(set) var value = Viewport.identity
    /// Bumped on every change; the renderer redraws when it moves.
    private(set) var revision = 0
    /// Called after every change (the renderer's redraw request).
    var onChange: (() -> Void)?

    func update(_ change: (inout Viewport) -> Void) {
        var v = value
        change(&v)
        guard v != value else { return }
        value = v
        revision += 1
        onChange?()
    }
}
