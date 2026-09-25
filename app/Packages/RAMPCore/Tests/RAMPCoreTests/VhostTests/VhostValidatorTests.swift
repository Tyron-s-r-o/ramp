import Foundation
import Testing
@testable import RAMPCore

@Suite struct VhostValidatorTests {
    typealias F = VhostFixtures

    private func issues(_ config: RampConfig, fs: FakeFileChecking = F.mampFS()) -> [VhostIssue] {
        F.validator(config, fs: fs).validate()
    }

    private func errors(_ config: RampConfig, fs: FakeFileChecking = F.mampFS()) -> [VhostIssue] {
        issues(config, fs: fs).filter { $0.severity == .error }
    }

    /// Config = MAMP fixture + one extra vhost whose docroot exists.
    private func withExtra(_ extra: Vhost, fs: inout FakeFileChecking) -> RampConfig {
        var config = F.mampConfig()
        config.vhosts.append(extra)
        if fs.kinds[extra.docroot] == nil, extra.docroot.hasPrefix("/Users/tester/Sites") {
            fs.kinds[extra.docroot] = .directory
        }
        return config
    }

    // MARK: valid

    @Test func mampFixtureIsValid() {
        #expect(issues(F.mampConfig()) == [])
    }

    @Test func emptyConfigIsValid() {
        #expect(issues(F.baseConfig(), fs: FakeFileChecking()) == [])
    }

    // MARK: hostnames

