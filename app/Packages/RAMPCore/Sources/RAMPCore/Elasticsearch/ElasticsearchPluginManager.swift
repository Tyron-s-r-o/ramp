import Darwin
import Foundation

/// Result of a helper process run through `ProcessRunning`.
public struct ProcessRunResult: Sendable, Equatable {
    public var status: Int32
    /// Combined stdout + stderr.
    public var output: String
    public var timedOut: Bool

    public init(status: Int32, output: String, timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }
}

/// Runs a short-lived helper process (injectable for tests).
public protocol ProcessRunning: Sendable {
    func run(_ argv: [String], environment: [String: String], timeout: Duration) async -> ProcessRunResult
}

/// `Process`-based runner: combined output captured in a temp file (no pipe deadlock), SIGTERM then SIGKILL
/// on timeout.
public struct SystemProcessRunner: ProcessRunning {
    public let tempDir: URL

    public init(tempDir: URL) {
        self.tempDir = tempDir
    }

    public func run(_ argv: [String], environment: [String: String], timeout: Duration) async -> ProcessRunResult {
        guard let exe = argv.first else { return ProcessRunResult(status: -1, output: "empty argv") }
        let fm = FileManager.default
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outURL = tempDir.appending(path: ".run-\(UUID().uuidString).out", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: outURL) }
        guard fm.createFile(atPath: outURL.path(percentEncoded: false), contents: nil,
                            attributes: [.posixPermissions: 0o600]),
              let outHandle = try? FileHandle(forWritingTo: outURL) else {
            return ProcessRunResult(status: -1, output: "cannot create temp output file")
        }
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outHandle
        p.standardError = outHandle

        let exited = ExitFlag()
        var launchError: String?
        let status: Int32 = await withCheckedContinuation { continuation in
            p.terminationHandler = { proc in
                exited.set()
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                launchError = error.localizedDescription
                exited.set()
                continuation.resume(returning: -1)
                return
            }
            let pid = p.processIdentifier
            Task.detached {
                let deadline = ContinuousClock.now + timeout
                while !exited.isSet, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard !exited.isSet else { return }
                exited.markTimedOut()
                kill(pid, SIGTERM)
                try? await Task.sleep(for: .seconds(5))
                if !exited.isSet { kill(pid, SIGKILL) }
            }
        }
        try? outHandle.close()
        if let launchError { return ProcessRunResult(status: -1, output: "cannot run \(exe): \(launchError)") }
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        return ProcessRunResult(status: status, output: text, timedOut: exited.timedOut)
    }

    /// Thread-safe flags shared between the termination handler and the timeout task.
    private final class ExitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var didTimeOut = false
        var isSet: Bool { lock.withLock { done } }
        var timedOut: Bool { lock.withLock { didTimeOut } }
        func set() { lock.withLock { done = true } }
        func markTimedOut() { lock.withLock { didTimeOut = true } }
    }
}

/// Outcome of a plugin install/remove.
public struct PluginChange: Sendable, Equatable {
    public var name: String
    /// `false` when nothing had to be done (already installed / not installed).
    public var changed: Bool
    /// ES was running: the change takes effect after a restart (caller decides).
    public var restartRequired: Bool
}

