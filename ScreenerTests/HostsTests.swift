import Network
import SwiftData
import XCTest
@testable import Screener

final class KeychainTests: XCTestCase {
    private var account = ""

    override func setUp() { account = "test-\(UUID().uuidString)" }
    override func tearDown() { try? Keychain.delete(account: account) }

    func testRoundTrip() throws {
        XCTAssertNil(try Keychain.get(account: account))
        try Keychain.set("s3cret pässword", account: account)
        XCTAssertEqual(try Keychain.get(account: account), "s3cret pässword")
        try Keychain.set("changed", account: account)                 // update in place
        XCTAssertEqual(try Keychain.get(account: account), "changed")
        try Keychain.delete(account: account)
        XCTAssertNil(try Keychain.get(account: account))
        XCTAssertNoThrow(try Keychain.delete(account: account))       // deleting nothing is fine
    }

    func testItemAttributes() throws {
        try Keychain.set("pw", account: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.vestal.screener",
                                    kSecAttrAccount as String: account,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attrs = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    /// L6: an item saved by an earlier build ("after first unlock") is
    /// re-saved as "when unlocked, this device only" when it's read.
    func testReadMigratesOlderAccessibility() throws {
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: Keychain.service,
                                  kSecAttrAccount as String: account,
                                  kSecValueData as String: Data("old".utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(Keychain.accessibility(account: account),
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try Keychain.get(account: account), "old")
        XCTAssertEqual(Keychain.accessibility(account: account),
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(try Keychain.get(account: account), "old")
    }

    func testStoreUsesHostID() throws {
        let id = UUID()
        let store = KeychainPasswordStore()
        defer { try? store.deletePassword(for: id) }
        try store.setPassword("pw", for: id)
        XCTAssertEqual(try Keychain.get(account: id.uuidString), "pw")
        XCTAssertEqual(try store.password(for: id), "pw")
    }
}

/// In-memory PasswordStore for the model tests.
final class MemoryPasswordStore: PasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: String] = [:]
    func password(for id: UUID) throws -> String? { lock.withLock { items[id] } }
    func setPassword(_ password: String, for id: UUID) throws { lock.withLock { items[id] = password } }
    func deletePassword(for id: UUID) throws { _ = lock.withLock { items.removeValue(forKey: id) } }
    var count: Int { lock.withLock { items.count } }
}

@MainActor
final class SavedHostTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try HostStore.makeContainer(inMemory: true)
    }

    private func fetchAll() throws -> [SavedHost] { try context.fetch(FetchDescriptor<SavedHost>()) }

    func testCRUD() throws {
        let h = SavedHost(name: "Studio", host: "192.168.1.20", username: "alex")
        context.insert(h)
        try context.save()
        XCTAssertEqual(try fetchAll().map(\.name), ["Studio"])
        XCTAssertEqual(h.port, 5900)
        XCTAssertNil(h.displayMode)            // Task 23 fields exist, unset
        XCTAssertNil(h.pinnedKeySHA256)

        h.name = "Studio Mac"
        h.port = 5901
        try context.save()
        let again = try XCTUnwrap(try fetchAll().first)
        XCTAssertEqual(again.name, "Studio Mac")
        XCTAssertEqual(again.displayAddress, "192.168.1.20:5901")

        let passwords = MemoryPasswordStore()
        try passwords.setPassword("pw", for: h.id)
        try HostStore.delete(h, in: context, passwords: passwords)
        XCTAssertTrue(try fetchAll().isEmpty)
        XCTAssertNil(try passwords.password(for: h.id))
    }

    func testDeleteRemovesKeychainItem() throws {
        let h = SavedHost(name: "Mini", host: "mini.local", username: "u")
        context.insert(h)
        try context.save()
        let store = KeychainPasswordStore()
        try store.setPassword("pw", for: h.id)
        XCTAssertEqual(try Keychain.get(account: h.id.uuidString), "pw")
        try HostStore.delete(h, in: context, passwords: store)
        XCTAssertNil(try Keychain.get(account: h.id.uuidString))
        XCTAssertTrue(try fetchAll().isEmpty)
    }

    func testDuplicateCopiesPassword() throws {
        let passwords = MemoryPasswordStore()
        let h = SavedHost(name: "Mini", host: "mini.local", port: 5901, username: "u", bonjourName: "Mini")
        context.insert(h)
        try passwords.setPassword("pw", for: h.id)
        let copy = try HostStore.duplicate(h, in: context, passwords: passwords)
        XCTAssertNotEqual(copy.id, h.id)
        XCTAssertEqual(copy.name, "Mini copy")
        XCTAssertEqual(copy.port, 5901)
        XCTAssertEqual(try passwords.password(for: copy.id), "pw")
        XCTAssertEqual(try fetchAll().count, 2)
    }

