import SwiftUI
import RAMPCore

extension IniDirective: @retroactive Identifiable {
    public var id: String { key }
}

/// Effective php.ini of a branch (or the base + global layer for "Globálne") with provenance, filter and
/// override edit / reset / add. Protected keys are read-only (managed by the dedicated controls).
struct IniEditorView: View {
    @Environment(AppModel.self) private var app
    let selection: PHPSelection

    @State private var filter = ""
    @State private var sheet: IniOverrideSheet.Mode?
    @State private var pendingGlobalReset: String?

    private var branch: String? {
        if case .branch(let b) = selection { return b }
        return nil
    }

    var body: some View {
        let php = app.php
        let key = PHPModel.iniKey(selection)
        let rows = (php.iniCache[key] ?? []).filter {
            filter.isEmpty || $0.key.localizedCaseInsensitiveContains(filter)
                || $0.value.localizedCaseInsensitiveContains(filter)
        }
        let busy = branch.map(php.isBusy) ?? php.isGlobalBusy
        VStack(spacing: 0) {
            HStack {
                TextField(text: $filter, prompt: Text("Filtrovať direktívy")) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button {
                    sheet = .add
                } label: {
                    Label("Pridať direktívu", systemImage: "plus")
                }
                .disabled(busy)
            }
            .padding(10)

            if let error = php.iniErrors[key] {
                Text(verbatim: error)
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
            }

            Table(rows) {
                TableColumn("Direktíva") { row in
                    HStack(spacing: 4) {
                        if PHPIniLayers.isProtected(row.key) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .help("Spravuje RAMP — použi prepínače OPcache/APCu/Xdebug/Rozšírenia")
                        }
                        Text(verbatim: row.key).font(.body.monospaced())
                    }
                }
                TableColumn("Hodnota") { row in
                    Text(verbatim: row.value).font(.body.monospaced()).textSelection(.enabled)
                }
                TableColumn("Zdroj") { row in
                    SourceBadge(source: row.source)
                }
                .width(min: 90, ideal: 110, max: 140)
                TableColumn(Text(verbatim: "")) { row in
                    actions(row, busy: busy)
                }
                .width(min: 60, ideal: 64, max: 80)
            }
        }
        .task(id: key) { await php.loadIni(selection) }
        .sheet(item: $sheet) { mode in
            IniOverrideSheet(mode: mode, branch: branch)
        }
        .confirmationDialog(Text("Obnoviť globálnu direktívu?"), isPresented: Binding(
            get: { pendingGlobalReset != nil },
            set: { if !$0 { pendingGlobalReset = nil } })) {
            Button("Obnoviť a znovu načítať", role: .destructive) {
                guard let key = pendingGlobalReset else { return }
                Task { try? await php.setIniOverride(scope: .global, key: key, value: nil) }
            }
        } message: {
            Text("Znovu načíta všetky PHP verzie")
        }
    }

    @ViewBuilder private func actions(_ row: IniDirective, busy: Bool) -> some View {
        let locked = PHPIniLayers.isProtected(row.key)
        HStack(spacing: 6) {
            Button {
                sheet = .edit(key: row.key, value: row.value,
                              scope: branch != nil && row.source != .global ? .branch : .global)
            } label: {
                Label("Upraviť", systemImage: "pencil")
            }
            .help("Upraviť")
            Button {
                reset(row)
            } label: {
                Label("Obnoviť", systemImage: "arrow.uturn.backward")
            }
            .help("Obnoviť")
            .disabled(!canReset(row))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(busy || locked)
    }

    private func canReset(_ row: IniDirective) -> Bool {
        switch row.source {
        case .base: false
        case .global: true
        case .branch: branch != nil
        }
    }

    private func reset(_ row: IniDirective) {
        switch row.source {
        case .base:
            return
        case .global:
            pendingGlobalReset = row.key
        case .branch:
            guard let branch else { return }
            let php = app.php
            Task { try? await php.setIniOverride(scope: .branch(branch), key: row.key, value: nil) }
        }
    }
}

private struct SourceBadge: View {
    let source: IniDirective.Source

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.2), in: .capsule)
    }

    private var title: LocalizedStringKey {
        switch source {
        case .base: "RAMP základ"
        case .global: "Globálne"
        case .branch: "Táto verzia"
        }
    }

    private var color: Color {
        switch source {
        case .base: .gray
        case .global: .blue
        case .branch: .purple
        }
    }
}
