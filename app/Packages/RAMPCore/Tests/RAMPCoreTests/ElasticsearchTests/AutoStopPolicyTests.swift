import Foundation
import Testing
@testable import RAMPCore

/// Plan 06-02: pure auto-stop deadline / decision logic for Elasticsearch.
@Suite struct AutoStopPolicyTests {
    static func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    let cal = Self.calendar("Europe/Bratislava")

    /// Local wall-clock date in `cal`'s time zone.
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, in c: Calendar? = nil) -> Date {
        let c = c ?? cal
        return c.date(from: DateComponents(timeZone: c.timeZone, year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func deadline(_ start: Date, _ s: AutoStopSettings, postponed: Date? = nil,
                  calendar: Calendar? = nil) -> (Date, AutoStopReason)? {
        AutoStopPolicy.deadline(startedAt: start, settings: s, postponedUntil: postponed, calendar: calendar ?? cal)
    }

    func expectDeadline(_ start: Date, _ s: AutoStopSettings, _ expected: Date, _ reason: AutoStopReason,
                        postponed: Date? = nil, calendar: Calendar? = nil,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        let r = deadline(start, s, postponed: postponed, calendar: calendar)
        #expect(r?.0 == expected, sourceLocation: sourceLocation)
        #expect(r?.1 == reason, sourceLocation: sourceLocation)
    }

    let t0100 = AutoStopTime("01:00")!

    // MARK: AutoStopTime

    @Test(arguments: [("01:00", 1, 0), ("1:05", 1, 5), ("00:00", 0, 0), ("23:59", 23, 59), ("9:30", 9, 30)])
    func parsesTime(_ s: String, _ h: Int, _ m: Int) throws {
        let t = try #require(AutoStopTime(s))
        #expect(t.hour == h)
        #expect(t.minute == m)
    }

    @Test(arguments: ["24:00", "1:5", "01:60", " 01:00", "", "01:00 ", "1", "001:00", "01-00", "a1:00", "-1:00", "01:0０"])
    func rejectsTime(_ s: String) {
        #expect(AutoStopTime(s) == nil)
    }

    @Test func timeDescription() {
        #expect(AutoStopTime("1:05")?.description == "01:05")
        #expect(AutoStopTime(hour: 23, minute: 9)?.description == "23:09")
        #expect(AutoStopTime(hour: 24, minute: 0) == nil)
    }

    // MARK: Validation

    @Test func validate() throws {
        try AutoStopSettings().validate()
        try AutoStopSettings(afterHours: nil, atTime: nil).validate()
        try AutoStopSettings(afterHours: 1, atTime: "01:00").validate()
        try AutoStopSettings(afterHours: 72, atTime: "23:59").validate()
        #expect(throws: AutoStopError.invalidAfterHours(0)) { try AutoStopSettings(afterHours: 0).validate() }
        #expect(throws: AutoStopError.invalidAfterHours(73)) { try AutoStopSettings(afterHours: 73).validate() }
        #expect(throws: AutoStopError.invalidTime("25:00")) {
            try AutoStopSettings(afterHours: nil, atTime: "25:00").validate()
        }
    }

    // MARK: Deadline

    @Test func afterHoursOnly() {
        expectDeadline(at(2026, 9, 24, 10, 0), AutoStopSettings(afterHours: 6), at(2026, 9, 24, 16, 0), .afterHours(6))
    }

    @Test func atTimeOnly() {
        expectDeadline(at(2026, 9, 24, 20, 0), AutoStopSettings(afterHours: nil, atTime: "01:00"),
                       at(2026, 9, 25, 1, 0), .atTime(t0100))
    }

    @Test func atTimeGraceSkipsToNextDay() {
        // 00:50 + 15 min grace = 01:05 > 01:00 → tomorrow.
        expectDeadline(at(2026, 9, 24, 0, 50), AutoStopSettings(afterHours: nil, atTime: "01:00"),
                       at(2026, 9, 25, 1, 0), .atTime(t0100))
        // Exactly at the grace boundary (00:45 + 15 min = 01:00) → strictly after → tomorrow.
        expectDeadline(at(2026, 9, 24, 0, 45), AutoStopSettings(afterHours: nil, atTime: "01:00"),
                       at(2026, 9, 25, 1, 0), .atTime(t0100))
    }

    @Test func atTimeBeyondGraceSameNight() {
        expectDeadline(at(2026, 9, 24, 0, 40), AutoStopSettings(afterHours: nil, atTime: "01:00"),
                       at(2026, 9, 24, 1, 0), .atTime(t0100))
    }

    @Test func bothEarlierWins() {
        let both = AutoStopSettings(afterHours: 6, atTime: "01:00")
        expectDeadline(at(2026, 9, 24, 22, 0), both, at(2026, 9, 25, 1, 0), .atTime(t0100))
        expectDeadline(at(2026, 9, 24, 0, 50), both, at(2026, 9, 24, 6, 50), .afterHours(6))
    }

    @Test func noneIsNil() {
        #expect(deadline(at(2026, 9, 24, 10, 0), AutoStopSettings(afterHours: nil, atTime: nil)) == nil)
        // Postponement alone never creates a deadline.
        #expect(deadline(at(2026, 9, 24, 10, 0), AutoStopSettings(afterHours: nil, atTime: nil),
                         postponed: at(2026, 9, 24, 12, 0)) == nil)
    }

    @Test func invalidValuesAreIgnored() {
        // Callers validate first; the policy never stops ES because of a malformed setting.
        #expect(deadline(at(2026, 9, 24, 10, 0), AutoStopSettings(afterHours: 0, atTime: "25:00")) == nil)
        expectDeadline(at(2026, 9, 24, 10, 0), AutoStopSettings(afterHours: 6, atTime: "bogus"),
                       at(2026, 9, 24, 16, 0), .afterHours(6))
    }

    @Test func postponementLaterWins() {
        expectDeadline(at(2026, 9, 24, 10, 0), AutoStopSettings(afterHours: 6), at(2026, 9, 24, 17, 0), .postponed,
                       postponed: at(2026, 9, 24, 17, 0))
    }

    @Test func postponementEarlierIgnored() {
        expectDeadline(at(2026, 9, 24, 10, 0), AutoStopSettings(afterHours: 6), at(2026, 9, 24, 16, 0), .afterHours(6),
                       postponed: at(2026, 9, 24, 15, 0))
    }

    // MARK: DST / time zones

    @Test func springForwardGapMovesToNextExistingTime() {
        // 2027-03-28: 02:00 CET → 03:00 CEST, 02:30 does not exist.
        let r = deadline(at(2027, 3, 27, 22, 0), AutoStopSettings(afterHours: nil, atTime: "02:30"))
        #expect(r?.0 == at(2027, 3, 28, 3, 0))
        #expect(r?.0 == Date(timeIntervalSince1970: 1_806_195_600)) // 2027-03-28T01:00:00Z
        #expect(r?.1 == .atTime(AutoStopTime("02:30")!))
    }

    @Test func fallBackDuplicateTakesFirstOccurrence() {
        // 2026-10-25: 03:00 CEST → 02:00 CET, 02:30 occurs twice; first = 02:30 CEST = 00:30Z.
        let r = deadline(at(2026, 10, 24, 22, 0), AutoStopSettings(afterHours: nil, atTime: "02:30"))
        #expect(r?.0 == Date(timeIntervalSince1970: 1_792_888_200)) // 2026-10-25T00:30:00Z
    }

    @Test func afterHoursAcrossFallBackIsElapsedTime() {
        let start = at(2026, 10, 25, 0, 0) // CEST
        let r = deadline(start, AutoStopSettings(afterHours: 6))
        #expect(r?.0 == start.addingTimeInterval(6 * 3600))
        #expect(cal.component(.hour, from: r!.0) == 5) // wall clock shows 5 h later (one hour repeated)
    }

    @Test func timeZoneChangeRecomputesWallClock() {
        let start = Date(timeIntervalSince1970: 1_790_272_800) // 2026-09-24T18:00:00Z
        let s = AutoStopSettings(afterHours: nil, atTime: "01:00")
        // Bratislava (CEST, +2): 20:00 local → 01:00 CEST = 23:00Z.
        #expect(deadline(start, s)?.0 == Date(timeIntervalSince1970: 1_790_290_800))
        // New York (EDT, −4): 14:00 local → 01:00 EDT = 05:00Z next day.
        #expect(deadline(start, s, calendar: Self.calendar("America/New_York"))?.0
                == Date(timeIntervalSince1970: 1_790_312_400))
    }

    // MARK: Decision

    @Test func decideDisabled() {
        #expect(AutoStopPolicy.decide(now: at(2026, 9, 24, 12, 0), startedAt: at(2026, 9, 24, 10, 0),
                                      settings: AutoStopSettings(afterHours: nil), postponedUntil: nil,
                                      calendar: cal) == .disabled)
    }

    @Test func decideKeepRunningUntilDeadline() {
        let d = AutoStopPolicy.decide(now: at(2026, 9, 24, 15, 59), startedAt: at(2026, 9, 24, 10, 0),
                                      settings: AutoStopSettings(afterHours: 6), postponedUntil: nil, calendar: cal)
        #expect(d == .keepRunning(deadline: at(2026, 9, 24, 16, 0), reason: .afterHours(6)))
    }

    @Test func decideStopAtDeadline() {
        let d = AutoStopPolicy.decide(now: at(2026, 9, 24, 16, 0), startedAt: at(2026, 9, 24, 10, 0),
                                      settings: AutoStopSettings(afterHours: 6), postponedUntil: nil, calendar: cal)
        #expect(d == .stopNow(.afterHours(6)))
    }

    @Test func decideStopAfterSleepingPastDeadline() {
        let d = AutoStopPolicy.decide(now: at(2026, 9, 25, 4, 0), startedAt: at(2026, 9, 24, 20, 0),
                                      settings: AutoStopSettings(afterHours: nil, atTime: "01:00"),
                                      postponedUntil: nil, calendar: cal)
        #expect(d == .stopNow(.atTime(t0100)))
    }

    @Test func postponeFlow() {
        let start = at(2026, 9, 24, 10, 0)
        let s = AutoStopSettings(afterHours: 6)
        let until = AutoStopPolicy.postpone(now: at(2026, 9, 24, 15, 30), currentDeadline: at(2026, 9, 24, 16, 0))
        #expect(until == at(2026, 9, 24, 17, 0))
        #expect(AutoStopPolicy.decide(now: at(2026, 9, 24, 16, 30), startedAt: start, settings: s,
                                      postponedUntil: until, calendar: cal)
                == .keepRunning(deadline: at(2026, 9, 24, 17, 0), reason: .postponed))
        #expect(AutoStopPolicy.decide(now: at(2026, 9, 24, 17, 0), startedAt: start, settings: s,
                                      postponedUntil: until, calendar: cal) == .stopNow(.postponed))
    }

    @Test func postponeAfterDeadlineCountsFromNow() {
        // Deadline already passed (e.g. prompt shown late) → now + by.
        #expect(AutoStopPolicy.postpone(now: at(2026, 9, 24, 16, 20), currentDeadline: at(2026, 9, 24, 16, 0),
                                        by: .seconds(1800)) == at(2026, 9, 24, 16, 50))
    }
}
