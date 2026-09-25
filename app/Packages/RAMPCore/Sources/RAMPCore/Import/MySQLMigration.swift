import Darwin
import Foundation

// MAMP PRO MySQL 8.0 → RAMP migration engine (plan 07-04).
//   (a) datadirUpgrade: clone copy without binlogs → 8.4.11 in-place upgrade → account auth conversion
//       → 9.7.2 in-place upgrade → verify → activate (rename into mysql-data/<branch>).
//   (b) logical: per-DB mysqldump of the running MAMP server → RAMP mysql.
// Resumable (state in <root>/.staging/mamp-import/mysql-state.json), cancellable, dry-run precheck.
// The source datadir is only ever read; no mysqld is ever started on it.

public enum MigrationMethod: String, Codable, Sendable, CaseIterable {
    case datadirUpgrade = "datadir"
    case logical
}

/// Last completed phase (the failure, if any, is kept separately in `MigrationState.failure`).
public enum MigrationPhase: String, Codable, Sendable, CaseIterable {
    case precheck, copying, copied, upgraded84, usersConverted, upgraded97, verified, activated
    /// Method (b).
    case importing, imported
}

public struct MigrationFailure: Codable, Sendable, Equatable {
    /// Step that failed (named after the phase it was producing).
    public var step: String
    public var message: String
    public var at: Date
}

/// (size, mtime) of `mysql.ibd` + entry count of the source — must never change because of us.
public struct SourceFingerprint: Codable, Sendable, Equatable {
    public var mysqlIbdSize: Int64
    /// Seconds since 1970 with sub-second precision (a JSON `Date` would be rounded to whole seconds).
    public var mysqlIbdMtime: Double
    public var entryCount: Int

    public init(mysqlIbdSize: Int64, mysqlIbdMtime: Double, entryCount: Int) {
        self.mysqlIbdSize = mysqlIbdSize
        self.mysqlIbdMtime = mysqlIbdMtime
        self.entryCount = entryCount
    }

    public static func of(_ scan: DatadirScan) -> SourceFingerprint {
        let ibd = scan.files.first { $0.relativePath == "mysql.ibd" }
        return SourceFingerprint(mysqlIbdSize: ibd?.size ?? -1, mysqlIbdMtime: ibd?.modified.timeIntervalSince1970 ?? 0,
                                 entryCount: scan.files.count + scan.directories.count + scan.internalSymlinks.count)
    }

    public func matches(_ other: SourceFingerprint) -> Bool {
        mysqlIbdSize == other.mysqlIbdSize && entryCount == other.entryCount
            && abs(mysqlIbdMtime - other.mysqlIbdMtime) < 0.000_01
    }
}

public struct AccountChange: Codable, Sendable, Equatable {
    public var user: String
    public var host: String
    public var from: String
    public var to: String
}

public struct MigrationState: Codable, Sendable, Equatable {
    public var version = 1
    public var method: MigrationMethod
    public var sourcePath: String
    /// Final MySQL branch: "9.7" (default) or "8.4" (keeps mysql_native_password possible — ISS-004).
    public var targetBranch: String
    public var phase: MigrationPhase = .precheck
    public var failure: MigrationFailure?
    public var sourceFingerprint: SourceFingerprint?
    public var copiedFiles = 0
    public var skippedFiles = 0
    public var copiedBytes: Int64 = 0
    /// Schema names (decoded) from the precheck (a) / the source server (b).
    public var schemas: [String] = []
    public var tableCounts84: [String: Int] = [:]
    public var tableCountsFinal: [String: Int] = [:]
    public var sourceTableCounts: [String: Int] = [:]
    public var lowerCaseTableNames: Int?
    /// branch → `SELECT VERSION()`.
    public var serverVersions: [String: String] = [:]
    /// branch → upgrade markers seen in the error log.
    public var upgradeMarkers: [String: [String]] = [:]
    public var convertedAccounts: [AccountChange] = []
    public var keptNativeAccounts: [MySQLAccount] = []
    public var unconvertedAccounts: [MySQLAccount] = []
    public var doneDatabases: [String] = []
    public var inProgressDatabase: String?
    public var installed84ByMigration = false
    public var movedAsidePath: String?
    public var warnings: [String] = []
    /// step → seconds.
    public var timings: [String: Double] = [:]
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?

    public init(method: MigrationMethod, sourcePath: String, targetBranch: String, now: Date = Date()) {
        self.method = method
        self.sourcePath = sourcePath
        self.targetBranch = targetBranch
        startedAt = now
        updatedAt = now
    }

    public var isComplete: Bool { phase == .activated || phase == .imported }
}

/// Steps of the state machine (pure transition table, tested).
public enum MigrationStep: String, Sendable, Equatable {
    case copy, upgrade84, convertUsers, upgrade97, verify, activate, importDatabases

    /// Phase reached when the step succeeds.
    public var resultPhase: MigrationPhase {
        switch self {
        case .copy: .copied
        case .upgrade84: .upgraded84
        case .convertUsers: .usersConverted
        case .upgrade97: .upgraded97
        case .verify: .verified
        case .activate: .activated
        case .importDatabases: .imported
        }
    }

    public static func next(after state: MigrationState) -> MigrationStep? {
        switch state.method {
        case .logical:
            return state.phase == .imported ? nil : .importDatabases
        case .datadirUpgrade:
            switch state.phase {
            case .precheck, .copying, .importing: return .copy
            case .copied: return .upgrade84
            case .upgraded84: return .convertUsers
            case .usersConverted: return state.targetBranch == "8.4" ? .verify : .upgrade97
            case .upgraded97: return .verify
            case .verified: return .activate
            case .activated, .imported: return nil
            }
        }
    }
}

