// ConnectSheet's form state and its save logic (kept out of the view so it
// can be unit-tested against an in-memory ModelContainer and PasswordStore).
import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class HostEditorModel {
    enum Mode: Equatable {
        /// "+": a new Mac typed in by hand.
        case new
        /// Editing the saved host with this id.
        case edit(UUID)
        /// A Mac found with Bonjour (not saved yet).
        case discovered(DiscoveredHost)
    }

    let mode: Mode
    var name = ""
    var host = ""
    var port = "5900"
    var username = ""
    var password = ""
    /// New / discovered hosts only: keep this Mac (and its password) in Hosts.
    var saveToHosts = true
    /// The Bonjour service this host is tied to (see SavedHost.bonjourName).
    private(set) var bonjourName: String?
    private var originalHost = ""

    init() { mode = .new }

    init(discovered: DiscoveredHost) {
        mode = .discovered(discovered)
        name = discovered.name
        bonjourName = discovered.name
    }

    /// Prefills every field from `saved`, the password from `passwords`.
    init(editing saved: SavedHost, passwords: any PasswordStore) {
        mode = .edit(saved.id)
        name = saved.name
        host = saved.host
        originalHost = saved.host
        port = String(saved.port)
        username = saved.username
        bonjourName = saved.bonjourName
        password = (try? passwords.password(for: saved.id)) ?? ""
    }

    var isEditing: Bool { if case .edit = mode { true } else { false } }
    var discoveredService: DiscoveredHost? { if case .discovered(let d) = mode { d } else { nil } }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var portValue: UInt16? {
        guard let p = UInt16(port.trimmingCharacters(in: .whitespaces)), p > 0 else { return nil }
        return p
    }
    /// The name a saved host gets: the typed name, else the address.
    var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        return trimmedHost.isEmpty ? (bonjourName ?? "Mac") : trimmedHost
    }

    /// Enough to store: an address (or a Bonjour service that resolves to one) and a port.
    var canSave: Bool { (!trimmedHost.isEmpty || discoveredService != nil) && portValue != nil }
    var canConnect: Bool { canSave && !username.isEmpty }

    /// Writes the form. Edit mode updates `existing`; new / discovered mode
    /// inserts a host when `saveToHosts` is on (else returns nil). The
    /// password goes only to `passwords`; an empty password field removes
    /// a stored one in edit mode.
    @discardableResult
    func save(existing: SavedHost? = nil, context: ModelContext, passwords: any PasswordStore) throws -> SavedHost? {
        guard let portValue, canSave else { return nil }
        let saved: SavedHost
        if isEditing {
            guard let existing else { return nil }
            saved = existing
            saved.name = effectiveName
            if trimmedHost != originalHost {
                // A hand-typed address replaces the Bonjour tie.
                saved.bonjourName = nil
            }
            saved.host = trimmedHost
            saved.port = Int(portValue)
            saved.username = username
            if password.isEmpty {
                try passwords.deletePassword(for: saved.id)
            } else {
                try passwords.setPassword(password, for: saved.id)
            }
        } else {
            guard saveToHosts else { return nil }
            saved = SavedHost(name: effectiveName, host: trimmedHost, port: Int(portValue), username: username,
                              sortOrder: HostStore.nextSortOrder(context), bonjourName: bonjourName)
            context.insert(saved)
            if !password.isEmpty { try passwords.setPassword(password, for: saved.id) }
        }
        try context.save()
        Log.hosts.info("\(isEditing ? "updated" : "saved") host \(saved.id.uuidString)")
        return saved
    }
}
