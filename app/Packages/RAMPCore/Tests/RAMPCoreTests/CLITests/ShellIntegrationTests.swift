import Foundation
import Testing
@testable import RAMPCore

/// The user's real MAMP lines (plan: terminal integration).
enum MAMPSamples {
    static let path = #"export PATH="/Applications/MAMP/bin/php:/Applications/MAMP/bin/php/php8.3.14/bin:${PATH}""#
    static let php = #"alias php='/Applications/MAMP/bin/php/php8.3.14/bin/php -c "/Library/Application Support/appsolute/MAMP PRO/conf/php8.3.14.ini"'"#
    static let composer = "alias composer='/Applications/MAMP/bin/php/composer'"

    static let profile = """
    # user profile
    export EDITOR=vim
    \(path)
    \(php)
    \(composer)
    alias ll='ls -la'
    export PATH="$HOME/bin:$PATH"

    """
}

@Suite struct ShellIntegrationTextTests {
    typealias S = ShellIntegration

    @Test func insertAppendsBlockAtEnd() {
        let out = S.insertingBlock(into: "export A=1\n")
        #expect(out == "export A=1\n\n" + S.block + "\n")
        #expect(out.hasSuffix(S.blockEnd + "\n"))
        #expect(out.contains(#"export PATH="$HOME/.ramp/bin:$PATH""#))
    }

    @Test func insertIntoEmptyAndMissingTrailingNewline() {
        #expect(S.insertingBlock(into: "") == S.block + "\n")
        #expect(S.insertingBlock(into: "export A=1") == "export A=1\n\n" + S.block + "\n")
    }

    @Test func insertIsIdempotent() {
        let once = S.insertingBlock(into: MAMPSamples.profile)
        #expect(S.insertingBlock(into: once) == once)
        #expect(once.components(separatedBy: S.blockStart).count == 2)
    }

    @Test func insertMovesAnEarlierBlockToTheEnd() {
        let text = "a=1\n" + S.block + "\nexport PATH=\"/opt/x:$PATH\"\n"
        let out = S.insertingBlock(into: text)
        #expect(out == "a=1\nexport PATH=\"/opt/x:$PATH\"\n\n" + S.block + "\n")
    }

    @Test func insertReplacesAnOutdatedBlock() {
        let old = "x\n\n# >>> RAMP >>>\nexport PATH=\"/old:$PATH\"\n# <<< RAMP <<<\n"
        let out = S.insertingBlock(into: old)
        #expect(!out.contains("/old"))
        #expect(out == "x\n\n" + S.block + "\n")
    }

    @Test func removeRestoresOriginal() {
        let original = "export A=1\nalias x=y\n"
        #expect(S.removingBlock(from: S.insertingBlock(into: original)) == original)
        #expect(S.removingBlock(from: original) == original)   // absent → unchanged byte for byte
        #expect(S.removingBlock(from: S.insertingBlock(into: "")) == "")
    }

    @Test func detectsTheUsersMAMPLines() {
        let conflicts = S.mampConflicts(in: MAMPSamples.profile)
        #expect(conflicts.map(\.kind) == [.path, .alias("php"), .alias("composer")])
        #expect(conflicts.map(\.index) == [2, 3, 4])
        #expect(conflicts[1].text == MAMPSamples.php)
        #expect(conflicts.allSatisfy { $0.disableable })
    }

    @Test func detectionIgnoresCommentsOtherAliasesAndNonShadowingLines() {
        let text = """
        # alias php='/Applications/MAMP/bin/php/php8.3.14/bin/php'
        alias mampstart='/Applications/MAMP/bin/start.sh'
        source /Applications/MAMP/some/env.sh
        alias php='/opt/homebrew/bin/php'
          alias mysql="/Applications/MAMP/Library/bin/mysql80/bin/mysql"
        alias php7.4='/Applications/MAMP/bin/php/php7.4.33/bin/php'
        export PATH="/Applications/MAMP/Library/bin:/usr/local/bin:$PATH"
        path=(/Applications/MAMP/bin/php $path)
        """
        let c = S.mampConflicts(in: text)
        #expect(c.map(\.kind) == [.alias("mysql"), .alias("php7.4"), .mixedPath, .path])
        #expect(c.map(\.index) == [4, 5, 6, 7])
        #expect(!c[2].disableable)
    }

    @Test func disableAndRestoreRoundTrip() {
        let (disabled, n) = S.disablingMAMP(in: MAMPSamples.profile)
        #expect(n == 3)
        #expect(disabled.contains(S.disabledPrefix + MAMPSamples.php + "\n"))
        #expect(disabled.contains(S.disabledPrefix + MAMPSamples.path + "\n"))
        #expect(S.mampConflicts(in: disabled).isEmpty)
        #expect(S.disabledMAMPLines(in: disabled).map(\.text) == [MAMPSamples.path, MAMPSamples.php, MAMPSamples.composer])
        // idempotent: nothing more to disable
        #expect(S.disablingMAMP(in: disabled).count == 0)
        let (restored, m) = S.restoringMAMP(in: disabled)
        #expect(m == 3)
        #expect(restored == MAMPSamples.profile)
    }

    @Test func restoreTouchesOnlyRAMPsOwnMarkers() {
        let text = "# alias php='/Applications/MAMP/x'\n# [RAMP disabled MAMP] alias composer='/Applications/MAMP/bin/php/composer'\n"
        let (restored, n) = S.restoringMAMP(in: text)
        #expect(n == 1)
        #expect(restored == "# alias php='/Applications/MAMP/x'\nalias composer='/Applications/MAMP/bin/php/composer'\n")
    }

