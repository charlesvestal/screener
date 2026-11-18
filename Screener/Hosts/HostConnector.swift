// Connects to a saved or discovered Mac through SessionCoordinator.
//
// A Bonjour service is resolved to an IPv4 literal here (BonjourResolver)
// and that literal is what SessionCoordinator.connect gets, so TCP and UDP
// use the same IPv4. A typed host name goes to the coordinator unchanged
// (it resolves it once, IPv4Resolver). On success the saved host's
// `lastConnected` (and, for Bonjour, its last address) is updated, and a
// password the user chose to remember is stored in the Keychain only then.
import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class HostConnector {
    let model: SessionCoordinator
    let passwords: any PasswordStore
    /// Bonjour name → last resolved IPv4 (for matching discovered ↔ saved).
    private(set) var resolvedIPv4: [String: String] = [:]
    /// A Bonjour lookup is in progress (before the coordinator's own `.connecting`).
    private(set) var isResolving = false
    /// An error from before the coordinator was involved (Bonjour lookup, saving).
    var error: String?
    /// Bumped by `cancel()`: a connect whose Bonjour lookup outlives a cancel stops there.
    private var generation = 0

    init(model: SessionCoordinator, passwords: any PasswordStore = KeychainPasswordStore()) {
        self.model = model
        self.passwords = passwords
    }

    var isBusy: Bool { isResolving || model.isBusy }

    func resolve(_ service: DiscoveredHost) async throws -> (address: String, port: UInt16) {
        isResolving = true
        defer { isResolving = false }
        let r = try await BonjourResolver.resolve(service)
        resolvedIPv4[service.name] = r.address
        return r
    }

    /// Connects to `host:port`, first re-resolving `service` when given (a
    /// lookup failure falls back to `host` if there is one). Returns the IPv4
    /// literal used for a Bonjour host, and whether the session connected.
    @discardableResult
    func connect(host: String, port: UInt16, username: String, password: String,
                 service: DiscoveredHost? = nil) async -> (connected: Bool, resolvedAddress: String?) {
        guard !isBusy else { return (false, nil) }
        error = nil
        generation += 1
        let gen = generation
        var target = host, targetPort = port, resolved: String?
        if let service {
            do {
                (target, targetPort) = try await resolve(service)
                resolved = target
            } catch {
                Log.hosts.error("bonjour resolve \(service.name) failed: \(error)")
                if host.isEmpty {
                    self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't find \(service.name)."
                    return (false, nil)
                }
            }
        }
        guard gen == generation else { return (false, nil) }   // cancelled during the lookup
        guard !target.isEmpty else {
            error = "This Mac has no address."
            return (false, nil)
        }
        await model.connect(host: target, port: targetPort, username: username, password: password)
        if case .connected = model.state { return (true, resolved) }
        return (false, resolved)
    }

    /// Stops a connect in progress (the Bonjour lookup or the session's connect).
    func cancel() async {
        generation += 1
        error = nil
        await model.disconnect()
    }

    /// Connects to a saved host with `password`. `remember`: store the
    /// password in the Keychain once the connect succeeds.
    func connect(saved: SavedHost, username: String? = nil, password: String, remember: Bool,
                 service: DiscoveredHost?, context: ModelContext) async {
        guard let port = saved.portValue else { error = "Invalid port \(saved.port)."; return }
        let user = username ?? saved.username
        let result = await connect(host: saved.host, port: port, username: user, password: password, service: service)
        guard result.connected else { return }
        markConnected(saved, resolvedAddress: result.resolvedAddress, username: user,
                      rememberPassword: remember ? password : nil, context: context)
    }

    /// Records a successful connect on `saved`.
    func markConnected(_ saved: SavedHost, resolvedAddress: String?, username: String? = nil,
                       rememberPassword: String?, context: ModelContext, now: Date = .now) {
        saved.lastConnected = now
        if let resolvedAddress { saved.host = resolvedAddress }
        if let username, !username.isEmpty { saved.username = username }
        if let pw = rememberPassword, !pw.isEmpty {
            do { try passwords.setPassword(pw, for: saved.id) } catch {
                Log.hosts.error("couldn't store the password for \(saved.id.uuidString): \(error)")
            }
        }
        do { try context.save() } catch { Log.hosts.error("couldn't save host: \(error)") }
    }
}
