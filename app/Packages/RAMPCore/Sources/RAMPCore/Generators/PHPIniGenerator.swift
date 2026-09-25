import Foundation

/// Renders `conf/php/<branch>/php.ini` (RAMP defaults → global → per-branch overrides, see `PHPIniLayers`)
/// plus the `conf/php/<branch>/conf.d/*.ini` fragments (FPM runs with `PHP_INI_SCAN_DIR` = that conf.d).
/// conf.d fragments come from `PHPConfDGenerator` (OPcache, optional extensions, Xdebug only when enabled).
public struct PHPIniGenerator: Sendable {
    public let config: RampConfig
    public let paths: Paths

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    /// php.ini followed by the conf.d fragments (sorted by name).
    public func files(branch: String) throws -> [GeneratedFile] {
        [GeneratedFile(path: paths.phpIni(branch: branch), contents: try render(branch: branch, cli: false))]
            + (try PHPConfDGenerator(config: config, paths: paths).files(branch: branch))
    }

    /// `conf/php/<branch>/php-cli.ini` for the terminal shims (`php<branch> -c …`, `PHP_INI_SCAN_DIR` = the
    /// same conf.d, so extensions / Xdebug match FPM; OPcache is off in CLI via `opcache.enable_cli=0`).
    /// Same layers as php.ini, except `memory_limit = -1` while it still comes from RAMP's base layer.
    public func cliIni(branch: String) throws -> GeneratedFile {
        GeneratedFile(path: paths.phpCliIni(branch: branch), contents: try render(branch: branch, cli: true))
    }

    private func render(branch: String, cli: Bool) throws -> String {
        let pkg = try GeneratorSupport.installedPHP(config, branch: branch)
        guard let rel = pkg.extensionDirRel, !rel.isEmpty, !rel.hasPrefix("/") else {
            throw GeneratorError.missingExtensionDir(branch: branch)
        }
        let extensionDir = paths.current(component: "php", branch: branch)
            .appending(path: rel, directoryHint: .isDirectory)

        var ini = ConfigText(dialect: .backslash, separator: "=", commentPrefix: ";")
        if cli {
            ini.comment("PHP \(branch) CLI (terminal shims in ~/.ramp/bin) — like php.ini, memory_limit -1 unless overridden. conf.d/*.ini is loaded after this file.")
        } else {
            ini.comment("PHP \(branch) — RAMP defaults, then global and per-branch overrides. conf.d/*.ini is loaded after this file.")
        }
        ini.blank()
        try ini.line("[PHP]")
        try ini.directive("extension_dir", extensionDir)
        let layers = try PHPIniLayers.effective(config: config, branch: branch, paths: paths)
        // CA bundle shipped in the package (ISS-003): curl / openssl verify HTTPS in CLI and FPM alike, without
        // relying on SSL_CERT_FILE in the environment. A user override of either key wins (then not written here).
        let caBundle = paths.current(component: "php", branch: branch).appending(path: "ssl/cert.pem")
        for key in ["curl.cainfo", "openssl.cafile"] where !layers.contains(where: { $0.key == key }) {
            try ini.directive(key, caBundle)
        }
        for d in layers {
            let value = cli && d.key == "memory_limit" && d.source == .base ? "-1" : d.value
            try ini.directive(d.key, try PHPIniLayers.encode(value))
        }
        return ini.rendered
    }
}
