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
                }
                .sheet(isPresented: $showingConnect) { ConnectSheet(model: model) }
        }
        #if DEBUG
        .task { await DebugLaunch.runIfRequested(model) }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .connected(let w, let h):
            // Placeholder until SessionView (Task 14).
            VStack(spacing: 16) {
                Text("Connected — canvas \(w)×\(h)").font(.title2)
                Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                    .buttonStyle(.borderedProminent)
            }
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
