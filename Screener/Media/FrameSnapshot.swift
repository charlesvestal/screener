// A still image of the latest decoded picture, for the UI: the blurred
// "Reconnecting…" backdrop and the host card thumbnail. Built from the
// VideoFrameStore's presentable set (the strips that make one picture),
// composited exactly as the renderer lays them out (CompositeLayout), then
// downscaled. Core Image does the colour conversion (the decoder outputs
// 4:4:4 bi-planar YCbCr), on a background task — never on the main thread.
//
// The snapshot keeps its CVPixelBuffers alive, so it may be taken just
// before `VideoFrameStore.reset()` drops them (teardown) and rendered after.
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

/// A store snapshot handed to a background task (pixel buffers are
/// immutable once decoded; see DecodedFrame).
struct FrameSnapshot: @unchecked Sendable {
    let frames: [Int: CVPixelBuffer]
    let tileCount: Int
    let canvas: CGSize?

    init?(_ snapshot: VideoFrameStore.Snapshot?) {
        guard let snapshot, !snapshot.frames.isEmpty else { return nil }
        frames = snapshot.frames
        tileCount = snapshot.tileCount
        canvas = snapshot.canvas
    }

    init(frames: [Int: CVPixelBuffer], tileCount: Int, canvas: CGSize?) {
        self.frames = frames
        self.tileCount = tileCount
        self.canvas = canvas
    }

    /// What the store presents now (nil before a first picture).
    static func capture(_ store: VideoFrameStore) -> FrameSnapshot? {
        FrameSnapshot(store.snapshot(ifNewerThan: nil))
    }

    /// Longest side of the image kept for the UI (the backdrop is blurred,
    /// the thumbnail is ~640 px): full canvases would be ~60 MB each.
    static let uiMaxPixels: CGFloat = 1280

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Renders on a background task.
    func image(maxPixels: CGFloat = FrameSnapshot.uiMaxPixels) async -> UIImage? {
        let snap = self
        return await Task.detached(priority: .userInitiated) {
            snap.renderCGImage(maxPixels: maxPixels).map { ImageBox($0) }
        }.value.map { UIImage(cgImage: $0.image) }
    }

    /// Synchronous render (call off the main thread).
    func renderCGImage(maxPixels: CGFloat = FrameSnapshot.uiMaxPixels) -> CGImage? {
        guard let first = frames.values.first else { return nil }
        let decoded = CGSize(width: CVPixelBufferGetWidth(first), height: CVPixelBufferGetHeight(first))
        let layout = CompositeLayout.make(canvas: canvas, tileCount: tileCount, decoded: decoded)
        let size = layout.canvas
        guard size.width >= 1, size.height >= 1 else { return nil }
        var composite = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        for strip in layout.strips {
            guard let pb = frames[strip.tile], let source = Self.ciImage(pb) else { continue }
            let h = CGFloat(CVPixelBufferGetHeight(pb))
            let w = strip.canvasRect.width, rows = strip.canvasRect.height
            // Core Image is bottom-left origin: the strip's top `rows` rows
            // land at canvas y (top-left) `minY`.
            let crop = CGRect(x: 0, y: h - rows, width: w, height: rows)
            let destY = size.height - strip.canvasRect.minY - rows
            let piece = source.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: strip.canvasRect.minX, y: destY - (h - rows)))
            composite = piece.composited(over: composite)
        }
        let scale = min(1, maxPixels / max(size.width, size.height))
        let out = scale < 1
            ? composite.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale,
                                                                                kCIInputAspectRatioKey: 1])
            : composite
        let rect = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(.down),
                          height: (size.height * scale).rounded(.down))
        return Self.context.createCGImage(out, from: rect, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Core Image reads the decoder's formats directly; anything it can't is
    /// converted by VideoToolbox.
    private static func ciImage(_ pb: CVPixelBuffer) -> CIImage? {
        if let img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
            as CIImage?, !img.extent.isEmpty {
            return img
        }
        var cg: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg) == noErr, let cg else { return nil }
        return CIImage(cgImage: cg)
    }
}

private struct ImageBox: @unchecked Sendable {   // CGImage is immutable
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
