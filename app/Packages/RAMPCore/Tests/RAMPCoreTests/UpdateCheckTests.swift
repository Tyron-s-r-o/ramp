import Foundation
import Testing
@testable import RAMPCore

/// 05-05 Task 1 edge cases (core cases live in `UpdateCheckTests` inside UpdatePolicyTests.swift, 07-01).
@Suite struct UpdateCheckEdgeTests {
    private let date = Date(timeIntervalSince1970: 0)

    private func manifest(_ components: [String: [String: String]]) -> Manifest {
        Manifest(schema: 1, generated: nil, manifestURL: URL(string: "file:///tmp/m.json")!,
                 components: components.mapValues { branches in
                     Dictionary(uniqueKeysWithValues: branches.map { b, v in (b, entry(b, v)) })
                 })
    }

    private func entry(_ b: String, _ v: String) -> ManifestEntry {
        ManifestEntry(component: "x", branch: b, version: v, url: URL(string: "https://example.test/x")!,
                      hash: .sha256("00"), size: nil, extensionDirRel: nil, extensions: [])
    }

    private func installed(_ v: String) -> InstalledPackage {
        InstalledPackage(version: v, sha256: "a", installedAt: date)
    }

    @Test func equalOrOlderManifestYieldsNothing() {
        let m = manifest(["php": ["8.3": "8.3.35", "8.2": "8.2.30"], "redis": ["8.10": "8.10.2"]])
        let result = UpdateCheck.available(manifest: m, installed: [
            "php": ["8.3": installed("8.3.35"), "8.2": installed("8.2.34")],
            "redis": ["8.10": installed("8.10.2")],
        ])
        #expect(result.isEmpty)
    }

    @Test func unknownComponentsAndNotInstalledBranchesIgnored() {
        let m = manifest(["php": ["8.3": "8.3.36", "8.4": "8.4.20"], "memcached": ["1.6": "1.6.40"]])
        let result = UpdateCheck.available(manifest: m, installed: [
            "php": ["8.3": installed("8.3.35")],
            "legacy": ["1.0": installed("1.0.0")],
        ])
        #expect(result == [PackageUpdate(component: "php", branch: "8.3", installed: "8.3.35", available: "8.3.36")])
    }

    @Test func releaseIsNewerThanInstalledReleaseCandidate() {
        let m = manifest(["php": ["8.5": "8.5.0"]])
        let result = UpdateCheck.available(manifest: m, installed: ["php": ["8.5": installed("8.5.0-rc1")]])
        #expect(result.map(\.available) == ["8.5.0"])
        let none = UpdateCheck.available(manifest: manifest(["php": ["8.5": "8.5.0-rc1"]]),
                                         installed: ["php": ["8.5": installed("8.5.0")]])
        #expect(none.isEmpty)
    }

    @Test func sortedByComponentThenBranch() {
        let m = manifest(["php": ["8.10": "8.10.1", "8.3": "8.3.36"], "apache": ["2.4": "2.4.69"]])
        let result = UpdateCheck.available(manifest: m, installed: [
            "php": ["8.10": installed("8.10.0"), "8.3": installed("8.3.35")],
            "apache": ["2.4": installed("2.4.68")],
        ])
        #expect(result.map(\.id) == ["apache/2.4", "php/8.3", "php/8.10"])
    }
}