public struct MigrationOptions: Sendable {
    public var method: MigrationMethod
    public var source: URL
    /// "9.7" (default) or "8.4".
    public var targetBranch: String
    /// MAMP root password (default MAMP: "root"). Becomes RAMP's `mysql.rootPassword` after activation.
    public var rootPassword: String
    public var rootAuthPlugin: MySQLAuthPlugin
    /// Per-account target plugins (+ passwords) — ISS-004.
    public var accountRequests: [AccountAuthRequest]
    /// Keep the mysql 8.4 package after a successful 9.7 migration.
    public var keep84: Bool
    /// Sockets whose connectability means "source in use" (a) / the source server (b; first entry).
    /// nil = MAMP's socket when the source is MAMP's datadir.
    public var sourceSockets: [URL]?
    /// MAMP's 8.0 mysqldump (fallback for method b).
    public var fallbackDump: URL?
    public var upgradeTimeout: Duration
    /// Leave RAMP MySQL running after activation / logical import (the app); rampctl stops it again.
    public var leaveRunning: Bool
    /// (b) import into databases that already exist in RAMP.
    public var replaceExistingDatabases: Bool
    /// Test hook: interrupt the copy after N newly copied files.
    public var interruptCopyAfterFiles: Int?

    public init(method: MigrationMethod, source: URL = SourceUsageProbe.mampDatadir, targetBranch: String = "9.7",
                rootPassword: String = "root", rootAuthPlugin: MySQLAuthPlugin = .cachingSHA2,
                accountRequests: [AccountAuthRequest] = [], keep84: Bool = false, sourceSockets: [URL]? = nil,
                fallbackDump: URL? = SourceUsageProbe.mampBin.appending(path: "mysqldump"),
                upgradeTimeout: Duration = .seconds(3600), leaveRunning: Bool = true,
                replaceExistingDatabases: Bool = false, interruptCopyAfterFiles: Int? = nil) {
        self.method = method
        self.source = source
        self.targetBranch = targetBranch
        self.rootPassword = rootPassword
        self.rootAuthPlugin = rootAuthPlugin
        self.accountRequests = accountRequests
        self.keep84 = keep84
        self.sourceSockets = sourceSockets
        self.fallbackDump = fallbackDump
        self.upgradeTimeout = upgradeTimeout
        self.leaveRunning = leaveRunning
        self.replaceExistingDatabases = replaceExistingDatabases
        self.interruptCopyAfterFiles = interruptCopyAfterFiles
    }

    var resolvedSockets: [URL] { sourceSockets ?? SourceUsageProbe.defaultSockets(for: source) }
    /// Socket of the running source server (method b).
    var sourceServerSocket: URL { sourceSockets?.first ?? SourceUsageProbe.mampSocket }
}

public enum MigrationProgress: Sendable, Equatable {
    case phase(MigrationPhase)
    case step(MigrationStep)
    case copy(DatadirCopyProgress)
    case server(branch: String, elapsedSeconds: Int, lastLogLine: String?)
    case database(name: String, index: Int, total: Int)
    case info(String)
}

public struct MigrationPackageStatus: Sendable, Equatable {
    public var branch: String
    public var inManifest: String?
    public var installed: String?
    public var downloadSize: Int64?
}

/// Dry-run result (no writes, no processes except `ps`).
public struct MigrationPrecheck: Sendable {
    public var method: MigrationMethod
    public var source: URL
    public var sourceExists = false
    public var sourceReadable = false
    public var usage = SourceUsage()
    /// (b) source server socket accepts connections.
    public var sourceReachable: Bool?
    public var schemas: [String] = []
    public var sizes = DatadirSizes()
    public var freeBytes: Int64?
    public var clonePossible = false
    public var requiredBytes: Int64 = 0
    public var packages: [MigrationPackageStatus] = []
    public var mysqlshPath: String?
    public var mysqldAutoCnf: String?
    public var problems: [String] = []
    public var warnings: [String] = []

    public var ok: Bool { problems.isEmpty }
    public var sourceInUse: Bool { usage.inUse }
}

public enum PrecheckMath {
    public static let headroom: Int64 = 5 * 1024 * 1024 * 1024

    /// Clone: copy-on-write → headroom only; else to-copy + 10 % + headroom.
    public static func requiredBytes(toCopy: Int64, clonePossible: Bool) -> Int64 {
        clonePossible ? headroom : toCopy + toCopy / 10 + headroom
    }
}

public enum MigrationError: Error, LocalizedError, Equatable {
    case sourceMissing(String)
    case sourceInUse([String])
    case sourceChanged
    case precheckFailed([String])
    case alreadyRunning(Int32)
    case stateMismatch(String)
    case packageUnavailable(String)
    case verifyFailed(String)
    case rampMySQLRunning(String)
    case activationFailed(String)
    case notConfigured(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let p): "Source datadir not found: \(p)"
        case .sourceInUse(let reasons):
            "MAMP MySQL is running on the source datadir — stop MySQL in MAMP PRO first.\n"
                + reasons.joined(separator: "\n")
        case .sourceChanged:
            "The source datadir changed since the copy started (MAMP MySQL was started?). Discard the copy and start again."
        case .precheckFailed(let p): "Precheck failed:\n" + p.joined(separator: "\n")
        case .alreadyRunning(let pid): "A MySQL migration is already running (pid \(pid))."
        case .stateMismatch(let m): "An unfinished migration with different settings exists (\(m)) — discard it first."
        case .packageUnavailable(let m): "MySQL package unavailable: \(m)"
        case .verifyFailed(let m): "Verification failed: \(m)"
        case .rampMySQLRunning(let m): "RAMP MySQL is still running (\(m)) — stop it first."
        case .activationFailed(let m): "Activation failed (previous state restored): \(m)"
        case .notConfigured(let m): m
        case .cancelled: "Cancelled — state kept, run again to resume."
        }
    }
}

