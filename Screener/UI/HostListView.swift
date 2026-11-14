import SwiftUI
import UIKit

struct HostListView: View {
    @State private var model = SessionCoordinator()
    @State private var showingConnect = false
    @State private var showingAbout = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Hosts")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingConnect = true } label: { Label("Connect", systemImage: "plus") }
                    }
                    ToolbarItem(placement: .secondaryAction) { ShareLogButton() }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingAbout = true } label: { Label("About", systemImage: "info.circle") }
                    }
                }
                .sheet(isPresented: $showingConnect) { ConnectSheet(model: model) }
                .sheet(isPresented: $showingAbout) { AcknowledgementsView() }
        }
        // A connected session (from ConnectSheet, or the DEBUG autoConnect)
        // is shown full-screen; it goes away when the session ends.
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
                Task {
                    await model.enterBackground()
                    token.end()
                }
            case .active:
                Task { await model.becomeActive() }
            default:
                break
            }
        }
        #if DEBUG
        .task { await DebugLaunch.runIfRequested(model) }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .connected(let w, let h):
            // Behind the full-screen SessionView.
            Text("Connected — canvas \(w)×\(h)").font(.title2)
        case .connecting:
            ProgressView(model.isReconnecting ? "Reconnecting…" : "Connecting…")
        case .suspended:
            ProgressView("Reconnecting…")
        case .failed(let message):
            ContentUnavailableView("Couldn't connect", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .idle:
            ContentUnavailableView("No Macs yet", systemImage: "desktopcomputer",
                                   description: Text("Tap + to connect to a Mac."))
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
