// Saved hosts (Task 18). Passwords are NEVER stored here: they live only in
// the Keychain (Keychain.swift), keyed by `SavedHost.id`.
//
// The schema is versioned from day one so later changes (Task 23 and beyond)
// can migrate with a `SchemaMigrationPlan` stage instead of a wipe. Task 23's
// per-host fields (display / input mode, audio, clipboard, MAC address,
// pinned key) are already part of v1, all optional, so that task needs no
// migration. Add a field → add `HostsSchemaV2` + a lightweight stage.
import Foundation
import SwiftData

enum HostsSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [SavedHost.self] }

    @Model
    final class SavedHost {
        @Attribute(.unique) var id: UUID
        var name: String
        /// Host name or IPv4 literal (for a Bonjour host: the last resolved IPv4).
        var host: String
        var port: Int
        var username: String
        var lastConnected: Date?
        /// Manual order among hosts never connected to (lower first).
        var sortOrder: Int
        var createdAt: Date
        /// The Bonjour (_rfb._tcp) service name this host was saved from. While
        /// that service is on the network, connecting re-resolves it, so a
        /// changed DHCP address is followed.
        var bonjourName: String?

        // Task 23 (unused until then).
        var displayMode: String?
        var inputMode: String?
        var audioEnabled: Bool?
        var clipboardEnabled: Bool?
        var macAddress: String?
        var pinnedKeySHA256: Data?
        var allowLegacyAuth: Bool?

        init(id: UUID = UUID(), name: String, host: String, port: Int = 5900, username: String,
             lastConnected: Date? = nil, sortOrder: Int = 0, createdAt: Date = .now, bonjourName: String? = nil) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.lastConnected = lastConnected
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.bonjourName = bonjourName
        }
    }
}

typealias SavedHost = HostsSchemaV1.SavedHost

enum HostsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HostsSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

extension SavedHost {
    /// "host" or "host:port" when the port isn't the default.
    var displayAddress: String {
        let h = host.isEmpty ? (bonjourName ?? "") : host
        return port == 5900 ? h : "\(h):\(port)"
    }

    var portValue: UInt16? { UInt16(exactly: port) }
}

enum HostStore {
    /// The app's persistent container (Application Support/default.store).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HostsSchemaV1.self)
        if !inMemory {
            // The default store lives in Application Support, which doesn't
            // exist on a fresh install (CoreData logs a wall of stat errors).
            let dir = URL.applicationSupportDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, migrationPlan: HostsMigrationPlan.self, configurations: config)
    }

    /// Recents first (lastConnected, newest first), then never-connected
    /// hosts by `sortOrder`, then name.
    static func ordered(_ hosts: [SavedHost]) -> [SavedHost] {
        hosts.sorted { a, b in
            switch (a.lastConnected, b.lastConnected) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Case-insensitive match on name, address, username or Bonjour name.
    static func filter(_ hosts: [SavedHost], query: String) -> [SavedHost] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return hosts }
        return hosts.filter { h in
            [h.name, h.host, h.username, h.bonjourName ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    static func nextSortOrder(_ context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<SavedHost>())) ?? []
        return (all.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Deletes the host and its Keychain password.
    static func delete(_ host: SavedHost, in context: ModelContext, passwords: any PasswordStore) throws {
        let id = host.id
        try passwords.deletePassword(for: id)
        context.delete(host)
        try context.save()
        Log.hosts.info("deleted host \(id.uuidString)")
    }

    /// A copy of `host` ("<name> copy"), with its own copy of the password.
    @discardableResult
    static func duplicate(_ host: SavedHost, in context: ModelContext, passwords: any PasswordStore) throws -> SavedHost {
        let copy = SavedHost(name: "\(host.name) copy", host: host.host, port: host.port, username: host.username,
                             sortOrder: nextSortOrder(context), bonjourName: host.bonjourName)
        copy.displayMode = host.displayMode
        copy.inputMode = host.inputMode
        copy.audioEnabled = host.audioEnabled
        copy.clipboardEnabled = host.clipboardEnabled
        copy.macAddress = host.macAddress
        copy.pinnedKeySHA256 = host.pinnedKeySHA256
        copy.allowLegacyAuth = host.allowLegacyAuth
        context.insert(copy)
        if let pw = try passwords.password(for: host.id) {
            try passwords.setPassword(pw, for: copy.id)
        }
        try context.save()
        return copy
    }
}
