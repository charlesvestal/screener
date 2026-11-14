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
final class VideoCaptureWriter {
    private let handle: FileHandle
    private var start: ContinuousClock.Instant?
    private(set) var count = 0

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: VideoCaptureFile.magic),
              let h = FileHandle(forWritingAtPath: path) else { return nil }
        h.seekToEndOfFile()
        handle = h
    }

    func write(_ p: MediaPacket) {
        let t0 = start ?? p.arrival
        start = t0
        let ns = max(0, (p.arrival - t0).components.seconds * 1_000_000_000
                     + (p.arrival - t0).components.attoseconds / 1_000_000_000)
        handle.write(VideoCaptureFile.encode(.init(ssrc: p.ssrc, seq: p.seq, timestamp: p.timestamp, marker: p.marker,
                                                   payloadType: p.payloadType, arrivalNanos: UInt64(ns),
                                                   payload: p.payload)))
        count += 1
    }

    func close() { try? handle.close() }
}
#endif

#if DEBUG
extension VideoCaptureFile {
    /// When $SCREENER_CAPTURE_VIDEO is set: registers a media consumer, so
    /// each session's video packets are dumped there (subscribed before the
    /// UDP bind, start burst included) and run through an HEVCAssembler
    /// (keyframe requests included), logging a summary.
    @MainActor
    static func attachIfRequested(to model: SessionCoordinator) {
        guard let path = ProcessInfo.processInfo.environment[envKey], !path.isEmpty else { return }
        model.addMediaConsumer { media in run(media, path: path) }
    }

    private static func run(_ media: MediaTransport, path: String) {
        guard let writer = VideoCaptureWriter(path: path) else {
            Log.video.error("DEBUG capture: cannot open \(path)")
            return
        }
        Log.video.info("DEBUG capture: writing video RTP to \(path)")
        Task.detached {
            var assembler: HEVCAssembler?
            var aus = 0, idrs = 0, params = 0
            for await p in media.video {
                writer.write(p)
                if assembler == nil || !(assembler!.tileSSRCs.contains(p.ssrc)) {
                    let group = await media.activeVideoSSRCs
                    if assembler == nil { assembler = HEVCAssembler(tileSSRCs: group) }
                    else if group != assembler!.tileSSRCs { assembler!.resetForNewGroup(tileSSRCs: group) }
                }
                for o in assembler!.ingest(p) {
                    switch o {
                    case .accessUnit(let au): aus += 1; if au.isIDR { idrs += 1 }
                    case .needKeyframe(let ssrc): await media.requestKeyframe(ssrc: ssrc)
                    case .parameterSets(_, let sps, let pps):
                        params += 1
                        let i = HEVCSPSInfo(sps: sps)
                        Log.video.info("DEBUG capture: parameter sets SPS \(sps.count)B PPS x\(pps.count) "
                            + (i.map { "profile=\($0.profileIdc) chroma=\($0.chromaFormatIdc) \($0.width)x\($0.height)" } ?? ""))
                    case .notHEVC: Log.video.error("DEBUG capture: stream is not HEVC")
                    }
                }
            }
            writer.close()
            Log.video.info("DEBUG capture: \(writer.count) packets written; AUs=\(aus) IDRs=\(idrs) paramSets=\(params) "
                + "stats=\(assembler.map { "\($0.stats)" } ?? "-")")
        }
    }
}
#endif