    @Test func mixedPathIsNeverDisabled() {
        let text = "export PATH=\"/Applications/MAMP/Library/bin:/usr/local/bin:$PATH\"\n"
        #expect(S.disablingMAMP(in: text).count == 0)
        #expect(S.disablingMAMP(in: text).text == text)
    }
}

/// File side against a sandbox home (never the real one).
@Suite struct ShellIntegrationFileTests {
    let home: URL
    let shell: ShellIntegration

    init() throws {
        home = URL(filePath: "/tmp/ramp-shell-tests/\(UUID().uuidString)/home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        shell = ShellIntegration(home: home)
    }

    func text(_ name: String) throws -> String { try String(contentsOf: shell.file(name), encoding: .utf8) }
    func write(_ name: String, _ s: String) throws { try Data(s.utf8).write(to: shell.file(name)) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: shell.file(name).path(percentEncoded: false)) }
    func cleanup() { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

    @Test func targetsForAFreshZshHome() {
        defer { cleanup() }
        #expect(shell.blockTargets(loginShell: "/bin/zsh").map(\.lastPathComponent) == [".zprofile", ".zshrc"])
        #expect(shell.blockTargets(loginShell: "/bin/bash").map(\.lastPathComponent)
                == [".zprofile", ".zshrc", ".bash_profile"])
    }

    @Test func profileIsATargetWhenItCarriesPathOrAliases() throws {
        defer { cleanup() }
        try write(".profile", MAMPSamples.profile)
        #expect(shell.blockTargets(loginShell: "/bin/zsh").map(\.lastPathComponent) == [".zprofile", ".zshrc", ".profile"])
        // bash without .bash_profile reads .profile — never create .bash_profile then.
        #expect(!shell.blockTargets(loginShell: "/bin/bash").map(\.lastPathComponent).contains(".bash_profile"))
    }

    @Test func installWithoutMAMPThenUninstallLeavesNoTrace() throws {
        defer { cleanup() }
        try write(".zshrc", "export A=1\n")
        let r = try shell.install(disableMAMP: false, loginShell: "/bin/zsh", now: Date(timeIntervalSince1970: 0))
        #expect(Set(r.modified.map(\.lastPathComponent)) == [".zprofile", ".zshrc"])
        #expect(r.backups.map(\.lastPathComponent) == [".zshrc.ramp-backup-" + ShellIntegration.stamp(Date(timeIntervalSince1970: 0))])
        #expect(try text(".zshrc").hasSuffix(ShellIntegration.block + "\n"))
        #expect(try text(".zprofile") == ShellIntegration.block + "\n")
        #expect(shell.status(loginShell: "/bin/zsh").blockInstalled)

        // second run: no change, no second backup
        let again = try shell.install(disableMAMP: false, loginShell: "/bin/zsh", now: Date())
        #expect(again.modified.isEmpty && again.backups.isEmpty)

        let u = try shell.uninstall(restoreMAMP: true)
        #expect(try text(".zshrc") == "export A=1\n")
        #expect(u.removedFiles.map(\.lastPathComponent) == [".zprofile"])   // RAMP created it
        #expect(!exists(".zprofile"))
    }

    @Test func mampLinesAreOnlyDisabledOnRequestAndRestoredExactly() throws {
        defer { cleanup() }
        try write(".profile", MAMPSamples.profile)
        try shell.install(disableMAMP: false, loginShell: "/bin/zsh")
        var status = shell.status(loginShell: "/bin/zsh")
        #expect(status.blockingConflicts.count == 3)
        #expect(status.blockingConflicts.allSatisfy { $0.file?.lastPathComponent == ".profile" })

        let r = try shell.install(disableMAMP: true, loginShell: "/bin/zsh")
        #expect(r.disabledMAMP == 3)
        status = shell.status(loginShell: "/bin/zsh")
        #expect(status.conflicts.isEmpty)
        #expect(status.disabledLines.count == 3)
        #expect(shell.backups(of: shell.file(".profile")).count == 1)

        try shell.restoreMAMP()
        #expect(try text(".profile") == ShellIntegration.insertingBlock(into: MAMPSamples.profile))
        try shell.uninstall(restoreMAMP: true)
        #expect(try text(".profile") == MAMPSamples.profile)
    }

    @Test func symlinkedDotfileIsEditedAtItsTarget() throws {
        defer { cleanup() }
        let dotfiles = home.deletingLastPathComponent().appending(path: "dotfiles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appending(path: "zshrc")
        try Data("export B=2\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: shell.file(".zshrc"), withDestinationURL: real)
        try shell.install(disableMAMP: false, loginShell: "/bin/zsh")
        let attrs = try FileManager.default.attributesOfItem(atPath: shell.file(".zshrc").path(percentEncoded: false))
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try String(contentsOf: real, encoding: .utf8).hasSuffix(ShellIntegration.block + "\n"))
        #expect(shell.backups(of: shell.file(".zshrc")).first?.deletingLastPathComponent().lastPathComponent == "dotfiles")
    }

    @Test func probeSeesTheShimInANewLoginShell() async throws {
        defer { cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: shell.shimDir, withIntermediateDirectories: true)
        let php = shell.shimDir.appending(path: "php")
        try Data("#!/bin/bash\n\(CLIShimGenerator.managedHeader)\necho fake\n".utf8).write(to: php)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path(percentEncoded: false))
        try write(".zprofile", MAMPSamples.path + "\n")
        try write(".zshrc", "\(MAMPSamples.php)\n")

        let before = await shell.probe(shell: "/bin/zsh")
        #expect(before?.hasPrefix("alias php=") == true)   // alias beats PATH
        #expect(!shell.resolvesToRAMP(before))

        try shell.install(disableMAMP: true, loginShell: "/bin/zsh")
        let after = await shell.probe(shell: "/bin/zsh")
        #expect(shell.resolvesToRAMP(after), "probe: \(after ?? "nil")")
    }
}
