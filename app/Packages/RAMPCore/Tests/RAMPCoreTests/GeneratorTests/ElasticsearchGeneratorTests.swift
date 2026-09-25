import Foundation
import Testing
@testable import RAMPCore

/// Plan 06-01: `ElasticsearchConfigGenerator` — elasticsearch.yml + jvm.options.d/ramp.options.
@Suite struct ElasticsearchGeneratorTests {
    let root = GeneratorFixture.rootPath
    let logs = GeneratorFixture.logsPath

    static var esConfig: RampConfig {
        var c = GeneratorFixture.config
        c.installed["elasticsearch"] = ["9.5": GeneratorFixture.pkg("9.5.4")]
        return c
    }

    func files(_ mutate: (inout RampConfig) -> Void = { _ in }) throws -> [GeneratedFile] {
        var c = Self.esConfig
        mutate(&c)
        return try ElasticsearchConfigGenerator(config: c, paths: GeneratorFixture.paths).files()
    }

    func yml(_ mutate: (inout RampConfig) -> Void = { _ in }) throws -> String {
        try #require(try files(mutate).first { $0.path.lastPathComponent == "elasticsearch.yml" }).contents
    }

    func options(_ mutate: (inout RampConfig) -> Void = { _ in }) throws -> String {
        try #require(try files(mutate).first { $0.path.lastPathComponent == "ramp.options" }).contents
    }

