import Foundation

/// Renders Elasticsearch's RAMP-owned configuration (plan 06-01):
/// `conf/elasticsearch/elasticsearch.yml` and `conf/elasticsearch/jvm.options.d/ramp.options`.
///
/// Local single node, security off → loopback bind only; explicit equal `-Xms`/`-Xmx` (without it
/// ES auto-sizes the heap to ~50 % of RAM). `cluster.name` / `node.name` are deliberately not set so an
/// existing data dir (created with ES defaults) can be migrated (07-03). CORS is on for local origins only
/// (Elasticvue at http://localhost/elasticvue/). Pure: no disk, no environment.
public struct ElasticsearchConfigGenerator: Sendable {
    public static let component = "elasticsearch"
    /// Only loopback binds are allowed — there is no authentication.
    public static let allowedBindAddresses: Set<String> = ["127.0.0.1", "::1", "localhost"]
    /// 256m … 31g (above 31g the JVM loses compressed oops).
    public static let heapRangeMB = 256...(31 * 1024)

    /// ES regex (between slashes, full match against `Origin`): http(s) on localhost / 127.0.0.1 / [::1], any port.
    /// Project vhosts (`*.local`) and every remote origin are refused.
    static let corsAllowOrigin = #"/^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?$/"#
    /// Elasticvue sends JSON bodies (+ Authorization when a cluster has credentials).
    static let corsAllowHeaders = "X-Requested-With,Content-Type,Content-Length,Authorization"

    public let config: RampConfig
    public let paths: Paths

    public init(config: RampConfig, paths: Paths) {
        self.config = config
        self.paths = paths
    }

    /// `true` when the configured branch is installed.
    public static func isInstalled(_ config: RampConfig) -> Bool {
        config.installed[component]?[config.elasticsearch.branch] != nil
    }

    /// Both files, or `[]` when Elasticsearch (configured branch) is not installed.
    public func files() throws -> [GeneratedFile] {
        guard Self.isInstalled(config) else { return [] }
        return [
            GeneratedFile(path: paths.elasticsearchConf, contents: try renderYML()),
            GeneratedFile(path: paths.elasticsearchJvmOptionsDir.appending(path: "ramp.options",
                                                                           directoryHint: .notDirectory),
                          contents: try renderJvmOptions()),
        ]
    }

    // MARK: Validation (shared with ServiceSpecFactory)

    /// Validates branch, ports and bind address.
    static func validate(_ es: ElasticsearchSettings) throws {
        try GeneratorSupport.validateToken(es.branch, key: "elasticsearch.branch")
        try GeneratorSupport.validatePort(es.httpPort, key: "elasticsearch.httpPort")
        try GeneratorSupport.validatePort(es.transportPort, key: "elasticsearch.transportPort")
        guard es.httpPort != es.transportPort else {
            throw GeneratorError.invalidValue(key: "elasticsearch.transportPort", value: String(es.transportPort))
        }
        guard allowedBindAddresses.contains(es.bindAddress) else {
            throw GeneratorError.invalidValue(key: "elasticsearch.bindAddress", value: es.bindAddress)
        }
    }

    /// `^[1-9][0-9]*[mMgG]$` within `heapRangeMB`, normalized to lowercase (`"2G"` → `"2g"`).
    static func normalizedHeap(_ heap: String) throws -> String {
        let invalid = GeneratorError.invalidValue(key: "elasticsearch.heap", value: heap)
        guard let unit = heap.last.map({ Character($0.lowercased()) }), unit == "m" || unit == "g" else { throw invalid }
        let digits = heap.dropLast()
        guard let first = digits.first, first != "0",
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits) else { throw invalid }
        let (mb, overflow) = value.multipliedReportingOverflow(by: unit == "g" ? 1024 : 1)
        guard !overflow, heapRangeMB.contains(mb) else { throw invalid }
        return "\(value)\(unit)"
    }

    // MARK: Rendering

    func renderYML() throws -> String {
        let es = config.elasticsearch
        try Self.validate(es)
        var t = ConfigText(dialect: .yaml, separator: ": ", commentPrefix: "#")
        t.comment("Elasticsearch \(es.branch) — managed by RAMP (ES_PATH_CONF). "
                  + "Local single node, security off, loopback only.")
        t.blank()
        try t.directive("discovery.type", "single-node")
        // "::1" starts with an indicator character → quote it.
        try t.directive("network.host", es.bindAddress, quoted: es.bindAddress.contains(":"))
        try t.directive("http.port", String(es.httpPort))
        try t.directive("transport.port", String(es.transportPort))
        try t.directive("path.data", paths.elasticsearchData(branch: es.branch))
        try t.directive("path.logs", paths.elasticsearchLogs)
        try t.directive("xpack.security.enabled", "false")
        try t.directive("xpack.security.enrollment.enabled", "false")
        // No background downloads from a laptop.
        try t.directive("ingest.geoip.downloader.enabled", "false")
        // A nearly full laptop disk must not flip indices read-only.
        try t.directive("cluster.routing.allocation.disk.threshold_enabled", "false")
        // Deprecation warnings stay in the log file only. With indexing on, a node stopped shortly after its
        // first boot hangs ~30 s in "closing" (BulkProcessor2.awaitClose → SIGKILL by the supervisor; 06-03).
        try t.directive("cluster.deprecation_indexing.enabled", "false")
        t.comment("Elasticvue (http://localhost/elasticvue/) calls this node from the browser → CORS for local origins only.")
        try t.directive("http.cors.enabled", "true")
        try t.directive("http.cors.allow-origin", Self.corsAllowOrigin, quoted: true)
        try t.directive("http.cors.allow-headers", Self.corsAllowHeaders, quoted: true)
        return t.rendered
    }

    func renderJvmOptions() throws -> String {
        let heap = try Self.normalizedHeap(config.elasticsearch.heap)
        var t = ConfigText(dialect: .yaml, separator: "", commentPrefix: "#")
        t.comment("Fixed heap (Xms = Xmx). Without it Elasticsearch sizes the heap to ~50 % of RAM.")
        try t.line("-Xms\(heap)")
        try t.line("-Xmx\(heap)")
        return t.rendered
    }
}
