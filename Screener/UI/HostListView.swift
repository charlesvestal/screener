import SwiftData
import SwiftUI
import UIKit

/// The host list (Task 18): saved Macs (recents first) and Macs found with
/// Bonjour, as a grid of cards. Tap → connect (asking for the password when
/// none is stored); "+" → ConnectSheet.
///
/// Delight: a card shows its Mac's last picture (HostThumbnails), model icon
/// (MacModelSymbol) and Bonjour presence (HostReachability); while connecting
/// it shows the connection stages, then zooms into the full-screen session
/// (and the session shrinks back into it on disconnect). Pull to refresh
/// restarts Bonjour discovery.
struct HostListView: View {
    @State private var model: SessionCoordinator
    @State private var connector: HostConnector
    @State private var browser = BonjourBrowser()
    @State private var sheet: HostSheet?
    @State private var pendingDelete: SavedHost?
    @State private var showSettings = false
    @State private var search = ""
    @State private var thumbnails = HostThumbnails()
    /// The card the session zooms out of (fixed for a presentation; nil:
    /// the default cover transition, e.g. for a ConnectSheet connect).
    @State private var zoomSource: UUID?
    /// The saved host whose card shows the connection stages.
    @State private var connectingHostID: UUID?
    @Namespace private var zoomNamespace
    @AppStorage("feedback.visual") private var visualFeedback = true
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
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) { thumbnails.removeAll() } label: {
                            Label("Clear All Thumbnails", systemImage: "photo.badge.minus")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .about } label: { Label("About", systemImage: "info.circle") }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                }
                .sheet(item: $sheet) { sheet in sheetView(sheet) }
                .onChange(of: sheet?.id) { _, id in
                    // A connect from a sheet other than a card's password prompt has no card.
                    if let id, !id.hasPrefix("password-") { zoomSource = nil; connectingHostID = nil }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
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
                // Every touch belongs to the Mac: no swipe/pinch-to-dismiss.
                .interactiveDismissDisabled()
                .modifier(SessionZoom(sourceID: zoomSource, namespace: zoomNamespace))
        }
        // The last picture of a session → its card's thumbnail; the Mac's
        // model (DeviceInfo) → its card's icon.
        .onChange(of: model.lastPicture?.serial) { _, _ in
            guard let picture = model.lastPicture?.image, let id = connector.activeHostID,
                  savedHosts.contains(where: { $0.id == id }) else { return }
            Task { await thumbnails.save(picture, for: id) }
        }
        .onChange(of: model.deviceModel) { _, m in connector.recordDeviceModel(m, in: context) }
        .task(id: savedHosts.map(\.id)) { await thumbnails.load(savedHosts.map(\.id)) }
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
        .task { await DemoHosts.seed(context: context, thumbnails: thumbnails, browser: browser) }
        #endif
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if savedHosts.isEmpty && browser.hosts.isEmpty && search.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    statusBanner.padding()
                    HostsEmptyState { sheet = .new }
                }
                .frame(maxWidth: .infinity)
            }
            .refreshable { await refreshDiscovery() }
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
            .refreshable { await refreshDiscovery() }
        }
    }

    /// Pull to refresh: a fresh Bonjour browse, held long enough for the
    /// Macs still advertised to come back.
    private func refreshDiscovery() async {
        guard !model.isSessionActive else { return }
        browser.restart()
        try? await Task.sleep(for: .seconds(1.5))
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
        let reachability = HostReachability.of(host, discovered: browser.hosts, resolved: connector.resolvedIPv4,
                                               isBrowsing: browser.isBrowsing)
        let thumbnail = thumbnails.image(for: host.id)
        return Button { open(host) } label: {
            HostCard(name: host.name, address: host.displayAddress,
                     detail: host.lastConnected.map { "Last connected \($0.formatted(.relative(presentation: .named)))" }
                        ?? "Never connected",
                     symbol: MacModelSymbol.symbol(for: host.macModel),
                     family: MacModelSymbol.family(for: host.macModel),
                     reachability: reachability, thumbnail: thumbnail, stage: connectingStage(for: host))
                .matchedTransitionSource(id: host.id, in: zoomNamespace) { source in
                    source.clipShape(RoundedRectangle(cornerRadius: HostCard.cornerRadius, style: .continuous))
                }
        }
        .buttonStyle(.plain)
        .disabled(connector.isBusy)
        .contextMenu {
            Button { open(host) } label: { Label("Connect", systemImage: "play.display") }
            Button { sheet = .edit(host) } label: { Label("Edit", systemImage: "pencil") }
            Button { duplicate(host) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if thumbnail != nil {
                Button { thumbnails.remove(host.id) } label: {
                    Label("Clear Thumbnail", systemImage: "photo.badge.minus")
                }
            }
            Divider()
            Button(role: .destructive) { pendingDelete = host } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func discoveredCard(_ d: DiscoveredHost) -> some View {
        Button { sheet = .discovered(d) } label: {
            HostCard(name: d.name, address: connector.resolvedIPv4[d.name] ?? "Bonjour",
                     detail: "On this network", reachability: .online)
        }
        .buttonStyle(.plain)
        .disabled(connector.isBusy)
    }

    /// The stage shown on `host`'s card while it connects (nil otherwise).
    private func connectingStage(for host: SavedHost) -> ConnectionStage? {
        guard connectingHostID == host.id, !model.isSessionActive,
              connector.isResolving || model.state == .connecting else { return nil }
        return connector.isResolving ? .idle : model.stage
    }

    /// Connecting / failure status for a connect started from a card.
    @ViewBuilder private var statusBanner: some View {
        if connector.isResolving || (model.state == .connecting && !model.isSessionActive) {
            HStack(spacing: 12) {
                ProgressView()
                Text(connector.isResolving ? "Looking up the Mac…" : model.stage.title)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: model.stage)
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
        connectingHostID = host.id
        zoomSource = visualFeedback ? host.id : nil
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
        let id = host.id
        do {
            try HostStore.delete(host, in: context, passwords: connector.passwords, thumbnails: thumbnails.store)
            thumbnails.remove(id)
        } catch {
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

/// The session zooms out of the card it was opened from (iPadOS 26 zoom
/// transition; with Reduce Motion the system cross-fades it) and shrinks back
/// into it when it ends. Without a source card: the default cover transition.
private struct SessionZoom: ViewModifier {
    let sourceID: UUID?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if let sourceID {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
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
