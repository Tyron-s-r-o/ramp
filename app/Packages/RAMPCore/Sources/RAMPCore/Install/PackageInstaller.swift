import Foundation

/// Errors raised by `PackageInstaller` / `ArchiveExtractor`. Every failure leaves no partial state behind.
public enum InstallError: Error, LocalizedError {
    case notInManifest(component: String, branch: String)
    /// Component known but not installable in this phase (e.g. elasticsearch).
    case unsupportedComponent(String)
    /// Manifest publishes no sha256 for this entry.
    case unsupportedHash(component: String, branch: String)
    case downloadFailed(url: String, reason: String)
    case sizeMismatch(component: String, version: String, expected: Int64, actual: Int64)
    case checksumMismatch(component: String, version: String, expected: String, actual: String)
    /// Archive entry (or symlink `name -> target`) that would escape the package directory.
    case unsafeArchive(String)
    /// Manifest names a component/branch/version/file that is not a safe single path segment.
    case unsafePath(String)
    case invalidPackage(component: String, version: String, reason: String)
    case extractionFailed(String)
    /// Archive is neither `.tar.xz` nor `.tar.gz` (detected by magic bytes).
    case unsupportedArchiveFormat(String)

    public var errorDescription: String? {
        switch self {
        case .notInManifest(let c, let b):
            return "\(c) \(b) is not listed in the manifest."
        case .unsupportedComponent(let c):
            return "\(c) cannot be installed by this RAMP version."
        case .unsupportedHash(let c, let b):
            return "Manifest entry \(c) \(b) has no sha256 checksum; refusing to install."
        case .downloadFailed(let url, let reason):
            return "Download of \(url) failed: \(reason)"
        case .sizeMismatch(let c, let v, let expected, let actual):
            return "\(c) \(v): downloaded \(actual) bytes, manifest says \(expected). The download was deleted; retry."
        case .checksumMismatch(let c, let v, let expected, let actual):
            return "\(c) \(v): checksum mismatch (expected \(expected), got \(actual)). The download was deleted; "
                + "retry or check the manifest."
        case .unsafeArchive(let entry):
            return "Package archive contains an unsafe entry (\(entry)); refusing to install."
        case .unsafePath(let value):
            return "Manifest value \"\(value)\" is not a safe path component; refusing to install."
        case .invalidPackage(let c, let v, let reason):
            return "\(c) \(v) is not a valid RAMP package: \(reason)"
        case .extractionFailed(let reason):
            return "Extracting the package failed: \(reason)"
        case .unsupportedArchiveFormat(let file):
            return "\(file) is not a .tar.xz or .tar.gz archive; this RAMP cannot unpack it."
        }
    }
}

/// Progress event for one package.
public struct InstallProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case downloading, verifying, extracting, activating
        case installed(InstalledPackage)
        case failed(String)
    }

    public let component: String
    public let branch: String
    public let stage: Stage
    /// Byte progress while `.downloading` (throttled to ~5 Hz); nil on the stage-change event itself.
    public let download: DownloadProgress?

    public init(component: String, branch: String, stage: Stage, download: DownloadProgress? = nil) {
        self.component = component
        self.branch = branch
        self.stage = stage
        self.download = download
    }

    /// Whole-install fraction for a determinate bar: download 0…0.85, then verify / extract / activate.
    public static func overallFraction(stage: Stage?, download: DownloadProgress?) -> Double {
        switch stage {
        case nil, .failed: 0
        case .downloading: 0.85 * (download?.fraction ?? 0)
        case .verifying: 0.86
        case .extracting: 0.9
        case .activating: 0.97
        case .installed: 1
        }
    }
}

/// Identifies a package slot (`installed[component][branch]`).
public struct PackageKey: Sendable, Hashable {
    public let component: String
    public let branch: String

    public init(component: String, branch: String) {
        self.component = component
        self.branch = branch
    }
}

