import AppKit
import Foundation
import Observation
import RAMPCore

/// "Import z MAMP PRO" wizard (07-05): vhosts → databases → Elasticsearch (+ legacy LaunchAgent). Every step previews
/// first, can be skipped, and long steps (MySQL, ES) run in `MAMPImportCoordinator` with progress; the wizard state is
/// persisted so it resumes after relaunch.
@MainActor @Observable
final class ImportModel {
    /// UserDefaults: "Neukazovať znova" for the first-launch offer.
    static let offerDismissedKey = "mampImportOfferDismissed"

    struct VhostRow: Identifiable, Equatable {
        var candidate: ImportCandidate
        var include: Bool
        var phpBranch: String?
        var id: UUID { candidate.id }
        var hasError: Bool { candidate.issues.contains { $0.severity == .error } }
    }

    var step: MAMPImportStep = .vhosts
    private(set) var wizard = MAMPImportWizardState()

    // Vhosts
    private(set) var plan: ImportPlan?
    var rows: [VhostRow] = []
    private(set) var phpBranches: [String] = []
    private(set) var vhostsBusy = false
    private(set) var vhostsResult: VhostChangeResult?
    private(set) var vhostsError: String?
    /// PHP branches MAMP vhosts use that RAMP has not installed but can (e.g. EOL 7.4) → offered for install.
    private(set) var phpNeeds: [MAMPPHPNeed] = []

    // Databases
    var method: MigrationMethod = .datadirUpgrade { didSet { if oldValue != method { Task { await precheckMySQL() } } } }
    var rootPassword = "root"
    private(set) var mysqlPrecheck: MigrationPrecheck?
    private(set) var mysqlChecking = false
    private(set) var mysqlRunning = false
    private(set) var mysqlState: MigrationState?
    private(set) var mysqlError: String?
    private(set) var mysqlCopy: DatadirCopyProgress?
    private(set) var mysqlCopyStarted: Date?
    private(set) var mysqlServerLine: (branch: String, elapsed: Int, line: String?)?
    private(set) var mysqlCurrentStep: MigrationStep?
    private(set) var mysqlDatabase: (name: String, index: Int, total: Int)?

    // Elasticsearch
    private(set) var esSources: [ElasticsearchSource] = []
    var esSource: ElasticsearchSource? { didSet { if oldValue != esSource { refreshES() } } }
    private(set) var esPrecheck: ElasticsearchMigrationPrecheck?
    private(set) var esRunning = false
    private(set) var esProgress: ElasticsearchMigrationProgress?
    private(set) var esResult: ElasticsearchMigrationResult?
    private(set) var esError: String?
    var esSmoke = true
    private(set) var agents: [LegacyAgent] = []
    var agentConfirmed = false
    private(set) var agentBusy = false
    private(set) var agentResult: String?
    private(set) var agentError: String?

    /// First-launch offer shown this session.
    var showOffer = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var coordinatorStorage: MAMPImportCoordinator?
    @ObservationIgnored private var offerChecked = false

    var isRunning: Bool { vhostsBusy || mysqlRunning || esRunning || agentBusy }
    var mampFound: Bool { MAMPLocator.default() != nil }

    /// Set by `ensureCoordinator()` (the shared lock lives on the StackController actor).
    private var coordinator: MAMPImportCoordinator? { coordinatorStorage }

    func ensureCoordinator() async {
        guard coordinatorStorage == nil, let app else { return }
        let lock = await app.stack.maintenance
        if coordinatorStorage == nil {
            coordinatorStorage = MAMPImportCoordinator(paths: app.paths, store: app.configStore,
                                                       vhostService: app.vhostService, lock: lock)
        }
    }

    // MARK: Lifecycle

    func open() async {
        await ensureCoordinator()
        guard let coordinator else { return }
        wizard = await coordinator.state()
        mysqlState = coordinator.mysql.loadState()
        if let state = mysqlState, !state.isComplete { method = state.method }
        if plan == nil { await previewVhosts() }
    }

    /// First launch: offer the wizard once per session when MAMP PRO's config exists, until "Neukazovať znova"
    /// or the vhost step finished.
    func checkOffer() async {
        #if DEBUG
        if ScreenshotMode.isActive { return }
        #endif
        guard !offerChecked else { return }
        offerChecked = true
        guard !UserDefaults.standard.bool(forKey: Self.offerDismissedKey), mampFound else { return }
        await ensureCoordinator()
        guard let coordinator else { return }
        let state = await coordinator.state()
        guard state.status(.vhosts) != .done, state.status(.vhosts) != .skipped else { return }
        showOffer = true
    }

