import Foundation

/// Result of `StackController.startAll()`: every service's state after the attempt plus per-service errors.
/// One failing service (e.g. MAMP holding :80) never prevents the others from starting.
public struct StackStartReport: Sendable {
    public var states: [ServiceID: ServiceState] = [:]
    public var errors: [ServiceID: String] = [:]
    public var succeeded: Bool { errors.isEmpty }
}

/// Result of `StackController.applyConfigChanges()`.
public struct ConfigApplyReport: Sendable, Equatable {
    /// Written or pruned files.
    public var changed: Set<URL> = []
    public var reloaded: [ServiceID] = []
    public var restarted: [ServiceID] = []
    public var started: [ServiceID] = []
    public var stopped: [ServiceID] = []
    public var errors: [ServiceID: String] = [:]
    /// Services whose config test (`httpd -t` / `php-fpm -t`) rejected the new files: raw test output.
    /// Also listed in `errors`. The running process keeps its previous config (not reloaded).
    public var preflightFailed: [ServiceID: String] = [:]
}

/// One service row for status listings (stack order).
public struct ServiceStatus: Sendable, Equatable {
    public var id: ServiceID
    public var state: ServiceState
}

/// Ties the core together: install → render configs → start in order → minimal reload on change → stop.
/// Owns `ConfigStore`, `PackageInstaller`, `ServiceSupervisor`.
public actor StackController {
    public typealias SpecProvider = @Sendable (RampConfig, Paths) throws -> [ServiceSpec]
    public typealias Renderer = @Sendable (RampConfig, Paths) throws -> [GeneratedFile]
    public typealias ManagedDirectories = @Sendable (RampConfig, Paths) -> [(dir: URL, ext: String)]

    public let paths: Paths
    public let configStore: ConfigStore
    public let installer: PackageInstaller
    public let supervisor: ServiceSupervisor
    /// Global lock for updates / dumps / MAMP import / uninstall (plan 07-02); `<root>/run/maintenance.lock`.
    public let maintenance: MaintenanceLock
    private let specProvider: SpecProvider
    private let renderer: Renderer
    private let managedDirectories: ManagedDirectories
    /// Services of the last `startAll` / `applyConfigChanges`, in stack order.
    private var knownIDs: [ServiceID] = []
    /// `/tmp/mysql.sock` compatibility link; nil = not managed (tests, one-shot tools).
    public nonisolated let tmpSocketLink: MySQLTmpSocketLink?
    /// Terminal shims (`~/.ramp/bin`), re-synced after every config render; nil = not managed (tests, tools).
    public nonisolated let cli: CLIIntegration?

    public init(paths: Paths, configStore: ConfigStore? = nil, supervisor: ServiceSupervisor? = nil,
                specProvider: @escaping SpecProvider = { try ServiceSpecFactory.specs(config: $0, paths: $1) },
                renderer: @escaping Renderer = { try ConfigRenderer.renderAll(config: $0, paths: $1) },
                managedDirectories: @escaping ManagedDirectories = {
                    ConfigRenderer.managedDirectories(config: $0, paths: $1)
                },
                mysqlTmpSocketLink: URL? = nil, cliHome: URL? = nil) {
        self.paths = paths
        let store = configStore ?? ConfigStore(paths: paths)
        self.configStore = store
        self.installer = PackageInstaller(paths: paths, configStore: store)
        self.supervisor = supervisor ?? ServiceSupervisor(paths: paths)
        self.maintenance = MaintenanceLock(paths: paths)
        self.specProvider = specProvider
        self.renderer = renderer
        self.managedDirectories = managedDirectories
        self.tmpSocketLink = mysqlTmpSocketLink.map { MySQLTmpSocketLink(linkPath: $0, paths: paths) }
        self.cli = cliHome.map { CLIIntegration(paths: paths, home: $0) }
    }

    public nonisolated var events: AsyncStream<ServiceEvent> { supervisor.events }

    // MARK: Install

    /// Installs the default set pieces that are missing (+ Elasticvue next to an installed Elasticsearch). `fallbackManifestURL` (e.g. `RAMP_DEV_MANIFEST`) is
    /// stored when ramp.json has no manifest. Returns nil when nothing had to be installed.
    @discardableResult
    public func ensureInstalled(fallbackManifestURL: URL? = nil,
                                progress: AsyncStream<InstallProgress>.Continuation? = nil) async throws -> InstallReport? {
        var config = try await configStore.load()
        if config.manifestURL == nil, let fallback = fallbackManifestURL {
            config = try await configStore.update { $0.manifestURL = fallback }
        }
        guard let manifestURL = config.manifestURL else {
            progress?.finish()
            return nil
        }
        let installed = config.installed
        let complete = !(installed["apache"] ?? [:]).isEmpty && !(installed["redis"] ?? [:]).isEmpty
            && installed["mysql"]?[PackageInstaller.defaultMySQLBranch] != nil && !(installed["php"] ?? [:]).isEmpty
        // Elasticsearch installed before Elasticvue was bundled (or its Elasticvue install failed) → add it now.
        let needsElasticvue = !(installed["elasticsearch"] ?? [:]).isEmpty
            && (installed[ElasticvueConfigGenerator.component] ?? [:]).isEmpty
        if complete && !needsElasticvue {
            progress?.finish()
            return nil
        }
        let manifest = try await ManifestLoader.load(manifestURL)
        // PHP branches the config already names (e.g. a restored ramp.json) are needed even when EOL.
        let requiredPHP = Set([config.apache.defaultPHP, config.phpmyadmin.phpBranch].compactMap { $0 }
            + config.vhosts.compactMap(\.phpBranch))
        var missing = PackageInstaller.defaultSlots(in: manifest, requiredPHP: requiredPHP)
            .filter { installed[$0.component]?[$0.branch] == nil }
        if needsElasticvue, let slot = PackageInstaller.elasticvueSlot(in: manifest) { missing.append(slot) }
        return await installer.install(slots: missing, from: manifest, progress: progress)
    }

    // MARK: Prepare

    /// Directories + default site + render/write/prune every config file. Returns the changed/removed files.
    @discardableResult
    public func prepare() async throws -> Set<URL> {
        try paths.ensureDirectories()
        try DefaultSite.ensure(paths: paths)
        try await ensurePhpMyAdminSetup()   // 04-04: secret + tmp dir before rendering
        let config = try await configStore.load()
        return try renderAndWrite(config)
    }

    private func renderAndWrite(_ config: RampConfig) throws -> Set<URL> {
        let files = try renderer(config, paths)
        let writer = ConfigWriter(paths: paths)
        var changed = try writer.write(files)
        let produced = Set(files.map { $0.path.standardizedFileURL })
        for managed in managedDirectories(config, paths) {
            changed.formUnion(try writer.prune(directory: managed.dir, keeping: produced, extension: managed.ext))
        }
        // Install / update / rollback / branch toggle all re-render here → shims follow (never fatal).
        _ = try? cli?.syncShims(config: config)
        return changed
    }

    // MARK: Start / stop

    /// Bootstraps MySQL if needed, then starts FPM branches → Apache → MySQL → Redis (honoring
    /// `services[..].autostart`). Per-service failures are collected, never abort the rest.
    @discardableResult
    public func startAll() async throws -> StackStartReport {
        var config = try await configStore.load()
        var report = StackStartReport()
        var specs = try specProvider(config, paths)
        knownIDs = specs.map(\.id)

        if let mysqlSpec = specs.first(where: { if case .mysql = $0.id { true } else { false } }),
           autostart(mysqlSpec.id, config), MySQLBootstrapper.needsBootstrap(config) {
            do {
                config = try await MySQLBootstrapper(paths: paths, configStore: configStore)
                    .bootstrapIfNeeded(config: config, supervisor: supervisor, spec: mysqlSpec)
                specs = try specProvider(config, paths)
            } catch {
                report.errors[mysqlSpec.id] = error.localizedDescription
            }
        }

        for spec in specs where autostart(spec.id, config) && report.errors[spec.id] == nil {
            let state = await supervisor.start(spec)
            if case .failed(let reason) = state { report.errors[spec.id] = reason }
        }
        for id in knownIDs { report.states[id] = await supervisor.state(of: id) }
        await syncMySQLTmpSocketLink()
        return report
    }

    public func stopAll() async {
        await supervisor.stopAll()
        await syncMySQLTmpSocketLink()
    }

    public func status() async -> [ServiceID: ServiceState] {
        var result: [ServiceID: ServiceState] = [:]
        for row in await orderedStatus() { result[row.id] = row.state }
        return result
    }

    /// Status in stack order (FPM ascending, Apache, MySQL, Redis).
    public func orderedStatus() async -> [ServiceStatus] {
        var ids = knownIDs
        if ids.isEmpty, let config = try? await configStore.load(), let specs = try? specProvider(config, paths) {
            ids = specs.map(\.id)
        }
        var rows: [ServiceStatus] = []
        for id in ids { rows.append(ServiceStatus(id: id, state: await supervisor.state(of: id))) }
        return rows
    }

    // MARK: Single service (GUI, 05-01)

    public func currentConfig() async throws -> RampConfig {
        try await configStore.load()
    }

    /// Services that should be running: configured (installed / enabled) and `autostart == true`.
    public func expectedServices() async -> Set<ServiceID> {
        guard let config = try? await configStore.load(), let specs = try? specProvider(config, paths) else { return [] }
        return Set(specs.map(\.id).filter { autostart($0, config) })
    }

    /// Starts one service with a spec freshly derived from the current config (MySQL is bootstrapped first
    /// when `requiresBootstrap`). Errors come back as `.failed(reason)`; never throws.
    @discardableResult
    public func start(_ id: ServiceID) async -> ServiceState {
        do {
            var config = try await configStore.load()
            var specs = try specProvider(config, paths)
            let registered = await supervisor.spec(of: id)
            guard var spec = specs.first(where: { $0.id == id }) ?? registered else {
                return .failed(reason: "\(id.displayName) is not configured")
            }
            if spec.requiresBootstrap, MySQLBootstrapper.needsBootstrap(config) {
                config = try await MySQLBootstrapper(paths: paths, configStore: configStore)
                    .bootstrapIfNeeded(config: config, supervisor: supervisor, spec: spec)
                specs = try specProvider(config, paths)
                spec = specs.first(where: { $0.id == id }) ?? spec
            }
            if knownIDs.isEmpty { knownIDs = specs.map(\.id) }
            let state = await supervisor.start(spec)
            if case .mysql = id { await syncMySQLTmpSocketLink() }
            return state
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    public func stop(_ id: ServiceID) async {
        await supervisor.stop(id)
        if case .mysql = id { await syncMySQLTmpSocketLink() }
    }

    /// Stop + start with a fresh spec (port / config changes apply). Throws when the service is unknown.
    @discardableResult
    public func restart(_ id: ServiceID) async throws -> ServiceState {
        let config = try await configStore.load()
        let configured = try specProvider(config, paths).contains { $0.id == id }
        let registered = await supervisor.spec(of: id) != nil
        guard configured || registered else { throw SupervisorError.unknownService(id) }
        await supervisor.stop(id)
        return await start(id)
    }

    /// Graceful reload after the spec's config test: Apache SIGUSR1, PHP-FPM SIGUSR2; others throw
    /// `SupervisorError.notReloadable`.
    public func reload(_ id: ServiceID) async throws {
        guard let spec = await supervisor.spec(of: id) else { throw SupervisorError.unknownService(id) }
        guard spec.reloadSignal != nil else { throw SupervisorError.notReloadable(id) }
        if let failure = await preflightFailure(spec) {
            throw StackError.configTestFailed(id, failure)
        }
        try await supervisor.reload(id)
    }

    // MARK: Reload

    /// Config test (`httpd -t`) then graceful reload (SIGUSR1). FPM masters are never touched.
    public func reloadApache() async throws {
        guard let spec = await supervisor.spec(of: .apache) else { throw SupervisorError.unknownService(.apache) }
        if let failure = await preflightFailure(spec) {
            throw StackError.configTestFailed(.apache, failure)
        }
        try await supervisor.reload(.apache)
    }

    /// Re-renders every config; only services whose files changed are touched:
    /// httpd.conf / vhosts → `httpd -t` + graceful reload; a branch's php-fpm.conf / php.ini / conf.d → that
    /// FPM's `-t` + SIGUSR2; my.cnf / redis.conf → restart. Services entering the configured set (e.g. a newly
    /// enabled PHP branch) are started, services leaving it are stopped (`serviceSetChanges`); Apache is
    /// reloaded only when its files changed.
    @discardableResult
    public func applyConfigChanges() async throws -> ConfigApplyReport {
        try await ensurePhpMyAdminSetup()   // 04-04
        let config = try await configStore.load()
        var report = ConfigApplyReport()
        report.changed = try renderAndWrite(config)
        let specs = try specProvider(config, paths)
        let newIDs = specs.map(\.id)

        let registeredIDs = await supervisor.registeredIDs()
        var runningIDs = Set<ServiceID>()
        for id in registeredIDs where await supervisor.state(of: id).isRunning { runningIDs.insert(id) }
        let changes = Self.serviceSetChanges(previous: knownIDs, next: newIDs, registered: registeredIDs,
                                             running: runningIDs,
                                             autostart: Set(newIDs.filter { autostart($0, config) }))
        for id in changes.stop {
            await supervisor.stop(id)
            report.stopped.append(id)
        }
        knownIDs = newIDs

        let affected = Self.affectedServices(changed: report.changed, paths: paths)
        for spec in specs {
            let id = spec.id
            if changes.start.contains(id) {
                let newState = await supervisor.start(spec)
                if case .failed(let reason) = newState { report.errors[id] = reason } else { report.started.append(id) }
                continue
            }
            guard registeredIDs.contains(id) else { continue }
            let state = await supervisor.state(of: id)
            if affected.reload.contains(id) {
                guard state.isRunning else { continue }
                if let failure = await preflightFailure(spec) {
                    report.errors[id] = "configuration test failed, not reloaded: \(failure)"
                    report.preflightFailed[id] = failure
                    continue
                }
                do {
                    try await supervisor.reload(id)
                    report.reloaded.append(id)
                } catch {
                    report.errors[id] = "\(error)"
                }
            } else if affected.restart.contains(id) {
                guard state.isRunning || isBackingOff(state) else { continue }
                await supervisor.stop(id)
                let newState = await supervisor.start(spec)
                if case .failed(let reason) = newState { report.errors[id] = reason } else { report.restarted.append(id) }
            }
        }
        // Elasticsearch (06-03): not in `specs`; restarted only when already running (ElasticsearchService.swift).
        await restartElasticsearchIfAffected(changed: report.changed, config: config, report: &report)
        await syncMySQLTmpSocketLink()   // branch change / setting toggled
        return report
    }

    // MARK: /tmp/mysql.sock

    /// Makes the `/tmp/mysql.sock` link match the stack: MySQL running + `mysql.tmpSocketSymlink` → link to
    /// its socket (created / replaced when RAMP's own); otherwise RAMP's own link is removed. Foreign files
    /// are never touched; problems go to the MySQL log. Returns nil when the link is not managed.
    @discardableResult
    public func syncMySQLTmpSocketLink() async -> MySQLTmpSocketLink.Outcome? {
        guard let link = tmpSocketLink else { return nil }
        let config = try? await configStore.load()
        var candidates: [String] = config.map { [$0.mysql.branch] } ?? []
        for case .mysql(let major) in knownIDs where !candidates.contains(major) { candidates.append(major) }
        var running: String?
        for major in candidates where await supervisor.state(of: .mysql(major)).isRunning {
            running = major
            break
        }
        let outcome: MySQLTmpSocketLink.Outcome
        if let running, config?.mysql.tmpSocketSymlink ?? true {
            outcome = link.ensure(target: paths.mysqlSocket(major: running))
        } else {
            outcome = link.removeIfOwned()
        }
        if let warning = outcome.warning, let major = running ?? candidates.first,
           let log = try? LogSink(paths: paths).open(service: ServiceID.mysql(major).name) {
            LogSink.marker(log, "\(link.linkPath.path(percentEncoded: false)) \(warning)")
        }
        return outcome
    }

    /// Service-set diff for `applyConfigChanges` (only services entering / leaving the configured set; the
    /// rest is left alone):
    /// - stop: services of `previous` no longer in `next`, plus any running PHP-FPM no longer in `next`
    ///   (e.g. a disabled branch when `previous` is unknown). Services outside the spec set (Elasticsearch)
    ///   are never stopped here.
    /// - start (autostart only, not running): never-registered services, and services added to the set
    ///   (e.g. a re-enabled branch whose stopped spec is still registered). A service the user stopped
    ///   while it stayed in the set is not restarted.
    public static func serviceSetChanges(previous: [ServiceID], next: [ServiceID], registered: Set<ServiceID>,
                                         running: Set<ServiceID>, autostart: Set<ServiceID>)
        -> (stop: [ServiceID], start: [ServiceID]) {
        let nextSet = Set(next)
        var stop = previous.filter { !nextSet.contains($0) }
        let extra = running.filter { id in
            guard case .phpFPM = id else { return false }
            return !nextSet.contains(id) && !stop.contains(id)
        }
        stop += extra.sorted { $0.name < $1.name }
        let previousSet = Set(previous)
        let start = next.filter { id in
            guard autostart.contains(id), !running.contains(id) else { return false }
            return !registered.contains(id) || (!previous.isEmpty && !previousSet.contains(id))
        }
        return (stop, start)
    }

    /// Maps changed config files to the services that must pick them up.
    public static func affectedServices(changed: Set<URL>, paths: Paths) -> (reload: Set<ServiceID>, restart: Set<ServiceID>) {
        var reload = Set<ServiceID>()
        var restart = Set<ServiceID>()
        let apache = paths.apacheConfDir.standardizedFileURL.pathComponents
        let php = paths.confDir.appending(path: "php", directoryHint: .isDirectory).standardizedFileURL.pathComponents
        let mysql = paths.confDir.appending(path: "mysql", directoryHint: .isDirectory).standardizedFileURL.pathComponents
        let redis = paths.redisConfDir.standardizedFileURL.pathComponents
        let elasticsearch = paths.elasticsearchConfDir.standardizedFileURL.pathComponents
        for url in changed {
            let c = url.standardizedFileURL.pathComponents
            func under(_ prefix: [String]) -> String? {
                guard c.count > prefix.count, Array(c.prefix(prefix.count)) == prefix else { return nil }
                return c[prefix.count]
            }
            if under(apache) != nil {
                reload.insert(.apache)
            } else if let branch = under(php), c.count > php.count + 1,
                      !(c.count == php.count + 2 && c.last == Paths.phpCliIniName) {   // CLI-only file
                reload.insert(.phpFPM(branch))
            } else if let major = under(mysql), c.count > mysql.count + 1 {
                restart.insert(.mysql(major))
            } else if under(redis) != nil {
                restart.insert(.redis)
            } else if under(elasticsearch) != nil {
                restart.insert(.elasticsearch)
            }
        }
        return (reload, restart)
    }

    // MARK: Helpers

    /// `services[key].autostart`, key = apache / php / mysql / redis (custom ids: their name). Default true.
    private func autostart(_ id: ServiceID, _ config: RampConfig) -> Bool {
        let key: String
        switch id {
        case .apache: key = "apache"
        case .phpFPM: key = "php"
        case .mysql: key = "mysql"
        case .redis: key = "redis"
        case .elasticsearch: return false   // optional service, never autostarts (06-01)
        case .custom(let name): key = name
        }
        return config.services[key]?.autostart ?? true
    }

    private func isBackingOff(_ state: ServiceState) -> Bool {
        if case .backingOff = state { return true }
        return false
    }

    /// Runs the spec's config tests; returns the failure output or nil.
    private func preflightFailure(_ spec: ServiceSpec) async -> String? {
        for argv in spec.preflight where !argv.isEmpty {
            let result = await ProcessRunner.run(argv, environment: spec.resolvedEnvironment(),
                                                 cwd: spec.workingDirectory, tempDir: paths.tmp)
            if result.status != 0 {
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "exit \(result.status)" : text
            }
        }
        return nil
    }
}

public enum StackError: Error, LocalizedError, Equatable {
    case configTestFailed(ServiceID, String)

    public var errorDescription: String? {
        switch self {
        case .configTestFailed(let id, let output): return "\(id.displayName) configuration test failed: \(output)"
        }
    }
}

// MARK: - Vhost changes (03-05)

extension StackController {
    /// `applyConfigChanges()` that fails loudly when Apache rejects the new files: throws
    /// `VhostServiceError.apacheRejected(output)`. When Apache is not running (e.g. :80 busy) the regular
    /// apply skips the test, so it is run here explicitly — the next start must not meet a broken config.
    @discardableResult
    public func applyConfigChangesTestingApache() async throws -> ConfigApplyReport {
        let report = try await applyConfigChanges()
        if let failure = report.preflightFailed[.apache] { throw VhostServiceError.apacheRejected(failure) }
        if !report.reloaded.contains(.apache),
           Self.affectedServices(changed: report.changed, paths: paths).reload.contains(.apache),
           let failure = try await apacheConfigTestFailure() {
            throw VhostServiceError.apacheRejected(failure)
        }
        return report
    }

    /// Renders/writes/prunes every config and runs `httpd -t` without starting, stopping or reloading anything
    /// (rampctl in a process other than the running stack). Returns the test output on failure, nil when OK
    /// or Apache is not installed.
    public func writeConfigsTestingApache() async throws -> (changed: Set<URL>, apacheTestFailure: String?) {
        try paths.ensureDirectories()
        let config = try await configStore.load()
        let changed = try renderAndWrite(config)
        return (changed, try await apacheConfigTestFailure())
    }

    private func apacheConfigTestFailure() async throws -> String? {
        let config = try await configStore.load()
        guard let spec = try specProvider(config, paths).first(where: { $0.id == .apache }) else { return nil }
        return await preflightFailure(spec)
    }
}

extension StackController: VhostConfigApplying {
    public func applyVhostConfig() async throws {
        try await applyConfigChangesTestingApache()
    }
}
