import SwiftUI
import RAMPCore

/// Vhosty a /etc/hosts (05-06): default TLD, manage toggle (part of the SettingsModel draft), hosts helper
/// status + approval (same logic as the 05-02 banner) and a manual sync.
struct HelperSettingsSection: View {
    @Bindable var model: SettingsModel
    @Environment(AppModel.self) private var app
    @State private var syncing = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Predvolená TLD") {
                    TextField(text: $model.draft.tld, prompt: Text(verbatim: "local")) { EmptyView() }
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
                if let message = model.errors[.tld] {
                    Text(verbatim: message).font(.callout).foregroundStyle(.red)
                }
            }
            Toggle("Spravovať /etc/hosts", isOn: $model.draft.manageHostsFile)
            if model.draft.manageHostsFile != model.loaded.manageHostsFile {
                Text("Zmena sa prejaví po uložení (tlačidlo Uložiť v sekcii Služby)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Pomocník pre /etc/hosts") {
                HStack {
                    Text(verbatim: app.hostsHelper.statusText)
                        .foregroundStyle(app.hostsHelper.status == .enabled ? Color.secondary : Color.orange)
                    if app.config.hosts.manageHostsFile, app.hostsHelper.status != .enabled {
                        Button("Povoliť pomocníka…") { Task { await app.vhosts.approveHelper() } }
                    }
                }
            }
            if app.config.hosts.manageHostsFile, app.hostsHelper.status != .enabled {
                Text("Bez pomocníka sa zmeny /etc/hosts zapisujú cez výzvu na heslo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                HStack {
                    if syncing { ProgressView().controlSize(.small) }
                    Button("Synchronizovať /etc/hosts teraz") {
                        syncing = true
                        Task {
                            await app.syncHosts()
                            syncing = false
                        }
                    }
                    .disabled(syncing || !app.config.hosts.manageHostsFile)
                }
            } label: {
                Text(syncStateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Vhosty a /etc/hosts")
        }
        .task { await app.hostsHelper.refreshStatus() }
    }

    private var syncStateText: String {
        switch app.hostsHelper.lastSync {
        case .none: String(localized: "Stav synchronizácie neznámy")
        case .notManaged: String(localized: "RAMP nespravuje /etc/hosts")
        case .synced: String(localized: "/etc/hosts je aktuálny")
        case .pending: String(localized: "/etc/hosts nie je aktuálny")
        }
    }
}