    func dismissOfferForever() {
        UserDefaults.standard.set(true, forKey: Self.offerDismissedKey)
        showOffer = false
    }

    func status(_ step: MAMPImportStep) -> MAMPImportStepStatus { wizard.status(step) }

    func skip(_ step: MAMPImportStep) async {
        guard let coordinator else { return }
        wizard = await coordinator.skip(step)
        advance(from: step)
    }

    func advance(from step: MAMPImportStep) {
        switch step {
        case .vhosts: self.step = .mysql
        case .mysql: self.step = .elasticsearch
        case .elasticsearch, .launchAgent: break
        }
    }

    /// App quit during a run: cancel (state persisted, resumable).
    func cancelAll() {
        if mysqlRunning { coordinator?.cancelMySQL() }
        if esRunning { Task { await coordinator?.cancelElasticsearch() } }
    }

    // MARK: Vhosts

    func previewVhosts() async {
        guard let coordinator, let app else { return }
        vhostsError = nil
        do {
            let config = try await app.stack.currentConfig()
            phpBranches = (config.installed["php"]?.keys.map { $0 } ?? []).sorted(by: UpdatePolicy.branchLess)
            let plan = try await coordinator.previewVhosts()
            self.plan = plan
            rows = plan.candidates.map { VhostRow(candidate: $0, include: $0.include, phpBranch: $0.vhost.phpBranch) }
            wizard = await coordinator.state()
            await app.php.loadOffers()
            phpNeeds = MAMPImportPlanner.installablePHPNeeds(candidates: plan.candidates, installed: Set(phpBranches),
                                                             offered: Set(app.php.offers.map(\.branch)))
        } catch {
            plan = nil
            rows = []
            vhostsError = error.localizedDescription
        }
    }

    var selectedCount: Int { rows.filter { $0.include && !$0.hasError }.count }

    /// Installs a PHP branch MAMP vhosts need, then re-plans (the vhosts map to it).
    func installPHP(_ branch: String) async {
        guard let app else { return }
        if await app.php.installBranch(branch) { await previewVhosts() }
    }

    func importVhosts() async {
        guard let coordinator, let app else { return }
        let vhosts = rows.filter { $0.include && !$0.hasError }.map { row -> Vhost in
            var v = row.candidate.vhost
            v.phpBranch = row.phpBranch
            return v
        }
        guard !vhosts.isEmpty else { return }
        vhostsBusy = true
        vhostsError = nil
        defer { vhostsBusy = false }
        do {
            vhostsResult = try await coordinator.applyVhosts(vhosts)
            if let hosts = vhostsResult?.hosts { app.hostsHelper.record(hosts) }
        } catch {
            vhostsError = error.localizedDescription
        }
        wizard = await coordinator.state()
        await app.reloadConfig()
    }

    // MARK: Databases

    func precheckMySQL() async {
        guard let coordinator, !mysqlRunning else { return }
        mysqlChecking = true
        defer { mysqlChecking = false }
        mysqlPrecheck = await coordinator.mysql.precheck(method: method)
        mysqlState = coordinator.mysql.loadState()
    }

    /// Method (a) needs MAMP MySQL stopped, (b) needs it running.
    var mysqlBlockedByMAMP: Bool {
        guard let p = mysqlPrecheck else { return false }
        return method == .datadirUpgrade ? p.sourceInUse : p.sourceReachable == false
    }

    var canResumeMySQL: Bool {
        guard let s = mysqlState else { return false }
        return !s.isComplete && s.method == method
    }

    func runMySQL() async {
        guard let coordinator, let app, !mysqlRunning else { return }
        mysqlRunning = true
        mysqlError = nil
        mysqlCopy = nil
        mysqlCopyStarted = nil
        defer { mysqlRunning = false }
        let options = MigrationOptions(method: method, rootPassword: rootPassword, leaveRunning: true)
        let (stream, continuation) = AsyncStream<MigrationProgress>.makeStream()
        let listener = Task { @MainActor [weak self] in
            for await event in stream { self?.handle(event) }
        }
        do {
            mysqlState = try await coordinator.runMySQL(options, progress: continuation)
        } catch {
            mysqlError = error.localizedDescription
            mysqlState = coordinator.mysql.loadState()
        }
        await listener.value
        mysqlCurrentStep = nil
        wizard = await coordinator.state()
        await app.reloadConfig()
    }

