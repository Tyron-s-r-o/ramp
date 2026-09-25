import SwiftUI
import RAMPCore

struct ServicesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let services = app.services
        Group {
            if services.rows.isEmpty {
                ContentUnavailableView {
                    Label("Žiadne služby", systemImage: "server.rack")
                } description: {
                    Text("Zatiaľ nie je nainštalovaná žiadna služba.")
                }
            } else {
                List {
                    let core = services.rows.filter { !ServicesModel.optionalServices.contains($0.id) }
                    let php = core.filter { if case .phpFPM = $0.id { true } else { false } }
                    if !php.isEmpty { PHPFPMGroupRow(rows: php) }
                    ForEach(core.filter { if case .phpFPM = $0.id { false } else { true } }) { row in
                        ServiceRow(row: row)
                    }
                    // 06-04: optional services (Elasticsearch) in their own group.
                    Section("Voliteľné") {
                        if let es = services.rows.first(where: { $0.id == .elasticsearch }) {
                            ServiceRow(row: es)
                        } else {
                            ElasticsearchNotInstalledRow()
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .safeAreaInset(edge: .top) {
            // First launch / missing packages: which package and how far (shared with ES install + updates).
            if let install = app.launchInstall {
                PackageProgressView(stage: install.stage, download: install.download,
                                    title: Self.packageTitle(install))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .navigationTitle(Text("Služby"))
        .task { await services.refresh() }
    }

    /// "Apache 2.4" / "PHP 8.4" for the launch-install line.
    static func packageTitle(_ install: InstallProgress) -> String {
        let names = ["apache": "Apache", "redis": "Redis", "mysql": "MySQL", "php": "PHP",
                     "phpmyadmin": "phpMyAdmin", "elasticsearch": "Elasticsearch",
                     "elasticvue": "Elasticvue"]
        return "\(names[install.component] ?? install.component) \(install.branch)"
    }
}


/// All PHP-FPM versions in one row (the usual case: all running). Expands automatically when one is not.
private struct PHPFPMGroupRow: View {
    @Environment(AppModel.self) private var app
    let rows: [ServiceRowState]
    @State private var expanded: Bool? = ScreenshotMode.isActive ? true : nil

    private var running: Int { rows.filter { $0.state.isRunning }.count }
    private var allRunning: Bool { running == rows.count }

    var body: some View {
        let services = app.services
        let isExpanded = expanded ?? !allRunning
        // Custom header instead of DisclosureGroup: its leading chevron shifted the dot/title out of
        // alignment with the other service rows. The expand chevron sits on the right instead.
        Group {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button { withAnimation { expanded = !isExpanded } } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: ServiceRowMetrics.chevronSlot)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Skryť jednotlivé verzie PHP" : "Zobraziť jednotlivé verzie PHP")
                Circle()
                    .fill(allRunning ? Color.green : (running == 0 ? Color.secondary : Color.orange))
                    .frame(width: 9, height: 9)
                Text(verbatim: "PHP-FPM").font(.headline)
                Text(allRunning ? "Všetky bežia (\(rows.count))" : "Beží \(running) z \(rows.count)")
                    .foregroundStyle(allRunning ? Color.secondary : Color.orange)
                Text(verbatim: rows.map { $0.id.phpBranchLabel }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    Button { Task { for r in rows where !r.state.isRunning { await services.start(r.id) } } } label: {
                        Label("Spustiť všetky PHP", systemImage: "play.fill")
                    }
                    .disabled(allRunning)
                    Button { Task { for r in rows where r.state.isRunning { await services.stop(r.id) } } } label: {
                        Label("Zastaviť všetky PHP", systemImage: "stop.fill")
                    }
                    .disabled(running == 0)
                    Button { Task { for r in rows where r.state.isRunning { await services.reload(r.id) } } } label: {
                        Label("Reload všetkých PHP", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(running == 0)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { withAnimation { expanded = !isExpanded } }
            if isExpanded {
                ForEach(rows) { row in ServiceRow(row: row) }
            }
        }
    }
}

private extension ServiceID {
    var phpBranchLabel: String { if case .phpFPM(let b) = self { b } else { "" } }
}
