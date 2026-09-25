import SwiftUI
import AppKit
import RAMPCore

/// Nastavenia › Elasticsearch (06-04): install, heap, auto-stop, plugins, ports, data dir.
/// Inserted into `SettingsView`'s Form as one line; renders several `Section`s.
struct ElasticsearchSettingsSection: View {
    @Environment(AppModel.self) private var app

    @State private var heapChoice = "1g"
    @State private var customHeap = ""
    @State private var httpPort = ""
    @State private var transportPort = ""
    @State private var pluginName = ""
    @State private var pending: PendingRestart?

    /// A settings change that needs a restart of the running ES: asked first.
    private struct PendingRestart: Identifiable {
        let id = UUID()
        let apply: @MainActor (_ restart: Bool) async -> Void
    }

    private static let custom = "custom"

    var body: some View {
        let es = app.elasticsearch
        Group {
            installSection(es)
            if es.isInstalled {
                heapSection(es)
                autoStopSection(es)
                pluginsSection(es)
                portsSection(es)
                dataSection(es)
            }
        }
        .task(id: es.isInstalled) {
            loadDrafts()
            await es.loadManifestEntry()
            if es.isInstalled {
                await es.loadPlugins()
                await es.refreshDataSize()
            }
        }
        .onChange(of: app.config.elasticsearch) { loadDrafts() }
        .confirmationDialog("Reštartovať Elasticsearch teraz?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { change in
            Button("Reštartovať") { Task { await change.apply(true) } }
            Button("Uložiť bez reštartu") { Task { await change.apply(false) } }
            Button("Zrušiť", role: .cancel) { loadDrafts() }
        } message: { _ in
            Text("Zmena sa prejaví až po reštarte Elasticsearch.")
        }
    }

    private func loadDrafts() {
        let settings = app.elasticsearch.settings
        if ElasticsearchModel.heapPresets.contains(settings.heap) {
            heapChoice = settings.heap
        } else {
            heapChoice = Self.custom
            customHeap = settings.heap
        }
        httpPort = String(settings.httpPort)
        transportPort = String(settings.transportPort)
    }

    /// Applies directly when ES is stopped, otherwise asks about the restart.
    private func applyOrAsk(_ apply: @escaping @MainActor (_ restart: Bool) async -> Void) {
        if app.elasticsearch.isActive {
            pending = PendingRestart(apply: apply)
        } else {
            Task { await apply(false) }
        }
    }

    // MARK: Inštalácia

