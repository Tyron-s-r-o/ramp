import Foundation
import Testing
@testable import RAMPCore

@Suite struct DatabaseInfoParsingTests {
    @Test func parsesBatchAndSkipsSystemSchemas() {
        let out = """
        information_schema\t0\t79
        mysql\t2637824\t38
        performance_schema\t0\t111
        shop_eshop\t1048576000\t212
        sys\t16384\t101
        tyrestock\t52428800\t64

        """
        let dbs = DatabaseInfoService.parseMySQLBatch(out)
        #expect(dbs == [DatabaseSize(name: "shop_eshop", bytes: 1_048_576_000, tables: 212),
                        DatabaseSize(name: "tyrestock", bytes: 52_428_800, tables: 64)])
        #expect(DatabaseInfoService.parseMySQLBatch(out, includeSystem: true).count == 6)
    }

    @Test func escapedAndRawTabsInNames() {
        let out = "we\\tird\\\\db\t100\t2\nraw\ttab\t200\t3\n"
        let dbs = DatabaseInfoService.parseMySQLBatch(out)
        #expect(dbs.map(\.name) == ["we\tird\\db", "raw\ttab"])
        #expect(dbs.map(\.bytes) == [100, 200])
        #expect(dbs.map(\.tables) == [2, 3])
    }

    @Test func emptyAndGarbageOutput() {
        #expect(DatabaseInfoService.parseMySQLBatch("").isEmpty)
        #expect(DatabaseInfoService.parseMySQLBatch("\n\n").isEmpty)
        #expect(DatabaseInfoService.parseMySQLBatch("ERROR 2002 (HY000): Can't connect\n").isEmpty)
        #expect(DatabaseInfoService.parseMySQLBatch("db\tx\t1\n").isEmpty)
    }

    @Test func decimalSizes() {
        #expect(DatabaseInfoService.parseMySQLBatch("db\t12345.0000\t4\n")
            == [DatabaseSize(name: "db", bytes: 12345, tables: 4)])
    }

    @Test func parsesRedisInfo() {
        let out = "# Server\r\nredis_version:8.10.2\r\nredis_mode:standalone\r\nexecutable:/Users/x/Library/Application Support/RAMP/redis/8.10/current/bin/redis-server\r\n"
            + "\r\n# Memory\r\nused_memory:1103456\r\nused_memory_human:1.05M\r\n"
            + "\r\n# Keyspace\r\ndb0:keys=12,expires=0,avg_ttl=0,subexpiry=0\r\ndb3:keys=30,expires=2,avg_ttl=100\r\n"
        let info = DatabaseInfoService.parseRedisInfo(out)
        #expect(info == RedisInfo(version: "8.10.2", usedMemoryHuman: "1.05M", keys: 42))
    }

    @Test func redisInfoEmptyKeyspace() {
        let info = DatabaseInfoService.parseRedisInfo("# Server\nredis_version:8.10.2\n# Keyspace\n")
        #expect(info.keys == 0)
        #expect(info.usedMemoryHuman == nil)
        #expect(DatabaseInfoService.parseRedisInfo("") == RedisInfo())
    }

    @Test func redisInfoValueWithTab() {
        let info = DatabaseInfoService.parseRedisInfo("used_memory_human:1.05M\t\nredis_version:8.0.0\n")
        #expect(info.usedMemoryHuman == "1.05M")
        #expect(info.version == "8.0.0")
    }
}
