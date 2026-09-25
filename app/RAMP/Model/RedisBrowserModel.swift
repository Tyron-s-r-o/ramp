import AppKit
import Foundation
import Observation
import RAMPCore

/// Loaded content of the selected key (one page of it for collections).
enum RedisDetail: Equatable {
    case string(RedisStringValue)
    case hash([RedisFieldValue], cursor: String)
    case list([Data], start: Int)
    case set([Data], cursor: String)
    case zset([RedisScoredMember], start: Int)
    case stream([RedisStreamEntry])
    case unsupported(String)
}

/// State of the native Redis browser (Databáza › Redis). SCAN-only listing, never `KEYS *`.
@MainActor @Observable
final class RedisBrowserModel {
    private(set) var databaseCount = 16
    private(set) var dbStats: [Int: RedisDBStats] = [:]
    private(set) var db = 0

    /// Applied MATCH pattern (the search field commits into this).
    private(set) var pattern = "*"
    private(set) var keys: [RedisKey] = []
    private(set) var types: [RedisKey: String] = [:]
    private(set) var tree: [RedisKeyNode] = []
    private(set) var cursor = "0"
    private(set) var loadingKeys = false
    private(set) var error: String?

    var selectedID: String? {
        didSet {
            if selectedID != oldValue { Task { await loadSelected() } }
        }
    }
    private(set) var selectedKey: RedisKey?
    private(set) var meta: RedisKeyMeta?
    private(set) var detail: RedisDetail?
    private(set) var loadingDetail = false
    private(set) var detailError: String?
    private(set) var working = false

    var autoRefresh = false {
        didSet { if autoRefresh != oldValue { restartAutoRefresh() } }
    }

    @ObservationIgnored private var service: RedisBrowserService?
    @ObservationIgnored private var endpoint: (host: String, port: Int)?
    @ObservationIgnored private var keyByID: [String: RedisKey] = [:]
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored weak var app: AppModel?

    static let autoRefreshInterval: Duration = .seconds(3)

    var hasMore: Bool { cursor != "0" }
    var totalInDB: Int { dbStats[db]?.keys ?? 0 }

    // MARK: Connection

    /// (Re)creates the client when host/port changed. Cheap; called before every load.
    func configure(host: String, port: Int) {
        #if DEBUG
        if ScreenshotMode.isActive { loadDemo(); return }   // never connects to a real Redis
        #endif
        if let endpoint, endpoint.host == host, endpoint.port == port, service != nil { return }
        let old = service
        Task { await old?.close() }
        service = RedisBrowserService(host: host, port: port)
        endpoint = (host, port)
    }

    func disconnect() {
        autoRefresh = false
        let old = service
        Task { await old?.close() }
        service = nil
        endpoint = nil
    }

    // MARK: Loading

    /// Keyspace + first page of keys (keeps the selection when the key still exists).
    func reload() async {
        await loadKeyspace()
        await loadKeys(reset: true)
        if selectedKey != nil { await loadSelected() }
    }

    func loadKeyspace() async {
        guard let service else { return }
        do {
            dbStats = try await service.keyspace()
            databaseCount = await service.databaseCount()
            error = nil
        } catch {
            self.error = Self.message(error)
        }
    }

    func selectDB(_ newDB: Int) async {
        guard newDB != db else { return }
        db = newDB
        clearSelection()
        await loadKeys(reset: true)
    }

    func applyPattern(_ text: String) async {
        let p = text.trimmingCharacters(in: .whitespaces)
        pattern = p.isEmpty ? "*" : p
        await loadKeys(reset: true)
    }

    /// First page (`reset`) or the next SCAN page ("Načítať ďalšie").
    func loadKeys(reset: Bool) async {
        guard let service, !loadingKeys else { return }
        if !reset && !hasMore { return }
        loadingKeys = true
        defer { loadingKeys = false }
        do {
            try await service.select(db)
            let page = try await service.scanPage(cursor: reset ? "0" : cursor, pattern: pattern)
            var list = reset ? [] : keys
            let known = Set(list)
            let fresh = page.keys.filter { !known.contains($0) }
            list.append(contentsOf: fresh)
            let t = try await service.types(fresh)
            if reset { types = t } else { types.merge(t) { $1 } }
            keys = list
            cursor = page.cursor
            rebuildTree()
            error = nil
        } catch {
            self.error = Self.message(error)
            if reset {
                keys = []
                cursor = "0"
                rebuildTree()
            }
        }
    }

