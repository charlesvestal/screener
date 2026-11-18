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
///
/// Per-Mac session settings (HostSessionSettings.swift): menu changes during
/// a saved Mac's session are saved on it; the defaults come back when it
/// ends. "Reconnect to Last Mac on Launch" (ResumeOnLaunch.swift) runs here
/// once per process. The menu's "Switch Mac" (MacSwitcher) ends the session,
/// shrinks it back into its card, and connects to the other Mac from its card.
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
    // The per-Mac session settings' live keys (captured into the session's Mac).
    @AppStorage(DisplayMode.defaultsKey) private var displayModeRaw = DisplayMode.default.rawValue
    @AppStorage(TouchInputMode.defaultsKey) private var touchModeRaw = TouchInputMode.default.rawValue
    @AppStorage(AudioPlayer.mutedDefaultsKey) private var audioMuted = false
    @AppStorage(ClipboardSyncMode.defaultsKey) private var clipboardModeRaw = ClipboardSyncMode.default.rawValue
    @AppStorage(PacingConfig.defaultsKey) private var smoothPlayback = false
    /// "Reconnect to Last Mac on Launch" countdown.
    @State private var resumer = LaunchResumer()
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
        let unmatched = HostMatcher.unmatched(browser.hosts, saved: savedHosts)
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
                    if id != nil { resumer.cancel() }
                    // A connect from a sheet other than a card's password prompt has no card.
                    if let id, !id.hasPrefix("password-") { zoomSource = nil; connectingHostID = nil }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
                .onChange(of: showSettings) { _, shown in if shown { resumer.cancel() } }
                .confirmationDialog("Delete \(pendingDelete?.name ?? "this Mac")?",
                                    isPresented: Binding(get: { pendingDelete != nil },
                                                         set: { if !$0 { pendingDelete = nil } }),
                                    titleVisibility: .visible, presenting: pendingDelete) { host in
                    Button("Delete", role: .destructive) { delete(host) }
                } message: { _ in
                    Text("Its saved password is removed from the Keychain.")
                }
                // H1: the Mac presented a key other than the pinned one; the
                // connect stopped before any credential was sent. Re-pin only
                // on this explicit choice.
                .alert("This Mac's identity changed", isPresented: Binding(
                    get: { identityChangedHost != nil },
                    set: { if !$0 { model.clearIdentityChange() } }),
                       presenting: identityChangedHost) { host in
                    let presented = model.identityChange?.presentedSHA256
                    Button("Cancel", role: .cancel) { model.clearIdentityChange() }
                    Button("Trust New Key", role: .destructive) {
                        guard let presented else { return }
                        connector.trustNewKey(presented, for: host, context: context)
                        open(host)
                    }
                } message: { host in
                    Text("\(host.name) presented a different identity than the one Screener remembered, so your "
                         + "password wasn't sent. This is expected if the Mac was reinstalled or replaced — but it "
                         + "can also mean someone on this network is impersonating it. Trust the new identity only "
                         + "if you know why it changed.\n\nNew identity: \(Self.fingerprint(model.identityChange))")
                }
        }
        // A connected session (from a card, ConnectSheet, or the DEBUG
        // autoConnect) is shown full-screen; it goes away when the session ends.
        .fullScreenCover(isPresented: Binding(
            get: { model.isSessionActive },
            set: { shown in if !shown, model.isSessionActive { Task { await model.disconnect() } } })) {
            SessionView(model: model, switchMac: macSwitcher, savedFor: connector.sessionHostName)
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
                resumer.cancel()
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
            // The session is over: its Mac's settings give way to the defaults.
            if !active { connector.sessionEnded() }
        }
        // A control-menu change during a saved Mac's session is saved on it.
        .onChange(of: [displayModeRaw, touchModeRaw, clipboardModeRaw, "\(audioMuted)", "\(smoothPlayback)"]) {
            connector.captureSessionSettings(context: context)
        }
        .onAppear { if !model.isSessionActive { browser.start() } }
        .task { startResumeOnLaunch() }
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
        if let pending = resumer.pending {
            HStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(pending.name)…")
                Spacer()
                Button("Cancel") { resumer.cancel() }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if connector.isResolving || (model.state == .connecting && !model.isSessionActive) {
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

    /// The saved host whose connect was refused for a changed identity.
    private var identityChangedHost: SavedHost? {
        guard model.identityChange != nil, let id = connector.pendingIdentityHostID else { return nil }
        return savedHosts.first { $0.id == id }
    }

    /// The first 8 bytes of a key fingerprint, "ab12 cd34 …" (for comparing by eye).
    static func fingerprint(_ change: SessionCoordinator.IdentityChange?) -> String {
        guard let d = change?.presentedSHA256 else { return "" }
        let hex = d.prefix(8).map { String(format: "%02X", $0) }
        return stride(from: 0, to: hex.count, by: 2).map { hex[$0..<min($0 + 2, hex.count)].joined() }
            .joined(separator: " ")
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
        resumer.cancel()
        guard !connector.isBusy else { return }
        connectingHostID = host.id
        zoomSource = visualFeedback ? host.id : nil
        if let stored = connector.storedPassword(for: host), !host.username.isEmpty {
            connect(host, username: nil, password: stored, remember: false)
        } else {
            sheet = .password(host)
        }
    }

    private func connect(_ host: SavedHost, username: String?, password: String, remember: Bool) {
        let service = HostMatcher.discovered(for: host, in: browser.hosts)
        Task {
            await connector.connect(saved: host, username: username, password: password, remember: remember,
                                    service: service, context: context)
        }
    }

    // MARK: - Switching Macs / resume on launch

    /// The menu's "Switch Mac" list: every saved Mac, the session's marked.
    private var macSwitcher: MacSwitcher? {
        let current = connector.activeHostID
        let macs = HostStore.ordered(savedHosts)
        guard macs.contains(where: { $0.id != current }) else { return nil }
        let options = macs.map { h in
            MacSwitchOption(id: h.id, name: h.name, address: h.displayAddress,
                            reachability: HostReachability.of(h, discovered: browser.hosts, isBrowsing: browser.isBrowsing),
                            isCurrent: h.id == current)
        }
        return MacSwitcher(macs: options, select: { switchMac(to: $0) }, listShown: { shown in
            if shown { browser.start() } else if model.isSessionActive { browser.stop() }
        })
    }

    /// Ends this session (keys released, TCP close awaited), lets the session
    /// view shrink back into its card, then connects to `id` from its card —
    /// with its stored password, or asking for one.
    private func switchMac(to id: UUID) {
        guard let host = savedHosts.first(where: { $0.id == id }), id != connector.activeHostID else { return }
        resumer.cancel()
        let service = HostMatcher.discovered(for: host, in: browser.hosts)
        let showCard = {
            connectingHostID = host.id
            zoomSource = visualFeedback ? host.id : nil
        }
        Task {
            let outcome = await connector.switchSession(to: host, service: service, context: context) {
                try? await Task.sleep(for: Self.coverDismissal)
                showCard()
            }
            if outcome == .needsPassword {
                try? await Task.sleep(for: Self.coverDismissal)
                showCard()
                sheet = .password(host)
            }
        }
    }

    /// Long enough for the session view's dismissal (zoom back into its card).
    private static let coverDismissal: Duration = .milliseconds(500)

    /// Cold launch, setting on, last Mac's password stored: connect after a
    /// cancellable countdown (the banner).
    private func startResumeOnLaunch() {
        let cold = LaunchGate.shared.claim()
        #if DEBUG
        if UserDefaults.standard.string(forKey: "autoConnect") != nil || DemoHosts.mode != nil { return }
        #endif
        guard let host = ResumeOnLaunch.candidate(enabled: ResumeOnLaunch.isEnabled(), coldLaunch: cold,
                                                  hosts: savedHosts,
                                                  hasStoredPassword: { connector.storedPassword(for: $0) != nil })
        else { return }
        resumer.start(host) { id in
            guard sheet == nil, !showSettings, !connector.isBusy, !model.isSessionActive,
                  let host = savedHosts.first(where: { $0.id == id }) else { return }
            open(host)
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
