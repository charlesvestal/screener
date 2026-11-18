// Saved-host passwords, in the Keychain only (generic password; service =
// the bundle id, account = SavedHost.id.uuidString). Accessible only while
// the iPad is unlocked, on this device only (never in backups / iCloud
// Keychain) — L6. Items saved by earlier builds with "after first unlock"
// are migrated the next time they're read. Never logged, never written
// anywhere else.
import Foundation
import Security

/// Where saved-host passwords live (the Keychain in the app; in memory in tests).
protocol PasswordStore: Sendable {
    func password(for id: UUID) throws -> String?
    func setPassword(_ password: String, for id: UUID) throws
    func deletePassword(for id: UUID) throws
}

enum Keychain {
    static let service = "com.vestal.screener"

    struct Failure: Error, Equatable, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    /// Adds or replaces the password for `account`.
    static func set(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: accessibility]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add.merge(update) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// The password for `account`, or nil if there is none.
    static func get(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attrs = item as? [String: Any],
              let data = attrs[kSecValueData as String] as? Data else { throw Failure(status: status) }
        if (attrs[kSecAttrAccessible as String] as? String) != (accessibility as String) {
            migrateAccessibility(account: account)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Re-saves an item stored with an older (weaker) accessibility class.
    static func migrateAccessibility(account: String) {
        let update = [kSecAttrAccessible as String: accessibility] as [String: Any]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status != errSecSuccess {
            Log.hosts.error("keychain: couldn't update the accessibility of a saved password (\(status))")
        }
    }

    /// The stored accessibility class of `account`'s item (tests).
    static func accessibility(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }

    /// Removes the password for `account` (no error if there is none).
    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

struct KeychainPasswordStore: PasswordStore {
    func password(for id: UUID) throws -> String? { try Keychain.get(account: id.uuidString) }
    func setPassword(_ password: String, for id: UUID) throws { try Keychain.set(password, account: id.uuidString) }
    func deletePassword(for id: UUID) throws { try Keychain.delete(account: id.uuidString) }
}