public struct InstallFailure: Sendable {
    public let component: String
    public let branch: String
    public let error: any Error

    public var message: String { error.localizedDescription }
}

/// Result of `installDefaultSet`: what got installed and every per-package failure.
public struct InstallReport: Sendable {
    public var installed: [PackageKey: InstalledPackage] = [:]
    public var failures: [InstallFailure] = []
    public var succeeded: Bool { failures.isEmpty }
}

/// A package downloaded, verified and extracted into `<root>/<component>/<version>` but not yet active
/// (`PackageInstaller.prepare`, plan 07-02).
public struct PreparedPackage: Sendable, Equatable {
    public let component: String
    public let branch: String
    public let version: String
    /// Digest the manifest published (sha256, or sha512 for Elasticsearch).
    public let sha256: String
    public let directory: URL
    public let extensionDirRel: String?
    public let opcache: String?
    public let extensions: [String]?
    /// Same version + digest was already recorded and on disk (nothing downloaded).
    public let alreadyInstalled: Bool
}

/// Installs service packages from a `Manifest` into `Paths.root`:
/// download → size + sha256 → list/validate → extract into `.staging/<uuid>` → sanity check →
/// move to `<root>/<component>/<version>` → atomically repoint `<branch>/current` → record in ramp.json.
///
/// Fail closed: any error removes the staging dir and (on size/hash mismatch) the download; nothing is
/// written to `<root>/<component>` or ramp.json before the package passed every check. Never writes
/// outside `Paths.root`.
public actor PackageInstaller {
    /// File every package must contain (relative to its root); executables must be executable.
    public static let sanityFiles: [String: (path: String, executable: Bool)] = [
        "php": ("sbin/php-fpm", true),
        "apache": ("bin/httpd", true),
        "mysql": ("bin/mysqld", true),
        "redis": ("bin/redis-server", true),
        "phpmyadmin": ("index.php", false),
        "elasticsearch": ("bin/elasticsearch", true),
        "elasticvue": ("index.html", false),
    ]
    /// MySQL branch installed by `installDefaultSet` (8.4 is only a Phase 7 migration step).
    public static let defaultMySQLBranch = "9.7"

    public let paths: Paths
    public let configStore: ConfigStore
    private let session: URLSession
    private let extractor: ArchiveExtractor

    public init(paths: Paths, configStore: ConfigStore, session: URLSession = .shared,
                extractor: ArchiveExtractor = ArchiveExtractor()) {
        self.paths = paths
        self.configStore = configStore
        self.session = session
        self.extractor = extractor
    }

    // MARK: Single package

    /// Download + verify + extract + activate in one call (`prepare` then `activate`).
    @discardableResult
    public func install(
        component: String, branch: String, from manifest: Manifest,
        progress: AsyncStream<InstallProgress>.Continuation? = nil
    ) async throws -> InstalledPackage {
        let prepared = try await prepare(component: component, branch: branch, from: manifest, progress: progress)
        return try await activate(prepared, progress: progress)
    }

    /// Everything that needs no downtime (plan 07-02): download, size + checksum, extract into staging,
    /// sanity check, move to `<root>/<component>/<version>`. `current` and ramp.json are NOT touched.
    /// Same version + digest already recorded and on disk → `alreadyInstalled` (no download).
    public func prepare(
        component: String, branch: String, from manifest: Manifest,
        progress: AsyncStream<InstallProgress>.Continuation? = nil
    ) async throws -> PreparedPackage {
        func report(_ stage: InstallProgress.Stage) {
            progress?.yield(InstallProgress(component: component, branch: branch, stage: stage))
        }
        guard Manifest.installableComponents.contains(component),
              let sanity = Self.sanityFiles[component] else {
            throw InstallError.unsupportedComponent(component)
        }
        guard let entry = manifest.entry(component: component, branch: branch) else {
            throw InstallError.notInManifest(component: component, branch: branch)
        }
        // sha256 for RAMP-built packages, sha512 for the official Elasticsearch artifact (06-03). The record's
        // `sha256` field stores whichever digest the manifest publishes (idempotency compares like with like).
        let expectedSHA: String
        let digest: @Sendable (URL) throws -> String
        switch entry.hash {
        case .sha256(let hex): expectedSHA = hex; digest = { try Checksum.sha256(of: $0) }
        case .sha512(let hex): expectedSHA = hex; digest = { try Checksum.sha512(of: $0) }
        }
        let fileName = entry.url.lastPathComponent
        for segment in [component, branch, entry.version, fileName] { try Self.requireSafeSegment(segment) }
        guard branch != entry.version else { throw InstallError.unsafePath(branch) }

        let finalDir = paths.package(component: component, version: entry.version)
        let currentLink = paths.current(component: component, branch: branch)
        let download = paths.downloads.appending(path: fileName, directoryHint: .notDirectory)
        for url in [finalDir, currentLink, download] { try requireInsideRoot(url) }

        // Idempotent: same version + sha already installed and on disk → existing record.
        if let existing = try await configStore.load().installed[component]?[branch],
           existing.version == entry.version, existing.sha256 == expectedSHA,
           isDirectory(finalDir) {
            return PreparedPackage(component: component, branch: branch, version: entry.version,
                                   sha256: expectedSHA, directory: finalDir,
                                   extensionDirRel: existing.extensionDirRel, opcache: existing.opcache,
                                   extensions: existing.extensions, alreadyInstalled: true)
        }

        try paths.ensureDirectories()

        // Download (reuse a cached download whose sha matches).
        report(.downloading)
        if !(isFile(download) && (try? digest(download)) == expectedSHA) {
            try? FileManager.default.removeItem(at: download)
            try await fetch(entry.url, to: download, expectedSize: entry.size) { bytes in
                progress?.yield(InstallProgress(component: component, branch: branch, stage: .downloading,
                                                download: bytes))
            }
        }

        // Verify size + sha256.
        report(.verifying)
        do {
            if let size = entry.size {
                let actual = try fileSize(download)
                guard actual == size else {
                    throw InstallError.sizeMismatch(component: component, version: entry.version,
                                                    expected: size, actual: actual)
                }
            }
            let actualSHA = try digest(download)
            guard actualSHA == expectedSHA else {
                throw InstallError.checksumMismatch(component: component, version: entry.version,
                                                    expected: expectedSHA, actual: actualSHA)
            }
        } catch {
            try? FileManager.default.removeItem(at: download)
            throw error
        }

        // Extract into staging, validate, move into place.
        report(.extracting)
        let staging = paths.staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try requireInsideRoot(staging)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try await extractor.extract(download, into: staging)
        let packageRoot = try locatePackageRoot(in: staging, sanity: sanity.path, component: component,
                                                version: entry.version)
        try ArchiveExtractor.validateSymlinks(in: packageRoot)
        try checkSanity(packageRoot, sanity: sanity, component: component, version: entry.version)
        let opcache = component == "php" ? Self.opcacheBuild(in: packageRoot) : nil

        let componentDir = finalDir.deletingLastPathComponent()
        try fm.createDirectory(at: componentDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: finalDir.path(percentEncoded: false)) {
            // Stale dir of this version not backed by a matching ramp.json record (e.g. kept after a
            // rolled-back update) → replace it.
            let trash = staging.appending(path: "stale-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.moveItem(at: finalDir, to: trash)
        }
        try fm.moveItem(at: packageRoot, to: finalDir)
        return PreparedPackage(component: component, branch: branch, version: entry.version, sha256: expectedSHA,
                               directory: finalDir, extensionDirRel: entry.extensionDirRel, opcache: opcache,
                               extensions: component == "php" && !entry.extensions.isEmpty ? entry.extensions : nil,
                               alreadyInstalled: false)
    }

    /// Flips `<branch>/current` to the prepared version (atomic) and records it in ramp.json. A different
    /// version already recorded for the branch becomes `previousVersion` (`recordingUpdate`, 07-01).
    @discardableResult
    public func activate(
        _ prepared: PreparedPackage, progress: AsyncStream<InstallProgress>.Continuation? = nil
    ) async throws -> InstalledPackage {
        let component = prepared.component, branch = prepared.branch
        func report(_ stage: InstallProgress.Stage) {
            progress?.yield(InstallProgress(component: component, branch: branch, stage: stage))
        }
        let currentLink = paths.current(component: component, branch: branch)
        try requireInsideRoot(currentLink)
        try requireInsideRoot(prepared.directory)
        let existing = try await configStore.load().installed[component]?[branch]
        if prepared.alreadyInstalled, let existing, existing.version == prepared.version {
            try pointCurrent(currentLink, toVersion: prepared.version)
            return existing
        }
        report(.activating)
        do {
            try pointCurrent(currentLink, toVersion: prepared.version)
        } catch {
            // Fresh install (no previous current) → nothing may stay behind.
            if existing == nil { try? FileManager.default.removeItem(at: prepared.directory) }
            throw error
        }

        // Whole seconds: ramp.json stores ISO 8601 without fractions, so the returned record equals
        // what a later load() yields (idempotent re-install returns an identical record).
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var record: InstalledPackage
        if let existing, existing.version != prepared.version {
            record = existing.recordingUpdate(to: prepared.version, sha256: prepared.sha256, at: now)
            record.extensionDirRel = prepared.extensionDirRel
            record.opcache = prepared.opcache
            record.extensions = prepared.extensions
        } else {
            record = InstalledPackage(version: prepared.version, sha256: prepared.sha256, installedAt: now,
                                      extensionDirRel: prepared.extensionDirRel, opcache: prepared.opcache,
                                      extensions: prepared.extensions)
        }
        let saved = record
        try await configStore.update { config in
            config.installed[component, default: [:]][branch] = saved
        }
        report(.installed(record))
        return record
    }

    /// Points `<branch>/current` at an existing version dir (rollback, 07-02). The dir must lie inside
    /// `<root>/<component>/` and pass the sanity-file check. ramp.json is not touched (see `setRecord`).
    public func switchCurrent(component: String, branch: String, toVersion version: String) throws {
        guard let sanity = Self.sanityFiles[component] else { throw InstallError.unsupportedComponent(component) }
        for segment in [component, branch, version] { try Self.requireSafeSegment(segment) }
        guard branch != version else { throw InstallError.unsafePath(branch) }
        let dir = paths.package(component: component, version: version)
        let link = paths.current(component: component, branch: branch)
        for url in [dir, link] { try requireInsideRoot(url) }
        guard isDirectory(dir), !isSymlink(dir) else {
            throw InstallError.invalidPackage(component: component, version: version, reason: "directory missing")
        }
        try checkSanity(dir, sanity: sanity, component: component, version: version)
        try pointCurrent(link, toVersion: version)
    }

    /// Replaces (or with `nil` removes) the ramp.json record of one slot.
    public func setRecord(_ record: InstalledPackage?, component: String, branch: String) async throws {
        try await configStore.update { config in
            if let record {
                config.installed[component, default: [:]][branch] = record
            } else {
                config.installed[component]?[branch] = nil
                if config.installed[component]?.isEmpty == true { config.installed[component] = nil }
            }
        }
    }

    /// Version dir names directly under `<root>/<component>/` (symlinks and hidden entries excluded).
    public func versionsOnDisk(component: String) throws -> [String] {
        try Self.requireSafeSegment(component)
        let dir = paths.root.appending(path: component, directoryHint: .isDirectory)
        try requireInsideRoot(dir)
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            let url = dir.appending(path: name, directoryHint: .isDirectory)
            return isDirectory(url) && !isSymlink(url)
        }.sorted()
    }

    /// Deletes the version dirs of `branch` that `RetentionPolicy.prunable` allows (never `current` /
    /// `previous`, never outside `<root>/<component>/`). Returns the removed version names.
    @discardableResult
    public func prune(component: String, branch: String, current: String, previous: String?) throws -> [String] {
        let versions = try versionsOnDisk(component: component)
        let doomed = RetentionPolicy.prunable(component: component, branch: branch, versionsOnDisk: versions,
                                              current: current, previous: previous)
        // Never delete what any branch's `current` points at (defense in depth).
        let linked = Set(((try? FileManager.default.contentsOfDirectory(
            atPath: paths.root.appending(path: component).path(percentEncoded: false))) ?? [])
            .compactMap { try? FileManager.default.destinationOfSymbolicLink(
                atPath: paths.current(component: component, branch: $0).path(percentEncoded: false)) }
            .map { ($0 as NSString).lastPathComponent })
        var removed: [String] = []
        for version in doomed where !linked.contains(version) {
            try Self.requireSafeSegment(version)
            let dir = paths.package(component: component, version: version)
            try requireInsideRoot(dir)
            guard dir.deletingLastPathComponent().standardizedFileURL
                == paths.root.appending(path: component, directoryHint: .isDirectory).standardizedFileURL else { continue }
            try FileManager.default.removeItem(at: dir)
            removed.append(version)
        }
        return removed
    }

    // MARK: Default set

    /// Installs apache, redis, mysql 9.7, phpmyadmin (all branches listed) and the supported PHP branches
    /// (`defaultSlots`). Failures are collected, never abort the rest. `progress` is finished when done.
    public func installDefaultSet(
        _ manifest: Manifest, progress: AsyncStream<InstallProgress>.Continuation? = nil
    ) async -> InstallReport {
        await install(slots: Self.defaultSlots(in: manifest), from: manifest, progress: progress)
    }

    /// Package slots of the default set, in install order (apache, redis, mysql 9.7, phpmyadmin, php).
    /// PHP: every branch the manifest does not mark `support: eol` (no `support` = supported, older manifests),
    /// plus `requiredPHP` (branches the config already references, e.g. phpMyAdmin's / a vhost's). EOL branches
    /// are installed on demand (PHP › Pridať verziu PHP, MAMP import). Only EOL branches → the highest one.
    public static func defaultSlots(in manifest: Manifest, requiredPHP: Set<String> = []) -> [PackageKey] {
        var slots: [PackageKey] = []
        for component in ["apache", "redis"] {
            slots += manifest.branches(of: component).map { PackageKey(component: component, branch: $0) }
        }
        if manifest.entry(component: "mysql", branch: Self.defaultMySQLBranch) != nil {
            slots.append(PackageKey(component: "mysql", branch: Self.defaultMySQLBranch))
        }
        slots += manifest.branches(of: "phpmyadmin").map { PackageKey(component: "phpmyadmin", branch: $0) }
        let php = manifest.branches(of: "php")
        var phpDefault = php.filter { branch in
            requiredPHP.contains(branch) || manifest.entry(component: "php", branch: branch)?.isEOL != true
        }
        if phpDefault.isEmpty, let highest = php.last { phpDefault = [highest] }
        slots += phpDefault.map { PackageKey(component: "php", branch: $0) }
        return slots
    }

    /// Installs the given slots; failures are collected, never abort the rest. `progress` is finished when done.
    public func install(
        slots: [PackageKey], from manifest: Manifest, progress: AsyncStream<InstallProgress>.Continuation? = nil
    ) async -> InstallReport {
        var result = InstallReport()
        for slot in slots {
            do {
                result.installed[slot] = try await install(component: slot.component, branch: slot.branch,
                                                           from: manifest, progress: progress)
            } catch {
                result.failures.append(InstallFailure(component: slot.component, branch: slot.branch, error: error))
                progress?.yield(InstallProgress(component: slot.component, branch: slot.branch,
                                                stage: .failed(error.localizedDescription)))
            }
        }
        progress?.finish()
        return result
    }

    /// Convenience: runs `installDefaultSet` in a task and returns its progress stream.
    public nonisolated func installDefaultSetWithProgress(
        _ manifest: Manifest
    ) -> (progress: AsyncStream<InstallProgress>, report: Task<InstallReport, Never>) {
        let (stream, continuation) = AsyncStream<InstallProgress>.makeStream()
        let task = Task { await self.installDefaultSet(manifest, progress: continuation) }
        return (stream, task)
    }

    // MARK: Elasticsearch (06-03)

    /// Installs Elasticsearch on demand (never part of `installDefaultSet`): branch from
    /// `config.elasticsearch.branch`, manifest from `manifest` or `config.manifestURL`. The official tarball is
    /// ~650 MB — `progress` gets the stage events and is finished when done.
    @discardableResult
    public func installElasticsearch(
        manifest: Manifest? = nil, progress: AsyncStream<InstallProgress>.Continuation? = nil
    ) async throws -> InstalledPackage {
        defer { progress?.finish() }
        let config = try await configStore.load()
        let branch = config.elasticsearch.branch
        let resolved: Manifest
        if let manifest {
            resolved = manifest
        } else if let url = config.manifestURL {
            resolved = try await ManifestLoader.load(url)
        } else {
            throw InstallError.notInManifest(component: "elasticsearch", branch: branch)
        }
        let record: InstalledPackage
        do {
            record = try await install(component: "elasticsearch", branch: branch, from: resolved, progress: progress)
        } catch {
            progress?.yield(InstallProgress(component: "elasticsearch", branch: branch,
                                            stage: .failed(error.localizedDescription)))
            throw error
        }
        // Elasticvue comes with Elasticsearch — best effort: a failure leaves ES installed and the app offers
        // "Nainštalovať Elasticvue" (StackController.ensureInstalled also retries on the next launch).
        if try await configStore.load().installed[ElasticvueConfigGenerator.component]?.isEmpty ?? true,
           let slot = Self.elasticvueSlot(in: resolved) {
            _ = try? await install(component: slot.component, branch: slot.branch, from: resolved, progress: progress)
        }
        return record
    }

    // MARK: Elasticvue

    /// Highest Elasticvue branch the manifest lists, or nil (older manifests have none).
    public static func elasticvueSlot(in manifest: Manifest) -> PackageKey? {
        manifest.branches(of: ElasticvueConfigGenerator.component).last
            .map { PackageKey(component: ElasticvueConfigGenerator.component, branch: $0) }
    }

    /// Installs Elasticvue (highest branch of `manifest` or `config.manifestURL`) — for an Elasticsearch
    /// installed before Elasticvue was bundled. `progress` is finished when done.
    @discardableResult
    public func installElasticvue(
        manifest: Manifest? = nil, progress: AsyncStream<InstallProgress>.Continuation? = nil
    ) async throws -> InstalledPackage {
        defer { progress?.finish() }
        let resolved: Manifest
        if let manifest {
            resolved = manifest
        } else if let url = try await configStore.load().manifestURL {
            resolved = try await ManifestLoader.load(url)
        } else {
            throw InstallError.notInManifest(component: ElasticvueConfigGenerator.component, branch: "*")
        }
        guard let slot = Self.elasticvueSlot(in: resolved) else {
            throw InstallError.notInManifest(component: ElasticvueConfigGenerator.component, branch: "*")
        }
        do {
            return try await install(component: slot.component, branch: slot.branch, from: resolved, progress: progress)
        } catch {
            progress?.yield(InstallProgress(component: slot.component, branch: slot.branch,
                                            stage: .failed(error.localizedDescription)))
            throw error
        }
    }

    // MARK: Steps

    /// Downloads `url` to `destination` (via `.partial`), reporting byte progress (~5 Hz, speed, total from the
    /// response or `expectedSize`). A delegate-based task — `session.download(from:)` gives no byte progress.
    private func fetch(_ url: URL, to destination: URL, expectedSize: Int64?,
                       onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let fm = FileManager.default
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        do {
            if url.isFileURL {
                try fm.copyItem(at: url, to: partial)
                let size = try fileSize(partial)
                onProgress(DownloadProgress(bytesReceived: size, totalBytes: size))
            } else {
                guard url.scheme?.lowercased() == "https" else {
                    throw ManifestError.insecureURL(url.absoluteString)
                }
                let delegate = PackageDownloadDelegate(destination: partial, totalBytes: expectedSize,
                                                       onProgress: onProgress)
                let downloadSession = URLSession(configuration: session.configuration, delegate: delegate,
                                                 delegateQueue: nil)
                defer { downloadSession.finishTasksAndInvalidate() }
                let task = downloadSession.downloadTask(with: url)
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        delegate.start(continuation)
                        task.resume()
                    }
                } onCancel: {
                    task.cancel()
                }
            }
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            if error is InstallError || error is ManifestError { throw error }
            throw InstallError.downloadFailed(url: url.absoluteString, reason: error.localizedDescription)
        }
    }

    /// `"shared"`/`"static"` from the PHP tree's own `ramp.json` (written by build/php/build-php.sh), else nil.
    static func opcacheBuild(in packageRoot: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: packageRoot.appending(path: "ramp.json")
                .path(percentEncoded: false)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj["opcache"] as? String, value == "shared" || value == "static" else { return nil }
        return value
    }

    /// The tree itself if the sanity file is at the top, else its single top-level directory.
    private func locatePackageRoot(in staging: URL, sanity: String, component: String,
                                   version: String) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.appending(path: sanity).path(percentEncoded: false)) { return staging }
        let children = try fm.contentsOfDirectory(atPath: staging.path(percentEncoded: false))
            .filter { $0 != ".DS_Store" }
        if children.count == 1 {
            let only = staging.appending(path: children[0], directoryHint: .isDirectory)
            if isDirectory(only), !isSymlink(only) { return only }
        }
        throw InstallError.invalidPackage(component: component, version: version, reason: "\(sanity) missing")
    }

    private func checkSanity(_ root: URL, sanity: (path: String, executable: Bool),
                             component: String, version: String) throws {
        let file = root.appending(path: sanity.path)
        let path = file.path(percentEncoded: false)
        guard isFile(file) else {
            throw InstallError.invalidPackage(component: component, version: version, reason: "\(sanity.path) missing")
        }
        if sanity.executable && !FileManager.default.isExecutableFile(atPath: path) {
            throw InstallError.invalidPackage(component: component, version: version,
                                              reason: "\(sanity.path) is not executable")
        }
    }

    /// `current` → `../<version>` via temp symlink + rename(2) (atomic replace).
    private func pointCurrent(_ link: URL, toVersion version: String) throws {
        let fm = FileManager.default
        let target = "../\(version)"
        if (try? fm.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))) == target { return }
        let dir = link.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appending(path: ".current.\(UUID().uuidString)", directoryHint: .notDirectory)
        try fm.createSymbolicLink(atPath: temp.path(percentEncoded: false), withDestinationPath: target)
        guard rename(temp.path(percentEncoded: false), link.path(percentEncoded: false)) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw InstallError.extractionFailed("switching \(link.path(percentEncoded: false)) failed: "
                + String(cString: strerror(code)))
        }
    }

    // MARK: Guards + helpers

    static func requireSafeSegment(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+")
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw InstallError.unsafePath(value)
        }
    }

    private func requireInsideRoot(_ url: URL) throws {
        let root = paths.root.standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(prefix) else { throw InstallError.unsafePath(path) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir)
            && isDir.boolValue
    }

    private func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir)
            && !isDir.boolValue
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.type]
            as? FileAttributeType) == .typeSymbolicLink
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }
}
