// The launch environment the experiment knobs read (SCREENER_RCTL_*,
// SCREENER_FB_*, SCREENER_KF_MODE, SCREENER_ENDPOINT_MODEL, SCREENER_PACING,
// SCREENER_NETSVC, SCREENER_LTR_ACK, …). Security review L8: those are A/B
// switches for development, so a Release build ignores the environment and
// always runs the fixed defaults; user-facing settings (UserDefaults /
// @AppStorage) are unaffected.
import Foundation

enum ExperimentEnv {
    static var current: [String: String] {
        #if DEBUG
        ProcessInfo.processInfo.environment
        #else
        [:]
        #endif
    }
}
