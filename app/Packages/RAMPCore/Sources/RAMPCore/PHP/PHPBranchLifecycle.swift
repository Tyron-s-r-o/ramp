import Foundation

/// One PHP branch the manifest offers, with its install state (PHP › Pridať verziu PHP, `rampctl php available`).
public struct PHPBranchOffer: Sendable, Equatable, Identifiable {
    public let branch: String
    /// Manifest version (the one an install would get).
    public let version: String
    /// Archive size in bytes, if published.
    public let size: Int64?
    public let support: PHPSupportStatus?
    /// End of (security) support, `YYYY-MM-DD`.
    public let eolDate: String?
    /// Installed version, nil when not installed.
    public let installedVersion: String?
    /// Why the installed branch cannot be uninstalled (nil = it can, or not installed).
    public let uninstallBlocker: PHPManagerError?

    public var id: String { branch }
    public var isInstalled: Bool { installedVersion != nil }
    public var isEOL: Bool { support == .eol }
}

// MARK: - Install / uninstall of whole PHP branches

extension PHPManager {
    /// Manifest PHP branches (highest first) with install state and uninstall guard.
    public func offers(manifest: Manifest? = nil) async throws -> [PHPBranchOffer] {
        let resolved = try await resolveManifest(manifest)
        let config = try await store.load()
        return Self.offers(manifest: resolved, config: config, paths: paths)
    }

    public nonisolated static func offers(manifest: Manifest, config: RampConfig, paths: Paths) -> [PHPBranchOffer] {
        manifest.branches(of: "php").reversed().compactMap { branch in
            guard let e = manifest.entry(component: "php", branch: branch) else { return nil }
            let installed = config.installed["php"]?[branch]
            return PHPBranchOffer(branch: branch, version: e.version, size: e.size, support: e.support,
                                  eolDate: e.eolDate, installedVersion: installed?.version,
                                  uninstallBlocker: installed == nil ? nil
                                      : uninstallBlocker(config: config, paths: paths, branch: branch))
        }
    }

    /// Downloads + installs PHP `branch` from the manifest (`manifest` or `config.manifestURL`), enables it and
    /// applies the configs — the running stack starts its FPM, terminal shims follow the render. A branch
    /// already installed is only (re-)enabled. When the new branch would become the highest one, an implicit
    /// Apache default / phpMyAdmin branch is pinned to the current one first (existing sites never move).
    /// `progress` gets the package stages and is finished when done.
    @discardableResult
    public func installBranch(_ branch: String, manifest: Manifest? = nil,
                              progress: AsyncStream<InstallProgress>.Continuation? = nil) async throws -> InstalledPackage {
        defer { progress?.finish() }
        do {
            guard PHPBranch(branch) != nil else { throw PHPManagerError.branchNotOffered(branch) }
            let config = try await store.load()
            if let existing = config.installed["php"]?[branch] {
                if !(config.php.branches[branch]?.enabled ?? true) {
                    try await setBranchEnabled(branch: branch, enabled: true)
                }
                progress?.yield(InstallProgress(component: "php", branch: branch, stage: .installed(existing)))
                return existing
            }
            let resolved = try await resolveManifest(manifest)
            guard resolved.entry(component: "php", branch: branch) != nil else {
                throw PHPManagerError.branchNotOffered(branch)
            }
            let prepared = try await installer.prepare(component: "php", branch: branch, from: resolved,
                                                       progress: progress)

            let previous = try await store.load()
            var next = previous
            Self.pinDefaults(&next, installing: branch)
            if next.php.branches[branch] != nil { next.php.branches[branch]?.enabled = true }
            if next != previous { try await store.save(next) }
            let record: InstalledPackage
            do {
                record = try await installer.activate(prepared, progress: progress)
            } catch {
                if next != previous { try? await store.save(previous) }
                throw error
            }
            // Render + (running stack) start the new FPM. A failed FPM start stays visible in Služby.
            _ = try await stack.applyConfigChanges()
            return record
        } catch {
            progress?.yield(InstallProgress(component: "php", branch: branch, stage: .failed(Self.describe(error))))
            throw error
        }
    }

    /// Removes PHP `branch` completely: guards (`uninstallBlocker`) → stop its FPM → drop the install record,
    /// branch settings and a `cli.defaultPHP` pointing at it → apply (configs re-rendered, shims re-synced) →
    /// delete `<root>/php/<branch>`, its version dirs, `conf/php/<branch>`, socket / pid file, cached downloads
    /// and its logs. A failed apply restores the previous config (files untouched).
    public func uninstallBranch(_ branch: String) async throws {
        let config = try await store.load()
        let record = try GeneratorSupport.installedPHP(config, branch: branch)
        if let blocker = Self.uninstallBlocker(config: config, paths: paths, branch: branch) { throw blocker }
        try await stack.stopFPMForRemoval(branch: branch)

        var next = config
        next.installed["php"]?[branch] = nil
        if next.installed["php"]?.isEmpty == true { next.installed["php"] = nil }
        next.php.branches[branch] = nil
        if next.cli.defaultPHP == branch { next.cli.defaultPHP = nil }
        try await store.save(next)
        do {
            _ = try await stack.applyConfigChanges()
        } catch {
            try? await store.save(config)
            _ = try? await stack.applyConfigChanges()
            throw error
        }
        try removeBranchFiles(branch: branch, record: record, remaining: next)
    }

