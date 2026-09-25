import Foundation
import RAMPHostsKit
import Synchronization
import Testing
@testable import RAMPCore

/// Records `apply` calls; never touches any file.
final class FakeHostsSync: PrivilegedHostsSyncing, Sendable {
    private let state: Mutex<(calls: [[String]], status: HelperStatus, error: HostsSyncError?)>
    let channel: HostsSyncChannel

    init(channel: HostsSyncChannel, status: HelperStatus = .enabled, error: HostsSyncError? = nil) {
        self.channel = channel
        state = Mutex(([], status, error))
    }

    var calls: [[String]] { state.withLock { $0.calls } }
    var status: HelperStatus { state.withLock { $0.status } }
    func fail(with error: HostsSyncError?) { state.withLock { $0.error = error } }

    func apply(names: [String]) async throws -> HostsSyncOutcome {
        let error = state.withLock { s -> HostsSyncError? in
            s.calls.append(names)
            return s.error
        }
        if let error { throw error }
        return .updated(via: channel)
    }
}

/// Captures the script; optionally emulates the privileged `install` by copying tmp → target itself.
final class FakeScriptRunner: AppleScriptRunning, Sendable {
    private let scripts = Mutex<[String]>([])
    let result: (Int32, String)
    let copy: (from: @Sendable (String) -> String?, to: String)?

    init(result: (Int32, String) = (0, ""), copyTo target: String? = nil) {
        self.result = result
        if let target {
            copy = ({ script in
                // quoted form of "<tmp>" — first literal after `quoted form of `
                guard let r = script.range(of: "quoted form of \"") else { return nil }
                let rest = script[r.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<end])
            }, target)
        } else {
            copy = nil
        }
    }

    var recorded: [String] { scripts.withLock { $0 } }

    func run(_ script: String) async -> (status: Int32, output: String) {
        scripts.withLock { $0.append(script) }
        if let copy, let tmp = copy.from(script) {
            let data = FileManager.default.contents(atPath: tmp) ?? Data()
            FileManager.default.createFile(atPath: copy.to, contents: data)
        }
        return result
    }
}

@Suite struct HostsSyncTests {
    private static let base = "127.0.0.1\tlocalhost\n::1\tlocalhost\n"

    @Test func inSyncFileIsANoOpWithoutAnyPrivilegedCall() async throws {
        let names = ["a.local", "b.local"]
        let content = try HostsBlock.merge(existing: Self.base, names: names)
        let helper = FakeHostsSync(channel: .helper)
        let fallback = FakeHostsSync(channel: .adminPrompt)
        let sync = HostsSyncCoordinator(helper: helper, fallback: fallback, reader: { content })
        #expect(try await sync.apply(names: ["b.local", "a.local"]) == .unchanged)
        #expect(helper.calls.isEmpty && fallback.calls.isEmpty)

        // No block and no names → also unchanged.
        let empty = HostsSyncCoordinator(helper: helper, fallback: fallback, reader: { Self.base })
        #expect(try await empty.apply(names: []) == .unchanged)
        #expect(helper.calls.isEmpty && fallback.calls.isEmpty)
    }

    @Test func enabledHelperIsUsed() async throws {
        let helper = FakeHostsSync(channel: .helper, status: .enabled)
        let fallback = FakeHostsSync(channel: .adminPrompt)
        let sync = HostsSyncCoordinator(helper: helper, fallback: fallback, reader: { Self.base })
        #expect(try await sync.apply(names: ["a.local"]) == .updated(via: .helper))
        #expect(helper.calls == [["a.local"]])
        #expect(fallback.calls.isEmpty)
    }

    @Test(arguments: [HelperStatus.requiresApproval, .notRegistered, .notFound])
    func helperNotEnabledFallsBack(_ status: HelperStatus) async throws {
        let helper = FakeHostsSync(channel: .helper, status: status)
        let fallback = FakeHostsSync(channel: .adminPrompt)
        let sync = HostsSyncCoordinator(helper: helper, fallback: fallback, reader: { Self.base })
        #expect(try await sync.apply(names: ["a.local"]) == .updated(via: .adminPrompt))
        #expect(helper.calls.isEmpty)
        #expect(fallback.calls == [["a.local"]])

        // No helper at all (rampctl).
        let noHelper = HostsSyncCoordinator(helper: nil, fallback: fallback, reader: { Self.base })
        #expect(try await noHelper.apply(names: ["b.local"]) == .updated(via: .adminPrompt))
    }

    @Test func appleScriptLiteralEscapesQuotesAndBackslashes() {
        #expect(AdminPromptHostsSync.literal(#"/tmp/my dir/a"b\c"#) == #""/tmp/my dir/a\"b\\c""#)
        let script = AdminPromptHostsSync.script(tempFile: "/tmp/R \"x\"/hosts.1", target: HostsFileWriter.systemHostsPath)
        #expect(script == #"do shell script "/usr/bin/install -m 0644 -o root -g wheel " & quoted form of "/tmp/R \"x\"/hosts.1" & " " & quoted form of "/private/etc/hosts" & " && /usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder" with administrator privileges"#)
    }

