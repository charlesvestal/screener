// Host card thumbnails: the last picture of a Mac's session, downscaled to
// ~640 px and kept as HEIC (JPEG where HEIC encoding isn't available) in
// Application Support/Thumbnails/<host id>.<ext>.
//
// Privacy: thumbnails show the Mac's screen, so they stay on this device —
// excluded from backups, never in Documents (which is shared with Files).
// They are deleted with their host, and "Clear Thumbnail(s)" (host context
// menu / host list menu) removes them on demand.
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

/// The files (no UI state; usable from any thread).
struct ThumbnailStore: Sendable {
    static let maxPixels = 640
    static let extensions = ["heic", "jpg"]

    let directory: URL

    static let shared = ThumbnailStore(directory: URL.applicationSupportDirectory
        .appendingPathComponent("Thumbnails", isDirectory: true))

    func url(for id: UUID, ext: String) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    /// The stored file for `id`, if any.
    func existingURL(for id: UUID) -> URL? {
        Self.extensions.map { url(for: id, ext: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Encodes `image` (downscaled to `maxPixels`) and replaces any stored one.
    @discardableResult
    func save(_ image: CGImage, for id: UUID) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        let (data, ext) = try Self.encode(image)
        let target = url(for: id, ext: ext)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        for other in Self.extensions where other != ext { try? fm.removeItem(at: url(for: id, ext: other)) }
        return target
    }

    func load(_ id: UUID) -> UIImage? {
        guard let u = existingURL(for: id), let data = try? Data(contentsOf: u) else { return nil }
        return UIImage(data: data)
    }

    func delete(_ id: UUID) {
        for ext in Self.extensions { try? FileManager.default.removeItem(at: url(for: id, ext: ext)) }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    enum EncodeError: Error { case failed }

    /// HEIC, else JPEG, at most `maxPixels` on the long side.
    static func encode(_ image: CGImage, maxPixels: Int = maxPixels) throws -> (Data, String) {
        for (type, ext) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { continue }
            var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.7]
            // (The max-size option scales small images UP, so only when needed.)
            if max(image.width, image.height) > maxPixels { options[kCGImageDestinationImageMaxPixelSize] = maxPixels }
            CGImageDestinationAddImage(dest, image, options as CFDictionary)
            if CGImageDestinationFinalize(dest), data.length > 0 { return (data as Data, ext) }
        }
        throw EncodeError.failed
    }
}

/// The thumbnails the host list shows (loaded and saved off the main thread).
@MainActor @Observable
final class HostThumbnails {
    private(set) var images: [UUID: UIImage] = [:]
    let store: ThumbnailStore

    init(store: ThumbnailStore = .shared) { self.store = store }

    func image(for id: UUID) -> UIImage? { images[id] }

    /// Loads the stored thumbnails of `ids` not loaded yet.
    func load(_ ids: [UUID]) async {
        let missing = ids.filter { images[$0] == nil }
        guard !missing.isEmpty else { return }
        let store = store
        let loaded = await Task.detached(priority: .userInitiated) {
            missing.compactMap { id in store.load(id).map { (id, ImageBox($0)) } }
        }.value
        for (id, box) in loaded where images[id] == nil { images[id] = box.image }
    }

    /// Stores `image` as `id`'s thumbnail.
    func save(_ image: UIImage, for id: UUID) async {
        guard let cg = image.cgImage else { return }
        let store = store, input = CGImageBox(cg)
        let saved = await Task.detached(priority: .userInitiated) { () -> ImageBox? in
            do {
                try store.save(input.image, for: id)
                return store.load(id).map(ImageBox.init)
            } catch {
                Log.hosts.error("couldn't save the thumbnail for \(id.uuidString): \(error)")
                return nil
            }
        }.value
        if let saved { images[id] = saved.image }
    }

    func remove(_ id: UUID) {
        images[id] = nil
        store.delete(id)
    }

    func removeAll() {
        images = [:]
        store.deleteAll()
        Log.hosts.info("cleared all host thumbnails")
    }
}

private struct ImageBox: @unchecked Sendable {   // UIImage is immutable
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

private struct CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
