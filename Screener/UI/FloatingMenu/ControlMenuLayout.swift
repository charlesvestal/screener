// What the expanded control menu shows, and in which order (pure;
// ControlMenuLayoutTests). FloatingMenuView's ControlPanel renders it.
//
//   Keyboard       Keyboard · Type Password, then the sticky modifiers and
//                  the special keys (Esc, Tab, ⌫, ⌦, F1–F12, arrows, …)
//   Mac Shortcuts  App Switcher, Spotlight, Mission Control, … (ShortcutAction)
//   View           Display · Touch Mode · Find Cursor · Picture in Picture
//   Clipboard      Get · Send · Auto Clipboard
//   Session        Mute · Switch Mac · More · Disconnect
//   More (pop-up)  Stats · Gesture Help · Share Log
//
// Smooth Playback is not here: it only takes effect on the next connection,
// and Settings (and Edit Mac → Session, per Mac) set it.
import Foundation

enum ControlMenuLayout {
    enum Section: String, CaseIterable, Sendable {
        case keyboard = "Keyboard"
        case shortcuts = "Mac Shortcuts"
        case view = "View"
        case clipboard = "Clipboard"
        case session = "Session"

        var title: String { rawValue }
    }

    /// A tile in a section's grid.
    enum Tile: Equatable, Sendable {
        case keyboard, typePassword
        case display, touchMode, findCursor, pictureInPicture
        case getClipboard, sendClipboard, autoClipboard
        case mute, switchMac, more, disconnect
    }

    /// The "More" pop-up: rarely needed, kept reachable.
    enum MoreItem: Equatable, Sendable, CaseIterable {
        case stats, gestureHelp, shareLog
    }

    /// Tiles per grid row (every section: the same tile width).
    static let columns = 4

    /// A section's tiles. `pictureInPicture` / `switchMac`: the session
    /// offers them (SessionControls).
    static func tiles(_ section: Section, pictureInPicture: Bool, switchMac: Bool) -> [Tile] {
        switch section {
        case .keyboard: [.keyboard, .typePassword]
        case .shortcuts: []
        case .view: [.display, .touchMode, .findCursor] + (pictureInPicture ? [.pictureInPicture] : [])
        case .clipboard: [.getClipboard, .sendClipboard, .autoClipboard]
        case .session: [.mute] + (switchMac ? [.switchMac] : []) + [.more, .disconnect]
        }
    }
}
