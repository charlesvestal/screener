// "Reconnect to Last Mac on Launch" (Settings, default off).
//
// Cold launch only: the first time the host list appears in this process.
// Returning from the background is the lifecycle's job (SessionCoordinator
// reconnects a suspended session), never this. The candidate is the most
// recently connected saved Mac, and only if its password is stored — a
// launch never opens a password prompt by itself. The host list shows
// "Connecting to <name>…" with Cancel for `delay` first; any other action
// in the meantime (a card tap, a sheet) cancels it too.
import Foundation
import Observation

enum ResumeOnLaunch {
    static let enabledKey = "launch.reconnectLast"
    static let enabledDefault = false
    static let delay: Duration = .seconds(2)

    static func isEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: enabledKey) == nil ? enabledDefault : d.bool(forKey: enabledKey)
    }

    /// The saved Mac to reconnect to, if any: the last connected one, with a
    /// username and a stored password.
    static func candidate(enabled: Bool, coldLaunch: Bool, hosts: [SavedHost],
                          hasStoredPassword: (SavedHost) -> Bool) -> SavedHost? {
        guard enabled, coldLaunch else { return nil }
        let last = hosts.filter { $0.lastConnected != nil }.max { $0.lastConnected! < $1.lastConnected! }
        guard let last, !last.username.isEmpty, hasStoredPassword(last) else { return nil }
        return last
    }
}

/// True exactly once per process (the "cold launch" signal).
@MainActor
final class LaunchGate {
    static let shared = LaunchGate()
    private var claimed = false

    /// The first call returns true; every later one false.
    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

/// The cancellable countdown before a launch reconnect.
@MainActor @Observable
final class LaunchResumer {
    struct Pending: Equatable {
        let hostID: UUID
        let name: String
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Shown as "Connecting to <name>…" until it fires or is cancelled.
    private(set) var pending: Pending?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let sleep: Sleep

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// After `delay`, unless cancelled: `fire(hostID)`.
    func start(_ host: SavedHost, delay: Duration = ResumeOnLaunch.delay, fire: @escaping @MainActor (UUID) -> Void) {
        cancel()
        let p = Pending(hostID: host.id, name: host.name)
        pending = p
        let sleep = sleep
        task = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.pending == p else { return }
            self.pending = nil
            self.task = nil
            Log.hosts.info("reconnecting to the last Mac on launch")
            fire(p.hostID)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    /// Test seam: the countdown's task.
    var pendingTask: Task<Void, Never>? { task }
}
