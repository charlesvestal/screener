// Minimal binary-plist ("bplist00") writer that reproduces CPython's
// `plistlib.dumps(value, fmt=plistlib.FMT_BINARY)` byte-for-byte
// (default sort_keys=True) for the types the protocol needs.
//
// Foundation's PropertyListSerialization emits the same format but orders
// dictionary keys by hash rather than sorted, so its bytes differ from the
// reference's offers; the fixtures are authoritative, hence this writer.
// Reading plists is left to PropertyListSerialization.
//
// plistlib's algorithm, mirrored here:
//   * objects are flattened depth-first pre-order; a dict lists its sorted
//     keys then its values; scalars (string/int/bool/data) are uniqued by
//     (type, value), containers never are
//   * ref size = smallest of 1/2/4/8 bytes holding the object count;
//     offset size = smallest holding the offset-table offset
//   * trailer: 6 zero bytes, offset size, ref size, u64 count, u64 top (0),
//     u64 offset-table offset
import Foundation

enum BinaryPlist {
    indirect enum Value: Hashable, Sendable {
        case bool(Bool)
        case int(Int64)
        case string(String)
        case data(Data)
        case array([Value])
        case dict([String: Value])
    }

    static func encode(_ root: Value) -> Data {
        var objects: [Value] = []
        var scalarRefs: [Value: Int] = [:]
        // refs[i] = child object refs for container i (keys then values for a dict).
        var refs: [Int: [Int]] = [:]

        @discardableResult
        func flatten(_ v: Value) -> Int {
            switch v {
            case .array, .dict: break
            default: if let r = scalarRefs[v] { return r }
            }
            let ref = objects.count
            objects.append(v)
            switch v {
            case .array(let items):
                refs[ref] = items.map { flatten($0) }
            case .dict(let d):
                let keys = d.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
                let keyRefs = keys.map { flatten(.string($0)) }
                let valueRefs = keys.map { flatten(d[$0]!) }
                refs[ref] = keyRefs + valueRefs
            default:
                scalarRefs[v] = ref
            }
            return ref
        }
        flatten(root)

        let refSize = byteSize(for: UInt64(objects.count))
        var out = Data("bplist00".utf8)
        var offsets: [UInt64] = []
        offsets.reserveCapacity(objects.count)

        for (i, obj) in objects.enumerated() {
            offsets.append(UInt64(out.count))
            switch obj {
            case .bool(let b):
                out.append(b ? 0x09 : 0x08)
            case .int(let n):
                if n < 0 { out.append(0x13); appendBE(&out, UInt64(bitPattern: n), size: 8) }
                else if n < 1 << 8 { out.append(0x10); appendBE(&out, UInt64(n), size: 1) }
                else if n < 1 << 16 { out.append(0x11); appendBE(&out, UInt64(n), size: 2) }
                else if n < 1 << 32 { out.append(0x12); appendBE(&out, UInt64(n), size: 4) }
                else { out.append(0x13); appendBE(&out, UInt64(n), size: 8) }
            case .data(let d):
                appendMarker(&out, 0x40, count: d.count)
                out.append(d)
            case .string(let s):
                if s.unicodeScalars.allSatisfy(\.isASCII) {
                    appendMarker(&out, 0x50, count: s.utf8.count)
                    out.append(contentsOf: s.utf8)
                } else {
                    let units = Array(s.utf16)
                    appendMarker(&out, 0x60, count: units.count)
                    for u in units { appendBE(&out, UInt64(u), size: 2) }
                }
            case .array(let items):
                appendMarker(&out, 0xA0, count: items.count)
                for r in refs[i]! { appendBE(&out, UInt64(r), size: refSize) }
            case .dict(let d):
                appendMarker(&out, 0xD0, count: d.count)
                for r in refs[i]! { appendBE(&out, UInt64(r), size: refSize) }
            }
        }

        let tableOffset = UInt64(out.count)
        let offsetSize = byteSize(for: tableOffset)
        for o in offsets { appendBE(&out, o, size: offsetSize) }
        out.append(contentsOf: [UInt8](repeating: 0, count: 6))
        out.append(UInt8(offsetSize))
        out.append(UInt8(refSize))
        appendBE(&out, UInt64(objects.count), size: 8)
        appendBE(&out, 0, size: 8)   // top object is always ref 0
        appendBE(&out, tableOffset, size: 8)
        return out
    }

    /// plistlib `_count_to_size`.
    private static func byteSize(for count: UInt64) -> Int {
        if count < 1 << 8 { return 1 }
        if count < 1 << 16 { return 2 }
        if count < 1 << 32 { return 4 }
        return 8
    }

    /// plistlib `_write_size`: low nibble count, or 0xF + an int object.
    private static func appendMarker(_ out: inout Data, _ token: UInt8, count: Int) {
        let n = UInt64(count)
        if n < 15 { out.append(token | UInt8(n)); return }
        out.append(token | 0x0F)
        if n < 1 << 8 { out.append(0x10); appendBE(&out, n, size: 1) }
        else if n < 1 << 16 { out.append(0x11); appendBE(&out, n, size: 2) }
        else if n < 1 << 32 { out.append(0x12); appendBE(&out, n, size: 4) }
        else { out.append(0x13); appendBE(&out, n, size: 8) }
    }

    private static func appendBE(_ out: inout Data, _ v: UInt64, size: Int) {
        for shift in stride(from: (size - 1) * 8, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }
}
