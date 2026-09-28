import SwiftUI
import RAMPCore

/// "Importovať z FileZilla…": reads ~/.config/filezilla/sitemanager.xml, lets the user pick groups, decrypts
/// passwords protected by the FileZilla master password (optional), stores sites + secrets, skips duplicates.
struct FTPImportSheet: View {
    let model: RemoteModel

    private enum Stage {
        case loading
        case failed(String)
        case choose
        case importing
        case done(Summary)
    }

    struct Summary {
        var imported = 0
        var withPassword = 0
        var duplicates = 0
        var withoutPassword = 0
    }

    private struct GroupRow: Identifiable {
        var id: String
        var title: String
        var count: Int
        var encrypted: Int
    }

    @State private var stage: Stage = .loading
    @State private var entries: [FileZillaImporter.Entry] = []
    @State private var selectedGroups: Set<String> = []
    @State private var fzPassword = ""
    @State private var fzError: String?
    @State private var decrypted = false
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import z FileZilly").font(.headline)
                Text(verbatim: (FileZillaImporter.defaultURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer.padding(12)
        }
        .frame(width: 520, height: 520)
        .vaultPromptSheet(model, host: .importer)
        .interactiveDismissDisabled(working)
        .task { load() }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .loading, .importing:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Súbor FileZilly sa nedá načítať", systemImage: "doc.questionmark")
            } description: {
                Text(verbatim: message)
            }
        case .choose:
            chooser
        case .done(let summary):
            VStack(alignment: .leading, spacing: 8) {
                Label("Import dokončený", systemImage: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                Text("Importované prístupy: \(summary.imported)")
                Text("S heslom: \(summary.withPassword)")
                if summary.withoutPassword > 0 {
                    Text("Bez hesla (vypýta sa pri pripojení): \(summary.withoutPassword)")
                }
                if summary.duplicates > 0 {
                    Text("Preskočené duplikáty: \(summary.duplicates)")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private var chooser: some View {
        let groups = groupRows
        let encrypted = selectedEntries.filter { $0.passwordStatus == .encryptedWithMasterPassword }.count
        return VStack(alignment: .leading, spacing: 0) {
            List {
                Section {
                    ForEach(groups) { group in
                        Toggle(isOn: groupBinding(group.id)) {
                            HStack {
                                Text(verbatim: group.title)
                                Spacer()
                                Text(verbatim: "\(group.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    HStack {
                        Text("Skupiny")
                        Spacer()
                        Button("Všetky") { selectedGroups = Set(groups.map(\.id)) }
                            .buttonStyle(.link)
                        Button("Žiadne") { selectedGroups = [] }
                            .buttonStyle(.link)
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                let dupes = duplicateCount
                Text("Vybrané: \(selectedEntries.count) · duplikáty (preskočia sa): \(dupes)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if encrypted > 0 && !decrypted {
                    Text("Heslá (\(encrypted)) sú vo FileZille chránené jej hlavným heslom. Zadajte ho, aby sa preniesli aj heslá.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField("Hlavné heslo FileZilly", text: $fzPassword)
                            .onSubmit { Task { await decrypt() } }
                        Button("Odomknúť") { Task { await decrypt() } }
                            .disabled(fzPassword.isEmpty || working)
                    }
                    if let fzError {
                        Label(fzError, systemImage: "xmark.octagon.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                } else if decrypted {
                    Label("Heslá z FileZilly sú odomknuté.", systemImage: "lock.open.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            switch stage {
            case .done:
                Button("Hotovo") { close() }
                    .keyboardShortcut(.defaultAction)
            case .choose:
                Button("Zrušiť") { close() }
                    .keyboardShortcut(.cancelAction)
                let encrypted = selectedEntries.contains { $0.passwordStatus == .encryptedWithMasterPassword }
                if encrypted && !decrypted {
                    Button("Importovať bez hesiel") { Task { await runImport() } }
                        .disabled(importable.isEmpty || working)
                }
                Button("Importovať") { Task { await runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importable.isEmpty || working || (encrypted && !decrypted))
            default:
                Button("Zavrieť") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
            }
        }
    }

    // MARK: Data

    private var groupRows: [GroupRow] {
        let byGroup = Dictionary(grouping: entries) { $0.site.group ?? "" }
        return byGroup.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { key in
            let items = byGroup[key] ?? []
            return GroupRow(id: key, title: key.isEmpty ? String(localized: "Bez skupiny") : key, count: items.count,
                            encrypted: items.filter { $0.passwordStatus == .encryptedWithMasterPassword }.count)
        }
    }

    private var selectedEntries: [FileZillaImporter.Entry] {
        entries.filter { selectedGroups.contains($0.site.group ?? "") }
    }

    private var existingKeys: Set<String> { Set(model.sites.map(RemoteModel.duplicateKey)) }

    private var duplicateCount: Int {
        let existing = existingKeys
        return selectedEntries.filter { existing.contains(RemoteModel.duplicateKey($0.site)) }.count
    }

    /// Selected entries minus duplicates (also duplicates inside the file itself).
    private var importable: [FileZillaImporter.Entry] {
        var seen = existingKeys
        return selectedEntries.filter { seen.insert(RemoteModel.duplicateKey($0.site)).inserted }
    }

    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedGroups.contains(id) },
                set: { if $0 { selectedGroups.insert(id) } else { selectedGroups.remove(id) } })
    }

    // MARK: Actions

    private func load() {
        #if DEBUG
        if ScreenshotMode.isRendering { stage = .failed("demo"); return }
        #endif
        do {
            entries = try FileZillaImporter.load()
            selectedGroups = Set(entries.map { $0.site.group ?? "" })
            stage = entries.isEmpty ? .failed(String(localized: "V súbore nie sú žiadne prístupy.")) : .choose
        } catch {
            stage = .failed(RemoteModel.describe(error))
        }
    }

    private func decrypt() async {
        guard !fzPassword.isEmpty, !working else { return }
        working = true
        defer { working = false }
        let current = entries
        let password = fzPassword
        do {
            entries = try await Task.detached(priority: .userInitiated) {
                try FileZillaImporter.decryptPasswords(current, masterPassword: password)
            }.value
            decrypted = true
            fzError = nil
        } catch {
            fzError = RemoteModel.describe(error)
        }
    }

    private func runImport() async {
        let chosen = importable
        guard !chosen.isEmpty else { return }
        working = true
        defer { working = false }
        let hasSecrets = chosen.contains { !($0.secrets?.password ?? "").isEmpty || !($0.secrets?.keyPassphrase ?? "").isEmpty }
        var storeSecrets = false
        if hasSecrets {
            storeSecrets = await model.ensureUnlocked(reason: String(localized: "Importované heslá sa uložia zašifrované."))
        }
        stage = .importing
        var summary = Summary()
        summary.duplicates = selectedEntries.count - chosen.count
        do {
            _ = try await model.add(imported: chosen.map { ($0.site, $0.secrets) }, withSecrets: storeSecrets)
            summary.imported = chosen.count
            summary.withPassword = storeSecrets ? chosen.filter { !($0.secrets?.password ?? "").isEmpty }.count : 0
            summary.withoutPassword = max(0, chosen.filter { $0.site.auth == .password && !RemoteModel.isAnonymous($0.site) }.count
                - summary.withPassword)
            stage = .done(summary)
        } catch {
            stage = .failed(RemoteModel.describe(error))
        }
    }

    private func close() {
        model.importing = false
        dismiss()
    }
}
