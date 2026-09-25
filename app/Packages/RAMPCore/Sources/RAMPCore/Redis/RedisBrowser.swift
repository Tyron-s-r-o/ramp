import Foundation

/// A binary-safe key: raw bytes for commands + display text (UTF-8 or `0x…` hex).
public struct RedisKey: Sendable, Hashable, Identifiable, Comparable {
    public let data: Data
    public let name: String

    public init(_ data: Data) {
        self.data = data
        self.name = RedisValueFormat.display(data)
    }

    public init(_ name: String) {
        self.data = Data(name.utf8)
        self.name = name
    }

    public var id: Data { data }

    public static func < (a: RedisKey, b: RedisKey) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

public enum RedisKeyType: String, Sendable, Equatable, CaseIterable {
    case string, hash, list, set, zset, stream, none
    case other

    public init(reply: String) {
        self = RedisKeyType(rawValue: reply) ?? .other
    }
}

/// Keys / expires of one logical DB (`INFO keyspace` line `db0:keys=12,expires=3,avg_ttl=0`).
public struct RedisDBStats: Sendable, Equatable {
    public var keys: Int
    public var expires: Int
    public init(keys: Int, expires: Int) {
        self.keys = keys
        self.expires = expires
    }
}

public struct RedisKeyMeta: Sendable, Equatable {
    public var type: RedisKeyType
    /// Raw `TYPE` reply (module types like `ReJSON-RL` keep their name).
    public var typeName: String
    /// Milliseconds; `nil` = no expiry (PTTL -1); `-2` means the key vanished.
    public var ttlMillis: Int64?
    public var size: Int64?
    public var memory: Int64?
    public var exists: Bool

    public init(type: RedisKeyType, typeName: String, ttlMillis: Int64?, size: Int64?, memory: Int64?, exists: Bool = true) {
        self.type = type
        self.typeName = typeName
        self.ttlMillis = ttlMillis
        self.size = size
        self.memory = memory
        self.exists = exists
    }
}

/// Namespace tree node (`user:1:name` → `user` › `1` › `name`).
public struct RedisKeyNode: Sendable, Identifiable, Equatable {
    /// Folders: "prefix:" path with a trailing separator marker; leaves: the key name.
    public let id: String
    public let name: String
    public let key: RedisKey?
    public var children: [RedisKeyNode]?
    /// Leaf keys below (1 for a leaf).
    public var count: Int

    public var isFolder: Bool { key == nil }
}

public enum RedisKeyTree {
    /// Builds folders by `separator`; folders sorted before keys, both natural-order.
    public static func build(_ keys: [RedisKey], separator: String = ":") -> [RedisKeyNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var leaves: [(String, RedisKey)] = []
        }
        let root = Folder()
        for key in keys {
            var parts = key.name.components(separatedBy: separator)
            let leafName = parts.removeLast()
            var f = root
            for p in parts {
                if let next = f.folders[p] {
                    f = next
                } else {
                    let next = Folder()
                    f.folders[p] = next
                    f = next
                }
            }
            f.leaves.append((leafName, key))
        }
        func convert(_ f: Folder, prefix: String) -> [RedisKeyNode] {
            var nodes: [RedisKeyNode] = []
            for name in f.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let path = prefix + name + separator
                let children = convert(f.folders[name]!, prefix: path)
                nodes.append(RedisKeyNode(id: "\u{1}folder:" + path, name: name.isEmpty ? "∅" : name, key: nil,
                                          children: children, count: children.reduce(0) { $0 + $1.count }))
            }
            for (name, key) in f.leaves.sorted(by: { $0.0.localizedStandardCompare($1.0) == .orderedAscending }) {
                nodes.append(RedisKeyNode(id: key.name, name: name.isEmpty ? "∅" : name, key: key, children: nil, count: 1))
            }
            return nodes
        }
        return convert(root, prefix: "")
    }
}

