import Foundation

/// Group of a log file in the Logs section list.
public enum LogGroup: Hashable, Sendable, Comparable {
    case apache
    case php(String)
    case mysql
    case redis
    case elasticsearch
    case other

    private var rank: Int {
        switch self {
        case .apache: 0
        case .php: 1
        case .mysql: 2
        case .redis: 3
        case .elasticsearch: 4
        case .other: 5
        }
    }

    public static func < (lhs: LogGroup, rhs: LogGroup) -> Bool {
        if case .php(let a) = lhs, case .php(let b) = rhs {
            if let pa = PHPBranch(a), let pb = PHPBranch(b) { return pa < pb }
            return a < b
        }
        return lhs.rank < rhs.rank
    }

    /// Group derived from a file name (`apache-error.log`, `php8.3-fpm.log`, `mysql9.7.err`, `redis.log`, …).
    public static func of(fileName name: String) -> LogGroup {
        if name.hasPrefix("apache") { return .apache }
        if name.hasPrefix("php") {
            let rest = name.dropFirst(3)
            let branch = rest.prefix { $0.isNumber || $0 == "." }
            if !branch.isEmpty, PHPBranch(String(branch)) != nil { return .php(String(branch)) }
        }
        if name.hasPrefix("mysql") { return .mysql }
        if name.hasPrefix("redis") { return .redis }
        if name.hasPrefix("elasticsearch") { return .elasticsearch }
        return .other
    }
}

/// One log file under the RAMP logs directory.
public struct LogFile: Hashable, Sendable, Identifiable {
    public var url: URL
    public var name: String
    public var group: LogGroup
    public var size: UInt64
    public var modified: Date

    public var id: URL { url }

    public init(url: URL, name: String, group: LogGroup, size: UInt64, modified: Date) {
        self.url = url
        self.name = name
        self.group = group
        self.size = size
        self.modified = modified
    }
}

public enum LogCatalog {
    /// `*.log` and `*.err` directly in `logs` (no rotated `.1`, no subdirectories such as `xdebug/`),
    /// sorted by group, then name. A missing directory yields `[]`.
    public static func files(in logs: URL) -> [LogFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard var items = try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        // Elasticsearch's own server log lives in a subdirectory (06-04); listed as "elasticsearch/elasticsearch.log".
        items.append(logs.appending(path: esServerLog, directoryHint: .notDirectory))
        return items.compactMap { url -> LogFile? in
            let name = url.deletingLastPathComponent().lastPathComponent == "elasticsearch"
                ? esServerLog : url.lastPathComponent
            guard name.hasSuffix(".log") || name.hasSuffix(".err") else { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { return nil }
            return LogFile(url: url, name: name, group: LogGroup.of(fileName: name),
                           size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.group != $1.group ? $0.group < $1.group : $0.name < $1.name }
    }

    /// Preferred log file name for a service (Services "Log" button).
    public static func preferredFileName(for id: ServiceID) -> String {
        switch id {
        case .apache: "apache-error.log"
        case .phpFPM(let branch): "php\(branch)-error.log"
        case .mysql(let branch): "mysql\(branch).err"
        case .redis: "redis.log"
        case .elasticsearch: esServerLog
        case .custom: "\(id.name).log"
        }
    }

    /// ES server log relative to the logs dir (`path.logs` = `<logs>/elasticsearch`, cluster `elasticsearch`).
    public static let esServerLog = "elasticsearch/elasticsearch.log"
}
