import SwiftData
import SwiftUI

/// Add / edit / connect form for a Mac (Task 18).
///   new        "+": type an address; Connect (and save it, if "Save to Hosts" is on)
///   discovered a Bonjour Mac: its address is looked up; Connect (and save)
///   edit       an existing saved host; Save
struct ConnectSheet: View {
    let connector: HostConnector
    /// The host being edited (edit mode only).
    var existing: SavedHost?
    @State private var editor: HostEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var saveError: String?

    init(connector: HostConnector, editor: HostEditorModel, existing: SavedHost? = nil) {
        self.connector = connector
        self.existing = existing
        _editor = State(initialValue: editor)
    }

    private var model: SessionCoordinator { connector.model }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    TextField("Name", text: $editor.name, prompt: Text(editor.effectiveName))
                        .textInputAutocapitalization(.words)
                    if let service = editor.discoveredService {
                        LabeledContent("Address") {
                            if editor.trimmedHost.isEmpty {
                                if connector.isResolving { ProgressView() } else { Text(service.name + " (Bonjour)") }
                            } else {
                                Text(editor.trimmedHost).textSelection(.enabled)
                            }
                        }
                    } else {
                        TextField("Host or IP address", text: $editor.host)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $editor.port)
                            .keyboardType(.numberPad)
                    }
                }
                Section {
                    TextField("Username", text: $editor.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $editor.password)
                        .textContentType(.password)
                } header: {
                    Text("Account")
                } footer: {
                    if editor.isEditing || editor.saveToHosts {
                        Text("The password is stored only in this iPad's Keychain.")
                    }
                }
                if !editor.isEditing {
                    Section {
                        Toggle("Save to Hosts", isOn: $editor.saveToHosts)
                    }
                }
                statusSection
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task { if connector.isBusy { await connector.cancel() } }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editor.isEditing {
                        Button("Save") { save() }.disabled(!editor.canSave)
                    } else {
                        Button("Connect") { connect() }.disabled(!editor.canConnect || connector.isBusy)
                    }
                }
            }
            // On success the sheet closes and HostListView presents the
            // SessionView full-screen (it follows model.isSessionActive).
            .onChange(of: model.state) { _, new in
                if case .connected = new { dismiss() }
            }
            .task {
                if !connector.isBusy { connector.error = nil }   // not a previous attempt's
                // Show the Bonjour Mac's address up front.
                if let service = editor.discoveredService, editor.trimmedHost.isEmpty, !connector.isBusy {
                    if let r = try? await connector.resolve(service) {
                        editor.host = r.address
                        editor.port = String(r.port)
                    }
                }
            }
        }
    }

    private var title: String {
        switch editor.mode {
        case .new: "Connect to Mac"
        case .edit: "Edit Mac"
        case .discovered(let d): d.name
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            if connector.isResolving {
                HStack { ProgressView(); Text("Looking up the Mac…") }
            } else if let error = saveError ?? connector.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if !editor.isEditing {
                switch model.state {
                case .connecting:
                    HStack { ProgressView(); Text("Connecting…") }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func save() {
        do {
            try editor.save(existing: existing, context: context, passwords: connector.passwords)
            dismiss()
        } catch {
            Log.hosts.error("save host failed: \(error)")
            saveError = "Couldn't save this Mac."
        }
    }

    private func connect() {
        guard let port = editor.portValue else { return }
        saveError = nil
        let editor = editor, connector = connector, context = context
        Task {
            // A Bonjour Mac is resolved to its IPv4 (usually already done when
            // the sheet opened) before it's saved; that literal is what connects.
            if let s = editor.discoveredService, editor.trimmedHost.isEmpty {
                do {
                    let r = try await connector.resolve(s)
                    editor.host = r.address
                    editor.port = String(r.port)
                } catch {
                    connector.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't find \(s.name)."
                    return
                }
            }
            var saved: SavedHost?
            do {
                saved = try editor.save(context: context, passwords: connector.passwords)
            } catch {
                Log.hosts.error("save host failed: \(error)")
                saveError = "Couldn't save this Mac."
            }
            let r = await connector.connect(host: editor.trimmedHost, port: editor.portValue ?? port,
                                            username: editor.username, password: editor.password)
            if r.connected, let saved {
                connector.markConnected(saved, resolvedAddress: r.resolvedAddress, rememberPassword: nil, context: context)
            }
        }
    }
}

/// Asks for the password of a saved host that has none in the Keychain.
struct PasswordPromptView: View {
    let host: SavedHost
    /// (username, password, remember)
    let onConnect: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var remember = true

    init(host: SavedHost, onConnect: @escaping (String, String, Bool) -> Void) {
        self.host = host
        self.onConnect = onConnect
        _username = State(initialValue: host.username)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(go)
                } header: {
                    Text(host.displayAddress)
                }
                Section {
                    Toggle("Remember Password", isOn: $remember)
                } footer: {
                    Text("Saved in this iPad's Keychain after a successful connection.")
                }
            }
            .navigationTitle(host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: go).disabled(username.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func go() {
        guard !username.isEmpty else { return }
        onConnect(username, password, remember)
        dismiss()
    }
}
