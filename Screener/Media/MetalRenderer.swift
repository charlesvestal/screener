// Ported in part from iShareScreen src/isharescreen/frontend/desktop/gpu.py
// (Renderer: biplanar pipeline, BT.709 full-range matrix, letterboxed draw)
// (AGPL-3.0)
//
// Draws the latest decoded picture of every tile (VideoFrameStore) into an
// MTKView: each tile's CVPixelBuffer is wrapped as two Metal textures through
// a CVMetalTextureCache (no copies) and drawn as one strip of the
// aspect-fitted canvas (CompositeLayout).
//
// Drawing is on demand (power): the MTKView is paused with
// enableSetNeedsDisplay, and the frame store's `onChange` asks for a redraw
// through a RedrawCoalescer (at most one pending main-queue hop, however many
// tiles publish). A static screen therefore costs no GPU work and no
// drawables. A redraw with nothing drawable marks the version seen and keeps
// the last presented picture on the layer (e.g. behind "Reconnecting…").
//
// Pacing (VideoFrameStore header; OPT-IN: the "Smooth Playback" menu
// toggle, or SCREENER_PACING=1/0 which overrides it — PacingConfig): pictures are queued with due times, so while any is queued
// the view runs its display link (up to the screen's maximum rate) and each
// vsync presents the newest due picture; `pacingIdle` after the queue
// empties it goes back to on-demand drawing. A vsync with nothing new due
// acquires no drawable. Off by default: in the simulator (2026-11-18, host
// load ~20–30) both paced runs starved the app — video receive stalls up to
// 1.4 s, 13–21k packets lost before the app with none missing on the wire —
// while the same runs drawing on arrival were clean; not yet tried on a
// device.
//
// The CAMetalLayer's colorspace is set explicitly from the pixel buffers'
// colour-primaries attachment: Display P3 → displayP3, BT.2020 → itur_2020,
// BT.709 or absent → sRGB (709 and sRGB share primaries, and desktop pixels
// are sRGB-encoded, so the sRGB transfer curve is the faithful one).
//
// Colour: the YCbCr matrix comes from the pixel buffer's attachment, which
// VideoToolbox fills from the stream's VUI (Apple's stream: ITU_R_709_2);
// BT.709 when absent, as gpu.py hard-codes. The range comes from the pixel
// format ('444f' = full range, as the reference). Logged once per change.
//
// Cursor (gpu.py cursor overlay): the host's cursor (RemoteCursor, 0x450)
// is drawn after the strips as one premultiplied-alpha quad at the pointer
// position (host canvas pixels mapped through the same aspect fit), minus
// the hotspot, sized cursor px × (view px per canvas px) × backing/scaled.
// A cursor change (shape, position, visibility) asks for a redraw through
// the same coalescer and forces a redraw of the current picture.
//
// Zoom (Viewport, Task 22): strips and cursor are mapped through the
// session's viewport (scale + origin in unit view coordinates) after the
// aspect fit — the same transform whose inverse InputController uses — so
// the drawn cursor stays on the pointer's host pixel at any zoom. The cursor
// sprite scales with the picture. A viewport change redraws like a cursor
// change.
//
// Touch feedback (FeedbackCenter, UI/Feedback; never touches the decoded
// frame or input mapping):
// - Ripples: while any is visible the composite (strips only) is drawn into
//   an offscreen `scene` texture, then one full-screen pass (`rippleFragment`)
//   samples it displaced around each ripple (≤ 8, a uniform array) onto the
//   drawable; the cursor is drawn after, undistorted. Otherwise the strips go
//   straight to the drawable as before. Ripple centres are BASE view points
//   mapped through the viewport (they stay on their spot of the picture) and
//   scaled to pixels by `pixelsPerPoint`. The scene texture is freed after
//   `sceneIdle` without ripples.
// - Cursor halo / trail: the sprite drawn at haloScale (about its hotspot)
//   over a soft additive glow, after a few fading ghost sprites.
// - Frames: an effect change asks for a redraw (onChange → coalescer); while
//   anything animates the view runs its display link (as pacing does) and a
//   redraw is forced even without a new picture; one more frame is drawn
//   after the last effect ends, so none is left on screen; then it pauses.
// - Minimap: while zoomed the visible region is published to the center on
//   every draw, and a 256-px-wide thumbnail of the picture (strips only,
//   unzoomed) is rendered into a shared texture at most every
//   `thumbnailInterval` (4 Hz) when the picture changed, read back on
//   completion and published as a CGImage.
import CoreVideo
import Metal
import MetalKit
import simd

