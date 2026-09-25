import Darwin
import Foundation

/// One terminal shim: a small bash script in `~/.ramp/bin` that `exec`s a RAMP binary with the right env.
public struct CLIShim: Sendable, Equatable {
    public var name: String
    public var contents: String

    public init(name: String, contents: String) {
        self.name = name
        self.contents = contents
    }
}

/// Renders the `~/.ramp/bin` shims from `ramp.json` (pure — no disk, no environment):
///
/// - `php<branch>` for every installed + enabled PHP branch → `<branch>/current/bin/php -c php-cli.ini`,
///   `PHP_INI_SCAN_DIR` = that branch's conf.d (extensions / Xdebug exactly as FPM; CLI OPcache off);
///   `phpize<branch>`, `php-config<branch>`; unversioned `php` / `phpize` / `php-config` → the CLI default branch.
/// - `composer` → `<root>/composer/composer.phar` run by the `php` shim (`RAMP_PHP=8.3` picks `php8.3`).
/// - `mysql`, `mysqldump`, `mysqladmin`, `mysqlcheck` → RAMP's MySQL client, `--socket=<RAMP socket>` added
///   unless the call names its own `--socket/-S/--host/-h/--protocol` (no default user is injected).
/// - `redis-cli` → RAMP's redis-cli with `-p <port>` unless `-p/-h/-s/-u` is given.
///
/// Every shim carries `managedHeader` on line 2; only such files are ever replaced or removed.
public struct CLIShimGenerator: Sendable {
    public static let managedHeader = "# Managed by RAMP — regenerated automatically"
    public static let mysqlClients = ["mysql", "mysqldump", "mysqladmin", "mysqlcheck"]

    public let config: RampConfig
    public let paths: Paths
    /// `~/.ramp/bin` (baked into the unversioned / composer shims).
    public let shimDir: URL

    public init(config: RampConfig, paths: Paths, shimDir: URL) {
        self.config = config
        self.paths = paths
        self.shimDir = shimDir
    }

    /// Installed + enabled branches with a usable install record (ascending).
    public static func phpBranches(_ config: RampConfig) -> [String] {
        GeneratorSupport.enabledPHPBranches(config).filter { b in
            guard let rel = config.installed["php"]?[b]?.extensionDirRel else { return false }
            return !rel.isEmpty && !rel.hasPrefix("/")
        }
    }

    /// Branch behind `php`: `cli.defaultPHP`, else `apache.defaultPHP`, else the highest — each only when
    /// installed + enabled. `nil` = no PHP.
    public static func defaultBranch(_ config: RampConfig) -> String? {
        let branches = phpBranches(config)
        for candidate in [config.cli.defaultPHP, config.apache.defaultPHP] {
            if let candidate, branches.contains(candidate) { return candidate }
        }
        return branches.last
    }

