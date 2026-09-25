import SwiftUI
import RAMPCore

/// PHP section: branch list (+ "Globálne" ini entry) and the selected branch detail.
struct PHPView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let php = app.php
        @Bindable var bindable = php
        // HStack, not HSplitView (see LogsView).
        HStack(spacing: 0) {
            List(selection: $bindable.selection) {
                Label("Globálne", systemImage: "globe")
                    .tag(PHPSelection.global)
                    .help("php.ini direktívy pre všetky PHP verzie")
                Section("Verzie") {
                    ForEach(php.branches) { info in
                        PHPBranchRow(info: info)
                            .tag(PHPSelection.branch(info.branch))
                            .contextMenu {
                                Button("Odinštalovať verziu…", role: .destructive) { php.requestUninstall(info.branch) }
                                    .disabled(php.isBusy(info.branch))
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        php.showVersionsSheet = true
                    } label: {
                        Label("Pridať verziu PHP…", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .help("Inštalácia a odinštalovanie PHP verzií")
                }
            }
            .frame(width: 220)

            Divider()

            VStack(spacing: 0) {
                if let status = php.status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(.green.opacity(0.08))
                        .transition(.opacity)
                }
                detail(php)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.default, value: php.status)
            .frame(minWidth: 460, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationTitle(Text(verbatim: "PHP"))
        .task {
            await php.refresh()
            await php.loadOffers()
        }
        .sheet(isPresented: $bindable.showVersionsSheet) {
            PHPVersionsSheet().environment(app)
        }
        .uninstallAlert(php, presented: !php.showVersionsSheet)
    }

    @ViewBuilder private func detail(_ php: PHPModel) -> some View {
        switch php.selection {
        case .global:
            IniEditorView(selection: .global)
        case .branch(let b):
            if let info = php.info(b) {
                PHPBranchDetail(info: info)
            } else {
                ContentUnavailableView("PHP \(b) nie je nainštalované", systemImage: "questionmark.circle")
            }
        case nil:
            ContentUnavailableView {
                Label("Žiadna PHP verzia", systemImage: "chevron.left.forwardslash.chevron.right")
            } description: {
                Text("Zatiaľ nie je nainštalovaná žiadna PHP verzia.")
            }
        }
    }
}

private struct PHPBranchRow: View {
    let info: PHPBranchInfo

    var body: some View {
        HStack(spacing: 8) {
            // Green = FPM running; stopped / disabled branch (no FPM service) → gray.
            StateDot(state: info.fpmState ?? .stopped)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "PHP \(info.branch)").font(.headline)
                if info.enabled {
                    Text(verbatim: info.version).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(info.version) · vypnutá").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if info.settings.xdebug != .off {
                Text(verbatim: "Xdebug").font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .background(.orange.opacity(0.25), in: .capsule)
            }
            if info.usedByVhosts > 0 {
                Text(verbatim: String(info.usedByVhosts))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(Text("Počet vhostov: \(info.usedByVhosts)"))
            }
        }
        .opacity(info.enabled ? 1 : 0.5)
    }
}

// MARK: - Versions sheet (install / uninstall branches)

/// "Pridať verziu PHP…": every manifest PHP branch with size, support phase and install state; Install per row
/// (with progress), Uninstall for installed rows when the guards allow it (else the reason).
struct PHPVersionsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let php = app.php
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Verzie PHP").font(.title2.bold())
                Text("Nainštalovaná verzia sa hneď zapne a spustí sa jej PHP-FPM.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            Group {
                if php.offers.isEmpty && php.offersLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if php.offers.isEmpty, let error = php.offersError {
                    VStack(spacing: 10) {
                        Label { Text(verbatim: error).textSelection(.enabled) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Button("Skúsiť znova") { Task { await php.loadOffers(force: true) } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(php.offers) { offer in
                        PHPOfferRow(offer: offer)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 320)
            Divider()
            HStack {
                if php.offersLoading && !php.offers.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                Button("Hotovo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 520)
        .task { await php.loadOffers() }
        .uninstallAlert(php, presented: true)
    }
}

private struct PHPOfferRow: View {
    @Environment(AppModel.self) private var app
    let offer: PHPBranchOffer

    var body: some View {
        let php = app.php
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "PHP \(offer.branch)").font(.headline)
                Text(verbatim: sizeLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)
            PHPSupportBadge(support: offer.support, eolDate: offer.eolDate)
            Spacer(minLength: 8)
            trailing(php)
        }
        .padding(.vertical, 4)
    }

    private var sizeLine: String {
        let version = offer.installedVersion ?? offer.version
        guard let size = offer.size, offer.installedVersion == nil else { return version }
        return "\(version) · \(DownloadProgress.bytes(size))"
    }

    @ViewBuilder private func trailing(_ php: PHPModel) -> some View {
        if let progress = php.installing[offer.branch] {
            PackageProgressView(stage: progress.stage, download: progress.download)
                .frame(width: 240)
        } else if offer.isInstalled {
            HStack(spacing: 8) {
                Label("Nainštalovaná", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                if let blocker = offer.uninstallBlocker {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help(Text(verbatim: PHPModel.uninstallMessage(blocker)))
                } else {
                    Button("Odinštalovať…", role: .destructive) { php.requestUninstall(offer.branch) }
                        .disabled(php.isBusy(offer.branch))
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Inštalovať") { php.install(offer.branch) }
                if let error = php.installErrors[offer.branch] {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 240, alignment: .trailing)
                        .help(Text(verbatim: error))
                }
            }
        }
    }
}

/// "Aktívna podpora" / "Len bezpečnostné opravy" / "Bez podpory (EOL)" + date.
struct PHPSupportBadge: View {
    let support: PHPSupportStatus?
    let eolDate: String?

    var body: some View {
        if let support {
            VStack(alignment: .leading, spacing: 1) {
                Text(title(support))
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(color(support).opacity(0.18), in: .capsule)
                    .foregroundStyle(color(support))
                if let eolDate {
                    dateLine(support, PHPModel.formatDate(eolDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func title(_ support: PHPSupportStatus) -> LocalizedStringKey {
        switch support {
        case .active: "Aktívna podpora"
        case .security: "Len bezpečnostné opravy"
        case .eol: "Bez podpory (EOL)"
        }
    }

    private func dateLine(_ support: PHPSupportStatus, _ date: String) -> Text {
        switch support {
        case .active, .security: Text("bezpečnostné opravy do \(date)")
        case .eol: Text("od \(date)")
        }
    }

    private func color(_ support: PHPSupportStatus) -> Color {
        switch support {
        case .active: .green
        case .security: .orange
        case .eol: .red
        }
    }
}

private extension View {
    /// "Odinštalovať verziu…" confirmation (or refusal reason) driven by `PHPModel.uninstallRequest`.
    func uninstallAlert(_ php: PHPModel, presented: Bool) -> some View {
        alert(uninstallTitle(php.uninstallRequest),
              isPresented: Binding(get: { presented && php.uninstallRequest != nil },
                                   set: { if !$0 { php.uninstallRequest = nil } }),
              presenting: php.uninstallRequest) { request in
            if request.refusal == nil {
                Button("Odinštalovať", role: .destructive) { php.confirmUninstall() }
                Button("Zrušiť", role: .cancel) { php.uninstallRequest = nil }
            } else {
                Button("OK", role: .cancel) { php.uninstallRequest = nil }
            }
        } message: { request in
            if let refusal = request.refusal {
                Text(verbatim: refusal)
            } else {
                Text("Zmaže sa PHP \(request.version), jeho nastavenia (php.ini, rozšírenia, Xdebug) a logy. Neskôr ho môžeš nainštalovať znova.")
            }
        }
    }

    private func uninstallTitle(_ request: PHPUninstallRequest?) -> Text {
        guard let request else { return Text(verbatim: "") }
        return request.refusal == nil ? Text("Odinštalovať PHP \(request.branch)?")
            : Text("PHP \(request.branch) sa nedá odinštalovať")
    }
}
