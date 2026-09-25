import Foundation
import Testing
@testable import RAMPCore

@Suite struct PhpMyAdminSetupTests {
    /// Renders only the phpMyAdmin files: throws if the secret was not persisted before rendering.
    let pmaRenderer: StackController.Renderer = { try PhpMyAdminConfigGenerator(config: $0, paths: $1).files() }

    func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
    }

    @Test func secretGeneratedOnceTmpDirPrivateConfigPrivate() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        try await store.update {
            $0.installed["phpmyadmin"] = ["5.2": InstalledPackage(version: "5.2.3", sha256: "x", installedAt: .now)]
            $0.installed["php"] = ["8.5": InstalledPackage(version: "8.5.11", sha256: "x", installedAt: .now)]
        }
        let controller = StackController(paths: env.paths, configStore: store,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in [] }, renderer: pmaRenderer)
        let changed = try await controller.prepare()
        let secret = try #require(try await store.load().phpmyadmin.blowfishSecret)
        #expect(PhpMyAdminConfigGenerator.isValidSecret(secret))

        let pma = env.paths.current(component: "phpmyadmin", branch: "5.2")
        let configFile = pma.appending(path: "config.inc.php")
        #expect(changed.contains(configFile))
        #expect(try mode(configFile) == 0o600)
        #expect(try String(contentsOf: configFile, encoding: .utf8).contains("'\(secret)'"))
        #expect(try mode(PhpMyAdminConfigGenerator.tempDir(env.paths)) == 0o700)

        // Never regenerated: prepare + applyConfigChanges keep the secret, nothing rewritten, no reload.
        try await controller.prepare()
        let report = try await controller.applyConfigChanges()
        #expect(try await store.load().phpmyadmin.blowfishSecret == secret)
        #expect(report.changed.isEmpty && report.reloaded.isEmpty)
    }

    @Test func notInstalledLeavesConfigAlone() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let store = ConfigStore(paths: env.paths)
        let controller = StackController(paths: env.paths, configStore: store,
                                         supervisor: ServiceSupervisor(paths: env.paths, cleanupOrphans: false),
                                         specProvider: { _, _ in [] }, renderer: pmaRenderer)
        try await controller.prepare()
        #expect(try await store.load().phpmyadmin.blowfishSecret == nil)
        #expect(!FileManager.default.fileExists(atPath: PhpMyAdminConfigGenerator.tempDir(env.paths).path(percentEncoded: false)))
    }
}
