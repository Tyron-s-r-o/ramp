import Darwin
import Foundation

/// Derives the real stack's `ServiceSpec`s from `ramp.json` + `Paths`. Pure: no disk, no shell.
///
/// Order: every PHP-FPM (ascending branch) → Apache (depends on all FPMs) → MySQL → Redis.
/// Stop signals: SIGTERM everywhere — httpd: immediate stop of master + children (SIGWINCH graceful-stop
/// would wait for long requests, unwanted when quitting the app); php-fpm: immediate terminate (SIGQUIT
/// graceful would also wait on requests); mysqld / redis-server: SIGTERM is their clean shutdown.
public enum ServiceSpecFactory {
    public static func specs(config: RampConfig, paths: Paths) throws -> [ServiceSpec] {
        var specs: [ServiceSpec] = []

        // PHP-FPM, one master per enabled branch (never a child of Apache).
        let fpmIDs = try GeneratorSupport.enabledPHPBranches(config).map { branch -> ServiceID in
            specs.append(try phpFPM(branch: branch, config: config, paths: paths))
            return .phpFPM(branch)
        }

        if let apacheBranch = GeneratorSupport.highestBranch(config, component: "apache") {
            try GeneratorSupport.validatePort(config.apache.port, key: "apache.port")
            let serverRoot = ConfigText.path(paths.current(component: "apache", branch: apacheBranch))
            let httpd = paths.current(component: "apache", branch: apacheBranch).appending(path: "bin/httpd")
            let base = ["-d", serverRoot, "-f", ConfigText.path(paths.apacheConf)]
            specs.append(ServiceSpec(
                id: .apache, executable: httpd, arguments: base + ["-DFOREGROUND"],
                workingDirectory: paths.root,
                ports: [config.apache.port], listenAddresses: config.apache.listenAddresses,
                readiness: .tcp(host: connectHost(config.apache.listenAddresses.first ?? "127.0.0.1"),
                                port: config.apache.port),
                readinessTimeout: .seconds(15), stopSignal: SIGTERM, stopTimeout: .seconds(10),
                reloadSignal: SIGUSR1, dependsOn: fpmIDs,
                preflight: [[httpd.path(percentEncoded: false)] + base + ["-t"]]))
        }

        let mysqlBranch = config.mysql.branch
        if config.installed["mysql"]?[mysqlBranch] != nil {
            try GeneratorSupport.validatePort(config.mysql.port, key: "mysql.port")
            let socket = paths.mysqlSocket(major: mysqlBranch)
            try GeneratorSupport.validateSocket(socket, paths: paths)
            let mysqld = paths.current(component: "mysql", branch: mysqlBranch).appending(path: "bin/mysqld")
            specs.append(ServiceSpec(
                id: .mysql(mysqlBranch), executable: mysqld,
                // --defaults-file MUST be the first argument.
                arguments: ["--defaults-file=\(ConfigText.path(paths.mysqlConf(major: mysqlBranch)))"],
                workingDirectory: paths.root,
                ports: [config.mysql.port], listenAddresses: [config.mysql.bindAddress],
                readiness: .all([.unixSocket(socket),
                                 .tcp(host: connectHost(config.mysql.bindAddress), port: config.mysql.port)]),
                readinessTimeout: .seconds(120), stopSignal: SIGTERM, stopTimeout: .seconds(60),
                requiresBootstrap: !config.mysql.initialized))
        }

        if let redisBranch = GeneratorSupport.highestBranch(config, component: "redis") {
            try GeneratorSupport.validatePort(config.redis.port, key: "redis.port")
            let redis = paths.current(component: "redis", branch: redisBranch).appending(path: "bin/redis-server")
            specs.append(ServiceSpec(
                id: .redis, executable: redis, arguments: [ConfigText.path(paths.redisConf)],
                workingDirectory: paths.redisData,
                ports: [config.redis.port], listenAddresses: [config.redis.bindAddress],
                readiness: .tcp(host: connectHost(config.redis.bindAddress), port: config.redis.port),
                readinessTimeout: .seconds(15), stopSignal: SIGTERM, stopTimeout: .seconds(30)))
        }
        return specs
    }