    func testRecentsOrderingAndSearch() {
        let now = Date()
        let old = SavedHost(name: "Old", host: "a", username: "u", lastConnected: now - 3600)
        let recent = SavedHost(name: "Recent", host: "b", username: "u", lastConnected: now)
        let never2 = SavedHost(name: "Zed", host: "c", username: "u", sortOrder: 2)
        let never1 = SavedHost(name: "Alpha", host: "d.local", username: "u", sortOrder: 1)
        let ordered = HostStore.ordered([never2, old, never1, recent])
        XCTAssertEqual(ordered.map(\.name), ["Recent", "Old", "Alpha", "Zed"])
        XCTAssertEqual(HostStore.filter(ordered, query: "d.LOCAL").map(\.name), ["Alpha"])
        XCTAssertEqual(HostStore.filter(ordered, query: " ").count, 4)
    }

    func testPersistentStoreOpensWithMigrationPlan() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema(versionedSchema: HostsSchemaV3.self)
        do {
            let c = try ModelContainer(for: schema, migrationPlan: HostsMigrationPlan.self,
                                       configurations: ModelConfiguration(schema: schema, url: url))
            c.mainContext.insert(SavedHost(name: "Kept", host: "1.2.3.4", username: "u"))
            try c.mainContext.save()
        }
        let reopened = try ModelContainer(for: schema, migrationPlan: HostsMigrationPlan.self,
                                          configurations: ModelConfiguration(schema: schema, url: url))
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<SavedHost>()).map(\.name), ["Kept"])
    }
}

