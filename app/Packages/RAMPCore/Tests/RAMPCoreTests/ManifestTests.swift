import Foundation
import Testing
@testable import RAMPCore

@Suite struct ManifestTests {
    private let manifestURL = URL(string: "file:///Users/dev/RAMP/build/dist/manifest.json")!

    private func decode(_ json: String) throws -> Manifest {
        try Manifest.decode(from: Data(json.utf8), manifestURL: manifestURL)
    }

    private static let phase1 = #"""
    {
      "schema": 1,
      "generated": "2026-09-24T10:00:00Z",
      "components": {
        "php": {
          "8.3": {"version": "8.3.35", "url": "${RAMP_DIST_BASE}/php-8.3.35.tar.xz",
                  "sha256": "AB12", "size": 1234,
                  "extension_dir_rel": "lib/php/extensions/no-debug-non-zts-20230831",
                  "extensions": ["opcache", "intl", "redis"]},
          "7.3": {"version": "7.3.33", "url": "php-7.3.33.tar.xz", "sha256": "cd34", "size": 99},
          "7.4": {"version": "7.4.33", "url": "${RAMP_DIST_BASE}/php-7.4.33-darwin-arm64.tar.xz", "sha256": "bc", "size": 7,
                  "extension_dir_rel": "lib/php/extensions/no-debug-non-zts-20190902", "api": 20190902,
                  "opcache": "shared", "extensions": ["apcu", "imagick", "memcached", "redis", "xdebug", "yaml"]}
        },
        "apache": {"2.4": {"version": "2.4.68", "url": "https://github.com/x/releases/download/v1/apache-2.4.68.tar.xz",
                           "sha256": "ee", "size": 10}},
        "mysql": {"9.7": {"version": "9.7.3", "url": "${RAMP_DIST_BASE}/mysql-9.7.3.tar.xz", "sha256": "01", "size": 1},
                  "8.4": {"version": "8.4.12", "url": "${RAMP_DIST_BASE}/mysql-8.4.12.tar.xz", "sha256": "02", "size": 1}},
        "redis": {"8.6": {"version": "8.6.1", "url": "${RAMP_DIST_BASE}/redis-8.6.1.tar.xz", "sha256": "03", "size": 1}},
        "phpmyadmin": {"5.2": {"version": "5.2.3", "url": "${RAMP_DIST_BASE}/phpmyadmin-5.2.3.tar.xz", "sha256": "04", "size": 1}},
        "elasticsearch": {"9.5": {"version": "9.5.4",
                                  "url": "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-9.5.4-darwin-aarch64.tar.gz",
                                  "sha512": "ff00"}},
        "valkey": {"9.0": {"version": "9.0.0", "url": "whatever", "sha256": "05"}}
      }
    }
    """#

    @Test func decodesPhase1Manifest() throws {
        let m = try decode(Self.phase1)
        #expect(m.schema == 1)
        #expect(m.generated == "2026-09-24T10:00:00Z")
        let php = try #require(m.entry(component: "php", branch: "8.3"))
        #expect(php.component == "php")
        #expect(php.branch == "8.3")
        #expect(php.version == "8.3.35")
        #expect(php.hash == .sha256("ab12"))  // normalized to lowercase
        #expect(php.size == 1234)
        #expect(php.extensionDirRel == "lib/php/extensions/no-debug-non-zts-20230831")
        #expect(php.extensions == ["opcache", "intl", "redis"])
        #expect(m.branches(of: "php") == ["7.3", "7.4", "8.3"])
        #expect(m.entry(component: "php", branch: "7.4")?.version == "7.4.33")
        #expect(m.entry(component: "php", branch: "7.4")?.extensionDirRel == "lib/php/extensions/no-debug-non-zts-20190902")
        #expect(m.branches(of: "mysql") == ["8.4", "9.7"])
        #expect(m.entry(component: "redis", branch: "8.6")?.version == "8.6.1")
        #expect(m.entry(component: "phpmyadmin", branch: "5.2")?.extensionDirRel == nil)
    }

    @Test func unsupportedSchemaRejected() {
        let error = #expect(throws: ManifestError.self) {
            try decode(#"{"schema": 2, "components": {}}"#)
        }
        guard case .unsupportedSchema(let found, let supported)? = error else {
            Issue.record("wrong error \(String(describing: error))"); return
        }
        #expect(found == 2)
        #expect(supported == 1)
    }

    @Test func unknownComponentsIgnored() throws {
        let m = try decode(Self.phase1)
        #expect(m.entry(component: "valkey", branch: "9.0") == nil)
        #expect(!m.components.keys.contains("valkey"))
    }

    @Test func elasticsearchSha512Decodes() throws {
        let m = try decode(Self.phase1)
        let es = try #require(m.entry(component: "elasticsearch", branch: "9.5"))
        #expect(es.hash == .sha512("ff00"))
        #expect(es.size == nil)
        #expect(Manifest.installableComponents.contains("elasticsearch"))   // on demand since 06-03
        #expect(Manifest.installableComponents.contains("elasticvue"))      // installed with Elasticsearch
    }

    @Test func urlResolution() throws {
        let m = try decode(Self.phase1)
        #expect(m.entry(component: "php", branch: "8.3")?.url.absoluteString
            == "file:///Users/dev/RAMP/build/dist/php-8.3.35.tar.xz")
        #expect(m.entry(component: "php", branch: "7.3")?.url.absoluteString
            == "file:///Users/dev/RAMP/build/dist/php-7.3.33.tar.xz")
        #expect(m.entry(component: "apache", branch: "2.4")?.url.absoluteString
            == "https://github.com/x/releases/download/v1/apache-2.4.68.tar.xz")
    }

    @Test func httpsManifestResolvesRelativeAgainstItsDirectory() throws {
        let json = #"{"schema":1,"components":{"redis":{"8.6":{"version":"8.6.1","url":"${RAMP_DIST_BASE}/r.tar.xz","sha256":"aa"}}}}"#
        let m = try Manifest.decode(from: Data(json.utf8),
                                    manifestURL: URL(string: "https://example.com/rel/v1/manifest.json")!)
        #expect(m.entry(component: "redis", branch: "8.6")?.url.absoluteString == "https://example.com/rel/v1/r.tar.xz")
    }

    @Test(arguments: ["http://example.com/x.tar.xz", "ftp://example.com/x.tar.xz", "data:,abc"])
    func insecureSchemesRejected(url: String) {
        let json = #"{"schema":1,"components":{"redis":{"8.6":{"version":"8.6.1","url":"\#(url)","sha256":"aa"}}}}"#
        let error = #expect(throws: ManifestError.self) { try decode(json) }
        guard case .insecureURL? = error else {
            Issue.record("wrong error \(String(describing: error))"); return
        }
    }

    @Test func missingFieldIsInvalidEntry() {
        let json = #"{"schema":1,"components":{"redis":{"8.6":{"version":"8.6.1","sha256":"aa"}}}}"#
        let error = #expect(throws: ManifestError.self) { try decode(json) }
        guard case .invalidEntry(let c, let b, _)? = error else {
            Issue.record("wrong error \(String(describing: error))"); return
        }
        #expect(c == "redis")
        #expect(b == "8.6")
    }

    @Test func malformedJSON() {
        #expect(throws: ManifestError.self) { try decode("not json") }
    }

    @Test func loaderReadsFileURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ramp-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "manifest.json")
        try Data(Self.phase1.utf8).write(to: url)
        let m = try await ManifestLoader.load(url)
        #expect(m.entry(component: "php", branch: "8.3")?.url
            == dir.appending(path: "php-8.3.35.tar.xz").standardizedFileURL)
    }

    @Test func loaderRejectsHTTP() async {
        await #expect(throws: ManifestError.self) {
            try await ManifestLoader.load(URL(string: "http://example.com/manifest.json")!)
        }
    }
}
