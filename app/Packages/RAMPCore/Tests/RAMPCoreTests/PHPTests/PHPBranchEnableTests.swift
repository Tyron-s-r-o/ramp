import Foundation
import Testing
@testable import RAMPCore

/// `PHPManager.setBranchEnabled` + the disable guard (default branch / vhosts / phpMyAdmin).
@Suite struct PHPBranchEnableTests {
    private let paths = GeneratorFixture.paths

    private func vhost(_ domain: String, _ branch: String?, enabled: Bool = true) -> Vhost {
        Vhost(domain: domain, docroot: "/Users/t/www/\(domain)", phpBranch: branch, enabled: enabled)
    }

    @Test func freeBranchHasNoBlocker() {
        var c = PHPConfDGeneratorTests.config
        c.vhosts = [vhost("a.local", "8.2", enabled: false)]   // disabled vhost does not count
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.2") == nil)
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "7.3") == nil)
    }

    @Test func defaultBranchIsBlocked() {
        var c = PHPConfDGeneratorTests.config
        // Implicit default = highest enabled branch.
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.5")
                == .branchInUse(branch: "8.5", isDefault: true, phpMyAdmin: false, vhosts: []))
        c.apache.defaultPHP = "8.2"
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.2")
                == .branchInUse(branch: "8.2", isDefault: true, phpMyAdmin: false, vhosts: []))
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.5") == nil)
    }

    @Test func vhostsUsingTheEffectiveBranchAreListed() throws {
        var c = PHPConfDGeneratorTests.config
        c.apache.defaultPHP = "8.5"
        c.vhosts = (1...7).map { vhost("v\($0).local", "8.3") } + [vhost("x.local", "8.2"), vhost("d.local", nil)]
        let error = try #require(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.3"))
        guard case .branchInUse(let b, let isDefault, let pma, let vhosts) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(b == "8.3" && !isDefault && !pma)
        #expect(vhosts == (1...7).map { "v\($0).local" })
        let text = try #require(error.errorDescription)
        #expect(text.contains("7 vhosts"))
        #expect(text.contains("v1.local, v2.local, v3.local, v4.local, v5.local"))
        #expect(!text.contains("v6.local"))
        // nil phpBranch → default branch 8.5.
        let d = try #require(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.5"))
        #expect(d == .branchInUse(branch: "8.5", isDefault: true, phpMyAdmin: false, vhosts: ["d.local"]))
    }

    @Test func phpMyAdminBranchIsBlocked() {
        var c = PHPConfDGeneratorTests.config
        c.installed["phpmyadmin"] = ["5.2": GeneratorFixture.pkg("5.2.3")]
        c.apache.defaultPHP = "8.2"
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.5")
                == .branchInUse(branch: "8.5", isDefault: false, phpMyAdmin: true, vhosts: []))
        c.phpmyadmin.enabled = false
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.5") == nil)
        c.phpmyadmin.enabled = true
        c.phpmyadmin.phpBranch = "8.3"
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.5") == nil)
        #expect(PHPManager.disableBlocker(config: c, paths: paths, branch: "8.3")
                == .branchInUse(branch: "8.3", isDefault: false, phpMyAdmin: true, vhosts: []))
    }
}

extension PHPManagerTests {
    @Test func setBranchEnabledTogglesConfigAndRespectsGuard() async throws {
        let env = try await Env { $0.vhosts = [Vhost(domain: "a.local", docroot: "/tmp/a", phpBranch: "8.3")] }
        defer { env.cleanup() }
        await #expect(throws: PHPManagerError.branchInUse(branch: "8.3", isDefault: false, phpMyAdmin: false,
                                                          vhosts: ["a.local"])) {
            try await env.manager.setBranchEnabled(branch: "8.3", enabled: false)
        }
        #expect(try await env.store.load().php.branches["8.3"]?.enabled ?? true)

        try await env.manager.setBranchEnabled(branch: "7.3", enabled: false)
        #expect(try await env.store.load().php.branches["7.3"]?.enabled == false)
        #expect(!GeneratorSupport.enabledPHPBranches(try await env.store.load()).contains("7.3"))
        // Re-enable; the default entry disappears again (no leftover change).
        try await env.manager.setBranchEnabled(branch: "7.3", enabled: true)
        #expect(try await env.store.load().php.branches["7.3"]?.enabled ?? true)
        await #expect(throws: GeneratorError.phpBranchNotInstalled("9.9")) {
            try await env.manager.setBranchEnabled(branch: "9.9", enabled: true)
        }
    }
}
