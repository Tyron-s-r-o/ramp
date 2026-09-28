import AppKit
import SwiftUI
import RAMPCore

/// Add / edit a saved FTP/FTPS/SFTP site. Password / passphrase are written to the vault on save (the master
/// password is asked then, not earlier); an empty field on edit keeps the stored secret.
struct FTPSiteEditorSheet: View {
    let model: RemoteModel
    @State private var draft: RemoteSiteDraft
    @Environment(\.dismiss) private var dismiss

    init(model: RemoteModel, draft: RemoteSiteDraft) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Názov", text: $draft.name, prompt: draft.trimmedHost.isEmpty ? Text("Môj web") : Text(verbatim: draft.trimmedHost))
                    LabeledContent("Skupina") {
                        HStack(spacing: 4) {
                            TextField("Skupina", text: $draft.group, prompt: Text("Bez skupiny"))
                                .labelsHidden()
                            Menu {
                                ForEach(model.groups, id: \.self) { group in
                                    Button(group) { draft.group = group }
                                }
                                if !model.groups.isEmpty { Divider() }
                                Button("Bez skupiny") { draft.group = "" }
                            } label: {
                                Label("Existujúce skupiny", systemImage: "folder")
                            }
                            .labelStyle(.iconOnly)
                            .menuStyle(.borderlessButton)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Existujúce skupiny")
                        }
                    }
                }

                Section("Server") {
                    Picker("Protokol", selection: $draft.proto) {
                        Text(verbatim: "FTP").tag(RemoteProtocol.ftp)
                        Text("FTPES – explicitný TLS").tag(RemoteProtocol.ftpes)
                        Text("FTPS – implicitný TLS").tag(RemoteProtocol.ftps)
                        Text(verbatim: "SFTP").tag(RemoteProtocol.sftp)
                    }
                    // Port still at the old protocol's default → follow the new protocol (21 → 22 for SFTP…).
                    .onChange(of: draft.proto) { old, new in
                        let port = draft.port.trimmingCharacters(in: .whitespaces)
                        if port.isEmpty || port == String(old.defaultPort) { draft.port = String(new.defaultPort) }
                    }
                    if draft.proto == .ftp {
                        warning("Obyčajné FTP posiela meno, heslo aj súbory nezašifrované. Ak to server podporuje, použite FTPES alebo SFTP.")
                    }
                    TextField("Server", text: $draft.host, prompt: Text(verbatim: "ftp.example.com"))
                    TextField("Port", text: $draft.port, prompt: Text(verbatim: String(draft.proto.defaultPort)))
                    if draft.portNumber == nil {
                        error("Port musí byť číslo 1 – 65535.")
                    }
                }

                Section("Prihlásenie") {
                    TextField("Používateľ", text: $draft.username)
                    if draft.proto == .sftp {
                        Picker("Overenie", selection: $draft.auth) {
                            Text("Heslo").tag(RemoteAuthKind.password)
                            Text("Súkromný kľúč").tag(RemoteAuthKind.privateKey)
                        }
                        .pickerStyle(.segmented)
                    }
                    if draft.usesKey {
                        LabeledContent("Kľúč") {
                            HStack {
                                Text(verbatim: draft.privateKeyPath.isEmpty ? String(localized: "Nevybraný") : abbreviate(draft.privateKeyPath))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(draft.privateKeyPath.isEmpty ? .secondary : .primary)
                                    .help(Text(verbatim: draft.privateKeyPath))
                                Button("Vybrať…") { pickKey() }
                            }
                        }
                        if let hint = SSHKeyHint.hint(for: draft.privateKeyPath) {
                            warningText(hint)
                        }
                        SecureField("Passphrase", text: $draft.keyPassphrase, prompt: secretPrompt)
                    } else {
                        SecureField("Heslo", text: $draft.password, prompt: secretPrompt)
                    }
                    Text(draft.isNew ? "Heslo sa uloží zašifrované hlavným heslom trezora." : "Nechajte prázdne, ak sa uložené heslo nemá meniť.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Pokročilé") {
                    TextField("Počiatočný priečinok", text: $draft.initialPath, prompt: Text(verbatim: "/www"))
                    if draft.proto != .sftp {
                        Toggle("Pasívny režim", isOn: $draft.passive)
                    }
                    if draft.usesTLS {
                        Toggle("Povoliť nedôveryhodný certifikát", isOn: $draft.allowInsecureCertificate)
                        if draft.allowInsecureCertificate {
                            warning("Certifikát servera sa nebude overovať. Spojenie je šifrované, ale neoverí sa, či naozaj hovoríte so správnym serverom.")
                        }
                    }
                    TextField("Poznámky", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if model.saving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Zrušiť") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Pridať" : "Uložiť") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || model.saving)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        .onChange(of: draft.proto) { old, new in
            // Auto-fill the default port unless the user typed a custom one.
            let current = draft.port.trimmingCharacters(in: .whitespaces)
            if current.isEmpty || current == String(old.defaultPort) { draft.port = String(new.defaultPort) }
            if new != .sftp { draft.auth = .password }
        }
        .vaultPromptSheet(model, host: .editor)
        .interactiveDismissDisabled(model.saving)
    }

    private var secretPrompt: Text {
        draft.isNew ? Text(verbatim: "") : Text("Nezmenené")
    }

    private func warning(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warningText(_ text: String) -> some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func error(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "xmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// NSOpenPanel directly: starts in ~/.ssh and shows hidden files (fileImporter can do neither).
    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Vyberte súkromný kľúč (formát OpenSSH)")
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        panel.directoryURL = draft.privateKeyPath.isEmpty
            ? ssh : URL(filePath: draft.privateKeyPath).deletingLastPathComponent()
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { draft.privateKeyPath = url.path(percentEncoded: false) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func cancel() {
        guard !model.saving else { return }
        model.editor = nil
        dismiss()
    }

    private func save() async {
        if await model.save(draft) { dismiss() }
    }
}

/// Hints for the chosen SFTP key file (09-02 limitations: OpenSSH format only; RSA signs with SHA-1).
enum SSHKeyHint {
    static func hint(for path: String) -> String? {
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(filePath: path)), data.count < 64_000,
              let text = String(data: data, encoding: .utf8) else { return nil }
        if text.contains("BEGIN RSA PRIVATE KEY") || text.contains("BEGIN PRIVATE KEY")
            || text.contains("BEGIN EC PRIVATE KEY") || text.contains("PuTTY-User-Key-File") {
            return String(localized: "Tento formát kľúča RAMP nepozná. Prevod na OpenSSH: ssh-keygen -p -f <kľúč> (alebo vytvorte nový ed25519 kľúč).")
        }
        guard let type = openSSHKeyType(text) else { return nil }
        if type == "ssh-rsa" {
            return String(localized: "RSA kľúč: moderné servery (OpenSSH 8.8+) ho môžu odmietnuť, lebo RAMP ním zatiaľ podpisuje cez SHA-1. Odporúčame kľúč ed25519 (ssh-keygen -t ed25519).")
        }
        if type != "ssh-ed25519" {
            return String(localized: "Typ kľúča \(type) RAMP nepodporuje. Použite kľúč ed25519 (ssh-keygen -t ed25519).")
        }
        return nil
    }

    /// Public key type from the unencrypted header of an `openssh-key-v1` file.
    private static func openSSHKeyType(_ pem: String) -> String? {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        guard let b = pem.range(of: begin), let e = pem.range(of: end, range: b.upperBound..<pem.endIndex),
              let data = Data(base64Encoded: String(pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace })) else { return nil }
        let bytes = [UInt8](data)
        var pos = 15
        guard bytes.count > pos, Array(bytes[0..<15]) == Array("openssh-key-v1\0".utf8) else { return nil }
        func blob() -> [UInt8]? {
            guard pos + 4 <= bytes.count else { return nil }
            let len = Int(bytes[pos..<pos + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            pos += 4
            guard len >= 0, pos + len <= bytes.count else { return nil }
            defer { pos += len }
            return Array(bytes[pos..<pos + len])
        }
        // cipher, kdf, kdf options, key count, first public key
        guard blob() != nil, blob() != nil, blob() != nil, pos + 4 <= bytes.count else { return nil }
        pos += 4
        guard let pub = blob(), pub.count >= 4 else { return nil }
        let len = Int(pub[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard 4 + len <= pub.count else { return nil }
        return String(bytes: pub[4..<4 + len], encoding: .utf8)
    }
}
