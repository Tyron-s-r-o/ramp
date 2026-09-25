import Foundation
import Observation
import RAMPCore

/// Error shown by `ErrorBanner`: Slovak title + verbatim (English) core message.
struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// Root app state. Created once in `RAMPApp`, shared with `AppDelegate` (launch / quit) and every scene via
/// `.environment`. Core work stays in RAMPCore actors; this only mirrors state and forwards actions.
@MainActor @Observable
final class AppModel {
    let paths: Paths
    let configStore: ConfigStore
    let stack: StackController
    // VhostService (03-05) / PHPManager (04-03) are wired here by 05-02 / 05-03 once they exist.
    /// Vhost CRUD → Apache → hosts block (03-05).
    let vhostService: VhostService
    /// Privileged hosts helper status / approval (03-05).
    let hostsHelper: HostsHelperModel

    /// Last loaded ramp.json; reloaded after every mutation.
    private(set) var config = RampConfig()

    let services: ServicesModel
    /// PHP section (05-03); owns the `PHPManager`.
    let php: PHPModel
    /// Logs section (05-04).
    let logs: LogsModel
    /// Databáza section (05-04).
    let database: DatabaseModel
    /// Vhosty section (05-02).
    let vhosts: VhostsModel
    /// Shared browser / Finder / PhpStorm open actions (window + menu bar).
    let opener: ProjectOpener
    /// Detect-only update check → menu-bar badge (05-05).
    let updates: UpdatesModel
    /// Nastavenia (05-06): stack settings draft + login item.
    let settings: SettingsModel
    /// Elasticsearch (06-04): lifecycle, auto-stop scheduler, install / settings / plugins.
    let elasticsearch: ElasticsearchModel
    /// "Import z MAMP PRO" wizard (07-05).
    let mampImport: ImportModel
    /// Nastavenia › Terminál: ~/.ramp/bin shims, PATH block, MAMP lines.
    let terminal: TerminalModel

    var selection: SidebarSection = .services
    var lastError: UserFacingError?
    /// Keys of running actions (per-action spinners), e.g. "start:apache", "startAll".
    var busy: Set<String> = []
    /// Service whose log the Logs section should preselect (hook for 05-04).
    var logPreselection: ServiceID?
    /// Package being installed at launch (first launch / missing packages), shown in Služby; nil otherwise.
    private(set) var launchInstall: InstallProgress?

    init(paths: Paths = .standard()) {
        self.paths = paths
        let store = ConfigStore(paths: paths)
        configStore = store
        let stack = StackController(paths: paths, configStore: store,
                                    mysqlTmpSocketLink: MySQLTmpSocketLink.standardPath(),
                                    cliHome: CLIIntegration.automaticHome())   // shims follow every config render
        self.stack = stack
        let hostsHelper = HostsHelperModel(paths: paths)
        self.hostsHelper = hostsHelper
        vhostService = VhostService(store: store, stack: stack, hosts: hostsHelper.syncer)
        services = ServicesModel(stack: stack)
        php = PHPModel(stack: stack)
        logs = LogsModel(logsDir: paths.logs)
        database = DatabaseModel(paths: paths)
        vhosts = VhostsModel()
        opener = ProjectOpener()
        updates = UpdatesModel()
        settings = SettingsModel()
        elasticsearch = ElasticsearchModel(stack: stack, paths: paths, configStore: store)
        mampImport = ImportModel()
        terminal = TerminalModel()
        services.app = self
        php.app = self
        database.app = self
        vhosts.app = self
        updates.app = self
        settings.app = self
        elasticsearch.app = self
        mampImport.app = self
        terminal.app = self
    }

    var localhostURL: URL {
        let port = config.apache.port
        return URL(string: port == 80 ? "http://localhost/" : "http://localhost:\(port)/")!
    }

    /// App launch: install missing packages (dev: `RAMP_DEV_MANIFEST`), render configs, start the stack.
    func launch() async {
        elasticsearch.startScheduler()   // 06-04: ES never autostarts; the scheduler only stops it
        busy.insert("launch")
        defer { busy.remove("launch") }
        // Fresh user = nothing installed yet → the terminal gets set up automatically after the first install.
        let freshInstall = (try? await stack.currentConfig())?.installed.isEmpty ?? true
        var installSucceeded = true
        do {
            // RAMP_DEV_MANIFEST (dev) → else the release manifest baked into Info.plist (08-03; fresh installs only)
            let dev = ProcessInfo.processInfo.environment["RAMP_DEV_MANIFEST"].flatMap { URL(string: $0) }
                ?? DistributionConfig.defaultManifestURL
            let (progress, continuation) = AsyncStream<InstallProgress>.makeStream()
            let observer = Task { [weak self] in
                for await event in progress {
                    switch event.stage {
                    case .installed, .failed: self?.launchInstall = nil
                    default: self?.launchInstall = event
                    }
                }
                self?.launchInstall = nil
            }
            defer { continuation.finish() }
            let install = try await stack.ensureInstalled(fallbackManifestURL: dev, progress: continuation)
            continuation.finish()
            await observer.value
            installSucceeded = install?.succeeded ?? true
            if let install, !install.succeeded {
                report(title: String(localized: "Inštalácia balíkov zlyhala"),
                       message: install.failures.map { "\($0.component) \($0.branch): \($0.message)" }
                           .joined(separator: "\n"))
            }
        } catch {
            launchInstall = nil
            installSucceeded = false
            report(title: String(localized: "Inštalácia balíkov zlyhala"), error: error)
        }
        await reloadConfig()
        await terminal.onLaunch(freshInstall: freshInstall && installSucceeded && !(config.installed["php"] ?? [:]).isEmpty)
        await services.startAll()
        await syncHosts()
        updates.start()
    }

    /// Brings the /etc/hosts RAMP block in line with ramp.json (helper, else password prompt — only when
    /// something differs). A cancelled prompt is reported, never fatal (03-05).
    func syncHosts() async {
        await hostsHelper.refreshStatus()
        let state = await vhostService.syncHosts()
        hostsHelper.record(state)
        if case .pending(let reason) = state {
            report(title: String(localized: "Súbor /etc/hosts nie je aktuálny"), message: reason)
        }
    }

    func reloadConfig() async {
        do {
            config = try await stack.currentConfig()
        } catch {
            report(title: String(localized: "Konfiguráciu nie je možné načítať"), error: error)
        }
    }

    func showLog(for id: ServiceID) {
        logPreselection = id
        selection = .logs
    }

    func report(title: String, message: String) {
        lastError = UserFacingError(title: title, message: message)
    }

    func report(title: String, error: any Error) {
        report(title: title, message: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}
