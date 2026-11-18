#if DEBUG
// DEBUG-only image-fidelity probe (launch argument `-colorDump <seconds>`):
// that long after the first presented picture, MetalRenderer
//   - logs the presentation geometry (view bounds, contentScaleFactor,
//     drawableSize, layer contentsScale, the aspect-fit rect, each strip's
//     destination rect in drawable pixels, the zoom),
//   - writes, to Library/Caches/ColorDump/:
//       ycc.png      the canvas as raw Y, Cb, Cr code values (in R, G, B; untagged)
//       decoded.png  the same canvas converted on the CPU with the exact shader
//                    maths (YCbCrConversion), tagged with the layer colorspace
//       drawable.png a GPU readback of the drawable actually presented,
//                    tagged with the layer colorspace
//       attachments.txt  every tile's pixel-buffer attachments + pixel format.
// The view is made non-framebufferOnly only when the argument is present.
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal

enum RenderDump {
    /// Seconds after the first draw, or nil when not requested.
    static var requestedDelay: Double? {
        let v = UserDefaults.standard.double(forKey: "colorDump")
        return v > 0 ? v : nil
    }

    static var directory: URL { URL.cachesDirectory.appendingPathComponent("ColorDump", isDirectory: true) }

    static func writePNG(_ bytes: [UInt8], width: Int, height: Int, space: CGColorSpace?, bgra: Bool, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let space = space ?? CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = bgra
            ? CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        let url = directory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        Log.video.info("DEBUG colorDump wrote \(name) \(width)x\(height)")
    }

    /// The canvas composited on the CPU, 1:1 canvas pixels: (raw YCbCr, shader RGB).
    static func cpuComposite(_ snap: VideoFrameStore.Snapshot, layout: CompositeLayout) -> (ycc: [UInt8], rgb: [UInt8], w: Int, h: Int, notes: String) {
        let W = Int(layout.canvas.width), H = Int(layout.canvas.height)
        var ycc = [UInt8](repeating: 0, count: W * H * 4), rgb = ycc
        var notes = ""
        for strip in layout.strips {
            guard let buf = snap.frames[strip.tile] else { continue }
            let type = CVPixelBufferGetPixelFormatType(buf)
            let attachments = CVBufferCopyAttachments(buf, .shouldPropagate) as? [String: Any] ?? [:]
            notes += "tile \(strip.tile) \(type.fourCC) \(CVPixelBufferGetWidth(buf))x\(CVPixelBufferGetHeight(buf)) "
                + "planes=\(CVPixelBufferGetPlaneCount(buf)) attachments=\(attachments)\n"
            guard let fmt = YCbCrFormat.of(type), fmt.lumaFormat == .r8Unorm,
                  CVPixelBufferGetPlaneCount(buf) >= 2,
                  CVPixelBufferGetWidthOfPlane(buf, 1) == CVPixelBufferGetWidth(buf) else { continue }   // 4:4:4 only
            let matrix = YCbCrMatrix.of(buf)
            CVPixelBufferLockBaseAddress(buf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            guard let yb = CVPixelBufferGetBaseAddressOfPlane(buf, 0)?.assumingMemoryBound(to: UInt8.self),
                  let cb = CVPixelBufferGetBaseAddressOfPlane(buf, 1)?.assumingMemoryBound(to: UInt8.self) else { continue }
            let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            let x0 = Int(strip.canvasRect.minX), y0 = Int(strip.canvasRect.minY)
            for j in 0..<Int(strip.canvasRect.height) {
                for i in 0..<Int(strip.canvasRect.width) {
                    let Y = yb[j * ys + i], Cb = cb[j * cs + 2 * i], Cr = cb[j * cs + 2 * i + 1]
                    let o = ((y0 + j) * W + x0 + i) * 4
                    ycc[o] = Y; ycc[o + 1] = Cb; ycc[o + 2] = Cr; ycc[o + 3] = 255
                    let v = YCbCrConversion.rgb8(y: Y, cb: Cb, cr: Cr, format: fmt, matrix: matrix)
                    rgb[o] = v.x; rgb[o + 1] = v.y; rgb[o + 2] = v.z; rgb[o + 3] = 255
                }
            }
        }
        return (ycc, rgb, W, H, notes)
    }
}
#endif