@MainActor
final class HostEditorModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let passwords = MemoryPasswordStore()

    override func setUp() async throws {
        container = try HostStore.makeContainer(inMemory: true)
    }

    func testNewHostSavesAndStoresPasswordOnlyInStore() throws {
        let e = HostEditorModel()
        XCTAssertTrue(e.saveToHosts)             // default on
        XCTAssertFalse(e.canConnect)
        e.host = " studio.local "
        e.username = "alex"
        e.password = "pw"
        XCTAssertTrue(e.canConnect)
        let saved = try XCTUnwrap(try e.save(context: context, passwords: passwords))
        XCTAssertEqual(saved.name, "studio.local")     // no name → the address
        XCTAssertEqual(saved.host, "studio.local")
        XCTAssertEqual(try passwords.password(for: saved.id), "pw")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavedHost>()).count, 1)
    }

    func testSaveToHostsOffSavesNothing() throws {
        let e = HostEditorModel()
        e.host = "1.2.3.4"; e.username = "u"; e.password = "pw"
        e.saveToHosts = false
        XCTAssertNil(try e.save(context: context, passwords: passwords))
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavedHost>()).count, 0)
        XCTAssertEqual(passwords.count, 0)
    }

    func testInvalidPortCannotSave() {
        let e = HostEditorModel()
        e.host = "h"; e.username = "u"
        e.port = "70000"
        XCTAssertFalse(e.canSave)
        e.port = "0"
        XCTAssertFalse(e.canSave)
        e.port = "5901"
        XCTAssertTrue(e.canSave)
    }

    func testEditPrefillsAndUpdates() throws {
        let h = SavedHost(name: "Studio", host: "10.0.0.2", port: 5901, username: "alex", bonjourName: "Studio")
        context.insert(h)
        try passwords.setPassword("old", for: h.id)
        let e = HostEditorModel(editing: h, passwords: passwords)
        XCTAssertTrue(e.isEditing)
        XCTAssertEqual([e.name, e.host, e.port, e.username, e.password], ["Studio", "10.0.0.2", "5901", "alex", "old"])

        e.name = "Studio Mac"
        e.password = "new"
        try e.save(existing: h, context: context, passwords: passwords)
        XCTAssertEqual(h.name, "Studio Mac")
        XCTAssertEqual(h.bonjourName, "Studio")       // address unchanged → Bonjour tie kept
        XCTAssertEqual(try passwords.password(for: h.id), "new")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavedHost>()).count, 1)

        let e2 = HostEditorModel(editing: h, passwords: passwords)
        e2.host = "studio.example.com"
        e2.password = ""                              // cleared → forget the stored password
        try e2.save(existing: h, context: context, passwords: passwords)
        XCTAssertNil(h.bonjourName)
        XCTAssertNil(try passwords.password(for: h.id))
    }

    func testPersistPasswordFalseSavesHostButNotAnUnverifiedPassword() throws {
        // The "+" flow: Connect saves the host only after it succeeds, and a
        // failed attempt (persistPassword: false) must leave no password in
        // the store — a mistyped password is never persisted (password save fix).
        let e = HostEditorModel()
        e.host = "1.2.3.4"; e.username = "u"; e.password = "mistyped"
        let saved = try XCTUnwrap(try e.save(context: context, passwords: passwords, persistPassword: false))
        XCTAssertNil(try passwords.password(for: saved.id))
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavedHost>()).count, 1)   // the host itself still exists
    }

    func testEditKeepsOldPasswordUntilAVerifiedConnect() throws {
        let h = SavedHost(name: "Studio", host: "10.0.0.2", username: "alex")
        context.insert(h)
        try passwords.setPassword("old", for: h.id)
        let e = HostEditorModel(editing: h, passwords: passwords)
        XCTAssertFalse(e.passwordChanged)
        e.password = "mistyped"
        XCTAssertTrue(e.passwordChanged)

        // A failed connect (persistPassword: false) keeps the old password,
        // but still saves other field edits made alongside it.
        e.name = "Studio Mac"
        try e.save(existing: h, context: context, passwords: passwords, persistPassword: false)
        XCTAssertEqual(try passwords.password(for: h.id), "old")
        XCTAssertEqual(h.name, "Studio Mac")

        // A verified connect (persistPassword: true) commits the new one.
        try e.save(existing: h, context: context, passwords: passwords, persistPassword: true)
        XCTAssertEqual(try passwords.password(for: h.id), "mistyped")
    }

    func testDiscoveredHostSavesBonjourName() throws {
        let d = DiscoveredHost(name: "Alex’s MacBook Pro",
                               endpoint: .service(name: "Alex’s MacBook Pro", type: "_rfb._tcp", domain: "local.", interface: nil))
        let e = HostEditorModel(discovered: d)
        XCTAssertEqual(e.name, "Alex’s MacBook Pro")
        XCTAssertTrue(e.canSave)                       // resolves at connect time
        e.host = "192.168.1.7"                         // filled in by the resolve
        e.username = "alex"
        let saved = try XCTUnwrap(try e.save(context: context, passwords: passwords))
        XCTAssertEqual(saved.bonjourName, "Alex’s MacBook Pro")
        XCTAssertEqual(saved.host, "192.168.1.7")
        XCTAssertEqual(passwords.count, 0)             // no password typed → none stored
    }

    func testMarkConnectedUpdatesHostAndRemembersPassword() throws {
        let h = SavedHost(name: "Studio", host: "10.0.0.2", username: "", bonjourName: "Studio")
        context.insert(h)
        let connector = HostConnector(model: SessionCoordinator(), passwords: passwords)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = Data(repeating: 0xAB, count: 32)
        h.pinnedKeySHA256 = key
        connector.markConnected(h, resolvedAddress: "10.0.0.9", username: "alex", rememberPassword: "pw",
                                context: context, now: now, presentedKey: key)
        XCTAssertEqual(h.lastConnected, now)
        XCTAssertEqual(h.host, "10.0.0.9")            // pinned key matched → follow the new address
        XCTAssertEqual(h.username, "alex")
        XCTAssertEqual(try passwords.password(for: h.id), "pw")

        let h2 = SavedHost(name: "Other", host: "x", username: "u")
        context.insert(h2)
        connector.markConnected(h2, resolvedAddress: nil, rememberPassword: nil, context: context, now: now)
        XCTAssertEqual(h2.host, "x")
        XCTAssertNil(try passwords.password(for: h2.id))
    }

    /// H1: the first successful sign-in pins the key (TOFU) but does not
    /// move the saved address; only a matching pin lets a Bonjour lookup
    /// update it.
    func testMarkConnectedPinsOnFirstUseAndKeepsAddressWithoutMatchedPin() throws {
        let h = SavedHost(name: "Studio", host: "10.0.0.2", username: "u", bonjourName: "Studio")
        context.insert(h)
        let connector = HostConnector(model: SessionCoordinator(), passwords: passwords)
        let key = Data(repeating: 0x11, count: 32)
        connector.markConnected(h, resolvedAddress: "10.0.0.66", rememberPassword: nil, context: context,
                                presentedKey: key)
        XCTAssertEqual(h.pinnedKeySHA256, key)
        XCTAssertEqual(h.host, "10.0.0.2")

        // Pinned, but a different key presented (cannot normally happen: auth
        // refuses first) → neither the pin nor the address changes.
        connector.markConnected(h, resolvedAddress: "10.0.0.77", rememberPassword: nil, context: context,
                                presentedKey: Data(repeating: 0x22, count: 32))
        XCTAssertEqual(h.pinnedKeySHA256, key)
        XCTAssertEqual(h.host, "10.0.0.2")

        // A saved host with no address yet takes the resolved one.
        let empty = SavedHost(name: "New", host: "", username: "u", bonjourName: "New")
        context.insert(empty)
        connector.markConnected(empty, resolvedAddress: "10.0.0.5", rememberPassword: nil, context: context,
                                presentedKey: key)
        XCTAssertEqual(empty.host, "10.0.0.5")
    }

    /// H1: "Trust New Key" (the only way a pin changes) re-pins to the presented key.
    func testTrustNewKeyRepins() throws {
        let h = SavedHost(name: "Studio", host: "10.0.0.2", username: "u")
        h.pinnedKeySHA256 = Data(repeating: 1, count: 32)
        context.insert(h)
        let connector = HostConnector(model: SessionCoordinator(), passwords: passwords)
        let new = Data(repeating: 2, count: 32)
        connector.trustNewKey(new, for: h, context: context)
        XCTAssertEqual(h.pinnedKeySHA256, new)
        XCTAssertEqual(HostConnector.authPolicy(for: h).pinnedKeySHA256, new)
    }

    func testAuthPolicyFromSavedHostAndLegacyToggle() throws {
        let h = SavedHost(name: "Studio", host: "10.0.0.2", username: "u")
        context.insert(h)
        XCTAssertEqual(HostConnector.authPolicy(for: h), AuthPolicy())   // ad-hoc-equivalent: no pin, no legacy
        let e = HostEditorModel(editing: h, passwords: passwords)
        XCTAssertFalse(e.allowLegacyAuth)
        e.allowLegacyAuth = true
        try e.save(existing: h, context: context, passwords: passwords)
        h.pinnedKeySHA256 = Data([1, 2, 3])
        XCTAssertEqual(HostConnector.authPolicy(for: h), AuthPolicy(pinnedKeySHA256: Data([1, 2, 3]), allowLegacy: true))
    }
}