    @Test func pathsAndModes() throws {
        let f = try files()
        #expect(f.map { $0.path.path(percentEncoded: false) } == [
            "\(root)/conf/elasticsearch/elasticsearch.yml",
            "\(root)/conf/elasticsearch/jvm.options.d/ramp.options",
        ])
        #expect(f.allSatisfy { $0.mode == 0o644 })
    }

    @Test func notInstalledProducesNothing() throws {
        #expect(try ElasticsearchConfigGenerator(config: GeneratorFixture.config, paths: GeneratorFixture.paths)
            .files().isEmpty)
        // Installed, but a different branch than configured.
        #expect(try files { $0.elasticsearch.branch = "8.19" }.isEmpty)
    }

    @Test func goldenYML() throws {
        #expect(try yml() == ElasticsearchGolden.yml)
    }

    @Test func goldenOptions() throws {
        #expect(try options() == ElasticsearchGolden.options)
    }

    @Test func reRenderIsByteIdentical() throws {
        #expect(try files() == files())
    }

    @Test func noClusterOrNodeName() throws {
        let text = try yml()
        #expect(!text.contains("cluster.name"))
        #expect(!text.contains("node.name"))
    }

    @Test func heapNormalizedAndEqual() throws {
        let text = try options { $0.elasticsearch.heap = "2G" }
        #expect(text.contains("\n-Xms2g\n-Xmx2g\n"))
        #expect(try options { $0.elasticsearch.heap = "512M" }.contains("\n-Xms512m\n-Xmx512m\n"))
        #expect(try options { $0.elasticsearch.heap = "256m" }.contains("-Xmx256m\n"))
        #expect(try options { $0.elasticsearch.heap = "31g" }.contains("-Xmx31g\n"))
    }

    @Test(arguments: ["100m", "64g", "1gb", "", "0g", "01g", "32g", "255m", "1g\n-Xmx8g", "99999999999999999999g"])
    func invalidHeapRejected(_ heap: String) {
        #expect(throws: GeneratorError.invalidValue(key: "elasticsearch.heap", value: heap)) {
            try files { $0.elasticsearch.heap = heap }
        }
    }

    @Test func bindAddress() throws {
        #expect(try yml { $0.elasticsearch.bindAddress = "localhost" }.contains("\nnetwork.host: localhost\n"))
        #expect(try yml { $0.elasticsearch.bindAddress = "::1" }.contains("\nnetwork.host: \"::1\"\n"))
        for bad in ["0.0.0.0", "192.168.1.10", "::", "", "127.0.0.1\nx: y"] {
            #expect(throws: GeneratorError.invalidValue(key: "elasticsearch.bindAddress", value: bad)) {
                try files { $0.elasticsearch.bindAddress = bad }
            }
        }
    }

    @Test func ports() throws {
        let text = try yml { $0.elasticsearch.httpPort = 9201; $0.elasticsearch.transportPort = 9301 }
        #expect(text.contains("\nhttp.port: 9201\ntransport.port: 9301\n"))
        #expect(throws: GeneratorError.invalidValue(key: "elasticsearch.httpPort", value: "0")) {
            try files { $0.elasticsearch.httpPort = 0 }
        }
        #expect(throws: GeneratorError.invalidValue(key: "elasticsearch.transportPort", value: "70000")) {
            try files { $0.elasticsearch.transportPort = 70000 }
        }
        #expect(throws: GeneratorError.invalidValue(key: "elasticsearch.transportPort", value: "9200")) {
            try files { $0.elasticsearch.transportPort = 9200 }
        }
    }

    @Test func yamlQuotingEscapesAndRejectsNewlines() throws {
        let odd = Paths(root: URL(filePath: "/tmp/a \"b\" \\c", directoryHint: .isDirectory),
                        logs: URL(filePath: "/tmp/logs", directoryHint: .isDirectory))
        let text = try #require(try ElasticsearchConfigGenerator(config: Self.esConfig, paths: odd).files().first).contents
        #expect(text.contains(#"path.data: "/tmp/a \"b\" \\c/elasticsearch-data/9.5""#))

        let bad = Paths(root: URL(filePath: "/tmp/a\nb", directoryHint: .isDirectory),
                        logs: URL(filePath: "/tmp/logs", directoryHint: .isDirectory))
        #expect(throws: GeneratorError.self) {
            try ElasticsearchConfigGenerator(config: Self.esConfig, paths: bad).files()
        }
    }

    @Test func corsOnlyForLocalOrigins() throws {
        let text = try yml()
        #expect(text.contains("\nhttp.cors.enabled: true\n"))
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("http.cors.allow-origin: ") })
        // YAML "\\." → regex "\." ; ES strips the surrounding slashes and full-matches the Origin header.
        var raw = String(line.dropFirst("http.cors.allow-origin: ".count))
        raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\\", with: "\\")
        #expect(raw.hasPrefix("/") && raw.hasSuffix("/"))
        let regex = try Regex(String(raw.dropFirst().dropLast()))
        for ok in ["http://localhost", "http://localhost:18091", "http://127.0.0.1:8080", "https://localhost", "http://[::1]:80"] {
            #expect(ok.wholeMatch(of: regex) != nil, "\(ok)")
        }
        for bad in ["http://localhost.evil.com", "http://evil.com", "http://127.0.0.1.nip.io", "http://p83.t.local",
                    "null", "http://localhost:80/x", "http://127x0x0x1"] {
            #expect(bad.wholeMatch(of: regex) == nil, "\(bad)")
        }
        #expect(text.contains("\nhttp.cors.allow-headers: \"X-Requested-With,Content-Type,Content-Length,Authorization\"\n"))
        // Security stays off, loopback bind unchanged.
        #expect(text.contains("\nxpack.security.enabled: false\n"))
        #expect(text.contains("\nnetwork.host: 127.0.0.1\n"))
    }

    @Test func rendererAppendsESLastAndManagesOptionsDir() throws {
        let base = try ConfigRenderer.renderAll(config: GeneratorFixture.config, paths: GeneratorFixture.paths)
        let withES = try ConfigRenderer.renderAll(config: Self.esConfig, paths: GeneratorFixture.paths)
        #expect(Array(withES.prefix(base.count)) == base)
        #expect(withES.suffix(2).map(\.path.lastPathComponent) == ["elasticsearch.yml", "ramp.options"])

        let jvmDir = GeneratorFixture.paths.elasticsearchJvmOptionsDir
        #expect(!ConfigRenderer.managedDirectories(config: GeneratorFixture.config, paths: GeneratorFixture.paths)
            .contains { $0.dir == jvmDir })
        #expect(ConfigRenderer.managedDirectories(config: Self.esConfig, paths: GeneratorFixture.paths)
            .contains { $0.dir == jvmDir && $0.ext == "options" })
    }
}

/// Golden snapshot — update intentionally when the generator output changes on purpose.
enum ElasticsearchGolden {
    static let yml = #"""
# Generated by RAMP — do not edit
# Elasticsearch 9.5 — managed by RAMP (ES_PATH_CONF). Local single node, security off, loopback only.

discovery.type: single-node
network.host: 127.0.0.1
http.port: 9200
transport.port: 9300
path.data: "/Users/t/Library/Application Support/RAMP/elasticsearch-data/9.5"
path.logs: "/Users/t/Library/Logs/RAMP/elasticsearch"
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
ingest.geoip.downloader.enabled: false
cluster.routing.allocation.disk.threshold_enabled: false
cluster.deprecation_indexing.enabled: false
# Elasticvue (http://localhost/elasticvue/) calls this node from the browser → CORS for local origins only.
http.cors.enabled: true
http.cors.allow-origin: "/^https?://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?$/"
http.cors.allow-headers: "X-Requested-With,Content-Type,Content-Length,Authorization"

"""#

    static let options = #"""
# Generated by RAMP — do not edit
# Fixed heap (Xms = Xmx). Without it Elasticsearch sizes the heap to ~50 % of RAM.
-Xms1g
-Xmx1g

"""#
}
