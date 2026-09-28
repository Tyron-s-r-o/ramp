import SwiftUI
import RAMPCore

/// FTP section: saved FTP/FTPS/SFTP sites on the left (visible without the master password), the browser of the
/// connected site on the right. Plain HStack with explicit widths (no HSplitView — it broke the window layout).
struct FTPView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var searchFocused: Bool

    var body: some View {
        let model = app.remote
        @Bindable var bindable = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FTPSiteList(model: model)
                    .frame(maxHeight: .infinity)
                Divider()
                // Finder-style bottom bar: add lives with the list (import is in File › Importovať z FileZilla…).
                HStack {
                    Button { model.startAdd() } label: {
                        Label("Pridať nový", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .frame(height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("Pridať prístup")
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
            }
            .frame(width: 260)
            Divider()
            detail(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.18), in: .capsule)
                    .overlay(Capsule().strokeBorder(.green.opacity(0.35)))
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.notice)
        .searchable(text: $bindable.search, placement: .toolbar, prompt: Text("Hľadať FTP"))
        .searchFocused($searchFocused)
        .background {
            Button("Hľadať prístupy") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .toolbar { toolbar(model) }
        .sheet(item: $bindable.editor) { draft in
            FTPSiteEditorSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $bindable.importing) {
            FTPImportSheet(model: model)
        }
        .vaultPromptSheet(model, host: .main)
        .sheet(item: secretPromptBinding(model)) { prompt in
            FTPSecretPromptSheet(model: model, prompt: prompt)
        }
        .confirmationDialog(deleteTitle(model), isPresented: deleteBinding(model), titleVisibility: .visible,
                            presenting: model.pendingDelete) { site in
            Button("Zmazať", role: .destructive) { Task { await model.delete(site) } }
            Button("Zrušiť", role: .cancel) {}
        } message: { _ in
            Text("Odstráni sa aj uložené heslo k tomuto prístupu.")
        }
        .confirmationDialog("Prebiehajú prenosy", isPresented: switchBinding(model), titleVisibility: .visible,
                            presenting: model.pendingSwitch) { site in
            Button("Zrušiť prenosy a pripojiť", role: .destructive) { Task { await model.connectNow(site) } }
            Button("Zostať pripojený", role: .cancel) {}
        } message: { _ in
            Text("Pripojenie k inému prístupu zruší prebiehajúce prenosy.")
        }
        .hostKeyAlerts(model)
        .task { model.onAppear() }
    }

    @ViewBuilder
    private func detail(_ model: RemoteModel) -> some View {
        if let browser = model.browser, model.selectedSiteID == nil || model.selectedSiteID == browser.site.id {
            FTPBrowserView(model: model, browser: browser)
                .id(ObjectIdentifier(browser))
        } else if let site = model.selectedSite {
            FTPSiteSummary(model: model, site: site)
        } else if model.sites.isEmpty {
            ContentUnavailableView {
                Label("Žiadne FTP prístupy", systemImage: "externaldrive.connected.to.line.below")
            } description: {
                Text("Pridajte FTP, FTPS alebo SFTP prístup, alebo si ich prevezmite z FileZilly.")
            } actions: {
                Button("Pridať prístup") { model.startAdd() }
                    .buttonStyle(.borderedProminent)
                Button("Importovať z FileZilla…") { model.importing = true }
            }
        } else {
            ContentUnavailableView {
                Label("Vyberte prístup", systemImage: "externaldrive.connected.to.line.below")
            } description: {
                Text("Dvojklikom na prístup sa pripojíte.")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: RemoteModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.vaultUnlocked {
                Button { model.lockVault() } label: {
                    Label("Zamknúť", systemImage: "lock.open")
                }
                .help("Zamknúť trezor s heslami (pri ďalšom použití sa znova vypýta hlavné heslo)")
            }
        }
    }

    private func deleteTitle(_ model: RemoteModel) -> Text {
        if let site = model.pendingDelete { Text("Zmazať prístup \(site.name)?") } else { Text("Zmazať prístup?") }
    }

    private func deleteBinding(_ model: RemoteModel) -> Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }

    private func switchBinding(_ model: RemoteModel) -> Binding<Bool> {
        Binding(get: { model.pendingSwitch != nil }, set: { if !$0 { model.pendingSwitch = nil } })
    }

    private func secretPromptBinding(_ model: RemoteModel) -> Binding<SecretPrompt?> {
        Binding(get: { model.secretPrompt }, set: { if $0 == nil, model.secretPrompt != nil { model.finishSecretPrompt(nil) } })
    }
}

// MARK: - Site list

/// Grouped, collapsible list of saved sites. Double-click = connect.
struct FTPSiteList: View {
    let model: RemoteModel
    @State private var renamingGroup: GroupRename?

    var body: some View {
        @Bindable var bindable = model
        Group {
            if model.sites.isEmpty {
                ContentUnavailableView("Žiadne prístupy", systemImage: "externaldrive")   // add: + below the list
            } else if model.filtered.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                List(selection: $bindable.selectedSiteID) {
                    if model.hasGroups {
                        ForEach(model.filteredSections) { section in
                            let expanded = model.isExpanded(section)
                            Section {
                                if expanded {
                                    ForEach(section.sites) { FTPSiteRow(site: $0, model: model) }
                                }
                            } header: {
                                FTPGroupHeader(section: section, expanded: expanded) { model.toggleExpanded(section) }
                                    .contextMenu {
                                        GroupHeaderMenu(group: section.group, expanded: expanded,
                                                        addTitle: "Pridať prístup do skupiny",
                                                        add: { model.startAdd(inGroup: section.group) },
                                                        rename: { if let g = section.group { renamingGroup = GroupRename(g) } },
                                                        ungroup: { if let g = section.group { model.ungroup(g) } },
                                                        toggle: { model.toggleExpanded(section) })
                                    }
                            }
                        }
                    } else {
                        ForEach(model.filtered) { FTPSiteRow(site: $0, model: model) }
                    }
                }
                .listStyle(.sidebar)
                .groupRenameAlert($renamingGroup) { old, new in model.renameGroup(old, to: new) }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first, let site = model.site(id: id) {
                        Button { model.connect(site) } label: { Label("Pripojiť", systemImage: "bolt.horizontal") }
                        Divider()
                        Button { model.startEdit(site) } label: { Label("Upraviť…", systemImage: "pencil") }
                        Button { Task { await model.duplicate(site) } } label: {
                            Label("Duplikovať", systemImage: "plus.square.on.square")
                        }
                        Divider()
                        Button(role: .destructive) { model.pendingDelete = site } label: {
                            Label("Zmazať…", systemImage: "trash")
                        }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first, let site = model.site(id: id) { model.connect(site) }
                }
            }
        }
    }
}

