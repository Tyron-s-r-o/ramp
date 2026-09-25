import Foundation
import Testing
@testable import RAMPCore

/// Plan 07-01: pure update planning (manifest vs `config.installed` + settings → `UpdatePlan`).
@Suite struct UpdatePolicyTests {
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func manifest(_ entries: [String: [String: String]]) -> Manifest {
        var components: [String: [String: ManifestEntry]] = [:]
        for (component, branches) in entries {
            for (branch, version) in branches {
                components[component, default: [:]][branch] = ManifestEntry(
                    component: component, branch: branch, version: version,
                    url: URL(string: "https://example.test/\(component)-\(version).tar.xz")!,
                    hash: .sha256("00"), size: 1, extensionDirRel: nil, extensions: [])
            }
        }
        return Manifest(schema: 1, generated: nil, manifestURL: URL(string: "file:///tmp/manifest.json")!,
                        components: components)
    }

    private func installed(_ entries: [String: [String: String]]) -> [String: [String: InstalledPackage]] {
        entries.mapValues { $0.mapValues { InstalledPackage(version: $0, sha256: "sha-\($0)", installedAt: Self.date) } }
    }

    private func plan(_ m: [String: [String: String]], _ i: [String: [String: String]],
                      settings: UpdateSettings = UpdateSettings(),
                      php: [String: PHPBranchSettings] = [:]) -> [UpdateItem] {
        UpdatePolicy.plan(manifest: manifest(m), installed: installed(i), settings: settings, phpBranches: php).items
    }

    // MARK: Same-branch patches

