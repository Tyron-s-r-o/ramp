import Darwin
import Foundation
import Testing
@testable import RAMPCore

@Suite struct ServiceSpecFactoryTests {
    let root = GeneratorFixture.rootPath

    private func specs(_ mutate: (inout RampConfig) -> Void = { _ in }) throws -> [ServiceSpec] {
        var config = GeneratorFixture.config
        mutate(&config)
        return try ServiceSpecFactory.specs(config: config, paths: GeneratorFixture.paths)
    }

    @Test func orderIsFPMThenApacheThenMySQLThenRedis() throws {
        let ids = try specs().map(\.id)
        #expect(ids == [.phpFPM("7.3"), .phpFPM("8.2"), .phpFPM("8.3"), .phpFPM("8.5"), .apache, .mysql("9.7"), .redis])
        #expect(ids.map(\.name) == ["php7.3-fpm", "php8.2-fpm", "php8.3-fpm", "php8.5-fpm", "apache", "mysql9.7", "redis"])
    }

    @Test func fpmSpecs() throws {
        let fpms = try specs().filter { if case .phpFPM = $0.id { return true } else { return false } }
        #expect(fpms.count == 4)
        for spec in fpms {
            #expect(spec.environment["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] == "YES")
            #expect(spec.resolvedEnvironment()["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] == "YES")
            #expect(spec.arguments.first == "--nodaemonize")
            #expect(spec.reloadSignal == SIGUSR2)
            #expect(spec.dependsOn.isEmpty)
        }
        let s = try #require(fpms.first { $0.id == .phpFPM("8.3") })
        #expect(s.executable.path(percentEncoded: false) == "\(root)/php/8.3/current/sbin/php-fpm")
        #expect(s.arguments == ["--nodaemonize",
                                "--fpm-config", "\(root)/conf/php/8.3/php-fpm.conf",
                                "-c", "\(root)/conf/php/8.3/php.ini"])
        #expect(s.environment["PHPRC"] == "\(root)/conf/php/8.3")
        #expect(s.environment["PHP_INI_SCAN_DIR"] == "\(root)/conf/php/8.3/conf.d")
        #expect(s.readiness == .unixSocket(GeneratorFixture.paths.fpmSocket(branch: "8.3")))
        #expect(s.preflight == [["\(root)/php/8.3/current/sbin/php-fpm",
                                 "--fpm-config", "\(root)/conf/php/8.3/php-fpm.conf",
                                 "-c", "\(root)/conf/php/8.3/php.ini", "-t"]])
    }

    /// Plan 04-02: OpenSSL env on every FPM; MAGICK_CONFIGURE_PATH only where imagick is effective-enabled.
    @Test func fpmRuntimeEnvironment() throws {
        func fpm(_ b: String, _ all: [ServiceSpec]) throws -> ServiceSpec {
            try #require(all.first { $0.id == .phpFPM(b) })
        }
        let all = try specs {
            $0.installed["php"]!["8.2"]!.extensions = ["imagick", "apcu", "phalcon"]
            $0.installed["php"]!["8.3"]!.extensions = ["imagick"]
            $0.php.branches["8.3"] = PHPBranchSettings(extensions: ["imagick": false])
        }
        for b in ["7.3", "8.2", "8.3", "8.5"] {
            let env = try fpm(b, all).environment
            #expect(env["SSL_CERT_FILE"] == "\(root)/php/\(b)/current/ssl/cert.pem")
            #expect(env["OPENSSL_CONF"] == "\(root)/php/\(b)/current/ssl/openssl.cnf")
        }
        #expect(try fpm("8.2", all).environment["MAGICK_CONFIGURE_PATH"] == "\(root)/php/8.2/current/etc/ImageMagick-7")
        #expect(try fpm("8.3", all).environment["MAGICK_CONFIGURE_PATH"] == nil)   // disabled
        #expect(try fpm("8.5", all).environment["MAGICK_CONFIGURE_PATH"] == nil)   // not shipped
        #expect(try specs().first { $0.id == .apache }?.environment["SSL_CERT_FILE"] == nil)
    }

    @Test func apacheSpec() throws {
        let all = try specs()
        let s = try #require(all.first { $0.id == .apache })
        #expect(s.executable.path(percentEncoded: false) == "\(root)/apache/2.4/current/bin/httpd")
        #expect(s.arguments == ["-d", "\(root)/apache/2.4/current", "-f", "\(root)/conf/apache/httpd.conf", "-DFOREGROUND"])
        #expect(s.dependsOn == [.phpFPM("7.3"), .phpFPM("8.2"), .phpFPM("8.3"), .phpFPM("8.5")])
        #expect(s.readiness == .tcp(host: "127.0.0.1", port: 8080))
        #expect(s.ports == [8080])
        #expect(s.listenAddresses == ["127.0.0.1", "::1"])
        #expect(s.reloadSignal == SIGUSR1)
        #expect(s.stopSignal == SIGTERM)
        #expect(s.preflight == [["\(root)/apache/2.4/current/bin/httpd", "-d", "\(root)/apache/2.4/current",
                                 "-f", "\(root)/conf/apache/httpd.conf", "-t"]])
        #expect(s.environment["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] == nil)
    }

    @Test func mysqlSpec() throws {
        let s = try #require(try specs().first { $0.id == .mysql("9.7") })
        #expect(s.executable.path(percentEncoded: false) == "\(root)/mysql/9.7/current/bin/mysqld")
        #expect(s.arguments.first == "--defaults-file=\(root)/conf/mysql/9.7/my.cnf")
        #expect(s.stopTimeout == .seconds(60))
        #expect(s.ports == [3306])
        #expect(s.requiresBootstrap)
        #expect(s.readiness == .all([.unixSocket(GeneratorFixture.paths.mysqlSocket(major: "9.7")),
                                     .tcp(host: "127.0.0.1", port: 3306)]))
        let initialized = try #require(try specs { $0.mysql.initialized = true }.first { $0.id == .mysql("9.7") })
        #expect(!initialized.requiresBootstrap)
    }

    @Test func redisSpec() throws {
        let s = try #require(try specs().first { $0.id == .redis })
        #expect(s.executable.path(percentEncoded: false) == "\(root)/redis/8.10/current/bin/redis-server")
        #expect(s.arguments == ["\(root)/conf/redis/redis.conf"])
        #expect(s.readiness == .tcp(host: "127.0.0.1", port: 6379))
        #expect(s.ports == [6379])
    }

    @Test func disabledPHPBranchHasNoSpecAndNoApacheDependency() throws {
        let all = try specs { $0.php.branches["8.2"] = PHPBranchSettings(enabled: false) }
        #expect(!all.contains { $0.id == .phpFPM("8.2") })
        #expect(all.first { $0.id == .apache }?.dependsOn.contains(.phpFPM("8.2")) == false)
    }

    @Test func missingComponentsProduceNoSpecs() throws {
        let all = try specs { $0.installed = ["php": $0.installed["php"]!] }
        #expect(all.map(\.id) == [.phpFPM("7.3"), .phpFPM("8.2"), .phpFPM("8.3"), .phpFPM("8.5")])
    }

    @Test func pathsWithSpacesAreSingleArgvElements() throws {
        #expect(root.contains(" "))
        for spec in try specs() {
            let argv = [spec.executable.path(percentEncoded: false)] + spec.arguments + spec.preflight.flatMap { $0 }
            for arg in argv where arg.contains("Application") {
                #expect(arg.contains("Application Support"), "split path in \(spec.id): \(arg)")
                #expect(!arg.hasPrefix("\"") && !arg.hasSuffix("\""), "shell quoting in \(spec.id): \(arg)")
            }
            #expect(!spec.executable.path(percentEncoded: false).hasPrefix("/bin/sh"))
        }
    }
}