@MainActor
final class HostMatcherTests: XCTestCase {
    private func service(_ name: String) -> DiscoveredHost {
        DiscoveredHost(name: name, endpoint: .service(name: name, type: "_rfb._tcp", domain: "local.", interface: nil))
    }

    /// H1(d): only the exact (case-sensitive) Bonjour service name the host
    /// was saved from matches — no case folding, punctuation stripping,
    /// ".local" names or resolved-IP matches.
    func testMatchingIsExactBonjourNameOnly() {
        let byBonjour = SavedHost(name: "Mine", host: "10.0.0.5", username: "u", bonjourName: "Studio")
        let byLocalName = SavedHost(name: "Laptop", host: "Alexs-MacBook-Pro.local", username: "u")
        let byIP = SavedHost(name: "Mini", host: "10.0.0.8", username: "u")
        XCTAssertTrue(HostMatcher.matches(byBonjour, discoveredName: "Studio"))
        XCTAssertFalse(HostMatcher.matches(byBonjour, discoveredName: "studio"))
        XCTAssertFalse(HostMatcher.matches(byBonjour, discoveredName: "Stu dio"))
        XCTAssertFalse(HostMatcher.matches(byBonjour, discoveredName: "Studio "))
        XCTAssertFalse(HostMatcher.matches(byLocalName, discoveredName: "Alex’s MacBook Pro"))
        XCTAssertFalse(HostMatcher.matches(byIP, discoveredName: "Mac mini"))
        let studioLocal = SavedHost(name: "Studio", host: "studio.local", username: "u")
        XCTAssertFalse(HostMatcher.matches(studioLocal, discoveredName: "Stu dio"))
        XCTAssertFalse(HostMatcher.matches(SavedHost(name: "x", host: "h", username: "u", bonjourName: ""),
                                           discoveredName: ""))

        let found = [service("Studio"), service("Alex’s MacBook Pro"), service("Mac mini"), service("studio")]
        let saved = [byBonjour, byLocalName, byIP]
        XCTAssertEqual(HostMatcher.unmatched(found, saved: saved).map(\.name),
                       ["Alex’s MacBook Pro", "Mac mini", "studio"])
        XCTAssertEqual(HostMatcher.discovered(for: byBonjour, in: found)?.name, "Studio")
        XCTAssertNil(HostMatcher.discovered(for: byLocalName, in: found))
        XCTAssertNil(HostMatcher.discovered(for: byIP, in: found))
        XCTAssertNil(HostMatcher.savedHost(for: service("STUDIO"), in: saved))
    }

    func testIPv4FromResolvedEndpoint() {
        let ep = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.7%en0")!), port: 5900)
        XCTAssertEqual(BonjourResolver.ipv4HostPort(ep)?.0, "192.168.1.7")
        XCTAssertEqual(BonjourResolver.ipv4HostPort(ep)?.1, 5900)
        XCTAssertNil(BonjourResolver.ipv4HostPort(.hostPort(host: .ipv6(.loopback), port: 5900)))
        XCTAssertNil(BonjourResolver.ipv4HostPort(.hostPort(host: .name("mac.local", nil), port: 5900)))
    }
}