// MARK: - Collaborators

/// Stop/start of RAMP's own MySQL service (StackController in the app and rampctl).
public protocol MigrationStackControlling: Sendable {
    func stopMySQLService(branch: String) async
    /// Renders configs and starts the service (bootstrapping a never-initialized datadir).
    func startMySQLService(branch: String) async -> ServiceState
}

extension StackController: MigrationStackControlling {
    public func stopMySQLService(branch: String) async {
        await stop(.mysql(branch))
    }

    public func startMySQLService(branch: String) async -> ServiceState {
        do { try await prepare() } catch { return .failed(reason: error.localizedDescription) }
        return await start(.mysql(branch))
    }
}

/// Global maintenance lock (07-02 `MaintenanceLock(.mampImport)` conforms when it lands). Returns a release closure.
public protocol MigrationLocking: Sendable {
    func acquireForMySQLMigration() async throws -> @Sendable () async -> Void
}

/// Execution context handed to the steps.
public struct MigrationContext: Sendable {
    public var options: MigrationOptions
    public var progress: @Sendable (MigrationProgress) -> Void
    public var cancel: CancelFlag
    /// Persists an intermediate state (per-DB progress of method b, copy start).
    public var save: @Sendable (MigrationState) async throws -> Void
}

/// The work behind each step (real implementation: `DefaultMigrationSteps`; tests inject fakes).
public protocol MySQLMigrationSteps: Sendable {
    func copy(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState
    func upgrade(branch: String, _ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState
    func convertUsers(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState
    func verify(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState
    func activate(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState
    func importDatabases(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState
    /// Always called at the end of a run (success, failure, cancel): stop temporary servers, cleanups.
    func finish(_ state: MigrationState, _ ctx: MigrationContext) async -> MigrationState
}

// MARK: - Engine

public actor MySQLMigration {
    public let paths: Paths
    public let configStore: ConfigStore
    private let steps: any MySQLMigrationSteps
    private let lock: (any MigrationLocking)?
    private var cancelFlag: CancelFlag?
    private var runTask: Task<MigrationState, any Error>?

    public init(paths: Paths, configStore: ConfigStore? = nil, installer: PackageInstaller? = nil,
                stack: (any MigrationStackControlling)? = nil, lock: (any MigrationLocking)? = nil,
                steps: (any MySQLMigrationSteps)? = nil) {
        self.paths = paths
        let store = configStore ?? ConfigStore(paths: paths)
        self.configStore = store
        self.lock = lock
        self.steps = steps ?? DefaultMigrationSteps(
            paths: paths, configStore: store,
            installer: installer ?? PackageInstaller(paths: paths, configStore: store),
            stack: stack ?? StackController(paths: paths, configStore: store))
    }

    public static func stagingDir(_ paths: Paths) -> URL {
        paths.staging.appending(path: "mamp-import", directoryHint: .isDirectory)
    }
    public static func stateURL(_ paths: Paths) -> URL {
        stagingDir(paths).appending(path: "mysql-state.json", directoryHint: .notDirectory)
    }
    public static func datadirCopy(_ paths: Paths) -> URL {
        stagingDir(paths).appending(path: "datadir", directoryHint: .isDirectory)
    }
    static func lockURL(_ paths: Paths) -> URL {
        stagingDir(paths).appending(path: "mysql-run.lock", directoryHint: .notDirectory)
    }
    static func tempDir(_ paths: Paths) -> URL {
        stagingDir(paths).appending(path: "tmp", directoryHint: .isDirectory)
    }

    // MARK: State persistence

    public nonisolated func loadState() -> MigrationState? {
        guard let data = try? Data(contentsOf: Self.stateURL(paths)) else { return nil }
        return try? Self.decoder.decode(MigrationState.self, from: data)
    }

    func saveState(_ state: MigrationState) throws {
        var s = state
        s.updatedAt = Date()
        let dir = Self.stagingDir(paths)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(s)
        let url = Self.stateURL(paths)
        let tmp = dir.appending(path: ".mysql-state.json.tmp", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: tmp.path(percentEncoded: false), contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path(percentEncoded: false), url.path(percentEncoded: false)) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// PID of a `run` holding the run lock (another process or this one), nil when idle.
    public nonisolated func runningPID() -> Int32? {
        let path = Self.lockURL(paths).path(percentEncoded: false)
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    // MARK: Precheck

    /// Dry run: never writes, never starts a server.
    public func precheck(source: URL = SourceUsageProbe.mampDatadir, method: MigrationMethod,
                         targetBranch: String = "9.7", sourceSockets: [URL]? = nil) async -> MigrationPrecheck {
        var p = MigrationPrecheck(method: method, source: source)
        let fm = FileManager.default
        let path = source.path(percentEncoded: false)
        var isDir: ObjCBool = false
        p.sourceExists = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        let sockets = sourceSockets ?? SourceUsageProbe.defaultSockets(for: source)
        if p.sourceExists {
            do {
                let scan = try DatadirCopier().scan(source)
                p.sourceReadable = true
                p.sizes = scan.sizes
                p.schemas = scan.schemaDirectories.map(MySQLFilename.decode)
                p.warnings += scan.warnings
                let auto = source.appending(path: "mysqld-auto.cnf")
                if let data = try? Data(contentsOf: auto), data.count < 65536 {
                    p.mysqldAutoCnf = String(decoding: data, as: UTF8.self)
                }
            } catch {
                p.warnings.append(error.localizedDescription)
            }
            p.usage = SourceUsageProbe.check(datadir: source, sockets: sockets)
        }
        p.clonePossible = p.sourceExists && DatadirCopier.clonePossible(source: source, destination: Self.stagingDir(paths))
        p.freeBytes = Self.freeBytes(at: paths.root)
        p.requiredBytes = PrecheckMath.requiredBytes(toCopy: p.sizes.toCopyBytes,
                                                    clonePossible: method == .datadirUpgrade && p.clonePossible)
        p.mysqlshPath = Self.findMysqlsh()

        let config = try? await configStore.load()
        var manifest: Manifest?
        if let url = config?.manifestURL { manifest = try? await ManifestLoader.load(url) }
        let needed: [String]
        switch method {
        case .datadirUpgrade: needed = targetBranch == "8.4" ? ["8.4"] : ["8.4", "9.7"]
        case .logical: needed = [config?.mysql.branch ?? "9.7"]
        }
        for branch in needed {
            let entry = manifest?.entry(component: "mysql", branch: branch)
            let status = MigrationPackageStatus(branch: branch, inManifest: entry?.version,
                                                installed: config?.installed["mysql"]?[branch]?.version,
                                                downloadSize: entry?.size)
            p.packages.append(status)
            if status.installed == nil && status.inManifest == nil {
                p.problems.append("mysql \(branch) is neither installed nor in the manifest")
            }
        }

        if !p.sourceExists { p.problems.append("source datadir not found: \(path)") }
        switch method {
        case .datadirUpgrade:
            if p.sourceExists && !p.sourceReadable { p.problems.append("source datadir is not readable") }
            if p.usage.inUse {
                p.problems.append("sourceInUse: MAMP MySQL is running — stop MySQL in MAMP PRO")
            }
            if let free = p.freeBytes, free < p.requiredBytes {
                p.problems.append("not enough free space: \(Self.gb(free)) free, \(Self.gb(p.requiredBytes)) required")
            }
            if targetBranch != "9.7" && targetBranch != "8.4" { p.problems.append("unsupported target \(targetBranch)") }
        case .logical:
            let socket = sourceSockets?.first ?? SourceUsageProbe.mampSocket
            let reachable = SocketAddress.canConnectUnix(path: socket.path(percentEncoded: false))
            p.sourceReachable = reachable
            if !reachable {
                p.problems.append("source MySQL not reachable on \(socket.path(percentEncoded: false)) — start MySQL in MAMP PRO")
            }
            if config?.installed["mysql"]?[config?.mysql.branch ?? "9.7"] == nil {
                p.problems.append("RAMP MySQL \(config?.mysql.branch ?? "9.7") is not installed")
            }
            if let free = p.freeBytes, free < p.requiredBytes {
                p.warnings.append("free space \(Self.gb(free)) may be too small (~\(Self.gb(p.requiredBytes)) of data)")
            }
        }
        if p.sizes.binlogBytes > 0 { p.warnings.append("binlogs excluded: \(Self.gb(p.sizes.binlogBytes))") }
        return p
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }

    static func freeBytes(at url: URL) -> Int64? {
        var dir = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func findMysqlsh() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/mysqlsh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Run

    /// Runs (or resumes) the migration. Progress events go to `progress` (finished at the end).
    @discardableResult
    public func run(_ options: MigrationOptions,
                    progress: AsyncStream<MigrationProgress>.Continuation? = nil) async throws -> MigrationState {
        defer { progress?.finish() }
        let flag = CancelFlag()
        cancelFlag = flag
        let task = Task { try await self.body(options, progress: progress, cancel: flag) }
        runTask = task
        defer {
            runTask = nil
            cancelFlag = nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            flag.cancel()
            task.cancel()
        }
    }

    /// Stops the running migration cleanly (temporary mysqld gets SIGTERM, state is kept).
    public func cancel() {
        cancelFlag?.cancel()
        runTask?.cancel()
    }

    /// Removes the staging copy + state. Never touches the source, RAMP's mysql-data or moved-aside datadirs.
    public func discard() async throws {
        if let pid = runningPID() { throw MigrationError.alreadyRunning(pid) }
        let fm = FileManager.default
        for url in [Self.datadirCopy(paths), Self.tempDir(paths), Self.stateURL(paths), Self.lockURL(paths)]
        where fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try fm.removeItem(at: url)
        }
    }

    private func body(_ options: MigrationOptions, progress: AsyncStream<MigrationProgress>.Continuation?,
                      cancel: CancelFlag) async throws -> MigrationState {
        let runLock = try acquireRunLock()
        defer { releaseRunLock(runLock) }
        let release = try await lock?.acquireForMySQLMigration()
        let sourcePath = options.source.standardizedFileURL.path(percentEncoded: false)
        var state: MigrationState
        if let existing = loadState() {
            if existing.method != options.method || existing.sourcePath != sourcePath
                || existing.targetBranch != options.targetBranch {
                await release?()
                throw MigrationError.stateMismatch("\(existing.method.rawValue) from \(existing.sourcePath) → \(existing.targetBranch)")
            }
            state = existing
        } else {
            state = MigrationState(method: options.method, sourcePath: sourcePath, targetBranch: options.targetBranch)
        }
        if state.isComplete {
            await release?()
            return state
        }
        state.failure = nil
        let emit: @Sendable (MigrationProgress) -> Void = { progress?.yield($0) }
        let ctx = MigrationContext(options: options, progress: emit, cancel: cancel,
                                   save: { [weak self] s in try await self?.saveState(s) })
        var current = MigrationStep.copy
        do {
            if state.phase == .precheck || (state.method == .datadirUpgrade && state.phase == .copying) {
                try await gate(&state, options)
            }
            try saveState(state)
            while let step = MigrationStep.next(after: state) {
                current = step
                if cancel.isCancelled || Task.isCancelled { throw MigrationError.cancelled }
                emit(.step(step))
                if step == .copy, state.phase != .copying {
                    state.phase = .copying
                    try saveState(state)
                } else if step == .importDatabases, state.phase != .importing {
                    state.phase = .importing
                    try saveState(state)
                }
                let started = Date()
                switch step {
                case .copy: state = try await steps.copy(state, ctx)
                case .upgrade84: state = try await steps.upgrade(branch: "8.4", state, ctx)
                case .convertUsers: state = try await steps.convertUsers(state, ctx)
                case .upgrade97: state = try await steps.upgrade(branch: "9.7", state, ctx)
                case .verify: state = try await steps.verify(state, ctx)
                case .activate: state = try await steps.activate(state, ctx)
                case .importDatabases: state = try await steps.importDatabases(state, ctx)
                }
                state.timings[step.rawValue, default: 0] += Date().timeIntervalSince(started)
                state.phase = step.resultPhase
                if state.isComplete { state.finishedAt = Date() }
                try saveState(state)
                emit(.phase(state.phase))
            }
        } catch {
            let message: String
            if cancel.isCancelled || Task.isCancelled || error is CancellationError {
                message = MigrationError.cancelled.localizedDescription
            } else {
                message = error.localizedDescription
            }
            // Steps persist intermediate progress (per-DB list, copy phase) — continue from the latest saved state.
            if let persisted = loadState() { state = persisted }
            state.failure = MigrationFailure(step: current.resultPhase.rawValue, message: message, at: Date())
            state = await steps.finish(state, ctx)
            try? saveState(state)
            await release?()
            if cancel.isCancelled || Task.isCancelled { throw MigrationError.cancelled }
            throw error
        }
        state = await steps.finish(state, ctx)
        try saveState(state)
        await release?()
        return state
    }

    /// Start-of-run checks for steps that still read the source.
    private func gate(_ state: inout MigrationState, _ options: MigrationOptions) async throws {
        let fm = FileManager.default
        let path = options.source.path(percentEncoded: false)
        guard fm.fileExists(atPath: path) else { throw MigrationError.sourceMissing(path) }
        switch options.method {
        case .datadirUpgrade:
            let usage = SourceUsageProbe.check(datadir: options.source, sockets: options.resolvedSockets)
            if usage.inUse { throw MigrationError.sourceInUse(usage.reasons) }
            let scan = try DatadirCopier().scan(options.source)
            let fp = SourceFingerprint.of(scan)
            if let recorded = state.sourceFingerprint, !recorded.matches(fp) { throw MigrationError.sourceChanged }
            if state.phase == .precheck {
                let check = await precheck(source: options.source, method: .datadirUpgrade,
                                           targetBranch: options.targetBranch, sourceSockets: options.sourceSockets)
                if !check.ok { throw MigrationError.precheckFailed(check.problems) }
                state.schemas = check.schemas
                state.warnings += check.warnings
                state.sourceFingerprint = fp
            }
        case .logical:
            let socket = options.sourceServerSocket
            if !SocketAddress.canConnectUnix(path: socket.path(percentEncoded: false)) {
                throw LogicalMigrationError.sourceUnreachable(socket.path(percentEncoded: false))
            }
        }
    }

    private func acquireRunLock() throws -> Int32 {
        let dir = Self.stagingDir(paths)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = Self.lockURL(paths).path(percentEncoded: false)
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            close(fd)
            throw MigrationError.alreadyRunning(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1)
        }
        ftruncate(fd, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBufferPointer { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return fd
    }

    private func releaseRunLock(_ fd: Int32) {
        ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
    }
}

// MARK: - Real steps

public actor DefaultMigrationSteps: MySQLMigrationSteps {
    let paths: Paths
    let configStore: ConfigStore
    let installer: PackageInstaller
    let stack: any MigrationStackControlling
    let runner: MySQLUpgradeRunner
    /// Target service started by the logical import (stopped again unless `leaveRunning`).
    private var startedTargetService: String?

    public init(paths: Paths, configStore: ConfigStore, installer: PackageInstaller, stack: any MigrationStackControlling) {
        self.paths = paths
        self.configStore = configStore
        self.installer = installer
        self.stack = stack
        self.runner = MySQLUpgradeRunner(paths: paths)
    }

    var datadir: URL { MySQLMigration.datadirCopy(paths) }
    var tempDir: URL { MySQLMigration.tempDir(paths) }

    func bin(_ branch: String, _ tool: String) -> URL {
        paths.current(component: "mysql", branch: branch).appending(path: "bin/\(tool)", directoryHint: .notDirectory)
    }

    // MARK: copy

    public func copy(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        var s = state
        s.phase = .copying
        try await ctx.save(s)
        let source = ctx.options.source
        let copier = DatadirCopier()
        let scan = try copier.scan(source)
        let destination = datadir
        let cancel = ctx.cancel
        let emit = ctx.progress
        let interrupt = ctx.options.interruptCopyAfterFiles
        let report = try await withCheckedThrowingContinuation { (c: CheckedContinuation<DatadirCopyReport, any Error>) in
            Thread.detachNewThread {
                c.resume(with: Result {
                    try copier.copy(scan, from: source, to: destination, interruptAfter: interrupt,
                                    isCancelled: { cancel.isCancelled }, progress: { emit(.copy($0)) })
                })
            }
        }
        s.copiedFiles += report.filesCopied
        s.skippedFiles = report.filesSkipped
        s.copiedBytes += report.bytes
        s.warnings += report.warnings.filter { !s.warnings.contains($0) }
        // The source must not have changed while copying.
        let after = SourceFingerprint.of(try copier.scan(source))
        if let recorded = s.sourceFingerprint, !recorded.matches(after) { throw MigrationError.sourceChanged }
        return s
    }

    // MARK: upgrade

    private func ensurePackage(_ branch: String, _ state: inout MigrationState) async throws {
        let config = try await configStore.load()
        if config.installed["mysql"]?[branch] != nil,
           FileManager.default.isExecutableFile(atPath: bin(branch, "mysqld").path(percentEncoded: false)) { return }
        guard let url = config.manifestURL else { throw MigrationError.packageUnavailable("no manifest configured") }
        let manifest = try await ManifestLoader.load(url)
        try await installer.install(component: "mysql", branch: branch, from: manifest)
        if branch == "8.4" { state.installed84ByMigration = true }
    }

    private func startServer(_ branch: String, _ ctx: MigrationContext) async throws -> MySQLUpgradeRunner.Server {
        let emit = ctx.progress
        return try await runner.start(branch: branch, datadir: datadir, timeout: ctx.options.upgradeTimeout) { elapsed, line in
            emit(.server(branch: branch, elapsedSeconds: Int(elapsed.components.seconds), lastLogLine: line))
        }
    }

    public func upgrade(branch: String, _ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        var s = state
        try await ensurePackage(branch, &s)
        await runner.stop()
        let server = try await startServer(branch, ctx)
        s.upgradeMarkers[branch] = server.events.compactMap { event -> String? in
            switch event {
            case .dictionaryUpgradeStarted(let a, let b): "Data dictionary upgrading from version '\(a)' to '\(b)'"
            case .dictionaryUpgradeCompleted(let a, let b): "Data dictionary upgrade from version '\(a)' to '\(b)' completed"
            case .serverUpgradeStarted(let a, let b): "Server upgrade from '\(a)' to '\(b)' started"
            case .serverUpgradeCompleted(let a, let b): "Server upgrade from '\(a)' to '\(b)' completed"
            case .ready(let v): "ready for connections, version \(v)"
            case .unloadedAuthPlugin(let u, let h, let p): "\(p) not loaded for '\(u)'@'\(h)'"
            default: nil
            }
        }
        s.serverVersions[branch] = server.version
        let unloaded = server.events.compactMap { e -> MySQLAccount? in
            if case .unloadedAuthPlugin(let u, let h, let p) = e { MySQLAccount(user: u, host: h, plugin: p) } else { nil }
        }
        for account in unloaded where !s.unconvertedAccounts.contains(account) && !s.keptNativeAccounts.contains(account) {
            s.unconvertedAccounts.append(account)
        }
        return s
    }

    private func client(_ server: MySQLUpgradeRunner.Server, password: String) -> MySQLClient {
        MySQLClient(binary: bin(server.branch, "mysql"), socket: server.socket, user: "root", password: password,
                    tempDir: tempDir)
    }

    private func running(_ branch: String, _ ctx: MigrationContext) async throws -> MySQLUpgradeRunner.Server {
        if let current = await runner.current, current.branch == branch { return current }
        return try await startServer(branch, ctx)
    }

    static let schemaSQL = "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN "
        + "('mysql','sys','performance_schema','information_schema') ORDER BY schema_name;"
    static let countSQL = "SELECT s.schema_name, COUNT(t.table_name) FROM information_schema.schemata s "
        + "LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name WHERE s.schema_name NOT IN "
        + "('mysql','sys','performance_schema','information_schema') GROUP BY s.schema_name;"

    static func counts(_ rows: [[String]]) -> [String: Int] {
        Dictionary(rows.compactMap { $0.count >= 2 ? ($0[0], Int($0[1]) ?? 0) : nil }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: users (8.4 running)

    public func convertUsers(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        var s = state
        let server = try await running("8.4", ctx)
        let pw = ctx.options.rootPassword
        let c = client(server, password: pw)
        do {
            let info = try await c.rows("SELECT VERSION(), @@lower_case_table_names;")
            if let row = info.first, row.count >= 2 {
                s.serverVersions["8.4"] = row[0]
                s.lowerCaseTableNames = Int(row[1])
            }
        } catch MySQLClientError.accessDenied(let m) {
            throw MySQLClientError.accessDenied("MAMP root password rejected by the migrated server (\(m))")
        }
        s.tableCounts84 = Self.counts(try await c.rows(Self.countSQL))
        let accounts = try await c.rows("SELECT user, host, plugin FROM mysql.user ORDER BY user, host;")
            .filter { $0.count >= 3 }.map { MySQLAccount(user: $0[0], host: $0[1], plugin: $0[2]) }
            .filter { !$0.user.hasPrefix("mysql.") }
        let plan = try AccountAuthPlanner.plan(accounts: accounts, requests: ctx.options.accountRequests, rootPassword: pw,
                                               rootPlugin: ctx.options.rootAuthPlugin, targetBranch: s.targetBranch)
        _ = try await c.execute(AccountAuthPlanner.sql(plan, rootPassword: pw, rootPlugin: ctx.options.rootAuthPlugin))
        s.convertedAccounts = plan.conversions.map {
            AccountChange(user: $0.account.user, host: $0.account.host, from: $0.account.plugin, to: $0.plugin.rawValue)
        }
        s.keptNativeAccounts = plan.keptNative
        s.unconvertedAccounts = plan.unconverted
        // mysql_tzinfo_to_sql not needed: RAMP does not rely on time-zone tables (they are not upgraded either).
        return s
    }

    // MARK: verify (final branch running)

    public func verify(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        var s = state
        let branch = s.targetBranch
        await runner.stop()   // fresh start of the final branch: proves a clean restart after the upgrade
        let server = try await startServer(branch, ctx)
        let c = client(server, password: ctx.options.rootPassword)
        let version = try await c.rows("SELECT VERSION();").first?.first ?? ""
        s.serverVersions[branch] = version
        let schemas = try await c.rows(Self.schemaSQL).compactMap(\.first)
        s.tableCountsFinal = Self.counts(try await c.rows(Self.countSQL))
        var problems: [String] = []
        if schemas.count != s.schemas.count {
            problems.append("schema count \(schemas.count) ≠ precheck \(s.schemas.count) "
                            + "(server: \(schemas.joined(separator: ", ")); datadir: \(s.schemas.joined(separator: ", ")))")
        }
        if !s.tableCounts84.isEmpty && s.tableCountsFinal != s.tableCounts84 {
            let diff = Set(s.tableCounts84.keys).union(s.tableCountsFinal.keys).sorted()
                .filter { s.tableCounts84[$0] != s.tableCountsFinal[$0] }
                .map { "\($0): 8.4=\(s.tableCounts84[$0].map(String.init) ?? "-") \(branch)=\(s.tableCountsFinal[$0].map(String.init) ?? "-")" }
            problems.append("table counts differ: " + diff.joined(separator: "; "))
        }
        if !schemas.isEmpty {
            let probe = schemas.map { "USE \(SQL.identifier($0)); SELECT 1;" }.joined(separator: "\n")
            _ = try await c.execute(probe)
        }
        await runner.stop()
        if !problems.isEmpty { throw MigrationError.verifyFailed(problems.joined(separator: "\n")) }
        return s
    }

    // MARK: activate

    private func rampMySQLRunning(_ branch: String) -> String? {
        let pidFile = paths.pidFile(service: ServiceID.mysql(branch).name)
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0 {
            return "pid \(pid)"
        }
        let socket = paths.mysqlSocket(major: branch)
        if SocketAddress.canConnectUnix(path: socket.path(percentEncoded: false)) { return socket.path(percentEncoded: false) }
        return nil
    }

    public func activate(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        var s = state
        let branch = s.targetBranch
        await runner.stop()
        let fm = FileManager.default
        let copy = datadir
        guard fm.fileExists(atPath: copy.path(percentEncoded: false)) else {
            throw MigrationError.activationFailed("staging copy missing: \(copy.path(percentEncoded: false))")
        }
        let before = try await configStore.load()
        await stack.stopMySQLService(branch: before.mysql.branch)
        if before.mysql.branch != branch { await stack.stopMySQLService(branch: branch) }
        for b in Set([before.mysql.branch, branch]) {
            if let running = rampMySQLRunning(b) { throw MigrationError.rampMySQLRunning("mysql \(b): \(running)") }
        }
        let target = paths.mysqlData(major: branch)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var aside: URL?
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            let stamp = Self.stamp()
            let a = target.deletingLastPathComponent().appending(path: "\(branch).pre-import-\(stamp)", directoryHint: .isDirectory)
            try fm.moveItem(at: target, to: a)
            aside = a
        }
        func rollback(_ reason: String) async -> MigrationError {
            await stack.stopMySQLService(branch: branch)
            if fm.fileExists(atPath: target.path(percentEncoded: false)), !fm.fileExists(atPath: copy.path(percentEncoded: false)) {
                try? fm.moveItem(at: target, to: copy)
            }
            if let aside { try? fm.moveItem(at: aside, to: target) }
            _ = try? await configStore.update {
                $0.mysql.rootPassword = before.mysql.rootPassword
                $0.mysql.initialized = before.mysql.initialized
                $0.mysql.branch = before.mysql.branch
            }
            return .activationFailed(reason)
        }
        do {
            try fm.moveItem(at: copy, to: target)
        } catch {
            throw await rollback("rename into \(target.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        let password = ctx.options.rootPassword
        do {
            _ = try await configStore.update {
                $0.mysql.rootPassword = password
                $0.mysql.initialized = true
                $0.mysql.branch = branch
            }
        } catch {
            throw await rollback("ramp.json: \(error.localizedDescription)")
        }
        let started = await stack.startMySQLService(branch: branch)
        guard started.isRunning else {
            if case .failed(let reason) = started { throw await rollback("MySQL did not start: \(reason)") }
            throw await rollback("MySQL did not start (\(started))")
        }
        let c = MySQLClient(binary: bin(branch, "mysql"), socket: paths.mysqlSocket(major: branch), user: "root",
                            password: password, tempDir: tempDir)
        do {
            let version = try await c.rows("SELECT VERSION();").first?.first ?? ""
            s.serverVersions["ramp-\(branch)"] = version
        } catch {
            throw await rollback("SELECT VERSION() on RAMP MySQL: \(error.localizedDescription)")
        }
        if !ctx.options.leaveRunning { await stack.stopMySQLService(branch: branch) }
        s.movedAsidePath = aside?.path(percentEncoded: false)
        return s
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // MARK: logical

    public func importDatabases(_ state: MigrationState, _ ctx: MigrationContext) async throws -> MigrationState {
        var s = state
        s.phase = .importing
        let config = try await configStore.load()
        let branch = config.mysql.branch
        guard config.installed["mysql"]?[branch] != nil else {
            throw MigrationError.notConfigured("RAMP MySQL \(branch) is not installed")
        }
        let sourceSocket = ctx.options.sourceServerSocket
        guard SocketAddress.canConnectUnix(path: sourceSocket.path(percentEncoded: false)) else {
            throw LogicalMigrationError.sourceUnreachable(sourceSocket.path(percentEncoded: false))
        }
        let targetSocket = paths.mysqlSocket(major: branch)
        if !SocketAddress.canConnectUnix(path: targetSocket.path(percentEncoded: false)) {
            let started = await stack.startMySQLService(branch: branch)
            guard started.isRunning else { throw LogicalMigrationError.targetUnreachable("\(started)") }
            startedTargetService = branch
        }
        let targetPassword = try await configStore.load().mysql.rootPassword
        let source = MySQLEndpoint(socket: sourceSocket, password: ctx.options.rootPassword)
        let target = MySQLEndpoint(socket: targetSocket, password: targetPassword)
        let migrator = LogicalDBMigrator(binDir: bin(branch, "mysql").deletingLastPathComponent(),
                                         fallbackDump: ctx.options.fallbackDump, tempDir: tempDir)
        let dbs = try await migrator.databases(source)
        s.schemas = dbs.map(\.name)
        s.sourceTableCounts = try await migrator.tableCounts(source)
        let existing = try await migrator.client(target).rows(Self.schemaSQL).compactMap(\.first)
        let conflicts = dbs.map(\.name).filter { existing.contains($0) && !s.doneDatabases.contains($0) && $0 != s.inProgressDatabase }
        if !conflicts.isEmpty && !ctx.options.replaceExistingDatabases {
            throw LogicalMigrationError.targetDatabaseExists(conflicts)
        }
        try await ctx.save(s)
        for (index, db) in dbs.enumerated() where !s.doneDatabases.contains(db.name) {
            if ctx.cancel.isCancelled { throw MigrationError.cancelled }
            ctx.progress(.database(name: db.name, index: index + 1, total: dbs.count))
            if s.inProgressDatabase == db.name || conflicts.contains(db.name) {
                try await migrator.dropDatabase(db.name, target: target)   // redo the interrupted DB only
            }
            s.inProgressDatabase = db.name
            try await ctx.save(s)
            if try await migrator.migrate(db, source: source, target: target, cancel: ctx.cancel) {
                s.warnings.append("\(db.name): dumped with the MAMP 8.0 mysqldump (RAMP mysqldump failed)")
            }
            let after = try await migrator.tableCounts(target)
            let expected = s.sourceTableCounts[db.name] ?? 0
            if (after[db.name] ?? 0) != expected {
                throw LogicalMigrationError.verifyFailed(database: db.name, source: expected, target: after[db.name] ?? 0)
            }
            s.tableCountsFinal[db.name] = after[db.name] ?? 0
            s.doneDatabases.append(db.name)
            s.inProgressDatabase = nil
            try await ctx.save(s)
        }
        s.serverVersions["ramp-\(branch)"] = try await migrator.client(target).rows("SELECT VERSION();").first?.first ?? ""
        return s
    }

    // MARK: finish

    public func finish(_ state: MigrationState, _ ctx: MigrationContext) async -> MigrationState {
        var s = state
        await runner.stop()
        if let branch = startedTargetService, !ctx.options.leaveRunning {
            await stack.stopMySQLService(branch: branch)
        }
        startedTargetService = nil
        try? FileManager.default.removeItem(at: tempDir)
        if s.phase == .activated, s.targetBranch != "8.4", s.installed84ByMigration, !ctx.options.keep84 {
            do {
                try await removePackage84()
                s.installed84ByMigration = false
            } catch {
                s.warnings.append("mysql 8.4 package could not be removed: \(error.localizedDescription)")
            }
        }
        return s
    }

    /// Removes `<root>/mysql/8.4` (current link) + `<root>/mysql/<8.4.x>` and the ramp.json record.
    private func removePackage84() async throws {
        let config = try await configStore.load()
        guard config.mysql.branch != "8.4", let record = config.installed["mysql"]?["8.4"] else { return }
        try PackageInstaller.requireSafeSegment(record.version)
        let fm = FileManager.default
        for url in [paths.branchDir(component: "mysql", branch: "8.4"), paths.package(component: "mysql", version: record.version)]
        where PortProbe.isUnder(url.path(percentEncoded: false), root: paths.root) {
            try? fm.removeItem(at: url)
        }
        _ = try await configStore.update { $0.installed["mysql"]?["8.4"] = nil }
    }
}
