// Picture in Picture: the frame store's picture → one small BGRA image.
//
// The main view draws the decoded tile strips with Metal (MetalRenderer), but
// Picture in Picture keeps running while the app is in the background, where
// iOS refuses GPU command buffers from apps. So the PiP picture is built
// without Metal: each strip is converted and downscaled by a
// VTPixelTransferSession (any decoder output — '444f', '420f', 10-bit, or the
// TCP fallback's BGRA — to BGRA, colour matrix from the buffer's attachments)
// into a scratch buffer, and its rows are copied into the output at the
// strip's place (CompositeLayout's geometry: strip i at i × slot on the
// canvas, the last one cut at the canvas bottom, padding columns cut at the
// right edge). Strips are scaled whole, with one uniform factor, so the cut
// is just "copy fewer rows / columns" — no source crop needed.
//
// Output: at most `maxDimension` pixels on the long side (a PiP window is
// small; 1280 keeps text legible when the user enlarges it), aspect kept,
// even dimensions. Buffers come from CVPixelBufferPools (output and one per
// scratch size), so a steady stream allocates nothing; a resize (display
// mode change, fallback switch) makes new pools and lets the old ones go.
//
// Not thread-safe: PiPFrameFeeder calls it from its one serial queue.
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Where each strip goes in the PiP picture (pure; unit-tested).
struct PiPLayout: Equatable, Sendable {
    struct Size: Equatable, Hashable, Sendable {
        var width: Int
        var height: Int
    }

    struct Placement: Equatable, Sendable {
        var tile: Int
        /// The whole decoded strip, scaled by the layout's factor.
        var scaled: Size
        /// First output row, and how many rows / columns of the scaled strip land.
        var destY: Int
        var rows: Int
        var cols: Int
    }

    var output: Size
    var scale: CGFloat
    var placements: [Placement]

    static let defaultMaxDimension = 1280

    /// `decoded`: one decoded strip's size (all strips of a picture share it).
    static func make(canvas: CGSize?, tileCount: Int, decoded: CGSize,
                     maxDimension: Int = defaultMaxDimension) -> PiPLayout? {
        let layout = CompositeLayout.make(canvas: canvas, tileCount: tileCount, decoded: decoded)
        let c = layout.canvas
        guard c.width >= 1, c.height >= 1, !layout.strips.isEmpty, maxDimension >= 2 else { return nil }
        let scale = min(1, CGFloat(maxDimension) / max(c.width, c.height))
        let out = Size(width: max(2, evenFloor(c.width * scale)), height: max(2, evenFloor(c.height * scale)))
        let scaled = Size(width: max(1, Int((decoded.width * scale).rounded())),
                          height: max(1, Int((decoded.height * scale).rounded())))
        let tops = layout.strips.map { min(out.height, Int(($0.canvasRect.minY * scale).rounded())) }
        var placements: [Placement] = []
        for (i, strip) in layout.strips.enumerated() {
            let top = tops[i]
            let bottom = i + 1 < tops.count ? tops[i + 1] : out.height
            let rows = min(scaled.height, bottom - top)
            guard rows > 0 else { continue }
            placements.append(Placement(tile: strip.tile, scaled: scaled, destY: top, rows: rows,
                                        cols: min(scaled.width, out.width)))
        }
        // The last strip reaches the bottom: a rounding gap of a row would be a black line.
        if var last = placements.popLast() {
            last.rows = min(last.scaled.height, out.height - last.destY)
            placements.append(last)
        }
        return PiPLayout(output: out, scale: scale, placements: placements)
    }

    private static func evenFloor(_ v: CGFloat) -> Int { Int(v.rounded(.down)) & ~1 }
}

final class PiPCompositor {
    let maxDimension: Int
    private var transfer: VTPixelTransferSession?
    private var outputPool: (pool: CVPixelBufferPool, size: PiPLayout.Size)?
    private var scratchPools: [PiPLayout.Size: CVPixelBufferPool] = [:]
    private var failureLogged = false

