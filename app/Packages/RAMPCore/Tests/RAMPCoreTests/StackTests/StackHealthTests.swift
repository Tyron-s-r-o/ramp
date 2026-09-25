import Foundation
import Testing
@testable import RAMPCore

@Suite struct StackHealthTests {
    private let running = ServiceState.running(pid: 1, since: .distantPast)
    private let expected: Set<ServiceID> = [.phpFPM("8.4"), .apache, .mysql("9.7"), .redis]

    private func all(_ state: ServiceState) -> [ServiceID: ServiceState] {
        Dictionary(uniqueKeysWithValues: expected.map { ($0, state) })
    }

    @Test func allRunning() {
        #expect(StackHealth.evaluate(states: all(running), expected: expected).level == .allRunning)
    }

    @Test func oneStoppedIsPartial() {
        var states = all(running)
        states[.redis] = .stopped
        #expect(StackHealth.evaluate(states: states, expected: expected).level == .partial)
        states[.redis] = nil   // missing = stopped
        #expect(StackHealth.evaluate(states: states, expected: expected).level == .partial)
    }

    @Test func oneFailedIsError() {
        var states = all(running)
        states[.apache] = .failed(reason: "Port 80 is used by httpd (MAMP)")
        let health = StackHealth.evaluate(states: states, expected: expected)
        #expect(health.level == .error)
        #expect(health.failed == [.apache])
    }

    @Test func backingOffIsPartial() {
        var states = all(running)
        states[.redis] = .backingOff(attempt: 2, until: .now)
        #expect(StackHealth.evaluate(states: states, expected: expected).level == .partial)
    }

    @Test func startingOnlyIsPartial() {
        #expect(StackHealth.evaluate(states: all(.starting), expected: expected).level == .partial)
    }

    @Test func nothingRunningIsStopped() {
        #expect(StackHealth.evaluate(states: [:], expected: expected).level == .stopped)
        #expect(StackHealth.evaluate(states: all(.stopping), expected: expected).level == .stopped)
    }

    @Test func optionalStoppedKeepsAllRunning() {
        let health = StackHealth.evaluate(states: all(running), expected: expected, optional: [.elasticsearch])
        #expect(health.level == .allRunning)
    }

    @Test func optionalFailedIsError() {
        var states = all(running)
        states[.elasticsearch] = .failed(reason: "boom")
        let health = StackHealth.evaluate(states: states, expected: expected, optional: [.elasticsearch])
        #expect(health.level == .error)
        #expect(health.failed == [.elasticsearch])
    }

    @Test func xdebugFlag() {
        #expect(!StackHealth.evaluate(states: all(running), expected: expected).xdebugOn)
        #expect(StackHealth.evaluate(states: all(running), expected: expected, xdebugBranches: ["8.3"]).xdebugOn)
    }
}
