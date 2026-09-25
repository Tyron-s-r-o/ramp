import Darwin
import Foundation

/// A standalone Elasticsearch installation found next to RAMP (e.g. `~/Lib/elasticsearch-9.5.4`), plan 07-05.
public struct ElasticsearchSource: Sendable, Equatable, Codable, Hashable {
    /// ES home (`bin/elasticsearch`, `data/`).
    public var root: URL
    /// `9.5.4` (from the dir name or `lib/elasticsearch-<ver>.jar`), nil when unknown.
    public var version: String?

    public init(root: URL, version: String?) {
        self.root = root
        self.version = version
    }

    public var dataDir: URL { root.appending(path: "data", directoryHint: .isDirectory) }

    /// `9.5` from `9.5.4`.
    public var branch: String? {
        guard let parts = version?.split(separator: "."), parts.count >= 2 else { return nil }
        return "\(parts[0]).\(parts[1])"
    }
}

/// Dry-run result for an ES data migration. Nothing is written by `precheck`.
public struct ElasticsearchMigrationPrecheck: Sendable, Equatable {
    public var source: ElasticsearchSource
    public var target: URL
    public var targetBranch: String
    public var versionCompatible: Bool
    /// Why the source ES counts as running (empty = stopped).
    public var sourceRunning: [String] = []
    public var rampRunning = false
    public var bytes: Int64 = 0
    public var files = 0
    /// `node.lock`, `.DS_Store` — never copied.
    public var excludedFiles = 0
    public var freeBytes: Int64?
    public var requiredBytes: Int64 = 0
    public var clonePossible = false
    /// Target already holds data → it will be moved aside (`<branch>.pre-import-<ts>`), never deleted.
    public var targetHasData = false
    public var problems: [String] = []
    public var warnings: [String] = []

    public var ok: Bool { problems.isEmpty }
}

public struct ElasticsearchMigrationProgress: Sendable, Equatable {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var currentFile: String
}

public struct ElasticsearchMigrationResult: Sendable, Equatable {
    public var target: URL
    public var movedAside: URL?
    public var filesCopied: Int
    public var filesSkipped: Int
    public var cloned: Int
    public var bytes: Int64
    /// `index → docs.count` from the smoke test (nil = no smoke run).
    public var smokeIndices: [String: Int]?
    public var warnings: [String]
}

public enum ElasticsearchMigrationError: Error, LocalizedError, Equatable {
    case precheckFailed([String])
    case cancelled
    case activateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .precheckFailed(let problems): return problems.joined(separator: "\n")
        case .cancelled: return "Elasticsearch data migration cancelled (staging copy kept, run again to resume)"
        case .activateFailed(let message): return "Cannot move the copied data into place: \(message)"
        }
    }
}

/// Detects whether a standalone ES installation is running (read-only probes).
public protocol ElasticsearchSourceProbing: Sendable {
    func runningReasons(_ source: ElasticsearchSource) -> [String]
}

/// `ps` rows whose command line names the ES home + fcntl lock holder of `data/node.lock`.
public struct LiveElasticsearchSourceProbe: ElasticsearchSourceProbing {
    public init() {}

    public func runningReasons(_ source: ElasticsearchSource) -> [String] {
        var reasons: [String] = []
        let lock = source.dataDir.appending(path: "node.lock", directoryHint: .notDirectory).path(percentEncoded: false)
        if let pid = SourceUsageProbe.lockHolder(lock) {
            reasons.append("data/node.lock is locked by process \(pid) (Elasticsearch is running on this data dir)")
        }
        for (pid, command) in Self.processes(naming: source.root) {
            reasons.append("process \(pid) runs from the source: \(command.prefix(160))")
        }
        return reasons
    }

    static func processes(naming root: URL) -> [(pid_t, String)] {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return matching(psOutput: String(decoding: data, as: UTF8.self), root: root)
    }

