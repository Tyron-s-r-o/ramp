import Darwin
import Foundation
import ServiceManagement

/// Real side effects of an uninstall. Every privileged/system action is individually switchable so rampctl
/// and DEBUG fake-home runs never touch the real helper, login item or preferences.
public struct LiveUninstallActions: UninstallActions {
    public let paths: Paths
    public let config: RampConfig
    public let stack: StackController
    public let hosts: (any HostsSyncing)?
    /// `false` (rampctl, fake home) → the SMAppService / UserDefaults steps are no-ops.
    public let systemIntegration: Bool
    /// Lock hook — default: the stack's global `MaintenanceLock(.uninstall)` (fails fast with `busy` while an
    /// update / dump / MAMP import runs, in this process or — via `run/maintenance.lock` — in another one).
    public let lock: @Sendable () async throws -> @Sendable () async -> Void

    public init(paths: Paths, config: RampConfig, stack: StackController, hosts: (any HostsSyncing)?,
                systemIntegration: Bool,
                lock: (@Sendable () async throws -> @Sendable () async -> Void)? = nil) {
        self.paths = paths
        self.config = config
        self.stack = stack
        self.hosts = hosts
        self.systemIntegration = systemIntegration
        let maintenance = stack.maintenance
        self.lock = lock ?? {
            let token = try await maintenance.acquire(.uninstall)
            return { await maintenance.release(token) }
        }
    }

    public func acquireLock() async throws -> @Sendable () async -> Void {
        try await lock()
    }

    public func stopServices() async {
        await stack.stopAll()
        // Services started by another process (a separate `rampctl up`): pid files, but only processes whose
        // executable lives inside the RAMP root (a stale pid could belong to anything else).
        Self.terminateRampProcesses(paths: paths)
    }

    public func dumpAllDatabases(to url: URL) async throws {
        let id = ServiceID.mysql(config.mysql.branch)
        if await stack.status()[id]?.isRunning != true {
            let state = await stack.start(id)
            guard state.isRunning else { throw UninstallError.dumpFailed("MySQL did not start: \(state)") }
        }
        do {
            try await UninstallMySQLDump.dumpAll(paths: paths, config: config, to: url)
        } catch {
            await stack.stop(id)
            throw error
        }
        await stack.stop(id)
    }

    public func removeHostsBlock() async throws {
        guard let hosts else { throw HostsSyncError.helperUnavailable("no hosts sync configured") }
        _ = try await hosts.apply(names: [])
    }

    public func unregisterHelper() async throws {
        guard systemIntegration else { return }
        let service = SMAppService.daemon(plistName: "sk.tyron.ramp.hostshelper.plist")
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        try await service.unregister()
    }

    public func unregisterLoginItem() async throws {
        guard systemIntegration else { return }
        let service = SMAppService.mainApp
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        try await service.unregister()
    }

    public func removePreferencesDomain(_ bundleID: String) async {
        guard systemIntegration else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
    }

    public func moveToTrash(_ url: URL) async throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// SIGTERM (then SIGKILL after 15 s) to pids from `run/supervisor/*.pid` + `run/rampctl.pid` whose
    /// executable is inside `paths.root` (rampctl itself is exempt from the path rule only when its pid file
    /// names a process called `rampctl`).
    static func terminateRampProcesses(paths: Paths) {
        let fm = FileManager.default
        var pidFiles = ((try? fm.contentsOfDirectory(at: paths.supervisorRunDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pid" }
        pidFiles.append(paths.runDir.appending(path: "rampctl.pid", directoryHint: .notDirectory))
        let root = UninstallPathGuard.canonical(paths.root.path(percentEncoded: false))
        var targets: [pid_t] = []
        for file in pidFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
                  pid != getpid(), kill(pid, 0) == 0, let exe = executablePath(pid) else { continue }
            let insideRoot = UninstallPathGuard.isInside(UninstallPathGuard.canonical(exe), root)
            let isRampctl = file.lastPathComponent == "rampctl.pid" && (exe as NSString).lastPathComponent == "rampctl"
            if insideRoot || isRampctl { targets.append(pid) }
        }
        for pid in targets { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, targets.contains(where: { kill($0, 0) == 0 }) {
            usleep(200_000)
        }
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// `mysqldump --all-databases` for the uninstall backup (07-02's `MySQLDumper` can replace it later).
/// Credentials travel in a 0600 temp defaults file (never argv); success = exit 0 + `-- Dump completed`.
public enum UninstallMySQLDump {
    public static func dumpAll(paths: Paths, config: RampConfig, to url: URL) async throws {
        let fm = FileManager.default
        let branch = config.mysql.branch
        let bin = paths.current(component: "mysql", branch: branch).appending(path: "bin/mysqldump")
        guard fm.isExecutableFile(atPath: bin.path(percentEncoded: false)) else {
            throw UninstallError.dumpFailed("mysqldump not found at \(bin.path(percentEncoded: false))")
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.tmp, withIntermediateDirectories: true)

        let text = ConfigText(dialect: .backslash, separator: "=", commentPrefix: "#")
        let cnf = "[client]\nuser=root\npassword=\(try text.quote(config.mysql.rootPassword))\n"
            + "socket=\(try text.quote(ConfigText.path(paths.mysqlSocket(major: branch))))\n"
        let cnfURL = paths.tmp.appending(path: ".uninstall-dump-\(UUID().uuidString).cnf", directoryHint: .notDirectory)
        let errURL = paths.tmp.appending(path: ".uninstall-dump-\(UUID().uuidString).err", directoryHint: .notDirectory)
        defer {
            try? fm.removeItem(at: cnfURL)
            try? fm.removeItem(at: errURL)
        }
        guard fm.createFile(atPath: cnfURL.path(percentEncoded: false), contents: Data(cnf.utf8),
                            attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: url.path(percentEncoded: false), contents: nil,
                            attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errURL.path(percentEncoded: false), contents: nil,
                            attributes: [.posixPermissions: 0o600]),
              let out = try? FileHandle(forWritingTo: url), let errH = try? FileHandle(forWritingTo: errURL)
        else {
            try? fm.removeItem(at: url)
            throw UninstallError.dumpFailed("cannot create \(url.path(percentEncoded: false))")
        }

        let p = Process()
        p.executableURL = bin
        p.arguments = ["--defaults-extra-file=\(ConfigText.path(cnfURL))", "--all-databases", "--routines",
                       "--events", "--triggers", "--single-transaction", "--hex-blob", "--set-gtid-purged=OFF",
                       "--default-character-set=utf8mb4"]
        p.environment = ServiceSpec.baseEnvironment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = errH
        let status: Int32 = await withCheckedContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch {
                p.terminationHandler = nil
                c.resume(returning: -1)
            }
        }
        try? out.close()
        try? errH.close()
        guard status == 0, lastLine(of: url)?.contains("-- Dump completed") == true else {
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: url)
            throw UninstallError.dumpFailed("mysqldump exit \(status): "
                                            + stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func lastLine(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map(String.init)
    }
}
