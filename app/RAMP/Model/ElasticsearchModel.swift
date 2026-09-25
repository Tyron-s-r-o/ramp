import AppKit
import Foundation
import Observation
import RAMPCore

/// Elasticsearch (06-04): lifecycle through `ElasticsearchService`, in-app auto-stop scheduler (replaces the
/// `com.rv.elastic-autostop` LaunchAgent), install, heap / ports / auto-stop settings, plugins, data dir.
/// The ES row state itself comes from `ServicesModel` (single supervisor-events consumer).
@MainActor @Observable
final class ElasticsearchModel {
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let service: ElasticsearchService
    @ObservationIgnored let scheduler: ElasticsearchAutoStopScheduler
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// Latest scheduler status (session start, deadline, reason).
    private(set) var autoStop: AutoStopStatus = .inactive

    // Install
    private(set) var installing = false
    private(set) var installStage: InstallProgress.Stage?
    /// Byte progress while downloading (nil before the first bytes / after the download).
    private(set) var installDownload: DownloadProgress?
    /// Whole-install fraction for the determinate bar (download bytes, then the later phases).
    var installFraction: Double { InstallProgress.overallFraction(stage: installStage, download: installDownload) }
    var installError: String?
    private(set) var installingElasticvue = false
    var elasticvueError: String?
    /// Manifest entry of the configured branch (version / size), loaded lazily.
    private(set) var manifestEntry: ManifestEntry?
    @ObservationIgnored private var manifest: Manifest?

    // Plugins
    private(set) var plugins: [String] = []
    private(set) var pluginsLoaded = false
    /// Plugin name being installed / removed ("" = list loading).
    private(set) var pluginBusy: String?
    var pluginError: String?
    /// A plugin change needs a restart of the running ES.
    var restartRequired = false

    // Settings feedback
    var settingsError: String?
    private(set) var dataSize: String?

    /// Heap choices offered in Nastavenia (default 1g).
    static let heapPresets = ["512m", "1g", "2g", "4g"]
    static let pluginSuggestions = ["analysis-icu", "analysis-phonetic", "analysis-kuromoji", "mapper-size"]

    init(stack: StackController, paths: Paths, configStore: ConfigStore) {
        let service = ElasticsearchService(stack: stack)
        self.service = service
        scheduler = ElasticsearchAutoStopScheduler(
            es: service,
            settings: { (try? await configStore.load())?.elasticsearch.autoStop ?? AutoStopSettings() },
            log: LogSink(paths: paths),
            stateFile: ElasticsearchAutoStopScheduler.stateFile(paths: paths))
        // The app ignores RAMP_ES_AUTOSTOP_SECONDS (rampctl test aid only).
    }

    // MARK: Derived

    var settings: ElasticsearchSettings { app?.config.elasticsearch ?? ElasticsearchSettings() }
    var installedVersion: String? { app?.config.installed["elasticsearch"]?[settings.branch]?.version }
    var isInstalled: Bool { installedVersion != nil }
    /// Elasticvue comes with Elasticsearch; older installs get it on the next launch or via "Nainštalovať Elasticvue".
    var isElasticvueInstalled: Bool { !(app?.config.installed["elasticvue"] ?? [:]).isEmpty }
    var state: ServiceState { app?.services.rows.first { $0.id == .elasticsearch }?.state ?? .stopped }
    var isActive: Bool {
        switch state {
        case .running, .starting, .backingOff: true
        case .stopped, .stopping, .failed: false
        }
    }
    var httpURL: URL { URL(string: "http://127.0.0.1:\(settings.httpPort)")! }
    var dataDirectory: URL? { app?.paths.elasticsearchData(branch: settings.branch) }

    // MARK: Scheduler

    /// App launch: 30 s ticks + tick on wake (time asleep counts; a passed deadline stops ES right away).
    func startScheduler() {
        guard schedulerTask == nil else { return }
        let scheduler = scheduler
        schedulerTask = Task.detached { await scheduler.run() }
        statusTask = Task { [weak self] in
            for await status in scheduler.updates {
                self?.autoStop = status
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await scheduler.wake() }
        }
    }

    /// App quit: no more ticks while the stack is being stopped.
    func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // MARK: Lifecycle (called by ServicesModel for the `.elasticsearch` row)

    func start() async {
        do {
            let state = try await service.start()
            if state.isRunning {
                await scheduler.sessionStarted(at: Date())
            } else if case .failed(let reason) = state {
                app?.report(title: String(localized: "Elasticsearch sa nepodarilo spustiť"), message: reason)
            }
        } catch {
            app?.report(title: String(localized: "Elasticsearch sa nepodarilo spustiť"), error: error)
        }
    }

    func stop() async {
        await service.stop()
        await scheduler.sessionEnded()
    }

    /// Restart keeps the auto-stop session (deadline unchanged).
    func restart() async {
        do {
            let state = try await service.restart()
            if state.isRunning {
                await scheduler.sessionStarted(at: Date())
                restartRequired = false
            } else if case .failed(let reason) = state {
                app?.report(title: String(localized: "Elasticsearch sa nepodarilo reštartovať"), message: reason)
            }
        } catch {
            app?.report(title: String(localized: "Elasticsearch sa nepodarilo reštartovať"), error: error)
        }
    }

    /// "Predĺžiť o 1 h" / "+1 h".
    func postpone() async {
        autoStop = await scheduler.postpone(now: Date())
    }

    // MARK: Install

