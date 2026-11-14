// Thin wrapper over the system zlib (the SDK ships a `zlib` Clang module that
// links libz). Using real zlib instead of Compression.framework keeps the
// exact semantics the reference relies on via Python's `zlib.decompressobj`:
// zlib-wrapped streams (2-byte header), Z_SYNC_FLUSH framing with no final
// block, and one persistent stream spanning many messages (RFB zlib encoding).
import Foundation
import zlib

enum ZlibError: Error, Equatable {
    case initFailed(Int32)
    case stream(Int32)
}

enum Zlib {
    /// Inflates one complete zlib-wrapped blob on a fresh stream. Accepts
    /// Z_SYNC_FLUSH-terminated input (no final block), like
    /// `zlib.decompressobj().decompress(d) + flush()` in the reference.
    static func inflate(_ data: Data) throws -> Data {
        try Inflater().inflate(data)
    }

    /// A persistent inflate stream: dictionary/window state carries across
    /// `inflate(_:)` calls. Input may be split at arbitrary byte boundaries.
    final class Inflater {
        private var strm = z_stream()

        init() throws {
            let rc = inflateInit_(&strm, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else { throw ZlibError.initFailed(rc) }
        }
        deinit { inflateEnd(&strm) }

        func inflate(_ input: Data) throws -> Data {
            guard !input.isEmpty else { return Data() }
            var out = Data()
            var chunk = [UInt8](repeating: 0, count: max(16_384, input.count * 4))
            let local = Data(input)   // contiguous, 0-based
            try local.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                strm.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
                strm.avail_in = uInt(src.count)
                defer { strm.next_in = nil; strm.avail_in = 0 }
                while true {
                    let produced: Int = try chunk.withUnsafeMutableBytes { dst in
                        strm.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                        strm.avail_out = uInt(dst.count)
                        let rc = zlib.inflate(&strm, Z_SYNC_FLUSH)
                        // Z_BUF_ERROR = no progress possible (input exhausted); not fatal.
                        guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR else { throw ZlibError.stream(rc) }
                        return dst.count - Int(strm.avail_out)
                    }
                    out.append(contentsOf: chunk[0..<produced])
                    // Stop once all input is consumed and the output buffer
                    // wasn't filled (nothing pending), or no progress was made.
                    if strm.avail_out != 0 || produced == 0 { break }
                }
            }
            return out
        }
    }

    /// A persistent deflate stream emitting Z_SYNC_FLUSH-framed chunks,
    /// matching the reference's `zlib.compressobj(level, DEFLATED, 15)` +
    /// `flush(Z_SYNC_FLUSH)`.
    final class Deflater {
        private var strm = z_stream()

        init(level: Int32 = Z_DEFAULT_COMPRESSION) throws {
            let rc = deflateInit2_(&strm, level, Z_DEFLATED, MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else { throw ZlibError.initFailed(rc) }
        }
        deinit { deflateEnd(&strm) }

        func compress(_ input: Data) throws -> Data {
            var out = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let local = Data(input)
            try local.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                strm.next_in = src.isEmpty ? nil
                    : UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
                strm.avail_in = uInt(src.count)
                defer { strm.next_in = nil; strm.avail_in = 0 }
                repeat {
                    let produced: Int = try chunk.withUnsafeMutableBytes { dst in
                        strm.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                        strm.avail_out = uInt(dst.count)
                        let rc = deflate(&strm, Z_SYNC_FLUSH)
                        guard rc == Z_OK || rc == Z_BUF_ERROR else { throw ZlibError.stream(rc) }
                        return dst.count - Int(strm.avail_out)
                    }
                    out.append(contentsOf: chunk[0..<produced])
                } while strm.avail_out == 0
            }
            return out
        }
    }
}
