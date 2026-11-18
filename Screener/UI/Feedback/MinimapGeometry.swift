// Minimap geometry (pure): where the zoomed viewport sits on the whole
// picture, and where a touch on the minimap points.
//
// "Unit view" coordinates are Viewport's (0…1 across the view); "unit
// content" coordinates are 0…1 across the fitted picture (the aspect-fitted
// canvas inside the view), which is what the minimap shows.
import CoreGraphics

enum MinimapGeometry {
    /// The minimap's longest sides (points).
    static let maxWidth: CGFloat = 200
    static let maxHeight: CGFloat = 130

    /// The fitted picture `content` (view points) in unit view coordinates.
    static func unitContent(_ content: CGRect, viewSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return CGRect(x: content.minX / viewSize.width, y: content.minY / viewSize.height,
                      width: content.width / viewSize.width, height: content.height / viewSize.height)
    }

    /// The visible region `visible` (unit view) as a rect in unit content
    /// coordinates, clipped to the picture (letterbox excluded).
    static func viewportRect(visible: CGRect, content: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let r = CGRect(x: (visible.minX - content.minX) / content.width,
                       y: (visible.minY - content.minY) / content.height,
                       width: visible.width / content.width, height: visible.height / content.height)
        let clipped = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull ? .zero : clipped
    }

    /// A point on a minimap of `size` → unit content coordinates (clamped).
    static func contentPoint(_ p: CGPoint, minimapSize size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, p.y / size.height)))
    }

    /// The minimap's size for a picture of `aspect` (width / height).
    static func size(aspect: CGFloat, maxWidth: CGFloat = maxWidth, maxHeight: CGFloat = maxHeight) -> CGSize {
        guard aspect.isFinite, aspect > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        return aspect >= maxWidth / maxHeight
            ? CGSize(width: maxWidth, height: (maxWidth / aspect).rounded())
            : CGSize(width: (maxHeight * aspect).rounded(), height: maxHeight)
    }
}
