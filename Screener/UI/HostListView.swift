import SwiftData
import SwiftUI
import UIKit

/// The host list (Task 18): saved Macs (recents first) and Macs found with
/// Bonjour, as a grid of cards. Tap → connect (asking for the password when
/// none is stored); "+" → ConnectSheet.
struct HostListView: View {
    @State private var model: SessionCoordinator
    @State private var connector: HostConnector
    @State private var browser = BonjourBrowser()
    @State private var sheet: HostSheet?
    @State private var pendingDelete: SavedHost?
    @State private var search = ""
    @Query private var savedHosts: [SavedHost]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = SessionCoordinator()
        _model = State(initialValue: model)
        _connector = State(initialValue: HostConnector(model: model))
    }

    private var saved: [SavedHost] { HostStore.filter(HostStore.ordered(savedHosts), query: search) }
    private var discovered: [DiscoveredHost] {
        let unmatched = HostMatcher.unmatched(browser.hosts, saved: savedHosts, resolved: connector.resolvedIPv4)
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? unmatched : unmatched.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Hosts")
                .searchable(text: $search, prompt: "Search Macs")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { sheet = .new } label: { Label("Add Mac", systemImage: "plus") }
                    }
                    ToolbarItem(placement: .secondaryAction) { ShareLogButton() }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .about } label: { Label("About", systemImage: "info.circle") }
                    }
                }
                .sheet(item: $sheet) { sheet in sheetView(sheet) }
                .confirmationDialog("Delete \(pendingDelete?.name ?? "this Mac")?",
                                    isPresented: Binding(get: { pendingDelete != nil },
                                                         set: { if !$0 { pendingDelete = nil } }),
                                    titleVisibility: .visible, presenting: pendingDelete) { host in
                    Button("Delete", role: .destructive) { delete(host) }
                } message: { _ in
                    Text("Its saved password is removed from the Keychain.")
                }
        }
        // A connected session (from a card, ConnectSheet, or the DEBUG
        // autoConnect) is shown full-screen; it goes away when the session ends.
        .fullScreenCover(isPresented: Binding(
            get: { model.isSessionActive },
            set: { shown in if !shown, model.isSessionActive { Task { await model.disconnect() } } })) {
            SessionView(model: model)
        }
        // Background: close the session at once (the Mac stops sharing);
        // active again: reconnect (SessionCoordinator / LifecyclePolicy).
        // The background task ends only after enterBackground returns, i.e.
        // after the TCP close went out (awaited, ≤ 1 s) and media closed.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                let token = BackgroundTask.begin("close session")
                browser.stop()
                Task {
                    await model.enterBackground()
                    token.end()
                }
            case .active:
                if !model.isSessionActive { browser.start() }
                Task { await model.becomeActive() }
            default:
                break
            }
        }
        // Browse only while the list is what's on screen.
        .onChange(of: model.isSessionActive) { _, active in
            if active { browser.stop() } else { browser.start() }
        }
        .onAppear { if !model.isSessionActive { browser.start() } }
        #if DEBUG
        .task { await DebugLaunch.runIfRequested(model) }
        #endif
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if savedHosts.isEmpty && browser.hosts.isEmpty && search.isEmpty {
            VStack(spacing: 0) {
                statusBanner.padding()
                ContentUnavailableView {
                    Label("No Macs yet", systemImage: "desktopcomputer")
                } description: {
                    Text("Macs with Screen Sharing on appear here. Tap + to add one by address.")
                } actions: {
                    Button("Add Mac") { sheet = .new }.buttonStyle(.borderedProminent)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusBanner
                    if !saved.isEmpty {
                        section("Saved") {
                            ForEach(saved) { host in savedCard(host) }
                        }
                    }
                    section("On This Network") {
                        ForEach(discovered) { d in discoveredCard(d) }
                    } empty: {
                        if discovered.isEmpty {
                            Text(browser.hosts.isEmpty ? "Looking for Macs with Screen Sharing on…"
                                                       : "No other Macs found.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 16)]

    private func section<Cards: View, Empty: View>(_ title: String, @ViewBuilder cards: () -> Cards,
                                                   @ViewBuilder empty: () -> Empty = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) { cards() }
            empty()
        }
    }

    private func savedCard(_ host: SavedHost) -> some View {
        let online = HostMatcher.discovered(for: host, in: browser.hosts, resolved: connector.resolvedIPv4) != nil
        return Button { open(host) } label: {
            HostCard(name: host.name, address: host.displayAddress,
                     detail: host.lastConnected.map { "Last connected \($0.formatted(.relative(presentation: .named)))" }
                        ?? "Never connected",
                     onNetwork: online)
        }
        .buttonStyle(.plain)
        .disabled(connector.isBusy)
        .contextMenu {
            Button { open(host) } label: { Label("Connect", systemImage: "play.display") }
            Button { sheet = .edit(host) } label: { Label("Edit", systemImage: "pencil") }
            Button { duplicate(host) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { pendingDelete = host } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func discoveredCard(_ d: DiscoveredHost) -> some View {
        Button { sheet = .discovered(d) } label: {
            HostCard(name: d.name, address: connector.resolvedIPv4[d.name] ?? "Bonjour",
                     detail: "On this network", onNetwork: true)
        }
        .buttonStyle(.plain)
        .disabled(connector.isBusy)
    }

    /// Connecting / failure status for a connect started from a card.
    @ViewBuilder private var statusBanner: some View {
        if connector.isResolving || (model.state == .connecting && !model.isSessionActive) {
            HStack(spacing: 12) {
                ProgressView()
                Text(connector.isResolving ? "Looking up the Mac…" : "Connecting…")
                Spacer()
                Button("Cancel") { Task { await connector.cancel() } }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if sheet == nil, let message = failureMessage {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                Spacer()
                Button("Dismiss") {
                    connector.error = nil
                    if case .failed = model.state { Task { await model.disconnect() } }
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var failureMessage: String? {
        if let e = connector.error { return e }
        if case .failed(let m) = model.state { return m }
        return nil
    }

    @ViewBuilder private func sheetView(_ sheet: HostSheet) -> some View {
        switch sheet {
        case .new:
            ConnectSheet(connector: connector, editor: HostEditorModel())
        case .discovered(let d):
            ConnectSheet(connector: connector, editor: HostEditorModel(discovered: d))
        case .edit(let host):
            ConnectSheet(connector: connector, editor: HostEditorModel(editing: host, passwords: connector.passwords),
                         existing: host)
        case .password(let host):
            PasswordPromptView(host: host) { user, password, remember in
                connect(host, username: user, password: password, remember: remember)
            }
        case .about:
            AcknowledgementsView()
        }
    }

    // MARK: - Actions

    /// Connects with the stored password, or asks for one.
    private func open(_ host: SavedHost) {
        guard !connector.isBusy else { return }
        let stored: String?
        do { stored = try connector.passwords.password(for: host.id) } catch {
            Log.hosts.error("keychain read failed for \(host.id.uuidString): \(error)")
            stored = nil
        }
        if let stored, !stored.isEmpty, !host.username.isEmpty {
            connect(host, username: nil, password: stored, remember: false)
        } else {
            sheet = .password(host)
        }
    }

    private func connect(_ host: SavedHost, username: String?, password: String, remember: Bool) {
        let service = HostMatcher.discovered(for: host, in: browser.hosts, resolved: connector.resolvedIPv4)
        Task {
            await connector.connect(saved: host, username: username, password: password, remember: remember,
                                    service: service, context: context)
        }
    }

    private func delete(_ host: SavedHost) {
        do { try HostStore.delete(host, in: context, passwords: connector.passwords) } catch {
            Log.hosts.error("delete host failed: \(error)")
            connector.error = "Couldn't delete \(host.name)."
        }
    }

    private func duplicate(_ host: SavedHost) {
        do { try HostStore.duplicate(host, in: context, passwords: connector.passwords) } catch {
            Log.hosts.error("duplicate host failed: \(error)")
        }
    }
}

enum HostSheet: Identifiable {
    case new, about
    case edit(SavedHost)
    case discovered(DiscoveredHost)
    case password(SavedHost)

    var id: String {
        switch self {
        case .new: "new"
        case .about: "about"
        case .edit(let h): "edit-\(h.id)"
        case .discovered(let d): "discovered-\(d.name)"
        case .password(let h): "password-\(h.id)"
        }
    }
}

/// One Mac in the host grid.
struct HostCard: View {
    let name: String
    let address: String
    let detail: String
    let onNetwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                Spacer()
                if onNetwork {
                    Label("On network", systemImage: "circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .accessibilityLabel("On this network")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(1)
                Text(address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// Extra time to finish closing the session after the app is backgrounded.
@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundTask {
        let t = BackgroundTask()
        t.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak t] in
            MainActor.assumeIsolated { t?.end() }
        }
        return t
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
