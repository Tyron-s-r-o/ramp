import AppKit
import SwiftUI
import RAMPCore

struct DatabaseView: View {
    @Environment(AppModel.self) private var app
    @State private var showPassword = false
    @State private var confirmRedisFlush = false
    @Environment(\.openWindow) private var openWindow

    @AppStorage(DatabaseTab.storageKey) private var tab: DatabaseTab = .mysql

    var body: some View {
        let model = app.database
        VStack(spacing: 0) {
            header(model)
            switch tab {
            case .mysql:
                Form {
                    mysqlSection(model)
                    databasesSection(model)
                }
                .formStyle(.grouped)
            case .redis:
                Form {
                    redisStatsSection(model)
                }
                .formStyle(.grouped)
            case .elasticsearch:
                Form {
                    elasticsearchSections(model)
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(Text("Databáza"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Načítať znova", systemImage: "arrow.clockwise")
                }
                .disabled(model.loadingMySQL || model.loadingRedis || model.loadingES)
                .help("Znova načítať údaje o databázach")
            }
        }
        .task { await model.refresh() }
        // ES started / stopped elsewhere (Služby, menu bar, auto-stop) → reload health + indices.
        .task(id: app.elasticsearch.state.isRunning) { await model.refreshElasticsearch() }
    }

    // MARK: Header (same layout as the PHP detail header)

    @ViewBuilder private func header(_ model: DatabaseModel) -> some View {
        let (title, running) = headerInfo(model)
        ZStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(running ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(verbatim: title)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.numericText())
                Spacer()
            }
            Picker(selection: $tab) {
                Text(verbatim: "MySQL").tag(DatabaseTab.mysql)
                Text(verbatim: "Redis").tag(DatabaseTab.redis)
                Text(verbatim: "Elasticsearch").tag(DatabaseTab.elasticsearch)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .animation(.default, value: title)
    }

    private func headerInfo(_ model: DatabaseModel) -> (String, Bool) {
        func join(_ name: String, _ version: String?) -> String {
            guard let version, !version.isEmpty else { return name }
            return "\(name) \(version)"
        }
        switch tab {
        case .mysql:
            return (join("MySQL", model.mysqlVersion), model.state(of: model.mysqlID).isRunning)
        case .redis:
            return (join("Redis", model.redis?.version), model.state(of: .redis).isRunning)
        case .elasticsearch:
            let es = app.elasticsearch
            return (join("Elasticsearch", es.installedVersion), es.isInstalled && es.state.isRunning)
        }
    }

    // MARK: MySQL

    @ViewBuilder private func mysqlSection(_ model: DatabaseModel) -> some View {
        let state = model.state(of: model.mysqlID)
        Section {
            serviceRow(model, id: model.mysqlID, state: state)
            LabeledContent("Verzia") { Text(verbatim: model.mysqlVersion ?? "—") }
            LabeledContent("Host") { Text(verbatim: model.mysqlHost).textSelection(.enabled) }
            LabeledContent("Port") { Text(verbatim: String(model.mysqlPort)).textSelection(.enabled) }
            LabeledContent("Socket") {
                HStack {
                    Text(verbatim: model.mysqlSocket)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    copyButton { model.copy(model.mysqlSocket) }
                }
            }
            LabeledContent("Používateľ") { Text(verbatim: "root").textSelection(.enabled) }
            LabeledContent("Heslo") {
                HStack {
                    Text(verbatim: showPassword ? model.rootPassword : String(repeating: "•", count: 10))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showPassword ? Text("Skryť heslo") : Text("Zobraziť heslo"))
                    copyButton { model.copy(model.rootPassword) }
                }
            }
            HStack {
                Button("Otvoriť phpMyAdmin") { NSWorkspace.shared.open(model.phpMyAdminURL) }
                    .disabled(!state.isRunning)
                Button("Kopírovať príkaz") { model.copy(model.clientCommand) }
                    .help(Text(verbatim: model.clientCommand))
            }
        } header: {
            Text(verbatim: "MySQL")
        }
    }

    @ViewBuilder private func databasesSection(_ model: DatabaseModel) -> some View {
        Section {
            if let error = model.mysqlError {
                errorRow(error)
            } else if model.databases.isEmpty && !model.loadingMySQL {
                Text("Žiadne databázy").foregroundStyle(.secondary)
            } else {
                // Table inside a grouped Form breaks the window layout (whole window renders blank),
                // so databases are plain Form rows.
                ForEach(model.databases) { db in
                    LabeledContent {
                        HStack(spacing: 16) {
                            Text("Tabuliek: \(db.tables)").monospacedDigit()
                            Text(db.bytes, format: .byteCount(style: .file))
                                .monospacedDigit()
                                .frame(minWidth: 80, alignment: .trailing)
                        }
                        .foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: db.name).textSelection(.enabled)
                    }
                }
            }
        } header: {
            HStack {
                Text("Databázy")
                if model.loadingMySQL { ProgressView().controlSize(.small) }
                Spacer()
                if !model.databases.isEmpty {
                    Text("Databáz: \(model.databases.count) · spolu \(model.totalBytes.formatted(.byteCount(style: .file)))")
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await model.refreshMySQL() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.loadingMySQL)
                .help("Obnoviť zoznam databáz")
            }
        }
    }

