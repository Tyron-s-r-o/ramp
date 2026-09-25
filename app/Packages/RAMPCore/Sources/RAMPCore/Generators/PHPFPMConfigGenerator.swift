import Foundation

/// Renders `conf/php/<branch>/php-fpm.conf` — one supervised (non-daemonized) master per PHP branch,
/// one `ondemand` pool listening on `run/php<branch>.sock`. Valid for PHP 7.3 … 8.x (no 8.x-only keys).
public struct PHPFPMConfigGenerator: Sendable {
    public let config: RampConfig
    public let paths: Paths

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    /// FPM master pid file, e.g. `<root>/run/php8.3-fpm.pid`.
    public func pidFile(branch: String) -> URL {
        paths.runDir.appending(path: "php\(branch)-fpm.pid", directoryHint: .notDirectory)
    }

    public func render(branch: String) throws -> String {
        _ = try GeneratorSupport.installedPHP(config, branch: branch)
        let socket = paths.fpmSocket(branch: branch)
        try GeneratorSupport.validateSocket(socket, paths: paths)

        var t = ConfigText(dialect: .backslash, separator: " = ", commentPrefix: ";")
        t.comment("PHP \(branch) FPM — supervised by RAMP (daemonize = no), runs as the logged-in user.")
        t.blank()
        try t.line("[global]")
        try t.directive("pid", pidFile(branch: branch))
        try t.directive("error_log", paths.log("php\(branch)-fpm.log"))
        try t.directive("log_level", "notice")
        try t.directive("daemonize", "no")
        t.blank()
        try t.line("[www]")
        try t.directive("listen", socket)
        try t.directive("listen.mode", "0660")
        try t.directive("pm", "ondemand")
        try t.directive("pm.max_children", "20")
        try t.directive("pm.process_idle_timeout", "60s")
        try t.directive("pm.max_requests", "500")
        try t.directive("request_terminate_timeout", "300")
        try t.directive("catch_workers_output", "yes")
        try t.directive("decorate_workers_output", "no")
        t.comment("Keep the environment so OBJC_DISABLE_INITIALIZE_FORK_SAFETY reaches the workers.")
        try t.directive("clear_env", "no")
        try t.directive("php_admin_value[error_log]", paths.log("php\(branch)-error.log"))
        try t.directive("php_admin_flag[log_errors]", "on")
        return t.rendered
    }
}