    /// Rows naming `root` as a whole path component (`…/elasticsearch-9.5.4/…` or at the end / before a space).
    /// Our own `ps` and the LaunchAgent's idle shell (`/bin/bash …/es-autostop.sh`) are ignored — the script
    /// only runs for a moment every 15 min and never holds the data dir.
    static func matching(psOutput: String, root: URL) -> [(pid_t, String)] {
        let base = root.standardizedFileURL.path(percentEncoded: false).trimmingSlash
        let own = getpid()
        var rows: [(pid_t, String)] = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]), pid != own else { continue }
            let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard command.contains("java") || command.contains("elasticsearch") else { continue }
            if command.hasSuffix("es-autostop.sh") { continue }
            var searchRange = command.startIndex..<command.endIndex
            var hit = false
            while let r = command.range(of: base, range: searchRange) {
                let next = r.upperBound < command.endIndex ? command[r.upperBound] : " "
                if next == "/" || next == " " || next == "\"" { hit = true; break }
                searchRange = r.upperBound..<command.endIndex
            }
            if hit { rows.append((pid, String(command))) }
        }
        return rows
    }
}

/// Copies a standalone ES 9.x data dir into `<root>/elasticsearch-data/<branch>` (plan 07-05).
/// The source is only read (APFS clone per file, `node.lock` never copied); the copy goes to a staging dir that
/// survives cancellation (resume = same size + mtime) and is renamed into place at the end; existing target data
/// is moved aside to `<branch>.pre-import-<ts>`, never deleted.
public struct ElasticsearchDataMigrator: Sendable {
    public let paths: Paths
    public let targetBranch: String
    public let copier: DatadirCopier
    public let probe: any ElasticsearchSourceProbing
    /// RAMP's own ES running (pid file alive by default).
    public let rampRunning: @Sendable () -> Bool

    public init(paths: Paths, targetBranch: String = "9.5", copier: DatadirCopier = DatadirCopier(),
                probe: any ElasticsearchSourceProbing = LiveElasticsearchSourceProbe(),
                rampRunning: (@Sendable () -> Bool)? = nil) {
        self.paths = paths
        self.targetBranch = targetBranch
        self.copier = copier
        self.probe = probe
        self.rampRunning = rampRunning ?? { Self.pidFileAlive(paths.pidFile(service: ServiceID.elasticsearch.name)) }
    }

    public static func stagingDir(_ paths: Paths) -> URL {
        MySQLMigration.stagingDir(paths).appending(path: "es-data", directoryHint: .isDirectory)
    }
    static func stagingMarker(_ paths: Paths) -> URL {
        MySQLMigration.stagingDir(paths).appending(path: "es-data.source", directoryHint: .notDirectory)
    }

    public var target: URL { paths.elasticsearchData(branch: targetBranch) }

    // MARK: Detect

