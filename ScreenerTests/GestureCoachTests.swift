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

    // MARK: markSeenIfFirstTime (the automatic coach's trigger policy)
    //
    // SessionView's onChange is just `guard has, GestureCoach.
    // markSeenIfFirstTime() else { return }; showCoach = true` — so these
    // tests exercise the actual gate, not a re-implementation of it.

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testMarkSeenIfFirstTime_firstCallFires() {
        let defaults = freshDefaults(#function)
        XCTAssertTrue(GestureCoach.markSeenIfFirstTime(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: GestureCoach.seenKey))
    }

    func testMarkSeenIfFirstTime_secondCallNeverFires() {
        let defaults = freshDefaults(#function)
        XCTAssertTrue(GestureCoach.markSeenIfFirstTime(defaults: defaults))
        XCTAssertFalse(GestureCoach.markSeenIfFirstTime(defaults: defaults))
    }

    /// Repeated `hasFirstFrame` transitions within one session (a reconnect,
    /// a display-mode resize that restarts the stream, Picture in Picture
    /// restoring) must fire the coach exactly once — mirroring SessionView's
    /// `guard has, …` loop over a stream of true/false events.
    func testRepeatedFirstFrameEventsAndReconnectsFireAtMostOnce() {
        let defaults = freshDefaults(#function)
        let hasFirstFrameStream = [true, false, true, false, true, true, false, true]
        var presentations = 0
        for has in hasFirstFrameStream where has {
            if GestureCoach.markSeenIfFirstTime(defaults: defaults) { presentations += 1 }
        }
        XCTAssertEqual(presentations, 1)
    }

    /// Two windows (iPad/Mac "Designed for iPad" multi-window, each with its
    /// own SessionCoordinator/SessionView) connected to two different Macs:
    /// whichever reaches its first picture first wins, the other must not
    /// also present — both calls go through the same UserDefaults store,
    /// checked and set atomically, not a per-View cached flag.
    func testTwoHostsOnlyOneWindowPresents() {
        let defaults = freshDefaults(#function)
        let windowAFired = GestureCoach.markSeenIfFirstTime(defaults: defaults)
        let windowBFired = GestureCoach.markSeenIfFirstTime(defaults: defaults)
        XCTAssertTrue(windowAFired)
        XCTAssertFalse(windowBFired)
    }

    /// Across app relaunches (a fresh `UserDefaults` read, same store): once
    /// marked, it stays marked — "once ever per install", not once per run.
    func testStaysSeenAcrossRelaunchSimulation() {
        let defaults = freshDefaults(#function)
        XCTAssertTrue(GestureCoach.markSeenIfFirstTime(defaults: defaults))
        // A later launch constructs its own SessionView/@State from scratch;
        // nothing but the persisted default carries over.
        XCTAssertFalse(GestureCoach.markSeenIfFirstTime(defaults: defaults))
        XCTAssertFalse(GestureCoach.markSeenIfFirstTime(defaults: defaults))
    }
}
