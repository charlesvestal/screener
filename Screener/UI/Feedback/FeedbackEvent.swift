// Touch feedback ("delight") events: what the input layer reports so the
// renderer and the overlay can acknowledge a gesture.
//
// RemoteInputView turns TouchInterpreter's cues (TouchCue) and its own
// pointer/zoom/scroll work into FeedbackEvents for a FeedbackSink
// (FeedbackCenter in the app, a recorder in tests). Events never affect what
// is sent to the Mac.
//
// Coordinates: points marked BASE are unzoomed view points (Viewport.toBase
// space), so an effect stays on the same piece of the remote picture while
// the viewport pans; the renderer maps them through the current viewport
// (toScreen). Points marked SCREEN are where something is drawn now (view
// points), used by the SwiftUI overlay.
//
// Settings (read, never written here; the Settings screen owns the toggle):
// - "feedback.visual" (Bool, default true): off disables the decorative
//   effects — GPU ripples (the drag pulse too), cursor halo and trail, the
//   scroll pill. The informational ones (the hold progress ring, zoom pill,
//   minimap) and the cursor locate (shake / Find Cursor) stay.
// - Reduce Motion: no refraction, no expanding rings, no trail, no halo
//   scale-up — ripples become short in-place fades.
import CoreGraphics
import Foundation
import simd

enum FeedbackEvent: Equatable, Sendable {
    /// A touch left click at the cursor (BASE).
    case click(at: CGPoint)
    /// A touch double click at the cursor (BASE).
    case doubleClick(at: CGPoint)
    /// A touch right click at the cursor (BASE).
    case rightClick(at: CGPoint)
    /// A touch drag with `button` is armed or pressed (a fired hold, a
    /// tap-drag, a Touch-mode drag): starts the slow pulse at the cursor
    /// (BASE), tinted by the button (DragIndicatorTint).
    case dragBegan(at: CGPoint, button: Int)
    /// That drag is over: stops the pulse.
    case dragEnded
    /// Trackpad mode: a finger landed (the cursor's halo).
    case fingerDown
    /// A touch moved the cursor (BASE): the motion trail, the drag pulse.
    case cursorMoved(to: CGPoint)
    /// A one-/two-/three-finger hold started arming a `button` drag at
    /// `at` (SCREEN: the fingers in Touch mode, the cursor in Trackpad
    /// mode); it fires after `duration`.
    case holdBegan(at: CGPoint, duration: TimeInterval, button: Int)
    /// The armed hold fired (the drag is armed) or was abandoned.
    case holdEnded(fired: Bool)
    /// The viewport zoom changed by a gesture (pinch / reset).
    case zoomChanged(scale: CGFloat)
    /// A touch scroll or momentum step of `dy` view points.
    case scrolled(dy: CGFloat)
    /// The touch scroll and its momentum are over.
    case scrollEnded
    /// Shake to locate / Find Cursor: enlarge the drawn cursor for at least
    /// `hold` more seconds (CursorEffects.locate). Functional: shown even
    /// with visual feedback off; Reduce Motion drops the bounce only.
    case locateCursor(hold: TimeInterval)
}

/// The hold / drag indicator's colour by mouse button, as in Screens: blue
/// for a left drag, red for a right (secondary) drag, green for a middle drag.
enum DragIndicatorTint {
    static let left = SIMD3<Float>(0.04, 0.52, 1.0)
    static let right = SIMD3<Float>(1.0, 0.23, 0.19)
    static let middle = SIMD3<Float>(0.20, 0.78, 0.35)

    /// The tint for an InputController.Button (unknown: left's blue).
    static func rgb(for button: Int) -> SIMD3<Float> {
        switch button {
        case InputController.Button.right: right
        case InputController.Button.middle: middle
        default: left
        }
    }
}

/// Receives FeedbackEvents (main actor).
@MainActor
protocol FeedbackSink: AnyObject {
    func feedback(_ event: FeedbackEvent)
}

enum FeedbackSettings {
    /// @AppStorage key of the visual feedback toggle (default on).
    static let visualKey = "feedback.visual"

    static func visualEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: visualKey) as? Bool ?? true
    }
}
