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
//   effects — GPU ripples, cursor halo and trail, the scroll pill. The
//   informational ones (long-press progress, zoom pill, minimap) and the
//   cursor locate (shake / Find Cursor) stay.
// - Reduce Motion: no refraction, no expanding rings, no trail, no halo
//   scale-up — ripples become short in-place fades.
import CoreGraphics
import Foundation

enum FeedbackEvent: Equatable, Sendable {
    /// A touch left click at the cursor (BASE).
    case click(at: CGPoint)
    /// A touch double click at the cursor (BASE).
    case doubleClick(at: CGPoint)
    /// A touch right click at the cursor (BASE).
    case rightClick(at: CGPoint)
    /// A touch drag (tap-drag / long-press-drag) pressed the button: starts
    /// the slow pulse at the cursor (BASE).
    case dragBegan(at: CGPoint)
    /// That drag released the button: stops the pulse.
    case dragEnded
    /// The trackpad three-finger drag lock engaged / released (cursor in
    /// BASE): the same pulse as `dragBegan`/`dragEnded`.
    case dragLock(active: Bool, at: CGPoint?)
    /// Trackpad mode: a finger landed (the cursor's halo).
    case fingerDown
    /// A touch moved the cursor (BASE): the motion trail, the drag-lock pulse.
    case cursorMoved(to: CGPoint)
    /// Direct mode: a long press started arming at a finger (SCREEN).
    case longPressBegan(at: CGPoint, duration: TimeInterval)
    /// The armed long press fired (right click / drag) or was abandoned.
    case longPressEnded(fired: Bool)
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
