import Foundation

/// RAMP's php.ini base layer — a project decision, identical for every PHP branch.
public enum PHPIniDefaults {
    /// Constant base directives in render order.
    public static let base: [(key: String, value: String)] = [
        ("memory_limit", "1024M"),
        ("max_execution_time", "300"),
        ("max_input_time", "300"),
        ("post_max_size", "1024M"),
        ("upload_max_filesize", "1024M"),
        ("display_errors", "On"),
        ("display_startup_errors", "On"),
        ("log_errors", "On"),
        ("error_reporting", "E_ALL"),
        ("date.timezone", "Europe/Bratislava"),
    ]

    /// Base directives that point into the RAMP tree (MySQL socket of the configured branch, tmp dir).
    /// `extension_dir` is not listed: it is RAMP-managed and never overridable.
    public static func rampPaths(config: RampConfig, paths: Paths) -> [(key: String, value: String)] {
        let socket = ConfigText.path(paths.mysqlSocket(major: config.mysql.branch))
        let tmp = ConfigText.path(paths.tmp)
        return [
            ("mysqli.default_socket", socket),
            ("pdo_mysql.default_socket", socket),
            ("upload_tmp_dir", tmp),
            ("sys_temp_dir", tmp),
            ("session.save_path", tmp),
        ]
    }

    /// OPcache defaults (`conf.d/10-opcache.ini`); JIT keys only exist on PHP ≥ 8.
    static func opcache(major: Int) -> [(key: String, value: String)] {
        var d: [(key: String, value: String)] = [
            ("opcache.enable", "1"),
            ("opcache.enable_cli", "0"),
            ("opcache.memory_consumption", "256"),
            ("opcache.interned_strings_buffer", "32"),
            ("opcache.max_accelerated_files", "50000"),
            ("opcache.validate_timestamps", "1"),
            ("opcache.revalidate_freq", "0"),
        ]
        if major >= 8 {
            d.append(("opcache.jit", "disable"))
            d.append(("opcache.jit_buffer_size", "0"))
        }
        return d
    }
}
