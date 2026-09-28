import SwiftUI
import RAMPCore

/// Presents the master-password sheet on the view that matches `host` (a sheet can only be shown from the
/// topmost window / sheet: main window, the site editor or the import sheet).
private struct VaultPromptModifier: ViewModifier {
    let model: RemoteModel
    let host: VaultPromptHost

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { model.vaultPrompt?.host == host },
            set: { if !$0, model.vaultPrompt?.host == host { model.finishVaultPrompt(false) } })) {
            if let prompt = model.vaultPrompt {
                FTPVaultSheet(model: model, prompt: prompt)
            }
        }
    }
}

extension View {
    func vaultPromptSheet(_ model: RemoteModel, host: VaultPromptHost) -> some View {
        modifier(VaultPromptModifier(model: model, host: host))
    }
}

/// First use: choose a master password (twice, cannot be recovered). Later: unlock; "Zabudnuté heslo" resets
/// the vault (all stored passwords are deleted) after a confirmation.
struct FTPVaultSheet: View {
    let model: RemoteModel
    let prompt: VaultPrompt
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false
    @State private var confirmReset = false
    @FocusState private var focused: Bool

    private var isSetup: Bool { prompt.kind == .setup }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSetup ? "lock.shield" : "lock")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isSetup ? "Nastavte hlavné heslo" : "Odomknite trezor s heslami")
                        .font(.headline)
                    Text(verbatim: prompt.reason)
                        .foregroundStyle(.secondary)
                    if isSetup {
                        Text("Heslá k FTP prístupom sa ukladajú zašifrované týmto heslom. RAMP si ho vypýta raz za spustenie, keď ho prvý raz potrebuje.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Form {
                SecureField("Hlavné heslo", text: $password)
                    .focused($focused)
                if isSetup {
                    SecureField("Heslo znova", text: $confirm)
                }
            }
            .formStyle(.columns)
            .disabled(working)

            if isSetup {
                Label("Hlavné heslo sa nedá obnoviť. Ak ho zabudnete, uložené heslá k prístupom sa stratia.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if !isSetup {
                    Button("Zabudnuté heslo…") { confirmReset = true }
                        .buttonStyle(.link)
                        .disabled(working)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Zrušiť") { model.finishVaultPrompt(false) }
                    .keyboardShortcut(.cancelAction)
                Button(isSetup ? "Nastaviť" : "Odomknúť") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
        .onChange(of: prompt.kind) {
            password = ""
            confirm = ""
            error = nil
        }
        .confirmationDialog("Zmazať všetky uložené heslá?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Zmazať heslá a nastaviť nové hlavné heslo", role: .destructive) {
                do {
                    try model.resetVault()
                } catch {
                    self.error = RemoteModel.describe(error)
                }
            }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Hlavné heslo sa nedá obnoviť. Zmažú sa všetky uložené heslá k FTP prístupom (samotné prístupy zostanú) a nastavíte nové hlavné heslo.")
        }
        .interactiveDismissDisabled(working)
    }

    private var canSubmit: Bool {
        !working && !password.isEmpty && (!isSetup || password == confirm)
    }

    private func submit() async {
        guard canSubmit else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            if isSetup {
                try await model.setupVault(password: password)
            } else {
                try await model.unlockVault(password: password)
            }
            model.finishVaultPrompt(true)
        } catch {
            self.error = RemoteModel.describe(error)
            password = ""
            confirm = ""
            focused = true
        }
    }
}

/// Password / key passphrase for one connection when none is stored (or the stored one was rejected).
struct FTPSecretPromptSheet: View {
    let model: RemoteModel
    let prompt: SecretPrompt
    @State private var value = ""
    @State private var save = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.field == .password ? "Heslo pre \(prompt.site.name)" : "Passphrase ku kľúču pre \(prompt.site.name)")
                    .font(.headline)
                Text(verbatim: FTPProtocolStyle.label(prompt.site.proto) + " · " + FTPProtocolStyle.address(prompt.site))
                    .foregroundStyle(.secondary)
            }
            SecureField(prompt.field == .password ? "Heslo" : "Passphrase", text: $value)
                .focused($focused)
            if prompt.canSave {
                Toggle("Uložiť do trezora (zašifrované hlavným heslom)", isOn: $save)
            }
            HStack {
                Spacer()
                Button("Zrušiť") { model.finishSecretPrompt(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Pripojiť") { model.finishSecretPrompt(SecretPromptResult(value: value, save: save && prompt.canSave)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}
