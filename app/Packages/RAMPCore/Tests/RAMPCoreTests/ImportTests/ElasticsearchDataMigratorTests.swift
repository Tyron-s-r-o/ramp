import Darwin
import Foundation
import Testing
@testable import RAMPCore

/// Synthetic ES homes only — never `~/Lib/elasticsearch-*`.
struct FakeESProbe: ElasticsearchSourceProbing {
    var reasons: [String] = []
    func runningReasons(_ source: ElasticsearchSource) -> [String] { reasons }
}

@Suite(.serialized) struct ElasticsearchDataMigratorTests {
    /// `<dir>/home/Lib/elasticsearch-<version>` with bin/elasticsearch, lib jar, data/{_state,indices,nodes,node.lock}.
    static func makeSource(_ dir: URL, version: String = "9.5.4") throws -> URL {
        let fm = FileManager.default
        let root = dir.appending(path: "home/Lib/elasticsearch-\(version)", directoryHint: .isDirectory)
        for sub in ["bin", "lib", "data/_state", "data/indices/abc/0/index", "data/snapshot_cache"] {
            try fm.createDirectory(at: root.appending(path: sub), withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\n".utf8).write(to: root.appending(path: "bin/elasticsearch"))
        try Data().write(to: root.appending(path: "lib/elasticsearch-\(version).jar"))
        try Data("state".utf8).write(to: root.appending(path: "data/_state/manifest-1.st"))
        try Data(repeating: 7, count: 4096).write(to: root.appending(path: "data/indices/abc/0/index/_0.cfs"))
        try Data("nodes".utf8).write(to: root.appending(path: "data/nodes"))
        try Data().write(to: root.appending(path: "data/node.lock"))
        try Data("x".utf8).write(to: root.appending(path: "data/.DS_Store"))
        return root
    }

    static func snapshot(_ dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        let base = dir.path(percentEncoded: false)
        guard let walker = fm.enumerator(atPath: base) else { return out }
        while let rel = walker.nextObject() as? String {
            let attrs = try? fm.attributesOfItem(atPath: base + "/" + rel)
            out[rel] = "\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                + "|\(attrs?[.posixPermissions] ?? 0)"
        }
        return out
    }

    @Test func detectFindsESHomesWithVersion() throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let root = try Self.makeSource(env.dir)
        try FileManager.default.createDirectory(at: env.dir.appending(path: "home/Lib/elasticsearch-broken"),
                                                withIntermediateDirectories: true)
        let found = ElasticsearchDataMigrator.detect(home: env.dir.appending(path: "home"))
        #expect(found.count == 1)
        #expect(found.first?.root.standardizedFileURL == root.standardizedFileURL)
        #expect(found.first?.version == "9.5.4")
        #expect(found.first?.branch == "9.5")
    }

    @Test func precheckBlocksOnVersionRunningSourceAndRAMP() throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let old = try #require(ElasticsearchDataMigrator.source(at: try Self.makeSource(env.dir, version: "8.17.0")))
        let ok = ElasticsearchDataMigrator(paths: env.paths, probe: FakeESProbe(), rampRunning: { false })
        let p1 = ok.precheck(source: old)
        #expect(!p1.versionCompatible)
        #expect(p1.problems.contains { $0.contains("iná verzia") })

        let src = try #require(ElasticsearchDataMigrator.source(at: try Self.makeSource(env.dir)))
        let good = ok.precheck(source: src)
        #expect(good.ok)
        #expect(good.files == 3)            // node.lock + .DS_Store excluded
        #expect(good.excludedFiles == 2)
        #expect(good.bytes == 4096 + 5 + 5)

        let running = ElasticsearchDataMigrator(paths: env.paths, probe: FakeESProbe(reasons: ["pid 42"]),
                                                rampRunning: { true })
        let p2 = running.precheck(source: src)
        #expect(p2.problems.count == 2)
        #expect(p2.rampRunning)
    }