/// String value (maybe only a prefix of it).
public struct RedisStringValue: Sendable, Equatable {
    public let data: Data
    /// STRLEN.
    public let total: Int64
    /// Only the first `RedisValueFormat.previewBytes` were fetched.
    public let truncated: Bool
}

public struct RedisScoredMember: Sendable, Equatable {
    public let member: Data
    public let score: String
}

public struct RedisStreamEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let fields: [RedisFieldValue]
}

public struct RedisFieldValue: Sendable, Equatable {
    public let field: Data
    public let value: Data
}

/// High-level, safe operations for the Redis browser. Never uses `KEYS`; listing is `SCAN` only and
/// bulk deletes go through `SCAN` + `UNLINK` in batches.
public actor RedisBrowserService {
    public nonisolated let client: RedisClient
    public static let scanCount = 500
    public static let pageSize = 100

    public init(host: String, port: Int, timeout: Duration = .seconds(3)) {
        client = RedisClient(host: host, port: port, timeout: timeout)
    }

    public init(client: RedisClient) {
        self.client = client
    }

    public func close() async { await client.close() }

    // MARK: Server / keyspace

    public static func parseKeyspace(_ info: String) -> [Int: RedisDBStats] {
        var out: [Int: RedisDBStats] = [:]
        for raw in info.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("db"), let colon = line.firstIndex(of: ":"),
                  let db = Int(line[line.index(line.startIndex, offsetBy: 2)..<colon]) else { continue }
            var stats = RedisDBStats(keys: 0, expires: 0)
            for pair in line[line.index(after: colon)...].split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let n = Int(kv[1]) else { continue }
                if kv[0] == "keys" { stats.keys = n }
                if kv[0] == "expires" { stats.expires = n }
            }
            out[db] = stats
        }
        return out
    }

    public func keyspace() async throws -> [Int: RedisDBStats] {
        let reply = try await client.call(["INFO", "keyspace"])
        return Self.parseKeyspace(reply.string ?? "")
    }

    /// `CONFIG GET databases` (falls back to 16 when CONFIG is renamed / disabled).
    public func databaseCount() async -> Int {
        guard let reply = try? await client.call(["CONFIG", "GET", "databases"]),
              let items = reply.elements, items.count >= 2, let n = items[1].int, n > 0 else { return 16 }
        return Int(min(n, 256))
    }

    public func select(_ db: Int) async throws {
        try await client.select(db)
    }

    public func dbSize() async throws -> Int {
        Int(try await client.call(["DBSIZE"]).int ?? 0)
    }

    // MARK: Listing

    /// One SCAN step. `cursor` "0" starts; the returned cursor "0" means done.
    public func scan(cursor: String, pattern: String, count: Int = scanCount) async throws -> (cursor: String, keys: [RedisKey]) {
        var args = ["SCAN", cursor]
        let p = pattern.isEmpty ? "*" : pattern
        if p != "*" { args += ["MATCH", p] }
        args += ["COUNT", String(count)]
        let reply = try await client.call(args)
        guard let parts = reply.elements, parts.count == 2, let next = parts[0].string,
              let keys = parts[1].elements else { throw RESPError.protocolError("unexpected SCAN reply") }
        return (next, keys.compactMap(\.data).map(RedisKey.init))
    }

    /// SCAN until at least `count` keys are collected or the iteration ends (MATCH can return empty pages).
    public func scanPage(cursor: String, pattern: String, count: Int = scanCount, maxSteps: Int = 50) async throws -> (cursor: String, keys: [RedisKey]) {
        var cur = cursor
        var keys: [RedisKey] = []
        var seen = Set<Data>()
        var steps = 0
        repeat {
            let step = try await scan(cursor: cur, pattern: pattern, count: count)
            for k in step.keys where seen.insert(k.data).inserted { keys.append(k) }
            cur = step.cursor
            steps += 1
        } while cur != "0" && keys.count < count && steps < maxSteps
        return (cur, keys)
    }

    /// TYPE for many keys in one pipelined round-trip.
    public func types(_ keys: [RedisKey]) async throws -> [RedisKey: String] {
        let replies = try await client.pipeline(keys.map { [Data("TYPE".utf8), $0.data] })
        var out: [RedisKey: String] = [:]
        for (k, r) in zip(keys, replies) { out[k] = r.string ?? "?" }
        return out
    }

    public func meta(_ key: RedisKey, memory: Bool = true) async throws -> RedisKeyMeta {
        let typeName = try await client.call([Data("TYPE".utf8), key.data]).string ?? "none"
        let type = RedisKeyType(reply: typeName)
        let pttl = try await client.call([Data("PTTL".utf8), key.data]).int ?? -1
        let sizeCommand: String? = switch type {
        case .string: "STRLEN"
        case .hash: "HLEN"
        case .list: "LLEN"
        case .set: "SCARD"
        case .zset: "ZCARD"
        case .stream: "XLEN"
        default: nil
        }
        var size: Int64?
        if let sizeCommand {
            size = try await client.call([Data(sizeCommand.utf8), key.data]).int
        }
        var mem: Int64?
        if memory, type != .none {
            // Optional: MEMORY may be disabled / renamed.
            if case .integer(let n) = try await client.command([Data("MEMORY".utf8), Data("USAGE".utf8), key.data]) {
                mem = n
            }
        }
        return RedisKeyMeta(type: type, typeName: typeName, ttlMillis: pttl < 0 ? (pttl == -2 ? -2 : nil) : pttl,
                            size: size, memory: mem, exists: type != .none)
    }

    // MARK: Detail

    /// String value; > `largeValueBytes` fetches only the first `previewBytes` unless `full`.
    public func string(_ key: RedisKey, full: Bool = false) async throws -> RedisStringValue {
        let total = try await client.call([Data("STRLEN".utf8), key.data]).int ?? 0
        if !full, total > RedisValueFormat.largeValueBytes {
            let r = try await client.call([Data("GETRANGE".utf8), key.data, Data("0".utf8),
                                           Data(String(RedisValueFormat.previewBytes - 1).utf8)])
            return RedisStringValue(data: r.data ?? Data(), total: total, truncated: true)
        }
        let r = try await client.call([Data("GET".utf8), key.data])
        return RedisStringValue(data: r.data ?? Data(), total: total, truncated: false)
    }

    public func hash(_ key: RedisKey, cursor: String = "0", count: Int = scanCount) async throws -> (pairs: [RedisFieldValue], cursor: String) {
        let r = try await client.call([Data("HSCAN".utf8), key.data, Data(cursor.utf8), Data("COUNT".utf8), Data(String(count).utf8)])
        guard let parts = r.elements, parts.count == 2, let items = parts[1].elements else {
            throw RESPError.protocolError("unexpected HSCAN reply")
        }
        var pairs: [RedisFieldValue] = []
        var i = 0
        while i + 1 < items.count {
            pairs.append(RedisFieldValue(field: items[i].data ?? Data(), value: items[i + 1].data ?? Data()))
            i += 2
        }
        return (pairs, parts[0].string ?? "0")
    }

    public func list(_ key: RedisKey, start: Int, count: Int = pageSize) async throws -> [Data] {
        let r = try await client.call([Data("LRANGE".utf8), key.data, Data(String(start).utf8), Data(String(start + count - 1).utf8)])
        return (r.elements ?? []).compactMap(\.data)
    }

    public func set(_ key: RedisKey, cursor: String = "0", count: Int = scanCount) async throws -> (members: [Data], cursor: String) {
        let r = try await client.call([Data("SSCAN".utf8), key.data, Data(cursor.utf8), Data("COUNT".utf8), Data(String(count).utf8)])
        guard let parts = r.elements, parts.count == 2, let items = parts[1].elements else {
            throw RESPError.protocolError("unexpected SSCAN reply")
        }
        return (items.compactMap(\.data), parts[0].string ?? "0")
    }

    public func zset(_ key: RedisKey, start: Int, count: Int = pageSize) async throws -> [RedisScoredMember] {
        let r = try await client.call([Data("ZRANGE".utf8), key.data, Data(String(start).utf8),
                                       Data(String(start + count - 1).utf8), Data("WITHSCORES".utf8)])
        let items = r.elements ?? []
        var out: [RedisScoredMember] = []
        // RESP2: flat [m, s, m, s]; RESP3: [[m, s], …].
        if items.allSatisfy({ $0.elements != nil }) {
            for pair in items {
                if let p = pair.elements, p.count == 2 { out.append(RedisScoredMember(member: p[0].data ?? Data(), score: p[1].string ?? "")) }
            }
        } else {
            var i = 0
            while i + 1 < items.count {
                out.append(RedisScoredMember(member: items[i].data ?? Data(), score: items[i + 1].string ?? ""))
                i += 2
            }
        }
        return out
    }

    /// Newest `count` entries (XREVRANGE), newest first.
    public func stream(_ key: RedisKey, count: Int = 50) async throws -> [RedisStreamEntry] {
        let r = try await client.call([Data("XREVRANGE".utf8), key.data, Data("+".utf8), Data("-".utf8),
                                       Data("COUNT".utf8), Data(String(count).utf8)])
        return (r.elements ?? []).compactMap { entry in
            guard let e = entry.elements, e.count == 2, let id = e[0].string else { return nil }
            let flat = e[1].elements ?? []
            var fields: [RedisFieldValue] = []
            var i = 0
            while i + 1 < flat.count {
                fields.append(RedisFieldValue(field: flat[i].data ?? Data(), value: flat[i + 1].data ?? Data()))
                i += 2
            }
            return RedisStreamEntry(id: id, fields: fields)
        }
    }

    // MARK: Mutations

    /// SET keeping the current TTL (Redis ≥ 6.0 `KEEPTTL`).
    public func setString(_ key: RedisKey, value: Data) async throws {
        try await client.call([Data("SET".utf8), key.data, value, Data("KEEPTTL".utf8)])
    }

    public func expire(_ key: RedisKey, seconds: Int) async throws {
        try await client.call([Data("EXPIRE".utf8), key.data, Data(String(seconds).utf8)])
    }

    public func persist(_ key: RedisKey) async throws {
        try await client.call([Data("PERSIST".utf8), key.data])
    }

    /// RENAMENX — never overwrites an existing key. Returns false when `newName` already exists.
    public func rename(_ key: RedisKey, to newName: RedisKey) async throws -> Bool {
        let r = try await client.call([Data("RENAMENX".utf8), key.data, newName.data])
        return r.int == 1
    }

    public func delete(_ keys: [RedisKey]) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        let r = try await client.call([Data("UNLINK".utf8)] + keys.map(\.data))
        return Int(r.int ?? 0)
    }

    /// Counts keys matching `pattern` with a full SCAN (for the confirmation dialog).
    public func count(matching pattern: String) async throws -> Int {
        var cursor = "0"
        var seen = Set<Data>()
        repeat {
            let step = try await scan(cursor: cursor, pattern: pattern, count: 1000)
            for k in step.keys { seen.insert(k.data) }
            cursor = step.cursor
        } while cursor != "0"
        return seen.count
    }

    /// SCAN + UNLINK in batches of up to 500. Returns the number of keys removed.
    public func delete(matching pattern: String, batch: Int = 500) async throws -> Int {
        var cursor = "0"
        var removed = 0
        repeat {
            let step = try await scan(cursor: cursor, pattern: pattern, count: 1000)
            var i = 0
            while i < step.keys.count {
                removed += try await delete(Array(step.keys[i..<min(i + batch, step.keys.count)]))
                i += batch
            }
            cursor = step.cursor
        } while cursor != "0"
        return removed
    }

    public func flushAll() async throws {
        try await client.call(["FLUSHALL"])
    }
}
