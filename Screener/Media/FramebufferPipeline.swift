// TCP-only fallback (Task 19): ControlSession's pixel events → ZlibRectDecoder
// → a BGRA CVPixelBuffer published to VideoFrameStore as the one tile of a
// one-tile canvas (CompositeLayout draws it as the full picture;
// MetalRenderer's BGRA path samples it directly).
//
// Everything runs on one serial queue, in wire order (the zlib stream is
// persistent). At each FramebufferUpdate end the framebuffer, if anything
// changed, is copied into a fresh pool buffer (the renderer may still be
// sampling the previous one) and published; then `updateConsumed` lets
// ControlSession send the next incremental FramebufferUpdateRequest, so at
// most one update is ever queued here (backpressure).
//
// A broken zlib stream (FramebufferDecodeError) is reported once through
// `failed`; later rects are ignored.
import CoreVideo
import Foundation

final class FramebufferPipeline: @unchecked Sendable {   // mutable state confined to `queue`
    struct Hooks: Sendable {
        /// An update was processed: ask for the next one.
        var updateConsumed: @Sendable () -> Void
        /// The stream is unusable (corrupt zlib, unsupported format, ...).
        var failed: @Sendable (Error) -> Void
    }

    private let queue = DispatchQueue(label: "screener.framebuffer", qos: .userInteractive)
    private let store: VideoFrameStore
    private let epoch: Int
    private let format: RFBPixelFormat
    private let hooks: Hooks
    private var decoder: ZlibRectDecoder?
    private var size: (width: Int, height: Int)
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int)?
    private var seq = 0
    private var decodeTime: Duration = .zero
    private var reportedFailure = false
    private let stopped = LockedValue(false)
    private var published = 0
    private var lastLog = ContinuousClock.now

    /// `size`: the framebuffer until the first 0x451 (backing pixels).
    init(store: VideoFrameStore, format: RFBPixelFormat, size: (width: Int, height: Int), hooks: Hooks) {
        self.store = store
        self.epoch = store.currentEpoch
        self.format = format
        self.size = size
        self.hooks = hooks
        store.configure(tileCount: 1, canvas: CGSize(width: size.width, height: size.height))
    }

    func stop() { stopped.value = true }

    /// Enqueues one control event (pixel rects, layouts, update ends; others ignored).
    func submit(_ event: ServerEvent) {
        switch event {
        case .zlibRect, .rawRect, .framebufferUpdateEnd, .displayLayout: break
        default: return
        }
        queue.async { [self] in
            guard !stopped.value else { return }
            process(event)
        }
    }

    /// Waits until everything submitted so far was processed (tests).
    func drain() { queue.sync {} }

    private func process(_ event: ServerEvent) {
        let started = ContinuousClock.now
        switch event {
        case .displayLayout(let l):
            guard l.backingWidth > 0, l.backingHeight > 0 else { return }
            size = (l.backingWidth, l.backingHeight)
            do {
                try decoder?.resize(width: l.backingWidth, height: l.backingHeight)
            } catch {
                return report(error)
            }
            store.configure(tileCount: 1, canvas: CGSize(width: l.backingWidth, height: l.backingHeight))
        case .zlibRect(let x, let y, let w, let h, let payload):
            guard let d = ensureDecoder() else { return }
            do { try d.decodeZlib(x: x, y: y, w: w, h: h, payload: payload) } catch { return report(error) }
        case .rawRect(let x, let y, let w, let h, let pixels):
            guard let d = ensureDecoder() else { return }
            do {
                try d.decodeRaw(x: x, y: y, w: w, h: h, data: pixels)
            } catch {
                Log.video.error("framebuffer: raw rect \(w)x\(h) dropped: \(error)")
            }
        case .framebufferUpdateEnd:
            if let d = decoder, d.takeDirty() { publish(d) }
            decodeTime = .zero
            hooks.updateConsumed()
            return
        default:
            return
        }
        decodeTime += ContinuousClock.now - started
    }

    private func ensureDecoder() -> ZlibRectDecoder? {
        if let decoder { return decoder.isBroken ? nil : decoder }
        guard !reportedFailure else { return nil }
        do {
            let d = try ZlibRectDecoder(width: size.width, height: size.height, format: format)
            decoder = d
            Log.video.info("framebuffer: decoder ready \(size.width)x\(size.height) "
                           + "(\(format.isNativeBGRA ? "native BGRA" : "converted") pixels)")
            return d
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        Log.video.error("framebuffer: stream failed: \(error)")
        hooks.failed(error)
    }

    // MARK: publishing

    private func publish(_ d: ZlibRectDecoder) {
        guard let pb = makeBuffer(width: d.width, height: d.height) else {
            Log.video.error("framebuffer: no pixel buffer for \(d.width)x\(d.height)")
            return
        }
        let copyStart = ContinuousClock.now
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let dstRow = CVPixelBufferGetBytesPerRow(pb)
            let srcRow = d.width * ZlibRectDecoder.bytesPerPixel
            d.pixels.withUnsafeBytes { src in
                if dstRow == srcRow {
                    base.copyMemory(from: src.baseAddress!, byteCount: srcRow * d.height)
                } else {
                    for r in 0..<d.height {
                        (base + r * dstRow).copyMemory(from: src.baseAddress! + r * srcRow, byteCount: srcRow)
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        seq += 1
        published += 1
        let total = decodeTime + (ContinuousClock.now - copyStart)
        store.publish(DecodedFrame(tile: 0, pixelBuffer: pb, decodeTime: total, don: 0, seq: seq), epoch: epoch)
        let now = ContinuousClock.now
        if published == 1 || now - lastLog >= .seconds(5) {
            lastLog = now
            Log.video.info("framebuffer: published \(published) picture(s) \(d.width)x\(d.height), "
                           + "\(d.rectsDecoded) rect(s) decoded")
        }
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolSize.map({ $0 != (width, height) }) ?? true {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess else { return nil }
        return out
    }
}
