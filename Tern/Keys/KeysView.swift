import SwiftUI

/// Manage SSH keys in `~/.ssh` without typing paths: generate, copy the public key, share, import, delete.
struct KeysView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [SSHKey] = []
    @State private var showingGenerate = false
    @State private var showingImport = false
    @State private var pendingDelete: SSHKey?
    @State private var copiedKeyID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if keys.isEmpty {
                        emptyState
                    } else {
                        Card {
                            ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                                keyRow(key)
                                if index < keys.count - 1 { CardDivider() }
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Generate key") { showingGenerate = true }.buttonStyle(SecondaryButtonStyle())
                            Button("Import key") { showingImport = true }.buttonStyle(SecondaryButtonStyle())
                        }
                        Text("Add a public key to a server's ~/.ssh/authorized_keys and ssh will use it automatically. Keys live in ~/.ssh and are visible in the Files app, so back them up with care.")
                            .font(Typography.body(13))
                            .foregroundStyle(ChromeColor.textTertiary)
                    }
                }
                .screenPadding()
                .padding(.vertical, 16)
            }
            .background(ChromeColor.background)
            .navigationTitle("SSH Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .sheet(isPresented: $showingGenerate) {
                GenerateKeyView(existingNames: keys.map(\.name)) { command in
                    run(command)
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportKeyView(existingNames: keys.map(\.name)) { name in
                    run("ssh-keygen -y -f ~/.ssh/\(SSHKeyStore.shellQuote(name)) > ~/.ssh/\(SSHKeyStore.shellQuote(name)).pub && chmod 644 ~/.ssh/\(SSHKeyStore.shellQuote(name)).pub")
                }
            }
            .confirmationDialog("Delete \(pendingDelete?.name ?? "key")? This cannot be undone.", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete key", role: .destructive) {
                    if let key = pendingDelete { SSHKeyStore.delete(key) }
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
            Text("No keys yet.")
                .font(Typography.display(28))
                .foregroundStyle(ChromeColor.textPrimary)
            Text("An SSH key lets you log in without a password. Generate one here, copy the public half to your server, and you are set.")
                .font(Typography.body(16))
                .foregroundStyle(ChromeColor.textSecondary)
            Button("Generate a key") { showingGenerate = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
            Button("Import an existing key") { showingImport = true }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.top, 24)
    }

    private func keyRow(_ key: SSHKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.name).font(Typography.body(16, weight: .medium)).foregroundStyle(ChromeColor.textPrimary)
                    Text(key.typeTitle + (key.comment.isEmpty ? "" : "  " + key.comment))
                        .font(Typography.body(13)).foregroundStyle(ChromeColor.textSecondary)
                    Text(key.fingerprint).font(Typography.mono(11)).foregroundStyle(ChromeColor.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu {
                    ShareLink(item: key.publicKey) { Label("Share public key", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = key.publicKey } label: { Label("Copy public key", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { pendingDelete = key } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(ChromeColor.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Actions for \(key.name)")
            }
            Button {
                UIPasteboard.general.string = key.publicKey
                copiedKeyID = key.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copiedKeyID == key.id { copiedKeyID = nil } }
            } label: {
                HStack {
                    Image(systemName: copiedKeyID == key.id ? "checkmark" : "doc.on.doc")
                    Text(copiedKeyID == key.id ? "Copied" : "Copy public key")
                }
                .font(Typography.body(14, weight: .medium))
                .foregroundStyle(copiedKeyID == key.id ? ChromeColor.success : ChromeColor.accent)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func reload() {
        keys = SSHKeyStore.load()
    }

    /// Runs a command in a prompt-idle tab so the user sees exactly what happened.
    private func run(_ command: String) {
        dismiss()
        if let selected = model.selected, selected.mode == .prompt {
            selected.runCommand(command)
        } else {
            model.newSession(initialCommand: command)
        }
    }
}

struct GenerateKeyView: View {
    @Environment(\.dismiss) private var dismiss
    let existingNames: [String]
    let onGenerate: (String) -> Void

    @State private var type: SSHKeyStore.KeyType = .ed25519
    @State private var name = "id_ed25519"
    @State private var comment = "mobile@tern"
    @State private var passphrase = ""

    private var nameConflict: Bool { existingNames.contains(name) }
    private var isValid: Bool { !name.isEmpty && !name.contains("/") && !name.contains(" ") && !nameConflict }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $type) {
                        ForEach(SSHKeyStore.KeyType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: type) { _, newType in
                        if SSHKeyStore.KeyType.allCases.map(\.defaultFileName).contains(name) { name = newType.defaultFileName }
                    }
                }
                Section {
                    TextField("File name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Comment", text: $comment).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passphrase (optional)", text: $passphrase)
                } header: {
                    Text("Details")
                } footer: {
                    Text(nameConflict ? "A key named \(name) already exists." : "Saved as ~/.ssh/\(name) and ~/.ssh/\(name).pub. The command runs in the terminal so you can see it.")
                        .foregroundStyle(nameConflict ? ChromeColor.danger : ChromeColor.textTertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChromeColor.background)
            .navigationTitle("Generate Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        onGenerate(SSHKeyStore.generateCommand(name: name, type: type, comment: comment, passphrase: passphrase))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }
}

struct ImportKeyView: View {
    @Environment(\.dismiss) private var dismiss
    let existingNames: [String]
    let onImport: (String) -> Void

    @State private var name = "id_imported"
    @State private var text = ""
    @State private var error: String?

    private var looksLikeKey: Bool { text.contains("PRIVATE KEY") }
    private var isValid: Bool { !name.isEmpty && !name.contains("/") && !existingNames.contains(name) && looksLikeKey }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("File name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(existingNames.contains(name) ? "A key named \(name) already exists." : "Saved as ~/.ssh/\(name) with permissions 600. Tern then derives the public key.")
                }
                Section {
                    TextEditor(text: $text)
                        .font(Typography.mono(12))
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Paste from clipboard") {
                        if let clipboard = UIPasteboard.general.string { text = clipboard }
                    }
                } header: {
                    Text("Private key")
                } footer: {
                    if let error { Text(error).foregroundStyle(ChromeColor.danger) }
                    else if !text.isEmpty && !looksLikeKey { Text("This does not look like an OpenSSH private key.").foregroundStyle(ChromeColor.danger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChromeColor.background)
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            try SSHKeyStore.importPrivateKey(text, name: name)
                            onImport(name)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }
}
