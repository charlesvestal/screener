// Live stream statistics for the control menu's quality badge and the stats
// overlay.
//
// SessionCoordinator's 1 Hz stats poll feeds `LiveStatsModel.ingest` with
// cumulative counters: MediaTransport.Stats (video payload bytes, the RCTL
// bandwidth estimate, the estimator's windowed loss) and VideoFrameStore.
// LiveTotals (decoded pictures per tile, decode time, pixel format).
// StatsSampler turns two consecutive readings into one StatsSample:
//   fps       = the busiest tile's pictures per second (as the video log's
//               `fps=`; a static screen sends nothing, so 0 fps is normal)
//   Mbps      = decrypted video payload (what the encoder spent)
//   decode ms = mean submit → output time of the pictures decoded
//   loss %    = BandwidthEstimator's windowed loss
//   BWE       = the last RCTL estimate sent to the Mac
// RTT is not shown: the Mac sends no receiver reports for our SRs, so there
// is no round-trip measurement to show.
//
// The UI therefore updates at most once a second (one @Observable write per
// poll), and the last 30 samples (30 s) feed the sparkline.
import CoreVideo
import Foundation
import Observation

/// One second of the stream.
struct StatsSample: Equatable, Sendable {
    /// Seconds since the sampler's first reading.
    var time: Double
    var fps: Double
    var mbps: Double
    /// nil when nothing was decoded in the interval.
    var decodeMs: Double?
    /// nil when too few packets were expected to tell.
    var lossPercent: Double?
    /// nil before the first RCTL.
    var bweMbps: Double?
}

/// A fixed-capacity FIFO: the newest `capacity` elements, oldest first.
struct StatsRing<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    var elements: [Element] { Array(storage[head...]) + storage[..<head] }
    var last: Element? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// Cumulative counters → per-interval samples.
struct StatsSampler {
    struct Reading: Equatable, Sendable {
        /// Seconds on any monotonic clock.
        var now: Double
        var payloadBytes: Int
        var tileFrames: [Int: Int]
        var decodeNanos: Int64
        var lossFraction: Double?
        var bweKbps: Int
    }

    private var last: Reading?
    private var origin: Double?

    /// The sample since the previous reading; nil for the first one, a
    /// clock that did not move, or counters that went backwards (a new
    /// transport: the next reading starts the new baseline).
    mutating func sample(_ r: Reading) -> StatsSample? {
        defer { last = r }
        if origin == nil { origin = r.now }
        guard let l = last else { return nil }
        let dt = r.now - l.now
        guard dt > 0.05 else { return nil }
        let bytes = r.payloadBytes - l.payloadBytes
        let nanos = r.decodeNanos - l.decodeNanos
        guard bytes >= 0, nanos >= 0 else { return nil }
        var busiest = 0, total = 0
        for (tile, n) in r.tileFrames {
            let d = max(0, n - (l.tileFrames[tile] ?? 0))
            busiest = max(busiest, d)
            total += d
        }
        return StatsSample(
            time: r.now - (origin ?? r.now),
            fps: Double(busiest) / dt,
            mbps: Double(bytes) * 8 / dt / 1_000_000,
            decodeMs: total > 0 ? Double(nanos) / Double(total) / 1e6 : nil,
            lossPercent: r.lossFraction.map { $0 * 100 },
            bweMbps: r.bweKbps > 0 ? Double(r.bweKbps) / 1000 : nil)
    }
}

/// The badge's colored dot.
enum StreamQuality: Equatable, Sendable {
    case good, fair, poor

    /// Loss decides first (≥ 5 % poor, ≥ 1 % fair). A low frame rate counts
    /// only while the stream is busy (≥ 5 Mbps): a static screen sends few
    /// pictures on its own, and a 24 fps movie is fine (≥ 20 fps).
    static func classify(_ s: StatsSample) -> StreamQuality {
        let loss = s.lossPercent ?? 0
        if loss >= 5 { return .poor }
        if s.mbps >= 5 {
            if s.fps < 10 { return .poor }
            if s.fps < 20 { return .fair }
        }
        if loss >= 1 { return .fair }
        return .good
    }

