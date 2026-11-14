// Ported from iShareScreen src/isharescreen/proxy/session.py
// (_handle_cursor_rect cache, _notify_cursor) and frontend/desktop/app.py /
// gpu.py (canvas cursor overlay: position, visibility, scale) (AGPL-3.0)
//
// The host's cursor (0x450, RFC §8.3), drawn by MetalRenderer over the video
// at the pointer position the client last sent, minus the hotspot.
// - STORE: w×h BGRA pixmap + separate w×h alpha plane (the BGRA 4th byte is
//   ignored; the reference overwrites A with the mask). Converted once to
//   premultiplied RGBA for the GPU. Cached by id, at most 64 entries;
//   beyond that the oldest-INSERTED id is dropped (oldest-first by first
//   store, as the reference's insertion-ordered dict: re-storing an id keeps
//   its place and selecting does not refresh it — not LRU). Apple uses ~16.
// - SELECT: re-apply a cached id. An id we never received selects nothing
//   (the reference notifies None and falls back to the local OS cursor; the
//   input view shows the system pointer then).
// - The pixmap is in host logical points: the sprite is drawn at
//   size × (view pixels per canvas pixel) × `pointScale` (backing / scaled),
//   as app.py's _cursor_render_scale folds the HiDPI factor back in.
import CoreGraphics
import Foundation

struct CursorImage: Equatable {
    var width: Int
    var height: Int
    var hotspot: PixelPoint
    /// Premultiplied RGBA8, `width * 4` bytes per row.
    var rgba: Data
    /// Distinguishes two stores with identical pixels (texture upload key).
    var serial: Int

    /// BGRA (A ignored) + alpha plane → premultiplied RGBA; nil on a size mismatch.
    static func premultipliedRGBA(bgra: Data, alpha: Data, pixels: Int) -> Data? {
        guard pixels >= 0, bgra.count == pixels * 4, alpha.count == pixels else { return nil }
        var out = Data(count: pixels * 4)
        let src = [UInt8](bgra), a = [UInt8](alpha)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for i in 0..<pixels {
                let al = UInt32(a[i]), o = i * 4
                func pm(_ c: UInt8) -> UInt8 { UInt8((UInt32(c) * al + 127) / 255) }
                dst[o] = pm(src[o + 2])        // R
                dst[o + 1] = pm(src[o + 1])    // G
                dst[o + 2] = pm(src[o])        // B
                dst[o + 3] = a[i]
            }
        }
        return out
    }
}

@MainActor
final class RemoteCursor {
    static let cacheLimit = 64

    /// The selected cursor (nil: none known).
    private(set) var image: CursorImage?
    /// The pointer in host canvas pixels (nil: hidden).
    private(set) var position: CGPoint?
    /// The canvas size `position` is measured in.
    private(set) var hostSize = CGSize.zero
    /// Backing pixels per host logical point (0x451 backing / scaled).
    private(set) var pointScale: CGFloat = 2
    /// Bumped on every visible change; the renderer redraws when it moves.
    private(set) var revision = 0
    /// Called after every visible change (main actor).
    var onChange: (() -> Void)?
    /// Called when the selected cursor's availability (nil ↔ image) flips.
    var onAvailabilityChange: ((Bool) -> Void)?

    private var cache: [UInt32: CursorImage] = [:]
    private var order: [UInt32] = []
    private var serial = 0

    func store(id: UInt32, hotspot: PixelPoint, size: PixelSize, bgra: Data, alpha: Data) {
        guard let rgba = CursorImage.premultipliedRGBA(bgra: bgra, alpha: alpha, pixels: size.width * size.height)
        else {
            Log.input.debug("cursor \(id): size mismatch, ignored")
            return
        }
        serial += 1
        let img = CursorImage(width: size.width, height: size.height, hotspot: hotspot, rgba: rgba, serial: serial)
        if cache.updateValue(img, forKey: id) == nil { order.append(id) }
        if order.count > Self.cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
        setImage(img)
    }

    func select(id: UInt32) {
        if cache[id] == nil { Log.input.debug("cursor cache miss for id \(id)") }
        setImage(cache[id])
    }

    func move(toHostX x: Int, y: Int, hostWidth: Int, hostHeight: Int) {
        let p = CGPoint(x: x, y: y), size = CGSize(width: hostWidth, height: hostHeight)
        guard p != position || size != hostSize else { return }
        position = p
        hostSize = size
        changed()
    }

    func hide() {
        guard position != nil else { return }
        position = nil
        changed()
    }

    func setPointScale(_ scale: CGFloat) {
        guard scale > 0, scale != pointScale else { return }
        pointScale = scale
        changed()
    }

    /// A new session: cache ids are per viewer connection.
    func reset() {
        cache.removeAll()
        order.removeAll()
        position = nil
        setImage(nil)
    }

    private func setImage(_ img: CursorImage?) {
        let wasAvailable = image != nil
        image = img
        changed()
        if wasAvailable != (img != nil) { onAvailabilityChange?(img != nil) }
    }

    private func changed() {
        revision += 1
        onChange?()
    }
}
