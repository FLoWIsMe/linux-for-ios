import SwiftUI

/// Visual front end for `~/.ssh/config`: tap a host to open a tab connected to it.
struct HostsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [SSHHost] = []
    @State private var showingAdd = false
    @State private var pendingDelete: SSHHost?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hosts.isEmpty {
                        emptyState
                    } else {
                        Card {
                            ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                                Button {
                                    connect(to: host)
                                } label: {
                                    CardRow(title: host.name, subtitle: host.summary, systemImage: "network") {
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(ChromeColor.textTertiary)
                                    }
                                }
                                .buttonStyle(PressableStyle(pressedScale: 1))
                                .contextMenu {
                                    Button { connect(to: host) } label: { Label("Connect", systemImage: "terminal") }
                                    Button { UIPasteboard.general.string = "ssh \(host.name)" } label: { Label("Copy command", systemImage: "doc.on.doc") }
                                    Button(role: .destructive) { pendingDelete = host } label: { Label("Remove", systemImage: "trash") }
                                }
                                if index < hosts.count - 1 { CardDivider() }
                            }
                        }
                        Text("Hosts come from ~/.ssh/config. Edit the file for options Tern does not show, such as ProxyJump or ForwardAgent.")
                            .font(Typography.body(13))
                            .foregroundStyle(ChromeColor.textTertiary)
                    }
                }
                .screenPadding()
                .padding(.vertical, 16)
            }
            .background(ChromeColor.background)
            .navigationTitle("Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Done sits trailing on every sheet; the add button takes the leading slot.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add host")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddHostView { host in
                    SSHConfig.add(host)
                    reload()
                }
            }
            .confirmationDialog("Remove \(pendingDelete?.name ?? "host") from ~/.ssh/config?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let host = pendingDelete { SSHConfig.remove(host) }
                    pendingDelete = nil
                    reload()
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
            .onAppear(perform: reload)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No hosts yet.")
                .font(Typography.display(28))
                .foregroundStyle(ChromeColor.textPrimary)
            Text("Add a server here and Tern writes it to ~/.ssh/config, the same file ssh reads. Then connect with one tap, or type ssh name.")
                .font(Typography.body(16))
                .foregroundStyle(ChromeColor.textSecondary)
            Button("Add a host") { showingAdd = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
        }
        .padding(.top, 24)
    }

    private func reload() {
        hosts = SSHConfig.load()
    }

    private func connect(to host: SSHHost) {
        dismiss()
        let command = "ssh \(host.name)"
        if let selected = model.selected, selected.mode == .prompt {
            selected.runCommand(command)
        } else {
            model.newSession(initialCommand: command)
        }
    }
}

struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (SSHHost) -> Void

    @State private var name = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var keys: [SSHKey] = SSHKeyStore.load()

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(" ") && (port.isEmpty || Int(port) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (what you type after ssh)", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Host name or IP", text: $hostName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("User", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port (22)", text: $port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Only the name is required. Leave the host name empty when the name is already the address.")
                }
                Section("Key") {
                    Picker("Identity file", selection: $identityFile) {
                        Text("Default").tag("")
                        ForEach(keys) { key in
                            Text(key.name).tag("~/.ssh/\(key.name)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChromeColor.background)
            .navigationTitle("Add Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let host = SSHHost(
                            name: name.trimmingCharacters(in: .whitespaces),
                            hostName: hostName.isEmpty ? nil : hostName.trimmingCharacters(in: .whitespaces),
                            user: user.isEmpty ? nil : user.trimmingCharacters(in: .whitespaces),
                            port: Int(port),
                            identityFile: identityFile.isEmpty ? nil : identityFile
                        )
                        onSave(host)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }
}
