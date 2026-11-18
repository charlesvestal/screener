import XCTest
@testable import Screener

/// The gesture coach's card sets (one per TouchInputMode) and the
/// "coach.seen" @AppStorage key it's gated by.
final class GestureCoachTests: XCTestCase {
    func testTrackpadCardsMatchCurrentMode() {
        let cards = GestureCoach.cards(for: .trackpad)
        XCTAssertEqual(cards, GestureCoach.trackpadCards)
    }

    func testDirectCardsMatchCurrentMode() {
        let cards = GestureCoach.cards(for: .direct)
        XCTAssertEqual(cards, GestureCoach.directCards)
    }

    func testEachModeHasBetweenFourAndSixCards() {
        for mode in TouchInputMode.allCases {
            let count = GestureCoach.cards(for: mode).count
            XCTAssertGreaterThanOrEqual(count, 4, "\(mode) has too few cards")
            XCTAssertLessThanOrEqual(count, 6, "\(mode) has too many cards")
        }
    }

    func testCardsHaveUniqueIDs() {
        for mode in TouchInputMode.allCases {
            let ids = GestureCoach.cards(for: mode).map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(mode) has duplicate card ids")
        }
    }

    func testCardsHaveNonEmptyContent() {
        for mode in TouchInputMode.allCases {
            for card in GestureCoach.cards(for: mode) {
                XCTAssertFalse(card.systemImage.isEmpty)
                XCTAssertFalse(card.title.isEmpty)
                XCTAssertFalse(card.subtitle.isEmpty)
            }
        }
    }

    /// Both modes teach opening the control menu with the same instruction.
    func testBothModesTeachOpeningTheMenu() {
        for mode in TouchInputMode.allCases {
            let cards = GestureCoach.cards(for: mode)
            XCTAssertTrue(cards.contains { $0.kind == .menu }, "\(mode) is missing the open-menu card")
        }
    }

    /// Trackpad teaches relative pointer movement; direct teaches tap-to-click
    /// at the touch point — the two modes must not share the same "move" card.
    func testModesHaveDistinctMoveCards() {
        let trackpadMove = GestureCoach.trackpadCards.first { $0.id == "move" }
        let directMove = GestureCoach.directCards.first { $0.id == "move" }
        XCTAssertNotEqual(trackpadMove, directMove)
        XCTAssertEqual(trackpadMove?.kind, .moveTrackpad)
        XCTAssertEqual(directMove?.kind, .moveDirect)
    }

    // MARK: seen flag

    func testSeenKeyDefaultsToUnseen() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        XCTAssertFalse(defaults.bool(forKey: GestureCoach.seenKey))
    }

    func testSeenKeyPersistsOnceSet() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        XCTAssertFalse(defaults.bool(forKey: GestureCoach.seenKey))
        defaults.set(true, forKey: GestureCoach.seenKey)
        XCTAssertTrue(defaults.bool(forKey: GestureCoach.seenKey))
    }
}
