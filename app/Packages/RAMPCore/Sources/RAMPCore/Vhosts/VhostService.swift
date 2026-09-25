import Foundation

public enum VhostServiceError: Error, Equatable, LocalizedError {
    /// `httpd -t` rejected the generated config; the previous config was restored.
    case apacheRejected(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .apacheRejected(let output): return "Apache rejected the configuration (change rolled back): \(output)"
        case .notFound(let name): return "No vhost named \(name)"
        }
    }
}

/// Writes the configs derived from the saved `ramp.json` and makes Apache pick them up.
/// Throws `VhostServiceError.apacheRejected` when the Apache config test fails.
public protocol VhostConfigApplying: Sendable {
    func applyVhostConfig() async throws
}

/// What happened to the hosts file after a vhost change.
public enum HostsSyncState: Sendable, Equatable {
    /// `hosts.manageHostsFile == false`.
    case notManaged
    case synced(HostsSyncOutcome)
    /// Vhost was applied, but the hosts file could not be updated (cancelled prompt, helper error) — offer "Retry".
    case pending(reason: String)
}

public struct VhostChangeResult: Sendable, Equatable {
    public var config: RampConfig
    public var warnings: [VhostIssue]
    public var hosts: HostsSyncState
}

/// One call per vhost change: validate (`VhostCatalog`) → save → regenerate + `httpd -t` + graceful reload
/// (rollback to the previous config when Apache rejects it) → sync the hosts block. Changes are serialized.
public actor VhostService {
    private let store: ConfigStore
    private let applier: any VhostConfigApplying
    private let hosts: any HostsSyncing
    private let catalog: VhostCatalog
    private var tail: Task<Void, Never>?

    public init(store: ConfigStore, applier: any VhostConfigApplying, hosts: any HostsSyncing,
                catalog: VhostCatalog? = nil) {
        self.store = store
        self.applier = applier
        self.hosts = hosts
        self.catalog = catalog ?? VhostCatalog(paths: store.paths)
    }

    public init(store: ConfigStore, stack: StackController, hosts: any HostsSyncing) {
        self.init(store: store, applier: stack, hosts: hosts)
    }

    public func list() async throws -> [Vhost] {
        try await store.load().vhosts
    }

    /// Vhost by domain or alias (case-insensitive, default TLD appended to dot-less names).
    public func find(_ name: String) async throws -> Vhost {
        let config = try await store.load()
        let wanted = Vhost.normalizeDomain(name, tld: config.hosts.defaultTLD)
        guard let v = config.vhosts.first(where: { $0.domain == wanted })
                ?? config.vhosts.first(where: { $0.aliases.contains(wanted) })
        else { throw VhostServiceError.notFound(wanted) }
        return v
    }

    @discardableResult
    public func add(_ vhost: Vhost) async throws -> VhostChangeResult {
        try await change { [catalog] in try catalog.add(vhost, in: $0) }
    }

    /// Batch add (MAMP import, 07-05): every vhost validated in turn against the growing config (first error
    /// throws, nothing written) → one save → one Apache apply (rollback on rejection) → one hosts sync.
    @discardableResult
    public func addMany(_ vhosts: [Vhost]) async throws -> VhostChangeResult {
        try await change { [catalog] config in
            var next = config
            var warnings: [VhostIssue] = []
            for vhost in vhosts {
                let result = try catalog.add(vhost, in: next)
                next = result.config
                for w in result.warnings where !warnings.contains(w) { warnings.append(w) }
            }
            return VhostCatalog.Result(config: next, warnings: warnings)
        }
    }

    @discardableResult
    public func update(_ vhost: Vhost) async throws -> VhostChangeResult {
        try await change { [catalog] in try catalog.update(vhost, in: $0) }
    }

    @discardableResult
    public func remove(id: UUID) async throws -> VhostChangeResult {
        try await change { [catalog] in try catalog.remove(id: id, in: $0) }
    }

    @discardableResult
    public func setEnabled(id: UUID, _ enabled: Bool) async throws -> VhostChangeResult {
        try await change { [catalog] in try catalog.setEnabled(id: id, enabled, in: $0) }
    }

    /// Moves vhosts into a group (`nil` = ungrouped). Groups are UI-only: saved to `ramp.json` without an Apache
    /// apply or hosts sync (the rendered config cannot change). Returns the saved config.
    @discardableResult
    public func setGroup(ids: Set<UUID>, _ group: String?) async throws -> RampConfig {
        try await serialized { [store, catalog] in
            let next = try catalog.setGroup(ids: ids, group, in: try await store.load()).config
            try await store.save(next)
            return next
        }
    }

    /// One-time "group by Sites folders": fills the group of every ungrouped vhost from `VhostGroupSuggester`.
    /// Saves only when something changed. Returns the ids that got a group.
    @discardableResult
    public func autoGroup(sitesRoot: String) async throws -> [UUID] {
        try await serialized { [store] in
            let (next, changed) = VhostCatalog.autoGroup(try await store.load(), sitesRoot: sitesRoot)
            if !changed.isEmpty { try await store.save(next) }
            return changed
        }
    }

    /// Brings the hosts block in line with the saved config (app start, "Retry").
    public func syncHosts() async -> HostsSyncState {
        do {
            return await hostsStep(try await store.load())
        } catch {
            return .pending(reason: error.localizedDescription)
        }
    }

    // MARK: private

    private func change(_ transform: @escaping @Sendable (RampConfig) throws -> VhostCatalog.Result)
        async throws -> VhostChangeResult {
        try await serialized { [self] in try await self.perform(transform) }
    }

    private func perform(_ transform: @Sendable (RampConfig) throws -> VhostCatalog.Result)
        async throws -> VhostChangeResult {
        let previous = try await store.load()
        let result = try transform(previous)            // validation errors thrown unchanged, nothing written
        try await store.save(result.config)
        do {
            try await applier.applyVhostConfig()
        } catch {
            // Never leave Apache (or ramp.json) with a config it rejected: restore and re-render the previous one.
            try await store.save(previous)
            _ = try? await applier.applyVhostConfig()
            throw error
        }
        let hostsState = await hostsStep(result.config)
        return VhostChangeResult(config: result.config, warnings: result.warnings, hosts: hostsState)
    }

    private func hostsStep(_ config: RampConfig) async -> HostsSyncState {
        guard config.hosts.manageHostsFile else { return .notManaged }
        do {
            return .synced(try await hosts.apply(names: VhostCatalog.enabledHostnames(in: config)))
        } catch {
            return .pending(reason: error.localizedDescription)
        }
    }

    /// Actor methods are re-entrant across `await`; chain changes so load → save → apply never interleave.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
