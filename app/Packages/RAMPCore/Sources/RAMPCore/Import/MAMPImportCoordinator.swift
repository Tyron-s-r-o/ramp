import Foundation

/// Steps of the "Import z MAMP PRO" wizard (plan 07-05).
public enum MAMPImportStep: String, Sendable, Codable, CaseIterable, Hashable {
    case vhosts, mysql, elasticsearch, launchAgent
}

public enum MAMPImportStepStatus: String, Sendable, Codable, Equatable {
    case notStarted, previewed, running, done, skipped, failed
}

/// Persisted wizard state (`<root>/.staging/mamp-import/wizard.json`) — the wizard resumes after a relaunch.
public struct MAMPImportWizardState: Sendable, Codable, Equatable {
    /// Keyed by `MAMPImportStep.rawValue`.
    public var steps: [String: MAMPImportStepStatus] = [:]
    /// Last result / error line per step.
    public var messages: [String: String] = [:]
    public var importedVhosts: [String] = []
    public var elasticsearchSource: String?
    public var trashedPlist: String?
    public var updatedAt = Date()

    public init() {}

    public func status(_ step: MAMPImportStep) -> MAMPImportStepStatus { steps[step.rawValue] ?? .notStarted }
    public func message(_ step: MAMPImportStep) -> String? { messages[step.rawValue] }

    public mutating func set(_ step: MAMPImportStep, _ status: MAMPImportStepStatus, message: String? = nil) {
        steps[step.rawValue] = status
        if let message { messages[step.rawValue] = message } else if status != .failed { messages[step.rawValue] = nil }
    }

    /// Steps still `running` when loaded were interrupted (app quit / crash) → failed, resumable.
    mutating func markInterrupted() {
        for (key, status) in steps where status == .running {
            steps[key] = .failed
            messages[key] = "Prerušené — spusti znova pre pokračovanie"
        }
    }
}

/// `MaintenanceLock` as the MySQL migration's global lock (07-04 `MigrationLocking` hook, reason `.mampImport`).
extension MaintenanceLock: MigrationLocking {
    public func acquireForMySQLMigration() async throws -> @Sendable () async -> Void {
        let token = try acquire(.mampImport)
        return { [self] in await self.release(token) }
    }
}