    /// Real AppleScript parsing of the literal (compile only — `osacompile`, no execution, no prompt).
    @Test func appleScriptCompiles() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let script = AdminPromptHostsSync.script(tempFile: "/tmp/a \"q\" b\\c/hosts.x", target: "/tmp/t\"t")
        let out = env.dir.appending(path: "s.scpt")
        let result = await ProcessRunner.run(["/usr/bin/osacompile", "-e", script, "-o", out.path(percentEncoded: false)],
                                             tempDir: env.dir)
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func adminPromptInstallsMergedContentIntoTarget() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let hosts = env.dir.appending(path: "my hosts")
        try Data(Self.base.utf8).write(to: hosts)
        let target = hosts.path(percentEncoded: false)
        let runner = FakeScriptRunner(copyTo: target)
        let sync = AdminPromptHostsSync(paths: env.paths, hostsPath: target, runner: runner)

        #expect(try await sync.apply(names: ["x.local"]) == .updated(via: .adminPrompt))
        #expect(runner.recorded.count == 1)
        #expect(runner.recorded[0].contains("with administrator privileges"))
        let written = try String(contentsOf: hosts, encoding: .utf8)
        #expect(written == (try HostsBlock.merge(existing: Self.base, names: ["x.local"])))
        #expect(HostsBlock.names(in: written) == ["x.local"])
        // Temp file removed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.tmp.path(percentEncoded: false))
            .filter { $0.hasPrefix("hosts.") }.isEmpty)

        // Already in sync → no second prompt.
        #expect(try await sync.apply(names: ["x.local"]) == .unchanged)
        #expect(runner.recorded.count == 1)
    }

    @Test func userCancelIsReportedAsCancelled() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let hosts = env.dir.appending(path: "hosts")
        try Data(Self.base.utf8).write(to: hosts)
        let runner = FakeScriptRunner(result: (1, "0:94: execution error: User canceled. (-128)"))
        let sync = AdminPromptHostsSync(paths: env.paths, hostsPath: hosts.path(percentEncoded: false), runner: runner)
        await #expect(throws: HostsSyncError.cancelled) { try await sync.apply(names: ["x.local"]) }
        #expect(try String(contentsOf: hosts, encoding: .utf8) == Self.base)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.tmp.path(percentEncoded: false))
            .filter { $0.hasPrefix("hosts.") }.isEmpty)
    }

    @Test func directSyncWritesTempHostsFile() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        let hosts = env.dir.appending(path: "hosts")
        try Data(Self.base.utf8).write(to: hosts)
        let sync = HostsSyncCoordinator(helper: nil, fallback: DirectHostsSync(path: hosts),
                                        reader: { try HostsFileWriter(path: hosts).read() })
        #expect(try await sync.apply(names: ["a.local"]) == .updated(via: .direct))
        #expect(try sync.isInSync(names: ["a.local"]))
        #expect(try await sync.apply(names: ["a.local"]) == .unchanged)
        #expect(try await sync.apply(names: []) == .updated(via: .direct))
        #expect(try String(contentsOf: hosts, encoding: .utf8) == Self.base)
    }

    @Test func replyTimeoutFiresOnceAndLateRepliesAreDropped() async throws {
        let late = Mutex<OneShot<String>?>(nil)
        let start = ContinuousClock.now
        await #expect(throws: HostsSyncError.timeout) {
            _ = try await withReplyTimeout(.milliseconds(100)) { (shot: OneShot<String>) in
                late.withLock { $0 = shot }      // never replies
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        // A reply arriving after the timeout must not resume a second time (would crash).
        #expect(late.withLock { $0 }?.resume(.success("late")) == false)

        // Reply before the timeout wins; the timeout later is a no-op.
        let value = try await withReplyTimeout(.milliseconds(200)) { (shot: OneShot<String>) in
            #expect(shot.resume(.success("ok")))
            #expect(!shot.resume(.success("again")))
        }
        #expect(value == "ok")
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func helperStatusMapping() {
        #expect(HelperHostsSync.map(.enabled) == .enabled)
        #expect(HelperHostsSync.map(.requiresApproval) == .requiresApproval)
        #expect(HelperHostsSync.map(.notRegistered) == .notRegistered)
        #expect(HelperHostsSync.map(.notFound) == .notFound)
    }

    @Test func helperIsUnavailableWithoutTeamSignature() async throws {
        // `swift test` binaries are ad-hoc signed → no Team ID → no XPC attempt at all.
        guard HelperHostsSync.ownTeamID() == nil else { return }
        await #expect(throws: HostsSyncError.self) { try await HelperHostsSync().apply(names: ["a.local"]) }
    }
}
