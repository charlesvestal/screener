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
    /// The inflated output would exceed the caller's `maxOutput` (zlib bomb
    /// or a lying length); inflation stopped at the cap.
    case outputLimit(Int)
}

enum Zlib {
    /// Inflates one complete zlib-wrapped blob on a fresh stream. Accepts
    /// Z_SYNC_FLUSH-terminated input (no final block), like
    /// `zlib.decompressobj().decompress(d) + flush()` in the reference.
    /// `maxOutput` is a hard cap: inflation stops (and throws
    /// `.outputLimit`) as soon as more than `maxOutput` bytes would be
    /// produced, so a small hostile blob can't make us allocate more than
    /// about `maxOutput` + one 16 KB chunk.
    static func inflate(_ data: Data, maxOutput: Int = .max) throws -> Data {
        try Inflater().inflate(data, maxOutput: maxOutput)
    }

    /// A persistent inflate stream: dictionary/window state carries across
    /// `inflate(_:)` calls. Input may be split at arbitrary byte boundaries.
    /// Once the stream reaches Z_STREAM_END (a final block + Adler-32), any
    /// further input — in the same call or later ones — is ignored and yields
    /// no output, like bytes left in Python's `decompressobj().unused_data`.
    final class Inflater {
        /// Heap-pinned: zlib keeps a back-pointer from its internal state to
        /// the z_stream (`state->strm`) and checks it on every call, so the
        /// struct must never move. `&property` inout bridging doesn't
        /// guarantee a stable address.
        private let strm: UnsafeMutablePointer<z_stream>

        init() throws {
            strm = .allocate(capacity: 1)
            strm.initialize(to: z_stream())
            let rc = inflateInit_(strm, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else {
                strm.deinitialize(count: 1); strm.deallocate()
                throw ZlibError.initFailed(rc)
            }
        }
        deinit {
            inflateEnd(strm)
            strm.deinitialize(count: 1); strm.deallocate()
        }

        /// Inflates `input`, throwing `.outputLimit` once this call's output
        /// passes `maxOutput` (the stream is then mid-message and should be
        /// discarded). Memory stays bounded by `maxOutput` + one chunk.
        func inflate(_ input: Data, maxOutput: Int = .max) throws -> Data {
            var out = Data()
            try inflate(input, maxOutput: maxOutput) { out.append(contentsOf: $0) }
            return out
        }

        /// Streaming form: hands each inflated chunk (≤ 1 MB) to `sink` as it
        /// is produced, so a large output never has to be held at once (RFB
        /// zlib rects are blitted straight into the framebuffer). Throws
        /// `.outputLimit` BEFORE handing over a chunk that would take this
        /// call's output past `maxOutput`. Returns the bytes produced.
        @discardableResult
        func inflate(_ input: Data, maxOutput: Int = .max,
                     sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
            guard !input.isEmpty else { return 0 }
            var total = 0
            // Scratch buffer: ≥ 16 KB, ≤ 1 MB (input × 4 in between).
            var chunk = [UInt8](repeating: 0, count: max(16_384, min(input.count, 1 << 18) * 4))
            let local = Data(input)   // contiguous, 0-based
            try local.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                strm.pointee.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
                strm.pointee.avail_in = uInt(src.count)
                defer {
                    strm.pointee.next_in = nil; strm.pointee.avail_in = 0
                    strm.pointee.next_out = nil; strm.pointee.avail_out = 0
                }
                // Output-growth loop: keep draining fixed-size chunks while
                // zlib fills them completely (high-ratio input).
                while true {
                    let filledAll: Bool = try chunk.withUnsafeMutableBytes { dst in
                        strm.pointee.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                        strm.pointee.avail_out = uInt(dst.count)
                        let rc = zlib.inflate(strm, Z_SYNC_FLUSH)
                        // Z_BUF_ERROR = no progress possible (input exhausted); not fatal.
                        guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR else { throw ZlibError.stream(rc) }
                        let produced = dst.count - Int(strm.pointee.avail_out)
                        guard produced <= maxOutput - total else { throw ZlibError.outputLimit(maxOutput) }
                        total += produced
                        if produced > 0 { try sink(UnsafeRawBufferPointer(rebasing: dst[0..<produced])) }
                        // Stop once all input is consumed and the output buffer
                        // wasn't filled (nothing pending), or no progress was made.
                        return strm.pointee.avail_out == 0 && produced > 0
                    }
                    if !filledAll { break }
                }
            }
            return total
        }
    }

    /// A persistent deflate stream emitting Z_SYNC_FLUSH-framed chunks,
    /// matching the reference's `zlib.compressobj(level, DEFLATED, 15)` +
    /// `flush(Z_SYNC_FLUSH)`.
    final class Deflater {
        /// Heap-pinned for the same reason as `Inflater.strm`.
        private let strm: UnsafeMutablePointer<z_stream>

        init(level: Int32 = Z_DEFAULT_COMPRESSION) throws {
            strm = .allocate(capacity: 1)
            strm.initialize(to: z_stream())
            let rc = deflateInit2_(strm, level, Z_DEFLATED, MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else {
                strm.deinitialize(count: 1); strm.deallocate()
                throw ZlibError.initFailed(rc)
            }
        }
        deinit {
            deflateEnd(strm)
            strm.deinitialize(count: 1); strm.deallocate()
        }

        func compress(_ input: Data) throws -> Data {
            var out = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let local = Data(input)
            try local.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                strm.pointee.next_in = src.isEmpty ? nil
                    : UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
                strm.pointee.avail_in = uInt(src.count)
                defer {
                    strm.pointee.next_in = nil; strm.pointee.avail_in = 0
                    strm.pointee.next_out = nil; strm.pointee.avail_out = 0
                }
                repeat {
                    let produced: Int = try chunk.withUnsafeMutableBytes { dst in
                        strm.pointee.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                        strm.pointee.avail_out = uInt(dst.count)
                        let rc = deflate(strm, Z_SYNC_FLUSH)
                        guard rc == Z_OK || rc == Z_BUF_ERROR else { throw ZlibError.stream(rc) }
                        return dst.count - Int(strm.pointee.avail_out)
                    }
                    out.append(contentsOf: chunk[0..<produced])
                } while strm.pointee.avail_out == 0
            }
            return out
        }
    }
}
