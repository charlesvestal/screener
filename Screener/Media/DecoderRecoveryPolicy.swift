// What VideoPipeline does when VideoToolbox reports a failed frame (pure, so
// the decision can be tested without a decoder).
//
//   * Format-unsupported errors (kVTCouldNotFindVideoDecoderErr,
//     kVTVideoDecoderUnsupportedDataFormatErr): this output mode cannot
//     decode the stream → fall back to the next mode.
//   * Session-level errors (kVTInvalidSessionErr — e.g. after backgrounding —
//     kVTVideoDecoderMalfunctionErr, kVTVideoDecoderNotAvailableNowErr):
//     rebuild in the SAME mode + keyframe. Never counted toward a fallback.
//   * A failed IRAP (any other status): rebuild + keyframe. Only after
//     `fallbackAfterIRAPFailures` such failures in a row in the same mode,
//     with no picture decoded in between, fall back. A single transient
//     failure must not ratchet the output mode down for the rest of the
//     session (Task 14 review).
//   * Anything else is concealment-class: gate + keyframe, at most one per
//     `keyframeThrottle` (vtdecode._on_decoded: 0.5 s).
// Frames already queued on a session fail together, so rebuild decisions
// within `rebuildThrottle` of the last one are ignored (and not counted).
import CoreMedia
import Foundation
import VideoToolbox

struct DecoderRecoveryPolicy: Sendable {
    enum Action: Equatable, Sendable {
        /// Throttled: a rebuild / keyframe request just happened.
        case ignore
        /// Gate the tile and ask for a keyframe.
        case requestKeyframe
        /// Rebuild the session in the same output mode, then keyframe.
        case rebuild
        /// Move to the next output mode, then keyframe.
        case fallBack
    }

    static let fallbackAfterIRAPFailures = 3
    static let rebuildThrottle: Duration = .milliseconds(500)
    static let keyframeThrottle: Duration = .milliseconds(500)

    static func isFormatUnsupported(_ s: OSStatus) -> Bool {
        s == kVTCouldNotFindVideoDecoderErr || s == kVTVideoDecoderUnsupportedDataFormatErr
    }

    static func isSessionLevel(_ s: OSStatus) -> Bool {
        s == kVTInvalidSessionErr || s == kVTVideoDecoderMalfunctionErr || s == kVTVideoDecoderNotAvailableNowErr
    }

    /// Failed IRAPs in a row in the current mode with nothing decoded between.
    private(set) var consecutiveIRAPFailures = 0
    private var lastRebuild: ContinuousClock.Instant?
    private var lastKeyframe: ContinuousClock.Instant?

    /// The output mode changed (fallback, or a new parameter set).
    mutating func noteModeChanged() { consecutiveIRAPFailures = 0 }

    /// - Parameter decodedSinceLastFailure: a picture was decoded since the
    ///   previous failure (the current mode works).
    mutating func decide(status: OSStatus, isIRAP: Bool, decodedSinceLastFailure: Bool,
                         now: ContinuousClock.Instant) -> Action {
        if decodedSinceLastFailure { consecutiveIRAPFailures = 0 }
        let unsupported = Self.isFormatUnsupported(status)
        let sessionLevel = Self.isSessionLevel(status)
        if unsupported || sessionLevel || isIRAP {
            if let last = lastRebuild, now - last < Self.rebuildThrottle { return .ignore }
            lastRebuild = now
            lastKeyframe = now
            if unsupported {
                consecutiveIRAPFailures = 0
                return .fallBack
            }
            if isIRAP && !sessionLevel {
                consecutiveIRAPFailures += 1
                if consecutiveIRAPFailures >= Self.fallbackAfterIRAPFailures {
                    consecutiveIRAPFailures = 0
                    return .fallBack
                }
            }
            return .rebuild
        }
        if let last = lastKeyframe, now - last < Self.keyframeThrottle { return .ignore }
        lastKeyframe = now
        return .requestKeyframe
    }
}