/// Plan 06-01: Elasticsearch has its own spec and is never part of the autostart set.
@Suite struct ElasticsearchServiceSpecTests {
    let root = GeneratorFixture.rootPath
    let logs = GeneratorFixture.logsPath

    private func esSpec(_ mutate: (inout RampConfig) -> Void = { _ in }) throws -> ServiceSpec? {
        var config = ElasticsearchGeneratorTests.esConfig
        mutate(&config)
        return try ServiceSpecFactory.elasticsearch(config: config, paths: GeneratorFixture.paths)
    }

    @Test func serviceID() {
        #expect(ServiceID.elasticsearch.name == "elasticsearch")
        #expect(ServiceID.elasticsearch.displayName == "Elasticsearch")
    }

    @Test func notInstalledIsNil() throws {
        #expect(try ServiceSpecFactory.elasticsearch(config: GeneratorFixture.config, paths: GeneratorFixture.paths) == nil)
        #expect(try esSpec { $0.elasticsearch.branch = "8.19" } == nil)
    }

    @Test func neverInAutostartSet() throws {
        let ids = try ServiceSpecFactory.specs(config: ElasticsearchGeneratorTests.esConfig, paths: GeneratorFixture.paths)
            .map(\.id)
        #expect(!ids.contains(.elasticsearch))
        #expect(ids == [.phpFPM("7.3"), .phpFPM("8.2"), .phpFPM("8.3"), .phpFPM("8.5"), .apache, .mysql("9.7"), .redis])
    }