/// Drives the MAMP PRO import (plan 07-05): vhosts (07-03 plan → `VhostService.addMany`), MySQL (07-04
/// `MySQLMigration`, which takes the maintenance lock itself), Elasticsearch data + legacy LaunchAgent.
/// Step state is persisted so the wizard resumes after relaunch. Mysql / ES steps hold `MaintenanceLock(.mampImport)`.
public actor MAMPImportCoordinator {
    public nonisolated let paths: Paths
    public nonisolated let mysql: MySQLMigration
    public nonisolated let elasticsearch: ElasticsearchDataMigrator
    public nonisolated let launchAgents: LegacyLaunchAgentRemover
    private let store: ConfigStore
    private let vhostService: VhostService
    private let lock: MaintenanceLock
    private let location: @Sendable () -> MAMPLocation?
    private let files: any FileChecking
    private var esCancel: CancelFlag?
    private var cached: MAMPImportWizardState?

    public init(paths: Paths, store: ConfigStore, vhostService: VhostService, lock: MaintenanceLock,
                mysql: MySQLMigration? = nil, elasticsearch: ElasticsearchDataMigrator? = nil,
                launchAgents: LegacyLaunchAgentRemover = LegacyLaunchAgentRemover(),
                location: @escaping @Sendable () -> MAMPLocation? = { MAMPLocator.default() },
                files: any FileChecking = LiveFileChecking()) {
        self.paths = paths
        self.store = store
        self.vhostService = vhostService
        self.lock = lock
        self.mysql = mysql ?? MySQLMigration(paths: paths, configStore: store, lock: lock)
        self.elasticsearch = elasticsearch ?? ElasticsearchDataMigrator(paths: paths)
        self.launchAgents = launchAgents
        self.location = location
        self.files = files
    }

    public static func stateURL(_ paths: Paths) -> URL {
        MySQLMigration.stagingDir(paths).appending(path: "wizard.json", directoryHint: .notDirectory)
    }

    // MARK: State

    public func state() -> MAMPImportWizardState {
        if let cached { return cached }
        var s = MAMPImportWizardState()
        if let data = try? Data(contentsOf: Self.stateURL(paths)),
           let decoded = try? MySQLMigration.decoder.decode(MAMPImportWizardState.self, from: data) {
            s = decoded
            s.markInterrupted()
        }
        cached = s
        return s
    }

    @discardableResult
    public func mark(_ step: MAMPImportStep, _ status: MAMPImportStepStatus, message: String? = nil)
        -> MAMPImportWizardState {
        var s = state()
        s.set(step, status, message: message)
        save(s)
        return s
    }

    public func skip(_ step: MAMPImportStep) -> MAMPImportWizardState { mark(step, .skipped) }

    /// Forget the wizard progress (the MySQL/ES staging data is untouched).
    public func reset() {
        cached = MAMPImportWizardState()
        try? FileManager.default.removeItem(at: Self.stateURL(paths))
    }

    private func save(_ state: MAMPImportWizardState) {
        var s = state
        s.updatedAt = Date()
        cached = s
        let dir = MySQLMigration.stagingDir(paths)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? MySQLMigration.encoder.encode(s) {
            try? data.write(to: Self.stateURL(paths), options: .atomic)
        }
    }

    // MARK: Vhosts

    /// MAMP PRO config found (readable httpd.conf)?
    public nonisolated var mampLocation: MAMPLocation? { location() }

    /// Dry-run plan against the current ramp.json and the installed PHP branches (`availableBranches` overrides).
    public func previewVhosts(availableBranches: Set<String>? = nil) async throws -> ImportPlan {
        guard let location = location() else {
            throw MAMPImportError.unreadable(path: MAMPLocator.locate().httpConf.path(percentEncoded: false))
        }
        let config = try await store.load()
        let branches = availableBranches ?? Set(config.installed["php"]?.keys.map { $0 } ?? [])
        let plan = try MAMPLocator.dryRun(location, existing: config, availableBranches: branches, files: files,
                                          paths: paths)
        if state().status(.vhosts) == .notStarted { mark(.vhosts, .previewed) }
        return plan
    }

    /// One validated batch: `VhostService.addMany` (one save, one Apache reload, one hosts sync; rollback on failure).
    public func applyVhosts(_ vhosts: [Vhost]) async throws -> VhostChangeResult {
        mark(.vhosts, .running)
        do {
            let result = try await vhostService.addMany(vhosts)
            var s = state()
            s.importedVhosts += vhosts.map(\.domain)
            s.set(.vhosts, .done, message: "\(vhosts.count)")
            save(s)
            return result
        } catch {
            mark(.vhosts, .failed, message: error.localizedDescription)
            throw error
        }
    }

    // MARK: MySQL (07-04 engine)

    public func runMySQL(_ options: MigrationOptions,
                         progress: AsyncStream<MigrationProgress>.Continuation? = nil) async throws -> MigrationState {
        mark(.mysql, .running)
        do {
            let result = try await mysql.run(options, progress: progress)
            mark(.mysql, .done)
            return result
        } catch {
            mark(.mysql, .failed, message: error.localizedDescription)
            throw error
        }
    }

    public nonisolated func cancelMySQL() {
        Task { await mysql.cancel() }
    }

    public func discardMySQL() async throws {
        try await mysql.discard()
        mark(.mysql, .notStarted)
    }

    // MARK: Elasticsearch

    public nonisolated func detectElasticsearch(extra: [URL] = []) -> [ElasticsearchSource] {
        ElasticsearchDataMigrator.detect(extra: extra)
    }

    public nonisolated func precheckElasticsearch(_ source: ElasticsearchSource) -> ElasticsearchMigrationPrecheck {
        elasticsearch.precheck(source: source)
    }

    public func runElasticsearch(_ source: ElasticsearchSource,
                                 progress: @escaping @Sendable (ElasticsearchMigrationProgress) -> Void = { _ in },
                                 smoke: (@Sendable () async throws -> [String: Int])? = nil)
        async throws -> ElasticsearchMigrationResult {
        let token = try await lock.acquire(.mampImport)
        let flag = CancelFlag()
        esCancel = flag
        var s = state()
        s.elasticsearchSource = source.root.path(percentEncoded: false)
        s.set(.elasticsearch, .running)
        save(s)
        do {
            let result = try await elasticsearch.run(source: source, cancel: flag, progress: progress, smoke: smoke)
            esCancel = nil
            await lock.release(token)
            mark(.elasticsearch, .done, message: "\(result.filesCopied + result.filesSkipped)")
            return result
        } catch {
            esCancel = nil
            await lock.release(token)
            mark(.elasticsearch, .failed, message: error.localizedDescription)
            throw error
        }
    }

    public func cancelElasticsearch() {
        esCancel?.cancel()
    }

    // MARK: LaunchAgent

    public nonisolated func legacyAgents(for source: ElasticsearchSource) -> [LegacyAgent] {
        launchAgents.find(referencing: source.root)
    }

    /// Only with `confirmed == true` (UI checkbox / `--yes-remove-launchagent`).
    @discardableResult
    public func removeLegacyAgent(_ agent: LegacyAgent, source: ElasticsearchSource, confirmed: Bool) async throws -> URL? {
        guard confirmed else { throw LegacyLaunchAgentError.notConfirmed }
        mark(.launchAgent, .running)
        do {
            let trashed = try await launchAgents.remove(agent, referencing: source.root, confirmed: true)
            var s = state()
            s.trashedPlist = trashed?.path(percentEncoded: false) ?? agent.plistURL.path(percentEncoded: false)
            s.set(.launchAgent, .done)
            save(s)
            return trashed
        } catch {
            mark(.launchAgent, .failed, message: error.localizedDescription)
            throw error
        }
    }
}
