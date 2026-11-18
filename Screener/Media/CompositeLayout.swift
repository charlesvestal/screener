// Ported in part from iShareScreen src/isharescreen/frontend/desktop/gpu.py
// (Renderer.upload_tile, content_dims, draw) and app.py's slot_h refinement
// (AGPL-3.0).
//
// Where each decoded tile lands on the canvas, and where the canvas lands in
// the view. Apple's encoder splits the canvas into `tileCount` horizontal
// strips, one per SSRC, top to bottom in SSRC order (RFC §10.7). Each strip
// is coded padded up to a CTU boundary, so the decoded strip is usually a few
// rows taller than canvasHeight / tileCount (e.g. 432 vs 427 for 1708 rows):
// the slot height is the decoded strip height (app.py refines slot_h to
// tile.height), strips are stacked at i × slot, and the last one is cut at
// the canvas bottom (upload_tile: rows = min(tile.height, slot, remaining)).
// A strip wider than the canvas is cut at the right edge the same way.
//
// If a decoded picture is already as tall as the canvas, VideoToolbox gave
// us the whole picture (not strips): it is drawn alone, full canvas.
//
// Presentation: the canvas is scaled uniformly to the largest size that fits
// the view and centred (letterbox / pillarbox), as gpu.draw's docstring and
// Apple's viewer do; the image is never stretched.
import CoreGraphics

struct CompositeLayout: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case strips, fullPicture }

    struct Strip: Equatable, Sendable {
        var tile: Int
        /// Destination in canvas pixels.
        var canvasRect: CGRect
        /// Fraction of the decoded image to sample (top-left origin):
        /// < 1 when the strip is cut at the canvas edge.
        var textureExtent: CGSize
    }

    var mode: Mode
    var canvas: CGSize
    var strips: [Strip]

    /// `canvas`: the 0x1c answer's canvas (nil before it is known: then the
    /// strips' own extent is the canvas). `decoded`: one decoded picture's size.
    static func make(canvas: CGSize?, tileCount: Int, decoded: CGSize) -> CompositeLayout {
        let tiles = max(1, tileCount)
        let w = decoded.width, slot = decoded.height
        guard w > 0, slot > 0 else { return CompositeLayout(mode: .strips, canvas: .zero, strips: []) }
        let canvas = canvas.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
            ?? CGSize(width: w, height: slot * CGFloat(tiles))
        if slot >= canvas.height || tiles == 1 {
            let size = CGSize(width: min(w, canvas.width), height: min(slot, canvas.height))
            return CompositeLayout(mode: .fullPicture, canvas: size, strips: [
                Strip(tile: 0, canvasRect: CGRect(origin: .zero, size: size),
                      textureExtent: CGSize(width: size.width / w, height: size.height / slot))])
        }
        var strips: [Strip] = []
        let cols = min(w, canvas.width)
        for i in 0..<tiles {
            let y = CGFloat(i) * slot
            let rows = min(slot, canvas.height - y)
            guard rows > 0 else { break }
            strips.append(Strip(tile: i, canvasRect: CGRect(x: 0, y: y, width: cols, height: rows),
                                textureExtent: CGSize(width: cols / w, height: rows / slot)))
        }
        return CompositeLayout(mode: .strips, canvas: canvas, strips: strips)
    }

    /// The largest rect with `content`'s aspect that fits `bounds`, centred.
    static func aspectFit(_ content: CGSize, in bounds: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// `aspectFit` for a target measured in PIXELS (the drawable), with the
    /// letterbox origin rounded to whole pixels: a half-pixel offset would make
    /// the bilinear sampler blend every pair of neighbouring pixels (a visible
    /// softening at 1:1). The input mapping keeps the unrounded fit (points);
    /// the two differ by at most half a drawable pixel.
    static func pixelAlignedFit(_ content: CGSize, in pixels: CGSize) -> CGRect {
        var fit = aspectFit(content, in: pixels)
        fit.origin = CGPoint(x: fit.minX.rounded(), y: fit.minY.rounded())
        return fit
    }

    /// The canvas lands on the `pixels` target exactly 1:1 (one canvas pixel
    /// per target pixel, whole-pixel origin): it can be sampled
    /// nearest-neighbour, bit-exact. (Fit Retina: canvas = drawable.)
    func isOneToOne(in pixels: CGSize) -> Bool {
        guard canvas.width > 0, canvas.height > 0 else { return false }
        let fit = Self.pixelAlignedFit(canvas, in: pixels)
        return fit.width == canvas.width && fit.height == canvas.height
            && fit.minX == fit.minX.rounded() && fit.minY == fit.minY.rounded()
    }

    /// Where `strip` lands in a target of `bounds` PIXELS (top-left origin;
    /// whole-pixel letterbox origin, `pixelAlignedFit`).
    func viewRect(of strip: Strip, in bounds: CGSize) -> CGRect {
        let fit = Self.pixelAlignedFit(canvas, in: bounds)
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let sx = fit.width / canvas.width, sy = fit.height / canvas.height
        return CGRect(x: fit.minX + strip.canvasRect.minX * sx, y: fit.minY + strip.canvasRect.minY * sy,
                      width: strip.canvasRect.width * sx, height: strip.canvasRect.height * sy)
    }
}