    private func rebuildTree() {
        let sorted = keys.sorted()
        tree = RedisKeyTree.build(sorted)
        keyByID = Dictionary(sorted.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var flatKeys: [RedisKey] { keys.sorted() }

    func clearSelection() {
        selectedID = nil
        selectedKey = nil
        meta = nil
        detail = nil
        detailError = nil
    }

    // MARK: Detail

    func loadSelected() async {
        guard let id = selectedID, let key = keyByID[id] else {
            selectedKey = nil
            meta = nil
            detail = nil
            return
        }
        await loadDetail(key)
    }

    func loadDetail(_ key: RedisKey, full: Bool = false) async {
        guard let service else { return }
        let changed = selectedKey != key
        selectedKey = key
        if changed {
            meta = nil
            detail = nil
        }
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            try await service.select(db)
            let m = try await service.meta(key)
            guard selectedKey == key else { return }
            meta = m
            let d: RedisDetail
            switch m.type {
            case .string:
                d = .string(try await service.string(key, full: full))
            case .hash:
                let page = try await service.hash(key)
                d = .hash(page.pairs, cursor: page.cursor)
            case .list:
                // Keep the current page on refresh.
                var start = 0
                if !changed, case .list(_, let s) = detail { start = s }
                d = .list(try await service.list(key, start: start), start: start)
            case .set:
                let page = try await service.set(key)
                d = .set(page.members, cursor: page.cursor)
            case .zset:
                var start = 0
                if !changed, case .zset(_, let s) = detail { start = s }
                d = .zset(try await service.zset(key, start: start), start: start)
            case .stream:
                d = .stream(try await service.stream(key))
            case .none:
                d = .unsupported("none")
            case .other:
                d = .unsupported(m.typeName)
            }
            guard selectedKey == key else { return }
            detail = d
            detailError = nil
        } catch {
            detailError = Self.message(error)
        }
    }

    func loadFullString() async {
        guard let key = selectedKey else { return }
        await loadDetail(key, full: true)
    }

    func page(_ start: Int) async {
        guard let service, let key = selectedKey, let detail else { return }
        let s = max(0, start)
        do {
            switch detail {
            case .list: self.detail = .list(try await service.list(key, start: s), start: s)
            case .zset: self.detail = .zset(try await service.zset(key, start: s), start: s)
            default: break
            }
        } catch {
            detailError = Self.message(error)
        }
    }

    /// Next HSCAN / SSCAN page, appended.
    func loadMoreMembers() async {
        guard let service, let key = selectedKey, let detail else { return }
        do {
            switch detail {
            case .hash(let pairs, let cur) where cur != "0":
                let page = try await service.hash(key, cursor: cur)
                self.detail = .hash(pairs + page.pairs, cursor: page.cursor)
            case .set(let members, let cur) where cur != "0":
                let page = try await service.set(key, cursor: cur)
                self.detail = .set(members + page.members, cursor: page.cursor)
            default: break
            }
        } catch {
            detailError = Self.message(error)
        }
    }

    // MARK: Mutations (all confirmed in the view)

    func saveString(_ text: String) async -> Bool {
        guard let key = selectedKey else { return false }
        return await mutate(String(localized: "Hodnotu sa nepodarilo uložiť")) { s in
            try await s.setString(key, value: Data(text.utf8))
        }
    }

    func setTTL(seconds: Int?) async {
        guard let key = selectedKey else { return }
        _ = await mutate(String(localized: "TTL sa nepodarilo zmeniť")) { s in
            if let seconds { try await s.expire(key, seconds: seconds) } else { try await s.persist(key) }
        }
    }

    /// `false` = target exists (RENAMENX never overwrites) or failure.
    func rename(to newName: String) async -> Bool {
        guard let service, let key = selectedKey, !newName.isEmpty, newName != key.name else { return false }
        working = true
        defer { working = false }
        do {
            try await service.select(db)
            guard try await service.rename(key, to: RedisKey(newName)) else {
                app?.report(title: String(localized: "Kľúč sa nepodarilo premenovať"),
                            message: String(localized: "Kľúč „\(newName)“ už existuje."))
                return false
            }
            await loadKeyspace()
            await loadKeys(reset: true)
            selectedID = newName
            return true
        } catch {
            app?.report(title: String(localized: "Kľúč sa nepodarilo premenovať"), error: error)
            return false
        }
    }

    func deleteSelected() async {
        guard let service, let key = selectedKey else { return }
        working = true
        defer { working = false }
        do {
            try await service.select(db)
            _ = try await service.delete([key])
            keys.removeAll { $0 == key }
            rebuildTree()
            clearSelection()
            await loadKeyspace()
        } catch {
            app?.report(title: String(localized: "Kľúč sa nepodarilo vymazať"), error: error)
        }
    }

    /// Full SCAN count for the "delete by pattern" confirmation.
    func countMatching() async -> Int? {
        guard let service else { return nil }
        working = true
        defer { working = false }
        do {
            try await service.select(db)
            return try await service.count(matching: pattern)
        } catch {
            app?.report(title: String(localized: "Kľúče sa nepodarilo spočítať"), error: error)
            return nil
        }
    }

    func deleteMatching() async {
        guard let service else { return }
        working = true
        defer { working = false }
        do {
            try await service.select(db)
            _ = try await service.delete(matching: pattern)
        } catch {
            app?.report(title: String(localized: "Kľúče sa nepodarilo vymazať"), error: error)
        }
        clearSelection()
        await loadKeyspace()
        await loadKeys(reset: true)
    }

    private func mutate(_ failure: String, _ body: (RedisBrowserService) async throws -> Void) async -> Bool {
        guard let service, let key = selectedKey else { return false }
        working = true
        defer { working = false }
        do {
            try await service.select(db)
            try await body(service)
            await loadDetail(key)
            await loadKeyspace()
            return true
        } catch {
            app?.report(title: failure, error: error)
            return false
        }
    }

    // MARK: Auto-refresh (off by default)

    private func restartAutoRefresh() {
        autoTask?.cancel()
        autoTask = nil
        guard autoRefresh else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoRefreshInterval)
                guard !Task.isCancelled, let self else { return }
                await self.loadKeyspace()
                if let key = self.selectedKey, !self.working { await self.loadDetail(key) }
            }
        }
    }

    // MARK: Helpers

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func type(of key: RedisKey) -> String? { types[key] }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

#if DEBUG
extension RedisBrowserModel {
    /// Screenshot mode: fictional keyspace instead of a connection.
    fileprivate func loadDemo() {
        guard keys.isEmpty else { return }
        keys = DemoData.redisKeys.map(RedisKey.init)
        types = Dictionary(uniqueKeysWithValues: keys.map { ($0, DemoData.redisType(of: $0.name)) })
        dbStats = [0: RedisDBStats(keys: DemoData.redis.keys, expires: 412), 1: RedisDBStats(keys: 37, expires: 0)]
        cursor = "0"
        rebuildTree()
    }
}
#endif