    @Test func spec() throws {
        let s = try #require(try esSpec())
        #expect(s.id == .elasticsearch)
        #expect(s.executable.path(percentEncoded: false) == "\(root)/elasticsearch/9.5/current/bin/elasticsearch")
        #expect(s.arguments.isEmpty)
        #expect(s.environment == ["ES_PATH_CONF": "\(root)/conf/elasticsearch",
                                  "ES_TMPDIR": "\(root)/tmp/elasticsearch"])
        #expect(Set(s.unsetEnvironment) == ["JAVA_HOME", "ES_JAVA_HOME", "ES_JAVA_OPTS"])
        #expect(s.workingDirectory?.path(percentEncoded: false) == "\(logs)/elasticsearch/")
        #expect(s.ports == [9200, 9300])
        #expect(s.listenAddresses == ["127.0.0.1"])
        #expect(s.readiness == .tcp(host: "127.0.0.1", port: 9200))
        #expect(s.readinessTimeout == .seconds(120))
        #expect(s.stopSignal == SIGTERM)
        #expect(s.stopTimeout == .seconds(30))
        #expect(s.reloadSignal == nil)
        #expect(s.dependsOn.isEmpty)
        #expect(s.preflight.isEmpty)
        #expect(s.requiresBootstrap == false)
    }

    @Test func customPortsAndIPv6() throws {
        let s = try #require(try esSpec {
            $0.elasticsearch.httpPort = 9201; $0.elasticsearch.transportPort = 9301; $0.elasticsearch.bindAddress = "::1"
        })
        #expect(s.ports == [9201, 9301])
        #expect(s.listenAddresses == ["::1"])
        #expect(s.readiness == .tcp(host: "::1", port: 9201))
    }

    @Test func invalidSettingsThrow() {
        #expect(throws: GeneratorError.self) { try esSpec { $0.elasticsearch.bindAddress = "0.0.0.0" } }
        #expect(throws: GeneratorError.self) { try esSpec { $0.elasticsearch.transportPort = 9200 } }
    }

    @Test func environmentDropsJavaOverrides() throws {
        let s = try #require(try esSpec())
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/t", "JAVA_HOME": "/opt/jdk",
                    "ES_JAVA_HOME": "/opt/jdk2", "ES_JAVA_OPTS": "-Xmx8g"]
        let env = s.resolvedEnvironment(base: base)
        #expect(env["ES_PATH_CONF"] == "\(root)/conf/elasticsearch")
        #expect(env["ES_TMPDIR"] == "\(root)/tmp/elasticsearch")
        #expect(env["JAVA_HOME"] == nil)
        #expect(env["ES_JAVA_HOME"] == nil)
        #expect(env["ES_JAVA_OPTS"] == nil)
        #expect(env["HOME"] == "/Users/t")
    }

    @Test func unsetEnvironmentDefaultsEmpty() {
        let s = ServiceSpec(id: .custom("x"), executable: URL(filePath: "/bin/true"))
        #expect(s.unsetEnvironment.isEmpty)
        #expect(s.resolvedEnvironment(base: ["JAVA_HOME": "/j"])["JAVA_HOME"] == "/j")
    }
}