struct FTPGroupHeader: View {
    let section: RemoteSiteSection
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                // Same weight as the vhost group headers — the default sidebar section style was barely readable.
                Group {
                    if let group = section.group {
                        Text(verbatim: group)
                    } else {
                        Text("Bez skupiny")
                    }
                }
                .font(.headline)
                .foregroundStyle(.primary)
                Text(verbatim: "\(section.sites.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)   // breathing room between the group title and its first site
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FTPSiteRow: View {
    let site: RemoteSite
    let model: RemoteModel

    var body: some View {
        let connected = model.browser?.site.id == site.id
        HStack(spacing: 8) {
            FTPProtocolBadge(proto: site.proto)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: site.name)
                    .lineLimit(1)
                Text(verbatim: FTPProtocolStyle.address(site))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if connected {
                Circle()
                    .fill(model.browser?.state == .connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text("Pripojené"))
            }
        }
        .tag(site.id)
    }
}

/// Selected (not connected) site: details + "Pripojiť".
struct FTPSiteSummary: View {
    let model: RemoteModel
    let site: RemoteSite

    var body: some View {
        VStack(spacing: 14) {
            FTPProtocolBadge(proto: site.proto, large: true)
            Text(verbatim: site.name).font(.title2.weight(.semibold))
            Text(verbatim: FTPProtocolStyle.address(site))   // protocol is in the badge
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let notes = site.notes {
                Text(verbatim: notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: 420)
            }
            HStack {
                Button("Upraviť…") { model.startEdit(site) }
                Button("Pripojiť") { model.connect(site) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            if let browser = model.browser {
                Button("Späť na pripojený prístup \(browser.site.name)") { model.selectedSiteID = browser.site.id }
                    .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Protocol as a small text tag (FTP / FTPES / FTPS / SFTP) — the SF Symbols we had (lock, terminal…) said
/// nothing and looked unrelated. Unencrypted plain FTP is orange, encrypted protocols neutral.
struct FTPProtocolBadge: View {
    let proto: RemoteProtocol
    var large = false

    var body: some View {
        let tint: Color = proto == .ftp ? .orange : .secondary
        Text(verbatim: FTPProtocolStyle.label(proto))
            .font(.system(size: large ? 15 : 9, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, large ? 9 : 4)
            .padding(.vertical, large ? 4 : 2)
            .frame(minWidth: large ? nil : 38)
            .background(tint.opacity(0.15), in: .rect(cornerRadius: large ? 6 : 4))
            .overlay(RoundedRectangle(cornerRadius: large ? 6 : 4).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
            .help(proto == .ftp ? Text("FTP – nešifrované") : Text(verbatim: FTPProtocolStyle.label(proto)))
            .accessibilityLabel(Text(verbatim: FTPProtocolStyle.label(proto)))
    }
}

enum FTPProtocolStyle {

    static func label(_ proto: RemoteProtocol) -> String {
        switch proto {
        case .ftp: "FTP"
        case .ftpes: "FTPES"
        case .ftps: "FTPS"
        case .sftp: "SFTP"
        }
    }

    static func address(_ site: RemoteSite) -> String {
        let user = site.username.isEmpty ? "" : site.username + "@"
        let port = site.port == site.proto.defaultPort ? "" : ":\(site.port)"
        return user + site.host + port
    }
}

// MARK: - Host key alerts

private struct HostKeyAlerts: ViewModifier {
    let model: RemoteModel

    func body(content: Content) -> some View {
        content
            .alert(Text("Neznámy kľúč servera"), isPresented: binding(mismatch: false), presenting: model.hostKeyPrompt) { prompt in
                Button("Dôverovať a pripojiť") { model.trustHostKey(prompt) }
                Button("Zrušiť", role: .cancel) { model.hostKeyPrompt = nil }
            } message: { prompt in
                if case .unknownHostKey(let host, let port, let fingerprint) = prompt.error {
                    Text("Server \(host):\(String(port)) sa ešte nepoužil. Overte odtlačok jeho kľúča (napr. u poskytovateľa hostingu):\n\n\(fingerprint)")
                }
            }
            .alert(Text("POZOR: Kľúč servera sa zmenil!"), isPresented: binding(mismatch: true), presenting: model.hostKeyPrompt) { prompt in
                Button("Zrušiť", role: .cancel) { model.hostKeyPrompt = nil }
                    .keyboardShortcut(.defaultAction)
                Button("Zabudnúť starý kľúč", role: .destructive) { model.forgetHostKey(prompt) }
            } message: { prompt in
                if case .hostKeyMismatch(let host, let port, let expected, let actual) = prompt.error {
                    Text("Server \(host):\(String(port)) sa preukázal iným kľúčom, než aký RAMP pozná. Môže ísť o útok (niekto sa vydáva za server) alebo o preinštalovaný server. Nepripájajte sa, kým zmenu neoveríte.\n\nZnámy: \(expected)\nTeraz: \(actual)")
                }
            }
    }

    private func binding(mismatch: Bool) -> Binding<Bool> {
        Binding(get: { model.hostKeyPrompt.map { $0.isMismatch == mismatch } ?? false },
                set: { if !$0, model.hostKeyPrompt?.isMismatch == mismatch { model.hostKeyPrompt = nil } })
    }
}

extension View {
    fileprivate func hostKeyAlerts(_ model: RemoteModel) -> some View { modifier(HostKeyAlerts(model: model)) }
}
