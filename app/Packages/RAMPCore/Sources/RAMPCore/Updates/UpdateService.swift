import Foundation

/// Step reported by `UpdateService.apply`.
public enum UpdateProgress: Sendable, Equatable {
    case waitingForLock
    case dumping
    case downloading
    /// Byte progress of the running download (after `.downloading`, ~5 Hz).
    case downloadingBytes(DownloadProgress)
    case verifying
    case extracting
    case stopping
    case activating
    case restarting
    case checking
    case rollingBack
    case finished(UpdateOutcome)
}

public enum UpdateError: Error, LocalizedError, Equatable, Sendable {
    case busy(MaintenanceReason?)
    /// MySQL major changes are migrations (dump + datadir upgrade), never applied by the updater.
    case migrationNotSupportedHere(component: String, branch: String)
    case noManifest
    case manifest(String)
    case notInstalled(component: String, branch: String)
    case dumpFailed(String)
    /// Download / checksum / extraction failed — nothing was changed, no service was stopped.
    case prepareFailed(String)
    case activationFailed(String)
    /// The stack runs in another process (RAMP.app while using rampctl or vice versa).
    case stackRunningElsewhere(String)

    public var errorDescription: String? {
        switch self {
        case .busy(let reason): return MaintenanceError.busy(reason).errorDescription
        case .migrationNotSupportedHere(let c, let b):
            return "\(c) \(b) is a major-version migration (dump + data upgrade); it is not applied as an update."
        case .noManifest: return "No manifest URL is configured."
        case .manifest(let m): return "Loading the manifest failed: \(m)"
        case .notInstalled(let c, let b): return "\(c) \(b) is not installed."
        case .dumpFailed(let m): return "The MySQL backup dump failed, update aborted (nothing changed): \(m)"
        case .prepareFailed(let m): return "Update download/verification failed, nothing changed: \(m)"
        case .activationFailed(let m): return "Activating the new version failed: \(m)"
        case .stackRunningElsewhere(let m): return m
        }
    }
}

public enum UpdateOutcome: Sendable, Equatable {
    /// New version active and healthy (`from == nil`: new branch installed).
    case updated(from: String?, to: String)
    /// New version failed (start/health); `current` points at `to` (previous) again.
    case rolledBack(to: String, reason: String)
    /// Nothing changed (or, after a failed rollback, see reason).
    case failed(UpdateError)

    public var succeeded: Bool { if case .updated = self { true } else { false } }

    public var message: String {
        switch self {
        case .updated(let from?, let to): return "updated \(from) → \(to)"
        case .updated(nil, let to): return "installed \(to)"
        case .rolledBack(let to, let reason): return "rolled back to \(to): \(reason)"
        case .failed(let error): return error.errorDescription ?? "\(error)"
        }
    }
}

/// What `UpdateService` needs from the running stack (`StackController` conforms; tests fake it).
public protocol UpdateStackControlling: Sendable {
    func serviceState(_ id: ServiceID) async -> ServiceState
    func stopService(_ id: ServiceID) async
    func startService(_ id: ServiceID) async -> ServiceState
    /// Re-render + write every config (binaries resolve through `current`; e.g. extension_dir is per version).
    func renderConfigs() async throws
}