    @ViewBuilder private func installSection(_ es: ElasticsearchModel) -> some View {
        Section("Elasticsearch") {
            if let version = es.installedVersion {
                LabeledContent("Nainštalovaná verzia") { Text(verbatim: version).monospacedDigit() }
                // Clickable only while ES runs — otherwise the URL would open an empty/error page.
                if es.state.isRunning {
                    Link(destination: es.httpURL) { Text("Otvoriť \(es.httpURL.absoluteString)") }
                } else {
                    LabeledContent("Adresa") {
                        Text(verbatim: es.httpURL.absoluteString).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("Elasticsearch nebeží — spusti ho v Službách.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                let version = es.manifestEntry?.version ?? "9.5.4"
                let size = es.manifestEntry?.size.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "600 MB"
                LabeledContent {
                    Button("Nainštalovať Elasticsearch \(version) (~\(size))") { Task { await es.install() } }
                        .disabled(es.installing)
                } label: {
                    Text("Nie je nainštalovaný")
                }
                if es.installing {
                    PackageProgressView(stage: es.installStage, download: es.installDownload)
                }
            }
            if let error = es.installError {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Text("Elasticsearch sa nikdy nespúšťa automaticky; pri ukončení RAMP sa zastaví.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pamäť

    @ViewBuilder private func heapSection(_ es: ElasticsearchModel) -> some View {
        Section("Pamäť (heap)") {
            Picker("Heap", selection: Binding(get: { heapChoice }, set: { value in
                heapChoice = value
                guard value != Self.custom, value != es.settings.heap else { return }
                applyOrAsk { restart in _ = await es.setHeap(value, restart: restart) }
            })) {
                Text("512 MB").tag("512m")
                Text("1 GB (predvolené)").tag("1g")
                Text("2 GB").tag("2g")
                Text("4 GB").tag("4g")
                Text("Vlastná").tag(Self.custom)
            }
            if heapChoice == Self.custom {
                LabeledContent("Vlastná veľkosť") {
                    HStack {
                        TextField(text: $customHeap, prompt: Text(verbatim: "768m")) { Text("Vlastná veľkosť") }
                            .frame(width: 90)
                            .onSubmit { applyCustomHeap(es) }
                        Button("Uložiť") { applyCustomHeap(es) }
                            .disabled(customHeap.isEmpty || customHeap == es.settings.heap)
                    }
                }
            }
            if let error = es.settingsError {
                Text(verbatim: error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func applyCustomHeap(_ es: ElasticsearchModel) {
        let value = customHeap
        applyOrAsk { restart in _ = await es.setHeap(value, restart: restart) }
    }

    // MARK: Auto-stop

    @ViewBuilder private func autoStopSection(_ es: ElasticsearchModel) -> some View {
        let auto = es.settings.autoStop
        Section {
            HStack {
                Toggle("Po", isOn: Binding(get: { auto.afterHours != nil }, set: { on in
                    var next = auto
                    next.afterHours = on ? 6 : nil
                    Task { await es.setAutoStop(next) }
                }))
                Spacer()
                Stepper(value: Binding(get: { auto.afterHours ?? 6 }, set: { hours in
                    var next = auto
                    next.afterHours = hours
                    Task { await es.setAutoStop(next) }
                }), in: 1...max(24, auto.afterHours ?? 1)) {
                    Text("\(auto.afterHours ?? 6) h").monospacedDigit()
                }
                .disabled(auto.afterHours == nil)
            }
            HStack {
                Toggle("V čase", isOn: Binding(get: { auto.atTime != nil }, set: { on in
                    var next = auto
                    next.atTime = on ? (auto.time?.description ?? "01:00") : nil
                    Task { await es.setAutoStop(next) }
                }))
                Spacer()
                DatePicker(selection: Binding(get: { Self.date(from: auto.time) }, set: { date in
                    var next = auto
                    next.atTime = Self.hhmm(date)
                    guard next != auto else { return }
                    Task { await es.setAutoStop(next) }
                }), displayedComponents: .hourAndMinute) { Text("V čase") }
                    .labelsHidden()
                    .disabled(auto.atTime == nil)
            }
            if es.isActive {
                LabeledContent("Aktuálne") { AutoStopRemainingText(status: es.autoStop) }
            }
        } header: {
            Text("Auto-stop")
        } footer: {
            Text("Platí skorší z oboch termínov. Čas do 15 minút po spustení sa posunie na ďalší deň.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func date(from time: AutoStopTime?) -> Date {
        let t = time ?? AutoStopTime(hour: 1, minute: 0)!
        return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
    }

    static func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return AutoStopTime(hour: c.hour ?? 1, minute: c.minute ?? 0)?.description ?? "01:00"
    }

    // MARK: Pluginy

    @ViewBuilder private func pluginsSection(_ es: ElasticsearchModel) -> some View {
        Section("Pluginy") {
            if es.pluginsLoaded && es.plugins.isEmpty {
                Text("Žiadne pluginy").foregroundStyle(.secondary)
            }
            ForEach(es.plugins, id: \.self) { name in
                LabeledContent {
                    if es.pluginBusy == name {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Odstrániť", role: .destructive) { Task { await es.removePlugin(name) } }
                            .disabled(es.pluginBusy != nil)
                    }
                } label: {
                    Text(verbatim: name).monospaced()
                }
            }
            HStack {
                TextField(text: $pluginName, prompt: Text(verbatim: "analysis-icu")) { Text("Plugin") }
                    .onSubmit { installPlugin(es) }
                Menu {
                    ForEach(ElasticsearchModel.pluginSuggestions.filter { !es.plugins.contains($0) }, id: \.self) { name in
                        Button(name) { pluginName = name }
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Návrhy")
                Button("Nainštalovať") { installPlugin(es) }
                    .disabled(pluginName.isEmpty || es.pluginBusy != nil)
            }
            if let busy = es.pluginBusy, !busy.isEmpty, !es.plugins.contains(busy) {
                ProgressView { Text("Inštaluje sa \(busy)…") }
                    .progressViewStyle(.linear)
            }
            if let error = es.pluginError {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if es.restartRequired && es.isActive {
                LabeledContent {
                    Button("Reštartovať teraz") { Task { await es.restart() } }
                } label: {
                    Text("Zmena pluginov sa prejaví po reštarte Elasticsearch.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func installPlugin(_ es: ElasticsearchModel) {
        let name = pluginName
        Task {
            await es.installPlugin(name)
            if es.pluginError == nil { pluginName = "" }
        }
    }

    // MARK: Porty

    @ViewBuilder private func portsSection(_ es: ElasticsearchModel) -> some View {
        Section("Porty") {
            LabeledContent("HTTP") {
                TextField(text: $httpPort, prompt: Text(verbatim: "9200")) { Text("HTTP") }
                    .frame(width: 90)
            }
            LabeledContent("Transport") {
                TextField(text: $transportPort, prompt: Text(verbatim: "9300")) { Text("Transport") }
                    .frame(width: 90)
            }
            HStack {
                Spacer()
                Button("Uložiť porty") { savePorts(es) }
                    .disabled(httpPort == String(es.settings.httpPort)
                              && transportPort == String(es.settings.transportPort))
            }
        }
    }

    private func savePorts(_ es: ElasticsearchModel) {
        guard let http = Int(httpPort), let transport = Int(transportPort) else {
            es.settingsError = String(localized: "Port musí byť číslo")
            return
        }
        applyOrAsk { restart in
            await es.save(restart: restart) { $0.httpPort = http; $0.transportPort = transport }
        }
    }

    // MARK: Dáta

    @ViewBuilder private func dataSection(_ es: ElasticsearchModel) -> some View {
        Section("Dáta") {
            if let dir = es.dataDirectory {
                LabeledContent("Priečinok") {
                    Text(verbatim: dir.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Veľkosť") { Text(verbatim: es.dataSize ?? "…") }
                HStack {
                    Spacer()
                    Button("Zobraziť vo Finderi") { es.showDataInFinder() }
                }
            }
        }
    }
}
