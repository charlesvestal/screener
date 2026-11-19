import XCTest
@testable import Screener

/// The control menu's sections and tiles (ControlMenuLayout) and the
/// collapsed pill's idle look (PillAppearance).
final class ControlMenuLayoutTests: XCTestCase {
    typealias L = ControlMenuLayout

    private func all(pip: Bool, switchMac: Bool) -> [L.Tile] {
        L.Section.allCases.flatMap { L.tiles($0, pictureInPicture: pip, switchMac: switchMac) }
    }

    func testSectionsAreGroupedKeyboardShortcutsViewClipboardSession() {
        XCTAssertEqual(L.Section.allCases.map(\.title),
                       ["Keyboard", "Mac Shortcuts", "View", "Clipboard", "Session"])
        XCTAssertEqual(L.tiles(.keyboard, pictureInPicture: true, switchMac: true), [.keyboard, .typePassword])
        XCTAssertEqual(L.tiles(.view, pictureInPicture: true, switchMac: true),
                       [.display, .touchMode, .findCursor, .pictureInPicture])
        XCTAssertEqual(L.tiles(.clipboard, pictureInPicture: true, switchMac: true),
                       [.getClipboard, .sendClipboard, .autoClipboard])
        XCTAssertEqual(L.tiles(.session, pictureInPicture: true, switchMac: true),
                       [.mute, .switchMac, .more, .disconnect])
        // The shortcuts section is the ShortcutAction grid, no tiles.
        XCTAssertTrue(L.tiles(.shortcuts, pictureInPicture: true, switchMac: true).isEmpty)
    }

    func testEveryTileAppearsOnceAndDisconnectIsLast() {
        let tiles = all(pip: true, switchMac: true)
        for t in tiles { XCTAssertEqual(tiles.filter { $0 == t }.count, 1, "\(t)") }
        XCTAssertEqual(tiles.count, 13)
        XCTAssertEqual(tiles.last, .disconnect)
        // No section needs more than one row.
        for s in L.Section.allCases {
            XCTAssertLessThanOrEqual(L.tiles(s, pictureInPicture: true, switchMac: true).count, L.columns)
        }
    }

    func testPictureInPictureAndSwitchMacOnlyWhenOffered() {
        let tiles = all(pip: false, switchMac: false)
        XCTAssertFalse(tiles.contains(.pictureInPicture))
        XCTAssertFalse(tiles.contains(.switchMac))
        XCTAssertTrue(tiles.contains(.disconnect))
    }

    func testRarelyNeededItemsLiveUnderMore() {
        XCTAssertEqual(L.MoreItem.allCases, [.stats, .gestureHelp, .shareLog])
        XCTAssertTrue(all(pip: false, switchMac: false).contains(.more))
    }

    func testIdlePillStaysFindable() {
        XCTAssertGreaterThanOrEqual(PillAppearance.idleOpacity, 0.5)
        XCTAssertLessThan(PillAppearance.idleOpacity, 1)
        XCTAssertGreaterThan(PillAppearance.ringOpacity, 0)
        XCTAssertGreaterThan(PillAppearance.shadowOpacity, 0)
    }
}