    /// Why `branch` cannot be uninstalled, or nil: it is the Apache default (explicit or implicit) or the only
    /// installed branch, phpMyAdmin runs on it / is pinned to it, or any vhost (enabled or not) uses it.
    public nonisolated static func uninstallBlocker(config: RampConfig, paths: Paths, branch: String) -> PHPManagerError? {
        let installed = config.installed["php"] ?? [:]
        let defaultBranch = try? ApacheConfigGenerator(config: config, paths: paths).defaultPHPBranch()
        let isDefault = defaultBranch == branch || config.apache.defaultPHP == branch
            || (installed.count == 1 && installed[branch] != nil)
        let vhosts = config.vhosts.filter { ($0.phpBranch ?? defaultBranch) == branch }.map(\.domain)
        let pma = PhpMyAdminConfigGenerator(config: config, paths: paths)
        let usedByPMA = pma.packageDirectory != nil && (config.phpmyadmin.phpBranch == branch
            || (config.phpmyadmin.enabled && (try? pma.phpBranch()) == branch))
        guard isDefault || usedByPMA || !vhosts.isEmpty else { return nil }
        return .uninstallBlocked(branch: branch, isDefault: isDefault, phpMyAdmin: usedByPMA, vhosts: vhosts)
    }

    /// A new highest branch would become the implicit Apache default / phpMyAdmin branch → pin both to the
    /// current highest enabled branch first.
    nonisolated static func pinDefaults(_ config: inout RampConfig, installing branch: String) {
        guard let new = PHPBranch(branch), let highest = GeneratorSupport.enabledPHPBranches(config).last,
              let current = PHPBranch(highest), new > current else { return }
        if config.apache.defaultPHP == nil { config.apache.defaultPHP = highest }
        if config.phpmyadmin.phpBranch == nil, !(config.installed["phpmyadmin"] ?? [:]).isEmpty {
            config.phpmyadmin.phpBranch = highest
        }
    }

    // MARK: Internals

    private func resolveManifest(_ manifest: Manifest?) async throws -> Manifest {
        if let manifest { return manifest }
        guard let url = try await store.load().manifestURL else { throw PHPManagerError.noManifest }
        return try await loadManifest(url)
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Everything on disk that belonged to `branch` (never outside `paths.root` / `paths.logs`).
    private func removeBranchFiles(branch: String, record: InstalledPackage, remaining: RampConfig) throws {
        let fm = FileManager.default
        try PackageInstaller.requireSafeSegment(branch)
        func remove(_ url: URL, under base: URL) throws {
            let root = base.standardizedFileURL.path(percentEncoded: false)
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(prefix), path.count > prefix.count else { throw InstallError.unsafePath(path) }
            // lstat semantics: a dangling symlink still counts.
            guard (try? fm.attributesOfItem(atPath: path)) != nil else { return }
            try fm.removeItem(atPath: path)
        }
        // Versions still used by another branch record (never expected, defense in depth).
        let kept = Set((remaining.installed["php"] ?? [:]).values.flatMap { [$0.version, $0.previousVersion] }
            .compactMap { $0 })
        let versions = [record.version, record.previousVersion].compactMap { $0 }
            .filter { $0 != branch && !kept.contains($0) }

        try remove(paths.branchDir(component: "php", branch: branch), under: paths.root)
        for version in versions {
            try PackageInstaller.requireSafeSegment(version)
            try remove(paths.package(component: "php", version: version), under: paths.root)
        }
        try remove(paths.phpConfDir(branch: branch), under: paths.root)
        try remove(paths.fpmSocket(branch: branch), under: paths.root)
        try remove(paths.pidFile(service: ServiceID.phpFPM(branch).name), under: paths.root)
        let downloads = (try? fm.contentsOfDirectory(atPath: paths.downloads.path(percentEncoded: false))) ?? []
        for name in downloads where versions.contains(where: { name.hasPrefix("php-\($0)-") || name.hasPrefix("php-\($0).tar") }) {
            try remove(paths.downloads.appending(path: name, directoryHint: .notDirectory), under: paths.root)
        }
        let logs = (try? fm.contentsOfDirectory(atPath: paths.logs.path(percentEncoded: false))) ?? []
        for name in logs where name.hasPrefix("php\(branch)-") {
            try remove(paths.logs.appending(path: name, directoryHint: .notDirectory), under: paths.logs)
        }
    }
}
