import Darwin
import Foundation

public enum PHPManagerError: Error, LocalizedError, Equatable {
    /// `php-fpm -t` rejected the new config; the previous config was restored and re-applied.
    case fpmRejected(branch: String, output: String)
    /// Clear OPcache / APCu needs a running FPM master.
    case notRunning(branch: String)
    /// Not an extension RAMP manages (`PHPExtensionCatalog`), or Xdebug (use the Xdebug mode instead).
    case unknownExtension(String)
    /// The branch cannot be disabled: it is the Apache default, runs phpMyAdmin and/or serves enabled vhosts
    /// (domains in config order).
    case branchInUse(branch: String, isDefault: Bool, phpMyAdmin: Bool, vhosts: [String])
    /// The branch cannot be uninstalled: it is the Apache default (or the only branch), phpMyAdmin's, and/or
    /// referenced by vhosts (enabled or not, domains in config order).
    case uninstallBlocked(branch: String, isDefault: Bool, phpMyAdmin: Bool, vhosts: [String])
    /// No manifest URL configured (`installBranch`).
    case noManifest
    /// The manifest offers no such PHP branch.
    case branchNotOffered(String)
    /// Uninstall needs the branch's FPM stopped, but it is supervised by another process (the app / `rampctl up`).
    case fpmRunningElsewhere(branch: String, pid: Int32)

    /// Domains shown in `branchInUse` messages (the rest is summarized as "…").
    public static let shownVhostDomains = 5

    public var errorDescription: String? {
        switch self {
        case .fpmRejected(let b, let output):
            return "PHP \(b) FPM rejected the configuration (previous settings restored): \(output)"
        case .notRunning(let b): return "PHP \(b) FPM is not running"
        case .unknownExtension(let name):
            return name == "xdebug" ? "Xdebug is switched via its mode (off/debug/profile), not as an extension"
                : "\(name) is not an extension RAMP manages"
        case .branchInUse(let b, let isDefault, let pma, let vhosts):
            var reasons: [String] = []
            if isDefault { reasons.append("it is the default PHP version") }
            if pma { reasons.append("it runs phpMyAdmin") }
            if !vhosts.isEmpty {
                var list = vhosts.prefix(Self.shownVhostDomains).joined(separator: ", ")
                if vhosts.count > Self.shownVhostDomains { list += ", …" }
                reasons.append("it is used by \(vhosts.count) \(vhosts.count == 1 ? "vhost" : "vhosts") (\(list))")
            }
            return "PHP \(b) cannot be disabled: " + reasons.joined(separator: "; ")
        case .uninstallBlocked(let b, let isDefault, let pma, let vhosts):
            var reasons: [String] = []
            if isDefault { reasons.append("it is the default PHP version") }
            if pma { reasons.append("it runs phpMyAdmin") }
            if !vhosts.isEmpty {
                var list = vhosts.prefix(Self.shownVhostDomains).joined(separator: ", ")
                if vhosts.count > Self.shownVhostDomains { list += ", …" }
                reasons.append("it is used by \(vhosts.count) \(vhosts.count == 1 ? "vhost" : "vhosts") (\(list))")
            }
            return "PHP \(b) cannot be uninstalled: " + reasons.joined(separator: "; ")
        case .noManifest: return "No manifest URL is configured."
        case .branchNotOffered(let b): return "PHP \(b) is not offered by the manifest."
        case .fpmRunningElsewhere(let b, let pid):
            return "PHP \(b) FPM (pid \(pid)) is supervised by another process — stop it there first "
                + "(RAMP app: switch the version off; rampctl up: rampctl php disable \(b))."
        }
    }
}

/// Where a php.ini override lives.
public enum PHPIniScope: Sendable, Equatable {
    /// `php.globalIniOverrides` — every branch.
    case global
    /// `php.branches[b].iniOverrides`.
    case branch(String)
}

/// What `PHPManager` needs from the running stack.
public protocol PHPStackControl: Sendable {
    /// Render + write + prune; changed PHP files → `php-fpm -t` + SIGUSR2 of that branch only.
    func applyConfigChanges() async throws -> ConfigApplyReport
    /// Graceful reload (SIGUSR2 → master re-exec, which drops OPcache + APCu shared memory) without a
    /// config change. Throws `PHPManagerError.notRunning` when the branch's FPM is not running.
    func reloadFPM(branch: String) async throws
    /// Uninstall: stop the branch's FPM now (its binaries are about to be deleted). Throws when it cannot.
    func stopFPMForRemoval(branch: String) async throws
}

