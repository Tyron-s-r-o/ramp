import Darwin
import Foundation

/// Errors of the Elasticsearch service / plugin manager (plan 06-03).
public enum ElasticsearchError: Error, LocalizedError, Equatable {
    /// `installed["elasticsearch"][branch]` missing.
    case notInstalled(branch: String)
    /// Plugin name not matching `^[a-z0-9][a-z0-9-]{1,63}$` (no URLs, paths, options).
    case invalidPluginName(String)
    /// `elasticsearch-plugin` exited non-zero (output included).
    case pluginCommandFailed(command: String, status: Int32, output: String)
    /// `elasticsearch-plugin` did not finish within the timeout (killed).
    case pluginCommandTimedOut(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let branch):
            return "Elasticsearch \(branch) is not installed. Install it first (rampctl es install)."
        case .invalidPluginName(let name):
            return "\"\(name)\" is not a valid plugin name (official plugin names only, e.g. analysis-icu)."
        case .pluginCommandFailed(let command, let status, let output):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "elasticsearch-plugin \(command) failed (exit \(status))" + (text.isEmpty ? "" : ": \(text)")
        case .pluginCommandTimedOut(let command, let output):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "elasticsearch-plugin \(command) timed out" + (text.isEmpty ? "" : ": \(text)")
        }
    }
}

