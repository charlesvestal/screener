import SwiftData
import XCTest
@testable import Screener

/// A throwaway UserDefaults suite (the live session keys) per test.
@MainActor
private func makeDefaults() -> UserDefaults {
    let name = "screener.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: override resolution

@MainActor
final class SessionOverridesTests: XCTestCase {
    func testEachSettingIsHostOverrideElseGlobal() {
        let global = SessionSettings(displayMode: .moreSpace, touchMode: .trackpad, audioMuted: false,
                                     clipboardMode: .automatic, smoothPlayback: false)
        XCTAssertEqual(SessionOverrides.none.resolved(over: global), global)
        let o = SessionOverrides(displayMode: .sharper, touchMode: nil, audioMuted: true, clipboardMode: nil,
                                 smoothPlayback: true)
        XCTAssertEqual(o.resolved(over: global),
                       SessionSettings(displayMode: .sharper, touchMode: .trackpad, audioMuted: true,
                                       clipboardMode: .automatic, smoothPlayback: true))
        let all = SessionOverrides(displayMode: .matchMac, touchMode: .direct, audioMuted: false,
                                   clipboardMode: .manual, smoothPlayback: false)
        XCTAssertEqual(all.resolved(over: SessionSettings(audioMuted: true, smoothPlayback: true)),
                       SessionSettings(displayMode: .matchMac, touchMode: .direct, audioMuted: false,
                                       clipboardMode: .manual, smoothPlayback: false))
    }

    func testSavedHostFieldsMapToOverrides() {
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        XCTAssertEqual(h.sessionOverrides, .none, "a new host uses every default")
        h.sessionOverrides = SessionOverrides(displayMode: .sharper, touchMode: .direct, audioMuted: true,
                                              clipboardMode: .manual, smoothPlayback: true)
        XCTAssertEqual(h.displayMode, "sharper")
        XCTAssertEqual(h.inputMode, "direct")
        XCTAssertEqual(h.audioEnabled, false)
        XCTAssertEqual(h.clipboardEnabled, false)
        XCTAssertEqual(h.smoothPlayback, true)
        XCTAssertEqual(h.sessionOverrides.audioMuted, true)
        h.displayMode = "fromTheFuture"
        XCTAssertNil(h.sessionOverrides.displayMode, "an unknown stored value reads as Use Default")
        h.sessionOverrides = .none
        XCTAssertNil(h.inputMode)
        XCTAssertNil(h.audioEnabled)
        XCTAssertNil(h.smoothPlayback)
    }

    func testEditorLoadsAndSavesOverrides() throws {
        let c = try HostStore.makeContainer(inMemory: true)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        h.inputMode = "direct"
        c.mainContext.insert(h)
        let editor = HostEditorModel(editing: h, passwords: MemoryPasswordStore())
        XCTAssertEqual(editor.overrides.touchMode, .direct)
        editor.overrides.touchMode = nil
        editor.overrides.displayMode = .moreSpace
        try editor.save(existing: h, context: c.mainContext, passwords: MemoryPasswordStore())
        XCTAssertNil(h.inputMode)
        XCTAssertEqual(h.displayMode, "moreSpace")
    }

    func testDuplicateCopiesOverrides() throws {
        let c = try HostStore.makeContainer(inMemory: true)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        h.smoothPlayback = true
        h.audioEnabled = false
        c.mainContext.insert(h)
        let copy = try HostStore.duplicate(h, in: c.mainContext, passwords: MemoryPasswordStore())
        XCTAssertEqual(copy.sessionOverrides, h.sessionOverrides)
    }
}

// MARK: the overlay (live keys during a session)

@MainActor
final class HostSettingsOverlayTests: XCTestCase {
    func testBeginAppliesEffectiveValuesAndEndRestoresTheDefaults() {
        let d = makeDefaults()
        d.set(DisplayMode.moreSpace.rawValue, forKey: DisplayMode.defaultsKey)
        d.set(true, forKey: AudioPlayer.mutedDefaultsKey)
        let global = SessionSettings.read(d)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        h.sessionOverrides = SessionOverrides(displayMode: .sharper, audioMuted: false, smoothPlayback: true)

        let overlay = HostSettingsOverlay(defaults: d)
        overlay.begin(h)
        XCTAssertEqual(overlay.hostID, h.id)
        XCTAssertEqual(SessionSettings.read(d), h.sessionOverrides.resolved(over: global))
        XCTAssertNotNil(d.dictionary(forKey: HostSettingsOverlay.savedGlobalsKey))

        overlay.end()
        XCTAssertNil(overlay.hostID)
        XCTAssertEqual(SessionSettings.read(d), global)
        XCTAssertNil(d.dictionary(forKey: HostSettingsOverlay.savedGlobalsKey))
        overlay.end()   // idempotent
        XCTAssertEqual(SessionSettings.read(d), global)
    }

    func testMenuChangesPersistToTheCurrentHostNotTheDefaults() {
        let d = makeDefaults()
        let global = SessionSettings.read(d)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        let overlay = HostSettingsOverlay(defaults: d)
        overlay.begin(h)
        XCTAssertEqual(overlay.captureChanges(into: h), [], "what the overlay wrote isn't the user's change")

        // The control menu writes the live keys.
        d.set(TouchInputMode.direct.rawValue, forKey: TouchInputMode.defaultsKey)
        d.set(true, forKey: AudioPlayer.mutedDefaultsKey)
        XCTAssertEqual(overlay.captureChanges(into: h), [.touchMode, .audio])
        XCTAssertEqual(h.sessionOverrides, SessionOverrides(touchMode: .direct, audioMuted: true))
        XCTAssertEqual(overlay.captureChanges(into: h), [], "captured once")

        // Another host is never written.
        let other = SavedHost(name: "Other", host: "1.2.3.5", username: "u")
        d.set(ClipboardSyncMode.manual.rawValue, forKey: ClipboardSyncMode.defaultsKey)
        XCTAssertEqual(overlay.captureChanges(into: other), [])
        XCTAssertEqual(other.sessionOverrides, .none)

        overlay.end()
        XCTAssertEqual(SessionSettings.read(d), global, "the defaults were never changed by the menu")
        // After the session, a change (Settings) is a default, not an override.
        d.set(DisplayMode.sharper.rawValue, forKey: DisplayMode.defaultsKey)
        XCTAssertEqual(overlay.captureChanges(into: h), [])
        XCTAssertNil(h.sessionOverrides.displayMode)
    }

    func testCrashRecoveryPutsTheDefaultsBack() {
        let d = makeDefaults()
        let global = SessionSettings.read(d)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        h.sessionOverrides = SessionOverrides(displayMode: .matchMac, touchMode: .direct)
        HostSettingsOverlay(defaults: d).begin(h)   // ...and the app dies mid-session
        XCTAssertNotEqual(SessionSettings.read(d), global)
        HostSettingsOverlay.recoverAfterCrash(d)
        XCTAssertEqual(SessionSettings.read(d), global)
        XCTAssertNil(d.dictionary(forKey: HostSettingsOverlay.savedGlobalsKey))
        HostSettingsOverlay.recoverAfterCrash(d)   // nothing to do
        XCTAssertEqual(SessionSettings.read(d), global)
    }

    func testConnectorSavesMenuChangesOnTheSessionsHost() throws {
        let d = makeDefaults()
        let c = try HostStore.makeContainer(inMemory: true)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        c.mainContext.insert(h)
        let connector = HostConnector(model: SessionCoordinator(), passwords: MemoryPasswordStore(), settingsDefaults: d)
        connector.markConnected(h, resolvedAddress: nil, rememberPassword: nil, context: c.mainContext)
        XCTAssertEqual(connector.sessionHostName, "Studio")

        d.set(DisplayMode.sharper.rawValue, forKey: DisplayMode.defaultsKey)
        XCTAssertEqual(connector.captureSessionSettings(context: c.mainContext), [.displayMode])
        XCTAssertEqual(h.displayMode, "sharper")

        // The session view went away (no session up): the defaults return.
        connector.sessionEnded()
        XCTAssertNil(connector.sessionHostName)
        XCTAssertEqual(DisplayMode.stored(d), .default)
        // The next session on this Mac starts with what was saved.
        connector.markConnected(h, resolvedAddress: nil, rememberPassword: nil, context: c.mainContext)
        XCTAssertEqual(DisplayMode.stored(d), .sharper)
        connector.sessionEnded()
    }
}

// MARK: resume on launch

@MainActor
final class ResumeOnLaunchTests: XCTestCase {
    private func hosts() -> (old: SavedHost, last: SavedHost, never: SavedHost) {
        let old = SavedHost(name: "Old", host: "1.1.1.1", username: "u", lastConnected: Date(timeIntervalSince1970: 100))
        let last = SavedHost(name: "Last", host: "1.1.1.2", username: "u", lastConnected: Date(timeIntervalSince1970: 200))
        let never = SavedHost(name: "Never", host: "1.1.1.3", username: "u")
        return (old, last, never)
    }

    func testPicksTheLastConnectedHostOnlyOnAColdLaunchWithAStoredPassword() {
        let h = hosts()
        let all = [h.old, h.never, h.last]
        XCTAssertTrue(ResumeOnLaunch.candidate(enabled: true, coldLaunch: true, hosts: all,
                                               hasStoredPassword: { _ in true }) === h.last)
        XCTAssertNil(ResumeOnLaunch.candidate(enabled: false, coldLaunch: true, hosts: all,
                                              hasStoredPassword: { _ in true }), "off by default")
        XCTAssertNil(ResumeOnLaunch.candidate(enabled: true, coldLaunch: false, hosts: all,
                                              hasStoredPassword: { _ in true }), "not when returning from background")
        XCTAssertNil(ResumeOnLaunch.candidate(enabled: true, coldLaunch: true, hosts: all,
                                              hasStoredPassword: { $0 !== h.last }),
                     "no stored password: no prompt at launch, and no falling back to another Mac")
        XCTAssertNil(ResumeOnLaunch.candidate(enabled: true, coldLaunch: true, hosts: [h.never],
                                              hasStoredPassword: { _ in true }))
        h.last.username = ""
        XCTAssertNil(ResumeOnLaunch.candidate(enabled: true, coldLaunch: true, hosts: all,
                                              hasStoredPassword: { _ in true }))
    }

    func testSettingDefaultsOff() {
        let d = makeDefaults()
        XCTAssertFalse(ResumeOnLaunch.isEnabled(d))
        d.set(true, forKey: ResumeOnLaunch.enabledKey)
        XCTAssertTrue(ResumeOnLaunch.isEnabled(d))
    }

    func testTheGateOpensOncePerProcess() {
        let gate = LaunchGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    func testCountdownFiresAfterTheDelay() async {
        let h = hosts().last
        let resumer = LaunchResumer(sleep: { _ in })
        var fired: [UUID] = []
        resumer.start(h, delay: .seconds(2)) { fired.append($0) }
        XCTAssertEqual(resumer.pending, .init(hostID: h.id, name: "Last"))
        await resumer.pendingTask?.value
        XCTAssertEqual(fired, [h.id])
        XCTAssertNil(resumer.pending)
    }

    func testCancelStopsTheCountdown() async {
        let h = hosts().last
        let gate = AsyncStream<Void>.makeStream()
        let resumer = LaunchResumer(sleep: { _ in
            for await _ in gate.stream { break }
            try Task.checkCancellation()
        })
        var fired = 0
        resumer.start(h) { _ in fired += 1 }
        let task = resumer.pendingTask
        resumer.cancel()
        XCTAssertNil(resumer.pending)
        gate.continuation.yield()
        await task?.value
        XCTAssertEqual(fired, 0)
    }
}

// MARK: switching Macs

@MainActor
final class SwitchMacTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _auths: [(user: String, pass: String, earlierClosed: Bool)] = []
        private var _channels: [FakeDatagramChannel] = []

        func make() -> FakeDatagramChannel {
            let c = FakeDatagramChannel()
            lock.lock(); _channels.append(c); lock.unlock()
            return c
        }
        var channels: [FakeDatagramChannel] { lock.lock(); defer { lock.unlock() }; return _channels }
        var auths: [(user: String, pass: String, earlierClosed: Bool)] {
            lock.lock(); defer { lock.unlock() }; return _auths
        }
        /// Each handshake records whether every earlier session's sockets
        /// (all but the newest two channels) were already closed.
        func noteAuth(_ user: String, _ pass: String) {
            lock.lock()
            let earlier = _channels.dropLast(2)
            _auths.append((user, pass, earlier.allSatisfy(\.cancelled)))
            lock.unlock()
        }
    }

    private func coordinator(_ rec: Recorder) -> SessionCoordinator {
        SessionCoordinator(seams: SessionCoordinator.Seams(
            resolveIPv4: { host in
                switch host {
                case "a.test": "192.0.2.71"
                case "b.test": "192.0.2.72"
                default: throw TransportError.closed
                }
            },
            controlSeams: { _ in
                ControlSession.Seams(
                    connect: { _, _ in throw TransportError.closed },
                    authenticate: { user, pass, _, _ in
                        rec.noteAuth(user, pass)
                        try await Task.sleep(for: .seconds(60))   // parked until cancelled
                        throw TransportError.closed
                    })
            },
            channelFactory: { _, _ in rec.make() }))
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
        for _ in 0..<600 where !cond() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private struct Setup {
        let connector: HostConnector
        let rec: Recorder
        let context: ModelContext
        let container: ModelContainer
        let defaults: UserDefaults
        let a: SavedHost
        let b: SavedHost
        let passwords: MemoryPasswordStore
    }

    private func setup() throws -> Setup {
        let rec = Recorder()
        let container = try HostStore.makeContainer(inMemory: true)
        let a = SavedHost(name: "A", host: "a.test", username: "ua")
        let b = SavedHost(name: "B", host: "b.test", username: "ub")
        a.sessionOverrides = SessionOverrides(touchMode: .direct)
        b.sessionOverrides = SessionOverrides(displayMode: .sharper)
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        let passwords = MemoryPasswordStore()
        try passwords.setPassword("pwA", for: a.id)
        let defaults = makeDefaults()
        let connector = HostConnector(model: coordinator(rec), passwords: passwords, settingsDefaults: defaults)
        return Setup(connector: connector, rec: rec, context: container.mainContext, container: container,
                     defaults: defaults, a: a, b: b, passwords: passwords)
    }

    func testSwitchTearsDownFirstThenConnectsWithTheOtherMacsOwnCredentials() async throws {
        let s = try setup()
        try s.passwords.setPassword("pwB", for: s.b.id)
        let global = SessionSettings.read(s.defaults)
        let first = Task { await s.connector.connect(saved: s.a, password: "pwA", remember: false, service: nil,
                                                    context: s.context) }
        try await waitUntil("A handshaking") { s.rec.auths.count == 1 }
        XCTAssertEqual(s.connector.settings.hostID, s.a.id)
        XCTAssertEqual(SessionSettings.read(s.defaults).touchMode, .direct, "A's override applies to A")

        let switching = Task { await s.connector.switchSession(to: s.b, service: nil, context: s.context) }
        try await waitUntil("B handshaking") { s.rec.auths.count == 2 }
        let auths = s.rec.auths
        XCTAssertEqual(auths.map(\.user), ["ua", "ub"])
        XCTAssertEqual(auths.map(\.pass), ["pwA", "pwB"], "B gets only its own password")
        XCTAssertTrue(auths[1].earlierClosed, "A's session was torn down before B's handshake began")
        XCTAssertEqual(s.connector.model.lastRequest?.username, "ub")
        XCTAssertEqual(s.connector.model.lastRequest?.password, "pwB")
        XCTAssertEqual(s.connector.model.lastRequest?.host, "b.test")

        // B's settings replace A's (A's touch override doesn't carry over).
        XCTAssertEqual(s.connector.settings.hostID, s.b.id)
        let live = SessionSettings.read(s.defaults)
        XCTAssertEqual(live.displayMode, .sharper)
        XCTAssertEqual(live.touchMode, global.touchMode)

        // A's connect unwinding late must not undo B's settings.
        await first.value
        XCTAssertEqual(s.connector.settings.hostID, s.b.id)

        await s.connector.cancel()
        let outcome = await switching.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(s.connector.settings.hostID)
        XCTAssertEqual(SessionSettings.read(s.defaults), global)
        XCTAssertTrue(s.rec.channels.allSatisfy(\.cancelled))
    }

    func testSwitchToAMacWithoutAStoredPasswordAsksAndNeverSendsAnother() async throws {
        let s = try setup()
        let first = Task { await s.connector.connect(saved: s.a, password: "pwA", remember: false, service: nil,
                                                    context: s.context) }
        try await waitUntil("A handshaking") { s.rec.auths.count == 1 }

        let outcome = await s.connector.switchSession(to: s.b, service: nil, context: s.context)
        XCTAssertEqual(outcome, .needsPassword)
        await first.value
        XCTAssertEqual(s.rec.auths.count, 1, "nothing was sent to B")
        XCTAssertEqual(s.connector.model.state, .idle)
        XCTAssertNil(s.connector.model.lastRequest, "A's credentials are dropped")
        XCTAssertTrue(s.rec.channels.allSatisfy(\.cancelled))
        XCTAssertNil(s.connector.settings.hostID)
    }

    func testSwitchRunsBeforeConnectAfterTheTeardown() async throws {
        let s = try setup()
        try s.passwords.setPassword("pwB", for: s.b.id)
        let first = Task { await s.connector.connect(saved: s.a, password: "pwA", remember: false, service: nil,
                                                    context: s.context) }
        try await waitUntil("A handshaking") { s.rec.auths.count == 1 }
        var sawIdle = false
        let rec = s.rec
        let switching = Task {
            await s.connector.switchSession(to: s.b, service: nil, context: s.context) {
                sawIdle = s.connector.model.state == .idle && s.connector.model.control == nil
                    && rec.channels.allSatisfy(\.cancelled)
            }
        }
        try await waitUntil("B handshaking") { s.rec.auths.count == 2 }
        XCTAssertTrue(sawIdle)
        await s.connector.cancel()
        _ = await switching.value
        await first.value
    }
}

@MainActor
final class HostsSchemaV3MigrationTests: XCTestCase {
    /// A v2 store opens with the v3 schema: hosts and their existing
    /// overrides kept, the new `smoothPlayback` column empty.
    func testV2StoreMigratesToV3() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let id = UUID()
        do {
            let v2 = Schema(versionedSchema: HostsSchemaV2.self)
            let c = try ModelContainer(for: v2, migrationPlan: HostsMigrationPlan.self,
                                       configurations: ModelConfiguration(schema: v2, url: url))
            let old = HostsSchemaV2.SavedHost(id: id, name: "Kept", host: "1.2.3.4", username: "u")
            old.inputMode = "direct"
            old.macModel = "Mac13,1"
            c.mainContext.insert(old)
            try c.mainContext.save()
        }
        let c = try HostStore.makeContainer(url: url)
        let h = try XCTUnwrap(c.mainContext.fetch(FetchDescriptor<SavedHost>()).first)
        XCTAssertEqual(h.id, id)
        XCTAssertEqual(h.macModel, "Mac13,1")
        XCTAssertEqual(h.sessionOverrides, SessionOverrides(touchMode: .direct))
        h.smoothPlayback = true
        try c.mainContext.save()
    }
}
