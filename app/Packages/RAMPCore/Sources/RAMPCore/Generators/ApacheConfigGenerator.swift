import Foundation

/// Renders `conf/apache/httpd.conf`: event MPM, PHP only via mod_proxy_fcgi to per-branch FPM unix sockets.
///
/// Never emits mod_php / mod_fastcgi / mod_fcgid / SSL / `Listen 443` (MAMP fork-crash root cause),
/// nor `User`/`Group` (httpd runs as the logged-in user; those are honored only as root).
public struct ApacheConfigGenerator: Sendable {
    public let config: RampConfig
    public let paths: Paths

    /// Exactly these modules are loaded (relative to ServerRoot).
    public static let modules = [
        "mpm_event", "authz_core", "authz_host", "unixd", "dir", "mime", "log_config", "alias",
        "rewrite", "headers", "setenvif", "env", "expires", "deflate", "filter", "proxy", "proxy_fcgi",
    ]

    /// Minimal MIME map used when the package has no `conf/mime.types`.
    static let fallbackTypes: [(String, String)] = [
        ("text/html", ".html .htm"), ("text/css", ".css"), ("text/javascript", ".js .mjs"),
        ("application/json", ".json .map"), ("application/xml", ".xml"), ("text/plain", ".txt"),
        ("image/png", ".png"), ("image/jpeg", ".jpg .jpeg"), ("image/gif", ".gif"), ("image/webp", ".webp"),
        ("image/avif", ".avif"), ("image/svg+xml", ".svg"), ("image/x-icon", ".ico"),
        ("font/woff", ".woff"), ("font/woff2", ".woff2"), ("font/ttf", ".ttf"), ("font/otf", ".otf"),
        ("application/pdf", ".pdf"), ("application/zip", ".zip"), ("video/mp4", ".mp4"),
        ("application/wasm", ".wasm"),
    ]

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    /// PHP branch for the default site: `apache.defaultPHP` or the highest installed+enabled branch.
    /// `nil` when no PHP is installed (site served without a PHP handler).
    public func defaultPHPBranch() throws -> String? {
        if let explicit = config.apache.defaultPHP {
            _ = try GeneratorSupport.installedPHP(config, branch: explicit)
            return explicit
        }
        return GeneratorSupport.enabledPHPBranches(config).last
    }

