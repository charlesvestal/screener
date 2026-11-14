// Ported in part from iShareScreen src/isharescreen/frontend/desktop/gpu.py
// (Renderer: biplanar pipeline, BT.709 full-range matrix, letterboxed draw)
// (AGPL-3.0)
//
// Draws the latest decoded picture of every tile (VideoFrameStore) into an
// MTKView: each tile's CVPixelBuffer is wrapped as two Metal textures through
// a CVMetalTextureCache (no copies) and drawn as one strip of the
// aspect-fitted canvas (CompositeLayout). Driven by the MTKView at the
// screen's maximum refresh rate; a vsync with nothing new draws nothing (the
// layer keeps showing the last frame).
//
// Colour: the YCbCr matrix comes from the pixel buffer's attachment, which
// VideoToolbox fills from the stream's VUI (Apple's stream: ITU_R_709_2);
// BT.709 when absent, as gpu.py hard-codes. The range comes from the pixel
// format ('444f' = full range, as the reference). Logged once per change.
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
    private let textureCache: CVMetalTextureCache
    private let store: VideoFrameStore
    private var lastVersion: Int?
    private var lastDrawableSize: CGSize = .zero
    private var lastLayout: CompositeLayout?
    private var lastColorDescription = ""
    private var droppedFormatLogged = false
    private(set) var framesDrawn = 0
    /// Called on the main actor after the first picture is presented.
    var onFirstDraw: (() -> Void)?

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    init?(store: VideoFrameStore, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
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
        super.init()
    }

    /// Configures `view` for this renderer.
    func attach(to view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorPixelFormat
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = self
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        let size = view.drawableSize
        let resized = size != lastDrawableSize
        guard let snap = store.snapshot(ifNewerThan: resized ? nil : lastVersion) else { return }
        guard !snap.frames.isEmpty, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard encode(snap, into: pass, size: size, commandBuffer: cmd) else { return }
        cmd.present(drawable)
        cmd.commit()
        CVMetalTextureCacheFlush(textureCache, 0)
        lastVersion = snap.version
        lastDrawableSize = size
        framesDrawn += 1
        if framesDrawn == 1 { onFirstDraw?() }
    }

    /// Encodes the composite of `snap` into `pass` (target `size` pixels).
    /// Returns false when nothing could be drawn.
    @discardableResult
    func encode(_ snap: VideoFrameStore.Snapshot, into pass: MTLRenderPassDescriptor, size: CGSize,
                commandBuffer cmd: MTLCommandBuffer) -> Bool {
        guard size.width > 0, size.height > 0,
              let ref = snap.frames[0] ?? snap.frames.sorted(by: { $0.key < $1.key }).first?.value else { return false }
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
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(pipeline)
        var keep: [CVMetalTexture] = []
        var drew = false
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
            let r = layout.viewRect(of: strip, in: size)
            var u = StripUniforms(
                dstRect: SIMD4(Float(r.minX / size.width * 2 - 1), Float(1 - r.minY / size.height * 2),
                               Float(r.maxX / size.width * 2 - 1), Float(1 - r.maxY / size.height * 2)),
                texExtent: SIMD2(Float(strip.textureExtent.width), Float(strip.textureExtent.height)),
                range: fmt.range, coeffs: matrix.coefficients)
            enc.setVertexBytes(&u, length: MemoryLayout<StripUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<StripUniforms>.stride, index: 0)
            enc.setFragmentTexture(lt, index: 0)
            enc.setFragmentTexture(ct, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            drew = true
        }
        enc.endEncoding()
        // The CVMetalTextures (and through them the pixel buffers) must live
        // until the GPU is done with them.
        let held = TextureHold(keep)
        cmd.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        return drew
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var out: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &out)
        return status == kCVReturnSuccess ? out : nil
    }
}

/// Keeps CVMetalTextures alive until a command buffer completes (read-only).
private final class TextureHold: @unchecked Sendable {
    let textures: [CVMetalTexture]
    init(_ textures: [CVMetalTexture]) { self.textures = textures }
}
