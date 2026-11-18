import SwiftUI
import XCTest
@testable import Screener

/// iPhone / iPad / Mac layout decisions (AdaptiveLayout), the 3× display
/// geometry, and the keyboard accessory row on narrow widths.
@MainActor
final class AdaptiveLayoutTests: XCTestCase {
    // MARK: control menu

    func testControlMenuIsABottomSheetOnCompactSizes() {
        typealias L = AdaptiveLayout
        // iPad full screen / large Stage Manager window, Mac window.
        XCTAssertEqual(L.menuPresentation(horizontal: .regular, vertical: .regular), .floatingPanel)
        // iPhone portrait; iPad Slide Over / narrow split.
        XCTAssertEqual(L.menuPresentation(horizontal: .compact, vertical: .regular), .bottomSheet)
        // iPhone landscape (compact height; Pro Max is regular width there).
        XCTAssertEqual(L.menuPresentation(horizontal: .compact, vertical: .compact), .bottomSheet)
        XCTAssertEqual(L.menuPresentation(horizontal: .regular, vertical: .compact), .bottomSheet)
        // Unknown size class (no trait yet): the panel.
        XCTAssertEqual(L.menuPresentation(horizontal: nil, vertical: nil), .floatingPanel)
    }

    // MARK: host list

    func testHostCardsAreOneColumnOnACompactWidth() {
        let compact = AdaptiveLayout.hostCardMinimumWidth(horizontal: .compact)
        let regular = AdaptiveLayout.hostCardMinimumWidth(horizontal: .regular)
        // An iPhone 17 Pro portrait list (402 pt − 2 × 16 pt padding) fits one card...
        XCTAssertEqual(Int((402 - 32 + 16) / (compact + 16)), 1)
        // ...the smallest iPhone (375 pt) still at least one.
        XCTAssertLessThanOrEqual(compact, 375 - 32)
        // iPad keeps its multi-column grid.
        XCTAssertGreaterThanOrEqual(Int((1376 - 32 + 16) / (regular + 16)), 4)
    }

    // MARK: session

    func testLandscapeHintOnlyForAPortraitPhone() {
        let portrait = CGSize(width: 402, height: 874), landscape = CGSize(width: 874, height: 402)
        XCTAssertTrue(AdaptiveLayout.suggestsLandscape(platform: .phone, size: portrait))
        XCTAssertFalse(AdaptiveLayout.suggestsLandscape(platform: .phone, size: landscape))
        XCTAssertFalse(AdaptiveLayout.suggestsLandscape(platform: .pad, size: CGSize(width: 1032, height: 1376)))
        XCTAssertFalse(AdaptiveLayout.suggestsLandscape(platform: .mac, size: portrait))
        XCTAssertFalse(AdaptiveLayout.suggestsLandscape(platform: .phone, size: .zero))
    }

    func testMacGatesPointerLockAndPictureInPicture() {
        XCTAssertTrue(AdaptiveLayout.supportsPointerLock(platform: .pad))
        XCTAssertTrue(AdaptiveLayout.supportsPointerLock(platform: .phone))
        XCTAssertFalse(AdaptiveLayout.supportsPointerLock(platform: .mac))
        XCTAssertTrue(AdaptiveLayout.supportsPictureInPicture(platform: .phone, systemSupported: true))
        XCTAssertTrue(AdaptiveLayout.supportsPictureInPicture(platform: .pad, systemSupported: true))
        XCTAssertFalse(AdaptiveLayout.supportsPictureInPicture(platform: .pad, systemSupported: false))
        XCTAssertFalse(AdaptiveLayout.supportsPictureInPicture(platform: .mac, systemSupported: true))
    }

    func testPlatformOfThisRun() {
        let expected: AdaptiveLayout.Platform = ProcessInfo.processInfo.isiOSAppOnMac ? .mac
            : (UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad)
        XCTAssertEqual(AdaptiveLayout.Platform.current, expected)
        XCTAssertEqual(PointerLock.isAvailable, expected != .mac)
    }

    func testStatsPanelClearsTheToastRowOnACompactWidth() {
        // Toast: 14 pt from the top, ~44 pt tall.
        XCTAssertGreaterThanOrEqual(AdaptiveLayout.statsTopInset(horizontal: .compact), 14 + 44 + 8)
        XCTAssertEqual(AdaptiveLayout.statsTopInset(horizontal: .regular), 16)
    }

    func testCoachCardsAreShorterInACompactHeight() {
        XCTAssertLessThan(AdaptiveLayout.coachCardHeight(vertical: .compact),
                          AdaptiveLayout.coachCardHeight(vertical: .regular))
        // Title + card + "Got it" fit an iPhone in landscape (402 pt minus the home indicator).
        XCTAssertLessThanOrEqual(AdaptiveLayout.coachCardHeight(vertical: .compact) + 8 + 22 + 8 + 50 + 8 + 8, 381)
    }