    // MARK: Elasticsearch

    @ViewBuilder private func elasticsearchSections(_ model: DatabaseModel) -> some View {
        let es = app.elasticsearch
        if es.isInstalled {
            elasticsearchServiceSection(model, es)
            if es.state.isRunning {
                elasticsearchClusterSection(model)
                elasticsearchIndicesSection(model)
            }
        } else {
            elasticsearchInstallSection(es)
        }
    }

    /// Reuses the Nastavenia install flow (`ElasticsearchModel.install()` + the shared `PackageProgressView`).
    @ViewBuilder private func elasticsearchInstallSection(_ es: ElasticsearchModel) -> some View {
        Section {
            Text("Elasticsearch nie je nainštalovaný. Je to voliteľná služba — nikdy sa nespúšťa automaticky.")
                .foregroundStyle(.secondary)
            let version = es.manifestEntry?.version ?? "9.5.4"
            let size = es.manifestEntry?.size.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "600 MB"
            HStack {
                Button("Nainštalovať Elasticsearch \(version) (~\(size))") { Task { await es.install() } }
                    .disabled(es.installing)
                Spacer()
                settingsLink
            }
            if es.installing {
                PackageProgressView(stage: es.installStage, download: es.installDownload)
            }
            if let error = es.installError {
                errorRow(error)
            }
        }
        .task { await es.loadManifestEntry() }
    }

