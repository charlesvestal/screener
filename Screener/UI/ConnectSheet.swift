import SwiftUI

/// Minimal manual-connect form (reused by Task 18).
struct ConnectSheet: View {
    let model: SessionCoordinator
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