    public func render() throws -> String {
        let port = config.apache.port
        try GeneratorSupport.validatePort(port, key: "apache.port")
        if port == 443 { throw GeneratorError.invalidValue(key: "apache.port", value: "443 (SSL is not supported)") }
        guard !config.apache.listenAddresses.isEmpty else {
            throw GeneratorError.invalidValue(key: "apache.listenAddresses", value: "[]")
        }

        let apacheBranch = GeneratorSupport.highestBranch(config, component: "apache") ?? "2.4"
        let serverRoot = paths.current(component: "apache", branch: apacheBranch)
        let serverRootPath = ConfigText.path(serverRoot)
        let wwwDir = ConfigText.path(paths.root.appending(path: "www", directoryHint: .isDirectory))
        let docroot: String
        if let custom = config.apache.documentRoot {
            guard custom.hasPrefix("/") else {
                throw GeneratorError.invalidValue(key: "apache.documentRoot", value: custom)
            }
            try ConfigText.validate(custom, key: "apache.documentRoot")
            docroot = ConfigText.path(URL(filePath: custom, directoryHint: .isDirectory))
        } else {
            docroot = ConfigText.path(paths.defaultDocroot)
        }
        let phpBranch = try defaultPHPBranch()

        var t = ConfigText(dialect: .apache, separator: " ", commentPrefix: "#")
        t.comment("Source of truth: ramp.json — regenerated on every change.")
        t.blank()
        try t.directive("ServerRoot", serverRoot)
        try t.directive("PidFile", paths.httpdPidFile)
        try t.directive("ServerName", "localhost")
        for address in config.apache.listenAddresses {
            try GeneratorSupport.validateToken(address, key: "apache.listenAddresses")
        }
        // macOS lets unprivileged processes bind ports < 1024 only on the wildcard address, never on
        // 127.0.0.1 / ::1 (EACCES). Loopback-only config on a privileged port therefore listens on all
        // interfaces and is restricted to local clients by the `Require local` <Location> below.
        let wildcardLoopback = Self.needsWildcardListen(port: port, addresses: config.apache.listenAddresses)
        if wildcardLoopback {
            try t.directive("Listen", "\(port)")
        } else {
            for address in config.apache.listenAddresses {
                let host = address.contains(":") ? "[\(address)]" : address
                try t.directive("Listen", "\(host):\(port)")
            }
        }
        t.blank()
        for module in Self.modules {
            try t.directive("LoadModule", "\(module)_module modules/mod_\(module).so")
        }
        t.blank()
        t.comment("Event MPM — modest development sizing.")
        try t.directive("StartServers", "2")
        try t.directive("MinSpareThreads", "25")
        try t.directive("MaxSpareThreads", "75")
        try t.directive("ThreadsPerChild", "25")
        try t.directive("MaxRequestWorkers", "150")
        try t.directive("MaxConnectionsPerChild", "0")
        t.blank()
        try t.directive("Timeout", "300")
        try t.directive("KeepAlive", "On")
        try t.directive("ServerTokens", "Prod")
        try t.directive("ServerSignature", "Off")
        try t.directive("ErrorLog", paths.log("apache-error.log"))
        try t.directive("LogLevel", "warn")
        try t.line(#"LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined"#)
        try t.line("CustomLog \(try t.quote(ConfigText.path(paths.log("apache-access.log")))) combined")
        t.blank()
        let mimeTypes = serverRootPath + "/conf/mime.types"
        try t.block("<IfFile \(try t.quote(mimeTypes))>", "</IfFile>") {
            try $0.directive("TypesConfig", mimeTypes, quoted: true)
        }
        try t.block("<IfFile \(try t.quote("!" + mimeTypes))>", "</IfFile>") {
            try $0.directive("TypesConfig", "/dev/null", quoted: true)
            for (type, exts) in Self.fallbackTypes {
                try $0.directive("AddType", "\(type) \(exts)")
            }
        }
        try t.directive("AddDefaultCharset", "UTF-8")
        t.blank()
        try t.block("<Directory />", "</Directory>") {
            try $0.directive("AllowOverride", "None")
            try $0.directive("Require", "all denied")
        }
        try Self.grantedDirectory(&t, wwwDir)
        if docroot != wwwDir { try Self.grantedDirectory(&t, docroot) }
        try t.block(#"<Files ".ht*">"#, "</Files>") {
            try $0.directive("Require", "all denied")
        }
        try t.directive("DirectoryIndex", "index.php index.html")
        if wildcardLoopback {
            // Wildcard listen (see above) — still only reachable from this Mac.
            try t.block(#"<Location "/">"#, "</Location>") { try $0.directive("Require", "local") }
        }
        t.blank()
        t.comment("PHP reaches Apache only through mod_proxy_fcgi + per-branch FPM unix sockets.")
        try t.block(#"<Proxy "fcgi://localhost" enablereuse=off>"#, "</Proxy>") { _ in }
        try t.directive("ProxyTimeout", "300")
        t.blank()
        let pma = try PhpMyAdminConfigGenerator(config: config, paths: paths).site()
        let elasticvue = ElasticvueConfigGenerator(config: config, paths: paths).site()
        try t.block("<VirtualHost *:\(port)>", "</VirtualHost>") { v in
            try v.directive("ServerName", "localhost")
            try v.directive("DocumentRoot", docroot, quoted: true)
            // Handler scoped to the docroot (not vhost-wide) so the /phpmyadmin alias can use another branch.
            if let phpBranch {
                try v.block("<Directory \(try v.quote(docroot))>", "</Directory>") {
                    try phpHandler(&$0, branch: phpBranch)
                }
            }
            if let pma {
                try phpMyAdminAlias(&v, pma)
            }
            if let elasticvue {
                try elasticvueAlias(&v, elasticvue)
            }
        }
        t.blank()
        t.comment("Per-site virtual hosts (Phase 3).")
        try t.directive("IncludeOptional", ConfigText.path(paths.apacheVhostsDir) + "/*.conf", quoted: true)
        return t.rendered
    }

    private func phpHandler(_ t: inout ConfigText, branch: String) throws {
        let socket = paths.fpmSocket(branch: branch)
        try GeneratorSupport.validateSocket(socket, paths: paths)
        try t.block(#"<FilesMatch "\.php$">"#, "</FilesMatch>") {
            try $0.directive("SetHandler", "proxy:unix:\(ConfigText.path(socket))|fcgi://localhost", quoted: true)
        }
    }

    /// True when every configured address is loopback and the port is privileged (< 1024).
    static func needsWildcardListen(port: Int, addresses: [String]) -> Bool {
        port < 1024 && !addresses.isEmpty && addresses.allSatisfy { $0 == "127.0.0.1" || $0 == "::1" || $0 == "localhost" }
    }

    /// `/phpmyadmin` → package dir (localhost site only, `Require local`), internals denied (04-04).
    private func phpMyAdminAlias(_ v: inout ConfigText, _ site: PhpMyAdminConfigGenerator.Site) throws {
        let dir = ConfigText.path(site.directory)
        v.comment("phpMyAdmin — localhost only, never on project vhosts.")
        try v.directive("Alias", "/phpmyadmin \(try v.quote(dir))")
        try v.block("<Directory \(try v.quote(dir))>", "</Directory>") { d in
            try d.directive("Options", "FollowSymLinks")
            try d.directive("AllowOverride", "None")
            try d.directive("Require", "local")
            try d.directive("DirectoryIndex", "index.php")
            try phpHandler(&d, branch: site.phpBranch)
            try d.block(#"<Files ".user.ini">"#, "</Files>") { try $0.directive("Require", "all denied") }
        }
        let denied = PhpMyAdminConfigGenerator.deniedDirectories.joined(separator: "|")
        try v.block("<DirectoryMatch \(try v.quote("^\(Self.regexEscaped(dir))/(\(denied))/"))>", "</DirectoryMatch>") {
            try $0.directive("Require", "all denied")
        }
    }

    /// `/elasticvue` → static web build (localhost site only, `Require local`, no PHP). History-mode routes fall
    /// back to index.html; index.html + default_clusters.json are revalidated (hashed assets change on update).
    private func elasticvueAlias(_ v: inout ConfigText, _ directory: URL) throws {
        let dir = ConfigText.path(directory)
        let base = ElasticvueConfigGenerator.urlPath
        v.comment("Elasticvue (Elasticsearch GUI) — localhost only, static files, no PHP.")
        try v.directive("Alias", "\(base) \(try v.quote(dir))")
        try v.block("<Directory \(try v.quote(dir))>", "</Directory>") { d in
            try d.directive("Options", "FollowSymLinks")
            try d.directive("AllowOverride", "None")
            try d.directive("Require", "local")
            try d.directive("DirectoryIndex", "index.html")
            try d.directive("FallbackResource", "\(base)/index.html")
            try d.block(#"<FilesMatch "^(index\.html|default_clusters\.json)$">"#, "</FilesMatch>") {
                try $0.directive("Header", #"set Cache-Control "no-cache""#)
            }
        }
    }

    /// PCRE-escapes a literal path (spaces are literal; `.` etc. are not).
    static func regexEscaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if #"\^$.|?*+()[]{}"#.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func grantedDirectory(_ t: inout ConfigText, _ dir: String) throws {
        try t.block("<Directory \(try t.quote(dir))>", "</Directory>") {
            try $0.directive("Options", "FollowSymLinks")
            try $0.directive("AllowOverride", "All")
            try $0.directive("Require", "all granted")
        }
    }
}
