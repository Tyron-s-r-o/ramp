import Foundation

/// Elasticvue (Elasticsearch web GUI, MIT): the static web build (`build/elasticvue/fetch-elasticvue.sh`,
/// public path `/elasticvue/`) is aliased by `ApacheConfigGenerator` at `/elasticvue` in the localhost site only.
///
/// Renders `<elasticvue current>/api/default_clusters.json` = one predefined cluster "RAMP" pointing at the
/// configured Elasticsearch HTTP port. The web build imports it on every page load (upstream "default clusters",
/// docker build mode; RAMP patches the path to `<base>/api/`). The browser then calls Elasticsearch directly,
/// which is why `ElasticsearchConfigGenerator` enables CORS for local origins. Pure: no disk, no environment.
public struct ElasticvueConfigGenerator: Sendable {
    public static let component = "elasticvue"
    /// Name of the predefined cluster.
    public static let clusterName = "RAMP"
    /// Apache alias (localhost site).
    public static let urlPath = "/elasticvue"

    public let config: RampConfig
    public let paths: Paths

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    /// Any Elasticvue branch installed.
    public static func isInstalled(_ config: RampConfig) -> Bool {
        GeneratorSupport.highestBranch(config, component: component) != nil
    }

    /// `http://localhost[:port]/elasticvue/`.
    public static func url(apachePort: Int) -> String {
        "http://localhost\(apachePort == 80 ? "" : ":\(apachePort)")\(urlPath)/"
    }

    /// `<root>/elasticvue/<branch>/current` of the highest installed branch, or nil.
    public var packageDirectory: URL? {
        GeneratorSupport.highestBranch(config, component: Self.component)
            .map { paths.current(component: Self.component, branch: $0) }
    }

    /// Package directory to alias — only when the configured Elasticsearch branch is installed too
    /// (Elasticvue without Elasticsearch has nothing to show).
    public func site() -> URL? {
        guard ElasticsearchConfigGenerator.isInstalled(config) else { return nil }
        return packageDirectory
    }

    /// Elasticsearch HTTP endpoint as the browser reaches it (`http://127.0.0.1:<port>`, `[::1]`, `localhost`).
    public func clusterURI() throws -> String {
        let es = config.elasticsearch
        try ElasticsearchConfigGenerator.validate(es)
        let host = es.bindAddress == "::1" ? "[::1]" : es.bindAddress
        return "http://\(host):\(es.httpPort)"
    }

    /// `api/default_clusters.json` (0644), or `[]` when Elasticvue / Elasticsearch is not installed.
    public func files() throws -> [GeneratedFile] {
        guard let dir = site() else { return [] }
        // Values are validated tokens (loopback host, numeric port) — no JSON escaping needed.
        let json = #"[{"name":"\#(Self.clusterName)","uri":"\#(try clusterURI())"}]"# + "\n"
        return [GeneratedFile(path: dir.appending(path: "api/default_clusters.json", directoryHint: .notDirectory),
                              contents: json, mode: 0o644)]
    }
}