    init(maxDimension: Int = PiPLayout.defaultMaxDimension) {
        self.maxDimension = maxDimension
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    /// The picture of `snapshot` as one BGRA buffer (nil: nothing to show yet,
    /// or the conversion failed). Tiles missing from it stay black.
    func composite(_ snapshot: VideoFrameStore.Snapshot) -> CVPixelBuffer? {
        guard let first = snapshot.frames[0] ?? snapshot.frames.values.first else { return nil }
        let decoded = CGSize(width: CVPixelBufferGetWidth(first), height: CVPixelBufferGetHeight(first))
        guard let layout = PiPLayout.make(canvas: snapshot.canvas, tileCount: snapshot.tileCount,
                                          decoded: decoded, maxDimension: maxDimension),
              let out = makeOutput(layout.output) else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let dst = CVPixelBufferGetBaseAddress(out) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(out)
        Self.fillOpaqueBlack(dst, stride: dstStride, width: layout.output.width, height: layout.output.height)
        var copied = false
        for p in layout.placements {
            guard let strip = snapshot.frames[p.tile], let scratch = scaled(strip, to: p.scaled) else { continue }
            CVPixelBufferLockBaseAddress(scratch, .readOnly)
            if let src = CVPixelBufferGetBaseAddress(scratch) {
                let srcStride = CVPixelBufferGetBytesPerRow(scratch)
                let rows = min(p.rows, CVPixelBufferGetHeight(scratch))
                let bytes = min(p.cols, CVPixelBufferGetWidth(scratch)) * 4
                for y in 0..<rows {
                    memcpy(dst + (p.destY + y) * dstStride, src + y * srcStride, bytes)
                }
                copied = true
            }
            CVPixelBufferUnlockBaseAddress(scratch, .readOnly)
        }
        guard copied else { return nil }
        Self.copyColorAttachments(from: first, to: out)
        return out
    }

    // MARK: helpers

    /// `buffer` converted to BGRA at `size` (a pool buffer).
    private func scaled(_ buffer: CVPixelBuffer, to size: PiPLayout.Size) -> CVPixelBuffer? {
        guard let session = transferSession(), let pool = scratchPool(size) else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else { return nil }
        let status = VTPixelTransferSessionTransferImage(session, from: buffer, to: dst)
        guard status == noErr else {
            if !failureLogged {
                failureLogged = true
                Log.video.error("pip: pixel transfer failed (\(status)) for "
                                + "\(CVPixelBufferGetPixelFormatType(buffer).fourCC) → BGRA \(size.width)x\(size.height)")
            }
            return nil
        }
        return dst
    }

    private func transferSession() -> VTPixelTransferSession? {
        if let transfer { return transfer }
        var s: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else {
            return nil
        }
        // Downscaling a desktop: favour legibility over speed.
        VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_DownsamplingMode,
                             value: kVTDownsamplingMode_Average)
        transfer = s
        return s
    }

    private func makeOutput(_ size: PiPLayout.Size) -> CVPixelBuffer? {
        if outputPool?.size != size {
            outputPool = Self.makePool(size, minimumBuffers: 3).map { ($0, size) }
            // A new geometry: scratch sizes changed too.
            scratchPools = [:]
        }
        guard let pool = outputPool?.pool else { return nil }
        var pb: CVPixelBuffer?
        // The display layer may still hold the last few: the pool grows as needed.
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    private func scratchPool(_ size: PiPLayout.Size) -> CVPixelBufferPool? {
        if let p = scratchPools[size] { return p }
        let p = Self.makePool(size, minimumBuffers: 1)
        scratchPools[size] = p
        return p
    }

    private static func makePool(_ size: PiPLayout.Size, minimumBuffers: Int) -> CVPixelBufferPool? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: minimumBuffers]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private static func fillOpaqueBlack(_ base: UnsafeMutableRawPointer, stride: Int, width: Int, height: Int) {
        var black: UInt32 = 0xFF00_0000   // BGRA little-endian: B=0 G=0 R=0 A=255
        for y in 0..<height {
            memset_pattern4(base + y * stride, &black, width * 4)
        }
    }

    /// Primaries / transfer function of the source (BGRA has no YCbCr matrix),
    /// so the display layer colour-manages the picture like the main view.
    private static func copyColorAttachments(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let v = CVBufferCopyAttachment(src, key, nil) {
                CVBufferSetAttachment(dst, key, v, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(dst, key)
            }
        }
    }
}

/// Strictly increasing presentation times on the host clock: two pictures
/// composited within one clock tick (or a clock that steps back) still get
/// distinct, ordered timestamps.
struct PiPTimestamps: Sendable {
    /// Smallest step between two timestamps.
    static let minimumStep = CMTime(value: 1, timescale: 1_000_000)
    private var last: CMTime?

    mutating func next(now: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> CMTime {
        var t = now
        if let last, CMTimeCompare(t, last) <= 0 { t = CMTimeAdd(last, Self.minimumStep) }
        last = t
        return t
    }
}

enum PiPSampleBuffer {
    /// `pixelBuffer` as a ready sample buffer shown as soon as it is enqueued.
    static func make(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    static func displaysImmediately(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return false }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as NSDictionary
        return (dict[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool) == true
    }
}