/// Manages Elasticsearch plugins via `<es current>/bin/elasticsearch-plugin` (plan 06-03).
///
/// Plugins live inside the versioned package dir (`<root>/elasticsearch/<version>/plugins`), so a package update
/// loses them — `config.elasticsearch.plugins` is the desired set and `reconcile()` reinstalls what is missing.
/// Names are validated before anything runs (official plugin names only; no URLs, paths or options).
public actor ElasticsearchPluginManager {
    public static let timeout: Duration = .seconds(600)

    public let paths: Paths
    public let configStore: ConfigStore
    private let runner: any ProcessRunning

    public init(paths: Paths, configStore: ConfigStore, runner: (any ProcessRunning)? = nil) {
        self.paths = paths
        self.configStore = configStore
        self.runner = runner ?? SystemProcessRunner(tempDir: paths.tmp)
    }

    /// `^[a-z0-9][a-z0-9-]{1,63}$`
    public static func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (2...64).contains(scalars.count) else { return false }
        func ok(_ s: Unicode.Scalar, dash: Bool) -> Bool {
            ("a"..."z").contains(s) || ("0"..."9").contains(s) || (dash && s == "-")
        }
        return ok(scalars[0], dash: false) && scalars.dropFirst().allSatisfy { ok($0, dash: true) }
    }

    /// Installed plugin names (`elasticsearch-plugin list`).
    public func list() async throws -> [String] {
        let output = try await runTool(["list"], command: "list")
        return Self.parseList(output)
    }

    /// Plugin names from `elasticsearch-plugin list` output (warnings / JVM noise ignored).
    static func parseList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isValidName)
    }

    /// `elasticsearch-plugin install --batch <name>`; adds the name to `config.elasticsearch.plugins`.
    @discardableResult
    public func install(_ name: String, running: Bool = false) async throws -> PluginChange {
        guard Self.isValidName(name) else { throw ElasticsearchError.invalidPluginName(name) }
        let present = try await list().contains(name)
        if !present {
            _ = try await runTool(["install", "--batch", name], command: "install \(name)")
        }
        try await configStore.update { config in
            if !config.elasticsearch.plugins.contains(name) { config.elasticsearch.plugins.append(name) }
        }
        return PluginChange(name: name, changed: !present, restartRequired: running && !present)
    }

    /// `elasticsearch-plugin remove <name>`; removes the name from `config.elasticsearch.plugins`.
    @discardableResult
    public func remove(_ name: String, running: Bool = false) async throws -> PluginChange {
        guard Self.isValidName(name) else { throw ElasticsearchError.invalidPluginName(name) }
        let present = try await list().contains(name)
        if present {
            _ = try await runTool(["remove", name], command: "remove \(name)")
        }
        try await configStore.update { config in config.elasticsearch.plugins.removeAll { $0 == name } }
        return PluginChange(name: name, changed: present, restartRequired: running && present)
    }

    /// Installs desired plugins (`config.elasticsearch.plugins`) missing from `list()`. Needs network.
    /// Invalid names in ramp.json are skipped (never passed to the tool). Returns the installed names.
    @discardableResult
    public func reconcile() async throws -> [String] {
        let desired = try await configStore.load().elasticsearch.plugins.filter(Self.isValidName)
        guard !desired.isEmpty else { return [] }
        let present = Set(try await list())
        var installed: [String] = []
        for name in desired where !present.contains(name) && !installed.contains(name) {
            _ = try await runTool(["install", "--batch", name], command: "install \(name)")
            installed.append(name)
        }
        return installed
    }

    // MARK: Helpers

    /// argv for `elasticsearch-plugin <args>`.
    func argv(_ args: [String], config: RampConfig) throws -> [String] {
        let branch = config.elasticsearch.branch
        guard ElasticsearchConfigGenerator.isInstalled(config) else {
            throw ElasticsearchError.notInstalled(branch: branch)
        }
        let tool = paths.current(component: ElasticsearchConfigGenerator.component, branch: branch)
            .appending(path: "bin/elasticsearch-plugin")
        return [tool.path(percentEncoded: false)] + args
    }

    /// Base env + ES_PATH_CONF / ES_TMPDIR, without JAVA_HOME / ES_JAVA_HOME / ES_JAVA_OPTS (bundled JDK only).
    func environment() -> [String: String] {
        var env = ServiceSpec.baseEnvironment()
        env["ES_PATH_CONF"] = ConfigText.path(paths.elasticsearchConfDir)
        env["ES_TMPDIR"] = ConfigText.path(paths.elasticsearchTmp)
        for key in ["JAVA_HOME", "ES_JAVA_HOME", "ES_JAVA_OPTS"] { env[key] = nil }
        return env
    }

    private func runTool(_ args: [String], command: String) async throws -> String {
        let config = try await configStore.load()
        let argv = try argv(args, config: config)
        for dir in [paths.elasticsearchConfDir, paths.elasticsearchTmp] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let result = await runner.run(argv, environment: environment(), timeout: Self.timeout)
        if result.timedOut { throw ElasticsearchError.pluginCommandTimedOut(command: command, output: result.output) }
        guard result.status == 0 else {
            throw ElasticsearchError.pluginCommandFailed(command: command, status: result.status, output: result.output)
        }
        return result.output
    }
}
