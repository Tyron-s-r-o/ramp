import SwiftUI
import AppKit
import RAMPCore

/// Per-branch PHP detail: OPcache, APCu, Xdebug, extensions, FPM state + the ini editor tab.
struct PHPBranchDetail: View {
    @Environment(AppModel.self) private var app
    let info: PHPBranchInfo

    var body: some View {
        let php = app.php
        @Bindable var bindable = php
        VStack(spacing: 0) {
            // Which branch is being edited — changes visibly when switching versions on the left.
            ZStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(info.fpmState?.isRunning == true ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(verbatim: "PHP \(info.version)")
                        .font(.title3.weight(.semibold))
                        .contentTransition(.numericText())
                        .foregroundStyle(info.enabled ? .primary : .secondary)
                    Spacer()
                    Toggle("Verzia zapnutá", isOn: Binding(
                        get: { info.enabled },
                        set: { php.setBranchEnabled(info.branch, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.callout)
                        .fixedSize()
                        .disabled(php.isBusy(info.branch))
                        .help("Vypnutá verzia nemá bežiace PHP-FPM a nedá sa zvoliť pre vhosty")
                }
                Picker(selection: $bindable.detailTab) {
                    Text("Nastavenia").tag(PHPDetailTab.settings)
                    Text(verbatim: "php.ini").tag(PHPDetailTab.ini)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .animation(.default, value: info.version)

            if let offer = php.offer(info.branch), offer.isEOL {
                Label {
                    if let date = offer.eolDate {
                        Text("PHP \(info.branch) nemá od \(PHPModel.formatDate(date)) podporu — žiadne bezpečnostné opravy.")
                    } else {
                        Text("PHP \(info.branch) nemá podporu — žiadne bezpečnostné opravy.")
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .help("Verzia PHP po skončení podpory (EOL) — používaj ju len pre staré projekty")
            }

            if let error = php.enableErrors[info.branch] {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(verbatim: error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button {
                        php.clearEnableError(info.branch)
                    } label: {
                        Label("Zavrieť", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }

            switch php.detailTab {
            case .settings:
                PHPBranchSettingsForm(info: info)
            case .ini:
                IniEditorView(selection: .branch(info.branch))
            }
        }
        .navigationSubtitle(Text(verbatim: "PHP \(info.version)"))
    }
}

private struct PHPBranchSettingsForm: View {
    @Environment(AppModel.self) private var app
    let info: PHPBranchInfo
    @State private var shmSize = ""
    @State private var shmInvalid = false

    var body: some View {
        let php = app.php
        let b = info.branch
        let busy = php.isBusy(b)
        Form {
            opcache(php, busy: busy)
            apcu(php, busy: busy)
            xdebug(php, busy: busy)
            extensions(php, busy: busy)
            state(php, busy: busy)
            vhostsSection()
        }
        .formStyle(.grouped)
        .onAppear { shmSize = info.settings.apcu.shmSize }
        .onChange(of: info.settings.apcu.shmSize) { _, new in shmSize = new; shmInvalid = false }
        .onChange(of: info.branch) { _, _ in shmSize = info.settings.apcu.shmSize; shmInvalid = false }
    }

    // MARK: Sections

    @ViewBuilder private func opcache(_ php: PHPModel, busy: Bool) -> some View {
        let b = info.branch
        let options = info.settings.opcache
        Section {
            Toggle("OPcache zapnutý", isOn: Binding(
                get: { options.enabled },
                set: { var o = options; o.enabled = $0; php.setOPcache(b, o) }))
            Picker("Profil", selection: Binding(
                get: { options.profile },
                set: { var o = options; o.profile = $0; php.setOPcache(b, o) })) {
                Text("Vývoj").tag(OPcacheOptions.Profile.development)
                Text("Výkon").tag(OPcacheOptions.Profile.performance)
            }
            .disabled(!options.enabled)
            Toggle("JIT", isOn: Binding(
                get: { options.jit || options.profile == .performance },
                set: { var o = options; o.jit = $0; php.setOPcache(b, o) }))
                .disabled(!info.supportsJIT || !options.enabled || options.profile == .performance)
                .help(info.supportsJIT ? Text("Tracing JIT, buffer 128M") : Text("JIT je dostupný až od PHP 8"))
            HStack {
                Spacer()
                Button("Vyčistiť OPcache") { php.clearOPcache(b) }
            }
        } header: {
            Text(verbatim: "OPcache")
        } footer: {
            Text("Výkon = bez kontroly zmien súborov + JIT").foregroundStyle(.secondary)
        }
        .disabled(busy)
    }

    @ViewBuilder private func apcu(_ php: PHPModel, busy: Bool) -> some View {
        let b = info.branch
        let shipped = info.available.contains("apcu")
        Section {
            if shipped {
                LabeledContent("Veľkosť pamäte (shm_size)") {
                    HStack {
                        TextField(text: $shmSize, prompt: Text(verbatim: "128M")) { EmptyView() }
                            .labelsHidden()
                            .frame(width: 90)
                            .onSubmit { shmInvalid = !php.setAPCuSize(b, shmSize) }
                        Button("Použiť") { shmInvalid = !php.setAPCuSize(b, shmSize) }
                            .disabled(shmSize == info.settings.apcu.shmSize)
                    }
                }
                if shmInvalid {
                    Text("Neplatná veľkosť — napr. 128M alebo 1G").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Vyčistiť APCu") { php.clearAPCu(b) }
                        .disabled(!info.enabledExtensions.contains("apcu"))
                }
            } else {
                Text("APCu nie je v balíku").foregroundStyle(.secondary)
            }
        } header: {
            Text(verbatim: "APCu")
        }
        .disabled(busy)
    }

    @ViewBuilder private func xdebug(_ php: PHPModel, busy: Bool) -> some View {
        let b = info.branch
        Section {
            Picker("Režim", selection: Binding(
                get: { info.settings.xdebug },
                set: { php.setXdebug(b, $0) })) {
                Text("Vypnutý").tag(XdebugMode.off)
                Text("Debug").tag(XdebugMode.debug)
                Text("Profile").tag(XdebugMode.profile)
            }
            .pickerStyle(.segmented)
            .disabled(!info.available.contains("xdebug") && info.settings.xdebug == .off)
        } header: {
            Text(verbatim: "Xdebug")
        } footer: {
            Text("Aktivuje sa len s XDEBUG_TRIGGER, PhpStorm port 9003").foregroundStyle(.secondary)
        }
        .disabled(busy)
    }

    @ViewBuilder private func extensions(_ php: PHPModel, busy: Bool) -> some View {
        let b = info.branch
        let entries = PHPExtensionCatalog.entries.filter { $0.kind == .extension }
        Section {
            ForEach(entries, id: \.name) { entry in
                if info.available.contains(entry.name) {
                    Toggle(isOn: Binding(
                        get: { info.enabledExtensions.contains(entry.name) },
                        set: { php.setExtension(b, entry.name, enabled: $0) })) {
                        Text(verbatim: entry.name)
                        if entry.name == "phalcon" {
                            Text("predvolene len 8.2")
                        }
                    }
                } else {
                    LabeledContent {
                        Text("nie je v balíku")
                    } label: {
                        Text(verbatim: entry.name)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Rozšírenia")
        }
        .disabled(busy)
    }

    @ViewBuilder private func state(_ php: PHPModel, busy: Bool) -> some View {
        let b = info.branch
        let socket = php.socketPath(b)
        Section {
            LabeledContent("FPM") {
                HStack(spacing: 6) {
                    StateDot(state: info.fpmState ?? .stopped)
                    Text(info.enabled ? stateText(info.fpmState) : "Vypnutá")
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if let hint = php.hints[b] {
                Text(verbatim: hint).font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Socket") {
                HStack(spacing: 6) {
                    Text(verbatim: socket)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(socket, forType: .string)
                    } label: {
                        Label("Kopírovať", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Kopírovať cestu k socketu")
                }
            }
            LabeledContent("Vhosty") { Text(verbatim: String(info.usedByVhosts)) }
            HStack {
                Spacer()
                Button {
                    php.reload(b)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(busy || !(info.fpmState?.isRunning ?? false))
                .help("Graceful reload len tejto PHP verzie")
            }
        } header: {
            Text("Stav")
        }
    }

    /// Vhosts running on this branch — click opens in the browser; header link jumps to Vhosty filtered.
    @ViewBuilder private func vhostsSection() -> some View {
        let vhostsModel = app.vhosts
        let list = vhostsModel.vhosts.filter { vhostsModel.effectivePHPBranch($0) == info.branch }
        Section {
            if list.isEmpty {
                Text("Túto verziu nepoužíva žiadny vhost").foregroundStyle(.secondary)
            } else {
                ForEach(list) { vhost in
                    HStack {
                        Circle()
                            .fill(vhost.enabled ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Button(vhost.domain) { vhostsModel.openInBrowser(vhost) }
                            .buttonStyle(.link)
                            .help("Otvoriť v prehliadači")
                        if let group = vhost.group {
                            Text(verbatim: group).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: vhostsModel.displayDocroot(vhost.docroot))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } header: {
            HStack {
                Text("Vhosty (\(list.count))")
                Spacer()
                Button("Zobraziť vo Vhostoch") {
                    vhostsModel.phpFilter = info.branch
                    vhostsModel.search = ""
                    app.selection = .vhosts
                }
                .buttonStyle(.link)
                .disabled(list.isEmpty)
            }
        }
    }

    private func stateText(_ state: ServiceState?) -> LocalizedStringKey {
        switch state {
        case .running: "Beží"
        case .starting: "Spúšťa sa"
        case .stopping: "Zastavuje sa"
        case .backingOff: "Reštartuje sa"
        case .failed: "Chyba"
        case .stopped, nil: "Zastavené"
        }
    }
}
