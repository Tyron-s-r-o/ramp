import Foundation
import Testing
@testable import RAMPCore

/// Fake ES: settable state, counts stops.
private actor FakeES: ElasticsearchControlling {
    var current: ServiceState = .stopped
    var stops = 0

    func state() -> ServiceState { current }
    func stop() {
        stops += 1
        current = .stopped
    }
    func set(_ state: ServiceState) { current = state }
}

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AutoStopSettings
    init(_ value: AutoStopSettings) { self.value = value }
    var settings: AutoStopSettings {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Plan 06-04: auto-stop scheduler (session tracking, once-per-session stop, postpone, sleep, marker).
@Suite struct AutoStopSchedulerTests {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        return c
    }()

    /// 2026-09-25 10:00 local.
    let t0 = Self.cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10, minute: 0))!
    func t(_ h: Double, _ m: Double = 0) -> Date { t0.addingTimeInterval(h * 3600 + m * 60) }
    let running = ServiceState.running(pid: 4242, since: .now)

    let base: URL
    let paths: Paths

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "ramp-autostop-\(UUID().uuidString)")
        paths = Paths(root: base.appending(path: "root"), logs: base.appending(path: "logs"))
    }

    private func make(_ settings: SettingsBox, override: TimeInterval? = nil, stateFile: URL? = nil)
        -> (FakeES, ElasticsearchAutoStopScheduler) {
        let es = FakeES()
        let scheduler = ElasticsearchAutoStopScheduler(es: es, settings: { settings.settings },
                                                       calendar: { Self.cal }, log: LogSink(paths: paths),
                                                       stateFile: stateFile, overrideAfterSeconds: override)
        return (es, scheduler)
    }

    private func started(_ es: FakeES, _ s: ElasticsearchAutoStopScheduler, at date: Date) async {
        await es.set(running)
        await s.sessionStarted(at: date)
    }

    private func marker() -> String {
        (try? String(contentsOf: paths.log("elasticsearch.log"), encoding: .utf8)) ?? ""
    }

    @Test func stopsAfterHoursExactlyOnce() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        await started(es, s, at: t(0))
        await s.tick(now: t(5, 59))
        #expect(await es.stops == 0)
        #expect(await s.status(now: t(5, 59)).remaining == .seconds(60))
        await s.tick(now: t(6))
        #expect(await es.stops == 1)
        await s.tick(now: t(6, 1))
        #expect(await es.stops == 1)
        #expect(await s.sessionStart == nil)
        #expect(marker().contains("=== RAMP auto-stop: po 6 h ==="))
    }

    @Test func crashRestartKeepsDeadline() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        await started(es, s, at: t(0))
        await es.set(.backingOff(attempt: 1, until: t(2)))
        await s.tick(now: t(2))
        await es.set(.starting)
        await s.tick(now: t(2, 0.5))
        await es.set(running)
        await s.tick(now: t(2, 1))
        #expect(await s.status(now: t(2, 1)).deadline == t(6))
        await s.tick(now: t(6))
        #expect(await es.stops == 1)
    }

    @Test func manualStopThenNewStart() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        await started(es, s, at: t(0))
        await es.set(.stopped)
        await s.tick(now: t(1))
        #expect(await s.sessionStart == nil)
        await es.set(running)
        await s.tick(now: t(3))   // adopted by the tick (started elsewhere)
        #expect(await s.status(now: t(3)).deadline == t(9))
        await s.tick(now: t(6))
        #expect(await es.stops == 0)
        await s.tick(now: t(9))
        #expect(await es.stops == 1)
    }

    @Test func requestedStopStartResetsSession() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        await started(es, s, at: t(0))
        await es.set(.stopped)
        await s.sessionEnded(now: t(1))
        await started(es, s, at: t(1, 0.2))   // between two ticks
        #expect(await s.status(now: t(2)).deadline == t(7, 0.2))
    }

    @Test func postponeExtendsFromDeadline() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        await started(es, s, at: t(0))
        let status = await s.postpone(now: t(5, 30))
        #expect(status.deadline == t(7))
        #expect(status.reason == .postponed)
        await s.tick(now: t(6))
        #expect(await es.stops == 0)
        await s.tick(now: t(7))
        #expect(await es.stops == 1)
        #expect(marker().contains("auto-stop: po predĺžení"))
    }

    @Test func postponeWithoutSessionIsNoop() async {
        let (_, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        #expect(await s.postpone(now: t(1)) == .inactive)
    }

    @Test func sleepPastDeadlineStopsOnFirstTick() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        await started(es, s, at: t(0))
        await s.tick(now: t(1))
        await s.tick(now: t(9))   // woke up 3 h after the deadline
        #expect(await es.stops == 1)
    }

    @Test func settingsChangeWhileRunningRecomputes() async {
        let box = SettingsBox(AutoStopSettings(afterHours: 6))
        let (es, s) = make(box)
        await started(es, s, at: t(0))   // 10:00
        await s.tick(now: t(1))
        box.settings = AutoStopSettings(afterHours: nil, atTime: "13:00")
        #expect(await s.status(now: t(1)).deadline == t(3))
        #expect(await s.status(now: t(1)).reason == .atTime(AutoStopTime("13:00")!))
        await s.tick(now: t(3))
        #expect(await es.stops == 1)
        #expect(marker().contains("auto-stop: o 13:00"))
    }

    @Test func disabledNeverStops() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: nil, atTime: nil)))
        await started(es, s, at: t(0))
        await s.tick(now: t(100))
        #expect(await es.stops == 0)
        let status = await s.status(now: t(100))
        #expect(status.isDisabled)
        #expect(status.cliDescription(calendar: Self.cal) == "auto-stop: vypnutý")
    }

    @Test func stoppingStateIsNotAdopted() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 1)))
        await es.set(.stopping)
        await s.tick(now: t(0))
        #expect(await s.sessionStart == nil)
    }

    @Test func overrideSecondsAndPersistence() async throws {
        let file = base.appending(path: "es-autostop.json")
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)), override: 60, stateFile: file)
        await started(es, s, at: t(0))
        #expect(ElasticsearchAutoStopScheduler.loadPersisted(from: file)?.sessionStart == t(0))
        await s.tick(now: t(0, 0.5))
        #expect(await es.stops == 0)
        await s.tick(now: t(0, 1))
        #expect(await es.stops == 1)
        #expect(marker().contains("auto-stop: po 60 s (RAMP_ES_AUTOSTOP_SECONDS)"))
        #expect(ElasticsearchAutoStopScheduler.loadPersisted(from: file) == nil)
    }

    @Test func updatesStreamEmits() async {
        let (es, s) = make(SettingsBox(AutoStopSettings(afterHours: 6)))
        await started(es, s, at: t(0))
        await s.tick(now: t(1))
        var iterator = s.updates.makeAsyncIterator()
        let latest = await iterator.next()
        #expect(latest?.deadline == t(6))
        #expect(latest?.remaining == .seconds(5 * 3600))
    }

    @Test func cliDescription() {
        let status = AutoStopStatus(sessionStart: t(0), deadline: t(15), reason: .afterHours(6),
                                    remaining: .seconds(4 * 3600 + 12 * 60))
        #expect(status.cliDescription(calendar: Self.cal) == "auto-stop: o 01:00 (po 6 h) — zostáva 4 h 12 min")
        #expect(AutoStopStatus.remainingText(.seconds(61)) == "2 min")
        #expect(AutoStopStatus.remainingText(.seconds(3 * 3600 + 5 * 60)) == "3 h 05 min")
        #expect(ElasticsearchAutoStopScheduler.overrideFromEnvironment(["RAMP_ES_AUTOSTOP_SECONDS": "60"]) == 60)
        #expect(ElasticsearchAutoStopScheduler.overrideFromEnvironment(["RAMP_ES_AUTOSTOP_SECONDS": "x"]) == nil)
        #expect(ElasticsearchAutoStopScheduler.overrideFromEnvironment([:]) == nil)
    }
}
