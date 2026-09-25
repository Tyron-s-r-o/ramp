import Foundation
import Testing
@testable import RAMPCore

enum RedisSandbox {
    static var serverBinary: URL? {
        let repo = URL(filePath: #filePath).deletingLastPathComponent() // RedisTests
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // RAMPCore
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // repo root
        let out = repo.appending(path: "build/out/redis")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: out.path(percentEncoded: false)) else { return nil }
        for v in versions.sorted().reversed() {
            let bin = out.appending(path: "\(v)/bin/redis-server")
            if FileManager.default.isExecutableFile(atPath: bin.path(percentEncoded: false)) { return bin }
        }
        return nil
    }
}

/// Runs against a throwaway `redis-server` from `build/out/redis/<ver>/bin` on port 16390
/// (no persistence). Skipped when that binary is not built. Never touches the user's 6379.
@Suite(.serialized, .enabled(if: RedisSandbox.serverBinary != nil))
struct RedisIntegrationTests {
    static let port = 16390

    private func startServer() async throws -> Process {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ramp-redis-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = RedisSandbox.serverBinary!
        p.arguments = ["--port", String(Self.port), "--bind", "127.0.0.1", "--save", "", "--appendonly", "no",
                       "--dir", dir.path(percentEncoded: false), "--databases", "16"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let probe = RedisClient(host: "127.0.0.1", port: Self.port, timeout: .seconds(1))
        for _ in 0..<50 {
            if (try? await probe.command(["PING"])) == .simple("PONG") {
                await probe.close()
                return p
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        p.terminate()
        throw RESPError.connectionFailed("sandbox redis-server did not start")
    }

    @Test func browseAllTypes() async throws {
        let server = try await startServer()
        defer {
            server.terminate()
            server.waitUntilExit()
        }
        let svc = RedisBrowserService(host: "127.0.0.1", port: Self.port)
        let c = svc.client

        // Seed (DB 3 to exercise SELECT).
        try await svc.select(3)
        try await c.call(["FLUSHDB"])
        try await c.call(["SET", "app:config", #"{"debug":true,"n":[1,2]}"#])
        try await c.call(["SET", "cache:php", #"a:1:{s:1:"k";i:5;}"#])
        try await c.call([Data("SET".utf8), Data("bin:blob".utf8), Data([0x00, 0xFF, 0x10])])
        try await c.call(["SET", "big", String(repeating: "x", count: RedisValueFormat.largeValueBytes + 10)])
        try await c.call(["HSET", "user:1", "name", "Ann", "mail", "a@x.sk"])
        try await c.call(["RPUSH", "queue:jobs"] + (0..<250).map { "job\($0)" })
        try await c.call(["SADD", "tags", "a", "b", "c"])
        try await c.call(["ZADD", "rank", "1", "one", "2.5", "two", "3", "three"])
        try await c.call(["XADD", "events", "*", "type", "login", "user", "1"])
        try await c.call(["XADD", "events", "*", "type", "logout", "user", "1"])
        for i in 0..<1200 { _ = try await c.call(["SET", "bulk:\(i)", "v"]) }
        try await c.call(["EXPIRE", "user:1", "1000"])

        // Keyspace.
        let ks = try await svc.keyspace()
        #expect(ks[3]?.keys == 1209)
        #expect(ks[3]?.expires == 1)
        #expect(await svc.databaseCount() == 16)

        // SCAN (incremental) collects every key exactly once.
        var cursor = "0"
        var all = Set<String>()
        var pages = 0
        repeat {
            let page = try await svc.scanPage(cursor: cursor, pattern: "*")
            all.formUnion(page.keys.map(\.name))
            cursor = page.cursor
            pages += 1
        } while cursor != "0"
        #expect(all.count == 1209)
        #expect(pages >= 2)
        let userPage = try await svc.scanPage(cursor: "0", pattern: "user:*")
        #expect(userPage.keys.map(\.name) == ["user:1"])
        #expect(all.contains("0x62696e3a626c6f62") == false && all.contains("bin:blob"))

        // TYPE pipeline + meta.
        let types = try await svc.types(["app:config", "user:1", "queue:jobs", "tags", "rank", "events"].map(RedisKey.init))
        #expect(types[RedisKey("rank")] == "zset")
        #expect(types[RedisKey("events")] == "stream")
        let m = try await svc.meta(RedisKey("user:1"))
        #expect(m.type == .hash && m.size == 2 && m.exists)
        #expect((m.ttlMillis ?? 0) > 900_000)
        #expect(m.memory != nil)
        let listMeta = try await svc.meta(RedisKey("queue:jobs"))
        #expect(listMeta.size == 250 && listMeta.ttlMillis == nil)
        #expect(try await svc.meta(RedisKey("missing")).exists == false)

        // Detail per type.
        let json = try await svc.string(RedisKey("app:config"))
        #expect(RedisValueFormat.kind(json.data) == .json && !json.truncated)
        #expect(RedisValueFormat.kind(try await svc.string(RedisKey("cache:php")).data) == .phpSerialized)
        #expect(try await svc.string(RedisKey("bin:blob")).data == Data([0x00, 0xFF, 0x10]))
        let big = try await svc.string(RedisKey("big"))
        #expect(big.truncated && big.data.count == RedisValueFormat.previewBytes && big.total == Int64(RedisValueFormat.largeValueBytes + 10))
        #expect(try await svc.string(RedisKey("big"), full: true).data.count == RedisValueFormat.largeValueBytes + 10)
        let h = try await svc.hash(RedisKey("user:1"))
        #expect(Set(h.pairs.map { String(decoding: $0.field, as: UTF8.self) }) == ["name", "mail"])
        let l = try await svc.list(RedisKey("queue:jobs"), start: 200)
        #expect(l.count == 50 && String(decoding: l[0], as: UTF8.self) == "job200")
        #expect(Set(try await svc.set(RedisKey("tags")).members.map { String(decoding: $0, as: UTF8.self) }) == ["a", "b", "c"])
        let z = try await svc.zset(RedisKey("rank"), start: 0)
        #expect(z.map { String(decoding: $0.member, as: UTF8.self) } == ["one", "two", "three"])
        #expect(z[1].score == "2.5")
        let s = try await svc.stream(RedisKey("events"))
        #expect(s.count == 2 && s[0].fields.first.map { String(decoding: $0.value, as: UTF8.self) } == "logout")

        // Mutations.
        try await svc.setString(RedisKey("user:tmp"), value: Data("x".utf8))
        try await svc.expire(RedisKey("user:tmp"), seconds: 500)
        try await svc.setString(RedisKey("user:tmp"), value: Data("y".utf8))
        #expect((try await svc.meta(RedisKey("user:tmp")).ttlMillis ?? 0) > 400_000) // KEEPTTL
        try await svc.persist(RedisKey("user:tmp"))
        #expect(try await svc.meta(RedisKey("user:tmp")).ttlMillis == nil)
        #expect(try await svc.rename(RedisKey("user:tmp"), to: RedisKey("user:renamed")))
        #expect(try await svc.rename(RedisKey("user:renamed"), to: RedisKey("user:1")) == false) // never overwrites
        #expect(try await svc.delete([RedisKey("user:renamed")]) == 1)
        #expect(try await svc.count(matching: "bulk:*") == 1200)
        #expect(try await svc.delete(matching: "bulk:1*") == 311) // 1, 10-19, 100-199, 1000-1199
        #expect(try await svc.count(matching: "bulk:*") == 889)

        // Error reply + DB isolation.
        #expect(try await c.command(["NOPE"]).string == nil)
        try await svc.select(0)
        #expect(try await svc.dbSize() == 0)
        await svc.close()
    }

    @Test func timeoutOnSilentServer() async throws {
        // A listening socket that never answers → the round-trip must time out, not hang.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let client = RedisClient(host: "127.0.0.1", port: port, timeout: .milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: RESPError.timeout) { try await client.command(["PING"]) }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func refusedConnectionFails() async {
        let client = RedisClient(host: "127.0.0.1", port: 1, timeout: .seconds(1))
        await #expect(throws: RESPError.self) { try await client.command(["PING"]) }
    }
}
