import SwiftUI
import RAMPCore

/// Služby: one toggle row per supervised service (ServicesModel rows). Disabled PHP branches are hidden.
/// Optional services (Elasticsearch, Phase 6) are rendered after a divider — extension point for the
/// remaining-time display.
struct MenuServicesSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let services = app.services
        let rows = visibleRows
        let core = rows.filter { !ServicesModel.optionalServices.contains($0.id) }
        let optional = rows.filter { ServicesModel.optionalServices.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            MenuSectionTitle("Služby")
            // PHP-FPM branches collapse into one row (like the Služby section); the rest stay one per service.
            let php = core.filter(\.isPHPFPM)
            if !php.isEmpty { MenuPHPGroupRow(rows: php) }
            ForEach(core.filter { !$0.isPHPFPM }) { MenuServiceRow(row: $0) }
            if !optional.isEmpty {
                Divider()
                ForEach(optional) { MenuServiceRow(row: $0) }
            }
            HStack(spacing: 6) {
                Button("Spustiť všetko") { Task { await services.startAll() } }
                    .disabled(services.isBusyAll || services.health.level == .allRunning)
                Button("Zastaviť všetko") { Task { await services.stopAll() } }
                    .disabled(services.isBusyAll || services.health.level == .stopped)
                Button("Reštart Apache") { Task { await services.restartApache() } }
                    .disabled(!(rows.first { $0.id == .apache }?.state.isRunning ?? false))
                    .help("Reštart Apache (graceful)")
                if services.isBusyAll { ProgressView().controlSize(.mini) }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    private var visibleRows: [ServiceRowState] {
        let branches = app.config.php.branches
        return app.services.rows.filter { row in
            if case .phpFPM(let b) = row.id { return branches[b]?.enabled ?? true }
            return true
        }
    }
}

private extension ServiceRowState {
    var isPHPFPM: Bool { if case .phpFPM = id { true } else { false } }
}

/// "PHP-FPM · 7.4 · 8.2 …" with one switch for all branches; the chevron (or a failure) shows the branches.
private struct MenuPHPGroupRow: View {
    @Environment(AppModel.self) private var app
    @AppStorage("menuPHPExpanded") private var expandedPref = false
    let rows: [ServiceRowState]

    var body: some View {
        let services = app.services
        let running = rows.filter { $0.state.isRunning }.count
        let anyFailed = rows.contains { if case .failed = $0.state { true } else { false } }
        let busy = services.isBusyAll || rows.contains(where: \.isTransitioning)
        let expanded = expandedPref || anyFailed
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(running == rows.count ? Color.green : (running == 0 ? Color.secondary : Color.orange))
                    .frame(width: 9, height: 9)
                Button {
                    expandedPref.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: "PHP-FPM")
                        Text(verbatim: versions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(anyFailed)
                .help(expanded ? Text("Skryť jednotlivé verzie") : Text("Zobraziť jednotlivé verzie"))
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                Toggle(isOn: Binding(
                    get: { running > 0 },
                    set: { on in
                        let ids = rows.filter { on ? !$0.state.isRunning : $0.state.isRunning }.map(\.id)
                        Task { for id in ids { on ? await services.start(id) : await services.stop(id) } }
                    })) { Text(verbatim: "PHP-FPM") }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(busy)
            }
            if expanded {
                ForEach(rows) { MenuServiceRow(row: $0) }
                    .padding(.leading, 17)
            }
        }
    }

    private var versions: String {
        rows.compactMap { row -> String? in if case .phpFPM(let b) = row.id { b } else { nil } }.joined(separator: " · ")
    }
}

private struct MenuServiceRow: View {
    @Environment(AppModel.self) private var app
    let row: ServiceRowState

    var body: some View {
        let services = app.services
        let busy = ["start", "stop", "restart", "reload"].contains { services.isBusy($0, row.id) }
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                StateDot(state: row.state)
                Text(verbatim: row.displayName)
                if case .phpFPM(let b) = row.id, let used = app.php.info(b)?.usedByVhosts, used > 0 {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(Text("Používa \(used) vhostov"))
                }
                Spacer()
                if busy || row.isTransitioning { ProgressView().controlSize(.mini) }
                Toggle(isOn: Binding(
                    get: { isOn },
                    set: { on in
                        let id = row.id
                        Task { on ? await services.start(id) : await services.stop(id) }
                    })) { Text(verbatim: row.displayName) }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(busy || row.isTransitioning || services.isBusyAll)
            }
            if row.id == .elasticsearch { MenuElasticsearchExtras(state: row.state) }   // 06-04
            if case .failed(let reason) = row.state {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(verbatim: reason))
                    .padding(.leading, 17)
            }
        }
    }

    private var isOn: Bool {
        switch row.state {
        case .running, .starting, .backingOff: true
        case .stopped, .stopping, .failed: false
        }
    }
}
