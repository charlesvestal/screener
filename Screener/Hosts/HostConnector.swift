// Connects to a saved or discovered Mac through SessionCoordinator.
//
// A Bonjour service is resolved to an IPv4 literal here (BonjourResolver)
// and that literal is what SessionCoordinator.connect gets, so TCP and UDP
// use the same IPv4. A typed host name goes to the coordinator unchanged
// (it resolves it once, IPv4Resolver). On success the saved host's
// `lastConnected` is updated, and a password the user chose to remember is
// stored in the Keychain only then.
//
// Mac identity (security review H1): the first successful sign-in pins the
// SHA-256 of the Mac's RSA1 key on the saved host (`pinnedKeySHA256`); every
// later connect passes that pin down (AuthPolicy), and a different key fails
// before any credential is sent (SessionCoordinator.identityChange → the
// "This Mac's identity changed" sheet; only "Trust New Key" re-pins). A
// saved host's address is updated from a Bonjour lookup only when its pinned
// key matched, so a spoofed service can't redirect the saved host.
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
    /// The saved host of the current (or last) session: its card gets the
    /// session's last picture as a thumbnail and its model identifier.
    private(set) var activeHostID: UUID?

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
                 service: DiscoveredHost? = nil, authPolicy: AuthPolicy = AuthPolicy(),
                 savedHostID: UUID? = nil) async -> (connected: Bool, resolvedAddress: String?) {
        guard !isBusy else { return (false, nil) }
        error = nil
        pendingIdentityHostID = savedHostID
        activeHostID = nil   // set again by markConnected for a saved host
        generation += 1
        let gen = generation
        var target = host, targetPort = port, resolved: String?
        if let service {
            do {
                (target, targetPort) = try await resolve(service)
                resolved = target
            } catch {
                Log.hosts.error("bonjour resolve \(private: service.name) failed: \(error)")
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
        await model.connect(host: target, port: targetPort, username: username, password: password,
                            authPolicy: authPolicy)
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
        let result = await connect(host: saved.host, port: port, username: user, password: password, service: service,
                                   authPolicy: Self.authPolicy(for: saved), savedHostID: saved.id)
        guard result.connected else { return }
        markConnected(saved, resolvedAddress: result.resolvedAddress, username: user,
                      rememberPassword: remember ? password : nil, context: context)
    }

    /// The trust decisions stored on `saved` for its next connect.
    static func authPolicy(for saved: SavedHost) -> AuthPolicy {
        AuthPolicy(pinnedKeySHA256: saved.pinnedKeySHA256, allowLegacy: saved.allowLegacyAuth ?? false)
    }

    /// The saved host the last connect-from-a-card was for: the subject of
    /// an identity-changed prompt (`model.identityChange`).
    private(set) var pendingIdentityHostID: UUID?

    /// "Trust New Key": pins the key the Mac just presented
    /// (`model.identityChange`) on `saved` — only on this explicit user
    /// choice. The caller then reconnects.
    func trustNewKey(_ presentedSHA256: Data, for saved: SavedHost, context: ModelContext) {
        saved.pinnedKeySHA256 = presentedSHA256
        model.clearIdentityChange()
        do { try context.save() } catch { Log.hosts.error("couldn't save the new key: \(error)") }
        Log.hosts.info("host \(saved.id.uuidString): user trusted a new Mac identity key")
    }

    /// Records a successful connect on `saved`: TOFU-pins the Mac's key if
    /// none is pinned, and follows a new (Bonjour) address only when the
    /// pinned key matched.
    /// `presentedKey`: the session's key fingerprint (default: the coordinator's).
    func markConnected(_ saved: SavedHost, resolvedAddress: String?, username: String? = nil,
                       rememberPassword: String?, context: ModelContext, now: Date = .now,
                       presentedKey: Data? = nil) {
        activeHostID = saved.id
        saved.lastConnected = now
        if let m = model.deviceModel, !m.isEmpty { saved.macModel = m }
        let presented = presentedKey ?? model.serverKeySHA256
        let pinMatched = presented != nil && saved.pinnedKeySHA256 == presented
        if saved.pinnedKeySHA256 == nil, let presented {
            saved.pinnedKeySHA256 = presented
            Log.hosts.info("host \(saved.id.uuidString): pinned the Mac's identity key (first sign-in)")
        }
        if let resolvedAddress, resolvedAddress != saved.host {
            if pinMatched || saved.host.isEmpty {
                saved.host = resolvedAddress
            } else {
                Log.hosts.info("host \(saved.id.uuidString): not updating its address (no pinned key matched)")
            }
        }
        if let username, !username.isEmpty { saved.username = username }
        if let pw = rememberPassword, !pw.isEmpty {
            do { try passwords.setPassword(pw, for: saved.id) } catch {
                Log.hosts.error("couldn't store the password for \(saved.id.uuidString): \(error)")
            }
        }
        do { try context.save() } catch { Log.hosts.error("couldn't save host: \(error)") }
    }

    /// The session reported the Mac's model (DeviceInfo 0x456): remember it
    /// on the active saved host (its card icon).
    func recordDeviceModel(_ model: String?, in context: ModelContext) {
        guard let model, !model.isEmpty, let id = activeHostID else { return }
        let all = (try? context.fetch(FetchDescriptor<SavedHost>(predicate: #Predicate { $0.id == id }))) ?? []
        guard let host = all.first, host.macModel != model else { return }
        host.macModel = model
        do { try context.save() } catch { Log.hosts.error("couldn't save the Mac model: \(error)") }
        Log.hosts.info("host \(id.uuidString) is a \(model)")
    }
}
