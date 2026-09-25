import Foundation
import Synchronization
import Testing
@testable import RAMPCore

/// Records argv; never runs launchctl.
final class FakeLaunchctl: ProcessRunning, Sendable {
    private let calls = Mutex<[[String]]>([])
    let result: ProcessRunResult

    init(_ result: ProcessRunResult = ProcessRunResult(status: 0, output: "")) { self.result = result }

    var argvs: [[String]] { calls.withLock { $0 } }

    func run(_ argv: [String], environment: [String: String], timeout: Duration) async -> ProcessRunResult {
        calls.withLock { $0.append(argv) }
        return result
    }
}

@Suite struct LegacyLaunchAgentRemoverTests {
    struct Env {
        let dir: URL
        let agents: URL
        let trash: URL
        let esDir: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "ramp-la-\(UUID().uuidString.prefix(8))",
                                                                   directoryHint: .isDirectory)
            agents = dir.appending(path: "LaunchAgents", directoryHint: .isDirectory)
            trash = dir.appending(path: "Trash", directoryHint: .isDirectory)
            esDir = dir.appending(path: "Lib/elasticsearch-9.5.4", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }

        @discardableResult
        func plist(_ name: String, label: String, args: [String]) throws -> URL {
            let url = agents.appending(path: name)
            let dict: [String: Any] = ["Label": label, "ProgramArguments": args, "RunAtLoad": true, "StartInterval": 900]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: url)
            return url
        }

        func remover(_ runner: FakeLaunchctl) -> LegacyLaunchAgentRemover {
            let trash = self.trash
            return LegacyLaunchAgentRemover(launchAgentsDir: agents, runner: runner, uid: 501, trash: { url in
                let dest = trash.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })
        }
    }

    @Test func findsOnlyElasticAgentsReferencingTheESDir() throws {
        let env = try Env()
        defer { env.cleanup() }
        let script = env.esDir.appending(path: "es-autostop.sh").path(percentEncoded: false)
        try env.plist("com.rv.elastic-autostop.plist", label: "com.rv.elastic-autostop", args: ["/bin/bash", script])
        try env.plist("com.other.elastic.plist", label: "com.other.elastic",
                      args: ["/bin/bash", env.dir.path(percentEncoded: false) + "/Lib/elasticsearch-9.5.40/x.sh"])
        try env.plist("com.foo.backup.plist", label: "com.foo.backup", args: ["/bin/bash", script])
        try env.plist("sk.tyron.ramp.elastic.plist", label: "sk.tyron.ramp.elastic", args: [script])
        try Data("not a plist".utf8).write(to: env.agents.appending(path: "broken.plist"))

        let found = env.remover(FakeLaunchctl()).find(referencing: env.esDir)
        #expect(found.map(\.label) == ["com.rv.elastic-autostop"])
        #expect(found.first?.scriptPath(in: env.esDir) == script)
    }

    @Test func removeBootsOutThenTrashes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let url = try env.plist("com.rv.elastic-autostop.plist", label: "com.rv.elastic-autostop",
                                args: ["/bin/bash", env.esDir.appending(path: "es-autostop.sh").path(percentEncoded: false)])
        let runner = FakeLaunchctl()
        let remover = env.remover(runner)
        let agent = try #require(remover.find(referencing: env.esDir).first)
        let trashed = try await remover.remove(agent, referencing: env.esDir, confirmed: true)
        #expect(runner.argvs == [["/bin/launchctl", "bootout", "gui/501/com.rv.elastic-autostop"]])
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(trashed?.lastPathComponent == "com.rv.elastic-autostop.plist")
        #expect(FileManager.default.fileExists(atPath: env.trash.appending(path: "com.rv.elastic-autostop.plist")
            .path(percentEncoded: false)))
    }

    @Test func notLoadedIsFineButOtherFailuresKeepThePlist() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let args = ["/bin/bash", env.esDir.appending(path: "es-autostop.sh").path(percentEncoded: false)]
        let url = try env.plist("com.rv.elastic-autostop.plist", label: "com.rv.elastic-autostop", args: args)
        let agent = try #require(env.remover(FakeLaunchctl()).find(referencing: env.esDir).first)

        let failing = env.remover(FakeLaunchctl(ProcessRunResult(status: 5, output: "Input/output error")))
        await #expect(throws: LegacyLaunchAgentError.self) {
            try await failing.remove(agent, referencing: env.esDir, confirmed: true)
        }
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        let notLoaded = env.remover(FakeLaunchctl(ProcessRunResult(status: 3, output: "Boot-out failed: 3: No such process")))
        try await notLoaded.remove(agent, referencing: env.esDir, confirmed: true)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func requiresConfirmationAndRevalidates() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let args = ["/bin/bash", env.esDir.appending(path: "es-autostop.sh").path(percentEncoded: false)]
        try env.plist("com.rv.elastic-autostop.plist", label: "com.rv.elastic-autostop", args: args)
        let runner = FakeLaunchctl()
        let remover = env.remover(runner)
        let agent = try #require(remover.find(referencing: env.esDir).first)

        await #expect(throws: LegacyLaunchAgentError.notConfirmed) {
            try await remover.remove(agent, referencing: env.esDir, confirmed: false)
        }
        // Plist rewritten to point elsewhere → refused, launchctl never called.
        try env.plist("com.rv.elastic-autostop.plist", label: "com.rv.elastic-autostop", args: ["/bin/bash", "/tmp/other.sh"])
        await #expect(throws: LegacyLaunchAgentError.self) {
            try await remover.remove(agent, referencing: env.esDir, confirmed: true)
        }
        // Agent outside the LaunchAgents dir → refused.
        var moved = agent
        moved.plistURL = env.dir.appending(path: "elsewhere/com.rv.elastic-autostop.plist")
        await #expect(throws: LegacyLaunchAgentError.self) {
            try await remover.remove(moved, referencing: env.esDir, confirmed: true)
        }
        #expect(runner.argvs.isEmpty)
    }
}