extension PHPStackControl {
    public func stopFPMForRemoval(branch: String) async throws {}
}

extension StackController: PHPStackControl {
    public func reloadFPM(branch: String) async throws {
        let id = ServiceID.phpFPM(branch)
        guard await supervisor.state(of: id).isRunning else { throw PHPManagerError.notRunning(branch: branch) }
        try await supervisor.reload(id)
    }

    public func stopFPMForRemoval(branch: String) async throws {
        await supervisor.stop(.phpFPM(branch))
    }
}

/// Runtime PHP management: ini overrides, extensions, OPcache, APCu, Xdebug per branch.
///
/// Every mutation: build the new config → run the pure PHP generators (protected key, unavailable
/// extension, bad size… surface before anything is saved) → save → `stack.applyConfigChanges()` (only the
/// branches whose files changed get `php-fpm -t` + SIGUSR2; Apache is never touched) → a rejected
/// preflight restores and re-applies the previous config and throws `fpmRejected`.
public actor PHPManager {
    public let store: ConfigStore
    public let paths: Paths
    let stack: any PHPStackControl
    /// Downloads PHP branch packages (`installBranch`, PHPBranchLifecycle.swift).
    public let installer: PackageInstaller
    let loadManifest: @Sendable (URL) async throws -> Manifest

    public init(store: ConfigStore, stack: any PHPStackControl, paths: Paths, installer: PackageInstaller? = nil,
                loadManifest: @escaping @Sendable (URL) async throws -> Manifest = { try await ManifestLoader.load($0) }) {
        self.store = store
        self.stack = stack
        self.paths = paths
        self.installer = installer ?? PackageInstaller(paths: paths, configStore: store)
        self.loadManifest = loadManifest
    }

    public init(stack: StackController) {
        self.init(store: stack.configStore, stack: stack, paths: stack.paths, installer: stack.installer)
    }

    // MARK: Queries

    /// Effective php.ini directives with provenance (base / global / branch).
    public func effectiveIni(branch: String) async throws -> [IniDirective] {
        let config = try await store.load()
        _ = try GeneratorSupport.installedPHP(config, branch: branch)
        return try PHPIniLayers.effective(config: config, branch: branch, paths: paths)
    }

    /// Catalog extensions the branch's package ships (ext-dir scan fallback when unknown).
    public func availableExtensions(branch: String) async throws -> Set<String> {
        let config = try await loadWithKnownExtensions()
        _ = try GeneratorSupport.installedPHP(config, branch: branch)
        return PHPExtensionCatalog.available(branch: branch, config: config)
    }

    /// Effective-enabled extensions in load order (xdebug last when its mode ≠ off).
    public func enabledExtensions(branch: String) async throws -> [String] {
        let config = try await loadWithKnownExtensions()
        return try PHPConfDGenerator(config: config, paths: paths).enabledExtensions(branch: branch)
    }

    public func xdebugEnabledBranches() async throws -> [String] {
        XdebugStatus.enabledBranches(try await store.load())
    }

    // MARK: Mutations

    /// `value == nil` removes the override. A global override reloads every enabled branch (individually).
    @discardableResult
    public func setIniOverride(scope: PHPIniScope, key: String, value: String?) async throws -> ConfigApplyReport {
        if let value { try PHPIniLayers.validate(key: key, value: value) }
        return try await mutate(branch: scope.branch) { config in
            switch scope {
            case .global:
                config.php.globalIniOverrides[key] = value
            case .branch(let b):
                config.php.branches[b, default: PHPBranchSettings()].iniOverrides[key] = value
            }
        }
    }

    @discardableResult
    public func setExtension(branch: String, name: String, enabled: Bool) async throws -> ConfigApplyReport {
        guard let entry = PHPExtensionCatalog.entry(name), entry.kind == .extension else {
            throw PHPManagerError.unknownExtension(name)
        }
        return try await mutate(branch: branch) { config in
            config.php.branches[branch, default: PHPBranchSettings()].extensions[name] = enabled
        }
    }

    @discardableResult
    public func setXdebug(branch: String, mode: XdebugMode) async throws -> ConfigApplyReport {
        if mode == .profile {
            // Profile output dir (`xdebug.output_dir`), not part of Paths.ensureDirectories.
            try FileManager.default.createDirectory(at: paths.logs.appending(path: "xdebug", directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true)
        }
        return try await mutate(branch: branch) { config in
            config.php.branches[branch, default: PHPBranchSettings()].xdebug = mode
        }
    }

    @discardableResult
    public func setOPcache(branch: String, _ options: OPcacheOptions) async throws -> ConfigApplyReport {
        try await mutate(branch: branch) { config in
            config.php.branches[branch, default: PHPBranchSettings()].opcache = options
        }
    }

    @discardableResult
    public func setAPCu(branch: String, _ options: APCuOptions) async throws -> ConfigApplyReport {
        try await mutate(branch: branch) { config in
            config.php.branches[branch, default: PHPBranchSettings()].apcu = options
        }
    }

    /// Turns the whole branch on/off (`php.branches[b].enabled`): the running stack stops a disabled
    /// branch's FPM and starts it again when re-enabled. Disabling is refused (`branchInUse`) while the
    /// branch is the Apache default, runs phpMyAdmin or serves an enabled vhost.
    @discardableResult
    public func setBranchEnabled(branch: String, enabled: Bool) async throws -> ConfigApplyReport {
        if !enabled {
            let config = try await store.load()
            _ = try GeneratorSupport.installedPHP(config, branch: branch)
            if let blocker = Self.disableBlocker(config: config, paths: paths, branch: branch) { throw blocker }
        }
        return try await mutate(branch: branch) { config in
            config.php.branches[branch, default: PHPBranchSettings()].enabled = enabled
        }
    }

    /// Why `branch` cannot be disabled, or nil. Effective vhost branch = `vhost.phpBranch ?? default`;
    /// only enabled vhosts count; phpMyAdmin counts when installed + enabled.
    public nonisolated static func disableBlocker(config: RampConfig, paths: Paths, branch: String) -> PHPManagerError? {
        let defaultBranch = try? ApacheConfigGenerator(config: config, paths: paths).defaultPHPBranch()
        let isDefault = defaultBranch == branch
        let vhosts = config.vhosts.filter { $0.enabled && ($0.phpBranch ?? defaultBranch) == branch }.map(\.domain)
        let pma = PhpMyAdminConfigGenerator(config: config, paths: paths)
        let usedByPMA = config.phpmyadmin.enabled && pma.packageDirectory != nil && (try? pma.phpBranch()) == branch
        guard isDefault || usedByPMA || !vhosts.isEmpty else { return nil }
        return .branchInUse(branch: branch, isDefault: isDefault, phpMyAdmin: usedByPMA, vhosts: vhosts)
    }

    // MARK: Cache clearing

    /// Graceful FPM reload of `branch` only (no config change): the master re-execs → OPcache SHM is new.
    public func clearOPcache(branch: String) async throws {
        _ = try GeneratorSupport.installedPHP(try await store.load(), branch: branch)
        try await stack.reloadFPM(branch: branch)
    }

    /// Same mechanism as `clearOPcache`: APCu SHM belongs to the master and is dropped on re-exec.
    public func clearAPCu(branch: String) async throws {
        _ = try GeneratorSupport.installedPHP(try await store.load(), branch: branch)
        try await stack.reloadFPM(branch: branch)
    }

    // MARK: Internals

    /// Loads the config and persists the ext-dir scan result for records with unknown extensions (once).
    func loadWithKnownExtensions() async throws -> RampConfig {
        var config = try await store.load()
        if !PHPExtensionProbe.fillMissing(config: &config, paths: paths).isEmpty {
            try await store.save(config)
        }
        return config
    }

    func mutate(branch: String?, _ change: @Sendable (inout RampConfig) -> Void) async throws -> ConfigApplyReport {
        let previous = try await loadWithKnownExtensions()
        if let branch { _ = try GeneratorSupport.installedPHP(previous, branch: branch) }
        var next = previous
        change(&next)
        // A default entry created only by `branches[b, default:]` is not a change.
        for (b, s) in next.php.branches where previous.php.branches[b] == nil && s == PHPBranchSettings() {
            next.php.branches[b] = nil
        }
        guard next != previous else { return ConfigApplyReport() }
        try validatePHP(next, target: branch)

        try await store.save(next)
        let report: ConfigApplyReport
        do {
            report = try await stack.applyConfigChanges()
        } catch {
            try? await store.save(previous)
            _ = try? await stack.applyConfigChanges()
            throw error
        }
        let rejected = report.preflightFailed
            .compactMap { id, output -> (String, String)? in
                if case .phpFPM(let b) = id { return (b, output) }
                return nil
            }
            .sorted { $0.0 < $1.0 }
        if let (b, output) = rejected.first {
            try await store.save(previous)
            _ = try? await stack.applyConfigChanges()
            throw PHPManagerError.fpmRejected(branch: b, output: output)
        }
        return report
    }

    /// Pure PHP generators for every enabled branch (+ the target even if disabled).
    func validatePHP(_ config: RampConfig, target: String?) throws {
        var branches = GeneratorSupport.enabledPHPBranches(config)
        if let target, !branches.contains(target) { branches.append(target) }
        let fpm = PHPFPMConfigGenerator(config: config, paths: paths)
        let ini = PHPIniGenerator(config: config, paths: paths)
        for b in branches {
            _ = try fpm.render(branch: b)
            _ = try ini.files(branch: b)
        }
    }
}

private extension PHPIniScope {
    var branch: String? {
        if case .branch(let b) = self { return b }
        return nil
    }
}

/// `PHPStackControl` for a process that does not own the supervisor (rampctl next to a running
/// `rampctl up` / the app): renders + writes + prunes configs itself, runs `php-fpm -t` for every changed
/// branch, and signals the FPM master from its supervisor pid file (SIGUSR2 keeps the PID, so the owning
/// supervisor is unaffected). Non-PHP services with changed files are only reported in `errors`.
public struct DetachedPHPStack: PHPStackControl {
    public let paths: Paths
    public let store: ConfigStore

    public init(paths: Paths, store: ConfigStore) {
        self.paths = paths
        self.store = store
    }

    public func applyConfigChanges() async throws -> ConfigApplyReport {
        let config = try await store.load()
        var report = ConfigApplyReport()
        let files = try ConfigRenderer.renderAll(config: config, paths: paths)
        let writer = ConfigWriter(paths: paths)
        report.changed = try writer.write(files)
        let produced = Set(files.map { $0.path.standardizedFileURL })
        for managed in ConfigRenderer.managedDirectories(config: config, paths: paths) {
            report.changed.formUnion(try writer.prune(directory: managed.dir, keeping: produced, extension: managed.ext))
        }
        let affected = StackController.affectedServices(changed: report.changed, paths: paths)
        let specs = try ServiceSpecFactory.specs(config: config, paths: paths)
        for id in affected.reload.union(affected.restart).sorted(by: { $0.name < $1.name }) {
            guard case .phpFPM(let branch) = id else {
                report.errors[id] = "configuration changed; not applied by this process (run `rampctl reload`)"
                continue
            }
            guard let spec = specs.first(where: { $0.id == id }) else { continue }
            if let failure = await Self.preflightFailure(spec, tmp: paths.tmp) {
                report.errors[id] = "configuration test failed, not reloaded: \(failure)"
                report.preflightFailed[id] = failure
                continue
            }
            guard let pid = masterPID(branch: branch) else { continue }
            if kill(pid, spec.reloadSignal ?? SIGUSR2) == 0 {
                report.reloaded.append(id)
            } else {
                report.errors[id] = "cannot signal pid \(pid): errno \(errno)"
            }
        }
        return report
    }

    /// This process does not supervise the FPM: refuse while it runs (the owner would restart it).
    public func stopFPMForRemoval(branch: String) async throws {
        if let pid = masterPID(branch: branch) { throw PHPManagerError.fpmRunningElsewhere(branch: branch, pid: pid) }
    }

    public func reloadFPM(branch: String) async throws {
        guard let pid = masterPID(branch: branch) else { throw PHPManagerError.notRunning(branch: branch) }
        guard kill(pid, SIGUSR2) == 0 else {
            throw SupervisorError.signalFailed(.phpFPM(branch), errno: errno)
        }
    }

    /// Live FPM master PID from the supervisor pid file, or nil.
    public func masterPID(branch: String) -> pid_t? {
        let url = paths.pidFile(service: ServiceID.phpFPM(branch).name)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    private static func preflightFailure(_ spec: ServiceSpec, tmp: URL) async -> String? {
        for argv in spec.preflight where !argv.isEmpty {
            let result = await ProcessRunner.run(argv, environment: spec.resolvedEnvironment(),
                                                 cwd: spec.workingDirectory, tempDir: tmp)
            if result.status != 0 {
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "exit \(result.status)" : text
            }
        }
        return nil
    }
}