    /// FPM env: PHPRC / PHP_INI_SCAN_DIR, fork-safety, and the Phase 1 runtime vars — the bundled OpenSSL/curl
    /// have stage paths compiled in, so `SSL_CERT_FILE` / `OPENSSL_CONF` point into the PHP package
    /// (`<php current>/ssl/{cert.pem,openssl.cnf}`); `MAGICK_CONFIGURE_PATH` (`<php current>/etc/ImageMagick-7`)
    /// only when imagick is effective-enabled for the branch.
    static func phpFPM(branch: String, config: RampConfig, paths: Paths) throws -> ServiceSpec {
        let socket = paths.fpmSocket(branch: branch)
        try GeneratorSupport.validateSocket(socket, paths: paths)
        let current = paths.current(component: "php", branch: branch)
        let fpm = current.appending(path: "sbin/php-fpm")
        let confArgs = ["--fpm-config", ConfigText.path(paths.fpmConf(branch: branch)),
                        "-c", ConfigText.path(paths.phpIni(branch: branch))]
        func inPackage(_ rel: String) -> String { ConfigText.path(current.appending(path: rel)) }
        var env = [
            "PHPRC": ConfigText.path(paths.phpConfDir(branch: branch)),
            "PHP_INI_SCAN_DIR": ConfigText.path(paths.phpConfD(branch: branch)),
            // MAMP crash root cause: ObjC runtime aborts in forked FPM workers without this.
            "OBJC_DISABLE_INITIALIZE_FORK_SAFETY": "YES",
            "SSL_CERT_FILE": inPackage("ssl/cert.pem"),
            "OPENSSL_CONF": inPackage("ssl/openssl.cnf"),
        ]
        if try PHPConfDGenerator(config: config, paths: paths).enabledExtensions(branch: branch).contains("imagick") {
            env["MAGICK_CONFIGURE_PATH"] = inPackage("etc/ImageMagick-7")
        }
        return ServiceSpec(
            id: .phpFPM(branch), executable: fpm, arguments: ["--nodaemonize"] + confArgs, environment: env,
            workingDirectory: paths.root,
            readiness: .unixSocket(socket), readinessTimeout: .seconds(15),
            stopSignal: SIGTERM, stopTimeout: .seconds(10), reloadSignal: SIGUSR2,
            preflight: [[fpm.path(percentEncoded: false)] + confArgs + ["-t"]])
    }

    /// Elasticsearch (plan 06-01) — NOT part of `specs` (that list is the autostart set); started on demand only.
    /// `nil` when the configured branch is not installed. Runs `<es current>/bin/elasticsearch` with
    /// `ES_PATH_CONF` = RAMP's conf dir and the bundled JDK only (`JAVA_HOME`/`ES_JAVA_HOME`/`ES_JAVA_OPTS`
    /// removed, heap comes from `jvm.options.d/ramp.options`). Relative `gc.log`/`hs_err` land in the log dir.
    public static func elasticsearch(config: RampConfig, paths: Paths) throws -> ServiceSpec? {
        guard ElasticsearchConfigGenerator.isInstalled(config) else { return nil }
        let es = config.elasticsearch
        try ElasticsearchConfigGenerator.validate(es)
        let bin = paths.current(component: ElasticsearchConfigGenerator.component, branch: es.branch)
            .appending(path: "bin/elasticsearch")
        return ServiceSpec(
            id: .elasticsearch, executable: bin,
            environment: ["ES_PATH_CONF": ConfigText.path(paths.elasticsearchConfDir),
                          "ES_TMPDIR": ConfigText.path(paths.elasticsearchTmp)],
            workingDirectory: paths.elasticsearchLogs,
            ports: [es.httpPort, es.transportPort], listenAddresses: [es.bindAddress],
            readiness: .tcp(host: es.bindAddress == "::1" ? "::1" : "127.0.0.1", port: es.httpPort),
            readinessTimeout: .seconds(120), stopSignal: SIGTERM, stopTimeout: .seconds(30),
            unsetEnvironment: ["JAVA_HOME", "ES_JAVA_HOME", "ES_JAVA_OPTS"])
    }

    /// Wildcard bind addresses are probed via loopback.
    static func connectHost(_ bind: String) -> String {
        switch bind {
        case "0.0.0.0", "*", "": return "127.0.0.1"
        case "::", "[::]": return "::1"
        default: return bind
        }
    }
}