    @Test(arguments: ["asteel", "bad_name.local", "-x.local", "a..b", "*.asteel.local", "has space.local", "127.0.0.1"])
    func invalidDomainRejected(_ domain: String) {
        var fs = F.mampFS()
        let v = Vhost(domain: domain, docroot: "/Users/tester/Sites/new")
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.vhostID == v.id)
        #expect(errs.first?.field == .domain)
    }

    @Test(arguments: ["localhost", "LocalHost", "shop.localhost", "broadcasthost"])
    func reservedDomainRejected(_ domain: String) {
        var fs = F.mampFS()
        let v = Vhost(domain: domain, docroot: "/Users/tester/Sites/new")
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .domain)
        #expect(errs.first?.message.localizedCaseInsensitiveContains("reserved") == true)
    }

    @Test func invalidAliasRejectedOnAliasField() {
        var fs = F.mampFS()
        let v = Vhost(domain: "new.local", aliases: ["ok.new.local", "bad_alias.local"], docroot: "/Users/tester/Sites/new")
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.map(\.field) == [.alias])
        #expect(errs.first?.message.contains("bad_alias.local") == true)
    }

    // MARK: duplicates

    @Test func duplicateDomainCaseInsensitiveNamesOtherVhost() {
        var fs = F.mampFS()
        let v = Vhost(domain: "TyreStock.local", docroot: "/Users/tester/Sites/new")
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .domain)
        #expect(errs.first?.vhostID == v.id)
        #expect(errs.first?.message.contains("tyrestock.local") == true)
    }

    @Test func aliasOfAEqualsDomainOfB() {
        var fs = F.mampFS()
        let v = Vhost(domain: "new.local", aliases: ["front.asteel.local"], docroot: "/Users/tester/Sites/new")
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .alias)
        #expect(errs.first?.message == "Alias front.asteel.local is already used by vhost front.asteel.local")
    }

    @Test func aliasEqualsOtherAlias() {
        var fs = F.mampFS()
        let v = Vhost(domain: "new.local", aliases: ["admin.asteel.local"], docroot: "/Users/tester/Sites/new")
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.message.contains("vhost asteel.local") == true)
    }

    @Test func aliasEqualsOwnDomainAndAliasTwice() {
        var fs = F.mampFS()
        let v = Vhost(domain: "new.local", aliases: ["NEW.local", "x.new.local", "x.new.local"],
                      docroot: "/Users/tester/Sites/new")
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.count == 2)
        #expect(errs.allSatisfy { $0.field == .alias && $0.vhostID == v.id })
    }

    @Test func duplicatesCountEvenWhenDisabled() {
        var fs = F.mampFS()
        var config = F.mampConfig()
        config.vhosts[2].enabled = false
        let v = Vhost(domain: "tyrestock.local", docroot: "/Users/tester/Sites/new")
        config.vhosts.append(v)
        fs.kinds[v.docroot] = .directory
        #expect(errors(config, fs: fs).count == 1)
    }

    // MARK: docroot

    @Test(arguments: ["relative/www", "", "/Users/tester/Sites/../../etc", "/Users/tester/Sites/a\u{0}b",
                      "/Users/tester/Sites/a\nb"])
    func malformedDocrootRejected(_ docroot: String) {
        var fs = F.mampFS()
        let v = Vhost(domain: "new.local", docroot: docroot)
        let errs = errors(withExtra(v, fs: &fs), fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .docroot)
    }

    @Test func missingDocrootErrorWhenEnabledWarningWhenDisabled() {
        var config = F.mampConfig()
        config.vhosts.append(Vhost(domain: "api.tyron.local", docroot: "/Users/tester/Sites/missing"))
        var found = issues(config)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.field == .docroot)

        config.vhosts[5].enabled = false
        found = issues(config)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
    }

    @Test func docrootThatIsAFileRejected() {
        var fs = F.mampFS()
        fs.kinds["/Users/tester/Sites/file.txt"] = .file
        var config = F.mampConfig()
        config.vhosts.append(Vhost(domain: "new.local", docroot: "/Users/tester/Sites/file.txt"))
        let errs = errors(config, fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.message.contains("not a directory") == true)
    }

    @Test(arguments: ["/", "/Users/tester", "/System/Library", "/usr/local/www", "/bin", "/private/tmp/x",
                      "/etc/apache2", "/Library/WebServer", "/Applications/MAMP/htdocs",
                      "/Users/tester/Library/Application Support/RAMP", "/Users/tester/Library/Application Support/RAMP/www/default",
                      "/Users/tester/Library/Logs/RAMP/x"])
    func dangerousDocrootRejected(_ docroot: String) {
        var fs = F.mampFS()
        fs.kinds[docroot] = .directory
        var config = F.mampConfig()
        config.vhosts.append(Vhost(domain: "new.local", docroot: docroot))
        let errs = errors(config, fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .docroot)
    }

    @Test func similarlyNamedSiblingIsNotInsideForbiddenDir() {
        var fs = F.mampFS()
        fs.kinds["/usrdata/www"] = .directory
        fs.kinds["/Users/tester/Library/Application Support/RAMPX"] = .directory
        var config = F.mampConfig()
        config.vhosts.append(Vhost(domain: "a.local", docroot: "/usrdata/www"))
        config.vhosts.append(Vhost(domain: "b.local", docroot: "/Users/tester/Library/Application Support/RAMPX"))
        #expect(issues(config, fs: fs) == [])
    }

    @Test func symlinkResolvedBeforeSafetyCheck() {
        var fs = F.mampFS()
        fs.kinds["/Users/tester/Projects/shop/www"] = .directory
        fs.symlinks["/Users/tester/Sites/shop"] = "/Users/tester/Projects/shop/www"
        fs.kinds["/etc/secret"] = .directory
        fs.symlinks["/Users/tester/Sites/evil"] = "/etc/secret"
        var config = F.mampConfig()
        config.vhosts.append(Vhost(domain: "shop.local", docroot: "/Users/tester/Sites/shop"))
        #expect(issues(config, fs: fs) == [])
        config.vhosts.append(Vhost(domain: "evil.local", docroot: "/Users/tester/Sites/evil"))
        let errs = errors(config, fs: fs)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .docroot)
    }

    // MARK: PHP

    @Test func notInstalledPHPBranchRejected() {
        var config = F.mampConfig()
        config.vhosts[2].phpBranch = "5.6"
        let errs = errors(config)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .php)
        #expect(errs.first?.vhostID == F.ids[2])
    }

    @Test func disabledPHPBranchRejected() {
        var config = F.mampConfig()
        config.php.branches["8.2"] = PHPBranchSettings(enabled: false)
        let errs = errors(config)
        #expect(errs.count == 1)
        #expect(errs.first?.field == .php)
        #expect(errs.first?.message.contains("disabled") == true)
    }

    @Test func defaultBranchWithoutAnyPHPIsWarning() {
        var config = F.baseConfig(php: [])
        config.vhosts = [Vhost(domain: "a.local", docroot: "/Users/tester/Sites/asteel/www")]
        let found = issues(config)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.field == .php)
    }

    // MARK: limits

    @Test func tooManyVhosts() {
        var config = F.baseConfig()
        var fs = FakeFileChecking()
        fs.kinds["/Users/tester/Sites/x"] = .directory
        config.vhosts = (0...VhostValidator.maxVhosts).map {
            Vhost(domain: "v\($0).local", docroot: "/Users/tester/Sites/x", enabled: false)
        }
        let errs = errors(config, fs: fs)
        #expect(errs.map(\.field) == [.limits])
        #expect(errs.first?.vhostID == nil)
    }

    @Test func tooManyEnabledHostnames() {
        var config = F.baseConfig()
        var fs = FakeFileChecking()
        fs.kinds["/Users/tester/Sites/x"] = .directory
        let perVhost = 100
        let count = VhostValidator.maxHostnames / perVhost + 1
        config.vhosts = (0..<count).map { i in
            Vhost(domain: "v\(i).local", aliases: (1..<perVhost).map { "a\($0).v\(i).local" },
                  docroot: "/Users/tester/Sites/x")
        }
        let errs = errors(config, fs: fs)
        #expect(errs.map(\.field) == [.limits])
        // Disabled vhosts don't count towards the hostname limit.
        config.vhosts[0].enabled = false
        #expect(errors(config, fs: fs).isEmpty)
    }

    // MARK: live filesystem

    @Test func liveFileCheckingKindsAndSymlinks() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "ramp-vhost-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: base) }
        let dir = base.appending(path: "www", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = base.appending(path: "f.txt")
        try Data("x".utf8).write(to: file)
        let link = base.appending(path: "link")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)

        let live = LiveFileChecking()
        let p = { (u: URL) in u.path(percentEncoded: false) }
        #expect(live.kind(at: p(dir)) == .directory)
        #expect(live.kind(at: p(file)) == .file)
        #expect(live.kind(at: p(base.appending(path: "nope"))) == .missing)
        #expect(live.kind(at: p(link)) == .directory)
        #expect(live.realpath(p(link)) == live.realpath(p(dir)))
        #expect(live.realpath(p(base.appending(path: "nope"))) == nil)
    }
}
