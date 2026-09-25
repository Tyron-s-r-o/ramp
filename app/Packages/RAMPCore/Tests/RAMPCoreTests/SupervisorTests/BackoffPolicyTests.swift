import Foundation
import Testing
@testable import RAMPCore

@Suite struct BackoffPolicyTests {
    @Test func delaysDoubleUpToMax() {
        let p = BackoffPolicy.standard
        let delays = (1...9).map { p.delay(attempt: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
        #expect(p.delay(attempt: 1_000) == .seconds(60))
    }

    @Test func trackerRestartsWithIncreasingDelaysThenGivesUp() {
        var t = BackoffTracker(policy: .standard)
        var now = ContinuousClock.now
        var decisions: [BackoffTracker.Decision] = []
        for _ in 1...10 {
            let started = now
            now = now + .milliseconds(500) // short run
            decisions.append(t.recordCrash(startedAt: started, exitedAt: now))
            now = now + .seconds(1)
        }
        #expect(decisions.prefix(3) == [.restart(after: .seconds(1), attempt: 1),
                                        .restart(after: .seconds(2), attempt: 2),
                                        .restart(after: .seconds(4), attempt: 3)])
        #expect(decisions[8] == .restart(after: .seconds(60), attempt: 9))
        #expect(decisions[9] == .giveUp(crashes: 10))
    }

    @Test func stableRunResetsAttempt() {
        var t = BackoffTracker(policy: .standard)
        let t0 = ContinuousClock.now
        _ = t.recordCrash(startedAt: t0, exitedAt: t0 + .seconds(1))
        _ = t.recordCrash(startedAt: t0 + .seconds(2), exitedAt: t0 + .seconds(3))
        #expect(t.attempt == 2)
        // ran 61 s → counts as stable → back to attempt 1
        let d = t.recordCrash(startedAt: t0 + .seconds(10), exitedAt: t0 + .seconds(71))
        #expect(d == .restart(after: .seconds(1), attempt: 1))
    }

    @Test func crashesOutsideWindowAreForgotten() {
        var t = BackoffTracker(policy: BackoffPolicy(maxCrashes: 3, window: .seconds(600)))
        let t0 = ContinuousClock.now
        _ = t.recordCrash(startedAt: t0, exitedAt: t0 + .seconds(1))
        _ = t.recordCrash(startedAt: t0, exitedAt: t0 + .seconds(2))
        // third crash 20 min later: the first two fell out of the window
        let d = t.recordCrash(startedAt: t0 + .seconds(1_199), exitedAt: t0 + .seconds(1_200))
        #expect(d != .giveUp(crashes: 3))
        #expect(t.crashes.count == 1)
    }
}

@Suite struct LogSinkTests {
    @Test func appendsMarkersAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ramp-test-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir.appending(path: "root"), logs: dir.appending(path: "logs"))
        let sink = LogSink(paths: paths, rotateBytes: 100)
        do {
            let h = try sink.open(service: "redis")
            LogSink.marker(h, "started redis pid 1")
            try h.close()
        }
        let url = sink.url(service: "redis")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attrs[.posixPermissions] as? Int) == 0o644)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("=== RAMP started redis pid 1 ==="))
        // grow over the limit → next open rotates to .1
        let big = try sink.open(service: "redis")
        try big.write(contentsOf: Data(repeating: 65, count: 200))
        try big.close()
        let h2 = try sink.open(service: "redis")
        LogSink.marker(h2, "started redis pid 2")
        try h2.close()
        let rotated = URL(filePath: url.path(percentEncoded: false) + ".1")
        #expect(FileManager.default.fileExists(atPath: rotated.path(percentEncoded: false)))
        let current = try String(contentsOf: url, encoding: .utf8)
        #expect(current.contains("pid 2") && !current.contains("pid 1"))
    }
}
