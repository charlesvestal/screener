// iPhone, iPad and "Designed for iPad" on a Mac: the layout decisions that
// differ by size class / platform, as pure functions (AdaptiveLayoutTests).
//
// - Control menu: the draggable pill everywhere; its panel floats beside the
//   pill when there is room (regular width and height), and is a bottom
//   sheet (.medium / .large) on a compact width or height (iPhone, a narrow
//   Stage Manager window, Slide Over).
// - Host list: an adaptive grid of cards on iPad / Mac; on a compact width
//   (iPhone) one column of rows (thumbnail beside the name: HostCard).
// - Display: every idiom defaults to Fit (Retina), whose geometry is
//   scale-aware (DisplayMode.geometry): the Mac's virtual display is always
//   2× HiDPI, sized pixel for pixel to the view, so on a 3× iPhone the Mac's
//   desktop is 1.5× the phone's points (an iPhone 17 Pro in landscape gets a
//   1311×603 pt Mac desktop, rendered 1:1 into its 2622×1206 px screen).
//   That is the readable middle ground: Mac text appears at ⅔ of its size
//   on the Mac (pinch to zoom, trackpad mode to point precisely), while the
//   desktop is large enough for ordinary Mac windows.
// - Landscape hint: an iPhone session in portrait suggests turning it
//   sideways (once per session).
// - Mac ("Designed for iPad", ProcessInfo.isiOSAppOnMac): no pointer lock
//   (the Mac's own pointer drives the session through hover / clicks) and no
//   Picture in Picture.
import Foundation
import SwiftUI
import UIKit

enum AdaptiveLayout {
    /// What the app runs on.
    enum Platform: Equatable, Sendable {
        case phone, pad
        /// The iPad app on an Apple-silicon Mac ("Designed for iPad").
        case mac

        @MainActor static var current: Platform {
            if ProcessInfo.processInfo.isiOSAppOnMac { return .mac }
            return UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad
        }
    }

    /// How the expanded control menu is shown.
    enum MenuPresentation: Equatable, Sendable {
        /// The glass panel beside the pill (iPad, Mac).
        case floatingPanel
        /// A bottom sheet with medium / large detents (iPhone, narrow windows).
        case bottomSheet
    }

    static func menuPresentation(horizontal: UserInterfaceSizeClass?,
                                 vertical: UserInterfaceSizeClass?) -> MenuPresentation {
        horizontal == .compact || vertical == .compact ? .bottomSheet : .floatingPanel
    }

    /// Smallest host card width: one full-width column on a compact width.
    static func hostCardMinimumWidth(horizontal: UserInterfaceSizeClass?) -> CGFloat {
        horizontal == .compact ? 300 : 220
    }

    /// Show "turn sideways" for a session view of `size` on `platform`.
    static func suggestsLandscape(platform: Platform, size: CGSize) -> Bool {
        platform == .phone && size.height > size.width
    }

    /// Pointer lock (GCMouse-driven) is offered: not for the iPad app on a
    /// Mac, where the system won't lock the Mac's pointer to an iOS app's
    /// window and hover/clicks already carry the Mac's own pointer.
    static func supportsPointerLock(platform: Platform) -> Bool { platform != .mac }

    /// Picture in Picture is offered (and AVKit says the device supports it).
    static func supportsPictureInPicture(platform: Platform, systemSupported: Bool) -> Bool {
        systemSupported && platform != .mac
    }

    /// The stats panel's top inset: below the toast row on a compact width,
    /// where a toast (top centre) would otherwise cover it.
    static func statsTopInset(horizontal: UserInterfaceSizeClass?) -> CGFloat {
        horizontal == .compact ? 72 : 16
    }

    /// The gesture coach's card height: shorter in a compact height
    /// (iPhone landscape) so card, title and "Got it" fit.
    static func coachCardHeight(vertical: UserInterfaceSizeClass?) -> CGFloat {
        vertical == .compact ? 210 : 320
    }
}