    @Test func phpPatchIsAutomaticByDefault() {
        let items = plan(["php": ["8.3": "8.3.36"]], ["php": ["8.3": "8.3.35"]])
        #expect(items == [UpdateItem(component: "php", branch: "8.3", from: "8.3.35", to: "8.3.36",
                                     kind: .automatic, requiresDumpFirst: false)])
    }

    @Test func phpPatchOfferedWhenAutoApplyOff() {
        let items = plan(["php": ["8.3": "8.3.36"]], ["php": ["8.3": "8.3.35"]],
                         settings: UpdateSettings(autoApplyPHPPatches: false))
        #expect(items.map(\.kind) == [.offered])
    }

    @Test func apachePatchIsOffered() {
        let items = plan(["apache": ["2.4": "2.4.69"]], ["apache": ["2.4": "2.4.68"]])
        #expect(items == [UpdateItem(component: "apache", branch: "2.4", from: "2.4.68", to: "2.4.69",
                                     kind: .offered, requiresDumpFirst: false)])
    }

    @Test func mysqlPatchOfferedWithDumpPerSetting() {
        let on = plan(["mysql": ["9.7": "9.7.3"]], ["mysql": ["9.7": "9.7.2"]])
        #expect(on == [UpdateItem(component: "mysql", branch: "9.7", from: "9.7.2", to: "9.7.3",
                                  kind: .offered, requiresDumpFirst: true)])
        let off = plan(["mysql": ["9.7": "9.7.3"]], ["mysql": ["9.7": "9.7.2"]],
                       settings: UpdateSettings(dumpBeforeMySQLPatch: false))
        #expect(off.first?.kind == .offered)
        #expect(off.first?.requiresDumpFirst == false)
    }

    @Test func disabledPHPBranchIsOnlyOffered() {
        let items = plan(["php": ["8.3": "8.3.36"]], ["php": ["8.3": "8.3.35"]],
                         php: ["8.3": PHPBranchSettings(enabled: false)])
        #expect(items.map(\.kind) == [.offered])
    }

    @Test func equalOrLowerManifestVersionYieldsNothing() {
        #expect(plan(["php": ["8.3": "8.3.35"]], ["php": ["8.3": "8.3.35"]]).isEmpty)
        #expect(plan(["php": ["8.3": "8.3.34"]], ["php": ["8.3": "8.3.35"]]).isEmpty)
        #expect(plan(["php": ["8.3": "8.3.35-rc1"]], ["php": ["8.3": "8.3.35"]]).isEmpty)
    }

    @Test func unknownComponentIgnored() {
        let items = plan(["nginx": ["1.29": "1.29.1"]], ["nginx": ["1.29": "1.29.0"]])
        #expect(items.isEmpty)
    }

    // MARK: New branches / migrations

    @Test func newPHPBranchOffered() {
        let items = plan(["php": ["8.3": "8.3.35", "8.6": "8.6.0"]], ["php": ["8.3": "8.3.35"]])
        #expect(items == [UpdateItem(component: "php", branch: "8.6", from: nil, to: "8.6.0",
                                     kind: .newBranch, requiresDumpFirst: false)])
    }

    @Test func olderUninstalledBranchIsNotANewBranch() {
        // 7.3 exists in the manifest but is older than every installed branch → install UI, not an update.
        #expect(plan(["php": ["7.3": "7.3.33", "8.3": "8.3.35"]], ["php": ["8.3": "8.3.35"]]).isEmpty)
    }

    @Test func mysqlMajorIsMigrationNeverNewBranchOrAutomatic() {
        let items = plan(["mysql": ["9.7": "9.7.2", "10.0": "10.0.1"]], ["mysql": ["9.7": "9.7.2"]])
        #expect(items == [UpdateItem(component: "mysql", branch: "10.0", from: "9.7.2", to: "10.0.1",
                                     kind: .migration, requiresDumpFirst: true)])
        let noDump = plan(["mysql": ["10.0": "10.0.1"]], ["mysql": ["9.7": "9.7.2"]],
                          settings: UpdateSettings(dumpBeforeMySQLPatch: false))
        #expect(noDump.map(\.kind) == [.migration])
        #expect(noDump.first?.requiresDumpFirst == true)
    }

    @Test func mysqlHelperBranchNeverProposed() {
        #expect(plan(["mysql": ["8.4": "8.4.12", "9.7": "9.7.2"]], ["mysql": ["9.7": "9.7.2"]]).isEmpty)
        #expect(UpdatePolicy.migrationOnlyBranches["mysql"] == ["8.4"])
    }

    @Test func elasticsearchPatchOffered() {
        let items = plan(["elasticsearch": ["9.5": "9.5.5"]], ["elasticsearch": ["9.5": "9.5.4"]])
        #expect(items.map(\.kind) == [.offered])
    }

    @Test func elasticsearchNewMajorOnlyWhenInstalled() {
        let with = plan(["elasticsearch": ["9.5": "9.5.4", "10.0": "10.0.0"]], ["elasticsearch": ["9.5": "9.5.4"]])
        #expect(with.map(\.kind) == [.newBranch])
        #expect(with.first?.branch == "10.0")
        #expect(plan(["elasticsearch": ["10.0": "10.0.0"]], ["php": ["8.3": "8.3.35"]]).isEmpty)
    }

    @Test func ordering() {
        let items = plan(
            ["php": ["8.3": "8.3.36", "8.4": "8.4.20", "8.10": "8.10.0"],
             "apache": ["2.4": "2.4.69"], "redis": ["8.6": "8.6.2"],
             "mysql": ["9.7": "9.7.3", "10.0": "10.0.0"]],
            ["php": ["8.3": "8.3.35", "8.4": "8.4.19"], "apache": ["2.4": "2.4.68"],
             "redis": ["8.6": "8.6.1"], "mysql": ["9.7": "9.7.2"]])
        #expect(items.map { "\($0.kind) \($0.component) \($0.branch)" } == [
            "automatic php 8.3", "automatic php 8.4",
            "offered apache 2.4", "offered mysql 9.7", "offered redis 8.6",
            "newBranch php 8.10",
            "migration mysql 10.0",
        ])
    }

    // MARK: Retention

    @Test func retentionKeepsCurrentAndPrevious() {
        let prunable = RetentionPolicy.prunable(
            component: "php", branch: "8.3",
            versionsOnDisk: ["8.3.33", "8.3.34", "8.3.35", "8.3.36", "8.3.36", "current", ".staging", "8.3", "8.4.4"],
            current: "8.3.36", previous: "8.3.35")
        #expect(prunable == ["8.3.33", "8.3.34"])
    }

    @Test func retentionWithoutPreviousAndDuplicates() {
        let prunable = RetentionPolicy.prunable(
            component: "mysql", branch: "9.7", versionsOnDisk: ["9.7.2", "9.7.1", "9.7.1", "9.7.2"],
            current: "9.7.2", previous: nil)
        #expect(prunable == ["9.7.1"])
        #expect(RetentionPolicy.prunable(component: "mysql", branch: "9.7", versionsOnDisk: ["9.7.2"],
                                         current: "9.7.2", previous: "9.7.2").isEmpty)
    }

    // MARK: Installed record

    @Test func recordingUpdateKeepsPrevious() {
        let old = InstalledPackage(version: "8.3.35", sha256: "aaa", installedAt: Self.date,
                                   extensionDirRel: "lib/x", opcache: "shared", extensions: ["intl"])
        let later = Self.date.addingTimeInterval(3600)
        let new = old.recordingUpdate(to: "8.3.36", sha256: "bbb", at: later)
        #expect(new.version == "8.3.36")
        #expect(new.sha256 == "bbb")
        #expect(new.installedAt == later)
        #expect(new.previousVersion == "8.3.35")
        #expect(new.previousSHA256 == "aaa")
        #expect(new.extensionDirRel == "lib/x")
    }
}

/// Plan 07-01: `RampConfig.updates` + `InstalledPackage.previous*` — tolerant decode, schema stays 1.
@Suite struct UpdateSettingsTests {
    @Test func defaultsWhenMissing() throws {
        let config = try RampConfig.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(config.updates == UpdateSettings())
        #expect(config.updates.checkIntervalHours == 24)
        #expect(config.updates.autoApplyPHPPatches == true)
        #expect(config.updates.dumpBeforeMySQLPatch == true)
    }

