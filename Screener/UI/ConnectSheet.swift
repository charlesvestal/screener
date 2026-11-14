import Observation
import SwiftUI
import UIKit

/// Owns one `ControlSession` for the debug connect flow (Task 10). Task 14's
/// SessionView will replace the "connected" placeholder in HostListView.
@MainActor @Observable
final class ConnectionModel {
    enum State: Equatable {
        case idle
        case connecting
        case connected(canvasWidth: Int, canvasHeight: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    private var session: ControlSession?
    private var eventsTask: Task<Void, Never>?
    private var userClosed = false

    var isBusy: Bool { state == .connecting }

    func connect(host: String, port: UInt16, username: String, password: String,
                 order: ControlSession.StartupOrder = .reference) async {
        guard session == nil else { return }
        let (logical, backing) = Self.screenSizes()
        let config = ControlSession.Config(host: host, port: port, username: username, password: password,
                                           logicalSize: logical, backingSize: backing, startupOrder: order)
        let session = ControlSession(config: config)
        self.session = session
        userClosed = false
        state = .connecting
        do {
            let params = try await session.start()
            state = .connected(canvasWidth: params.canvas.width, canvasHeight: params.canvas.height)
            watch(session)
        } catch {
            self.session = nil
            state = userClosed ? .idle : .failed(ControlSession.describe(error))
        }
    }

    func disconnect() async {
        userClosed = true
        eventsTask?.cancel(); eventsTask = nil
        if let session { await session.close() }
        session = nil
        state = .idle
    }

    /// Drains events (nothing consumes them yet) and notices when the session ends.
    private func watch(_ session: ControlSession) {
        eventsTask = Task { [weak self] in
            for await _ in session.events {}
            let failure = await session.failure
            guard let self, !Task.isCancelled, self.session === session else { return }
            self.session = nil
            self.state = failure.map { .failed(ControlSession.describe($0)) } ?? .idle
        }
    }

    /// Advertised display: the window scene's screen in points (logical) and
    /// `points × nativeScale` (backing). Using bounds × scale rather than
    /// `nativeBounds` keeps the backing size in the current orientation.
    static func screenSizes() -> (logical: CGSize, backing: CGSize) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let logical = screen?.bounds.size ?? CGSize(width: 1376, height: 1032)
        let scale = screen?.nativeScale ?? 2
        return (logical, CGSize(width: logical.width * scale, height: logical.height * scale))
    }
}

/// Minimal manual-connect form (reused by Task 18).
struct ConnectSheet: View {
    let model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "5900"
    @State private var username = ""
    @State private var password = ""

    private var portValue: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }
    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && portValue != nil && !username.isEmpty && !model.isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    TextField("Host or IP address", text: $host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                Section {
                    switch model.state {
                    case .connecting:
                        HStack { ProgressView(); Text("Connecting…") }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Connect to Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task { if model.isBusy { await model.disconnect() } }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { connect() }
                        .disabled(!canConnect)
                }
            }
            .onChange(of: model.state) { _, new in
                if case .connected = new { dismiss() }
            }
        }
    }

    private func connect() {
        guard let portValue else { return }
        let host = host.trimmingCharacters(in: .whitespaces)
        Task { await model.connect(host: host, port: portValue, username: username, password: password) }
    }
}
