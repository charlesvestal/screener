import SwiftUI

struct HostListView: View {
    @State private var model = SessionCoordinator()
    @State private var showingConnect = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Hosts")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingConnect = true } label: { Label("Connect", systemImage: "plus") }
                    }
                    ToolbarItem(placement: .secondaryAction) { ShareLogButton() }
                }
                .sheet(isPresented: $showingConnect) { ConnectSheet(model: model) }
        }
        // A connected session (from ConnectSheet, or the DEBUG autoConnect)
        // is shown full-screen; it goes away when the session ends.
        .fullScreenCover(isPresented: Binding(
            get: { model.isSessionActive },
            set: { shown in if !shown, model.isSessionActive { Task { await model.disconnect() } } })) {
            SessionView(model: model)
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
            ProgressView("Connecting…")
        case .failed(let message):
            ContentUnavailableView("Couldn't connect", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .idle:
            ContentUnavailableView("No Macs yet", systemImage: "desktopcomputer",
                                   description: Text("Tap + to connect to a Mac."))
        }
    }
}