    /// `<home>/Lib/elasticsearch-*` (+ `extra` user-chosen dirs) that have `data/` and `bin/elasticsearch`.
    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              extra: [URL] = []) -> [ElasticsearchSource] {
        let fm = FileManager.default
        var candidates = extra
        let lib = home.appending(path: "Lib", directoryHint: .isDirectory)
        if let names = try? fm.contentsOfDirectory(atPath: lib.path(percentEncoded: false)) {
            candidates += names.filter { $0.hasPrefix("elasticsearch-") }.sorted()
                .map { lib.appending(path: $0, directoryHint: .isDirectory) }
        }
        var seen = Set<String>()
        return candidates.compactMap { dir in
            let root = dir.standardizedFileURL
            guard seen.insert(root.path(percentEncoded: false).trimmingSlash).inserted,
                  let source = source(at: root) else { return nil }
            return source
        }
    }

    /// Source at `root` when it looks like an ES home (`data/` dir + `bin/elasticsearch`).
    public static func source(at root: URL) -> ElasticsearchSource? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let data = root.appending(path: "data", directoryHint: .isDirectory).path(percentEncoded: false)
        guard fm.fileExists(atPath: data, isDirectory: &isDir), isDir.boolValue,
              fm.fileExists(atPath: root.appending(path: "bin/elasticsearch", directoryHint: .notDirectory)
                .path(percentEncoded: false)) else { return nil }
        return ElasticsearchSource(root: root, version: version(of: root))
    }

    /// `lib/elasticsearch-<ver>.jar`, else the dir name `elasticsearch-<ver>`.
    public static func version(of root: URL) -> String? {
        let lib = root.appending(path: "lib", directoryHint: .isDirectory).path(percentEncoded: false)
        let pattern = /^elasticsearch-(\d+\.\d+\.\d+)\.jar$/
        if let names = try? FileManager.default.contentsOfDirectory(atPath: lib) {
            for name in names.sorted() {
                if let m = name.wholeMatch(of: pattern) { return String(m.1) }
            }
        }
        if let m = root.lastPathComponent.wholeMatch(of: /^elasticsearch-(\d+\.\d+\.\d+)$/) { return String(m.1) }
        return nil
    }

    // MARK: Precheck

    public func precheck(source: ElasticsearchSource) -> ElasticsearchMigrationPrecheck {
        var p = ElasticsearchMigrationPrecheck(source: source, target: target, targetBranch: targetBranch,
                                               versionCompatible: source.branch == targetBranch)
        let fm = FileManager.default
        if !p.versionCompatible {
            p.problems.append("Elasticsearch \(source.version ?? "?") ≠ RAMP \(targetBranch) — iná verzia, migrácia nepodporovaná")
        }
        p.sourceRunning = probe.runningReasons(source)
        if !p.sourceRunning.isEmpty {
            p.problems.append("Zdrojový Elasticsearch beží — zastav ho: " + p.sourceRunning.joined(separator: "; "))
        }
        p.rampRunning = rampRunning()
        if p.rampRunning { p.problems.append("Elasticsearch v RAMP beží — zastav ho pred migráciou") }
        do {
            let scan = try Self.scan(source.dataDir)
            let copy = scan.files.filter { $0.category == .copy }
            p.files = copy.count
            p.bytes = copy.reduce(Int64(0)) { $0 + $1.size }
            p.excludedFiles = scan.files.count - copy.count
            p.warnings += scan.warnings
        } catch {
            p.problems.append("Dátový priečinok \(source.dataDir.path(percentEncoded: false)) sa nedá čítať")
        }
        p.clonePossible = DatadirCopier.clonePossible(source: source.dataDir, destination: Self.stagingDir(paths))
        p.requiredBytes = p.clonePossible ? min(p.bytes, 64 << 20) : p.bytes + p.bytes / 10
        p.freeBytes = Self.freeBytes(near: target)
        if let free = p.freeBytes, free < p.requiredBytes {
            p.problems.append("Málo miesta na disku: voľné \(free / 1_048_576) MB, potrebné \(p.requiredBytes / 1_048_576) MB")
        }
        let targetPath = target.path(percentEncoded: false)
        if let children = try? fm.contentsOfDirectory(atPath: targetPath), children.contains(where: { $0 != ".DS_Store" }) {
            p.targetHasData = true
            p.warnings.append("Cieľ \(targetPath) už obsahuje dáta — presunie sa bokom (\(targetBranch).pre-import-…), nič sa nezmaže")
        }
        return p
    }

    // MARK: Run

    /// Precheck (blocking) → copy into staging (resumable) → move old target aside → rename staging into place (0700)
    /// → optional `smoke` (start RAMP ES, `_cat/indices`, stop). Smoke failures become warnings; data stays.
    public func run(source: ElasticsearchSource, cancel: CancelFlag = CancelFlag(),
                    progress: @escaping @Sendable (ElasticsearchMigrationProgress) -> Void = { _ in },
                    smoke: (@Sendable () async throws -> [String: Int])? = nil,
                    now: Date = Date()) async throws -> ElasticsearchMigrationResult {
        let check = precheck(source: source)
        guard check.ok else { throw ElasticsearchMigrationError.precheckFailed(check.problems) }
        let fm = FileManager.default
        let staging = Self.stagingDir(paths)
        let marker = Self.stagingMarker(paths)
        let sourceKey = source.dataDir.standardizedFileURL.path(percentEncoded: false)
        // A staging copy of another source is never resumed.
        if fm.fileExists(atPath: staging.path(percentEncoded: false)),
           (try? String(contentsOf: marker, encoding: .utf8)) != sourceKey {
            try fm.removeItem(at: staging)
        }
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try Data(sourceKey.utf8).write(to: marker, options: .atomic)

        let scan = try Self.scan(source.dataDir)
        let report: DatadirCopyReport
        do {
            report = try await Task.detached(priority: .userInitiated) { [copier] in
                try copier.copy(scan, from: source.dataDir, to: staging, isCancelled: { cancel.isCancelled }) { c in
                    progress(ElasticsearchMigrationProgress(filesDone: c.filesDone, filesTotal: c.filesTotal,
                                                            bytesDone: c.bytesDone, bytesTotal: c.bytesTotal,
                                                            currentFile: c.currentFile))
                }
            }.value
        } catch DatadirCopyError.cancelled {
            throw ElasticsearchMigrationError.cancelled
        }
        if cancel.isCancelled { throw ElasticsearchMigrationError.cancelled }
        // Both nodes must still be stopped right before the switch.
        let recheck = probe.runningReasons(source)
        if !recheck.isEmpty || rampRunning() {
            throw ElasticsearchMigrationError.precheckFailed(recheck.isEmpty ? ["Elasticsearch v RAMP beží"] : recheck)
        }

        let target = self.target
        let targetPath = target.path(percentEncoded: false)
        var movedAside: URL?
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let children = try? fm.contentsOfDirectory(atPath: targetPath) {
            if children.contains(where: { $0 != ".DS_Store" }) {
                let aside = target.deletingLastPathComponent()
                    .appending(path: "\(targetBranch).pre-import-\(Self.stamp(now))", directoryHint: .isDirectory)
                guard rename(targetPath, aside.path(percentEncoded: false)) == 0 else {
                    throw ElasticsearchMigrationError.activateFailed(String(cString: strerror(errno)))
                }
                movedAside = aside
            } else {
                try fm.removeItem(at: target)   // empty dir (prepare() creates it)
            }
        }
        guard rename(staging.path(percentEncoded: false), targetPath) == 0 else {
            let e = String(cString: strerror(errno))
            if let movedAside { rename(movedAside.path(percentEncoded: false), targetPath) }
            throw ElasticsearchMigrationError.activateFailed(e)
        }
        chmod(targetPath, 0o700)
        try? fm.removeItem(at: marker)

        var result = ElasticsearchMigrationResult(target: target, movedAside: movedAside,
                                                  filesCopied: report.filesCopied, filesSkipped: report.filesSkipped,
                                                  cloned: report.cloned, bytes: report.bytes, smokeIndices: nil,
                                                  warnings: report.warnings)
        if let smoke {
            do {
                result.smokeIndices = try await smoke()
                if result.smokeIndices?.isEmpty ?? true {
                    result.warnings.append("Smoke test: RAMP Elasticsearch nevidí žiadny index")
                }
            } catch {
                result.warnings.append("Smoke test zlyhal: \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Removes a leftover staging copy (never the source or the target).
    public func discardStaging() throws {
        let fm = FileManager.default
        for url in [Self.stagingDir(paths), Self.stagingMarker(paths)] where fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: Helpers

    /// Datadir scan with ES rules: `node.lock` (and `.DS_Store`) never copied; everything else is data.
    static func scan(_ dataDir: URL) throws -> DatadirScan {
        var scan = try DatadirCopier().scan(dataDir)
        for i in scan.files.indices {
            let name = (scan.files[i].relativePath as NSString).lastPathComponent
            scan.files[i].category = (name == "node.lock" || name == ".DS_Store") ? .excluded : .copy
        }
        return scan
    }

    static func freeBytes(near url: URL) -> Int64? {
        var dir = url.standardizedFileURL
        let fm = FileManager.default
        while !fm.fileExists(atPath: dir.path(percentEncoded: false)), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func pidFileAlive(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// `GET http://127.0.0.1:<port>/_cat/indices?h=index,docs.count` → `[index: docs]` (system indices included).
    public static func catIndices(port: Int, host: String = "127.0.0.1") async throws -> [String: Int] {
        guard let url = URL(string: "http://\(host):\(port)/_cat/indices?h=index,docs.count") else { return [:] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ElasticsearchMigrationError.activateFailed("_cat/indices HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        var out: [String: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = parts.first else { continue }
            out[String(name)] = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        }
        return out
    }
}