    @Test func partialDecodeAndClamp() throws {
        let json = #"{"schemaVersion":1,"updates":{"checkIntervalHours":1000,"autoApplyPHPPatches":false}}"#
        let u = try RampConfig.decode(from: Data(json.utf8)).updates
        #expect(u.checkIntervalHours == 168)
        #expect(u.autoApplyPHPPatches == false)
        #expect(u.dumpBeforeMySQLPatch == true)
        let low = try RampConfig.decode(from: Data(#"{"schemaVersion":1,"updates":{"checkIntervalHours":0}}"#.utf8))
        #expect(low.updates.checkIntervalHours == 1)
        #expect(UpdateSettings(checkIntervalHours: -5).checkIntervalHours == 1)
    }

    @Test func roundTrip() throws {
        var config = RampConfig()
        config.updates = UpdateSettings(checkIntervalHours: 12, autoApplyPHPPatches: false, dumpBeforeMySQLPatch: false)
        config.installed["php"] = ["8.3": InstalledPackage(version: "8.3.36", sha256: "b",
                                                           installedAt: Date(timeIntervalSince1970: 1_790_000_000))
            .recordingUpdate(to: "8.3.37", sha256: "c", at: Date(timeIntervalSince1970: 1_790_003_600))]
        #expect(try RampConfig.decode(from: config.encoded()) == config)
    }

    @Test func oldConfigRoundTripsWithoutNewKeys() throws {
        let json = #"""
        {"schemaVersion":1,"installed":{"php":{"8.3":{"version":"8.3.35","sha256":"abc",
         "installedAt":"2026-09-24T12:00:00Z","extensionDirRel":"lib/x"}}},"mysql":{"port":3307}}
        """#
        let config = try RampConfig.decode(from: Data(json.utf8))
        let pkg = try #require(config.installed["php"]?["8.3"])
        #expect(pkg.previousVersion == nil)
        #expect(pkg.previousSHA256 == nil)
        #expect(config.mysql.port == 3307)
        // Re-encode: the package record gains no keys, decoding again is lossless.
        let data = try config.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let installed = try #require(object["installed"] as? [String: [String: [String: Any]]])
        #expect(Set(installed["php"]?["8.3"]?.keys.map { $0 } ?? []) == ["version", "sha256", "installedAt", "extensionDirRel"])
        #expect(try RampConfig.decode(from: data) == config)
    }
}

/// 05-05 Task 1 (created here because 05-05 is not executed yet): `PackageVersion` + `UpdateCheck`.
@Suite struct UpdateCheckTests {
    @Test func versionParsingAndOrdering() throws {
        let v = { (s: String) throws -> PackageVersion in try #require(PackageVersion(s)) }
        #expect(try v("8.3.35") < v("8.3.36"))
        #expect(try v("2.4.68") < v("2.4.69"))
        #expect(try v("9.7.2") < v("10.0.0"))
        #expect(try v("8.10.0") > v("8.9.9"))
        #expect(try v("9.5") == v("9.5.0"))
        #expect(try v("8.3.35-rc1") < v("8.3.35"))
        #expect(try v("8.3.35-rc1") < v("8.3.35-rc2"))
        #expect(try v("8.3.35-rc2") > v("8.3.34"))
        #expect(PackageVersion("current") == nil)
        #expect(PackageVersion(".staging") == nil)
        #expect(PackageVersion("") == nil)
        #expect(PackageVersion("8..3") == nil)
    }

    @Test func availableOnlyForInstalledBranches() {
        let m = Manifest(schema: 1, generated: nil, manifestURL: URL(string: "file:///tmp/m.json")!, components: [
            "php": ["8.3": entry("php", "8.3", "8.3.36"), "8.6": entry("php", "8.6", "8.6.0")],
            "mysql": ["9.7": entry("mysql", "9.7", "9.7.2"), "10.0": entry("mysql", "10.0", "10.0.0")],
            "apache": ["2.4": entry("apache", "2.4", "2.4.69")],
        ])
        let date = Date(timeIntervalSince1970: 0)
        let installed: [String: [String: InstalledPackage]] = [
            "php": ["8.3": InstalledPackage(version: "8.3.35", sha256: "a", installedAt: date)],
            "mysql": ["9.7": InstalledPackage(version: "9.7.2", sha256: "b", installedAt: date)],
            "apache": ["2.4": InstalledPackage(version: "2.4.68", sha256: "c", installedAt: date)],
        ]
        #expect(UpdateCheck.available(manifest: m, installed: installed) == [
            PackageUpdate(component: "apache", branch: "2.4", installed: "2.4.68", available: "2.4.69"),
            PackageUpdate(component: "php", branch: "8.3", installed: "8.3.35", available: "8.3.36"),
        ])
    }

    private func entry(_ c: String, _ b: String, _ v: String) -> ManifestEntry {
        ManifestEntry(component: c, branch: b, version: v, url: URL(string: "https://example.test/x")!,
                      hash: .sha256("00"), size: nil, extensionDirRel: nil, extensions: [])
    }
}
