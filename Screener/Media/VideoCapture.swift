#if DEBUG
// DEBUG-only capture/replay of decrypted video RTP packets (MediaPacket), for
// validating HEVCAssembler against real streams offline.
//
// Captures contain images of the host's screen. They are written only where
// the SCREENER_CAPTURE_VIDEO environment variable points (pass it through
// simctl as SIMCTL_CHILD_SCREENER_CAPTURE_VIDEO) and must never be stored in
// the repository.
//
// File: "SCRV0001", then per packet
//   u32 recordLength | u32 ssrc | u16 seq | u32 timestamp | u8 marker |
//   u8 payloadType | u64 arrival ns since the first packet | payload
// all big-endian; recordLength covers everything after itself.
import Foundation

enum VideoCaptureFile {
    static let magic = Data("SCRV0001".utf8)
    static let envKey = "SCREENER_CAPTURE_VIDEO"

    struct Record: Equatable {
        var ssrc: UInt32
        var seq: UInt16
        var timestamp: UInt32
        var marker: Bool
        var payloadType: UInt8
        var arrivalNanos: UInt64
        var payload: Data

        /// A MediaPacket with `arrival` = `base` + the recorded offset.
        func packet(base: ContinuousClock.Instant) -> MediaPacket {
            MediaPacket(ssrc: ssrc, seq: seq, timestamp: timestamp, marker: marker, payloadType: payloadType,
                        payload: payload, arrival: base.advanced(by: .nanoseconds(Int64(arrivalNanos))))
        }
    }

    static func encode(_ r: Record) -> Data {
        var body = Data(capacity: 20 + r.payload.count)
        func be<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.bigEndian) { body.append(contentsOf: $0) } }
        be(r.ssrc); be(r.seq); be(r.timestamp); be(UInt8(r.marker ? 1 : 0)); be(r.payloadType); be(r.arrivalNanos)
        body.append(r.payload)
        var out = Data(capacity: body.count + 4)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    static func read(_ url: URL) throws -> [Record] {
        let d = try Data(contentsOf: url)
        guard d.prefix(magic.count) == magic else { throw CocoaError(.fileReadCorruptFile) }
        var r = ByteReader(d.dropFirst(magic.count))
        var out: [Record] = []
        while r.remaining > 0 {
            let len = Int(try r.u32())
            var b = ByteReader(try r.bytes(len))
            let ssrc = try b.u32(), seq = try b.u16(), ts = try b.u32()
            let marker = try b.u8() != 0, pt = try b.u8()
            let arrival = try b.u64()
            out.append(Record(ssrc: ssrc, seq: seq, timestamp: ts, marker: marker, payloadType: pt,
                              arrivalNanos: arrival, payload: try b.bytes(b.remaining)))
        }
        return out
    }
}

/// Appends captured packets to a file. Not thread-safe; owned by one task.
/// A failed write (disk full, file gone) is logged once and ends the
/// capture; later packets are ignored.
final class VideoCaptureWriter {
    private let handle: FileHandle
    private var start: ContinuousClock.Instant?
    private(set) var count = 0
    private(set) var failed = false

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: VideoCaptureFile.magic),
              let h = FileHandle(forWritingAtPath: path),
              (try? h.seekToEnd()) != nil else { return nil }
        handle = h
    }

    func write(_ p: MediaPacket) {
        guard !failed else { return }
        let t0 = start ?? p.arrival
        start = t0
        let ns = max(0, (p.arrival - t0).components.seconds * 1_000_000_000
                     + (p.arrival - t0).components.attoseconds / 1_000_000_000)
        do {
            try handle.write(contentsOf: VideoCaptureFile.encode(.init(
                ssrc: p.ssrc, seq: p.seq, timestamp: p.timestamp, marker: p.marker,
                payloadType: p.payloadType, arrivalNanos: UInt64(ns), payload: p.payload)))
            count += 1
        } catch {
            failed = true
            Log.video.error("DEBUG capture: write failed after \(self.count) packets, capture stopped: \(error)")
        }
    }

    func close() {
        try? handle.close()
        Log.video.info("DEBUG capture: \(count) packets written")
    }
}
#endif

#if DEBUG
extension VideoCaptureWriter: VideoPacketTap {}

extension VideoCaptureFile {
    /// When $SCREENER_CAPTURE_VIDEO is set: every session's video packets are
    /// dumped there by the coordinator's single video consumer loop
    /// (VideoPipeline.run writes each packet to the tap before the
    /// assembler sees it, start burst included). MediaTransport.video has
    /// ONE consumer, so the capture never subscribes to it itself.
    @MainActor
    static func attachIfRequested(to model: SessionCoordinator) {
        guard let path = ProcessInfo.processInfo.environment[envKey], !path.isEmpty else { return }
        model.makeVideoTap = {
            guard let writer = VideoCaptureWriter(path: path) else {
                Log.video.error("DEBUG capture: cannot open \(path)")
                return nil
            }
            Log.video.info("DEBUG capture: writing video RTP to \(path)")
            return writer
        }
    }
}
#endif
