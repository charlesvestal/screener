// Whether a session presents pictures on their RTP timeline (VideoFrameStore
// pacing). Read once at session start (MetalRenderer init):
//   * SCREENER_PACING=1 / =0 (launch environment) wins, for device A/Bs;
//   * otherwise the "Smooth Playback" toggle in the control menu
//     (UserDefaults `video.smoothPlayback`, @AppStorage), default OFF.
import Foundation

enum PacingConfig {
    static let defaultsKey = "video.smoothPlayback"

    static func isOn(env: [String: String] = ProcessInfo.processInfo.environment,
                     defaults: UserDefaults = .standard) -> Bool {
        if let v = env["SCREENER_PACING"] { return v == "1" }
        return defaults.bool(forKey: defaultsKey)
    }

    static func current(env: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard) -> VideoFrameStore.Pacing? {
        isOn(env: env, defaults: defaults) ? VideoFrameStore.Pacing() : nil
    }

    /// For the log line.
    static var source: String {
        ProcessInfo.processInfo.environment["SCREENER_PACING"] != nil ? "SCREENER_PACING=1" : "Smooth Playback"
    }
}
