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
            ForEach(core) { MenuServiceRow(row: $0) }
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