    @Test func runCopiesIntoTargetMovesOldAsideAndKeepsSource() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let root = try Self.makeSource(env.dir)
        let src = try #require(ElasticsearchDataMigrator.source(at: root))
        let before = Self.snapshot(root)
        let migrator = ElasticsearchDataMigrator(paths: env.paths, probe: FakeESProbe(), rampRunning: { false })
        let target = env.paths.elasticsearchData(branch: "9.5")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appending(path: "old-node-data"))

        let result = try await migrator.run(source: src, smoke: { ["products": 12] },
                                            now: Date(timeIntervalSince1970: 1_800_000_000))
        let fm = FileManager.default
        #expect(result.filesCopied == 3)
        #expect(result.smokeIndices == ["products": 12])
        #expect(fm.fileExists(atPath: target.appending(path: "indices/abc/0/index/_0.cfs").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: target.appending(path: "node.lock").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: target.appending(path: ".DS_Store").path(percentEncoded: false)))
        let perms = try fm.attributesOfItem(atPath: target.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(perms == 0o700)
        let aside = try #require(result.movedAside)
        #expect(aside.lastPathComponent.hasPrefix("9.5.pre-import-"))
        #expect(fm.fileExists(atPath: aside.appending(path: "old-node-data").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: ElasticsearchDataMigrator.stagingDir(env.paths).path(percentEncoded: false)))
        #expect(Self.snapshot(root) == before)   // source untouched (incl. node.lock, mtimes, perms)
    }

    @Test func refusesWhileRunningAndWritesNothing() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let src = try #require(ElasticsearchDataMigrator.source(at: try Self.makeSource(env.dir)))
        let migrator = ElasticsearchDataMigrator(paths: env.paths, probe: FakeESProbe(reasons: ["pid 42"]),
                                                 rampRunning: { false })
        await #expect(throws: ElasticsearchMigrationError.self) {
            try await migrator.run(source: src)
        }
        #expect(!FileManager.default.fileExists(atPath: ElasticsearchDataMigrator.stagingDir(env.paths).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: env.paths.elasticsearchData(branch: "9.5").path(percentEncoded: false)))
    }

    @Test func cancelKeepsStagingAndResumeSkipsCopiedFiles() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let src = try #require(ElasticsearchDataMigrator.source(at: try Self.makeSource(env.dir)))
        let migrator = ElasticsearchDataMigrator(paths: env.paths, probe: FakeESProbe(), rampRunning: { false })
        let flag = CancelFlag()
        flag.cancel()
        await #expect(throws: ElasticsearchMigrationError.cancelled) {
            try await migrator.run(source: src, cancel: flag)
        }
        // Simulate a partially copied staging dir: one file already there with same size + mtime.
        let staging = ElasticsearchDataMigrator.stagingDir(env.paths)
        let from = src.dataDir.appending(path: "nodes")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: from, to: staging.appending(path: "nodes"))
        let result = try await migrator.run(source: src)
        #expect(result.filesSkipped == 1)
        #expect(result.filesCopied == 2)
    }

    @Test func psMatchingIsComponentWise() {
        let root = URL(filePath: "/Users/x/Lib/elasticsearch-9.5.4")
        let ps = """
          101 /Users/x/Lib/elasticsearch-9.5.4/jdk.app/Contents/Home/bin/java -Des.path.home=/Users/x/Lib/elasticsearch-9.5.4 org.elasticsearch.bootstrap.Elasticsearch
          102 /Users/x/Lib/elasticsearch-9.5.40/jdk.app/Contents/Home/bin/java -Xms1g
          103 /bin/bash /Users/x/Lib/elasticsearch-9.5.4/es-autostop.sh
          104 vim notes.txt
        """
        let rows = LiveElasticsearchSourceProbe.matching(psOutput: ps, root: root)
        #expect(rows.map(\.0) == [101])
    }
}
