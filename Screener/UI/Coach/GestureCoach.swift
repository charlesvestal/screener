// First-run gesture coach: what each finger gesture does, for the touch mode
// currently selected (TouchInputMode). Shown once automatically on the first
// session that reaches its first picture (SessionView, "coach.seen"), and
// reopened any time from the floating menu's "?" tile or the Help screen's
// Gestures section.
//
// Pure data here (GestureCoach.cards); GestureCoachView draws and animates
// the cards.
import Foundation

/// One gesture, as a card: an icon (animated per `kind`), what it does, and
/// a short instruction.
struct CoachCard: Identifiable, Equatable {
    let id: String
    let systemImage: String
    let title: String
    let subtitle: String
    let kind: CoachAnimationKind
}

/// How a card's icon animates (GestureCoachView); static under Reduce Motion.
enum CoachAnimationKind: Equatable {
    case moveTrackpad
    case moveDirect
    case tap
    case twoFingerTap
    case drag
    case longPress
    case scroll
    case pinch
    case shake
    case menu
}

enum GestureCoach {
    /// UserDefaults key: the coach has been shown once (set when it's first
    /// presented, whether or not it was dismissed). Gated by
    /// `markSeenIfFirstTime`, not read/written directly, so "shown once ever
    /// per install" holds regardless of how many times SessionView itself is
    /// torn down and recreated (a reconnect, a display-mode resize that
    /// restarts the stream, Picture in Picture restoring, the card→session
    /// zoom transition, an iPhone/iPad layout swap, or a second window/Mac) —
    /// every one of those re-reads live from UserDefaults instead of trusting
    /// a value a View's own @State captured earlier.
    static let seenKey = "coach.seen"

    /// Atomically checks and marks "seen": returns `true` — meaning "present
    /// the automatic coach now" — at most once per install. The first caller
    /// to ask (across any number of reconnects, resizes, or SessionView
    /// instances, in this run or a past one) wins; every later caller gets
    /// `false`. A plain `UserDefaults` read-then-write, not `@AppStorage`'s
    /// View-bound cache, so the check is always against the live value.
    @discardableResult
    static func markSeenIfFirstTime(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: seenKey) else { return false }
        defaults.set(true, forKey: seenKey)
        return true
    }

    /// The cards for the touch mode currently in effect.
    static func cards(for mode: TouchInputMode) -> [CoachCard] {
        switch mode {
        case .trackpad: trackpadCards
        case .direct: directCards
        }
    }

    static let trackpadCards: [CoachCard] = [
        CoachCard(id: "move", systemImage: "hand.point.up.left.fill",
                  title: "Move the Pointer", subtitle: "One finger moves the pointer, like a trackpad.",
                  kind: .moveTrackpad),
        CoachCard(id: "click", systemImage: "hand.tap.fill",
                  title: "Click & Right-Click", subtitle: "Tap to click. Two fingers, tap together, to right-click.",
                  kind: .tap),
        CoachCard(id: "drag", systemImage: "hand.draw.fill",
                  title: "Drag", subtitle: "Press and hold, then move, to drag. Or double-tap and hold.",
                  kind: .drag),
        CoachCard(id: "scrollZoom", systemImage: "hand.draw",
                  title: "Scroll & Zoom", subtitle: "Two fingers drag to scroll. Pinch to zoom; "
                     + "two-finger double-tap resets.",
                  kind: .pinch),
        CoachCard(id: "findCursor", systemImage: "iphone.gen3.radiowaves.left.and.right",
                  title: "Find the Cursor", subtitle: "Shake the iPad to flash the pointer's position.",
                  kind: .shake),
        CoachCard(id: "menu", systemImage: "circle.grid.2x2.fill",
                  title: "Open the Control Menu", subtitle: "Tap the floating button — or press ⌘⌥M.",
                  kind: .menu),
    ]

    static let directCards: [CoachCard] = [
        CoachCard(id: "move", systemImage: "hand.point.up.left",
                  title: "Tap to Click", subtitle: "The pointer follows your finger; tap where you touch to click.",
                  kind: .moveDirect),
        CoachCard(id: "rightClick", systemImage: "hand.tap",
                  title: "Right-Click", subtitle: "Press and hold, then lift, to right-click where you touched.",
                  kind: .longPress),
        CoachCard(id: "drag", systemImage: "hand.draw.fill",
                  title: "Drag", subtitle: "Press and hold, then move without lifting, to drag.",
                  kind: .drag),
        CoachCard(id: "scrollZoom", systemImage: "hand.draw",
                  title: "Scroll & Zoom", subtitle: "Two fingers drag to scroll. Pinch to zoom; "
                     + "two-finger double-tap resets.",
                  kind: .pinch),
        CoachCard(id: "findCursor", systemImage: "iphone.gen3.radiowaves.left.and.right",
                  title: "Find the Cursor", subtitle: "Shake the iPad to flash the pointer's position.",
                  kind: .shake),
        CoachCard(id: "menu", systemImage: "circle.grid.2x2.fill",
                  title: "Open the Control Menu", subtitle: "Tap the floating button — or press ⌘⌥M.",
                  kind: .menu),
    ]
}
