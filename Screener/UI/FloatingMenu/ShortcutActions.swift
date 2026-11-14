// Mac shortcuts the floating menu can send. iPadOS keeps some chords for
// itself (⌘Tab, ⌘Space, Globe), and a soft-keyboard user has no modifiers at
// all, so these are one tap away. Each is a declarative key chord: the
// modifiers pressed in order, the key tapped, the modifiers released in
// reverse (ShortcutActionsTests checks every list).
import Foundation

struct KeyChord: Equatable, Sendable {
    var modifiers: [UInt32]
    var key: UInt32

    init(_ modifiers: [UInt32], _ key: UInt32) {
        self.modifiers = modifiers
        self.key = key
    }

    var strokes: [KeyStroke] {
        modifiers.map(KeyStroke.down) + [.down(key), .up(key)] + modifiers.reversed().map(KeyStroke.up)
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    /// ⌘Tab. The menu keeps ⌘ held across repeated taps (each sends Tab) so
    /// the app switcher stays up; ⌘ is released when the menu collapses or
    /// after `ControlMenuModel.appSwitcherIdleRelease` without a tap.
    case appSwitcher
    case spotlight
    case missionControl
    case appExpose
    case showDesktop
    case lockScreen
    case forceQuit
    case screenshot
    case screenshotToClipboard

    var id: String { rawValue }

    private static let cmd = StickyModifier.command.keysym!
    private static let opt = StickyModifier.option.keysym!
    private static let ctrl = StickyModifier.control.keysym!
    private static let shift = StickyModifier.shift.keysym!

    var chord: KeyChord {
        switch self {
        case .appSwitcher: KeyChord([Self.cmd], SpecialKey.tab.keysym)
        case .spotlight: KeyChord([Self.cmd], 0x20)                              // space
        case .missionControl: KeyChord([Self.ctrl], SpecialKey.up.keysym)
        case .appExpose: KeyChord([Self.ctrl], SpecialKey.down.keysym)
        case .showDesktop: KeyChord([], SpecialKey.function(11).keysym)
        case .lockScreen: KeyChord([Self.ctrl, Self.cmd], 0x71)                  // q
        case .forceQuit: KeyChord([Self.opt, Self.cmd], SpecialKey.escape.keysym)
        case .screenshot: KeyChord([Self.shift, Self.cmd], 0x34)                 // 4
        case .screenshotToClipboard: KeyChord([Self.ctrl, Self.shift, Self.cmd], 0x34)
        }
    }

    var title: String {
        switch self {
        case .appSwitcher: "App Switcher"
        case .spotlight: "Spotlight"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .showDesktop: "Show Desktop"
        case .lockScreen: "Lock Screen"
        case .forceQuit: "Force Quit"
        case .screenshot: "Screenshot"
        case .screenshotToClipboard: "Screenshot to Clipboard"
        }
    }

    /// The chord as a Mac menu would print it (⌃⌥⇧⌘ order).
    var shortcutText: String {
        switch self {
        case .appSwitcher: "⌘⇥"
        case .spotlight: "⌘Space"
        case .missionControl: "⌃↑"
        case .appExpose: "⌃↓"
        case .showDesktop: "F11"
        case .lockScreen: "⌃⌘Q"
        case .forceQuit: "⌥⌘⎋"
        case .screenshot: "⇧⌘4"
        case .screenshotToClipboard: "⌃⇧⌘4"
        }
    }

    var systemImage: String {
        switch self {
        case .appSwitcher: "square.stack.3d.forward.dottedline"
        case .spotlight: "magnifyingglass"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "rectangle.stack"
        case .showDesktop: "menubar.dock.rectangle"
        case .lockScreen: "lock"
        case .forceQuit: "xmark.octagon"
        case .screenshot: "camera.viewfinder"
        case .screenshotToClipboard: "doc.on.clipboard"
        }
    }
}