    private func handle(_ event: MigrationProgress) {
        switch event {
        case .step(let step):
            mysqlCurrentStep = step
            mysqlState = coordinator?.mysql.loadState()
        case .copy(let c):
            if mysqlCopyStarted == nil { mysqlCopyStarted = Date() }
            mysqlCopy = c
        case .server(let branch, let elapsed, let line): mysqlServerLine = (branch, elapsed, line)
        case .database(let name, let index, let total): mysqlDatabase = (name, index, total)
        case .phase, .info: break
        }
    }

    func cancelMySQL() { coordinator?.cancelMySQL() }

    func discardMySQL() async {
        guard let coordinator else { return }
        do {
            try await coordinator.discardMySQL()
            mysqlState = nil
            mysqlError = nil
        } catch {
            mysqlError = error.localizedDescription
        }
        wizard = await coordinator.state()
        await precheckMySQL()
    }

    /// Steps shown in the phase list for the current method (target 9.7).
    var mysqlSteps: [MigrationStep] {
        method == .logical ? [.importDatabases] : [.copy, .upgrade84, .convertUsers, .upgrade97, .verify, .activate]
    }

    func isDone(_ step: MigrationStep) -> Bool {
        guard let state = mysqlState, state.method == method else { return false }
        guard let next = MigrationStep.next(after: state) else { return true }
        let order = mysqlSteps
        guard let a = order.firstIndex(of: step), let b = order.firstIndex(of: next) else { return false }
        return a < b
    }

    /// Bytes per second + ETA of the datadir copy.
    var copyRate: (rate: Double, eta: TimeInterval?)? {
        guard let c = mysqlCopy, let started = mysqlCopyStarted else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 0.5 else { return nil }
        let rate = Double(c.bytesDone) / elapsed
        let eta = rate > 0 ? Double(c.bytesTotal - c.bytesDone) / rate : nil
        return (rate, eta)
    }

    // MARK: Elasticsearch

    func detectES() {
        guard let coordinator else { return }
        esSources = coordinator.detectElasticsearch()
        if esSource == nil { esSource = esSources.first } else { refreshES() }
    }

    func chooseESFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let source = ElasticsearchDataMigrator.source(at: url) {
            if !esSources.contains(source) { esSources.append(source) }
            esSource = source
        } else {
            esError = String(localized: "Vybraný priečinok nie je inštalácia Elasticsearch (chýba data/ alebo bin/elasticsearch)")
        }
    }

    func refreshES() {
        guard let coordinator, let source = esSource else {
            esPrecheck = nil
            agents = []
            return
        }
        esError = nil
        esPrecheck = coordinator.precheckElasticsearch(source)
        agents = coordinator.legacyAgents(for: source)
    }

    var esInstalledInRAMP: Bool {
        guard let app else { return false }
        return app.config.installed["elasticsearch"]?[app.config.elasticsearch.branch] != nil
    }

    func runES() async {
        guard let coordinator, let app, let source = esSource, !esRunning else { return }
        esRunning = true
        esError = nil
        esResult = nil
        esProgress = nil
        defer { esRunning = false }
        var smoke: (@Sendable () async throws -> [String: Int])?
        if esSmoke && esInstalledInRAMP {
            let service = app.elasticsearch.service
            let port = app.config.elasticsearch.httpPort
            smoke = {
                _ = try await service.start()
                defer { Task { await service.stop() } }
                var last: (any Error)?
                for _ in 0..<60 {
                    do { return try await ElasticsearchDataMigrator.catIndices(port: port) } catch {
                        last = error
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                throw last ?? CancellationError()
            }
        }
        do {
            esResult = try await coordinator.runElasticsearch(source, progress: { [weak self] p in
                Task { @MainActor in self?.esProgress = p }
            }, smoke: smoke)
        } catch {
            esError = error.localizedDescription
        }
        wizard = await coordinator.state()
        refreshES()
        await app.elasticsearch.refreshDataSize()
    }

    func cancelES() {
        Task { await coordinator?.cancelElasticsearch() }
    }

    func removeAgent(_ agent: LegacyAgent) async {
        guard let coordinator, let source = esSource, agentConfirmed else { return }
        agentBusy = true
        agentError = nil
        defer { agentBusy = false }
        do {
            let trashed = try await coordinator.removeLegacyAgent(agent, source: source, confirmed: true)
            agentResult = (trashed ?? agent.plistURL).path(percentEncoded: false)
            agentConfirmed = false
        } catch {
            agentError = error.localizedDescription
        }
        wizard = await coordinator.state()
        agents = coordinator.legacyAgents(for: source)
    }
}
