import Foundation

/// Renders `conf/redis/redis.conf` — supervised in the foreground, localhost only, RDB snapshots.
public struct RedisConfigGenerator: Sendable {
    public let config: RampConfig
    public let paths: Paths

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    public func render() throws -> String {
        let r = config.redis
        try GeneratorSupport.validatePort(r.port, key: "redis.port")
        try GeneratorSupport.validateToken(r.bindAddress, key: "redis.bindAddress")
        if let maxmemory = r.maxmemory { try GeneratorSupport.validateSize(maxmemory, key: "redis.maxmemory") }

        var t = ConfigText(dialect: .backslash, separator: " ", commentPrefix: "#")
        t.blank()
        // `-::1` = bind IPv6 loopback if available, don't fail otherwise.
        try t.directive("bind", r.bindAddress == "127.0.0.1" ? "127.0.0.1 -::1" : r.bindAddress)
        try t.directive("port", String(r.port))
        try t.directive("protected-mode", "yes")
        try t.directive("daemonize", "no")
        try t.directive("supervised", "no")
        try t.directive("pidfile", paths.runDir.appending(path: "redis.pid", directoryHint: .notDirectory))
        try t.directive("logfile", paths.log("redis.log"))
        try t.directive("loglevel", "notice")
        try t.directive("dir", paths.redisData)
        try t.directive("dbfilename", "dump.rdb")
        try t.directive("save", "3600 1 300 100")
        try t.directive("appendonly", "no")
        if let maxmemory = r.maxmemory {
            try t.directive("maxmemory", maxmemory)
        }
        return t.rendered
    }
}