    var accessibilityName: String {
        switch self {
        case .good: "good"
        case .fair: "fair"
        case .poor: "poor"
        }
    }
}

/// The decoded pictures' chroma subsampling.
enum ChromaFormat: String, Equatable, Sendable {
    case yuv444 = "4:4:4"
    case yuv422 = "4:2:2"
    case yuv420 = "4:2:0"
    case rgb = "RGB"

    init?(pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            self = .yuv444
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            self = .yuv422
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            self = .yuv420
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, kCVPixelFormatType_32ARGB:
            self = .rgb
        default:
            return nil
        }
    }
}

/// "HP · 4:4:4 · 60 fps · 58 Mbps".
enum QualityBadgeText {
    /// High Performance (HEVC) is the only stream Screener plays.
    static let codec = "HP"

    static func text(_ s: StatsSample?, chroma: ChromaFormat?) -> String {
        var parts = [codec]
        if let chroma { parts.append(chroma.rawValue) }
        if let s {
            parts.append("\(Int(s.fps.rounded())) fps")
            parts.append(mbps(s.mbps))
        }
        return parts.joined(separator: " · ")
    }

    /// One decimal under 10 Mbps, whole numbers above.
    static func mbps(_ v: Double) -> String {
        v < 9.95 ? String(format: "%.1f Mbps", v) : "\(Int(v.rounded())) Mbps"
    }

    static func accessibilityText(_ s: StatsSample?, chroma: ChromaFormat?) -> String {
        var parts = ["High Performance"]
        if let chroma { parts.append(chroma == .rgb ? "RGB" : "chroma \(chroma.rawValue)") }
        if let s {
            parts.insert("Stream quality \(StreamQuality.classify(s).accessibilityName)", at: 0)
            parts.append("\(Int(s.fps.rounded())) frames per second")
            parts.append(mbps(s.mbps).replacingOccurrences(of: "Mbps", with: "megabits per second"))
        }
        return parts.joined(separator: ", ")
    }
}

/// What the badge and overlay show (owned by SessionCoordinator).
@MainActor @Observable
final class LiveStatsModel {
    nonisolated static let historySeconds = 30

    private(set) var latest: StatsSample?
    private(set) var history = StatsRing<StatsSample>(capacity: LiveStatsModel.historySeconds)
    private(set) var chroma: ChromaFormat?
    @ObservationIgnored private var sampler = StatsSampler()

    var quality: StreamQuality? { latest.map(StreamQuality.classify) }
    var badgeText: String { QualityBadgeText.text(latest, chroma: chroma) }

    /// One poll's cumulative counters (SessionCoordinator, 1 Hz).
    func ingest(media: MediaTransport.Stats, video: VideoFrameStore.LiveTotals, now: Double) {
        let reading = StatsSampler.Reading(now: now, payloadBytes: media.videoPayloadBytes,
                                           tileFrames: video.frames, decodeNanos: video.decodeNanos,
                                           lossFraction: media.lossFraction, bweKbps: media.bweKbps)
        let format = video.pixelFormat.flatMap(ChromaFormat.init(pixelFormat:))
        if format != nil, format != chroma { chroma = format }
        guard let s = sampler.sample(reading) else { return }
        latest = s
        history.append(s)
    }

    /// A new session: the transport's counters start over.
    func reset() {
        sampler = StatsSampler()
        latest = nil
        history.removeAll()
        chroma = nil
    }

    #if DEBUG
    /// Synthetic history for the DEBUG menu preview / screenshots.
    func loadPreview() {
        reset()
        chroma = .yuv444
        for i in 0..<Self.historySeconds {
            let t = Double(i)
            let s = StatsSample(time: t, fps: 52 + 8 * sin(t / 3), mbps: 48 + 12 * sin(t / 4 + 1),
                                decodeMs: 3.1 + 0.4 * cos(t / 2), lossPercent: i == 21 ? 1.4 : 0.1,
                                bweMbps: 62)
            latest = s
            history.append(s)
        }
    }
    #endif
}
