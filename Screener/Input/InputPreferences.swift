// Settings → Input preferences that change how touches and scrolls are
// interpreted (the Settings screen writes them; RemoteInputView reads them
// when a session's input arrives and again whenever UserDefaults changes).
//
// - Tap to Click delay (TapClickDelay, "input.tapDelay"): how long a
//   trackpad-mode tap waits for a second touch (double tap / tap-drag)
//   before it is sent as a click, and how long a zoomed two-finger tap waits
//   for a second one (reset zoom) — TouchInterpreter.tapDelay.
// - Scroll direction (ScrollDirection, "input.scrollDirection"): Natural
//   (default) leaves every scroll as iPadOS reports it (content follows the
//   fingers, and the hardware trackpad/mouse follows the iPad's own
//   setting); Reversed flips the sign of every scroll sent to the Mac —
//   touch (+ momentum), wheel, hardware continuous and pointer-lock.
// - Touch-and-Hold Drag Delay (HoldDragDelay, "input.holdDelay"): how long
//   one, two or three still fingers take to arm a left / right / middle
//   drag (TouchInterpreter.holdDelay). Short 0.3 s, Normal 0.45 s (default),
//   Long 0.6 s.
// (The old "input.longPressRightClick" toggle is gone: two-finger tap is the
// right click and a two-finger hold a right drag. A stored value is ignored.)
// - Pointer Speed / Touch Pointer Speed ("input.pointerSpeed",
//   "input.touchPointerSpeed", 0.25×–3×, default 1×): PointerScaling.swift.
// - Keyboard Tester ("input.keyboardTester", default off): a diagnostic
//   overlay of the last hardware key events (HardwareKeyboard.swift).
import Foundation

enum TapClickDelay: String, CaseIterable, Sendable {
    case fast
    case normal
    case relaxed

    static let defaultsKey = "input.tapDelay"
    static let `default` = TapClickDelay.normal

    /// Seconds a tap's click waits for a double tap / tap-drag.
    var seconds: TimeInterval {
        switch self {
        case .fast: 0.15
        case .normal: 0.25
        case .relaxed: 0.35
        }
    }

    var title: String {
        switch self {
        case .fast: "Fast"
        case .normal: "Normal"
        case .relaxed: "Relaxed"
        }
    }
}

enum ScrollDirection: String, CaseIterable, Sendable {
    /// As iPadOS reports it (content follows the fingers).
    case natural
    case reversed

    static let defaultsKey = "input.scrollDirection"
    static let `default` = ScrollDirection.natural

    /// Multiplies the host scroll ticks.
    var sign: Int { self == .natural ? 1 : -1 }

    var title: String {
        switch self {
        case .natural: "Natural"
        case .reversed: "Reversed"
        }
    }
}

enum HoldDragDelay: String, CaseIterable, Sendable {
    case short
    case normal
    case long

    static let defaultsKey = "input.holdDelay"
    static let `default` = HoldDragDelay.normal

    /// Seconds still fingers take to arm a hold-drag.
    var seconds: TimeInterval {
        switch self {
        case .short: 0.3
        case .normal: 0.45
        case .long: 0.6
        }
    }

    var title: String {
        switch self {
        case .short: "Short"
        case .normal: "Normal"
        case .long: "Long"
        }
    }
}

struct InputPreferences: Equatable, Sendable {
    static let keyboardTesterKey = "input.keyboardTester"

    var tapDelay = TapClickDelay.default
    var scrollDirection = ScrollDirection.default
    var holdDelay = HoldDragDelay.default
    var keyboardTester = false
    /// Hardware mouse / trackpad under pointer lock (PointerScaling).
    var pointerSpeed = PointerScaling.defaultSpeed
    /// Trackpad-mode finger moves (PointerScaling).
    var touchPointerSpeed = PointerScaling.defaultSpeed

    /// The stored preferences (unknown / missing values → defaults).
    static func load(_ d: UserDefaults = .standard) -> InputPreferences {
        var p = InputPreferences()
        if let raw = d.string(forKey: TapClickDelay.defaultsKey), let v = TapClickDelay(rawValue: raw) {
            p.tapDelay = v
        }
        if let raw = d.string(forKey: ScrollDirection.defaultsKey), let v = ScrollDirection(rawValue: raw) {
            p.scrollDirection = v
        }
        if let raw = d.string(forKey: HoldDragDelay.defaultsKey), let v = HoldDragDelay(rawValue: raw) {
            p.holdDelay = v
        }
        p.keyboardTester = d.bool(forKey: keyboardTesterKey)
        if d.object(forKey: PointerScaling.pointerSpeedKey) != nil {
            p.pointerSpeed = PointerScaling.clamp(d.double(forKey: PointerScaling.pointerSpeedKey))
        }
        if d.object(forKey: PointerScaling.touchPointerSpeedKey) != nil {
            p.touchPointerSpeed = PointerScaling.clamp(d.double(forKey: PointerScaling.touchPointerSpeedKey))
        }
        return p
    }
}