    // MARK: display geometry on a 3× screen

    private func g(_ w: Int, _ h: Int) -> DisplayGeometry { DisplayGeometry(logicalWidth: w, logicalHeight: h, hidpiScale: 2) }

    func testFitRetinaOnA3xPhoneIsPixelForPixelAt2x() throws {
        // iPhone 17 Pro: 874×402 pt at 3× (2622×1206 px).
        let l = try XCTUnwrap(DisplayMode.fitRetina.geometry(viewPoints: CGSize(width: 874, height: 402), scale: 3))
        XCTAssertEqual(l, g(1311, 603))
        XCTAssertEqual(l.backingSize, CGSize(width: 2622, height: 1206))
        XCTAssertEqual(DisplayMode.fitRetina.geometry(viewPoints: CGSize(width: 402, height: 874), scale: 3),
                       g(603, 1311))
        // The Mac's display never goes past 2× HiDPI.
        XCTAssertEqual(l.hidpiScale, 2)
    }

    func testScaledModesOnA3xPhone() {
        let landscape = CGSize(width: 874, height: 402)
        // Sharper: 0.8 × 1.5 = 1.2× the points, even.
        XCTAssertEqual(DisplayMode.sharper.geometry(viewPoints: landscape, scale: 3), g(1048, 482))
        // More Space: 1.25 × 1.5 = 1.875×, even.
        XCTAssertEqual(DisplayMode.moreSpace.geometry(viewPoints: landscape, scale: 3), g(1638, 754))
        XCTAssertNil(DisplayMode.matchMac.geometry(viewPoints: landscape, scale: 3))
    }

    func test2xAnd1xScreensAreUnchanged() {
        // iPad / Retina Mac.
        XCTAssertEqual(DisplayMode.fitRetina.geometry(viewPoints: CGSize(width: 1376, height: 1032), scale: 2),
                       g(1376, 1032))
        // The iPad app on a non-Retina Mac display: 1× HiDPI.
        XCTAssertEqual(DisplayMode.fitRetina.geometry(viewPoints: CGSize(width: 1280, height: 800), scale: 1),
                       DisplayGeometry(logicalWidth: 1280, logicalHeight: 800, hidpiScale: 1))
    }

    // MARK: keyboard accessory row

    func testAccessoryRowScrollsOnlyWhenTheKeysWouldGetTooNarrow() {
        typealias Bar = KeyboardAccessoryBar
        let n = CGFloat(Bar.items.count)
        let minimum = n * Bar.minimumKeyWidth + (n - 1) * Bar.spacing
        // iPhone portrait (402 / 375 pt): scrolls at the minimum key width.
        for width: CGFloat in [375, 402] {
            let l = Bar.rowLayout(width: width)
            XCTAssertTrue(l.scrolls, "\(width)")
            XCTAssertEqual(l.rowWidth, minimum)
            XCTAssertEqual(l.inset, Bar.sideMargin)
        }
        // iPhone landscape (874 pt, minus ~62 pt each side for the sensor housing): fits.
        let phoneLandscape = Bar.rowLayout(width: 874 - 124)
        XCTAssertFalse(phoneLandscape.scrolls)
        XCTAssertEqual(phoneLandscape.rowWidth, min(874 - 124 - 2 * Bar.sideMargin, Bar.maximumRowWidth))
        // iPad: centred at the maximum width.
        let pad = Bar.rowLayout(width: 1376)
        XCTAssertFalse(pad.scrolls)
        XCTAssertEqual(pad.rowWidth, Bar.maximumRowWidth)
        XCTAssertEqual(pad.inset, (1376 - Bar.maximumRowWidth) / 2)
    }

    func testAccessoryBarKeepsEveryKeyTappableWhenNarrow() throws {
        let bar = KeyboardAccessoryBar()
        bar.frame = CGRect(x: 0, y: 0, width: 375, height: KeyboardAccessoryBar.height)
        bar.layoutIfNeeded()
        XCTAssertTrue(bar.rowScrolls)
        for item in KeyboardAccessoryBar.items {
            let b = try XCTUnwrap(bar.button(for: item))
            XCTAssertGreaterThanOrEqual(b.bounds.width, KeyboardAccessoryBar.minimumKeyWidth - 0.5, "\(item)")
        }
        bar.frame.size.width = 1024
        bar.layoutIfNeeded()
        XCTAssertFalse(bar.rowScrolls)
    }
}
