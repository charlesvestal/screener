import Foundation

struct ByteWriter {
    private(set) var data = Data()
    init(capacity: Int = 64) { data.reserveCapacity(capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
}

struct ByteReader {
    enum Error: Swift.Error { case underflow(needed: Int, remaining: Int) }
    private let data: Data
    private(set) var offset: Int = 0
    init(_ data: Data) { self.data = Data(data) }   // rebase indices to 0
    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, n <= remaining else { throw Error.underflow(needed: n, remaining: remaining) }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }
    mutating func skip(_ n: Int) throws { _ = try bytes(n) }
    mutating func rest() -> Data { let d = data.subdata(in: offset..<data.count); offset = data.count; return d }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 { try fixed() }
    mutating func u32() throws -> UInt32 { try fixed() }
    mutating func u64() throws -> UInt64 { try fixed() }
    mutating func u32le() throws -> UInt32 { try fixed(bigEndian: false) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    private mutating func fixed<T: FixedWidthInteger>(bigEndian: Bool = true) throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { dst in
            raw.copyBytes(to: dst)
        }
        return bigEndian ? T(bigEndian: v) : T(littleEndian: v)
    }
}