struct StripUniforms {
    var dstRect: SIMD4<Float>
    var texExtent: SIMD2<Float>
    var pad = SIMD2<Float>(0, 0)
    var range: SIMD4<Float>
    var coeffs: SIMD4<Float>
}

/// How to read one bi-planar pixel format.
struct YCbCrFormat: Equatable {
    var lumaFormat: MTLPixelFormat
    var chromaFormat: MTLPixelFormat
    var fullRange: Bool

    static func of(_ type: OSType) -> YCbCrFormat? {
        switch type {
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
            return .init(lumaFormat: .r8Unorm, chromaFormat: .rg8Unorm, fullRange: true)
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
            return .init(lumaFormat: .r8Unorm, chromaFormat: .rg8Unorm, fullRange: false)
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return .init(lumaFormat: .r16Unorm, chromaFormat: .rg16Unorm, fullRange: true)
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            return .init(lumaFormat: .r16Unorm, chromaFormat: .rg16Unorm, fullRange: false)
        default:
            return nil
        }
    }

    /// (luma offset, luma scale, chroma offset, chroma scale) on normalized values.
    var range: SIMD4<Float> {
        fullRange ? SIMD4(0, 1, 128.0 / 255.0, 1)
                  : SIMD4(16.0 / 255.0, 255.0 / 219.0, 128.0 / 255.0, 255.0 / 224.0)
    }
}

enum YCbCrMatrix: String {
    case bt709 = "BT.709", bt601 = "BT.601", bt2020 = "BT.2020"

    /// From the pixel buffer's kCVImageBufferYCbCrMatrixKey (BT.709 if absent).
    static func of(_ buffer: CVPixelBuffer) -> YCbCrMatrix {
        guard let v = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else { return .bt709 }
        if v == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            || v == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) { return .bt601 }
        if v == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
        return .bt709
    }

    /// R = Y + x·Cr; G = Y − y·Cb − z·Cr; B = Y + w·Cb.
    var coefficients: SIMD4<Float> {
        switch self {
        case .bt709: SIMD4(1.5748, 0.187324, 0.468124, 1.8556)      // gpu.py WGSL_BIPLANAR
        case .bt601: SIMD4(1.402, 0.344136, 0.714136, 1.772)
        case .bt2020: SIMD4(1.4746, 0.164553, 0.571353, 1.8814)
        }
    }
}

