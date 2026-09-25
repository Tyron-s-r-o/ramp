import Foundation

/// Renders `conf/mysql/<branch>/my.cnf` (used via `--defaults-file`). No binlog, no X Protocol,
/// localhost only. `[client]`/`[mysqladmin]` share socket + port so bundled clients work.
public struct MySQLConfigGenerator: Sendable {
    public let config: RampConfig
    public let paths: Paths

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    public func render() throws -> String {
        let m = config.mysql
        guard PHPBranch(m.branch) != nil, config.installed["mysql"]?[m.branch] != nil else {
            throw GeneratorError.componentNotInstalled("mysql \(m.branch)")
        }
        try GeneratorSupport.validatePort(m.port, key: "mysql.port")
        try GeneratorSupport.validateToken(m.bindAddress, key: "mysql.bindAddress")
        try GeneratorSupport.validateSize(m.maxAllowedPacket, key: "mysql.maxAllowedPacket")
        try GeneratorSupport.validateSize(m.innodbBufferPoolSize, key: "mysql.innodbBufferPoolSize")
        let socket = paths.mysqlSocket(major: m.branch)
        try GeneratorSupport.validateSocket(socket, paths: paths)

        var t = ConfigText(dialect: .backslash, separator: "=", commentPrefix: "#")
        t.comment("MySQL \(m.branch) — started with --defaults-file.")
        t.blank()
        try t.line("[mysqld]")
        try t.directive("basedir", paths.current(component: "mysql", branch: m.branch))
        try t.directive("datadir", paths.mysqlData(major: m.branch))
        try t.directive("socket", socket)
        try t.directive("pid-file", paths.runDir.appending(path: "mysql\(m.branch).pid", directoryHint: .notDirectory))
        try t.directive("port", String(m.port))
        try t.directive("bind-address", m.bindAddress)
        try t.directive("mysqlx", "OFF")
        try t.line("skip-log-bin")
        // 8.4 is only used as the ISS-004 fallback / MAMP migration target: accounts migrated with
        // mysql_native_password (PHP 7.3) must be able to log in. The option does not exist in 9.x.
        if m.branch == "8.4" { try t.directive("mysql-native-password", "ON") }
        try t.directive("log-error", paths.log("mysql\(m.branch).err"))
        try t.directive("sql_mode", m.sqlMode, quoted: true)
        try t.directive("max_allowed_packet", m.maxAllowedPacket)
        try t.directive("innodb_buffer_pool_size", m.innodbBufferPoolSize)
        try t.directive("character-set-server", "utf8mb4")
        try t.directive("collation-server", "utf8mb4_0900_ai_ci")
        try t.directive("tmpdir", paths.tmp)
        for section in ["client", "mysqladmin"] {
            t.blank()
            try t.line("[\(section)]")
            try t.directive("socket", socket)
            try t.directive("port", String(m.port))
        }
        return t.rendered
    }
}
