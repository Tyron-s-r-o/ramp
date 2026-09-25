import Foundation
import Testing
@testable import RAMPCore

/// Uninstall (07-07) covers the terminal integration: shims, ~/.ramp, PATH blocks, MAMP lines RAMP disabled.
@Suite struct CLIUninstallTests {
    func setUp(foreignShim: Bool = false) throws -> (UninstallSandbox, UninstallContext, ShellIntegration) {
        let s = try UninstallSandbox()
        let shell = ShellIntegration(home: s.home)
        try Data(MAMPSamples.profile.utf8).write(to: shell.file(".profile"))
        try shell.install(disableMAMP: true, loginShell: "/bin/zsh")
        try CLIShimWriter(shimDir: shell.shimDir).sync([
            CLIShim(name: "php", contents: "#!/bin/bash\n\(CLIShimGenerator.managedHeader)\nexit 0\n"),
        ])
        if foreignShim { try Data("mine".utf8).write(to: shell.shimDir.appending(path: "my-tool")) }
        let ctx = UninstallContext(paths: s.paths, home: s.home, library: s.library, config: RampConfig(),
                                   appBundle: nil)
        return (s, ctx, shell)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test func planRemovesShellIntegrationAndRampDir() async throws {
        let (s, ctx, shell) = try setUp()
        defer { s.cleanup() }
        let planner = UninstallPlanner(context: ctx)
        let plan = planner.plan(options: UninstallOptions(dumpDatabases: false, dumpDirectory: s.home))
        #expect(plan.isExecutable, "\(plan.refusals)")
        let step = plan.steps.first { if case .removeShellIntegration = $0.kind { true } else { false } }
        #expect(step?.description.contains("re-enable 3 MAMP line(s)") == true)
        let deleted = plan.deletions.map { $0.url.lastPathComponent }
        #expect(deleted.contains("php") && deleted.contains("bin") && deleted.contains(".ramp"))

        let report = await Uninstaller(actions: FakeUninstallActions(), pathGuard: planner.pathGuard).execute(plan)
        #expect(report.aborted == nil && report.warnings.isEmpty, "\(report)")
        #expect(!exists(shell.rampDir))
        #expect(try String(contentsOf: shell.file(".profile"), encoding: .utf8) == MAMPSamples.profile)
        #expect(!exists(shell.file(".zprofile")) && !exists(shell.file(".zshrc")))   // RAMP created them
    }

    @Test func foreignFilesKeepTheShimDirectory() throws {
        let (s, ctx, shell) = try setUp(foreignShim: true)
        defer { s.cleanup() }
        let plan = UninstallPlanner(context: ctx).plan(options: UninstallOptions(dumpDatabases: false, dumpDirectory: s.home))
        let deleted = plan.deletions.map { $0.url.lastPathComponent }
        #expect(deleted.contains("php"))
        #expect(!deleted.contains("bin") && !deleted.contains(".ramp") && !deleted.contains("my-tool"))
        #expect(plan.notes.contains { $0.contains("bin/my-tool") })
        _ = shell
    }

    @Test func guardAllowsOnlyTheRampDirInHome() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let g = s.guardFor()
        let ramp = s.home.appending(path: ".ramp/bin/php")
        try FileManager.default.createDirectory(at: ramp.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect((try? g.check(ramp).get()) != nil)
        #expect((try? g.check(s.home.appending(path: ".zshrc")).get()) == nil)
        #expect((try? g.check(s.home.appending(path: ".ramp2")).get()) == nil)
    }
}