@MainActor
final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let ripplePipeline: MTLRenderPipelineState
    private let glowPipeline: MTLRenderPipelineState
    /// Touch feedback effects (nil: none).
    var feedback: FeedbackCenter?
    /// Drawable pixels per view point (set from the view on every draw).
    var pixelsPerPoint: CGFloat = 2
    private var sceneTexture: MTLTexture?
    private var lastRippleAt: Double = 0
    private var lastFeedbackRevision: Int?
    /// The last presented frame carried an effect (one clean frame is owed).
    private var effectsOnScreen = false
    private var thumbTexture: MTLTexture?
    private var lastThumbAt: Double = -.infinity
    private var thumbVersion: Int?
    private var thumbRetryPending = false
    static let thumbnailInterval = 0.25
    static let thumbnailWidth = 256
    /// The scene texture is released after this long without ripples.
    static let sceneIdle = 3.0
    private let cursor: RemoteCursor?
    private var cursorTexture: MTLTexture?
    private var cursorTextureSerial: Int?
    private var lastCursorRevision: Int?
    /// The zoom/pan the picture is drawn through (nil: always fitted).
    var viewport: ViewportModel?
    private var lastViewportRevision: Int?
    private let textureCache: CVMetalTextureCache
    private let store: VideoFrameStore
    private var lastVersion: Int?
    private var lastDrawableSize: CGSize = .zero
    private var lastLayout: CompositeLayout?
    private var lastColorDescription = ""
    private var droppedFormatLogged = false
    private var layerColorSpace: CFString?
    private var coalescer: RedrawCoalescer?
    private var lastQueued: ContinuousClock.Instant?
    private(set) var framesDrawn = 0
    /// Called on the main actor after the first picture is presented.
    var onFirstDraw: (() -> Void)?

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Presentation pacing, read once per renderer (= per session; PacingConfig).
    let pacing: VideoFrameStore.Pacing? = PacingConfig.current()
    /// How long the display link keeps running after the queue empties.
    static let pacingIdle: Duration = .milliseconds(250)

    init?(store: VideoFrameStore, cursor: RemoteCursor? = nil,
          device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else {
            Log.video.error("Metal: no device / command queue")
            return nil
        }
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalRenderer.self))
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "stripVertex")
            desc.fragmentFunction = library.makeFunction(name: "stripFragment")
            desc.colorAttachments[0].pixelFormat = Self.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            let cdesc = MTLRenderPipelineDescriptor()
            cdesc.vertexFunction = library.makeFunction(name: "cursorVertex")
            cdesc.fragmentFunction = library.makeFunction(name: "cursorFragment")
            let att = cdesc.colorAttachments[0]!
            att.pixelFormat = Self.colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            cursorPipeline = try device.makeRenderPipelineState(descriptor: cdesc)
            cdesc.fragmentFunction = library.makeFunction(name: "glowFragment")
            glowPipeline = try device.makeRenderPipelineState(descriptor: cdesc)
            let rdesc = MTLRenderPipelineDescriptor()
            rdesc.vertexFunction = library.makeFunction(name: "postVertex")
            rdesc.fragmentFunction = library.makeFunction(name: "rippleFragment")
            rdesc.colorAttachments[0].pixelFormat = Self.colorPixelFormat
            ripplePipeline = try device.makeRenderPipelineState(descriptor: rdesc)
        } catch {
            Log.video.error("Metal: pipeline creation failed: \(error)")
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            Log.video.error("Metal: CVMetalTextureCacheCreate failed")
            return nil
        }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        self.store = store
        self.cursor = cursor
        super.init()
    }

    /// Configures `view` for this renderer: on-demand drawing, redrawn when
    /// the store changes.
    func attach(to view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorPixelFormat
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = self
        store.setPacing(pacing)
        if pacing != nil {
            view.preferredFramesPerSecond = 120             // capped to the screen's maximum
            Log.video.info("M4 pacing ON (\(PacingConfig.source)): pictures presented on their RTP timeline")
        }
        setLayerColorSpace(CGColorSpace.sRGB, on: view)
        let coalescer = RedrawCoalescer { [weak view] in view?.setNeedsDisplay() }
        self.coalescer = coalescer
        store.setOnChange(owner: self) { coalescer.signal() }
        cursor?.onChange = { coalescer.signal() }
        viewport?.onChange = { coalescer.signal() }
        feedback?.onChange = { coalescer.signal() }
        view.setNeedsDisplay()
    }

    /// Stops redraw requests (the view is going away).
    func detach() {
        store.clearOnChange(owner: self)
        cursor?.onChange = nil
        viewport?.onChange = nil
        feedback?.onChange = nil
        feedback?.setMinimap(nil)
        coalescer = nil
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { view.setNeedsDisplay() }
    }

    /// Layer colorspace for the stream's colour-primaries attachment (see the header).
    nonisolated static func colorSpaceName(primaries: String?) -> CFString {
        let p3 = [kCVImageBufferColorPrimaries_P3_D65, kCVImageBufferColorPrimaries_DCI_P3].map { $0 as String }
        if let primaries, p3.contains(primaries) { return CGColorSpace.displayP3 }
        if primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) { return CGColorSpace.itur_2020 }
        return CGColorSpace.sRGB
    }

    private func setLayerColorSpace(_ name: CFString, on view: MTKView) {
        guard name != layerColorSpace, let layer = view.layer as? CAMetalLayer else { return }
        layerColorSpace = name
        layer.colorspace = CGColorSpace(name: name)
        Log.video.info("M4 layer colorspace: \(name)")
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        defer { updateDisplayLink(view) }
        let size = view.drawableSize
        let resized = size != lastDrawableSize
        let cursorChanged = cursor.map { $0.revision != lastCursorRevision } ?? false
            || viewport.map { $0.revision != lastViewportRevision } ?? false
        if view.bounds.width > 0 { pixelsPerPoint = size.width / view.bounds.width }
        let fxForce = feedback.map {
            $0.revision != lastFeedbackRevision || effectsOnScreen || $0.needsFrames(at: $0.now())
        } ?? false
        guard let snap = store.snapshot(ifNewerThan: resized || cursorChanged || fxForce ? nil : lastVersion)
        else { return }
        guard let ref = snap.frames[0] ?? snap.frames.first?.value else {
            // Nothing drawable (new session, reconnecting): keep the last
            // picture on the layer and don't grab a drawable for this version.
            lastVersion = snap.version
            lastCursorRevision = cursor?.revision
            lastFeedbackRevision = feedback?.revision
            lastDrawableSize = size
            return
        }
        let primaries = CVBufferCopyAttachment(ref, kCVImageBufferColorPrimariesKey, nil) as? String
        setLayerColorSpace(Self.colorSpaceName(primaries: primaries), on: view)
        guard let drawable = view.currentDrawable else {
            // No drawable right now (e.g. the layer isn't sized/visible yet):
            // ask for another pass rather than silently dropping this frame —
            // `lastVersion` is left as-is, so the next draw sees it as new again.
            view.setNeedsDisplay()
            return
        }
        guard let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard encode(snap, into: pass, size: size, commandBuffer: cmd) else {
            lastVersion = snap.version
            lastCursorRevision = cursor?.revision
            lastFeedbackRevision = feedback?.revision
            lastViewportRevision = viewport?.revision
            lastDrawableSize = size
            return
        }
        cmd.present(drawable)
        cmd.commit()
        if snap.version != lastVersion { store.noteDrawn(changedAt: snap.changedAt, rtpTimestamp: snap.rtpTimestamp) }
        CVMetalTextureCacheFlush(textureCache, 0)
        lastVersion = snap.version
        lastCursorRevision = cursor?.revision
        lastFeedbackRevision = feedback?.revision
        lastViewportRevision = viewport?.revision
        lastDrawableSize = size
        framesDrawn += 1
        if framesDrawn == 1 { onFirstDraw?() }
    }

    /// Runs the view's display link while paced pictures are queued (back
    /// to on-demand drawing `pacingIdle` after the queue empties) or while a
    /// feedback effect animates (or one last clean frame is owed).
    private func updateDisplayLink(_ view: MTKView) {
        var want = false
        if let feedback {
            let t = feedback.now()
            want = feedback.needsFrames(at: t) || (effectsOnScreen && feedback.gpuState(at: t).isEmpty)
        }
        if pacing != nil {
            let now = ContinuousClock.now
            if store.nextDue != nil {
                lastQueued = now
                want = true
            } else if !view.isPaused, let q = lastQueued, now - q < Self.pacingIdle {
                want = true
            }
        }
        if want, view.isPaused {
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        } else if !want, !view.isPaused {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
    }

    /// One strip ready to draw: its textures and uniforms (dstRect is
    /// filled per target).
    private struct PreparedStrip {
        var strip: CompositeLayout.Strip
        var luma: MTLTexture
        var chroma: MTLTexture
        var uniforms: StripUniforms
    }

    /// Wraps the tiles of `snap` as textures; nil when nothing is drawable.
    private func prepare(_ snap: VideoFrameStore.Snapshot, keep: inout [CVMetalTexture])
        -> (layout: CompositeLayout, strips: [PreparedStrip])? {
        guard let ref = snap.frames[0] ?? snap.frames.sorted(by: { $0.key < $1.key }).first?.value else { return nil }
        let decoded = CGSize(width: CVPixelBufferGetWidth(ref), height: CVPixelBufferGetHeight(ref))
        let layout = CompositeLayout.make(canvas: snap.canvas, tileCount: snap.tileCount, decoded: decoded)
        if layout != lastLayout {
            lastLayout = layout
            switch layout.mode {
            case .strips:
                Log.video.info("M4 composite: \(layout.strips.count) strips of \(Int(decoded.width))x\(Int(decoded.height)) "
                    + "stacked into canvas \(Int(layout.canvas.width))x\(Int(layout.canvas.height)) (RFC 10.7)")
            case .fullPicture:
                Log.video.info("M4 composite: VideoToolbox outputs the full picture "
                    + "\(Int(decoded.width))x\(Int(decoded.height)); drawn directly")
            }
        }
        var out: [PreparedStrip] = []
        for strip in layout.strips {
            guard let buffer = snap.frames[strip.tile] else { continue }   // never arrived: stays black
            let type = CVPixelBufferGetPixelFormatType(buffer)
            guard let fmt = YCbCrFormat.of(type), CVPixelBufferGetPlaneCount(buffer) >= 2 else {
                if !droppedFormatLogged {
                    droppedFormatLogged = true
                    Log.video.error("Metal: unsupported pixel format \(type.fourCC); not drawn")
                }
                continue
            }
            guard let luma = texture(buffer, plane: 0, format: fmt.lumaFormat),
                  let chroma = texture(buffer, plane: 1, format: fmt.chromaFormat),
                  let lt = CVMetalTextureGetTexture(luma), let ct = CVMetalTextureGetTexture(chroma) else { continue }
            keep += [luma, chroma]
            let matrix = YCbCrMatrix.of(buffer)
            let colorDescription = "pixfmt=\(type.fourCC) matrix=\(matrix.rawValue) range=\(fmt.fullRange ? "full" : "video")"
            if colorDescription != lastColorDescription {
                lastColorDescription = colorDescription
                Log.video.info("M4 render colour: \(colorDescription)")
            }
            let u = StripUniforms(
                dstRect: .zero,
                texExtent: SIMD2(Float(strip.textureExtent.width), Float(strip.textureExtent.height)),
                range: fmt.range, coeffs: matrix.coefficients)
            out.append(PreparedStrip(strip: strip, luma: lt, chroma: ct, uniforms: u))
        }
        return (layout, out)
    }

    /// Draws `strips` aspect-fitted into a `size` target through `zoom`.
    private func drawStrips(_ enc: MTLRenderCommandEncoder, _ strips: [PreparedStrip], layout: CompositeLayout,
                            size: CGSize, zoom: Viewport) {
        enc.setRenderPipelineState(pipeline)
        for p in strips {
            let r = zoom.toScreen(layout.viewRect(of: p.strip, in: size), viewSize: size)
            var u = p.uniforms
            u.dstRect = SIMD4(Float(r.minX / size.width * 2 - 1), Float(1 - r.minY / size.height * 2),
                              Float(r.maxX / size.width * 2 - 1), Float(1 - r.maxY / size.height * 2))
            enc.setVertexBytes(&u, length: MemoryLayout<StripUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<StripUniforms>.stride, index: 0)
            enc.setFragmentTexture(p.luma, index: 0)
            enc.setFragmentTexture(p.chroma, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Encodes the composite of `snap` into `pass` (target `size` pixels),
    /// with the feedback effects of this instant. Returns false when
    /// nothing could be drawn.
    @discardableResult
    func encode(_ snap: VideoFrameStore.Snapshot, into pass: MTLRenderPassDescriptor, size: CGSize,
                commandBuffer cmd: MTLCommandBuffer) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        var keep: [CVMetalTexture] = []
        guard let (layout, strips) = prepare(snap, keep: &keep) else { return false }
        let zoom = viewport?.value ?? .identity
        let fxNow = feedback?.now() ?? 0
        let fx = feedback?.gpuState(at: fxNow) ?? FeedbackCenter.GPUState()
        let drew = !strips.isEmpty
        let scene = fx.ripples.isEmpty ? nil : sceneTarget(size)
        if let scene {
            // Ripples: the picture into the scene texture, then displaced onto the target.
            lastRippleAt = fxNow
            let sp = MTLRenderPassDescriptor()
            sp.colorAttachments[0].texture = scene
            sp.colorAttachments[0].loadAction = .clear
            sp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            sp.colorAttachments[0].storeAction = .store
            guard let senc = cmd.makeRenderCommandEncoder(descriptor: sp) else { return false }
            drawStrips(senc, strips, layout: layout, size: size, zoom: zoom)
            senc.endEncoding()
        } else if sceneTexture != nil, fxNow - lastRippleAt > Self.sceneIdle {
            sceneTexture = nil
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if let scene {
            drawRipples(enc, scene: scene, ripples: fx.ripples, size: size, zoom: zoom)
        } else {
            drawStrips(enc, strips, layout: layout, size: size, zoom: zoom)
        }
        if drew { drawCursor(enc, canvas: layout.canvas, size: size, viewport: zoom, fx: fx) }
        enc.endEncoding()
        effectsOnScreen = drew && !fx.isEmpty
        if drew { updateMinimap(snap: snap, layout: layout, strips: strips, size: size, zoom: zoom, cmd: cmd) }
        // The CVMetalTextures (and through them the pixel buffers) must live
        // until the GPU is done with them.
        let held = TextureHold(keep)
        cmd.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        return drew
    }

    /// The offscreen target the picture is drawn into under ripples.
    private func sceneTarget(_ size: CGSize) -> MTLTexture? {
        let w = Int(size.width), h = Int(size.height)
        if let t = sceneTexture, t.width == w, t.height == h { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorPixelFormat, width: w, height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        sceneTexture = device.makeTexture(descriptor: desc)
        return sceneTexture
    }

    /// Ripple uniforms: [size.x, size.y, count, 0] then per ripple
    /// [cx, cy, radius, amplitude] [width, highlight, 0, 0] [tint.rgb, 0]
    /// (pixels). Shaders.metal `rippleFragment`.
    static func rippleUniforms(_ ripples: [RippleSample], size: CGSize, pixelsPerPoint k: CGFloat,
                               zoom: Viewport) -> [SIMD4<Float>] {
        let list = ripples.prefix(RippleField.maxCount)
        var u: [SIMD4<Float>] = [SIMD4(Float(size.width), Float(size.height), Float(list.count), 0)]
        for r in list {
            let c = zoom.toScreen(CGPoint(x: r.center.x * k, y: r.center.y * k), viewSize: size)
            u.append(SIMD4(Float(c.x), Float(c.y), Float(r.radius * k), Float(r.amplitude * k)))
            u.append(SIMD4(Float(max(1, r.width * k)), Float(r.highlight), 0, 0))
            u.append(SIMD4(r.tint, 0))
        }
        while u.count < 1 + 3 * RippleField.maxCount { u.append(.zero) }
        return u
    }

    private func drawRipples(_ enc: MTLRenderCommandEncoder, scene: MTLTexture, ripples: [RippleSample],
                             size: CGSize, zoom: Viewport) {
        var u = Self.rippleUniforms(ripples, size: size, pixelsPerPoint: pixelsPerPoint, zoom: zoom)
        enc.setRenderPipelineState(ripplePipeline)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * u.count, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: minimap

    /// While zoomed: publishes the visible region and, at most every
    /// `thumbnailInterval` when the picture changed, renders a thumbnail.
    private func updateMinimap(snap: VideoFrameStore.Snapshot, layout: CompositeLayout, strips: [PreparedStrip],
                               size: CGSize, zoom: Viewport, cmd: MTLCommandBuffer) {
        guard let feedback else { return }
        guard zoom.isZoomed, layout.canvas.width > 0, layout.canvas.height > 0 else {
            feedback.setMinimap(nil)
            thumbVersion = nil
            thumbTexture = nil
            return
        }
        let content = MinimapGeometry.unitContent(CompositeLayout.aspectFit(layout.canvas, in: size), viewSize: size)
        feedback.setMinimap(.init(aspect: layout.canvas.width / layout.canvas.height,
                                  viewport: MinimapGeometry.viewportRect(visible: zoom.visibleUnitRect,
                                                                         content: content)))
        guard snap.version != thumbVersion || feedback.thumbnail == nil else { return }
        let now = feedback.now()
        let wait = Self.thumbnailInterval - (now - lastThumbAt)
        guard wait <= 0 else {
            // Too soon: come back for it (a static picture draws nothing more).
            if !thumbRetryPending {
                thumbRetryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.thumbRetryPending = false
                        self.coalescer?.signal()
                        self.lastFeedbackRevision = nil          // force a redraw of the same picture
                    }
                }
            }
            return
        }
        let w = Self.thumbnailWidth
        let h = max(1, Int((CGFloat(w) * layout.canvas.height / layout.canvas.width).rounded()))
        if thumbTexture?.width != w || thumbTexture?.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorPixelFormat, width: w, height: h,
                                                                mipmapped: false)
            desc.usage = [.renderTarget]
            desc.storageMode = .shared
            thumbTexture = device.makeTexture(descriptor: desc)
        }
        guard let tex = thumbTexture else { return }
        let tp = MTLRenderPassDescriptor()
        tp.colorAttachments[0].texture = tex
        tp.colorAttachments[0].loadAction = .clear
        tp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        tp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: tp) else { return }
        drawStrips(enc, strips, layout: layout, size: CGSize(width: w, height: h), zoom: .identity)
        enc.endEncoding()
        thumbVersion = snap.version
        lastThumbAt = now
        let box = TextureBox(tex)
        cmd.addCompletedHandler { [weak feedback] _ in
            let image = Self.cgImage(box.texture)
            let sendable = ImageBox(image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { feedback?.setThumbnail(sendable.image) }
            }
        }
    }

    /// A BGRA8 shared texture → CGImage (sRGB).
    nonisolated static func cgImage(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height, row = w * 4
        var bytes = [UInt8](repeating: 0, count: row * h)
        bytes.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: cursor

    private func drawCursor(_ enc: MTLRenderCommandEncoder, canvas: CGSize, size: CGSize, viewport: Viewport,
                            fx: FeedbackCenter.GPUState) {
        guard let cursor, let img = cursor.image, let pos = cursor.position, img.width > 0, img.height > 0
        else { return }
        let host = cursor.hostSize.width > 0 && cursor.hostSize.height > 0 ? cursor.hostSize : canvas
        let fit = CompositeLayout.aspectFit(host, in: size)
        guard fit.width > 0, let tex = cursorTexture(for: img) else { return }
        let scl = fit.width / host.width * viewport.scale      // view px per canvas px (zoomed)
        let d = scl * cursor.pointScale
        let p = viewport.toScreen(CGPoint(x: fit.minX + pos.x * fit.width / host.width,
                                          y: fit.minY + pos.y * fit.height / host.height), viewSize: size)
        func ndc(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> SIMD4<Float> {
            SIMD4(Float(x0 / size.width * 2 - 1), Float(1 - y0 / size.height * 2),
                  Float(x1 / size.width * 2 - 1), Float(1 - y1 / size.height * 2))
        }
        /// The sprite with its hotspot at `at`, scaled by `s`, at `alpha`.
        func sprite(at a: CGPoint, scale s: CGFloat, alpha: Float) {
            var alpha = alpha
            let x0 = a.x - CGFloat(img.hotspot.x) * d * s, y0 = a.y - CGFloat(img.hotspot.y) * d * s
            var rect = ndc(x0, y0, x0 + CGFloat(img.width) * d * s, y0 + CGFloat(img.height) * d * s)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if fx.haloGlow > 0 {
            // Soft glow centred between the hotspot and the sprite's middle.
            let mid = CGPoint(x: p.x + (CGFloat(img.width) / 2 - CGFloat(img.hotspot.x)) * d * 0.5,
                              y: p.y + (CGFloat(img.height) / 2 - CGFloat(img.hotspot.y)) * d * 0.5)
            let r = 30 * pixelsPerPoint * (0.8 + 0.4 * fx.haloGlow)
            var rect = ndc(mid.x - r, mid.y - r, mid.x + r, mid.y + r)
            var color = SIMD4<Float>(0.75, 0.88, 1, 0.45 * Float(fx.haloGlow))
            enc.setRenderPipelineState(glowPipeline)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.setRenderPipelineState(cursorPipeline)
        enc.setFragmentTexture(tex, index: 0)
        let k = pixelsPerPoint
        for g in fx.ghosts {
            sprite(at: viewport.toScreen(CGPoint(x: g.point.x * k, y: g.point.y * k), viewSize: size),
                   scale: 1, alpha: g.alpha)
        }
        sprite(at: p, scale: fx.haloScale, alpha: 1)
    }

    private func cursorTexture(for img: CursorImage) -> MTLTexture? {
        if cursorTextureSerial == img.serial, let t = cursorTexture { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width,
                                                            height: img.height, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        img.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tex.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0,
                        withBytes: base, bytesPerRow: img.width * 4)
        }
        cursorTexture = tex
        cursorTextureSerial = img.serial
        return tex
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var out: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &out)
        return status == kCVReturnSuccess ? out : nil
    }
}

/// Turns any number of `signal()`s (from any thread) into at most one pending
/// main-queue call of `fire`. A signal that arrives while `fire` runs
/// schedules another call, so no change is ever missed.
final class RedrawCoalescer: @unchecked Sendable {   // `pending` behind `lock`
    private let lock = NSLock()
    private var pending = false
    private let fire: @MainActor () -> Void
    private(set) var fired = 0

    init(fire: @escaping @MainActor () -> Void) { self.fire = fire }

    func signal() {
        let schedule = lock.withLock { () -> Bool in
            if pending { return false }
            pending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.withLock { pending = false; fired += 1 }
            MainActor.assumeIsolated { fire() }
        }
    }
}

/// Carries a texture into a completion handler (read only after the GPU is done).
private final class TextureBox: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
}

/// Carries a CGImage to the main actor (immutable).
private final class ImageBox: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

/// Keeps CVMetalTextures alive until a command buffer completes (read-only).
private final class TextureHold: @unchecked Sendable {
    let textures: [CVMetalTexture]
    init(_ textures: [CVMetalTexture]) { self.textures = textures }
}