    func loadManifestEntry() async {
        guard manifestEntry == nil, let app else { return }
        let dev = ProcessInfo.processInfo.environment["RAMP_DEV_MANIFEST"].flatMap { URL(string: $0) }
        guard let url = app.config.manifestURL ?? dev else { return }
        let branch = settings.branch
        if let loaded = try? await ManifestLoader.load(url) {
            manifest = loaded
            manifestEntry = loaded.components["elasticsearch"]?[branch]
        }
    }

    func install() async {
        guard let app, !installing else { return }
        installing = true
        installError = nil
        installStage = .downloading
        installDownload = nil
        defer { installing = false; installDownload = nil }
        await loadManifestEntry()
        let installer = PackageInstaller(paths: app.paths, configStore: app.configStore)
        let (progress, continuation) = AsyncStream<InstallProgress>.makeStream()
        let observer = Task { [weak self] in
            for await p in progress {
                self?.installStage = p.stage
                self?.installDownload = p.stage == .downloading ? p.download : nil
            }
        }
        do {
            _ = try await installer.installElasticsearch(manifest: manifest, progress: continuation)
        } catch {
            installError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        await observer.value
        if case .failed(let message) = installStage, installError == nil { installError = message }
        await applyElasticvueAlias()
        await app.services.refresh()
    }

    /// Elasticvue alone (Elasticsearch installed before it was bundled, or its install failed).
    func installElasticvue() async {
        guard let app, !installingElasticvue else { return }
        installingElasticvue = true
        elasticvueError = nil
        defer { installingElasticvue = false }
        await loadManifestEntry()
        let installer = PackageInstaller(paths: app.paths, configStore: app.configStore)
        do {
            _ = try await installer.installElasticvue(manifest: manifest)
        } catch {
            elasticvueError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        await applyElasticvueAlias()
    }

    /// Re-renders (Apache `/elasticvue` alias + default cluster file) and reloads Apache gracefully.
    private func applyElasticvueAlias() async {
        guard let app else { return }
        await app.reloadConfig()
        guard isElasticvueInstalled else { return }
        do {
            _ = try await app.stack.applyConfigChanges()
        } catch {
            elasticvueError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: Settings

    /// Saves `mutate` into ramp.json (validated with the generator's rules). `restart` → restart a running ES.
    @discardableResult
    func save(restart: Bool, _ mutate: @escaping @Sendable (inout ElasticsearchSettings) -> Void) async -> Bool {
        guard let app else { return false }
        var draft = settings
        mutate(&draft)
        do {
            try ElasticsearchService.validate(draft)
            _ = try ElasticsearchService.validateHeap(draft.heap)
            try draft.autoStop.validate()
            let final = draft
            try await app.configStore.update { $0.elasticsearch = final }
            settingsError = nil
        } catch {
            settingsError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return false
        }
        await app.reloadConfig()
        if restart && isActive { await self.restart() }
        await app.services.refresh()
        return true
    }

    func setHeap(_ heap: String, restart: Bool) async -> Bool {
        let normalized: String
        do {
            normalized = try ElasticsearchService.validateHeap(heap.trimmingCharacters(in: .whitespaces))
        } catch {
            settingsError = String(localized: "Neplatná veľkosť pamäte (napr. 768m, 3g; 256m – 31g)")
            return false
        }
        return await save(restart: restart) { $0.heap = normalized }
    }

    func setAutoStop(_ autoStop: AutoStopSettings) async {
        if await save(restart: false, { $0.autoStop = autoStop }) {
            await scheduler.wake()   // recompute the deadline now, not on the next tick
        }
    }

    // MARK: Plugins

    func loadPlugins() async {
        #if DEBUG
        if ScreenshotMode.isActive { plugins = settings.plugins; pluginsLoaded = true; return }
        #endif
        guard isInstalled, pluginBusy == nil else { return }
        pluginBusy = ""
        defer { pluginBusy = nil }
        do {
            plugins = try await service.listPlugins()
            pluginsLoaded = true
            pluginError = nil
        } catch {
            pluginError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    func installPlugin(_ raw: String) async {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard ElasticsearchPluginManager.isValidName(name) else {
            pluginError = String(localized: "Neplatný názov pluginu (napr. analysis-icu)")
            return
        }
        await changePlugin(name) { try await self.service.installPlugin(name) }
    }

    func removePlugin(_ name: String) async {
        await changePlugin(name) { try await self.service.removePlugin(name) }
    }

    private func changePlugin(_ name: String, _ body: () async throws -> PluginChange) async {
        pluginBusy = name
        pluginError = nil
        do {
            let change = try await body()
            if change.restartRequired { restartRequired = true }
        } catch {
            pluginError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        pluginBusy = nil
        await app?.reloadConfig()
        await loadPlugins()
    }

    // MARK: Data dir

    func refreshDataSize() async {
        #if DEBUG
        if ScreenshotMode.isActive { dataSize = "412 MB"; return }
        #endif
        guard let dir = dataDirectory else { return }
        dataSize = await Task.detached { Self.size(of: dir) }.value
    }

    func showDataInFinder() {
        guard let dir = dataDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    nonisolated static func size(of dir: URL) -> String {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    // MARK: Formatting

    /// `"01:00"` in the user's time zone.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// Remaining time until `deadline`, e.g. "3 h 05 min" (minutes rounded up).
    static func remaining(until deadline: Date, now: Date) -> String {
        AutoStopStatus.remainingText(.seconds(Int64(max(0, deadline.timeIntervalSince(now)).rounded(.up))))
    }
}