/// Applies updates safely (plan 07-02): lock → (MySQL) verified dump → prepare (no downtime) → stop affected
/// service → flip `current` → re-render → start → health probe → rollback on failure → prune old versions.
public actor UpdateService {
    public typealias ManifestLoading = @Sendable (URL) async throws -> Manifest

    public let installer: PackageInstaller
    public let store: ConfigStore
    private let stack: any UpdateStackControlling
    private let lock: MaintenanceLock
    private let dumper: any MySQLDumping
    private let probe: any HealthProbing
    private let loadManifest: ManifestLoading

    public init(installer: PackageInstaller, stack: any UpdateStackControlling, store: ConfigStore,
                lock: MaintenanceLock, dumper: any MySQLDumping, probe: any HealthProbing,
                loadManifest: @escaping ManifestLoading = { try await ManifestLoader.load($0) }) {
        self.installer = installer
        self.stack = stack
        self.store = store
        self.lock = lock
        self.dumper = dumper
        self.probe = probe
        self.loadManifest = loadManifest
    }

    /// Production wiring around a `StackController`.
    public init(stack: StackController) {
        self.init(installer: stack.installer, stack: stack, store: stack.configStore, lock: stack.maintenance,
                  dumper: MySQLDumper(paths: stack.paths), probe: HealthProbe(paths: stack.paths))
    }

    // MARK: Plan

    public func manifest() async throws -> Manifest {
        guard let url = try await store.load().manifestURL else { throw UpdateError.noManifest }
        do { return try await loadManifest(url) } catch { throw UpdateError.manifest(error.localizedDescription) }
    }

    public func plan(manifest: Manifest? = nil) async throws -> UpdatePlan {
        let resolved: Manifest
        if let manifest { resolved = manifest } else { resolved = try await self.manifest() }
        return UpdatePolicy.plan(manifest: resolved, config: try await store.load())
    }

    // MARK: Apply

    /// Applies every `.automatic` item sequentially.
    public func applyAutomatic(_ plan: UpdatePlan, manifest: Manifest? = nil,
                               progress: @escaping @Sendable (UpdateItem, UpdateProgress) -> Void = { _, _ in })
        async -> [(UpdateItem, UpdateOutcome)] {
        var results: [(UpdateItem, UpdateOutcome)] = []
        for item in plan.automatic {
            let outcome = await apply(item, manifest: manifest) { progress(item, $0) }
            results.append((item, outcome))
        }
        return results
    }

    public func apply(_ item: UpdateItem, manifest: Manifest? = nil,
                      progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async -> UpdateOutcome {
        let outcome = await applyLocked(item, manifest: manifest, progress: progress)
        progress(.finished(outcome))
        return outcome
    }

    private func applyLocked(_ item: UpdateItem, manifest: Manifest?,
                             progress: @escaping @Sendable (UpdateProgress) -> Void) async -> UpdateOutcome {
        if item.kind == .migration {
            return .failed(.migrationNotSupportedHere(component: item.component, branch: item.branch))
        }
        let token: MaintenanceToken
        do {
            token = try await lock.acquire(.update)
        } catch let MaintenanceError.busy(reason) {
            return .failed(.busy(reason))
        } catch {
            return .failed(.busy(nil))
        }
        let outcome = await run(item, manifest: manifest, progress: progress)
        await lock.release(token)
        return outcome
    }

    private func run(_ item: UpdateItem, manifest: Manifest?,
                     progress: @escaping @Sendable (UpdateProgress) -> Void) async -> UpdateOutcome {
        let resolved: Manifest
        let config: RampConfig
        do {
            if let manifest { resolved = manifest } else { resolved = try await self.manifest() }
            config = try await store.load()
        } catch let e as UpdateError {
            return .failed(e)
        } catch {
            return .failed(.manifest(error.localizedDescription))
        }
        let component = item.component, branch = item.branch

        if item.kind == .newBranch {
            return await installNewBranch(item, manifest: resolved, progress: progress)
        }
        guard let oldRecord = config.installed[component]?[branch] else {
            return .failed(.notInstalled(component: component, branch: branch))
        }
        let serviceID = Self.affectedService(component: component, branch: branch, config: config)

        // 1. MySQL: verified dump first (active branch only); failure aborts before anything changes.
        if component == "mysql", item.requiresDumpFirst, branch == config.mysql.branch {
            progress(.dumping)
            do { _ = try await dumper.automaticDump(config: config) } catch {
                return .failed(.dumpFailed(error.localizedDescription))
            }
        }

        // 2. Prepare: download + verify + extract — no downtime.
        let prepared: PreparedPackage
        do {
            prepared = try await prepareForwarding(component: component, branch: branch, manifest: resolved,
                                                   progress: progress)
        } catch {
            return .failed(.prepareFailed(error.localizedDescription))
        }
        if prepared.version == oldRecord.version {
            return .updated(from: oldRecord.version, to: oldRecord.version)   // nothing newer (idempotent)
        }

        // 3. Stop the affected service (only if it runs).
        var wasRunning = false
        if let serviceID {
            let state = await stack.serviceState(serviceID)
            wasRunning = state.isRunning || Self.isBackingOff(state) || state == .starting
            if wasRunning {
                progress(.stopping)
                await stack.stopService(serviceID)
            }
        }

        // 4. Flip + record, re-render, start, probe.
        progress(.activating)
        do {
            try await installer.activate(prepared)
        } catch {
            // `current` flip is atomic: either still old (→ just restart) or new (→ roll back).
            return await rollback(item: item, oldRecord: oldRecord, serviceID: serviceID, wasRunning: wasRunning,
                                  reason: "activation failed: \(error.localizedDescription)", progress: progress)
        }
        let failure = await startAndProbe(component: component, branch: branch, serviceID: serviceID,
                                          wasRunning: wasRunning, progress: progress)
        if let failure {
            return await rollback(item: item, oldRecord: oldRecord, serviceID: serviceID, wasRunning: wasRunning,
                                  reason: failure, progress: progress)
        }

        // 5. Success → keep current + previous, prune older versions of this branch.
        _ = try? await installer.prune(component: component, branch: branch, current: prepared.version,
                                       previous: oldRecord.version)
        return .updated(from: oldRecord.version, to: prepared.version)
    }

    /// Re-render + (if it ran before) start + probe. Returns the failure reason or nil.
    private func startAndProbe(component: String, branch: String, serviceID: ServiceID?, wasRunning: Bool,
                               progress: @escaping @Sendable (UpdateProgress) -> Void) async -> String? {
        do { try await stack.renderConfigs() } catch { return "config render failed: \(error.localizedDescription)" }
        let config = (try? await store.load()) ?? RampConfig()
        if let serviceID, wasRunning {
            progress(.restarting)
            let state = await stack.startService(serviceID)
            guard state.isRunning else {
                switch state {
                case .failed(let reason): return "\(serviceID.displayName) did not start: \(reason)"
                case .backingOff:
                    return "\(serviceID.displayName) exited right after start (see \(serviceID.name).log)"
                default:
                    return "\(serviceID.displayName) did not become ready (see \(serviceID.name).log)"
                }
            }
        }
        progress(.checking)
        let result = await probe.check(component: component, branch: branch, config: config,
                                       serviceRunning: serviceID != nil && wasRunning)
        return result.ok ? nil : "health check failed: \(result.detail)"
    }

    private func rollback(item: UpdateItem, oldRecord: InstalledPackage, serviceID: ServiceID?, wasRunning: Bool,
                          reason: String, progress: @escaping @Sendable (UpdateProgress) -> Void) async -> UpdateOutcome {
        progress(.rollingBack)
        if let serviceID { await stack.stopService(serviceID) }   // also cancels a backoff restart loop
        do {
            try await installer.switchCurrent(component: item.component, branch: item.branch,
                                              toVersion: oldRecord.version)
            try await installer.setRecord(oldRecord, component: item.component, branch: item.branch)
        } catch {
            return .failed(.activationFailed("\(reason); rollback to \(oldRecord.version) failed: "
                + error.localizedDescription))
        }
        // The new version dir stays on disk for diagnosis (pruned by a later successful update).
        if let second = await startAndProbe(component: item.component, branch: item.branch, serviceID: serviceID,
                                            wasRunning: wasRunning, progress: progress) {
            return .rolledBack(to: oldRecord.version, reason: "\(reason) (previous version is not healthy either: \(second))")
        }
        return .rolledBack(to: oldRecord.version, reason: reason)
    }

    /// `.newBranch`: plain install; a new PHP branch starts disabled (no FPM starts unasked).
    private func installNewBranch(_ item: UpdateItem, manifest: Manifest,
                                  progress: @escaping @Sendable (UpdateProgress) -> Void) async -> UpdateOutcome {
        let prepared: PreparedPackage
        do {
            prepared = try await prepareForwarding(component: item.component, branch: item.branch, manifest: manifest,
                                                   progress: progress)
        } catch {
            return .failed(.prepareFailed(error.localizedDescription))
        }
        progress(.activating)
        do {
            if item.component == "php" {
                let branch = item.branch
                try await store.update { config in
                    if config.php.branches[branch] == nil {
                        config.php.branches[branch] = PHPBranchSettings(enabled: false)
                    }
                }
            }
            let record = try await installer.activate(prepared)
            try await stack.renderConfigs()
            return .updated(from: nil, to: record.version)
        } catch {
            return .failed(.activationFailed(error.localizedDescription))
        }
    }

    // MARK: Manual rollback

    /// Switches a branch back to its recorded `previousVersion` (+ restart when running + probe). The
    /// replaced version becomes the new `previous`.
    public func rollbackToPrevious(component: String, branch: String) async -> UpdateOutcome {
        let token: MaintenanceToken
        do { token = try await lock.acquire(.update) } catch let MaintenanceError.busy(reason) {
            return .failed(.busy(reason))
        } catch { return .failed(.busy(nil)) }
        let outcome = await rollbackLocked(component: component, branch: branch)
        await lock.release(token)
        return outcome
    }

    private func rollbackLocked(component: String, branch: String) async -> UpdateOutcome {
        guard let config = try? await store.load(), let record = config.installed[component]?[branch] else {
            return .failed(.notInstalled(component: component, branch: branch))
        }
        guard let previous = record.previousVersion else {
            return .failed(.activationFailed("\(component) \(branch) has no previous version recorded"))
        }
        let serviceID = Self.affectedService(component: component, branch: branch, config: config)
        var wasRunning = false
        if let serviceID {
            let state = await stack.serviceState(serviceID)
            wasRunning = state.isRunning || Self.isBackingOff(state)
            if wasRunning { await stack.stopService(serviceID) }
        }
        var swapped = record
        swapped.version = previous
        swapped.sha256 = record.previousSHA256 ?? record.sha256
        swapped.previousVersion = record.version
        swapped.previousSHA256 = record.sha256
        swapped.installedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        do {
            try await installer.switchCurrent(component: component, branch: branch, toVersion: previous)
            try await installer.setRecord(swapped, component: component, branch: branch)
        } catch {
            if let serviceID, wasRunning { _ = await stack.startService(serviceID) }
            return .failed(.activationFailed(error.localizedDescription))
        }
        if let failure = await startAndProbe(component: component, branch: branch, serviceID: serviceID,
                                             wasRunning: wasRunning, progress: { _ in }) {
            // Undo: back to the version that was active before.
            if let serviceID { await stack.stopService(serviceID) }
            try? await installer.switchCurrent(component: component, branch: branch, toVersion: record.version)
            try? await installer.setRecord(record, component: component, branch: branch)
            _ = await startAndProbe(component: component, branch: branch, serviceID: serviceID,
                                    wasRunning: wasRunning, progress: { _ in })
            return .rolledBack(to: record.version, reason: failure)
        }
        return .updated(from: record.version, to: previous)
    }

    // MARK: Helpers

    private func prepareForwarding(component: String, branch: String, manifest: Manifest,
                                   progress: @escaping @Sendable (UpdateProgress) -> Void) async throws -> PreparedPackage {
        let (stream, continuation) = AsyncStream<InstallProgress>.makeStream()
        let forwarder = Task {
            for await event in stream {
                switch event.stage {
                case .downloading: progress(event.download.map { .downloadingBytes($0) } ?? .downloading)
                case .verifying: progress(.verifying)
                case .extracting: progress(.extracting)
                default: break
                }
            }
        }
        defer { forwarder.cancel() }
        do {
            let prepared = try await installer.prepare(component: component, branch: branch, from: manifest,
                                                       progress: continuation)
            continuation.finish()
            await forwarder.value
            return prepared
        } catch {
            continuation.finish()
            await forwarder.value
            throw error
        }
    }

    /// The one service that must be restarted for `component/branch`, or nil (phpMyAdmin, a branch that is
    /// not the active one, a disabled PHP branch). Elasticsearch counts only while running (checked later).
    public static func affectedService(component: String, branch: String, config: RampConfig) -> ServiceID? {
        switch component {
        case "php":
            return (config.php.branches[branch]?.enabled ?? true) ? .phpFPM(branch) : nil
        case "apache":
            return GeneratorSupport.highestBranch(config, component: "apache") == branch ? .apache : nil
        case "redis":
            return GeneratorSupport.highestBranch(config, component: "redis") == branch ? .redis : nil
        case "mysql":
            return config.mysql.branch == branch ? .mysql(branch) : nil
        case "elasticsearch":
            return config.elasticsearch.branch == branch ? .elasticsearch : nil
        default:
            return nil
        }
    }

    private static func isBackingOff(_ state: ServiceState) -> Bool {
        if case .backingOff = state { return true }
        return false
    }
}

// MARK: - StackController as the update target

extension StackController: UpdateStackControlling {
    public func serviceState(_ id: ServiceID) async -> ServiceState {
        await supervisor.state(of: id)
    }

    public func stopService(_ id: ServiceID) async {
        await stop(id)
    }

    public func startService(_ id: ServiceID) async -> ServiceState {
        if id == .elasticsearch {
            do { return try await ElasticsearchService(stack: self).start() } catch {
                return .failed(reason: error.localizedDescription)
            }
        }
        return await start(id)
    }

    public func renderConfigs() async throws {
        _ = try await prepare()
    }
}
