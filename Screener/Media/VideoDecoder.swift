// Ported from iShareScreen src/isharescreen/proxy/media/vtdecode.py (AGPL-3.0)
//
// One VTDecompressionSession decodes every tile's access units (RFC §10.7:
// the encoder references pictures across tiles, so per-tile decoders fail).
// Each tile's coded picture is one horizontal STRIP of the canvas (its own
// SPS-sized picture, e.g. 1280×432 for a 1280×1708 canvas, 4 tiles), so every
// decoded image is one strip; the output handler carries the tile index of
// the AU it came from, and the renderer composites the strips vertically
// (see CompositeLayout). Verified on a live capture (2026-11-14): one SPS
// 1280×432, chroma 4:4:4, every AU decodes to a 1280×432 image.
//
// Session (vtdecode.set_params / _build_session_locked):
//   * CMVideoFormatDescriptionCreateFromHEVCParameterSets over VPS, SPS and
//     every PPS, NAL length size 4;
//   * output requested as kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
//     ('444f', nv24), IOSurface-backed and Metal-compatible; if that session
//     cannot be created, VideoToolbox picks the format (the reference's
//     fallback), and as a last resort the software decoder is used. Which
//     one is live is logged.
// Samples: the reference feeds one NAL per sample buffer; here one sample is
// the whole AU (all VCL NAL units, 4-byte big-endian length each), which is
// what a sample means to VideoToolbox. Parameter sets never go in samples.
//
// Deviations from the reference:
//   * Asynchronous decode (kVTDecodeFrame_EnableAsynchronousDecompression)
//     with a per-frame output handler (the handler captures the tile). The
//     reference decodes synchronously only because its async handlers never
//     fired under pyobjc; VideoToolbox still emits frames in decode order.
//   * Errors: as the reference, a failed frame is reported (the owner tells
//     the assembler, which gates tiles and asks for a keyframe). The session
//     is NOT rebuilt for an ordinary concealment error (a rebuild wipes the
//     DPB; vtdecode.restart is a no-op for that reason). It IS rebuilt when
//     VideoToolbox invalidates it (kVTInvalidSessionErr, e.g. after the app
//     was backgrounded), when an IRAP itself fails to decode (the session is
//     wedged), or on a parameter-set change.
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// AVCC sample framing: each NAL unit prefixed with its 4-byte big-endian length.
enum AVCC {
    static func sample(_ nalUnits: [Data]) -> Data {
        var out = Data(capacity: nalUnits.reduce(0) { $0 + 4 + $1.count })
        for nal in nalUnits {
            withUnsafeBytes(of: UInt32(nal.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }
}

/// One decoded picture (a tile strip, or the whole picture).
struct DecodedFrame: @unchecked Sendable {      // CVPixelBuffer is immutable once decoded
    var tile: Int
    var pixelBuffer: CVPixelBuffer
    /// Submit → output handler.
    var decodeTime: Duration
    var don: UInt16
    /// Monotonic submit counter, process-global (survives rebuilds and
    /// sessions; DONs do not).
    var seq: Int
}

extension OSType {
    /// '444f'-style four-character code, for logs.
    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return String(decoding: bytes, as: UTF8.self) }
        return String(format: "0x%08x", self)
    }
}

/// Not thread-safe: `configure`/`decode`/`invalidate` must be called from one
/// owner (VideoPipeline). The output handler runs on VideoToolbox threads and
/// only calls `onEvent` with values it captured.
final class VideoDecoder {
    enum Event: Sendable {
        case frame(DecodedFrame)
        /// The AU (`tile`, `don`) failed to decode with `status`.
        case error(tile: Int, don: UInt16, status: OSStatus, isIRAP: Bool)
    }

    /// Output configurations tried in order (see the header).
    enum OutputMode: Int, CaseIterable, Sendable, CustomStringConvertible {
        case hardware444 = 0, hardwareAny, software444, softwareAny
        var description: String {
            switch self {
            case .hardware444: "hw/444f"
            case .hardwareAny: "hw/any"
            case .software444: "sw/444f"
            case .softwareAny: "sw/any"
            }
        }
        var requestsNV24: Bool { self == .hardware444 || self == .software444 }
        var software: Bool { self == .software444 || self == .softwareAny }
    }

    static let preferredPixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange   // '444f'

    private let onEvent: @Sendable (Event) -> Void
    private(set) var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSets: (vps: Data, sps: Data, pps: [Data])?
    private(set) var mode: OutputMode?
    private(set) var sessionsBuilt = 0
    /// Frames submitted since the session was (re)built.
    private(set) var submitted = 0
    /// Process-global, so frames of two decoders (two sessions) never compare
    /// out of order in a shared store.
    private static let sequence = Atomic<Int>(0)
    static func nextSequence() -> Int { sequence.wrappingAdd(1, ordering: .relaxed).newValue }

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    deinit { invalidate() }

    var isReady: Bool { session != nil }

    // MARK: - format description

    static func makeFormatDescription(vps: Data, sps: Data, pps: [Data]) throws -> CMVideoFormatDescription {
        let sets = [vps, sps] + pps
        let copies = sets.map { [UInt8]($0) }
        var fmt: CMFormatDescription?
        let status: OSStatus = withPointers(copies) { pointers in
            let sizes = copies.map(\.count)
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: copies.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        }
        guard status == noErr, let fmt else { throw DecoderError.formatDescription(status) }
        return fmt
    }

