import Foundation

/// Renders `conf/php/<branch>/conf.d/*.ini` from typed per-branch settings (pure):
/// `10-opcache.ini`, `20-<ext>.ini` (apcu, imagick, memcached, redis, yaml), `30-phalcon.ini`,
/// `90-xdebug.ini` (only when `xdebug` ≠ off). Stale fragments are pruned via `managedDirectories`.
///
/// Effective extension = (explicit choice ?? catalog default) ∧ shipped by the package. An explicit `true`
/// for an extension the package lacks throws `extensionUnavailable`; a default-on one is silently absent.
public struct PHPConfDGenerator: Sendable {
    public let config: RampConfig
    public let paths: Paths

    public static let xdebugPort = 9003

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    /// Fragments sorted by file name.
    public func files(branch: String) throws -> [GeneratedFile] {
        let pkg = try GeneratorSupport.installedPHP(config, branch: branch)
        let php = PHPBranch(branch)!
        let s = settings(branch)
        var out = [GeneratedFile(path: confD(branch, "10-opcache.ini"),
                                 contents: try opcache(branch: branch, php: php, pkg: pkg, options: s.opcache))]
        for name in try enabledExtensions(branch: branch) {
            let entry = PHPExtensionCatalog.entry(name)!
            let contents: String
            switch name {
            case "apcu": contents = try apcu(branch: branch, options: s.apcu)
            case "xdebug": contents = try xdebug(branch: branch, mode: s.xdebug)
            default:
                var t = fragment("\(name) — PHP \(branch)")
                try t.directive("extension", name)
                contents = t.rendered
            }
            out.append(GeneratedFile(path: confD(branch, entry.fileName), contents: contents))
        }
        return out.sorted { $0.path.lastPathComponent < $1.path.lastPathComponent }
    }

    /// Effective-enabled catalog extensions in catalog (load) order; `xdebug` last when its mode ≠ off.
    public func enabledExtensions(branch: String) throws -> [String] {
        _ = try GeneratorSupport.installedPHP(config, branch: branch)
        let s = settings(branch)
        let available = PHPExtensionCatalog.available(branch: branch, config: config)

        for (name, on) in s.extensions.sorted(by: { $0.key < $1.key }) where on {
            if name == "xdebug" {
                throw GeneratorError.invalidValue(key: "php.branches.\(branch).extensions", value: name)
            }
            guard available.contains(name) else {
                throw GeneratorError.extensionUnavailable(branch: branch, name: name)
            }
        }
        var result: [String] = []
        for entry in PHPExtensionCatalog.entries where entry.kind == .extension {
            let want = s.extensions[entry.name] ?? entry.defaultEnabled(branch: branch)
            if want && available.contains(entry.name) { result.append(entry.name) }
        }
        if s.xdebug != .off {
            guard available.contains("xdebug") else {
                throw GeneratorError.extensionUnavailable(branch: branch, name: "xdebug")
            }
            result.append("xdebug")
        }
        return result
    }

    // MARK: Fragments

    /// `zend_extension=opcache` only for a shared build (ISS-001): PHP ≥ 8.5 always has OPcache compiled in.
    /// Unknown build type → inferred from the branch. JIT keys only on PHP ≥ 8.
    private func opcache(branch: String, php: PHPBranch, pkg: InstalledPackage, options: OPcacheOptions) throws -> String {
        let build: String
        switch pkg.opcache {
        case nil: build = php >= PHPBranch("8.5")! ? "static" : "shared"
        case "shared"?, "static"?: build = pkg.opcache!
        case let other?: throw GeneratorError.invalidValue(key: "installed.php.\(branch).opcache", value: other)
        }
        let performance = options.profile == .performance
        let jit = options.jit || performance
        var t = fragment("OPcache — PHP \(branch) (\(build) build)")
        if build == "shared" { try t.directive("zend_extension", "opcache") }
        for (key, value) in PHPIniDefaults.opcache(major: php.major) {
            let v: String
            switch key {
            case "opcache.enable": v = options.enabled ? value : "0"
            case "opcache.validate_timestamps": v = performance ? "0" : value
            case "opcache.jit": v = jit ? "tracing" : value
            case "opcache.jit_buffer_size": v = jit ? "128M" : value
            default: v = value
            }
            try t.directive(key, v)
        }
        return t.rendered
    }

    private func apcu(branch: String, options: APCuOptions) throws -> String {
        try GeneratorSupport.validateSize(options.shmSize, key: "php.branches.\(branch).apcu.shmSize")
        var t = fragment("APCu — PHP \(branch)")
        try t.directive("extension", "apcu")
        try t.directive("apc.enabled", "1")
        try t.directive("apc.shm_size", options.shmSize)
        try t.directive("apc.enable_cli", "0")
        return t.rendered
    }

    private func xdebug(branch: String, mode: XdebugMode) throws -> String {
        var t = fragment("Xdebug — PHP \(branch), mode \(mode.rawValue), trigger only (XDEBUG_TRIGGER cookie/GET/POST), IDE port \(Self.xdebugPort)")
        try t.directive("zend_extension", "xdebug")
        try t.directive("xdebug.mode", mode.rawValue)
        try t.directive("xdebug.start_with_request", "trigger")
        try t.directive("xdebug.client_host", "127.0.0.1")
        try t.directive("xdebug.client_port", String(Self.xdebugPort))
        if mode == .profile {
            try t.directive("xdebug.output_dir", paths.logs.appending(path: "xdebug", directoryHint: .isDirectory))
        }
        try t.directive("xdebug.log_level", "0")
        return t.rendered
    }

    // MARK: Helpers

    private func settings(_ branch: String) -> PHPBranchSettings {
        config.php.branches[branch] ?? PHPBranchSettings()
    }

    private func fragment(_ title: String) -> ConfigText {
        var t = ConfigText(dialect: .backslash, separator: "=", commentPrefix: ";")
        t.comment(title)
        return t
    }

    private func confD(_ branch: String, _ name: String) -> URL {
        paths.phpConfD(branch: branch).appending(path: name, directoryHint: .notDirectory)
    }
}
