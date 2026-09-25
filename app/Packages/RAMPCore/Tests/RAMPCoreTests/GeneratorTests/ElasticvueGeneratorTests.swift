import Foundation
import Testing
@testable import RAMPCore

/// Elasticvue fixture: generator fixture + Elasticsearch 9.5 + Elasticvue 1.16.
enum ElasticvueFixture {
    static var config: RampConfig {
        var c = GeneratorFixture.config
        c.installed["elasticsearch"] = ["9.5": GeneratorFixture.pkg("9.5.4")]
        c.installed["elasticvue"] = ["1.16": GeneratorFixture.pkg("1.16.0")]
        return c
    }
}

/// Elasticvue (Elasticsearch web GUI): `<elasticvue current>/api/default_clusters.json` + the site Apache aliases.
@Suite struct ElasticvueGeneratorTests {
    let root = GeneratorFixture.rootPath
    let paths = GeneratorFixture.paths

    func generator(_ config: RampConfig = ElasticvueFixture.config) -> ElasticvueConfigGenerator {
        ElasticvueConfigGenerator(config: config, paths: paths)
    }

    @Test func defaultClustersFile() throws {
        let files = try generator().files()
        #expect(files.count == 1)
        let f = try #require(files.first)
        #expect(f.path.path(percentEncoded: false) == "\(root)/elasticvue/1.16/current/api/default_clusters.json")
        #expect(f.mode == 0o644)
        #expect(f.contents == #"[{"name":"RAMP","uri":"http://127.0.0.1:9200"}]"# + "\n")
        // Valid JSON the upstream loader accepts (array of {name, uri}).
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(f.contents.utf8)) as? [[String: String]])
        #expect(parsed == [["name": "RAMP", "uri": "http://127.0.0.1:9200"]])
    }

    @Test func clusterURIFollowsPortAndBindAddress() throws {
        var c = ElasticvueFixture.config
        c.elasticsearch.httpPort = 19202
        #expect(try generator(c).clusterURI() == "http://127.0.0.1:19202")
        c.elasticsearch.bindAddress = "::1"
        #expect(try generator(c).clusterURI() == "http://[::1]:19202")
        c.elasticsearch.bindAddress = "localhost"
        #expect(try generator(c).clusterURI() == "http://localhost:19202")
        c.elasticsearch.bindAddress = "0.0.0.0"
        #expect(throws: GeneratorError.invalidValue(key: "elasticsearch.bindAddress", value: "0.0.0.0")) {
            try generator(c).files()
        }
    }

    @Test func nothingWithoutElasticvueOrElasticsearch() throws {
        var c = ElasticvueFixture.config
        c.installed["elasticvue"] = nil
        #expect(try generator(c).files().isEmpty)
        #expect(generator(c).site() == nil)
        c = ElasticvueFixture.config
        c.installed["elasticsearch"] = nil
        #expect(try generator(c).files().isEmpty)
        #expect(generator(c).site() == nil)
        // ES installed, but another branch than configured.
        c = ElasticvueFixture.config
        c.elasticsearch.branch = "8.19"
        #expect(generator(c).site() == nil)
    }

    @Test func siteIsHighestBranchCurrent() throws {
        var c = ElasticvueFixture.config
        c.installed["elasticvue"]?["1.9"] = GeneratorFixture.pkg("1.9.2")
        let site = try #require(generator(c).site())
        #expect(ConfigText.path(site) == "\(root)/elasticvue/1.16/current")
    }

    @Test func url() {
        #expect(ElasticvueConfigGenerator.url(apachePort: 80) == "http://localhost/elasticvue/")
        #expect(ElasticvueConfigGenerator.url(apachePort: 18091) == "http://localhost:18091/elasticvue/")
    }

    @Test func rendererIncludesDefaultClustersAfterElasticsearch() throws {
        let files = try ConfigRenderer.renderAll(config: ElasticvueFixture.config, paths: paths)
        #expect(files.suffix(3).map(\.path.lastPathComponent) == ["elasticsearch.yml", "ramp.options", "default_clusters.json"])
        var noEV = ElasticvueFixture.config
        noEV.installed["elasticvue"] = nil
        #expect(!(try ConfigRenderer.renderAll(config: noEV, paths: paths)).contains { $0.path.lastPathComponent == "default_clusters.json" })
    }
}
