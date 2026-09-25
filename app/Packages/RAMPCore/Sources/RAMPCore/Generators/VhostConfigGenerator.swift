import Foundation
import RAMPHostsKit

/// Renders one `conf/apache/vhosts/<domain>.conf` per enabled vhost (included by httpd.conf via
/// `IncludeOptional`). PHP goes only through mod_proxy_fcgi to the FPM socket of the vhost's branch.
///
/// The `<FilesMatch>` handler lives inside `<Directory docroot>` (not vhost-wide) so a later `Alias`
/// (phpMyAdmin) can route to a different PHP branch without section-merge ambiguity.
/// Values are re-validated here (defence in depth) even though `VhostValidator` ran before.
public struct VhostConfigGenerator: Sendable {
    public let config: RampConfig
    public let paths: Paths

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    /// Enabled vhosts only, sorted by (normalized) domain.
    public func files() throws -> [GeneratedFile] {
        let port = config.apache.port
        try GeneratorSupport.validatePort(port, key: "apache.port")
        if port == 443 { throw GeneratorError.invalidValue(key: "apache.port", value: "443 (SSL is not supported)") }

        var rendered: [(domain: String, file: GeneratedFile)] = []
        for vhost in config.vhosts where vhost.enabled {
            let domain = try Self.hostname(vhost.domain, key: "vhosts.domain")
            let file = GeneratedFile(path: path(domain: domain), contents: try render(vhost, domain: domain, port: port))
            rendered.append((domain, file))
        }
        return rendered.sorted { $0.domain < $1.domain }.map(\.file)
    }

    /// `<root>/conf/apache/vhosts/<domain>.conf` (domain must already be LDH-validated).
    public func path(domain: String) -> URL {
        paths.apacheVhostsDir.appending(path: "\(domain).conf", directoryHint: .notDirectory)
    }

    private func render(_ vhost: Vhost, domain: String, port: Int) throws -> String {
        let aliases = try Set(vhost.aliases.map { try Self.hostname($0, key: "vhosts.aliases") })
            .subtracting([domain]).sorted()
        let docroot = try Self.docroot(vhost.docroot)
        let branch = try phpBranch(vhost)

        var t = ConfigText(dialect: .apache, separator: " ", commentPrefix: "#")
        try t.block("<VirtualHost *:\(port)>", "</VirtualHost>") { v in
            try v.directive("ServerName", domain)
            if !aliases.isEmpty { try v.directive("ServerAlias", aliases.joined(separator: " ")) }
            try v.directive("DocumentRoot", docroot, quoted: true)
            try v.block("<Directory \(try v.quote(docroot))>", "</Directory>") { d in
                try d.directive("Options", "FollowSymLinks")
                try d.directive("AllowOverride", "All")
                try d.directive("Require", "all granted")
                try d.directive("CGIPassAuth", "On")
                if let branch {
                    let socket = paths.fpmSocket(branch: branch)
                    try GeneratorSupport.validateSocket(socket, paths: paths)
                    try d.block(#"<FilesMatch "\.php$">"#, "</FilesMatch>") {
                        try $0.directive("SetHandler", "proxy:unix:\(ConfigText.path(socket))|fcgi://localhost", quoted: true)
                    }
                }
            }
            try v.directive("ErrorLog", paths.log("apache-\(domain)-error.log"))
        }
        return t.rendered
    }

    /// Explicit branch must be installed + enabled; `nil` → Apache default branch (or no PHP at all).
    private func phpBranch(_ vhost: Vhost) throws -> String? {
        guard let branch = vhost.phpBranch else {
            return try ApacheConfigGenerator(config: config, paths: paths).defaultPHPBranch()
        }
        guard GeneratorSupport.enabledPHPBranches(config).contains(branch) else {
            throw GeneratorError.phpBranchNotInstalled(branch)
        }
        return branch
    }

    private static func hostname(_ value: String, key: String) throws -> String {
        do { return try Hostname.validate(value) } catch {
            throw GeneratorError.invalidValue(key: key, value: value)
        }
    }

    /// Absolute path, no control characters; trailing slashes stripped.
    private static func docroot(_ value: String) throws -> String {
        guard value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" })
        else { throw GeneratorError.invalidValue(key: "vhosts.docroot", value: value) }
        return ConfigText.path(URL(filePath: value, directoryHint: .isDirectory))
    }
}
