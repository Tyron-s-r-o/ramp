import SwiftUI
import AppKit
import RAMPCore

/// Nastavenia (05-06): sidebar section of the main window and the `Settings` scene (⌘,).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    /// `true` inside the `Settings` scene (⌘,) — activates RAMP when the Dock icon is hidden.
    var isSettingsScene = false

    @AppStorage(DockPolicy.hideDockIconKey) private var hideDockIcon = false
    /// nil = no explicit choice → `ProjectOpener` default (PhpStorm when installed).
    @AppStorage(ProjectOpener.optionClickTargetKey) private var storedOptionClickTarget: String?
    @State private var language = AppLanguage.current
    @State private var launchLanguage = AppLanguage.current
    @State private var showLicenses = false

    var body: some View {
        Form {
            generalSection
            ServicesSettingsSection(model: app.settings)
            HelperSettingsSection(model: app.settings)
            TerminalSettingsSection()
            UpdatesSettingsSection()
            AppUpdateSettingsSection()   // 08-03 Sparkle
            ElasticsearchSettingsSection()   // 06-04
            aboutSection
            advancedSection
        }
        .formStyle(.grouped)
        .onAppear {
            app.settings.loginItem.refresh()
            app.settings.load()
            if isSettingsScene { DockPolicy.windowOpened() }
        }
        .onChange(of: app.config) { app.settings.load() }
        .sheet(isPresented: $showLicenses) { LicensesSheet() }
    }

    // MARK: Všeobecné

    private var generalSection: some View {
        let login = app.settings.loginItem
        return Section("Všeobecné") {
            Toggle("Spúšťať pri prihlásení", isOn: Binding(get: { login.isEnabled },
                                                           set: { login.setEnabled($0) }))
            if login.status == .requiresApproval {
                LabeledContent {
                    Button("Otvoriť Nastavenia systému") { login.openSystemSettings() }
                } label: {
                    Text("Čaká na schválenie v Nastaveniach systému › Položky pri prihlásení")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = login.lastError {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Toggle("Skryť ikonu v Docku", isOn: $hideDockIcon)
                .onChange(of: hideDockIcon) { _, hidden in DockPolicy.apply(hidden: hidden) }

            Picker("Jazyk", selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: language) { _, value in AppLanguage.set(value) }
            if language != launchLanguage {
                LabeledContent {
                    Button("Reštartovať teraz") { AppLanguage.relaunch() }
                } label: {
                    Text("Prejaví sa po reštarte RAMP (služby sa zastavia a znovu spustia)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("⌥-klik otvorí", selection: optionClickTarget) {
                Text("Finder").tag(ProjectOpenTarget.finder)
                Text("PhpStorm").tag(ProjectOpenTarget.phpStorm)
                    .selectionDisabled(!app.opener.isPhpStormAvailable)
            }
            if !app.opener.isPhpStormAvailable {
                Text("PhpStorm sa nenašiel — ⌥-klik otvorí Finder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Effective target (stored choice, else default); writing stores an explicit choice.
    private var optionClickTarget: Binding<ProjectOpenTarget> {
        Binding(get: { [storedOptionClickTarget, opener = app.opener] in
                    let stored = storedOptionClickTarget.flatMap(ProjectOpenTarget.init(rawValue:))
                    return stored == .phpStorm && !opener.isPhpStormAvailable ? .finder
                        : stored ?? opener.optionClickTarget
                },
                set: { storedOptionClickTarget = $0.rawValue })
    }

    // MARK: O aplikácii

    private var aboutSection: some View {
        Section("O aplikácii") {
            LabeledContent("Verzia RAMP") { Text(verbatim: Self.appVersion).textSelection(.enabled) }
            LabeledContent("Verzia RAMPCore") { Text(verbatim: RAMPCore.version).textSelection(.enabled) }
            pathRow("Application Support", url: app.paths.root)
            pathRow("Logy", url: app.paths.logs)
            LabeledContent("Licencie tretích strán") {
                Button("Zobraziť…") { showLicenses = true }
                    .disabled(LicensesSheet.url == nil)
            }
        }
    }

    private func pathRow(_ title: LocalizedStringKey, url: URL) -> some View {
        LabeledContent {
            HStack {
                Text(verbatim: url.path(percentEncoded: false))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Zobraziť vo Finderi") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } label: {
            Text(title)
        }
    }

    // MARK: Pokročilé

    private var advancedSection: some View {
        Section("Pokročilé") {
            LabeledContent {
                MAMPImportButton()   // 07-05 wizard window
            } label: {
                Text("Prevezme vhosty, databázy a dáta Elasticsearch z MAMP PRO — najprv náhľad, nič sa nemení bez potvrdenia.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                UninstallMenuButton()   // 07-07 window
            } label: {
                Text("Odstráni RAMP, jeho dáta a logy. Projektové priečinky sa nikdy nemažú.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Služby

/// Ports, default PHP, MySQL root password — draft saved via ConfigStore + applyConfigChanges.
struct ServicesSettingsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section {
            portField("Port Apache", text: $model.draft.apachePort, field: .apachePort)
            Picker("Predvolená PHP verzia", selection: $model.draft.defaultPHP) {
                Text("Najvyššia nainštalovaná").tag(String?.none)
                ForEach(model.phpBranches, id: \.self) { branch in
                    Text(verbatim: "PHP \(branch)").tag(String?.some(branch))
                }
            }
            portField("Port MySQL", text: $model.draft.mysqlPort, field: .mysqlPort)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Odkaz /tmp/mysql.sock na MySQL RAMP", isOn: $model.draft.tmpSocketSymlink)
                Text("Pre klienta mysql a skripty bez --socket/--host. Cudzí súbor na tejto ceste RAMP nikdy neprepíše.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            portField("Port Redis", text: $model.draft.redisPort, field: .redisPort)
            if model.mysqlInitialized {
                LabeledContent("MySQL root heslo") {
                    SecureField(text: .constant(model.draft.rootPassword)) { EmptyView() }
                        .disabled(true)
                        .frame(maxWidth: 200)
                }
                Text("Heslo sa mení v MySQL (phpMyAdmin), RAMP ho len používa")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("MySQL root heslo") {
                    SecureField(text: $model.draft.rootPassword) { EmptyView() }
                        .frame(maxWidth: 200)
                }
                errorText(.rootPassword)
            }
        } header: {
            Text("Služby")
        } footer: {
            HStack {
                if model.savedAt != nil, !model.isDirty {
                    Label("Uložené", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Zrušiť zmeny") { model.revert() }
                    .disabled(!model.isDirty || model.isSaving)
                Button("Uložiť") { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isDirty || model.isSaving)
            }
        }
    }

    private func portField(_ title: LocalizedStringKey, text: Binding<String>, field: SettingsModel.Field)
        -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField(text: text) { EmptyView() }
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
            }
            errorText(field)
        }
    }

    @ViewBuilder private func errorText(_ field: SettingsModel.Field) -> some View {
        if let message = model.errors[field] {
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Licenses

/// THIRD_PARTY_LICENSES.md (08-04), bundled as a resource.
struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    static var url: URL? { Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md") }

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Licencie tretích strán").font(.headline)
                Spacer()
                if let url = Self.url {
                    Button("Otvoriť v editore") { NSWorkspace.shared.open(url) }
                }
                Button("Zavrieť") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                Text(verbatim: text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 600)
        .task {
            guard let url = Self.url else { return }
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
}