    private static func withPointers<R>(_ arrays: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        func recurse(_ i: Int) -> R {
            if i == arrays.count { return body(pointers) }
            return arrays[i].withUnsafeBufferPointer { buf in
                pointers.append(buf.baseAddress!)
                return recurse(i + 1)
            }
        }
        return recurse(0)
    }

    /// Colour metadata the format description carries (from the SPS VUI), for logs.
    static func colorDescription(_ fmt: CMFormatDescription) -> String {
        func ext(_ key: CFString) -> String {
            CMFormatDescriptionGetExtension(fmt, extensionKey: key).map { "\($0)" } ?? "-"
        }
        return "matrix=\(ext(kCMFormatDescriptionExtension_YCbCrMatrix)) "
            + "primaries=\(ext(kCMFormatDescriptionExtension_ColorPrimaries)) "
            + "transfer=\(ext(kCMFormatDescriptionExtension_TransferFunction)) "
            + "fullRange=\(ext(kCMFormatDescriptionExtension_FullRangeVideo))"
    }

    enum DecoderError: Error, CustomStringConvertible {
        case formatDescription(OSStatus)
        case session(OSStatus)
        var description: String {
            switch self {
            case .formatDescription(let s): "CMVideoFormatDescriptionCreateFromHEVCParameterSets failed (\(s))"
            case .session(let s): "VTDecompressionSessionCreate failed for every output mode (\(s))"
            }
        }
    }

    // MARK: - session

    /// (Re)builds the session for a new parameter set. Returns false when the
    /// set is unchanged and a session is already live.
    @discardableResult
    func configure(vps: Data, sps: Data, pps: [Data]) throws -> Bool {
        if let cur = parameterSets, cur.vps == vps, cur.sps == sps, cur.pps == pps, session != nil { return false }
        let fmt = try Self.makeFormatDescription(vps: vps, sps: sps, pps: pps)
        parameterSets = (vps, sps, pps)
        formatDescription = fmt
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        Log.video.info("VT format \(dims.width)x\(dims.height) " + Self.colorDescription(fmt)
                       + " hwHEVC=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))")
        try build(from: mode ?? .hardware444)
        return true
    }

    /// Tears the session down and builds it again (same parameter sets),
    /// starting at `mode` (default: the current one).
    func rebuild(from start: OutputMode? = nil) throws {
        guard parameterSets != nil else { return }
        try build(from: start ?? mode ?? .hardware444)
    }

    /// Advances to the next output mode (the current one cannot decode this
    /// stream). Returns false when there is none left.
    func fallBack() throws -> Bool {
        guard let m = mode, let next = OutputMode(rawValue: m.rawValue + 1) else { return false }
        Log.video.error("VT output mode \(m) cannot decode this stream; trying \(next)")
        try build(from: next)
        return true
    }

    private func build(from start: OutputMode) throws {
        guard let fmt = formatDescription else { return }
        invalidate()
        var last: OSStatus = noErr
        for m in OutputMode.allCases where m.rawValue >= start.rawValue {
            var attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                                          kCVPixelBufferMetalCompatibilityKey: true]
            if m.requestsNV24 { attrs[kCVPixelBufferPixelFormatTypeKey] = Self.preferredPixelFormat }
            let spec: [CFString: Any]? = m.software
                ? [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] : nil
            var s: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: fmt,
                decoderSpecification: spec as CFDictionary?, imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &s)
            if status == noErr, let s {
                VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                session = s
                mode = m
                sessionsBuilt += 1
                submitted = 0
                Log.video.info("VT session ready mode=\(m) (build #\(sessionsBuilt))")
                return
            }
            last = status
            Log.video.error("VTDecompressionSessionCreate mode=\(m) failed: \(status)")
        }
        throw DecoderError.session(last)
    }

    func invalidate() {
        guard let s = session else { return }
        session = nil
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        VTDecompressionSessionInvalidate(s)
    }

    /// Waits for every submitted frame's output handler (tests, teardown).
    func flush() {
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s) }
    }

    // MARK: - decode

    /// Submits one AU for asynchronous decode. Returns the synchronous submit
    /// status (noErr when queued; the outcome arrives through `onEvent`).
    @discardableResult
    func decode(_ au: AccessUnit) -> OSStatus {
        if let refused = Self.precheck(hasSession: session != nil && formatDescription != nil, au: au) { return refused }
        guard let session, let fmt = formatDescription else { return kVTInvalidSessionErr }
        guard let sample = Self.makeSample(AVCC.sample(au.nalUnits), format: fmt) else { return kVTParameterErr }
        let tile = au.tile, don = au.don, irap = au.isIDR
        let onEvent = self.onEvent
        let start = ContinuousClock.now
        submitted += 1
        let seq = Self.nextSequence()
        var infoOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoOut
        ) { status, flags, image, _, _ in
            if status == noErr, let image, !flags.contains(.frameDropped) {
                onEvent(.frame(DecodedFrame(tile: tile, pixelBuffer: image,
                                            decodeTime: ContinuousClock.now - start, don: don, seq: seq)))
            } else if status != noErr {
                onEvent(.error(tile: tile, don: don, status: status, isIRAP: irap))
            }
        }
        return status
    }

    /// Why an AU cannot be submitted, or nil. No session → kVTInvalidSessionErr
    /// (rebuild); an empty AU is a bad AU (kVTParameterErr → keyframe), never
    /// mistaken for a dead session.
    static func precheck(hasSession: Bool, au: AccessUnit) -> OSStatus? {
        if au.nalUnits.isEmpty { return kVTParameterErr }
        if !hasSession { return kVTInvalidSessionErr }
        return nil
    }

    static func makeSample(_ bytes: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = bytes.count
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}