    /// All shims, sorted by name.
    public func shims() -> [CLIShim] {
        var out: [CLIShim] = []
        let branches = Self.phpBranches(config)
        for branch in branches {
            out.append(CLIShim(name: "php\(branch)", contents: php(branch: branch)))
            for tool in ["phpize", "php-config"] {
                out.append(CLIShim(name: "\(tool)\(branch)", contents: phpTool(tool, branch: branch)))
            }
        }
        if let d = Self.defaultBranch(config) {
            for tool in ["php", "phpize", "php-config"] {
                out.append(CLIShim(name: tool, contents: alias(tool, target: "\(tool)\(d)",
                                                               note: "\(tool) → PHP \(d) (RAMP terminal default)")))
            }
            out.append(CLIShim(name: "composer", contents: composer(defaultBranch: d)))
        }
        let mysqlBranch = config.mysql.branch
        if config.installed["mysql"]?[mysqlBranch] != nil {
            for client in Self.mysqlClients {
                out.append(CLIShim(name: client, contents: mysql(client, branch: mysqlBranch)))
            }
        }
        if let redis = GeneratorSupport.highestBranch(config, component: "redis") {
            out.append(CLIShim(name: "redis-cli", contents: redisCLI(branch: redis)))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Command names a user can type (for the Settings list / `rampctl cli status`).
    public func commandNames() -> [String] { shims().map(\.name) }

    // MARK: Scripts

    private func php(branch: String) -> String {
        let current = paths.current(component: "php", branch: branch)
        func pkg(_ rel: String) -> String { Self.sq(ConfigText.path(current.appending(path: rel))) }
        let imagick = (try? PHPConfDGenerator(config: config, paths: paths).enabledExtensions(branch: branch))?
            .contains("imagick") ?? false
        var lines = header("PHP \(branch) (RAMP) — php.ini: \(ConfigText.path(paths.phpCliIni(branch: branch)))")
        lines += [
            "export PHP_INI_SCAN_DIR=\(Self.sq(ConfigText.path(paths.phpConfD(branch: branch))))",
            // The bundled OpenSSL has build-time paths compiled in (same env as the FPM spec).
            "export OPENSSL_CONF=\(pkg("ssl/openssl.cnf"))",
            "if [ -z \"${SSL_CERT_FILE:-}\" ]; then export SSL_CERT_FILE=\(pkg("ssl/cert.pem")); fi",
        ]
        if imagick { lines.append("export MAGICK_CONFIGURE_PATH=\(pkg("etc/ImageMagick-7"))") }
        lines.append("exec \(pkg("bin/php")) -c \(Self.sq(ConfigText.path(paths.phpCliIni(branch: branch)))) \"$@\"")
        return Self.script(lines)
    }

    private func phpTool(_ tool: String, branch: String) -> String {
        let bin = paths.current(component: "php", branch: branch).appending(path: "bin/\(tool)")
        return Self.script(header("\(tool) of PHP \(branch) (RAMP)")
                           + ["exec \(Self.sq(ConfigText.path(bin))) \"$@\""])
    }

    private func alias(_ name: String, target: String, note: String) -> String {
        let url = shimDir.appending(path: target, directoryHint: .notDirectory)
        return Self.script(header(note) + ["exec \(Self.sq(ConfigText.path(url))) \"$@\""])
    }

    private func composer(defaultBranch: String) -> String {
        let dir = ConfigText.path(shimDir)
        let phar = Self.sq(ConfigText.path(paths.composerPhar))
        return Self.script(header("Composer (RAMP) on PHP \(defaultBranch); RAMP_PHP=8.3 composer … picks another installed branch") + [
            "phar=\(phar)",
            "if [ ! -f \"$phar\" ]; then",
            "  echo \"composer: $phar is missing — run: rampctl cli update-composer (or RAMP › Settings › Terminal)\" >&2",
            "  exit 127",
            "fi",
            "php=\(Self.sq(dir + "/php"))",
            "if [ -n \"${RAMP_PHP:-}\" ]; then",
            "  case \"$RAMP_PHP\" in",
            "    *[!0-9.]*) echo \"composer: invalid RAMP_PHP=$RAMP_PHP (expected e.g. 8.3)\" >&2; exit 2 ;;",
            "  esac",
            "  php=\(Self.sq(dir + "/php"))\"$RAMP_PHP\"",
            "  if [ ! -x \"$php\" ]; then",
            "    echo \"composer: PHP $RAMP_PHP is not installed or enabled in RAMP\" >&2",
            "    exit 2",
            "  fi",
            "fi",
            "exec \"$php\" \"$phar\" \"$@\"",
        ])
    }

    private func mysql(_ client: String, branch: String) -> String {
        let bin = paths.current(component: "mysql", branch: branch).appending(path: "bin/\(client)")
        let socket = ConfigText.path(paths.mysqlSocket(major: branch))
        return Self.script(header("\(client) (RAMP MySQL \(branch)) — adds --socket unless --socket/-S/--host/-h/--protocol is given") + [
            "bin=\(Self.sq(ConfigText.path(bin)))",
            "for a in \"$@\"; do",
            "  case \"$a\" in",
            "    --) break ;;",
            "    \(MySQLShimArgs.bashPattern)) exec \"$bin\" \"$@\" ;;",
            "  esac",
            "done",
            "# --defaults-file and friends must stay first",
            "pre=()",
            "while [ $# -gt 0 ]; do",
            "  case \"$1\" in",
            "    \(MySQLShimArgs.leadingBashPattern)) pre+=(\"$1\"); shift ;;",
            "    *) break ;;",
            "  esac",
            "done",
            "exec \"$bin\" \"${pre[@]}\" --socket=\(Self.sq(socket)) \"$@\"",
        ])
    }

    private func redisCLI(branch: String) -> String {
        let bin = paths.current(component: "redis", branch: branch).appending(path: "bin/redis-cli")
        return Self.script(header("redis-cli (RAMP Redis \(branch)) — adds -p \(config.redis.port) unless -p/-h/-s/-u is given") + [
            "bin=\(Self.sq(ConfigText.path(bin)))",
            "for a in \"$@\"; do",
            "  case \"$a\" in",
            "    -p|-h|-s|-u) exec \"$bin\" \"$@\" ;;",
            "  esac",
            "done",
            "exec \"$bin\" -p \(config.redis.port) \"$@\"",
        ])
    }

    // MARK: Helpers

    private func header(_ note: String) -> [String] {
        ["#!/bin/bash", Self.managedHeader, "# \(note.replacingOccurrences(of: "\n", with: " "))"]
    }

    private static func script(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    /// POSIX single-quoted word (`'` → `'\''`).
    static func sq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// When the MySQL shims add `--socket` (mirrors the bash `case` in the generated script; unit-tested both ways).
public enum MySQLShimArgs {
    /// Options that pick the server themselves → the shim adds nothing.
    static let bashPattern = "--socket|--socket=*|-S|-S*|--host|--host=*|-h|-h*|--protocol|--protocol=*"
    /// Options mysql requires as the very first arguments; the injected `--socket` goes after them.
    static let leadingBashPattern = "--defaults-file=*|--defaults-extra-file=*|--defaults-group-suffix=*"
        + "|--login-path=*|--no-defaults|--print-defaults|--no-login-paths"

    /// `true` when the shim injects `--socket=<RAMP socket>` for these arguments.
    public static func injectsSocket(_ args: [String]) -> Bool {
        for a in args {
            if a == "--" { break }
            if a == "--socket" || a.hasPrefix("--socket=") || a.hasPrefix("-S")
                || a == "--host" || a.hasPrefix("--host=") || (a.hasPrefix("-h") && !a.hasPrefix("--"))
                || a == "--protocol" || a.hasPrefix("--protocol=") {
                return false
            }
        }
        return true
    }
}

/// Writes the shims into `~/.ramp/bin` (0755): only files carrying `CLIShimGenerator.managedHeader` are
/// replaced or removed — anything else (user scripts, symlinks) is left alone and reported.
public struct CLIShimWriter: Sendable {
    public struct Report: Sendable, Equatable {
        public var written: [String] = []
        public var removed: [String] = []
        /// Names that exist but are not RAMP-managed (not overwritten).
        public var skipped: [String] = []
        public var changed: Bool { !written.isEmpty || !removed.isEmpty }
    }

    public let shimDir: URL

    public init(shimDir: URL) { self.shimDir = shimDir }

    @discardableResult
    public func sync(_ shims: [CLIShim]) throws -> Report {
        let fm = FileManager.default
        let dir = ConfigText.path(shimDir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        var report = Report()
        let wanted = Set(shims.map(\.name))
        for shim in shims {
            let path = dir + "/" + shim.name
            let data = Data(shim.contents.utf8)
            var st = stat()
            if lstat(path, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFREG, Self.isManaged(path: path) else {
                    report.skipped.append(shim.name)
                    continue
                }
                if fm.contents(atPath: path) == data {
                    if (st.st_mode & 0o777) != 0o755 { chmod(path, 0o755) }
                    continue
                }
            }
            let temp = dir + "/.\(shim.name).tmp-\(UUID().uuidString)"
            guard fm.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o755]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp])
            }
            chmod(temp, 0o755)
            if rename(temp, path) != 0 {
                let err = errno
                unlink(temp)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            report.written.append(shim.name)
        }
        for name in managedNames() where !wanted.contains(name) {
            if unlink(dir + "/" + name) == 0 { report.removed.append(name) }
        }
        return report
    }

    /// Removes every managed shim (uninstall / `rampctl cli uninstall`); returns the removed names.
    @discardableResult
    public func removeAll() -> [String] {
        let dir = ConfigText.path(shimDir)
        return managedNames().filter { unlink(dir + "/" + $0) == 0 }
    }

    /// Managed shim names currently in the directory (sorted).
    public func managedNames() -> [String] {
        let dir = ConfigText.path(shimDir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var st = stat()
            return lstat(dir + "/" + name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
                && Self.isManaged(path: dir + "/" + name)
        }.sorted()
    }

    /// Regular file whose first 3 lines contain the managed header.
    public static func isManaged(path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 512) else { return false }
        let head = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).prefix(3)
        return head.contains { $0 == CLIShimGenerator.managedHeader }
    }
}