    @ViewBuilder private func elasticsearchServiceSection(_ model: DatabaseModel, _ es: ElasticsearchModel) -> some View {
        let state = es.state
        Section {
            serviceRow(model, id: .elasticsearch, state: state)
            LabeledContent("Verzia") { Text(verbatim: es.installedVersion ?? "—").monospacedDigit() }
            LabeledContent("Adresa") {
                // Clickable only while ES runs — otherwise the URL would open an empty/error page.
                if state.isRunning {
                    Link(destination: es.httpURL) { Text(verbatim: es.httpURL.absoluteString) }
                } else {
                    Text(verbatim: es.httpURL.absoluteString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Auto-stop") { ElasticsearchAutoStopLine(state: state) }
            HStack {
                elasticvueButton(model, es, esRunning: state.isRunning)
                Spacer()
                settingsLink
            }
            if let error = es.elasticvueError {
                errorRow(error)
            }
        } header: {
            HStack {
                Text(verbatim: "Elasticsearch")
                if model.loadingES { ProgressView().controlSize(.small) }
            }
        }
    }

    /// "Prehliadať v Elasticvue" (default browser, localhost site) — needs Elasticsearch and Apache running.
    @ViewBuilder private func elasticvueButton(_ model: DatabaseModel, _ es: ElasticsearchModel,
                                               esRunning: Bool) -> some View {
        if es.isElasticvueInstalled {
            let apacheRunning = model.state(of: .apache).isRunning
            Button("Prehliadať v Elasticvue") { NSWorkspace.shared.open(model.elasticvueURL) }
                .disabled(!esRunning || !apacheRunning)
                .help(!esRunning ? Text("Elasticsearch nebeží — spustite ho a potom otvorte Elasticvue.")
                      : !apacheRunning ? Text("Apache nebeží — Elasticvue sa otvára cez http://localhost.")
                      : Text("Otvorí Elasticvue v predvolenom prehliadači (\(model.elasticvueURL.absoluteString))"))
        } else {
            Button("Nainštalovať Elasticvue") { Task { await es.installElasticvue() } }
                .disabled(es.installingElasticvue)
                .help("Webové rozhranie na prehliadanie indexov a dokumentov Elasticsearch")
            if es.installingElasticvue { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private func elasticsearchClusterSection(_ model: DatabaseModel) -> some View {
        Section("Klaster") {
            if let error = model.esError {
                errorRow(error)
            } else if let health = model.esHealth {
                LabeledContent("Stav klastra") {
                    HStack(spacing: 6) {
                        healthDot(health.status)
                        Text(verbatim: health.status)
                    }
                }
                if let name = health.clusterName {
                    LabeledContent("Názov") { Text(verbatim: name).textSelection(.enabled) }
                }
                LabeledContent("Uzly") { Text(health.numberOfNodes, format: .number) }
            } else if model.loadingES {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private func elasticsearchIndicesSection(_ model: DatabaseModel) -> some View {
        Section {
            if model.esError == nil && model.esIndices.isEmpty && !model.loadingES {
                Text("Žiadne indexy").foregroundStyle(.secondary)
            } else {
                // Plain Form rows — a Table inside a grouped Form breaks the window layout.
                ForEach(model.esIndices) { index in
                    LabeledContent {
                        HStack(spacing: 16) {
                            Text("Dokumentov: \(index.docsCount ?? 0)").monospacedDigit()
                            Group {
                                if let bytes = index.storeBytes {
                                    Text(bytes, format: .byteCount(style: .file))
                                } else {
                                    Text(verbatim: "—")
                                }
                            }
                            .monospacedDigit()
                            .frame(minWidth: 80, alignment: .trailing)
                        }
                        .foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 6) {
                            healthDot(index.health)
                                .help(Text(verbatim: index.health ?? index.status ?? ""))
                            Text(verbatim: index.index).textSelection(.enabled)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Indexy")
                Spacer()
                if !model.esIndices.isEmpty {
                    Text("Indexov: \(model.esIndices.count) · spolu \(model.esTotalBytes.formatted(.byteCount(style: .file)))")
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await model.refreshElasticsearch() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.loadingES)
                .help("Obnoviť zoznam indexov")
            }
        }
    }

    private var settingsLink: some View {
        Button("Nastavenia Elasticsearch…") { app.selection = .settings }
            .buttonStyle(.link)
    }

    private func healthDot(_ status: String?) -> some View {
        let color: Color = switch status {
        case "green": .green
        case "yellow": .yellow
        case "red": .red
        default: .secondary
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: Pieces

    @ViewBuilder private func serviceRow(_ model: DatabaseModel, id: ServiceID, state: ServiceState) -> some View {
        LabeledContent("Stav") {
            HStack {
                Text(Self.stateText(state))
                    .foregroundStyle(state.isRunning ? .green : .secondary)
                let busy = app.busy.contains("start:\(id.name)") || app.busy.contains("stop:\(id.name)")
                Button {
                    Task { await model.toggle(id) }
                } label: {
                    if state.isRunning { Text("Zastaviť") } else { Text("Spustiť") }
                }
                .disabled(busy)
            }
        }
    }

    private func copyButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Kopírovať")
    }

    private func errorRow(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    static func stateText(_ state: ServiceState) -> LocalizedStringKey {
        switch state {
        case .running: "Beží"
        case .starting: "Spúšťa sa"
        case .stopping: "Zastavuje sa"
        case .stopped, .backingOff: "Zastavené"
        case .failed: "Chyba"
        }
    }
}


// MARK: - Redis stats (browser opens in its own window, like phpMyAdmin for MySQL)

extension DatabaseView {
    @ViewBuilder func redisStatsSection(_ model: DatabaseModel) -> some View {
        let state = model.state(of: .redis)
        Section {
            LabeledContent("Stav") {
                Text(Self.redisStateText(state)).foregroundStyle(state.isRunning ? .green : .secondary)
            }
            LabeledContent("Port") { Text(verbatim: String(model.redisPort)).textSelection(.enabled) }
            if let error = model.redisError {
                Label { Text(verbatim: error) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let info = model.redis {
                LabeledContent("Verzia") { Text(verbatim: info.version ?? "—") }
                LabeledContent("Pamäť") { Text(verbatim: info.usedMemoryHuman ?? "—") }
                LabeledContent("Kľúče") { Text(info.keys, format: .number) }
            }
            HStack {
                Button("Prehliadať databázu") {
                    openWindow(id: "redis-browser")
                    NSApplication.shared.activate()
                }
                .disabled(!state.isRunning)
                Spacer()
                Button("Vymazať všetko (FLUSHALL)…", role: .destructive) { confirmRedisFlush = true }
                    .disabled(!state.isRunning || model.flushing)
            }
        } header: {
            Text(verbatim: "Redis")
        }
        .confirmationDialog(Text("Vymazať všetky kľúče v Redise?"), isPresented: $confirmRedisFlush,
                            titleVisibility: .visible) {
            Button("Vymazať všetko (FLUSHALL)", role: .destructive) { Task { await model.flushRedis() } }
        }
    }

    static func redisStateText(_ state: ServiceState) -> LocalizedStringKey {
        switch state {
        case .running: "Beží"
        case .starting: "Spúšťa sa"
        case .stopping: "Zastavuje sa"
        case .stopped, .backingOff: "Zastavené"
        case .failed: "Chyba"
        }
    }
}
