import Foundation
import Testing
@testable import RAMPCore

@Suite struct PathsTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ramp-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func standardPathsHaveExpectedSuffixes() {
        let p = Paths.standard(environment: [:])
        #expect(p.root.path(percentEncoded: false).hasSuffix("Library/Application Support/RAMP/"))
        #expect(p.logs.path(percentEncoded: false).hasSuffix("Library/Logs/RAMP/"))
        #expect(p.configFile.path(percentEncoded: false).hasSuffix("RAMP/ramp.json"))
        #expect(p.package(component: "php", version: "8.3.35").path(percentEncoded: false).hasSuffix("RAMP/php/8.3.35/"))
        #expect(p.current(component: "php", branch: "8.3").path(percentEncoded: false).hasSuffix("RAMP/php/8.3/current"))
        #expect(p.apacheConf.path(percentEncoded: false).hasSuffix("RAMP/conf/apache/httpd.conf"))
        #expect(p.phpIni(branch: "8.3").path(percentEncoded: false).hasSuffix("RAMP/conf/php/8.3/php.ini"))
        #expect(p.fpmConf(branch: "8.3").path(percentEncoded: false).hasSuffix("RAMP/conf/php/8.3/php-fpm.conf"))
        #expect(p.mysqlConf(major: "9.7").path(percentEncoded: false).hasSuffix("RAMP/conf/mysql/9.7/my.cnf"))
        #expect(p.redisConf.path(percentEncoded: false).hasSuffix("RAMP/conf/redis/redis.conf"))
        #expect(p.fpmSocket(branch: "8.3").path(percentEncoded: false).hasSuffix("RAMP/run/php8.3.sock"))
        #expect(p.mysqlSocket(major: "9.7").path(percentEncoded: false).hasSuffix("RAMP/run/mysql9.7.sock"))
        #expect(p.pidFile(service: "mysql").path(percentEncoded: false).hasSuffix("RAMP/run/supervisor/mysql.pid"))
        #expect(p.mysqlData(major: "9.7").path(percentEncoded: false).hasSuffix("RAMP/mysql-data/9.7/"))
        #expect(p.redisData.path(percentEncoded: false).hasSuffix("RAMP/redis-data/"))
        #expect(p.defaultDocroot.path(percentEncoded: false).hasSuffix("RAMP/www/default/"))
        #expect(p.staging.path(percentEncoded: false).hasSuffix("RAMP/.staging/"))
        #expect(p.log("apache-error.log").path(percentEncoded: false).hasSuffix("Logs/RAMP/apache-error.log"))
    }

    @Test func environmentOverrideHonored() {
        let p = Paths.standard(environment: ["RAMP_HOME": "/tmp/ramp-x", "RAMP_LOGS": "/tmp/ramp-x-logs"])
        #expect(p.root.path(percentEncoded: false) == "/tmp/ramp-x/")
        #expect(p.logs.path(percentEncoded: false) == "/tmp/ramp-x-logs/")
        #expect(p.configFile.path(percentEncoded: false) == "/tmp/ramp-x/ramp.json")
    }

    @Test func ensureDirectoriesCreatesLayout() throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let p = Paths(root: base.appending(path: "root"), logs: base.appending(path: "logs"))
        try p.ensureDirectories()
        let fm = FileManager.default
        for url in [p.root, p.logs, p.apacheConfDir, p.apacheVhostsDir, p.redisConfDir, p.runDir,
                    p.supervisorRunDir, p.redisData, p.defaultDocroot, p.downloads, p.staging, p.tmp] {
            var isDir: ObjCBool = false
            #expect(fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue,
                    "missing \(url.path(percentEncoded: false))")
        }
        let runPerms = try fm.attributesOfItem(atPath: p.runDir.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(runPerms == 0o700)
        let tmpPerms = try fm.attributesOfItem(atPath: p.tmp.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(tmpPerms == 0o755)
        try p.ensureDirectories() // idempotent
    }

    @Test func longSocketPathThrows() {
        let p = Paths.standard(environment: [:])
        let long = URL(filePath: "/" + String(repeating: "a", count: 119))
        #expect(long.path(percentEncoded: false).utf8.count == 120)
        #expect(throws: PathsError.socketPathTooLong(long.path(percentEncoded: false))) {
            try p.validateSocketPath(long)
        }
    }

    @Test func defaultSocketsFitSunPath() throws {
        let p = Paths.standard(environment: [:])
        for url in [p.fpmSocket(branch: "8.3"), p.mysqlSocket(major: "9.7")] {
            #expect(url.path(percentEncoded: false).utf8.count < Paths.maxSocketPathBytes)
            try p.validateSocketPath(url)
        }
    }
}