/// Elasticsearch as an on-demand supervised service (plan 06-03). Single owner of ES lifecycle:
/// `prepare()` (ES_PATH_CONF + dirs), `start()`, `stop()`, `restart()`, `state()`. The process itself is
/// supervised by the `StackController`'s `ServiceSupervisor`, so `stopAll()` (app quit / `rampctl up` exit)
/// stops ES too. ES is NEVER started implicitly: not by `startAll`, not by `applyConfigChanges`
/// (that only restarts an already running ES whose files changed).
///
/// ES_PATH_CONF base-file rules (`<root>/conf/elasticsearch`):
/// - every top-level file of `<es current>/config/` missing in ES_PATH_CONF is copied, except `elasticsearch.yml`
///   (generated) and `elasticsearch.keystore` (created by ES itself, never overwritten);
/// - `jvm.options` and `log4j2.properties` are overwritten when the package version differs from
///   `.ramp-base-version` (then the marker is rewritten) — other files keep local edits;
/// - `elasticsearch.yml` + `jvm.options.d/ramp.options` are rendered by `ConfigRenderer` (stale
///   `jvm.options.d/*.options` pruned).
public actor ElasticsearchService {
    public typealias SpecProvider = @Sendable (RampConfig, Paths) throws -> ServiceSpec?

    /// Base files refreshed on every package version change.
    public static let versionedBaseFiles: Set<String> = ["jvm.options", "log4j2.properties"]
    /// Never copied from the package.
    public static let skippedBaseFiles: Set<String> = ["elasticsearch.yml", "elasticsearch.keystore"]
    public static let baseVersionMarker = ".ramp-base-version"

    public let stack: StackController
    public let plugins: ElasticsearchPluginManager
    private let specProvider: SpecProvider

    public init(stack: StackController, plugins: ElasticsearchPluginManager? = nil,
                specProvider: @escaping SpecProvider = { try ServiceSpecFactory.elasticsearch(config: $0, paths: $1) }) {
        self.stack = stack
        self.plugins = plugins ?? ElasticsearchPluginManager(paths: stack.paths, configStore: stack.configStore)
        self.specProvider = specProvider
    }

    public nonisolated var paths: Paths { stack.paths }

    /// Heap string validated/normalized exactly like the generator (`512M` → `512m`, 256m…31g).
    public static func validateHeap(_ heap: String) throws -> String {
        try ElasticsearchConfigGenerator.normalizedHeap(heap)
    }

    /// Branch / ports (valid, http ≠ transport) / loopback bind — the generator's rules (GUI, 06-04).
    public static func validate(_ settings: ElasticsearchSettings) throws {
        try ElasticsearchConfigGenerator.validate(settings)
    }

    // MARK: Prepare

    /// Dirs (data/tmp 0700), base config copy, render + write + prune. With `allowNetwork` the desired plugin set
    /// is reconciled (`elasticsearch-plugin install` downloads from artifacts.elastic.co) — never during `start()`.
    @discardableResult
    public func prepare(allowNetwork: Bool = false) async throws -> Set<URL> {
        let config = try await stack.configStore.load()
        let es = config.elasticsearch
        guard let record = config.installed[ElasticsearchConfigGenerator.component]?[es.branch] else {
            throw ElasticsearchError.notInstalled(branch: es.branch)
        }
        let fm = FileManager.default
        try paths.ensureDirectories()
        for dir in [paths.elasticsearchConfDir, paths.elasticsearchJvmOptionsDir, paths.elasticsearchLogs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dir in [paths.elasticsearchData(branch: es.branch), paths.elasticsearchTmp] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false))
        }
        var changed = try copyBaseFiles(branch: es.branch, version: record.version)
        // Only ES's own files — other services' configs are applied by StackController (reload semantics).
        let files = try ElasticsearchConfigGenerator(config: config, paths: paths).files()
        let writer = ConfigWriter(paths: paths)
        changed.formUnion(try writer.write(files))
        // Elasticvue's default cluster follows the ES port (static file, no service to reload).
        changed.formUnion(try writer.write(try ElasticvueConfigGenerator(config: config, paths: paths).files()))
        changed.formUnion(try writer.prune(directory: paths.elasticsearchJvmOptionsDir,
                                           keeping: Set(files.map { $0.path.standardizedFileURL }), extension: "options"))
        if allowNetwork { _ = try await plugins.reconcile() }
        return changed
    }

    /// Copies the package's base config into ES_PATH_CONF (rules in the type doc). Returns written files.
    func copyBaseFiles(branch: String, version: String) throws -> Set<URL> {
        let fm = FileManager.default
        let source = paths.current(component: ElasticsearchConfigGenerator.component, branch: branch)
            .appending(path: "config", directoryHint: .isDirectory)
        let dest = paths.elasticsearchConfDir
        let marker = dest.appending(path: Self.baseVersionMarker, directoryHint: .notDirectory)
        let markerVersion = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let versionChanged = markerVersion != version
        var written = Set<URL>()
        let names = (try? fm.contentsOfDirectory(atPath: source.path(percentEncoded: false))) ?? []
        for name in names.sorted() where !Self.skippedBaseFiles.contains(name) && !name.hasPrefix(".") {
            let from = source.appending(path: name, directoryHint: .notDirectory)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path(percentEncoded: false), isDirectory: &isDir), !isDir.boolValue
            else { continue }
            let to = dest.appending(path: name, directoryHint: .notDirectory)
            let exists = fm.fileExists(atPath: to.path(percentEncoded: false))
            guard !exists || (versionChanged && Self.versionedBaseFiles.contains(name)) else { continue }
            let data = try Data(contentsOf: from)
            try data.write(to: to, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: to.path(percentEncoded: false))
            written.insert(to.standardizedFileURL)
        }
        if versionChanged {
            try Data("\(version)\n".utf8).write(to: marker, options: .atomic)
        }
        return written
    }

    // MARK: Lifecycle

    /// Prepare → validate auto-stop settings → supervised start. Not installed → `ElasticsearchError.notInstalled`.
    /// A failed state's reason carries the tail of ES's own `elasticsearch.log`.
    @discardableResult
    public func start() async throws -> ServiceState {
        let config = try await stack.configStore.load()
        guard ElasticsearchConfigGenerator.isInstalled(config) else {
            throw ElasticsearchError.notInstalled(branch: config.elasticsearch.branch)
        }
        try await prepare()
        try config.elasticsearch.autoStop.validate()
        guard let spec = try specProvider(config, paths) else {
            throw ElasticsearchError.notInstalled(branch: config.elasticsearch.branch)
        }
        let state = await stack.supervisor.start(spec)
        if case .failed(let reason) = state, let tail = logTail() {
            return .failed(reason: reason + "\n--- \(Self.serverLogName) (last lines) ---\n" + tail)
        }
        return state
    }

    public func stop() async {
        await stack.supervisor.stop(.elasticsearch)
    }

    @discardableResult
    public func restart() async throws -> ServiceState {
        await stop()
        return try await start()
    }

    public func state() async -> ServiceState {
        await stack.supervisor.state(of: .elasticsearch)
    }

    // MARK: Plugins (restartRequired when ES runs)

    // ES_PATH_CONF is prepared first: the plugin tool reads it (and some plugins ship config files).

    public func listPlugins() async throws -> [String] {
        try await prepare()
        return try await plugins.list()
    }

    /// `running` overrides the supervisor state (rampctl in a process other than the supervising one).
    @discardableResult
    public func installPlugin(_ name: String, running: Bool? = nil) async throws -> PluginChange {
        guard ElasticsearchPluginManager.isValidName(name) else { throw ElasticsearchError.invalidPluginName(name) }
        try await prepare()
        let isRunning: Bool
        if let running { isRunning = running } else { isRunning = await state().isRunning }
        return try await plugins.install(name, running: isRunning)
    }

    @discardableResult
    public func removePlugin(_ name: String, running: Bool? = nil) async throws -> PluginChange {
        guard ElasticsearchPluginManager.isValidName(name) else { throw ElasticsearchError.invalidPluginName(name) }
        try await prepare()
        let isRunning: Bool
        if let running { isRunning = running } else { isRunning = await state().isRunning }
        return try await plugins.remove(name, running: isRunning)
    }

    // MARK: Log

    /// ES's own log (cluster name `elasticsearch` → `<logs>/elasticsearch/elasticsearch.log`).
    static let serverLogName = "elasticsearch.log"

    /// Last `lines` lines of ES's own log, nil when missing/empty.
    func logTail(lines: Int = 20) -> String? {
        let url = paths.elasticsearchLogs.appending(path: Self.serverLogName, directoryHint: .notDirectory)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 16 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let tail = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
        return tail.isEmpty ? nil : tail
    }
}

// MARK: - StackController hook (06-03)

extension StackController {
    /// Part of `applyConfigChanges`: ES files changed and ES running (or backing off) → restart with a fresh spec
    /// (ES has no reload signal). ES not running → nothing (never an implicit start).
    func restartElasticsearchIfAffected(changed: Set<URL>, config: RampConfig, report: inout ConfigApplyReport) async {
        guard Self.affectedServices(changed: changed, paths: paths).restart.contains(.elasticsearch),
              let registered = await supervisor.spec(of: .elasticsearch) else { return }
        let state = await supervisor.state(of: .elasticsearch)
        var active = state.isRunning
        if case .backingOff = state { active = true }
        guard active else { return }
        // Fresh spec (port changes apply) — unless the registered one was injected (not a package binary).
        var spec = registered
        if PortProbe.isUnder(registered.executable.path(percentEncoded: false), root: paths.root),
           let fresh = (try? ServiceSpecFactory.elasticsearch(config: config, paths: paths)) ?? nil {
            spec = fresh
        }
        await supervisor.stop(.elasticsearch)
        let newState = await supervisor.start(spec)
        if case .failed(let reason) = newState {
            report.errors[.elasticsearch] = reason
        } else {
            report.restarted.append(.elasticsearch)
        }
    }
}
